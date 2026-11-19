// The `rl` the build-time scene snapshot is evaluated against.
//
// `crates/goats/build.rs` evaluates `scene::SCENE` once, at build time, and
// embeds the realm it leaves behind; the client boots by restoring it. The
// engine's snapshot cannot carry a Rust callback, so the realm has no raylib.
// This stub stands in for the only member the scene's *top level* reads -- not
// the scene at large, which resolves `rl` at call time against the real module
// the host installs before restoring.
//
// That narrowness is the contract. `null_rl.js` enumerates the whole surface
// the headless scene calls; this file enumerates what is read while the script
// loads, and nothing else:
//
//   rl.color(...)              nine palette constants (core.js) and two cloud
//                              tints (weather.js), all packed `0xRRGGBBAA`
//   rl.KEY_GRAVE               `CONSOLE_KEY` (console.js)
//   typeof rl.makeModel        `TERRAIN_MESH_OK` (world.js)
//
// A top-level read this file does not answer fails the build with a
// `TypeError`, which is what keeps the snapshot honest: the alternative is a
// constant frozen to the wrong value and discovered at play time. The values
// above are the client's, not the headless stub's -- `color()` has to return
// the packed number raylib's bindings return, because `null_rl.js`'s
// `{ r, g, b, a }` object would be restored as the palette the renderer then
// draws with.
//
// The stub is deleted from the global before the blob is written, so it can
// never shadow the real `rl` the client installs.

(function () {
    // `Color` in raylib's bindings is one number, `0xRRGGBBAA`, with each
    // channel masked to 0..=255. The arithmetic form stays unsigned where
    // `<<` would sign the top channel.
    function color(r, g, b, a) {
        const alpha = a === undefined ? 255 : a;
        return ((r & 255) * 0x1000000) + ((g & 255) * 0x10000) +
            ((b & 255) * 0x100) + (alpha & 255);
    }

    globalThis.rl = {
        color: color,
        KEY_GRAVE: 96,
        // Present so `TERRAIN_MESH_OK` is true, as it is in every build of the
        // client; the function is never called at load time.
        makeModel: function () {},
    };
})();
