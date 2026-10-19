# The local goat: `goat.js`'s gait state machine, movement and stats.
#
# This is the port's *player* -- the goat the person at the keyboard is. It is the
# first thing in the port that is a game rather than a mirror: everything before it
# drew a world somebody else's simulation had already decided, and this decides.
#
# The rules are transcribed from `sceneFrame` and its helpers, in its order, because
# the order is what they are: the yaw before the state machine, the state machine
# before the stats, the stats before the integration. Three things are worth naming
# up front:
#
#   * **The gait speeds are the model's own clips.** `walkSpeed` is
#     `stride / (duty * clipDuration)` (`model.js` `gaitSpeed`), so the goat's speed
#     is whatever would make its feet not slide -- which is why the numbers are read
#     off the loaded model rather than written down here. `verify_goat.gd` checks
#     them against the JavaScript's own arithmetic.
#   * **The goat faces local +X.** `px += cos(yaw) * move * speed * dt` and
#     `pz += -sin(yaw) * move * speed * dt` is a walk along local +X, and Godot's
#     `rotation.y` maps local +X to `(cos, -sin)` in the XZ plane -- the same
#     convention `herd.gd` uses for the mirrored goats, so a local goat and a
#     mirrored one turn the same way.
#   * **The camera is the scene's, not an orbit somebody invented.** `orbit_eye`
#     is `sceneFrame`'s three lines, and it is *here* rather than in `main.gd`
#     because the height it orbits is `goatBaseY` plus the 0.85 the scene aims at.
#
# Not ported, and each is a deliberate hole rather than an oversight: the collision
# between goats (`resolveGoatCollisions`) and the death's X-eye sprite (the model's own
# death clip carries it).
#
# Every local is annotated rather than inferred -- see the `:=` note in
# `terrain.gd`.
class_name PlayerGoat
extends Node3D

## The goat, complete with its rig and clips. The same model the herd mirrors.
const MODEL := preload("res://assets/goat_animated.glb")

## `TUNING.stats`, verbatim. Each is a `static var` rather than a `const` so the tuning tree
## can write it (`APIv1.md` section 4.10): the module still *owns* the number and every read
## site below is unchanged, so a write is the one thing that moves.
static var STATS_MAX: float = 100.0
static var ENERGY_DRAIN: Dictionary = {"idle": 0.4, "walk": 1.0, "trot": 2.0, "run": 4.0}
static var JUMP_ENERGY_COST: float = 2.0
static var SLEEP_ENERGY_RECOVER: float = 12.0
static var SLEEP_HEALTH_RECOVER: float = 2.0
static var IDLE_HEALTH_RECOVER: float = 0.1
static var EXHAUST_HEALTH_DRAIN: float = 3.0
static var RESTED_ENERGY: float = 20.0
static var AUTO_SLEEP_DELAY: float = 2.0

## `TUNING.movement.turnRate`, in rad/s.
static var TURN_RATE: float = 1.8

## `TUNING.gait`: metres of stride per cycle, and the share of the cycle a foot is
## on the ground. The speed is derived from these and the clip's duration.
static var GAIT: Dictionary = {
	"walk": {"stride": 0.40, "duty": 0.50},
	"trot": {"stride": 0.46, "duty": 0.50},
	"run": {"stride": 0.50, "duty": 0.34},
}

## `TUNING.world.dayLength`'s job here is the clock, which `main.gd` owns; what the
## goat needs from `world` is when the cold starts biting and how much.
static var NIGHT_DRAIN_MULT: float = 1.6
## `skyLight` below this counts as night (`updateStats`'s `skyLight < 0.25`).
const NIGHT_LIGHT := 0.25

## `TUNING.jump`: the cube fallback's hop, used when the model has no jump clip.
static var JUMP_FALLBACK_TIME: float = 0.6
## `TUNING.explosions.fling`: the arc's gravity and the ceiling on the pose's stretch.
## The gravity is several times life on purpose -- the scene's note is that it is
## 7.3 g, so the goat leaves and lands hard rather than floating.
const FLING_GRAVITY := -72.0
const FLING_MAX_FLIGHT := 2.5
## `food.js` `EAT_FALLBACK_TIME`: a cube-fallback meal's length.
const EAT_FALLBACK_TIME := 2.4
## `core.js` V_STRIDE / V_CYCLE: the cube fallback's stride and cycle, which is what
## a gait falls back to when the model has no clip for it.
const V_STRIDE := 0.20
const V_CYCLE := 0.70

