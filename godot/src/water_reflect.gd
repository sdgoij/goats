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
# The port answers it with **`water_mirror.gd`'s own second camera** -- `renderWaterMirror`
# transcribed -- and that is a measurement rather than a preference. Godot's own `ssr_enabled`
# never reaches a transparent material (it is computed from the opaque pass: toggling it moves
# a frame by 0.000064 with this water transparent against 0.003081 with it made opaque), and
# the port's own screen-space march in the shader found only what sits near the reflector's
# own screen footprint -- a pool reflected a splat of the goat and nothing else.
#
# So the three tiers are the three things the scene's were:
#
#   SKY      no pass at all, and the engine's specular reflection of the sky stands -- which is
#            exactly what M20b-M20d shipped, and the fallback a build with no rasteriser
#            degrades to.
#   GROUND   the pass, drawing the ground **and not the goat** -- the scene's own exclusion
#            ("the bake has no goat in it"), said with a `cull_mask` of the ground's layer
#            alone. It is also where that tier's saving is, since the goats are what a mirror
#            frame has to pose twice.
#   MIRROR   the pass, drawing everything but the surface and the meadow -- so the goat and the
#            herd are in the water, which is the scene's tier 2.
#
# The rule is transcribed exactly -- the leaf and its clamp, the promise, and the words
# `setting reflect` and the menu's combo box spell -- and what each tier *draws* is
# `water_mirror.gd`'s table, beside the camera that uses it.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name WaterReflect
extends RefCounted

## `water.js`'s three tiers, by the numbers the leaf holds.
const SKY := 0
const GROUND := 1
const MIRROR := 2

## The port's default tier, and the end of `TUNING_CLAMP["water.reflection"]`: the leaf is a
## *closed* range and nothing else. The scene's own `TUNING.water.reflection` is `1` (`ground`,
## `core.js`); the port ships `2` (`mirror`) because its ground tier is the pass drawing only
## the ground, while the look the scene's top tier describes -- the goat and the herd in the
## water -- is the one the port can draw. The leaf and its clamp are still the scene's, so
## `setting reflect ground` and a mod's write land exactly as before.
const DEFAULT := 2
const LEAST := 0
const MOST := 2

## `ctl.js`'s `CTL_REFLECT`, which is what both the `setting reflect` route and the menu's
## combo box spell the tiers with.
const NAMES: Array[String] = ["sky", "ground", "mirror"]

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

## What a tier's pass draws, and whether it runs one at all. Both live in `water_mirror.gd`,
## beside the camera that does the drawing: this object owns the *rule*, not the pass.
static func mask_of(which: int) -> int:
	return WaterMirror.mask_of(which)

static func runs(which: int) -> bool:
	return WaterMirror.runs(which)

## Whether the ground tier can be kept. The scene's asks whether the bake was made; a mirrored
## pass needs a *frame*, so the port's asks for a rasteriser -- `--headless` has none, and a
## tier that needs a submission degrades to the sky there rather than drawing nothing.
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

## Point the surface and the pass at the tier. Called where the wish moves -- a tier is a
## setting, and neither the material's uniform nor a camera's cull mask wants touching a frame.
func apply(surface: WaterMesh, mirror: WaterMirror) -> void:
	var which: int = tier()
	surface.set_reflection(which, mirror.texture())
	mirror.set_tier(which)

## `sceneWater`'s own two keys -- the leaf's wish and the frame's promise, which can differ --
## with what the promise draws, and whether it draws anything.
func report() -> Dictionary:
	var which: int = tier()
	return {
		"reflect": roundi(wish),
		"tier": which,
		"mask": mask_of(which),
		"running": runs(which),
	}
