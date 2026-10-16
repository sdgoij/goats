# The readable-surface gate: the `goats` groups a *mod* reads the live world through -- its own
# identity and logging (`APIv1.md` section 4.1), the world (`sections 4.5-4.12`), the asset slots
# (4.11) and the seam that lets one mod see another's entities (4.16) -- against the scene's own
# values.
#
#   Godot --headless --path godot --script res://tools/verify_mod_surface.gd
#
# `verify_scene_mods.gd` holds the runtime (the table, the isolation, the console verb) and
# `verify_mod_gfx.gd` holds the drawing surfaces; both are about what a mod *tells* the game.
# This is the other direction -- what a mod *reads* -- and it exists because the port's `goats`
# handle had five members and a mod that touched a sixth threw on its first hook.
#
# The design it holds is `PORT.md` section 6 decision 3: the core **pushes** one JSON snapshot per
# frame and the readable groups read it, so none of these reads crosses the language boundary. That
# is a claim about *cost*, and the way to check it is not to time it but to check the thing the
# design buys: the values are the scene's own, field for field, taken from the same modules the
# HUD and the wire take theirs from. A snapshot that drifted from the world would be a mod reading
# a second, wrong world -- which no amount of "the call arrived" would catch.
#
# Eleven things, and the order is the order of the ways they can be faked:
#
#   0. **Every mod knows who it is and can speak.** `goats.api`, `goats.game`, `goats.mods()`,
#      a handle's own `goats.mod` -- held against the *scene's* table, which is the one the Mods
#      screen draws -- and `goats.log`/`warn`/`error`, whose lines must reach the console with
#      their level still on them.
#   1. **Every group answers**, from inside a mod's own hook (`hud`), which is where a mod reads
#      it -- not from a probe that could be reading the host directly.
#   2. **The values are the scene's.** Each group is held against its module: the goat's health and
#      its position, the weather machine's `rain_amount`, the frame's `_wind_sway`, the `Settings`
#      object, the herd's own `report()`.
#   3. **The tuning tree mirrors its sources.** Every leaf is a module's `static var` (`stats.max`
#      is `PlayerGoat.STATS_MAX`, `explosions.blast.lift` is `Explosions.BLAST_LIFT`), so the gate
#      holds the tree against the modules rather than against a second literal -- and an absent
#      path throws, which is the API's own contract. The *writes* (`tuning.set`/`merge`) are held
#      with the other writes, below: each one lands on the module that owns the leaf.
#   4. **The handles are reused**, which `APIv1.md` section 4.8 promises and `PERF.md` appendix B
#      pays for: `list()` twice is the same array, and `get(0)` is the same object as `list()[0]`.
#   5. **The one functional read crosses and answers** -- `terrainHeight` against `Terrain.height_at`,
#      the scene's own function including the craters.
#   6. **The writes are the scene's** (`APIv1.md` sections 4.5-4.12). Each is applied and held
#      against the *scene's own* field -- a position, a heading, a gait, a clamped camera, a gain,
#      a clock, a herd size and a bot's own x/z/yaw -- because a write is a claim about the
#      simulation and only the simulation can keep its invariants. The tuning tree is written the
#      same way: `tuning.set`/`merge` are held against the modules that own the leaves, including
#      one the *scene* owns (`herd.count`), and the three refusals (a branch, an unknown path, a
#      string where a number belongs) are asserted too. `assets.override` is the one family the
#      port has still not got, and it is asserted as a refusal with them, so a member that quietly
#      became a no-op would show. (`explosions.armed` was another and is now in -- it is checked
#      with the devices, above.)
#   7. **The asset slots have both of their owners** (`assets`, section 4.11). This is the one group
#      two things supply -- the built-in half is the scene's own table and the declared half is the
#      mods' -- so what is held is that both are visible, that a built-in slot's name really loads
#      through `gfx.model`, that a join **appends** rather than displacing, and that `get` answers
#      with what the slot holds, which is the reference client's own shape and not a tidier one.
#      The two code-side writes (`override`/`add`) are held too, both ways: refused outside a mod's
#      entry, and landing inside one -- which is why the gate stages a mod with an entry of its own
#      (`_check_staged_assets`), the way `verify_scene_mods` stages a broken one.
#   8. **Two mods can see each other** (`entities`, section 4.16), which is the only group whose
#      subject is another mod: an offer is namespaced to the mod that made it, a *different* mod's
#      `near` finds it, and a callback that throws costs its own mod's rows and nobody else's.
#   9. **A world mod's stream is the one two peers must agree on** (`rng`, `world.registerStream`,
#      section 4.13), so it is held against the reference's derivation transcribed into this file --
#      FNV-1a, xorshift32, and one shared draw per stream from the session seed -- rather than
#      against a second copy of the port. The seed itself goes through the scene's own path.
#  10. **A mod's bang is the core's bang** (`explosions`, section 4.15). `traps` is held against
#      `Explosions.traps_near`, which is the derivation the console's own verb prints, at a point
#      the gate *finds* rather than guesses; and `blast` is held against the scene's own counters --
#      the blast count rises, the device is spent so the cell is armed nowhere afterwards -- because
#      "through the core's own path" is the whole of the member's contract.
#
# **The sentinel.** GDScript has no `try`, so a runtime error inside a check aborts that function
# and leaves the failure it was about to record unrecorded -- a gate that would print `OK` having
# checked half of what it claims. `_finished` is set at the very end of `_check`, and a run that
# does not reach it is a failure no matter what else it managed to assert. This bit once: the first
# version of this file compared two strings with `String(x)`, which Godot 4.7 rejects for a
# same-type argument, and the abort printed `OK`.
extends SceneTree

