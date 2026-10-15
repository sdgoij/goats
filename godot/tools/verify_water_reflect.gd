# The reflection gate (M20e): the setting's three tiers against `water.js`'s own.
#
#   Godot --headless --path godot --script res://tools/verify_water_reflect.gd
#
# M20e is the one part of the water that is *mostly* a look, and the port answers it with
# Godot's environment rather than with the scene's bake and mirrored pass (`PORT.md` section
# 3). So what a headless run can hold is the part that is a *rule*:
#
#   * the leaf and its clamp, which `tuningCoerce` does and not `waterReflectTier`;
#   * the promise `waterReflectTier` makes -- the wish rounded, and a tier the build cannot
#     keep falling to the one below it rather than to nothing;
#   * the three words `setting reflect` and the menu's combo box spell (`ctl.js` `CTL_REFLECT`);
#   * and the port's own mapping of a tier onto Godot's probe: what it *sees* (`cull_mask`,
#     which is where "the ground, and not the goat" and "everything but what must not be in a
#     reflection" live) and how often it *costs* (`update_mode`, the ladder the setting is a
#     lever over).
#
# What no case can hold is how any of it *looks* -- the same gap M20b and M20c shipped with,
# and the reason `GOATS_FLOOD`/`GOATS_REFLECT` pictures exist. The oracle is `water.js` and
# its neighbours transcribed from source; the port is asked the same questions.
#
# It runs its checks on the first `_process` frame rather than in `_initialize`, and that is
# not a style choice: `SceneTree.root` is **not inside the tree yet** while `_initialize`
# runs -- `root.is_inside_tree()` is false there and true a frame later -- and the whole of
# the port's half of the promise is a probe that knows *where it is*.
extends SceneTree

## `_process` runs once: `_run` quits the loop, and this keeps a mis-return from running it
## twice and reporting everything a second time.
var _done := false

## `water.js`'s reflection section, and the bits of `core.js` and `ctl.js` it leans on,
## transcribed *from their sources*: the clamp the tuning system stores a leaf with (no
## rounding -- `water.reflection` is not in `TUNING_INT`), the promise `waterReflectTier`
## makes, and the words the `setting reflect` route knows.
const JS := """
const REFLECT_SKY = 0, REFLECT_MAP = 1, REFLECT_MIRROR = 2;
const CTL_REFLECT = { sky: 0, ground: 1, mirror: 2 };
function clamp(v, lo, hi) { return v < lo ? lo : (v > hi ? hi : v); }
function storedLeaf(raw) { return clamp(Number(raw), 0, 2); }
function waterReflectTier(want, mirrorOK, bakeOK) {
    want = Math.round(want);
    if (want >= REFLECT_MIRROR && mirrorOK) return REFLECT_MIRROR;
    if (want >= REFLECT_MAP && bakeOK) return REFLECT_MAP;
    return REFLECT_SKY;
}
const RAW = __RAW__;
for (let i = 0; i < RAW.length; i++) {
    const stored = storedLeaf(RAW[i]);
    for (let m = 0; m < 2; m++) {
        for (let b = 0; b < 2; b++) {
            console.log('tier ' + i + ' ' + m + ' ' + b + ' ' + stored + ' ' +
                waterReflectTier(stored, m === 1, b === 1));
        }
    }
}
const WORDS = __WORDS__;
for (const w of WORDS) {
    console.log('word ' + w + ' ' + (CTL_REFLECT[w] === undefined ? -1 : CTL_REFLECT[w]));
}
"""

## The leaf values the pair are asked about: the clamp's own ends, both sides of each
## rounding boundary, a fractional leaf a mod could write (the leaf is a number, not an
## index), and values past the clamp on both sides.
const RAW := [-1.0, 0.0, 0.49, 0.5, 0.51, 1.0, 1.4, 1.5, 1.6, 2.0, 2.5, 3.0]

## The words the setting route is asked about, matching the oracle's own list. The last two
## are the two ways a word can be *wrong*: one the scene has never heard of, and one spelled
## the way the menu labels it rather than the way the console takes it.
const WORDS := ["sky", "ground", "mirror", "nope", "Sky"]

