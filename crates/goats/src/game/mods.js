// Part 15/15 of the goat scene: the mod table and the `goats` API.
// ---- mods -----------------------------------------------------------------
//
// The host is the only side that touches the disk. It discovers mods, reads
// their manifests, entries and assets, and registers the assets with the engine
// under opaque names, so nothing here ever sees a path. This part is the scene
// end:
//
//   sceneMods(json)      the host pushes the metadata table (once, at startup)
//   sceneModResult(...)  the host reports whether an entry loaded
//   sceneModEnd(id)      the host unloaded a mod (disable/reload)
//   sceneModFreeze()     the host closed registration
//   sceneModDrain()      the scene's queued enable/disable/reload intents
//
// `goats` is the global a mod writes against. A mod's entry is wrapped by the
// host as `(function (goats) { ... })(goats.begin(id))`, so a reload gets a
// fresh scope and every handle knows which mod it belongs to.
//
// Registration (events, commands) closes at `goats.freeze()`, which the host
// calls once every entry has run. A reload re-opens the window for exactly the
// mod being reloaded, which is why `goats.begin` marks the current entry open
// and `sceneModResult` closes it again.

const MOD_API = 1;
const GAME_VERSION = "0.1.0";

// The table the host pushed. Metadata only; `enabled`/`loaded`/`failed` are
// live scene state the host does not need back.
let MODS = [];
let modsFrozen = false;
// The id whose entry is executing right now, if any. Registration is allowed
// for it even after the freeze, so a reload can re-register.
let modOpenFor = null;
// id -> the per-mod `goats` handle while its entry is loaded.
const modInstances = new Map();
// Intents the scene wants the host to perform, drained once a frame.
const modOutbox = [];

function modFind(id) {
    for (let i = 0; i < MODS.length; i++) {
        if (MODS[i].id === id) return MODS[i];
    }
    return null;
}

function modEntry(meta) {
    return {
        id: String(meta.id),
        name: meta.name === undefined ? String(meta.id) : String(meta.name),
        version: meta.version === undefined ? "" : String(meta.version),
        api: Number(meta.api),
        side: meta.side === "world" ? "world" : "client",
        description: meta.description === undefined ? "" : String(meta.description),
        enabled: meta.enabled !== false,
        loaded: false,
        failed: false,
        error: "",
        assets: meta.assets === undefined ? {} : meta.assets,
        tuning: meta.tuning === undefined || meta.tuning === null ? null : meta.tuning,
        hash: meta.hash === undefined ? "" : String(meta.hash),
    };
}

// Install the host's metadata table. Called once, before any entry runs.
function sceneMods(json) {
    let table;
    try {
        table = JSON.parse(String(json));
    } catch (error) {
        console.log("mods: unreadable table: " + String(error));
        return "error unreadable mod table";
    }
    MODS = [];
    if (Array.isArray(table)) {
        for (let i = 0; i < table.length; i++) MODS.push(modEntry(table[i]));
    }
    // A mod's declared assets re-point the slots it filled, in load order, so
    // the last mod wins. This is what lets a data-only pack replace a built-in.
    for (let i = 0; i < MODS.length; i++) {
        const declared = MODS[i].assets;
        const slots = Object.keys(declared);
        for (let j = 0; j < slots.length; j++) {
            ASSET_SLOTS[slots[j]] = declared[slots[j]];
        }
    }
    // A mod's `tuning.json` lands before any entry runs, so the entry reads the
    // values it declared. Every leaf is validated by `tuningMerge`; a typo is a
    // warning, not a failure, so the rest of the tree still applies.
    for (let i = 0; i < MODS.length; i++) {
        if (MODS[i].tuning === null) continue;
        try {
            tuningMerge(MODS[i].tuning);
        } catch (error) {
            console.log("mods: " + MODS[i].id + " tuning: " + String(error));
        }
    }
    return "ok";
}

// The host reports whether a mod's entry loaded. A failure is named rather than
// silently dropped, so the console can explain it.
function sceneModResult(id, ok, error) {
    modOpenFor = null;
    const meta = modFind(id);
    if (meta === null) return "error unknown mod";
    meta.loaded = ok === true;
    meta.failed = ok !== true;
    meta.error = ok === true ? "" : String(error);
    if (meta.failed) {
        console.log("mods: " + meta.id + " failed: " + meta.error);
    } else {
        modEmit("load", modInfo(meta));
    }
    return "ok";
}

