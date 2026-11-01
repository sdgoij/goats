# The water's mirror (M20e): `water.js`'s tier 2, a second camera under a second viewport.
#
# `renderWaterMirror` renders the world from the camera the water's own plane mirrors the
# player's into -- "a horizontal plane mirrors y and leaves xz alone, so both the eye and what
# it looks at flip through `2 * level - y`" -- into a half-resolution target it clears
# *transparent*, so the surface can tell what the pass actually drew from what it left to the
# sky. This is that: a `SubViewport` sharing the scene's own `World3D`, a `Camera3D` inside it
# at the mirrored eye looking at the mirrored target, and the texture the surface samples at
# its own **column**, flipped in the row (`water.gdshader`): the pass's camera is ordinary, so
# it renders the world upright, while a reflection is that image about the waterline.
#
# It is a *second scene submission*, and that is the one thing `PORT.md`'s plan ruled out. It
# is here because the two things that would have avoided it cannot do this job: Godot's own
# `ssr_enabled` never reaches a transparent material (measured: 0.000064 of a frame transparent
# against 0.003081 with the water made opaque), and the port's own screen-space march in the
# shader finds only what sits near the reflector's own screen footprint -- a pool reflected a
# splat of the goat and nothing else.
#
# What the pass draws is the scene's own list -- terrain, the player, the herd -- and what it
# leaves out is the scene's own two exclusions, said with `cull_mask` over the layers `main.gd`
# sets: the **surface and the drops** (a reflection must not contain the thing that reflects)
# and the **meadow** (a tuft is two cubes of noise in a reflection, and the grass is the
# frame's largest phase). The ground tier culls *everything but the ground*, which is how "it
# does not reflect the goat" is said -- and it is also where that tier's saving is, since the
# goats are what a mirror frame has to pose twice.
#
# The ground is the one thing here that needs a **second instance** rather than a second
# `cull_mask` entry: a heightfield's quads face away from a camera under it, so the mesh the
# main pass draws is invisible to this one and vice versa. `use_ground` takes the terrain's own
# `ArrayMesh` and the material `terrain_mesh.gd` builds for it, and the twin lives on a layer of
# its own that the main camera is told to skip -- so the reflection costs one draw at half the
# viewport and no geometry at all.
#
# One thing here is **not** the scene's, and it is the cost it pays for being a mirror at all.
# The scene's tier 1 was a heightfield baked once, so it was camera-independent and cost
# nothing a frame. A mirror cannot be: its image depends on where the camera is, so the port's
# two tiers both pay a submission and differ in what they contain.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterMirror
extends Node

## The three layers the masks are built from: the ground as the *main* pass draws it, the
## things that must never be in a reflection, and the ground as the *mirror* draws it. Everything
## else -- the goat, the herd, the devices, the bodies -- keeps layer 1, which is what makes "the
## ground and not the goat" expressible at all.
##
## **The ground needs two layers because it needs two draws.** A heightfield's quads face away
## from a camera under it, so the mesh the main pass draws is invisible to the mirror and the
## mesh the mirror draws is invisible to the main pass (`terrain_mirror.gdshader` carries the
## why). Two layers is what keeps each camera to its own; a single layer would put one of them
## on the wrong side and cost a draw of terrain nobody can see at best.
##
## They start at layer 5, and that is not arbitrary: **layer 2 is already the moon's**
## (`celestial.gd`'s `MOON_LAYER`, the layer its own light is masked to), and a collision with
## it is silent and expensive -- the ground moved onto it went pale, because the moon's light
## was suddenly lighting the terrain as well as the moon. A layer is a global number and
## nothing checks it is free.
const LAYER_GROUND := 1 << 4
const LAYER_NOREFLECT := 1 << 5
const LAYER_GROUND_MIRROR := 1 << 6

## What a tier's pass draws, indexed by `water.js`'s tier number. The sky tier draws nothing at
## all, which is why `runs` can be read off the mask rather than kept beside it. The ground tier
## draws the *mirror's* ground -- and not layer 1, which is the goat, and not the main pass's
## terrain, whose quads face away from this camera.
const MASK_SKY := 0
const MASK_GROUND := LAYER_GROUND_MIRROR
const MASK_WORLD := 0xFFFFF & ~(LAYER_NOREFLECT | LAYER_GROUND)
const MASKS := [MASK_SKY, MASK_GROUND, MASK_WORLD]

## The pass's target, the camera that fills it and the ground's own twin. Built on first use, so
## a node can be created before the tree it will share a world with.
var _viewport: SubViewport
var _camera: Camera3D
var _size := Vector2i.ZERO
## The ground as this pass draws it: a second `MeshInstance3D` over the *same* `ArrayMesh` as
## the terrain, wearing `terrain_mesh.gd`'s mirror material. Null until `use_ground` names one,
## because the terrain is not this object's to find.
var _ground: MeshInstance3D
var _ground_material: ShaderMaterial
## The level last pushed into that material, so a still pool costs no write.
var _ground_level := NAN

## How many times the pass has run, which is the port's answer to the scene's `mirrorPasses`:
## a case reads the difference across a frame, and a picture shows a goat's reflection only when
## this moves.
var passes := 0

func _ready() -> void:
	build()

## What a tier's pass draws, and whether it draws at all.
static func mask_of(which: int) -> int:
	if which < 0 or which >= MASKS.size():
		return MASK_SKY
	return MASKS[which]

static func runs(which: int) -> bool:
	return mask_of(which) != 0

