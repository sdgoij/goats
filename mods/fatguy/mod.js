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
// **What touches him.** Goats *and birds*: the player, every bot, and every bird
// within reach of a shove. The birds are another mod, which is what `goats.entities`
// is for (APIv1.md §4.16): their flock offers its birds and this asks what is near
// him. A bird in the air does not count; one on the ground does, and so does one
// perched on a goat that then walks into him -- the incident that prompted the
// collision in the first place. A bird is a fraction of a goat, so it nudges him
// rather than knocking him off his feet.
//
// He is not solid: contact is read, and then he is the one who moves. A goat
// genuinely blocked by him would have to be resolved by the scene's collision, or
// by teleporting the player every frame, which fights the player's own movement.
// He is also drawn unlit, because a mod has no handle on the scene's lit shader or
// its ambient tint (APIv1 exposes neither).
//
// **What he trips.** Devices: the same surface the birds use (`goats.explosions`,
// §4.15). He asks the derived field whether he is standing on one -- the core's own
// trigger radius, from the core's own derivation, so a device a mod has switched
// off is not one here either -- and sets it off through the core's blast path, so
// the crater, the damage, the flash and the sound are the ones a goat gets. A bang
// within its `radius` of him throws him: `lift` up and `push` out, both scaled by
// the same falloff as the damage, so a mine he is standing on throws him the twelve
// metres and eight up that the tuning's own comment quotes.
//
// **And he is unlucky.** A thrown guy does not land where the throw takes him: with
// a device within `CHAIN_RANGE` the arc is *aimed* at it -- the same lift, and the
// horizontal speed that covers the distance in the time that lift implies -- so he
// lands on the next device and it goes off under him. The chance is a ladder, and it
// is the whole joke: the first bang of an episode always finds one, and after that
// it is 75%, 50%, 25% and then none, so the poor man escalates and then runs out of
// luck. `CHAIN_RESET` seconds on his feet restores the whole ladder, which is what
// makes the first bang of the next episode a certainty rather than a coin toss.
//
// **Sounds.** Two slots of the mod's own -- `sfx.fatguy.yell` as he goes up and
// `sfx.fatguy.land` when he comes down (the slots at the top of the audio block
// below). `mod.json` declares them with `assetAdds`, which is the door for a *list*
// slot: three screams in the yell slot and a thud in the landing one, so a variant is
// picked per play rather than the first file standing in for all of them. Neither has
// to be there: an undeclared slot resolves to `[]`, which is silence rather than an
// error, and a *declared* file that is missing is a load error -- the whole difference
// between shipping without a voice and pointing a slot at the wrong file.

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
const BIRD_BUMP = 0.45;     // how much of a goat's shove a bird's contact carries
const BIRD_AIRBORNE = 0.5;  // metres above the ground a bird is flying, not walking
const ENTITY_MARGIN = 1.0;  // metres past `BUMP_DIST` the bird query reaches, for the radius
                            // an offered entity carries (APIv1.md §4.16)

const GROUNDED = 0.5;       // metres above the ground he still counts as standing
const FLUNG_GRAVITY = -72;  // m/s², the goat's own arc, so his throw looks like one
const FLUNG_MAX = 4.0;      // seconds; a ceiling on the arc, as the birds keep one
const FLUNG_SPIN = 1.6;     // forward somersaults a second, over the arc
// The chain. `CHAIN_RANGE` is the field's own arithmetic: the devices are one per ~330
// m², so the nearest neighbour is typically nine metres away, and a range under that
// would make "another device nearby" a coin toss on the *layout* as well as on his
// luck. `CHAIN_REACH` is the joke's licence: an aimed throw may ask for up to twice the
// horizontal speed the bang's own push carries, which is what turns a nine-metre throw
// into a flat, fast, extremely unlucky one.
const CHAIN_RANGE = 12.0;   // metres: how far "nearby" looks for the next device
const CHAIN_CHANCE = [1, 0.75, 0.5, 0.25];  // the luck ladder, by blast number
const CHAIN_RESET = 2.0;    // seconds on his feet before the ladder starts over
const CHAIN_REACH = 2.0;    // how far past the bang's own push an aimed throw may ask

