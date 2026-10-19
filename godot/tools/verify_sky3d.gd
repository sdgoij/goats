# The Sky3D wiring gate: the addon is the scene's sky, and the port's clock drives it.
#
#   Godot --headless --path godot --script res://tools/verify_sky3d.gd
#
# The curve itself is `verify_sky.gd`'s subject. This is the hand-off: the
# `WorldEnvironment` node carries the Sky3D script, the addon built its sky material and
# both lights, its own clock is paused, `_apply_sky` writes the port's hours and sun/moon
# arc into it, the weather reaches its cloud covers, and the port's own disc meshes are
# out of the frame.
extends SceneTree

## Enough frames for `main._ready` and several `_process` passes to settle. `_ready`
## runs on the first frame, not during `_initialize` (the port's own note about
## `SceneTree.root`), so the clock is pinned at frame 1 and read a few frames later.
const FRAMES := 8

var _frames := 0

func _initialize() -> void:
	var scene: Node = load("res://scenes/herd.tscn").instantiate()
	root.add_child(scene)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		# Pin the clock and the cloud cover so the assertions below are exact rather
		# than a moving target. `_forced_hour` is the scene's own staging knob.
		var game: Node = root.get_node("Game")
		game.set("_forced_hour", 12.0)
		game.set("_hours", 12.0)
		game.set("_forced_cloud", 1.0)
		return false
	if _frames < FRAMES:
		return false

	var failures: Array[String] = []
	var main: Node = root.get_node("Game")
	var world: Node = main.get_node("WorldEnvironment")
	var celestial: Node3D = main.get_node("Celestial")
	var environment: Environment = world.environment
	var sun: DirectionalLight3D = world.sun
	var moon: DirectionalLight3D = world.moon
	var sky: Node = world.sky
	var tod: Node = world.tod

	if world.get_script().resource_path != "res://addons/sky_3d/src/Sky3D.gd":
		failures.append("WorldEnvironment does not carry the Sky3D script")
	if sun == null or moon == null:
		failures.append("Sky3D did not build its sun and moon lights")
	if sky == null or tod == null:
		failures.append("Sky3D did not build its SkyDome and TimeOfDay nodes")
	if environment == null or environment.sky == null \
			or environment.sky.sky_material == null:
		failures.append("Sky3D did not install its sky material")
	elif environment.background_mode != Environment.BG_SKY:
		failures.append("the environment is not drawing the sky")
	if environment != null and environment.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR:
		failures.append("the ambient is not the port's colour source")
	if environment != null and absf(environment.ambient_light_energy - 0.25) > 0.001:
		failures.append("the ambient energy is %.3f, not the dimmed 0.25"
			% environment.ambient_light_energy)
	if celestial.visible:
		failures.append("the port's own sun/moon discs are still in the frame")
	if tod != null and tod.game_time_enabled:
		failures.append("Sky3D's clock still advances itself")
	if main.get("sun") != sun:
		failures.append("main.gd does not point at Sky3D's sun")
	if main.get("sky3d") != world:
		failures.append("main.gd does not point at the Sky3D node")
	if world.fog_enabled:
		failures.append("Sky3D's screen-space fog is on in a scene with its own rain")

	if tod != null and absf(tod.current_time - 12.0) > 0.01:
		failures.append("Sky3D's clock is %.4f, not 12.0" % tod.current_time)

	# The addon's sun/moon setter uses 0 = zenith and an azimuth from +Z toward +X; the
	# port's `sun_dir` is a unit vector. This is the conversion `_apply_sky` makes.
	if sky != null:
		# The addon's dynamic-creation path runs `SkyDome._ready()` before the parent
		# assigns `environment`, so `_build_scene()` returns early and the cloud tick
		# later dereferences a null material. The scene declares the children to avoid
		# that; these assertions are what would catch it coming back.
		if not sky.is_scene_built:
			failures.append("SkyDome did not build its scene")
		if sky.sky_material == null:
			failures.append("SkyDome has no sky material")
		else:
			var shader_coverage: float = sky.sky_material.get_shader_parameter("cumulus_coverage")
			if absf(shader_coverage - 0.95) > 0.001:
				failures.append("the shader's cumulus coverage is %.4f, not 0.95"
					% shader_coverage)
		if sky.fog_visible:
			failures.append("Sky3D's screen-space fog mesh is visible")

		var direction: Vector3 = SkyModel.sun_dir(12.0)
		var wanted_altitude: float = acos(clampf(direction.y, -1.0, 1.0))
		var wanted_azimuth: float = atan2(direction.x, direction.z)
		if absf(sky.sun_altitude - wanted_altitude) > 0.001:
			failures.append("sun altitude is %.4f, not %.4f"
				% [sky.sun_altitude, wanted_altitude])
		if absf(wrapf(sky.sun_azimuth - wanted_azimuth, -PI, PI)) > 0.001:
			failures.append("sun azimuth is %.4f, not %.4f"
				% [sky.sun_azimuth, wanted_azimuth])
		if absf(sky.cumulus_coverage - 0.95) > 0.001:
			failures.append("overcast cumulus coverage is %.4f, not 0.95"
				% sky.cumulus_coverage)
		if absf(sky.cirrus_coverage - SkyModel.cirrus_of(1.0)) > 0.001:
			failures.append("overcast cirrus coverage is %.4f, not %.4f"
				% [sky.cirrus_coverage, SkyModel.cirrus_of(1.0)])

	print("sky material: ", environment.sky.sky_material if environment.sky != null else null)
	print("sun: ", sun, ", moon: ", moon)
	print("clock: %.4f h, sun altitude %.4f, azimuth %.4f"
		% [tod.current_time if tod != null else NAN,
			sky.sun_altitude if sky != null else NAN,
			sky.sun_azimuth if sky != null else NAN])
	print("coverage: cumulus %.4f, cirrus %.4f"
		% [sky.cumulus_coverage if sky != null else NAN,
			sky.cirrus_coverage if sky != null else NAN])

	if failures.is_empty():
		print("OK: Sky3D owns the scene's sky, its lights follow the port's clock, and the old discs are out of the frame")
		quit(0)
	else:
		for failure in failures:
			print("FAIL: ", failure)
		quit(1)
	return true
