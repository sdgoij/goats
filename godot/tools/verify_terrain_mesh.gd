# The drawn-ground gate: the mesh the scene's heightfield implies.
#
#   Godot --headless --path godot --script res://tools/verify_terrain_mesh.gd
#
# `terrain.gd` is measured against the JavaScript (`verify_terrain.gd`). This is
# the other half: that the *grid* built from it is the grid the client builds --
# the near 2401-vertex, 4608-triangle surface, the mid and far rings' own 49x49
# grids with their inner squares cut out, and the two seam strips that close the
# lens between a fine edge and the coarse chord meeting it -- plus a normal from
# central differences, a per-vertex material colour, a world-space texcoord -- and
# that it rebuilds when the anchor drifts rather than every frame.
#
# The geometry can be checked without a window, which is why this is a gate and
# not a screenshot: the winding of the first triangle decides whether the ground
# faces up at all, and a mesh whose faces point the wrong way is invisible while
# looking perfectly correct in the data.
extends SceneTree

## `world.js`'s palette, as sRGB bytes (`T_ROCK` .. `T_SNOW`).
const PALETTE := [
	[128, 122, 112], [104, 84, 62], [198, 178, 130],
	[98, 150, 84], [78, 126, 66], [126, 146, 74], [232, 238, 245],
]

