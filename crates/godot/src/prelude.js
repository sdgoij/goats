// The `goats` handle and the engine's `rl` surface, as a mod sees them.
//
// This is the JavaScript facade the extension evaluates once, before any mod
// entry runs. It is deliberately thin: everything that needs to cross into
// native code or into GDScript is an `__`-prefixed capability the Rust side
// registers (`__goatsWorldTime`, `__rlDrawText`), and the rest is the shape a
// mod expects from `APIv1.md` section 4.
//
// Splitting it this way is the bridge design from `godot/PORT.md` section 6:
// the registries are a JS layer (as they are today, in the raylib client's
// `mods.js`), while reads of the world and draws through the engine are native
// calls -- and each of those is a place the design says to push a value or
// register a callback rather than reimplement the world in JavaScript.

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
// The engine surface. A mod may build geometry and textures with this, so the
// extension hosts a Godot-backed shim (PORT.md section 6, decision 2). Only the
// two members the example mod uses are here so far; the rest of the surface the
// scene exposes arrives with the drawing shim proper.
// ---------------------------------------------------------------------------

if (typeof globalThis.rl === "undefined") {
    globalThis.rl = {
        // A colour is plain data, so it needs no crossing.
        color: function (r, g, b, a) {
            return { r: r, g: g, b: b, a: a === undefined ? 255 : a };
        },

        // Drawing is not: this lands in the extension, which queues it for Godot.
        drawText: function (text, x, y, size, color) {
            __rlDrawText(String(text), x, y, size, color.r, color.g, color.b, color.a);
        },
    };
}
