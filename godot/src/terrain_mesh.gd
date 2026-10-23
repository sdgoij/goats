# The ground, drawn: `world.js`'s heightfield as one mesh with five surfaces.
#
# The field itself is `terrain.gd` -- a pure function of where you are, which is
# what the herd stands on and what the scene's own heightfield is measured
# against. This file is the other half of that port: the 48x48 grid the client
# builds through `makeModel`, and the reason it is one mesh rather than a field of
# cubes (a cube per cell measured ~14 us and capped a frame at about a hundred of
# them, so the whole field would not fit in a frame at all).
#
# The second to fourth surfaces are the coarse rings (`world.js`
# `terrainMidBuild` / `terrainFarBuild`): the same field on 4 m and 8 m grids,
# each with a hole that exactly matches the surface inside it, out to 96 and 192
# units. That is what gives the mountains a smoother silhouette and the flying
# goat something to look at; they share the near grid's anchor and material, so
# they cost two more submissions and no new resource to keep in step.
#
# The last two surfaces are the seam strips (`world.js` `terrainSeamBuild`): the
# vertical lens between a fine edge and the coarse chord that meets it. The near
# grid's 2 m boundary and the mid ring's 4 m boundary share positions but not
# heights, so the two triangulations leave a lens you can see through at a
# grazing angle -- the holes that showed on mountain slopes. A strip from each
# fine vertex to the chord under it spans the lens exactly, with no constant
# depth to run out of and no second surface to depth-fight.
#
# Three things are transcriptions and not reinterpretations, because they decide
# what the ground looks like:
#
#   * the **normals come from central differences on the grid**, not from
#     `SurfaceTool.generate_normals()` -- so the shading is smooth across cells.
#     The **perimeter is the exception**: it measures the field over a fixed
#     2 m step (`EDGE_STEP`) so the finer and coarser sides of a seam agree at
#     the shared vertex instead of shading it differently and drawing a line;
#   * the **material is a per-vertex colour** from `Terrain.material`, so adjacent
#     cells blend and a material boundary reads as a gradient rather than a tile;
#   * the **UVs are world-space** (`wx * UV_SCALE`, 0.12), so the detail texture
#     tiles per world unit rather than per quad.
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
## (`TUNING.terrain.uv`). 256 px at 0.12 is four times the texel density of the
## 64 px texture before it -- the ground under a hoof was 13 cm a texel and read
## as pixelation, and it is now 3.3 cm.
const DETAIL_SIZE := 256
static var UV_SCALE: float = 0.12

## The two coarse rings (`world.js` `TERRAIN_MID_*` / `TERRAIN_FAR_*`). Both are a
## 48x48 grid whose square hole is half their own half-extent, so they share one
## index topology: the mid ring's 4 m cells carry 48..96 m and the far ring's 8 m
## cells 96..192 m.
const MID_CELL := 4.0
const MID_HALF := 96.0
const FAR_CELL := 8.0
const FAR_HALF := 192.0
const RING_QUADS := 48
const RING_N := RING_QUADS + 1
const RING_HOLE0 := 12
const RING_HOLE1 := 36
## The hole's perimeter: 25 vertices a side, so the 4 m mid ring and the 8 m far
## ring both present exactly half as many boundary vertices as the 2 m surface
## inside them. That ratio is what `_build_seam` interpolates over.
const HOLE_N := RING_HOLE1 - RING_HOLE0 + 1
const HOLE_PERIM := 4 * HOLE_N - 4
## The step a seam vertex's normal is measured over, in metres. Fixed rather than
## the grid's, so a 2 m boundary and the 4 m boundary meeting it measure the same
## hill the same way -- the alternative is a hard shading and material line exactly
## on every seam.
const EDGE_STEP := 2.0

## The ground as the mirror draws it (M20e): the same mesh and the same look, seen from under
## the terrain. See `mirror_material`.
const MIRROR_SHADER := preload("res://src/terrain_mirror.gdshader")

