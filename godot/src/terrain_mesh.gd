# The ground, drawn: `world.js`'s heightfield as one mesh.
#
# The field itself is `terrain.gd` -- a pure function of where you are, which is
# what the herd stands on and what the scene's own heightfield is measured
# against. This file is the other half of that port: the 48x48 grid the client
# builds through `makeModel`, and the reason it is one mesh rather than a field of
# cubes (a cube per cell measured ~14 us and capped a frame at about a hundred of
# them, so the whole field would not fit in a frame at all).
#
# Three things are transcriptions and not reinterpretations, because they decide
# what the ground looks like:
#
#   * the **normals come from central differences on the grid**, not from
#     `SurfaceTool.generate_normals()` -- so the shading is smooth across cells and
#     a border vertex takes the scene's own one-sided difference rather than a
#     reflected one;
#   * the **material is a per-vertex colour** from `Terrain.material`, so adjacent
#     cells blend and a material boundary reads as a gradient rather than a tile;
#   * the **UVs are world-space** (`wx * 0.06`), so the detail texture tiles per
#     world unit rather than per quad.
#
# What is *not* transcribed: the scene routes the terrain through its own lit
# program and its hand-rolled shadow map, and this uses Godot's material,
# lighting and shadows (`PORT.md` section 5, decided). The look is a Godot look;
# the ground is the scene's ground.
#
# Like every file here, it annotates its locals rather than inferring them: see
# the `:=` note in `terrain.gd` for why a same-class static call under `:=` is
# not survivable.
class_name TerrainMesh
extends MeshInstance3D

## Vertices per side -- `TERRAIN_QUADS + 1`.
const N := 49
## Half the field's width, in world units (`48 quads * 2 units / 2`).
const HALF := 48.0
## The detail texture's size in pixels, and its tiling rate per world unit
## (`TUNING.terrain.uv`).
const DETAIL_SIZE := 64
const UV_SCALE := 0.06

## The ground as the mirror draws it (M20e): the same mesh and the same look, seen from under
## the terrain. See `mirror_material`.
const MIRROR_SHADER := preload("res://src/terrain_mirror.gdshader")

var _heights := PackedFloat64Array()
var _mesh: ArrayMesh
var _material: StandardMaterial3D
## The detail texture, made once and shared: `_material` and `mirror_material` both read it, so
## the ground and its reflection cannot drift apart.
var _detail: ImageTexture
var _anchor := Vector2(INF, INF)
var _built := false
## How many times the grid has been rebuilt, which is what a gate reads to tell a
## rebuild from a no-op.
var rebuilds := 0

func _ready() -> void:
	build(0.0, 0.0)

## Snap to the grid the scene snaps to, and rebuild only if the snapped anchor
## moved -- so a step rebuild lands every `SNAP` units of travel rather than every
## frame (`world.js` `terrainEnsure`). Returns whether it rebuilt.
func follow(x: float, z: float) -> bool:
	var ax: float = round(x / Terrain.SNAP) * Terrain.SNAP
	var az: float = round(z / Terrain.SNAP) * Terrain.SNAP
	if _built and ax == _anchor.x and az == _anchor.y:
		return false
	build(ax, az)
	return true

## Rebuild the grid where it already is, because the *ground* changed under it rather
## than the goat moving: a bang dishes it and a crater heals. `Craters.dirty` is what
## says so, and `main.gd` is what calls this.
##
## The whole grid, not the cells the crater reaches. The scene patches the affected
## rectangle (`terrainStampCraters`) because it measured a full rebuild as too much;
## the port rebuilds the whole field on an anchor move already (every 24 units of
## travel, so every eight seconds at a run), so a bang costs what a walk past a
## boundary costs and nothing more.
func refresh() -> void:
	if _built:
		build(_anchor.x, _anchor.y)

## The field's centre: the grid spans `anchor +/- HALF`.
func anchor() -> Vector2:
	return _anchor

## The grid's own heights, by row then column (`k = j * N + i`), which is `world.js`'s
## `T_H` -- the water reads them because the drawn surface *is* this grid, so the depth
## a goat wades in has to be the depth of the thing it is standing in.
##
## They are kept in double precision (the mesh narrows its own copy to float32 for
## Godot) and handed over as the array itself, so a caller must not write it -- and
## must re-read it after a rebuild, which is when it is refilled.
func heights() -> PackedFloat64Array:
	return _heights

