// ---- net ------------------------------------------------------------------
//
// The JS engine has no sockets, so all of the networking lives in the Rust host
// (`crates/goats/src/net.rs`). This part is only the scene end of a line-based
// bridge: intents accumulate in an outbox that `sceneNetDrain()` returns and
// clears once a frame, and events arrive through `sceneNetEvent(line)`, one JSON
// object per line. Both directions are plain text, so the harness can drive the
// whole thing without a socket or a peer.
//
// The events update a small local view (`netMode`, `netName`, `netRoster`) for
// the `net` and `who` commands, and print into the console's network stream.

const NET_OFF = "off";
// The flag on `connect` that consents to fetching the host's world mods when the
// join is refused for them (M18d).
const NET_PULL_FLAG = "--pull";
let netMode = NET_OFF;      // "off" | "host" | "client"
let netName = "";           // this player's assigned name, once connected
let netTicket = "";         // the ticket to hand out, once hosting
let netRoster = [];         // names in the session, host first
let netOutbox = [];         // intent lines waiting for the host

function netQueue(intent) {
    netOutbox.push(JSON.stringify(intent));
}

// Called by the host once a frame; returns and clears the queued intents. An
// empty string means "nothing to send", which is the common case. The local
// goat's pose is queued here rather than by the scene, because this is the one
// place that runs exactly once a frame.
function sceneNetDrain() {
    netMaybePublish();
    netMaybePublishWorld();
    if (netOutbox.length === 0) return "";
    const text = netOutbox.join("\n");
    netOutbox = [];
    return text;
}

function netStatus() {
    return { mode: netMode, name: netName, ticket: netTicket, roster: netRoster.slice() };
}

function netInSession() {
    return netMode !== NET_OFF;
}

// The default name to ask for when the player did not give one. The server has
// the final say, so this is only a request.
function netRequestedName(parts, index) {
    const requested = parts[index];
    return requested === undefined ? "" : requested;
}

// Says something. The server routes a leading `@name` as a whisper, so the line
// is queued exactly as typed. An empty reply means "nothing to report": the
// console should not print an `ok` after every chat line.
function netSay(text) {
    if (!netInSession()) return "error not in a session";
    const line = String(text).trim();
    if (line === "") return "error nothing to say";
    netQueue({ type: "say", text: line });
    return "";
}

// ---- intents ---------------------------------------------------------------

function netHost(parts) {
    if (netInSession()) return "error already in a session (leave first)";
    netQueue({ type: "host", name: netRequestedName(parts, 1) });
    consoleSystem("net: hosting ...");
    return "ok host";
}

// `connect <ticket> [name] [--pull]`, taken apart. The consent flag may sit
// anywhere after the verb, so `connect T --pull alice` reads as well as
// `connect T alice --pull`; `name` is `undefined` when the player gave none, which
// is what the console's username prompt keys off.
function netJoinArgs(parts) {
    const args = parts.slice(1).filter(function (part) { return part !== NET_PULL_FLAG; });
    return {
        ticket: args[0] === undefined ? "" : args[0],
        name: args[1],
        pull: args.length !== parts.length - 1
    };
}

// `--pull` is the player's consent to fetch what the host runs and this client
// lacks, install it and retry once -- a mod is code, so it is only ever fetched
// because somebody said so.
function netJoin(parts) {
    if (netInSession()) return "error already in a session (leave first)";
    const args = netJoinArgs(parts);
    if (args.ticket === "") return "error connect expects a ticket";
    netQueue({
        type: "join",
        ticket: args.ticket,
        name: args.name === undefined ? "" : args.name,
        pull: args.pull
    });
    consoleSystem("net: connecting ..." + (args.pull ? " fetching the host's mods if they differ" : ""));
    return "ok connect";
}

function netLeave() {
    if (!netInSession()) return "error not in a session";
    netQueue({ type: "close" });
    netReset();
    consoleSystem("net: leaving");
    return "ok leave";
}

function netReset() {
    netMode = NET_OFF;
    netName = "";
    netTicket = "";
    netRoster = [];
    netPeersClear();
}

// ---- events ----------------------------------------------------------------

