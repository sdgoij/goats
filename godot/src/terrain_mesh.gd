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
## The three grids' drawn attributes, kept between builds so an anchor step can
## *shift* the part of the field that did not move instead of resampling it. A 32
## unit step exposes one strip of new ground per grid, so this is what turns a
## 90 ms rebuild into one that samples a quarter of the vertices.
var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _uvs := PackedVector2Array()
var _mid_verts := PackedVector3Array()
var _mid_norms := PackedVector3Array()
var _mid_cols := PackedColorArray()
var _mid_uvs := PackedVector2Array()
var _far_verts := PackedVector3Array()
var _far_norms := PackedVector3Array()
var _far_cols := PackedColorArray()
var _far_uvs := PackedVector2Array()
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
## Set by `refresh`: the ground changed under the mesh, so the shifted arrays are
## stale and the next build has to resample the field.
var _force_full := false
## How many times the grid has been rebuilt, which is what a gate reads to tell a
## rebuild from a no-op.
var rebuilds := 0

## The Rust field sampler (`crates/godot/src/terrain.rs`), made once when the
## extension is loaded. It is `null` on a host without the library, where the
## GDScript transcription below is the ground instead; the two are checked against
## each other by `tools/verify_terrain_mesh.gd`.
static var _rust_field: Object = null
static var _rust_checked := false

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
		_force_full = true
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

