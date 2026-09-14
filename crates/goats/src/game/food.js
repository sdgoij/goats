// Part 8/15 of the goat scene: grass as food.
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

// The meal's reach, energy, belly fill and regrowth windows live in
// `TUNING.food` (core.js); `rainSlowFactor` in weather.js reads the same tree.
const EAT_FALLBACK_TIME = 2.4;  // cube-fallback meal length

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

// Draw a regrow time for `key` and record it. Shared by a local bite and one
// reported by a client, so both assign the same kind of duration.
function assignRegrow(key) {
    foodRngState ^= foodRngState << 13;
    foodRngState >>>= 0;
    foodRngState ^= foodRngState >>> 17;
    foodRngState ^= foodRngState << 5;
    foodRngState >>>= 0;
    EATEN.set(key, TUNING.food.regrowMin +
        (foodRngState / 4294967296) * (TUNING.food.regrowMax - TUNING.food.regrowMin));
    eatenCount += 1;
}

// Mark a tuft eaten so it disappears and schedules its regrowth. Shared by the
// player and the bots; returns false when there was nothing to eat.
function consumeTuft(target) {
    if (target === null || target === undefined) return false;
    assignRegrow(tuftKey(target.cx, target.cz));
    return true;
}

// Record a cell a client reported eating. The host owns the meadow, so this is
// where a client's bite becomes real; a cell already gone is ignored.
function sceneConsume(key) {
    if (EATEN.has(key)) return;
    assignRegrow(key);
}

// The meadow as the wire sees it: the eaten cells and their remaining seconds.
function sceneEaten() {
    const out = [];
    for (const entry of EATEN) {
        out.push({ key: entry[0], left: netRound3(entry[1]) });
    }
    return out;
}

// Replace the meadow with the server's, wholesale. Joining adopts the server's
// world rather than merging it with the one this client had already generated.
//
// A snapshot that could not carry the meadow -- the world was over its datagram
// budget, so the meadow was the part that went -- sends `null` instead, and that
// means "keep the one you have". Clearing it would put back every tuft the host
// has eaten, and a client that believes a tuft is there cannot eat it.
function applyEaten(list) {
    if (!Array.isArray(list)) return;
    EATEN.clear();
    for (let i = 0; i < list.length; i++) {
        EATEN.set(list[i].key, list[i].left);
    }
}

// Eat `target`: remove the tuft, turn onto it, top up energy, fill the belly,
// and switch to the eat clip. Returns false when there is nothing to eat.
function startEat(target) {
    if (!consumeTuft(target)) return false;
    // Face the tuft, so the head comes down where the grass actually was.
    goat.yaw = Math.atan2(-(target.z - goat.pz), target.x - goat.px);
    stats.energy = Math.min(TUNING.stats.max, stats.energy + TUNING.food.eatEnergy);
    satiety = Math.min(1, satiety + TUNING.food.eatSatiety);
    mode = "eat";
    eatTime = 0;
    cyclePlayerVariant("eat");
    // In a session the meadow is the server's, so tell it about the bite; it
    // comes back in the next world snapshot, which replaces this optimistic one.
    if (!netWorldLocal()) netQueue({ type: "consume", key: tuftKey(target.cx, target.cz) });
    return true;
}

// Once per frame: let the belly empty out and let eaten tufts grow back.
function updateFood(dt) {
    satiety = Math.max(0, satiety - TUNING.food.satietyDecay * dt);
    // The meadow is the server's in a session: a client mirrors `EATEN` from the
    // snapshots instead of counting it down, so the two cannot disagree about
    // when a tuft returns.
    if (!netWorldLocal()) return;
    if (EATEN.size === 0) return;
    for (const key of EATEN.keys()) {
        const left = EATEN.get(key) - dt;
        if (left <= 0) EATEN.delete(key);
        else EATEN.set(key, left);
    }
}
