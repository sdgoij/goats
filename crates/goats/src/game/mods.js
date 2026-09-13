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
// `goats` is the global a mod writes against. M14b gives it identity, logging
// and the lifecycle; the event/command/registry surface is M14c. A mod's entry
// is wrapped by the host as `(function (goats) { ... })(goats.begin(id))`, so a
// reload gets a fresh scope and every handle knows which mod it belongs to.

const MOD_API = 1;
const GAME_VERSION = "0.1.0";

// The table the host pushed. Metadata only; `enabled`/`loaded`/`failed` are
// live scene state the host does not need back.
let MODS = [];
let modsFrozen = false;
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
    return "ok";
}

// The host reports whether a mod's entry loaded. A failure is named rather than
// silently dropped, so the console can explain it.
function sceneModResult(id, ok, error) {
    const meta = modFind(id);
    if (meta === null) return "error unknown mod";
    meta.loaded = ok === true;
    meta.failed = ok !== true;
    meta.error = ok === true ? "" : String(error);
    if (meta.failed) console.log("mods: " + meta.id + " failed: " + meta.error);
    return "ok";
}

// The host unloaded a mod's instance (a disable, or the first half of a reload).
function sceneModEnd(id) {
    modInstances.delete(id);
    const meta = modFind(id);
    if (meta !== null) meta.loaded = false;
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

// ---- the `goats` API (identity + lifecycle) ------------------------------

function modLog(id, level, args) {
    const message = Array.prototype.join.call(args, " ");
    const tag = "[mod:" + id + "] " + message;
    if (level === "warn" && typeof console.warn === "function") console.warn(tag);
    else if (level === "error" && typeof console.error === "function") console.error(tag);
    else console.log(tag);
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

// The asset slots a mod filled, resolved to the opaque names the host
// registered. This is the only route from a mod to an asset's bytes.
function modAssets(meta) {
    return {
        slots: function () {
            return Object.keys(meta.assets);
        },
        get: function (slot) {
            const value = meta.assets[slot];
            if (value === undefined) return undefined;
            return Array.isArray(value) ? value[0] : value;
        },
        all: function (slot) {
            const value = meta.assets[slot];
            return value === undefined ? [] : Array.isArray(value) ? value.slice() : [value];
        },
    };
}

// Start a mod instance. The host's wrapper calls this as `goats.begin(id)`; the
// returned handle is what the entry sees as `goats`.
function goatsBegin(id) {
    const meta = modFind(id);
    if (meta === null) throw new Error("mods: unknown mod '" + id + "'");
    const handle = {
        api: MOD_API,
        game: GAME_VERSION,
        mod: { id: meta.id, name: meta.name, version: meta.version, side: meta.side },
        log: function () { modLog(meta.id, "log", arguments); },
        warn: function () { modLog(meta.id, "warn", arguments); },
        error: function () { modLog(meta.id, "error", arguments); },
        fail: function (message) { return modFail(meta.id, message); },
        mods: goatsMods,
        assets: modAssets(meta),
        frozen: function () { return modsFrozen; },
    };
    modInstances.set(meta.id, handle);
    meta.enabled = true;
    meta.loaded = true;
    meta.failed = false;
    meta.error = "";
    return handle;
}

// Tear a mod instance down. M14c adds the hook/command unsubscription here.
function goatsEnd(id) {
    if (!modInstances.has(id)) return "error mod not loaded";
    modInstances.delete(id);
    const meta = modFind(id);
    if (meta !== null) meta.loaded = false;
    return "ok";
}

// Close registration. M14c rejects a late `on`/`command`/`register` here.
function goatsFreeze() {
    modsFrozen = true;
    return "ok";
}

// Mark a mod failed from inside its own code or a handler.
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
    log: function () { modLog("-", "log", arguments); },
    warn: function () { modLog("-", "warn", arguments); },
    error: function () { modLog("-", "error", arguments); },
};

// ---- the `mod` console verb ----------------------------------------------

function modQueue(type, id) {
    modOutbox.push(JSON.stringify({ type: type, id: id }));
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
        });
    }
    if (verb === "enable" || verb === "disable" || verb === "reload") {
        const id = parts[2];
        if (id === undefined) return "error mod " + verb + " expects an id";
        const meta = modFind(id);
        if (meta === null) return "error unknown mod: " + id;
        if (verb === "enable") {
            meta.enabled = true;
            meta.failed = false;
            meta.error = "";
        } else if (verb === "disable") {
            meta.enabled = false;
            meta.loaded = false;
        } else {
            meta.failed = false;
            meta.error = "";
        }
        modQueue(verb, id);
        return "ok mod " + verb + " " + id;
    }
    return "error mod expects list|info|key|enable|disable|reload";
}
