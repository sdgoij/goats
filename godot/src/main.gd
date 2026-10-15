# The port's scene: the game. A local goat you drive, a herd mirrored from a host,
# and a world -- ground, meadow and sky -- derived rather than received.
#
# It owns no simulation of *anybody else's* goats: it joins the session named by
# `GOATSD_TICKET`, drains the bridge once a frame, and hands every world snapshot to
# the `Herd`, which places one real goat per bot the host is simulating (see
# `herd.gd`). Everything else is its own: the local goat (`player_goat.gd`, the one
# the keyboard is), the ground (`terrain_mesh.gd`), the meadow (`grass.gd` over
# `meadow.gd`) and the sky with its light (`sky.gd`).
#
# The one number that has to travel is the clock -- a session's `weather.world_time`
# sets the hour, and with no session the scene is its own host and the day advances
# at `TUNING.world.dayLength` (`world.js` `sceneFrame`) -- and the weather, which the
# same event carries because the host owns it. Where the scene is a client it also
# *publishes* its goat, about twenty times a second, so a raylib client or another
# Godot one sees it exactly as it sees theirs.
#
# The weather and the two celestial bodies are the last of the world to land, and both
# are stitched in here. Offline the weather is a *machine* (`weather.gd`) whose clock
# and easing `_advance` moves, and the wind, the grass's sway and the goat's own
# slowdown all come off it; in a session it only *mirrors* the host's values, because
# the host owns the weather. Either way the rain still falls locally -- a client is sent
# a *rate*, not a list of drops -- and the sun and the moon (`celestial.gd`) move,
# because both are derived from values on the wire rather than sent as events.
#
# Two modes, one scene:
#
#   * a game -- set `GOATSD_TICKET` and play with other people, or set nothing at all
#     and play alone;
#   * a probe -- also set `GOATS_PROBE=1` and it settles, reports the herd, and
#     exits non-zero if the mirror did not converge. `tools/interop.sh herd` runs it
#     against a real `goatsd`, which is what makes it a gate rather than a window.
#
# The ticket comes from the environment because the console and the menu are stage 6;
# there is no in-game way to paste one yet.
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
extends Node3D

## How long the mirror is given to converge before the probe reports. Long
## enough for the easing (`Herd.SMOOTH`) to close a snapshot's worth of gap, and
## long enough for the host's bots to actually start moving -- a herd that is
## standing still would let a broken mirror pass.
const PROBE_SETTLE := 8.0
## The gap the probe tolerates. A bot moves about 0.15 m between snapshots at
## 10 Hz, and the easing leaves a fraction of that, so anything near this is a
## mirror that is not tracking rather than one merely lagging.
const PROBE_TOLERANCE := 0.5
## The least motion the probe will accept as evidence that the mirror tracks a
## herd that moves rather than a herd that happens to be still. One centimetre
## between snapshots is far below a walking bot's step and far above jitter.
const PROBE_MOTION := 0.01
## The least relief the probe will accept under the herd. The spawn bowl is
## deliberately flat (`TUNING.terrain.flat` is 6 units), so a herd that has not
## wandered out of it would report ~0 and prove nothing about the terrain; the
## bots do wander out, and this is what says so.
const PROBE_RELIEF := 0.05

@onready var herd: Herd = $Herd
@onready var goat: PlayerGoat = $Goat
@onready var terrain: TerrainMesh = $Terrain
@onready var grass: Grass = $Grass
@onready var explosions: Explosions = $Explosions
@onready var celestial: Celestial = $Celestial
@onready var hud: Hud = $Ui/Hud
@onready var rain: Rain = $Ui/Rain
@onready var sun: DirectionalLight3D = $Sun
@onready var world_environment: WorldEnvironment = $WorldEnvironment

## The bridge is built in code, not in the scene. A GDExtension class named as a
## node type in a `.tscn` cannot be resolved while the import pass that registers
## it is still running, and a scene cached from such a pass silently loses the
## node -- `$NetBridge` comes back null and every frame fails on it. A script path
## and a `ClassDB.instantiate` always resolve.
var bridge: Object