const YELL_VOLUME = 0.9;    // the two slots, and how loud they are at arm's length
const LAND_VOLUME = 0.7;
const VOICE_FADE = 12.0;    // metres at which a voice is half as loud

const YELL_SLOT = "sfx.fatguy.yell";
const LAND_SLOT = "sfx.fatguy.land";

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
// The thrown arc. `y` is height above the ground, `vx`/`vz` are the throw's own
// velocity rather than his heading's, and `tumble` is how far over he has gone.
let y = 0;
let vx = 0;
let vz = 0;
let vy = 0;
let flung = false;
let flungT = 0;
let tumble = 0;
// The chain: how many bangs have thrown him in this episode, how long he has been on
// his feet since the last one, and whether the throw he is in was aimed at a device.
let blasts = 0;
let resting = CHAIN_RESET;
let aimed = false;
let warned = false;
// His own luck, and his own voices. The scene's seeded streams belong to `side:
// "world"` mods (a client mod may not register one) and `Math.random` would make a
// run unreproducible for the harness, so the ladder rolls on a private xorshift32
// that starts from a constant.
let rngState = 0x1f2e3d4c;
let yells = [];             // the loaded variants of each slot, in the order declared
let lands = [];
let voiceRead = false;

function clamp(v, lo, hi) {
    return v < lo ? lo : v > hi ? hi : v;
}