## Build the grid at an anchor. A move is **incremental**: the anchor snaps to
## `Terrain.SNAP` and every grid's cell divides it, so the new grid is the old one
## shifted by a whole number of cells. The overlapping vertices describe the same
## world points, so their heights and attributes are copied, and only the strip the
## shift uncovered is sampled. That is the difference between ~7200 field samples
## every 32 units and ~1900.
func build(anchor_x: float, anchor_z: float) -> void:
	# Lazily, rather than in `_ready`: `_ready` is not guaranteed to have run before
	# the first `follow` in every host (a `SceneTree` script that adds the node
	# during `_initialize` never sees it), and a build with no material is a mesh
	# that is invisible for reasons no data shows.
	if _material == null:
		_material = _make_material()
	var prev_x: float = _anchor.x
	var prev_z: float = _anchor.y
	var had: bool = _built
	_anchor = Vector2(anchor_x, anchor_z)
	_built = true
	rebuilds += 1

	# A step's shifts, in each grid's own cells. `_shift_steps` returns the grid
	# size when the move is not a whole number of cells or is larger than the grid
	# (a teleport), which makes the build a full resample instead.
	var full: bool = not had or _force_full
	_force_full = false
	var di := 0
	var dj := 0
	var mdi := 0
	var mdj := 0
	var fdi := 0
	var fdj := 0
	if not full:
		di = _shift_steps(anchor_x - prev_x, Terrain.CELL, N)
		dj = _shift_steps(anchor_z - prev_z, Terrain.CELL, N)
		mdi = _shift_steps(anchor_x - prev_x, MID_CELL, RING_N)
		mdj = _shift_steps(anchor_z - prev_z, MID_CELL, RING_N)
		fdi = _shift_steps(anchor_x - prev_x, FAR_CELL, RING_N)
		fdj = _shift_steps(anchor_z - prev_z, FAR_CELL, RING_N)
		if di >= N or dj >= N or mdi >= RING_N or mdj >= RING_N \
				or fdi >= RING_N or fdj >= RING_N:
			full = true
	if full:
		di = 0
		dj = 0
		mdi = 0
		mdj = 0
		fdi = 0
		fdj = 0

	var x0: float = anchor_x - HALF
	var z0: float = anchor_z - HALF
	_heights = _shift_heights(_heights, x0, z0, Terrain.CELL, N, di, dj, full)
	var near_rects: Array = _dirty_rects(N, di, dj, full)
	var near := _write_grid(x0, z0, Terrain.CELL, N, _heights, di, dj,
		_verts, _norms, _cols, _uvs, near_rects, false)
	_verts = near[0]
	_norms = near[1]
	_cols = near[2]
	_uvs = near[3]

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
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_TEX_UV] = _uvs
	arrays[Mesh.ARRAY_INDEX] = indices

	# The mid and far rings are further surfaces of the same mesh: the same
	# material, the same detail texture and the same draw. Each one's hole matches
	# the surface inside it, so the three tile; the seam strips close the lens a
	# coarser grid leaves at the shared edge.
	#
	# Far is built before mid because the mid seam reads the far ring's hole
	# heights, and the surfaces are *added* in near/mid/far order so the surface
	# indices stay what the gates and the mirror expect.
	_far_heights = _shift_heights(_far_heights, anchor_x - FAR_HALF, anchor_z - FAR_HALF,
		FAR_CELL, RING_N, fdi, fdj, full)
	var far_rects: Array = _dirty_rects(RING_N, fdi, fdj, full)
	var far := _write_grid(anchor_x - FAR_HALF, anchor_z - FAR_HALF, FAR_CELL, RING_N,
		_far_heights, fdi, fdj, _far_verts, _far_norms, _far_cols, _far_uvs, far_rects, true)
	_far_verts = far[0]
	_far_norms = far[1]
	_far_cols = far[2]
	_far_uvs = far[3]

	_mid_heights = _shift_heights(_mid_heights, anchor_x - MID_HALF, anchor_z - MID_HALF,
		MID_CELL, RING_N, mdi, mdj, full)
	var mid_rects: Array = _dirty_rects(RING_N, mdi, mdj, full)
	var mid := _write_grid(anchor_x - MID_HALF, anchor_z - MID_HALF, MID_CELL, RING_N,
		_mid_heights, mdi, mdj, _mid_verts, _mid_norms, _mid_cols, _mid_uvs, mid_rects, true)
	_mid_verts = mid[0]
	_mid_norms = mid[1]
	_mid_cols = mid[2]
	_mid_uvs = mid[3]

	if _ring_indices.is_empty():
		_ring_indices.resize((RING_QUADS * RING_QUADS \
			- (RING_HOLE1 - RING_HOLE0) * (RING_HOLE1 - RING_HOLE0)) * 6)
		var r: int = 0
		for j in RING_QUADS:
			for i in RING_QUADS:
				if i >= RING_HOLE0 and i < RING_HOLE1 and j >= RING_HOLE0 and j < RING_HOLE1:
					continue
				var a: int = j * RING_N + i
				var b: int = a + 1
				var c: int = a + RING_N
				var d: int = c + 1
				_ring_indices[r] = a
				_ring_indices[r + 1] = b
				_ring_indices[r + 2] = c
				_ring_indices[r + 3] = b
				_ring_indices[r + 4] = d
				_ring_indices[r + 5] = c
				r += 6

	var mid_arrays := []
	mid_arrays.resize(Mesh.ARRAY_MAX)
	mid_arrays[Mesh.ARRAY_VERTEX] = _mid_verts
	mid_arrays[Mesh.ARRAY_NORMAL] = _mid_norms
	mid_arrays[Mesh.ARRAY_COLOR] = _mid_cols
	mid_arrays[Mesh.ARRAY_TEX_UV] = _mid_uvs
	mid_arrays[Mesh.ARRAY_INDEX] = _ring_indices
	var far_arrays := []
	far_arrays.resize(Mesh.ARRAY_MAX)
	far_arrays[Mesh.ARRAY_VERTEX] = _far_verts
	far_arrays[Mesh.ARRAY_NORMAL] = _far_norms
	far_arrays[Mesh.ARRAY_COLOR] = _far_cols
	far_arrays[Mesh.ARRAY_TEX_UV] = _far_uvs
	far_arrays[Mesh.ARRAY_INDEX] = _ring_indices

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

	var near_seam := _build_seam(_verts, _norms, _cols, _uvs, _mid_heights)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, near_seam)
	_mesh.surface_set_material(3, _material)
	var mid_seam := _build_seam(_mid_verts, _mid_norms, _mid_cols, _mid_uvs, _far_heights)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mid_seam)
	_mesh.surface_set_material(4, _material)

