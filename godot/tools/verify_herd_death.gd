# Does a client's own death and respawn leave the herd it mirrors still moving?
#
#   GOATSD_TICKET=<ticket> Godot --headless --path godot --script res://tools/verify_herd_death.gd
#
# The herd a client sees is the *host's* -- `herd.gd` mirrors what the world snapshot carries, and a
# client simulates none of it. So "the flock stopped when I died" is a question about two things at
# once: whether the host is still publishing a herd that moves, and whether this end is still taking
# it. Nothing here simulates anything: it joins, watches the mirror settle, dies the way a player
# dies (the console's own `kill` and `restart`, which are `R` and a lethal bang's own paths), *lies
# there* for a while -- a death is many frames, not one, and the report was about the death and the
# respawn both, so each window is measured on its own -- and then asks whether the herd moved across
# each of them.
#
# The worlds this end has applied are printed beside every sample, because the two ways a herd stops
# are different bugs: a mirror that is still being sent worlds is a host whose herd stood still, and
# one that is not is a session that stopped carrying them.
#
# `interop.sh death` drives it against a real `goatsd`, which is a *Rust* host: it can only ever
# show that this end mirrors. `interop.sh hostdeath` drives it against this scene hosting
# (`verify_herd_host.gd`), which is the host the report was about.
extends SceneTree

## How long the mirror is given to settle onto the host's herd before the first sample, how long the
## goat lies dead, and how long the herd is watched after it gets up. Seconds.
const SETTLE := 3.0
const DEAD := 3.0
const WATCH := 3.0
## The least the herd has to move for "it is still being mirrored" to be true. A walking bot covers
## about a metre a second, so a tenth of a metre over either window is far below any real motion and
## far above the easing's own noise.
const MOTION := 0.1

var _main: Node
var _frames := 0
var _timer := 0.0
var _phase := 0
var _before := {}
var _mid := {}
var _failures: Array[String] = []

func _initialize() -> void:
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(delta: float) -> bool:
	_frames += 1
	# `SceneTree.root` is not inside the tree while `_initialize` runs, so the scene is read a few
	# frames later -- the trap `verify_console.gd` names.
	if _frames < 6:
		return false
	# The clock starts at the first readable frame, so the herd's own wait is bounded from there.
	_timer += delta
	var herd: Node = _main.get("herd")
	if herd == null:
		_failures.append("the scene did not build a Herd")
		return _finish()
	match _phase:
		0:
			if int(herd.call("count")) == 0:
				# A refused join leaves no herd arriving at all, which is a hang rather than a
				# failure -- so the wait is bounded and says what it was waiting for.
				if _timer > 20.0:
					_failures.append("no herd was mirrored within 20 s (was the join refused?)")
					return _finish()
				return false
			print("herd:    ", int(herd.call("count")), " goat(s) mirrored; settling")
			_phase = 1
			_timer = 0.0
		1:
			if _timer < SETTLE:
				return false
			_before = _positions(herd)
			print("before:  ", _before.size(), " goat(s), ", _worlds(), " world(s) applied")
			var commands: Object = _main.get("commands")
			print("kill ->    ", commands.call("run", "kill"))
			_phase = 2
			_timer = 0.0
		2:
			# The goat lies dead for a while, as it does for a player: this is the window the
			# report is about, and a watch that skipped it would be measuring the respawn alone.
			if _timer < DEAD:
				return false
			_mid = _positions(herd)
			print("dead:    ", _mid.size(), " goat(s), ", _worlds(), " world(s) applied")
			var commands: Object = _main.get("commands")
			print("restart -> ", commands.call("run", "restart"))
			_phase = 3
			_timer = 0.0
		3:
			if _timer < WATCH:
				return false
			var after := _positions(herd)
			print("after:   ", after.size(), " goat(s), ", _worlds(), " world(s) applied")
			_compare(_before, _mid, "while this client's goat lay dead", DEAD)
			_compare(_mid, after, "after this client's goat got up", WATCH)
			return _finish()
	return false

## The herd's drawn positions by index, which is what `herd.report()` answers a console `bots` verb.
func _positions(herd: Node) -> Dictionary:
	var out := {}
	for row: Dictionary in herd.call("report"):
		out[int(row.get("index", 0))] = Vector2(
			float(row.get("x", 0.0)), float(row.get("z", 0.0)))
	return out

## How many world snapshots carrying a herd this end has applied, which is the *scene's* own count.
## It is read rather than kept here because the question is whether the frame loop took them.
func _worlds() -> int:
	return int(_main.get("_worlds"))

## What the herd did across one window, and whether that counts as moving.
func _compare(from: Dictionary, to: Dictionary, window: String, seconds: float) -> void:
	if from.is_empty() or to.is_empty():
		_failures.append("there was no herd to compare " + window)
		return
	var moved := 0
	var most := 0.0
	for index in from:
		if not to.has(index):
			continue
		var distance: float = (from[index] as Vector2).distance_to(to[index] as Vector2)
		most = maxf(most, distance)
		if distance > MOTION:
			moved += 1
	print("motion:  ", moved, " of ", from.size(), " goat(s) moved ", window,
		", most %.3f m in %.1f s" % [most, seconds])
	if most <= MOTION:
		_failures.append("the mirrored herd did not move %s (most was %.3f m in %.1f s)"
			% [window, most, seconds])

func _finish() -> bool:
	if _failures.is_empty():
		print("OK: the mirrored herd keeps moving through a client's death and respawn")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true
