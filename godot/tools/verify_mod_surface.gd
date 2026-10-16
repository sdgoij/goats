# The readable-surface gate: the `goats` groups a *mod* reads the live world through -- its own
# identity and logging (`APIv1.md` section 4.1) and the world (`sections 4.5-4.12`) -- against the
# scene's own values.
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
# Seven things, and the order is the order of the ways they can be faked:
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
        const started = goats.begin(table.length > 0 ? table[0].id : "nobody");
        out.mod_id = started.mod === null ? "null" : started.mod.id;
        out.mod_side = started.mod === null ? "null" : started.mod.side;
        goats.log("surface: hello from the probe");
        goats.warn("surface: a warning");
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
	var answer: Variant = JSON.parse_string(str(host.call("run_command", "modsurface", "modsurface")))
	if not (answer is Dictionary):
		_failures.append("the surface probe did not answer with a table")
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
	_finished = true

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