## How many cells a snapped step is, in this grid's units; `n` when the move is
## not a whole number of cells or is at least the whole grid (a teleport).
func _shift_steps(delta: float, cell: float, n: int) -> int:
	var steps: float = delta / cell
	var rounded: float = round(steps)
	if absf(steps - rounded) > 0.0001 or absf(rounded) >= float(n):
		return n
	return int(rounded)

## The blocks of a grid that a shift made new, each widened by one vertex so the
## normals on its inner edge are rebuilt too (they read the new neighbour). A move
## on both axes exposes two strips, whose union is an L -- *not* the corner their
## bounding box would be. Each entry is `[i0, i1, j0, j1]`.
func _dirty_rects(n: int, di: int, dj: int, full: bool) -> Array:
	if full or (di == 0 and dj == 0):
		return [[0, n - 1, 0, n - 1]]
	var rects: Array = []
	if di != 0:
		var i0: int = n - di if di > 0 else 0
		var i1: int = n - 1 if di > 0 else -di - 1
		rects.append([maxi(0, i0 - 1), mini(n - 1, i1 + 1), 0, n - 1])
	if dj != 0:
		var j0: int = n - dj if dj > 0 else 0
		var j1: int = n - 1 if dj > 0 else -dj - 1
		rects.append([0, n - 1, maxi(0, j0 - 1), mini(n - 1, j1 + 1)])
	return rects

## A grid's heights after the anchor moved by (`di`, `dj`) cells: the overlapping
## entries are the same world points and are copied, the exposed strip is sampled.
##
## The sampling is ~7 us a point in GDScript, which is the whole reason a rebuild
## had to stop resampling three grids; when the Rust extension is present the loop
## runs there instead (`crates/godot/src/terrain.rs`, the same maths and the same
## `is-this-a-whole-cell` copy rule).
func _shift_heights(src: PackedFloat64Array, x0: float, z0: float, cell: float,
		n: int, di: int, dj: int, full: bool) -> PackedFloat64Array:
	var field: Object = _rust_fill()
	if field != null:
		return field.call("fill_heights", src, x0, z0, cell, n, di, dj, full,
			Terrain.RELIEF, Terrain.FLAT, Terrain.RAMP,
			Terrain.MOUNTAIN, Terrain.MOUNTAIN_FLAT, Terrain.MOUNTAIN_RAMP)
	return _shift_heights_gd(src, x0, z0, cell, n, di, dj, full)

## The Rust field sampler, made on first use. `ClassDB` rather than a typed
## reference so a build without the extension still parses and falls back.
static func _rust_fill() -> Object:
	if not _rust_checked:
		_rust_checked = true
		if ClassDB.class_exists("TerrainField"):
			_rust_field = ClassDB.instantiate("TerrainField")
	return _rust_field

func _shift_heights_gd(src: PackedFloat64Array, x0: float, z0: float, cell: float,
		n: int, di: int, dj: int, full: bool) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(n * n)
	if full or src.size() != n * n:
		for j in n:
			var wz: float = z0 + j * cell
			var row: int = j * n
			for i in n:
				out[row + i] = Terrain.base_height(x0 + i * cell, wz)
		return out
	for j in n:
		var wz: float = z0 + j * cell
		var row: int = j * n
		var sj: int = j + dj
		for i in n:
			var si: int = i + di
			if sj >= 0 and sj < n and si >= 0 and si < n:
				out[row + i] = src[sj * n + si]
			else:
				out[row + i] = Terrain.base_height(x0 + i * cell, wz)
	return out

