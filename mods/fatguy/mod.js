// The `fatguy` mod: a fat guy with a small guitar who runs for his life.
//
// Everything he needs is in this directory, the model included. `mod.json`
// declares one asset under a slot of the mod's own --
//
//   "assets": { "model.fatguy": "assets/fat_guy.glb" }
//
// -- and the host reads the file, registers the bytes with the engine under an
// opaque name, and hands that name back through `goats.assets.get`. A slot does
// not have to be one of the built-ins the scene already uses: a mod may name its
// own, which is how this model travels with the mod instead of being embedded in
// the game's binary. Read it with `.get()` before handing it to `rl.loadModel`,
// because a slot that is neither declared nor built in resolves to `undefined`
// rather than failing.
//
// The rest is the mod: the model load, the threat logic, the pace, the drawing.
// The Blender source, the builder script and the render live beside the asset.
//
// The model is one mesh with one primitive per material, and there is no
// armature -- so the run *is* the motion: heading, pace and a stride bob, with the
// panic carried by speed, the bob's amplitude and a frantic wobble.
//
// **What he does.** Every goat is a threat -- the player and every bot
// (`goats.bots.list()`) -- and the nearest sets his pace: inside `PANIC_RANGE` he
// sprints away from it, beyond `CALM_RANGE` he drops to a jog. Two radii, not one,
// so a goat at the edge of the range cannot flip him between running and strolling
// every frame. He turns at `TURN_RATE` rather than snapping, steers himself back
// inside `FIELD_RADIUS` so he cannot be chased out of the meadow, and keeps his
// feet on `terrainHeight`. Once he is clear he ambles back toward the middle and
// circles lazily there -- without that, a *distant* goat would pin him to the rim
// for ever, because every goat counts as a threat.
//
// He is not solid: contact is read, and then he is the one who moves. A goat
// genuinely blocked by him would have to be resolved by the scene's collision, or
// by teleporting the player every frame, which fights the player's own movement.
// He is also drawn unlit, because a mod has no handle on the scene's lit shader or
// its ambient tint (APIv1 exposes neither).

const SLOT = "model.fatguy";
const SCALE = 0.75;         // 2.60 units tall in the GLB

const JOG_SPEED = 2.0;      // m/s, his pace with nobody near
const PANIC_SPEED = 7.0;    // m/s, faster than a goat's run, so he gets away
const PANIC_RANGE = 7.0;    // metres: inside this, a goat panics him
const CALM_RANGE = 13.0;    // metres: past this he settles back to the jog
const TURN_RATE = 3.0;      // rad/s, so he leans into a turn instead of pivoting
const ACCEL = 6.0;          // m/s², how fast the pace changes
const FIELD_RADIUS = 26.0;  // metres from the spawn; he will not be chased out
const CALM_RADIUS = 8.0;    // metres: inside this he ambles instead of heading in
const STEER_ZONE = 4.0;     // metres of rim where he turns back inward
const STRIDE = 1.2;         // metres per footfall
const BOB_BASE = 0.04;      // metres of bob at a standstill
const BOB_PER_SPEED = 0.015;// ...plus this much per m/s
const WOBBLE = 7.0;         // degrees of frantic yaw at full panic

const BUMP_DIST = 1.4;      // metres at which contact starts
const BUMP_OFFSET = 2.6;    // metres he is shoved at full overlap
const BUMP_FADE = 1.1;      // seconds for the shove to bleed off
const KNOCK_FADE = 0.45;    // seconds for the hop and the stagger to settle
const STAGGER = 25;         // degrees of yaw at the peak of a knock
const HOP = 0.30;           // metres he pops up at the peak of a knock

let model = -1;
let x = -9;                 // metres from the spawn, where he starts his day
let z = 0;
let heading = -Math.PI / 2; // radians; the model faces local +Z, so this is -X
let speed = 0;              // m/s
let stride = 0;             // footfalls, since he started
let panic = 0;              // 0..1, latched by the two radii
let knockX = 0;             // metres off his line: the shove, and how hard it was
let knockZ = 0;
let knock = 0;              // 0..1, drives the hop and the stagger
let held = false;           // still in contact, so the shove is not fading
let warned = false;

function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

function ensureModel() {
    if (model >= 0) return;
    const name = goats.assets.get(SLOT);
    if (name === undefined || name === null) {
        if (!warned) {
            warned = true;
            goats.log("fatguy: nothing declared in slot " + SLOT);
        }
        return;
    }
    model = rl.loadModel(name);
    if (model < 0) goats.log("fatguy: could not load " + name);
}

