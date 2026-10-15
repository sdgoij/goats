# The herd: `bots.js`'s bots -- the goats nobody is driving.
#
# Seven goats with a temperament each, who graze, stroll, trot, occasionally sprint and
# rarely doze, who wander around the player and are steered home once they drift too
# far -- so the herd stays near without any explicit flocking. They are what makes
# `goatsd` optional rather than required: a scene that simulates its own herd is a
# *game* on its own, and a client that joins mirrors the host's instead (`herd.gd`,
# which draws one real goat per bot the host reports).
#
# Three things are worth naming before the code.
#
#   * **The bots have a random stream of their own.** `bots.js` keeps `botRngState`
#     apart from the weather's `rnd()` because the harness asserts on the exact weather a
#     seed produces, and drawing the herd from that stream would shift every later value.
#     It is also the *second* of the five draws `sceneUseSeed` makes, so `use_seed` takes
#     the second -- `weather.gd` takes the first and `explosions.gd` the fifth.
#
#   * **The AI is a state machine with no steering model.** A bot picks an action when a
#     timer runs out -- eat, stand, doze, or walk/trot/run to a target -- and while it
#     walks it turns toward that target at `TURN` rad/s and moves at its gait's own
#     speed. There is no pathing, no flocking and no avoidance beyond the push-apart in
#     `resolve_collisions`, which is `collidePairs`' two relaxation passes.
#
#   * **Two of its rules read as mistakes and are not.** `new_action`'s doze branch spends
#     *one* draw on the mode and then reads the mode back to choose which timer line to
#     run -- so "sleep" and "idle" cost the same two draws whatever they turn out to be.
#     And the gait branch computes the clip role *before* it may call `new_action`, so the
#     frame a bot changes its mind advances the phase of the clip it was playing rather
#     than the one it just picked. Both are transcribed exactly; `verify_bots.gd` would
#     catch either if it were "fixed".
#
# The rules are `bots.js`'s and the *look* is the port's where the engine is better at
# it. Not reproduced, and each a decision rather than an omission:
#
#   * the **shadow blobs** under bots outside the shadow map's box -- Godot has a real
#     shadow atlas, so the blobs are the scene's fallback for a hand-rolled depth pass it
#     does not need;
#   * the **tumble** of a flung bot (`flingDraw`'s roll about a pivot) -- the port's
#     player goat has no tumble either, and both are posed from the clip;
#   * the **mod events** (`spawn`, `despawn`, `blast`) -- the `goats` surface is stage 8,
#     and nothing in GDScript consumes them yet.
#
# The fleece *is* ported: `makeBotTextures`' three octaves of `vnoise2` tiled as a
# 64x64 diffuse per coat colour, one material per coat shared by every bot wearing it.
# The port's mottle is at a different density from the shipped client's, because Godot
# honours `KHR_texture_transform` on the fur and raylib does not (see `verify_model.gd`),
# so the UVs the noise is tiled across are not the same ones -- the colours and the noise
# are the scene's, the tiling is the port's.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Bots
extends Node3D

## One bot. Typed fields rather than the scene's object literal, because a mistyped
## string key is a silently wrong value and this is a long transcription: `b.jumpSpeed`
## and `b.jump_speed` are the same field here, checked by the parser.
class Bot:
	extends RefCounted

	## `TUNING.herd.spec[i % 6]`, with the scale grown past the sixth cycle.
	var spec: Dictionary = {}
	var x := 0.0
	var z := 0.0
	var yaw := 0.0
	## The loop's own fraction through the current clip.
	var phase := 0.0
	## `idle | walk | trot | run | jump | sleep | eat | dead | flung`.
	var mode := "idle"
	## Seconds until this bot thinks again.
	var timer := 0.0
	## The target a walk, trot or run is aimed at.
	var tx := 0.0
	var tz := 0.0
	## Seconds of "zoomies" left while running; the odd hop comes out of it.
	var zoom := 0.0
	var jump_time := 0.0
	var jump_dur := 1.0
	var jump_speed := 0.0
	var jump_cool := 0.0
	## Seconds into the current meal, how long it lasts, and how long until the next one.
	var eat_time := 0.0
	var eat_dur := 1.0
	var eat_cool := 0.0
	## 0..1. Eases this bot's rain slowdown while it lasts, and decays.
	var satiety := 0.0
	## Walking to a tuft to eat when it arrives.
	var graze := false
	## Blast damage (M19a). Unlike the player there is no floor: a bot can be killed, and
	## the only thing that heals it is getting up again.
	var health := 0.0
	## Seconds since it died, and the clip's own length the pose is stretched over.
	var death_time := 0.0
	var death_dur := 1.0
	## The blast's arc (M19c), the player's shape in a bot's fields: `py` is the height
	## above the ground it is drawn at, `fly_y` the absolute height the physics
	## integrates, and `fly_time`/`fly_flight` the clip's stretch.
	var py := 0.0
	var fly_time := 0.0
	var fly_y := 0.0
	var fly_flight := 1.0
	var fly_vx := 0.0
	var fly_vy := 0.0
	var fly_vz := 0.0
	## Which clip variant this bot plays per role, `-1` so the first cycle lands on index
	## 0 for the roles that cycle -- and, because `clipAt` wraps, on the *last* variant
	## until the first `new_action` bumps it, which is what the scene does too.
	var variants: Dictionary = {}

	## The rig: the instanced model, its player, and the clip it is playing.
	var node: Node3D
	var anim: AnimationPlayer
	var clip := ""

## The goat, complete with its rig and clips. The same model the player's is and the
## same one `herd.gd` mirrors with.
const GOAT_SCENE := preload("res://assets/goat_animated.glb")

