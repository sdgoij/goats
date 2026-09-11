// Part 7/8 of the goat scene: the weather state machine, wind and effects.
// ---- weather -------------------------------------------------------------

const WIND_BASE = 1.6;              // m/s
const CLOUD_DRIFT = 0.35;           // clouds move slower than the ground wind
const CLOUD_WRAP = 100;             // recycle clouds this far from the goat
const RAIN_MAX = 160;       // streaks; each is a drawLine, so this is a cost knob

const OVERCAST_TOP = rl.color(96, 102, 116, 255);
const OVERCAST_BOT = rl.color(150, 154, 162, 255);

// Weather bites into gameplay: rain and wind slow the goat down, and being wet
// and cold burns energy faster (on top of the existing night penalty).
const RAIN_SLOW = 0.28;      // at full rain the goat moves up to 28% slower
const WIND_SLOW = 0.07;      // a full gust slows it a little more
const WET_DRAIN = 0.65;      // up to +65% energy drain in heavy rain
const WIND_DRAIN = 0.20;
const WIND_NORM = 1.4;       // windSway value that counts as "a full gust"

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
const WEATHER_HOLD = { clear: [22, 45], cloudy: [16, 34], rain: [20, 40], clearing: [8, 16] };

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
(function buildRain() {
    for (let i = 0; i < RAIN_MAX; i++) {
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
    const speed = WIND_BASE * Math.max(0.2, gust);
    windX = Math.cos(dir) * speed;
    windZ = Math.sin(dir) * speed;
    windSway = Math.min(1.4, speed / WIND_BASE) * (0.55 + 0.45 * cloudiness);
}

function updateWeather(dt) {
    weatherTimer -= dt;
    if (weatherTimer <= 0) {
        const opts = WEATHER_NEXT[weatherKind];
        weatherKind = opts[Math.floor(rnd() * opts.length) % opts.length];
        const hold = WEATHER_HOLD[weatherKind];
        weatherTimer = hold[0] + rnd() * (hold[1] - hold[0]);
    }
    const target = WEATHER_STATES[weatherKind];
    const k = Math.min(1, dt * 0.6);
    cloudiness += (target.cloud - cloudiness) * k;
    rainAmount += (target.rain - rainAmount) * k;
    const windNorm = Math.min(1, windSway / WIND_NORM);
    // Gate on rain: "clear" stays exactly neutral, and wind only bites when the
    // goat is actually wet.
    weatherSpeed = 1 - (RAIN_SLOW + WIND_SLOW * windNorm) * rainAmount;
    weatherDrain = 1 + (WET_DRAIN + WIND_DRAIN * windNorm) * rainAmount;
    weatherText = weatherKind + "   wind " +
        Math.sqrt(windX * windX + windZ * windZ).toFixed(1) + " m/s";
    if (rainAmount > 0.02) weatherText = weatherText + "   rain " + Math.round(rainAmount * 100) + "%";
    if (weatherSpeed < 0.98) weatherText = weatherText + "   slowed " + Math.round((1 - weatherSpeed) * 100) + "%";
}

// C jumps to the next state, for previewing the cycle.
function forceWeather() {
    weatherKind = WEATHER_NEXT[weatherKind][0];
    weatherTimer = WEATHER_HOLD[weatherKind][0];
}

function updateClouds(dt) {
    const W = CLOUD_WRAP;
    for (let i = 0; i < CLOUDS.length; i++) {
        const c = CLOUDS[i];
        c.x += windX * CLOUD_DRIFT * dt;
        c.z += windZ * CLOUD_DRIFT * dt;
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
    rainActive = Math.round(RAIN_MAX * rainAmount);
    for (let i = 0; i < rainActive; i++) {
        const d = RAIN[i];
        d.y += (0.7 + d.speed) * dt;
        d.x += windX * 0.02 * dt;
        if (d.y > 1.05) {
            d.y = d.y - 1.1;
            d.x = hash(i * 13.1 + rngState * 0.0001);
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
            rl.drawCube(x + off, 0.06, z + off * 0.4, 0.14, 0.16, 0.14, tuftCol);
            if (d2 < detail2) {
                rl.drawCube(x + off * 1.7, 0.20, z + off * 0.7, 0.11, 0.16, 0.11, tuftCol);
            }
        }
    }
}

function drawGround(g, groundCol, tuftCol) {
    // Snap the slab to a 2-unit grid so it looks pinned down while we travel.
    const gx = Math.round(g.px / 2) * 2;
    const gz = Math.round(g.pz / 2) * 2;
    rl.drawCube(gx, -0.06, gz, 70, 0.1, 70, groundCol);
    drawTufts(g, tuftCol, 576, 180);   // cull beyond 24 units, detail inside ~13
}