## The probe, evaluated in the mod realm through the host's own `eval_js`. It registers a console
## verb -- the same seam a mod's command uses -- and a `hud` hook, so the readings are taken
## exactly the way a mod takes them: from inside a hook, during the frame the scene pushed.
const PROBE_JS := """
(function () {
    // The `hud` hook reads the surface where a mod reads it: inside the frame.
    globalThis.__surfaceHud = null;
    goats.on("hud", function () {
        const p = goats.player.state();
        globalThis.__surfaceHud = { health: p.health, x: p.x, mode: p.mode };
    });

    // The `"tuning"` event (`APIv1.md` section 4.2): record every change, so the gate can hold the
    // event's own shape -- the dotted path and the coerced value.
    globalThis.__surfaceTuning = [];
    goats.on("tuning", function (path, value) {
        globalThis.__surfaceTuning.push({ path: path, value: value });
    });

    goats.command("modsurface", function () {
        const out = {};
        // What the `hud` hook read during the frame -- the surface as a mod sees it.
        out.from_hud = globalThis.__surfaceHud;
        const p = goats.player.state();
        out.player = {
            mode: p.mode, health: p.health, energy: p.energy, exhausted: p.exhausted,
            satiety: p.satiety, x: p.x, y: p.y, z: p.z, yaw: p.yaw,
            phase: p.phase, speed: p.speed, clip: p.clip,
        };
        const c = goats.camera.get();
        out.camera = { yaw: c.yaw, pitch: c.pitch, dist: c.dist };
        const w = goats.world.weather();
        out.weather = { kind: w.kind, cloudiness: w.cloudiness, rain: w.rain,
                        wind: w.wind, speed: w.speed };
        const wind = goats.world.wind();
        out.wind = { x: wind.x, z: wind.z, sway: wind.sway };
        const s = goats.settings.get();
        out.settings = { bgm: s.bgm, sfx: s.sfx, light: s.light, shadow: s.shadow,
                         sky: s.sky, cloud: s.cloud, fullscreen: s.fullscreen, herd: s.herd };

        out.bots_count = goats.bots.count();
        const list = goats.bots.list();
        out.bots_len = list.length;
        if (list.length > 0) {
            out.bot0 = { id: list[0].id, x: list[0].x, z: list[0].z, yaw: list[0].yaw,
                         mode: list[0].mode, satiety: list[0].satiety };
        }
        // The handles are the scene's own and are reused (APIv1.md section 4.8).
        out.bots_reused = goats.bots.list() === list && goats.bots.get(0) === list[0];
        out.bots_null = goats.bots.get(99) === null;

        out.tuning = {
            max: goats.tuning.get("stats.max"),
            drain_run: goats.tuning.get("stats.energyDrain.run"),
            trot_stride: goats.tuning.get("gait.trot.stride"),
            relief: goats.tuning.get("terrain.relief"),
            blast_lift: goats.tuning.get("explosions.blast.lift"),
            herd_count: goats.tuning.get("herd.count"),
            min_dist: goats.tuning.get("camera.minDist"),
            water_on: goats.tuning.get("water.enabled"),
            reflect: goats.tuning.get("water.reflection"),
            steps: (goats.tuning.get("sky.steps") || []).length,
            branch: typeof goats.tuning.get("explosions.blast") === "object",
        };
        try { goats.tuning.get("no.such.path"); out.tuning_unknown = "answered"; }
        catch (error) { out.tuning_unknown = "threw"; }

        out.terrain = goats.world.terrainHeight(GOATS_TERRAIN_X, GOATS_TERRAIN_Z);
        out.net = {
            mode: goats.net.mode(), local: goats.net.localWorld(),
            session: goats.net.inSession(), host: goats.net.isHost(),
            name: goats.net.name(), roster: goats.net.roster().length,
        };
        // The water's connected regions (M20f), taken here so the gate can hold the *algorithm*
        // against the field as well as the crossing against the scene.
        out.pools = goats.water.pools();

        // The writes are a command of their own (`modwrite`, below), because they *change* the
        // world the readings above describe: a gate that wrote before it read would be comparing
        // the mod's own pre-write snapshot against a post-write scene.

        // The identity a mod reads before it reads anything else (APIv1.md section 4.1), and the
        // three ways it can say something.
        out.api = goats.api;
        out.game = goats.game;
        out.frozen = goats.frozen();
        const table = goats.mods();
        out.mods = table.length;
        try {
            const started = goats.begin(table.length > 0 ? table[0].id : "nobody");
            out.mod_id = started.mod === null ? "null" : started.mod.id;
            out.mod_side = started.mod === null ? "null" : started.mod.side;
            out.assets_kind = typeof started.assets;
        } catch (error) {
            out.begin_error = String(error);
        }
        goats.log("surface: hello from the probe");
        goats.warn("surface: a warning");

        // The asset slots (`APIv1.md` section 4.11): the game's own half and the mods' own half,
        // resolved together -- and the slots a mod *declared* are the ones it actually asks for.
        const slots = goats.assets.slots();
        out.asset_slots = slots.length;
        out.asset_has_goat = slots.indexOf("model.goat") >= 0;
        out.asset_has_squawk = slots.indexOf("sfx.squawk") >= 0;
        // Every slot appendix B names, and none of the three M19g ones it does not: `core.js`'s
        // `ASSET_SLOTS` holds only slots that have files, so a reserved-but-empty slot is one a
        // mod *makes* by declaring it -- `audio.js` reads the three by name and lives with an
        // absent slot, which is why they belong in the play table and not in the asset table.
        const listed = ["model.goat", "sfx.music", "sfx.rain", "sfx.wind",
                        "sfx.bleat", "sfx.thunder", "sfx.blast", "sfx.debris"];
        out.asset_missing = listed.filter(function (slot) { return slots.indexOf(slot) < 0; })
            .join(",");
        const reserved = ["sfx.blast.close", "sfx.fuse", "sfx.trap"];
        out.asset_reserved = reserved.filter(function (slot) { return slots.indexOf(slot) >= 0; })
            .join(",");
        out.asset_goat = goats.assets.get("model.goat");
        out.asset_goat_loads = goats.gfx.model(goats.assets.get("model.goat")) !== null;
        out.asset_bleat = goats.assets.all("sfx.bleat");
        out.asset_squawk = goats.assets.all("sfx.squawk").length;
        out.asset_fatguy = goats.assets.get("model.fatguy");
        out.asset_unknown = goats.assets.get("no.such.slot") === undefined;
        // The *shape* rule: the table answers a slot with what the slot holds, so a list slot is
        // a list and a single-file slot is the name (`modAssetsFor`, `mods.js`).
        out.asset_bleat_is_list = typeof goats.assets.get("sfx.bleat") === "object";
        out.asset_goat_is_name = typeof goats.assets.get("model.goat") === "string";
        // ...and a mod's *own* declaration wins over the table, with a declared list answering
        // its head: `birds` fills `sfx.squawk` with two files, so the mod itself sees one name
        // and nobody else does.
        const birds = goats.begin("com.github.sdgoij.goats.birds");
        out.own_get = birds.assets.get("sfx.squawk");
        out.own_all = birds.assets.all("sfx.squawk").length;
        out.own_fallback = birds.assets.get("model.goat");
        try {
            goats.assets.override("model.goat", "x");
            out.asset_write = "answered";
        } catch (error) {
            out.asset_write = "threw";
        }

        // The entities one mod offers another (`APIv1.md` section 4.16). Two handles, because the
        // seam is exactly the one that lets two *mods* see each other -- offering and asking from
        // one mod would prove the registry and not the crossing.
        const owner = goats.begin("com.example.owner");
        const asker = goats.begin("com.example.asker");
        // Only *this* mod's offers are counted, and it is not tidiness: the repository's own mods
        // offer entities too -- the flock is one, and it flies about -- so a raw count would be
        // asking the birds what the gate did, and would change between two queries in one probe.
        // What the seam's cross-mod behaviour means is `verify_scene_mods.gd`'s subject.
        function mineOnly(rows) {
            return rows.filter(function (e) { return e.from.indexOf("com.example.owner:") === 0; });
        }
        owner.entities.offer("blob", function () { return [[1, 0.5, 0, 0.5], [9, 9, 9, 1]]; });
        owner.entities.offer("junk", function () { return [[0, 0, 0, 9]]; });
        // A second offer under one name replaces the first, rather than joining it -- which is what
        // the count below holds: the displaced row was inside the range too, so a *join* would have
        // answered three.
        owner.entities.offer("junk", function () { return [[0, 0, 0, 0.25]]; });
        const near = mineOnly(asker.entities.near(0, 0, 2));
        out.entity_near = near.length;
        out.entity_from = near.length > 0 ? near[0].from : null;
        out.entity_row = near.length > 0
            ? [near[0].x, near[0].y, near[0].z, near[0].r, near[0].d] : null;
        // The range is the ground plane's, so the far one is dropped and the near one kept.
        out.entity_far = mineOnly(asker.entities.near(0, 0, 0.1)).length;
        // A callback that throws costs *its own* mod's entities for that query and nobody
        // else's, and a row that is not four finite numbers is skipped rather than thrown.
        owner.entities.offer("boom", function () { throw new Error("nope"); });
        owner.entities.offer("junkrows", function () {
            return [[1, 2, 3], ["a", "b", "c", "d"], [0, 0, 0, 0.5], null];
        });
        out.entity_threw = mineOnly(asker.entities.near(0, 0, 2)).length;
        try {
            owner.entities.offer("bad", "not a function");
            out.entity_offer_check = "accepted";
        } catch (error) {
            out.entity_offer_check = "threw";
        }
        try {
            asker.entities.near(0, 0, -1);
            out.entity_range_check = "accepted";
        } catch (error) {
            out.entity_range_check = "threw";
        }
        return JSON.stringify(out);
    });

    // The world mods' streams (`APIv1.md` section 4.13). A *verb*, because the sequence has to
    // outlive one call: the gate registers and draws, then re-derives from a seed through the
    // scene's own path and draws again -- and the second half is where a stream that restarted,
    // or that never re-derived, would show.
    goats.command("modstreams", function (args) {
        const out = { f: [], v: [] };
        const birds = goats.begin("com.github.sdgoij.goats.birds");
        const verb = args.length > 1 ? String(args[1]) : "register";
        if (verb === "register") {
            birds.world.registerStream("f", 0x5eed);
            // A seed of 0 is not a seed: the reference falls through to the key's own hash, so two
            // mods asking for the same name still get different sequences.
            birds.world.registerStream("valueless", 0);
            for (let i = 0; i < 3; i++) out.f.push(birds.rng("f")());
            for (let i = 0; i < 2; i++) out.v.push(birds.rng("valueless")());
            out.never = birds.rng("never-registered")();
            // Only a `side: "world"` mod owns a stream, and the base object has neither member --
            // both are the reference's own shape (`modWorldFor`, `goatsBegin`).
            try {
                goats.begin("com.github.sdgoij.goats.fatguy").world.registerStream("x", 1);
                out.client = "answered";
            } catch (error) {
                out.client = "threw";
            }
            try {
                goats.world.registerStream("base", 1);
                out.base = "answered";
            } catch (error) {
                out.base = "threw";
            }
            out.base_rng = typeof goats.rng;
        } else {
            for (let i = 0; i < 2; i++) out.f.push(birds.rng("f")());
            for (let i = 0; i < 1; i++) out.v.push(birds.rng("valueless")());
        }
        return JSON.stringify(out);
    });

    // The devices (`APIv1.md` section 4.15). The coordinates come from the command line rather than
    // from the source, because the field is derived from the seed and the gate has to pick a point
    // that actually holds a device.
    goats.command("moddevices", function (args) {
        const x = Number(args[1]);
        const z = Number(args[2]);
        const out = {};
        const near = goats.explosions.traps(x, z, 40);
        out.mines = near.mines.length;
        out.traps = near.traps.length;
        out.mine = near.mines.length > 0 ? near.mines[0] : null;
        // `armed` (`APIv1.md` section 4.15): the request is the mod's, and with the field away the
        // derivation answers *nothing* -- which is what makes a "clear the field" tool a mod.
        out.armed_before = goats.explosions.armed();
        goats.explosions.armed(false);
        out.armed_after = goats.explosions.armed();
        const off = goats.explosions.traps(x, z, 40);
        out.off_mines = off.mines.length;
        out.off_traps = off.traps.length;
        goats.explosions.armed(true);
        out.on_mines = goats.explosions.traps(x, z, 40).mines.length;
        // The bang goes through the *core's* path, so the scene's own count rises and the device is
        // spent -- and a spent device is a cell that is armed nowhere, which the query below says.
        out.blast = goats.explosions.blast(x, z, "mine");
        out.single = goats.explosions.traps(x, z, 1).mines.length;
        return JSON.stringify(out);
    });

    // The writes (`APIv1.md` sections 4.5-4.12), a command of their own so they run *after* every
    // reading above. Only their returns are collected here; the gate holds each against the
    // scene's own field, which is the thing a write is a claim about -- the readable groups answer
    // from the frame that was pushed before this ran, so a mod's own read cannot show the effect.
    // `restart` comes first because it resets the goat, position and mode and all.
    goats.command("modwrite", function () {
        const out = {};
        goats.player.restart();
        const WX = 12.5, WZ = -7.25, WYAW = 0.75;
        goats.player.teleport(WX, WZ);
        goats.player.face(WYAW);
        out.wrote = { x: WX, z: WZ, yaw: WYAW };
        out.mode_gait = goats.player.setMode("trot");
        out.mode_eat = goats.player.setMode("eat");
        out.mode_dead = goats.player.setMode("dead");
        goats.camera.set({ yaw: WYAW, pitch: 9.9, dist: -5 });
        goats.settings.set({ bgm: 17, cloud: "high" });
        out.set_time = goats.world.setTime(3);
        out.set_weather = goats.world.setWeather("rain");
        out.set_weather_bad = goats.world.setWeather("bogus");
        out.say = goats.net.say("hello");
        out.say_empty = goats.net.say("   ");
        out.bot_count = goats.bots.setCount(3);
        const b = goats.bots.get(0);
        b.teleport(WX + 4, WZ - 3);
        b.face(1.25);
        b.zoomies(2);
        b.startle();
        out.bot_wrote = { x: WX + 4, z: WZ - 3, yaw: 1.25 };
        // The tuning tree (`APIv1.md` section 4.10). Each write lands on the module that *owns* the
        // leaf and answers the coerced value; the gate holds the scene's side below. A clamp, an int
        // and a nested dict member prove the coercion and the keys, and `merge` proves the recursion.
        // (`herd.count`, a leaf the *scene* owns, is written through the seam in the gate itself, so
        // it does not disturb the herd the checks above just sized.)
        out.tune = {
            set: goats.tuning.set("camera.dist", 6.75),
            int: goats.tuning.set("explosions.relocate.tries", 7.6),
            clamp: goats.tuning.set("herd.deathLinger", 0.1),
            nested: goats.tuning.set("stats.energyDrain.idle", 1.25),
        };
        goats.tuning.merge({ sky: { absorb: 1.5 }, camera: { pitch: 0.5 } });
        // A branch is not a leaf, an unknown path is unknown, and a number leaf refuses a string --
        // the API's own three refusals.
        out.tune_branch = "answered";
        try { goats.tuning.set("explosions.blast", 1); }
        catch (error) { out.tune_branch = "threw"; }
        out.tune_unknown = "answered";
        try { goats.tuning.set("no.such.path", 1); }
        catch (error) { out.tune_unknown = "threw"; }
        out.tune_type = "answered";
        try { goats.tuning.set("camera.dist", "wide"); }
        catch (error) { out.tune_type = "threw"; }
        // The asset writes (`APIv1.md` section 4.11) are in but *gated*: legal only while a mod's own
        // entry runs, and this is a command rather than an entry, so both are refused here -- with
        // the reference's own message. The success path is an entry (`_check_staged_assets`, below).
        try { goats.assets.override("sfx.music", "mod:com.example:sfx.music.mp3"); out.asset_write = "answered"; }
        catch (error) { out.asset_write = "threw"; }
        try { goats.assets.add("sfx.bleat", "mod:com.example:bleat.wav"); out.asset_add = "answered"; }
        catch (error) { out.asset_add = "threw"; }
        return JSON.stringify(out);
    });

    // The `"tuning"` events the listener above recorded (`APIv1.md` section 4.2).
    goats.command("modtuning", function () {
        return JSON.stringify(globalThis.__surfaceTuning);
    });
})();
"""

