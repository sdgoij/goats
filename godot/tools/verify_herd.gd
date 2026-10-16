# The mirror gate (M11/M21): what a world snapshot does to the herd a client sees.
#
#   Godot --headless --path godot --script res://tools/verify_herd.gd
#
# `herd.gd` is the whole of the client's half of the world -- a joiner simulates no herd and places
# what the host tells it to -- and its rules lived only in the interop runs, which need a session
# and a server. That is where a real defect hid: the scene's `world` arm kept a herd from arriving
# until it had *bots in it*, so a world that said "no herd" was one this end ignored. The flock then
# stood where it was last told to stand for the rest of the session, which is what a player reports
# as "the host's herd is frozen" -- and the host is allowed to have none: the herd's size is
# `TUNING.herd.count`, a *setting* the settings screen, the console and a mod all write
# (`bots.js`'s own `tuningWatch("herd.count", ...)`), so zero is a legitimate world.
#
# The rule under it is `netApplyWorld`'s, transcribed here from `net.js` itself:
#
#     if (!Array.isArray(bots)) return;
#     if (BOTS.length !== bots.length) setHerdSize(bots.length);
#
#   * a `bots` **list** is adopted, and its *length is the herd's length* -- three goats, two, or
#     none at all, which is a herd of zero rather than a field that was left out;
#   * a world with **no** `bots` at all is the half-built one `goatsd` publishes while it loads its
#     scene, and it keeps what this end has -- the early return above, which is the one place the
#     two cases differ and the reason the arm cannot simply default to an empty list.
#
# Everything here is driven through the *scene's* own event arm (`main.gd`'s `_handle`), because
# that is where both halves live: `Herd.apply` has always emptied itself on a list that lost a goat,
# and it was the arm in front of it that decided whether it was asked. No session is started -- a
# `world` event is a line, and a line is what `_handle` takes.
extends SceneTree

## The least the mirror has to have converged for a placement claim to be about the wire rather
## than about the easing: `Herd._process` covers a fixed fraction of the gap per frame, so this is
## waited for rather than assumed (see `_settling`).
const TOLERANCE := 0.05
## How long that wait may take, in **seconds of the frame's own clock**. Time rather than frames,
## because the ease is `min(1, delta * SMOOTH)`: three quarters of a second closes the gap to
## `exp(-9)` of itself whatever rate the loop runs at, while a headless loop is uncapped and a frame
## count would be a different wait on every machine.
const SETTLE_SECONDS := 0.75

## The three goats of the first world: index, where the host put it, and the gait it is in. The
## last one is `dead`, whose clip is the model's `GoatDeath` rather than the gait's own name --
## the one row of `Herd._clip_for`'s table that is not a capitalised gait.
const THREE := [
	{"index": 0, "x": 4.0, "z": -2.0, "yaw": 0.5, "phase": 0.25, "gait": "walk", "py": 0},
	{"index": 1, "x": -6.0, "z": 3.0, "yaw": -1.0, "phase": 0.6, "gait": "trot", "py": 0},
	{"index": 2, "x": 8.0, "z": 7.0, "yaw": 2.0, "phase": 0.4, "gait": "dead", "py": 0},
]
## The same flock with the third goat gone, which is a bot a host that shrank its herd no longer
## names: a mirror that cannot forget is a leak, and one that *blinks* has lost a goat the host
## still has.
const TWO := [
	{"index": 0, "x": 4.0, "z": -2.0, "yaw": 0.5, "phase": 0.25, "gait": "walk", "py": 0},
	{"index": 1, "x": -6.0, "z": 3.0, "yaw": -1.0, "phase": 0.6, "gait": "trot", "py": 0},
]

var _main: Node
var _frames := 0
var _phase := 0
## Seconds spent settling onto the last snapshot, which is this gate's own clock.
var _settle := 0.0
var _failures: Array[String] = []

func _initialize() -> void:
	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return
	# The scene is instantiated here and read a few frames later: `SceneTree.root` is not inside the
	# tree while `_initialize` runs (the trap `verify_console.gd` names).
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	var herd: Node = _main.get("herd")
	if herd == null:
		_failures.append("the scene did not build a Herd")
		return _finish()
	match _phase:
		# A world that names three goats: the mirror builds exactly those, in the poses the gaits
		# name, and then settles onto the spots the wire carried (rather than staying at the
		# origin a goat it just built is standing on).
		0:
			_world({"bots": THREE, "weather": {"kind": "clear", "cloudiness": 0.2,
				"rain_amount": 0.0, "wind_x": 1.0, "wind_z": 0.0, "wind_sway": 0.3}})
			_expect_count(herd, 3, "a world naming three goats")
			_expect_indexes(herd, [0, 1, 2], "a world naming three goats")
			_expect_gait(herd, 0, "walk", "a walking bot")
			_expect_gait(herd, 2, "dead", "a dead bot")
			_expect_clip(herd, 2, "GoatDeath", "a bot on the `dead` gait")
			_phase = 1
			_settle = 0.0
		1:
			if _settling(herd, delta):
				return false
			_expect_spots(herd)      # the drawn flock is the wire's, after the easing
			# ...and the herd a host shrank: the goat it no longer names is gone, and the two it
			# still does are where they were.
			_world({"bots": TWO})
			_expect_count(herd, 2, "a world that dropped a goat")
			_expect_indexes(herd, [0, 1], "a world that dropped a goat")
			_phase = 2
			_settle = 0.0
		2:
			if _settling(herd, delta):
				return false
			# **The empty flock.** This is the case the report was about: the host has no herd --
			# its size is a setting, and the settings screen's own "Herd size" slider can take it
			# to zero -- so the mirror holds none. A gate that kept the last flock here is a herd
			# standing still for the rest of the session.
			_world({"bots": []})
			_expect_count(herd, 0, "a world whose herd is empty")
			_expect_indexes(herd, [], "a world whose herd is empty")
			_phase = 3
			_settle = 0.0
		3:
			if _settling(herd, delta):
				return false
			# A flock again, and then a world that says nothing about the herd at all: the
			# half-built snapshot a loading host publishes, which keeps what this end has -- the
			# *only* difference from the empty list above.
			_world({"bots": TWO})
			_world({"weather": {"kind": "rain", "cloudiness": 0.8, "rain_amount": 0.5,
				"wind_x": 0.0, "wind_z": 2.0, "wind_sway": 0.6}})
			_expect_count(herd, 2, "a world with no `bots` field")
			_expect_indexes(herd, [0, 1], "a world with no `bots` field")
			var worlds: int = int(_main.get("_worlds"))
			if worlds != 4:
				_failures.append("the world clock counted %d snapshots carrying a herd, not 4" % worlds)
			var last: int = int(_main.get("_last_bots"))
			if herd.call("count") != last:
				_failures.append("the mirror holds %d goat(s) and the last snapshot named %d"
					% [int(herd.call("count")), last])
			print("worlds: ", worlds, ", last snapshot: ", last, " bot(s)")
			for line in herd.call("describe"):
				print(line)
			return _finish()
	return false

