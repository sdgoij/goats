// The `goats` handle, as a mod sees it.
//
// This is the JavaScript facade the extension evaluates once, before any mod
// entry runs. It is deliberately thin: everything that needs to cross into
// native code or into GDScript is an `__`-prefixed capability the Rust side
// registers (`__goatsWorldTime`, `__goatsDraw`, `__goatsScreenW`), and the rest
// is the shape a mod expects from `APIv1.md` section 4.
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