## `TUNING.weather` / `TUNING.food.rainShelter`, for the two things the weather does
## to a goat that is ported: how fast it moves and how fast it tires. `windNorm` is the
## *sky's* leaf (`SkyModel.WIND_NORM`) rather than a second copy here, because `TUNING` has one
## owner per number and the sky is what derives the gust this normalises.
static var RAIN_SLOW: float = 0.28
static var WIND_SLOW: float = 0.07
static var RAIN_SHELTER: float = 0.6
static var WET_DRAIN: float = 0.65
static var WIND_DRAIN: float = 0.20

## The order the roles are tried in, which is `clipRole()`'s order: the modes that
## lock the pose first, then the gaits, then idle.
const ROLES := ["walk", "trot", "run", "jump", "sleep", "eat", "death", "flung", "idle"]

var px := 0.0
var pz := 0.0
var py := 0.0
var yaw := 0.0
var phase := 0.0
## `idle | walk | trot | run | jump | sleep | eat | dead`.
var mode := "idle"
var health := STATS_MAX
var energy := STATS_MAX
var exhausted := false
## 0..1. A full belly eases the rain's slowdown (`food.js`), and decays.
var satiety := 0.0
## This frame's ground speed, in m/s. The HUD reads it and so does the wire.
var speed := 0.0

var _anim: AnimationPlayer
## The model's clips by role, in variant order (`GoatIdle`, `GoatIdle2`, ...).
var _roles := {}
## Which variant each role is on. `cyclePlayerVariant` bumps one per settle.
var _variant := {}
var _playing := ""
## The model's own lowest point, negated, so its feet land on the ground.
var _ground_offset := 0.0

var _jump_time := 0.0
var _jump_speed := 0.0
var _jump_dir := 0
## The arc (M19c): a world-space velocity in absolute height, so a slope the goat
## crosses mid-air cannot drag it along, and `py` is derived from it.
var _fling_time := 0.0
var _fling_vx := 0.0
var _fling_vz := 0.0
var _fling_vy := 0.0
var _fling_y := 0.0
var _fling_flight := 0.0
## The device trigger stamp (`explosions.gd` `check_triggers`): a half-metre bucket
## with the airborne bit packed beside it, so a goat standing still is one compare.
var trip_stamp := 0
var _eat_time := 0.0
var _sleep_time := 0.0
var _death_time := 0.0
var _idle_timer := 0.0
var _last_mode := "idle"
## This frame's share of the goat's speed that the weather leaves it. It is a field
## rather than a parameter because `ground_speed` and `start_jump` -- two of the
## scene's own helpers -- read the weather without being handed it.
var _weather_speed_now := 1.0
## ...and this frame's shares that the *water* leaves it, which are the caller's because
## they are a function of where the goat is standing (`water.gd`'s own two factors).
## Both are 1 out of water, so dry ground is exactly the frame it has always been.
var _water_speed_now := 1.0
var _water_drain_now := 1.0

func _ready() -> void:
	ready_up()

## Build the model and index its clips. `_ready` calls it, and so does a gate: a
## `SceneTree` script that adds the node during `_initialize` never sees `_ready`,
## which is the same reason `terrain_mesh.gd` builds its material lazily.
func ready_up() -> void:
	if _anim != null:
		return
	var node: Node3D = MODEL.instantiate()
	add_child(node)
	_anim = _find_animation(node)
	_index_clips()
	_measure_ground_offset(node)
	_pose("idle", 0.0)

## The goat through the lit material or the plain one: `L` and the settings screen's `Light`
## (M25), which the scene reaches with `setModelShader`.
##
## The rig's materials are the **glTF's**, and the importer puts them on the *mesh resource*
## rather than on the node -- so every instantiated rig and every mirrored herd points at the same
## ones, and this one walk flips the goat, the herd's bodies and the mirrors together. That is
## what the scene's own per-model shader swap amounts to; only the bots' own coat materials are
## separate, and `Bots.set_lit` is theirs.
func set_lit(on: bool) -> void:
	var mesh_instance: MeshInstance3D = _find_mesh(self)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	for i in mesh_instance.mesh.get_surface_count():
		var material: BaseMaterial3D = mesh_instance.mesh.surface_get_material(i) as BaseMaterial3D
		if material != null:
			material.shading_mode = TerrainMesh.shading(on)

## The bleat gains `goat.js` fires with: one per situation, at the call site in the source
## rather than in the audio module, because the gain is the *situation's* -- a goat falling
## asleep is quieter than one being thrown.
const BLEAT_JUMP := 0.9
const BLEAT_FLING := 1.0
const BLEAT_SLEEP := 0.45
const BLEAT_WAKE := 0.7
const BLEAT_DIE := 1.0

## `goat.js` `playBleat`, as a seam: the scene hands this goat a `Callable` and this file never
## learns what is on the other end of it.
func _sound(gain: float) -> void:
	if bleat.is_valid():
		bleat.call(gain)

