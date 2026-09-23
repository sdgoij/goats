// ---- audio ---------------------------------------------------------------
//
// The background track and the weather beds are `Music` streams: they loop
// natively and stream, so the long wind/rain files cost almost no memory.
// Bleats, thunder, bangs and the grit a bang throws are short `Sound` effects, fired
// with a little pitch variation so repeats do not sound identical; a bang also fades
// with its distance, and its debris follows it a beat later (`playBlast`,
// `updateAudio`). Every path below is embedded in
// the binary by the host (`crates/goats/src/main.rs`), which registers each name
// with `register_raylib_asset`; the loader looks the bytes up by name, so the
// game needs no files on disk and a missing name just falls back to `sfx/`.

// Every clip is named by an asset slot (core.js). The defaults are the embedded
// files; a mod that declares an asset for a slot replaces it, so the loaders
// below read the slot rather than a path.

const MUSIC_VOLUME = 0.20;   // the background track sits well under the sfx
const SFX_VOLUME = 0.65;
const RAIN_VOLUME = 0.9;     // scaled by the rain amount
const WIND_VOLUME = 0.8;     // scaled by the wind gust
// A bang is the one thing in the scene that carries: the blast's own radius is the
// point beyond which it starts to fall away, and `BLAST_FALLOFF` is the distance
// over which it loses half of what is left. A mine going off across the field is
// still audible, which is the whole reason to look up.
const BLAST_VOLUME = 1.0;
const BLAST_FALLOFF = 24;
// How far from a bang the optional `sfx.blast.close` mix takes over from the roomier
// one: the slot is the cleaner "you got hit" version of the same sample (M19g).
const BLAST_CLOSE_RANGE = 6;
// The trigger's click and a trapped tuft's snap, under the bang they promise.
const FUSE_VOLUME = 0.5;
const TRAP_VOLUME = 0.6;
// How many copies of each effect are loaded per slot (M19g). A `Sound` handle played
// twice *restarts*, so a bang inside the tail of the last one used to cut it off; three
// copies is what lets two bangs sound like two bangs rather than like one that hiccuped.
const SFX_POOL = 3;
// The grit comes down under the bang it came from, a beat later: `DEBRIS_DELAY` is
// where it starts and `DEBRIS_SPREAD` is the jitter on top, so two bangs in a chain
// do not land their dirt in lockstep. The puff lasts 0.9 s (explosions.js), so this
// puts the falls in the second half of it.
const DEBRIS_VOLUME = 0.55;
const DEBRIS_DELAY = 0.42;
const DEBRIS_SPREAD = 0.34;
const DEBRIS_CAPACITY = 8;   // pending falls; a dense field must not queue a crowd

// Settings scale the two base levels: SETTINGS.bgm / SETTINGS.sfx are 0..100
// (see menu.js).
function musicGain() { return MUSIC_VOLUME * SETTINGS.bgm / 100; }
function sfxGain() { return SFX_VOLUME * SETTINGS.sfx / 100; }

// Re-apply the music volume after a settings change (SFX volume is set per play).
function applyAudioSettings() {
    if (audioReady && musicMain >= 0) rl.setMusicVolume(musicMain, muted ? 0 : musicGain());
    voiceGainChanged();
}

// Voice chat is mixed in Rust (the `rl` surface has no audio streams), so the
// only thing the scene owes it is the master mute. Sent on change, and the
// starting value matches the host's own default gain of 1, so a session that
// starts unmuted queues nothing at rest.
let voiceGainSent = 1;
function voiceGainChanged() {
    const gain = muted ? 0 : 1;
    if (gain === voiceGainSent) return;
    voiceGainSent = gain;
    netQueue({ type: "voice_gain", gain: gain });
}

let audioReady = false;
let muted = false;
let musicMain = -1;
let rainLoop = -1;
let windLoop = -1;
// Each slot is a list of *variants*, and each variant a list of copies (M19g): the
// variant is picked so a field does not sound like a button, the copy so two of them
// can be in the air at once.
const BLEATS = [];
const THUNDERS = [];
const BLASTS = [];
const BLASTS_CLOSE = [];
const FUSES = [];
const TRAPS = [];
const DEBRIS = [];
// The bangs whose dirt has not come down yet. A bang is an instant; the load it
// throws is not, and the delay is the whole point of the sound -- without it the
// grit is just a second layer of explosion.
const DEBRIS_QUEUE = [];
let thunderCooldown = 6;
let audioSeed = 0x2f6e2b1;

// A PRNG for audio variety, kept separate from the weather's so the weather
// sequence stays reproducible.
function arnd() {
    audioSeed ^= audioSeed << 13;
    audioSeed >>>= 0;
    audioSeed ^= audioSeed >>> 17;
    audioSeed ^= audioSeed << 5;
    audioSeed >>>= 0;
    return audioSeed / 4294967296;
}