var _failures: Array[String] = []
var _frames := 0
var _finished := false
var _main: Node
## The point of largest relief the terrain callback is asked about, found once and cached: value
## noise has flat spots, so a hard-coded point can be one and the check would prove nothing.
var _probe := Vector2.ZERO
var _probe_found := false

## The terrain point the callback is asked about, found by the gate rather than hard-coded: the
## field is value noise and a chosen point can happen to sit near zero, which would be a check two
## zeros could satisfy. `_check_world` scans a coarse grid for the point of largest relief
## **outside the spawn bowl** (`Terrain.FLAT` is 6 units) and asks about that one.
const TERRAIN_STEP := 5.0
const TERRAIN_SPAN := 8

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		# Drive the goat for a few frames, so what the surface reports is a *moving* goat and not
		# a row of defaults two sources would agree on trivially. The console's virtual key is the
		# port's own way in (`cmd_set_gait`), and it is the same path a `walk` line takes.
		if _frames == 3:
			_main.call("cmd_set_gait", "run")
		return false
	_check()
	# The sentinel: a check that aborted on a GDScript error never recorded its failure, so a run
	# that did not reach the end of `_check` is one, whatever else it asserted.
	if not _finished:
		_failures.append("the checks did not run to the end (a script error aborted them)")
	if _failures.is_empty():
		print("OK: the mods read the live world through every readable goats group")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	var mods: Object = _main.get("mods")
	if mods == null or mods.get("host") == null:
		_failures.append("the scene has no mod runtime")
		_finished = true
		return
	var host: Object = mods.get("host")
	var goat: Object = _main.get("goat")
	var weather: Object = _main.get("weather")
	var bots: Object = _main.get("bots")
	var settings: Object = _main.get("settings")
	var reflect: Object = _main.get("water_reflect")

	var point: Vector2 = _probe_point()
	# The scene boots dry, and a dry field has no pools -- so the gate wets it by hand, through the
	# console's own `flood` path (`Water.set_force`). Without this the flood fill would be held
	# against an empty field and pass for the wrong reason.
	var water: Object = _main.get("water")
	water.call("set_force", 0.0)
	water.call("update")
	var evaluated: String = str(host.call("eval_js", PROBE_JS
		.replace("GOATS_TERRAIN_X", "%f" % point.x)
		.replace("GOATS_TERRAIN_Z", "%f" % point.y)))
	if evaluated != "ok":
		_failures.append("the surface probe did not run: " + evaluated)
		_finished = true
		return

	# 1. One frame, driven here rather than by the node's `_process`, so the snapshot and the
	#    readings are the same instant: the world cannot advance between the push and the read.
	var snapshot: Dictionary = _main.call("_mod_snapshot")
	mods.call("frame", _main.call("cmd_hours"), Vector2(1280.0, 720.0), true,
		_main.get_node("Camera3D"), snapshot)
	var raw: String = str(host.call("run_command", "modsurface", "modsurface"))
	var answer: Variant = JSON.parse_string(raw)
	if not (answer is Dictionary):
		# The raw answer, because a probe that threw answers with the error and a gate that
		# swallowed it would say only that it had nothing.
		_failures.append("the surface probe did not answer with a table: " + raw)
		_finished = true
		return
	var read: Dictionary = answer

	_check_hook(read, goat)
	_check_player(read, goat)
	_check_world(read, weather)
	_check_camera(read)
	_check_settings(read, settings, bots)
	_check_bots(read, bots)
	_check_tuning(read, bots, reflect)
	_check_calls(read)
	# A second frame, so anything the probe *said* is drained into the console before the identity
	# check reads it: the first frame ran before the probe answered, and a log line lands in the
	# host's queue when it is said and not when the frame is drawn.
	mods.call("frame", _main.call("cmd_hours"), Vector2(1280.0, 720.0), true,
		_main.get_node("Camera3D"), snapshot)
	_check_identity(read, mods, _main.get("console"))
	_check_assets(read)
	_check_entities(read, _main.get("console"))
	_check_streams(host, mods)
	# Before the devices, which blast a crater: a crater makes a puddle, and the pools the probe
	# read are the ones the field had when it asked.
	_check_pools(read, _main.get("water"))
	_check_devices(host)
	# ...and the writes, **last**, because they change the world every reading above describes.
	# The probe's `restart` needs something to restore, or "a full goat is still full" is a check
	# that cannot fail -- these are the scene's own fields, set the way the console's own
	# `health`/`energy` verbs set them.
	goat.set("health", 1.0)
	goat.set("energy", 1.0)
	goat.set("mode", "idle")
	var wrote_raw: String = str(host.call("run_command", "modwrite", "modwrite"))
	var wrote: Variant = JSON.parse_string(wrote_raw)
	if not (wrote is Dictionary):
		_failures.append("the write probe did not answer with a table: " + wrote_raw)
	else:
		_check_writes(wrote as Dictionary, _main)
	# The `"tuning"` events the writes queued (`APIv1.md` section 4.2): the mods *say* them at the end
	# of a frame (outside every hook, for `blast`'s reason), so one more run and the probe's listener
	# can be read back.
	mods.call("frame", _main.call("cmd_hours"), Vector2(1280.0, 720.0), true,
		_main.get_node("Camera3D"), _main.call("_mod_snapshot"))
	var events: Variant = JSON.parse_string(str(host.call("run_command", "modtuning", "modtuning")))
	_check_tuning_event(events)
	# ...and the entry-gated asset writes, which need a mod *entry* to run in: the gate stages one, so
	# this is last -- it replaces the loaded set.
	_check_staged_assets(host)
	_finished = true

## The asset slots (`APIv1.md` section 4.11), the one group that is a *merge* of two owners: the
## game's own files are the scene's (`audio.gd`'s table) and the declared ones are the mods', and
## what is asserted is that both halves are visible and that a name `get` hands back can actually
## be loaded -- the API's own example is `gfx.model(goats.assets.get("model.goat"))`.
func _check_assets(read: Dictionary) -> void:
	for key: String in ["asset_has_goat", "asset_has_squawk"]:
		if read.get(key) != true:
			_failures.append("goats.assets.slots() is missing a slot (%s)" % key)
	if str(read.get("asset_missing", "?")) != "":
		_failures.append("goats.assets.slots() is missing appendix B's built-ins: %s"
			% read.get("asset_missing"))
	if str(read.get("asset_reserved", "?")) != "":
		_failures.append("goats.assets.slots() lists a reserved-but-empty M19g slot: %s"
			% read.get("asset_reserved"))
	if str(read.get("asset_goat")) != "goat_animated.glb":
		_failures.append("goats.assets.get(\"model.goat\") is %s, and the game's is goat_animated.glb"
			% read.get("asset_goat"))
	if read.get("asset_goat_loads") != true:
		_failures.append("the built-in slot's own name did not resolve through goats.gfx.model")

	# The *merge*, which is what this group is: a slot can have two owners. `sfx.bleat` is the
	# one that has both -- the game's own six (`core.js` `ASSET_SLOTS`) and the two the checked-in
	# example mod joins (`mods/example/mod.json`'s `assetAdds`) -- and the API's rule is that a
	# join **appends**: the game's files stay where they were and the mod's go on the end
	# (`APIv1.md` section 4.11). A bare count would pass for a table that had simply replaced the
	# slot, so what is held is the order too: six the game's, then two the mod's.
	const BUILT_IN_BLEATS := 6
	const JOINED_BLEATS := 2
	var bleats: Array = read.get("asset_bleat", [])
	if bleats.size() != BUILT_IN_BLEATS + JOINED_BLEATS:
		_failures.append("goats.assets.all(\"sfx.bleat\") is %s long, and the game's six plus the example mod's two is eight"
			% bleats.size())
	for i: int in range(mini(BUILT_IN_BLEATS, bleats.size())):
		if str(bleats[i]).begins_with("mod:"):
			_failures.append("a join displaced the game's own bleat at %s (%s)" % [i, bleats[i]])
	for i: int in range(BUILT_IN_BLEATS, bleats.size()):
		if not str(bleats[i]).begins_with("mod:"):
			_failures.append("the example mod's joined bleat is not an opaque name: %s" % bleats[i])
	if int(read.get("asset_squawk", -1)) != 2:
		_failures.append("goats.assets.all(\"sfx.squawk\") is %s long, birds declared 2"
			% read.get("asset_squawk"))
	if not str(read.get("asset_fatguy", "")).begins_with("mod:"):
		_failures.append("goats.assets.get(\"model.fatguy\") is %s, and fatguy declared an opaque name"
			% read.get("asset_fatguy"))
	if read.get("asset_unknown") != true:
		_failures.append("goats.assets.get on an unknown slot did not answer undefined")
	# The shape rule (`modAssetsFor`, `mods.js`): a slot answers with what it holds.
	if read.get("asset_bleat_is_list") != true:
		_failures.append("goats.assets.get on the list slot sfx.bleat did not answer a list")
	if read.get("asset_goat_is_name") != true:
		_failures.append("goats.assets.get on the single-file slot model.goat did not answer a name")
	# ...and a mod's own declaration wins over the table, a declared list answering its head.
	if not str(read.get("own_get", "")).begins_with("mod:"):
		_failures.append("a mod's own assets.get on the slot it filled answered %s, and its own list should answer its head"
			% read.get("own_get"))
	if int(read.get("own_all", -1)) != 2:
		_failures.append("a mod's own assets.all on the slot it filled is %s long, and birds declared 2"
			% read.get("own_all"))
	if str(read.get("own_fallback", "")) != "goat_animated.glb":
		_failures.append("a mod's assets.get on a slot it did not fill answered %s, and the fallback is the game's own name"
			% read.get("own_fallback"))
	if str(read.get("asset_write")) != "threw":
		_failures.append("goats.assets.override did not throw: %s" % read.get("asset_write"))
	print("assets: ", read.get("asset_slots"), " slot(s)  model.goat -> ", read.get("asset_goat"),
		"  bleat ", bleats.size(), "  squawk ", read.get("asset_squawk"))

