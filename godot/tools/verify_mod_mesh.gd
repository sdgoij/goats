# The mods' own geometry gate: `goats.gfx.mesh` / `texture` / `bind` and `draw.mesh`
# (`APIv1.md` section 4.19) -- the API's answer to the engine's `makeModel` / `makeTexture` /
# `setModelTexture` / `drawModelEx`, so a mod that builds its own shapes never reads an engine
# library.
#
#   Godot --headless --path godot --script res://tools/verify_mod_mesh.gd
#
# This is the piece `verify_mod_gfx.gd` does not reach. That gate is about *assets* -- a name the
# host resolves and Godot imports -- and this one is about geometry a mod built in JavaScript: a
# mesh that exists nowhere on disk, a texture generated from a mod's own noise, and a placement
# that is an axis and an angle rather than a yaw. It is the surface that `birds` needs and the
# reason a mod was bound to one client at all.
#
# Six things, and the fourth and fifth are the ones this port can get wrong quietly:
#
#   1. **A mesh becomes an `ArrayMesh`** with the mod's own vertices, normals, texcoords and
#      per-vertex colours -- the arrays the mod handed over, not a box standing in for them.
#   2. **The texture becomes an `ImageTexture`**, texel for texel, from the mod's hex.
#   3. **`bind` reaches the material**, so a mesh the mod textured draws in it.
#   4. **The winding is reversed.** The arrays are authored for the reference client's culling
#      and raylib and Godot wind a front face oppositely (`PORT.md` section 9), so a triangle
#      handed over as `[0, 1, 2]` must be stored as `[0, 2, 1]`. A port that forgot this would
#      draw every generated shape inside-out, which is exactly the bug the heightfield had.
#   5. **The placement is an axis-angle**, not a yaw: a tumbling thing is not a turning one, and
#      a port that mapped the call onto `rotation.y` would look right for a bird standing still.
##   6. **A malformed build answers `null`** -- the same answer a client with no renderer gives --
##      so a mod's check is one `if` on every platform.
##   7. **A freed handle is freed.** `goats.gfx.unload` is *queued* for the frame rather than done
##      in the mod's own JavaScript, which is how it can work at all: the host is borrowed while a
##      mod runs (`PORT.md` section 9). What it must actually drop is the whole of what the handle
##      became -- the scene's cache, the node's mesh and the extension's arrays.
##
## **The repository's mods are off here**, set in `_initialize` before the scene exists. Every count
## below is exact -- one draw, one node -- and a world mod draws in `draw3d` every frame it is
## loaded: `birds` is 24 records a frame since its rework, which makes "what this hook drew" and
## "what the tree holds" two different questions. `verify_scene_mods.gd` is where the repository's
## own mods are the subject.
#
# **The sentinel.** GDScript has no `try`, so a runtime error inside a check aborts it and leaves
# the failure it was about to record unrecorded. `_finished` is set at the very end of `_check`,
# and a run that does not reach it is a failure whatever else it asserted (see
# `verify_mod_surface.gd`, where this bit for real).
extends SceneTree

## The probe. It builds a three-vertex mesh, a 2x2 texture, binds them and draws the mesh at
## `(2, 3, 4)` about the **+X** axis by a quarter turn -- the axis a yaw-only port would drop on
## the floor -- then reports what the calls answered.
const PROBE_JS := """
(function () {
    goats.command("modmesh", function (parts) {
        const verb = parts[1] === undefined ? "build" : parts[1];
        const out = {};
        // The second verb: free what the first one built. The handle is the scene's own, kept on
        // a global because a command is one call and the handle has to outlive it.
        if (verb === "unload") {
            goats.gfx.unload(globalThis.__modMesh);
            out.unloaded = goats.gfx.mesh([0, 0, 0, 1, 0, 0, 0, 1, 0]) !== globalThis.__modMesh;
            return JSON.stringify(out);
        }
        out.mesh_null = goats.gfx.mesh([1, 2]) === null;
        out.texture_null = goats.gfx.texture(2, "short") === null;
        out.texture_odd = goats.gfx.texture(2.5, "") === null;

        // One triangle, three colours, a normal each and a texcoord each.
        const mesh = goats.gfx.mesh(
            [0, 0, 0, 1, 0, 0, 0, 1, 0],
            [0, 1, 2],
            [0, 0, 1, 0, 0, 1, 0, 0, 1],
            [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255],
            [0, 0, 1, 0, 0, 1]);
        out.mesh = typeof mesh === "string" ? "handle" : String(mesh);
        const texture = goats.gfx.texture(2,
            "ff0000ff" + "00ff00ff" + "0000ffff" + "ffffffff");
        out.texture = typeof texture === "string" ? "handle" : String(texture);
        goats.gfx.bind(mesh, texture);
        out.bound = true;
        out.cached = goats.gfx.mesh([0, 0, 0, 1, 0, 0, 0, 1, 0]) !== mesh;
        globalThis.__modMesh = mesh;

        out.draws = globalThis.__modMeshDraws || 0;
        goats.on("draw3d", function () {
            globalThis.__modMeshDraws = (globalThis.__modMeshDraws || 0) + 1;
            goats.gfx.draw.mesh(mesh, 2, 3, 4, 1, 0, 0, Math.PI / 2, 1, goats.draw.WHITE);
            // A null handle is not a draw, the same as a null model.
            goats.gfx.draw.mesh(goats.gfx.mesh([]), 9, 9, 9);
        });
        return JSON.stringify(out);
    });
})();
"""

