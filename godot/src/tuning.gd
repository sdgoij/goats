# The tuning tree (`APIv1.md` section 4.10): the game's constants, gathered into the dotted-path
# shape a mod reads and writes through `goats.tuning`.
#
# The scene's constants are `static var`s on the modules that own them, and this file does two
# things with them. It **gathers** them into the API's one address space -- `stats.energyDrain.run`
# is `PlayerGoat.ENERGY_DRAIN["run"]`, `explosions.blast.lift` is `Explosions.BLAST_LIFT` -- so
# `goats.tuning.get` reads exactly the number the simulation reads and never a second copy that
# could drift from it. And it **routes a write back to the owner**, so `goats.tuning.set` moves the
# one number both the tree and the simulation read.
#
# That is the whole reason the leaves are `static var`s rather than `const`s: a `const` cannot be
# written, and a parallel copy that *could* would be the drift this file exists to prevent. Read
# sites are unchanged -- `PlayerGoat` still reads `STATS_MAX` -- because a `static var` is read
# exactly like a `const`; only the declaration keyword and the `set` path are new. A field is
# reached by name through `Object.get`/`set` on the owner's `GDScript`, which is the one place the
# tree touches reflection, and the gate holds every path in `_leaves()` against its owner so a
# typo'd field name is a failure rather than a silently-ignored write.
#
# **The tree is a subset, and an absent path is an error.** The port deliberately did not port the
# JavaScript client's model *fallbacks* (`PORT.md` section 5), and a few leaves live in a shader
# rather than in GDScript. Those are left out rather than guessed at, and both `get` and `set` on
# one answer the same "unknown path" a typo does -- which is `APIv1.md` section 4.10's own contract,
# so a mod cannot tell a missing leaf from a misspelling, and neither case is ever answered with a
# wrong number. What is absent, and why:
#
#   * `stats.deadEyeFraction`, `jump.fallbackHeight`/`fallbackTrotMult`/`fallbackRunMult` -- the
#     cube-goat fallback, which the port has no build without.
#   * `weather.cloudDrift` -- the port's clouds drift off `sky.speed` and the shader's own marcher.
#   * `water.shore`, `water.fresnel` -- uniforms of `water.gdshader`, quoted nowhere in GDScript.
#   * `explosions.enabled`, `explosions.mine.tell`, `explosions.crater.scorch`/`scorchRange`,
#     `explosions.fx.*.cols`/`cell` -- the port's devices have no off switch, its mines are never
#     drawn as a tell, and its bang's art is generated at boot rather than from an atlas.
#   * `lighting` -- Godot's own `DirectionalLight3D` shadow settings, which the scene never
#     overrides, so the port has no equivalent numbers to report.
#   * `world.timeFast` -- the JavaScript client's `T` key; the port has no fast-forward.
#
# **Three leaves are the scene's, not a module's.** `herd.count` is the herd's size, and
# `water.enabled` / `water.reflection` are the water system's switch and the reflection tier -- live
# values on the scene, not constants. The scene registers them (`register_live`) so the tree still
# addresses them as leaves, with a getter that reads the scene and a setter that writes it in the
# scene's own way (resizing the herd, waking the water).
#
# **A write is validated against the value it replaces** (`tuningCoerce`, transcribed): a number
# stays finite and is rounded or clamped where the leaf says so, an array stays an array (`herd.spec`
# may not empty, `sky.steps` may not change length), and a branch is not a leaf. Every accepted
# write is recorded in `_changed`, which the scene drains once a frame and hands to the mod runtime
# as the `"tuning"` event (`APIv1.md` section 4.2) -- *deferred* rather than fired here, because a
# write happens inside a mod's own JavaScript where the extension is borrowed, the same reason the
# `"blast"` event is said by the frame and not by the bang.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Tuning
extends RefCounted

## The camera's boot values and limits (`main.gd`'s `_orbit`, `cmd_set_camera`,
## `cmd_camera_reset`). The five the tree addresses are `static var`s -- a mod may aim the reset
## pose -- while the two pitch limits the API's tree does not name stay `const`.
static var CAMERA_YAW: float = 0.7
static var CAMERA_PITCH: float = 0.42
static var CAMERA_DIST: float = 5.2
static var CAMERA_MIN_DIST: float = 2.2
static var CAMERA_MAX_DIST: float = 12.0
const CAMERA_MIN_PITCH := 0.08
const CAMERA_MAX_PITCH := 1.35