## The attributes of a grid after the same shift. Entries outside the overlap are
## left at zero: `_dirty_rect` is exactly the set the write pass replaces.
func _shift_vec3(src: PackedVector3Array, n: int, di: int, dj: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(n * n)
	if src.size() != n * n or (di == 0 and dj == 0):
		return out
	for j in n:
		var sj: int = j + dj
		if sj < 0 or sj >= n:
			continue
		var row: int = j * n
		var srow: int = sj * n
		for i in n:
			var si: int = i + di
			if si >= 0 and si < n:
				out[row + i] = src[srow + si]
	return out

func _shift_vec2(src: PackedVector2Array, n: int, di: int, dj: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(n * n)
	if src.size() != n * n or (di == 0 and dj == 0):
		return out
	for j in n:
		var sj: int = j + dj
		if sj < 0 or sj >= n:
			continue
		var row: int = j * n
		var srow: int = sj * n
		for i in n:
			var si: int = i + di
			if si >= 0 and si < n:
				out[row + i] = src[srow + si]
	return out

func _shift_color(src: PackedColorArray, n: int, di: int, dj: int) -> PackedColorArray:
	var out := PackedColorArray()
	out.resize(n * n)
	if src.size() != n * n or (di == 0 and dj == 0):
		return out
	for j in n:
		var sj: int = j + dj
		if sj < 0 or sj >= n:
			continue
		var row: int = j * n
		var srow: int = sj * n
		for i in n:
			var si: int = i + di
			if si >= 0 and si < n:
				out[row + i] = src[srow + si]
	return out

## Rewrite one grid's position, normal, colour and texcoord over the dirty blocks.
## `ring` selects the hole-rim edge rule; the near grid's perimeter is the outer
## square. Returns the four arrays in that order.
##
## A copied vertex's attributes are only valid if it was shaded the same way
## before and after the shift: a world point that was on the outer edge (or on a
## hole rim) and is now interior was lit with the fixed-step edge slope, and one
## that moved onto an edge with the grid's own difference. Those are recomputed
## too -- they are thin lines, and a scan for them costs nothing beside the field.
func _write_grid(x0: float, z0: float, cell: float, n: int, grid: PackedFloat64Array,
		di: int, dj: int, prev_verts: PackedVector3Array, prev_norms: PackedVector3Array,
		prev_cols: PackedColorArray, prev_uvs: PackedVector2Array,
		rects: Array, ring: bool) -> Array:
	var verts := _shift_vec3(prev_verts, n, di, dj)
	var norms := _shift_vec3(prev_norms, n, di, dj)
	var cols := _shift_color(prev_cols, n, di, dj)
	var uvs := _shift_vec2(prev_uvs, n, di, dj)
	for rect in rects:
		var i0: int = rect[0]
		var i1: int = rect[1]
		var j0: int = rect[2]
		var j1: int = rect[3]
		for j in range(j0, j1 + 1):
			_write_row(x0, z0, cell, n, grid, i0, i1, j, verts, norms, cols, uvs, ring)
	if di != 0 or dj != 0:
		# A copied vertex's attributes are only valid if it was shaded the same way
		# before and after the shift: a world point that was on the outer edge (or a
		# hole rim) and is now interior was lit with the fixed-step edge slope, and
		# one that moved onto an edge with the grid's own difference. The edge rule
		# is `outer(i) or outer(j) or (rim(i) and holeRange(j)) or (rim(j) and
		# holeRange(i))`, so each axis' three bits answer it for a whole row at a
		# time and the scan is arithmetic rather than a call per vertex.
		var bits := _axis_bits(n, ring)
		var oi: PackedByteArray = bits[0]
		var ri: PackedByteArray = bits[1]
		var hi: PackedByteArray = bits[2]
		for j in n:
			var sj: int = j + dj
			if sj < 0 or sj >= n:
				continue
			var nj_o: int = oi[j]
			var nj_r: int = ri[j]
			var nj_h: int = hi[j]
			var sj_o: int = oi[sj]
			var sj_r: int = ri[sj]
			var sj_h: int = hi[sj]
			for i in n:
				var si: int = i + di
				if si < 0 or si >= n:
					continue
				var now: int = oi[i] | nj_o | (ri[i] & nj_h) | (nj_r & hi[i])
				var was: int = oi[si] | sj_o | (ri[si] & sj_h) | (sj_r & hi[si])
				if now != was:
					_write_row(x0, z0, cell, n, grid, i, i, j, verts, norms, cols, uvs, ring)
	return [verts, norms, cols, uvs]

## One axis' edge bits: `outer` (the two ends), `rim` (the hole's lines) and
## `hole` (inside the hole's span). `_ring_edge` is exactly these three per axis.
func _axis_bits(n: int, ring: bool) -> Array:
	var outer := PackedByteArray()
	var rim := PackedByteArray()
	var hole := PackedByteArray()
	outer.resize(n)
	rim.resize(n)
	hole.resize(n)
	for v in n:
		outer[v] = 1 if (v == 0 or v == n - 1) else 0
		if ring:
			rim[v] = 1 if (v == RING_HOLE0 or v == RING_HOLE1) else 0
			hole[v] = 1 if (v >= RING_HOLE0 and v <= RING_HOLE1) else 0
	return [outer, rim, hole]

func _write_row(x0: float, z0: float, cell: float, n: int, grid: PackedFloat64Array,
		i0: int, i1: int, j: int, verts: PackedVector3Array, norms: PackedVector3Array,
		cols: PackedColorArray, uvs: PackedVector2Array, ring: bool) -> void:
	var wz: float = z0 + j * cell
	var row: int = j * n
	for i in range(i0, i1 + 1):
		var k: int = row + i
		var wx: float = x0 + i * cell
		var y: float = float(grid[k])
		verts[k] = Vector3(wx, y, wz)

		# Central differences on the grid, the scene's own edge handling
		# included: at the last column the forward sample is the cell itself
		# rather than a reflected one, which halves the slope there instead of
		# inventing a neighbour. The perimeter does not use that handling: it
		# samples the field over `EDGE_STEP`, so it agrees with the coarser
		# surface on the other side of the seam.
		var edge: bool = _ring_edge(i, j) if ring \
			else (i == 0 or i == n - 1 or j == 0 or j == n - 1)
		var dx: float = 0.0
		var dz: float = 0.0
		if edge:
			var slope2 := _edge_slope(wx, wz)
			dx = slope2.x
			dz = slope2.y
		else:
			var fwd_i: int = 1 if i < n - 1 else 0
			var back_i: int = 1 if i > 0 else 0
			var fwd_j: int = n if j < n - 1 else 0
			var back_j: int = n if j > 0 else 0
			dx = (grid[k + fwd_i] - grid[k - back_i]) / (2.0 * cell)
			dz = (grid[k + fwd_j] - grid[k - back_j]) / (2.0 * cell)
		var inv: float = 1.0 / sqrt(dx * dx + dz * dz + 1.0)
		norms[k] = Vector3(-dx * inv, inv, -dz * inv)

		var slope: float = minf(1.0, sqrt(dx * dx + dz * dz))
		var patch: float = Terrain.vnoise2(wx * 0.07 + 3.1, wz * 0.07 + 9.7)
		cols[k] = Terrain.material(y, slope, patch)
		uvs[k] = Vector2(wx * UV_SCALE, wz * UV_SCALE)

## The slope at a world point over the fixed `EDGE_STEP`, so a surface's
## perimeter shades the way the field does rather than the way its own cell size
## happens to sample it. `world.js` `terrainEdgeSlope`. The sampling is Rust when
## the extension is present: a perimeter vertex asks for four field values and a
## rebuild asks for hundreds of them.
func _edge_slope(x: float, z: float) -> Vector2:
	var field: Object = _rust_fill()
	if field != null:
		return field.call("slope", x, z, EDGE_STEP,
			Terrain.RELIEF, Terrain.FLAT, Terrain.RAMP,
			Terrain.MOUNTAIN, Terrain.MOUNTAIN_FLAT, Terrain.MOUNTAIN_RAMP)
	return _edge_slope_gd(x, z)

func _edge_slope_gd(x: float, z: float) -> Vector2:
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
