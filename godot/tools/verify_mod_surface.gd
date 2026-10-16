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
#   3. **The tuning tree mirrors its sources.** Every leaf is a module's constant (`stats.max` is
#      `PlayerGoat.STATS_MAX`, `explosions.blast.lift` is `Explosions.BLAST_LIFT`), so the gate
#      holds the tree against the modules rather than against a second literal -- and an absent
#      path throws, which is the API's own contract.
#   4. **The handles are reused**, which `APIv1.md` section 4.8 promises and `PERF.md` appendix B
#      pays for: `list()` twice is the same array, and `get(0)` is the same object as `list()[0]`.
#   5. **The one functional read crosses and answers** -- `terrainHeight` against `Terrain.height_at`,
#      the scene's own function including the craters.
#   6. **A write is refused, clearly.** The clock and the weather are the API's documented *safe*
#      pair and answer `false`; every other write is a thrown error naming the member, which the
#      mod's own hook isolation logs rather than swallowing (`APIv1.md` section 7).
#   7. **The asset slots have both of their owners** (`assets`, section 4.11). This is the one group
#      two things supply -- the built-in half is the scene's own table and the declared half is the
#      mods' -- so what is held is that both are visible, that a built-in slot's name really loads
#      through `gfx.model`, that a join **appends** rather than displacing, and that `get` answers
#      with what the slot holds, which is the reference client's own shape and not a tidier one.
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

        // The writes: the clock and the weather are the API's safe pair, and answer `false`;
        // everything else is refused with a thrown error that names the member.
        out.set_time = goats.world.setTime(3);
        out.set_weather = goats.world.setWeather("rain");
        try { goats.player.teleport(1, 2); out.teleport = "answered"; }
        catch (error) { out.teleport = "threw"; }
        try { goats.settings.set({ bgm: 10 }); out.setting = "answered"; }
        catch (error) { out.setting = "threw"; }
        try { goats.bots.get(0).zoomies(3); out.zoomies = "answered"; }
        catch (error) { out.zoomies = "threw"; }

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
        owner.entities.offer("blob", function () { return [[1, 0.5, 0, 0.5], [9, 9, 9, 1]]; });
        owner.entities.offer("junk", function () { return [[0, 0, 0, 9]]; });
        // A second offer under one name replaces the first, rather than joining it -- which is what
        // the count below holds: the displaced row was inside the range too, so a *join* would have
        // answered three.
        owner.entities.offer("junk", function () { return [[0, 0, 0, 0.25]]; });
        const near = asker.entities.near(0, 0, 2);
        out.entity_near = near.length;
        out.entity_from = near.length > 0 ? near[0].from : null;
        out.entity_row = near.length > 0
            ? [near[0].x, near[0].y, near[0].z, near[0].r, near[0].d] : null;
        // The range is the ground plane's, so the far one is dropped and the near one kept.
        out.entity_far = asker.entities.near(0, 0, 0.1).length;
        // A callback that throws costs *its own* mod's entities for that query and nobody
        // else's, and a row that is not four finite numbers is skipped rather than thrown.
        owner.entities.offer("boom", function () { throw new Error("nope"); });
        owner.entities.offer("junkrows", function () {
            return [[1, 2, 3], ["a", "b", "c", "d"], [0, 0, 0, 0.5], null];
        });
        out.entity_threw = asker.entities.near(0, 0, 2).length;
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
        // The bang goes through the *core's* path, so the scene's own count rises and the device is
        // spent -- and a spent device is a cell that is armed nowhere, which the query below says.
        out.blast = goats.explosions.blast(x, z, "mine");
        out.single = goats.explosions.traps(x, z, 1).mines.length;
        try {
            goats.explosions.armed(false);
            out.armed = "answered";
        } catch (error) {
            out.armed = "threw";
        }
        return JSON.stringify(out);
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
	_check_writes(read)
	# A second frame, so anything the probe *said* is drained into the console before the identity
	# check reads it: the first frame ran before the probe answered, and a log line lands in the
	# host's queue when it is said and not when the frame is drawn.
	mods.call("frame", _main.call("cmd_hours"), Vector2(1280.0, 720.0), true,
		_main.get_node("Camera3D"), snapshot)
	_check_identity(read, mods, _main.get("console"))
	_check_assets(read)
	_check_entities(read, _main.get("console"))
	_check_streams(host, mods)
	_check_devices(host)
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
	if str(answer.get("armed")) != "threw":
		_failures.append("goats.explosions.armed did not throw: %s" % answer.get("armed"))
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
	print("tuning: stats.max ", t.get("max"), "  blast.lift ", t.get("blast_lift"),
		"  herd.count ", t.get("herd_count"), "  sky.steps ", t.get("steps"))

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

## 6. A write is refused, and the way each refusal reads is the one its signature documents.
func _check_writes(read: Dictionary) -> void:
	# The API's safe pair: safe to call, and `false` says it could not take effect.
	if read.get("set_time") != false:
		_failures.append("goats.world.setTime did not answer false: %s" % read.get("set_time"))
	if read.get("set_weather") != false:
		_failures.append("goats.world.setWeather did not answer false: %s" % read.get("set_weather"))
	for member: String in ["teleport", "setting", "zoomies"]:
		if str(read.get(member)) != "threw":
			_failures.append("a refused write (%s) did not throw: %s"
				% [member, read.get(member)])
	print("writes: setTime/setWeather false, and refused writes thrown")

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