// A number in [0, 1). xorshift32: three shifts and three xors, which is all the luck
// this needs, and it is reproducible from the constant above.
function rng() {
    let s = rngState;
    s ^= s << 13;
    s ^= s >>> 17;
    s ^= s << 5;
    rngState = s >>> 0;
    return (rngState >>> 8) / 16777216;
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

// The two voices, read once. `all` rather than `get`: a slot holds a list and this mod
// ships three screams and one landing, so every variant is loaded and one is picked per
// play (APIv1.md §4.11). An undeclared slot is an empty list, which is why this is also
// the whole of "ships without sound": there is nothing to fail on, and nothing to hear.
function loadVoices(slot) {
    const names = goats.assets.all(slot);
    const out = [];
    for (let i = 0; i < names.length; i++) {
        const sound = rl.loadSound(names[i]);
        if (sound >= 0) out.push(sound);
    }
    return out;
}

function ensureVoice() {
    if (voiceRead) return;
    voiceRead = true;
    if (typeof rl.loadSound !== "function") return;
    yells = loadVoices(YELL_SLOT);
    lands = loadVoices(LAND_SLOT);
}

// One voice out of a slot's variants, faded by how far the goat is -- the one listener
// this mod can place. The variant and the pitch both come from the *same* roll: one draw
// a yell, which keeps the luck ladder's own sequence exactly where it was, and a chain of
// three screams is not one file three times over.
function say(sounds, volume) {
    if (sounds.length === 0) return;
    const roll = rng();
    const sound = sounds[(roll * sounds.length) | 0];
    const p = goats.player.state();
    const dx = x - p.x;
    const dz = z - p.z;
    const att = 1 / (1 + Math.sqrt(dx * dx + dz * dz) / VOICE_FADE);
    rl.setSoundVolume(sound, goats.settings.get().sfx * volume * att);
    rl.setSoundPitch(sound, 0.92 + roll * 0.22);
    rl.playSound(sound);
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

// One contact: a bounded shove rather than an accumulating one, and two radii so a
// body standing on him holds the shove instead of buzzing it. `weight` is what the
// body is worth -- a goat 1, a bird `BIRD_BUMP` -- and `reach` is how close its own
// width lets it come. Null when it is out of reach at all, and a frame's contact is
// the deepest one, so being crowded by the herd shoves him no harder than the
// closest of them.
function bump(ox, oz, weight, reach) {
    const dx = ox - x;
    const dz = oz - z;
    const d2 = dx * dx + dz * dz;
    const release = reach + BUMP_OFFSET * 0.75;
    if (d2 > release * release) return null;
    const d = Math.sqrt(d2);
    const overlap = clamp((reach - d) / reach + 0.35, 0.2, 1) * weight;
    // Coincident is the *deepest* contact, so it must not be a no-op: with no
    // direction from the pair, the shove goes the way he is already running.
    const nx = d2 > 1e-6 ? dx / d : Math.sin(heading);
    const nz = d2 > 1e-6 ? dz / d : Math.cos(heading);
    return {
        x: nx * BUMP_OFFSET * overlap,
        z: nz * BUMP_OFFSET * overlap,
        overlap: overlap,
    };
}

// Everyone who touched him this frame: the player, every bot, and every bird within
// reach that is not flying. The birds come from `goats.entities` -- another mod's
// offer -- so this is also where a mod that is not loaded simply contributes nothing.
function contact() {
    let best = bump(goats.player.state().x, goats.player.state().z, 1, BUMP_DIST);
    const bots = goats.bots.list();
    for (let i = 0; i < bots.length; i++) {
        const hit = bump(bots[i].x, bots[i].z, 1, BUMP_DIST);
        if (hit !== null && (best === null || hit.overlap > best.overlap)) best = hit;
    }
    const near = goats.entities.near(x, z, BUMP_DIST + ENTITY_MARGIN);
    for (let i = 0; i < near.length; i++) {
        const e = near[i];
        // A bird in the air is not a bird he can walk into; `y` against the ground is
        // the whole of telling them apart, since nothing here knows what a bird is.
        if (e.y - goats.world.terrainHeight(e.x, e.z) > BIRD_AIRBORNE) continue;
        const hit = bump(e.x, e.z, BIRD_BUMP, BUMP_DIST + e.r);
        if (hit !== null && (best === null || hit.overlap > best.overlap)) best = hit;
    }
    if (best === null) {
        held = false;
        return;
    }
    knockX = best.x;
    knockZ = best.z;
    knock = Math.min(1, knock + best.overlap * 0.5);
    held = true;
}

// ---- the devices ----------------------------------------------------------

// The device he is standing on, of either kind, or null. `traps` is the core's own
// derivation and its own filter -- `range` is measured to the device itself -- so
// asking at the core's trigger radius *is* the core's trigger question.
//
// The half-metre bucket is the core's own trick in `checkTriggers`, by way of the
// birds: a guy standing still would otherwise ask the field the same question sixty
// times a second, and the same device would answer it sixty times.
let tripStamp = -1;

function trip() {
    if (y > GROUNDED) return;
    const stamp = ((((x * 2) | 0) + 4096) * 8192 + (((z * 2) | 0) + 4096));
    if (tripStamp === stamp) return;
    tripStamp = stamp;
    const near = goats.explosions.traps(x, z, goats.tuning.get("explosions.mine.trigger"));
    let kind = null;
    let best = Infinity;
    const pools = [["mine", near.mines], ["trap", near.traps]];
    for (let i = 0; i < pools.length; i++) {
        const list = pools[i][1];
        for (let j = 0; j < list.length; j++) {
            const d = list[j].dist;
            if (d < best) {
                best = d;
                kind = pools[i][0];
            }
        }
    }
    if (kind === null) return;
    // The core's own path, so this is the bang a goat gets: the crater, the damage,
    // the flash, the sound, the event, and -- in a session -- the report. It also
    // spends the device and moves its replacement, which is what keeps him from
    // setting the same one off again when the next arc lands him back on it.
    goats.explosions.blast(x, z, kind);
}

// A bang within its radius throws him, and the throw is the core's own: the same lift
// and push a goat gets, scaled by the same falloff as the damage, so the rim is a
// shove and the centre is a launch. The *event* is what says so rather than his own
// trip, because that covers every bang near him and not only the ones under his feet.
function onBlast(blast) {
    if (flung) return;
    const dx = x - blast.x;
    const dz = z - blast.z;
    const d = Math.sqrt(dx * dx + dz * dz);
    if (d > blast.radius) return;
    const falloff = clamp(1 - d / blast.radius, 0.15, 1);
    const lift = goats.tuning.get("explosions.blast.lift") * falloff;
    const push = goats.tuning.get("explosions.blast.push") * falloff;
    blasts += 1;
    resting = 0;
    flung = true;
    flungT = 0;
    tumble = 0;
    y = Math.max(y, 0.01);
    vy = lift;
    aimed = false;
    let ux = 0;
    let uz = 0;
    if (d > 1e-3) {
        ux = dx / d;
        uz = dz / d;
    } else {
        ux = Math.sin(heading);
        uz = Math.cos(heading);
    }
    // The unlucky half. With a device in reach and the ladder saying yes, the arc is
    // aimed at it: the flight time to *its* ground -- the arc lands where the terrain
    // is, so a device half a metre up a slope still gets hit -- and the horizontal
    // speed that covers the distance in that time. `CHAIN_REACH` is the one guard: a
    // bang too weak to carry him that far cannot do it, and the aim then fails and he
    // lands short, which is the only thing that ever stops the chain early.
    const target = nearestDevice(null, CHAIN_RANGE);
    const index = Math.min(blasts - 1, CHAIN_CHANCE.length - 1);
    const chance = blasts <= CHAIN_CHANCE.length ? CHAIN_CHANCE[index] : 0;
    if (target !== null && rng() < chance) {
        // `y(T) = drop` for T, the ordinary quadratic, with the early root the way up
        // and the late one the way down. A target above the apex has no real root.
        const drop = goats.world.terrainHeight(target.x, target.z) - goats.world.terrainHeight(x, z);
        const flight = -vy / FLUNG_GRAVITY +
            Math.sqrt((vy * vy) / (FLUNG_GRAVITY * FLUNG_GRAVITY) + (2 * drop) / FLUNG_GRAVITY);
        const tx = target.x - x;
        const tz = target.z - z;
        const span = Math.sqrt(tx * tx + tz * tz);
        const need = span / flight;
        if (isFinite(flight) && flight > 0 && span > 0.01 && need <= push * CHAIN_REACH) {
            vx = (tx / span) * need;
            vz = (tz / span) * need;
            aimed = true;
        }
    }
    if (!aimed) {
        vx = ux * push;
        vz = uz * push;
    }
    say(yells, YELL_VOLUME);
}

// The nearest armed device within `range` of him, of one kind or either (`want` null),
// or null when the field is empty there. The core's own derivation, so a device a mod
// has switched off is not one here either, and the returned `dist` is the number the
// range filtered on.
function nearestDevice(want, range) {
    const near = goats.explosions.traps(x, z, range);
    const pools = want === "trap" ? [near.traps] :
        want === "mine" ? [near.mines] : [near.mines, near.traps];
    let best = null;
    for (let i = 0; i < pools.length; i++) {
        for (let j = 0; j < pools[i].length; j++) {
            if (best === null || pools[i][j].dist < best.dist) best = pools[i][j];
        }
    }
    return best;
}

// The arc, one step. He is not steered while he is in the air: the throw owns his
// position until he meets the ground, and the *ground* is where he meets it --
// `terrainHeight` at the point under him, crater and all, so an aimed landing in a
// fresh hole arrives where the hole is.
function stepFlung(dt) {
    vy += FLUNG_GRAVITY * dt;
    x += vx * dt;
    z += vz * dt;
    y += vy * dt;
    tumble += FLUNG_SPIN * dt;
    flungT += dt;
    if ((vy < 0 && y <= 0) || flungT >= FLUNG_MAX) {
        y = 0;
        grounded();
    }
}

// Down he comes: a running start in the direction the throw was going -- which is
// where the device is -- a full panic, and, a frame later, once he is standing on it,
// the device he landed on. That is the whole chain: the aim, the bang, the aim.
function grounded() {
    const landing = Math.sqrt(vx * vx + vz * vz);
    if (landing > 0.2) {
        heading = Math.atan2(vx / landing, vz / landing);
        speed = clamp(landing, 0, PANIC_SPEED);
    }
    flung = false;
    vy = 0;
    vx = 0;
    vz = 0;
    y = 0;
    flungT = 0;
    tumble = 0;
    resting = 0;
    panic = 1;
    say(lands, LAND_VOLUME);
}

goats.on("blast", onBlast);

goats.on("update", function (dt) {
    ensureModel();
    ensureVoice();

    if (flung) {
        stepFlung(dt);
        // The shove still bleeds off, and still has to reach zero: the flung branch is
        // the one he is in when a bang follows a contact on the same frame, and a value
        // left a thousandth above zero would read as a contact for the rest of the arc.
        knock *= Math.exp(-dt / KNOCK_FADE);
        if (knock < 1e-3) knock = 0;
        return;
    }

    // The ladder is restored once he has been on his feet a while, so the next device
    // he finds is a certainty again rather than the tail of the last episode.
    resting += dt;
    if (resting >= CHAIN_RESET && blasts > 0) {
        blasts = 0;
        aimed = false;
    }

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

    contact();
    if (!held) {
        const fade = Math.exp(-dt / BUMP_FADE);
        knockX *= fade;
        knockZ *= fade;
    }
    knock *= Math.exp(-dt / KNOCK_FADE);
    if (knock < 1e-3) knock = 0;

    trip();
});

goats.on("draw3d", function () {
    if (model < 0) return;
    const dx = x + knockX;
    const dz = z + knockZ;
    // He faces local +Z. On his feet that is a Y rotation of the heading -- the wobble
    // is the panic and the stagger is the bump -- and the hop is him landing from one.
    let axisX = 0;
    let axisY = 1;
    let axisZ = 0;
    let yaw = (heading * 180) / Math.PI
        + Math.sin(stride * Math.PI * 2) * WOBBLE * panic
        + knock * STAGGER;
    // Thrown, he somersaults instead: one axis and one angle is all `drawModelEx`
    // takes, and the axis he needs is his own side -- level, perpendicular to the way
    // he is facing -- so he goes over nose-first along the throw rather than spinning
    // like a top. (The birds compose a quaternion for a pitch *and* a roll; a guy who
    // only ever rolls needs neither.)
    if (flung) {
        axisX = Math.cos(heading);
        axisY = 0;
        axisZ = -Math.sin(heading);
        yaw = tumble * 360;
    }
    const bob = flung ? 0 : Math.abs(Math.sin(stride * Math.PI)) * (BOB_BASE + speed * BOB_PER_SPEED);
    const hop = flung ? 0 : Math.sin(knock * Math.PI) * HOP;
    rl.drawModelEx(model, dx, y + goats.world.terrainHeight(dx, dz) + bob + hop, dz,
        axisX, axisY, axisZ, yaw, SCALE, SCALE, SCALE, rl.WHITE);
});

// ---- the console ----------------------------------------------------------

// `fatguy` reports what he is doing, which is also what a test reads: the ladder is
// only visible as the number of bangs and the chance the next throw carries.
goats.command("fatguy", function (parts) {
    const verb = parts.length > 1 ? parts[1] : "state";
    if (verb === "boom") {
        const want = parts.length > 2 ? parts[2] : "mine";
        const dev = nearestDevice(want === "trap" ? "trap" : "mine", 40);
        if (dev === null) return "error fatguy: no " + want + " in reach";
        x = dev.x;
        z = dev.z;
        y = 0;
        flung = false;
        tumble = 0;
        heading = 0;
        speed = 0;
        // Straight onto it, so the next frame's trip is the core's own trigger test
        // rather than this command's -- which is the point of the command.
        tripStamp = -1;
        goats.log("fatguy: standing on a " + want + " at " + dev.x.toFixed(1) + ", " +
            dev.z.toFixed(1));
        return "ok fatguy boom " + want;
    }
    if (verb !== "state") return "error fatguy: state or boom";
    // `chance` is what the *next* bang's aim will carry, so the ladder is readable
    // between bangs: 1.0 before the first, 0.75 after it, and 0 once it has run out.
    return "ok " + JSON.stringify({
        x: Math.round(x * 100) / 100,
        z: Math.round(z * 100) / 100,
        y: Math.round(y * 100) / 100,
        flung: flung,
        aimed: aimed,
        blasts: blasts,
        chance: blasts < CHAIN_CHANCE.length ? CHAIN_CHANCE[blasts] : 0,
        knock: Math.round(knock * 100) / 100,
        panic: Math.round(panic * 100) / 100,
    });
});

goats.on("shutdown", function () {
    if (typeof rl.unloadModel === "function" && model >= 0) rl.unloadModel(model);
    model = -1;
    // The voices are dropped rather than freed: there is no `unloadSound` to call.
    yells = [];
    lands = [];
    voiceRead = false;
});