## Advance one frame. `controls` carries what the goat acts on:
##
##   `move` (int, -1..1), `turn` (int, -1..1), `gait` (String), and the four
##   *presses* this frame: `jump`, `eat`, `sleep`, `restart`.
##
## `weather` is the session's own snapshot, or the local machine's values offline
## (`main.gd` `_weather_now`); both carry `rain_amount` and `wind_sway`, which are what
## the rain uses to slow the goat and drain it faster, and a full belly takes the edge
## off both.
##
## `meadow` is what a bite reads and writes. It may be null -- the goat still walks.
##
## `trap` is a bite's device test, handed to `start_eat`; it may be invalid, and then a
## bite is the plain meal it always was. It is a `Callable` and not a device type for
## the reason `Meadow.nearest`'s filter is one -- see `start_eat`.
##
## `water` is the wading the frame's own field imposes, as the two factors `water.js`
## derives from it: `{ "speed": ..., "drain": ... }`, both 1 out of water. They are
## derived by the caller because they depend on where the goat is standing, which the
## field answers and this does not.
##
## `bite` is called with a `(cx, cz)` a meal actually took, and only then. It is what tells a
## session about the bite (`food.js`'s `netQueue({"type":"consume"})`), and it is a `Callable`
## for the same reason `trap` is: this file does not link against the network.
var bite: Callable = Callable()

## `bleat` is called with the gain the situation calls for, at the five moments `goat.js`
## bleats: a jump, a fling, falling asleep, waking, and dying. A `Callable` for the reason
## `bite` is one -- this file does not link against the audio either.
var bleat: Callable = Callable()
func step(delta: float, controls: Dictionary, sky_light: float, weather: Dictionary,
		meadow: Meadow, trap: Callable = Callable(), water: Dictionary = {}) -> void:
	var move: int = int(controls.get("move", 0))
	var turn: int = int(controls.get("turn", 0))
	var gait: String = String(controls.get("gait", "walk"))
	# An exhausted goat cannot run or trot: it is capped at a walk until it sleeps.
	if exhausted:
		gait = "walk"

	# The yaw comes first, and every mode but the three that lock it steers. A sleeping,
	# dead or eating goat does not turn -- a *flung* one does, which reads as "no
	# steering" because the arc's velocity is world-space: the model spins and the
	# flight does not change.
	if mode != "sleep" and mode != "dead" and mode != "eat":
		yaw += turn * TURN_RATE * delta

	# The state machine: jump, sleep, eat, fling and death lock the mode; everything
	# else follows the requested gait.
	if mode == "dead":
		if bool(controls.get("restart", false)):
			restart()
	elif mode == "sleep":
		# The water can arrive under a sleeping goat -- there is none yet -- and so
		# can a full belly, which is the third way out.
		if bool(controls.get("sleep", false)) or move != 0 or energy >= STATS_MAX:
			wake_up()
	elif mode == "jump":
		_jump_time += delta
		if _jump_time >= jump_duration():
			mode = gait if move != 0 else "idle"
	elif mode == "flung":
		# Not in charge until the feet touch: no jumping out of it, no eating. The
		# arc is advanced in `_integrate`.
		pass
	elif mode == "eat":
		_eat_time += delta
		if _eat_time >= eat_duration():
			mode = gait if move != 0 else "idle"
	elif bool(controls.get("eat", false)) and meadow != null:
		# A meal is only started on a tuft that is actually there.
		start_eat(meadow.nearest(px, pz), meadow, trap)
	elif bool(controls.get("sleep", false)):
		start_sleep()
	elif bool(controls.get("jump", false)):
		start_jump(move, gait)
	else:
		mode = gait if move != 0 else "idle"
		# Drop off on our own once exhausted and standing still.
		if exhausted and move == 0:
			_idle_timer += delta
			if _idle_timer >= AUTO_SLEEP_DELAY:
				start_sleep()
		else:
			_idle_timer = 0.0

	# The weather and the water, before anything reads the speed they decide. The keys are
	# the world snapshot's (`WeatherState` on the wire, which `weather.js`
	# `applyWeatherState` reads with the same names); the water's two are the caller's.
	_weather_speed_now = weather_speed(
		satiety, float(weather.get("rain_amount", 0.0)),
		float(weather.get("wind_sway", 0.0)))
	_water_speed_now = float(water.get("speed", 1.0))
	_water_drain_now = float(water.get("drain", 1.0))

	# The belly empties whatever the mode is doing (`food.js` `updateFood`).
	satiety = maxf(0.0, satiety - Meadow.SATIETY_DECAY * delta)
	if _update_stats(delta, sky_light, weather_drain(weather) * _water_drain_now) == "die":
		mode = "dead"
		_death_time = 0.0
		_sound(BLEAT_DIE)

	# The idle variant advances each time the goat settles into idle, so it cycles
	# through the idle clips instead of always doing the same one.
	if mode != _last_mode:
		if mode == "idle":
			cycle_variant("idle")
		_last_mode = mode

	speed = ground_speed()
	_integrate(delta, move, gait)
	_place()
	_pose_role()