## Leaves that must stay whole numbers (`tuningCoerce`'s `TUNING_INT`, restricted to the leaves this
## client has). Integer-ness is explicit rather than inferred: a default of `2.0` is just a number,
## and a mod may legitimately want `2.5` for a duration.
const INT := {
	"herd.count": true,
	"explosions.relocate.tries": true,
	"explosions.crater.max": true,
	"explosions.maxActive": true,
	"explosions.chainDepth": true,
	"explosions.fx.debris.count": true,
}

## Bounds, listed only where the game needs one (`tuningCoerce`'s `TUNING_CLAMP`, restricted to the
## leaves this client has). Each value is `[least, most]`. `herd.count`'s ceiling is the herd's own
## `Bots.MAX_HERD` rather than a second `100`, so the clamp and the resize cannot disagree.
const CLAMP := {
	"herd.count": [0.0, Bots.MAX_HERD],
	"herd.deathLinger": [0.5, 120.0],
	"herd.botReleaseLanding": [0.0, 1.0],
	"herd.botReleaseAir": [0.0, 1.0],
	"food.fullBelly": [0.0, 1.0],
	"food.fullBellyHeal": [0.0, 100.0],
	"camera.minDist": [0.1, 1000.0],
	"camera.maxDist": [0.1, 1000.0],
	# The captured-bird flight model's own bounds, `core.js` `TUNING_CLAMP`'s flight half. The
	# crate validates again when the scene configures it, so these are the console/mods' view
	# rather than the only guard; ordering `minSpeed`/`maxSpeed` is the crate's job.
	"flight.takeoffLift": [0.0, 50.0],
	"flight.takeoffPitch": [-1.4, 1.4],
	"flight.takeoffEnergy": [0.0, 100.0],
	"flight.speed": [0.0, 100.0],
	"flight.minSpeed": [0.0, 100.0],
	"flight.maxSpeed": [0.0, 100.0],
	"flight.pitchMax": [0.0, 1.4],
	"flight.bankMax": [0.0, 1.4],
	"flight.flapCooldown": [0.0, 10.0],
	"flight.flapEnergy": [0.0, 100.0],
	"flight.ceiling": [1.0, 1000.0],
	"flight.gravity": [-200.0, -0.1],
	"flight.safeFall": [0.0, 200.0],
	"flight.fallDamage": [0.0, 100.0],
	"flight.fallHealthFloor": [0.0, 100.0],
	"explosions.mine.density": [0.0, 0.1],
	"explosions.relocate.min": [0.0, 60.0],
	"explosions.relocate.max": [0.0, 60.0],
	"explosions.relocate.tries": [1.0, 64.0],
	"explosions.blast.radius": [0.0, 12.0],
	"explosions.blast.damage": [0.0, 100.0],
	"explosions.blast.healthFloor": [0.0, 100.0],
	"explosions.blast.push": [0.0, 40.0],
	"explosions.blast.lift": [0.0, 40.0],
	"explosions.maxActive": [0.0, 64.0],
	"explosions.chainDepth": [0.0, 2.0],
	"explosions.crater.radius": [0.0, 12.0],
	"explosions.crater.depth": [0.0, 4.0],
	"explosions.crater.lip": [0.0, 2.0],
	"explosions.crater.heal": [2.0, 3600.0],
	"explosions.crater.max": [0.0, 64.0],
	"explosions.flash.time": [0.0, 3.0],
	"explosions.flash.energy": [0.0, 8.0],
	"explosions.flash.lift": [0.0, 6.0],
	"explosions.fling.pivot": [0.0, 2.0],
	"explosions.fx.blast.time": [0.0, 10.0],
	"explosions.fx.blast.scale": [0.0, 40.0],
	"explosions.fx.blast.lift": [0.0, 20.0],
	"explosions.fx.smoke.time": [0.0, 10.0],
	"explosions.fx.smoke.scale": [0.0, 40.0],
	"explosions.fx.smoke.lift": [0.0, 20.0],
	"explosions.fx.debris.count": [0.0, 32.0],
	"explosions.fx.debris.time": [0.0, 10.0],
	"explosions.fx.debris.speed": [0.0, 60.0],
	"explosions.fx.debris.up": [0.0, 60.0],
	"explosions.fx.debris.gravity": [0.0, 120.0],
	"explosions.fx.debris.size": [0.0, 2.0],
	"explosions.shake.energy": [0.0, 2.0],
	"explosions.shake.range": [0.0, 100.0],
	"explosions.shake.decay": [0.0, 20.0],
	"explosions.shake.speed": [0.0, 80.0],
	"explosions.pulse.decay": [0.0, 20.0],
	"explosions.pulse.damage": [0.0, 100.0],
	"water.fill": [0.0, 1.0],
	"water.low": [-8.0, 8.0],
	"water.high": [-8.0, 8.0],
	"water.seep": [0.0, 0.99],
	"water.wetDown": [0.0, 900.0],
	"water.maxDepth": [0.0, 8.0],
	"water.wave.height": [0.0, 1.0],
	"water.wave.scale": [0.05, 8.0],
	"water.wave.speed": [0.0, 20.0],
	"water.wave.wind": [0.0, 1.0],
	"water.drag": [0.0, 1.0],
	"water.dragEnergy": [0.0, 2.0],
	"water.enabled": [0.0, 1.0],
	"water.reflection": [0.0, 2.0],
}