## `TUNING.herd.count`: how many bots the herd holds. The tuning leaf is a console and
## menu setting (stage 6); until then this is the number, and `set_herd_size` is what a
## setting would write.
const COUNT := 7
## `TUNING.herd.count`'s own ceiling -- `setHerdSize` clamps to it.
const MAX_HERD := 10
## `TUNING.herd.deathLinger`: seconds a killed bot lies there before it gets up.
const DEATH_LINGER := 8.0
## `TUNING.herd.spec`: coat colour, body scale and temperament. `bold` scales a bot's
## cruising speed; `lazy` biases it toward standing still.
const SPEC := [
	{"coat": [196, 168, 128], "scale": 0.80, "bold": 0.95, "lazy": 0.55, "name": "tan kid"},
	{"coat": [222, 216, 206], "scale": 1.06, "bold": 1.00, "lazy": 0.50, "name": "cream"},
	{"coat": [116, 92, 70], "scale": 1.22, "bold": 0.70, "lazy": 0.72, "name": "big brown"},
	{"coat": [156, 126, 92], "scale": 0.94, "bold": 1.18, "lazy": 0.32, "name": "lively"},
	{"coat": [88, 90, 98], "scale": 1.12, "bold": 0.85, "lazy": 0.62, "name": "charcoal"},
	{"coat": [208, 180, 142], "scale": 0.74, "bold": 1.05, "lazy": 0.45, "name": "small beige"},
]
## `TUNING.movement.goatRadius` / `modelScale`: the body collision radius at scale 1, and
## the scale the player's own model stands at, so goats block each other.
const GOAT_RADIUS := 0.45
const MODEL_SCALE := 1.0

## `bots.js` `GRAZE_SEEK_RANGE`: how far a bot looks for grass to walk to.
const GRAZE_SEEK_RANGE := 12.0
## `bots.js` `botRngState`: the private stream's seed, and where it starts offline.
const RNG_SEED := 0x2545f491
## `updateBots`'s `TURN`: how fast a bot swings onto its target, in rad/s.
const TURN := 1.5
## `bots.js` `botRole`'s roles, the same list `player_goat.gd` indexes -- every one is
## also a clip prefix in the model (`GoatIdle`, `GoatDeath`, ...).
const ROLES := ["walk", "trot", "run", "jump", "sleep", "eat", "death", "flung", "idle"]
## `makeBotTextures`' tile, in pixels.
const COAT_SIZE := 64

## The goat the herd orbits: what a spawn rings, what a target is aimed from, what a
## respawn stands away from, and what `resolve_collisions` pushes bots off. `main.gd`
## hands it in -- and a gate may set a bare one's `px`/`pz` to script a herd around a
## fixed point.
var goat: PlayerGoat
## The meadow a bite reads and writes. It may be null, and then there is nothing to eat.
var meadow: Meadow
## A bite's device test, `Explosions.trip_trap_at` in the scene: `(cx, cz, x, z) -> bool`,
## answering whether there was a trap to set off -- and setting it off, which is what one
## call rather than two buys (see `player_goat.gd` `start_eat`). Invalid in a gate, and
## then a bite is the plain meal. A `Callable` and not the node, for the reason
## `Meadow.nearest`'s filter is one: this file does not link against the devices.
var trap: Callable = Callable()
## An armed mine in a cell, `Explosions.mine_armed`: what a respawn avoids. A bot that
## came back onto one would be blown up before it took a step, which reads as a bug rather
## than as a minefield.
var armed: Callable = Callable()
## Whether a point is *in* the water, `Water.in_water`: a bot does not doze in it any more
## than the player's goat does (M20f'), and one the rain reaches gets up. It is the HUD's own
## line (`depth_at >= HUD_MIN`) and deliberately *not* `Water.submerged_at`, which is the
## grid test the grass cull asks: near a pool's edge the two disagree, and one of them is
## the one the scene's sleep rule uses.
var in_water: Callable = Callable()

## The herd, oldest first. A bot that dies is replaced by itself rather than by nothing,
## so the index is stable and the length is the setting's.
var _bots: Array[Bot] = []
## Highest belly any bot has reached this run, and how many times a bot has set off to walk
## to a tuft. Both are the scene's own counters, logged so the harness can see the herd
## actually fed itself.
var belly_max := 0.0
var graze_walks := 0

var _rng := RNG_SEED
## The model's clips by role, in variant order, and their lengths -- read from the first
## rig, since every goat in the herd is the same model. `player_goat.gd` indexes the same
## table in the same way for the player; this is a second reader of one source rather than
## a second copy of a rule, so a re-exported model moves both.
var _roles := {}
var _durations := {}
## The model's own lowest point, negated, so a bot's feet land on the ground rather than at
## its origin. Measured once, off the first rig.
var _ground_offset := 0.0
var _measured := false
## One material per coat: `makeBotTextures`' mottle, shared by every bot wearing it.
var _coats: Array[StandardMaterial3D] = []

## Grow or shrink the herd to `count` (0..10). A bot that leaves takes its rig with it.
func set_herd_size(count: int) -> void:
	var want: int = clampi(int(round(float(count))), 0, MAX_HERD)
	while _bots.size() > want:
		var leaving: Bot = _bots.pop_back()
		if leaving.node != null:
			leaving.node.queue_free()
	while _bots.size() < want:
		if not _add(_bots.size()):
			break

## The herd's own wake actors: `(x, z, py)` a bot, in bot order. A *flat* run rather than an
## array of arrays, because the wake takes one of these a frame and gives it straight back to
## `Water.wake_step`, and because the numbers are doubles the water's own mark measures a
## stride against.
##
## `py` is the height above the ground a bot is drawn at, which is what the wake's own test
## reads: a bot in the air over a pool is not in it.
func actors() -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(_bots.size() * 3)
	var at: int = 0
	for bot: Bot in _bots:
		out[at] = bot.x
		out[at + 1] = bot.z
		out[at + 2] = bot.py
		at += 3
	return out

## How many goats the herd holds.
func count() -> int:
	return _bots.size()