var _heights := PackedFloat64Array()
var _mid_heights := PackedFloat64Array()
var _far_heights := PackedFloat64Array()
var _ring_indices := PackedInt32Array()
var _seam_indices := PackedInt32Array()
var _mesh: ArrayMesh
var _material: StandardMaterial3D
## Whether the ground is drawn through the lit material or the unshaded one (`L` and the settings
## screen, M25). It is a field rather than a read of `_material` because the material is built
## lazily -- a mode set before the first build has to survive into it.
var _lit := true
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
## the port rebuilds the whole field on an anchor move already (every 32 units of
## travel, so every six seconds at a run), so a bang costs what a walk past a
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
			# inventing a neighbour. The perimeter does not use that handling: it
			# samples the field over `EDGE_STEP`, so it agrees with the coarser
			# surface on the other side of the seam.
			var dx: float = 0.0
			var dz: float = 0.0
			if i == 0 or i == N - 1 or j == 0 or j == N - 1:
				var edge := _edge_slope(wx, wz)
				dx = edge.x
				dz = edge.y
			else:
				var fwd_i: int = 1 if i < N - 1 else 0
				var back_i: int = 1 if i > 0 else 0
				var fwd_j: int = N if j < N - 1 else 0
				var back_j: int = N if j > 0 else 0
				dx = (_heights[k + fwd_i] - _heights[k - back_i]) / (2.0 * Terrain.CELL)
				dz = (_heights[k + fwd_j] - _heights[k - back_j]) / (2.0 * Terrain.CELL)
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

	# The mid and far rings are further surfaces of the same mesh: the same
	# material, the same detail texture and the same draw. Each one's hole matches
	# the surface inside it, so the three tile; the seam strips close the lens a
	# coarser grid leaves at the shared edge.
	#
	# Far is built before mid because the mid seam reads the far ring's hole
	# heights, and the surfaces are *added* in near/mid/far order so the surface
	# indices stay what the gates and the mirror expect.
	var far_arrays := _build_ring(anchor_x, anchor_z, FAR_CELL, FAR_HALF, _far_heights)
	var mid_arrays := _build_ring(anchor_x, anchor_z, MID_CELL, MID_HALF, _mid_heights)

	if _mesh == null:
		_mesh = ArrayMesh.new()
		mesh = _mesh
	else:
		_mesh.clear_surfaces()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh.surface_set_material(0, _material)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mid_arrays)
	_mesh.surface_set_material(1, _material)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, far_arrays)
	_mesh.surface_set_material(2, _material)

	var near_seam := _build_seam(verts, norms, cols, uvs, _mid_heights)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, near_seam)
	_mesh.surface_set_material(3, _material)
	var mid_verts: PackedVector3Array = mid_arrays[Mesh.ARRAY_VERTEX]
	var mid_norms: PackedVector3Array = mid_arrays[Mesh.ARRAY_NORMAL]
	var mid_cols: PackedColorArray = mid_arrays[Mesh.ARRAY_COLOR]
	var mid_uvs: PackedVector2Array = mid_arrays[Mesh.ARRAY_TEX_UV]
	var mid_seam := _build_seam(mid_verts, mid_norms, mid_cols, mid_uvs, _far_heights)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mid_seam)
	_mesh.surface_set_material(4, _material)