## `{path: [owner, field, keys]}`: where every *static* leaf lives. `owner` is the module's
## `GDScript` (a `class_name`), `field` the `static var` on it, and `keys` the path into that var's
## value when the leaf is a member of a dictionary the module holds (`stats.energyDrain.run` is
## `PlayerGoat.ENERGY_DRAIN["run"]`). Built once, lazily -- the owner classes are read at call time
## rather than in a static initialiser, so the tree never introduces a load-order dependency
## between itself and the modules.
static var _leaves_cache: Dictionary = {}

## `{path: {"get": Callable, "set": Callable}}`: the three leaves the *scene* owns. Registered at
## boot; read and written through the same leaf address space as everything else.
static var _live: Dictionary = {}

## The tree's own cache, invalidated whenever a write lands, so `tree()` rebuilds at most once
## between writes rather than once per frame.
static var _tree_cache: Dictionary = {}

## Every accepted write since the last `take_changed`, as `[path, value]` pairs. The scene drains
## this once a frame and says each as the `"tuning"` event (`APIv1.md` section 4.2).
static var _changed: Array = []

## Bumped by every accepted write, so the browser's Tuning tab can tell a stale read from a
## current one (`mods.gd`'s `_web_tuning_state`). The reference client's host watches the same
## thing (`sceneTuningVersion` in `core.js`).
static var version: int = 0