## Take the herd's stream from the session seed. `weather.js` `sceneUseSeed` draws the
## weather first and the bots second, so this is the *second* draw -- the same shape
## `explosions.gd` uses for the fifth (`trapSalt`), and only reachable in a session the
## scene is *hosting*, which today it never is. It is here so a host and a peer agree.
func use_seed(seed: int) -> void:
	var state: int = _i32(seed)
	if state == 0:
		state = 1
	var value: int = 1
	for draw in 2:
		state = _step(state)
		if state == 0:
			state = 1
		value = state
	_rng = value

## The temperament and coat for bot `index`. Only six fleeces are hand-authored, so past
## the sixth the coats recycle with a bigger body -- enough variety up to the settings' ten
## goats.
func spec_of(index: int) -> Dictionary:
	var base: Dictionary = SPEC[index % SPEC.size()]
	var cycle: int = index / SPEC.size()
	if cycle == 0:
		return base
	return {
		"coat": base["coat"],
		"scale": float(base["scale"]) * (1.0 + 0.08 * float(cycle)),
		"bold": base["bold"],
		"lazy": base["lazy"],
		"name": base["name"],
	}

## `bots.js` `botRnd`: one xorshift32 draw from the herd's own stream. Returned as
## `uint32 / 2**32`, so it is the unsignd value that is divided -- a signed int32 would
## make half the draws negative.
func bot_rnd() -> float:
	_rng = _step(_rng)
	return float(_rng) / 4294967296.0

## The model's clips for a role, in variant order -- and so every pose the role can cycle
## through. `player_goat.gd` `clip_names`, read off the same model.
func clip_names(role: String) -> PackedStringArray:
	var names: Variant = _roles.get(role, null)
	if names is PackedStringArray:
		return names
	return PackedStringArray()

## Whether the model has any clip for a role at all -- `CLIP[role]` in the scene.
func has_role(role: String) -> bool:
	return not clip_names(role).is_empty()

## How many variants a role has. `bots.js` `clipCount` answers 0 for a role with a single
## clip and the list's length for one that cycles (`idle`, `sleep`, `jump`, `eat`); the
## port answers the list's length either way, and the only use is a `> 1` test, so the two
## are the same question.
func clip_count(role: String) -> int:
	return clip_names(role).size()

## The clip a role's variant names, wrapping the index the way `clipAt` does -- which is
## what makes a bot's initial `-1` the role's *last* variant rather than its first.
func clip_at(role: String, variant: int) -> String:
	var names: PackedStringArray = clip_names(role)
	if names.is_empty():
		return ""
	var n: int = names.size()
	return names[((variant % n) + n) % n]

## The length of that clip, or 0 when the role has none.
func clip_length(role: String, variant: int) -> float:
	var lengths: Variant = _durations.get(role, null)
	if not (lengths is PackedFloat64Array):
		return 0.0
	var n: int = (lengths as PackedFloat64Array).size()
	if n == 0:
		return 0.0
	return (lengths as PackedFloat64Array)[((variant % n) + n) % n]

## The clip role a bot is playing right now, falling back the way `clipRole` does: the
## mode's own role when the model has one, and the **walk** for any role it does not. Dead
## is not a gait -- a corpse plays the death clip -- and a flung bot reads as the jump when
## the model has no flung clip.
func bot_role(bot: Bot) -> String:
	if bot.mode == "dead" and has_role("death"):
		return "death"
	if bot.mode == "flung":
		return "flung" if has_role("flung") else "jump"
	if bot.mode == "jump" and has_role("jump"):
		return "jump"
	if bot.mode == "eat" and has_role("eat"):
		return "eat"
	if bot.mode == "sleep" and has_role("sleep"):
		return "sleep"
	if bot.mode == "run" and has_role("run"):
		return "run"
	if bot.mode == "trot" and has_role("trot"):
		return "trot"
	if bot.mode == "idle" and has_role("idle"):
		return "idle"
	return "walk"

## The fraction through a flung bot's arc, which is what the pose is stretched over.
func fling_progress(bot: Bot) -> float:
	return minf(bot.fly_time / bot.fly_flight, 1.0)

## Whether a bot is over the ground rather than on it. A jump is airborne by mode (the
## clip's root motion does the hop, so there is no height to read) and a flung bot owns its
## own height.
func airborne(bot: Bot) -> bool:
	return bot.mode == "jump" or bot.mode == "flung"

## A lethal bang (M19a). The blast that kills a bot does not also throw it -- that is the
## one place this differs from the player, whose arc and damage land together -- but a bot
## killed *in the air* keeps the arc it already had, so a chain on a flung bot drops a
## corpse rather than teleporting one to the ground.
func die(bot: Bot) -> void:
	bot.health = 0.0
	bot.mode = "dead"
	bot.death_time = 0.0
	bot.graze = false
	bot.zoom = 0.0
	var variants: int = clip_count("death")
	if variants > 1:
		bot.variants["death"] = (int(bot.variants["death"]) + 1) % variants
	var index: int = int(bot.variants["death"])
	var length: float = clip_length("death", index)
	# With no death clip there is nothing to stretch the fraction over (`bot_role` falls
	# through to the walk), so any positive number will do -- but it has to be one,
	# because the pose divides by it.
	bot.death_dur = length if (not clip_at("death", index).is_empty() and length > 0.0) else 1.0

## Take a blast's impulse (M19c), the player's `start_fling` in a bot's fields. A second
## bang mid-arc *adds* to the arc rather than restarting it, so a chain through a minefield
## reads as one continuous throw.
func start_fling(bot: Bot, vx: float, vz: float, vy: float) -> void:
	if bot.mode != "flung":
		bot.fly_y = Terrain.height_at(bot.x, bot.z)   # the arc starts where the bot is
		bot.fly_time = 0.0
		bot.mode = "flung"
		bot.timer = 0.0
		bot.graze = false
		bot.zoom = 0.0
	bot.fly_vx += vx
	bot.fly_vz += vz
	bot.fly_vy += vy
	var air: float = 0.4
	if bot.fly_vy > 0.0 and PlayerGoat.FLING_GRAVITY < 0.0:
		air = (-2.0 * bot.fly_vy) / PlayerGoat.FLING_GRAVITY
	bot.fly_flight = clampf(bot.fly_time + air, 0.3, PlayerGoat.FLING_MAX_FLIGHT)

