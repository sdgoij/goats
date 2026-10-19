# The sun and the moon: `world.js`'s `drawCelestial` (M2), the two spheres on the
# light's own line.
#
# The placement is the whole of the rule and it is centralised in one static so the
# draw and a gate read the same numbers (`celestialPlacement`, `celestialCover`) --
# the scene says as much, and it is why this is a `static func` on a node rather than
# buried in `update`.
#
# Two things about the port are the port's own. The *look* is Godot's: a `SphereMesh`
# lit by a dedicated directional light for the moon's terminator, rather than the
# scene's celestial shader with its own `sunDir` uniform. And the bodies are drawn in
# **one** sky pass, so a body is dimmed by the weather's cover (`celestialCover`, the
# scene's own mitigation) but not *per-pixel occluded* by a cloud crossing it -- the
# scene draws them between its two sky layers to get that, and the port's sky is one
# pass. What is exact is where each body is, how big, what tint and how opaque.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name Celestial
extends Node3D

## `world.js` `CELESTIAL_R` and the two discs' radii: a body sits 600 units out, which
## is what makes a walk across the meadow move it about a degree.
const R := 600.0
const SUN_RADIUS := 13.6
const MOON_RADIUS := 12.9
## `SUN_TINT` / `MOON_TINT`.
const SUN_TINT := Vector3(255.0, 246.0, 214.0)
const MOON_TINT := Vector3(238.0, 234.0, 222.0)
## `CELESTIAL_GLARE` and `CELESTIAL_HALO`: the tight glare on the disc and the wide
## faint halo under it, both as multiples of the disc's radius.
const GLARE := 5.2
const HALO := 11.0
## `CELESTIAL_CLOUD_FADE` and `CELESTIAL_HORIZON`: how much of a body the weather
## takes, and the elevation (as a sine) over which one fades out at the horizon.
const CLOUD_FADE := 0.55
const HORIZON := 0.05
## `world.js` `moonTex` is a 128x64 cratered disc, generated at boot.
const MOON_W := 128
const MOON_H := 64

## The body layer: the moon is lit by its own light, which only this layer sees, so
## the scene's day/night flip of the main light does not leave the moon dark.
const MOON_LAYER := 2

var _sun: MeshInstance3D
var _moon: MeshInstance3D
var _sun_glare: Sprite3D
var _sun_halo: Sprite3D
var _moon_light: DirectionalLight3D

func _ready() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 48
	sphere.rings = 24

	var sun_material := StandardMaterial3D.new()
	sun_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sun_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sun_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_sun = MeshInstance3D.new()
	_sun.mesh = sphere
	_sun.material_override = sun_material
	_sun.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_sun)

	# The moon is *lit* -- by the sun, always, even at night, which is why it has a
	# light of its own rather than the scene's (`world.js`: the moon's phase is set by
	# the sun even when the scene's light has flipped to the moon).
	var moon_material := StandardMaterial3D.new()
	moon_material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	moon_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	moon_material.albedo_texture = _moon_texture()
	moon_material.roughness = 1.0
	moon_material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	_moon = MeshInstance3D.new()
	_moon.mesh = sphere
	_moon.material_override = moon_material
	_moon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_moon.layers = MOON_LAYER
	add_child(_moon)

	_moon_light = DirectionalLight3D.new()
	_moon_light.light_cull_mask = MOON_LAYER
	_moon_light.light_energy = 0.9
	_moon_light.shadow_enabled = false
	add_child(_moon_light)

	# The glare: two additive billboards, because one reads as a bright circle rather
	# than as a sun. Only the sun has them (`drawCelestialBody`'s `glare` is 0 on the
	# moon).
	var glow: Texture2D = _glow_texture()
	_sun_halo = _make_glare(glow)
	_sun_glare = _make_glare(glow)

## Where a body is and how opaque it is, from the sun's own direction and which end of
## the line it sits on (`side` 1 is the sun, -1 the moon). `world.js`
## `celestialPlacement`, verbatim.
static func placement(side: float, coverage: float, sun_dir: Vector3, px: float,
		pz: float) -> Dictionary:
	var up: float = sun_dir.y * side
	var fade: float = 0.0
	if up > 0.0:
		fade = minf(1.0, up / HORIZON)
	return {
		"x": px + sun_dir.x * side * R,
		"y": up * R,
		"z": pz + sun_dir.z * side * R,
		"elevation": up,
		"alpha": round(255.0 * coverage * fade),
	}

## What the weather takes off a body, 0..1: a disc glows dimmer through a gap than it
## does in the clear. `world.js` `celestialCover`.
static func cover(cloudiness: float) -> float:
	return 1.0 - CLOUD_FADE * cloudiness

## The tint a body is drawn with, and how warm it is. A low disc reddens, the way the
## sky's own glow does; only the *sun* warms (`shaded` 0 is the body that is the
## light) and a setting moon stays grey. `drawCelestialBody`'s three lines.
static func tint_of(tint: Vector3, elevation: float, shaded: bool) -> Vector3:
	var warm: float = 1.0
	if not shaded:
		warm = minf(1.0, maxf(0.0, elevation / 0.30))
	# `tint[0]` crosses unrounded -- it is already a whole byte -- while the other two
	# are `Math.round`ed, and the difference is what the gate compares.
	return Vector3(tint.x, roundf(tint.y * (0.78 + 0.22 * warm)),
		roundf(tint.z * (0.42 + 0.58 * warm)))