## The camera's own state: an orbit the mouse drags and the arrow keys nudge, seeded
## from and clamped by `TUNING.camera`. The scene's `sceneFrame` owns the same three
## numbers and moves them the same way, and they matter more than they look: the
## scene's camera rides about three metres up (`TUNING.camera.dist` 5.2 at pitch
## 0.42) while its cloud slab hangs from `TUNING.sky.cloudBase` 5 to `cloudTop` 9.5
## -- so the eye is *under* the deck, and the sky shader's march is a function of
## that. From higher up the same slab is a band across the horizon instead of a
## canopy overhead.
var _cam_yaw := 0.7
var _cam_pitch := 0.42
var _cam_dist := 5.2
var _dragging := false
## The one-shot presses since the last frame, filled by `_unhandled_input` and
## consumed by `_process`. The scene's `press()` reads the same four keys once per
## frame; Godot delivers the press as an event, so it is held here until then.
var _jump_pressed := false
var _eat_pressed := false
var _sleep_pressed := false
var _restart_pressed := false

## The meadow: the eaten cells, their countdowns and the tufts a bite can reach.
var meadow := Meadow.new()

## The weather: offline this scene's own state machine, and in a session a mirror of
## the host's values (see `weather.gd`). The rain overlay draws its pool and
## `PlayerGoat` reads its rain and wind through `_weather_now`.
var weather := Weather.new()

## Whether the scene is in a session as a *client*. It is what the pose publishing
## hangs on, and its window is the wire's.
var _joined := false
## How often this scene publishes its goat -- `NET_POSE_RATE`, about twenty a
## second: the datagrams are unreliable by design and a lost one does not matter.
const POSE_INTERVAL := 0.05
var _pose_timer := 0.0

## The sky material and the world's clock, wind and weather, all of which `_advance`
## refreshes once a frame. `_hours` starts where the scene's own `worldTime` does.
var _sky_material: ShaderMaterial
var _hours := SkyDome.DEFAULT_HOUR
var _sky_time := 0.0
var _sway_time := 0.0
var _sky_light := 1.0
var _cloudiness := SkyDome.CLOUDINESS_CLEAR
var _wind_x := 0.0
var _wind_z := 0.0
var _wind_sway := 0.0
## The last `weather` the host sent, or empty while there is no session -- which is
## what decides whether the clock runs locally or follows the wire.
var _weather := {}
## The staging knobs: everything there is no UI for yet. The console and the menu are
## stage 6, so each of these is an environment variable, and a session's own values win,
## because the host owns the world.
##
##   `GOATS_HOUR`             pin the hour, for looking at a sky phase.
##   `GOATS_CLOUD`            pin the sky's cloudiness, for exercising the cloud march.
##                            The state machine still runs, so rain still comes and goes
##                            around it.
##   `GOATS_WEATHER=<state>`  pin the machine's state (`clear`, `cloudy`, `rain`,
##                            `clearing`), which `GOATS_CLOUD` cannot do -- it moves the
##                            sky but not the rain. A downpour has no UI either, and it
##                            is the one thing only a picture can judge (the overlay is
##                            drawn, not measured), so this is the knob that shows it.
##   `GOATS_CAM=yaw,pitch[,dist]`
##                            aim the camera. The two bodies sit on the light's line
##                            *behind* the boot camera (`TUNING.camera.yaw` 0.7), so a
##                            script cannot photograph one without this and a person
##                            would drag the mouse. Missing parts keep their defaults.
##   `GOATS_BOOM`             set off a bang beside the goat a moment into the run, so a
##                            bang and the hole it leaves can be *looked at* rather than
##                            measured. The one that changes the world rather than the
##                            view.
var _forced_hour := -1.0
var _forced_cloud := -1.0
var _boom := false
var _boom_frame := 0