## Kill the bot the herd holds at `index`. `bots.js` `botDie` has no index because the
## caller is already holding the bot; this is the seam a blast and a gate reach it by.
func kill_at(index: int) -> void:
	if index >= 0 and index < _bots.size():
		die(_bots[index])

## Give the bot at `index` a blast's impulse.
func fling_at(index: int, vx: float, vz: float, vy: float) -> void:
	if index >= 0 and index < _bots.size():
		start_fling(_bots[index], vx, vz, vy)

## Take a bang's damage and, if the bot survives it, its throw. `bots.js` `blast`'s herd
## half, which is the one place a bot differs from the player: the same curve off the same
## radius, and **not** the player's `healthFloor`, which is the promise that a mine cannot
## end *this* player's run. `damage`, `push` and `lift` arrive already scaled by the blast's
## falloff, and `direction` is the away-from-the-blast unit vector the throw goes along
## (the devices' own `flingDirection`). Answers whether the bot is still on its feet.
func blast_at(index: int, damage: float, push: float, lift: float,
		direction: Vector2) -> bool:
	var bot: Bot = _bots[index]
	bot.health = maxf(0.0, bot.health - damage)
	if bot.health <= 0.0:
		die(bot)
		return false
	start_fling(bot, direction.x * push, direction.y * push, lift)
	return true

## A bot's state as a plain dictionary, for a probe or a gate: what the frame reads,
## rather than a second derivation of it. `clip` is the clip the rig is actually playing,
## so a pose that disagrees with the role shows up here.
func state(index: int) -> Dictionary:
	var bot: Bot = _bots[index]
	return {
		"x": bot.x, "z": bot.z, "yaw": bot.yaw, "phase": bot.phase,
		"mode": bot.mode, "timer": bot.timer, "satiety": bot.satiety,
		"health": bot.health, "clip": bot.clip, "py": bot.py,
		"scale": float(bot.spec["scale"]),
	}

## One frame of the herd, in `updateBots`'s own order: the corpse's fall, then the timers,
## then the one branch the mode picks. `weather` is this frame's snapshot in the shape
## `weather.js`'s `weatherSpeedFor` reads its module scope in -- `rain_amount` and
## `wind_sway` -- which is why it is handed in rather than read.
func update(delta: float, weather: Dictionary) -> void:
	var rain: float = float(weather.get("rain_amount", 0.0))
	var sway: float = float(weather.get("wind_sway", 0.0))
	for bot: Bot in _bots:
		if bot.mode == "dead":
			# The body lies where it fell, playing the death clip, and nothing else
			# happens to it -- no AI, no grazing and no devices, since a corpse does not
			# set off a mine. The one thing it still does is fall: a bot killed mid-arc
			# lands, and the clip plays on the way down.
			bot.death_time += delta
			if bot.py > 0.0:
				bot.x += bot.fly_vx * delta
				bot.z += bot.fly_vz * delta
				bot.fly_vy += PlayerGoat.FLING_GRAVITY * delta
				bot.fly_y += bot.fly_vy * delta
				bot.py = bot.fly_y - Terrain.height_at(bot.x, bot.z)
				if bot.fly_vy <= 0.0 and bot.py <= 0.0:
					bot.py = 0.0
					bot.fly_vx = 0.0
					bot.fly_vy = 0.0
					bot.fly_vz = 0.0
			if bot.death_time >= DEATH_LINGER:
				_respawn(bot)
			_place(bot)
			continue

		bot.timer -= delta
		# ...and one the rain reaches gets up, for the same reason and in the same way the
		# player's goat does: `new_action` is where a sleep is refused and this is where
		# one that has already started ends. No draw is taken -- the timer goes to zero,
		# so the plan that follows is the ordinary one for this frame.
		if bot.mode == "sleep" and _in_water(bot.x, bot.z):
			bot.mode = "idle"
			bot.timer = 0.0
		if bot.jump_cool > 0.0:
			bot.jump_cool -= delta
		if bot.eat_cool > 0.0:
			bot.eat_cool -= delta
		if bot.satiety > 0.0:
			bot.satiety = maxf(0.0, bot.satiety - Meadow.SATIETY_DECAY * delta)
		if bot.satiety > belly_max:
			belly_max = bot.satiety

		if bot.mode == "flung":
			# The arc, the player's exactly: an absolute height with `py` derived from it,
			# so a slope crossed mid-air cannot drag the bot, and the ground it actually
			# meets that ends the flight. There is no AI while it flies.
			bot.fly_time += delta
			bot.x += bot.fly_vx * delta
			bot.z += bot.fly_vz * delta
			bot.fly_vy += PlayerGoat.FLING_GRAVITY * delta
			bot.fly_y += bot.fly_vy * delta
			bot.py = bot.fly_y - Terrain.height_at(bot.x, bot.z)
			if bot.fly_vy <= 0.0 and bot.py <= 0.0:
				bot.py = 0.0
				bot.fly_vx = 0.0
				bot.fly_vy = 0.0
				bot.fly_vz = 0.0
				bot.mode = "idle"
				bot.timer = 1.5 + bot_rnd() * 3.0
		elif bot.mode == "jump":
			# Airborne: the jump clip's root motion does the hop, so this only carries the
			# bot forward along its heading.
			bot.jump_time += delta
			bot.x += cos(bot.yaw) * bot.jump_speed * delta
			bot.z += -sin(bot.yaw) * bot.jump_speed * delta
			if bot.jump_time >= bot.jump_dur:
				if bot.zoom > 0.0:
					bot.mode = "run"        # still zooming: run on
					bot.jump_cool = 0.4 + bot_rnd() * 1.2
				else:
					bot.mode = "idle"
					bot.timer = 1.5 + bot_rnd() * 3.0
		elif bot.mode == "eat":
			# A meal is one-shot: hold position, play it out, then move on.
			bot.eat_time += delta
			if bot.eat_time >= bot.eat_dur:
				bot.mode = "idle"
				bot.timer = 1.5 + bot_rnd() * 3.0
		else:
			_gait(bot, delta, rain, sway)

		# A hard backstop: if a bot ever gets really far, pull it back in.
		var away_x: float = bot.x - goat.px
		var away_z: float = bot.z - goat.pz
		var far: float = sqrt(away_x * away_x + away_z * away_z)
		if far > 80.0:
			bot.x = goat.px + (away_x / far) * 80.0
			bot.z = goat.pz + (away_z / far) * 80.0

		_place(bot)