var _failures: Array[String] = []
var _frames := 0
var _finished := false
var _main: Node
var _world: Object

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	# The repository's mods off -- see the header. Nothing this gate needs lives in them: it builds
	# its own mesh and its own texture, and draws one record a frame.
	OS.set_environment("GOATS_NO_MODS", "1")
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
	if not _finished:
		_failures.append("the checks did not run to the end (a script error aborted them)")
	if _failures.is_empty():
		print("OK: a mod builds its own mesh and image, and the port draws them")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	_world = _main.get("mod_world")
	var mods: Object = _main.get("mods")
	var host: Object = mods.get("host")
	if _world == null or host == null:
		_failures.append("the scene has no world node or no mod host")
		_finished = true
		return

	var evaluated: String = str(host.call("eval_js", PROBE_JS))
	if evaluated != "ok":
		_failures.append("the mesh probe did not run: " + evaluated)
		_finished = true
		return

	# The probe registers its `draw3d` hook inside a command, so it has to be invoked once and
	# then a frame has to be drawn: the hook is what makes the draw.
	var answer: Variant = JSON.parse_string(str(host.call("run_command", "modmesh", "modmesh")))
	if not (answer is Dictionary):
		_failures.append("the mesh probe did not answer with a table")
		_finished = true
		return
	_check_calls(answer)

	# One frame with this scene's camera, which is what fires `draw3d` and drains the records.
	mods.call("frame", 12.0, Vector2(1280.0, 720.0), true, _main.get_node("Camera3D"))
	var commands: Array = _world.get("commands")
	print("records: ", commands.size(), ", placed: ", _world.get("placed"))
	for command: Dictionary in commands:
		print("  ", command.get("k"), "  h=", command.get("h"))
	if commands.size() != 1:
		_failures.append("one draw was asked for and %d arrived" % commands.size())

	_check_node()
	_check_release(host)
	_finished = true

## 7. Freeing a handle frees what it became -- in the scene and in the extension both.
func _check_release(host: Object) -> void:
	if _world.get_child_count() < 1:
		return
	var handle: String = String((_world.get_child(0) as MeshInstance3D).get_meta("mod_mesh"))
	if handle.is_empty():
		return
	var freed: Variant = JSON.parse_string(str(host.call("run_command", "modmesh", "modmesh unload")))
	if not (freed is Dictionary) or (freed as Dictionary).get("unloaded") != true:
		_failures.append("goats.gfx.unload did not answer: %s" % [freed])
	# A frame, which is what a queued unload rides in on.
	_main.get("mods").call("frame", 12.0, Vector2(1280.0, 720.0), true, _main.get_node("Camera3D"))
	print("unload: ", handle, "  arrays left: ", str(host.call("mesh_data", handle)).length(),
		"  cached: ", _world.get("_meshes").get(handle, null) != null,
		"  mesh: ", (_world.get_child(0) as MeshInstance3D).mesh)
	if not str(host.call("mesh_data", handle)).is_empty():
		_failures.append("the extension still holds the arrays of a freed handle")
	if _world.get("_meshes").get(handle, null) != null:
		_failures.append("the scene still caches what a freed handle became")
	if (_world.get_child(0) as MeshInstance3D).mesh != null:
		_failures.append("a node still holds the mesh of a freed handle")

## 6. The two malformed builds, and that a second `mesh()` is its own handle.
func _check_calls(answer: Dictionary) -> void:
	for key: String in ["mesh_null", "texture_null", "texture_odd"]:
		if answer.get(key) != true:
			_failures.append("goats.gfx.%s did not answer null for a malformed build: %s"
				% [key, answer.get(key)])
	if String(answer.get("mesh", "")) != "handle":
		_failures.append("goats.gfx.mesh did not answer a handle: %s" % answer.get("mesh"))
	if String(answer.get("texture", "")) != "handle":
		_failures.append("goats.gfx.texture did not answer a handle: %s" % answer.get("texture"))
	if answer.get("cached") != true:
		_failures.append("two meshes were handed the same handle")
	print("calls: mesh ", answer.get("mesh"), "  texture ", answer.get("texture"),
		"  malformed -> null")