## One ring (`world.js` `terrainRingBuild`): a `RING_N` square at `cell` metres,
## with the quads over its hole left out. The heights are filled across the hole as
## well -- a vertex on its edge reads its inside neighbour for the normal -- but
## those inner vertices are never indexed. The index topology is the same for the
## mid and far rings, so it is built once.
func _build_ring(anchor_x: float, anchor_z: float, cell: float, half: float,
		grid_heights: PackedFloat64Array) -> Array:
	var count: int = RING_N * RING_N
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var cols := PackedColorArray()
	var uvs := PackedVector2Array()
	verts.resize(count)
	norms.resize(count)
	cols.resize(count)
	uvs.resize(count)
	grid_heights.resize(count)

	var x0: float = anchor_x - half
	var z0: float = anchor_z - half

	for j in RING_N:
		var wz: float = z0 + j * cell
		var row: int = j * RING_N
		for i in RING_N:
			grid_heights[row + i] = Terrain.base_height(x0 + i * cell, wz)

	for j in RING_N:
		var wz: float = z0 + j * cell
		var row: int = j * RING_N
		# The hole's interior is unreferenced; its boundary rows and columns are not.
		var inner: bool = j > RING_HOLE0 and j < RING_HOLE1
		for i in RING_N:
			if inner and i > RING_HOLE0 and i < RING_HOLE1:
				continue
			var k: int = row + i
			var wx: float = x0 + i * cell
			var y: float = float(grid_heights[k])
			verts[k] = Vector3(wx, y, wz)

			var fwd_i: int = 1 if i < RING_N - 1 else 0
			var back_i: int = 1 if i > 0 else 0
			var fwd_j: int = RING_N if j < RING_N - 1 else 0
			var back_j: int = RING_N if j > 0 else 0
			var dx: float = 0.0
			var dz: float = 0.0
			if _ring_edge(i, j):
				var edge := _edge_slope(wx, wz)
				dx = edge.x
				dz = edge.y
			else:
				dx = (grid_heights[k + fwd_i] - grid_heights[k - back_i]) / (2.0 * cell)
				dz = (grid_heights[k + fwd_j] - grid_heights[k - back_j]) / (2.0 * cell)
			var inv: float = 1.0 / sqrt(dx * dx + dz * dz + 1.0)
			norms[k] = Vector3(-dx * inv, inv, -dz * inv)

			var slope: float = minf(1.0, sqrt(dx * dx + dz * dz))
			var patch: float = Terrain.vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7)
			cols[k] = Terrain.material(y, slope, patch)
			uvs[k] = Vector2(wx * UV_SCALE, wz * UV_SCALE)

	if _ring_indices.is_empty():
		_ring_indices.resize((RING_QUADS * RING_QUADS \
			- (RING_HOLE1 - RING_HOLE0) * (RING_HOLE1 - RING_HOLE0)) * 6)
		var t: int = 0
		for j in RING_QUADS:
			for i in RING_QUADS:
				if i >= RING_HOLE0 and i < RING_HOLE1 and j >= RING_HOLE0 and j < RING_HOLE1:
					continue
				var a: int = j * RING_N + i
				var b: int = a + 1
				var c: int = a + RING_N
				var d: int = c + 1
				_ring_indices[t] = a
				_ring_indices[t + 1] = b
				_ring_indices[t + 2] = c
				_ring_indices[t + 3] = b
				_ring_indices[t + 4] = d
				_ring_indices[t + 5] = c
				t += 6

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_COLOR] = cols
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = _ring_indices
	return arrays

## The slope at a world point over the fixed `EDGE_STEP`, so a surface's
## perimeter shades the way the field does rather than the way its own cell size
## happens to sample it. `world.js` `terrainEdgeSlope`.
func _edge_slope(x: float, z: float) -> Vector2:
	var d: float = EDGE_STEP
	var dx: float = (Terrain.base_height(x + d, z) - Terrain.base_height(x - d, z)) / (2.0 * d)
	var dz: float = (Terrain.base_height(x, z + d) - Terrain.base_height(x, z - d)) / (2.0 * d)
	return Vector2(dx, dz)

## Whether a ring vertex sits on an edge that meets another surface: the outer
## square, or one of the hole's rims. A vertex in the hole's column but outside
## its rows is ordinary ground and keeps the grid's own difference.
func _ring_edge(i: int, j: int) -> bool:
	if i == 0 or i == RING_N - 1 or j == 0 or j == RING_N - 1:
		return true
	var in_hole_i: bool = i >= RING_HOLE0 and i <= RING_HOLE1
	var in_hole_j: bool = j >= RING_HOLE0 and j <= RING_HOLE1
	return ((i == RING_HOLE0 or i == RING_HOLE1) and in_hole_j) \
		or ((j == RING_HOLE0 or j == RING_HOLE1) and in_hole_i)

## The hole's perimeter in the same order as a surface's own perimeter, but
## `HOLE_N` square. Built on the first seam and kept: it is a property of the
## topology, not of the anchor.
static var _hole_i := PackedInt32Array()
static var _hole_j := PackedInt32Array()

func _hole_perimeter() -> void:
	if not _hole_i.is_empty():
		return
	_hole_i.resize(HOLE_PERIM)
	_hole_j.resize(HOLE_PERIM)
	var p: int = 0
	for i in range(RING_HOLE0, RING_HOLE1 + 1):
		_hole_i[p] = i
		_hole_j[p] = RING_HOLE0
		p += 1
	for j in range(RING_HOLE0 + 1, RING_HOLE1 + 1):
		_hole_i[p] = RING_HOLE1
		_hole_j[p] = j
		p += 1
	for i in range(RING_HOLE1 - 1, RING_HOLE0 - 1, -1):
		_hole_i[p] = i
		_hole_j[p] = RING_HOLE1
		p += 1
	for j in range(RING_HOLE1 - 1, RING_HOLE0, -1):
		_hole_i[p] = RING_HOLE0
		_hole_j[p] = j
		p += 1

