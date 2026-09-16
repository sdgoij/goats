// Part 1/16 of the goat scene: tuning, stats, palette and maths helpers. This
// file also carries the scene's overall header comment.
//
// A walking, running, jumping goat for the Slag x raylib sandbox.
//
// The scene is split across `crates/goats/src/game/*.js`, which the host
// concatenates into one script in the order listed in
// `crates/goats/src/main.rs` -- the pieces therefore share a single top-level
// scope, exactly as when this was one file. The parts, in
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
//   menu.js      the main menu, settings and keymap (raygui)
//   console.js   the in-game console overlay (M9)
//   net.js       the network bridge to the Rust host (M10)
//   mods.js      the mod table and the `goats` API (M14b)
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
//   F11           toggle fullscreen
//   A / D         turn left / right
//   mouse drag    orbit the camera        mouse wheel    zoom
//   arrow keys    orbit the camera (keyboard fallback)
//   P             pause / resume
//   ESC           main menu / resume

// ---- tuning --------------------------------------------------------------
//
// Every gameplay value the sandbox reads lives in one mutable tree so mods can
// retune it without patching code (see `APIv1.md`). The scene reads the tree
// directly; `tuningSet`/`tuningMerge` are the validated write path, and
// `tuningWatch` is how a system reacts to a change. The defaults here are
// exactly the constants they replaced, so a mod-free run is unchanged.

// The logical asset slots the scene loads through `rl.*`. The defaults are the
// embedded names the host registers with `register_raylib_asset`; a mod that
// declares an asset for a slot re-points it at the host's opaque name, so the
// loaders read the slot and never a path. Data-only packs use this to replace a
// built-in model or sound without any code.
//
// A mod's own slots land here too (`sceneMods` writes every slot its manifest
// declares, new names included), which is how a mod names its own model without
// the host embedding it.
const ASSET_SLOTS = {
    "model.goat": "goat_animated.glb",
    "sfx.music": "sfx/jkstudios-rage-2-187959.mp3",
    "sfx.rain": "sfx/WE Heavy Outside Rain 1.ogg",
    "sfx.wind": "sfx/WE Light Wind Whistle 1.ogg",
    "sfx.bleat": [
        "sfx/dragon-studio-goat-baa-390303.mp3",
        "sfx/dragon-studio-goat-kid-bleating-390290.mp3",
        "sfx/dragon-studio-goat-sound-390298.mp3",
        "sfx/dragon-studio-goat-sound-effect-390305.mp3",
        "sfx/mightuser-1-goat-sound-effect-259473.mp3",
        "sfx/freesound_community-happy-goat-6463.mp3",
    ],
    "sfx.thunder": [
        "sfx/WE Thunder 1.ogg",
        "sfx/WE Thunder 26.ogg",
        "sfx/WE Thunder 29.ogg",
    ],
};

// A slot value as a list: a mod may point a list slot at a single file.
function assetList(slot) {
    const value = ASSET_SLOTS[slot];
    if (value === undefined) return [];
    return Array.isArray(value) ? value : [value];
}