var _probe := false
var _worlds := 0
var _last_bots := 0
## The largest distance any single bot covered between two snapshots, which is
## what tells a mirror that tracks a moving herd from one that agrees with a
## herd standing still.
var _max_step := 0.0
var _previous := {}
## Seconds since the first snapshot that carried a herd, or -1 until one does. It
## is deliberately not a plain timer: `goatsd` publishes half-built worlds while
## it loads its scene, and settling on one of those would measure nothing.
var _settle := -1.0

func _ready() -> void:
	_set_up_sky()
	# The devices need the goat they hurt and the meadow a trap has to land in; the
	# scene's own field is wired the same way (`explosions.js` reads the goat and
	# `EATEN` out of the module scope it shares with them).
	explosions.goat = goat
	explosions.meadow = meadow
	explosions.terrain = terrain
	# The scene's own field of view (`beginMode3D(..., 55)`); Godot's default is 75.
	var camera := $Camera3D as Camera3D
	camera.fov = 55.0
	_forced_hour = _environment_float("GOATS_HOUR", -1.0)
	_forced_cloud = _environment_float("GOATS_CLOUD", -1.0)
	_boom = not OS.get_environment("GOATS_BOOM").is_empty()
	if _forced_hour >= 0.0:
		_hours = _forced_hour
	# `GOATS_WEATHER` is a one-shot: `Weather.hold` leaves the machine *in* the state
	# (its targets are the current values), so nothing here has to remember it.
	var forced_weather := OS.get_environment("GOATS_WEATHER")
	if not forced_weather.is_empty():
		weather.hold(forced_weather)
	var forced_cam := OS.get_environment("GOATS_CAM")
	if not forced_cam.is_empty():
		var parts: PackedStringArray = forced_cam.split(",")
		if parts.size() >= 1 and parts[0].is_valid_float():
			_cam_yaw = parts[0].to_float()
		if parts.size() >= 2 and parts[1].is_valid_float():
			_cam_pitch = parts[1].to_float()
		if parts.size() >= 3 and parts[2].is_valid_float():
			_cam_dist = parts[2].to_float()

	var node := ClassDB.instantiate("NetBridge") as Node
	add_child(node)
	bridge = node

	_probe = not OS.get_environment("GOATS_PROBE").is_empty()
	var ticket := OS.get_environment("GOATSD_TICKET")
	if ticket.is_empty():
		# No ticket is the *normal* way to play. A session is optional -- the game's
		# own client boots into a solo world and only hosts or joins when it is asked
		# to -- and there is nothing here that needs one to run: the goat is yours,
		# the field builds itself from the seedless noise, and the sky runs its own
		# clock.
		#
		# The probe is the one case that needs a session, because what it measures is
		# a mirror of somebody else's herd, so it says so rather than sitting there
		# reporting nothing.
		if _probe:
			_report(["GOATS_PROBE is set but GOATSD_TICKET is not: the probe mirrors a session"])
			return
		print("offline: no GOATSD_TICKET, so there is no session to mirror")
		print("  play alone:         this, with WASD, shift to run, space to jump, E to eat")
		print("  watch a real herd:  godot/tools/interop.sh herd")
		print("  join a host:        set GOATSD_TICKET to its ticket")
		return
	print("join -> ", bridge.call("join", ticket, "godot"))
	# The scene is a *client* here, and a client is the one that publishes its goat: a
	# host's own goat is already local to its owns scene (`NetBridge::pose`).
	_joined = true

## Give the scene the scene's sky: a `shader_type sky` material on the
## `WorldEnvironment`, and the environment told that its ambient is the light's
## rather than the sky's.
##
## `REALTIME` and not a bake: the sun moves, the clouds drift and the clock runs, and
## a cached radiance would freeze all three. The ambient is a colour and not the sky
## because the scene's own ambient has a *floor* (`lighting.js` `LIGHT_AMBIENT`, 0.10
## at midnight) that a sky-derived one would not have, and the scene's night is dark
## rather than black.
func _set_up_sky() -> void:
	_sky_material = SkyDome.make_material()
	var environment: Environment = world_environment.environment
	environment.sky.sky_material = _sky_material
	environment.sky.process_mode = Sky.PROCESS_MODE_REALTIME
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR

