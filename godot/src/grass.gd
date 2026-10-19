# The grass, drawn: `weather.js`'s `tuftField` as a `MultiMesh`.
#
# The meadow is not a mesh that is placed anywhere -- it is a *function of where the
# goat is*, recomputed per frame from a hash of each 2-unit cell, so the field
# follows the herd and never runs out (a fixed patch leaves bare ground behind after
# a walk). `field` is that function, a transcription of the scene's `tuftField` down
# to the arithmetic and the call order, and `tools/verify_grass.gd` checks it
# against the JavaScript itself -- the scene's own engine -- the way
# `verify_terrain.gd` checks the heightfield.
#
# Three things about the transcription are worth naming, because each is a place a
# plausible tidying would change the field:
#
#   * The per-cell hash is **`Meadow.cell_hash`**, not a copy. The scene carries
#     that arithmetic twice (`food.js` `nearestTuft` and `weather.js` `tuftField`)
#     to keep the per-frame call depth down; here it is one function, so the grass
#     a goat can see and the grass it can eat are the same grass by construction.
#     The hash itself is 32-bit **wrap-around integer mixing** (`Math.imul`, `>>>`,
#     `| 0`) and GDScript's `int` is 64 bits, so `Meadow` re-implements the wrap --
#     a subtly wrong `imul` is not a slightly wrong field, it is a different one
#     that still looks like grass.
#   * The cell's height is a **deliberate omission of a cache**. The scene memoises
#     `terrainHeight` per cell (it was ~2 ms/frame at ~500 samples); GDScript does
#     the ~330 samples the visible field needs in a fraction of a millisecond, and a
#     pure function is one the gate can call.
#   * The two cubes are the scene's own **two-cube tuft**: a far tuft is one cube,
#     a near one gets a second, shorter segment so the bend reads up close. A
#     `MultiMesh` carries both as instances of one unit box, scaled per instance --
#     and `rl.drawCube` centres a cube on its position, which is what `BoxMesh`
#     scaled about its own origin also does.
#
# The colour is the scene's `TUFT` (core.js), passed as it is: the port's ground
# (`terrain_mesh.gd`) hands Godot's pipeline its per-vertex colours the same way, so
# the grass and the ground it stands on agree about how bright green is.
#
# The meadow is also the one field a *pool* edits: a tuft standing under the water is
# skipped (M20d), because the surface is drawn over the ground and a tuft inside a pool
# would stand out of it. The scene does that in `drawTufts`, a line after it has built the
# tuft pool; here the test is the last thing `field` does to a cell, so the tufts a frame
# *keeps* are one function's answer and a gate can hold them. `submerged` is the seam --
# `Water.submerged_at` in the scene, and nothing at all when there is no water.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Grass
extends MultiMeshInstance3D

## `drawTufts(goat, TUFT, 576, 180)` (`goat.js` sceneFrame): cull beyond 24 units,
## detail inside ~13.4.
const CULL2 := 576.0
const DETAIL2 := 180.0

## `core.js` `TUFT`, converted from the scene's sRGB bytes to linear for Godot's
## pipeline (`Color8` does not convert; `PORT.md` section 9).
static var TUFT_COLOUR: Color = Color8(78, 128, 66).srgb_to_linear()
## `rl.drawCube`'s `(0.14, 0.16, 0.14)` and the detail segment's `(0.11, 0.16, 0.11)`.
const CUBE := Vector3(0.14, 0.16, 0.14)
const CUBE_DETAIL := Vector3(0.11, 0.16, 0.11)

## Instances the `MultiMesh` is allocated for. A rebuild walks the ~25x25 cells the
## 24-unit cull reaches (~55% of which hold a tuft) and is a few hundred instances;
## the buffer is allocated once and `visible_instance_count` moves, rather than
## reallocating every frame.
const CAPACITY := 4096

## Floats per tuft in `field`'s answer: `ax, ay, az, bx, by, bz, detail`.
const STRIDE := 7

var _multimesh: MultiMesh
## The tufts' material, kept so `set_lit` can reach it: the field's look is one `StandardMaterial3D`
## on the box the instances share.
var _material: StandardMaterial3D
## Whether the tufts are drawn lit (M25's `L` and the settings screen). A field of the mode rather
## than a read of `_material`, because `_ready` is not the only path that gets here.
var _lit := true
## How many times the field has been rebuilt, which is what a gate reads.
var rebuilds := 0
## The water this field is drawn through: a tuft under it is skipped (M20d). `main.gd`
## hands it in, and with none nothing is culled.
var water: Water

func _ready() -> void:
	_multimesh = MultiMesh.new()
	_multimesh.transform_format = MultiMesh.TRANSFORM_3D
	_multimesh.use_colors = true
	var box := BoxMesh.new()
	box.size = Vector3.ONE
	var material := StandardMaterial3D.new()
	# The scene's lit path draws the tufts through its own program with `TUFT` as the
	# tint; Godot's material, light and shadows do that here (`PORT.md` section 5).
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.shading_mode = TerrainMesh.shading(_lit)
	_material = material
	box.material = material
	_multimesh.mesh = box
	_multimesh.instance_count = CAPACITY
	multimesh = _multimesh
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

