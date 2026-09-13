// Part 7/15 of the goat scene: the weather state machine, wind and effects.
// ---- weather -------------------------------------------------------------

// The wind, rain and gameplay-impact numbers live in `TUNING.weather`
// (core.js). `CLOUD_WRAP` stays here: it is structural rather than a tuning
// knob.
const CLOUD_WRAP = 100;             // recycle clouds this far from the goat

const OVERCAST_TOP = rl.color(96, 102, 116, 255);
const OVERCAST_BOT = rl.color(150, 154, 162, 255);

const WEATHER_STATES = {
    clear: { cloud: 0.05, rain: 0.0 },
    cloudy: { cloud: 0.70, rain: 0.0 },
    rain: { cloud: 1.00, rain: 1.0 },
    clearing: { cloud: 0.40, rain: 0.12 },
};
const WEATHER_NEXT = {
    clear: ["cloudy"],
    cloudy: ["rain", "clear"],
    rain: ["clearing"],
    clearing: ["clear", "cloudy"],
};

let cloudTex = -1;
let weatherKind = "clear";
let weatherTimer = 24;
let cloudiness = 0.05;      // 0..1, eased toward the state's target
let rainAmount = 0.0;       // 0..1, eased
let rainActive = 0;
let windX = 1.0, windZ = 0.2;
let windSway = 0.4;
let weatherSpeed = 1.0;      // multiplier on the goat's ground speed
let weatherDrain = 1.0;      // multiplier on its energy drain
let swayTime = 0.0;
let weatherText = "";
let rngState = 0x9e3779b9;
// The rain's own stream. Kept separate so a client -- which does not run the
// weather state machine, and so never advances `rngState` -- still gets varied
// streaks, and so offline rain does not perturb the weather sequence the harness
// asserts on.
let rainSeed = 0x13579bdf;

// Derive every scene PRNG from the session seed, so two players in the same
// session run the same weather, food regrowth and bleat variety. Offline the
// streams keep the constants above, which is what makes the harness stable.
// Each stream is a separate xorshift draw from the seed rather than the seed
// itself, so they do not move in lockstep.
function sceneUseSeed(seed) {
    let s = (seed | 0) || 1;
    const next = function () {
        s ^= s << 13;
        s >>>= 0;
        s ^= s >>> 17;
        s ^= s << 5;
        s >>>= 0;
        return s;
    };
    rngState = next() || 1;
    botRngState = next() || 1;
    foodRngState = next() || 1;
    audioSeed = next() || 1;
}

// The four stream states. A seam for the headless harness, which cannot read
// lexical `let`s out of the scene realm directly.
function sceneStreams() {
    return { weather: rngState, bots: botRngState, food: foodRngState, audio: audioSeed };
}

// Adopt the server's streams. Joining takes the server's PRNG state as it is
// *now* -- not the seed it started from -- so a stream the client still draws
// from continues where the server is instead of replaying from zero. The world
// snapshot keeps re-adopting them, so the two cannot drift.
function sceneUseStreams(streams) {
    if (!streams) return;
    rngState = streams.weather >>> 0;
    botRngState = streams.bots >>> 0;
    foodRngState = streams.food >>> 0;
    audioSeed = streams.audio >>> 0;
}

// Offline and the host run the weather state machine; a client takes the
// server's and only recomputes the per-goat effects.
function netWeatherLocal() {
    return netMode !== "client";
}

// The weather as the wire sees it. Snake_case keys, so `proto::WeatherState`
// deserialises it unchanged.
function sceneWeatherState() {
    return {
        kind: weatherKind,
        cloudiness: netRound3(cloudiness),
        rain_amount: netRound3(rainAmount),
        wind_x: netRound3(windX),
        wind_z: netRound3(windZ),
        wind_sway: netRound3(windSway),
        world_time: netRound3(worldTime),
    };
}

// Take the server's sky. The wind and the eased amounts come straight from it;
// `weatherSpeed`/`weatherDrain` are recomputed here, because they depend on this
// goat's own belly.
function applyWeatherState(state) {
    if (!state) return;
    weatherKind = state.kind;
    cloudiness = state.cloudiness;
    rainAmount = state.rain_amount;
    windX = state.wind_x;
    windZ = state.wind_z;
    windSway = state.wind_sway;
    worldTime = state.world_time;
    updateWeatherEffects();
}