func _initialize() -> void:
	var failures: Array[String] = []

	var node := TerrainMesh.new()
	root.add_child(node)   # `_ready` builds the grid at (0, 0).
	print("after add_child: rebuilds=", node.rebuilds, " mesh set=", node.mesh != null)
	if node.mesh == null:
		node.build(0.0, 0.0)
		print("after an explicit build: rebuilds=", node.rebuilds, " mesh set=", node.mesh != null)

	var mesh := node.mesh as ArrayMesh
	if mesh == null or mesh.get_surface_count() != 5:
		print("FAIL: the terrain did not build its near grid, two rings and two seam strips")
		quit(1)
		return

	var arrays := mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]

	# 1. The grid: the client's 49x49 vertices and 48x48x2 triangles, the two rings'
	#    49x49 with a 24x24-quad hole, and the two 384-vertex seam strips.
	@warning_ignore("integer_division")
	print("vertices: ", verts.size(), "  triangles: ", indices.size() / 3)
	if verts.size() != 49 * 49:
		failures.append("expected 2401 vertices, got %d" % verts.size())
	if indices.size() != 48 * 48 * 6:
		failures.append("expected 13824 indices, got %d" % indices.size())
	if cols.size() != verts.size() or uvs.size() != verts.size() or norms.size() != verts.size():
		failures.append("the attribute arrays are not all the same length")

	for surface in [1, 2]:
		var ring_arrays := mesh.surface_get_arrays(surface)
		var ring_verts: PackedVector3Array = ring_arrays[Mesh.ARRAY_VERTEX]
		var ring_indices: PackedInt32Array = ring_arrays[Mesh.ARRAY_INDEX]
		@warning_ignore("integer_division")
		print("surface %d: %d vertices, %d triangles" % [surface, ring_verts.size(), ring_indices.size() / 3])
		if ring_verts.size() != 49 * 49:
			failures.append("surface %d: expected 2401 vertices, got %d" % [surface, ring_verts.size()])
		if ring_indices.size() != (48 * 48 - 24 * 24) * 6:
			failures.append("surface %d: expected %d indices, got %d"
				% [surface, (48 * 48 - 24 * 24) * 6, ring_indices.size()])

	for surface in [3, 4]:
		var seam_arrays := mesh.surface_get_arrays(surface)
		var seam_verts: PackedVector3Array = seam_arrays[Mesh.ARRAY_VERTEX]
		var seam_indices: PackedInt32Array = seam_arrays[Mesh.ARRAY_INDEX]
		@warning_ignore("integer_division")
		print("surface %d: %d vertices, %d triangles" % [surface, seam_verts.size(), seam_indices.size() / 3])
		if seam_verts.size() != 2 * (4 * 49 - 4):
			failures.append("surface %d: expected 384 seam vertices, got %d" % [surface, seam_verts.size()])
		if seam_indices.size() != (4 * 49 - 4) * 12:
			failures.append("surface %d: expected %d seam indices, got %d"
				% [surface, (4 * 49 - 4) * 12, seam_indices.size()])

	# 2. The field it covers, and that it is where the anchor says it is. The near
	#    grid's own bounds are in its vertex array; the mesh's AABB includes the ring.
	var box := mesh.get_aabb()
	print("mesh aabb: ", box)
	if not is_equal_approx(box.size.x, 384.0) or not is_equal_approx(box.size.z, 384.0):
		failures.append("the far ring does not span 384 units: %s" % box.size)
	if not is_equal_approx(box.position.x, -192.0) or not is_equal_approx(box.position.z, -192.0):
		failures.append("the far ring does not start at -192: %s" % box.position)
	var near_low := Vector3(INF, INF, INF)
	var near_high := Vector3(-INF, -INF, -INF)
	for v in verts:
		near_low = near_low.min(v)
		near_high = near_high.max(v)
	print("near aabb: ", near_low, " .. ", near_high)
	if not is_equal_approx(near_high.x - near_low.x, 96.0) \
			or not is_equal_approx(near_high.z - near_low.z, 96.0):
		failures.append("the near grid does not span 96 units")
	if not is_equal_approx(near_low.x, -48.0) or not is_equal_approx(near_low.z, -48.0):
		failures.append("the near grid does not start at -48: %s" % near_low)

	# 3. The heights are the field's. The vertices are float32 and the field is
	#    double, so this compares to a tenth of a millimetre -- a transcription
	#    error (a swapped axis, an off-by-one in the row stride) would be metres.
	var worst_height := 0.0
	for k in [0, 1, 49, 50, 1200, 2400, 1176, 1177]:
		var v: Vector3 = verts[k]
		var expected: float = Terrain.base_height(v.x, v.z)
		worst_height = maxf(worst_height, absf(v.y - expected))
	print("worst height error: %.6f m (float32 grid against the double field)" % worst_height)
	if worst_height > 0.001:
		failures.append("a vertex is %.6f m off the field under it" % worst_height)

	# 4. Normals: unit length, and pointing up. A grid whose normals are downhill
	#    is a grid that renders black.
	var worst_normal := 0.0
	var downward := 0
	for k in verts.size():
		worst_normal = maxf(worst_normal, absf(norms[k].length() - 1.0))
		if norms[k].y <= 0.0:
			downward += 1
	print("worst normal error: %.6f  (normals not facing up: %d)" % [worst_normal, downward])
	if worst_normal > 0.001:
		failures.append("a normal is not unit length (off by %.6f)" % worst_normal)
	if downward != 0:
		failures.append("%d normals do not face up" % downward)

	# 5. The winding, which the data does not show and the window does: the first
	#    triangle has to be front-facing *for Godot*, which is the reverse of
	#    raylib's convention. Asking Godot's own `Plane` rather than doing the cross
	#    product here is the point -- the assertion is then Godot's rule and not
	#    mine, and a mirrored winding cannot pass it by both being wrong. The skirts
	#    are vertical and emitted double-sided, so they are not in this check.
	for surface in [0, 1, 2]:
		var winding_arrays := mesh.surface_get_arrays(surface)
		var winding_verts: PackedVector3Array = winding_arrays[Mesh.ARRAY_VERTEX]
		var winding_indices: PackedInt32Array = winding_arrays[Mesh.ARRAY_INDEX]
		var a: Vector3 = winding_verts[winding_indices[0]]
		var b: Vector3 = winding_verts[winding_indices[1]]
		var c: Vector3 = winding_verts[winding_indices[2]]
		var facing := Plane(a, b, c).normal
		print("surface %d's first triangle faces: %s" % [surface, facing])
		if facing.y <= 0.0:
			failures.append("surface %d is wound the wrong way for Godot (faces %s)" % [surface, facing])

	# 6. The material colour is one of the palette's, per vertex.
	var off_palette := 0
	for k in cols.size():
		if not _in_palette(cols[k]):
			off_palette += 1
	print("vertices off the palette: ", off_palette)
	if off_palette != 0:
		failures.append("%d vertices are not a palette colour" % off_palette)

	# 7. The texcoord is world-space, so the detail tiles per unit and not per
	#    quad -- the same cell is a different UV at a different anchor.
	var worst_uv := 0.0
	for k in [0, 500, 2400]:
		var v: Vector3 = verts[k]
		worst_uv = maxf(worst_uv, absf(uvs[k].x - v.x * 0.12))
		worst_uv = maxf(worst_uv, absf(uvs[k].y - v.z * 0.12))
	print("worst texcoord error: %.6f" % worst_uv)
	if worst_uv > 0.001:
		failures.append("the texcoords are not world-space (off by %.6f)" % worst_uv)

	# 8. The drift: a rebuild every `SNAP` units of travel, not every frame.
	var before := node.rebuilds
	node.follow(30.0, 7.0)
	var moved: Vector2 = node.anchor()
	print("follow(30, 7) -> anchor (%.0f, %.0f), %d rebuild(s)" % [moved.x, moved.y, node.rebuilds - before])
	if moved != Vector2(32.0, 0.0):
		failures.append("the anchor should snap to (32, 0), got %s" % moved)
	if node.rebuilds != before + 1:
		failures.append("a snap of 6 units did not rebuild")

	before = node.rebuilds
	node.follow(31.0, 7.0)
	if node.rebuilds != before:
		failures.append("a step inside the same cell rebuilt the grid")

	before = node.rebuilds
	node.follow(70.0, 7.0)
	moved = node.anchor()
	print("follow(70, 7) -> anchor (%.0f, %.0f), %d rebuild(s)" % [moved.x, moved.y, node.rebuilds - before])
	if moved != Vector2(64.0, 0.0) or node.rebuilds != before + 1:
		failures.append("the second snap did not rebuild at (64, 0): %s" % moved)

	# The grid moved with the anchor, and the field under it is still the field.
	var moved_arrays := (node.mesh as ArrayMesh).surface_get_arrays(0)
	var moved_verts: PackedVector3Array = moved_arrays[Mesh.ARRAY_VERTEX]
	if moved_verts.size() == 0 or not is_equal_approx(moved_verts[0].x, 16.0):
		failures.append("the rebuilt grid did not move with the anchor: %s" % moved_verts[0])

	node.free()

	if failures.is_empty():
		print("OK: the ground is the scene's grid, built from the scene's field")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

func _in_palette(colour: Color) -> bool:
	for entry in PALETTE:
		# The mesh carries the palette in linear space (`Terrain._rgb`), and the
		# vertex buffer stores colours as 8-bit, so a linear component can be up to
		# half a byte from its exact conversion.
		var c := Color8(entry[0], entry[1], entry[2]).srgb_to_linear()
		var tolerance := 1.0 / 255.0
		if absf(c.r - colour.r) < tolerance and absf(c.g - colour.g) < tolerance \
				and absf(c.b - colour.b) < tolerance:
			return true
	return false