## The entities one mod offers another (`APIv1.md` section 4.16), held as the seam it is: a *second*
## mod's `near` finds the first mod's offer, under the name the offer was namespaced to. This is the
## only group whose subject is another mod, so the shape matters as much as the numbers -- a
## registry that answered from the asker's own offers would pass a weaker gate and fail the one
## thing the seam exists for (the flock the fatguy's run has to collide with).
func _check_entities(read: Dictionary, console: Object) -> void:
	if int(read.get("entity_near", -1)) != 2:
		_failures.append("goats.entities.near found %s of the two offered rows in range (and a third would mean a re-offer joined rather than replaced)"
			% read.get("entity_near"))
	if str(read.get("entity_from", "")) != "com.example.owner:blob":
		_failures.append("an offered entity's `from` is %s, and a name is namespaced to the mod that offered it"
			% read.get("entity_from"))
	var row: Array = read.get("entity_row", [])
	var wanted: Array = [1.0, 0.5, 0.0, 0.5, 1.0]
	if row.size() != wanted.size():
		_failures.append("an offered entity came back as %s, and a row is x, y, z, r and the distance"
			% row)
	else:
		for i: int in range(wanted.size()):
			if absf(float(row[i]) - float(wanted[i])) > 1e-6:
				_failures.append("an offered row's field %d is %s, and the offered row says %s"
					% [i, row[i], wanted[i]])
	# `range` is the ground plane's, so the row a metre away is outside a tenth of one.
	if int(read.get("entity_far", -1)) != 1:
		_failures.append("goats.entities.near(0, 0, 0.1) found %s, and only the row at the point is inside it"
			% read.get("entity_far"))
	# Three good rows survive a throwing offer and a malformed one, which is the isolation.
	if int(read.get("entity_threw", -1)) != 3:
		_failures.append("a throwing or malformed offer cost another mod its rows: near answered %s of three"
			% read.get("entity_threw"))
	if str(read.get("entity_offer_check")) != "threw":
		_failures.append("goats.entities.offer accepted a non-callback: %s"
			% read.get("entity_offer_check"))
	if str(read.get("entity_range_check")) != "threw":
		_failures.append("goats.entities.near accepted a negative range: %s"
			% read.get("entity_range_check"))
	# ...and the mod it could not ask is *named*, which is the whole of the isolation: the asker got
	# everybody else's rows, and the console says whose callback threw.
	var named := false
	if console != null:
		for line: Dictionary in console.get("lines"):
			var text: String = String(line.get("text", ""))
			if text.contains("entities.offer threw") and text.contains("com.example.owner"):
				named = true
	if not named:
		_failures.append("a throwing offer was not named on the console")
	print("entities: ", read.get("entity_near"), " in range from ", read.get("entity_from"),
		"  at a point ", read.get("entity_far"), "  past a throw ", read.get("entity_threw"),
		"  named ", named)

## The world mods' streams (`APIv1.md` section 4.13), held against the reference's own derivation
## rather than against a second copy of the port's: FNV-1a over the namespaced key, xorshift32 for
## the draw, and a fresh draw per stream from the session seed (`modSeedStreams`). The oracle is
## written *here* and never asked of the port, because this is the one member whose whole purpose is
## that two peers compute the same numbers -- a port that answered its own question would prove only
## that it was self-consistent, and the two implementations could still part.
##
## The streams the probe registers, in the order it registers them: the order is part of the answer,
## because `modSeedStreams` spends one draw of a shared sequence per stream.
const STREAMS := [
	{"key": "com.github.sdgoij.goats.birds:f", "seed": 0x5eed},
	{"key": "com.github.sdgoij.goats.birds:valueless", "seed": 0},
]
## The seed the scene is handed on a `session` event. Any non-zero value does; this one is the
## reference's own trap salt, picked so a transcription error in the derivation shows.
const STREAM_SEED := 0x2f6e2b1d

## The 32-bit signed reading of a value, which is what every `| 0` in `mods.js` means.
static func _i32(value: int) -> int:
	var low: int = value & 0xFFFFFFFF
	return low - 0x100000000 if low >= 0x80000000 else low

## An unsigned right shift, which GDScript's `>>` is not for a negative operand.
static func _ushr(value: int, bits: int) -> int:
	return (value & 0xFFFFFFFF) >> bits

## `modHashKey`: FNV-1a, 32-bit -- and the multiply is done in **double precision on purpose**,
## because that is what JavaScript's `>>> 0` sees. The product passes 2^53 for a 32-bit hash, where a
## double can no longer hold every integer and *rounds*: an exact 64-bit multiply takes different
## low bits, which is off by one at the third character and unrecognisable by the tenth. It is the
## same floor the port's `trap_noise` had to sit on (`PORT.md` section 9, the devices), and a
## transcription that "fixed" it would agree with nobody -- including the client it is copying.
static func _key_hash(key: String) -> int:
	var hash: int = 2166136261
	for i: int in key.length():
		hash = (hash ^ key.unicode_at(i)) & 0xFFFFFFFF
		var product: float = float(_i32(hash)) * 16777619.0
		hash = int(product) & 0xFFFFFFFF
	return hash

## `modRegisterStream`'s `initial`, including the two fall-throughs: a zero seed becomes the key's
## own hash, and a zero result becomes 1.
static func _stream_initial(key: String, seed: int) -> int:
	var initial: int = _i32(seed)
	if initial == 0:
		initial = _i32(0x9e3779b9) ^ _key_hash(key)
	initial = initial & 0xFFFFFFFF
	return 1 if initial == 0 else initial

## `modStreamNext`: one xorshift32 step, the draw it returns and the state it leaves.
static func _stream_step(state: int) -> Dictionary:
	var s: int = state & 0xFFFFFFFF
	s = s ^ ((s << 13) & 0xFFFFFFFF)
	s = s ^ _ushr(s, 17)
	s = s ^ ((s << 5) & 0xFFFFFFFF)
	s = s & 0xFFFFFFFF
	return {"draw": float(s) / 4294967296.0, "state": s}

## Advance one stream by one draw and answer it.
static func _stream_draw(states: Dictionary, key: String) -> float:
	var step: Dictionary = _stream_step(int(states[key]))
	states[key] = int(step["state"])
	return float(step["draw"])

## `modSeedStreams`: one draw of a shared sequence per stream, in insertion order, each mixed into
## the stream's own seed.
static func _seed_streams(states: Dictionary, seeds: Dictionary, order: Array, seed: int) -> void:
	var s: int = _i32(seed)
	if s == 0:
		s = 1
	for key: String in order:
		s = s ^ ((s << 13) & 0xFFFFFFFF)
		s = s & 0xFFFFFFFF
		s = s ^ _ushr(s, 17)
		s = s ^ ((s << 5) & 0xFFFFFFFF)
		s = s & 0xFFFFFFFF
		if s == 0:
			s = 1
		var mixed: int = int(seeds[key]) ^ s
		states[key] = 1 if mixed == 0 else mixed

## One `run_command` answer, as a table; empty when the probe did not answer with one.
func _mod_command(host: Object, name: String, line: String) -> Dictionary:
	var answer: Variant = JSON.parse_string(str(host.call("run_command", name, line)))
	return answer if answer is Dictionary else {}

