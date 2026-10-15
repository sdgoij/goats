# The water's surface gate: `water_mesh.gd` against `water.js`'s mesh builder.
#
#   Godot --headless --path godot --script res://tools/verify_water_mesh.gd
#
# The surface is the terrain's grid with two things done to it, and both are what this
# checks:
#
#   1. **The cut.** `waterCut` keeps a quad only if some corner of it stands under the
#      table's ceiling, because nothing above the ceiling can ever be wet -- so a dry
#      field costs one empty draw rather than the terrain's again. The oracle rebuilds
#      that decision for all 2304 quads and hands back the *whole* membership as a string
#      of `0`/`1`, which the port's own index list is turned back into and compared
#      against. A one-quad disagreement is a visible hole in a pool.
#
#   2. **The winding.** The scene winds a quad `a, c, b` / `b, c, d`, which is raylib's
#      front face and Godot's *back* one -- so the port mirrors it, and a surface that got
#      this wrong would be culled and invisible with every number in it right. That is
#      `terrain_mesh.gd`'s own recorded bug, and the check here is the same one it uses:
#      the triangle's own normal, from Godot's own arithmetic, facing the sky.
#
# The *vertex lift* is not here and cannot be: it is `water.gdshader`'s vertex stage, and
# a headless run has no GPU to run it on. What is checked of it is the plumbing -- the
# level `main.gd` pushes each frame arrives at the shader -- and the rest is a picture,
# because water that is level and water that is a skin over the dips are the same numbers
# on the CPU. `tools/screenshot.gd` is the evidence for that half.
extends SceneTree

## `water.js` `waterCut`, transcribed *from its source*, with the grid injected: the
## keep test and the winding, and the whole membership handed back so a single quad
## cannot hide.
const JS := """
const T_H = __HEIGHTS__;
const TOP = __TOP__;
const WATER_N = 49, QUADS = 48;
let kept = "";
let count = 0;
for (let j = 0; j < QUADS; j++) {
    for (let i = 0; i < QUADS; i++) {
        const a = j * WATER_N + i;
        const b = a + 1;
        const c = a + WATER_N;
        const d = c + 1;
        if (T_H[a] >= TOP && T_H[b] >= TOP && T_H[c] >= TOP && T_H[d] >= TOP) { kept += "0"; continue; }
        kept += "1";
        count++;
    }
}
console.log('cut ' + count + ' ' + kept);
"""

## The grid is float32 in the mesh and double in the field, so a vertex cannot be more
## than its own storage away from the ground it was built from -- a tenth of a
## micrometre at the metre scale, and `verify_terrain_mesh.gd` measures the same 0.
const TOLERANCE := 1e-5