## Build the pass's target and its camera, once. Called from `_ready` and from `run`, because a
## `SceneTree` script that adds the node during `_initialize` never sees `_ready` -- the same
## reason `water_mesh.gd` builds its material inside `build`.
func build() -> void:
	if _viewport != null:
		return
	_viewport = SubViewport.new()
	# The scene's own list, and the scene's own clear: it draws terrain and bodies and clears to
	# alpha 0, so the surface mixes the sky in wherever the pass drew nothing. `transparent_bg`
	# is what makes that alpha, and it is also why the pass draws no sky of its own.
	_viewport.transparent_bg = true
	_viewport.own_world_3d = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)
	_camera = Camera3D.new()
	_camera.cull_mask = MASK_SKY
	# The target is half the viewport, as the scene's is: a reflection is read through a ripple
	# and nothing in it is worth a pixel.
	_size = Vector2i.ZERO
	_viewport.add_child(_camera)
	_camera.current = true
	# The ground's twin, on the layer only this pass draws. It is off until a tier asks for the
	# ground, and it wears whatever mesh and material `use_ground` names -- which is the terrain's
	# own `ArrayMesh`, so a rebuilt grid is a rebuilt reflection with nothing to copy.
	_ground = MeshInstance3D.new()
	_ground.name = "GroundMirror"
	_ground.layers = LAYER_GROUND_MIRROR
	# The ground the main pass casts from is the same geometry; a second caster would be the same
	# depth map written twice.
	_ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_ground.visible = false
	add_child(_ground)

## Name the ground this pass draws: the terrain's own mesh, and the material the mirror draws it
## with (`terrain_mesh.gd`'s `mirror_material`). The *instance* is this object's because the pass
## is; the *look* is the terrain's because the ground is.
func use_ground(mesh: Mesh, material: ShaderMaterial) -> void:
	build()
	_ground.mesh = mesh
	_ground.material_override = material
	_ground_material = material
	_ground_level = NAN

## Whether there is a ground for the pass to draw, which is what a caller checks before asking
## the tier to show one.
func has_ground() -> bool:
	build()
	return _ground.mesh != null

## The tier last set, and whether there is water for it to reflect. Kept here because the
## viewport's update mode is a *state* rather than a call: "don't run this frame" has to be
## written into the target, so it cannot be skipped the way `renderWaterMirror`'s early
## return skips it in the scene.
var _tier := 0
var _wet := true

## Point the pass at a tier: what it draws, and whether it runs at all. Called where the wish
## moves rather than every frame, because a tier is a setting.
func set_tier(which: int) -> void:
	_tier = which
	_sync()

## Whether there is anything to reflect this frame, which the scene asks as `!waterOn`.
## It is **not** a micro-optimisation: the mirror tier is a second submission of the whole
## scene, and a dry meadow was paying it every frame for a target nothing samples -- measured
## at 5-8% of the frame on the desktop build, with a browser paying more for the same
## submission. Cheap to call every frame: an unchanged value writes nothing.
func set_wet(wet: bool) -> void:
	if wet == _wet:
		return
	_wet = wet
	_sync()

## Write the two states into what draws them.
func _sync() -> void:
	build()
	_viewport.render_target_update_mode = \
		SubViewport.UPDATE_ALWAYS if (runs(_tier) and _wet) else SubViewport.UPDATE_DISABLED
	# The twin is only in a tier whose mask names its layer, so a tier that does not draw the
	# ground does not submit it either -- the pass is half the viewport but the draw is not free.
	_ground.visible = ((mask_of(_tier) & LAYER_GROUND_MIRROR) != 0) and _wet

## What the pass draws this frame, and whether it runs at all -- the two things `set_tier`
## decides, read back off the camera and the target rather than kept beside them. There is no
## second copy of the tier here, which is why the two can never disagree with what will run.
func mask() -> int:
	build()
	return _camera.cull_mask

func running() -> bool:
	build()
	return _viewport.render_target_update_mode != SubViewport.UPDATE_DISABLED

## The texture the surface samples, or `null` before the pass has been built.
func texture() -> ViewportTexture:
	build()
	return _viewport.get_texture()

## Place the pass for this frame: the mirrored eye, the mirrored target, and the target's own
## size. `level` is the water's plane, so the eye and what it looks at both flip through it.
func run(source: Camera3D, level: float) -> void:
	build()
	# The ground's own cut is the water's plane, so the twin is told where it is -- once, because a
	# still pool would otherwise be a uniform write a frame for nothing.
	if _ground_material != null and (is_nan(_ground_level) or absf(level - _ground_level) > 1e-6):
		_ground_level = level
		_ground_material.set_shader_parameter("water_level", level)
	if _viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED:
		return
	var size: Vector2i = (source.get_viewport().get_visible_rect().size / 2.0).floor()
	size = Vector2i(maxi(size.x, 16), maxi(size.y, 16))
	if size != _size:
		_size = size
		_viewport.size = size
		# The projection has to match the camera's, or the sample lands on the wrong pixel.
		_camera.fov = source.fov
		_camera.near = source.near
		_camera.far = source.far
		_camera.keep_aspect = source.keep_aspect
	var eye: Vector3 = source.global_position
	var look: Vector3 = eye - source.global_transform.basis.z
	_camera.global_position = Vector3(eye.x, 2.0 * level - eye.y, eye.z)
	var target := Vector3(look.x, 2.0 * level - look.y, look.z)
	# A camera looking straight down would mirror to one looking straight up, where `UP` cannot
	# orient it -- and the scene's own pitch clamp is what keeps that from happening, so this is
	# only a guard.
	var up := Vector3.UP
	if absf((target - _camera.global_position).normalized().dot(up)) > 0.999:
		up = Vector3.FORWARD
	_camera.look_at(target, up)
	passes += 1
