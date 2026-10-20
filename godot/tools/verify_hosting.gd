# The hosting gate: the *scene's* own world payload, and the one parse it has to survive.
#
#   Godot --headless --path godot --script res://tools/verify_hosting.gd
#
# `verify_net.gd` proves the bridge's `world` intent carries a hand-written snapshot over iroh.
# What it cannot reach is the object the scene *builds*: `main.gd`'s `_world_payload`, which is
# `net.js`'s six `scene*`/`netWorld*` functions in one place. That shape is the part of hosting
# that can be wrong in silence -- `WorldIntent` is `proto::WorldState`, so a renamed or dropped
# field makes `NetBridge::world` answer `error: ...` and the snapshot is a world nobody has, and
# nothing about the game looks broken until a client is standing in the wrong place.
#
# So this gate does three things, all without a socket:
#
#   1. **The shape**, field for field against the lists transcribed below from `net.js`
#      (`sceneWorldBots`, `sceneWeatherState`, `sceneStreams`, `sceneEaten`, `netWorldCraters`,
#      `netWorldSpent`) and from `proto`'s own structs. A row with a key the wire does not have,
#      or missing one it does, fails -- which is the silent-drop bug.
#   2. **The parse**: the same JSON is handed to the scene's own `NetBridge.world`, the method
#      that *is* the schema check, and must answer `ok`.
#   3. **The mods datagram** (`APIv1.md` section 4.13), the second half of the same subject: the
#      object `ModHost::world_mods_json` builds for a host, its own parse, and -- after a few
#      frames -- what *applying* one does to a mirroring scene. A world mod's state rides its own
#      datagram because it may be bigger than the world's budget, and losing it costs a mod rather
#      than everyone's world; the flock is the mod this gate watches.
#
# It runs the real scene (`scenes/herd.tscn`) for a few frames so the payload carries a herd that
# has spawned and a clock that has moved, rather than an empty world at frame zero: a payload that
# is only ever checked at boot would pass with the bots missing. The mods half then runs on to
# `MODS_FRAME`, because an applied row is only visible once the mod has run under it.
#
extends SceneTree

## `proto::WorldState`'s fields -- the top level of the object, and every key `net.js`
## `netMaybePublishWorld` queues.
const WORLD_KEYS := ["bots", "weather", "streams", "eaten", "craters", "spent"]
## `proto::WeatherState` / `net.js` `sceneWeatherState`, snake_case.
const WEATHER_KEYS := ["kind", "cloudiness", "rain_amount", "wind_x", "wind_z", "wind_sway",
	"world_time"]
## `proto::Streams` / `net.js` `sceneStreams`: the four PRNG states.
const STREAM_KEYS := ["weather", "bots", "food", "audio"]
## `proto::BotState` / `net.js` `sceneWorldBots`, including the flung height in centimetres and
## the flight attitude in degrees (protocol 12).
const BOT_KEYS := ["index", "x", "z", "yaw", "phase", "gait", "variant", "py", "pitch", "roll"]
## `proto::EatenCell` / `net.js` `sceneEaten`.
const EATEN_KEYS := ["key", "left"]
## `proto::Crater` / `net.js` `netWorldCraters`: four fields, no age and no heal clock.
const CRATER_KEYS := ["x", "z", "r", "depth"]
## `proto::Spent` / `net.js` `netWorldSpent`.
const SPENT_KEYS := ["key", "trap"]
## `sceneWorldMods`'s own shape (`APIv1.md` section 4.13): every registered stream's state, and
## `{extension id: what its `publish` returned}`. `proto::ModsState` is opaque -- a mod's state is
## its own business -- so this object is the only schema there is, and it is `mods.js`'s.
const MODS_KEYS := ["streams", "data"]
## The repository's world mod, named rather than discovered: this gate has to write rows the
## *flock's* `apply` accepts, and the row's shape is the mod's own.
const BIRDS_ID := "com.github.sdgoij.goats.birds"
## When the applied mod state is read: long enough for the mirrored flock to have eased to the rows
## the host published. `birds`' `mirror` eases at `MIRROR_K` 7 per second, so a second is most of
## the way and the check's tolerance does not have to be tight.
const MODS_FRAME := 70

## Frames to let the scene run before reading the payload. The herd spawns in `_ready` and the
## clock starts at the scene's own hour, so a handful is enough the world is not frame zero.
const SETTLE_FRAMES := 8