func _initialize() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var grid := TerrainMesh.new()
	root.add_child(grid)
	grid.build(0.0, 0.0)
	var heights: PackedFloat64Array = grid.heights()
	var anchor: Vector2 = grid.anchor()

	var surface := WaterMesh.new()
	root.add_child(surface)
	surface.build(heights, anchor)
	if not surface.is_built() or surface.mesh == null:
		print("FAIL: the surface did not build")
		quit(1)
		return

	var as_array: Array = []
	as_array.assign(heights)
	var source: String = JS \
		.replace("__HEIGHTS__", JSON.stringify(as_array)) \
		.replace("__TOP__", str(Water.HIGH))
	var host: Object = ClassDB.instantiate("ModHost")
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return
	var answers: PackedStringArray = host.call("poll_lines")
	var wanted_quads := -1
	var wanted_kept := ""
	for line in answers:
		if line.begins_with("log cut "):
			var parts: PackedStringArray = line.substr(8).split(" ")
			if parts.size() == 2:
				wanted_quads = int(parts[0])
				wanted_kept = parts[1]
	host.free()
	print("oracle answered %d quad(s) kept of %d, %d index/indices"
		% [wanted_quads, Terrain.QUADS * Terrain.QUADS, wanted_kept.length()])

	var arrays: Array = (surface.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	print("surface: %d vertices, %d indices, %d quad(s), %d rebuild(s)"
		% [verts.size(), idx.size(), surface.quads, surface.rebuilds])
	print("aabb: %s" % str((surface.mesh as ArrayMesh).get_aabb()))

	# 1. The cut, completely: the port's own index list turned back into the membership the
	#    oracle handed over. The port's `CUT_EPS` is the one deliberate widening -- the
	#    ceiling is the field's midline, so a quad on it flips on the heightfield's 5e-11
	#    floor -- and the two halves of that claim are what is asserted: nothing the scene
	#    keeps is dropped, and nothing extra is kept that is not a boundary case.
	#    ...and the port's own index list turned back into it. A quad's first index is the
	#    id this reads, and it is every *sixth* one: a quad is two triangles, and the
	#    second triangle opens on the quad's `b` rather than on its own `a`.
	var present := {}
	for t in range(0, idx.size(), 6):
		var a: int = idx[t]
		present[(a / Water.N) * Terrain.QUADS + (a % Water.N)] = true
	var mine := ""
	for q in Terrain.QUADS * Terrain.QUADS:
		mine += "1" if present.has(q) else "0"
	var dropped := 0
	var extra := 0
	var extra_above := 0.0
	var first_dropped := ""
	var first_extra := ""
	for q in mine.length():
		if q >= wanted_kept.length():
			break
		var i: int = q % Terrain.QUADS
		var j: int = q / Terrain.QUADS
		var corner: int = j * Water.N + i
		var lowest: float = minf(
			minf(float(heights[corner]), float(heights[corner + 1])),
			minf(float(heights[corner + Water.N]),
				float(heights[corner + Water.N + 1])))
		if wanted_kept[q] == "1" and mine[q] == "0":
			dropped += 1
			if first_dropped == "":
				first_dropped = "quad %d (%d, %d) bottoms out at %.9f" % [q, i, j, lowest]
		elif wanted_kept[q] == "0" and mine[q] == "1":
			extra += 1
			# How far the *widest* of the port's extra keeps sits from the ceiling -- either
			# side, because the grid itself differs between the engines by the heightfield's
			# 5e-11 `sin` floor. This is the most the port's cut can ever disagree about: a
			# quad that far over the ceiling can never be wet, so every one of these is
			# invisible, and the number is what says so rather than the arithmetic.
			var margin: float = absf(lowest - Water.HIGH)
			if margin > extra_above:
				extra_above = margin
				first_extra = "quad %d (%d, %d) whose lowest corner sits %.12f m from it" % [
					q, i, j, lowest - Water.HIGH]
	print("cut: %d kept, %d of the scene's dropped, %d beyond it, none more than %.12f m "
		% [surface.quads, dropped, extra, extra_above] + "from the ceiling")
	if first_dropped != "":
		print("  first dropped: ", first_dropped)
	if first_extra != "":
		print("  widest extra: ", first_extra)

	# 2. The winding, on every triangle: Godot culls a back face, and a surface whose
	#    triangles all face *down* is a surface that is not there. The test is Godot's own
	#    -- `Plane(p0, p1, p2)`, whose normal is *minus* the cross product, as
	#    `terrain_mesh.gd` records -- and not this file's idea of which way is up.
	var down := 0
	for t in range(0, idx.size(), 3):
		var p0: Vector3 = verts[idx[t]]
		var p1: Vector3 = verts[idx[t + 1]]
		var p2: Vector3 = verts[idx[t + 2]]
		if Plane(p0, p1, p2).normal.y <= 0.0:
			down += 1
	var first_normal := Vector3.ZERO
	if idx.size() >= 3:
		first_normal = Plane(verts[idx[0]], verts[idx[1]], verts[idx[2]]).normal
	print("winding: %d triangle(s) facing down, first normal %s" % [down, str(first_normal)])

	# 3. The vertices are the grid: the ground in `y`, the anchor's window in `x`/`z`.
	var worst: float = 0.0
	var x0: float = anchor.x - Water.HALF
	var z0: float = anchor.y - Water.HALF
	var misplaced := 0
	for j in Water.N:
		for i in Water.N:
			var k: int = j * Water.N + i
			worst = maxf(worst, absf(verts[k].y - float(heights[k])))
			if absf(verts[k].x - (x0 + i * Water.CELL)) > TOLERANCE \
					or absf(verts[k].z - (z0 + j * Water.CELL)) > TOLERANCE:
				misplaced += 1
	print("grid: worst height error %.9f m (float32 mesh against the double field), %d off the window"
		% [worst, misplaced])

	# 4. The lift's plumbing: the level is a *uniform*, so this is as much of the vertex
	#    stage as a headless run can hold on to.
	surface.set_level(-0.5)
	var pushed: Variant = null
	if surface.material_override is ShaderMaterial:
		pushed = (surface.material_override as ShaderMaterial).get_shader_parameter("water_level")
	print("level: pushed -0.5, read back %s" % str(pushed))

	var kept: int = surface.quads
	surface.free()
	grid.free()

	if wanted_quads < 0 or wanted_kept == "":
		failures.append("the oracle did not answer the cut")
	if dropped != 0:
		failures.append("the cut drops %d quad(s) the scene keeps, so a pool has holes: %s"
			% [dropped, first_dropped])
	if extra_above > WaterMesh.CUT_EPS + 1e-9:
		failures.append("the widening reaches %.9f m past the ceiling, further than its own "
			% extra_above + "%.9f m: %s" % [WaterMesh.CUT_EPS, first_extra])
	if down != 0:
		failures.append("%d triangle(s) face down, so Godot culls them" % down)
	if worst > TOLERANCE:
		failures.append("a vertex is %f m off the ground it was built from" % worst)
	if misplaced != 0:
		failures.append("%d vertex/vertices are off the anchor's window" % misplaced)
	if pushed == null or absf(float(pushed) + 0.5) > 1e-6:
		failures.append("the level does not reach the shader: %s" % str(pushed))

	if failures.is_empty():
		print("OK: the surface is the scene's grid, cut and wound the scene's way")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
		# flushes, so a failure written there is never seen.
		for f in failures:
			print("FAIL: ", f)
		quit(1)