// The host unloaded a mod's instance (a disable, or the first half of a reload).
function sceneModEnd(id) {
    if (modInstances.has(id)) goatsEnd(id);
    const meta = modFind(id);
    if (meta !== null) meta.loaded = false;
    return "ok";
}

// Re-apply a mod's `tuning.json` after the host re-read it from disk (a reload,
// or the file watcher). `sceneMods` applies it at load; this is the same merge,
// for a tree that changed. A typo warns rather than failing.
function sceneModTuning(id, json) {
    const meta = modFind(id);
    if (meta === null) return "error unknown mod: " + id;
    let tree;
    try {
        tree = JSON.parse(String(json));
    } catch (error) {
        return "error tuning: " + String(error);
    }
    meta.tuning = tree;
    try {
        tuningMerge(tree);
    } catch (error) {
        console.log("mods: " + id + " tuning: " + String(error));
    }
    return "ok";
}

// The host closed registration once every entry had its chance to register.
function sceneModFreeze() {
    modsFrozen = true;
    return "ok";
}

// The queued intents, one JSON object per line; the host clears them by calling
// this, exactly like `sceneNetDrain`.
function sceneModDrain() {
    if (modOutbox.length === 0) return "";
    const text = modOutbox.join("\n");
    modOutbox.length = 0;
    return text;
}

// ---- events ---------------------------------------------------------------
//
// `event -> [{ id, fn }]`, in registration order. An event with no subscribers
// costs one Map lookup, so the frame loop can emit freely.

const modHooks = new Map();

function modRegistrationAllowed(id) {
    return !modsFrozen || modOpenFor === id;
}

function modOn(id, event, fn) {
    if (typeof fn !== "function") throw new Error("goats.on: handler must be a function");
    if (!modRegistrationAllowed(id)) throw new Error("goats.on: registration is closed");
    const name = String(event);
    const list = modHooks.get(name) || [];
    const entry = { id: id, fn: fn };
    list.push(entry);
    modHooks.set(name, list);
    return function () {
        const at = list.indexOf(entry);
        if (at >= 0) list.splice(at, 1);
    };
}

function modEmit(event) {
    const list = modHooks.get(event);
    if (list === undefined || list.length === 0) return;
    const args = Array.prototype.slice.call(arguments, 1);
    const snapshot = list.slice();   // a handler may unsubscribe while we run
    for (let i = 0; i < snapshot.length; i++) {
        try {
            snapshot[i].fn.apply(null, args);
        } catch (error) {
            console.log("mods: '" + snapshot[i].id + "' " + event + " handler threw: " + String(error));
        }
    }
}

// Fire an event to one mod's handlers only (used by the unload path).
function modEmitFor(id, event) {
    const list = modHooks.get(event);
    if (list === undefined) return;
    const args = Array.prototype.slice.call(arguments, 2);
    const snapshot = list.slice();
    for (let i = 0; i < snapshot.length; i++) {
        if (snapshot[i].id !== id) continue;
        try {
            snapshot[i].fn.apply(null, args);
        } catch (error) {
            console.log("mods: '" + id + "' " + event + " handler threw: " + String(error));
        }
    }
}

function modDropHooks(id) {
    for (const list of modHooks.values()) {
        for (let i = list.length - 1; i >= 0; i--) {
            if (list[i].id === id) list.splice(i, 1);
        }
    }
}

// ---- commands -------------------------------------------------------------

// Built-ins always win: a mod extends the vocabulary, it does not shadow it.
const MOD_RESERVED = new Set([
    "help", "ping", "state", "stats", "time", "weather", "bots", "camera",
    "features", "fps", "settings", "setting", "ui", "console", "mod",
    "jump", "sleep", "wake", "restart", "kill", "health", "energy", "heal",
    "eat", "grass", "walk", "trot", "run", "back", "stop", "turn", "yaw",
    "pos", "phase", "pause", "resume", "step", "lighting", "shadows", "sky",
    "mute", "screenshot", "quit", "host", "connect", "leave", "who", "net",
    "copy", "say", "msg",
]);

const modCommands = new Map();   // name -> { id, fn }

