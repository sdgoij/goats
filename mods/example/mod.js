// The checked-in example mod (see APIv1.md §5). Copy this directory into the
// `mods/` folder the game scans to load it. It is `side: "client"`, so it is
// local-only and never enters a session's compatibility set.
//
// It shows four things:
//   * `goats.command` -- a new console verb, `hello`.
//   * `goats.on("hud")` -- drawing over the HUD with the engine's `rl` surface.
//   * a declared `assets` entry (mod.json) -- `sfx.bleat` now plays bleat.wav.
//   * a `tuning.json` merged before this file runs (camera.dist is a little
//     further out, and its deliberate typo is warned about, not fatal).

// A command runs through the same dispatcher as every built-in. Built-in names
// are reserved, so `hello` is ours.
goats.command("hello", function (parts) {
    const who = parts[1] === undefined ? "world" : parts[1];
    return "ok hello " + who;
});

// The HUD hook receives the screen size. `goats.world.time()` is the in-game
// clock in hours.
goats.on("hud", function (screen) {
    const t = goats.world.time();
    const hh = String(Math.floor(t) % 24).padStart(2, "0");
    const mm = String(Math.floor((t - Math.floor(t)) * 60)).padStart(2, "0");
    rl.drawText("example mod  " + hh + ":" + mm, screen.width - 380, 16, 20,
        rl.color(255, 235, 160, 220));
});