## Pick a new action: graze, stand and gaze, doze, or set off to a wander target, aimed
## back toward the player when the bot has drifted too far.
func new_action(bot: Bot) -> void:
	# The herd grazes too. If a tuft is already under the nose it eats it now; otherwise
	# it walks to the nearest one and eats when it arrives (the arrival check in `_gait`
	# reads the `graze` flag). The cooldown keeps the herd from stripping the field bare.
	if bot.eat_cool <= 0.0 and bot_rnd() < 0.6:
		var near: Dictionary = _nearest(bot.x, bot.z, Meadow.EAT_RANGE)
		if not near.is_empty():
			start_eat(bot, near)
			return
		var far: Dictionary = _nearest(bot.x, bot.z, GRAZE_SEEK_RANGE)
		if not far.is_empty():
			bot.graze = true
			graze_walks += 1
			bot.tx = float(far["x"])
			bot.tz = float(far["z"])
			bot.mode = "walk"
			bot.timer = 14.0      # give up if the walk drags on
			bot.zoom = 0.0
			return
	bot.graze = false
	var roll: float = bot_rnd()
	var spec: Dictionary = bot.spec
	if roll < 0.30 + 0.35 * float(spec["lazy"]):
		# A bot does not doze in the water any more than the player's goat does (M20f').
		# The roll is the same roll and the stream is untouched either way -- one draw on
		# the mode and one on the timer, which is why the *timer* line reads `bot.mode`
		# rather than taking a second draw. The water is only asked when the roll says so,
		# which is `&&`'s short circuit and not a saving of anything.
		var dozing: bool = bot_rnd() < 0.10
		if dozing and not _in_water(bot.x, bot.z):
			bot.mode = "sleep"
			bot.timer = 5.0 + bot_rnd() * 6.0
		else:
			bot.mode = "idle"
			bot.timer = 2.0 + bot_rnd() * 5.0
		bot.zoom = 0.0
		# Rotate the variant, so this bot does not always do the same clip.
		var cycles: int = clip_count(bot.mode)
		if cycles > 1:
			bot.variants[bot.mode] = (int(bot.variants[bot.mode]) + 1) % cycles
		return
	var gait: float = bot_rnd()
	if gait < 0.60:
		bot.mode = "walk"
	elif gait < 0.90:
		bot.mode = "trot"
	else:
		bot.mode = "run"
	bot.timer = 3.0 + bot_rnd() * 9.0
	# A run is a "zoomies" burst: `_gait` throws in the odd jump while it lasts, which is
	# what makes a running bot look like it has the zoomies.
	if bot.mode == "run":
		bot.zoom = 2.5 + bot_rnd() * 4.0
	else:
		bot.zoom = 0.0
	bot.jump_cool = 0.4 + bot_rnd() * 1.0
	var reach: float = 7.0
	if bot.mode == "run":
		reach = 22.0
	elif bot.mode == "trot":
		reach = 14.0
	var dist: float = reach + bot_rnd() * 14.0
	var dx: float = goat.px - bot.x
	var dz: float = goat.pz - bot.z
	var away: float = sqrt(dx * dx + dz * dz)
	var angle: float = 0.0
	if away > 42.0:
		angle = atan2(-dz, dx) + (bot_rnd() - 0.5) * 0.9
	else:
		angle = bot_rnd() * PI * 2.0
	bot.tx = bot.x + cos(angle) * dist
	bot.tz = bot.z - sin(angle) * dist

## Begin a meal: consume `t`, fill the belly, turn onto it and play an eat clip. Used both
## when grass is already under the nose and when a grazing walk arrives.
func start_eat(bot: Bot, target: Dictionary) -> void:
	var cycles: int = clip_count("eat")
	if cycles > 1:
		bot.variants["eat"] = (int(bot.variants["eat"]) + 1) % cycles
	var index: int = int(bot.variants["eat"])
	if meadow != null:
		meadow.consume(int(target["cx"]), int(target["cz"]))
	bot.yaw = atan2(-(float(target["z"]) - bot.z), float(target["x"]) - bot.x)
	# A trapped tuft is a bang for a bot too: the tuft is gone, the belly gets nothing,
	# and the herd is where that pays off -- everyone sees a bot go up in the air.
	var trapped: bool = trap.is_valid() and bool(trap.call(int(target["cx"]),
		int(target["cz"]), float(target["x"]), float(target["z"])))
	if not trapped:
		# The herd's meals get the second helping too: a bot that has grazed its belly
		# full heals a little with every tuft after that, which is the only way back from
		# the bruises a minefield hands it. The belly is read *before* the meal.
		var heal: float = Meadow.sated_heal(bot.satiety)
		bot.satiety = minf(1.0, bot.satiety + Meadow.EAT_SATIETY)
		bot.health = minf(PlayerGoat.STATS_MAX, bot.health + heal)
	bot.mode = "eat"
	bot.eat_time = 0.0
	# The clip decides the meal's length when the model has one, the scene's fallback when
	# it does not -- `info !== null ? info.duration : EAT_FALLBACK_TIME`, which is existence
	# rather than a positive length.
	bot.eat_dur = (clip_length("eat", index) if not clip_at("eat", index).is_empty()
		else PlayerGoat.EAT_FALLBACK_TIME)
	bot.timer = bot.eat_dur
	bot.eat_cool = 20.0 + bot_rnd() * 40.0
	bot.graze = false
	bot.zoom = 0.0