func _check_streams(host: Object, mods: Object) -> void:
	var order: Array = []
	var seeds: Dictionary = {}
	var states: Dictionary = {}
	for entry: Dictionary in STREAMS:
		var key: String = str(entry["key"])
		order.append(key)
		seeds[key] = _stream_initial(key, int(entry["seed"]))
		states[key] = seeds[key]

	var first: Dictionary = _mod_command(host, "modstreams", "modstreams register")
	if first.is_empty():
		_failures.append("the streams probe did not answer with a table")
		return
	# The named seed is used as given; the zero one falls through to the key's hash, so the two
	# streams draw different sequences from the same file.
	var drawn_f: Array = []
	for i: int in range(3):
		drawn_f.append(_stream_draw(states, order[0]))
	var drawn_v: Array = []
	for i: int in range(2):
		drawn_v.append(_stream_draw(states, order[1]))
	_streams_match(first.get("f", []), drawn_f, "the first three draws of a named seed")
	_streams_match(first.get("v", []), drawn_v, "the draws of a stream whose seed is 0")
	if float(first.get("never", -1.0)) != 0.0:
		_failures.append("goats.rng on a name nobody registered answered %s, and the reference says 0"
			% first.get("never"))
	if str(first.get("client")) != "threw":
		_failures.append("a side:\"client\" mod was allowed to register a stream")
	if str(first.get("base")) != "threw":
		_failures.append("goats.world.registerStream answered outside a begin, and the reference has no such member")
	if str(first.get("base_rng")) != "undefined":
		_failures.append("goats.rng is %s on the base object, and the reference keeps it on the handle"
			% first.get("base_rng"))

	# ...and the seed, through the *scene's* own path: `mods.use_seed` is what the `session` event
	# calls, and `sceneUseSeed`'s last act is this same derivation.
	mods.call("use_seed", STREAM_SEED)
	_seed_streams(states, seeds, order, STREAM_SEED)
	var second: Dictionary = _mod_command(host, "modstreams", "modstreams draw")
	if second.is_empty():
		_failures.append("the streams probe did not answer after a seed")
		return
	var seeded_f: Array = []
	for i: int in range(2):
		seeded_f.append(_stream_draw(states, order[0]))
	var seeded_v: Array = []
	for i: int in range(1):
		seeded_v.append(_stream_draw(states, order[1]))
	_streams_match(second.get("f", []), seeded_f, "the draws after a session seed")
	_streams_match(second.get("v", []), seeded_v, "the seeded draws of a stream whose seed is 0")
	print("streams: f ", first.get("f"), " then ", second.get("f"),
		"  valueless ", first.get("v"), " then ", second.get("v"))

## Two rows of draws, field for field. A draw is a quotient of two exact doubles, so the tolerance
## is only here so a float32 somewhere cannot make the gate lie.
func _streams_match(got: Variant, want: Array, what: String) -> void:
	if not (got is Array) or (got as Array).size() != want.size():
		_failures.append("%s: the port answered %s and the reference derives %s" % [what, got, want])
		return
	var row: Array = got
	for i: int in range(want.size()):
		if absf(float(row[i]) - float(want[i])) > 1e-12:
			_failures.append("%s: draw %d is %s and the reference derives %s"
				% [what, i, row[i], want[i]])

## A point with an armed mine on it, found by scanning the derived field rather than guessed: the
## layout comes from the seed, so a hard-coded point can easily be one of the empty ones -- and a
## check that asked about an empty cell would pass for a `traps` that answered nothing.
func _armed_point(devices: Object) -> Vector2:
	for cx: int in range(-48, 49):
		for cz: int in range(-48, 49):
			if bool(devices.call("mine_armed", cx, cz)):
				return Vector2(float(cx * 2 + 1), float(cz * 2 + 1))
	return Vector2.ZERO

## The devices (`APIv1.md` section 4.15). `traps` is the scene's *own* derivation -- the one the
## `traps` console verb prints, factored out so a mod and the console cannot drift -- and `blast`
## has to be the core's bang, which is a claim about the scene's own state rather than about a
## return value: the counter rises and the cell is armed nowhere afterwards.
## The water's connected regions (`APIv1.md` section 4.17, `pools`), the *algorithm* as well as the
## crossing. The crossing is that the mod's array is the scene's, field for field; the algorithm is
## that the pools **partition the wet cells** -- the cells they claim are exactly the vertices the
## field stands over -- which is the property a flood fill can get wrong while still handing back
## plausible rows.
func _check_pools(read: Dictionary, water: Object) -> void:
	var pools: Variant = read.get("pools", null)
	if not (pools is Array):
		_failures.append("goats.water.pools did not answer with an array: %s" % pools)
		return
	var own: Array = water.call("pools")
	if (pools as Array).size() != own.size():
		_failures.append("goats.water.pools found %d pool(s), the scene's own derivation %d"
			% [(pools as Array).size(), own.size()])
	var wet: int = 0
	for k in Water.N * Water.N:
		if float(water.call("vertex_depth", k)) > 0.0:
			wet += 1
	var claimed: int = 0
	for row: Variant in (pools as Array):
		if not (row is Dictionary):
			_failures.append("a pool row is not an object: %s" % row)
			continue
		for key: String in ["x", "z", "r", "cells", "deepest", "deepX", "deepZ"]:
			if not (row as Dictionary).has(key):
				_failures.append("a pool row is missing %s: %s" % [key, row])
		claimed += int((row as Dictionary).get("cells", 0))
	if claimed != wet:
		_failures.append("the pools claim %d cell(s); the field stands over %d vertex(es)"
			% [claimed, wet])
	if wet <= 0 or (pools as Array).is_empty():
		_failures.append("a wetted field produced no pools (%d wet, %d pool(s)) -- nothing was checked"
			% [wet, (pools as Array).size()])
	for i in (pools as Array).size():
		# Field by field rather than by string: the crossing turns the scene's `cells` integer into
		# a float, which is a JSON detail and not a disagreement about the pool.
		var mine: Dictionary = pools[i]
		var theirs: Dictionary = own[i]
		if not _near(float(mine.get("x", 0.0)), float(theirs.get("x", 0.0))) \
				or not _near(float(mine.get("z", 0.0)), float(theirs.get("z", 0.0))) \
				or not _near(float(mine.get("r", 0.0)), float(theirs.get("r", 0.0))) \
				or not _near(float(mine.get("cells", 0.0)), float(theirs.get("cells", 0.0))) \
				or not _near(float(mine.get("deepest", 0.0)), float(theirs.get("deepest", 0.0))) \
				or not _near(float(mine.get("deepX", 0.0)), float(theirs.get("deepX", 0.0))) \
				or not _near(float(mine.get("deepZ", 0.0)), float(theirs.get("deepZ", 0.0))):
			_failures.append("pool %d crossed as %s, and the scene's is %s" % [i, mine, theirs])
	print("pools: ", (pools as Array).size(), " region(s), ", claimed, " of ", wet, " wet vertex(es)")

func _check_devices(host: Object) -> void:
	var devices: Object = _main.get("explosions")
	var found: Vector2 = _armed_point(devices)
	if found == Vector2.ZERO:
		_failures.append("the derived field has no armed mine in reach to ask about")
		return
	var cell: Vector2i = Meadow.cell_at(found.x, found.y)
	var want: Dictionary = devices.call("traps_near", found.x, found.y, 40.0)
	var before: int = int(devices.get("blasts"))
	var answer: Dictionary = _mod_command(host, "moddevices",
		"moddevices %f %f" % [found.x, found.y])
	if answer.is_empty():
		_failures.append("the devices probe did not answer with a table")
		return
	if int(answer.get("mines", -1)) != (want["mines"] as Array).size():
		_failures.append("goats.explosions.traps found %s mine(s) where the scene's own derivation has %d"
			% [answer.get("mines"), (want["mines"] as Array).size()])
	if int(answer.get("traps", -1)) != (want["traps"] as Array).size():
		_failures.append("goats.explosions.traps found %s trap(s) where the scene's own derivation has %d"
			% [answer.get("traps"), (want["traps"] as Array).size()])
	var mine: Variant = answer.get("mine")
	if not (mine is Dictionary) or not (mine as Dictionary).has("x") \
			or not (mine as Dictionary).has("key") or not (mine as Dictionary).has("dist"):
		_failures.append("goats.explosions.traps answered no usable mine row at a point that has one: %s"
			% answer.get("mine"))
	if answer.get("blast") != true:
		_failures.append("goats.explosions.blast did not answer true: %s" % answer.get("blast"))
	if int(devices.get("blasts")) != before + 1:
		_failures.append("a mod's bang did not reach the scene's own blast path (%d -> %s)"
			% [before, devices.get("blasts")])
	if bool(devices.call("mine_armed", cell.x, cell.y)):
		_failures.append("the device a mod set off is still armed in its own cell")
	if int(answer.get("single", -1)) != 0:
		_failures.append("the cell is still armed a moment after the bang (%s found)"
			% answer.get("single"))
	# `armed` (`APIv1.md` section 4.15): the field answers nothing while a mod has it away, and
	# `armed(true)` hands it back -- so the count comes home, which is what makes the toggle the
	# *derivation's* rather than a second device system.
	if answer.get("armed_before") != true:
		_failures.append("goats.explosions.armed() was %s with the field armed"
			% answer.get("armed_before"))
	if answer.get("armed_after") != false:
		_failures.append("goats.explosions.armed(false) left armed() at %s"
			% answer.get("armed_after"))
	if int(answer.get("off_mines", -1)) != 0 or int(answer.get("off_traps", -1)) != 0:
		_failures.append("the derivation still found a device with the field away: %s/%s"
			% [answer.get("off_mines"), answer.get("off_traps")])
	if int(answer.get("on_mines", -1)) != (want["mines"] as Array).size():
		_failures.append("armed(true) did not hand the field back: %s mine(s), the scene has %d"
			% [answer.get("on_mines"), (want["mines"] as Array).size()])
	# ...and a frame, because the `blast` event a mod's *own* bang produces is **queued** and said by
	# the frame rather than inside the bang: a bang a mod asked for runs in that mod's JavaScript,
	# where the extension is borrowed, and a call back into `ModHost` from there panics (`PORT.md`
	# section 9). So this line is the check for the re-entrancy, and an empty queue afterwards is
	# what says the frame took it rather than dropped it.
	var mods: Object = _main.get("mods")
	mods.call("frame", 12.0, Vector2(1280.0, 720.0), true, _main.get_node("Camera3D"))
	if not (devices.get("blast_events") as Array).is_empty():
		_failures.append("the frame left %d blast event(s) unsaid"
			% (devices.get("blast_events") as Array).size())
	print("devices: ", answer.get("mines"), " mine(s)  ", answer.get("traps"), " trap(s)  blast ",
		answer.get("blast"), "  blasts ", devices.get("blasts"))