function modCommandRegister(id, name, fn) {
    if (typeof name !== "string" || name === "") throw new Error("goats.command: a name is required");
    if (typeof fn !== "function") throw new Error("goats.command: a handler is required");
    if (MOD_RESERVED.has(name)) {
        throw new Error("goats.command: '" + name + "' is a built-in command");
    }
    if (modCommands.has(name) && modCommands.get(name).id !== id) {
        throw new Error("goats.command: '" + name + "' is already registered");
    }
    if (!modRegistrationAllowed(id)) throw new Error("goats.command: registration is closed");
    modCommands.set(name, { id: id, fn: fn });
}

function modDropCommands(id) {
    for (const [name, entry] of modCommands) {
        if (entry.id === id) modCommands.delete(name);
    }
}

// Consults mod commands and `command` observers. Returns a reply string to
// consume the line, or null to let the caller fall through (chat/error).
function modHandleCommand(name, parts, raw) {
    const registered = modCommands.get(name);
    if (registered !== undefined) {
        let reply;
        try {
            reply = registered.fn(parts, raw);
        } catch (error) {
            return "error " + name + ": " + String(error);
        }
        return reply === undefined || reply === null ? "" : String(reply);
    }
    const list = modHooks.get("command");
    if (list === undefined || list.length === 0) return null;
    const snapshot = list.slice();
    for (let i = 0; i < snapshot.length; i++) {
        let reply;
        try {
            reply = snapshot[i].fn(raw, parts);
        } catch (error) {
            console.log("mods: '" + snapshot[i].id + "' command handler threw: " + String(error));
            continue;
        }
        if (reply !== undefined && reply !== null && reply !== false) return String(reply);
    }
    return null;
}

// ---- logging --------------------------------------------------------------

function modLog(id, level, args) {
    const message = Array.prototype.join.call(args, " ");
    const tag = "[mod:" + id + "] " + message;
    if (level === "warn" && typeof console.warn === "function") console.warn(tag);
    else if (level === "error" && typeof console.error === "function") console.error(tag);
    else console.log(tag);
}

function modInfo(meta) {
    return { id: meta.id, name: meta.name, version: meta.version, side: meta.side };
}

function goatsMods() {
    return MODS.map(function (meta) {
        return {
            id: meta.id,
            name: meta.name,
            version: meta.version,
            api: meta.api,
            side: meta.side,
            description: meta.description,
            enabled: meta.enabled,
            loaded: meta.loaded,
            failed: meta.failed,
            error: meta.error,
        };
    });
}

// ---- accessors ------------------------------------------------------------
//
// Thin, documented wrappers over the scene's own globals; the values are read
// (or written) live, so a mod sees the same state the frame loop does.

const goatsPlayer = {
    state: function () {
        return {
            mode: mode,
            health: stats.health,
            energy: stats.energy,
            exhausted: exhausted,
            satiety: satiety,
            x: goat.px,
            y: goat.py,
            z: goat.pz,
            yaw: goat.yaw,
            phase: goat.phase,
            speed: curSpeed,
            clip: curClipName,
        };
    },
    teleport: function (x, z) {
        goat.px = Number(x);
        goat.pz = Number(z);
    },
    face: function (yaw) {
        goat.yaw = Number(yaw);
    },
    giveEnergy: function (amount) {
        stats.energy = clamp(stats.energy + Number(amount), 0, TUNING.stats.max);
        return stats.energy;
    },
    giveHealth: function (amount) {
        stats.health = clamp(stats.health + Number(amount), 0, TUNING.stats.max);
        return stats.health;
    },
    // Only the states a script may enter: jump and dead are the simulation's.
    setMode: function (next) {
        if (next === "sleep") {
            startSleep();
            return true;
        }
        if (next === "idle" || next === "walk" || next === "trot" || next === "run") {
            if (mode === "dead" || mode === "jump" || mode === "eat") return false;
            mode = next;
            return true;
        }
        return false;
    },
    restart: function () {
        restart();
    },
};

const goatsCamera = {
    get: function () {
        return { yaw: camYaw, pitch: camPitch, dist: camDist };
    },
    set: function (options) {
        if (options === null || typeof options !== "object") return;
        if (typeof options.yaw === "number") camYaw = options.yaw;
        if (typeof options.pitch === "number") camPitch = clamp(options.pitch, 0.08, 1.35);
        if (typeof options.dist === "number") {
            camDist = clamp(options.dist, TUNING.camera.minDist, TUNING.camera.maxDist);
        }
    },
};