## Push apart any goats that overlap, so nobody can walk through anybody else. Bots yield
## fully to the player (it can shove them) and split the push evenly with each other. Runs
## after both the player and the herd have moved.
func resolve_collisions() -> void:
	if goat == null:
		return
	_collide_pairs(goat.px, goat.pz, GOAT_RADIUS, GOAT_RADIUS * MODEL_SCALE)

## Smallest gap between any two goats (negative means they overlap). The frame log reports
## it, so the harness can assert that collisions actually hold.
func min_gap() -> float:
	var best: float = 1e9
	for i in _bots.size():
		var bot: Bot = _bots[i]
		var dx: float = bot.x - goat.px
		var dz: float = bot.z - goat.pz
		var d: float = sqrt(dx * dx + dz * dz) - GOAT_RADIUS * (
			MODEL_SCALE + float(bot.spec["scale"]))
		if d < best:
			best = d
		for j in range(i + 1, _bots.size()):
			var other: Bot = _bots[j]
			dx = other.x - bot.x
			dz = other.z - bot.z
			d = sqrt(dx * dx + dz * dz) - GOAT_RADIUS * (
				float(bot.spec["scale"]) + float(other.spec["scale"]))
			if d < best:
				best = d
	return best

## Speed for the current gait, from the same stride/duty the player uses, and the frame's
## steering and arrival on top of it. `bots.js` `updateBots`'s final branch, whose two
## subtleties (the role read before `new_action`, the shared timer draw) are named in the
## header.
func _gait(bot: Bot, delta: float, rain: float, sway: float) -> void:
	var role: String = bot_role(bot)
	var index: int = int(bot.variants.get(role, 0))
	var length: float = clip_length(role, index)
	var gait: Variant = PlayerGoat.GAIT.get(role, null)
	var speed: float = 0.0
	if bot.mode != "idle" and bot.mode != "sleep":
		if length > 0.0 and gait != null:
			speed = float(gait["stride"]) / (float(gait["duty"]) * length)
		else:
			speed = (2.0 * PlayerGoat.V_STRIDE) / PlayerGoat.V_CYCLE
		# Rain slows the herd too, each bot eased by its own belly, so a herd that has
		# been grazing keeps its pace in the wet.
		speed = speed * (0.75 + 0.5 * float(bot.spec["bold"])) \
			* PlayerGoat.weather_speed(bot.satiety, rain, sway)

	if speed > 0.0:
		var dx: float = bot.tx - bot.x
		var dz: float = bot.tz - bot.z
		var d: float = sqrt(dx * dx + dz * dz)
		# A grazing walk closes right in on its tuft; other targets stop short.
		var arrive: float = 0.7 if bot.graze else 1.6
		if d < arrive or bot.timer <= 0.0:
			if bot.graze:
				# Arrived: eat whatever is under the nose now (the tuft may have been
				# taken meanwhile), else give up.
				bot.graze = false
				var tuft: Dictionary = _nearest(bot.x, bot.z, Meadow.EAT_RANGE)
				if not tuft.is_empty():
					start_eat(bot, tuft)
				else:
					bot.mode = "idle"
					bot.timer = 1.5 + bot_rnd() * 3.0
			elif bot.mode == "run" and bot.zoom > 0.0:
				# Mid-zoomies: grab a fresh target and keep going.
				var angle: float = bot_rnd() * PI * 2.0
				var radius: float = 9.0 + bot_rnd() * 12.0
				bot.tx = bot.x + cos(angle) * radius
				bot.tz = bot.z - sin(angle) * radius
				bot.timer = 2.0 + bot_rnd() * 3.0
			else:
				bot.mode = "idle"
				bot.timer = 1.5 + bot_rnd() * 4.0
		else:
			# Steer toward the target (the goat faces local +X, so heading `yaw` moves
			# along (cos, -sin) in the XZ plane).
			var want: float = atan2(-dz, dx)
			var diff: float = want - bot.yaw
			while diff > PI:
				diff -= PI * 2.0
			while diff < -PI:
				diff += PI * 2.0
			bot.yaw += clampf(diff, -TURN * delta, TURN * delta)
			bot.x += cos(bot.yaw) * speed * delta
			bot.z += -sin(bot.yaw) * speed * delta
	elif bot.timer <= 0.0:
		new_action(bot)

	# Zoomies: while a run lasts, hop every second or so.
	if bot.mode == "run":
		bot.zoom -= delta
		if bot.zoom > 0.0 and bot.jump_cool <= 0.0 and speed > 0.0:
			bot.mode = "jump"
			var jumps: int = clip_count("jump")
			if jumps > 1:
				bot.variants["jump"] = (int(bot.variants["jump"]) + 1) % jumps
			var jump_index: int = int(bot.variants["jump"])
			bot.jump_dur = (clip_length("jump", jump_index)
				if not clip_at("jump", jump_index).is_empty()
				else PlayerGoat.JUMP_FALLBACK_TIME)
			bot.jump_time = 0.0
			bot.jump_speed = speed * 1.15
			bot.jump_cool = 0.5 + bot_rnd() * 1.3

	# Advance the looping clip (jumps pose themselves from `jump_time`). Two things about
	# this line are the scene's, and both are deliberate. The **role** is the one read at the
	# top, so a bot that changed its mind this frame advances the phase of the clip it was
	# *playing* rather than the one it just picked. And the **variant** is read *again* here
	# rather than reused from the speed above, because `new_action` may have cycled it: a bot
	# that re-chose `idle` moves to the next idle clip and advances *that* one's phase from
	# its first frame. Reusing the speed's index instead is worth 4e-4 of phase -- one
	# frame's advance -- which is small, invisible, and a divergence that never comes back.
	if bot.mode != "jump":
		var current: int = int(bot.variants.get(role, 0))
		var duration: float = clip_length(role, current)
		if duration <= 0.0:
			duration = PlayerGoat.V_CYCLE
		bot.phase = _mod1(bot.phase + delta / duration)

