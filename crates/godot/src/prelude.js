// The `goats` handle, as a mod sees it.
//
// This is the JavaScript facade the extension evaluates once, before any mod
// entry runs. It is deliberately thin: everything that needs to cross into
// native code or into GDScript is an `__`-prefixed capability the Rust side
// registers (`__goatsSnapshot`/`__goatsPush`, `__goatsCall`, `__goatsDraw`,
// `__goatsDraw3d`, `__goatsScreenW`/`__goatsScreenH`, `__goatsHasAsset`,
// `__goatsWorldTime`), and the rest is the shape a mod expects from `APIv1.md`
// section 4.
//
// The readable groups -- `player`, `camera`, `world`, `bots`, `settings`,
// `tuning`, `net` -- are all read out of one snapshot the core *pushes* each
// frame (`ModHost::push_world`). That is decision 3 of `godot/PORT.md` section 6
// carried out: the hot reads never touch the boundary, because the scene has
// already told the extension what they are, and no group needs its own crossing
// or its own signature. The one thing a push cannot answer -- a *function* of
// the world (`terrainHeight`) -- and every write go the other way through
// `__goatsCall`, which is the "callbacks for the rest" half of the same decision.
//
// Splitting it this way is the bridge design from `godot/PORT.md` section 6:
// the registries are a JS layer (as they are today, in the raylib client's
// `mods.js`), while reads of the world and draws through the engine are native
// calls -- and each of those is a place the design says to push a value or
// register a callback rather than reimplement the world in JavaScript.
//
// **No engine library is exposed here.** A mod draws through `goats.draw`
// (`APIv1.md` section 4.18) and never through `rl`: `rl` is raylib, so a mod that
// read it would be bound to the raylib client, and the port would have to
// emulate a C library to run it. What the port implements is the API's surface.