## A seam strip (`world.js` `terrainSeamBuild`): the fine surface's own boundary
## above, and the height of the *coarse* chord crossing it below. The two grids
## share positions but not heights -- a 4 m or 8 m edge is a straight line between
## every other fine vertex -- so the surfaces leave a vertical lens you can see
## through at a grazing angle. This spans it exactly: at an even fine index the
## two edges coincide (a degenerate quad) and between them the strip is the lens.
## Each quad is emitted with both windings, because the lens is looked at from the
## inner side and the outer one.
func _build_seam(verts: PackedVector3Array, norms: PackedVector3Array,
		cols: PackedColorArray, uvs: PackedVector2Array,
		coarse_heights: PackedFloat64Array) -> Array:
	_hole_perimeter()
	var count: int = 4 * RING_N - 4
	var seam_verts := PackedVector3Array()
	var seam_norms := PackedVector3Array()
	var seam_cols := PackedColorArray()
	var seam_uvs := PackedVector2Array()
	seam_verts.resize(count * 2)
	seam_norms.resize(count * 2)
	seam_cols.resize(count * 2)
	seam_uvs.resize(count * 2)

	if _seam_indices.is_empty():
		_seam_indices.resize(count * 12)
		var t: int = 0
		for k in count:
			var next: int = (k + 1) % count
			var a: int = k * 2
			var b: int = next * 2
			var c: int = next * 2 + 1
			var d: int = k * 2 + 1
			_seam_indices[t] = a
			_seam_indices[t + 1] = b
			_seam_indices[t + 2] = c
			_seam_indices[t + 3] = a
			_seam_indices[t + 4] = c
			_seam_indices[t + 5] = d
			_seam_indices[t + 6] = a
			_seam_indices[t + 7] = c
			_seam_indices[t + 8] = b
			_seam_indices[t + 9] = a
			_seam_indices[t + 10] = d
			_seam_indices[t + 11] = c
			t += 12

	# The perimeter in order: top row, right column, bottom row back, left column up.
	var per_i := PackedInt32Array()
	var per_j := PackedInt32Array()
	per_i.resize(count)
	per_j.resize(count)
	var p: int = 0
	for i in RING_N:
		per_i[p] = i
		per_j[p] = 0
		p += 1
	for j in range(1, RING_N):
		per_i[p] = RING_N - 1
		per_j[p] = j
		p += 1
	for i in range(RING_N - 2, -1, -1):
		per_i[p] = i
		per_j[p] = RING_N - 1
		p += 1
	for j in range(RING_N - 2, 0, -1):
		per_i[p] = 0
		per_j[p] = j
		p += 1

	# Both perimeters start at the same corner and run the same way, so a fine
	# vertex lies `k / ratio` coarse steps along the hole's edge.
	var ratio: float = float(count) / float(HOLE_PERIM)
	for k in count:
		var src: int = per_j[k] * RING_N + per_i[k]
		var top: int = k * 2
		var bot: int = top + 1
		var pos: Vector3 = verts[src]
		var at: float = float(k) / ratio
		var whole: int = int(floor(at))
		var f: float = at - float(whole)
		var c0: int = whole % HOLE_PERIM
		var c1: int = (c0 + 1) % HOLE_PERIM
		var y0: float = coarse_heights[_hole_j[c0] * RING_N + _hole_i[c0]]
		var y1: float = coarse_heights[_hole_j[c1] * RING_N + _hole_i[c1]]
		var y_chord: float = y0 + (y1 - y0) * f
		seam_verts[top] = pos
		seam_verts[bot] = Vector3(pos.x, y_chord, pos.z)
		seam_norms[top] = norms[src]
		seam_norms[bot] = norms[src]
		seam_cols[top] = cols[src]
		seam_cols[bot] = cols[src]
		seam_uvs[top] = uvs[src]
		seam_uvs[bot] = uvs[src]

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = seam_verts
	arrays[Mesh.ARRAY_NORMAL] = seam_norms
	arrays[Mesh.ARRAY_COLOR] = seam_cols
	arrays[Mesh.ARRAY_TEX_UV] = seam_uvs
	arrays[Mesh.ARRAY_INDEX] = _seam_indices
	return arrays

## The detail texture, made on first use.
func _detail_texture() -> ImageTexture:
	if _detail == null:
		_detail = _make_detail_texture()
	return _detail