## Bring a dead bot back (M19a). The herd keeps the size the setting asks for, so a bot
## that dies is replaced by itself: it gets up out of the way, facing the player, with a
## whole skin. Ground with no armed mine under it is preferred, but eight tries is the
## whole of the search and a dense field has no clean ground left to offer.
func _respawn(bot: Bot) -> void:
	var x: float = bot.x
	var z: float = bot.z
	for attempt in 8:
		var angle: float = bot_rnd() * PI * 2.0
		var radius: float = 10.0 + bot_rnd() * 16.0
		x = goat.px + cos(angle) * radius
		z = goat.pz + sin(angle) * radius
		if not _mine_armed(x, z):
			break
	bot.x = x
	bot.z = z
	bot.yaw = atan2(-(goat.pz - z), goat.px - x)
	bot.health = PlayerGoat.STATS_MAX
	bot.death_time = 0.0
	bot.py = 0.0
	bot.fly_time = 0.0
	bot.fly_flight = 1.0
	bot.fly_vx = 0.0
	bot.fly_vy = 0.0
	bot.fly_vz = 0.0
	bot.satiety = 0.0
	bot.graze = false
	bot.zoom = 0.0
	bot.mode = "idle"
	bot.timer = 1.5 + bot_rnd() * 3.0

## Push apart everything overlapping, `collidePairs`' two relaxation passes: shoving a bot
## off the player can push it into another bot, so a second pass settles the chain -- but
## only a pass that moved something can have made a chain, and the herd spends most frames
## touching nobody. A chain still settles inside the frame it was made in.
func _collide_pairs(px: float, pz: float, radius: float, player_radius: float) -> void:
	var moved: bool = true                 # the first pass always runs
	var pass_number: int = 0
	while pass_number < 2 and moved:
		pass_number += 1
		moved = false
		for bot: Bot in _bots:
			var apart: float = player_radius + radius * float(bot.spec["scale"])
			var dx: float = bot.x - px
			var dz: float = bot.z - pz
			var d2: float = dx * dx + dz * dz
			if d2 < apart * apart:
				if d2 <= 1e-4:
					bot.x = px + apart    # dead centre: shove it out sideways
				else:
					var d: float = sqrt(d2)
					var push: float = (apart - d) / d
					bot.x += dx * push
					bot.z += dz * push
				if bot.timer > 0.6:
					bot.timer = 0.6       # re-think the plan soon
				moved = true
		for i in _bots.size():
			var a: Bot = _bots[i]
			var a_radius: float = radius * float(a.spec["scale"])
			for j in range(i + 1, _bots.size()):
				var b: Bot = _bots[j]
				var gap: float = a_radius + radius * float(b.spec["scale"])
				var bx: float = b.x - a.x
				var bz: float = b.z - a.z
				var bd2: float = bx * bx + bz * bz
				if bd2 < gap * gap and bd2 > 1e-4:
					var bd: float = sqrt(bd2)
					var push: float = (gap - bd) / (2.0 * bd)
					a.x -= bx * push
					a.z -= bz * push
					b.x += bx * push
					b.z += bz * push
					moved = true

## Draw one bot where the simulation left it. `bots.js` `drawBots`, minus the contact blob
## Godot's own shadows make unnecessary. A one-shot role (jump, eat, death, flung) poses
## from its own clock and the rest loop, which is the only thing that can pose a clip that
## is not a loop.
func _place(bot: Bot) -> void:
	if bot.node == null:
		return
	var scale: float = float(bot.spec["scale"])
	var y: float = Terrain.height_at(bot.x, bot.z) + _ground_offset * scale + bot.py
	bot.node.position = Vector3(bot.x, y, bot.z)
	bot.node.rotation = Vector3(0.0, bot.yaw, 0.0)
	bot.node.scale = Vector3(scale, scale, scale)
	var role: String = bot_role(bot)
	var pose: float = bot.phase
	if bot.mode == "jump":
		pose = minf(bot.jump_time / bot.jump_dur, 1.0)
	elif bot.mode == "eat":
		pose = minf(bot.eat_time / bot.eat_dur, 1.0)
	elif bot.mode == "dead" and has_role("death"):
		pose = minf(bot.death_time / bot.death_dur, 1.0)
	elif bot.mode == "flung":
		pose = fling_progress(bot)
	if bot.anim == null:
		return
	var clip: String = clip_at(role, int(bot.variants.get(role, 0)))
	if clip.is_empty():
		return
	if clip != bot.clip:
		bot.clip = clip
		bot.anim.play(clip)
	var animation: Animation = bot.anim.get_animation(clip)
	if animation != null:
		bot.anim.seek(fmod(pose, 1.0) * animation.length, true)

