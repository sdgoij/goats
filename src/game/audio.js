// Part 6/10 of the goat scene: music streams, weather beds and goat bleats.
// ---- audio ---------------------------------------------------------------
//
// The background track and the weather beds are `Music` streams: they loop
// natively and stream from disk, so the long wind/rain files cost almost no
// memory. Bleats and thunder are short `Sound` effects, fired with a little
// pitch variation so repeats do not sound identical. Everything loads from
// `sfx/` on disk and fails silently if a file is missing.

const MUSIC_PATH = "sfx/jkstudios-rage-2-187959.mp3";
const RAIN_PATH = "sfx/WE Heavy Outside Rain 1.wav";
const WIND_PATH = "sfx/WE Light Wind Whistle 1.wav";
const BLEAT_PATHS = [
    "sfx/dragon-studio-goat-baa-390303.mp3",
    "sfx/dragon-studio-goat-kid-bleating-390290.mp3",
    "sfx/dragon-studio-goat-sound-390298.mp3",
    "sfx/dragon-studio-goat-sound-effect-390305.mp3",
    "sfx/mightuser-1-goat-sound-effect-259473.mp3",
    "sfx/freesound_community-happy-goat-6463.mp3",
];
const THUNDER_PATHS = [
    "sfx/WE Thunder 1.wav",
    "sfx/WE Thunder 26.wav",
    "sfx/WE Thunder 29.wav",
];

const MUSIC_VOLUME = 0.20;   // the background track sits well under the sfx
const SFX_VOLUME = 0.65;
const RAIN_VOLUME = 0.9;     // scaled by the rain amount
const WIND_VOLUME = 0.8;     // scaled by the wind gust

let audioReady = false;
let muted = false;
let musicMain = -1;
let rainLoop = -1;
let windLoop = -1;
const BLEATS = [];
const THUNDERS = [];
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
    musicMain = rl.loadMusic(MUSIC_PATH);
    if (musicMain >= 0) {
        rl.setMusicVolume(musicMain, MUSIC_VOLUME);
        rl.playMusic(musicMain);
    }
    for (let i = 0; i < BLEAT_PATHS.length; i++) {
        const sound = rl.loadSound(BLEAT_PATHS[i]);
        if (sound >= 0) BLEATS.push(sound);
    }
    for (let i = 0; i < THUNDER_PATHS.length; i++) {
        const sound = rl.loadSound(THUNDER_PATHS[i]);
        if (sound >= 0) THUNDERS.push(sound);
    }
    // The ambience beds start at silence and swell with the weather; keeping
    // them playing avoids a start/stop click at every transition.
    rainLoop = rl.loadMusic(RAIN_PATH);
    if (rainLoop >= 0) {
        rl.setMusicVolume(rainLoop, 0);
        rl.playMusic(rainLoop);
    }
    windLoop = rl.loadMusic(WIND_PATH);
    if (windLoop >= 0) {
        rl.setMusicVolume(windLoop, 0);
        rl.playMusic(windLoop);
    }
    audioReady = true;
    console.log("audio: music " + musicMain + " rain " + rainLoop + " wind " + windLoop +
        " bleats " + BLEATS.length + " thunder " + THUNDERS.length);
}

// Fire a random bleat. `gain` scales the base sfx volume for the situation.
function playBleat(gain) {
    if (!audioReady || muted || BLEATS.length === 0) return;
    const sound = BLEATS[Math.floor(arnd() * BLEATS.length) % BLEATS.length];
    rl.setSoundVolume(sound, SFX_VOLUME * gain);
    rl.setSoundPitch(sound, 0.9 + arnd() * 0.25);
    rl.playSound(sound);
}

// Called once per frame: keep every stream fed and tie the beds to the weather.
function updateAudio(dt) {
    if (!audioReady) return;
    if (musicMain >= 0) rl.updateMusic(musicMain);
    if (rainLoop >= 0) {
        rl.updateMusic(rainLoop);
        rl.setMusicVolume(rainLoop, muted ? 0 : MUSIC_VOLUME * RAIN_VOLUME * rainAmount);
    }
    if (windLoop >= 0) {
        rl.updateMusic(windLoop);
        rl.setMusicVolume(windLoop, muted ? 0 : MUSIC_VOLUME * WIND_VOLUME * windSway);
    }
    thunderCooldown -= dt;
    if (rainAmount > 0.55 && thunderCooldown <= 0 && THUNDERS.length > 0) {
        const sound = THUNDERS[Math.floor(arnd() * THUNDERS.length) % THUNDERS.length];
        if (!muted) {
            rl.setSoundVolume(sound, SFX_VOLUME * 0.8);
            rl.playSound(sound);
        }
        thunderCooldown = 8 + arnd() * 14;
    }
}

function setMuted(next) {
    muted = next;
    if (audioReady && musicMain >= 0) rl.setMusicVolume(musicMain, muted ? 0 : MUSIC_VOLUME);
}

