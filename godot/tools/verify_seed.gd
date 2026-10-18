# The seed a client borrows and gives back.
#
#   Godot --headless --path godot --script res://tools/verify_seed.gd
#
# A session is shared by seed: the host sends one, and every peer derives the weather, the
# bots, the meadow, the bleat variety and the device salt from it (`sceneUseSeed`). A
# client that leaves must return to the world it had before the session -- the session's
# seed was never its own. A host is the opposite case: the session seed *is* its world,
# so stopping hosting keeps it.
#
# The snapshot is taken by `main.gd` on the `session` event and restored on `leave`,
# `disconnected` and `error` for a client. This gate drives those three events directly
# on the real scene, which is the only place the state lives.
extends SceneTree

const SETTLE_FRAMES := 6

var _frames := 0
var _failures: Array[String] = []
var _main: Node

func _initialize() -> void:
	if not ClassDB.class_exists("NetBridge"):
		print("FAIL: NetBridge is not registered - the GDExtension did not load")
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
	if _frames < SETTLE_FRAMES:
		return false
	_check()
	_main.get("bridge").call("shutdown")
	if _failures.is_empty():
		print("OK: a client gets its own streams back, and a host keeps the session's")
		quit(0)
	else:
		for failure: String in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

## The five derived values plus the trap salt: everything `sceneUseSeed` replaces.
func _streams() -> Dictionary:
	var weather: Weather = _main.get("weather")
	var bots: Bots = _main.get("bots")
	var meadow: Meadow = _main.get("meadow")
	var audio: Audio = _main.get("audio")
	var explosions: Explosions = _main.get("explosions")
	return {
		"weather": weather.rng,
		"rain": weather.rain_seed,
		"bots": bots._rng,
		"meadow": meadow._rng,
		"audio": audio._seed,
		"salt": explosions.salt,
	}

func _send(line: String) -> void:
	_main.call("_handle", line)

func _check() -> void:
	# 1. A client: the session replaces the streams, and leaving restores them.
	var own: Dictionary = _streams()
	_send('{"type":"session","seed":424242}')
	if _streams() == own:
		_failures.append("the session seed did not change the streams")
	_send('{"type":"welcome","name":"eve"}')
	_main.call("cmd_leave")
	if _streams() != own:
		_failures.append("leaving a session did not restore this client's streams")

	# 2. A drop instead of a leave is the same client case.
	var before_drop: Dictionary = _streams()
	_send('{"type":"session","seed":5150}')
	_send('{"type":"welcome","name":"eve"}')
	_send('{"type":"disconnected"}')
	if _streams() != before_drop:
		_failures.append("a disconnect did not restore this client's streams")

	# 3. A host: the session seed is its own world, so leaving keeps it.
	_send('{"type":"session","seed":777}')
	_send('{"type":"hosting","name":"bob"}')
	var hosted: Dictionary = _streams()
	_main.call("cmd_leave")
	if _streams() != hosted:
		_failures.append("a host restored a seed it never borrowed")
