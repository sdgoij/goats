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
# So this gate does two things, both without a socket:
#
#   1. **The shape**, field for field against the lists transcribed below from `net.js`
#      (`sceneWorldBots`, `sceneWeatherState`, `sceneStreams`, `sceneEaten`, `netWorldCraters`,
#      `netWorldSpent`) and from `proto`'s own structs. A row with a key the wire does not have,
#      or missing one it does, fails -- which is the silent-drop bug.
#   2. **The parse**: the same JSON is handed to the scene's own `NetBridge.world`, the method
#      that *is* the schema check, and must answer `ok`.
#
# It runs the real scene (`scenes/herd.tscn`) for a few frames so the payload carries a herd that
# has spawned and a clock that has moved, rather than an empty world at frame zero: a payload that
# is only ever checked at boot would pass with the bots missing.
extends SceneTree

## `proto::WorldState`'s fields -- the top level of the object, and every key `net.js`
## `netMaybePublishWorld` queues.
const WORLD_KEYS := ["bots", "weather", "streams", "eaten", "craters", "spent"]
## `proto::WeatherState` / `net.js` `sceneWeatherState`, snake_case.
const WEATHER_KEYS := ["kind", "cloudiness", "rain_amount", "wind_x", "wind_z", "wind_sway",
	"world_time"]
## `proto::Streams` / `net.js` `sceneStreams`: the four PRNG states.
const STREAM_KEYS := ["weather", "bots", "food", "audio"]
## `proto::BotState` / `net.js` `sceneWorldBots`, including the flung height in centimetres.
const BOT_KEYS := ["index", "x", "z", "yaw", "phase", "gait", "variant", "py"]
## `proto::EatenCell` / `net.js` `sceneEaten`.
const EATEN_KEYS := ["key", "left"]
## `proto::Crater` / `net.js` `netWorldCraters`: four fields, no age and no heal clock.
const CRATER_KEYS := ["x", "z", "r", "depth"]
## `proto::Spent` / `net.js` `netWorldSpent`.
const SPENT_KEYS := ["key", "trap"]

## Frames to let the scene run before reading the payload. The herd spawns in `_ready` and the
## clock starts at the scene's own hour, so a handful is enough the world is not frame zero.
const SETTLE_FRAMES := 8

var _failures: Array[String] = []
var _frames := 0
var _main: Node

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
	if _frames < SETTLE_FRAMES:
		return false
	_check()
	# The scene's bridge is a real node with a runtime thread; `world` starts it. Close it before
	# the process ends, the way every other gate does -- iroh tearing an endpoint down during
	# teardown is a segfault.
	_main.get("bridge").call("shutdown")
	if _failures.is_empty():
		print("OK: the scene's world payload is the wire's, and the wire's own parse takes it")
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