## 1-5. The node the record became, and everything about it.
func _check_node() -> void:
	if _world.get_child_count() < 1:
		_failures.append("the mesh draw placed nothing")
		return
	var instance := _world.get_child(0) as MeshInstance3D
	if instance == null:
		_failures.append("the mesh draw did not place a MeshInstance3D")
		return
	if not (instance.mesh is ArrayMesh):
		_failures.append("the handle did not become an ArrayMesh")
		return

	# 1. The arrays are the mod's own.
	var arrays: Array = (instance.mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	print("mesh: ", vertices.size(), " vertex/vertices, indices ", indices)
	if vertices.size() != 3:
		_failures.append("the mesh has %d vertices, the mod built 3" % vertices.size())
	elif not vertices[0].is_equal_approx(Vector3(0, 0, 0)) \
			or not vertices[1].is_equal_approx(Vector3(1, 0, 0)) \
			or not vertices[2].is_equal_approx(Vector3(0, 1, 0)):
		_failures.append("the mesh's vertices are not the mod's: %s" % [vertices])
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	# A tolerance rather than an equality, and the reason is worth knowing: Godot re-encodes the
	# vertex buffer, so a normal read back off an `ArrayMesh` is the one that went in to within
	# normal quantisation -- the mod's `(0, 0, 1)` comes back as `(-0.000015, -0.000015, 1.0)`.
	# Positions and colours survive exactly; a normal does not, and a gate that demanded it would
	# fail on a mesh that is right.
	if normals.size() != 3 or not _near_vec(normals[0], Vector3(0, 0, 1)):
		_failures.append("the mesh's normals are not the mod's: %s" % [normals])
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if uvs.size() != 3 or not uvs[1].is_equal_approx(Vector2(1, 0)):
		_failures.append("the mesh's texcoords are not the mod's: %s" % [uvs])
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	if colors.size() != 3 or not colors[0].is_equal_approx(Color8(255, 0, 0, 255)):
		_failures.append("the mesh's per-vertex colours are not the mod's: %s" % [colors])

	# 4. The winding. `[0, 1, 2]` authored for raylib is `[0, 2, 1]` here.
	if indices.size() != 3 or indices[0] != 0 or indices[1] != 2 or indices[2] != 1:
		_failures.append("the winding was not reversed for this client: %s" % [indices])

	# 5. The placement: an axis-angle, not a yaw.
	if not instance.position.is_equal_approx(Vector3(2, 3, 4)):
		_failures.append("the mesh is at %s, the mod put it at (2, 3, 4)" % instance.position)
	var wanted := Basis(Vector3(1, 0, 0), PI / 2.0)
	if not instance.basis.is_equal_approx(wanted):
		_failures.append("the mesh's basis is %s, a quarter turn about +X is %s"
			% [instance.basis, wanted])

	# 2/3. The texture, texel for texel, and the material that carries it and the vertex colours.
	var material := instance.material_override as StandardMaterial3D
	if material == null:
		_failures.append("the mesh has no material of its own")
		return
	if not material.vertex_color_use_as_albedo:
		_failures.append("the mesh's material does not let its per-vertex colours through")
	if material.albedo_texture == null:
		_failures.append("the texture the mod bound did not reach the material")
		return
	var image: Image = material.albedo_texture.get_image()
	print("texture: ", image.get_width(), "x", image.get_height(),
		"  texel 0 ", image.get_pixel(0, 0), "  texel 3 ", image.get_pixel(1, 1))
	if image.get_width() != 2 or image.get_height() != 2:
		_failures.append("the texture is %dx%d, the mod generated 2x2"
			% [image.get_width(), image.get_height()])
	elif not image.get_pixel(0, 0).is_equal_approx(Color8(255, 0, 0, 255)):
		_failures.append("texel 0 is %s, the mod wrote ff0000ff" % image.get_pixel(0, 0))
	elif not image.get_pixel(1, 1).is_equal_approx(Color8(255, 255, 255, 255)):
		_failures.append("texel 3 is %s, the mod wrote ffffffff" % image.get_pixel(1, 1))

## A vector comparison for a value Godot re-encoded on its way into the vertex buffer.
static func _near_vec(mine: Vector3, live: Vector3) -> bool:
	return absf(mine.x - live.x) < 1e-3 and absf(mine.y - live.y) < 1e-3 \
		and absf(mine.z - live.z) < 1e-3