// One event line from the host. Unknown types are reported rather than ignored,
// so a bridge change cannot fail silently.
function sceneNetEvent(line) {
    let event;
    try {
        event = JSON.parse(String(line));
    } catch (error) {
        consoleNet("net: unreadable event " + String(line));
        return;
    }
    modEmit("session", event);
    switch (event.type) {
        case "session":
            // The world is shared by seed: the first event of every session,
            // before any roster or chat line.
            sceneUseSeed(event.seed);
            consoleNet("net: world seed " + String(event.seed));
            break;
        case "hosting":
            netMode = "host";
            netName = String(event.name);
            // Publish promptly now that a session exists, rather than waiting
            // for the next throttle window.
            netPoseFrame = -NET_POSE_EVERY;
            netWorldFrame = -NET_WORLD_EVERY;
            consoleNet("net: hosting as " + netName);
            break;
        case "ticket":
            netTicket = String(event.ticket);
            consoleNet("net: ticket " + netTicket);
            consoleSystem("net: `copy` puts the ticket on the clipboard");
            break;
        case "welcome":
            netMode = "client";
            netName = String(event.name);
            netPoseFrame = -NET_POSE_EVERY;
            consoleNet("net: joined as " + netName);
            break;
        case "joined":
            consoleNet("net: " + event.name + " joined");
            break;
        case "left":
            netPeerRemove(String(event.name));
            consoleNet("net: " + event.name + " left");
            break;
        case "peer":
            // Positions arrive many times a second, so they are not printed.
            netPeerState(String(event.name), event.state);
            break;
        case "world":
            // The server's world. Not printed either.
            netApplyWorld(event.bots, event.weather, event.streams, event.eaten,
                event.craters, event.spent);
            break;
        case "mods":
            // Every world mod's state, on the server's own datagram. Not printed.
            netApplyMods(event.mods);
            break;
        case "consume":
            // A client's bite, on the host: record it in this meadow. The next
            // world snapshot carries it back to everyone.
            sceneConsume(event.key);
            break;
        case "blast":
            // A bang the host relayed (M19e). The fire, the crater, and the goat this end
            // simulates -- a peer's mine flings *this* goat, here, and not on the host.
            applyRemoteBlast(String(event.kind), event.key, event.x, event.z);
            break;
        case "blast_report":
            // A client's device went off (M19e), on the host: spend it, dig it here, and
            // hand the relay back to the host bridge with the reporter named.
            netBlastReport(String(event.kind), event.key, String(event.by));
            break;
        case "chat":
            consoleNet("net: " + (event.direct ? "dm " : "") +
                (event.from === netName ? "you" : event.from) + ": " + event.text);
            break;
        case "roster":
            netRoster = Array.isArray(event.names) ? event.names.slice() : [];
            consoleNet("net: roster " + netRoster.join(", "));
            break;
        case "notice":
            consoleNet("net: " + event.text);
            break;
        case "pulled":
            // The host has already loaded what arrived -- an entry is Rust's to
            // evaluate -- and this arrives before the retried join's welcome, so
            // by the time the world does, the mods it is built on are in the
            // scene. All that is left here is to say what the join cost.
            consoleNet("net: " + event.text);
            break;
        case "disconnected":
            netReset();
            consoleNet("net: disconnected");
            break;
        case "error":
            netReset();
            consoleNet("net: error " + event.text);
            break;
        default:
            consoleNet("net: unknown event " + String(line));
    }
}

// ---- remote goats ----------------------------------------------------------
//
// Each peer is one more goat model, driven by the snapshots the server relays.
// A snapshot is a target, not a teleport: the render position eases toward it,
// so 20 Hz arrivals read as movement instead of a stutter. A peer's model is
// loaded the first time it is seen and unloaded when it leaves, the same
// ownership rule the bots follow (CPU skinning gives each goat its own model).

const NET_POSE_EVERY = 3;    // frames between snapshots (~20 Hz at 60 fps)
const NET_PEER_SMOOTH = 12;  // how fast a remote goat converges, per second
const NET_WORLD_EVERY = 6;   // frames between world snapshots (~10 Hz at 60 fps)
let PEERS = [];
let netPoseFrame = -NET_POSE_EVERY;
let netWorldFrame = -NET_WORLD_EVERY;

function netPeersClear() {
    if (typeof rl.unloadModel === "function") {
        for (let i = 0; i < PEERS.length; i++) rl.unloadModel(PEERS[i].model);
    }
    PEERS = [];
}

function netPeerFind(name) {
    for (let i = 0; i < PEERS.length; i++) {
        if (PEERS[i].name === name) return i;
    }
    return -1;
}

function netPeerRemove(name) {
    const i = netPeerFind(name);
    if (i < 0) return;
    if (typeof rl.unloadModel === "function") rl.unloadModel(PEERS[i].model);
    PEERS.splice(i, 1);
}

