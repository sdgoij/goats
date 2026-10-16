# The world-drawing gate: `goats.gfx`, the API's own 3D surface (`APIv1.md` section 4.19), from a
# mod's `draw3d` hook to a node standing in the world.
#
#   Godot --headless --path godot --script res://tools/verify_mod_gfx.gd
#
# `verify_scene_mods.gd` holds the *scene* half of the mod runtime and `verify_mods.gd` the host
# half; both are about the Surface a mod registers on. This is about the other direction -- a mod
# drawing -- and it exists because the port's first attempt at that was wrong in a way no other
# gate could see: it queued a draw as a *line of text* and painted none of it. So the claim here
# is not "the call arrived" but "there is a node in the world where the mod said".
#
# Five things, in increasing order of how easy they are to fake:
#
#   1. **The hook fires with the camera.** `draw3d` is the world pass, and a mod draws inside it.
#   2. **A cube becomes a box.** The record's position and size land on a `MeshInstance3D` whose
#      mesh is the size the mod asked for -- two cubes in one frame are two sizes.
#   3. **A model becomes the asset's glTF.** `goats.gfx.model(name)` hands over an opaque name,
#      and `ModWorld` imports the bytes behind it with Godot's own loader (`mod:...:model.fatguy.glb`,
#      the repository's own asset, which is a real import rather than a stub).
#   4. **A frame is a frame.** Children are reused and a frame that draws less hides the rest, so
#      the tree is the last frame and not the union of every frame.
#   5. **A name that resolves to nothing draws nothing.** `goats.gfx.model` answers `null`, and a
#      draw of `null` is not a record at all.
extends SceneTree

## The `draw3d` hook the gate registers, through the host's own `eval_js`: one cube of a known
## size in a known place, and a model from the repository's own `mods/fatguy` asset.
const PROBE_JS := """
goats.on("draw3d", function (cam) {
    goats.gfx.draw.cube(1.0, 2.0, 3.0, 0.5, 0.25, 1.5, goats.draw.WHITE);
    const fat = goats.gfx.model(GOATS_PROBE_MODEL);
    goats.gfx.draw.model(fat, 4.0, 0.5, -2.0, 0.0, 1.0, goats.draw.WHITE);
    // A name nothing declares is `null`, and a draw of `null` is not a draw.
    goats.gfx.draw.model(goats.gfx.model("no-such-asset"), 9.0, 9.0, 9.0);
});
"""

var _failures: Array[String] = []
var _frames := 0
var _main: Node
var _world: Node3D
var _camera: Camera3D
var _model_name := ""

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
		return false
	_check()
	if _failures.is_empty():
		print("OK: a mod's goats.gfx draws stand in the world, one node per call")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	_world = _main.get("mod_world")
	_camera = _main.get_node("Camera3D") as Camera3D
	var mods: Object = _main.get("mods")
	var host: Object = mods.get("host")
	if _world == null or host == null:
		_failures.append("the scene has no world node or no mod host")
		return

	# A real model asset, from the repository's own `mods/fatguy`. Taken by opaque name because
	# that is what a mod addresses an asset with (`APIv1.md` section 0: no paths).
	for name in host.call("asset_names"):
		if String(name).contains("model."):
			_model_name = String(name)
			break
	print("model asset: ", _model_name)
	if _model_name.is_empty():
		_failures.append("no model asset was found to draw")

	# 1. The handful. `eval_js` runs outside `goats.begin`, so the hook lands on the idle state --
	# which `__fireDraw3d` fires, exactly as the scene's own events reach it.
	var source: String = PROBE_JS.replace("GOATS_PROBE_MODEL", JSON.stringify(_model_name))
	var evaluated: String = String(host.call("eval_js", source))
	print("probe -> ", evaluated)
	if evaluated != "ok":
		_failures.append("the draw3d probe did not run: " + evaluated)
		return

	_frame()
	var commands: Array = _world.get("commands")
	print("records: ", commands.size(), ", placed: ", _world.get("placed"))
	if commands.size() != 2:
		_failures.append("two draws were asked for and %d arrived" % commands.size())
	if int(_world.get("placed")) != 2:
		_failures.append("two records were adopted and %d node(s) placed" % _world.get("placed"))

	# 2. The cube: position and size, off the record and onto the mesh.
	if commands.size() >= 1:
		var cube: Dictionary = commands[0]
		if String(cube.get("k", "")) != "cube":
			_failures.append("the first record is not the cube: %s" % cube)
		var box := _child(0) as MeshInstance3D
		if box == null or not (box.mesh is BoxMesh):
			_failures.append("the cube did not become a box mesh")
		else:
			var size: Vector3 = (box.mesh as BoxMesh).size
			if not size.is_equal_approx(Vector3(0.5, 0.25, 1.5)):
				_failures.append("the box is %s, and the mod asked for (0.5, 0.25, 1.5)" % size)
			if not box.position.is_equal_approx(Vector3(1.0, 2.0, 3.0)):
				_failures.append("the box is at %s, and the mod put it at (1, 2, 3)" % box.position)

	# 3. The model: the asset's own glTF, imported at runtime and standing where the mod said.
	var model := _child(1)
	if model == null:
		_failures.append("the model draw placed nothing")
	else:
		if not model.position.is_equal_approx(Vector3(4.0, 0.5, -2.0)):
			_failures.append("the model is at %s, and the mod put it at (4, 0.5, -2)" % model.position)
		if _mesh_count(model) < 1:
			_failures.append("the model instance has no meshes - the glTF did not import")

	# 4. A frame is a frame: the same hook again is the same two nodes, not four.
	var before: int = _world.get_child_count()
	_frame()
	print("after a second frame: ", _world.get_child_count(), " child(ren), ",
		_world.get("placed"), " placed")
	if _world.get_child_count() != before:
		_failures.append("a steady draw grew the tree: %d -> %d"
			% [before, _world.get_child_count()])
	# ...and a frame that draws nothing leaves nothing standing.
	_world.call("adopt", PackedStringArray())
	print("after an empty frame: ", _world.get("placed"), " placed")
	if int(_world.get("placed")) != 0:
		_failures.append("an empty frame left %d node(s) placed" % _world.get("placed"))
	for child in _world.get_children():
		if (child as Node3D).visible:
			_failures.append("an empty frame left a node visible")
			break

## One frame of the runtime, driven by the gate rather than by the node's `_process`, with the
## scene's own camera: what the world pass is handed.
func _frame() -> void:
	_main.get("mods").call("frame", 12.0, Vector2(1280.0, 720.0), true, _camera)

## The instance in slot `index`, or null.
func _child(index: int) -> Node3D:
	if index >= _world.get_child_count():
		return null
	return _world.get_child(index) as Node3D

## How many `MeshInstance3D`s an instance holds, at any depth: an imported glTF scene is a tree.
func _mesh_count(root: Node) -> int:
	var count := 0
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if node is MeshInstance3D:
			count += 1
	return count