// Load the short effects from the current slot table. Kept apart from `makeAudio`
// because the table can move at runtime: a mod that fills a slot is enabled or
// disabled, or is pulled in from a host, and the sounds it names have to be picked
// up then. The track and the two weather beds are *not* here -- they are streams
// that are already playing, and re-pointing a slot must not restart them.
function loadSfx() {
    BLEATS.length = 0;
    THUNDERS.length = 0;
    BLASTS.length = 0;
    BLASTS_CLOSE.length = 0;
    FUSES.length = 0;
    TRAPS.length = 0;
    DEBRIS.length = 0;
    DEBRIS_QUEUE.length = 0;   // a fall queued for a handle that is going away
    loadSlot(BLEATS, assetList("sfx.bleat"));
    loadSlot(THUNDERS, assetList("sfx.thunder"));
    loadSlot(BLASTS, assetList("sfx.blast"));
    loadSlot(BLASTS_CLOSE, assetList("sfx.blast.close"));
    loadSlot(FUSES, assetList("sfx.fuse"));
    loadSlot(TRAPS, assetList("sfx.trap"));
    loadSlot(DEBRIS, assetList("sfx.debris"));
}

// One slot's variants into `out`, each with `SFX_POOL` copies. A slot with no files is
// simply empty -- the three M19g slots start that way, because the samples have not
// arrived: silence is the degradation, exactly like a missing texture.
function loadSlot(out, paths) {
    for (let i = 0; i < paths.length; i++) {
        const copies = [];
        for (let c = 0; c < SFX_POOL; c++) {
            const sound = rl.loadSound(paths[i]);
            if (sound >= 0) copies.push(sound);
        }
        if (copies.length > 0) out.push(copies);
    }
}

// One play out of a slot: a variant at random, and inside it a copy that is not already
// in the air. `isSoundPlaying` is the only clock the audio side has, and it is the right
// one -- what matters is whether *this* handle is busy, not how long it has been.
function sfxPick(slot) {
    const variant = slot[Math.floor(arnd() * slot.length) % slot.length];
    for (let i = 0; i < variant.length; i++) {
        if (typeof rl.isSoundPlaying !== "function" || !rl.isSoundPlaying(variant[i])) {
            return variant[i];
        }
    }
    return variant[0];
}

// Re-read the effects because the slot table moved. A `Sound` that has already been
// loaded cannot be un-picked -- the `rl` surface has no `unloadSound` -- so the old
// handles are dropped rather than freed, which leaks one decoded buffer per toggle.
// That is the price of a mod going quiet the moment it is switched off.
function reloadSfx() {
    if (!audioReady) return;
    loadSfx();
    console.log("audio: effects reloaded, bleats " + BLEATS.length + " thunder " +
        THUNDERS.length + " blasts " + BLASTS.length + " debris " + DEBRIS.length);
}

function makeAudio() {
    if (typeof rl.loadMusic !== "function" || typeof rl.loadSound !== "function" ||
        typeof rl.updateMusic !== "function" || typeof rl.initAudioDevice !== "function") {
        console.log("audio: engine has no audio bindings");
        return;
    }
    rl.initAudioDevice();
    musicMain = rl.loadMusic(ASSET_SLOTS["sfx.music"]);
    if (musicMain >= 0) {
        rl.setMusicVolume(musicMain, musicGain());
        rl.playMusic(musicMain);
    }
    loadSfx();
    // The ambience beds start at silence and swell with the weather; keeping
    // them playing avoids a start/stop click at every transition.
    rainLoop = rl.loadMusic(ASSET_SLOTS["sfx.rain"]);
    if (rainLoop >= 0) {
        rl.setMusicVolume(rainLoop, 0);
        rl.playMusic(rainLoop);
    }
    windLoop = rl.loadMusic(ASSET_SLOTS["sfx.wind"]);
    if (windLoop >= 0) {
        rl.setMusicVolume(windLoop, 0);
        rl.playMusic(windLoop);
    }
    audioReady = true;
    console.log("audio: music " + musicMain + " rain " + rainLoop + " wind " + windLoop +
        " bleats " + BLEATS.length + " thunder " + THUNDERS.length +
        " blasts " + BLASTS.length + " debris " + DEBRIS.length);
}

// Fire a random bleat. `gain` scales the base sfx volume for the situation.
function playBleat(gain) {
    if (!audioReady || muted || BLEATS.length === 0) return;
    const sound = sfxPick(BLEATS);
    rl.setSoundVolume(sound, sfxGain() * gain);
    rl.setSoundPitch(sound, 0.9 + arnd() * 0.25);
    rl.playSound(sound);
}

// How loud a bang at (x, z) is from where the goat is: full volume anywhere inside the
// blast itself, half at twenty-odd metres, and tending to silence rather than reaching it.
function blastAttenuation(x, z) {
    const dx = x - goat.px;
    const dz = z - goat.pz;
    const near = TUNING.explosions.blast.radius;
    const d = Math.max(0, Math.sqrt(dx * dx + dz * dz) - near);
    return 1 / (1 + d / BLAST_FALLOFF);
}