## Every static leaf, `path -> [owner, field, keys]`. The dotted paths are the duplication that has
## to be: a path is a name, and the API is the authority on what a name is.
static func _leaves() -> Dictionary:
	if _leaves_cache.is_empty():
		_leaves_cache = {
			# `TUNING.stats` -- `PlayerGoat`'s own, verbatim.
			"stats.max": [PlayerGoat, &"STATS_MAX", PackedStringArray()],
			"stats.energyDrain.idle": [PlayerGoat, &"ENERGY_DRAIN", PackedStringArray(["idle"])],
			"stats.energyDrain.walk": [PlayerGoat, &"ENERGY_DRAIN", PackedStringArray(["walk"])],
			"stats.energyDrain.trot": [PlayerGoat, &"ENERGY_DRAIN", PackedStringArray(["trot"])],
			"stats.energyDrain.run": [PlayerGoat, &"ENERGY_DRAIN", PackedStringArray(["run"])],
			"stats.energyDrain.fly": [PlayerGoat, &"ENERGY_DRAIN", PackedStringArray(["fly"])],
			"stats.jumpEnergyCost": [PlayerGoat, &"JUMP_ENERGY_COST", PackedStringArray()],
			"stats.sleepEnergyRecover": [PlayerGoat, &"SLEEP_ENERGY_RECOVER", PackedStringArray()],
			"stats.sleepHealthRecover": [PlayerGoat, &"SLEEP_HEALTH_RECOVER", PackedStringArray()],
			"stats.idleHealthRecover": [PlayerGoat, &"IDLE_HEALTH_RECOVER", PackedStringArray()],
			"stats.exhaustHealthDrain": [PlayerGoat, &"EXHAUST_HEALTH_DRAIN", PackedStringArray()],
			"stats.restedEnergy": [PlayerGoat, &"RESTED_ENERGY", PackedStringArray()],
			"stats.autoSleepDelay": [PlayerGoat, &"AUTO_SLEEP_DELAY", PackedStringArray()],
			# The turn rate is the goat's; the radius and scale are the herd's, because that is
			# where the body collision between two goats is resolved.
			"movement.turnRate": [PlayerGoat, &"TURN_RATE", PackedStringArray()],
			"movement.goatRadius": [Bots, &"GOAT_RADIUS", PackedStringArray()],
			"movement.modelScale": [Bots, &"MODEL_SCALE", PackedStringArray()],
			# A gait is a stride and a duty, the same table for the player and the herd.
			"gait.walk.stride": [PlayerGoat, &"GAIT", PackedStringArray(["walk", "stride"])],
			"gait.walk.duty": [PlayerGoat, &"GAIT", PackedStringArray(["walk", "duty"])],
			"gait.trot.stride": [PlayerGoat, &"GAIT", PackedStringArray(["trot", "stride"])],
			"gait.trot.duty": [PlayerGoat, &"GAIT", PackedStringArray(["trot", "duty"])],
			"gait.run.stride": [PlayerGoat, &"GAIT", PackedStringArray(["run", "stride"])],
			"gait.run.duty": [PlayerGoat, &"GAIT", PackedStringArray(["run", "duty"])],
			# `jump.fallbackTime` is the *modelled* jump's fallback length (`PlayerGoat`); the cube
			# fallback's own height and speed multiples are not ported (header).
			"jump.fallbackTime": [PlayerGoat, &"JUMP_FALLBACK_TIME", PackedStringArray()],
			# The captured-bird flight model (`crates/flight`). The crate owns the maths and these
			# are its defaults; `PlayerGoat.flight_config` maps them into the `Flight` class, and a
			# write to any of them re-configures it on the next frame (`main.gd`'s version watch).
			"flight.takeoffLift": [PlayerGoat, &"FLIGHT", PackedStringArray(["takeoffLift"])],
			"flight.takeoffPitch": [PlayerGoat, &"FLIGHT", PackedStringArray(["takeoffPitch"])],
			"flight.takeoffEnergy": [PlayerGoat, &"FLIGHT", PackedStringArray(["takeoffEnergy"])],
			"flight.speed": [PlayerGoat, &"FLIGHT", PackedStringArray(["speed"])],
			"flight.minSpeed": [PlayerGoat, &"FLIGHT", PackedStringArray(["minSpeed"])],
			"flight.maxSpeed": [PlayerGoat, &"FLIGHT", PackedStringArray(["maxSpeed"])],
			"flight.speedResponse": [PlayerGoat, &"FLIGHT", PackedStringArray(["speedResponse"])],
			"flight.pitchMax": [PlayerGoat, &"FLIGHT", PackedStringArray(["pitchMax"])],
			"flight.pitchRate": [PlayerGoat, &"FLIGHT", PackedStringArray(["pitchRate"])],
			"flight.bankMax": [PlayerGoat, &"FLIGHT", PackedStringArray(["bankMax"])],
			"flight.bankRate": [PlayerGoat, &"FLIGHT", PackedStringArray(["bankRate"])],
			"flight.turnRate": [PlayerGoat, &"FLIGHT", PackedStringArray(["turnRate"])],
			"flight.sink": [PlayerGoat, &"FLIGHT", PackedStringArray(["sink"])],
			"flight.climbGain": [PlayerGoat, &"FLIGHT", PackedStringArray(["climbGain"])],
			"flight.vyResponse": [PlayerGoat, &"FLIGHT", PackedStringArray(["vyResponse"])],
			"flight.flapLift": [PlayerGoat, &"FLIGHT", PackedStringArray(["flapLift"])],
			"flight.flapSpeed": [PlayerGoat, &"FLIGHT", PackedStringArray(["flapSpeed"])],
			"flight.flapCooldown": [PlayerGoat, &"FLIGHT", PackedStringArray(["flapCooldown"])],
			"flight.flapEnergy": [PlayerGoat, &"FLIGHT", PackedStringArray(["flapEnergy"])],
			"flight.ceiling": [PlayerGoat, &"FLIGHT", PackedStringArray(["ceiling"])],
			"flight.gravity": [PlayerGoat, &"FLIGHT", PackedStringArray(["gravity"])],
			"flight.safeFall": [PlayerGoat, &"FLIGHT", PackedStringArray(["safeFall"])],
			"flight.fallDamage": [PlayerGoat, &"FLIGHT", PackedStringArray(["fallDamage"])],
			"flight.fallHealthFloor": [PlayerGoat, &"FLIGHT", PackedStringArray(["fallHealthFloor"])],
			"flight.fallPitchGain": [PlayerGoat, &"FLIGHT", PackedStringArray(["fallPitchGain"])],
			"flight.botAltitude": [PlayerGoat, &"FLIGHT", PackedStringArray(["botAltitude"])],
			"flight.botRadius": [PlayerGoat, &"FLIGHT", PackedStringArray(["botRadius"])],
			"flight.botTime": [PlayerGoat, &"FLIGHT", PackedStringArray(["botTime"])],
			"flight.botCooldown": [PlayerGoat, &"FLIGHT", PackedStringArray(["botCooldown"])],
			"flight.botTurn": [PlayerGoat, &"FLIGHT", PackedStringArray(["botTurn"])],
			"flight.botYawGain": [PlayerGoat, &"FLIGHT", PackedStringArray(["botYawGain"])],
			"flight.botPitchGain": [PlayerGoat, &"FLIGHT", PackedStringArray(["botPitchGain"])],
			"flight.botFlapBelow": [PlayerGoat, &"FLIGHT", PackedStringArray(["botFlapBelow"])],
			"flight.botTerrainGuard": [PlayerGoat, &"FLIGHT", PackedStringArray(["botTerrainGuard"])],
			# The meal is the meadow's rule; `rainShelter` is the weather's effect on it, which the
			# goat owns because the belly eases the rain's slowdown.
			"food.eatRange": [Meadow, &"EAT_RANGE", PackedStringArray()],
			"food.eatEnergy": [Meadow, &"EAT_ENERGY", PackedStringArray()],
			"food.eatSatiety": [Meadow, &"EAT_SATIETY", PackedStringArray()],
			"food.fullBelly": [Meadow, &"FULL_BELLY", PackedStringArray()],
			"food.fullBellyHeal": [Meadow, &"FULL_BELLY_HEAL", PackedStringArray()],
			"food.satietyDecay": [Meadow, &"SATIETY_DECAY", PackedStringArray()],
			"food.rainShelter": [PlayerGoat, &"RAIN_SHELTER", PackedStringArray()],
			"food.regrowMin": [Meadow, &"REGROW_MIN", PackedStringArray()],
			"food.regrowMax": [Meadow, &"REGROW_MAX", PackedStringArray()],
			# The wind's base and its normaliser are the sky's (it derives the gust); the rest are
			# the two shares the goat feels, and the hold times are the machine's. `windNorm` lives
			# only on the sky, which is what the goat and the water read.
			"weather.windBase": [SkyModel, &"WIND_BASE", PackedStringArray()],
			"weather.windNorm": [SkyModel, &"WIND_NORM", PackedStringArray()],
			"weather.rainMax": [Weather, &"RAIN_MAX", PackedStringArray()],
			"weather.rainSlow": [PlayerGoat, &"RAIN_SLOW", PackedStringArray()],
			"weather.windSlow": [PlayerGoat, &"WIND_SLOW", PackedStringArray()],
			"weather.wetDrain": [PlayerGoat, &"WET_DRAIN", PackedStringArray()],
			"weather.windDrain": [PlayerGoat, &"WIND_DRAIN", PackedStringArray()],
			"weather.hold.clear": [Weather, &"HOLD", PackedStringArray(["clear"])],
			"weather.hold.cloudy": [Weather, &"HOLD", PackedStringArray(["cloudy"])],
			"weather.hold.rain": [Weather, &"HOLD", PackedStringArray(["rain"])],
			"weather.hold.clearing": [Weather, &"HOLD", PackedStringArray(["clearing"])],
			# The field's shape, and the rate its detail texture tiles at.
			"terrain.relief": [Terrain, &"RELIEF", PackedStringArray()],
			"terrain.flat": [Terrain, &"FLAT", PackedStringArray()],
			"terrain.ramp": [Terrain, &"RAMP", PackedStringArray()],
			"terrain.mountain": [Terrain, &"MOUNTAIN", PackedStringArray()],
			"terrain.mountainFlat": [Terrain, &"MOUNTAIN_FLAT", PackedStringArray()],
			"terrain.mountainRamp": [Terrain, &"MOUNTAIN_RAMP", PackedStringArray()],
			"terrain.snap": [Terrain, &"SNAP", PackedStringArray()],
			"terrain.uv": [TerrainMesh, &"UV_SCALE", PackedStringArray()],
			# The table and its drag. `enabled` and `reflection` are the scene's (header).
			"water.low": [Water, &"LOW", PackedStringArray()],
			"water.high": [Water, &"HIGH", PackedStringArray()],
			"water.fill": [Water, &"FILL", PackedStringArray()],
			"water.seep": [Water, &"SEEP", PackedStringArray()],
			"water.wetDown": [Water, &"WET_DOWN", PackedStringArray()],
			"water.maxDepth": [Water, &"MAX_DEPTH", PackedStringArray()],
			"water.wave.height": [Water, &"WAVE_HEIGHT", PackedStringArray()],
			"water.wave.scale": [Water, &"WAVE_SCALE", PackedStringArray()],
			"water.wave.speed": [Water, &"WAVE_SPEED", PackedStringArray()],
			"water.wave.wind": [Water, &"WAVE_WIND", PackedStringArray()],
			"water.drag": [Water, &"DRAG", PackedStringArray()],
			"water.dragEnergy": [Water, &"DRAG_ENERGY", PackedStringArray()],
			# The day's length is the sky's; the cold's multiplier is the goat's.
			"world.dayLength": [SkyModel, &"DAY_LENGTH", PackedStringArray()],
			"world.nightDrainMult": [PlayerGoat, &"NIGHT_DRAIN_MULT", PackedStringArray()],
			# `count` is the scene's (header); the linger and the pool are the herd's, and so
			# are the birds' release odds -- the birds mod is the one reader.
			"herd.deathLinger": [Bots, &"DEATH_LINGER", PackedStringArray()],
			"herd.botReleaseLanding": [Bots, &"RELEASE_LANDING", PackedStringArray()],
			"herd.botReleaseAir": [Bots, &"RELEASE_AIR", PackedStringArray()],
			"herd.spec": [Bots, &"SPEC", PackedStringArray()],
			"camera.yaw": [Tuning, &"CAMERA_YAW", PackedStringArray()],
			"camera.pitch": [Tuning, &"CAMERA_PITCH", PackedStringArray()],
			"camera.dist": [Tuning, &"CAMERA_DIST", PackedStringArray()],
			"camera.minDist": [Tuning, &"CAMERA_MIN_DIST", PackedStringArray()],
			"camera.maxDist": [Tuning, &"CAMERA_MAX_DIST", PackedStringArray()],
			# The cloud layer's own numbers, which the sky shader's march reads every frame.
			"sky.cloudBase": [SkyModel, &"CLOUD_BASE", PackedStringArray()],
			"sky.cloudTop": [SkyModel, &"CLOUD_TOP", PackedStringArray()],
			"sky.scale": [SkyModel, &"CLOUD_SCALE", PackedStringArray()],
			"sky.detail": [SkyModel, &"CLOUD_DETAIL", PackedStringArray()],
			"sky.absorb": [SkyModel, &"CLOUD_ABSORB", PackedStringArray()],
			"sky.cirrusLevel": [SkyModel, &"CIRRUS_LEVEL", PackedStringArray()],
			"sky.speed": [SkyModel, &"CLOUD_SPEED", PackedStringArray()],
			"sky.steps": [SkyModel, &"CLOUD_STEPS", PackedStringArray()],
			# The devices: the field, the trigger, the bang and the look. The crate's dish is
			# `craters.gd`'s, because the crater is a term in the ground rather than a bang's effect.
			"explosions.safe": [Explosions, &"SAFE", PackedStringArray()],
			"explosions.fuse": [Explosions, &"FUSE", PackedStringArray()],
			"explosions.maxActive": [Explosions, &"MAX_ACTIVE", PackedStringArray()],
			"explosions.mine.density": [Explosions, &"MINE_DENSITY", PackedStringArray()],
			"explosions.mine.trigger": [Explosions, &"MINE_TRIGGER", PackedStringArray()],
			"explosions.mine.clearance": [Explosions, &"MINE_CLEARANCE", PackedStringArray()],
			"explosions.trap.chance": [Explosions, &"TRAP_CHANCE", PackedStringArray()],
			"explosions.relocate.min": [Explosions, &"RELOCATE_MIN", PackedStringArray()],
			"explosions.relocate.max": [Explosions, &"RELOCATE_MAX", PackedStringArray()],
			"explosions.relocate.tries": [Explosions, &"RELOCATE_TRIES", PackedStringArray()],
			"explosions.blast.radius": [Explosions, &"BLAST_RADIUS", PackedStringArray()],
			"explosions.blast.damage": [Explosions, &"BLAST_DAMAGE", PackedStringArray()],
			"explosions.blast.healthFloor": [Explosions, &"BLAST_HEALTH_FLOOR", PackedStringArray()],
			"explosions.blast.push": [Explosions, &"BLAST_PUSH", PackedStringArray()],
			"explosions.blast.lift": [Explosions, &"BLAST_LIFT", PackedStringArray()],
			"explosions.crater.radius": [Craters, &"RADIUS", PackedStringArray()],
			"explosions.crater.depth": [Craters, &"DEPTH", PackedStringArray()],
			"explosions.crater.lip": [Craters, &"LIP", PackedStringArray()],
			"explosions.crater.heal": [Craters, &"HEAL", PackedStringArray()],
			"explosions.crater.max": [Craters, &"MAX", PackedStringArray()],
			"explosions.flash.time": [Explosions, &"FLASH_TIME", PackedStringArray()],
			"explosions.flash.energy": [Explosions, &"FLASH_ENERGY", PackedStringArray()],
			"explosions.flash.lift": [Explosions, &"FLASH_LIFT", PackedStringArray()],
			# The body centre the flung arc and the flight pose turn about. The birds mod
			# reads it to seat a captured rider, so it is a leaf for the same reason
			# `movement.modelScale` is: two owners of one number would drift.
			"explosions.fling.pivot": [PlayerGoat, &"FLIGHT_PIVOT", PackedStringArray()],
			"explosions.fx.blast.time": [Explosions, &"FX_BLAST_TIME", PackedStringArray()],
			"explosions.fx.blast.scale": [Explosions, &"FX_BLAST_SCALE", PackedStringArray()],
			"explosions.fx.blast.lift": [Explosions, &"FX_BLAST_LIFT", PackedStringArray()],
			"explosions.fx.smoke.time": [Explosions, &"FX_SMOKE_TIME", PackedStringArray()],
			"explosions.fx.smoke.scale": [Explosions, &"FX_SMOKE_SCALE", PackedStringArray()],
			"explosions.fx.smoke.lift": [Explosions, &"FX_SMOKE_LIFT", PackedStringArray()],
			"explosions.fx.debris.count": [Explosions, &"DEBRIS_COUNT", PackedStringArray()],
			"explosions.fx.debris.time": [Explosions, &"DEBRIS_TIME", PackedStringArray()],
			"explosions.fx.debris.speed": [Explosions, &"DEBRIS_SPEED", PackedStringArray()],
			"explosions.fx.debris.up": [Explosions, &"DEBRIS_UP", PackedStringArray()],
			"explosions.fx.debris.gravity": [Explosions, &"DEBRIS_GRAVITY", PackedStringArray()],
			"explosions.fx.debris.size": [Explosions, &"DEBRIS_SIZE", PackedStringArray()],
			"explosions.shake.energy": [Explosions, &"SHAKE_ENERGY", PackedStringArray()],
			"explosions.shake.range": [Explosions, &"SHAKE_RANGE", PackedStringArray()],
			"explosions.shake.decay": [Explosions, &"SHAKE_DECAY", PackedStringArray()],
			"explosions.shake.speed": [Explosions, &"SHAKE_SPEED", PackedStringArray()],
			"explosions.pulse.decay": [Explosions, &"PULSE_DECAY", PackedStringArray()],
			"explosions.pulse.damage": [Explosions, &"PULSE_DAMAGE", PackedStringArray()],
			"explosions.chain": [Explosions, &"CHAIN_DELAY", PackedStringArray()],
			"explosions.chainDepth": [Explosions, &"CHAIN_DEPTH", PackedStringArray()],
		}
	return _leaves_cache