func _process(delta: float) -> void:
	for line in bridge.call("poll_events"):
		_handle(String(line))

	# The ground, the fuses and the effects first, which is `sceneFrame`'s order: a
	# crater ages, a fuse runs out and a bang lands *before* the goat moves, so a goat
	# thrown this frame is thrown on the ground this frame.
	explosions.update(delta)
	# Walk onto something. The trigger is tested once per arrival rather than once per
	# frame -- the stamp is a half-metre bucket, so a goat standing still is one
	# compare -- and neither a sleeping goat nor a dead one is walking anywhere.
	if goat.mode != "sleep" and goat.mode != "dead":
		goat.trip_stamp = explosions.check_triggers(
			goat.px, goat.pz, goat.airborne(), goat.trip_stamp)

	# The goat: it is what the camera, the ground and the meadow are placed around,
	# and it is the only thing in this scene that decides anything.
	goat.step(delta, _controls(), _sky_light, _weather_now(), meadow)
	# The meadow is the host's in a session, so a client only mirrors it.
	meadow.update(delta, _weather.is_empty())
	_orbit(delta)

	# The ground rebuilds when its snapped anchor moves (`terrain.gd` /
	# `terrainEnsure`) and when something has blown a hole in it, and the grass is
	# recomputed every frame, because it sways and because the scene's meadow is a
	# function of where the goat is.
	if Craters.dirty:
		Craters.dirty = false
		terrain.refresh()
	var here := Vector3(goat.px, 0.0, goat.pz)
	terrain.follow(here.x, here.z)
	var camera := $Camera3D as Camera3D
	_place_camera(camera)
	_advance(delta, camera.global_position)
	grass.update(here, _sway_time, _wind_sway, meadow.eaten)
	# The two bodies and the rain, from the values `_advance` just settled: the sun and
	# the moon ride the light's own line, and the rain is screen space over everything.
	celestial.update(here.x, here.z, SkyDome.sun_dir(_hours), _cloudiness)
	rain.show_for(weather, _wind_x)
	_publish_pose(delta)
	hud.show_for(goat, _hours, _weather_now())
	_boom_if_asked()

	if _settle >= 0.0:
		_settle += delta
		if _settle >= PROBE_SETTLE:
			_settle = -99.0
			_probe_report()

## This frame's controls, in the form `PlayerGoat.step` wants. `sceneFrame` reads
## its keys the same way and combines them the same way: a held axis, a gait chosen
## by the modifiers, and the four presses.
func _controls() -> Dictionary:
	var move: int = 0
	if Input.is_physical_key_pressed(KEY_W):
		move += 1
	if Input.is_physical_key_pressed(KEY_S):
		move -= 1
	var turn: int = 0
	if Input.is_physical_key_pressed(KEY_A):
		turn += 1
	if Input.is_physical_key_pressed(KEY_D):
		turn -= 1
	var running: bool = Input.is_physical_key_pressed(KEY_SHIFT)
	var trotting: bool = Input.is_physical_key_pressed(KEY_CTRL)
	var gait: String = "walk"
	if running:
		gait = "run"
	elif trotting:
		gait = "trot"
	var controls := {
		"move": move,
		"turn": turn,
		"gait": gait,
		"jump": _jump_pressed,
		"eat": _eat_pressed,
		"sleep": _sleep_pressed,
		"restart": _restart_pressed,
	}
	_jump_pressed = false
	_eat_pressed = false
	_sleep_pressed = false
	_restart_pressed = false
	return controls