const goatsWorld = {
    time: function () { return worldTime; },
    // A client in a session does not own the clock or the weather; the call is
    // safe but reports that it could not take effect.
    setTime: function (hours) {
        if (!netWeatherLocal()) return false;
        worldTime = ((Number(hours) % 24) + 24) % 24;
        return true;
    },
    weather: function () {
        return {
            kind: weatherKind,
            cloudiness: cloudiness,
            rain: rainAmount,
            wind: windSway,
            speed: weatherSpeed,
        };
    },
    setWeather: function (kind) {
        if (!netWeatherLocal()) return false;
        if (WEATHER_STATES[kind] === undefined) return false;
        const previous = weatherKind;
        weatherKind = kind;
        weatherTimer = TUNING.weather.hold[kind][0];
        modEmit("weather", kind, previous);
        return true;
    },
    wind: function () {
        return { x: windX, z: windZ, sway: windSway };
    },
    terrainHeight: function (x, z) { return terrainHeight(x, z); },
};

function modBotHandle(b) {
    return {
        x: b.x,
        z: b.z,
        yaw: b.yaw,
        mode: b.mode,
        satiety: b.satiety,
        zoomies: function (seconds) {
            b.zoom = Number(seconds === undefined ? 3 : seconds);
            b.mode = "run";
        },
        startle: function () {
            b.mode = "run";
            b.timer = 0.2;
        },
        teleport: function (x, z) { b.x = Number(x); b.z = Number(z); },
        face: function (yaw) { b.yaw = Number(yaw); },
    };
}

const goatsBots = {
    count: function () { return BOTS.length; },
    setCount: function (n) { return tuningSet("herd.count", n); },
    list: function () { return BOTS.map(modBotHandle); },
    get: function (index) {
        const b = BOTS[index];
        return b === undefined ? null : modBotHandle(b);
    },
};

const goatsSettings = {
    get: function () {
        return {
            bgm: SETTINGS.bgm,
            sfx: SETTINGS.sfx,
            light: SETTINGS.light,
            shadow: SETTINGS.shadow,
            sky: SETTINGS.sky,
            cloud: SETTINGS.cloud,
            fullscreen: SETTINGS.fullscreen,
            herd: TUNING.herd.count,
        };
    },
    set: function (options) {
        if (options === null || typeof options !== "object") return;
        const keys = ["bgm", "sfx", "light", "shadow", "sky", "cloud", "fullscreen"];
        for (let i = 0; i < keys.length; i++) {
            if (options[keys[i]] !== undefined) SETTINGS[keys[i]] = options[keys[i]];
        }
        if (options.herd !== undefined) tuningSet("herd.count", options.herd);
        applySettings();
    },
};

const goatsTuning = {
    get: function (path) { return tuningGet(path); },
    set: function (path, value) { return tuningSet(path, value); },
    merge: function (object) { tuningMerge(object); },
};

const goatsNet = {
    mode: function () { return netMode; },
    inSession: function () { return netInSession(); },
    isHost: function () { return netMode === "host"; },
    localWorld: function () { return netWorldLocal(); },
    name: function () { return netName; },
    roster: function () { return netRoster.slice(); },
    say: function (text) { return netSay(text); },
};

// The asset slots a mod may read and override. The opaque names come from the
// host's table; a mod never sees a path. `override` re-points a built-in slot
// at one of them, before the freeze.
function modAssetsFor(id, meta) {
    return {
        slots: function () { return Object.keys(ASSET_SLOTS); },
        get: function (slot) {
            const value = meta.assets[slot];
            if (value !== undefined) return Array.isArray(value) ? value[0] : value;
            return ASSET_SLOTS[slot];
        },
        all: function (slot) {
            const value = meta.assets[slot];
            if (value !== undefined) return Array.isArray(value) ? value.slice() : [value];
            return assetList(slot);
        },
        override: function (slot, name) { return modAssetOverride(id, slot, name); },
    };
}

// ---- registries -----------------------------------------------------------
//
// Content a mod adds before the freeze: new bot archetypes, a gait override,
// and an asset slot. All three are pre-freeze, because the loaders run after
// the entries do.

function modBotsFor(id) {
    return {
        count: goatsBots.count,
        setCount: goatsBots.setCount,
        list: goatsBots.list,
        get: goatsBots.get,
        register: function (name, spec) { return modBotRegister(id, name, spec); },
    };
}

function modClipsFor(id) {
    return {
        register: function (role, options) { return modClipRegister(id, role, options); },
    };
}