## The tree, as the nested object a mod reads (`goats.tuning.get`). Built from the leaves and
## cached; a write invalidates the cache. The live leaves are patched from their getters on every
## call, because their value is the scene's and moves without a write through here.
##
## The answer is the cached dictionary itself, **not a copy** -- it is stringified into the frame's
## snapshot immediately and never held, so the copy a per-frame caller would need is exactly the
## cost this avoids. A caller that wants to keep it must `duplicate(true)` first.
static func tree() -> Dictionary:
	if _tree_cache.is_empty():
		_tree_cache = _build()
	for path: String in _live:
		var getter: Callable = _live[path]["get"]
		if getter.is_valid():
			_assign(_tree_cache, path, getter.call())
	return _tree_cache

## `goats.tuning.set(path, value)` (`APIv1.md` section 4.10): validated against the value it
## replaces, written back to the leaf's owner, and recorded for the `"tuning"` event. Answers
## `{"ok": stored}` or `{"err": message}`.
static func write(path: String, value: Variant) -> Dictionary:
	var parts: PackedStringArray = path.split(".")
	var leaf: String = parts[parts.size() - 1]
	var node: Variant = tree()
	for i: int in parts.size() - 1:
		var part: String = parts[i]
		if not (node is Dictionary) or not (node as Dictionary).has(part):
			return _error(_unknown(path))
		node = (node as Dictionary)[part]
	if not (node is Dictionary) or not (node as Dictionary).has(leaf):
		return _error(_unknown(path))
	var coerced: Dictionary = _coerce(path, (node as Dictionary)[leaf], value)
	if coerced.has("err"):
		return coerced
	_store(path, coerced["ok"])
	return coerced