// A snapshot from the server. The first one also creates the goat, placed
// exactly where it is so it does not slide in from the origin.
function netPeerState(name, state) {
    if (!state || typeof state.x !== "number") return;
    const found = netPeerFind(name);
    if (found < 0) {
        // No model to drive (headless, or the goat model itself failed to
        // load): drop the snapshot rather than track a ghost.
        if (typeof rl.loadModel !== "function" || !haveModel) return;
        const handle = rl.loadModel(ASSET_SLOTS["model.goat"]);
        if (handle < 0) return;
        modelLoaded(handle);
        if (litShader >= 0) {
            rl.setModelShader(handle, modelShaderFor(handle, useLighting ? litShader : -1));
        }
        if (shadowColor >= 0) rl.setModelTexture(handle, SHADOW_MAP_INDEX, shadowColor);
        PEERS.push({
            name: name,
            model: handle,
            x: state.x, z: state.z, yaw: state.yaw, phase: state.phase,
            tx: state.x, tz: state.z, tyaw: state.yaw, tphase: state.phase,
            // The flung arc's height (M19f), in metres above the ground under it. Its
            // own field rather than part of the easing below: a parabola whose apex is
            // eased is a lower parabola, so this is applied *directly*, every
            // snapshot.
            py: netPeerHeight(state),
            gait: state.gait,
            shot: netPeerShot(state.gait),
        });
        return;
    }
    const p = PEERS[found];
    const shot = netPeerShot(state.gait);
    // A one-shot is stepped straight from the snapshot rather than eased into:
    // the two phase spaces are not shared (a jump ends at 1, the loop it
    // interrupts resumes wherever it was), so entering one and leaving it again
    // both snap instead of gliding.
    if (shot || shot !== p.shot) p.phase = state.phase;
    p.shot = shot;
    p.tx = state.x;
    p.tz = state.z;
    p.tyaw = state.yaw;
    p.tphase = state.phase;
    // ...and neither is the flung height: `py` is applied where it arrives, for the
    // reason above and one more -- the arc's shape is the host's simulation, and a
    // smoothed copy of a parabola is a different, lower trajectory.
    p.py = netPeerHeight(state);
    p.gait = state.gait;
}

// A peer's height above its ground, from the frame. Absent (an older scene, or a goat
// that has never been airborne) is zero.
function netPeerHeight(state) {
    return typeof state.py === "number" && state.py > 0 ? state.py : 0;
}

// Ease every remote goat toward its last snapshot. Phase and yaw take the short
// way around, so neither spins the long way when a value wraps.
function updatePeers(dt) {
    if (PEERS.length === 0) return;
    const k = Math.min(1, dt * NET_PEER_SMOOTH);
    for (let i = 0; i < PEERS.length; i++) {
        const p = PEERS[i];
        p.x += (p.tx - p.x) * k;
        p.z += (p.tz - p.z) * k;
        let dy = p.tyaw - p.yaw;
        while (dy > Math.PI) dy -= 2 * Math.PI;
        while (dy < -Math.PI) dy += 2 * Math.PI;
        p.yaw += dy * k;
        if (p.shot) {
            // A one-shot is posed at the fraction the snapshot carried, with
            // nothing to ease toward -- and the wrap below would read the jump
            // from 0.9 back to 0.1 as a lap of the clip rather than a new leap.
            p.phase = p.tphase;
            continue;
        }
        let dp = p.tphase - p.phase;
        if (dp > 0.5) dp -= 1;
        else if (dp < -0.5) dp += 1;
        p.phase = mod1(p.phase + dp * k);
    }
}

// Whether a gait plays once, from its own clock, rather than looping. Its phase
// is a fraction through that clip, so it is neither eased nor wrapped the way a
// loop phase is.
function netPeerShot(gait) {
    return gait === "jump" || gait === "dead" || gait === "eat" || gait === "flung";
}

// The clip role a peer's gait plays, falling back like `clipRole` does.
function peerRole(p) {
    if (p.gait === "dead" && CLIP.death) return "death";
    if (p.gait === "sleep" && CLIP.sleep) return "sleep";
    if (p.gait === "eat" && CLIP.eat) return "eat";
    if (p.gait === "flung") return CLIP.flung ? "flung" : "jump";
    if (p.gait === "jump" && CLIP.jump) return "jump";
    if (p.gait === "run" && CLIP.run) return "run";
    if (p.gait === "trot" && CLIP.trot) return "trot";
    if (p.gait === "walk" && CLIP.walk) return "walk";
    if (CLIP.idle) return "idle";
    return "walk";
}