// The nearest goat: the player first, then the herd. The offset *to* it, so the
// escape direction is the negation.
function nearestGoat() {
    const p = goats.player.state();
    let bx = p.x - x;
    let bz = p.z - z;
    let best = bx * bx + bz * bz;
    const bots = goats.bots.list();
    for (let i = 0; i < bots.length; i++) {
        const dx = bots[i].x - x;
        const dz = bots[i].z - z;
        const d2 = dx * dx + dz * dz;
        if (d2 < best) {
            best = d2;
            bx = dx;
            bz = dz;
        }
    }
    return { dx: bx, dz: bz, d2: best };
}

// Contact with the player's goat: a bounded shove rather than an accumulating one,
// and two radii so a goat standing on him holds the shove instead of buzzing it.
function bump(goatX, goatZ) {
    const dx = goatX - x;
    const dz = goatZ - z;
    const d2 = dx * dx + dz * dz;
    const release = BUMP_DIST + BUMP_OFFSET * 0.75;
    if (d2 > release * release) {
        held = false;
        return;
    }
    const d = Math.sqrt(d2);
    const overlap = clamp((BUMP_DIST - d) / BUMP_DIST + 0.35, 0.2, 1);
    // Coincident is the *deepest* contact, so it must not be a no-op: with no
    // direction from the pair, the shove goes the way he is already running.
    const nx = d2 > 1e-6 ? dx / d : Math.sin(heading);
    const nz = d2 > 1e-6 ? dz / d : Math.cos(heading);
    knockX = nx * BUMP_OFFSET * overlap;
    knockZ = nz * BUMP_OFFSET * overlap;
    knock = Math.min(1, knock + overlap * 0.5);
    held = true;
}

goats.on("update", function (dt) {
    ensureModel();
    const near = nearestGoat();

    if (panic > 0) {
        if (near.d2 > CALM_RANGE * CALM_RANGE) panic = 0;
    } else if (near.d2 < PANIC_RANGE * PANIC_RANGE) {
        panic = 1;
    }

    // Away from the nearest goat while frightened; back toward the middle once he
    // is clear, then a lazy circle there.
    const r = Math.sqrt(x * x + z * z);
    let dirX;
    let dirZ;
    if (panic > 0) {
        dirX = -near.dx;
        dirZ = -near.dz;
    } else if (r > CALM_RADIUS) {
        dirX = -x;
        dirZ = -z;
    } else {
        dirX = Math.sin(heading + 0.4);
        dirZ = Math.cos(heading + 0.4);
    }
    // Blended back inward near the rim, so a long chase ends in him circling the
    // meadow instead of leaving it.
    if (r > FIELD_RADIUS - STEER_ZONE) {
        const t = clamp((r - (FIELD_RADIUS - STEER_ZONE)) / STEER_ZONE, 0, 1);
        dirX = dirX * (1 - t) - (x / r) * t * 1.5;
        dirZ = dirZ * (1 - t) - (z / r) * t * 1.5;
    }
    const dirLen = Math.sqrt(dirX * dirX + dirZ * dirZ);
    if (dirLen > 1e-6) {
        const want = Math.atan2(dirX / dirLen, dirZ / dirLen);
        let turn = want - heading;
        while (turn > Math.PI) turn -= Math.PI * 2;
        while (turn < -Math.PI) turn += Math.PI * 2;
        heading += clamp(turn, -TURN_RATE * dt, TURN_RATE * dt);
    }

    const wantSpeed = panic > 0 ? PANIC_SPEED : JOG_SPEED;
    speed += clamp(wantSpeed - speed, -ACCEL * dt, ACCEL * dt);
    x += Math.sin(heading) * speed * dt;
    z += Math.cos(heading) * speed * dt;
    stride += (speed * dt) / STRIDE;

    const player = goats.player.state();
    bump(player.x, player.z);
    if (!held) {
        const fade = Math.exp(-dt / BUMP_FADE);
        knockX *= fade;
        knockZ *= fade;
    }
    knock *= Math.exp(-dt / KNOCK_FADE);
    if (knock < 1e-3) knock = 0;
});

goats.on("draw3d", function () {
    if (model < 0) return;
    const dx = x + knockX;
    const dz = z + knockZ;
    // He faces local +Z, so a Y rotation of the heading points him along it: the
    // wobble is the panic, the stagger is the bump, and the hop is it landing.
    const yaw = (heading * 180) / Math.PI
        + Math.sin(stride * Math.PI * 2) * WOBBLE * panic
        + knock * STAGGER;
    const bob = Math.abs(Math.sin(stride * Math.PI)) * (BOB_BASE + speed * BOB_PER_SPEED);
    const hop = Math.sin(knock * Math.PI) * HOP;
    rl.drawModelEx(model, dx, goats.world.terrainHeight(dx, dz) + bob + hop, dz,
        0, 1, 0, yaw, SCALE, SCALE, SCALE, rl.WHITE);
});
