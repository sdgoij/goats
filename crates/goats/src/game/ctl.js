// Part 11/16 of the goat scene: the stdin command channel.
// ---- control channel ------------------------------------------------------
//
// The host (`crates/goats/src/main.rs`) reads a line from stdin, calls
// `sceneCommand(line)` and prints the returned string to stdout -- one line in,
// one line out. All engine logging goes to stderr, so stdout carries command
// responses only.
//
// Commands are dispatched between frames, so each one takes effect at a frame
// boundary. Every response is `ok ...` or `error ...`; queries return JSON
// after `ok `. `help` lists the vocabulary.

// Set by `quit`; `sceneFrame` (goat.js) stops the loop when it is true.
let ctlQuit = false;
// Frames left to run while stepping (`step <n>`); at 0 the game is paused
// again. `sceneFrame` consults it in the update gate.
let ctlStep = 0;
// Keys a script holds down, layered over the real keyboard by `ctlKeyDown`
// (which goat.js routes its movement reads through).
const ctlHeld = {};

// The vocabulary, grouped one topic per line. The console shows a multi-line
// reply and wraps anything still too wide, so `help` is a short page rather than
// one line that runs off the panel.
const HELP_GROUPS = [
    ["basics", "help ping"],
    ["state", "state stats time weather bots camera pos phase features fps"],
    ["move", "jump sleep wake walk trot run back stop turn yaw"],
    ["vitals", "health energy heal eat grass traps craters restart kill"],
    ["view", "lighting shadows sky mute settings setting tune perf ui console screenshot"],
    ["session", "host connect leave who net copy say msg"],
    ["mods", "mod"],
    ["flow", "pause resume step quit"],
];

const HELP = (function () {
    const rows = ["help - commands by topic"];
    for (let i = 0; i < HELP_GROUPS.length; i++) {
        rows.push("  " + HELP_GROUPS[i][0].padEnd(8) + HELP_GROUPS[i][1]);
    }
    return rows.join("\n");
})();

// A movement key is down if a script holds it or the real keyboard does, and no
// menu or the console is swallowing input.
function ctlKeyDown(code) {
    return uiScreen === "hud" && !consoleOpen && (ctlHeld[code] === true || rl.isKeyDown(code));
}

function ctlRelease(code) {
    delete ctlHeld[code];
}

// Hold the keys for a gait: W forward (S for `back`), SHIFT for run, CTRL for
// trot; `stop` releases everything.
function ctlSetGait(gait) {
    ctlRelease(rl.KEY_W);
    ctlRelease(rl.KEY_S);
    ctlRelease(rl.KEY_LEFT_SHIFT);
    ctlRelease(rl.KEY_RIGHT_SHIFT);
    ctlRelease(rl.KEY_LEFT_CONTROL);
    ctlRelease(rl.KEY_RIGHT_CONTROL);
    if (gait === "walk" || gait === "trot" || gait === "run") ctlHeld[rl.KEY_W] = true;
    else if (gait === "back") ctlHeld[rl.KEY_S] = true;
    if (gait === "trot") ctlHeld[rl.KEY_LEFT_CONTROL] = true;
    else if (gait === "run") ctlHeld[rl.KEY_LEFT_SHIFT] = true;
}

// The direction/gait the held keys imply, for `jump`.
function ctlHeldMove() {
    if (ctlHeld[rl.KEY_W] === true) return 1;
    if (ctlHeld[rl.KEY_S] === true) return -1;
    return 0;
}

function ctlHeldGait() {
    if (ctlHeld[rl.KEY_LEFT_SHIFT] === true || ctlHeld[rl.KEY_RIGHT_SHIFT] === true) return "run";
    if (ctlHeld[rl.KEY_LEFT_CONTROL] === true || ctlHeld[rl.KEY_RIGHT_CONTROL] === true) return "trot";
    return "walk";
}

function ctlArg(parts, index) {
    if (index >= parts.length) return null;
    const value = Number(parts[index]);
    return Number.isFinite(value) ? value : null;
}

