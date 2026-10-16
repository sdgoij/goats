# The tuning tree (`APIv1.md` section 4.10): the game's constants, gathered into the dotted-path
# shape a mod reads through `goats.tuning.get`.
#
# The scene's `TUNING` is JavaScript's, a mutable tree every system reads out of (`core.js`). The
# port has no such tree: its constants are `const`s on the modules that own them -- `PlayerGoat`'s
# drain table, `Terrain`'s relief, `Explosions`' blast -- which is the *better* shape until a write
# path exists, because a constant cannot drift from its reader. What a mod wants, though, is the
# API's one address space: `goats.tuning.get("stats.energyDrain.run")`.
#
# So this file gathers, and it gathers *from the owners*: every leaf below is `PlayerGoat.SOMETHING`
# or `Explosions.SOMETHING` rather than a literal, so there is still exactly one place each number
# lives and this file cannot become a second copy of the tree that drifts from the first. The
# dotted paths are the duplication, and they have to be -- a path is a name, and the API is the
# authority on what a name is.
#
# **The tree is a subset, and an absent path throws.** The port deliberately did not port the
# JavaScript client's model *fallbacks* (`PORT.md` section 5: a fallback for a build without
# something Godot always has is not ported), and a few leaves live in a shader rather than in
# GDScript. Those are left out rather than guessed at, and `goats.tuning.get` on one throws the
# same "unknown path" a typo does -- which is `APIv1.md` section 4.10's own contract, so a mod
# cannot tell a missing leaf from a misspelling, and neither case is ever answered with a wrong
# number. What is absent, and why:
#
#   * `stats.deadEyeFraction`, `jump.fallbackHeight`/`fallbackTrotMult`/`fallbackRunMult` -- the
#     cube-goat fallback, which the port has no build without.
#   * `weather.cloudDrift` -- the port's clouds drift off `sky.speed` and the shader's own marcher;
#     there is no separate leaf.
#   * `water.shore`, `water.fresnel` -- uniforms of `water.gdshader`, quoted nowhere in GDScript.
#   * `explosions.enabled`, `explosions.mine.tell`, `explosions.crater.scorch`/`scorchRange`,
#     `explosions.fx.*.cols`/`cell` -- the port's devices have no off switch, its mines are never
#     drawn as a tell, and its bang's art is generated at boot rather than from an atlas.
#   * `lighting` -- Godot's own `DirectionalLight3D` shadow settings, which the scene never
#     overrides, so the port has no equivalent numbers to report.
#   * `world.timeFast` -- the JavaScript client's `T` key; the port has no fast-forward.
#
# The three leaves that are *live* rather than constant -- `herd.count`, `water.enabled`,
# `water.reflection` -- are the caller's: `tree()` patches them in from the frame, because a
# static function cannot see them and a constant would be a lie.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Tuning
extends RefCounted

## The camera's boot values and limits (`main.gd`'s `_orbit`, `cmd_set_camera`,
## `cmd_camera_reset`). They live here so the tree and the camera that clamps to them cannot
## disagree, which is the same reason `Settings` is one object.
const CAMERA_YAW := 0.7
const CAMERA_PITCH := 0.42
const CAMERA_DIST := 5.2
const CAMERA_MIN_DIST := 2.2
const CAMERA_MAX_DIST := 12.0
const CAMERA_MIN_PITCH := 0.08
const CAMERA_MAX_PITCH := 1.35

## The constants, built once and then kept. Nothing in the tree changes except the three live
## leaves below, so it is worth building only once.
static var _tree: Dictionary = {}

## The tree, with the three leaves the *frame* owns patched in: the herd's size, whether the
## water system is on, and the reflection tier's wish. They are live values rather than constants
## (the frame owns the herd and the water), which is why they are arguments here rather than
## literals above.
##
## The answer is the cached dictionary itself, **not a copy** -- it is stringified into the frame's
## snapshot immediately and never held, so the copy a per-frame caller would need is exactly the
## cost this avoids. A caller that wants to keep it must `duplicate(true)` first.
static func tree(herd_count: int, water_enabled: bool, water_reflection: float) -> Dictionary:
	if _tree.is_empty():
		_tree = _build()
	(_tree["herd"] as Dictionary)["count"] = herd_count
	(_tree["water"] as Dictionary)["enabled"] = 1 if water_enabled else 0
	(_tree["water"] as Dictionary)["reflection"] = water_reflection
	return _tree