var _failures: Array[String] = []
var _frames := 0
var _main: Node
## The stream the mods case changes before applying it, and the value it changes it to: a value
## this end did not have is what makes *adopting* it a difference rather than a no-op.
var _stream_key := ""
var _stream_value := 0

func _initialize() -> void:
	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
		quit(1)
		return
	# The scene is instantiated here and *read* a few frames later: `SceneTree.root` is not inside
	# the tree while `_initialize` runs (the trap `verify_console.gd` names).
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == SETTLE_FRAMES:
		_check()
		# ...and the mods half, staged here and read at `MODS_FRAME`: a row the host published is
		# only visible once the mod it belongs to has run under it.
		_stage_mods()
		return false
	if _frames < MODS_FRAME:
		return false
	_check_mods()
	# The scene's bridge is a real node with a runtime thread; `world` starts it. Close it before
	# the process ends, the way every other gate does -- iroh tearing an endpoint down during
	# teardown is a segfault.
	_main.get("bridge").call("shutdown")
	if _failures.is_empty():
		print("OK: the scene's world and mods payloads are the wire's, and applying a host's mods moves the flock")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	var payload: Variant = _main.call("_world_payload")
	if not (payload is Dictionary):
		_failures.append("_world_payload did not answer a dictionary")
		return
	_check_keys(payload, WORLD_KEYS, "the world")

	# The bots: one row per bot the scene is simulating, each with exactly `BotState`'s fields.
	var bots: Bots = _main.get("bots")
	var rows: Variant = payload.get("bots", null)
	if not (rows is Array):
		_failures.append("the world's bots are not a list")
	else:
		var list: Array = rows
		print("bots: ", list.size(), " row(s), the scene simulates ", bots.count())
		_expect(list.size() == bots.count(),
			"the payload carries %d bot(s) and the scene simulates %d" % [list.size(), bots.count()])
		for entry: Variant in list:
			if not (entry is Dictionary):
				_failures.append("a bot row is not an object")
				break
			_check_keys(entry, BOT_KEYS, "a bot row")
		if not list.is_empty() and list[0] is Dictionary:
			# The gait is `Gait`'s own snake_case spelling, which is what makes a row deserialise.
			var gait: String = String(list[0].get("gait", ""))
			_expect(gait != "" and not gait.contains(" ") and gait == gait.to_lower(),
				"the first bot's gait is not a snake_case word: '%s'" % gait)

	# The sky: `WeatherState`'s fields, and the clock is the scene's own.
	var weather: Weather = _main.get("weather")
	var sky: Variant = payload.get("weather", null)
	if not (sky is Dictionary):
		_failures.append("the world's weather is not an object")
	else:
		_check_keys(sky, WEATHER_KEYS, "the weather")
		var hours: float = float(_main.call("cmd_hours"))
		_expect(absf(float(sky.get("world_time", -1.0)) - hours) < 1e-9,
			"the weather's clock is %s and the scene's is %s" % [sky.get("world_time"), hours])
		_check_weather_kind(String(sky.get("kind", "")))

	# The four streams: u32 states, and each is the module's own current draw.
	var streams: Variant = payload.get("streams", null)
	if not (streams is Dictionary):
		_failures.append("the world's streams are not an object")
	else:
		_check_keys(streams, STREAM_KEYS, "the streams")
		var pairs := [
			["weather", weather.stream()],
			["bots", bots.stream()],
			["food", _main.get("meadow").call("stream")],
			["audio", _main.get("audio").call("stream")],
		]
		for pair: Array in pairs:
			var name: String = String(pair[0])
			var mine: int = int(pair[1])
			_expect(int(streams.get(name, -1)) == mine,
				"the %s stream is %s and the module's is %d" % [name, streams.get(name), mine])
			_expect(mine >= 0 and mine <= 0xFFFFFFFF,
				"the %s stream is not an unsigned word: %d" % [name, mine])

	# The three lists, whose rows are `proto`'s own shapes. Offline at boot they are usually
	# empty, which is why the *keys* are what is held here.
	_check_rows(payload.get("eaten", null), EATEN_KEYS, "eaten")
	_check_rows(payload.get("craters", null), CRATER_KEYS, "craters")
	_check_rows(payload.get("spent", null), SPENT_KEYS, "spent")

	# And the parse: the same JSON handed to the method that is the schema check. `NetBridge.world`
	# answers `ok` or `error: ...`, which is exactly the pair a scene reads.
	var bridge: Object = _main.get("bridge")
	var answer: String = String(bridge.call("world", JSON.stringify(payload)))
	print("world intent -> ", answer)
	_expect(answer == "ok", "the wire's own parse refused the payload: %s" % answer)

	# And that the throttled sender really is wired to it: a host publishes, and the frame counter
	# moves so the next call within the window is a no-op. Forcing `_hosting` is how the gate makes
	# a client-flagged-at-boot scene take the host path in the one place it matters.
	_main.set("_hosting", true)
	_main.set("_world_frame", -32768)
	_main.call("_publish_world")
	var after: int = int(_main.get("_world_frame"))
	var now: int = Engine.get_process_frames()
	_expect(after == now, "_publish_world did not stamp the frame it published on: %d vs %d"
		% [after, now])
	_main.call("_publish_world")
	_expect(int(_main.get("_world_frame")) == after,
		"_publish_world published twice inside one window")
	_main.set("_hosting", false)

	# --- the world mods, on their own datagram (`APIv1.md` section 4.13) --------------------------
	#
	# A world mod's state is *not* the world's: it rides a datagram of its own so that a mod
	# publishing too much loses its own state rather than everyone's world. The `_publish_world`
	# above has already queued one -- the two go out at the same rate -- so this holds the object
	# rather than sending a second, and `NetBridge.mods` is the parse the wire does of it.
	var mods: Object = _main.get("mods")
	var contribution: String = String(mods.call("world_mods_json"))
	print("mods payload: ", contribution.substr(0, 140))
	if contribution.is_empty():
		_failures.append("the repository's flock is a world mod, and the host published no mods")
		return
	var mods_payload: Variant = JSON.parse_string(contribution)
	if not (mods_payload is Dictionary):
		_failures.append("the mods payload is not an object")
		return
	_check_keys(mods_payload, MODS_KEYS, "the mods")
	var mod_streams: Variant = (mods_payload as Dictionary).get("streams", null)
	if not (mod_streams is Dictionary) or (mod_streams as Dictionary).is_empty():
		_failures.append("the mods payload carries no stream, and the flock registered one")
	var mod_data: Variant = (mods_payload as Dictionary).get("data", null)
	if not (mod_data is Dictionary) or not (mod_data as Dictionary).has(BIRDS_ID):
		_failures.append("the mods payload does not carry the flock's published state: %s" % mod_data)
	else:
		# The flock's own payload is `{rows, riders}` since 1.2.0: the rows are the birds, the
		# riders map is who is aboard (empty on an ordinary frame).
		var published: Variant = (mod_data as Dictionary)[BIRDS_ID]
		var published_rows: Variant = (published as Dictionary).get("rows", null) \
			if published is Dictionary else null
		if not (published_rows is Array) or (published_rows as Array).is_empty():
			_failures.append("the flock published no rows: %s" % published)
		elif not ((published as Dictionary).get("riders", null) is Dictionary):
			_failures.append("the flock published no rider map: %s" % published)
		else:
			print("published rows: ", (published_rows as Array).size())
	var mods_answer: String = String(bridge.call("mods", contribution))
	print("mods intent -> ", mods_answer)
	_expect(mods_answer == "ok", "the wire's own parse refused the mods payload: %s" % mods_answer)