## The identity and logging members (`APIv1.md` section 4.1): the API major, the game's version,
## the table, a mod's own row, and the three ways to say something -- each held against the
## *scene's* table, which is the one the Mods screen draws.
func _check_identity(read: Dictionary, mods: Object, console: Object) -> void:
	if int(read.get("api", -1)) != 1:
		_failures.append("goats.api is %s, and the API major is 1" % read.get("api"))
	if str(read.get("game", "")).is_empty():
		_failures.append("goats.game is empty")
	if read.get("frozen") != false:
		_failures.append("goats.frozen() is %s and nothing has frozen" % read.get("frozen"))
	var table: Array = mods.call("mod_table")
	if int(read.get("mods", -1)) != table.size():
		_failures.append("goats.mods() is %s row(s), the scene's table is %d"
			% [read.get("mods"), table.size()])
	if not table.is_empty():
		var first: Dictionary = table[0]
		if str(read.get("mod_id")) != str(first.get("id")):
			_failures.append("a mod's goats.mod.id is %s, the table says %s"
				% [read.get("mod_id"), first.get("id")])
		if str(read.get("mod_side")) != str(first.get("side")):
			_failures.append("a mod's goats.mod.side is %s, the table says %s"
				% [read.get("mod_side"), first.get("side")])
	# The level is carried, so a warning and a log line are told apart on the console.
	var said := false
	var warned := false
	if console != null:
		for line: Dictionary in console.get("lines"):
			var text: String = String(line.get("text", ""))
			if text.contains("surface: hello from the probe"):
				said = true
			if text.contains("warn surface: a warning"):
				warned = true
	if not said:
		_failures.append("goats.log did not reach the console")
	if not warned:
		_failures.append("goats.warn did not reach the console with its level")
	print("identity: api ", read.get("api"), "  game ", read.get("game"), "  mods ",
		read.get("mods"), "  mod ", read.get("mod_id"), "/", read.get("mod_side"),
		"  frozen ", read.get("frozen"))

## 1. The same read from inside a `hud` hook -- the frame the scene pushed, which is where a mod
## actually reads it. A surface that only answers a probe is not a surface a mod has.
func _check_hook(read: Dictionary, goat: Object) -> void:
	var from_hud: Variant = read.get("from_hud")
	if not (from_hud is Dictionary):
		_failures.append("a mod's hud hook could not read goats.player")
		return
	var hud: Dictionary = from_hud
	if not _near(float(hud.get("health", NAN)), float(goat.get("health"))):
		_failures.append("the hud hook read health %s, the goat has %s"
			% [hud.get("health"), goat.get("health")])
	if not _near(float(hud.get("x", NAN)), float(goat.get("px"))):
		_failures.append("the hud hook read x %s, the goat is at %s"
			% [hud.get("x"), goat.get("px")])
	print("hud hook: hp ", hud.get("health"), " at x ", snapshot_round(hud.get("x")))

## 2a. The goat's own fields, field for field.
func _check_player(read: Dictionary, goat: Object) -> void:
	var player: Dictionary = read.get("player", {})
	var wanted: Dictionary = {
		"mode": goat.get("mode"), "health": goat.get("health"), "energy": goat.get("energy"),
		"exhausted": goat.get("exhausted"), "satiety": goat.get("satiety"),
		"x": goat.get("px"), "y": goat.get("py"), "z": goat.get("pz"),
		"yaw": goat.get("yaw"), "phase": goat.get("phase"), "speed": goat.get("speed"),
	}
	for key: String in wanted.keys():
		var mine: Variant = player.get(key)
		var live: Variant = wanted[key]
		if live is float or live is int:
			if not _near(float(mine), float(live)):
				_failures.append("goats.player.state().%s is %s, the goat's is %s"
					% [key, mine, live])
		elif str(mine) != str(live):
			_failures.append("goats.player.state().%s is %s, the goat's is %s" % [key, mine, live])
	if str(player.get("clip")) != str(goat.call("playing_clip")):
		_failures.append("goats.player.state().clip is %s, the goat is playing %s"
			% [player.get("clip"), goat.call("playing_clip")])
	# The goat was driven for three frames before the read, so a snapshot that agreed with a
	# *standing* goat would not be agreeing with this one: a goat still at the origin means the
	# drive did not take and every field above was a default two sources share.
	if absf(float(goat.get("px"))) < 0.01 and absf(float(goat.get("pz"))) < 0.01:
		_failures.append("the goat never moved, so the player check proved nothing")
	print("player: ", player.get("mode"), "  hp ", player.get("health"),
		"  at (", snapshot_round(player.get("x")), ", ", snapshot_round(player.get("z")), ")")

## 2b. The weather machine, the wind the frame derived, and the height it stands the goat on.
func _check_world(read: Dictionary, weather: Object) -> void:
	var w: Dictionary = read.get("weather", {})
	if str(w.get("kind")) != str(weather.get("kind")):
		_failures.append("goats.world.weather().kind is %s, the machine's is %s"
			% [w.get("kind"), weather.get("kind")])
	if not _near(float(w.get("cloudiness", NAN)), float(weather.get("cloudiness"))):
		_failures.append("goats.world.weather().cloudiness is %s, the machine's is %s"
			% [w.get("cloudiness"), weather.get("cloudiness")])
	if not _near(float(w.get("rain", NAN)), float(weather.get("rain_amount"))):
		_failures.append("goats.world.weather().rain is %s, the machine's rain_amount is %s"
			% [w.get("rain"), weather.get("rain_amount")])
	# `weather().wind` is the sway share; `weather().speed` is *this goat's* own weather share.
	if not _near(float(w.get("wind", NAN)), float(_main.get("_wind_sway"))):
		_failures.append("goats.world.weather().wind is %s, the frame's sway is %s"
			% [w.get("wind"), _main.get("_wind_sway")])
	if not _near(float(w.get("speed", NAN)), float(_main.get("goat").call("weather_speed_now"))):
		_failures.append("goats.world.weather().speed is %s, the goat's weather share is %s"
			% [w.get("speed"), _main.get("goat").call("weather_speed_now")])
	var wind: Dictionary = read.get("wind", {})
	for pair: Array in [["x", wind.get("x"), _main.get("_wind_x")],
			["z", wind.get("z"), _main.get("_wind_z")],
			["sway", wind.get("sway"), _main.get("_wind_sway")]]:
		if not _near(float(pair[1]), float(pair[2])):
			_failures.append("goats.world.wind().%s is %s, the frame's is %s"
				% [pair[0], pair[1], pair[2]])
	# 5. The one *function* of the world, through the callback seam: the scene's own
	#    `Terrain.height_at`, craters and all.
	var point: Vector2 = _probe_point()
	var mine: float = float(read.get("terrain", NAN))
	var live: float = Terrain.height_at(point.x, point.y)
	if not _near(mine, live):
		_failures.append("goats.world.terrainHeight(%s, %s) is %s, the scene's is %s"
			% [point.x, point.y, mine, live])
	if absf(live) < 0.05:
		_failures.append("the terrain probe point is flat (%.4f), so it proves nothing" % live)
	print("weather: ", w.get("kind"), "  rain ", snapshot_round(w.get("rain")),
		"  terrainHeight ", snapshot_round(mine))

## 2c. The camera's three numbers, off the frame's own state.
func _check_camera(read: Dictionary) -> void:
	var c: Dictionary = read.get("camera", {})
	for pair: Array in [["yaw", c.get("yaw"), _main.get("_cam_yaw")],
			["pitch", c.get("pitch"), _main.get("_cam_pitch")],
			["dist", c.get("dist"), _main.get("_cam_dist")]]:
		if not _near(float(pair[1]), float(pair[2])):
			_failures.append("goats.camera.get().%s is %s, the frame's is %s"
				% [pair[0], pair[1], pair[2]])

## 2d. The `Settings` object, and the `herd` alias the API names.
func _check_settings(read: Dictionary, settings: Object, bots: Object) -> void:
	var s: Dictionary = read.get("settings", {})
	for pair: Array in [["bgm", s.get("bgm"), settings.get("bgm")],
			["sfx", s.get("sfx"), settings.get("sfx")],
			["light", s.get("light"), settings.get("light")],
			["shadow", s.get("shadow"), settings.get("shadow")],
			["sky", s.get("sky"), settings.get("sky")],
			["cloud", s.get("cloud"), settings.get("cloud")],
			["fullscreen", s.get("fullscreen"), settings.get("fullscreen")]]:
		if pair[2] is float or pair[2] is int:
			if not _near(float(pair[1]), float(pair[2])):
				_failures.append("goats.settings.get().%s is %s, the object's is %s"
					% [pair[0], pair[1], pair[2]])
		elif str(pair[1]) != str(pair[2]):
			_failures.append("goats.settings.get().%s is %s, the object's is %s"
				% [pair[0], pair[1], pair[2]])
	if int(s.get("herd", -1)) != int(bots.call("count")):
		_failures.append("goats.settings.get().herd is %s, the herd is %s"
			% [s.get("herd"), bots.call("count")])
	print("settings: bgm ", s.get("bgm"), "  shadow ", s.get("shadow"), "  herd ", s.get("herd"))

## 2e/4. The herd, against its own `report()`, and the promise that the handles are reused.
func _check_bots(read: Dictionary, bots: Object) -> void:
	var report: Array = bots.call("report")
	if int(read.get("bots_count", -1)) != report.size():
		_failures.append("goats.bots.count() is %s, the herd is %d"
			% [read.get("bots_count"), report.size()])
	if int(read.get("bots_len", -1)) != report.size():
		_failures.append("goats.bots.list() is %s long, the herd is %d"
			% [read.get("bots_len"), report.size()])
	if not bool(read.get("bots_reused", false)):
		_failures.append("goats.bots.list()/get() handed back fresh objects, and the API says reused")
	if not bool(read.get("bots_null", false)):
		_failures.append("goats.bots.get(99) is not null")
	if not report.is_empty():
		var bot0: Dictionary = read.get("bot0", {})
		var live: Dictionary = report[0]
		for pair: Array in [["id", bot0.get("id"), 0],
				["x", bot0.get("x"), live.get("x")],
				["z", bot0.get("z"), live.get("z")],
				["yaw", bot0.get("yaw"), live.get("yaw")],
				["mode", bot0.get("mode"), live.get("mode")]]:
			if pair[0] == "mode":
				if str(pair[1]) != str(pair[2]):
					_failures.append("goats.bots.list()[0].mode is %s, the bot's is %s"
						% [pair[1], pair[2]])
			elif not _near(float(pair[1]), float(pair[2])):
				_failures.append("goats.bots.list()[0].%s is %s, the herd's is %s"
					% [pair[0], pair[1], pair[2]])
	print("herd: ", read.get("bots_count"), " bot(s), first at (",
		snapshot_round((read.get("bot0", {}) as Dictionary).get("x")), ", ",
		snapshot_round((read.get("bot0", {}) as Dictionary).get("z")), ")")

