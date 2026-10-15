# The water's reflection (M20e): the setting's three tiers, and the port's answer to what the
# surface reflects.
#
# `water.js` answers "what does the surface reflect" three ways -- the sky alone, the ground
# baked into a texture the fragment shader marches, and the world rendered mirrored about the
# table -- behind one clamped leaf, `TUNING.water.reflection`, with the *wish* the leaf holds
# and the *promise* the frame can keep told apart (`waterReflectTier`). A tier a build cannot
# keep degrades to the one below it rather than failing, the way `applySettings` degrades a
# shadow mode the engine has no map for.
#
# The port answers the same question with **Godot's own environment** instead of the scene's
# bake and mirrored pass (`PORT.md` sections 3 and 5), and the mapping is exact where it can
# be:
#
#   * **What the reflection sees is `cull_mask`.** A reflection probe's background is the sky,
#     so the three tiers are three masks: nothing (the sky alone), the ground alone, and the
#     world. "The ground, and not the goat" and "everything but the grass" are the scene's own
#     two exclusions -- its tier 1 bakes a grid with no goat in it, and its tier 2 deliberately
#     leaves the grass out because a tuft is two cubes of noise in a reflection and the grass
#     is the frame's largest phase -- and they are expressible here only because the ground is
#     on a layer of its own (`LAYER_GROUND`) and the things that must never be in a reflection
#     on another (`LAYER_NOREFLECT`: the meadow, the surface itself, and the drops -- a
#     reflection that contained the surface would reflect itself). Both are set by `main.gd`.
#   * **What it costs is `update_mode`.** `UPDATE_ONCE` for the two static tiers and
#     `UPDATE_ALWAYS` for the mirror, which is the scene's own ladder: one bake, no pass at
#     all, and a pass a frame. `UPDATE_ONCE` is the default tier for the reason the scene gave
#     -- it costs no pass and no state.
#
# One engine fact shapes the cadence, and it is worth the sentence: **a `ReflectionProbe` in
# `UPDATE_ONCE` re-bakes when its *transform* moves, not when the ground under it changes**
# (Godot says so, and it is why the probe carries moving geometry by being *moved*). So the
# port's re-bake is a nudge of a tenth of a millimetre, and this node owns when it happens:
# with the ground (`refresh`'s `ground_changed`) and on a slow cadence, because the same
# cubemap carries the *sky*, which drifts. The cadence is the port's own number and the one
# place the two engines genuinely differ -- the scene's tier 1 has a live sky and a frozen
# ground because its bake is only the ground, while anything Godot bakes is frozen whole.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterReflect
extends ReflectionProbe

## `water.js`'s three tiers, by the numbers the leaf holds.
const SKY := 0
const GROUND := 1
const MIRROR := 2

## `TUNING.water.reflection`'s own default, and `TUNING_CLAMP["water.reflection"]`: the leaf
## is a *closed* range and nothing else.
const DEFAULT := 1
const LEAST := 0
const MOST := 2

## `ctl.js`'s `CTL_REFLECT`, which is what both the `setting reflect` route and the menu's
## combo box spell the tiers with.
const NAMES: Array[String] = ["sky", "ground", "mirror"]

## The three layers the tiers are built out of: the ground (the heightfield grid, craters and
## all, since a crater is a term in the heights), the *surface* -- the one thing in the scene
## that receives a reflection -- and the things that must never appear in one. Everything
## else -- the goat, the herd, the devices, the bodies -- keeps layer 1.
##
## They start at layer 5, and that is not arbitrary: **layer 2 is already the moon's**
## (`celestial.gd`'s `MOON_LAYER`, which the moon's own light is masked to), and a collision
## with it is silent and expensive -- the ground moved onto it went pale, because the moon's
## light was suddenly lighting the terrain as well as the moon. A layer is a global number
## and nothing checks it is free.
const LAYER_GROUND := 1 << 4
const LAYER_WATER := 1 << 5
const LAYER_NOREFLECT := 1 << 6

## What the probe *sees*, which is the tier. `MASK_SKY` is empty on purpose: a probe still
## renders the sky behind whatever its mask admits, so "nothing" *is* "the sky alone".
const MASK_SKY := 0
const MASK_GROUND := LAYER_GROUND
const MASK_WORLD := 0xFFFFF & ~(LAYER_WATER | LAYER_NOREFLECT)

## ...and what it reflects *onto*, which is the one layer that reads it. A probe reflects onto
## every instance in its box, and the ground here is a single 96 m mesh -- so a probe left to
## reflect onto layer 1 would tint the terrain from its cubemap as well as the water. Only the
## surface receives.
const REFLECT_TO := LAYER_WATER

## Seconds between the two static tiers' re-bakes. A `UPDATE_ONCE` probe is frozen until it is
## moved, and the cubemap it is frozen with holds the sky as well as the ground -- so a
## re-bake slower than this would show an hour-old sky in the water, and one faster than it
## would pay for a submission the tier exists to avoid.
const REFRESH := 0.25

## The leaf itself (`TUNING.water.reflection`): a finite number in `LEAST..MOST`, and *not*
## an integer -- `tuningCoerce` clamps it and `waterReflectTier` is what rounds it, which is
## why `1.6` is a legal leaf and answers `MIRROR`.
var wish: float = DEFAULT

## How many times the probe has been told to bake, which is the port's answer to the scene's
## `bakeWhole`/`bakeRect` counters: a case reads it across a frame the way it counts draws.
var bakes := 0