// The registry keeps one state per mod rather than one shared bag, because that
// is what `goats.begin(id)` means: `crates/mods` wraps every entry in
// `(function (goats) { ... })(goats.begin(id))`, so a mod's commands and hooks
// belong to the mod that registered them -- which is what lets the console name
// the owner and what makes a reload of one mod drop only its own.
if (typeof globalThis.goats === "undefined") {
    globalThis.goats = (function () {
        // For code evaluated without `begin` (a probe, a REPL line).
        const idle = { id: null, commands: {}, hooks: {} };

        // --- the pushed world ------------------------------------------------
        //
        // One snapshot arrives per frame (`ModHost::push_world`), and every readable
        // group below reads it. It is *parsed once per push and kept*, because a mod may
        // read several groups in a hook and `JSON.parse` of the whole world is the one
        // cost here: `__goatsPush` is the counter that says whether the cached parse is
        // still the frame's, so a frame's reads share one parse between them.

        let pushId = -1;
        let parsed = {};

        function snapshot() {
            const id = __goatsPush();
            if (id !== pushId) {
                pushId = id;
                parsed = parseSnapshot(__goatsSnapshot());
            }
            return parsed;
        }

        function parseSnapshot(text) {
            if (text === undefined || text === null || text === "") return {};
            try {
                const value = JSON.parse(text);
                return value !== null && typeof value === "object" ? value : {};
            } catch (error) {
                // A snapshot that will not parse is the host's bug, not a mod's: it is
                // named on the console rather than thrown into a mod's hook, so the frame
                // survives and the failure is visible.
                console.log("mods: the world snapshot did not parse: " + error);
                return {};
            }
        }

        /** One group of the pushed snapshot, or an empty object before the first push. */
        function group(name) {
            const value = snapshot()[name];
            return value !== null && typeof value === "object" ? value : {};
        }

        // A write the port cannot perform. The port's simulation is GDScript and the only
        // way to change it is a callback the scene has not built yet, so a write is refused
        // *loudly* rather than silently ignored -- `APIv1.md` section 7's isolation logs it
        // with the mod's id and the frame goes on, which is a failure a mod author can see
        // instead of a goat that quietly never teleports. The readable half of the same
        // member (if any) still works.
        function refuse(member) {
            return function () {
                throw new Error("goats." + member + ": this client has no write path to " +
                    "the scene yet; the readable surface is in and the writes are not");
            };
        }

        /**
         * A member that is a *question* rather than a value: `terrainHeight` today, and the
         * writes when they land. The scene's own `Callable` answers, through the same
         * `(name, args)` shape `__goatsDraw`'s records use -- `{"ok": ...}` or
         * `{"err": "..."}`, which this turns into a value or a thrown error.
         */
        function ask(name, args) {
            let answer = null;
            try {
                answer = JSON.parse(__goatsCall(name, JSON.stringify(args === undefined ? [] : args)));
            } catch (error) {
                answer = null;
            }
            if (answer === null || typeof answer !== "object") {
                throw new Error("goats." + name + ": the scene gave no answer");
            }
            if (typeof answer.err === "string") throw new Error(answer.err);
            return answer.ok;
        }

        // The `bots` handles, kept rather than rebuilt -- `mods.js`'s own decision, and for
        // its own reason: `list()` is the one read a mod calls in a loop, and a handle is an
        // object and four closures, so rebuilding one per bot per call is allocation the
        // frame does not need. Here the numbers are refreshed from the frame's snapshot on
        // every read; the verbs are refusals, because a client mirrors the herd rather than
        // owning it.
        const BOT_LIST = [];
        const BOT_VIEW = [];

        function botHandle(index) {
            let handle = BOT_VIEW[index];
            if (handle === undefined) {
                handle = BOT_VIEW[index] = {
                    id: index, x: 0, z: 0, yaw: 0, mode: "idle", satiety: 0,
                    zoomies: refuse("bots.get(" + index + ").zoomies"),
                    startle: refuse("bots.get(" + index + ").startle"),
                    teleport: refuse("bots.get(" + index + ").teleport"),
                    face: refuse("bots.get(" + index + ").face"),
                };
            }
            return handle;
        }

        /** The frame's bots array, or an empty one. */
        function botEntries() {
            const bots = snapshot().bots;
            return Array.isArray(bots) ? bots : [];
        }

        /** Refresh one handle from its entry. */
        function fillBot(index, entry) {
            const handle = botHandle(index);
            handle.id = typeof entry.id === "number" ? entry.id : index;
            handle.x = entry.x;
            handle.z = entry.z;
            handle.yaw = entry.yaw;
            handle.mode = entry.mode;
            handle.satiety = entry.satiety;
            return handle;
        }

        /** `tuningGet`: the value at a dotted path, or a thrown error for an unknown one. */
        function tuningAt(path) {
            const parts = String(path).split(".");
            let node = snapshot().tuning;
            for (let i = 0; i < parts.length; i++) {
                if (node === null || typeof node !== "object" ||
                        !Object.prototype.hasOwnProperty.call(node, parts[i])) {
                    throw new Error("tuning: unknown path '" + path + "'");
                }
                node = node[parts[i]];
            }
            return node;
        }

        // --- a mod's own geometry and images ---------------------------------
        //
        // `goats.gfx.mesh` / `texture` / `bind` (APIv1.md section 4.19) are the API's answer to
        // the engine's `makeModel`/`makeTexture`/`setModelTexture`: a mod builds its own shapes
        // and pictures and never reads an engine library, so each client renders them its own
        // way. This client keeps what the mod built and hands it to Godot when a draw asks for
        // it, which is the same division of labour `assets` has.
        //
        // The handle is minted here and the *data* is stored on the host, so a draw record stays
        // a handle and a transform rather than a mesh -- a `draw3d` hook that draws a
        // thousand-vertex mesh every frame must not ship a thousand vertices every frame.
        let handleSeq = 0;

        function store(kind, value) {
            const handle = kind + ":" + (handleSeq++);
            if (kind === "mesh") __goatsStoreMesh(handle, JSON.stringify(value));
            else __goatsStoreTexture(handle, JSON.stringify(value));
            return handle;
        }

        /** A flat number array with `stride` numbers per element, or null when it is not one. */
        function flat(value, stride) {
            if (!Array.isArray(value) || value.length === 0 || value.length % stride !== 0) {
                return null;
            }
            for (let i = 0; i < value.length; i++) {
                if (typeof value[i] !== "number") return null;
            }
            return value;
        }

        /**
         * An optional flat array: `undefined` when it was not given, the array when it was
         * and is well formed, `null` when it was given and is not -- so a mesh built with one
         * bad array is refused rather than silently drawn without it.
         */
        function optional(value, stride) {
            if (value === undefined || value === null) return undefined;
            return flat(value, stride);
        }

        /** A capability's JSON answer, or `fallback` when it is not one. */
        function parseJson(text, fallback) {
            if (typeof text !== "string" || text === "") return fallback;
            try {
                return JSON.parse(text);
            } catch (error) {
                return fallback;
            }
        }

        /**
         * Say something the way `goats.log`/`warn`/`error` say it: the arguments joined with a
         * space, and the level carried to whatever `console` the embedder wired.
         */
        function logAt(level, args) {
            const line = Array.prototype.join.call(args, " ");
            if (level === "warn" && typeof console.warn === "function") console.warn(line);
            else if (level === "error" && typeof console.error === "function") console.error(line);
            else console.log(line);
        }

        // --- the asset slots --------------------------------------------------
        //
        // `goats.assets` (`APIv1.md` section 4.11) is a *merge*, and it is done here because this
        // is the only place both halves are visible at once: the **built-in** slots are the
        // scene's (it owns the game's files, and `audio.gd`'s table is pushed each frame), and the
        // **declared** ones are the host's, in the mod table a mod can already read. Fills replace
        // and joins append, in load order, which is `modApplyAssets`'s own rule.
        //
        // The table holds the values **raw** -- a scalar for a single-file slot, a list for a
        // multi-file one -- and not normalised to lists, because that distinction is visible
        // through `get`: `modAssetsFor` (`mods.js`) answers a slot with what the slot holds, so
        // `get("model.goat")` is the name and `get("sfx.bleat")` is the list. `all` is the member
        // that normalises, and it keeps the same shape for a slot either half owns.
        let builtInValues = null;

        /** A slot value as a list: a mod may point a list slot at a single file. */
        function asList(value) {
            if (value === undefined || value === null) return [];
            return Array.isArray(value) ? value : [value];
        }

        /** The whole slot table: the built-ins, then every enabled mod's fills and joins. */
        function slotTable() {
            const table = {};
            const built = snapshot().assets;
            if (built !== null && typeof built === "object") {
                for (const slot in built) table[slot] = built[slot];
            }
            const mods = parseJson(__goatsMods(), []);
            for (let i = 0; i < mods.length; i++) {
                const row = mods[i];
                if (row === null || typeof row !== "object" || row.enabled === false) continue;
                // A fill replaces whatever the slot held, including a list -- which is why a fill
                // is *not* `asList`ed here and a join is: the reference assigns the declared value
                // straight into its table (`modApplyAssets`) and only ever appends through
                // `modSlotJoin`, which refuses a slot that holds a single file.
                const fills = row.assets === undefined ? {} : row.assets;
                for (const slot in fills) table[slot] = fills[slot];
                const joins = row.assetAdds === undefined ? {} : row.assetAdds;
                for (const slot in joins) {
                    if (table[slot] === undefined) table[slot] = [];
                    table[slot] = asList(table[slot]).concat(asList(joins[slot]));
                }
            }
            return table;
        }

        /**
         * The first name a value holds. Only a mod's **own** declaration goes through this: the
         * reference answers a declared list with its head (`Array.isArray(value) ? value[0] :
         * value`) and a table lookup with the value itself, and both are reproduced rather than
         * tidied, because a mod that reads a slot back has to see what the reference shows it.
         */
        function firstOf(value) {
            const list = asList(value);
            return list.length === 0 ? undefined : list[0];
        }

        /**
         * Whether a name is one of the *game's* own files rather than a mod's declared asset.
         * `gfx.model` and `sfx.load` resolve both, and the difference is only where the bytes come
         * from -- the host's registry or this build's `res://` (`APIv1.md` section 4.11).
         */
        function isBuiltIn(name) {
            if (builtInValues === null) {
                builtInValues = {};
                const built = snapshot().assets;
                if (built !== null && typeof built === "object") {
                    for (const slot in built) {
                        const list = asList(built[slot]);
                        for (let i = 0; i < list.length; i++) builtInValues[list[i]] = true;
                    }
                }
            }
            return builtInValues[name] === true;
        }

        /**
         * The `assets` group for one mod, or for nobody (`goats.assets` outside a `begin`). `get`
         * prefers **this mod's own** declared asset for the slot -- which is why the group is per
         * mod and not one shared object -- and falls back to the table.
         */
        function assetsFor(id) {
            const mine = {};
            const mods = parseJson(__goatsMods(), []);
            for (let i = 0; i < mods.length; i++) {
                if (mods[i] !== null && typeof mods[i] === "object" && mods[i].id === id) {
                    const fills = mods[i].assets === undefined ? {} : mods[i].assets;
                    for (const slot in fills) mine[slot] = fills[slot];
                }
            }
            return {
                slots: function () {
                    return Object.keys(slotTable());
                },
                get: function (slot) {
                    const declared = mine[slot];
                    if (declared !== undefined) return firstOf(declared);
                    return slotTable()[slot];
                },
                all: function (slot) {
                    if (mine[slot] !== undefined) return asList(mine[slot]).slice();
                    return asList(slotTable()[slot]);
                },
                override: refuse("assets.override"),
                add: refuse("assets.add"),
            };
        }

        // --- the entities one mod offers another -------------------------------
        //
        // `goats.entities` (`APIv1.md` section 4.16) is the one seam that lets two *mods* collide
        // with each other -- the flock and the fatguy's run are the pair it exists for -- and it is
        // done here for the reason `assets` is done here: the offers belong to mods, so the registry
        // that holds them has to live where the mods do. The query is the interesting half: it calls
        // one mod's callback from another mod's code, which is a crossing this prelude can make
        // without asking the host for anything, and it is deliberately *not* a scene-level entity
        // system -- a row is `[x, y, z, r]`, a position and a radius, and nothing here knows what a
        // bird is.
        const entityOffers = {};   // "<mod id>:<name>" -> { id, fn }, in offer order

        /** Every offered entity within `range` of `(x, z)` in the ground plane. */
        function entitiesNear(x, z, range) {
            const found = [];
            const r2 = range * range;
            const failed = [];
            for (const key in entityOffers) {
                const offer = entityOffers[key];
                const outcome = offeredRows(offer);
                if (outcome.bad !== undefined) {
                    failed.push(outcome.bad);
                    continue;
                }
                const rows = outcome.rows;
                if (!Array.isArray(rows)) continue;
                for (let i = 0; i < rows.length; i++) {
                    const row = rows[i];
                    // Rows are validated rather than trusted: one that is not four finite numbers is
                    // skipped, not thrown at an asker who did not write it.
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
            // The failures are said *here* rather than inside the `catch` above, and that is a rule
            // about this engine rather than a preference: Slag's `LeaveBlock` (`slag/crates/runtime/
            // src/ir.rs`) pops a scope environment the exception never pushed when a *host* call
            // (`console.log`, which re-enters Rust) happens inside a `catch` that caught a throw from
            // a nested call -- `SyntaxError: Environment stack underflow`, and the query's answer is
            // lost with it. Recording during and saying afterwards keeps the guarantee the `catch` is
            // for (`APIv1.md` section 7: the failure is named with its mod's id) without the host
            // call that trips it. `__fireHud`/`__fireDraw3d` should be read with this in mind.
            for (let i = 0; i < failed.length; i++) console.log(failed[i]);
            return found;
        }

        /**
         * A mod's offered rows, or `bad`: its message when the callback threw. It exists so the
         * `catch` above it holds nothing but the record -- see the note in `entitiesNear`.
         */
        function offeredRows(offer) {
            try {
                // The callback runs on *every* query, because what it offers moves; a mod that
                // caches its rows collides with where things were.
                return { rows: offer.fn() };
            } catch (error) {
                return { bad: "mods: '" + offer.id + "' entities.offer threw: " + String(error) };
            }
        }

        /**
         * The `entities` group for one mod, or for nobody (`goats.entities` outside a `begin`).
         * `offer` names the entities *this* mod simulates, so the name has to be namespaced to it --
         * which is why the group is per mod and not one shared object -- while `near` is the same for
         * every caller, because what is near a point does not depend on who asks.
         *
         * A mod's offers go when its handlers do in the reference client, from its unload path
         * (`goatsEnd`). This client has no unload yet -- no `modSetEnabled` and no reload -- so that
         * drop arrives with them rather than being half-built here.
         */
        function entitiesFor(id) {
            return {
                offer: function (name, fn) {
                    if (typeof fn !== "function") {
                        throw new Error(
                            "goats.entities.offer: a callback returning rows is required");
                    }
                    // A second offer under one name replaces the first, and keeps its place.
                    entityOffers[id + ":" + String(name)] = { id: id, fn: fn };
                },
                near: function (x, z, range) {
                    const fx = Number(x);
                    const fz = Number(z);
                    const fr = Number(range);
                    if (!isFinite(fx) || !isFinite(fz) || !isFinite(fr) || fr < 0) {
                        throw new Error("goats.entities.near: x, z and a range are required");
                    }
                    return entitiesNear(fx, fz, fr);
                },
            };
        }

        // The API major and the game's version (`APIv1.md` section 4.1). Read once, because they
        // are constants -- the host answers them from its own crate, so a prelude copy could not
        // drift from the contract the loader enforces.
        const IDENTITY = parseJson(__goatsIdentity(), { api: 1, game: "0.0.0" });

        return {
            /** id -> { id, commands, hooks }, in registration order. */
            __mods: {},
            /** The state `command`/`on` write to outside a `begin` scope. */
            __state: idle,

            /**
             * The API major and the game's version. Both are the *host's* (`APIv1.md` section
             * 4.1): a mod comparing `goats.api` against the major it was written for is asking
             * the thing that would have refused it at load.
             */
            api: IDENTITY.api,
            game: IDENTITY.game,
            /** This mod's info (`{id, name, version, side}`), set on the per-mod handle by
             * `begin`; `null` outside a mod's scope, which is what the reference client has. */
            mod: null,
            /**
             * The loaded mod table (`APIv1.md` section 4.1), as the Mods screen draws it -- the
             * host's own, so a mod reading it reads the same rows a player does.
             */
            mods: function () {
                return parseJson(__goatsMods(), []);
            },
            /**
             * Whether registration has closed. It never has in this client -- there is no
             * `goats.freeze()` to call -- so a mod that guards a late registration on it is told
             * the truth rather than a guess.
             */
            frozen: function () {
                return false;
            },

            /**
             * Say something on the console. The level is carried, because a warning is not the
             * same thing to a player as a log line.
             */
            log: function () {
                logAt("log", arguments);
            },
            warn: function () {
                logAt("warn", arguments);
            },
            error: function () {
                logAt("error", arguments);
            },

            /**
             * The per-mod handle. The loader calls this with the mod's id and
             * passes the result to the mod's entry as its `goats`.
             */
            begin: function (id) {
                const state = this.__mods[id] ||
                    (this.__mods[id] = { id: id, commands: {}, hooks: {} });
                // Inherits the surface, so `handle.command` is this function;
                // only the state is the mod's own.
                const handle = Object.create(this);
                handle.__state = state;
                // Its own identity, which is the one member a handle does not inherit: a mod
                // asking `goats.mod` is asking who *it* is (`APIv1.md` section 4.1).
                handle.mod = parseJson(__goatsModInfo(id), null);
                // ...and its own asset slots, for `get`'s reason: a mod's `get(slot)` prefers the
                // asset *it* declared for that slot (`APIv1.md` section 4.11).
                handle.assets = assetsFor(id);
                // ...and its own entity offers, for the same reason once more: `offer` names them
                // after the mod that made them (`APIv1.md` section 4.16).
                handle.entities = entitiesFor(id);
                return handle;
            },

            /**
             * Register a console verb. Built-in names are reserved, as they are
             * in the client, so a mod cannot shadow one.
             */
            command: function (name, fn) {
                this.__state.commands[name] = fn;
            },

            /**
             * Subscribe to an event. `"hud"` is the one wired so far; it
             * receives the screen size.
             */
            on: function (event, fn) {
                const state = this.__state;
                (state.hooks[event] || (state.hooks[event] = [])).push(fn);
            },

            world: {
                /**
                 * The in-game clock, in hours. A read of the world, so it
                 * crosses: the core pushes the value each frame and this reads
                 * the last one (PORT.md section 6, decision 3).
                 */
                time: function () {
                    return __goatsWorldTime();
                },
                /**
                 * `worldTime` is the core's, so a scene with no session runs it
                 * and a client follows the host. The port has no write path to
                 * the clock yet, and the API's own answer for a call that could
                 * not take effect is `false` -- which is what a client in a
                 * session gets here, so a mod that guards on it behaves the same
                 * either way (`APIv1.md` section 4.7).
                 */
                setTime: function () {
                    return false;
                },
                /** The weather machine's own values this frame. */
                weather: function () {
                    const w = group("weather");
                    return {
                        kind: w.kind,
                        cloudiness: w.cloudiness,
                        rain: w.rain,
                        wind: w.wind,
                        speed: w.speed,
                    };
                },
                /** `setWeather`, refused the same way and for the same reason `setTime` is. */
                setWeather: function () {
                    return false;
                },
                /** The wind the frame derived: the gust's direction and its sway share. */
                wind: function () {
                    const w = group("wind");
                    return { x: w.x, z: w.z, sway: w.sway };
                },
                /**
                 * The ground at `(x, z)` -- the *same* function the scene stands a
                 * goat on, craters and all, which is why it crosses rather than
                 * being a second heightfield built here.
                 */
                terrainHeight: function (x, z) {
                    return ask("world.terrainHeight", [Number(x), Number(z)]);
                },
            },

            /**
             * The player's goat (`APIv1.md` section 4.5). `state()` is a snapshot of
             * the frame the core pushed; every write is refused (see `refuse`).
             */
            player: {
                state: function () {
                    const p = group("player");
                    return {
                        mode: p.mode, health: p.health, energy: p.energy,
                        exhausted: p.exhausted, satiety: p.satiety,
                        x: p.x, y: p.y, z: p.z, yaw: p.yaw,
                        phase: p.phase, speed: p.speed, clip: p.clip,
                    };
                },
                teleport: refuse("player.teleport"),
                face: refuse("player.face"),
                giveEnergy: refuse("player.giveEnergy"),
                giveHealth: refuse("player.giveHealth"),
                setMode: refuse("player.setMode"),
                restart: refuse("player.restart"),
            },

            /**
             * The orbit camera (`APIv1.md` section 4.6). Cosmetic, and never part of the
             * compatibility set, which is why only the read is in.
             */
            camera: {
                get: function () {
                    const c = group("camera");
                    return { yaw: c.yaw, pitch: c.pitch, dist: c.dist };
                },
                set: refuse("camera.set"),
            },

            /**
             * The herd (`APIv1.md` section 4.8). On a client the herd is the host's and
             * these mirror the last snapshot; offline the scene simulates it. Either way
             * the verbs are refused here, because a bot's state is the simulation's.
             */
            bots: {
                count: function () {
                    return botEntries().length;
                },
                setCount: refuse("bots.setCount"),
                list: function () {
                    const entries = botEntries();
                    const n = entries.length;
                    for (let i = 0; i < n; i++) BOT_LIST[i] = fillBot(i, entries[i]);
                    BOT_LIST.length = n;
                    return BOT_LIST;
                },
                get: function (index) {
                    const entries = botEntries();
                    if (typeof index !== "number" || index < 0 || index >= entries.length) {
                        return null;
                    }
                    return fillBot(index, entries[index]);
                },
            },

            /**
             * The settings the menu and the console both edit (`APIv1.md` section 4.9),
             * read back off the frame's own `Settings` object. `herd` is the alias for
             * `bots.setCount` the API names, and reads the herd's size.
             */
            settings: {
                get: function () {
                    const s = group("settings");
                    return {
                        bgm: s.bgm, sfx: s.sfx, light: s.light, shadow: s.shadow,
                        sky: s.sky, cloud: s.cloud, fullscreen: s.fullscreen,
                        herd: s.herd,
                    };
                },
                set: refuse("settings.set"),
            },

            /**
             * The asset slots (`APIv1.md` section 4.11): the game's own files and everything the
             * loaded mods declared, resolved together. `get`/`all` prefer *this mod's* own
             * declaration for a slot, which is why the group is per mod; `slots()` is every slot
             * either half knows. The two writes are pre-freeze in the reference client and are
             * refused here with all the rest.
             */
            assets: assetsFor(null),

            /**
             * The entities one mod offers another (`APIv1.md` section 4.16): `offer(name, fn)` says
             * where this mod's own things are and how wide, and `near(x, z, range)` finds every
             * offered one, from *any* mod, in the ground plane. Unlike the groups above it reads no
             * snapshot, and unlike `assets` it involves no host table: an offer is a mod's own live
             * callback, and a query calls it, so both members are this prelude's and neither crosses.
             *
             * The id here is the reference client's own "nobody" (`-`), because an offer made
             * outside a `begin` is *visible* in `from` and has to name what it is.
             */
            entities: entitiesFor("-"),

            /**
             * The game's constants (`APIv1.md` section 4.10), read as a tree of dotted
             * paths. `get` throws on an unknown path, which is the API's own contract and
             * is what makes a typo -- or a leaf this client has not ported -- loud rather
             * than answered with `undefined`.
             */
            tuning: {
                get: function (path) {
                    return tuningAt(path);
                },
                set: refuse("tuning.set"),
                merge: refuse("tuning.merge"),
            },

            /**
             * The session (`APIv1.md` section 4.12), read off the frame's own net state.
             * `say` is the one write, and it is refused with the rest.
             */
            net: {
                mode: function () {
                    const mode = group("net").mode;
                    return typeof mode === "string" ? mode : "off";
                },
                inSession: function () {
                    return group("net").inSession === true;
                },
                isHost: function () {
                    return group("net").isHost === true;
                },
                localWorld: function () {
                    return group("net").localWorld !== false;
                },
                name: function () {
                    const name = group("net").name;
                    return typeof name === "string" ? name : "";
                },
                roster: function () {
                    const roster = group("net").roster;
                    return Array.isArray(roster) ? roster.slice() : [];
                },
                say: refuse("net.say"),
            },

            /**
             * A mod's own sound (`APIv1.md` section 4.20): `load(name)` turns an opaque asset
             * name -- usually one of `goats.assets.all(slot)` -- into a handle or `null`, and
             * `play(handle, volume, pitch)` sounds it.
             *
             * Both members *cross*, which is the one thing about this group that differs from
             * every other: a sound is not a value the core can push (there is nothing to read
             * back) and it is not a frame's drawing either -- it is a thing to *do*, at the
             * moment the mod asks. So it goes the way `terrainHeight` does, through the scene's
             * own `Callable` seam, and each client puts the volume and the pitch where its
             * engine wants them.
             */
            sfx: {
                load: function (name) {
                    if (name === undefined || name === null) return null;
                    const handle = ask("sfx.load", [String(name)]);
                    return handle === undefined || handle === null ? null : String(handle);
                },
                play: function (handle, volume, pitch) {
                    if (handle === undefined || handle === null) return;
                    ask("sfx.play", [String(handle),
                        volume === undefined ? 1 : volume,
                        pitch === undefined ? 1 : pitch]);
                },
            },

            /**
             * The API's own drawing surface (`APIv1.md` section 4.18). A mod draws
             * through this and never through an engine library, so one mod draws on
             * every client: here each call is queued as a record and the frame's
             * `ModHud` control paints it, while the raylib client implements the same
             * members over `rl` (`PORT.md` section 6).
             *
             * A colour is an opaque value from `color()` or a named constant; a length
             * is a pixel of the surface `screen()` reports; `y` is the top of a line of
             * text. A draw outside a hook is dropped -- there is no frame to draw into.
             */
            draw: (function () {
                function call(record) {
                    __goatsDraw(JSON.stringify(record));
                }
                function color(r, g, b, a) {
                    return { r: r, g: g, b: b, a: a === undefined ? 255 : a };
                }
                return {
                    color: color,
                    WHITE: color(255, 255, 255),
                    RAYWHITE: color(245, 245, 245),
                    BLACK: color(0, 0, 0),
                    RED: color(230, 41, 55),
                    GREEN: color(0, 228, 48),
                    BLUE: color(0, 121, 241),
                    YELLOW: color(253, 249, 0),
                    ORANGE: color(255, 161, 0),
                    GREY: color(130, 130, 130),
                    DARKGRAY: color(80, 80, 80),

                    /** The surface a draw lands on, in pixels: `{ width, height }`. */
                    screen: function () {
                        return { width: __goatsScreenW(), height: __goatsScreenH() };
                    },

                    text: function (text, x, y, size, col) {
                        call({ k: "text", s: String(text), x: x, y: y, size: size, col: col });
                    },
                    rect: function (x, y, w, h, col) {
                        call({ k: "rect", x: x, y: y, w: w, h: h, col: col });
                    },
                    rectLines: function (x, y, w, h, col) {
                        call({ k: "rectLines", x: x, y: y, w: w, h: h, col: col });
                    },
                    line: function (x1, y1, x2, y2, col) {
                        call({ k: "line", x: x1, y: y1, x2: x2, y: y2, col: col });
                    },
                    circle: function (cx, cy, radius, col) {
                        call({ k: "circle", x: cx, y: cy, r: radius, col: col });
                    },
                    circleLines: function (cx, cy, radius, col) {
                        call({ k: "circleLines", x: cx, y: cy, r: radius, col: col });
                    },
                };
            })(),

            /**
             * The API's own **world-space** surface (`APIv1.md` section 4.19). Where
             * `draw` takes pixels, this takes metres, and its calls are valid inside the
             * `"draw3d"` hook -- the frame's 3D pass, which is handed the camera. The two
             * surfaces are two because they are two spaces, and each client implements
             * each the way its renderer wants.
             *
             * A handle is opaque: `model()` answers one or `null` when the name does not
             * resolve, and a mod compares against `null`.
             */
            gfx: (function () {
                function call(record) {
                    __goatsDraw3d(JSON.stringify(record));
                }
                return {
                    model: function (name) {
                        if (name === undefined || name === null) return null;
                        const token = String(name);
                        if (__goatsHasAsset(token)) return token;
                        // A *built-in* slot's value is one of the game's own files, which this
                        // build loads from `res://assets/` rather than from bytes a mod declared
                        // -- so `gfx.model(goats.assets.get("model.goat"))` resolves, which is the
                        // API's own example (`APIv1.md` section 4.11).
                        return isBuiltIn(token) ? token : null;
                    },

                    /**
                     * A mod's own geometry (`APIv1.md` section 4.19): a mesh built from flat
                     * arrays, or `null` when the input is not one. `vertices` and `normals` are
                     * `[x, y, z, ...]` in metres; `colors` is `[r, g, b, a, ...]` in 0..255 and
                     * `texcoords` is `[u, v, ...]`, both per vertex; `indices` are triangle
                     * corners into the vertices, and a triangle soup is the default. Only
                     * `vertices` is required.
                     *
                     * The winding is the *reference* client's -- raylib's and Godot's front
                     * faces disagree, so a client whose culling differs reverses it in its own
                     * implementation, which is what the port does.
                     */
                    mesh: function (vertices, indices, normals, colors, texcoords) {
                        const v = flat(vertices, 3);
                        if (v === null || v.length < 9) return null;
                        const i = optional(indices, 3);
                        const n = optional(normals, 3);
                        const c = optional(colors, 4);
                        const uv = optional(texcoords, 2);
                        if (i === null || n === null || c === null || uv === null) return null;
                        return store("mesh", { v: v, i: i, n: n, c: c, uv: uv });
                    },

                    /**
                     * A mod's own image: `size` x `size` texels, `pixels` as `size * size`
                     * eight-hex-digit texels ("rrggbbaa"), row by row. `null` when the string
                     * is not that length -- which is the same answer a client with no
                     * renderer gives, so a mod's check is one `if` either way.
                     */
                    texture: function (size, pixels) {
                        if (typeof size !== "number" || !Number.isInteger(size) || size <= 0
                                || size > 2048) {
                            return null;
                        }
                        if (typeof pixels !== "string" || pixels.length !== size * size * 8) {
                            return null;
                        }
                        return store("texture", { size: size, pixels: pixels });
                    },

                    /** Draw a mesh in a texture -- `setModelTexture`, without the engine. */
                    bind: function (mesh, texture) {
                        if (mesh === undefined || mesh === null) return;
                        if (texture === undefined || texture === null) return;
                        __goatsBind(String(mesh), String(texture));
                    },

                    /**
                     * Free a mesh a mod built (`APIv1.md` section 4.19). It is **queued** rather
                     * than done: what a handle became is the *scene's* (`mod_world.gd`), and a
                     * record is how a frame tells it -- the same crossing a draw takes. The
                     * handle is dead afterwards; a mod that draws it again draws nothing.
                     *
                     * Textures and sounds are not freed this way in the reference client, and
                     * this member does not pretend otherwise -- a handle from `texture()` here is
                     * released too, because this client can tell what it minted.
                     */
                    unload: function (handle) {
                        if (handle === undefined || handle === null) return;
                        call({ k: "unload", h: String(handle) });
                    },

                    draw: {
                        model: function (handle, x, y, z, yaw, scale, tint) {
                            if (handle === undefined || handle === null) return;
                            call({
                                k: "model", h: handle, x: x, y: y, z: z,
                                yaw: yaw === undefined ? 0 : yaw,
                                scale: scale === undefined ? 1 : scale,
                                tint: tint === undefined ? { r: 255, g: 255, b: 255, a: 255 } : tint,
                            });
                        },
                        /**
                         * Any handle at `(x, y, z)`, turned `angle` **radians** about the axis
                         * `(ax, ay, az)`. `draw.model` is this with the axis fixed at +Y, and
                         * the free axis is what a tumbling thing needs.
                         */
                        mesh: function (handle, x, y, z, ax, ay, az, angle, scale, tint) {
                            if (handle === undefined || handle === null) return;
                            call({
                                k: "mesh", h: handle, x: x, y: y, z: z,
                                ax: ax === undefined ? 0 : ax,
                                ay: ay === undefined ? 1 : ay,
                                az: az === undefined ? 0 : az,
                                angle: angle === undefined ? 0 : angle,
                                scale: scale === undefined ? 1 : scale,
                                tint: tint === undefined ? { r: 255, g: 255, b: 255, a: 255 } : tint,
                            });
                        },
                        cube: function (x, y, z, w, h, d, col) {
                            call({ k: "cube", x: x, y: y, z: z, w: w, h: h, d: d, col: col });
                        },
                    },
                };
            })(),

            // --- host entry points (the `__` prefix marks them as the host's) ---

            /** Every state, the idle one first, then the mods in load order. */
            __states: function () {
                const all = [idle];
                for (const id in this.__mods) {
                    all.push(this.__mods[id]);
                }
                return all;
            },

            /** Invoke a command by name with a console-style line. */
            __invoke: function (name, line) {
                const states = this.__states();
                for (let i = 0; i < states.length; i++) {
                    const fn = states[i].commands[name];
                    if (typeof fn === "function") {
                        return fn(String(line).split(" "));
                    }
                }
                return null;
            },

            /** Fire every `"hud"` hook for one frame, with the screen size. */
            __fireHud: function (width, height) {
                const arg = { width: width, height: height };
                const states = this.__states();
                const failed = [];
                for (let i = 0; i < states.length; i++) {
                    const list = states[i].hooks["hud"] || [];
                    for (let j = 0; j < list.length; j++) {
                        // A hook is a mod's own code, and one that throws must not take
                        // the frame with it: the guarantee `PORT.md` section 4 states is
                        // that a mod cannot affect the frame except by the work it is
                        // asked to do, and a `TypeError` out of a handler is the frame
                        // breaking on a mod's account. `APIv1.md` section 7's isolation,
                        // and the same shape `mods.js`'s `modEmit` uses: the failure is
                        // named on the mod's own line rather than swallowed.
                        //
                        // The failure is *recorded* here and said below, which is not a
                        // preference: a host call inside a `catch` that caught a throw from a
                        // nested call trips this engine's environment stack (`entitiesNear` has
                        // the detail), and the frame would die of the isolation itself.
                        try {
                            list[j](arg);
                        } catch (error) {
                            failed.push(states[i].id + ": hud hook failed: " + String(error));
                        }
                    }
                }
                for (let i = 0; i < failed.length; i++) console.log(failed[i]);
            },
            /**
             * Fire every `"draw3d"` hook for one frame, with the camera. The same
             * isolation as `__fireHud`: a handler is a mod's code, and one that throws
             * must not take the frame with it.
             */
            __fireDraw3d: function (x, y, z, targetX, targetY, targetZ, fov) {
                // The camera is built here rather than crossing as an object: the seven
                // numbers *are* the crossing, and this shape is the one the scene's own
                // `modEmit("draw3d", ...)` sends (`goat.js`).
                const camera = {
                    x: x, y: y, z: z,
                    targetX: targetX, targetY: targetY, targetZ: targetZ,
                    fov: fov,
                };
                const states = this.__states();
                const failed = [];
                for (let i = 0; i < states.length; i++) {
                    const list = states[i].hooks["draw3d"] || [];
                    for (let j = 0; j < list.length; j++) {
                        try {
                            list[j](camera);
                        } catch (error) {
                            failed.push(states[i].id + ": draw3d hook failed: " + String(error));
                        }
                    }
                }
                for (let i = 0; i < failed.length; i++) console.log(failed[i]);
            },
        };
    })();
}

// ---------------------------------------------------------------------------
// There is deliberately **no `rl` here.** `rl` *is* raylib, so an `rl` in this
// extension would be a Godot emulation of a C library -- a shim that grows a
// member at a time and never quite is what a mod was written against, and a mod
// that used it would be bound to one client. The API's own drawing surface above
// is what a mod uses instead, and each client implements it for itself; the
// raylib client's `rl` is its engine binding and stays its business
// (`PORT.md` section 6).
// ---------------------------------------------------------------------------
