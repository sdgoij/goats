# The water's surface, drawn: `water.js`'s mesh (M20b) as an `ArrayMesh`.
#
# It is `terrain_mesh.gd`'s sibling and follows it exactly -- the same 49x49 grid at the
# same anchor, rebuilt whole whenever the ground moves -- with one difference that is the
# whole of why the water can follow the rain at all: the **positions carry the ground, not
# the water**. The level is a shader uniform and `water.gdshader`'s vertex stage lifts
# each one by its own depth, so a rising table costs one uniform rather than a rebuild.
#
# The other difference is the index list, which is *cut*: a quad is kept only if some
# corner of it stands under the table's ceiling (`TUNING.water.high`), because nothing
# above the ceiling can ever be wet. A dry field therefore costs one empty draw rather
# than the terrain's again, and the ceiling is what that leaf is *for*.
#
# The winding is the terrain's, mirrored for Godot and for the same reason: the scene
# winds a quad `a, c, b` / `b, c, d`, which is counter-clockwise seen from above -- what
# raylib calls a front face and Godot calls a back one. A surface wound the scene's way is
# culled, and water that is invisible while every number in it is right is exactly the bug
# `terrain_mesh.gd` records costing a screenshot to find.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterMesh
extends MeshInstance3D

## Vertices per side, and the shader the surface is drawn with.
const N := Water.N
const SHADER: Shader = preload("res://src/water.gdshader")
## How far past the ceiling a corner may sit and still keep its quad. The ceiling is the
## field's own *midline*, so about half the grid stands within the heightfield's 5e-11
## `sin` floor of it (`PORT.md` section 9) and a quad that straddles the boundary flips
## between the two engines -- `verify_water_mesh.gd` measures 65 of 2304 doing exactly
## that. The two directions are not equal: a quad drawn and dry is invisible, because
## nothing above the ceiling can be wet, while a quad *culled* and wet is a hole in a
## pool. So the port keeps the scene's set and any boundary case besides.
const CUT_EPS := 1e-6

var _material: ShaderMaterial
var _anchor := Vector2(INF, INF)
var _built := false
## How many of the grid's quads survived the cut, which is what a gate reads -- and what
## `sceneWater` reports as `quads`.
var quads := 0
## How many times the surface has been rebuilt, so a gate can tell one from a no-op.
var rebuilds := 0

func _ready() -> void:
	# Lazily, rather than in `_ready`: a `SceneTree` script that adds the node during
	# `_initialize` never sees `_ready`, and a build with no material is a surface that
	# draws with Godot's default instead of the scene's colours -- wrong for reasons no
	# data shows. `terrain_mesh.gd` builds the same way and for the same reason.
	pass

## The level the surface is lifted to, which `water.gd` owns and `main.gd` pushes each
## frame.
func set_level(level: float) -> void:
	if _material != null:
		_material.set_shader_parameter("water_level", level)

## The chop's two moving inputs -- the wave clock and the wind -- pushed each frame.
## `water_wave` itself is a constant and is set once with the material.
func set_chop(clock: float, wind: Vector3) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("water_time", clock)
	_material.set_shader_parameter("water_wind", wind)

## The wake's three rings, pushed each frame with the chop's own inputs: the shader sums
## them into the chop's gradient, so they ride the same amplitude and the same distance
## fade. Every slot is set, a spent ring as nothing, so a ring cannot linger in the shader
## after its strength reached zero.
func set_ripples(first: Vector4, second: Vector4, third: Vector4) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("water_ripple0", first)
	_material.set_shader_parameter("water_ripple1", second)
	_material.set_shader_parameter("water_ripple2", third)

## The reflection (M20e): the tier, and the march's own budget. Pushed where the tier settles
## rather than every frame -- a tier is a setting, and the shader's `water_reflect` is read
## once a fragment either way.
func set_reflection(tier: int, steps: int, reach: float) -> void:
	if _material == null:
		return
	_material.set_shader_parameter("water_reflect", tier)
	_material.set_shader_parameter("water_steps", steps)
	_material.set_shader_parameter("water_reach", reach)

## The camera's own projection, pushed once a frame: a `spatial` fragment shader cannot see
## `PROJECTION_MATRIX` and the reflection's march has to project a ray point from exactly there.
func set_projection(matrix: Projection) -> void:
	if _material != null:
		_material.set_shader_parameter("water_projection", matrix)

## Build the surface over the terrain grid's own heights, at the grid's anchor.
func build(heights: PackedFloat64Array, anchor: Vector2) -> void:
	_anchor = anchor
	var count: int = N * N
	if heights.size() != count:
		return
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	verts.resize(count)
	norms.resize(count)
	var x0: float = anchor.x - Water.HALF
	var z0: float = anchor.y - Water.HALF
	for j in N:
		var wz: float = z0 + j * Water.CELL
		var row: int = j * N
		for i in N:
			var k: int = row + i
			# The ground is the position, and the normal is flat: the scene writes `0, 1,
			# 0` at every vertex and lets the fragment stage's chop tilt it (M20c), so a
			# port without the chop has a sheet whose normal is the truth.
			verts[k] = Vector3(x0 + i * Water.CELL, float(heights[k]), wz)
			norms[k] = Vector3.UP

	var indices := PackedInt32Array()
	indices.resize(Terrain.QUADS * Terrain.QUADS * 6)
	var t: int = 0
	for j in Terrain.QUADS:
		for i in Terrain.QUADS:
			var a: int = j * N + i
			var b: int = a + 1
			var c: int = a + N
			var d: int = c + 1
			# `waterCut`'s own test, widened by `CUT_EPS` and for the reason it gives: out
			# when every corner is at or above the ceiling.
			if heights[a] >= Water.HIGH + CUT_EPS and heights[b] >= Water.HIGH + CUT_EPS \
					and heights[c] >= Water.HIGH + CUT_EPS \
					and heights[d] >= Water.HIGH + CUT_EPS:
				continue
			indices[t] = a
			indices[t + 1] = b
			indices[t + 2] = c
			indices[t + 3] = b
			indices[t + 4] = d
			indices[t + 5] = c
			t += 6
	indices.resize(t)
	quads = t / 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices

	var built := ArrayMesh.new()
	built.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = built
	if _material == null:
		_material = ShaderMaterial.new()
		_material.shader = SHADER
		# The chop's shape is a constant, so it goes with the material rather than with the
		# frame: `TUNING.water.wave`, as the shader's `waterWave`.
		_material.set_shader_parameter("water_wave",
			Vector3(Water.WAVE_HEIGHT, Water.WAVE_SCALE, Water.WAVE_SPEED))
		material_override = _material
	_built = true
	rebuilds += 1

## Whether a surface has been built at all, which is what a gate reads to tell a rebuild
## from the first build.
func is_built() -> bool:
	return _built

## The field's centre the current surface was built at.
func anchor() -> Vector2:
	return _anchor