## Aim both bodies and the glare for one frame.
func update(px: float, pz: float, sun_dir: Vector3, cloudiness: float) -> void:
	var c: float = cover(cloudiness)
	_place(_sun, 1.0, SUN_RADIUS, SUN_TINT, false, c, sun_dir, px, pz)
	_place(_moon, -1.0, MOON_RADIUS, MOON_TINT, true, c, sun_dir, px, pz)
	# The moon's own light comes from the sun, which is `sun_dir` whichever body is up.
	if _moon_light != null:
		_moon_light.global_position = Vector3.ZERO
		_moon_light.look_at(-sun_dir)

## One body, and the sun's glare over it.
func _place(body: MeshInstance3D, side: float, radius: float, tint: Vector3,
		shaded: bool, c: float, sun_dir: Vector3, px: float, pz: float) -> void:
	if body == null:
		return
	var spot: Dictionary = placement(side, c, sun_dir, px, pz)
	var alpha: float = float(spot["alpha"])
	if alpha <= 2.0:
		body.visible = false
		if side > 0.0:
			_hide_glare()
		return
	body.visible = true
	var colour: Vector3 = tint_of(tint, float(spot["elevation"]), shaded)
	body.position = Vector3(float(spot["x"]), float(spot["y"]), float(spot["z"]))
	body.scale = Vector3.ONE * radius
	var material: StandardMaterial3D = body.material_override
	material.albedo_color = Color(colour.x / 255.0, colour.y / 255.0, colour.z / 255.0,
		alpha / 255.0)
	if side > 0.0:
		_place_glare(radius, colour, alpha, body.position)

func _make_glare(texture: Texture2D) -> Sprite3D:
	var sprite := Sprite3D.new()
	sprite.texture = texture
	sprite.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sprite.material_override = _additive(texture)
	sprite.visible = false
	add_child(sprite)
	return sprite

## The wide halo under the tight one, at `drawCelestialBody`'s two alphas.
func _place_glare(radius: float, colour: Vector3, alpha: float, at: Vector3) -> void:
	_sun_halo.visible = true
	_sun_halo.position = at
	_sun_halo.pixel_size = radius * HALO / float(_sun_halo.texture.get_width())
	_sun_halo.modulate = Color(colour.x / 255.0, colour.y / 255.0, colour.z / 255.0,
		alpha / 255.0 * 0.10)
	_sun_glare.visible = true
	_sun_glare.position = at
	_sun_glare.pixel_size = radius * GLARE / float(_sun_glare.texture.get_width())
	_sun_glare.modulate = Color(colour.x / 255.0, colour.y / 255.0, colour.z / 255.0,
		alpha / 255.0 * 0.35)

func _hide_glare() -> void:
	if _sun_halo != null:
		_sun_halo.visible = false
	if _sun_glare != null:
		_sun_glare.visible = false

func _additive(texture: Texture2D) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.albedo_texture = texture
	return material

## A radial gradient: the one sprite that cannot look wrong however the camera turns.
func _glow_texture() -> ImageTexture:
	var size := 64
	var image := Image.create_empty(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u: float = (float(x) + 0.5) / float(size) - 0.5
			var v: float = (float(y) + 0.5) / float(size) - 0.5
			var d: float = sqrt(u * u + v * v) / 0.5
			var alpha: float = 0.0
			if d < 1.0:
				var falloff: float = 1.0 - d
				alpha = falloff * falloff * falloff
			image.set_pixel(x, y, Color(1.0, 1.0, 1.0, clampf(alpha, 0.0, 1.0)))
	return ImageTexture.create_from_image(image)

## The moon's disc: a mottled grey with craters, from `world.js` `makeSkyTextures`'s
## own draws (46 craters, `hash` at four strides) and the `u` wrap that keeps one
## round on a sphere. The *shading* inside a crater is the port's -- the scene's curve
## is not transcribed -- so this is the moon's texture, not its rule.
func _moon_texture() -> ImageTexture:
	var craters: Array = []
	for i in 46:
		craters.append({
			"u": Terrain.value_hash(float(i) * 3.7),
			"v": 0.12 + Terrain.value_hash(float(i) * 9.1) * 0.76,
			"r": 0.018 + Terrain.value_hash(float(i) * 5.3) * 0.055,
			"deep": 0.35 + Terrain.value_hash(float(i) * 7.7) * 0.65,
		})
	var image := Image.create_empty(MOON_W, MOON_H, false, Image.FORMAT_RGB8)
	for y in MOON_H:
		for x in MOON_W:
			var u: float = (float(x) + 0.5) / float(MOON_W)
			var v: float = (float(y) + 0.5) / float(MOON_H)
			# A little mottling, so the surface is not a flat grey.
			var shade: float = 0.88 + 0.12 * Terrain.value_hash(float(x) * 0.31 + float(y) * 1.7)
			for crater: Dictionary in craters:
				var du: float = u - float(crater["u"])
				if du > 0.5:
					du -= 1.0
				if du < -0.5:
					du += 1.0
				# `v` spans half the angular range `u` does, so a crater only comes out
				# round on the sphere when the v distance is halved with it.
				var dv: float = (v - float(crater["v"])) * 0.5
				var d: float = sqrt(du * du + dv * dv) / float(crater["r"])
				if d < 1.0:
					shade -= float(crater["deep"]) * (1.0 - d) * 0.45
			var value: float = clampf(shade, 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value * 0.98))
	return ImageTexture.create_from_image(image)
