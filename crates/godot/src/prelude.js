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

        return {
            /** id -> { id, commands, hooks }, in registration order. */
            __mods: {},
            /** The state `command`/`on` write to outside a `begin` scope. */
            __state: idle,

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
                        return __goatsHasAsset(token) ? token : null;
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
                        try {
                            list[j](arg);
                        } catch (error) {
                            console.log("hud hook failed: " + error);
                        }
                    }
                }
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
                for (let i = 0; i < states.length; i++) {
                    const list = states[i].hooks["draw3d"] || [];
                    for (let j = 0; j < list.length; j++) {
                        try {
                            list[j](camera);
                        } catch (error) {
                            console.log("draw3d hook failed: " + error);
                        }
                    }
                }
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