## The goat's height above the world's origin: the ground under it plus whatever it
## is holding above that -- the flung arc's height, or nothing.
## `world.js` `goatBaseY`.
func base_y() -> float:
	return Terrain.height_at(px, pz) + py

## Whether the goat is over the ground rather than on it. The model's hop is the
## clip's root motion, so `py` stays 0 through a jump and the *mode* is what says
## airborne there; a flung goat owns its own height, so it is airborne by
## construction. `explosions.js` `goatAirborne`, minus the cube fallback -- the port
## always has the model.
func airborne() -> bool:
	return mode == "flung" or mode == "jump"

## Where the camera looks, and what `orbit_eye` orbits: the scene's `ty`. The 0.85
## is `sceneFrame`'s -- the goat's shoulders, not its feet.
func focus() -> Vector3:
	return Vector3(px, 0.85 + base_y(), pz)

## `sceneFrame`'s camera: an orbit of `dist` at `pitch` behind `yaw`, looking at the
## goat's focus. `TUNING.camera` supplies the starting yaw/pitch/distance and the
## clamps; the caller owns the state, because a camera is input and this is not.
static func orbit_eye(focus_point: Vector3, cam_yaw: float, cam_pitch: float,
		cam_dist: float) -> Vector3:
	var cp: float = cos(cam_pitch)
	return Vector3(
		focus_point.x + cam_dist * cp * sin(cam_yaw),
		focus_point.y + cam_dist * sin(cam_pitch),
		focus_point.z + cam_dist * cp * cos(cam_yaw))

## `weather.js` `weatherSpeedFor`: the share of its speed the weather leaves a goat.
## One out of the rain and the wind, so `clear` on dry ground is untouched.
static func weather_speed(belly: float, rain: float, wind_sway: float) -> float:
	if rain <= 0.0:
		return 1.0
	var shelter: float = RAIN_SLOW * (1.0 - RAIN_SHELTER * clampf(belly, 0.0, 1.0))
	var wind: float = WIND_SLOW * minf(1.0, wind_sway / SkyModel.WIND_NORM)
	return 1.0 - (shelter + wind) * rain

## `weather.js` `updateWeatherEffects`'s `weatherDrain`: how much faster a soaked goat
## tires. One when it is not raining, so the drain is the tuning's own number.
static func weather_drain(weather: Dictionary) -> float:
	var rain: float = float(weather.get("rain_amount", 0.0))
	if rain <= 0.0:
		return 1.0
	var wind: float = minf(1.0, float(weather.get("wind_sway", 0.0)) / SkyModel.WIND_NORM)
	return 1.0 + (WET_DRAIN + WIND_DRAIN * wind) * rain

## The speed of a gait, in m/s, from its stride, its duty and the clip's duration --
## `model.js` `gaitSpeed`. Returns 0 when the model has no clip for the role, which
## is what makes the caller fall back.
func gait_speed(role: String) -> float:
	var gait: Variant = GAIT.get(role, null)
	var length: float = clip_length(role)
	if gait == null or length <= 0.0:
		return 0.0
	return float(gait["stride"]) / (float(gait["duty"]) * length)

## `model.js` `walkSpeed` / `trotSpeed` / `runSpeed`, fallbacks and all.
func walk_speed() -> float:
	var derived: float = gait_speed("walk")
	if derived > 0.0:
		return derived
	return (2.0 * V_STRIDE) / V_CYCLE

func trot_speed() -> float:
	var derived: float = gait_speed("trot")
	if derived > 0.0:
		return derived
	return walk_speed() * 1.8

func run_speed() -> float:
	var derived: float = gait_speed("run")
	if derived > 0.0:
		return derived
	return walk_speed() * 3.5

## `goat.js` `groundSpeed`: nothing asleep or dead, the mode's gait otherwise, and the
## weather's and the water's shares of it -- both 1 on dry ground in the clear, so the
## frame is untouched until something is actually wrong with the ground or the sky.
func ground_speed() -> float:
	if mode == "sleep" or mode == "dead":
		return 0.0
	var base: float = walk_speed()
	if mode == "run":
		base = run_speed()
	elif mode == "trot":
		base = trot_speed()
	return base * _weather_speed_now * _water_speed_now

## A one-shot's length: the clip's own duration when the model has one, the scene's
## fallback when it does not.
func jump_duration() -> float:
	var length: float = clip_length("jump")
	return length if length > 0.0 else JUMP_FALLBACK_TIME

func eat_duration() -> float:
	var length: float = clip_length("eat")
	return length if length > 0.0 else EAT_FALLBACK_TIME