function drawPeers(tint) {
    for (let i = 0; i < PEERS.length; i++) {
        const p = PEERS[i];
        const dx = p.x - goat.px;
        const dz = p.z - goat.pz;
        if (dx * dx + dz * dz > shadowGrassCull2()) {
            rl.drawCube(p.x, terrainHeight(p.x, p.z) + 0.06, p.z, 1.3, 0.012, 1.75, ambShadow);
        }
        poseModelOn(p.model, clipAt(peerRole(p), 0), p.phase);
        // A flung peer is flown by *its own* client (M19c) and arrives here as a gait,
        // a phase and a height (M19f): the fraction poses and rolls it, the clip's own
        // tumble is the clip's, and `p.py` is where the arc had it -- without which a
        // mirrored goat somersaults on the grass. The roll stays the placeholder's on
        // the same rule as `clipRole`'s.
        const py = terrainHeight(p.x, p.z) + groundOffset + p.py;
        if (p.gait === "flung") {
            const d = flingDraw(p.x, py, p.z, p.yaw, flingTumble(p.phase),
                TUNING.explosions.fling.pivot);
            rl.drawModelEx(p.model, d.x, d.y, d.z, d.ax, d.ay, d.az, d.deg, 1, 1, 1, tint);
        } else {
            rl.drawModelEx(p.model, p.x, py, p.z,
                0, 1, 0, (p.yaw * 180) / Math.PI, 1, 1, 1, tint);
        }
    }
}

function drawPeersShadow() {
    for (let i = 0; i < PEERS.length; i++) {
        const p = PEERS[i];
        const dx = p.x - goat.px;
        const dz = p.z - goat.pz;
        if (dx * dx + dz * dz > shadowGrassCull2()) continue;
        rl.setModelShader(p.model, modelShaderFor(p.model, depthShader));
        rl.setModelTexture(p.model, SHADOW_MAP_INDEX, -1);
        // No `poseModelOn` here, for the reason spelled out in `drawBotsShadow`:
        // the depth pass draws the pose `drawPeers` left in the mesh last frame,
        // so a remote goat is skinned once a frame rather than twice. The roll is
        // the same as the visible pass leaves it, for the same reason.
        const py = terrainHeight(p.x, p.z) + groundOffset + p.py;
        if (p.gait === "flung") {
            const d = flingDraw(p.x, py, p.z, p.yaw, flingTumble(p.phase),
                TUNING.explosions.fling.pivot);
            rl.drawModelEx(p.model, d.x, d.y, d.z, d.ax, d.ay, d.az, d.deg, 1, 1, 1, rl.WHITE);
        } else {
            rl.drawModelEx(p.model, p.x, py, p.z,
                0, 1, 0, (p.yaw * 180) / Math.PI, 1, 1, 1, rl.WHITE);
        }
        rl.setModelTexture(p.model, SHADOW_MAP_INDEX, shadowColor);
        rl.setModelShader(p.model, modelShaderFor(p.model, litShader));
    }
}

// The phase to publish. A one-shot gait (a jump, the death, a meal) is posed
// from its own clock and `goat.phase` stands still for the whole of it, so the
// loop phase is a stale frame number there: a remote goat used to hold one
// frozen pose right through the jump. The fraction through the clip goes
// instead, the way `netBotPhase` carries the bots'.
function netPeerPhase() {
    if (mode === "flung") return flingProgress();
    if (mode === "jump" && CLIP.jump) return Math.min(jumpTime / CLIP.jump.duration, 1);
    if (mode === "dead" && CLIP.death) return Math.min(deathTime / CLIP.death.duration, 1);
    if (mode === "eat" && CLIP.eat) return Math.min(eatTime / CLIP.eat.duration, 1);
    return goat.phase;
}

// The local goat's snapshot, queued at a fraction of the frame rate when this
// player is in a session. Fire-and-forget: a dropped one is replaced by the
// next, which is why the channel is a datagram.
function netMaybePublish() {
    if (!netInSession()) return;
    if (sceneFrames - netPoseFrame < NET_POSE_EVERY) return;
    netPoseFrame = sceneFrames;
    netQueue({
        type: "pose",
        x: netRound3(goat.px),
        z: netRound3(goat.pz),
        yaw: netRound3(goat.yaw),
        phase: netRound3(netPeerPhase()),
        speed: netRound3(curSpeed),
        gait: mode,
        // The flung arc's height, in metres (M19f): the one thing a gait and a phase
        // could not say. Zero for every other mode, so a grounded goat costs a number
        // rather than nothing -- and it is what a viewer needs to put the tumble where
        // the throw actually went.
        py: netRound3(mode === "flung" ? goat.py : 0),
    });
}

