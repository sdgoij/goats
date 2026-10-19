# Render the scene once and save it, so the *picture* can be checked and not only
# the data.
#
#   "C:\Users\T\bin\Godot_v4.7.2-stable_win64.exe" --path godot \
#       --script res://tools/screenshot.gd --resolution 1280x720
#
# Writes `res://shot.png` (git-ignored) after 30 frames and quits.
#
# `GOATS_SHOT_FRAMES` raises the count, which is what a *live* session needs: a
# window that has to wait for a host to send a populated world and for the herd to
# ease onto it cannot be judged after half a second. `godot/tools/interop.sh shot`
# is that case, and sets a limit that is seconds rather than frames.
#
# This exists because a headless run cannot answer a rendering question at all --
# it has no rasteriser -- and two bugs in this port were invisible in every number
# and obvious in one image: a triangle wound the wrong way for Godot (culled, so
# the ground simply was not there) and a sun pointing at the sky. Both passed
# every gate that reads buffers.
#
# It opens a window, so it is not a gate and is never run in CI. A real GPU (or
# Godot's software renderer) is needed, and it is the one check here that cannot
# be automated away.
extends SceneTree

const OUT := "res://shot.png"
## Enough frames for the sky, the shadows and the material to settle.
const FRAMES := 30

var _frames := 0
var _limit := FRAMES

func _initialize() -> void:
	var requested: String = OS.get_environment("GOATS_SHOT_FRAMES")
	if requested.is_valid_int() and requested.to_int() > 0:
		_limit = requested.to_int()
	var packed := load("res://scenes/herd.tscn") as PackedScene
	var game: Node = packed.instantiate()
	# The desktop client boots full-screen, which would override the `--resolution` this harness
	# sizes its window with. Clear it before the scene's `_ready` applies it.
	var settings: Settings = game.get("settings")
	settings.fullscreen = false
	root.add_child(game)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < _limit:
		return false
	var image: Image = root.get_texture().get_image()
	var error := image.save_png(OUT)
	print("screenshot: ", _limit, " frames, ", image.get_size(), ", save error ", error)
	return true