## The clip that poses the goat right now, by role. `goat.js` `clipRole`, whose
## shape is "the role the mode names, if the model has one, and the **walk** for any
## role it does not" -- the fallback is the walk and not the idle, and `idle` has a
## test of its own like every other mode.
##
## This function was wrong in the first version of this file in both halves at once:
## the walk test came *last* with no `mode` in it, so an idle goat posed the walk
## clip, and the fallback was `idle`. The gate did not see it because the oracle was
## transcribed from the port rather than from `goat.js`, and so shared the mistake --
## which is the same shape of hole `verify_sky.gd` documents about `updateLight`'s
## warmth, and the reason the oracle is now written from the source with the clip
## role in the frame line.
func clip_role() -> String:
	if mode == "dead" and has_role("death"):
		return "death"
	if mode == "sleep" and has_role("sleep"):
		return "sleep"
	if mode == "eat" and has_role("eat"):
		return "eat"
	# The arc (M19c): the flung clip when the model has one, the jump when it does
	# not. `explosions.gd` is what sets this mode -- a bang within reach calls
	# `start_fling`.
	if mode == "flung":
		return "flung" if has_role("flung") else "jump"
	if mode == "jump" and has_role("jump"):
		return "jump"
	if mode == "run" and has_role("run"):
		return "run"
	if mode == "trot" and has_role("trot"):
		return "trot"
	if mode == "idle" and has_role("idle"):
		return "idle"
	return "walk"

## The clip the model is actually playing, which is the pose on screen. It is what
## `clip_for(clip_role())` should be, and a probe reads it to tell a *rule* that is
## right from a *pose* that is wrong -- an idle goat playing the walk clip was both
## at once for the first version of `clip_role`.
func playing_clip() -> String:
	return _playing

## The current clip for a role, `""` when the model has none.
func clip_for(role: String) -> String:
	var names: PackedStringArray = clip_names(role)
	if names.is_empty():
		return ""
	var index: int = int(_variant.get(role, 0)) % names.size()
	return names[index]

## Every clip the model has for a role, in variant order -- and so every pose the
## role can cycle through. `GoatIdle`, `GoatIdle2`, `GoatIdle3` for `idle`. A
## re-exported model with a new variant is picked up rather than ignored.
func clip_names(role: String) -> PackedStringArray:
	var names: Variant = _roles.get(role, null)
	if names is PackedStringArray:
		return names
	return PackedStringArray()

## Every variant's length for a role, in the same order. It is the whole table
## rather than the current one because a cycled variant is a different *length* --
## `GoatJump` is 1.167 s and `GoatJump2` is 1.333 s -- and that length is how long a
## jump lasts, so a caller that wants to know has to see all of them.
func clip_durations(role: String) -> Array:
	var out: Array = []
	if _anim == null:
		return out
	for name in clip_names(role):
		var animation: Animation = _anim.get_animation(name)
		out.append(animation.length if animation != null else 0.0)
	return out

## The length of the role's *current* clip. `playerClip(role).duration`, so an idle
## variant with a different length really is a different length.
func clip_length(role: String) -> float:
	var clip: String = clip_for(role)
	if clip.is_empty() or _anim == null:
		return 0.0
	var animation: Animation = _anim.get_animation(clip)
	if animation == null:
		return 0.0
	return animation.length

## Whether the model has any clip for a role at all.
func has_role(role: String) -> bool:
	return not clip_names(role).is_empty()

## The loop length the phase is advanced by: the current clip's, or the cube
## fallback's cycle when there is none.
func loop_duration() -> float:
	var length: float = clip_length(clip_role())
	return length if length > 0.0 else V_CYCLE

## Bump a role's variant, so `cyclePlayerVariant`'s idle cycling works -- and so a
## second jump is `GoatJump2`, with its own length, rather than a repeat of the
## first.
func cycle_variant(role: String) -> void:
	var names: PackedStringArray = clip_names(role)
	if names.is_empty():
		return
	_variant[role] = (int(_variant.get(role, 0)) + 1) % names.size()

## Start a jump, freezing the horizontal speed for its duration and taking the
## energy up front. `goat.js` `startJump`.
func start_jump(move: int, gait: String) -> void:
	mode = "jump"
	cycle_variant("jump")
	_jump_time = 0.0
	_jump_dir = move
	var base: float = walk_speed()
	if gait == "run":
		base = run_speed()
	elif gait == "trot":
		base = trot_speed()
	_jump_speed = base * _weather_speed_now * _water_speed_now
	energy = maxf(0.0, energy - JUMP_ENERGY_COST)
	_sound(BLEAT_JUMP)