// Deterministic PRNG (xorshift32) so a run's weather is reproducible and the
// headless harness stays stable.
function rnd() {
    rngState ^= rngState << 13;
    rngState >>>= 0;
    rngState ^= rngState >>> 17;
    rngState ^= rngState << 5;
    rngState >>>= 0;
    return rngState / 4294967296;
}

// Value noise, for the cloud puff sprite.
function vnoise2(x, y) {
    const xi = Math.floor(x);
    const yi = Math.floor(y);
    const xf = x - xi;
    const yf = y - yi;
    const u = xf * xf * (3 - 2 * xf);
    const v = yf * yf * (3 - 2 * yf);
    const a = hash(xi * 57.0 + yi * 131.0);
    const b = hash((xi + 1) * 57.0 + yi * 131.0);
    const c = hash(xi * 57.0 + (yi + 1) * 131.0);
    const d = hash((xi + 1) * 57.0 + (yi + 1) * 131.0);
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v;
}

function lerpColor(a, b, t) {
    const ar = (a >>> 24) & 255;
    const ag = (a >>> 16) & 255;
    const ab = (a >>> 8) & 255;
    const br = (b >>> 24) & 255;
    const bg = (b >>> 16) & 255;
    const bb = (b >>> 8) & 255;
    return rl.color(
        Math.round(ar + (br - ar) * t),
        Math.round(ag + (bg - ag) * t),
        Math.round(ab + (bb - ab) * t), 255);
}

const CLOUDS = [];
(function buildClouds() {
    for (let i = 0; i < 46; i++) {
        const a = hash(i * 2.1) * Math.PI * 2;
        const r = 26 + hash(i * 3.3) * 74;
        CLOUDS.push({
            x: Math.cos(a) * r,
            z: Math.sin(a) * r,
            y: 26 + hash(i * 5.5) * 22,
            size: 12 + hash(i * 7.1) * 22,
            cover: hash(i * 9.9),
        });
    }
})();

const RAIN = [];
// Built once, but with headroom: `TUNING.weather.rainMax` selects how many of
// these are active, so a mod can raise the count without rebuilding the array.
const RAIN_CAPACITY = 1024;
(function buildRain() {
    for (let i = 0; i < RAIN_CAPACITY; i++) {
        RAIN.push({ x: hash(i * 1.7), y: hash(i * 2.9), speed: 0.6 + hash(i * 4.3) });
    }
})();

// A soft noise-modulated puff, built once at startup.
function makeWeatherTextures() {
    const N = 48;
    let puff = "";
    for (let y = 0; y < N; y++) {
        for (let x = 0; x < N; x++) {
            const u = (x + 0.5) / N - 0.5;
            const v = (y + 0.5) / N - 0.5;
            const d = Math.sqrt(u * u + v * v) / 0.5;
            let a = 0;
            if (d < 1) {
                const n = 0.55 * vnoise2(x * 0.18, y * 0.18) +
                    0.30 * vnoise2(x * 0.37 + 11, y * 0.37 + 7) +
                    0.15 * vnoise2(x * 0.71 + 23, y * 0.71 + 5);
                a = (1 - d) * (n * 1.8 - 0.32);
                a = Math.min(1, Math.max(0, a)) * 255;
            }
            puff += "ffffff" + HEX256[Math.round(a)];
        }
    }
    cloudTex = rl.makeTexture(N, N, puff);
}

function updateWind(dt) {
    swayTime += dt;
    const gust = 0.55 + 0.35 * Math.sin(swayTime * 0.7) + 0.2 * Math.sin(swayTime * 1.9 + 1.3);
    const dir = 0.5 * Math.sin(swayTime * 0.23);
    const speed = TUNING.weather.windBase * Math.max(0.2, gust);
    windX = Math.cos(dir) * speed;
    windZ = Math.sin(dir) * speed;
    windSway = Math.min(1.4, speed / TUNING.weather.windBase) * (0.55 + 0.45 * cloudiness);
}

// The rain's slowdown share, eased by how full the goat's belly is: `satiety`
// (food.js) scales it down by up to `TUNING.food.rainShelter`, so a grazed goat
// keeps more of its speed in the wet. Wind is not affected.
function rainSlowFactor(sat) {
    return TUNING.weather.rainSlow * (1 - TUNING.food.rainShelter * clamp(sat, 0, 1));
}