function modBotRegister(id, key, spec) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.bots.register: registration is closed");
    if (spec === null || typeof spec !== "object") throw new Error("goats.bots.register: a spec is required");
    const coat = Array.isArray(spec.coat) && spec.coat.length === 3 ? spec.coat.slice() : [200, 190, 180];
    const name = typeof spec.name === "string" && spec.name !== "" ? spec.name
        : typeof key === "string" && key !== "" ? key : id;
    TUNING.herd.spec.push({
        coat: coat,
        scale: typeof spec.scale === "number" ? spec.scale : 1,
        bold: typeof spec.bold === "number" ? spec.bold : 1,
        lazy: typeof spec.lazy === "number" ? spec.lazy : 0.5,
        name: name,
    });
    return TUNING.herd.spec.length;
}

function modClipRegister(id, role, options) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.clips.register: registration is closed");
    if (role !== "walk" && role !== "trot" && role !== "run") {
        throw new Error("goats.clips.register: only walk, trot and run have a gait");
    }
    if (options !== null && typeof options === "object" && options.asset !== undefined) {
        throw new Error("goats.clips.register: an asset clip is not supported; point the model.goat slot at it");
    }
    if (options !== null && typeof options === "object" && options.gait !== undefined) {
        if (options.gait.stride !== undefined) tuningSet("gait." + role + ".stride", options.gait.stride);
        if (options.gait.duty !== undefined) tuningSet("gait." + role + ".duty", options.gait.duty);
    }
    return true;
}

function modAssetOverride(id, slot, name) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.assets.override: registration is closed");
    if (typeof slot !== "string" || slot === "") throw new Error("goats.assets.override: a slot is required");
    if (name === undefined) throw new Error("goats.assets.override: an asset name is required");
    ASSET_SLOTS[slot] = name;
    return true;
}

// ---- world extension (M14d2) ----------------------------------------------
//
// A `side: "world"` mod may own a seeded PRNG stream and publish state into the
// world snapshot. Streams are re-derived from the session seed on every peer so
// they agree, and the state travels in the snapshot too, so a client that joins
// mid-session continues rather than replaying from zero.

const modStreams = new Map();   // "<id>:<name>" -> { seed, state }
const modWorldExts = new Map(); // extension id -> { id, publish, apply }

function modWorldOnly(id, what) {
    const meta = modFind(id);
    if (meta === null || meta.side !== "world") {
        throw new Error("goats." + what + ": only a side:\"world\" mod may do this");
    }
}

function modHashKey(key) {
    let hash = 2166136261;
    for (let i = 0; i < key.length; i++) {
        hash ^= key.charCodeAt(i);
        hash = (hash * 16777619) >>> 0;
    }
    return hash >>> 0;
}

function modStreamNext(key) {
    const stream = modStreams.get(key);
    if (stream === undefined) return 0;
    let s = stream.state;
    s ^= s << 13;
    s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5;
    s >>>= 0;
    stream.state = s;
    return s / 4294967296;
}

function modRegisterStream(id, name, seed) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.world.registerStream: registration is closed");
    modWorldOnly(id, "world.registerStream");
    const key = id + ":" + String(name);
    const initial = (((Number(seed) | 0) || (0x9e3779b9 ^ modHashKey(key))) || 1) >>> 0;
    modStreams.set(key, { seed: initial, state: initial });
    return function () { return modStreamNext(key); };
}

function modRng(id, name) {
    const key = id + ":" + String(name);
    return function () { return modStreamNext(key); };
}

// Derive every stream from the session seed, the way the scene's own streams
// are derived -- hard to predict how much it matters, but the same seed gives
// the same streams on every peer. The value is not used directly; the draw
// keeps them from moving in lockstep.
function modSeedStreams(seed) {
    let s = (seed | 0) || 1;
    const next = function () {
        s ^= s << 13;
        s >>>= 0;
        s ^= s >>> 17;
        s ^= s << 5;
        s >>>= 0;
        return s || 1;
    };
    for (const stream of modStreams.values()) {
        stream.state = (stream.seed ^ next()) || 1;
    }
}

function modStreamStates() {
    const out = {};
    for (const [key, stream] of modStreams) out[key] = stream.state >>> 0;
    return out;
}