## `goats.tuning.merge(object)` and a mod's `tuning.json` (`APIv1.md` sections 3.4, 4.10): a nested
## object merged leaf by leaf, so every write is validated. Stops at the first bad leaf and answers
## its error, which is `tuningMerge`'s own shape -- the leaves before it have already landed.
static func merge(object: Variant, prefix: String = "") -> Dictionary:
	if not (object is Dictionary):
		return {"ok": null}
	var table: Dictionary = object
	for key: String in table:
		var path: String = key if prefix == "" else prefix + "." + key
		var value: Variant = table[key]
		if value is Dictionary:
			var nested: Dictionary = merge(value, path)
			if nested.has("err"):
				return nested
		else:
			var answer: Dictionary = write(path, value)
			if answer.has("err"):
				return answer
	return {"ok": null}

## Register a leaf the *scene* owns, with a getter and a setter that read and write it the scene's
## own way. Called once at boot, before the mod runtime loads -- a mod's `tuning.json` merges before
## its entry runs (`APIv1.md` section 3.4), so the live leaves have to be here by then.
static func register_live(path: String, getter: Callable, setter: Callable) -> void:
	_live[path] = {"get": getter, "set": setter}
	_tree_cache = {}

## Forget the tree's own state -- the scene is going down. The leaves stay where they are: a
## module's `static var` is the module's, and a session ends with it.
static func reset() -> void:
	_live.clear()
	_tree_cache = {}
	_changed.clear()

