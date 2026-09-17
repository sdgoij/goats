// Part 15/16 of the goat scene: the mod table and the `goats` API.
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
        adds: meta.assetAdds === undefined ? {} : meta.assetAdds,
        tuning: meta.tuning === undefined || meta.tuning === null ? null : meta.tuning,
        hash: meta.hash === undefined ? "" : String(meta.hash),
        wasm: meta.wasm === undefined || meta.wasm === null ? null : String(meta.wasm),
    };
}

// Join `name` to a slot's list, so a mod with one more bleat than the game has adds
// to the six instead of silencing five of them. The list is *copied* before it
// grows: the built-ins are the baseline every rebuild starts from, and pushing onto
// one in place would leak the mod's file into the game's own table for the rest of
// the session. A slot the game does not have at all is created as a list, so a mod
// can build its own multi-file slot; a slot that holds a single file (a track, a
// bed, a model) has no list to join and is refused.
function modSlotJoin(slot, name) {
    const current = ASSET_SLOTS[slot];
    if (current === undefined) {
        ASSET_SLOTS[slot] = [name];
        return true;
    }
    if (!Array.isArray(current)) return false;
    const list = current.slice();
    list.push(name);
    ASSET_SLOTS[slot] = list;
    return true;
}

// Point every slot at what the *enabled* mods ask for, rebuilt from the built-ins
// each time so the result does not depend on the order toggles happened in.
//
// This is why `mod disable example` gives the game its own bleats back rather than
// only dropping the mod's code: the slots a mod filled are part of its enablement,
// and a mod may name slots the game does not have at all (a model of its own), so
// those are cleared when nothing enabled claims them. Every fill is logged, because
// a slot is read once at load and the ones that make a noise are otherwise only
// discovered by ear, hours later.
function modApplyAssets() {
    const mine = Object.keys(ASSET_SLOTS);
    for (let i = 0; i < mine.length; i++) {
        if (ASSET_DEFAULTS[mine[i]] === undefined) delete ASSET_SLOTS[mine[i]];
        else ASSET_SLOTS[mine[i]] = ASSET_DEFAULTS[mine[i]];
    }
    for (let i = 0; i < MODS.length; i++) {
        if (!MODS[i].enabled) continue;
        // Fills first, then adds: a mod that names a whole list sets the slot, and
        // one that only wants its sound in with the others joins whatever is there
        // when its turn comes -- including what an earlier mod installed.
        const declared = MODS[i].assets;
        const slots = Object.keys(declared);
        for (let j = 0; j < slots.length; j++) {
            ASSET_SLOTS[slots[j]] = declared[slots[j]];
            console.log("mods: " + MODS[i].id + " fills " + slots[j]);
        }
        const added = MODS[i].adds;
        const into = Object.keys(added);
        for (let j = 0; j < into.length; j++) {
            const names = assetNames(added[into[j]]);
            for (let k = 0; k < names.length; k++) {
                if (modSlotJoin(into[j], names[k])) {
                    console.log("mods: " + MODS[i].id + " adds " + into[j]);
                } else {
                    console.log("mods: " + MODS[i].id + " cannot join " + into[j] +
                        ": it holds a single file");
                }
            }
        }
    }
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
    modApplyAssets();
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
    // A compiled mod's instance goes with the mod: `disable` and the first half
    // of a reload both land here, and a live module that outlived its mod would
    // keep being driven.
    modWasmLive.delete(id);
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

// Add one mod after the freeze (M18d): a world mod pulled from a host while the
// game is already running. The metadata, its asset slots and its tuning land
// exactly as `sceneMods` would have applied them at boot, and the host evaluates
// the new entry next. Registration stays closed for everything else -- the entry
// runs with `modOpenFor` set, which is the same window a reload gets.
function sceneModAdd(json) {
    let meta;
    try {
        meta = JSON.parse(String(json));
    } catch (error) {
        return "error unreadable mod metadata";
    }
    const entry = modEntry(meta);
    if (modFind(entry.id) !== null) return "error already loaded: " + entry.id;
    MODS.push(entry);
    // The per-mod half of `sceneMods`, in the same order: asset slots first, so
    // the entry resolves the names it declared, then its tuning tree. The effects
    // are re-read because a mod pulled in mid-session lands *after* the audio was
    // loaded, and a slot that is never read again is a slot that does nothing.
    modApplyAssets();
    reloadSfx();
    if (entry.tuning !== null) {
        try {
            tuningMerge(entry.tuning);
        } catch (error) {
            console.log("mods: " + entry.id + " tuning: " + String(error));
        }
    }
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
            wasm: modWasmDescribe(meta.id),
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
        add: function (slot, name) { return modAssetAdd(id, slot, name); },
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
    // Recorded on the entry as well as written now: `modApplyAssets` rebuilds the
    // table from what the enabled mods ask for, and this is a mod asking for a slot
    // -- from code rather than from its manifest, which is the only difference.
    const meta = modFind(id);
    if (meta !== null) meta.assets[slot] = name;
    ASSET_SLOTS[slot] = name;
    return true;
}

// Join one of the mod's assets to a slot's list instead of replacing it -- the code
// half of the manifest's `assetAdds`, and the thing to reach for when a mod has one
// more sound than the game does. Recorded on the entry for the same reason
// `override` is, and refused by the same rule `modSlotJoin` applies.
function modAssetAdd(id, slot, name) {
    if (!modRegistrationAllowed(id)) throw new Error("goats.assets.add: registration is closed");
    if (typeof slot !== "string" || slot === "") throw new Error("goats.assets.add: a slot is required");
    if (name === undefined) throw new Error("goats.assets.add: an asset name is required");
    if (!modSlotJoin(slot, name)) {
        throw new Error("goats.assets.add: " + slot + " holds a single file, so there is no list to join");
    }
    const meta = modFind(id);
    if (meta !== null) {
        const have = meta.adds[slot];
        if (have === undefined) meta.adds[slot] = [name];
        else if (Array.isArray(have)) have.push(name);
        else meta.adds[slot] = [have, name];
    }
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
    // A compiled world mod's streams live inside its module, not in
    // `modStreams`, so they are re-derived here from the same seed and the same
    // generator -- one draw per stream, so no two streams move in lockstep.
    for (const live of modWasmLive.values()) {
        if (live.side !== "world") continue;
        for (let i = 0; i < MOD_WASM_STREAMS; i++) {
            live.rng[i] = (live.rngSeed[i] ^ next()) || 1;
        }
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

// The Rust host's contribution (M17b): the server and a solo client host drive
// compiled world mods from Rust and push their published state here each frame,
// as `{ id: base64 }`. `sceneWorldMods` folds it in below; nothing in the JS
// driver owns it.
let rustModPublished = {};
function sceneSetWasmPublished(json) {
    try {
        rustModPublished = JSON.parse(String(json));
    } catch (error) {
        console.log("mods: sceneSetWasmPublished: " + String(error));
    }
    return "ok";
}

// The Rust host's HUD contribution: a client compiled mod pushes its `goats_hud`
// bar fill here each frame, as `{ id: fill }`. The built-in HUD reads it back;
// nothing else in the JS driver owns it.
let rustModHud = {};
function sceneSetWasmHud(json) {
    try {
        rustModHud = JSON.parse(String(json));
    } catch (error) {
        console.log("mods: sceneSetWasmHud: " + String(error));
    }
    return "ok";
}

// The first client compiled mod's HUD bar fill (0..1), or null when none is
// running. The built-in HUD uses this so a compiled mod can contribute a bar.
function modWasmHudFill() {
    for (const key in rustModHud) {
        const value = Number(rustModHud[key]);
        if (isFinite(value)) return value;
    }
    return null;
}

// The host's contribution to the world mods' datagram: every world mod's stream
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
    // A compiled world mod's state is the bytes it pushed through `publish`.
    for (const [id, live] of modWasmLive) {
        if (live.side !== "world" || live.published === null) continue;
        data[id] = modWasmB64Encode(live.published);
    }
    // A Rust-hosted compiled world mod's state (M17b), pushed in by the host.
    const wasmIds = Object.keys(rustModPublished);
    for (let i = 0; i < wasmIds.length; i++) {
        data[wasmIds[i]] = rustModPublished[wasmIds[i]];
    }
    return { streams: modStreamStates(), data: data };
}

// Whether there is any world-mod state to send at all: a registered extension or
// a seeded stream. Nothing else about a mod is the host's to broadcast, so this
// is what keeps a vanilla session from sending an empty datagram ten times a
// second.
function modWorldActive() {
    if (modWorldExts.size > 0 || modStreams.size > 0) return true;
    for (const live of modWasmLive.values()) {
        if (live.side === "world" && live.published !== null) return true;
    }
    return Object.keys(rustModPublished).length > 0;
}

// How many rows and how many numbers a row a mod may publish through
// `publishRows`. A structural guard, not the budget: the datagram holds ~1200
// bytes and the transport refuses anything larger (logging the size), so the
// real limit is the byte count. This is what stops a runaway loop from building
// a megabyte before anyone notices.
const PUBLISH_ROWS_MAX = 64;
const PUBLISH_COLS_MAX = 8;
// The published state that earns a warning: half the datagram, which leaves no
// room for another mod's. It names the mod, which the datagram-level report
// cannot -- it sees only the whole.
const PUBLISH_WARN_BYTES = 600;

// The compact way to publish: rows of finite numbers.
//
// The transport carries a mod's payload as opaque JSON, so rows of short numbers
// are what keeps it small -- and rounding to three decimals is what makes them
// short. It also catches the value `JSON.stringify` would silently turn into
// `null`: a NaN or an infinity is a mod's bug, and it is thrown here where the
// log can name the mod rather than arriving at every peer as `null`.
function modPublishRows(id, rows) {
    if (!Array.isArray(rows)) throw new Error("publishRows: rows must be an array");
    if (rows.length > PUBLISH_ROWS_MAX) {
        throw new Error("publishRows: " + rows.length + " rows, at most " +
            PUBLISH_ROWS_MAX + " (a payload larger than the datagram is not sent)");
    }
    const out = [];
    for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        if (!Array.isArray(row)) throw new Error("publishRows: row " + i + " is not an array");
        if (row.length > PUBLISH_COLS_MAX) {
            throw new Error("publishRows: row " + i + " has " + row.length +
                " numbers, at most " + PUBLISH_COLS_MAX);
        }
        const rounded = [];
        for (let j = 0; j < row.length; j++) {
            const value = row[j];
            if (typeof value !== "number" || !isFinite(value)) {
                throw new Error("publishRows: row " + i + ", column " + j + " is " + value +
                    ", and every value must be a finite number");
            }
            rounded.push(Math.round(value * 1000) / 1000);
        }
        out.push(rounded);
    }
    const size = JSON.stringify(out).length;
    if (size > PUBLISH_WARN_BYTES) {
        console.log("mods: '" + id + "' publishes " + size + " bytes of rows; keep a " +
            "published table under " + PUBLISH_WARN_BYTES + " so it fits the datagram");
    }
    return out;
}

// A client applies the host's contribution.
function sceneApplyWorldMods(mods) {
    if (mods === null || typeof mods !== "object") return;
    modAdoptStreams(mods.streams);
    const data = mods.data;
    if (data === null || typeof data !== "object") return;
    const ids = Object.keys(data);
    for (let i = 0; i < ids.length; i++) {
        const key = ids[i];
        const ext = modWorldExts.get(key);
        if (ext !== undefined) {
            if (ext.apply === null) continue;
            try {
                ext.apply(data[key]);
            } catch (error) {
                console.log("mods: '" + key + "' apply threw: " + String(error));
            }
            continue;
        }
        if (modWasmLive.has(key)) {
            modWasmApply(key, data[key]);
            continue;
        }
        // A Rust-hosted compiled world mod (M17b): the host owns the instance.
        if (typeof sceneWasmApply === "function") {
            try {
                sceneWasmApply(key, data[key]);
            } catch (error) {
                console.log("mods: '" + key + "' wasm apply threw: " + String(error));
            }
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
        publishRows: function (rows) { return modPublishRows(id, rows); },
    };
}

// The explosives a mod can see and set off (M19g). Per mod, because `armed` is a
// request the mod owns: it is handed back when the mod is unloaded, and two mods can
// want different things without one of them winning by being loaded last.
//
// `blast` goes through the scene's own `blast`, which means the same things happen as
// for a mine -- the crater, the damage, the flash, the sound, the mod event and, in a
// session, the report (M19e's path). It is deliberately not a *new* kind of bang on the
// wire: `BlastKind` is a closed enum, so a mod's device reports as the core kind it
// behaves like, and a mod that wants its own state on the wire rides `world.extend`
// instead (which is what the birds' flock already does).
function modExplosionsFor(id) {
    return {
        blast: function (x, z, kind) { return modBlast(id, x, z, kind); },
        traps: function (x, z, range) { return sceneTraps(x, z, range); },
        armed: function (on) { return modCoreArmed(id, on); },
    };
}

// ---- entities -------------------------------------------------------------
//
// What one mod may know about another's: a mod *offers* the entities it simulates
// as a live callback, and any mod may ask what is near a point. It is the one seam
// that lets two mods collide with each other -- the birds' flock and the fatguy's
// run are the pair it was added for -- and it is deliberately not a scene-level
// entity system: nothing here knows what a bird is, and a mod that wants to be
// avoidable does not have to declare what it is beyond where it is.
//
// A row is `[x, y, z, r]`: a position and a radius, in the world's units. The
// callback runs on every query (the flock moves), so a mod that caches the rows it
// offers collides with where things *were*. Rows that are not four finite numbers
// are skipped rather than throwing at the asker, and a callback that throws costs
// its own mod's entities for that query only.

const modEntityOffers = new Map();   // "<mod id>:<name>" -> { id, fn }

function modOfferEntities(id, name, fn) {
    if (typeof fn !== "function") {
        throw new Error("goats.entities.offer: a callback returning rows is required");
    }
    modEntityOffers.set(id + ":" + String(name), { id: id, fn: fn });
}

function modDropEntities(id) {
    for (const key of Array.from(modEntityOffers.keys())) {
        if (key.indexOf(id + ":") === 0) modEntityOffers.delete(key);
    }
}

// Every offered entity within `range` of `(x, z)`, as `{ from, x, y, z, r, d }`.
// The range is measured in the ground plane, which is the plane the scene resolves
// its own collisions in; `y` comes back so the asker can tell a bird standing on
// the ground from one in the air.
function modEntitiesNear(x, z, range) {
    const found = [];
    const r2 = range * range;
    for (const [key, offer] of modEntityOffers) {
        let rows;
        try {
            rows = offer.fn();
        } catch (error) {
            console.log("mods: '" + offer.id + "' entities.offer threw: " + String(error));
            continue;
        }
        if (!Array.isArray(rows)) continue;
        for (let i = 0; i < rows.length; i++) {
            const row = rows[i];
            if (!Array.isArray(row) || row.length < 4) continue;
            const ex = Number(row[0]);
            const ey = Number(row[1]);
            const ez = Number(row[2]);
            const er = Number(row[3]);
            if (!isFinite(ex) || !isFinite(ey) || !isFinite(ez) || !isFinite(er)) continue;
            const dx = ex - x;
            const dz = ez - z;
            const d2 = dx * dx + dz * dz;
            if (d2 > r2) continue;
            found.push({ from: key, x: ex, y: ey, z: ez, r: er, d: Math.sqrt(d2) });
        }
    }
    return found;
}

function modEntitiesFor(id) {
    return {
        offer: function (name, fn) { return modOfferEntities(id, name, fn); },
        near: function (x, z, range) {
            const fx = Number(x);
            const fz = Number(z);
            const fr = Number(range);
            if (!isFinite(fx) || !isFinite(fz) || !isFinite(fr) || fr < 0) {
                throw new Error("goats.entities.near: x, z and a range are required");
            }
            return modEntitiesNear(fx, fz, fr);
        },
    };
}

// Where a mod's bang lands on the wire: the *cell* it happened in, which is the key
// space every other device uses (`tuftKey`). A bang in a cell that holds a core device
// therefore spends it on every peer as well -- the same rule a core bang follows, and
// the reason a mod's bang is worth reporting rather than applied locally: the ground,
// the devices and the herd are the host's, so a bang nobody else hears is a bang that
// did not happen.
function modBlast(id, x, z, kind) {
    const fx = Number(x);
    const fz = Number(z);
    if (!isFinite(fx) || !isFinite(fz)) throw new Error("goats.explosions.blast: x and z are required");
    const blastKind = kind === "trap" ? "trap" : "mine";
    const cx = Math.floor(fx / 2);
    const cz = Math.floor(fz / 2);
    // The device in this cell is spent *here* as well (M19g). Every other process spends
    // it from the key in the report, so the origin has to do the same or the cell stays
    // armed where the bang happened -- and whatever the mod sent over it trips the same
    // device again on the way back. `spendDevice` is also what moves the replacement in,
    // so the field drifts for a mod's bang exactly as it does for a goat's.
    spendDevice(blastKind, cx, cz);
    blast(blastKind, fx, fz, hash(fx * 7.1 + fz * 3.3), 0, tuftKey(cx, cz));
    return true;
}

// ---- lifecycle ------------------------------------------------------------

function goatsBegin(id) {
    const meta = modFind(id);
    if (meta === null) throw new Error("mods: unknown mod '" + id + "'");
    // A reload re-enters here: clear what the previous instance left behind.
    modDropHooks(id);
    modDropCommands(id);
    modDropEntities(id);
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
        explosions: modExplosionsFor(id),
        entities: modEntitiesFor(id),
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
    // Its offered entities go with it, for the same reason its handlers do: nothing
    // outside the mod is allowed to keep asking a body that has been unloaded where it
    // is (APIv1.md §4.16).
    modDropEntities(id);
    // And the field, if this mod had taken the core devices out of it (M19g).
    modCoreArmed(id, true);
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
    explosions: modExplosionsFor("-"),
    entities: modEntitiesFor("-"),
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
    // Whether the mod filled anything, decided before the flag moves. A toggle
    // re-points the slots it filled, and a `Sound` that has already been loaded
    // cannot be un-picked, so the effects are read again from the table -- that is
    // what makes the toggle mean something to the ear and not only to the code. A
    // slot that is not audio (a model) still only changes at the next start.
    const filled = Object.keys(meta.assets).length > 0 || Object.keys(meta.adds).length > 0;
    meta.enabled = enabled;
    if (enabled) {
        meta.failed = false;
        meta.error = "";
    } else {
        meta.loaded = false;
    }
    modApplyAssets();
    if (filled) reloadSfx();
    modQueue(enabled ? "enable" : "disable", id);
    return "ok mod " + (enabled ? "enable " : "disable ") + id;
}

// The compiled-mod view for `mod info`: the JS driver's instance if it owns one,
// else the Rust host's (M17b).
function modWasmInfo(id) {
    const live = modWasmDescribe(id);
    if (live !== null) return live;
    if (typeof sceneWasmDescribe === "function") {
        try {
            const value = sceneWasmDescribe(id);
            return value === "null" || value === "" ? null : JSON.parse(value);
        } catch (error) {
            console.log("mods: sceneWasmDescribe: " + String(error));
            return null;
        }
    }
    return null;
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
            assetAdds: Object.keys(meta.adds),
            commands: modCommandsOf(meta.id),
            wasm: modWasmInfo(meta.id),
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

// ---- compiled mods (M17a) -------------------------------------------------
//
// A mod may ship a WebAssembly module instead of an entry (`ABIv1.md`). The ABI
// is deliberately small: the module imports `goats.log` and `goats.rng`, exports
// `goats_abi`/`goats_alloc`/`goats_init`/`goats_update`, and every frame the host
// hands it one buffer of records in the module's own memory.
//
// This driver is *host* code, which is the point of the milestone: the mod ships
// only the module, and what it may do is exactly what the import object below
// contains. The host does not read the records to decide anything -- the four
// floats are the mod's own state, and this side only moves the bytes.
//
// The crossing is coarse on purpose: one call a frame amortises the boundary
// against the work. A mod that crossed once per record would be paying for the
// boundary rather than for its own simulation.

const MOD_WASM_ABI = 1;
const MOD_WASM_RECORDS = 6;
const MOD_WASM_RECORD_BYTES = 16;
const MOD_WASM_STREAMS = 8;

// The largest state a compiled mod may publish in one frame. A structural guard,
// not the budget: the datagram holds ~1200 bytes and the transport refuses
// anything larger, so this only stops a runaway `publish` from building a
// megabyte before anyone notices.
const MOD_WASM_PUBLISH_MAX = 1024;

// A compiled mod's state is opaque bytes and the mods datagram is JSON, so the
// bytes need a compact, deterministic, JSON-safe spelling. Base64 is that: 4/3
// the size, and it round-trips exactly.
const MOD_WASM_B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
function modWasmB64Encode(bytes) {
    let out = "";
    const len = bytes.length;
    for (let i = 0; i < len; i += 3) {
        const a = bytes[i];
        const b = i + 1 < len ? bytes[i + 1] : 0;
        const c = i + 2 < len ? bytes[i + 2] : 0;
        out += MOD_WASM_B64[a >> 2];
        out += MOD_WASM_B64[((a & 3) << 4) | (b >> 4)];
        out += i + 1 < len ? MOD_WASM_B64[((b & 15) << 2) | (c >> 6)] : "=";
        out += i + 2 < len ? MOD_WASM_B64[c & 63] : "=";
    }
    return out;
}
function modWasmB64Decode(text) {
    const rev = {};
    for (let i = 0; i < MOD_WASM_B64.length; i++) rev[MOD_WASM_B64[i]] = i;
    const clean = String(text).replace(/=+$/, "");
    const count = clean.length;
    const out = new Uint8Array((count * 3) >> 2);
    let acc = 0;
    let bits = 0;
    let j = 0;
    for (let i = 0; i < count; i++) {
        const v = rev[clean[i]];
        if (v === undefined) return null;
        acc = (acc << 6) | v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            out[j] = (acc >> bits) & 255;
            j += 1;
        }
    }
    return out;
}

// id -> the live module: { instance, ptr, abi, imports, frames, error, rng }.
const modWasmLive = new Map();

// What the module declared it wants, and how it has behaved. The console and the
// Mods screen read this; nothing in it is inferred.
function modWasmDescribe(id) {
    const live = modWasmLive.get(id);
    if (live === undefined) return null;
    return {
        abi: live.abi,
        imports: live.imports,
        frames: live.frames,
        ok: live.error === "",
        error: live.error,
        log: live.lastLog,
    };
}

// The host's side of the ABI, closed over the live state so that `log` can read
// the module's own memory -- the bytes are there, and this side holds the memory.
function modWasmImports(live) {
    const goats = {
        log: function (ptr, len) {
            const memory = live.instance === null ? null : live.instance.exports.memory;
            if (memory === null || memory === undefined) return;
            const bytes = new Uint8Array(memory.buffer);
            const at = Number(ptr) | 0;
            const count = Math.min(Number(len) | 0, 200);
            let text = "";
            for (let i = 0; i < count; i++) {
                const code = bytes[at + i];
                if (code === undefined) break;
                text += String.fromCharCode(code);
            }
            live.lastLog = text;
            console.log("mods: '" + live.id + "' wasm: " + text);
        },
        // Host-owned randomness: the module has no clock to read and no
        // entropy of its own, so every draw comes from here. The order of the
        // draws is what a mod has to keep stable; the generator is the host's.
        rng: function (stream) {
            const at = (Number(stream) | 0) % MOD_WASM_STREAMS;
            let s = live.rng[at < 0 ? at + MOD_WASM_STREAMS : at];
            s ^= s << 13;
            s >>>= 0;
            s ^= s >>> 17;
            s ^= s << 5;
            s >>>= 0;
            live.rng[at] = s;
            return s / 4294967296;
        },
        // The module pushes its state: the host copies the bytes out of the
        // module's memory and remembers them for the world-mod datagram. The
        // bytes are opaque; this side only moves them.
        publish: function (ptr, len) {
            const memory = live.instance === null ? null : live.instance.exports.memory;
            if (memory === null || memory === undefined) return -1;
            const at = Number(ptr) | 0;
            const count = Math.min(Math.max(Number(len) | 0, 0), MOD_WASM_PUBLISH_MAX);
            const view = new Uint8Array(memory.buffer);
            const out = new Uint8Array(count);
            for (let i = 0; i < count; i++) {
                const code = view[at + i];
                if (code === undefined) break;
                out[i] = code;
            }
            live.published = out;
            if (count > PUBLISH_WARN_BYTES) {
                console.log("mods: '" + live.id + "' publishes " + count +
                    " bytes of state; keep a world mod under " + PUBLISH_WARN_BYTES +
                    " so it fits the datagram");
            }
            return 0;
        },
    };
    // `goats.belly` is a client-local reading (ABIv1.md): granted only to a
    // `side: "client"` module, so a world module that asks for it fails to link.
    if (live.side === "client") {
        goats.belly = function () { return satiety; };
    }
    return { goats: goats };
}

// The host delivers a compiled mod: bytes, never a path. Called once per mod,
// after `sceneMods`, by whichever host is running the scene.
function sceneWasmModule(id, bytes) {
    const meta = modFind(id);
    if (meta === null) return "error unknown mod: " + id;
    if (modWasmLive.has(id)) return "error already delivered";

    let module;
    try {
        module = new WebAssembly.Module(bytes);
    } catch (error) {
        sceneModResult(id, false, "invalid module: " + String(error));
        return "error invalid module";
    }

    // A per-mod, per-stream base seed, so one compiled mod's draws cannot disturb
    // another's. The *current* stream is re-derived from the session seed in
    // `modSeedStreams` for a world mod; the base is the fixed, per-mod part.
    const seed = modHashKey("wasm:" + id) || 1;
    const rngSeed = [];
    for (let i = 0; i < MOD_WASM_STREAMS; i++) {
        rngSeed.push(((seed ^ (i * 0x9e3779b9)) >>> 0) || 1);
    }
    const live = {
        id: id,
        side: meta.side,
        instance: null,
        ptr: 0,
        abi: 0,
        imports: [],
        frames: 0,
        error: "",
        lastLog: "",
        published: null,
        rngSeed: rngSeed,
        rng: rngSeed.slice(),
    };

    try {
        live.instance = new WebAssembly.Instance(module, modWasmImports(live));
    } catch (error) {
        // A capability the host does not grant fails here, before a line of the
        // mod's code runs: the import list is the API, and the linker enforces it.
        sceneModResult(id, false, "could not instantiate: " + String(error));
        return "error could not instantiate";
    }

    const exports = live.instance.exports;
    const abi = typeof exports.goats_abi === "function" ? exports.goats_abi() : 0;
    if (abi !== MOD_WASM_ABI) {
        // The module's own number, not the manifest's: it is what the code in
        // front of us was actually compiled against.
        sceneModResult(id, false, "compiled for ABI " + abi + ", this build is ABI " + MOD_WASM_ABI);
        return "error unsupported abi";
    }
    if (
        typeof exports.goats_alloc !== "function" ||
        typeof exports.goats_init !== "function" ||
        typeof exports.goats_update !== "function" ||
        exports.memory === undefined
    ) {
        sceneModResult(id, false, "incomplete module: needs goats_alloc, goats_init, goats_update and an exported memory");
        return "error incomplete module";
    }
    live.abi = abi;
    live.imports = WebAssembly.Module.imports(module).map(function (entry) {
        return entry.module + "." + entry.name;
    });

    live.ptr = exports.goats_alloc(MOD_WASM_RECORDS * MOD_WASM_RECORD_BYTES) | 0;
    // The host seeds the records once. What they mean is the mod's; this is so
    // the mod has something to compute with, laid out where the host reads the
    // results back.
    const view = new Float32Array(exports.memory.buffer);
    const base = live.ptr / 4;
    for (let i = 0; i < MOD_WASM_RECORDS; i++) {
        view[base + i * 4 + 0] = i * 0.6 - 1.5;
        view[base + i * 4 + 1] = 0;
        view[base + i * 4 + 2] = 0;
        view[base + i * 4 + 3] = 0;
    }

    modWasmLive.set(id, live);
    try {
        exports.goats_init(0);
    } catch (error) {
        live.error = String(error);
    }
    sceneModResult(id, live.error === "", live.error);
    return live.error === "" ? "ok" : "error init";
}

// One frame for every compiled mod. A trap is that mod's failure and nobody
// else's: it is reported once, the mod stops being driven, and the game runs on.
function modWasmTick(dt) {
    if (modWasmLive.size === 0) return;
    for (const live of modWasmLive.values()) {
        if (live.error !== "") continue;
        // A world mod runs only where the world is authoritative; a client that
        // mirrors does not simulate, exactly like a JS world mod. A client-side
        // mod is local and always runs.
        if (live.side === "world" && !netWorldLocal()) continue;
        try {
            live.instance.exports.goats_update(live.ptr, MOD_WASM_RECORDS, dt);
            live.frames += 1;
        } catch (error) {
            live.error = String(error);
            console.log("mods: '" + live.id + "' compiled update failed: " + live.error);
        }
    }
}

// The host's side of the world-mod apply for a compiled mod: decode a peer's
// published bytes, write them into the module's record buffer, and hand the
// module a call so it can react. A mirroring client never runs `goats_update`,
// so this is how its state moves; a module without `goats_apply` (a client mod,
// or an older world mod) simply has nothing to call.
function modWasmApply(id, encoded) {
    const live = modWasmLive.get(id);
    if (live === undefined || live.error !== "" || live.instance === null) return;
    const exports = live.instance.exports;
    if (typeof exports.goats_apply !== "function") return;
    const bytes = modWasmB64Decode(encoded);
    if (bytes === null) return;
    const view = new Uint8Array(exports.memory.buffer);
    const at = live.ptr;
    const count = Math.min(bytes.length, MOD_WASM_RECORDS * MOD_WASM_RECORD_BYTES);
    for (let i = 0; i < count; i++) view[at + i] = bytes[i];
    try {
        exports.goats_apply(at, count);
    } catch (error) {
        live.error = String(error);
        console.log("mods: '" + id + "' compiled apply failed: " + live.error);
    }
}

// One frame's worth of mod work: the `update` event, then the compiled mods.
// Everything that ticks per frame goes through here, so the game loop and the
// harness cannot drift on what a frame means.
function modFrameTick(dt) {
    modEmit("update", dt);
    modWasmTick(dt);
}
