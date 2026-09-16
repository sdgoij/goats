// Part 6/16 of the goat scene: music streams, weather beds and goat bleats.
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
const BLEATS = [];
const THUNDERS = [];
const BLASTS = [];
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
    const bleatPaths = assetList("sfx.bleat");
    for (let i = 0; i < bleatPaths.length; i++) {
        const sound = rl.loadSound(bleatPaths[i]);
        if (sound >= 0) BLEATS.push(sound);
    }
    const thunderPaths = assetList("sfx.thunder");
    for (let i = 0; i < thunderPaths.length; i++) {
        const sound = rl.loadSound(thunderPaths[i]);
        if (sound >= 0) THUNDERS.push(sound);
    }
    const blastPaths = assetList("sfx.blast");
    for (let i = 0; i < blastPaths.length; i++) {
        const sound = rl.loadSound(blastPaths[i]);
        if (sound >= 0) BLASTS.push(sound);
    }
    const debrisPaths = assetList("sfx.debris");
    for (let i = 0; i < debrisPaths.length; i++) {
        const sound = rl.loadSound(debrisPaths[i]);
        if (sound >= 0) DEBRIS.push(sound);
    }
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
    const sound = BLEATS[Math.floor(arnd() * BLEATS.length) % BLEATS.length];
    rl.setSoundVolume(sound, sfxGain() * gain);
    rl.setSoundPitch(sound, 0.9 + arnd() * 0.25);
    rl.playSound(sound);
}

// A bang, at (x, z): `explosions.js` calls this the moment a device goes off,
// wherever the goat is. Unlike a bleat it is placed -- the volume falls off with the
// distance past the blast's own radius, because a mine three metres away and one
// across the meadow are not the same event -- and it is picked and pitched at
// random, since a minefield that fires the same sample twice in a row stops sounding
// like a place and starts sounding like a button.
function playBlast(x, z) {
    if (!audioReady || muted || BLASTS.length === 0) return;
    const dx = x - goat.px;
    const dz = z - goat.pz;
    const near = TUNING.explosions.blast.radius;
    const d = Math.max(0, Math.sqrt(dx * dx + dz * dz) - near);
    const att = 1 / (1 + d / BLAST_FALLOFF);
    const sound = BLASTS[Math.floor(arnd() * BLASTS.length) % BLASTS.length];
    rl.setSoundVolume(sound, sfxGain() * BLAST_VOLUME * att);
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
            sound: DEBRIS[Math.floor(arnd() * DEBRIS.length) % DEBRIS.length],
            att: att,
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
        const sound = THUNDERS[Math.floor(arnd() * THUNDERS.length) % THUNDERS.length];
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