## Hand this scene a host's world-mod state, changed so that applying it is *visible*:
##
##   * one stream's state is moved by one, so adopting it is a value this end did not have rather
##     than one it already had;
##   * the flock's rows are rewritten to put every bird 40 m along +x from the player -- a distance a
##     **mirroring** flock reaches only by easing toward them (`birds`' `mirror`, `MIRROR_K` 7, so a
##     second is most of the way) and one a simulating flock would not be at.
##
## The scene is then told it is a *client*, through its own `welcome` event: `goats.net.localWorld()`
## is what decides `simulate` from `mirror` in the flock, and off a host it is false. Applying a row
## to a scene that is still simulating would be overwritten by the next `update` -- which is correct
## behaviour and a case that proves nothing.
func _stage_mods() -> void:
	var mods: Object = _main.get("mods")
	var payload: Variant = JSON.parse_string(String(mods.call("world_mods_json")))
	if not (payload is Dictionary):
		_failures.append("the mods payload is not an object")
		return
	var state: Dictionary = payload
	var streams: Variant = state.get("streams", null)
	if not (streams is Dictionary) or (streams as Dictionary).is_empty():
		_failures.append("no world mod stream to adopt")
		return
	var table: Dictionary = streams
	_stream_key = String(table.keys()[0])
	_stream_value = (int(table[_stream_key]) + 1) & 0xFFFFFFFF
	table[_stream_key] = _stream_value
	var data: Variant = state.get("data", null)
	if data is Dictionary:
		var flock_state: Variant = (data as Dictionary).get(BIRDS_ID, null)
		# The flock's payload is `{rows, riders}`; only the rows are rewritten, and the
		# empty rider map is sent through unchanged.
		var rows: Variant = (flock_state as Dictionary).get("rows", null) \
			if flock_state is Dictionary else null
		if rows is Array and not (rows as Array).is_empty():
			var goat: Object = _main.get("goat")
			var px: float = float(goat.get("px"))
			var pz: float = float(goat.get("pz"))
			var moved: Array = []
			for _row: Variant in (rows as Array):
				moved.append([px + 40.0, 0.5, pz, 0.0, 0])
			(flock_state as Dictionary)["rows"] = moved
		else:
			_failures.append("the flock has no published rows to rewrite: %s" % flock_state)
	_main.call("_handle", JSON.stringify({"type": "welcome", "name": "gate"}))
	mods.call("apply_world_mods", JSON.stringify(state))