## Every accepted write since the last call, as `[path, value]` pairs, and clear the list. The
## scene drains this once a frame and says each as the `"tuning"` event (`APIv1.md` section 4.2).
static func take_changed() -> Array:
	var out: Array = _changed
	_changed = []
	return out

## Put `value` at the dotted `path` in `root`, making the intermediate dictionaries.
static func _assign(root: Dictionary, path: String, value: Variant) -> void:
	var parts: PackedStringArray = path.split(".")
	var node: Dictionary = root
	for i: int in parts.size() - 1:
		var key: String = parts[i]
		if not (node.get(key) is Dictionary):
			node[key] = {}
		node = node[key]
	node[parts[parts.size() - 1]] = value

## The whole static tree, freshly gathered from the leaves.
static func _build() -> Dictionary:
	var out: Dictionary = {}
	var leaves: Dictionary = _leaves()
	for path: String in leaves:
		_assign(out, path, _read_leaf(leaves[path]))
	return out

## One static leaf's current value: the owner's `static var`, then the keys into it.
static func _read_leaf(desc: Array) -> Variant:
	var value: Variant = (desc[0] as Object).get(desc[1])
	for key: String in desc[2]:
		value = (value as Dictionary)[key]
	return value

## Write one static leaf back to its owner -- the `static var` itself, or the member of the
## dictionary it holds.
static func _write_leaf(desc: Array, value: Variant) -> void:
	var keys: PackedStringArray = desc[2]
	if keys.is_empty():
		(desc[0] as Object).set(desc[1], value)
		return
	var node: Dictionary = (desc[0] as Object).get(desc[1])
	for i: int in keys.size() - 1:
		node = node[keys[i]]
	node[keys[keys.size() - 1]] = value