## The tufts through the lit material or the plain one: `L` and the settings screen's `Light`
## (M25), which the scene reaches with `setTerrainShader`.
func set_lit(on: bool) -> void:
	_lit = on
	if _material != null:
		_material.shading_mode = TerrainMesh.shading(on)

## Rebuild the field around `centre` and push it to the `MultiMesh`.
##
## `sway_time` and `wind_sway` are the wind's phase clock and its strength, exactly
## the two the scene's `tuftField` takes: the offset each tuft leans by is
## `sin(sway_time * 3 + phase) * 0.11 * wind_sway`.
##
## `eaten` is the meadow the host has grazed, as `tuftKey` values. The snapshot
## carries it (`eaten` in the world event), so a joiner's meadow thins where the
## host's herd has fed.
##
## `water` is what culls the tufts a pool is hiding (M20d).
func update(centre: Vector3, sway_time: float, wind_sway: float, eaten: Dictionary) -> void:
	var cull: Callable = Callable()
	if water != null:
		cull = Callable(water, "submerged_at")
	var positions: PackedFloat64Array = field(
		centre.x, centre.z, CULL2, DETAIL2, sway_time, wind_sway, eaten, cull)
	var tufts: int = positions.size() / STRIDE
	rebuilds += 1

	var index: int = 0
	for i in tufts:
		var base: int = i * STRIDE
		var ax: float = positions[base]
		var ay: float = positions[base + 1]
		var az: float = positions[base + 2]
		if index >= CAPACITY:
			break
		_multimesh.set_instance_transform(index, _cube(ax, ay, az, CUBE))
		_multimesh.set_instance_color(index, TUFT_COLOUR)
		index += 1
		if positions[base + 6] > 0.5 and index < CAPACITY:
			_multimesh.set_instance_transform(index, _cube(
				positions[base + 3], positions[base + 4], positions[base + 5], CUBE_DETAIL))
			_multimesh.set_instance_color(index, TUFT_COLOUR)
			index += 1
	_multimesh.visible_instance_count = index
	# The instances the buffer holds past `visible_instance_count` are not drawn, but
	# the automatic bounds would still be computed over them -- every one of them
	# sitting at the origin -- so the visible region is declared instead.
	var reach: float = sqrt(CULL2) + Terrain.CELL
	_multimesh.custom_aabb = AABB(
		centre + Vector3(-reach, -8.0, -reach), Vector3(reach * 2.0, 16.0, reach * 2.0))

## How many tufts the last `update` drew, for a probe.
func count() -> int:
	if _multimesh == null:
		return 0
	return _multimesh.visible_instance_count

## A unit box scaled to a tuft's segment and centred on it.
func _cube(x: float, y: float, z: float, size: Vector3) -> Transform3D:
	return Transform3D(Basis.from_scale(size), Vector3(x, y, z))

## The visible tufts around `(gx, gz)`, flat: `STRIDE` doubles each, `ax, ay, az,
## bx, by, bz, detail`. `weather.js` `tuftField`, verbatim apart from the emulated
## 32-bit arithmetic, the dropped height cache, and the water cull `drawTufts` does a
## line later -- merged here for the reason the header gives.
static func field(gx: float, gz: float, cull2: float, detail2: float,
		sway_time: float, wind_sway: float, eaten: Dictionary,
		submerged: Callable = Callable()) -> PackedFloat64Array:
	var radius: float = sqrt(cull2)
	var cx0: int = int(floor((gx - radius) * 0.5))
	var cx1: int = int(ceil((gx + radius) * 0.5))
	var cz0: int = int(floor((gz - radius) * 0.5))
	var cz1: int = int(ceil((gz + radius) * 0.5))

	var out := PackedFloat64Array()
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			# Existence, and the z jitter.
			var hash: Vector3i = Meadow.cell_hash(cx, cz)
			var a: float = Meadow.unit(hash.x)
			if a < 0.45:
				continue
			# Eaten cells are skipped entirely, so the field thins as the herd grazes.
			if eaten.has(Meadow.key(cx, cz)):
				continue
			var x: float = cx * Terrain.CELL + (Meadow.unit(hash.y) - 0.5) * 1.8
			var z: float = cz * Terrain.CELL + (a - 0.5) * 1.8
			var tx: float = x - gx
			var tz: float = z - gz
			var d2: float = tx * tx + tz * tz
			if d2 > cull2:
				continue
			var off: float = sin(sway_time * 3.0 + Meadow.unit(hash.z) * 6.28) * 0.11 * wind_sway
			# A tuft standing under the water is skipped (`drawTufts`), and the test is the
			# tuft's *swayed* place -- the position the scene asks `waterSubmergedAt` about.
			# Where the count of what it skips lives is `Water`'s business: it is the test's
			# one caller and the number `state` reports.
			if submerged.is_valid() and bool(submerged.call(x + off, z + off * 0.4)):
				continue
			# The tuft sits on the heightfield, so the grass follows the ground.
			var gy: float = Terrain.height_at(x, z)
			out.append(x + off)
			out.append(gy + 0.06)
			out.append(z + off * 0.4)
			out.append(x + off * 1.7)
			out.append(gy + 0.20)
			out.append(z + off * 0.7)
			out.append(1.0 if d2 < detail2 else 0.0)
	return out