function modAdoptStreams(states) {
    if (states === null || typeof states !== "object") return;
    const keys = Object.keys(states);
    for (let i = 0; i < keys.length; i++) {
        const stream = modStreams.get(keys[i]);
        if (stream !== undefined) stream.state = Number(states[keys[i]]) >>> 0;
    }
}

function modExtend(id, extensionId, handlers) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.world.extend: registration is closed");
    modWorldOnly(id, "world.extend");
    if (handlers === null || typeof handlers !== "object") {
        throw new Error("goats.world.extend: handlers are required");
    }
    modWorldExts.set(String(extensionId), {
        id: id,
        publish: typeof handlers.publish === "function" ? handlers.publish : null,
        apply: typeof handlers.apply === "function" ? handlers.apply : null,
    });
}

function modDropWorld(id) {
    for (const key of Array.from(modStreams.keys())) {
        if (key.indexOf(id + ":") === 0) modStreams.delete(key);
    }
    for (const [key, ext] of Array.from(modWorldExts)) {
        if (ext.id === id) modWorldExts.delete(key);
    }
}

// The host's contribution to the world snapshot: every world mod's stream
// states and whatever it publishes. Only the host builds this.
function sceneWorldMods() {
    const data = {};
    for (const [id, ext] of modWorldExts) {
        if (ext.publish === null) continue;
        try {
            data[id] = ext.publish();
        } catch (error) {
            console.log("mods: '" + id + "' publish threw: " + String(error));
        }
    }
    return { streams: modStreamStates(), data: data };
}

// A client applies the host's contribution.
function sceneApplyWorldMods(mods) {
    if (mods === null || typeof mods !== "object") return;
    modAdoptStreams(mods.streams);
    const data = mods.data;
    if (data === null || typeof data !== "object") return;
    const ids = Object.keys(data);
    for (let i = 0; i < ids.length; i++) {
        const ext = modWorldExts.get(ids[i]);
        if (ext === undefined || ext.apply === null) continue;
        try {
            ext.apply(data[ids[i]]);
        } catch (error) {
            console.log("mods: '" + ids[i] + "' apply threw: " + String(error));
        }
    }
}

function modWorldFor(id) {
    return {
        time: goatsWorld.time,
        setTime: goatsWorld.setTime,
        weather: goatsWorld.weather,
        setWeather: goatsWorld.setWeather,
        wind: goatsWorld.wind,
        terrainHeight: goatsWorld.terrainHeight,
        registerStream: function (name, seed) { return modRegisterStream(id, name, seed); },
        extend: function (extensionId, handlers) { return modExtend(id, extensionId, handlers); },
    };
}

// ---- lifecycle ------------------------------------------------------------

function goatsBegin(id) {
    const meta = modFind(id);
    if (meta === null) throw new Error("mods: unknown mod '" + id + "'");
    // A reload re-enters here: clear what the previous instance left behind.
    modDropHooks(id);
    modDropCommands(id);
    modOpenFor = id;
    const handle = {
        api: MOD_API,
        game: GAME_VERSION,
        mod: modInfo(meta),
        on: function (event, fn) { return modOn(id, event, fn); },
        command: function (name, fn) { return modCommandRegister(id, name, fn); },
        run: function (text) { return modRun(text); },
        log: function () { modLog(id, "log", arguments); },
        warn: function () { modLog(id, "warn", arguments); },
        error: function () { modLog(id, "error", arguments); },
        fail: function (message) { return modFail(id, message); },
        mods: goatsMods,
        frozen: function () { return modsFrozen; },
        player: goatsPlayer,
        camera: goatsCamera,
        world: modWorldFor(id),
        rng: function (name) { return modRng(id, name); },
        bots: modBotsFor(id),
        clips: modClipsFor(id),
        settings: goatsSettings,
        tuning: goatsTuning,
        net: goatsNet,
        assets: modAssetsFor(id, meta),
    };
    modInstances.set(id, handle);
    meta.enabled = true;
    meta.loaded = true;
    meta.failed = false;
    meta.error = "";
    return handle;
}

function goatsEnd(id) {
    if (!modInstances.has(id)) return "error mod not loaded";
    modEmitFor(id, "shutdown");
    modDropHooks(id);
    modDropCommands(id);
    modDropWorld(id);
    modInstances.delete(id);
    const meta = modFind(id);
    if (meta !== null) meta.loaded = false;
    return "ok";
}

function goatsFreeze() {
    modsFrozen = true;
    return "ok";
}