## Gather every leaf from the module that owns it. See the header for what is not here.
static func _build() -> Dictionary:
	return {
		# `TUNING.stats` -- `PlayerGoat`'s own consts, verbatim.
		"stats": {
			"max": PlayerGoat.STATS_MAX,
			"energyDrain": PlayerGoat.ENERGY_DRAIN.duplicate(),
			"jumpEnergyCost": PlayerGoat.JUMP_ENERGY_COST,
			"sleepEnergyRecover": PlayerGoat.SLEEP_ENERGY_RECOVER,
			"sleepHealthRecover": PlayerGoat.SLEEP_HEALTH_RECOVER,
			"idleHealthRecover": PlayerGoat.IDLE_HEALTH_RECOVER,
			"exhaustHealthDrain": PlayerGoat.EXHAUST_HEALTH_DRAIN,
			"restedEnergy": PlayerGoat.RESTED_ENERGY,
			"autoSleepDelay": PlayerGoat.AUTO_SLEEP_DELAY,
		},
		# The turn rate is the goat's; the radius and scale are the herd's, because that is
		# where the body collision between two goats is resolved.
		"movement": {
			"turnRate": PlayerGoat.TURN_RATE,
			"goatRadius": Bots.GOAT_RADIUS,
			"modelScale": Bots.MODEL_SCALE,
		},
		# A gait is a stride and a duty, the same table for the player and the herd.
		"gait": PlayerGoat.GAIT.duplicate(true),
		# `jump.fallbackTime` is the *modelled* jump's fallback length (`PlayerGoat`); the cube
		# fallback's own height and speed multiples are not ported (header).
		"jump": {
			"fallbackTime": PlayerGoat.JUMP_FALLBACK_TIME,
		},
		# The meal is the meadow's rule; `rainShelter` is the weather's effect on it, which the
		# goat owns because the belly eases the rain's slowdown.
		"food": {
			"eatRange": Meadow.EAT_RANGE,
			"eatEnergy": Meadow.EAT_ENERGY,
			"eatSatiety": Meadow.EAT_SATIETY,
			"fullBelly": Meadow.FULL_BELLY,
			"fullBellyHeal": Meadow.FULL_BELLY_HEAL,
			"satietyDecay": Meadow.SATIETY_DECAY,
			"rainShelter": PlayerGoat.RAIN_SHELTER,
			"regrowMin": Meadow.REGROW_MIN,
			"regrowMax": Meadow.REGROW_MAX,
		},
		# The wind's base is the sky's (it is derived from the sky's own gust); the rest are the
		# two shares the goat feels, and the hold times are the machine's.
		"weather": {
			"windBase": SkyDome.WIND_BASE,
			"rainMax": Weather.RAIN_MAX,
			"rainSlow": PlayerGoat.RAIN_SLOW,
			"windSlow": PlayerGoat.WIND_SLOW,
			"wetDrain": PlayerGoat.WET_DRAIN,
			"windDrain": PlayerGoat.WIND_DRAIN,
			"windNorm": PlayerGoat.WIND_NORM,
			"hold": Weather.HOLD.duplicate(true),
		},
		# The field's shape, and the rate its detail texture tiles at.
		"terrain": {
			"relief": Terrain.RELIEF,
			"flat": Terrain.FLAT,
			"ramp": Terrain.RAMP,
			"snap": Terrain.SNAP,
			"uv": TerrainMesh.UV_SCALE,
		},
		# The table and its drag. `enabled` and `reflection` are the caller's (header).
		"water": {
			"enabled": 1,
			"low": Water.LOW,
			"high": Water.HIGH,
			"fill": Water.FILL,
			"seep": Water.SEEP,
			"wetDown": Water.WET_DOWN,
			"maxDepth": Water.MAX_DEPTH,
			"reflection": WaterReflect.DEFAULT,
			"wave": {
				"height": Water.WAVE_HEIGHT,
				"scale": Water.WAVE_SCALE,
				"speed": Water.WAVE_SPEED,
				"wind": Water.WAVE_WIND,
			},
			"drag": Water.DRAG,
			"dragEnergy": Water.DRAG_ENERGY,
		},
		# The day's length is the sky's; the cold's multiplier is the goat's.
		"world": {
			"dayLength": SkyDome.DAY_LENGTH,
			"nightDrainMult": PlayerGoat.NIGHT_DRAIN_MULT,
		},
		# `count` is the caller's (header); the pool and the linger are the herd's.
		"herd": {
			"count": Bots.COUNT,
			"deathLinger": Bots.DEATH_LINGER,
			"spec": Bots.SPEC.duplicate(true),
		},
		"camera": {
			"yaw": CAMERA_YAW,
			"pitch": CAMERA_PITCH,
			"dist": CAMERA_DIST,
			"minDist": CAMERA_MIN_DIST,
			"maxDist": CAMERA_MAX_DIST,
		},
		# The cloud layer's own numbers, which the sky shader's march reads every frame.
		"sky": {
			"cloudBase": SkyDome.CLOUD_BASE,
			"cloudTop": SkyDome.CLOUD_TOP,
			"scale": SkyDome.CLOUD_SCALE,
			"detail": SkyDome.CLOUD_DETAIL,
			"absorb": SkyDome.CLOUD_ABSORB,
			"cirrusLevel": SkyDome.CIRRUS_LEVEL,
			"speed": SkyDome.CLOUD_SPEED,
			"steps": SkyDome.CLOUD_STEPS.duplicate(),
		},
		# The devices: the field, the trigger, the bang and the look. The crate's dish is
		# `craters.gd`'s, because the crater is a term in the ground rather than a bang's effect.
		"explosions": {
			"safe": Explosions.SAFE,
			"fuse": Explosions.FUSE,
			"maxActive": Explosions.MAX_ACTIVE,
			"mine": {
				"density": Explosions.MINE_DENSITY,
				"trigger": Explosions.MINE_TRIGGER,
				"clearance": Explosions.MINE_CLEARANCE,
			},
			"trap": {
				"chance": Explosions.TRAP_CHANCE,
			},
			"relocate": {
				"min": Explosions.RELOCATE_MIN,
				"max": Explosions.RELOCATE_MAX,
				"tries": Explosions.RELOCATE_TRIES,
			},
			"blast": {
				"radius": Explosions.BLAST_RADIUS,
				"damage": Explosions.BLAST_DAMAGE,
				"healthFloor": Explosions.BLAST_HEALTH_FLOOR,
				"push": Explosions.BLAST_PUSH,
				"lift": Explosions.BLAST_LIFT,
			},
			"crater": {
				"radius": Craters.RADIUS,
				"depth": Craters.DEPTH,
				"lip": Craters.LIP,
				"heal": Craters.HEAL,
				"max": Craters.MAX,
			},
			"flash": {
				"time": Explosions.FLASH_TIME,
				"energy": Explosions.FLASH_ENERGY,
				"lift": Explosions.FLASH_LIFT,
			},
			"fx": {
				"blast": {
					"time": Explosions.FX_BLAST_TIME,
					"scale": Explosions.FX_BLAST_SCALE,
					"lift": Explosions.FX_BLAST_LIFT,
				},
				"smoke": {
					"time": Explosions.FX_SMOKE_TIME,
					"scale": Explosions.FX_SMOKE_SCALE,
					"lift": Explosions.FX_SMOKE_LIFT,
				},
				"debris": {
					"count": Explosions.DEBRIS_COUNT,
					"time": Explosions.DEBRIS_TIME,
					"speed": Explosions.DEBRIS_SPEED,
					"up": Explosions.DEBRIS_UP,
					"gravity": Explosions.DEBRIS_GRAVITY,
					"size": Explosions.DEBRIS_SIZE,
				},
			},
			"shake": {
				"energy": Explosions.SHAKE_ENERGY,
				"range": Explosions.SHAKE_RANGE,
				"decay": Explosions.SHAKE_DECAY,
				"speed": Explosions.SHAKE_SPEED,
			},
			"pulse": {
				"decay": Explosions.PULSE_DECAY,
				"damage": Explosions.PULSE_DAMAGE,
			},
			"chain": Explosions.CHAIN_DELAY,
			"chainDepth": Explosions.CHAIN_DEPTH,
		},
	}