## The scene's detail texture: neutral grain around 0.88, so the per-vertex
## material colours keep a texture up close without an atlas. `world.js`
## `makeTerrainTexture`, transcribed. The grain is authored in display space and
## stored linear, like the vertex colours (`PORT.md` section 9).
##
## The noise is **periodic** -- each octave is a whole number of lattice cells
## across the tile -- so the texture has no seam at its wrap. A non-periodic noise
## tiles as a chessboard: every repeat starts at a different value, and once the
## ground is far enough away for a repeat to be one flat colour that is exactly
## what the landscape looks like.
func _make_detail_texture() -> ImageTexture:
	var image := Image.create_empty(DETAIL_SIZE, DETAIL_SIZE, false, Image.FORMAT_RGB8)
	var cells: Array[int] = [8, 24, 64, 160]
	var amps: Array[float] = [0.50, 0.27, 0.15, 0.08]
	var tables: Array = []
	for period in cells:
		tables.append(_noise_table(period))
	for y in DETAIL_SIZE:
		for x in DETAIL_SIZE:
			var v: float = 0.0
			for o in cells.size():
				var period: int = cells[o]
				v += amps[o] * _noise_sample(tables[o], period,
					float(x * period) / float(DETAIL_SIZE),
					float(y * period) / float(DETAIL_SIZE))
			var c: int = int(round(198.0 + 57.0 * clampf(v, 0.0, 1.0)))
			image.set_pixel(x, y, Color8(
				c, int(round(c * 0.97)), int(round(c * 0.88))).srgb_to_linear())
	# This host has no `GenTextureMipmaps` for a runtime texture, but an `Image`
	# can build its own chain, and the sample at distance is what stops the grain
	# from aliasing into a grid.
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

## One octave's lattice, wrapped: the `hash` values of the `period` x `period`
## cells the tile spans. Baking it keeps the per-pixel path off `sin`.
func _noise_table(period: int) -> PackedFloat32Array:
	var table := PackedFloat32Array()
	table.resize(period * period)
	for y in period:
		for x in period:
			table[y * period + x] = Terrain.value_hash(float(x) * 57.0 + float(y) * 131.0)
	return table

## Bilinear sample of a wrapped lattice. `world.js` `terrainNoiseSample`.
func _noise_sample(table: PackedFloat32Array, period: int, x: float, y: float) -> float:
	var xi: float = floor(x)
	var yi: float = floor(y)
	var xf: float = x - xi
	var yf: float = y - yi
	var u: float = xf * xf * (3.0 - 2.0 * xf)
	var v: float = yf * yf * (3.0 - 2.0 * yf)
	var x0: int = int(xi) % period
	var y0: int = int(yi) % period
	if x0 < 0:
		x0 += period
	if y0 < 0:
		y0 += period
	var x1: int = 0 if x0 + 1 == period else x0 + 1
	var y1: int = 0 if y0 + 1 == period else y0 + 1
	var a: float = table[y0 * period + x0]
	var b: float = table[y0 * period + x1]
	var c: float = table[y1 * period + x0]
	var d: float = table[y1 * period + x1]
	return (a * (1.0 - u) + b * u) * (1.0 - v) + (c * (1.0 - u) + d * u) * v

## A plain Godot material, which is the decision from `PORT.md` section 5: the
## per-vertex colour is the albedo (so the detail texture and the material colour
## multiply, as the scene's shader does), and Godot's light and shadows do the
## rest of what the scene's own lit program and shadow map were doing.
func _make_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.albedo_texture = _detail_texture()
	# The detail texture is a grain the ground magnifies across a metre; linear
	# sampling with the mip chain is what keeps it from reading as pixels up close
	# and as a moire grid at altitude.
	material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	# Ground is not shiny, and a specular highlight on a hillside reads as water.
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.shading_mode = shading(_lit)
	return material

## The one line the scene's `setTerrainShader` amounts to here: the lit program or the plain one,
## which in Godot is a material's shading mode. `L` and the settings screen both call this.
func set_lit(on: bool) -> void:
	_lit = on
	if _material != null:
		_material.shading_mode = shading(on)

## A boolean as `BaseMaterial3D.ShadingMode`, so the three modules that flip a material and the
## one that builds one agree on which side is which.
static func shading(on: bool) -> BaseMaterial3D.ShadingMode:
	return BaseMaterial3D.SHADING_MODE_PER_PIXEL if on else BaseMaterial3D.SHADING_MODE_UNSHADED

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