function modFail(id, message) {
    const meta = modFind(id);
    if (meta !== null) {
        meta.failed = true;
        meta.loaded = false;
        meta.error = String(message);
    }
    console.log("mods: " + id + " failed: " + String(message));
    return "ok";
}

// Dispatch a line through the scene's own command dispatcher, so a mod command
// can call a built-in or another mod's command. Depth-limited: a command that
// runs itself would otherwise hang the frame.
let modRunDepth = 0;
function modRun(text) {
    if (modRunDepth >= 8) return "error command recursion";
    modRunDepth += 1;
    try {
        return sceneCommand(String(text));
    } finally {
        modRunDepth -= 1;
    }
}

// The global. The host wraps an entry with `goats.begin(id)`, so a mod's own
// `goats` is the per-mod handle; this base object is for the console and the
// host.
const goats = {
    api: MOD_API,
    game: GAME_VERSION,
    mod: null,
    begin: goatsBegin,
    end: goatsEnd,
    freeze: goatsFreeze,
    frozen: function () { return modsFrozen; },
    mods: goatsMods,
    run: function (text) { return modRun(text); },
    log: function () { modLog("-", "log", arguments); },
    warn: function () { modLog("-", "warn", arguments); },
    error: function () { modLog("-", "error", arguments); },
    player: goatsPlayer,
    camera: goatsCamera,
    world: goatsWorld,
    bots: modBotsFor("-"),
    clips: modClipsFor("-"),
    settings: goatsSettings,
    tuning: goatsTuning,
    net: goatsNet,
    assets: modAssetsFor("-", { assets: {} }),
};

// ---- the `mod` console verb ----------------------------------------------

function modQueue(type, id) {
    modOutbox.push(JSON.stringify({ type: type, id: id }));
}

// Toggle a mod for this session. A world mod may not change mid-session: the
// host fixed the compatibility set at join time, so changing it would desync.
function modSetEnabled(id, enabled) {
    if (id === undefined) return "error mod " + (enabled ? "enable" : "disable") + " expects an id";
    const meta = modFind(id);
    if (meta === null) return "error unknown mod: " + id;
    if (netInSession() && meta.side === "world") {
        return "error " + id + " is a world mod; leave the session first";
    }
    if (enabled) {
        meta.enabled = true;
        meta.failed = false;
        meta.error = "";
        modQueue("enable", id);
        return "ok mod enable " + id;
    }
    meta.enabled = false;
    meta.loaded = false;
    modQueue("disable", id);
    return "ok mod disable " + id;
}

function modCommand(parts) {
    const verb = parts[1] === undefined ? "list" : parts[1];
    if (verb === "" || verb === "list") {
        return "ok " + JSON.stringify(goatsMods());
    }
    if (verb === "key") {
        const world = MODS.filter(function (meta) { return meta.side === "world"; })
            .sort(function (a, b) { return a.id < b.id ? -1 : a.id > b.id ? 1 : 0; })
            .map(function (meta) { return meta.id + "@" + meta.version + "#" + meta.hash; });
        return "ok " + JSON.stringify(world);
    }
    if (verb === "info") {
        const id = parts[2];
        if (id === undefined) return "error mod info expects an id";
        const meta = modFind(id);
        if (meta === null) return "error unknown mod: " + id;
        return "ok " + JSON.stringify({
            id: meta.id,
            name: meta.name,
            version: meta.version,
            api: meta.api,
            side: meta.side,
            description: meta.description,
            enabled: meta.enabled,
            loaded: meta.loaded,
            failed: meta.failed,
            error: meta.error,
            hash: meta.hash,
            assets: Object.keys(meta.assets),
            commands: modCommandsOf(meta.id),
        });
    }
    if (verb === "enable") return modSetEnabled(parts[2], true);
    if (verb === "disable") return modSetEnabled(parts[2], false);
    if (verb === "reload") {
        const id = parts[2];
        if (id === undefined) return "error mod reload expects an id";
        const meta = modFind(id);
        if (meta === null) return "error unknown mod: " + id;
        meta.failed = false;
        meta.error = "";
        modQueue("reload", id);
        return "ok mod reload " + id;
    }
    return "error mod expects list|info|key|enable|disable|reload";
}

function modCommandsOf(id) {
    const out = [];
    for (const [name, entry] of modCommands) {
        if (entry.id === id) out.push(name);
    }
    return out.sort();
}
