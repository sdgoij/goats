# The splashes, drawn: `water.js`'s pooled drops as a `MultiMesh` of small spheres.
#
# `waterSplashDraw` is a handful of `drawSphereEx` calls from a pool of `SPLASH_MAX` fixed
# slots, and this is that pool read the Godot way: one `MultiMesh` of unit spheres whose
# `visible_instance_count` is the live drops, so a splash allocates nothing and a frame with
# no splash costs nothing at all. The fade is `waterSplashDraw`'s own, the drop's remaining
# life as the alpha, carried as a per-instance colour.
#
# It is a *second* water node rather than part of `water_mesh.gd`, and the split is the
# scene's: the surface carries the ground and the table and is one draw, while a drop is a
# ball in the air over it. The scene draws them after the surface for the same reason --
# a splash is a thing leaving the water rather than a thing in it -- and Godot's own
# transparent sorting does the rest.
#
# `Water` owns the pool and the physics (`wake_step`, `splash`, `_splash_step`); this node
# only reads it. That is `water_mesh.gd`'s bargain again: the rules are the scene's and the
# draw is Godot's.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterSplash
extends MultiMeshInstance3D

## The pool the water keeps, so the two cannot disagree about how many drops there are.
const SLOTS := Water.SPLASH_MAX

## The water whose drops this draws. `main.gd` hands it in; with none, nothing is drawn.
var water: Water

var _multimesh: MultiMesh

func _ready() -> void:
	_build()

## Build the pool's `MultiMesh`, once. Called from `_ready` and from `update`, because a
## `SceneTree` script that adds the node during `_initialize` never sees `_ready` -- the same
## reason `water_mesh.gd` builds its material inside `build` rather than in `_ready`.
func _build() -> void:
	if _multimesh != null:
		return
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	var sphere := SphereMesh.new()
	# `drawSphereEx(..., 0.035, 4, 4, ...)`: a 3.5 cm ball, and four is as low as either
	# count goes -- a drop is three pixels across, so more segments are invisible.
	sphere.radius = Water.SPLASH_RADIUS
	sphere.height = Water.SPLASH_RADIUS * 2.0
	sphere.radial_segments = 4
	sphere.rings = 4
	var material := StandardMaterial3D.new()
	# The scene's colour is an *immediate* one rather than a lit surface, so the drops are
	# unshaded; and the alpha is the drop's own life, which is what `waterSplashDraw`
	# computes per drop.
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sphere.material = material
	_multimesh.mesh = sphere
	_multimesh.instance_count = SLOTS
	multimesh = _multimesh
	# A drop is three pixels across and lives half a second; a shadow from one is noise.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Push this frame's live drops. A slot holding nothing reports a fade of zero, which is
## `waterSplashDraw`'s own test.
func update() -> void:
	_build()
	if _multimesh == null:
		return
	var index: int = 0
	if water != null:
		for slot in SLOTS:
			var drop: Vector4 = water.splash_drop(slot)
			if drop.w <= 0.0:
				continue
			_multimesh.set_instance_transform(
				index, Transform3D(Basis(), Vector3(drop.x, drop.y, drop.z)))
			var colour: Color = Water.SPLASH_COLOUR
			colour.a = minf(1.0, drop.w) * (Water.SPLASH_ALPHA / 255.0)
			_multimesh.set_instance_color(index, colour)
			index += 1
	_multimesh.visible_instance_count = index
	# The slots past the live ones are not drawn, but the automatic bounds would still be
	# computed over them -- every one sitting at the origin -- so a region that holds any
	# splash the water can throw is declared instead. It is wider than the terrain field
	# because the drops follow the goat wherever it is.
	_multimesh.custom_aabb = AABB(
		Vector3(-256.0, -16.0, -256.0), Vector3(512.0, 64.0, 512.0))

## How many drops the last `update` drew, for a probe.
func count() -> int:
	if _multimesh == null:
		return 0
	return _multimesh.visible_instance_count