## What applying a host's mods did, a second later. The stream check is the cheap half -- it is the
## value this gate wrote coming back out -- and the flock is the point: a *mod's* state moved a
## mod's simulation, which is the whole reason the datagram exists.
func _check_mods() -> void:
	var mods: Object = _main.get("mods")
	var payload: Variant = JSON.parse_string(String(mods.call("world_mods_json")))
	if not (payload is Dictionary):
		_failures.append("the mods payload stopped being an object late")
		return
	var streams: Variant = (payload as Dictionary).get("streams", null)
	if streams is Dictionary:
		_expect(int((streams as Dictionary).get(_stream_key, -1)) == _stream_value,
			"the stream the host sent was not adopted: %s, not %d"
			% [(streams as Dictionary).get(_stream_key), _stream_value])
	var flock: Variant = JSON.parse_string(String(
		_main.get("commands").call("run", "birds")).trim_prefix("ok "))
	if not (flock is Dictionary):
		_failures.append("the flock did not report its state after the apply")
		return
	print("flock after apply: ", flock)
	_expect(not bool((flock as Dictionary).get("local", true)),
		"the scene is still the world's authority, so a mirroring case proves nothing")
	var near: float = float((flock as Dictionary).get("near", -1.0))
	_expect(near > 20.0, "the flock did not mirror the rows that were applied: near is %s" % near)

## A dictionary must carry every key a `proto` struct has and no other, which is the silent-drop
## bug in one assertion: a field the wire does not know is ignored, and a field it needs is an
## `error:` the moment a host publishes.
func _check_keys(value: Variant, wanted: Array, what: String) -> void:
	var got: Dictionary = value
	for key: String in wanted:
		if not got.has(key):
			_failures.append("%s is missing '%s'" % [what, key])
	for key: Variant in got:
		if not wanted.has(String(key)):
			_failures.append("%s carries '%s', which the wire does not have" % [what, key])

## A list of rows, each with exactly `keys`, or empty.
func _check_rows(value: Variant, keys: Array, what: String) -> void:
	if not (value is Array):
		_failures.append("%s is not a list" % what)
		return
	for entry: Variant in value:
		if not (entry is Dictionary):
			_failures.append("a %s row is not an object" % what)
			return
		_check_keys(entry, keys, "a %s row" % what)

## The weather kind is `WeatherKind`'s snake_case spelling -- the same four words the state
## machine's own table uses.
func _check_weather_kind(kind: String) -> void:
	_expect(Weather.STATES.has(kind),
		"the weather's kind is not a state the machine knows: '%s'" % kind)

func _expect(condition: bool, claim: String) -> void:
	if not condition:
		_failures.append(claim)