// The ground-speed multiplier the weather imposes on a goat with the given
// belly (0..1): rain slows it, wind adds a little, and a full belly eases the
// rain share. Shared by the player and the bots so the herd feels the same
// weather, each according to its own grazing.
function weatherSpeedFor(sat) {
    const windNorm = Math.min(1, windSway / TUNING.weather.windNorm);
    return 1 - (rainSlowFactor(sat) + TUNING.weather.windSlow * windNorm) * rainAmount;
}

function updateWeather(dt) {
    weatherTimer -= dt;
    if (weatherTimer <= 0) {
        const opts = WEATHER_NEXT[weatherKind];
        const previous = weatherKind;
        weatherKind = opts[Math.floor(rnd() * opts.length) % opts.length];
        const hold = TUNING.weather.hold[weatherKind];
        weatherTimer = hold[0] + rnd() * (hold[1] - hold[0]);
        modEmit("weather", weatherKind, previous);
    }
    const target = WEATHER_STATES[weatherKind];
    const k = Math.min(1, dt * 0.6);
    cloudiness += (target.cloud - cloudiness) * k;
    rainAmount += (target.rain - rainAmount) * k;
    updateWeatherEffects();
}

// The per-goat side of the weather: how much it slows the goat down, how much
// extra energy it burns, and the HUD line. Split out because a client applies
// the server's cloudiness/rain/wind and still has to run this every frame -- the
// belly is its own.
function updateWeatherEffects() {
    const windNorm = Math.min(1, windSway / TUNING.weather.windNorm);
    // Gate on rain: "clear" stays exactly neutral, and wind only bites when the
    // goat is actually wet. A full belly (`satiety`, food.js) takes the edge off
    // the rain's slowdown.
    weatherSpeed = weatherSpeedFor(satiety);
    weatherDrain = 1 + (TUNING.weather.wetDrain + TUNING.weather.windDrain * windNorm) * rainAmount;
    weatherText = weatherKind + "   wind " +
        Math.sqrt(windX * windX + windZ * windZ).toFixed(1) + " m/s";
    if (rainAmount > 0.02) weatherText = weatherText + "   rain " + Math.round(rainAmount * 100) + "%";
    if (weatherSpeed < 0.98) weatherText = weatherText + "   slowed " + Math.round((1 - weatherSpeed) * 100) + "%";
}

// C jumps to the next state, for previewing the cycle.
function forceWeather() {
    const previous = weatherKind;
    weatherKind = WEATHER_NEXT[weatherKind][0];
    weatherTimer = TUNING.weather.hold[weatherKind][0];
    modEmit("weather", weatherKind, previous);
}

function updateClouds(dt) {
    const W = CLOUD_WRAP;
    for (let i = 0; i < CLOUDS.length; i++) {
        const c = CLOUDS[i];
        c.x += windX * TUNING.weather.cloudDrift * dt;
        c.z += windZ * TUNING.weather.cloudDrift * dt;
        if (c.x - goat.px > W) c.x -= 2 * W;
        else if (c.x - goat.px < -W) c.x += 2 * W;
        if (c.z - goat.pz > W) c.z -= 2 * W;
        else if (c.z - goat.pz < -W) c.z += 2 * W;
    }
}

function drawClouds() {
    if (cloudTex < 0 || cloudiness < 0.04) return;
    const t = skyLight;
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(t - 0.3) / 0.34));
    const cr = Math.min(255, Math.round(118 + 137 * t + 30 * warm));
    const cg = Math.min(255, Math.round(122 + 133 * t + 8 * warm));
    const cb = Math.min(255, Math.round(140 + 115 * t - 20 * warm));
    for (let i = 0; i < CLOUDS.length; i++) {
        const c = CLOUDS[i];
        if (c.cover > cloudiness) continue;
        const grow = Math.min(1, (cloudiness - c.cover) / 0.3 + 0.4);
        rl.drawBillboard(cloudTex, c.x, c.y, c.z, c.size,
            rl.color(cr, cg, cb, Math.round(190 * cloudiness * grow)));
    }
}