## Eat a tuft: turn onto it, take it out of the meadow, and bank what it gives.
##
## A *trapped* tuft gives nothing back. `food.js` `startEat`: the tuft is still gone,
## because the goat did eat a mine, but the bite is what sets the device off -- so the
## eat path needs one test, not a rewrite. That test reaches further than the walk-in
## trigger does (the eat range is 1.1 m, `mine.trigger` 0.6), which is why a bite needs
## a test of its own at all rather than trusting `check_triggers` to have caught it.
##
## `trap` is that test: a `Callable` taking `(cx, cz, x, z)` and answering whether there
## was a device to set off. It is a `Callable` and not an `Explosions` for the same
## reason `Meadow.nearest` takes a filter rather than reaching for one: this file does
## not link against `explosions.gd`. Give it none and the bite is the plain meal.
##
## A meal the belly is already nearly full of goes into the goat instead
## (`satedHeal`), read *before* the meal, because what decides is the state the goat
## ate in.
func start_eat(target: Dictionary, meadow: Meadow, trap: Callable = Callable()) -> bool:
	if target.is_empty():
		return false
	if meadow != null and not meadow.consume(int(target["cx"]), int(target["cz"])):
		return false
	# Face the tuft, so the head comes down where the grass actually was.
	yaw = atan2(-(float(target["z"]) - pz), float(target["x"]) - px)
	# `food.js` consumes the tuft and asks *after*: the order only decides what the goat
	# gets back, and both halves of the promise are that it gets nothing.
	var trapped: bool = trap.is_valid() and bool(trap.call(int(target["cx"]),
		int(target["cz"]), float(target["x"]), float(target["z"])))
	if not trapped:
		var heal: float = Meadow.sated_heal(satiety)
		energy = minf(STATS_MAX, energy + Meadow.EAT_ENERGY)
		satiety = minf(1.0, satiety + Meadow.EAT_SATIETY)
		health = minf(STATS_MAX, health + heal)
	mode = "eat"
	_eat_time = 0.0
	cycle_variant("eat")
	# In a session the meadow is the host's, so tell it about the bite; it comes back in the next
	# world snapshot, which replaces this optimistic one (`food.js` `startEat`'s own last line).
	if bite.is_valid():
		bite.call(int(target["cx"]), int(target["cz"]))
	return true

## `goat.js` `startSleep`. There is no water to refuse it here, so the only way it
## fails is not existing -- which is what the return value is for, so a console verb
## or a gate can tell.
func start_sleep() -> bool:
	mode = "sleep"
	cycle_variant("sleep")
	_sleep_time = 0.0
	_idle_timer = 0.0
	_sound(BLEAT_SLEEP)
	return true

## `goat.js` `restart`, which is also what a console `restart` does: a new life at
## the origin, full, on the ground.
func restart() -> void:
	health = STATS_MAX
	energy = STATS_MAX
	exhausted = false
	_idle_timer = 0.0
	_sleep_time = 0.0
	_death_time = 0.0
	px = 0.0
	pz = 0.0
	py = 0.0
	yaw = 0.0
	phase = 0.0
	satiety = 0.0          # a new life starts hungry
	mode = "idle"
	# A death (or a restart) mid-arc must not leave the next life hovering.
	_fling_time = 0.0
	_fling_vx = 0.0
	_fling_vz = 0.0
	_fling_vy = 0.0
	_fling_y = 0.0
	_fling_flight = 0.0
	trip_stamp = 0

## `goats.player.teleport(x, z)` (`APIv1.md` section 4.5). A *position*, not a move: the next
## `step` places the goat from here, so the simulation's own rules -- the ground under it, the
## water it is standing in -- apply from the new point rather than being bypassed. `mods.js`'s own
## write is these two assignments.
func teleport(x: float, z: float) -> void:
	px = x
	pz = z

## `goats.player.face(heading)`, in radians -- the goat's heading, which the next `step` turns from.
func face(heading: float) -> void:
	yaw = heading

## The goat's own weather factor, which the HUD's `slowed` term is read from (`weather.js`
## `updateWeatherEffects` reads `weatherSpeed`). It is this frame's, settled in `step`, and it
## belongs to the goat because the belly takes the edge off the rain and nothing else knows the
## belly.
func weather_speed_now() -> float:
	return _weather_speed_now

