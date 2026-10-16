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
# What is *not* here: the texture a mesh draws in when the mod binds one is in, but the
# shadow-map slot and `unload()` are not, and neither is a mod's own *sound* -- the other half
# of the engine surface these members replace. Those are the next additions, and until they
# exist a mod that builds its meshes in JavaScript draws its shapes but not its voices.
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
## Mesh handle -> the `ArrayMesh` a mod built, or `null` for one that would not build. Built
## once: a mod builds a mesh at boot and draws it for the life of the process.
var _meshes := {}
## ...and texture handle -> the `ImageTexture`, on the same terms.
var _textures := {}
## The per-frame instances, index-aligned with `commands`.
var _instances: Array = []

## Take one frame's world records. Parsing here rather than in `_place` keeps the placement a
## plain loop, and a record that does not parse is dropped rather than failing the frame.
##
## An `unload` is **not a draw**: it frees what a handle became and is taken out of the frame, so
## `commands` is the draws and `placed` is still what was placed (`goats.gfx.unload`).
func adopt(records: PackedStringArray) -> void:
	commands.clear()
	for record in records:
		var parsed: Variant = JSON.parse_string(String(record))
		if not (parsed is Dictionary):
			continue
		var command: Dictionary = parsed
		if String(command.get("k", "")) == "unload":
			_release(String(command.get("h", "")))
			continue
		commands.append(parsed)
	frames += 1
	_rebuild()

## Forget a handle a mod freed: the Godot resource this node built for it, any node still holding
## it, and the arrays the host is keeping.
##
## The host call is safe *here* and nowhere else: `adopt` runs in the frame's own drain, outside
## any mod's JavaScript, which is what a member reached through `_mod_call` cannot say for itself
## (`PORT.md` section 9). Dropping the node's `mesh` as well as the cache entry is what actually
## frees it -- an `ArrayMesh` a `MeshInstance3D` still points at is not freed by forgetting.
func _release(handle: String) -> void:
	if handle.is_empty():
		return
	_meshes.erase(handle)
	_textures.erase(handle)
	for instance in _instances:
		var node := instance as MeshInstance3D
		if node == null or String(_meta(node, "mod_mesh", "")) != handle:
			continue
		node.mesh = null
		node.set_meta("mod_mesh", "")
	if host != null:
		host.call("forget", handle)

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
		"mesh":
			# A `mesh` record's handle is *any* handle (`APIv1.md` section 4.19), and a mod has two kinds:
			# its own geometry (`goats.gfx.mesh`, an `ArrayMesh` the extension holds) or an asset
			# (`goats.gfx.model` / `assets.get`, a glTF this scene imports). Both checked-in examples
			# rely on it -- the flock's parts are meshes and the fat guy's body is a *model*, drawn
			# through the same axis-angle call -- and asking only the mesh store is what left him
			# invisible while his simulation ran. The kind carries which, so a slot that changes from
			# one to the other is rebuilt rather than reused with the wrong node under it.
			var oriented_handle: String = String(command.get("h", ""))
			if _mesh_for(oriented_handle) != null:
				kind = "mesh"
				node = MeshInstance3D.new()
			else:
				kind = "model-mesh"
				var packed: PackedScene = _model_scene(oriented_handle)
				if packed == null:
					return null
				node = packed.instantiate() as Node3D
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
	# The *node's* kind rather than the record's: a `mesh` record is one of two kinds of node
	# (`_node`), and the orientation below is the same for both.
	var kind: String = String(_meta(node, "mod_kind", ""))
	if kind == "cube":
		_place_cube(node as MeshInstance3D, command)
		return
	if kind == "mesh" or kind == "model-mesh":
		_place_oriented(node, command)
		return
	node.rotation = Vector3(0.0, float(command.get("yaw", 0.0)), 0.0)
	var scale: float = float(command.get("scale", 1.0))
	node.scale = Vector3(scale, scale, scale)
	_apply_tint(node, _color(command.get("tint", null)))

