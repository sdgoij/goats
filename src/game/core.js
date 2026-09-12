// Part 1/11 of the goat scene: tuning, stats, palette and maths helpers. This
// file also carries the scene's overall header comment.
//
// A walking, running, jumping goat for the Slag x raylib sandbox.
//
// The scene is split across `src/game/*.js`, which the host concatenates into
// one script in the order listed in `src/main.rs` -- the pieces therefore share
// a single top-level scope, exactly as when this was one file. The parts, in
// that order:
//
//   core.js      tuning, stats, palette, maths helpers
//   model.js     the animated goat model and the cube-skeleton fallback
//   world.js     grass, the day/night curve, sky colours, sun/moon/stars
//   lighting.js  lit shader, directional light, planar + shadow-map shadows
//   sky.js       2.5D procedural cloud shader
//   audio.js     music streams, weather beds, goat bleats
//   weather.js   the weather state machine and wind
//   food.js      grass as food: eating, satiety, the reach check
//   bots.js      the autonomous bot herd
//   goat.js      the gait state machine, HUD and frame loop
//   ctl.js       the stdin command channel
//
// The goat is `goat_animated.glb`, baked from the Blender rig and loaded through
// the `rl` model surface. Every clip bakes its forward travel as *in-place*
// motion, so the script moves the goat at the speed the gait implies and
// advances the clip at the matching rate, which keeps the hooves from skating:
//
//   speed = stride / (duty * clipDuration)
//
// where `stride` is how far a planted hoof sweeps back per step and `duty` is
// the fraction of the cycle that foot spends on the ground. Jump height comes
// from the `GoatJump` clip's root motion, so the script only moves the goat
// horizontally while it is airborne.
//
// If the model cannot be loaded the sandbox falls back to a cube-skeleton goat:
// voxel-filled body boxes and 2-bone-IK limbs drawn with `rl.drawCube`.
//
// The world: an hour-of-day clock drives a gradient sky, a sun and moon arcing
// overhead, stars and a scene-wide colour grade; a lit shader gives the goat and
// terrain per-fragment sunlight and a cast shadow; and a weather state machine
// brings clouds, rain and wind that slow the goat and drain its energy faster.
//
// The goat has health and energy. Energy drains faster the harder it works; at
// zero the goat is exhausted -- capped at a walk and slowly losing health -- so
// it has to sleep to recover. At zero health it dies and needs a restart.
//
// Controls:
//   W / S         walk forward / backward
//   CTRL + W/S    trot
//   SHIFT + W/S   run
//   SPACE         jump
//   E             eat the grass in reach
//   Z             sleep / wake
//   R             restart after death
//   T (hold)      fast-forward the clock
//   C             next weather state
//   L             toggle lighting
//   K             cycle shadows (map / planar / off)
//   B             toggle the sky shader
//   M             mute audio
//   A / D         turn left / right
//   mouse drag    orbit the camera        mouse wheel    zoom
//   arrow keys    orbit the camera (keyboard fallback)
//   P             pause / resume
//   ESC           quit

// ---- tuning --------------------------------------------------------------

const MODEL_PATH = "goat_animated.glb";
const MODEL_SCALE = 1.0;
const GOAT_RADIUS = 0.45;  // body collision radius at scale 1, so goats block
const TURN_RATE = 1.8;     // rad/s
const FALLBACK_TROT_MULT = 1.3;  // how much faster the cube goat "trots"
const FALLBACK_RUN_MULT = 1.6;   // how much faster the cube goat "runs"
const FALLBACK_JUMP_TIME = 0.6;  // seconds of the cube goat's hop
const FALLBACK_JUMP_H = 0.55;    // metres of the cube goat's hop

// ---- stats ---------------------------------------------------------------

const MAX_STAT = 100;
const ENERGY_DRAIN = { idle: 0.4, walk: 1.0, trot: 2.0, run: 4.0 };  // per second
const JUMP_ENERGY_COST = 2.0;
const SLEEP_ENERGY_RECOVER = 12;   // per second
const SLEEP_HEALTH_RECOVER = 2;
const IDLE_HEALTH_RECOVER = 0.1;
const EXHAUST_HEALTH_DRAIN = 3;
const RESTED_ENERGY = 20;          // health only regenerates above this
const AUTO_SLEEP_DELAY = 2.0;      // seconds idle while exhausted
const DEAD_EYE_FRACTION = 0.75;    // show the X eyes once the death clip is this far in

// Cube-fallback gait only (ignored when the model loads).
const V_STRIDE = 0.20;
const V_LIFT = 0.10;
const V_GROUND = 0.02;
const V_DROP = -0.08;
const V_BOB = 0.018;
const V_L1 = 0.26;
const V_L2 = 0.28;
const V_HIP_Y = 0.56;
const V_CYCLE = 0.70;

// The four legs of the cube fallback's 4-beat lateral walk (back-left leads).
const LEGS = [
    { hx: -0.34, hz: 0.18, phase: 0.00 },  // back left
    { hx: 0.34, hz: 0.18, phase: 0.25 },   // front left
    { hx: -0.34, hz: -0.18, phase: 0.50 }, // back right
    { hx: 0.34, hz: -0.18, phase: 0.75 },  // front right
];

// ---- palette (the cube fallback; the model brings its own textures) ------

const FUR = rl.color(206, 186, 156);
const FUR_DK = rl.color(150, 128, 100);
const DARK = rl.color(64, 50, 42);
const HORN = rl.color(84, 70, 56);
const HOOF = rl.color(46, 38, 34);
const EYE = rl.color(26, 22, 20);
const SKY = rl.color(150, 198, 235);
const GROUND = rl.color(104, 156, 88);
const TUFT = rl.color(78, 128, 66);

// ---- small maths helpers -------------------------------------------------

function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

function mod1(v) {
    return ((v % 1) + 1) % 1;
}

function hash(n) {
    const s = Math.sin(n * 127.1) * 43758.5453;
    return s - Math.floor(s);
}

// Two-character hex for every byte, so the texture builders avoid per-pixel
// string formatting.
const HEX256 = (function buildHex256() {
    const d = ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"];
    const out = [];
    for (let i = 0; i < 256; i++) out.push(d[Math.floor(i / 16)] + d[i % 16]);
    return out;
})();

// Local -> world: yaw about Y, then translate. The goat faces local +X, and
// `rl.drawModelEx` rotates the model by the same convention (a Y-axis rotation
// maps local +X to (cos, -sin) in the XZ plane).
function toWorld(p, g) {
    const c = Math.cos(g.yaw);
    const s = Math.sin(g.yaw);
    return { x: g.px + p.x * c + p.z * s, y: g.py + p.y, z: g.pz - p.x * s + p.z * c };
}

// A point `len` along a bone that starts at `from`, rotated `ang` in the local
// X-Y plane (measured from straight down towards +X, like the Blender rig).
function segEnd(from, ang, len) {
    return { x: from.x + Math.sin(ang) * len, y: from.y - Math.cos(ang) * len, z: from.z };
}