## One event, exactly as the session would hand it over: a line of JSON into the scene's own arm.
## Nothing else is faked -- the arm, the herd and the bookkeeping beside it are the ones that ship.
func _world(event: Dictionary) -> void:
	var line: Dictionary = event.duplicate()
	line["type"] = "world"
	_main.call("_handle", JSON.stringify(line))

## Whether the easing still has a goat to move onto its target, and counting the time it has spent
## doing it. A `Herd` that is converging answers `worst_gap() > 0` for a while; one that never
## arrives is what the budget is for.
func _settling(herd: Node, delta: float) -> bool:
	_settle += delta
	if float(herd.call("worst_gap")) <= TOLERANCE:
		print("settled: %.3f s, %d goat(s)" % [_settle, int(herd.call("count"))])
		return false
	if _settle < SETTLE_SECONDS:
		return true
	_failures.append("the mirror never reached the snapshot: worst gap %.4f m after %.2f s"
		% [float(herd.call("worst_gap")), SETTLE_SECONDS])
	return false

## What the wire says each goat is, by index: `Herd.report` answers what the console's `bots` verb
## wants, which is where a case reads a goat rather than reaching into the mirror.
func _report(herd: Node) -> Dictionary:
	var out := {}
	for row: Dictionary in herd.call("report"):
		out[int(row.get("index", 0))] = row
	return out

func _expect_count(herd: Node, want: int, what: String) -> void:
	var got: int = int(herd.call("count"))
	print("herd:    ", got, " goat(s) for ", what)
	if got != want:
		_failures.append("%s left the mirror holding %d goat(s), not %d" % [what, got, want])

func _expect_indexes(herd: Node, want: Array, what: String) -> void:
	var got: Array = _report(herd).keys()
	got.sort()
	if got != want:
		_failures.append("%s left the mirror holding indexes %s, not %s"
			% [what, str(got), str(want)])

## The gait a goat is in, which is the wire's own word rather than the clip it posed.
func _expect_gait(herd: Node, index: int, want: String, what: String) -> void:
	for row: Dictionary in herd.call("state"):
		if int(row.get("index", -1)) != index:
			continue
		if String(row.get("gait", "")) != want:
			_failures.append("%s is on the %s gait, not %s"
				% [what, row.get("gait"), want])
		return
	_failures.append("the mirror holds no goat at index %d, so %s cannot be read" % [index, what])

## The clip a goat posed, which only `describe` answers -- and it answers it for a probe or a log,
## which is what this is. A gait's clip is the model's vocabulary and not the wire's, so this is the
## one place the two tables meet.
func _expect_clip(herd: Node, index: int, want: String, what: String) -> void:
	for line in herd.call("describe"):
		var text: String = String(line)
		if not text.contains("bot %d " % index):
			continue
		if not text.contains(want):
			_failures.append("%s posed %s, not %s" % [what, text.strip_edges(), want])
		return
	_failures.append("the mirror holds no goat at index %d, so %s cannot be read" % [index, what])

## Where the flock is *drawn*, goat by goat, against the spots the snapshot carried -- the two of
## the first world that are still named by the second, which is the pair both are built from.
func _expect_spots(herd: Node) -> void:
	var rows: Dictionary = _report(herd)
	for entry: Dictionary in TWO:
		var index: int = int(entry["index"])
		if not rows.has(index):
			_failures.append("the mirror lost goat %d while settling" % index)
			continue
		var row: Dictionary = rows[index]
		var want := Vector2(float(entry["x"]), float(entry["z"]))
		var got := Vector2(float(row.get("x", 0.0)), float(row.get("z", 0.0)))
		if got.distance_to(want) > TOLERANCE:
			_failures.append("goat %d is drawn at %s, not the snapshot's %s"
				% [index, str(got), str(want)])
	print("spots:   ", rows.size(), " goat(s) on the wire's spots")

func _finish() -> bool:
	# The scene's bridge is a real node with a runtime thread; this scene never started it, but the
	# node is there and every gate closes it the way `verify_hosting.gd` does before the process
	# ends -- iroh tearing an endpoint down during teardown is a segfault.
	var bridge: Variant = _main.get("bridge")
	if bridge != null:
		bridge.call("shutdown")
	if _failures.is_empty():
		print("OK: the mirror adopts the herd the wire names, down to none, and keeps what a world leaves out")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true
