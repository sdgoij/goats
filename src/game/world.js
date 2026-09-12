// Part 3/11 of the goat scene: grass, the day/night curve, sun, moon and stars.
// ---- scenery -------------------------------------------------------------

// Grass is generated procedurally around the goat in `drawTufts` (weather.js),
// so the field extends as far as the eye (and the shadow pass) can see and never
// leaves bare ground behind after a walk.

// ---- day/night -----------------------------------------------------------

const DAY_LENGTH = 240;         // real seconds for one 24 h day
const TIME_FAST = 40;           // hold T to advance time this many times faster
const NIGHT_DRAIN_MULT = 1.6;   // energy drains faster in the cold

// Sky keyframes by hour: sky-top and horizon colours plus a 0..1 light factor
// used to tint the whole scene. Hour 24 repeats hour 0.
const SKY_KEYS = [
    { h: 0.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
    { h: 4.5, top: [12, 14, 34], bot: [26, 28, 54], light: 0.0 },
    { h: 6.0, top: [70, 70, 120], bot: [190, 120, 90], light: 0.25 },
    { h: 7.5, top: [120, 165, 220], bot: [235, 190, 150], light: 0.8 },
    { h: 12.0, top: [110, 170, 240], bot: [175, 210, 245], light: 1.0 },
    { h: 17.0, top: [120, 165, 220], bot: [235, 200, 160], light: 0.85 },
    { h: 19.0, top: [90, 80, 130], bot: [225, 130, 90], light: 0.35 },
    { h: 20.5, top: [26, 28, 58], bot: [70, 60, 90], light: 0.08 },
    { h: 22.0, top: [10, 12, 30], bot: [18, 22, 46], light: 0.0 },
    { h: 24.0, top: [8, 10, 28], bot: [16, 20, 44], light: 0.0 },
];

let worldTime = 8.0;        // hours, [0, 24)
let skyLight = 1.0;         // 0 (night) .. 1 (full day)
let skyWarm = 0.0;          // 0 (neutral) .. 1 (dawn/dusk warm)
let skyTop = 0;             // packed sky colours, refreshed each frame
let skyBot = 0;
let ambR = 1.0, ambG = 1.0, ambB = 1.0;
let ambTint = 0xFFFFFFFF;
let ambFur, ambFurDk, ambDark, ambHorn, ambHoof, ambEye, ambGround, ambTuft, ambShadow;
let clockText = "";

// Fixed star field on a big sphere; drawn relative to the goat so it reads as
// infinitely far away.
const STARS = [];
(function buildStars() {
    for (let i = 0; i < 320; i++) {
        const a = hash(i * 12.9898) * Math.PI * 2;
        const e = 0.05 + hash(i * 78.233) * 1.35;
        const r = Math.cos(e) * 90;
        STARS.push({ x: Math.cos(a) * r, y: Math.sin(e) * 90, z: Math.sin(a) * r, b: hash(i * 4.1) });
    }
})();

function mod24(h) {
    return ((h % 24) + 24) % 24;
}

function mix(a, b, t) {
    return a + (b - a) * t;
}

// Sample the sky curve at `h` hours: packed top/horizon colours and the light
// factor, interpolated between the two surrounding keyframes.
function skySample(h) {
    let i = 0;
    while (i < SKY_KEYS.length - 2 && h > SKY_KEYS[i + 1].h) i += 1;
    const a = SKY_KEYS[i];
    const b = SKY_KEYS[i + 1];
    const span = b.h - a.h;
    const t = span > 0 ? (h - a.h) / span : 0;
    return {
        top: rl.color(
            Math.round(mix(a.top[0], b.top[0], t)),
            Math.round(mix(a.top[1], b.top[1], t)),
            Math.round(mix(a.top[2], b.top[2], t)), 255),
        bot: rl.color(
            Math.round(mix(a.bot[0], b.bot[0], t)),
            Math.round(mix(a.bot[1], b.bot[1], t)),
            Math.round(mix(a.bot[2], b.bot[2], t)), 255),
        light: mix(a.light, b.light, t),
    };
}

// Multiply a packed 0xRRGGBBAA colour by per-channel factors.
function scaleColor(packed, fr, fg, fb) {
    return rl.color(
        Math.round(((packed >>> 24) & 255) * fr),
        Math.round(((packed >>> 16) & 255) * fg),
        Math.round(((packed >>> 8) & 255) * fb),
        255);
}

// Refresh the scene's ambient tint once per frame: a dim, blue-shifted version
// of daylight, plus the palette the fallback goat and terrain are drawn with.
function updateAmbient() {
    const t = skyLight;
    // Warm the light around dawn and dusk (light factor near 0.3).
    const warm = Math.max(0, Math.min(1, 1 - Math.abs(t - 0.3) / 0.34));
    skyWarm = warm;
    ambR = Math.min(1, 0.40 + 0.60 * t + 0.14 * warm);
    ambG = Math.min(1, 0.44 + 0.56 * t + 0.02 * warm);
    ambB = Math.min(1, 0.62 + 0.38 * t - 0.14 * warm);
    ambTint = rl.color(Math.round(255 * ambR), Math.round(255 * ambG), Math.round(255 * ambB), 255);
    ambFur = scaleColor(FUR, ambR, ambG, ambB);
    ambFurDk = scaleColor(FUR_DK, ambR, ambG, ambB);
    ambDark = scaleColor(DARK, ambR, ambG, ambB);
    ambHorn = scaleColor(HORN, ambR, ambG, ambB);
    ambHoof = scaleColor(HOOF, ambR, ambG, ambB);
    ambEye = scaleColor(EYE, ambR, ambG, ambB);
    ambGround = scaleColor(GROUND, ambR, ambG, ambB);
    ambTuft = scaleColor(TUFT, ambR, ambG, ambB);
    const dark = 1 - 0.5 * t;
    ambShadow = scaleColor(GROUND, ambR * dark, ambG * dark, ambB * dark);
}

function drawStars() {
    const fade = (0.35 - skyLight) / 0.35;
    if (fade <= 0) return;
    for (let i = 0; i < STARS.length; i++) {
        const s = Math.round((120 + 135 * STARS[i].b) * fade);
        rl.drawPoint3D(goat.px + STARS[i].x, STARS[i].y, goat.pz + STARS[i].z,
            rl.color(s, s, Math.min(255, s + 25), 255));
    }
}

// Sun and moon on opposite sides of a celestial sphere, arcing east to west
// between 06:00 and 18:00. The sun is a stack of soft glow billboards (a hard
// `drawSphere` reads flat), the moon a procedural cratered disc with a halo.
function drawCelestial() {
    const a = ((worldTime - 6) / 12) * Math.PI;   // 0 at 06:00, PI at 18:00
    const dx = Math.cos(a);
    const dy = Math.sin(a);
    const R = 70;
    const sx = goat.px + dx * R;
    const sy = dy * R;
    if (dy > -0.25 && glowTex >= 0) {
        const warm = 0.55 + 0.45 * Math.max(0, dy);
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 26,
            rl.color(255, Math.round(205 * warm + 30), Math.round(115 * warm + 40), 34));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 14,
            rl.color(255, Math.round(220 * warm + 30), Math.round(150 * warm + 70), 64));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 7.2, rl.color(255, 250, 225, 140));
        rl.drawBillboard(glowTex, sx, sy, goat.pz, 3.2, rl.color(255, 255, 246, 255));
    }
    if (dy < 0.25 && moonTex >= 0) {
        rl.drawBillboard(glowTex, goat.px - dx * R, -dy * R, goat.pz, 9.5,
            rl.color(196, 212, 240, 44));
        rl.drawBillboard(moonTex, goat.px - dx * R, -dy * R, goat.pz, 3.0,
            rl.color(255, 255, 255, 255));
    }
}

// Cheap contact shadow: a flattened dark rectangle under the goat, darker and
// longer-lived the higher the sun. Used only when the lit shader is unavailable;
// with lighting on the goat casts a real projected silhouette (see below).
function drawShadow() {
    if (skyLight <= 0.05) return;
    rl.drawCube(goat.px, 0.02, goat.pz, 1.25, 0.012, 1.7, ambShadow);
}

