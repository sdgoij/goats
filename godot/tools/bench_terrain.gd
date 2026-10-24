# A frame-time probe for the drawn ground: how much of the frame the terrain is.
#
#   Godot --path godot --script res://tools/bench_terrain.gd \
#       --resolution 1280x720 --disable-vsync --max-fps 0
#
# Opens a window (a headless run has no rasteriser, so it cannot answer this), waits
# for the scene to settle, times a window with the terrain drawn, then hides the
# ground and times another. The difference is the terrain's whole share of the
# frame -- vertex, fragment and shadow-caster -- which is the number to compare
# across a terrain change.
#
# `GOATS_BENCH_FRAMES` sets the sample window (default 300).
extends SceneTree

const WARMUP := 120

var _frames := 0
var _sample := 300
var _samples: Array[float] = []
var _with := -1.0
var _without := -1.0
var _phase := 0
var _terrain: Node3D = null
var _last := 0

func _initialize() -> void:
	var requested: String = OS.get_environment("GOATS_BENCH_FRAMES")
	if requested.is_valid_int() and requested.to_int() > 0:
		_sample = requested.to_int()
	var packed := load("res://scenes/herd.tscn") as PackedScene
	var game: Node = packed.instantiate()
	var settings: Settings = game.get("settings")
	settings.fullscreen = false
	root.add_child(game)
	_terrain = game.get_node("Terrain")

func _process(_delta: float) -> bool:
	_frames += 1
	var now: int = Time.get_ticks_usec()
	if _last != 0 and _frames > WARMUP:
		_samples.append(float(now - _last) / 1000.0)
	_last = now
	if _frames == WARMUP:
		return false
	if _samples.size() >= _sample:
		var mean := 0.0
		var worst := 0.0
		for ms in _samples:
			mean += ms
			worst = maxf(worst, ms)
		mean /= float(_samples.size())
		if _phase == 0:
			_with = mean
			print("terrain drawn:   mean %.2f ms  worst %.2f ms  (%.1f fps)  n=%d"
				% [mean, worst, 1000.0 / mean, _samples.size()])
			_terrain.visible = false
		else:
			_without = mean
			print("terrain hidden:  mean %.2f ms  worst %.2f ms  (%.1f fps)  n=%d"
				% [mean, worst, 1000.0 / mean, _samples.size()])
			var share: float = _with - _without
			print("terrain share:   %.2f ms  (%.0f%% of the drawn frame)" % [
				share, 100.0 * share / maxf(_with, 0.001)])
			return true
		_phase += 1
		_samples.clear()
		_last = 0
	return false
