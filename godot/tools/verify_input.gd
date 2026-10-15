# The input gate: the keyboard reaches the goat.
#
#   Godot --headless --path godot --script res://tools/verify_input.gd
#
# `verify_goat.gd` proves that `PlayerGoat.step` is the scene's frame *given*
# controls. This proves the controls arrive -- the one link neither that gate nor
# the probe covers, and the one a person hits first. The scene reads raylib's key
# states directly in `sceneFrame`; Godot's `Input` singleton is a different door
# with its own names (a *physical* keycode, and a held key that is not an event), so
# "the goat walks when you press W" is a claim about two files and neither of them
# is a transcription.
#
# It loads the real scene, holds keys down the way a real keyboard does
# (`Input.parse_input_event`), and asks the goat where it ended up.
extends SceneTree

## Long enough to cross the spawn bowl at a walk and to be well inside the first
## jump, which is 1.333 s: the jump cycles to `GoatJump2` on the first press
## (`cyclePlayerVariant`), which is itself a rule the goat gate covers.
const WALK_FRAMES := 90
const JUMP_FRAMES := 6
## Long enough for the jump to land and the goat to settle into idle: the flight is
## 1.333 s and headless has no vsync, so a *frame* budget here is generous on
## purpose -- it only has to be long enough.
const SETTLE_FRAMES := 300
const TOTAL_FRAMES := WALK_FRAMES + JUMP_FRAMES + SETTLE_FRAMES

## How far the walk may be from `walk speed * elapsed`. Headless has no vsync, so a
## *frame count* is not a duration here -- the loop runs as fast as it can and 90
## frames was 1.5 s on one run and 0.75 s on another. A tenth either way catches a
## goat that is not moving at its gait's speed and not a goat that is on a machine
## that draws faster.
const SLACK := 0.1

var _scene: Node
var _goat: PlayerGoat
var _frames := 0
## Seconds this gate has been running, which is what the walk is measured against.
var _elapsed := 0.0
## `px`, `pz` and the mode where the walk ended, read once so the jump can be judged
## against it rather than against the spawn point.
var _walked := 0.0
var _walk_z := 0.0
var _walk_mode := ""
## The elapsed time *at the sample*, not at the report: the jump frames after it are
## a fifth of a second, which is more than the slack the walk is judged with.
var _walk_elapsed := 0.0
var _worst := ""

func _initialize() -> void:
	var packed := load("res://scenes/herd.tscn") as PackedScene
	_scene = packed.instantiate()
	root.add_child(_scene)
	_goat = _scene.get_node("Goat") as PlayerGoat
	_key(KEY_W, true)

func _process(delta: float) -> bool:
	_frames += 1
	_elapsed += delta
	if _frames <= WALK_FRAMES and _frames % 15 == 0:
		print("  frame %d: px %.4f, elapsed %.3f, mode %s, clip %s" % [
			_frames, _goat.px, _elapsed, _goat.mode, _goat.playing_clip()])
	if _frames == WALK_FRAMES:
		_walked = _goat.px
		_walk_z = _goat.pz
		_walk_mode = _goat.mode
		_walk_elapsed = _elapsed
		_key(KEY_W, false)
		_key(KEY_SPACE, true)
	elif _frames == WALK_FRAMES + JUMP_FRAMES:
		_key(KEY_SPACE, false)
		if _goat.mode != "jump":
			_worst = "the jump did not start: mode is %s" % _goat.mode
		elif _goat.px <= _walked:
			_worst = "the goat did not travel through its jump (%.3f -> %.3f)" % [
				_walked, _goat.px]
	if _frames < TOTAL_FRAMES:
		return false
	_report()
	return true

## One key, held or released, through the same path a real keyboard uses.
func _key(code: int, down: bool) -> void:
	var event := InputEventKey.new()
	event.physical_keycode = code
	event.pressed = down
	Input.parse_input_event(event)

func _report() -> void:
	var failures: Array[String] = []
	var expected: float = _goat.walk_speed() * _walk_elapsed
	print("after %d frame(s) of W (%.2f s): mode %s, at (%.3f, %.3f), expected ~%.3f"
		% [WALK_FRAMES, _walk_elapsed, _walk_mode, _walked, _walk_z, expected])
	print("at the end: mode %s, at (%.3f, %.3f), energy %.1f"
		% [_goat.mode, _goat.px, _goat.pz, _goat.energy])
	print("after settling: mode %s, clip role %s, playing %s"
		% [_goat.mode, _goat.clip_role(), _goat.playing_clip()])

	if _walk_mode != "walk":
		failures.append("holding W did not put the goat in its walk (it is %s)" % _walk_mode)
	if absf(_walked - expected) > expected * SLACK:
		failures.append("holding W moved the goat %.3f m in %.2f s; its walk is %.3f m/s"
			% [_walked, _walk_elapsed, _goat.walk_speed()])
	# The goat faces local +X at yaw 0 and `sceneFrame` walks it along that, so a
	# straight walk is +X and *nothing* in Z. A sign slip in either would show here.
	if absf(_walk_z) > 0.05:
		failures.append("a straight walk drifted %.3f m sideways" % _walk_z)
	if _worst != "":
		failures.append(_worst)
	# The jump costs energy up front (`TUNING.stats.jumpEnergyCost`), and the walk
	# and the jump both drain it, so a full bar would mean nothing happened at all.
	if _goat.energy >= 100.0:
		failures.append("the goat's energy never moved, so nothing was simulated")
	# ...and a goat that is *standing still* poses the idle clip. This is the case a
	# person sees within a second of pressing play, and the first version of
	# `clip_role` played the walk clip here -- an inverted test and a swapped fallback
	# that the goat gate missed because its oracle shared them.
	if _goat.mode != "idle":
		failures.append("the goat did not settle into idle (it is %s)" % _goat.mode)
	elif _goat.clip_role() != "idle":
		failures.append("a standing goat poses the %s clip" % _goat.clip_role())
	elif _goat.playing_clip() != _goat.clip_for("idle"):
		failures.append("a standing goat is playing %s, not its idle clip %s" % [
			_goat.playing_clip(), _goat.clip_for("idle")])

	if failures.is_empty():
		print("OK: the keyboard reaches the goat")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)