## 3. The tuning tree, leaf by leaf, against the *module that owns each leaf* -- so this holds the
##    tree to its sources rather than to a second copy of the numbers.
func _check_tuning(read: Dictionary, bots: Object, reflect: Object) -> void:
	var t: Dictionary = read.get("tuning", {})
	var wanted: Dictionary = {
		"max": PlayerGoat.STATS_MAX,
		"drain_run": PlayerGoat.ENERGY_DRAIN["run"],
		"trot_stride": PlayerGoat.GAIT["trot"]["stride"],
		"relief": Terrain.RELIEF,
		"blast_lift": Explosions.BLAST_LIFT,
		"herd_count": bots.call("count"),
		"min_dist": Tuning.CAMERA_MIN_DIST,
		"water_on": 1,
		"reflect": reflect.get("wish"),
	}
	for key: String in wanted.keys():
		if not _near(float(t.get(key, NAN)), float(wanted[key])):
			_failures.append("goats.tuning.get(...).%s is %s, the module's is %s"
				% [key, t.get(key), wanted[key]])
	if int(t.get("steps", 0)) != 3:
		_failures.append("goats.tuning.get(\"sky.steps\") has %s entries, the sky has 3"
			% t.get("steps"))
	if not bool(t.get("branch", false)):
		_failures.append("goats.tuning.get(\"explosions.blast\") is not a branch")
	# An unknown path throws, which is the API's own contract and is what makes a typo -- or a
	# leaf this client never ported -- loud rather than answered with `undefined`.
	if str(read.get("tuning_unknown")) != "threw":
		_failures.append("goats.tuning.get on an unknown path did not throw")
	# ...and every leaf the tree *registers* resolves in the snapshot the scene builds. The leaf table
	# is the tree's own shape, and a typo'd field name -- the one thing reaching a `static var` by
	# name through `Object.get` can hide -- would leave a leaf reading `null` rather than failing
	# loudly. The probe's `t` above is its own sample; this is the whole tree, built the way the
	# scene pushes it.
	var full: Dictionary = (_main.call("_mod_snapshot") as Dictionary).get("tuning", {})
	var missing: Array = []
	for path: String in Tuning._leaves():
		var node: Variant = full
		for part: String in path.split("."):
			if not (node is Dictionary) or not (node as Dictionary).has(part):
				node = null
				break
			node = (node as Dictionary)[part]
		if node == null:
			missing.append(path)
	if not missing.is_empty():
		_failures.append("the tuning tree is missing %d leaf(s) it registers: %s"
			% [missing.size(), ", ".join(PackedStringArray(missing))])
	print("tuning: stats.max ", t.get("max"), "  blast.lift ", t.get("blast_lift"),
		"  herd.count ", t.get("herd_count"), "  sky.steps ", t.get("steps"),
		"  ", Tuning._leaves().size(), " leaf(s) resolved")

## 2f. The session's read, off the frame's own net state. Offline the scene is its own world.
func _check_calls(read: Dictionary) -> void:
	var net: Dictionary = read.get("net", {})
	if str(net.get("mode")) != "off":
		_failures.append("goats.net.mode() is %s with no session" % net.get("mode"))
	if net.get("local") != true:
		_failures.append("goats.net.localWorld() is %s with no session" % net.get("local"))
	if net.get("session") != false or net.get("host") != false:
		_failures.append("goats.net says a session is up with no ticket")
	if str(net.get("name")) != "":
		_failures.append("goats.net.name() is %s with no session" % net.get("name"))
	print("net: ", net.get("mode"), "  localWorld ", net.get("local"))

## The writes (`APIv1.md` sections 4.5-4.12), held against the **scene's own** fields -- which
## is the whole of a write's contract: the simulation is the thing that has to keep its invariants.
## The readable groups answer from the frame pushed *before* the probe ran, so a mod's own read one
## instant later cannot show the effect; the scene can, and it is what the reference client's writes
## move too. The tuning tree is held the same way (against the modules that own the leaves), and the
## one family the port has still not got (`assets.override`) is asserted as a refusal with them, so a
## member that quietly became a no-op would show.
func _check_writes(read: Dictionary, main: Node) -> void:
	var goat: Object = main.get("goat")
	var bots: Object = main.get("bots")
	var settings: Object = main.get("settings")
	var weather: Object = main.get("weather")
	var wrote: Dictionary = read.get("wrote", {})

	# The player: `restart` first (a full goat, because a full goat restarting to full is a check
	# that cannot fail), then a position, a heading and the modes a script may enter.
	if not _near(float(goat.get("health")), PlayerGoat.STATS_MAX) \
			or not _near(float(goat.get("energy")), PlayerGoat.STATS_MAX):
		_failures.append("player.restart did not refill the goat: %s/%s"
			% [goat.get("health"), goat.get("energy")])
	if not _near(float(goat.get("px")), float(wrote.get("x", 0.0))) \
			or not _near(float(goat.get("pz")), float(wrote.get("z", 0.0))):
		_failures.append("player.teleport did not move the goat: (%s, %s)"
			% [goat.get("px"), goat.get("pz")])
	if not _near(float(goat.get("yaw")), float(wrote.get("yaw", 0.0))):
		_failures.append("player.face did not turn the goat: %s" % goat.get("yaw"))
	if read.get("mode_gait") != true:
		_failures.append("player.setMode(\"trot\") answered %s" % read.get("mode_gait"))
	if read.get("mode_eat") != false or read.get("mode_dead") != false:
		_failures.append("player.setMode answered %s/%s for eat/dead -- the simulation's own"
			% [read.get("mode_eat"), read.get("mode_dead")])
	if str(goat.get("mode")) != "trot":
		_failures.append("the gait write did not land: goat.mode is %s" % goat.get("mode"))

	# The camera: partial, and the two clamps are the reference's own numbers.
	var cam: Dictionary = main.call("cmd_camera")
	if not _near(float(cam["yaw"]), float(wrote.get("yaw", 0.0))):
		_failures.append("camera.set did not take the yaw: %s" % cam["yaw"])
	if not _near(float(cam["pitch"]), Tuning.CAMERA_MAX_PITCH):
		_failures.append("camera.set did not clamp the pitch to %s: %s"
			% [Tuning.CAMERA_MAX_PITCH, cam["pitch"]])
	if not _near(float(cam["dist"]), Tuning.CAMERA_MIN_DIST):
		_failures.append("camera.set did not clamp the distance to %s: %s"
			% [Tuning.CAMERA_MIN_DIST, cam["dist"]])

	# The settings: a partial object, through the scene's own apply.
	if int(round(float(settings.get("bgm")))) != 17:
		_failures.append("settings.set did not take the gain: %s" % settings.get("bgm"))
	if str(settings.get("cloud")) != "high":
		_failures.append("settings.set did not take the cloud: %s" % settings.get("cloud"))

	# The clock and the weather: local-only, and they answer rather than throw.
	if read.get("set_time") != true or not _near(float(main.call("cmd_hours")), 3.0):
		_failures.append("world.setTime did not take: %s / %s"
			% [read.get("set_time"), main.call("cmd_hours")])
	if read.get("set_weather") != true or str(weather.get("kind")) != "rain":
		_failures.append("world.setWeather did not take: %s / %s"
			% [read.get("set_weather"), weather.get("kind")])
	if read.get("set_weather_bad") != false:
		_failures.append("world.setWeather answered %s for a state it has not got"
			% read.get("set_weather_bad"))

	# The chat line: reported by value, and offline the *session* gate answers first -- which is the
	# reference's own order (`netSay` checks the session before it looks at the text), so an empty
	# line offline is the same refusal.
	if str(read.get("say")) != "error not in a session":
		_failures.append("net.say did not refuse with no session: %s" % read.get("say"))
	if str(read.get("say_empty")) != "error not in a session":
		_failures.append("net.say answered an empty line offline with: %s" % read.get("say_empty"))

	# The herd: the size, and the four verbs on a live handle -- read back off the scene's own
	# `report()`, because that is the live herd and not the snapshot the mod reads.
	if int(read.get("bot_count", -1)) != 3 or int(bots.call("count")) != 3:
		_failures.append("bots.setCount did not resize the herd: %s / %s"
			% [read.get("bot_count"), bots.call("count")])
	var report: Array = bots.call("report")
	if report.is_empty():
		_failures.append("the herd is empty after bots.setCount(3)")
	else:
		var one: Dictionary = report[0]
		var bw: Dictionary = read.get("bot_wrote", {})
		if not _near(float(one.get("x", 0.0)), float(bw.get("x", 0.0))) \
				or not _near(float(one.get("z", 0.0)), float(bw.get("z", 0.0))) \
				or not _near(float(one.get("yaw", 0.0)), float(bw.get("yaw", 0.0))):
			_failures.append("a bot handle's teleport/face did not land: %s" % one)

	# The tuning tree (`APIv1.md` section 4.10): each write is held against the module that *owns*
	# the leaf, because the tree is a view of the constants and not a second copy. A clamp
	# (`herd.deathLinger` 0.1 -> 0.5), an int (`relocate.tries` 7.6 -> 8) and a nested member
	# (`stats.energyDrain.idle`) prove the coercion and the keys; `merge` proves the recursion.
	var tune: Dictionary = read.get("tune", {})
	if not _near(float(Tuning.CAMERA_DIST), 6.75) or not _near(float(tune.get("set", 0.0)), 6.75):
		_failures.append("tuning.set(\"camera.dist\", 6.75) did not land: %s / %s"
			% [Tuning.CAMERA_DIST, tune.get("set")])
	if int(Explosions.RELOCATE_TRIES) != 8 or int(tune.get("int", 0)) != 8:
		_failures.append("tuning.set on an int leaf stored %s, not 8" % Explosions.RELOCATE_TRIES)
	if not _near(float(Bots.DEATH_LINGER), 0.5):
		_failures.append("tuning.set(\"herd.deathLinger\", 0.1) stored %s, not the clamp 0.5"
			% Bots.DEATH_LINGER)
	if not _near(float(PlayerGoat.ENERGY_DRAIN["idle"]), 1.25):
		_failures.append("tuning.set(\"stats.energyDrain.idle\", 1.25) left the drain at %s"
			% PlayerGoat.ENERGY_DRAIN["idle"])
	if not _near(float(SkyDome.CLOUD_ABSORB), 1.5) or not _near(float(Tuning.CAMERA_PITCH), 0.5):
		_failures.append("tuning.merge did not land: absorb %s, pitch %s"
			% [SkyDome.CLOUD_ABSORB, Tuning.CAMERA_PITCH])
	for part: String in ["branch", "unknown", "type"]:
		if str(read.get("tune_" + part)) != "threw":
			_failures.append("tuning.set on a %s path did not throw" % part)
	# ...and a leaf the *scene* owns routes to the scene's own setter -- `herd.count` is the herd's
	# size and `water.enabled` the table's switch, so the write is the same one the console makes.
	if int(_seam(main, "tuning.set", ["herd.count", 4])) != 4 or int(bots.call("count")) != 4:
		_failures.append("tuning.set(\"herd.count\", 4) did not resize the herd: %s"
			% bots.call("count"))
	if int(_seam(main, "tuning.set", ["water.enabled", 0])) != 0 \
			or bool(main.get("water").get("enabled")):
		_failures.append("tuning.set(\"water.enabled\", 0) did not switch the water off")

	# The asset writes are in but *gated* (`APIv1.md` section 4.11): legal only while a mod's own
	# entry runs, and this probe is a command, so both are refused. (The success path is an entry,
	# held by `_check_staged_assets`.)
	for member: String in ["asset_write", "asset_add"]:
		if str(read.get(member)) != "threw":
			_failures.append("a write outside an entry (%s) did not throw: %s"
				% [member, read.get(member)])

	# ...and the two local-only writes answer `false` for a *client*, which is the API's "could not
	# take effect" rather than a refusal (`APIv1.md` section 4.7). The flag is the scene's own
	# `_joined`, stood up here rather than bound to a real session, and each is asked through the
	# seam the extension uses -- so this is a check on the real `_mod_call` and not on a copy of it.
	main.set("_joined", true)
	var before_hours: float = float(main.call("cmd_hours"))
	if _seam(main, "world.setTime", [6.0]) != false:
		_failures.append("world.setTime did not answer false for a client")
	if _seam(main, "world.setWeather", ["clear"]) != false:
		_failures.append("world.setWeather did not answer false for a client")
	if not _near(float(main.call("cmd_hours")), before_hours):
		_failures.append("a client's setTime moved the clock anyway: %s" % main.call("cmd_hours"))
	main.set("_joined", false)
	print("writes: player/camera/settings/world/net/bots/tuning took, the two local-only ones " +
		"answer false for a client, and the asset writes are refused outside an entry")

