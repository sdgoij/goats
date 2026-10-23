# The cumulus deck, as a world-space volume the goat can fly through.
#
# `sky.js`'s cloud slab hangs at `TUNING.sky.cloudBase`..`cloudTop` (5..9.5 m) and
# the scene's March is a function of the eye's height, so climbing into it is part
# of the world. Sky3D paints its cumulus in the *sky stage*, which is at infinity:
# no altitude ever arrives at it. This node is the deck itself -- a camera-centred
# box, far faces only, marched by `cloud_layer.gdshader` -- so the port keeps the
# scene's own cloud altitudes and the flight model has somewhere to go.
#
# It is a transparent `MeshInstance3D`, which is why it needs no draw-order work
# in `main.gd`: Godot paints opaque geometry first, so the ground and the water are
# already in the depth buffer when this composites over them. The box follows the
# camera in the ground plane and is scaled to the slab, so a ray from below, from
# inside or from above always meets exactly one far face.
class_name CloudLayer
extends MeshInstance3D

const SHADER: Shader = preload("res://src/cloud_layer.gdshader")

## Half the box's ground-plane extent, in metres. It only has to be beyond the
## farthest surface a ray can cross before the slab: the march itself is capped at
## 450 m, and the terrain ends at 192.
const HALF_EXTENT := 450.0

## The scene's `TUNING.sky` values, read through `SkyModel` so the port has one
## copy of the slab's geometry.
var _material: ShaderMaterial

func _ready() -> void:
	var box := BoxMesh.new()
	box.size = Vector3(2.0, 2.0, 2.0)
	mesh = box
	_material = ShaderMaterial.new()
	_material.shader = SHADER
	# After the water, which is the other transparent surface in the scene. A low
	# priority number draws first; the deck is above everything it covers.
	_material.render_priority = 100
	material_override = _material
	# It is a sky-sized cloud, not a caster: a shadow from a 900 m box would be a
	# second darkness over the whole meadow.
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The camera sits *inside* the box, so its AABB is not a useful cull test; the
	# large margin keeps a frustum check from throwing the deck away.
	extra_cull_margin = 4096.0

## Place the slab around `camera` and give the march this frame's sky.
##
## `sky_time` is the scene's own cloud clock (`main.gd` `_sway_time` folded by the
## weather), and `wind_x`/`wind_z` the same wind the grass feels, so the deck drifts
## with the world rather than on the addon's own timer.
func follow(camera: Vector3, hours: float, sky_light: float, cloudiness: float,
		wind_x: float, wind_z: float, sky_time: float) -> void:
	var base: float = SkyModel.CLOUD_BASE
	var top: float = SkyModel.CLOUD_TOP
	var half_height: float = maxf((top - base) * 0.5, 0.01)
	var middle: float = (base + top) * 0.5
	# A unit box scaled to `HALF_EXTENT` in the ground plane and the slab's half
	# thickness vertically, centred on the camera's own column.
	global_transform = Transform3D(
		Basis.from_scale(Vector3(HALF_EXTENT, half_height, HALF_EXTENT)),
		Vector3(camera.x, middle, camera.z))

	var warm: float = SkyModel.warmth(sky_light)
	var sun_colour: Color = SkyModel.light_color(hours, sky_light)
	_material.set_shader_parameter("cam_pos", camera)
	_material.set_shader_parameter("sun_dir", SkyModel.light_dir(hours))
	_material.set_shader_parameter("sun_color",
		Vector3(sun_colour.r, sun_colour.g, sun_colour.b))
	_material.set_shader_parameter("cloud_lit",
		SkyModel._linear(SkyModel.cloud_lit(sky_light, warm)))
	_material.set_shader_parameter("cloud_shadow",
		SkyModel._linear(SkyModel.cloud_shadow(sky_light)))
	# The haze colour, linear, from the same curve the sky background uses. The
	# port's `_apply_sky` owns the curve; this reads it again rather than carrying a
	# second horizon.
	var curve: Dictionary = SkyModel.sample(hours)
	var horizon: Color = SkyModel.overcast(curve["bot"], SkyModel.OVERCAST_BOT, cloudiness)
	_material.set_shader_parameter("horizon_color", SkyModel._linear(horizon))
	_material.set_shader_parameter("cloudiness", clampf(cloudiness, 0.0, 1.0))
	_material.set_shader_parameter("wind",
		Vector2(wind_x * SkyModel.CLOUD_SPEED, wind_z * SkyModel.CLOUD_SPEED))
	_material.set_shader_parameter("sky_time", sky_time)
	_material.set_shader_parameter("cloud_base", base)
	_material.set_shader_parameter("cloud_top", top)
	_material.set_shader_parameter("cloud_scale", SkyModel.CLOUD_SCALE)
	_material.set_shader_parameter("cloud_detail", SkyModel.CLOUD_DETAIL)
	_material.set_shader_parameter("cloud_absorb", SkyModel.CLOUD_ABSORB)
	var level: int = clampi(SkyModel.cloud_level, 0, SkyModel.CLOUD_STEPS.size() - 1)
	_material.set_shader_parameter("cloud_steps", int(SkyModel.CLOUD_STEPS[level]))