function updateRain(dt) {
    rainActive = Math.min(RAIN.length, Math.round(TUNING.weather.rainMax * rainAmount));
    for (let i = 0; i < rainActive; i++) {
        const d = RAIN[i];
        d.y += (0.7 + d.speed) * dt;
        d.x += windX * 0.02 * dt;
        if (d.y > 1.05) {
            d.y = d.y - 1.1;
            rainSeed ^= rainSeed << 13;
            rainSeed >>>= 0;
            rainSeed ^= rainSeed >>> 17;
            rainSeed ^= rainSeed << 5;
            rainSeed >>>= 0;
            d.x = hash(i * 13.1 + rainSeed * 0.0001);
        }
        if (d.x > 1.1) d.x = d.x - 1.2;
        else if (d.x < -0.1) d.x = d.x + 1.2;
    }
}

// Screen-space rain overlay: short streaks angled along the wind.
function drawRain(w, h) {
    if (rainActive <= 0) return;
    const slant = windX * 0.035;
    const col = rl.color(182, 202, 232, 150);
    for (let i = 0; i < rainActive; i++) {
        const d = RAIN[i];
        const sx = d.x * w;
        const sy = d.y * h;
        const len = 0.045 * h * (0.6 + d.speed);
        rl.drawLine(Math.round(sx), Math.round(sy),
            Math.round(sx + slant * w), Math.round(sy + len), col);
    }
}

// Grass tufts, leaning with the gust, generated per 2-unit cell from a hash of
// the cell so the field follows the goat and never runs out -- a fixed patch
// leaves bare ground behind after a walk. The hash is inlined rather than calling
// `hash()` to keep the per-frame JS call depth shallow. Shared with the shadow
// pass, which draws the same cubes through the depth program so the grass casts
// too. `cull2` is the cull radius squared; nearer tufts get a second segment so
// the bend reads up close.
function drawTufts(g, tuftCol, cull2, detail2) {
    const r = Math.sqrt(cull2);
    const cx0 = Math.floor((g.px - r) * 0.5);
    const cx1 = Math.ceil((g.px + r) * 0.5);
    const cz0 = Math.floor((g.pz - r) * 0.5);
    const cz1 = Math.ceil((g.pz + r) * 0.5);
    for (let cx = cx0; cx <= cx1; cx++) {
        for (let cz = cz0; cz <= cz1; cz++) {
            let h = (cx * 374761393 + cz * 668265263) | 0;
            h = Math.imul(h ^ (h >>> 13), 1274126177);
            h = (h ^ (h >>> 16)) >>> 0;
            const a = h / 4294967296;             // existence (and z jitter)
            if (a < 0.45) continue;
            // Eaten cells are skipped entirely, so the field thins as the goat
            // grazes. The key mirrors `tuftKey` in food.js, inlined to keep the
            // per-cell call depth down.
            if (EATEN.has((cx + 4096) * 8192 + (cz + 4096))) continue;
            let h2 = (cx * 1103515245 + cz * 12345) | 0;
            h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
            let h3 = (cx * 2654435761 + cz * 40503) | 0;
            h3 = Math.imul(h3 ^ (h3 >>> 16), 3266489917);
            h3 = (h3 ^ (h3 >>> 16)) >>> 0;
            const x = cx * 2 + (h2 / 4294967296 - 0.5) * 1.8;
            const z = cz * 2 + (a - 0.5) * 1.8;
            const tx = x - g.px;
            const tz = z - g.pz;
            const d2 = tx * tx + tz * tz;
            if (d2 > cull2) continue;
            const off = Math.sin(swayTime * 3.0 + (h3 / 4294967296) * 6.28) * 0.11 * windSway;
            // The tuft sits on the heightfield, so the grass follows the ground.
            // The cell's height is cached: the field is world-anchored, so a
            // cell never changes, and this drops the visible field's ~500 noise
            // samples per frame to nearly none (the key mirrors `tuftKey` in
            // food.js). Inlined rather than a helper call, to keep the per-frame
            // depth shallow.
            const hkey = (cx + 4096) * 8192 + (cz + 4096);
            let gy = TERRAIN_CELL_H.get(hkey);
            if (gy === undefined) {
                gy = terrainHeight(x, z);
                if (TERRAIN_CELL_H.size > 32768) TERRAIN_CELL_H.clear();
                TERRAIN_CELL_H.set(hkey, gy);
            }
            rl.drawCube(x + off, gy + 0.06, z + off * 0.4, 0.14, 0.16, 0.14, tuftCol);
            if (d2 < detail2) {
                rl.drawCube(x + off * 1.7, gy + 0.20, z + off * 0.7, 0.11, 0.16, 0.11, tuftCol);
            }
        }
    }
}