## The arrow keys as a camera fallback, and the clamps. `sceneFrame`'s own, with
## the same rates and the same two limits (`TUNING.camera.minDist`/`maxDist`, and a
## pitch that stops short of the poles so the up vector never degenerates).
func _orbit(delta: float) -> void:
	if Input.is_physical_key_pressed(KEY_LEFT):
		_cam_yaw += 1.6 * delta
	if Input.is_physical_key_pressed(KEY_RIGHT):
		_cam_yaw -= 1.6 * delta
	if Input.is_physical_key_pressed(KEY_UP):
		_cam_pitch += 1.0 * delta
	if Input.is_physical_key_pressed(KEY_DOWN):
		_cam_pitch -= 1.0 * delta
	_cam_pitch = clampf(_cam_pitch, 0.08, 1.35)
	_cam_dist = clampf(_cam_dist, 2.2, 12.0)

## Put the camera where the scene's own camera goes: an orbit of the goat, aimed at
## its shoulders. There is always a goat -- one you drive, offline or not -- so there
## is no case where the camera has nothing to orbit.
##
## The blast's knock moves the camera *and* what it looks at by the same offset, so
## the world shifts rather than the view swinging (`sceneFrame`).
func _place_camera(camera: Camera3D) -> void:
	var focus: Vector3 = goat.focus()
	var knock: Vector3 = explosions.shake_offset()
	camera.position = PlayerGoat.orbit_eye(focus, _cam_yaw, _cam_pitch, _cam_dist) + knock
	camera.look_at(focus + knock)

## Publish this goat to the session, about twenty times a second -- which is the rate
## `NetBridge::pose` documents, because the datagrams are unreliable by design and a
## lost one does not matter. Only a *client* does this: a host's own goat is already
## local to its own scene.
##
## The gait name is the goat's mode, which is the vocabulary the wire's `Gait` enum
## and the scene's own `net.js` both use.
func _publish_pose(delta: float) -> void:
	if not _joined:
		return
	_pose_timer += delta
	if _pose_timer < POSE_INTERVAL:
		return
	_pose_timer = 0.0
	bridge.call("pose", goat.px, goat.pz, goat.yaw, goat.phase, goat.speed, goat.mode,
		goat.py)

## The mouse: drag to orbit, wheel to zoom, and F11 for fullscreen. `sceneFrame`'s
## ratios, so the feel matches the thing being ported.
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index == MOUSE_BUTTON_LEFT:
			_dragging = button.pressed
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_UP:
			_cam_dist -= 0.4
		elif button.pressed and button.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_cam_dist += 0.4
	elif event is InputEventMouseMotion and _dragging:
		var motion := event as InputEventMouseMotion
		_cam_yaw -= motion.relative.x * 0.004
		_cam_pitch -= motion.relative.y * 0.004
	elif event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.physical_keycode:
			KEY_SPACE:
				_jump_pressed = true
			KEY_E:
				_eat_pressed = true
			KEY_Z:
				_sleep_pressed = true
			KEY_R:
				_restart_pressed = true
			KEY_C:
				# `weather.js`'s `C`: jump to the next state now, for previewing the cycle.
				# The scene gates it on `netWeatherLocal()` -- a client may not force the
				# host's weather -- and so does this.
				if _weather.is_empty():
					weather.force()
			KEY_F11:
				var full: bool = DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN
				DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if full \
					else DisplayServer.WINDOW_MODE_WINDOWED)