## Build the whole grid at an anchor. The scene patches rectangles for a crater or
## a collapse; nothing changes the ground here yet, so every rebuild is the whole
## field.
func build(anchor_x: float, anchor_z: float) -> void:
	# Lazily, rather than in `_ready`: `_ready` is not guaranteed to have run before
	# the first `follow` in every host (a `SceneTree` script that adds the node
	# during `_initialize` never sees it), and a build with no material is a mesh
	# that is invisible for reasons no data shows.
	if _material == null:
		_material = _make_material()
	_anchor = Vector2(anchor_x, anchor_z)
	_built = true
	rebuilds += 1

	var count: int = N * N
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(count)
	norms.resize(count)
	cols.resize(count)
	uvs.resize(count)
	_heights.resize(count)

	var x0: float = anchor_x - HALF
	var z0: float = anchor_z - HALF

	# Heights first, for the whole grid: a vertex's normal reads its neighbours, so
	# no vertex may be derived before every height it can see is written.
	for j in N:
		var wz: float = z0 + j * Terrain.CELL
		var row: int = j * N
		for i in N:
			var wx: float = x0 + i * Terrain.CELL
			_heights[row + i] = Terrain.base_height(wx, wz)

	for j in N:
		var wz: float = z0 + j * Terrain.CELL
		var row: int = j * N
		for i in N:
			var k: int = row + i
			var wx: float = x0 + i * Terrain.CELL
			var y: float = float(_heights[k])
			verts[k] = Vector3(wx, y, wz)

			# Central differences on the grid, the scene's own edge handling
			# included: at the last column the forward sample is the cell itself
			# rather than a reflected one, which halves the slope there instead of
			# inventing a neighbour.
			var fwd_i: int = 1 if i < N - 1 else 0
			var back_i: int = 1 if i > 0 else 0
			var fwd_j: int = N if j < N - 1 else 0
			var back_j: int = N if j > 0 else 0
			var dx: float = (_heights[k + fwd_i] - _heights[k - back_i]) / (2.0 * Terrain.CELL)
			var dz: float = (_heights[k + fwd_j] - _heights[k - back_j]) / (2.0 * Terrain.CELL)
			var inv: float = 1.0 / sqrt(dx * dx + dz * dz + 1.0)
			norms[k] = Vector3(-dx * inv, inv, -dz * inv)

			var slope: float = minf(1.0, sqrt(dx * dx + dz * dz))
			var patch: float = Terrain.vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7)
			cols[k] = Terrain.material(y, slope, patch)
			uvs[k] = Vector2(wx * UV_SCALE, wz * UV_SCALE)

	# The topology is the same grid at every anchor, so it is built once.
	#
	# **This is the mirror of the scene's winding, on purpose.** `world.js` winds
	# `a, c, b` / `b, c, d`, which is counter-clockwise seen from above -- what
	# raylib calls a front face. Godot's front face is the other way round (its
	# `Plane(p0, p1, p2)` normal is `-((p1-p0) x (p2-p0))`), so the scene's winding
	# here would be *back*-facing: culled, and the ground invisible with every
	# number in it correct. It cost a screenshot to see, which is the argument for
	# taking one.
	var indices := PackedInt32Array()
	indices.resize(Terrain.QUADS * Terrain.QUADS * 6)
	var t: int = 0
	for j in Terrain.QUADS:
		for i in Terrain.QUADS:
			var a: int = j * N + i
			var b: int = a + 1
			var c: int = a + N
			var d: int = c + 1
			indices[t] = a
			indices[t + 1] = b
			indices[t + 2] = c
			indices[t + 3] = b
			indices[t + 4] = d
			indices[t + 5] = c
			t += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	if _mesh == null:
		_mesh = ArrayMesh.new()
		mesh = _mesh
	else:
		_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh.surface_set_material(0, _material)

## The detail texture, made on first use.
func _detail_texture() -> ImageTexture:
	if _detail == null:
		_detail = _make_detail_texture()
	return _detail

## The scene's detail texture: neutral grain around 0.85, so the per-vertex
## material colours keep a texture up close without an atlas. `world.js`
## `makeTerrainTexture`, transcribed.
func _make_detail_texture() -> ImageTexture:
	var image := Image.create_empty(DETAIL_SIZE, DETAIL_SIZE, false, Image.FORMAT_RGB8)
	for y in DETAIL_SIZE:
		for x in DETAIL_SIZE:
			var broad: float = 0.60 * Terrain.vnoise2(x * 0.13 + 2.3, y * 0.13 + 7.7)
			var middle: float = 0.27 * Terrain.vnoise2(x * 0.31 + 19.1, y * 0.31 + 4.3)
			var grain: float = 0.13 * Terrain.value_hash(x * 5.7 + y * 17.3)
			var v: float = clampf(broad + middle + grain, 0.0, 1.0)
			var c: int = int(round(196.0 + 59.0 * v))
			image.set_pixel(x, y, Color8(c, int(round(c * 0.97)), int(round(c * 0.88))))
	return ImageTexture.create_from_image(image)

## A plain Godot material, which is the decision from `PORT.md` section 5: the
## per-vertex colour is the albedo (so the detail texture and the material colour
## multiply, as the scene's shader does), and Godot's light and shadows do the
## rest of what the scene's own lit program and shadow map were doing.
func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _detail_texture()
	# Ground is not shiny, and a specular highlight on a hillside reads as water.
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material

## The ground's material as the **mirror** draws it (M20e): the same mesh, the same detail
## texture and the same look, with the two differences a camera under the terrain needs --
## `cull_front`, so the quads that camera faces are the drawn ones, and a cut at the waterline.
## `terrain_mirror.gdshader` carries the why; `water_mirror.gd` owns the instance that wears
## this and pushes the level into it every frame.
func mirror_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = MIRROR_SHADER
	material.set_shader_parameter("detail_texture", _detail_texture())
	return material