// ---- the server's world ----------------------------------------------------
//
// The bots collide with players, the weather is a shared state machine, and the
// meadow is mutated by everyone, so none of them can be reproduced from a seed
// alone. The host is therefore the only side that simulates the world, and
// everyone else mirrors what it sends: `netWorldLocal` is what the frame loop
// gates the local simulation on, and `netApplyWorld` is the mirror end. Joining
// replaces the client's world rather than merging it.

function netRound3(v) {
    return Math.round(v * 1000) / 1000;
}

// Offline and the host simulate the bots; a client does not.
function netWorldLocal() {
    return netMode !== "client";
}

// A one-shot gait is posed from its own clock when it is drawn, so the wire
// carries the fraction through the clip rather than the bot's private timer.
function netBotPhase(b) {
    // A flung bot's arc is the host's; the fraction through it is what a viewer
    // poses and rolls from, the same as for a peer's goat.
    if (b.mode === "flung") return botFlingProgress(b);
    // A death is one-shot too: the pose comes from the fraction, not from a timer a
    // viewer does not have.
    if (b.mode === "dead") return Math.min(b.deathTime / b.deathDur, 1);
    if (b.mode === "jump") return Math.min(b.jumpTime / b.jumpDur, 1);
    if (b.mode === "eat") return Math.min(b.eatTime / b.eatDur, 1);
    return b.phase;
}

// The bots as the wire sees them. `index` picks the coat and scale from the
// shared table, so only what moves is sent.
function sceneWorldBots() {
    const out = [];
    for (let i = 0; i < BOTS.length; i++) {
        const b = BOTS[i];
        const role = botRole(b);
        const variant = b.var[role];
        out.push({
            index: i,
            x: netRound3(b.x),
            z: netRound3(b.z),
            yaw: netRound3(b.yaw),
            phase: netRound3(netBotPhase(b)),
            gait: b.mode,
            variant: variant === undefined ? 0 : variant,
            // The flung arc's height (M19f) in **centimetres**, which is the unit
            // `BotState::py` is typed in -- the scene is where a bot's height lives,
            // so this is the only conversion there is.
            py: Math.round(b.py * 100),
        });
    }
    return out;
}

function netMaybePublishWorld() {
    if (netMode !== "host") return;   // only the host owns the world
    if (sceneFrames - netWorldFrame < NET_WORLD_EVERY) return;
    netWorldFrame = sceneFrames;
    netQueue({
        type: "world",
        bots: sceneWorldBots(),
        weather: sceneWeatherState(),
        streams: sceneStreams(),
        eaten: sceneEaten(),
        // The ground and the devices that have gone off (M19e). The host is the authority
        // on both, so an empty list is a statement -- flat ground, nothing spent -- and the
        // `null` that means "keep yours" is the wire's, not the scene's.
        craters: netWorldCraters(),
        spent: netWorldSpent(),
    });
    // A world mod's state rides its own datagram, beside the world: it may be
    // bigger than the world's budget, and losing it costs a mod rather than
    // everyone's world. Nothing is sent when no world mod is loaded.
    if (modWorldActive()) netQueue({ type: "mods", mods: sceneWorldMods() });
}