## Move the world's clock and its weather on by a frame, then push both where they
## belong: the sky at the camera. The grass is `_process`'s -- it follows the goat,
## which the clock does not.
##
## The clock is the one thing the wire decides. `weather.js` `applyWeatherState` sets
## `worldTime` from the snapshot and `sceneFrame` advances it only when
## `netWeatherLocal()` -- so a scene with a session follows the host's day, and a
## scene without one is its own host and runs the day at `TUNING.world.dayLength`.
## The wind follows the same split, through the same function (`updateWind`).
##
## The two phase clocks (`_sky_time` for the cloud drift, `_sway_time` for the grass's
## lean) run locally in both cases, which is what the scene does for the sky's and not
## quite for the grass's -- it advances `swayTime` only where `updateWind` runs, so a
## joiner's grass leans at a fixed phase and only the strength of the wind changes.
## That reads as a frozen wind rather than as a faithful mirror, so the port runs the
## clock and lets the *values* come from the wire.
func _advance(delta: float, camera: Vector3) -> void:
	_sky_time += delta
	_sway_time += delta
	if _weather.is_empty():
		# Offline (or hosting): the weather is ours. The machine walks its own clock and
		# eases toward the state it is in, and the wind is read off the cloudiness it
		# leaves behind -- `updateWind` reads `cloudiness`, so the two are one step.
		if _forced_hour < 0.0:
			_hours = SkyDome.mod24(_hours + delta / SkyDome.DAY_LENGTH * 24.0)
		weather.update(delta)
		var cloud: float = weather.cloudiness
		if _forced_cloud >= 0.0:
			cloud = _forced_cloud
		var gust: Dictionary = SkyDome.wind(_sway_time, cloud)
		_wind_x = gust["x"]
		_wind_z = gust["z"]
		_wind_sway = gust["sway"]
		_cloudiness = cloud
	else:
		# A client: the host owns the weather, so the machine mirrors its values and
		# keeps only the rain's own integration and this goat's effects.
		weather.apply_wire(_weather)
		_hours = float(_weather.get("world_time", _hours))
		_wind_x = float(_weather.get("wind_x", 0.0))
		_wind_z = float(_weather.get("wind_z", 0.0))
		_wind_sway = float(_weather.get("wind_sway", 0.0))
		_cloudiness = float(_weather.get("cloudiness", 0.0))

	# The rain falls whether or not there is a session: a client is sent the *rate* and
	# still has to move its own drops, which is what `weather.js` keeps `rainSeed`
	# separate for.
	weather.update_rain(delta, _wind_x)

	_sky_light = float(SkyDome.sample(_hours)["light"])
	SkyDome.apply(_sky_material, world_environment.environment, sun, camera, _hours,
		_sky_light, _cloudiness, _wind_x, _wind_z, _sky_time)

## This frame's weather, in the shape the goat and the HUD read it: the session's own
## snapshot in a session, and the local machine's values offline. It is the same
## dictionary `weather.js` `sceneWeatherState` puts on the wire, so offline the scene
## is its own host and the goat feels the rain it is standing in.
func _weather_now() -> Dictionary:
	if _weather.is_empty():
		return weather.values(_wind_x, _wind_z, _wind_sway, _hours)
	return _weather

## Set off the staging bang, if one was asked for. It lands beside the goat rather
## than under it, so both the hole and the goat are in shot.
func _boom_if_asked() -> void:
	if not _boom:
		return
	_boom_frame += 1
	if _boom_frame == 20:
		explosions.blast("mine", goat.px + 2.0, goat.pz, 0.417, 0)

## An environment variable as a float, or `fallback` when it is unset or not a number.
func _environment_float(name: String, fallback: float) -> float:
	var text: String = OS.get_environment(name)
	if text.is_empty() or not text.is_valid_float():
		return fallback
	return text.to_float()

