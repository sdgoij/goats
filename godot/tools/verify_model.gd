# Smoke test for the port's riskiest asset assumption: that Godot's glTF import
# reproduces the rope the raylib client relies on -- 14 named clips, the 15-bone
# skeleton, and the fleece materials (including KHR_texture_transform, which
# raylib ignores and Godot honours).
#
#   Godot --headless --path godot --script res://tools/verify_model.gd
#
# It is a SceneTree script so it needs no scene and no window; a non-zero exit
# makes it usable as a gate.
extends SceneTree

const MODEL := "res://assets/goat_animated.glb"

# The clips `model.js` finds by name. A missing one is not fatal in the client
# (it degrades to the walk), so the port must not silently lose one either.
const WANTED := [
	"GoatIdle", "GoatIdle2", "GoatIdle3",
	"GoatWalk", "GoatTrot", "GoatRun",
	"GoatJump", "GoatJump2", "GoatFlung",
	"GoatSleep", "GoatSleep2",
	"GoatDeath", "GoatEat", "GoatEat2",
]

func _initialize() -> void:
	var failures: Array[String] = []

	var packed := load(MODEL) as PackedScene
	if packed == null:
		print("FAIL: could not load ", MODEL)
		quit(1)
		return
	var root := packed.instantiate()

	var anim := _find(root, "AnimationPlayer") as AnimationPlayer
	if anim == null:
		failures.append("no AnimationPlayer in the imported scene")
	else:
		var names := anim.get_animation_list()
		names.sort()
		print("clips: ", names.size())
		for name in names:
			print("  %-12s %.4f s" % [name, anim.get_animation(name).length])
		for want in WANTED:
			if not names.has(want):
				failures.append("missing clip " + want)

	var skel := _find(root, "Skeleton3D") as Skeleton3D
	if skel == null:
		failures.append("no Skeleton3D in the imported scene")
	else:
		var bones := skel.get_bone_count()
		print("bones: ", bones)
		if bones != 15:
			failures.append("expected 15 bones, got %d" % bones)
		for bone in ["Root", "Spine", "Neck", "Head", "Tail", "LidL", "LidR"]:
			if skel.find_bone(bone) < 0:
				failures.append("missing bone " + bone)

	# glTF's five primitives (one per material) land as one ArrayMesh with five
	# surfaces on a single MeshInstance3D, not five nodes -- so this is the
	# surface count, and it is what tells the fur from the eyes.
	var mesh_instance := _find(root, "MeshInstance3D") as MeshInstance3D
	if mesh_instance == null or mesh_instance.mesh == null:
		failures.append("no MeshInstance3D in the imported scene")
	else:
		var surfaces := mesh_instance.mesh.get_surface_count()
		print("mesh surfaces: ", surfaces)
		if surfaces != 5:
			failures.append("expected 5 surfaces (5 materials), got %d" % surfaces)
		var materials: Array[String] = []
		for s in surfaces:
			var material := mesh_instance.mesh.surface_get_material(s) as BaseMaterial3D
			materials.append(material.resource_name if material != null else "<none>")
		print("  material names: ", materials)
		# The textures must survive the "embed, don't extract" import default:
		# the fleece is the only surface with a diffuse and a normal map.
		var fur := mesh_instance.mesh.surface_get_material(0) as BaseMaterial3D
		if fur == null or fur.albedo_texture == null:
			failures.append("GoatFur lost its diffuse texture")
		elif fur.normal_texture == null:
			failures.append("GoatFur lost its normal texture")
		else:
			print("  GoatFur textures: diffuse ", fur.albedo_texture.get_size(),
				", normal ", fur.normal_texture.get_size())

	root.free()

	if failures.is_empty():
		print("OK: the model imports with every clip, bone and surface the scene needs")
		quit(0)
	else:
		for f in failures:
			print("FAIL: ", f)
		quit(1)

func _find(node: Node, type_name: String) -> Node:
	if node.is_class(type_name):
		return node
	for child in node.get_children():
		var found := _find(child, type_name)
		if found != null:
			return found
	return null