const TUNING = {
    stats: {
        max: 100,
        energyDrain: { idle: 0.4, walk: 1.0, trot: 2.0, run: 4.0 },  // per second
        jumpEnergyCost: 2.0,
        sleepEnergyRecover: 12,    // per second
        sleepHealthRecover: 2,
        idleHealthRecover: 0.1,
        exhaustHealthDrain: 3,
        restedEnergy: 20,          // health only regenerates above this
        autoSleepDelay: 2.0,       // seconds idle while exhausted
        deadEyeFraction: 0.75,     // show the X eyes once the death clip is this far in
    },
    movement: {
        turnRate: 1.8,             // rad/s
        goatRadius: 0.45,          // body collision radius at scale 1, so goats block
        modelScale: 1.0,
    },
    gait: {
        walk: { stride: 0.40, duty: 0.50 },
        trot: { stride: 0.46, duty: 0.50 },
        run: { stride: 0.50, duty: 0.34 },
    },
    jump: {
        fallbackTime: 0.6,         // seconds of the cube goat's hop
        fallbackHeight: 0.55,      // metres of the cube goat's hop
        fallbackTrotMult: 1.3,     // how much faster the cube goat "trots"
        fallbackRunMult: 1.6,      // how much faster the cube goat "runs"
    },
    food: {
        eatRange: 1.1,             // metres: a tuft closer than this is in reach
        eatEnergy: 8,              // energy per tuft
        eatSatiety: 0.55,          // belly fill per tuft, 0..1
        satietyDecay: 0.02,        // per second
        rainShelter: 0.6,          // a full belly removes this share of the rain slowdown
        regrowMin: 40,             // seconds before an eaten tuft comes back
        regrowMax: 90,             // ...at most, so the meadow recovers patchily
    },
    explosions: {
        enabled: 1,                // 0 disables the whole system (a frame-cost bisect)
        safe: 8,                   // metres around the spawn with no devices
        fuse: 0.18,                // seconds between the trigger and the bang
        maxActive: 24,             // effect instances; each is a draw call
        mine: {
            density: 0.012,        // chance per 2-unit cell, so one per ~330 m²
            trigger: 0.6,          // metres a goat has to come within
            clearance: 0.45,       // metres above the ground that counts as "over it"
            tell: 3.0,             // metres at which the patch becomes visible; 0 = never
            rearm: 300,            // seconds before the cell is mined again
        },
        trap: {
            chance: 0.04,          // share of the tufts that are trapped
            rearm: 300,
        },
        blast: {
            radius: 3.2,           // metres
            damage: 45,            // at the centre, falling to 0 at the rim
            healthFloor: 1,        // a blast cannot take health below this
        },
        chain: 0.15,               // seconds before a blast sets off a neighbour
        chainDepth: 1,             // how far a cascade goes; 1 = neighbours only
    },
    weather: {
        windBase: 1.6,             // m/s
        cloudDrift: 0.35,          // clouds move slower than the ground wind
        rainMax: 160,              // streaks; each is a drawLine, so this is a cost knob
        rainSlow: 0.28,            // at full rain the goat moves up to 28% slower
        windSlow: 0.07,            // a full gust slows it a little more
        wetDrain: 0.65,            // up to +65% energy drain in heavy rain
        windDrain: 0.20,
        windNorm: 1.4,             // windSway value that counts as "a full gust"
        hold: { clear: [22, 45], cloudy: [16, 34], rain: [20, 40], clearing: [8, 16] },
    },
    terrain: {
        relief: 2.1,               // peak displacement, in metres
        flat: 6,                   // spawn-bowl radius that stays level, in units
        ramp: 16,                  // units over which the bowl reaches full relief
        snap: 24,                  // rebuild when the goat has moved this far
        uv: 0.06,                  // texture tiles per world unit
    },
    world: {
        dayLength: 240,            // real seconds for one 24 h day
        timeFast: 40,              // hold T to advance time this many times faster
        nightDrainMult: 1.6,       // energy drains faster in the cold
    },
    herd: {
        count: 7,                  // bot goats, 0..10
        spec: [
            { coat: [196, 168, 128], scale: 0.80, bold: 0.95, lazy: 0.55, name: "tan kid" },
            { coat: [222, 216, 206], scale: 1.06, bold: 1.00, lazy: 0.50, name: "cream" },
            { coat: [116, 92, 70], scale: 1.22, bold: 0.70, lazy: 0.72, name: "big brown" },
            { coat: [156, 126, 92], scale: 0.94, bold: 1.18, lazy: 0.32, name: "lively" },
            { coat: [88, 90, 98], scale: 1.12, bold: 0.85, lazy: 0.62, name: "charcoal" },
            { coat: [208, 180, 142], scale: 0.74, bold: 1.05, lazy: 0.45, name: "small beige" },
        ],
    },
    camera: {
        yaw: 0.7,
        pitch: 0.42,
        dist: 5.2,
        minDist: 2.2,
        maxDist: 12.0,
    },
    sky: {
        cloudBase: 5.0,            // world height of the layer bottom
        cloudTop: 9.5,             // world height of the layer top
        scale: 0.055,              // base shape frequency
        detail: 0.35,              // high-frequency edge erosion
        absorb: 1.35,              // extinction per unit density
        cirrusLevel: 15.0,         // world height of the thin high layer
        speed: 0.55,               // how fast the layer drifts with the wind
        steps: [6, 12, 22],        // march steps per quality level
    },
    lighting: {
        shadow: {
            size: 1024,
            half: 7.0,             // half-width of the light's box, in world units
            dist: 22.0,            // how far the light sits from its centre
            near: 1.0,
            far: 48.0,
            bias: 0.0018,
            strength: 0.85,        // how dark a fully-shadowed sample gets
        },
    },
};

