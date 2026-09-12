// Part 8/11 of the goat scene: grass as food.
// ---- food ------------------------------------------------------------------
//
// The "grass thingys" are the procedural tufts weather.js draws. A tuft's
// existence and position come from a hash of its 2-unit cell, so the nearest one
// is recomputed from the same maths rather than stored. Eating records the cell
// in `EATEN`, which the draw skips, so the meadow visibly thins as the goat
// grazes (and does not regrow within a session).
//
// A meal tops up energy and fills the belly (`satiety`); a full belly eases the
// rain slowdown (see `rainSlowFactor` in weather.js), and satiety decays, so the
// goat has to keep grazing to keep the benefit.

const EAT_RANGE = 1.1;          // metres: a tuft closer than this is in reach
                                // (the posed muzzle reaches ~0.8 m ahead, so a
                                // tuft further out would be eaten from thin air)
const EAT_ENERGY = 8;           // energy per tuft
const EAT_SATIETY = 0.55;       // belly fill per tuft, 0..1
const SATIETY_DECAY = 0.02;     // per second
const RAIN_SHELTER = 0.6;       // a full belly removes this share of the rain slowdown
const EAT_FALLBACK_TIME = 2.4;  // cube-fallback meal length
const REGROW_MIN = 40;          // seconds before an eaten tuft comes back
const REGROW_MAX = 90;          // ...at most, so the meadow recovers patchily

// Eaten cells map to the seconds left before they return. A private PRNG keeps
// the regrow jitter off the weather's and the bots' streams (the harness asserts
// exact weather values).
const EATEN = new Map();
let foodRngState = 0x1f2e3d4c;
let satiety = 0;                // 0..1
let eatenCount = 0;

// A cell's identity as one number, unique for the cell range the field spans.
function tuftKey(cx, cz) {
    return (cx + 4096) * 8192 + (cz + 4096);
}

// The nearest tuft within `range` of (x, z), as { x, z, cx, cz, d2 }, or null.
// The cell hash is inlined (rather than calling a helper, as `drawTufts` does
// too) to keep the per-frame call depth shallow -- debug builds guard the native
// stack hard and the bots call this every action.
function nearestTuft(x, z, range) {
    const r = Math.ceil(range / 2);
    const cx = Math.floor(x / 2);
    const cz = Math.floor(z / 2);
    let best = null;
    let bestD2 = range * range;
    for (let i = cx - r; i <= cx + r; i++) {
        for (let j = cz - r; j <= cz + r; j++) {
            let h = (i * 374761393 + j * 668265263) | 0;
            h = Math.imul(h ^ (h >>> 13), 1274126177);
            h = (h ^ (h >>> 16)) >>> 0;
            const a = h / 4294967296;
            if (a < 0.45) continue;
            if (EATEN.has((i + 4096) * 8192 + (j + 4096))) continue;
            let h2 = (i * 1103515245 + j * 12345) | 0;
            h2 = Math.imul(h2 ^ (h2 >>> 15), 2246822519);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
            const tx = i * 2 + (h2 / 4294967296 - 0.5) * 1.8;
            const tz = j * 2 + (a - 0.5) * 1.8;
            const dx = tx - x;
            const dz = tz - z;
            const d2 = dx * dx + dz * dz;
            if (d2 <= bestD2) {
                bestD2 = d2;
                best = { x: tx, z: tz, cx: i, cz: j, d2: d2 };
            }
        }
    }
    return best;
}

// Mark a tuft eaten so it disappears and schedules its regrowth. Shared by the
// player and the bots; returns false when there was nothing to eat. The regrow
// PRNG is inlined so this stays a leaf call (see `nearestTuft`).
function consumeTuft(target) {
    if (target === null || target === undefined) return false;
    foodRngState ^= foodRngState << 13;
    foodRngState >>>= 0;
    foodRngState ^= foodRngState >>> 17;
    foodRngState ^= foodRngState << 5;
    foodRngState >>>= 0;
    EATEN.set(tuftKey(target.cx, target.cz),
        REGROW_MIN + (foodRngState / 4294967296) * (REGROW_MAX - REGROW_MIN));
    eatenCount += 1;
    return true;
}

// Eat `target`: remove the tuft, turn onto it, top up energy, fill the belly,
// and switch to the eat clip. Returns false when there is nothing to eat.
function startEat(target) {
    if (!consumeTuft(target)) return false;
    // Face the tuft, so the head comes down where the grass actually was.
    goat.yaw = Math.atan2(-(target.z - goat.pz), target.x - goat.px);
    stats.energy = Math.min(MAX_STAT, stats.energy + EAT_ENERGY);
    satiety = Math.min(1, satiety + EAT_SATIETY);
    mode = "eat";
    eatTime = 0;
    cyclePlayerVariant("eat");
    return true;
}

// Once per frame: let the belly empty out and let eaten tufts grow back.
function updateFood(dt) {
    satiety = Math.max(0, satiety - SATIETY_DECAY * dt);
    if (EATEN.size === 0) return;
    for (const key of EATEN.keys()) {
        const left = EATEN.get(key) - dt;
        if (left <= 0) EATEN.delete(key);
        else EATEN.set(key, left);
    }
}