## Whether this build has a renderer to bake a mirror from every frame. `--headless` has
## none, and that is the whole of the port's `waterMirrorOK` -- Godot has the bindings the
## scene had to check for, so what is left is the window. It is a var rather than a call to
## `DisplayServer` in the predicate so a gate can claim the window a headless run cannot
## have, which is the only way to exercise the tier it gates.
var mirror_capable := true

var _since_bake := 0.0

func _ready() -> void:
	mirror_capable = DisplayServer.get_name() != "headless"
	reflection_mask = REFLECT_TO
	apply()

## The scene's `waterReflectTier`, transcribed: the wish rounded, and a tier the build cannot
## keep falling to the one below rather than to nothing. `Math.round` rounds half toward
## +infinity and `roundi` away from zero; the clamp above admits no negative leaf, so the two
## agree on every value that reaches here.
static func promise(want: float, can_ground: bool, can_mirror: bool) -> int:
	var tier: int = roundi(want)
	if tier >= MIRROR and can_mirror:
		return MIRROR
	if tier >= GROUND and can_ground:
		return GROUND
	return SKY

## The leaf as the tuning system stores it (`tuningCoerce`'s clamp, and no rounding).
static func clamp_wish(value: float) -> float:
	return clampf(value, LEAST, MOST)

## A `setting reflect <word>`'s word as a tier, or `-1` for one the scene does not know --
## which `ctl.js` answers with an error, leaving the leaf where it was.
static func word_tier(word: String) -> int:
	for tier in NAMES.size():
		if NAMES[tier] == word:
			return tier
	return -1

## The word a tier is spelled with.
static func tier_word(tier: int) -> String:
	if tier < 0 or tier >= NAMES.size():
		return ""
	return NAMES[tier]

## The mask a tier reads the world through. `"the ground, and not the goat"` is tier 1's
## whole content -- layer 1 carries the goat and the herd -- and `"everything but what must
## not be in a reflection"` is tier 2's.
static func mask_of(tier: int) -> int:
	if tier == SKY:
		return MASK_SKY
	if tier == GROUND:
		return MASK_GROUND
	return MASK_WORLD

## How often a tier bakes: the two static tiers once, the mirror a frame. This is the cost
## ladder the setting exists as a lever over.
static func mode_of(tier: int) -> ReflectionProbe.UpdateMode:
	return UPDATE_ALWAYS if tier == MIRROR else UPDATE_ONCE

## Whether the ground tier can be kept: a probe in a tree has something to bake into.
func can_ground() -> bool:
	return is_inside_tree()

## Whether the mirror can. The scene's `waterMirrorOK` asks for the bindings *and a window to
## size its target to*; Godot has the bindings always, so what is left is the window, and a
## tier that needs a renderer a frame degrades to the ground rather than drawing nothing.
func can_mirror() -> bool:
	return can_ground() and mirror_capable

## The tier this frame actually gets (`waterReflectTier`).
func tier() -> int:
	return promise(wish, can_ground(), can_mirror())

## Set the leaf and point the probe at what it now reflects. `tuningSet`'s own shape: the
## stored value is clamped, never rounded.
func set_wish(value: float) -> void:
	wish = clamp_wish(value)
	apply()

## Point the probe at what the current tier reflects, and how often it bakes. Called where the
## wish moves; safe to call again.
func apply() -> void:
	var which: int = tier()
	cull_mask = mask_of(which)
	update_mode = mode_of(which)
	reflection_mask = REFLECT_TO
	rebake()

## Pin the ambient the probe lights its box with. A probe *carries* the ambient inside its box
## rather than falling through to the environment's, and the port's ambient is deliberately the
## scene's own flat grade rather than the sky's (`sky.gd` sets `AMBIENT_SOURCE_COLOR`, which is
## what the scene's lit program wanted) -- so the probe is told the same colour, and the ground
## inside the box keeps the grade the scene gave it. `main.gd` feeds it once a frame, where the
## grade has just been settled.
func set_ambient(grade: Color) -> void:
	ambient_mode = AMBIENT_COLOR
	ambient_color = grade
	ambient_color_energy = 1.0

## Re-arm a bake. A `UPDATE_ONCE` probe is told to bake again by being *moved*, which is the
## one thing the engine listens to; the mirror tier bakes every frame already and is left
## alone. The nudge is a tenth of a millimetre and is undone in the same call, so the probe's
## origin does not drift.
func rebake() -> void:
	bakes += 1
	_since_bake = 0.0
	if update_mode != UPDATE_ONCE:
		return
	var nudge := Vector3(0.0001, 0.0, 0.0)
	position = position + nudge
	position = position - nudge

## The two static tiers' cadence: a bake with the ground, and a bake on `REFRESH` seconds.
## The mirror needs neither -- it is a submission a frame.
func refresh(delta: float, ground_changed: bool) -> void:
	if update_mode != UPDATE_ONCE:
		return
	if ground_changed:
		rebake()
		return
	_since_bake += delta
	if _since_bake >= REFRESH:
		rebake()

## `sceneWater`'s own two keys -- the leaf's wish and the frame's promise, which can differ --
## with what the port's bake has done about them.
func report() -> Dictionary:
	return {
		"reflect": roundi(wish),
		"tier": tier(),
		"bakes": bakes,
		"mode": update_mode,
		"mask": cull_mask,
	}