## Load one bot's rig and give it its coat. A golden-angle spread rings the player evenly
## for any herd size, which is why a bot is placed from its index rather than from a
## random bearing.
func _add(index: int) -> bool:
	var node: Node3D = GOAT_SCENE.instantiate()
	if node == null:
		return false
	add_child(node)
	if not _measured:
		_measure(node)
	if not _coats.is_empty():
		var mesh_instance: MeshInstance3D = _find_mesh(node)
		if mesh_instance != null:
			mesh_instance.set_surface_override_material(
				0, _coats[index % _coats.size()])
	var angle: float = float(index) * 2.399963 + 0.3
	var radius: float = 6.0 + bot_rnd() * 14.0
	var bot: Bot = Bot.new()
	bot.spec = spec_of(index)
	bot.x = goat.px + cos(angle) * radius
	bot.z = goat.pz + sin(angle) * radius
	bot.yaw = angle + PI
	bot.phase = bot_rnd()
	bot.mode = "idle"
	bot.timer = 0.5 + bot_rnd() * 3.0
	bot.health = PlayerGoat.STATS_MAX
	bot.variants = {
		"idle": -1, "sleep": -1, "jump": -1, "eat": -1,
		"walk": 0, "trot": 0, "run": 0, "flung": -1, "death": -1,
	}
	bot.node = node
	bot.anim = _find_animation(node)
	_bots.append(bot)
	return true

## The model's own lowest point, negated, and its clips by role. Both are read once, off
## the first rig built: every goat in the herd is the same model, so its clips and its
## feet are a fact about the model rather than about a bot.
func _measure(node: Node3D) -> void:
	_measured = true
	var mesh_instance: MeshInstance3D = _find_mesh(node)
	if mesh_instance != null and mesh_instance.mesh != null:
		_ground_offset = -mesh_instance.mesh.get_aabb().position.y
	_build_coats()
	var anim: AnimationPlayer = _find_animation(node)
	for role in ROLES:
		_roles[role] = PackedStringArray()
		_durations[role] = PackedFloat64Array()
	if anim == null:
		return
	for name in anim.get_animation_list():
		var text: String = String(name)
		for role in ROLES:
			# The model's names are `GoatIdle`, `GoatIdle2`, `GoatDeath`, ... so the role
			# is `Goat` plus the role's own capitalised name. `eat` needs no special case
			# here the way `findClips(names, "goateat")` does in the scene, because a
			# *prefix* cannot match `GoatDeath` the way a substring can.
			if text.begins_with("Goat" + role.capitalize()):
				var animation: Animation = anim.get_animation(text)
				_roles[role].append(text)
				_durations[role].append(animation.length if animation != null else 0.0)
				break

## One mottled fleece per coat colour, `makeBotTextures`' three octaves of `vnoise2` at the
## scene's own frequencies and amplitudes, tinted by the coat and sharing one material per
## colour. Built once, and only when a herd is.
func _build_coats() -> void:
	for i in SPEC.size():
		var coat: Array = SPEC[i]["coat"]
		var red: float = float(coat[0])
		var green: float = float(coat[1])
		var blue: float = float(coat[2])
		var image: Image = Image.create_empty(COAT_SIZE, COAT_SIZE, false, Image.FORMAT_RGBA8)
		for y in COAT_SIZE:
			for x in COAT_SIZE:
				var noise: float = \
					0.55 * Terrain.vnoise2(x * 0.17 + i * 13.7, y * 0.17 + i * 5.1) \
					+ 0.30 * Terrain.vnoise2(x * 0.39 + i * 3.3, y * 0.39 + i * 9.9) \
					+ 0.15 * Terrain.vnoise2(x * 0.86 + i, y * 0.86 + i * 2.0)
				var shade: float = 0.62 + 0.70 * (noise - 0.5)
				image.set_pixel(x, y, Color8(
					_byte(red * shade), _byte(green * shade), _byte(blue * shade), 255))
		var material := StandardMaterial3D.new()
		material.albedo_texture = ImageTexture.create_from_image(image)
		# Godot 4 replaced the `TextureRepeat` enum with a flag; the mottle tiles.
		material.texture_repeat = true
		_coats.append(material)

## The nearest edible tuft within `reach`, or an empty dictionary. A thin wrapper, because
## the meadow owns the search and this file only asks it.
func _nearest(x: float, z: float, reach: float) -> Dictionary:
	if meadow == null:
		return {}
	return meadow.nearest(x, z, reach)

## Whether a point is in the water, through the seam `main.gd` wires to `Water.in_water`.
## Off the water -- or with no water handed in -- nothing is.
func _in_water(x: float, z: float) -> bool:
	if not in_water.is_valid():
		return false
	return bool(in_water.call(x, z))

## Whether an armed mine stands under a point, through the seam `main.gd` wires to
## `Explosions.mine_armed`. The cell is the 2 m device grid's, not the meadow's.
func _mine_armed(x: float, z: float) -> bool:
	if not armed.is_valid():
		return false
	return bool(armed.call(int(floor(x / 2.0)), int(floor(z / 2.0))))

## `| 0`: wrap to int32.
static func _i32(value: int) -> int:
	var low: int = value & 0xFFFFFFFF
	if low >= 0x80000000:
		return low - 0x100000000
	return low

## `>>>`: a right shift of the value read as unsigned.
static func _ushr(value: int, bits: int) -> int:
	return (value & 0xFFFFFFFF) >> bits

## One xorshift32 step, the three lines `bots.js`'s `botRnd` and `sceneUseSeed` run. The
## state comes back unsigned, which is what makes `bot_rnd`'s division land in `[0, 1)`.
static func _step(state: int) -> int:
	var s: int = _ushr(state, 0)
	s = _ushr(s ^ _i32(s << 13), 0)
	s = _ushr(s ^ _ushr(s, 17), 0)
	s = _ushr(s ^ _i32(s << 5), 0)
	return s

## `core.js` `mod1`: `((v % 1) + 1) % 1`, spelled out rather than `fposmod`, because the
## two differ at the far edge of a double -- `fposmod(-1e-17, 1)` is 1, and the scene's is
## 0.
static func _mod1(value: float) -> float:
	return fmod(fmod(value, 1.0) + 1.0, 1.0)

## `Math.round(clamp(v, 0, 255))` for a colour channel.
static func _byte(value: float) -> int:
	return int(round(clampf(value, 0.0, 255.0)))

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
