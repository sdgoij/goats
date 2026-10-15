# The water's reflection (M20e): the setting's three tiers, and the port's answer to what the
# surface reflects.
#
# `water.js` answers "what does the surface reflect" three ways -- the sky alone, the ground
# baked into a texture the fragment shader marches, and the world rendered mirrored about the
# table -- behind one clamped leaf, `TUNING.water.reflection`, with the *wish* the leaf holds
# and the *promise* the frame can keep told apart (`waterReflectTier`): no texture, no bake;
# no render texture, no mirror; else the sky. A tier a build cannot keep degrades to the one
# below it rather than failing, the way `applySettings` degrades a shadow mode the engine has
# no map for.
#
# The port answers the same question with its **own screen-space march**, written into
# `water.gdshader` rather than handed to Godot's `ssr_enabled`, and that is a measurement
# rather than a preference: Godot's screen-space reflections are computed from the *opaque*
# pass, so they do not reach an alpha-blended surface at all -- toggling `ssr_enabled` moves a
# frame by 0.000064 with this water transparent and by 0.003081 with it temporarily opaque, a
# 48x difference. The water has to be transparent (the shore fade and the submerged ground are
# M20b's), so the pass has nothing to apply its result to, and the march is the port's.
#
# The scene's tier 1 and tier 2 differ in *what* they read (a baked grid, a mirrored pass); a
# screen-space march can only differ in how far it goes, so the port's ladder is the **cost**
# one that the setting exists to be a lever over:
#
#   SKY      no march at all, and the engine's specular reflection of the sky stands -- which
#            is exactly what M20b-M20d shipped, and the fallback a build with no rasteriser
#            degrades to.
#   GROUND   a short march: the near shore, which is what a grazing view actually sees.
#   MIRROR   a deep one: the same march with three times the reach and twice the steps.
#
# The rule itself is transcribed exactly -- the leaf and its clamp, the promise, and the words
# `setting reflect` and the menu's combo box spell -- and only the budget behind each tier is
# the port's. See `WATER_STEPS` and `WATER_REACH`.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterReflect
extends RefCounted

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

## Each tier's march, as `(steps, reach in metres)`. The steps are capped by the shader's own
## `MAX_STEPS` and the reach is what a step is a slice of, so the two together are the whole
## budget: the sky tier marches nothing, the ground tier looks 12 m with a step a metre, and
## the mirror looks 48 m with a step of two. The numbers are the port's own -- the scene's
## tiers bought different *sources* rather than different distances -- and they are the one
## place this slice had to invent.
const WATER_STEPS := [0, 12, 24]
const WATER_REACH := [0.0, 12.0, 48.0]

## The leaf itself (`TUNING.water.reflection`): a finite number in `LEAST..MOST`, and *not*
## an integer -- `tuningCoerce` clamps it and `waterReflectTier` is what rounds it, which is
## why `1.6` is a legal leaf and answers `MIRROR`.
var wish: float = DEFAULT

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

## How many steps a tier's march takes, and how far it reaches. Both are zero for the sky,
## which marches nothing at all.
static func steps_of(tier: int) -> int:
	if tier < SKY or tier > MIRROR:
		return 0
	return WATER_STEPS[tier]

static func reach_of(tier: int) -> float:
	if tier < SKY or tier > MIRROR:
		return 0.0
	return WATER_REACH[tier]

## Whether the ground tier can be kept. The scene's asks whether the bake was made; a
## screen-space march needs a *frame*, so the port's asks for a rasteriser -- `--headless` has
## none, and a tier that needs a frame a frame degrades to the sky there rather than drawing
## nothing.
func can_ground() -> bool:
	return DisplayServer.get_name() != "headless"

## Whether the mirror can. The scene's asks for a render texture beside a window to size it to;
## Godot has the texture, so what is left is the window -- the same question as `can_ground`,
## and the two are one predicate here on purpose rather than by accident.
func can_mirror() -> bool:
	return can_ground()

## The tier this frame actually gets (`waterReflectTier`).
func tier() -> int:
	return promise(wish, can_ground(), can_mirror())

## Set the leaf. `tuningSet`'s own shape: the stored value is clamped, never rounded.
func set_wish(value: float) -> void:
	wish = clamp_wish(value)

## Push the tier the surface should march with, and its budget. Called where the wish moves.
func apply(surface: WaterMesh) -> void:
	var which: int = tier()
	surface.set_reflection(which, steps_of(which), reach_of(which))

## `sceneWater`'s own two keys -- the leaf's wish and the frame's promise, which can differ --
## with the budget the promise buys.
func report() -> Dictionary:
	var which: int = tier()
	return {
		"reflect": roundi(wish),
		"tier": which,
		"steps": steps_of(which),
		"reach": reach_of(which),
	}