## A `mesh` record's placement: a mod's own geometry *or* a model, oriented the same way.
##
## The orientation is an **axis and an angle** rather than a yaw -- `goats.gfx.draw.mesh`'s whole
## point, because a tumbling thing is not a turning one -- so the basis is set outright instead of
## through `rotation`, which has no third axis to give. The angle is the record's own, which the
## facade has already seen in the API's unit: **radians**.
func _place_oriented(node: Node3D, command: Dictionary) -> void:
	var handle: String = String(command.get("h", ""))
	if node is MeshInstance3D:
		var mesh: MeshInstance3D = node
		if String(_meta(mesh, "mod_mesh", "")) != handle:
			mesh.mesh = _mesh_for(handle)
			mesh.set_meta("mod_mesh", handle)
	var scale: float = float(command.get("scale", 1.0))
	var axis := Vector3(float(command.get("ax", 0.0)), float(command.get("ay", 1.0)),
		float(command.get("az", 0.0)))
	if axis.length_squared() < 1e-12:
		# A degenerate axis is one the mod did not mean: the up axis is the yaw case.
		axis = Vector3.UP
	node.basis = Basis(axis.normalized(), float(command.get("angle", 0.0))) \
		.scaled(Vector3(scale, scale, scale))
	# A mesh's material is the extension's (its per-vertex colours and its bound texture); an
	# imported model carries its own, and only the tint is ours.
	if node is MeshInstance3D:
		_apply_mesh_material(node as MeshInstance3D, handle, _color(command.get("tint", null)))
	else:
		_apply_tint(node, _color(command.get("tint", null)))

func _place_cube(box: MeshInstance3D, command: Dictionary) -> void:
	# The size is the record's, so the mesh is this instance's own -- two cubes in one frame
	# are two sizes.
	(box.mesh as BoxMesh).size = Vector3(float(command.get("w", 1.0)),
		float(command.get("h", 1.0)), float(command.get("d", 1.0)))
	var material := StandardMaterial3D.new()
	material.albedo_color = _color(command.get("col", null))
	box.material_override = material