## Take a blast's impulse (M19c). The caller has already decided this goat is in
## range and scaled the impulse by the falloff; this is where the goat starts being
## flown. A second blast mid-arc *adds* to the arc rather than restarting it, which
## is what a chain reaction through a minefield should look like.
func start_fling(vx: float, vz: float, vy: float) -> void:
	if mode != "flung":
		_fling_y = base_y()          # the arc starts where the goat is
		_fling_time = 0.0
		mode = "flung"
		# `goat.js` bleats on the *entry* to the arc and not on a chain that adds to one: the
		# second blast of a cascade is not a second goat being thrown.
		_sound(BLEAT_FLING)
	_fling_vx += vx
	_fling_vz += vz
	_fling_vy += vy
	# The pose is stretched over the ballistic time the remaining upward impulse
	# implies, counted from the start of the arc, so the phase keeps rising towards 1
	# instead of jumping back.
	var air: float = 0.4
	if _fling_vy > 0.0 and FLING_GRAVITY < 0.0:
		air = (-2.0 * _fling_vy) / FLING_GRAVITY
	_fling_flight = clampf(_fling_time + air, 0.3, FLING_MAX_FLIGHT)

## How far through the arc the goat is, in `[0, 1]`. The pose is stretched over the
## flight with it, and it is the phase a peer is told.
func fling_progress() -> float:
	return minf(_fling_time / _fling_flight, 1.0)

## The goat's world position: the ground under it, the arc's height above that, and
## the model's own offset so its feet are on the ground rather than at its origin.
func _place() -> void:
	position = Vector3(px, base_y() + _ground_offset, pz)
	rotation.y = yaw

## `goat.js` `wakeUp`, and the console's `wake` verb: a sleeping goat stands up and
## bleats. It is public because the scene reaches it only through the input path, and a
## command (or a gate) needs a way in that is not a key. The mode guard is the *verb's*,
## which is `ctl.js`'s own split (`wake` answers `error not asleep` before calling this).
func wake_up() -> void:
	mode = "idle"
	_sleep_time = 0.0
	_sound(BLEAT_WAKE)

## `goat.js` `die`: the goat drops where it stands and plays its death clip. The console's
## `kill` uses it, and the four `_update_stats` returns of `"die"` reach the same state
## from `step` -- which is why there is one implementation and not two.
func die() -> void:
	mode = "dead"
	_death_time = 0.0
	_sound(BLEAT_DIE)

## `goat.js` `updateStats`: drain by mode, faster at night and in the rain; at zero
## energy the goat is exhausted and starts losing health; above `restedEnergy` and
## idle it gets some back. Returns `"die"` when the health runs out.
func _update_stats(delta: float, sky_light: float, drain_factor: float) -> String:
	if mode == "dead":
		_death_time += delta
		return "dead"
	if mode == "sleep":
		_sleep_time += delta
		energy = minf(STATS_MAX, energy + SLEEP_ENERGY_RECOVER * delta)
		health = minf(STATS_MAX, health + SLEEP_HEALTH_RECOVER * delta)
		return "sleep"
	var drain: float = float(ENERGY_DRAIN["idle"])
	if mode == "run":
		drain = float(ENERGY_DRAIN["run"])
	elif mode == "trot":
		drain = float(ENERGY_DRAIN["trot"])
	elif mode == "walk":
		drain = float(ENERGY_DRAIN["walk"])
	if sky_light < NIGHT_LIGHT:
		drain *= NIGHT_DRAIN_MULT     # cold nights burn energy faster
	drain *= drain_factor             # ...and so does being soaked
	energy = maxf(0.0, energy - drain * delta)
	if energy <= 0.0:
		exhausted = true
		health = maxf(0.0, health - EXHAUST_HEALTH_DRAIN * delta)
	else:
		exhausted = false
		if mode == "idle" and energy > RESTED_ENERGY:
			health = minf(STATS_MAX, health + IDLE_HEALTH_RECOVER * delta)
	return "die" if health <= 0.0 else "awake"

## One frame of movement, `sceneFrame`'s blocks in its order: the arc, the jump, the
## locked modes, then the gaits.
func _integrate(delta: float, move: int, gait: String) -> void:
	if mode == "flung":
		# The arc is integrated in *absolute* height with `py` derived from it, so a
		# slope the goat crosses mid-air cannot drag it along. The clip's own hop
		# rides on top of the arc, which is the placeholder's cost and not a rule.
		_fling_time += delta
		px += _fling_vx * delta
		pz += _fling_vz * delta
		_fling_vy += FLING_GRAVITY * delta
		_fling_y += _fling_vy * delta
		py = _fling_y - Terrain.height_at(px, pz)
		# Ground contact is what ends the flight, not the ballistic time: that is what
		# lands the goat on the ground it really meets, on a slope or beside a crater
		# wall. The model rests at 0.
		if _fling_vy <= 0.0 and py <= 0.0:
			py = 0.0
			_fling_vx = 0.0
			_fling_vz = 0.0
			_fling_vy = 0.0
			mode = gait if move != 0 else "idle"
		return
	if mode == "jump":
		# Horizontal travel continues at the speed frozen at take-off; the vertical
		# arc is the clip's own, so `py` stays at rest.
		if _jump_dir != 0:
			px += cos(yaw) * _jump_dir * _jump_speed * delta
			pz += -sin(yaw) * _jump_dir * _jump_speed * delta
	elif mode == "sleep" or mode == "dead" or mode == "eat":
		# A meal is posed from its own clock; the goat stays put.
		pass
	else:
		phase = fmod(phase + delta / loop_duration(), 1.0)
		if move != 0:
			px += cos(yaw) * move * speed * delta
			pz += -sin(yaw) * move * speed * delta
	py = 0.0