// A write is validated against the value it replaces: numbers stay finite,
// arrays stay arrays, and a branch is not a leaf. Bounds are only listed where
// the game needs one.
const TUNING_CLAMP = {
    "herd.count": [0, 10],
    "camera.minDist": [0.1, 1000],
    "camera.maxDist": [0.1, 1000],
    "lighting.shadow.size": [16, 8192],
    // Explosions: the clamps a mistake could make unplayable. Density sets how
    // much of the field is a minefield, the radius and the damage decide whether
    // one bang ends a run, the floor is the promise that it cannot, and the depth
    // bounds a cascade.
    "explosions.mine.density": [0, 0.1],
    "explosions.blast.radius": [0, 12],
    "explosions.blast.damage": [0, 100],
    "explosions.blast.healthFloor": [0, 100],
    "explosions.maxActive": [0, 64],
    "explosions.chainDepth": [0, 2],
};

// Leaves that must stay whole numbers (counts and pixel sizes). Integer-ness is
// explicit rather than inferred: a default of `2.0` is just a number, and a mod
// may legitimately want `2.5` for a duration or cost.
const TUNING_INT = {
    "herd.count": true,
    "lighting.shadow.size": true,
};

function tuningHas(node, key) {
    return Object.prototype.hasOwnProperty.call(node, key);
}

function tuningKindOf(value) {
    if (typeof value === "number") return "number";
    if (Array.isArray(value)) return "array";
    return "other";
}

// The value at a dotted path. An unknown path is an error rather than
// `undefined`, so a typo is loud.
function tuningGet(path) {
    const parts = String(path).split(".");
    let node = TUNING;
    for (let i = 0; i < parts.length; i++) {
        if (node === null || typeof node !== "object" || !tuningHas(node, parts[i])) {
            throw new Error("tuning: unknown path '" + path + "'");
        }
        node = node[parts[i]];
    }
    return node;
}

// Validate and coerce `value` against the leaf's current value.
function tuningCoerce(path, current, value) {
    const kind = tuningKindOf(current);
    if (kind === "number") {
        const n = Number(value);
        if (!isFinite(n)) throw new Error("tuning: '" + path + "' expects a finite number");
        let out = tuningHas(TUNING_INT, path) ? Math.round(n) : n;
        const bounds = TUNING_CLAMP[path];
        if (bounds !== undefined) out = clamp(out, bounds[0], bounds[1]);
        return out;
    }
    if (kind === "array") {
        if (!Array.isArray(value)) throw new Error("tuning: '" + path + "' expects an array");
        if (path === "herd.spec" && value.length === 0) {
            throw new Error("tuning: 'herd.spec' must not be empty");
        }
        if (path === "sky.steps" && value.length !== current.length) {
            throw new Error("tuning: 'sky.steps' expects " + current.length + " entries");
        }
        return value;
    }
    throw new Error("tuning: '" + path + "' is not a leaf");
}

