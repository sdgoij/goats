# The mods' world drawing (stage 8's `goats.gfx`, the half the port can do today): the API's
# own world-space surface (`APIv1.md` section 4.19), which a mod calls from a `draw3d` hook and
# this places in the world.
#
# It is the 3D twin of `mod_hud.gd`, and the split between them is the split in the API: `draw`
# takes pixels and this takes metres. Where `ModHud` paints a primitive, this puts a *node* in
# the tree -- an `MeshInstance3D` for a cube, an instance of the asset's imported glTF scene for
# a model -- because Godot has no immediate-mode 3D, and the scene tree is how a thing is drawn.
#
# Two consequences of that, and they are deliberate:
#
#   * **The frame's records are the frame's nodes.** Children are reused by index and hidden
#     when a frame draws fewer than the last one, so a mod that draws the same thing every frame
#     does not churn the tree, and a mod that stops drawing leaves nothing standing.
#   * **An asset is imported once.** `goats.gfx.model(name)` hands over an opaque name, and the
#     bytes behind it are Godot's to make something of: `GLTFDocument` parses the glTF at
#     runtime, the result is packed back into a `PackedScene` so it can be instanced per draw,
#     and the name is remembered either way -- including the `null` of a name that would not
#     import, so a broken asset is reported once rather than every frame.
#
# What is *not* here: a mod's own procedural geometry and textures (`makeModel`/`makeTexture`),
# the shadow-map texture slot, `unloadModel`, and non-Y rotation (`drawModelEx`'s axis and
# angle, which is what a flung goat's tumble needs). Those are the next additions, and until
# they exist a mod that builds its meshes in JavaScript -- `birds` -- cannot draw in this build.
class_name ModWorld
extends Node3D

## The `ModHost`, so an asset name can be turned into bytes. Set by the frame.
var host: Object
## The records drained this frame, in call order: one `{"k": ...}` per `goats.gfx.draw` call.
var commands: Array = []
## Frames this node adopted something. Evidence rather than a decision.
var frames := 0
## How many nodes the last frame placed. Zero is a frame a mod drew nothing in.
var placed := 0

## Asset name -> the imported scene, or `null` for a name that did not import. `null` is
## remembered on purpose: a broken asset is parsed once and reported once.
var _models := {}
## The per-frame instances, index-aligned with `commands`.
var _instances: Array = []

## Take one frame's world records. Parsing here rather than in `_place` keeps the placement a
## plain loop, and a record that does not parse is dropped rather than failing the frame.
func adopt(records: PackedStringArray) -> void:
	commands.clear()
	for record in records:
		var parsed: Variant = JSON.parse_string(String(record))
		if parsed is Dictionary:
			commands.append(parsed)
	frames += 1
	_rebuild()

## Bring the tree in line with this frame's records: one node per record, in order.
func _rebuild() -> void:
	for index in commands.size():
		var command: Dictionary = commands[index]
		var node: Node3D = _node(index, command)
		if node == null:
			continue
		_place(node, command)
	for index in range(commands.size(), _instances.size()):
		(_instances[index] as Node3D).visible = false
	placed = commands.size()

## The instance for slot `index`: the one already there when it is the right kind, a fresh one
## otherwise. Slots are reused rather than remade, which is what keeps a steady draw steady.
func _node(index: int, command: Dictionary) -> Node3D:
	var kind: String = String(command.get("k", ""))
	var existing: Node3D = _instances[index] if index < _instances.size() else null
	if existing != null and String(_meta(existing, "mod_kind", "")) == kind:
		return existing
	if existing != null:
		_instances.remove_at(index)
		existing.queue_free()
	var node: Node3D = null
	match kind:
		"cube":
			var box := MeshInstance3D.new()
			box.mesh = BoxMesh.new()
			node = box
		"model":
			var handle: String = String(command.get("h", ""))
			var packed: PackedScene = _model_scene(handle)
			if packed == null:
				return null
			node = packed.instantiate() as Node3D
	if node == null:
		return null
	node.set_meta("mod_kind", kind)
	add_child(node)
	_instances.insert(index, node)
	return node

## Put one instance where the record says.
func _place(node: Node3D, command: Dictionary) -> void:
	node.visible = true
	node.position = Vector3(float(command.get("x", 0.0)), float(command.get("y", 0.0)),
		float(command.get("z", 0.0)))
	if String(command.get("k", "")) == "cube":
		_place_cube(node as MeshInstance3D, command)
		return
	node.rotation = Vector3(0.0, float(command.get("yaw", 0.0)), 0.0)
	var scale: float = float(command.get("scale", 1.0))
	node.scale = Vector3(scale, scale, scale)
	_apply_tint(node, _color(command.get("tint", null)))

func _place_cube(box: MeshInstance3D, command: Dictionary) -> void:
	# The size is the record's, so the mesh is this instance's own -- two cubes in one frame
	# are two sizes.
	(box.mesh as BoxMesh).size = Vector3(float(command.get("w", 1.0)),
		float(command.get("h", 1.0)), float(command.get("d", 1.0)))
	var material := StandardMaterial3D.new()
	material.albedo_color = _color(command.get("col", null))
	box.material_override = material

## Tint every mesh in an instance. The material is kept per mesh node and rebuilt only when the
## tint changes, so a mod that tints the same model a different colour each frame pays for it
## and one that does not pays nothing.
func _apply_tint(root: Node, tint: Color) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var mesh: MeshInstance3D = node
		var last: Variant = _meta(mesh, "mod_tint", null)
		if last != null and (last as Color).is_equal_approx(tint):
			continue
		var source: Material = mesh.get_active_material(0)
		var material := StandardMaterial3D.new()
		material.albedo_color = tint
		if source is StandardMaterial3D and (source as StandardMaterial3D).albedo_texture != null:
			material.albedo_texture = (source as StandardMaterial3D).albedo_texture
		mesh.material_override = material
		mesh.set_meta("mod_tint", tint)

## The imported scene for an asset name, or null. Packed from the generated node so a draw can
## instance it; the node itself is freed, because the scene is what is kept.
func _model_scene(name: String) -> PackedScene:
	if _models.has(name):
		return _models[name]
	var packed: PackedScene = null
	if host != null and not name.is_empty():
		var bytes: PackedByteArray = host.call("asset_bytes", name)
		if bytes.is_empty():
			print("mod: no asset named ", name)
		else:
			var document := GLTFDocument.new()
			var state := GLTFState.new()
			if document.append_from_buffer(bytes, "", state) != OK:
				print("mod: ", name, " is not a glTF this build can read")
			else:
				var scene: Node = document.generate_scene(state)
				if scene == null:
					print("mod: ", name, " imported to nothing")
				else:
					packed = PackedScene.new()
					if packed.pack(scene) != OK:
						packed = null
						print("mod: ", name, " would not pack")
					scene.free()
	_models[name] = packed
	return packed

## A node's own metadata, or `default` when it has none. `Object.get_meta` reports an error for
## a key that is absent even when it is handed a default (Godot 4.7), and this file asks for
## both of its keys on nodes that may not have them yet.
static func _meta(node: Object, key: String, fallback: Variant) -> Variant:
	return node.get_meta(key) if node.has_meta(key) else fallback

## A record's colour as a Godot `Color`: the API's `{r, g, b, a}` in 0..255, and a missing one is
## opaque white rather than an error.
static func _color(value: Variant) -> Color:
	if not (value is Dictionary):
		return Color.WHITE
	var datum: Dictionary = value
	return Color8(int(datum.get("r", 255.0)), int(datum.get("g", 255.0)),
		int(datum.get("b", 255.0)), int(datum.get("a", 255.0)))