## The fraction through its clip this frame is posed at: the loop's own `phase` for a gait, and
## the one-shot's clamped fraction for a jump, a meal, a death or the arc -- the only thing that
## can pose a clip that is not a loop.
##
## `phase` stands still for the whole of a one-shot, so the *fraction* is the only number that
## means anything there -- which is why this is also what the wire carries (`net.js`
## `netPeerPhase`, published by `netMaybePublish`): sending the loop phase instead was a stale
## number, and a remote goat held one frozen pose right through the jump.
func one_shot_fraction() -> float:
	if mode == "flung":
		return fling_progress()
	if mode == "jump":
		return minf(_jump_time / jump_duration(), 1.0)
	if mode == "dead":
		return minf(_death_time / maxf(clip_length("death"), 0.001), 1.0)
	if mode == "eat":
		return minf(_eat_time / eat_duration(), 1.0)
	return phase

## Pose the goat for this frame: the loop's own phase for a gait, and the one-shot's
## clamped fraction for a jump, a meal or a death -- the only thing that can pose a
## clip that is not a loop.
func _pose_role() -> void:
	if mode == "flung":
		_pose("flung" if has_role("flung") else "jump", one_shot_fraction())
	elif mode == "dead":
		_pose("death", one_shot_fraction())
	elif mode == "eat":
		_pose("eat", one_shot_fraction())
	else:
		_pose(clip_role(), one_shot_fraction())

func _pose(role: String, fraction: float) -> void:
	var clip: String = clip_for(role)
	if clip == "" or _anim == null:
		return
	if clip != _playing:
		_playing = clip
		_anim.play(clip)
	# Where in the clip the goat stands is `Pose`'s, which is `model.js` `poseModelOn` -- the one
	# place the whole scene poses anything through, and the reason a dead goat keeps the pose it
	# fell in while it lies there.
	Pose.on(_anim, clip, fraction)

## Index the model's clips by role. The scene indexes its own CLIP table, built from
## the same model; here the table is the model's, so a re-export with a new variant
## is picked up rather than ignored.
func _index_clips() -> void:
	for role in ROLES:
		_roles[role] = PackedStringArray()
		_variant[role] = 0
	if _anim == null:
		return
	for name in _anim.get_animation_list():
		var text: String = String(name)
		for role in ROLES:
			var prefix: String = "Goat" + role.capitalize()
			if text.begins_with(prefix):
				_roles[role].append(text)
				break
	for role in ROLES:
		_roles[role] = _sorted_by_variant(_roles[role], "Goat" + role.capitalize())

## The variant number in a clip's name: `GoatIdle` is 0, `GoatIdle3` is 3. Anything
## that is not a number sorts last rather than being dropped.
static func _variant_index(name: String, prefix: String) -> int:
	var rest: String = name.substr(prefix.length())
	if rest.is_empty():
		return 0
	if not rest.is_valid_int():
		return 999
	return rest.to_int()

## Insertion sort by variant number, so `GoatIdle` is variant 0 and the cycling
## starts at the base clip whatever order the importer listed them in.
static func _sorted_by_variant(names: PackedStringArray, prefix: String) -> PackedStringArray:
	var out: PackedStringArray = names.duplicate()
	for i in range(1, out.size()):
		var name: String = out[i]
		var index: int = _variant_index(name, prefix)
		var j: int = i - 1
		while j >= 0 and _variant_index(out[j], prefix) > index:
			out[j + 1] = out[j]
			j -= 1
		out[j + 1] = name
	return out

## The model's own lowest point, negated. Godot's glTF import keeps the mesh's
## authored origin -- the feet -- at y = 0, so this is 0.0 for this model, which is
## what the client measures too (`loadGoat` logs `y 0.000..1.470`). Measuring it
## rather than assuming it is what keeps a re-exported model from sinking.
func _measure_ground_offset(node: Node3D) -> void:
	var mesh_instance: MeshInstance3D = _find_mesh(node)
	if mesh_instance == null or mesh_instance.mesh == null:
		return
	_ground_offset = -mesh_instance.mesh.get_aabb().position.y

func _find_animation(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for child in node.get_children():
		var found: AnimationPlayer = _find_animation(child)
		if found != null:
			return found
	return null

func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for child in node.get_children():
		var found: MeshInstance3D = _find_mesh(child)
		if found != null:
			return found
	return null