## The two code-side slot writes (`APIv1.md` section 4.11) are legal only while a mod's *own entry*
## runs -- this client's stand-in for "before the freeze" -- so the success path needs an entry, and
## the repository's mods make neither call. The gate stages one: a mod whose entry overrides a slot,
## joins another, tries to join a single-file one, then registers a verb that reports what it
## answered and re-tries both from *outside* the window. Staged rather than shipped for
## `verify_scene_mods`' own reason (every checked-in mod must load), and last, because it replaces
## the loaded set.
func _check_staged_assets(host: Object) -> void:
	var uri: String = "user://gates-assets/assets"
	DirAccess.make_dir_recursive_absolute(uri)
	# The host is Rust and reads with `std::fs`, so it needs a real path: `user://` means nothing to
	# it (`verify_scene_mods` has the same note for the same reason).
	var dir: String = ProjectSettings.globalize_path("user://gates-assets")
	var source := """
const out = {};
out.before = goats.assets.all(\"sfx.bleat\").length;
try { out.override = goats.assets.override(\"model.goat\", \"mod:com.example.assets:goat.glb\"); }
catch (error) { out.override = String(error); }
try { out.added = goats.assets.add(\"sfx.bleat\", \"mod:com.example.assets:bleat.wav\"); }
catch (error) { out.added = String(error); }
out.after = goats.assets.all(\"sfx.bleat\").length;
try { out.single = goats.assets.add(\"sfx.music\", \"mod:com.example.assets:track.ogg\"); }
catch (error) { out.single = String(error); }
out.slot = goats.assets.get(\"model.goat\");
globalThis.__stagedAssets = out;
goats.command("stagedassets", function () {
    const seen = Object.assign({}, globalThis.__stagedAssets);
    // ...and the same two writes from *outside* the entry are refused.
    try { goats.assets.override("model.goat", "x"); seen.after_window = "answered"; }
    catch (error) { seen.after_window = String(error); }
    seen.kept = goats.assets.get("model.goat");
    return JSON.stringify(seen);
});
"""
	var written: Array = [
		["mod.json", JSON.stringify({
			"id": "com.example.assets", "name": "Assets", "version": "1.0.0", "api": 1,
			"side": "client", "entry": "mod.js",
		})],
		["mod.js", source],
	]
	for pair: Array in written:
		var file: FileAccess = FileAccess.open(uri + "/" + String(pair[0]), FileAccess.WRITE)
		if file == null:
			_failures.append("could not stage the asset mod (%s)" % pair[0])
			return
		file.store_string(String(pair[1]))
		file.close()
	host.call("load_mods", dir)
	host.call("load_all")
	var raw: String = str(host.call("run_command", "stagedassets", "stagedassets"))
	var seen: Variant = JSON.parse_string(raw)
	if not (seen is Dictionary):
		_failures.append("the staged asset probe did not answer with a table: " + raw)
		return
	var read: Dictionary = seen
	if read.get("override") != true:
		_failures.append("assets.override inside an entry answered %s" % read.get("override"))
	if read.get("added") != true:
		_failures.append("assets.add inside an entry answered %s" % read.get("added"))
	if str(read.get("slot")) != "mod:com.example.assets:goat.glb":
		_failures.append("an entry's override did not reach the slot: %s" % read.get("slot"))
	if int(read.get("after", 0)) != int(read.get("before", -1)) + 1:
		_failures.append("an entry's add did not join the bleat list: %s -> %s"
			% [read.get("before"), read.get("after")])
	if not str(read.get("single")).contains("no list to join"):
		_failures.append("assets.add on a single-file slot answered %s" % read.get("single"))
	if not str(read.get("after_window")).contains("registration is closed"):
		_failures.append("assets.override outside an entry answered %s" % read.get("after_window"))
	if str(read.get("kept")) != "mod:com.example.assets:goat.glb":
		_failures.append("an entry's override did not survive its window: %s" % read.get("kept"))
	print("staged assets: override ", read.get("override"), "  add ", read.get("added"),
		"  bleats ", read.get("before"), "->", read.get("after"), "  outside ",
		read.get("after_window"))

## 6b. The `"tuning"` event (`APIv1.md` section 4.2): `(path, value)`, once per changed leaf, said by
##     the frame that follows the write. The probe's writes are the changes, so the listener's list
##     must carry each path -- a leaf a module owns (`stats.energyDrain.idle`) and one the *scene*
##     owns (`herd.count`) -- with the coerced value and not the value it was handed.
func _check_tuning_event(events: Variant) -> void:
	if not (events is Array):
		_failures.append("the tuning listener did not answer with a table")
		return
	var list: Array = events
	var seen: Dictionary = {}
	for event: Dictionary in list:
		seen[str(event.get("path"))] = event.get("value")
	for path: String in ["camera.dist", "stats.energyDrain.idle", "sky.absorb", "camera.pitch",
			"explosions.relocate.tries", "herd.deathLinger", "herd.count", "water.enabled"]:
		if not seen.has(path):
			_failures.append("the \"tuning\" event never named %s" % path)
	if seen.has("camera.dist") and not _near(float(seen["camera.dist"]), 6.75):
		_failures.append("the \"tuning\" event's value for camera.dist is %s, not 6.75"
			% seen["camera.dist"])
	if seen.has("explosions.relocate.tries") and int(seen["explosions.relocate.tries"]) != 8:
		_failures.append("the \"tuning\" event carried %s for an int leaf that stores 8"
			% seen["explosions.relocate.tries"])
	if seen.has("herd.count") and int(seen["herd.count"]) != 4:
		_failures.append("the \"tuning\" event's value for herd.count is %s, not 4" % seen["herd.count"])
	print("tuning event: ", list.size(), " change(s), herd.count ", seen.get("herd.count"))

## One crossing through the scene's own `_mod_call`, the way the extension makes it, handing back
## the `ok` value. A check on a write's *answer* goes through the real seam this way.
func _seam(main: Node, name: String, args: Array) -> Variant:
	var answer: Variant = JSON.parse_string(str(main.call("_mod_call", name, JSON.stringify(args))))
	if not (answer is Dictionary):
		return null
	return (answer as Dictionary).get("ok", null)

## A float comparison that tolerates the JSON the readings crossed through.
func _near(mine: float, live: float) -> bool:
	if is_nan(mine) or is_nan(live):
		return false
	return absf(mine - live) < 1e-6

## The point of largest relief the terrain callback is asked about.
func _probe_point() -> Vector2:
	if _probe_found:
		return _probe
	_probe_found = true
	var best := 0.0
	for ix in range(-TERRAIN_SPAN, TERRAIN_SPAN + 1):
		for iz in range(-TERRAIN_SPAN, TERRAIN_SPAN + 1):
			var px: float = float(ix) * TERRAIN_STEP
			var pz: float = float(iz) * TERRAIN_STEP
			# Outside the spawn bowl, which is deliberately level (`Terrain.FLAT`).
			if px * px + pz * pz < 400.0:
				continue
			var h: float = Terrain.height_at(px, pz)
			if absf(h) > best:
				best = absf(h)
				_probe = Vector2(px, pz)
	return _probe

## A number as a short string, for the transcript only.
func snapshot_round(value: Variant) -> String:
	if value == null:
		return "?"
	return "%.3f" % float(value)