## Tint every mesh in an instance the way raylib's `drawModelEx` does: the tint **multiplies** each
## surface's own material rather than replacing the whole node with one flat colour.
##
## The distinction is an entire look. raylib scales a model's own colours by the tint, so a white
## tint changes nothing; a single `material_override` at the tint instead *erases* them. The fat guy
## is the model that shows the difference -- his glTF carries no texture at all, only twelve
## `baseColorFactor`s (shirt, skin, hair, guitar...), so the flat override drew him white. It is
## `_apply_mesh_material`'s shape on the other side: a mod's own mesh really is one material and the
## tint belongs on it, while an imported model already has a material per surface and the tint
## belongs *in* each. The material is kept per surface and rebuilt only when the tint changes,
## which is this function's old rule for its old reason.
func _apply_tint(root: Node, tint: Color) -> void:
	var stack: Array = [root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		if not (node is MeshInstance3D):
			continue
		var instance: MeshInstance3D = node
		var last: Variant = _meta(instance, "mod_tint", null)
		if last != null and (last as Color).is_equal_approx(tint):
			continue
		var surfaces: int = 0 if instance.mesh == null else instance.mesh.get_surface_count()
		if surfaces == 0:
			# Nothing to multiply into: a mesh with no surface still takes the tint flat.
			var flat := StandardMaterial3D.new()
			flat.albedo_color = tint
			instance.material_override = flat
		else:
			# A flat override a previous tint may have left is cleared, because the surface
			# overrides below are what the node draws with now.
			instance.material_override = null
			for surface in surfaces:
				instance.set_surface_override_material(surface,
					_tinted(instance.mesh.surface_get_material(surface), tint))
		instance.set_meta("mod_tint", tint)

## One surface's material with `tint` multiplied into its albedo, which is raylib's rule: the tint
## scales what the surface already had, so white changes nothing and a dusk-blue dims without
## repainting. A surface with no material of its own draws white times the tint, and the texture,
## the roughness and the metallic all ride along in the duplicate.
static func _tinted(source: Material, tint: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	if source is StandardMaterial3D:
		var standard: StandardMaterial3D = source
		material = standard.duplicate() as StandardMaterial3D
		material.albedo_color = standard.albedo_color * tint
	else:
		material.albedo_color = tint
	if tint.a < 1.0:
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	return material

## The imported scene for an asset name, or null. Packed from the generated node so a draw can
## instance it; the node itself is freed, because the scene is what is kept.
##
## Two kinds of name arrive here, and they are told apart by their prefix: a mod's declared asset is
## a `mod:...` opaque name the host holds the bytes of, and a **built-in** slot's value is one of the
## game's own files under `res://assets/` (`goats.assets.get("model.goat")`), which this build loads
## itself. Nothing here is reachable by a mod as a path (`APIv1.md` section 0) -- a mod only ever
## holds the name it was handed.
func _model_scene(name: String) -> PackedScene:
	if _models.has(name):
		return _models[name]
	var packed: PackedScene = null
	if not name.is_empty():
		if name.begins_with("mod:"):
			packed = _imported_scene(name)
		else:
			packed = _built_in_scene(name)
	_models[name] = packed
	return packed

## A mod's own asset, imported at runtime from the bytes the host kept.
func _imported_scene(name: String) -> PackedScene:
	var packed: PackedScene = null
	if host == null:
		return null
	var bytes: PackedByteArray = host.call("asset_bytes", name)
	if bytes.is_empty():
		print("mod: no asset named ", name)
		return null
	var document := GLTFDocument.new()
	var state := GLTFState.new()
	if document.append_from_buffer(bytes, "", state) != OK:
		print("mod: ", name, " is not a glTF this build can read")
		return null
	var scene: Node = document.generate_scene(state)
	if scene == null:
		print("mod: ", name, " imported to nothing")
		return null
	packed = PackedScene.new()
	if packed.pack(scene) != OK:
		packed = null
		print("mod: ", name, " would not pack")
	scene.free()
	return packed

## One of the game's own files, by the logical name a built-in slot holds.
func _built_in_scene(name: String) -> PackedScene:
	var path: String = Audio.ASSET_ROOT + name
	if not ResourceLoader.exists(path):
		print("mod: no built-in asset named ", name)
		return null
	var loaded: Variant = ResourceLoader.load(path)
	if loaded is PackedScene:
		return loaded
	print("mod: ", name, " is not a scene this build can instance")
	return null

## A node's own metadata, or `default` when it has none. `Object.get_meta` reports an error for
## a key that is absent even when it is handed a default (Godot 4.7), and this file asks for
## both of its keys on nodes that may not have them yet.
static func _meta(node: Object, key: String, fallback: Variant) -> Variant:
	return node.get_meta(key) if node.has_meta(key) else fallback

## The material a mod's own mesh draws with: its per-vertex colours, the tint, and the texture
## `goats.gfx.bind` gave it. Kept on the node and rebuilt only when either changes, which is
## `_apply_tint`'s rule for `_apply_tint`'s reason -- a mod that tints the same shape the same
## colour every frame should pay for it once.
func _apply_mesh_material(instance: MeshInstance3D, handle: String, tint: Color) -> void:
	var binding: String = ""
	if host != null:
		binding = String(host.call("mesh_binding", handle))
	var stamp: Array = [tint, binding]
	var last: Variant = _meta(instance, "mod_mesh_mat", null)
	if last is Array and (last as Array) == stamp:
		return
	var material := StandardMaterial3D.new()
	material.albedo_color = tint
	# The mesh carries its own RGBA per vertex (`colors` in the arrays, `APIv1.md` section
	# 4.19), so the material has to let them through or every shape draws white.
	material.vertex_color_use_as_albedo = true
	if not binding.is_empty():
		var texture: Texture2D = _texture_for(binding)
		if texture != null:
			material.albedo_texture = texture
	instance.material_override = material
	instance.set_meta("mod_mesh_mat", stamp)

## The `ArrayMesh` behind a mesh handle a mod built, or null. Built once and remembered --
## including the `null` of one that would not build, so a bad mesh is reported once.
func _mesh_for(handle: String) -> ArrayMesh:
	if _meshes.has(handle):
		return _meshes[handle]
	var built: ArrayMesh = null
	if host != null and not handle.is_empty():
		# An empty answer is "no such mesh" -- which is what a handle the mod freed arrives as,
		# so it is read as one rather than handed to `JSON.parse_string`, which logs an error for
		# an empty string.
		var json: String = String(host.call("mesh_data", handle))
		if json.is_empty():
			print("mod: no mesh named ", handle)
		else:
			var parsed: Variant = JSON.parse_string(json)
			if parsed is Dictionary:
				built = _build_mesh(parsed)
	_meshes[handle] = built
	return built

## An `ArrayMesh` from the arrays a mod handed `goats.gfx.mesh`.
##
## The one thing here that is **not** a transcription: the **winding is reversed.** The arrays
## are authored for the reference client's culling, and raylib and Godot wind a front face in
## *opposite* directions -- the finding that once cost this port an invisible ground (`PORT.md`
## section 9). Which way a triangle faces is the client's business, not the mod's, so the
## adaptation lives here rather than in every mod that builds a mesh.
func _build_mesh(data: Dictionary) -> ArrayMesh:
	var vertices: Array = data.get("v", [])
	if vertices.size() < 9 or vertices.size() % 3 != 0:
		print("mod: a mesh the mod built has no usable vertices")
		return null
	var count: int = vertices.size() / 3
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _vec3s(vertices)
	var indices: Variant = data.get("i")
	if indices is Array and (indices as Array).size() >= 3:
		arrays[Mesh.ARRAY_INDEX] = _triangles(indices, count)
	else:
		# A triangle soup: the corners are implied, and implied in the other order.
		var implied := PackedInt32Array()
		for at in range(0, count - count % 3, 3):
			implied.append(at)
			implied.append(at + 2)
			implied.append(at + 1)
		arrays[Mesh.ARRAY_INDEX] = implied
	var normals: Variant = data.get("n")
	if normals is Array and (normals as Array).size() == vertices.size():
		arrays[Mesh.ARRAY_NORMAL] = _vec3s(normals)
	var colors: Variant = data.get("c")
	if colors is Array and (colors as Array).size() == count * 4:
		arrays[Mesh.ARRAY_COLOR] = _colors(colors, count)
	var uvs: Variant = data.get("uv")
	if uvs is Array and (uvs as Array).size() == count * 2:
		arrays[Mesh.ARRAY_TEX_UV] = _vec2s(uvs)
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	# `add_surface_from_arrays` returns nothing on 4.7, so the answer is whether a surface is
	# there -- which is also the question, since a mesh with no surface draws nothing.
	if mesh.get_surface_count() != 1:
		print("mod: a mesh the mod built would not add a surface")
		return null
	return mesh

## An index list with every triangle's corners reversed, and any triangle that reaches past the
## vertices dropped -- a mod's own bug should cost its own shape and not the whole frame.
static func _triangles(indices: Array, count: int) -> PackedInt32Array:
	var out := PackedInt32Array()
	for at in range(0, (indices.size() / 3) * 3, 3):
		var a: int = int(indices[at])
		var b: int = int(indices[at + 1])
		var c: int = int(indices[at + 2])
		if a < 0 or b < 0 or c < 0 or a >= count or b >= count or c >= count:
			continue
		out.append(a)
		out.append(c)
		out.append(b)
	return out

## The `ImageTexture` behind a texture handle a mod generated (`goats.gfx.texture`), or null.
func _texture_for(handle: String) -> Texture2D:
	if _textures.has(handle):
		return _textures[handle]
	var built: Texture2D = null
	if host != null and not handle.is_empty():
		var json: String = String(host.call("texture_data", handle))
		if not json.is_empty():
			var parsed: Variant = JSON.parse_string(json)
			if parsed is Dictionary:
				built = _build_texture(parsed)
	_textures[handle] = built
	return built

## An `ImageTexture` from `{size, pixels}`, where `pixels` is `size * size` eight-hex-digit
## texels ("rrggbbaa") in row order -- the API's own encoding (`APIv1.md` section 4.19). A
## string rather than bytes because a mod *generates* it (`birds` bakes its feather pattern from
## its own noise), and a string is one crossing rather than a megabyte of array.
func _build_texture(data: Dictionary) -> Texture2D:
	var size: int = int(data.get("size", 0))
	var pixels: String = String(data.get("pixels", ""))
	if size <= 0 or pixels.length() != size * size * 8:
		print("mod: a texture the mod generated has the wrong length")
		return null
	var bytes := PackedByteArray()
	bytes.resize(size * size * 4)
	for texel in size * size:
		var at: int = texel * 8
		for channel in 4:
			bytes[texel * 4 + channel] = pixels.substr(at + channel * 2, 2).hex_to_int()
	var image := Image.create_from_data(size, size, false, Image.FORMAT_RGBA8, bytes)
	if image == null:
		return null
	return ImageTexture.create_from_image(image)

## Flat number arrays as Godot's own. The API's shape is raylib's -- three numbers a vertex, four
## bytes a colour -- and these three are the whole of the conversion.
static func _vec3s(flat: Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(flat.size() / 3)
	for at in flat.size() / 3:
		out[at] = Vector3(float(flat[at * 3]), float(flat[at * 3 + 1]), float(flat[at * 3 + 2]))
	return out

static func _vec2s(flat: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(flat.size() / 2)
	for at in flat.size() / 2:
		out[at] = Vector2(float(flat[at * 2]), float(flat[at * 2 + 1]))
	return out

static func _colors(flat: Array, count: int) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(count)
	for at in count:
		out[at] = Color8(int(flat[at * 4]), int(flat[at * 4 + 1]), int(flat[at * 4 + 2]),
			int(flat[at * 4 + 3]))
	return out

## A record's colour as a Godot `Color`: the API's `{r, g, b, a}` in 0..255, and a missing one is
## opaque white rather than an error.
static func _color(value: Variant) -> Color:
	if not (value is Dictionary):
		return Color.WHITE
	var datum: Dictionary = value
	return Color8(int(datum.get("r", 255.0)), int(datum.get("g", 255.0)),
		int(datum.get("b", 255.0)), int(datum.get("a", 255.0)))