// Mirror the server's world: its sky, its streams, its meadow, its bots, its ground and the
// devices it has seen go off. A client runs neither the weather state machine nor the bot AI,
// does not count its meadow down, and does not heal its craters, so this is the whole of all
// of it.
function netApplyWorld(bots, weather, streams, eaten, craters, spent) {
    applyWeatherState(weather);
    sceneUseStreams(streams);
    applyEaten(eaten);
    // The two that are *state* rather than events (M19e): the ground the goat is standing on
    // and the field of devices. `null` in either keeps what this end has, the meadow's contract.
    applyCraters(craters);
    applySpent(spent);
    modEmit("world", { bots: bots, weather: weather, streams: streams, eaten: eaten,
        craters: craters, spent: spent });
    if (!Array.isArray(bots)) return;
    if (BOTS.length !== bots.length) setHerdSize(bots.length);
    for (let i = 0; i < bots.length && i < BOTS.length; i++) {
        const s = bots[i];
        const b = BOTS[i];
        b.x = s.x;
        b.z = s.z;
        b.yaw = s.yaw;
        b.mode = s.gait;
        b.phase = s.phase;
        // Where the host had it, whatever the gait (M19f). Not the flung gait's private
        // field: a bot killed in the air keeps falling from where it was killed
        // (M19c2), and its corpse is a `dead` row with a height on it. An older row
        // without the field is a grounded bot, which is what zero means.
        b.py = (s.py === undefined ? 0 : s.py) / 100;
        // A one-shot gait is posed from its own clock in `drawBots`, so point
        // that clock at the fraction the server resolved.
        if (s.gait === "jump") {
            b.jumpDur = 1;
            b.jumpTime = s.phase;
        } else if (s.gait === "eat") {
            b.eatTime = s.phase;
            b.eatDur = 1;
        } else if (s.gait === "flung") {
            // The arc belongs to the host, and the fraction travels (M19f): point the
            // clock at it (as above) so the pose and the roll read the same here. The
            // height is in `b.py`, set above with every other row's.
            b.flyTime = s.phase;
            b.flyFlight = 1;
        } else if (s.gait === "dead") {
            // A death is the host's, clip and all: the fraction is the pose, and the
            // body lies at the position the snapshot carries. Getting up again is the
            // host's too -- `herd.deathLinger` runs where the herd is simulated, so a
            // client simply sees the next snapshot say something else. `Gait::Dead`
            // has been on the wire since the peers' goats had it, so a bot dying
            // costs no protocol version.
            b.deathTime = s.phase;
            b.deathDur = 1;
        }
        const v = s.variant | 0;
        b.var.idle = v;
        b.var.sleep = v;
        b.var.jump = v;
        b.var.eat = v;
    }
}

// Every world mod's state, on its own datagram: the host's stream states continue
// here, and each mod's published value goes to its `apply`. A client keeps the
// last one it got, so a lost datagram costs a tick of a mod's state rather than
// anything about the world.
function netApplyMods(mods) {
    sceneApplyWorldMods(mods);
    modEmit("mods", mods);
}

// ---- blasts (M19e) ---------------------------------------------------------
//
// A bang is an *event*, not state: small, infrequent, and on the channel that already carries
// a bite and a notice. The rule under all of it is that a device fires in exactly one place:
// the process that simulates the goat that tripped it fires it locally and reports it, the
// host spends the device and relays the bang to everyone else, and every other client draws
// it and applies it to the goats *it* simulates. Nobody waits for the host to fire it back.

// A device this process has just set off, at the end of its fuse (`blast` in
// explosions.js). Offline there is nobody to tell and the bang is already local. The
// coordinates ride along because a *host* relays with them; a client's are dropped on the way
// up, where the host derives them from the key rather than believing a peer.
function netBlastFired(kind, key, x, z) {
    if (!netInSession()) return;
    netQueue({ type: "blast", kind: kind, key: key, x: netRound3(x), z: netRound3(z) });
}

// A client's device went off, on the host: spend it and dig it here (`sceneBlastReport`),
// then hand the relay to the host bridge with the reporter named, so the relay can leave them
// out -- they have already felt this one.
function netBlastReport(kind, key, by) {
    const at = sceneBlastReport(kind, key);
    if (at === null) return;
    netQueue({
        type: "blast",
        kind: kind,
        key: key,
        x: netRound3(at.x),
        z: netRound3(at.z),
        by: by,
    });
}

// The craters as the wire sees them: where, how wide, and how deep *now* -- the host heals,
// and every snapshot carries the dish as it stands.
function netWorldCraters() {
    const out = [];
    for (let i = 0; i < CRATERS.length; i++) {
        const c = CRATERS[i];
        out.push({
            x: netRound3(c.x),
            z: netRound3(c.z),
            r: netRound3(c.r),
            depth: netRound3(c.dip),
        });
    }
    return out;
}

// The devices that have gone off, by key and kind. Where each one moved to is deliberately
// absent: the destination is derived from the key that fired, so a client that has the key
// has the whole field.
function netWorldSpent() {
    const out = [];
    SPENT.forEach(function (key) { out.push({ key: key, trap: false }); });
    TRAP_SPENT.forEach(function (key) { out.push({ key: key, trap: true }); });
    return out;
}

// The remote goats as the harness sees them: names, render and target positions,
// and the gait being played.
function scenePeers() {
    const out = [];
    for (let i = 0; i < PEERS.length; i++) {
        const p = PEERS[i];
        out.push({ name: p.name, x: p.x, z: p.z, tx: p.tx, tz: p.tz, gait: p.gait, phase: p.phase, py: p.py });
    }
    return out;
}