// Set one leaf and notify watchers. Returns the stored (coerced) value.
function tuningSet(path, value) {
    const parts = String(path).split(".");
    const leaf = parts.pop();
    let parent = TUNING;
    for (let i = 0; i < parts.length; i++) {
        if (parent === null || typeof parent !== "object" || !tuningHas(parent, parts[i])) {
            throw new Error("tuning: unknown path '" + path + "'");
        }
        parent = parent[parts[i]];
    }
    if (parent === null || typeof parent !== "object" || !tuningHas(parent, leaf)) {
        throw new Error("tuning: unknown path '" + path + "'");
    }
    const next = tuningCoerce(path, parent[leaf], value);
    parent[leaf] = next;
    tuningNotify(path, next);
    return next;
}

// Merge a nested object leaf by leaf, so every write is validated. Used by a
// mod's `tuning.json` and by `goats.tuning.merge`.
function tuningMerge(object, prefix) {
    const base = prefix === undefined ? "" : prefix;
    const keys = Object.keys(object);
    for (let i = 0; i < keys.length; i++) {
        const path = base === "" ? keys[i] : base + "." + keys[i];
        const value = object[keys[i]];
        if (value !== null && typeof value === "object" && !Array.isArray(value)) {
            tuningMerge(value, path);
        } else {
            tuningSet(path, value);
        }
    }
}

// Watch a path (or a branch, by prefix). Returns an unsubscribe function. A
// watcher that throws is reported and skipped, never aborting the write.
const tuningWatchers = [];
function tuningWatch(prefix, fn) {
    const entry = { prefix: String(prefix === undefined ? "" : prefix), fn: fn };
    tuningWatchers.push(entry);
    return function () {
        const at = tuningWatchers.indexOf(entry);
        if (at >= 0) tuningWatchers.splice(at, 1);
    };
}

function tuningNotify(path, value) {
    for (let i = 0; i < tuningWatchers.length; i++) {
        const watcher = tuningWatchers[i];
        const hit = watcher.prefix === "" || path === watcher.prefix ||
            path.indexOf(watcher.prefix + ".") === 0;
        if (!hit) continue;
        try {
            watcher.fn(path, value);
        } catch (error) {
            console.log("tuning: watcher on '" + watcher.prefix + "' threw: " + String(error));
        }
    }
    // Mods observe tuning changes through the same notification (mods.js).
    modEmit("tuning", path, value);
}

// ---- settings (see menu.js) ----------------------------------------------
//
// Live values the main menu edits. Kept here, in the first part, so every later
// part can read them; `applySettings` in menu.js pushes them into the systems
// that own the behaviour. `shadow` holds a SHADOW_* index from lighting.js (the
// numeric literals avoid a cross-part initialiser dependency). The herd size is
// not here: it is `TUNING.herd.count`, which menu.js and ctl.js write through
// `tuningSet`, so a mod retunes it the same way.

const SETTINGS = {
    bgm: 90,        // background music volume, 0..100
    sfx: 90,        // sound-effect volume, 0..100
    light: true,    // lit shader on/off
    shadow: 2,      // 0 none, 1 planar, 2 shadow map
    sky: true,      // sky shader on/off
    cloud: 1,       // volumetric cloud quality: 0 low, 1 medium, 2 high
    fullscreen: true,  // start (and toggle) full-screen
};

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
// maps local +X to (cos, -sin) in the XZ plane). `y` is measured from the
// ground under the goat (`goatBaseY`), so the cube fallback climbs the terrain.
function toWorld(p, g) {
    const c = Math.cos(g.yaw);
    const s = Math.sin(g.yaw);
    return { x: g.px + p.x * c + p.z * s, y: goatBaseY(g) + p.y, z: g.pz - p.x * s + p.z * c };
}

// A point `len` along a bone that starts at `from`, rotated `ang` in the local
// X-Y plane (measured from straight down towards +X, like the Blender rig).
function segEnd(from, ang, len) {
    return { x: from.x + Math.sin(ang) * len, y: from.y - Math.cos(ang) * len, z: from.z };
}