// The click between the trigger and the bang (M19g): `sfx.trap` for a trapped tuft, which
// is a snap, and `sfx.fuse` for a mine, which is a click and a whine. Played at the
// *trigger*, so a device the goat walks away from still ticks behind it -- and silent when
// the slot is empty, which is where the samples have not arrived yet.
function playTrigger(kind, x, z) {
    if (!audioReady || muted) return;
    const slot = kind === "trap" ? TRAPS : FUSES;
    if (slot.length === 0) return;
    const sound = sfxPick(slot);
    rl.setSoundVolume(sound, sfxGain() * (kind === "trap" ? TRAP_VOLUME : FUSE_VOLUME) *
        blastAttenuation(x, z));
    rl.setSoundPitch(sound, 0.95 + arnd() * 0.1);
    rl.playSound(sound);
}

// A bang, at (x, z): `explosions.js` calls this the moment a device goes off,
// wherever the goat is. Unlike a bleat it is placed -- the volume falls off with the
// distance past the blast's own radius, because a mine three metres away and one
// across the meadow are not the same event -- and it is picked and pitched at
// random, since a minefield that fires the same sample twice in a row stops sounding
// like a place and starts sounding like a button.
function playBlast(x, z, depth) {
    if (!audioReady || muted) return;
    const att = blastAttenuation(x, z);
    // A chained bang is a beat rather than a bang (M19g): quieter with every link, so a
    // five-device cascade reads as a sequence instead of five times the peak. `depth` is
    // the chain's own, and a first bang has none.
    const chain = 1 / (1 + 0.6 * (depth > 0 ? depth : 0));
    // The close mix, when there is one and the goat is in it (M19g): the same bang
    // without the room, which is the "you got hit" version rather than the "that went off
    // over there" one. A slot nobody has filled is the ordinary bang.
    const dx = x - goat.px;
    const dz = z - goat.pz;
    const near = BLASTS_CLOSE.length > 0 && dx * dx + dz * dz <= BLAST_CLOSE_RANGE * BLAST_CLOSE_RANGE;
    const slot = near ? BLASTS_CLOSE : BLASTS;
    if (slot.length === 0) return;
    const sound = sfxPick(slot);
    rl.setSoundVolume(sound, sfxGain() * BLAST_VOLUME * att * chain);
    rl.setSoundPitch(sound, 0.92 + arnd() * 0.16);
    rl.playSound(sound);
    // ...and its grit, later (`updateAudio` plays it). What is queued is the
    // *distance* the bang was heard at and not the goat's, so the fall belongs to
    // the same event even though the goat has usually been thrown clear by the time
    // it lands -- which is what it sounds like from underneath a flying goat.
    if (DEBRIS.length > 0) {
        if (DEBRIS_QUEUE.length >= DEBRIS_CAPACITY) DEBRIS_QUEUE.shift();
        DEBRIS_QUEUE.push({
            left: DEBRIS_DELAY + arnd() * DEBRIS_SPREAD,
            sound: sfxPick(DEBRIS),
            att: att * chain,
        });
    }
}

// Called once per frame: keep every stream fed and tie the beds to the weather.
function updateAudio(dt) {
    if (!audioReady) return;
    if (musicMain >= 0) rl.updateMusic(musicMain);
    if (rainLoop >= 0) {
        rl.updateMusic(rainLoop);
        rl.setMusicVolume(rainLoop, muted ? 0 : musicGain() * RAIN_VOLUME * rainAmount);
    }
    if (windLoop >= 0) {
        rl.updateMusic(windLoop);
        rl.setMusicVolume(windLoop, muted ? 0 : musicGain() * WIND_VOLUME * windSway);
    }
    thunderCooldown -= dt;
    if (rainAmount > 0.55 && thunderCooldown <= 0 && THUNDERS.length > 0) {
        const sound = sfxPick(THUNDERS);
        if (!muted) {
            rl.setSoundVolume(sound, sfxGain() * 0.8);
            rl.playSound(sound);
        }
        thunderCooldown = 8 + arnd() * 14;
    }
    // Whatever grit is due. The gain and the mute are read here rather than at the
    // bang, so a player who turns the volume down in the second between the two
    // hears the change.
    for (let i = DEBRIS_QUEUE.length - 1; i >= 0; i--) {
        const fall = DEBRIS_QUEUE[i];
        fall.left -= dt;
        if (fall.left > 0) continue;
        DEBRIS_QUEUE.splice(i, 1);
        if (muted) continue;
        rl.setSoundVolume(fall.sound, sfxGain() * DEBRIS_VOLUME * fall.att);
        rl.setSoundPitch(fall.sound, 0.9 + arnd() * 0.2);
        rl.playSound(fall.sound);
    }
}

function setMuted(next) {
    muted = next;
    applyAudioSettings();
}