## The leaf is a double on both sides and the clamp returns either it or an exact end, so the
## two agree to the last bit; the tiers are integers and have no tolerance at all.
const TOLERANCE := 1e-12

func _initialize() -> void:
	# Nothing here: see the note above about the tree.
	pass

func _process(_delta: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true

func _run() -> void:
	var failures: Array[String] = []

	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var source: String = JS.replace("__RAW__", JSON.stringify(RAW)) \
		.replace("__WORDS__", JSON.stringify(WORDS))
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle did not run: ", evaluated)
		quit(1)
		return

	# One record a line: the embedded engine truncates a long one, and a case's whole grid is
	# a hundred-odd numbers.
	var answers: PackedStringArray = host.call("poll_lines")
	var oracle_tier := {}
	var oracle_stored := {}
	var oracle_word := {}
	for line in answers:
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log tier ") and parts.size() == 7:
			oracle_tier["%d %s %s" % [int(parts[2]), parts[3], parts[4]]] = int(parts[6])
			oracle_stored[int(parts[2])] = float(parts[5])
		elif line.begins_with("log word ") and parts.size() == 4:
			oracle_word[parts[2]] = int(parts[3])
	print("oracle answered ", oracle_stored.size(), " leaf/leaves, ", oracle_tier.size(),
		" tier(s), ", oracle_word.size(), " word(s)")

	# 1. The leaf's clamp, and the promise over every leaf a build can be asked with.
	var compared := 0
	var clamp_mismatches := 0
	var first_clamp := ""
	var rule_mismatches := 0
	var first_rule := ""
	for index in RAW.size():
		var raw: float = RAW[index]
		var mine_stored: float = WaterReflect.clamp_wish(raw)
		var wanted_stored: float = float(oracle_stored.get(index, NAN))
		compared += 1
		if absf(mine_stored - wanted_stored) > TOLERANCE:
			clamp_mismatches += 1
			if first_clamp == "":
				first_clamp = "leaf %.1f: scene %.17f, port %.17f" % [
					raw, wanted_stored, mine_stored]
		for mirror_ok in 2:
			for bake_ok in 2:
				var mine: int = WaterReflect.promise(mine_stored, bake_ok == 1, mirror_ok == 1)
				var wanted: int = int(oracle_tier.get(
					"%d %d %d" % [index, mirror_ok, bake_ok], -1))
				compared += 1
				if mine != wanted:
					rule_mismatches += 1
					if first_rule == "":
						first_rule = "leaf %.1f ground=%d mirror=%d: scene %d, port %d" % [
							raw, bake_ok, mirror_ok, wanted, mine]
	print("clamp: %d leaf/leaves, %d mismatch(es)" % [RAW.size(), clamp_mismatches])
	if first_clamp != "":
		print("  first: ", first_clamp)
	print("promise: %d value(s) over %d leaf/leaves x ground x mirror, %d mismatch(es)"
		% [RAW.size() * 4, RAW.size(), rule_mismatches])
	if first_rule != "":
		print("  first: ", first_rule)

	# 2. The words the console and the menu spell the tiers with.
	var word_mismatches := 0
	var first_word := ""
	for word in WORDS:
		var mine: int = WaterReflect.word_tier(word)
		var wanted: int = int(oracle_word.get(word, -2))
		if mine != wanted:
			word_mismatches += 1
			if first_word == "":
				first_word = "'%s': scene %d, port %d" % [word, wanted, mine]
	print("words: %d, %d mismatch(es)" % [WORDS.size(), word_mismatches])
	if first_word != "":
		print("  first: ", first_word)

	# 3. The port's own mapping: what a tier *sees* and what it *costs*. These are pins
	#    rather than transcriptions -- the two engines answer the tier differently -- so they
	#    are asserted as the properties the mapping exists for, not as restated constants.
	var mapping: Array[String] = []
	var sky_mask: int = WaterReflect.mask_of(WaterReflect.SKY)
	var ground_mask: int = WaterReflect.mask_of(WaterReflect.GROUND)
	var world_mask: int = WaterReflect.mask_of(WaterReflect.MIRROR)
	if sky_mask != 0:
		mapping.append("the sky tier sees something (%d); a probe's sky is its background" % sky_mask)
	if (ground_mask & 1) != 0:
		mapping.append("the ground tier still sees layer 1, so it reflects the goat")
	if (ground_mask & WaterReflect.LAYER_GROUND) == 0:
		mapping.append("the ground tier does not see the ground")
	if (world_mask & 1) == 0:
		mapping.append("the mirror tier cannot see the goat it exists to reflect")
	if (world_mask & WaterReflect.LAYER_NOREFLECT) != 0:
		mapping.append("the mirror tier sees what must not be in a reflection")
	if (world_mask & WaterReflect.LAYER_WATER) != 0:
		mapping.append("the mirror tier sees the surface that is doing the reflecting")
	if sky_mask == ground_mask or ground_mask == world_mask or sky_mask == world_mask:
		mapping.append("two tiers read the world through the same mask")
	if WaterReflect.mode_of(WaterReflect.SKY) != ReflectionProbe.UPDATE_ONCE \
			or WaterReflect.mode_of(WaterReflect.GROUND) != ReflectionProbe.UPDATE_ONCE \
			or WaterReflect.mode_of(WaterReflect.MIRROR) != ReflectionProbe.UPDATE_ALWAYS:
		mapping.append("the bake ladder is not once/once/always")
	# ...and the other half of a probe: who *receives* the reflection. Only the surface may,
	# because a probe reflects onto every instance in its box and the ground is one 96 m mesh.
	if WaterReflect.REFLECT_TO != WaterReflect.LAYER_WATER:
		mapping.append("something other than the surface receives the reflection")
	if (WaterReflect.REFLECT_TO & (WaterReflect.LAYER_GROUND | 1)) != 0:
		mapping.append("the reflection reaches the ground, which goes pale when it does")
	print("mapping: sky %d, ground %d, mirror %d, reflects onto %d, %d problem(s)"
		% [sky_mask, ground_mask, world_mask, WaterReflect.REFLECT_TO, mapping.size()])
	for problem in mapping:
		print("  ", problem)

	# 4. The wiring: a probe in a tree takes the tier the promise makes, with the mask and the
	#    cadence that tier is. The mirror is only reachable by claiming the window, because a
	#    headless build has none -- which is the degrade the gate asserts first.
	var probe := WaterReflect.new()
	root.add_child(probe)
	var wiring_mismatches := 0
	var first_wiring := ""
	# The two capabilities, taken from the *build* rather than from the probe's own accessors:
	# a promise checked against the predicate it was built from cannot fail.
	var headless: bool = DisplayServer.get_name() == "headless"
	print("display server: ", DisplayServer.get_name(), ", can ground: ",
		probe.can_ground(), ", can mirror: ", probe.can_mirror())
	if not probe.can_ground():
		wiring_mismatches += 1
		first_wiring = "a probe in a live tree says it has nowhere to bake"
	if probe.can_mirror() == headless:
		wiring_mismatches += 1
		first_wiring = "the mirror's own capability does not follow the renderer"
	for wish in [0.0, 1.0, 2.0]:
		probe.set_wish(wish)
		var wanted: int = WaterReflect.promise(wish, true, not headless)
		if probe.tier() != wanted:
			wiring_mismatches += 1
			if first_wiring == "":
				first_wiring = "wish %.1f: tier %d, want %d" % [wish, probe.tier(), wanted]
		if probe.cull_mask != WaterReflect.mask_of(wanted):
			wiring_mismatches += 1
			if first_wiring == "":
				first_wiring = "wish %.1f: mask %d, want %d" % [
					wish, probe.cull_mask, WaterReflect.mask_of(wanted)]
		if probe.update_mode != WaterReflect.mode_of(wanted):
			wiring_mismatches += 1
			if first_wiring == "":
				first_wiring = "wish %.1f: mode %d, want %d" % [
					wish, probe.update_mode, WaterReflect.mode_of(wanted)]
		if probe.reflection_mask != WaterReflect.REFLECT_TO:
			wiring_mismatches += 1
			if first_wiring == "":
				first_wiring = "wish %.1f: reflects onto %d, want %d" % [
					wish, probe.reflection_mask, WaterReflect.REFLECT_TO]
		if int(probe.report()["reflect"]) != roundi(wish):
			wiring_mismatches += 1
			if first_wiring == "":
				first_wiring = "wish %.1f: the report says %d" % [
					wish, int(probe.report()["reflect"])]
	print("wiring: %d wish(es), %d mismatch(es)" % [3, wiring_mismatches])
	if first_wiring != "":
		print("  first: ", first_wiring)

	# 5. The mirror, claimed. `--headless` cannot have it, so the gate says it does -- the
	#    only way to exercise the one tier whose wiring a headless run would never reach.
	probe.mirror_capable = true
	probe.set_wish(2.0)
	var mirror_ok := probe.tier() == WaterReflect.MIRROR \
		and probe.cull_mask == WaterReflect.MASK_WORLD \
		and probe.update_mode == ReflectionProbe.UPDATE_ALWAYS
	print("mirror claimed: tier %d, mask %d, mode %d (want %d, %d, %d)"
		% [probe.tier(), probe.cull_mask, probe.update_mode,
			WaterReflect.MIRROR, WaterReflect.MASK_WORLD, ReflectionProbe.UPDATE_ALWAYS])

	# 6. The bake counters: the promise is a *bake*, and a probe that never re-baked would
	#    look identical from the outside. `set_wish` bakes; a frame short of `REFRESH` does
	#    not; `REFRESH` does; a moved ground does at once; and the mirror never does -- it is
	#    a submission a frame already.
	probe.set_wish(1.0)
	var base: int = probe.bakes
	probe.refresh(WaterReflect.REFRESH * 0.4, false)
	var quiet: int = probe.bakes
	probe.refresh(WaterReflect.REFRESH, false)
	var cadence: int = probe.bakes
	probe.refresh(0.0, true)
	var ground: int = probe.bakes
	# ...and the mirror never bakes on a cadence: it is a submission a frame already.
	probe.mirror_capable = true
	probe.set_wish(2.0)
	var before: int = probe.bakes
	probe.refresh(WaterReflect.REFRESH * 4.0, false)
	probe.refresh(0.0, true)
	var after: int = probe.bakes
	print("bakes: set %d, quiet %d, cadence %d, ground %d; mirror %d -> %d"
		% [base, quiet, cadence, ground, before, after])

	# 7. Edges: a probe with no tree to be in is the scene's build-without-the-bindings, and
	#    it degrades to the sky rather than drawing nothing.
	var loose := WaterReflect.new()
	var loose_ok := not loose.can_ground() and not loose.can_mirror()
	for wish in [0.0, 1.0, 2.0]:
		loose.set_wish(wish)
		if loose.tier() != WaterReflect.SKY:
			loose_ok = false
	print("no tree: quiet %s" % ["ok" if loose_ok else "WRONG"])
	loose.free()
	probe.free()

	host.free()

	if oracle_stored.size() != RAW.size():
		failures.append("the oracle answered %d leaf/leaves, expected %d"
			% [oracle_stored.size(), RAW.size()])
	if clamp_mismatches != 0:
		failures.append("the leaf's clamp is not the scene's: %d place(s)" % clamp_mismatches)
	if rule_mismatches != 0:
		failures.append("the promise is not the scene's: %d of %d value(s)"
			% [rule_mismatches, compared])
	if word_mismatches != 0:
		failures.append("the setting's words are not the scene's: %d place(s)" % word_mismatches)
	if not mapping.is_empty():
		failures.append("the tiers do not map onto the probe the way they are meant to")
	if wiring_mismatches != 0:
		failures.append("a probe in a tree does not take the tier it promises: %d place(s)"
			% wiring_mismatches)
	if not mirror_ok:
		failures.append("the claimed mirror tier does not wire the probe the mirror way")
	if quiet != base:
		failures.append("a frame short of `REFRESH` baked")
	if cadence != quiet + 1:
		failures.append("`REFRESH` seconds did not bake")
	if ground != cadence + 1:
		failures.append("a moved ground did not bake")
	if after != before:
		failures.append("the mirror tier baked on a cadence it does not have")
	if not loose_ok:
		failures.append("a probe with no tree answered as if it had one")

	if failures.is_empty():
		print("OK: the port's reflection tiers are the scene's, on the engine's own probe")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for f in failures:
			print("FAIL: ", f)
		quit(1)