## Write an accepted value to its leaf and record it.
static func _store(path: String, value: Variant) -> void:
	if _live.has(path):
		var setter: Callable = _live[path]["set"]
		if setter.is_valid():
			setter.call(value)
	else:
		_write_leaf(_leaves()[path], value)
	_tree_cache = {}
	_changed.append([path, value])
	version += 1

## `tuningCoerce`, transcribed: validate `value` against the leaf's current value -- a number stays
## finite and is rounded or clamped where the tables say so, an array stays an array, and a branch
## is not a leaf.
static func _coerce(path: String, current: Variant, value: Variant) -> Dictionary:
	if current is float or current is int:
		if not (value is float or value is int):
			return _error("tuning: '" + path + "' expects a finite number")
		var n: float = float(value)
		if is_nan(n) or is_inf(n):
			return _error("tuning: '" + path + "' expects a finite number")
		if INT.has(path):
			var whole: int = int(round(n))
			if CLAMP.has(path):
				whole = clampi(whole, int(CLAMP[path][0]), int(CLAMP[path][1]))
			return {"ok": whole}
		if CLAMP.has(path):
			n = clampf(n, CLAMP[path][0], CLAMP[path][1])
		return {"ok": n}
	if current is Array:
		if not (value is Array):
			return _error("tuning: '" + path + "' expects an array")
		var list: Array = value
		if path == "herd.spec" and list.is_empty():
			return _error("tuning: 'herd.spec' must not be empty")
		if path == "sky.steps" and list.size() != (current as Array).size():
			return _error("tuning: 'sky.steps' expects %d entries" % (current as Array).size())
		return {"ok": list}
	return _error("tuning: '" + path + "' is not a leaf")

static func _error(message: String) -> Dictionary:
	return {"err": message}

static func _unknown(path: String) -> String:
	return "tuning: unknown path '" + path + "'"