function ctlRound(value) {
    return Math.round(value * 100) / 100;
}

function ctlToggle(current, arg) {
    if (arg === "on") return true;
    if (arg === "off") return false;
    return !current;
}

const CTL_SHADOWS = { off: SHADOW_OFF, planar: SHADOW_PLANAR, map: SHADOW_MAP };
const CTL_CLOUDS = { low: 0, medium: 1, high: 2 };

function sceneCommand(line) {
    const parts = String(line).trim().split(/\s+/);
    // `/who` and `who` are the same command: the slash is just what people type
    // in something that looks like a chat box.
    if (parts[0].length > 1 && parts[0].charAt(0) === "/") parts[0] = parts[0].slice(1);
    const command = parts[0];
    if (command === "") return "error empty command";
    switch (command) {
        case "help":
            return "ok " + HELP;
        case "ping":
            return "ok pong";

        // ---- queries -----------------------------------------------------
        case "state":
            return "ok " + JSON.stringify({
                mode: mode,
                clip: curClipName,
                health: ctlRound(stats.health),
                energy: ctlRound(stats.energy),
                exhausted: exhausted,
                paused: paused,
                satiety: ctlRound(satiety),
                foodInReach: nearestTuft(goat.px, goat.pz, TUNING.food.eatRange) !== null,
                eaten: eatenCount,
                x: ctlRound(goat.px),
                y: ctlRound(goat.py),
                z: ctlRound(goat.pz),
                ground: ctlRound(terrainHeight(goat.px, goat.pz)),
                yaw: ctlRound(goat.yaw),
                phase: ctlRound(goat.phase),
                time: ctlRound(worldTime),
                weather: weatherKind,
                fps: rl.getFPS(),
                frame: sceneFrames
            });
        case "stats":
            return "ok " + JSON.stringify({
                health: ctlRound(stats.health),
                energy: ctlRound(stats.energy),
                exhausted: exhausted
            });
        case "time": {
            if (parts.length === 1) {
                const hh = Math.floor(worldTime);
                const mm = Math.floor((worldTime - hh) * 60);
                return "ok " + JSON.stringify({ hours: ctlRound(worldTime), clock: (hh < 10 ? "0" : "") + hh + ":" + (mm < 10 ? "0" : "") + mm });
            }
            const hours = ctlArg(parts, 1);
            if (hours === null) return "error time expects hours";
            worldTime = ((hours % 24) + 24) % 24;
            return "ok time " + ctlRound(worldTime);
        }
        case "weather": {
            if (parts.length === 1) {
                return "ok " + JSON.stringify({
                    kind: weatherKind,
                    cloudiness: ctlRound(cloudiness),
                    rain: ctlRound(rainAmount),
                    wind: ctlRound(windSway),
                    speed: ctlRound(weatherSpeed)
                });
            }
            if (WEATHER_STATES[parts[1]] === undefined) {
                return "error unknown weather: " + parts[1] + " (want " + Object.keys(WEATHER_STATES).join("|") + ")";
            }
            const previous = weatherKind;
            weatherKind = parts[1];
            weatherTimer = TUNING.weather.hold[weatherKind][0];
            modEmit("weather", weatherKind, previous);
            return "ok weather " + weatherKind;
        }
        case "bots":
            return "ok " + JSON.stringify({
                count: BOTS.length,
                bots: BOTS.map(function (b) {
                    return { x: ctlRound(b.x), z: ctlRound(b.z), yaw: ctlRound(b.yaw), mode: b.mode, belly: ctlRound(b.satiety) };
                })
            });
        case "camera": {
            if (parts.length === 1) {
                return "ok " + JSON.stringify({ yaw: ctlRound(camYaw), pitch: ctlRound(camPitch), dist: ctlRound(camDist) });
            }
            if (parts[1] === "reset") {
                camYaw = TUNING.camera.yaw;
                camPitch = TUNING.camera.pitch;
                camDist = TUNING.camera.dist;
                return "ok camera reset";
            }
            const yaw = ctlArg(parts, 1);
            const pitch = ctlArg(parts, 2);
            const dist = ctlArg(parts, 3);
            if (yaw === null || pitch === null || dist === null) return "error camera expects <yawDeg> <pitchDeg> <dist>";
            camYaw = yaw * Math.PI / 180;
            camPitch = clamp(pitch * Math.PI / 180, 0.08, 1.35);
            camDist = clamp(dist, TUNING.camera.minDist, TUNING.camera.maxDist);
            return "ok camera " + ctlRound(camYaw) + " " + ctlRound(camPitch) + " " + ctlRound(camDist);
        }
        case "features":
            return "ok " + JSON.stringify({
                lighting: useLighting,
                shadows: shadowMode === SHADOW_MAP ? "map" : shadowMode === SHADOW_PLANAR ? "planar" : "off",
                sky: useSkyShader,
                cloud: CLOUD_LEVELS[cloudLevel()],
                fullscreen: typeof rl.isWindowFullscreen === "function" ? rl.isWindowFullscreen() : false,
                muted: muted,
                paused: paused,
                fps: rl.getFPS()
            });
        case "fps":
            return "ok " + rl.getFPS();

        // ---- settings / UI ----------------------------------------------
        case "settings":
            return "ok " + JSON.stringify({
                bgm: SETTINGS.bgm,
                sfx: SETTINGS.sfx,
                light: SETTINGS.light,
                shadow: SETTINGS.shadow === SHADOW_MAP ? "map" : SETTINGS.shadow === SHADOW_PLANAR ? "planar" : "off",
                sky: SETTINGS.sky,
                cloud: CLOUD_LEVELS[cloudLevel()],
                fullscreen: SETTINGS.fullscreen,
                herd: TUNING.herd.count
            });
        case "setting": {
            const key = parts[1];
            if (key === "bgm" || key === "sfx") {
                const v = ctlArg(parts, 2);
                if (v === null) return "error setting " + key + " expects a number";
                SETTINGS[key] = clamp(Math.round(v), 0, 100);
            } else if (key === "light" || key === "sky" || key === "fullscreen") {
                if (parts[2] === "on" || parts[2] === "off") SETTINGS[key] = parts[2] === "on";
                else if (parts[2] === "toggle") SETTINGS[key] = !SETTINGS[key];
                else return "error setting " + key + " expects on|off|toggle";
            } else if (key === "shadow") {
                const mode = CTL_SHADOWS[parts[2]];
                if (mode === undefined) return "error setting shadow expects map|planar|off";
                SETTINGS.shadow = mode;
            } else if (key === "cloud") {
                const level = CTL_CLOUDS[parts[2]];
                if (level === undefined) return "error setting cloud expects low|medium|high";
                SETTINGS.cloud = level;
            } else if (key === "herd") {
                const v = ctlArg(parts, 2);
                if (v === null) return "error setting herd expects a number";
                tuningSet("herd.count", Math.round(v));
            } else {
                return "error unknown setting: " + (key === undefined ? "" : key);
            }
            applySettings();
            return "ok setting " + key;
        }
        // Any leaf of the tuning tree, by path -- the same tree a mod writes
        // through `goats.tuning.set`, so the console reaches every knob the game
        // has rather than the handful `setting` names. One argument reads, two
        // write.
        case "tune": {
            const path = parts[1];
            if (path === undefined) return "error tune expects <path> [value]";
            try {
                if (parts[2] === undefined) return "ok " + JSON.stringify(tuningGet(path));
                const value = ctlArg(parts, 2);
                if (value === null) return "error tune " + path + " expects a number";
                return "ok tune " + path + " " + ctlRound(tuningSet(path, value));
            } catch (error) {
                return "error " + (error && error.message ? error.message : String(error));
            }
        }
        case "ui": {
            const screen = parts[1];
            if (screen === undefined) return "ok " + uiScreen;
            if (screen !== "hud" && screen !== "main" && screen !== "settings" && screen !== "keymap" && screen !== "mods") {
                return "error ui expects hud|main|settings|keymap|mods";
            }
            uiScreen = screen;
            return "ok ui " + uiScreen;
        }

        // ---- console (M9) ------------------------------------------------
        case "console": {
            const action = parts[1];
            if (action === "open") {
                if (!consoleOpen) consoleToggle();
                return "ok console open";
            }
            if (action === "close") {
                consoleClose();
                return "ok console close";
            }
            if (action === "toggle") {
                consoleToggle();
                return "ok console " + (consoleOpen ? "open" : "close");
            }
            if (action === "say") {
                consoleSubmit(parts.slice(2).join(" "));
                return "ok console say";
            }
            return "ok " + JSON.stringify({
                open: consoleOpen,
                input: consoleInput,
                caret: consoleCaret,
                history: consoleHistory,
                lines: consoleLines.map(function (line) { return line.kind + ": " + line.text; })
            });
        }

        // ---- net (M10) ---------------------------------------------------
        case "host":
            if (parts.length < 2) {
                consoleAsk("Username?", function (answer) { return netHost(["host", answer]); });
                return "ok name?";
            }
            return netHost(parts);
        case "connect":
        case "join": {
            // The consent flag may sit anywhere after the verb (`netJoinArgs`, in
            // net.js), so the name cannot be counted off the raw parts: with the
            // flag in hand, `connect T --pull` still needs a username.
            const args = netJoinArgs(parts);
            if (args.ticket === "") return "error connect expects a ticket";
            if (args.name === undefined) {
                const ask = ["connect", args.ticket].concat(args.pull ? [NET_PULL_FLAG] : []);
                consoleAsk("Username?", function (answer) { return netJoin(ask.concat([answer])); });
                return "ok name?";
            }
            return netJoin(parts);
        }
        case "leave":
        case "disconnect":
            return netLeave();
        case "who":
            if (!netInSession()) return "error not in a session";
            return "ok " + JSON.stringify(netStatus());
        case "net":
            return "ok " + JSON.stringify(netStatus());
        case "copy": {
            if (!consoleClipboardAvailable()) return "error clipboard unavailable";
            // With no argument, `copy` is the ticket -- the one thing long enough
            // that it should never have to be typed.
            const text = parts.length > 1 ? parts.slice(1).join(" ") : netTicket;
            if (text === "") return "error nothing to copy";
            return consoleCopy(text) ? "ok copy" : "error clipboard unavailable";
        }
        case "say":
            return netSay(parts.slice(1).join(" "));
        case "msg":
        case "tell":
        case "whisper": {
            if (parts[1] === undefined) return "error msg expects a name";
            const body = parts.slice(2).join(" ");
            if (body === "") return "error msg expects a message";
            // A whisper is just a chat line with a leading `@name`, which is the
            // one form the server routes for both sides.
            return netSay("@" + parts[1] + " " + body);
        }

        // ---- goat state --------------------------------------------------
        case "jump":
            if (mode === "dead") return "error cannot jump while dead";
            if (mode === "sleep") return "error cannot jump while asleep";
            startJump(ctlHeldMove(), ctlHeldGait());
            return "ok jump";
        case "sleep":
            if (mode === "dead") return "error cannot sleep while dead";
            if (mode === "sleep") return "error already asleep";
            startSleep();
            return "ok sleep";
        case "wake":
            if (mode !== "sleep") return "error not asleep";
            wakeUp();
            return "ok wake";
        case "restart":
            restart();
            return "ok restart";
        case "kill":
            if (mode === "dead") return "error already dead";
            die();
            return "ok kill";
        case "health": {
            const value = ctlArg(parts, 1);
            if (value === null) return "error health expects a number";
            stats.health = clamp(value, 0, TUNING.stats.max);
            return "ok health " + ctlRound(stats.health);
        }
        case "energy": {
            const value = ctlArg(parts, 1);
            if (value === null) return "error energy expects a number";
            stats.energy = clamp(value, 0, TUNING.stats.max);
            exhausted = stats.energy <= 0;
            return "ok energy " + ctlRound(stats.energy);
        }
        case "heal":
            stats.health = TUNING.stats.max;
            stats.energy = TUNING.stats.max;
            exhausted = false;
            return "ok heal";

        // ---- food --------------------------------------------------------
        case "grass": {
            const range = ctlArg(parts, 1) || 60;
            const t = nearestTuft(goat.px, goat.pz, range);
            if (t === null) return "ok null";
            return "ok " + JSON.stringify({
                x: ctlRound(t.x),
                z: ctlRound(t.z),
                dist: ctlRound(Math.sqrt(t.d2)),
                inReach: t.d2 <= TUNING.food.eatRange * TUNING.food.eatRange,
                key: tuftKey(t.cx, t.cz)
            });
        }
        // The devices around the goat (explosions.js): mines and trapped tufts, their
        // distance, and whether the device moved there rather than being part of the
        // field's own derivation. A debugging tool, the answer to "was that thing
        // actually there?", and the shape a mod's mine detector reads.
        case "traps": {
            const range = ctlArg(parts, 1) || 30;
            const near = sceneTraps(goat.px, goat.pz, range);
            const rows = (list) => list.map((d) => ({
                x: ctlRound(d.x),
                z: ctlRound(d.z),
                dist: ctlRound(d.dist),
                moved: d.moved,
                key: d.key
            }));
            return "ok " + JSON.stringify({
                range: range,
                mines: rows(near.mines),
                traps: rows(near.traps),
                spent: sceneExplosions().spent,
                moved: sceneExplosions().moved,
                pending: sceneExplosions().pending
            });
        }
        // The craters the ground is carrying (explosions.js): where, how wide, how deep
        // right now and how far through its heal -- the devices' aftermath, and the
        // other half of what a mod's mine detector would want to read.
        case "craters": {
            const range = ctlArg(parts, 1) || 30;
            const all = sceneCraters();
            const range2 = range * range;
            const near = [];
            for (let i = 0; i < all.length; i++) {
                const c = all[i];
                const dx = c.x - goat.px;
                const dz = c.z - goat.pz;
                const d2 = dx * dx + dz * dz;
                if (d2 > range2) continue;
                near.push({
                    x: ctlRound(c.x),
                    z: ctlRound(c.z),
                    r: ctlRound(c.r),
                    depth: ctlRound(c.depth),
                    age: ctlRound(c.age),
                    heal: ctlRound(c.heal),
                    dist: ctlRound(Math.sqrt(d2))
                });
            }
            return "ok " + JSON.stringify({ range: range, craters: near, live: all.length });
        }
        // The frame-cost benchmark (goat.js): `perf` prints the phase breakdown
        // gathered since the last print, `perf on` logs it every 240 frames,
        // `perf probe` measures one JS->native call and one `rl` property read.
        case "perf": {
            const side = parts[1];
            if (side === "on") {
                PERF.on = true;
                PERF.acc = {};
                PERF.frames = 0;
                return "ok perf on";
            }
            if (side === "off") {
                PERF.on = false;
                return "ok perf off";
            }
            if (side === "probe") {
                const p = perfProbe();
                return "ok " + JSON.stringify({
                    callNs: ctlRound(p.callNs),
                    propNs: ctlRound(p.propNs),
                    jsNs: ctlRound(p.jsNs),
                    arithNs: ctlRound(p.arithNs),
                    pureNs: ctlRound(p.pureNs),
                    fps: rl.getFPS()
                });
            }
            if (side !== undefined) return "error perf expects on|off|probe";
            perfLog();
            return "ok perf logged";
        }
        case "eat": {
            const t = nearestTuft(goat.px, goat.pz, TUNING.food.eatRange);
            if (t === null) return "error no grass in reach";
            startEat(t);
            return "ok eat";
        }

        // ---- movement ----------------------------------------------------
        case "walk":
        case "trot":
        case "run":
        case "back":
        case "stop":
            ctlSetGait(command);
            return "ok " + command;
        case "turn":
            ctlRelease(rl.KEY_A);
            ctlRelease(rl.KEY_D);
            if (parts[1] === "left") ctlHeld[rl.KEY_A] = true;
            else if (parts[1] === "right") ctlHeld[rl.KEY_D] = true;
            else if (parts[1] !== "stop") return "error turn expects left|right|stop";
            return "ok turn " + (parts[1] || "stop");
        case "yaw": {
            const degrees = ctlArg(parts, 1);
            if (degrees === null) return "error yaw expects degrees";
            goat.yaw = degrees * Math.PI / 180;
            return "ok yaw " + ctlRound(goat.yaw);
        }
        case "pos": {
            const x = ctlArg(parts, 1);
            const z = ctlArg(parts, 2);
            if (x === null || z === null) return "error pos expects <x> <z>";
            goat.px = x;
            goat.pz = z;
            return "ok pos " + ctlRound(goat.px) + " " + ctlRound(goat.pz);
        }
        case "phase": {
            const value = ctlArg(parts, 1);
            if (value === null) return "error phase expects a number";
            goat.phase = ((value % 1) + 1) % 1;
            return "ok phase " + ctlRound(goat.phase);
        }

        // ---- toggles -----------------------------------------------------
        case "pause":
            paused = true;
            ctlStep = 0;
            return "ok pause";
        case "resume":
            paused = false;
            ctlStep = 0;
            return "ok resume";
        case "step": {
            const count = ctlArg(parts, 1);
            if (count === null || count < 1) return "error step expects a positive frame count";
            paused = false;
            ctlStep = Math.floor(count);
            return "ok step " + ctlStep;
        }
        case "lighting": {
            if (litShader < 0) return "error lighting unavailable";
            useLighting = ctlToggle(useLighting, parts[1]);
            if (haveModel) rl.setModelShader(model, modelShaderFor(model, useLighting ? litShader : -1));
            setBotsShader(useLighting ? litShader : -1);
            setTerrainShader(useLighting ? litShader : -1);
            return "ok lighting " + (useLighting ? "on" : "off");
        }
        case "shadows": {
            const name = parts[1] || "off";
            if (name === "map" && !shadowMapReady) return "error shadow map unavailable";
            if (name === "planar" && shadowShader < 0) return "error planar shadow unavailable";
            if (CTL_SHADOWS[name] === undefined) return "error shadows expects map|planar|off";
            shadowMode = CTL_SHADOWS[name];
            return "ok shadows " + name;
        }
        case "sky":
            if (skyShader < 0) return "error sky shader unavailable";
            useSkyShader = ctlToggle(useSkyShader, parts[1]);
            return "ok sky " + (useSkyShader ? "on" : "off");
        case "mute":
            setMuted(ctlToggle(muted, parts[1]));
            return "ok mute " + (muted ? "on" : "off");

        // ---- mods --------------------------------------------------------
        case "mod":
            return modCommand(parts);

        // ---- host --------------------------------------------------------
        case "screenshot":
            if (parts.length < 2) return "error screenshot expects a path";
            rl.takeScreenshot(parts.slice(1).join(" "));
            return "ok screenshot";
        case "quit":
            ctlQuit = true;
            return "ok quit";
        default: {
            // A mod's registered command, or a `command` observer, gets first
            // refusal on anything that is not a built-in -- built-ins always win.
            const handled = modHandleCommand(command, parts, line);
            if (handled !== null) return handled;
            // In a session, anything that is not a command is something to say --
            // that is what makes the console a chat box. Offline it stays an
            // error, so a typo is still caught rather than broadcast.
            if (netInSession()) return netSay(line);
            return "error unknown command: " + command;
        }
    }
}