func _handle(line: String) -> void:
	var event: Variant = JSON.parse_string(line)
	if not (event is Dictionary):
		return
	match String(event.get("type", "")):
		"session":
			# The seed the world is built from, sent once before anything else. The
			# device field is *derived* from it, so this is what puts this scene's mines
			# where the host's are without a word about where they are -- and the weather
			# stream too, which a host runs from this same seed (`sceneUseSeed`).
			var seed: int = int(event.get("seed", 0))
			explosions.use_seed(seed)
			weather.use_seed(seed)
		"welcome":
			print("welcome: ", event.get("name"))
		"world":
			# The weather and the meadow ride every world snapshot, not only the ones
			# that carry a herd: `goatsd` publishes half-built worlds while it loads its
			# scene, and the clock is as true in those as in any other.
			var weather: Variant = event.get("weather", null)
			if weather is Dictionary:
				_weather = weather
			var eaten: Variant = event.get("eaten", null)
			meadow.apply_wire(eaten)
			# The ground the host has cratered and the devices it has seen go off: state
			# rather than events, because a joiner has to see the world as it stands.
			Craters.apply_wire(event.get("craters", null))
			explosions.apply_spent(event.get("spent", null))
			var bots: Variant = event.get("bots", [])
			if bots is Array and bots.size() > 0:
				_measure_motion(bots)
				herd.apply(event)
				_worlds += 1
				_last_bots = bots.size()
				if _settle < 0.0:
					_settle = 0.0
		"notice", "error":
			print(String(event.get("type", "")), ": ", event.get("text"))
		_:
			pass

func _probe_report() -> void:
	var failures: Array[String] = []
	print("world snapshots: ", _worlds, ", mirroring ", _last_bots, " bot(s)")
	print("herd: ", herd.count(), " goat(s), ", herd.airborne_count(), " in the air")
	print("grounded gap: %.4f m, largest bot step %.4f m"
		% [herd.worst_gap(), _max_step])
	var ground: Array = herd.ground_range()
	print("ground under the herd: %.3f .. %.3f m" % [ground[0], ground[1]])
	var mark: Vector2 = terrain.anchor()
	print("terrain mesh: %d rebuild(s), anchored (%.0f, %.0f)"
		% [terrain.rebuilds, mark.x, mark.y])
	for line in herd.describe():
		print(line)

	if _worlds == 0:
		failures.append("no world snapshot carrying a herd arrived")
	if herd.count() != _last_bots:
		failures.append("the snapshot named %d bots and the mirror holds %d"
			% [_last_bots, herd.count()])
	if herd.worst_gap() > PROBE_TOLERANCE:
		failures.append("the grounded herd has not converged: worst gap %.4f m" % herd.worst_gap())
	# Agreeing with a herd that never moved would be a weaker thing than it
	# looks, so the probe insists the herd moved while it watched.
	if _max_step < PROBE_MOTION:
		failures.append("no bot moved more than %.4f m between snapshots" % PROBE_MOTION)
	# And agreeing with a herd that is standing on nothing would be weaker still:
	# the spawn bowl is flat, so this only says something because the bots wander
	# out of it.
	if ground[1] - ground[0] < PROBE_RELIEF:
		failures.append("the herd stands on ground that varies by only %.3f m"
			% (ground[1] - ground[0]))
	_report(failures, "the herd mirrors goatsd's bots, on Godot-drawn ground")

## The largest per-bot displacement between consecutive snapshots.
func _measure_motion(bots: Array) -> void:
	var current := {}
	for entry in bots:
		if not (entry is Dictionary):
			continue
		var index: int = int(entry.get("index", 0))
		var spot := Vector2(float(entry.get("x", 0.0)), float(entry.get("z", 0.0)))
		current[index] = spot
		if _previous.has(index):
			_max_step = maxf(_max_step, spot.distance_to(_previous[index]))
	_previous = current

## Report and exit. Used by the probe, and by a probe that was started without a
## session; a plain run without a ticket does not come here at all, because
## joining is optional (`_ready`).
func _report(failures: Array, ok_message: String = "") -> void:
	# Close the session and join its runtime thread before the process ends. The
	# bridge also does this when it leaves the tree, but a probe quits while the
	# tree is still up, so it says so explicitly.
	bridge.call("shutdown")
	if failures.is_empty():
		print("OK: ", ok_message)
		get_tree().quit(0)
		return
	# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it
	# flushes, so a failure written there is never seen.
	for failure in failures:
		print("FAIL: ", failure)
	get_tree().quit(1)
