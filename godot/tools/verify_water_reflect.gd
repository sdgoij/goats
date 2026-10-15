# The reflection gate (M20e): the setting's three tiers against `water.js`'s own.
#
#   Godot --headless --path godot --script res://tools/verify_water_reflect.gd
#
# M20e is mostly a *look*, and the port answers it with `water_mirror.gd`'s second camera --
# `renderWaterMirror` transcribed -- rather than with Godot's `ssr_enabled`, which never reaches
# a transparent material. So what a headless run can hold is the part that is a *rule*, plus the
# plumbing that carries it:
#
#   * the leaf and its clamp, which `tuningCoerce` does and not `waterReflectTier`;
#   * the promise `waterReflectTier` makes -- the wish rounded, and a tier the build cannot
#     keep falling to the one below it rather than to nothing;
#   * the three words `setting reflect` and the menu's combo box spell (`ctl.js` `CTL_REFLECT`);
#   * what each tier's pass *draws*, which is the scene's own two exclusions said as a
#     `cull_mask` -- "the ground, and not the goat" and "everything but what must not be in a
#     reflection" -- and which is where this slice's substance is;
#   * and that the tier reaches both the surface's material and the pass, under names the shader
#     actually declares: a misspelling is silent on both sides, which is the one thing a name
#     can be checked for at all here.
#
# What no case can hold is whether the mirror *looks* right -- the same gap M20b and M20c
# shipped with, and the reason `GOATS_FLOOD`/`GOATS_REFLECT` pictures exist.
extends SceneTree

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

## A leaf that is level ground, so every quad of the surface survives its cut and the material
## exists to be read back from.
const FLAT := -1.0

func _initialize() -> void:
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

	# 3. What each tier's pass draws. These are pins rather than transcriptions -- the two
	#    engines answer the tier differently -- so they are asserted as the properties the
	#    mapping exists for, not as restated constants.
	var sky_mask: int = WaterMirror.mask_of(WaterReflect.SKY)
	var ground_mask: int = WaterMirror.mask_of(WaterReflect.GROUND)
	var world_mask: int = WaterMirror.mask_of(WaterReflect.MIRROR)
	var drawing: Array[String] = []
	if WaterMirror.runs(WaterReflect.SKY) or sky_mask != 0:
		drawing.append("the sky tier runs a pass; it is meant to sample nothing at all")
	if not WaterMirror.runs(WaterReflect.GROUND):
		drawing.append("the ground tier runs no pass")
	if (ground_mask & WaterMirror.LAYER_GROUND) == 0:
		drawing.append("the ground tier does not draw the ground")
	if (ground_mask & 1) != 0:
		drawing.append("the ground tier draws layer 1, so it reflects the goat")
	if (world_mask & 1) == 0:
		drawing.append("the mirror tier cannot draw the goat it exists to reflect")
	if (world_mask & WaterMirror.LAYER_NOREFLECT) != 0:
		drawing.append("the mirror tier draws what must not be in a reflection")
	if (world_mask & ground_mask) != ground_mask:
		drawing.append("the mirror does not draw everything the ground tier does")
	if sky_mask == ground_mask or ground_mask == world_mask or sky_mask == world_mask:
		drawing.append("two tiers' passes draw the same layers")
	for which in WaterReflect.NAMES.size():
		if WaterMirror.runs(which) != (WaterMirror.mask_of(which) != 0):
			drawing.append("tier %d's pass runs and its mask disagree" % which)
	print("drawing: sky %d, ground %d, mirror %d (nothing %d, ground %d, noreflect %d), %d problem(s)"
		% [sky_mask, ground_mask, world_mask, 0, WaterMirror.LAYER_GROUND,
			WaterMirror.LAYER_NOREFLECT, drawing.size()])
	for problem in drawing:
		print("  ", problem)

	# 4. The plumbing: the surface's shader must *declare* the names the tier is pushed under
	#    (a misspelling is silent on both sides), and `apply` must land the tier on both the
	#    material and the pass.
	var shader: Shader = load("res://src/water.gdshader")
	var declared: PackedStringArray = []
	for uniform: Dictionary in shader.get_shader_uniform_list():
		declared.append(String(uniform["name"]))
	var missing: Array[String] = []
	for needed in ["water_reflect", "water_mirror"]:
		if not declared.has(needed):
			missing.append(needed)

	var mirror := WaterMirror.new()
	var surface := WaterMesh.new()
	surface.build(_flat_heights(), Vector2(0.0, 0.0))
	var reflect := WaterReflect.new()
	var headless: bool = DisplayServer.get_name() == "headless"
	var landing := 0
	var first_landing := ""
	for wish in [0.0, 1.0, 2.0]:
		reflect.set_wish(wish)
		reflect.apply(surface, mirror)
		var want: int = WaterReflect.promise(wish, not headless, not headless)
		var material: ShaderMaterial = surface.material_override
		if material == null:
			landing += 1
			first_landing = "the surface has no material to land on"
			continue
		if int(material.get_shader_parameter("water_reflect")) != want:
			landing += 1
			if first_landing == "":
				first_landing = "wish %.1f: the material says tier %d, want %d" % [
					wish, int(material.get_shader_parameter("water_reflect")), want]
		if int(mirror.mask()) != WaterMirror.mask_of(want):
			landing += 1
			if first_landing == "":
				first_landing = "wish %.1f: the pass draws %d, want %d" % [
					wish, mirror.mask(), WaterMirror.mask_of(want)]
		if mirror.running() != WaterMirror.runs(want):
			landing += 1
			if first_landing == "":
				first_landing = "wish %.1f: the pass runs %s, want %s" % [
					wish, mirror.running(), WaterMirror.runs(want)]
	print("declared: ", ", ".join(declared))
	if not missing.is_empty():
		print("  missing: ", ", ".join(missing))
	print("landing: 3 wish(es), %d mismatch(es)" % landing)
	if first_landing != "":
		print("  first: ", first_landing)

	# 5. The degrade: the promise falls a tier rather than drawing nothing, and the port's half
	#    of it is a *frame* -- a mirrored pass needs one, so `--headless` answers sky however the
	#    leaf is set.
	var degrade_mismatches := 0
	var first_degrade := ""
	print("display server: ", DisplayServer.get_name(), ", can pass: ", reflect.can_ground())
	if reflect.can_ground() != (not headless):
		degrade_mismatches += 1
		first_degrade = "the ability to run a pass does not follow the renderer"
	for wish in [0.0, 1.0, 2.0]:
		reflect.set_wish(wish)
		var want: int = WaterReflect.promise(wish, not headless, not headless)
		if reflect.tier() != want:
			degrade_mismatches += 1
			if first_degrade == "":
				first_degrade = "wish %.1f: tier %d, want %d" % [wish, reflect.tier(), want]
	var report: Dictionary = reflect.report()
	if int(report["reflect"]) != roundi(reflect.wish) or int(report["tier"]) != reflect.tier() \
			or int(report["mask"]) != WaterMirror.mask_of(reflect.tier()) \
			or bool(report["running"]) != WaterMirror.runs(reflect.tier()):
		degrade_mismatches += 1
		if first_degrade == "":
			first_degrade = "the report does not agree with the tier it reports"
	print("degrade: 3 wish(es), %d mismatch(es)" % degrade_mismatches)
	if first_degrade != "":
		print("  first: ", first_degrade)

	# 6. Edges: a word the scene does not know is not a tier, and a leaf past the clamp is
	#    stored clamped rather than rounded.
	var edge_ok := WaterReflect.word_tier("") == -1 and WaterReflect.word_tier("nope") == -1 \
		and WaterReflect.tier_word(-1) == "" and WaterReflect.tier_word(3) == "" \
		and WaterReflect.clamp_wish(-5.0) == 0.0 and WaterReflect.clamp_wish(9.0) == 2.0 \
		and WaterMirror.mask_of(-1) == 0 and WaterMirror.mask_of(9) == 0 \
		and WaterReflect.mask_of(WaterReflect.GROUND) == WaterMirror.MASK_GROUND
	print("edges: ", "ok" if edge_ok else "WRONG")

	mirror.free()
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
	if not drawing.is_empty():
		failures.append("the tiers do not draw what they are meant to")
	if not missing.is_empty():
		failures.append("the shader does not declare: %s" % ", ".join(missing))
	if landing != 0:
		failures.append("the tier does not reach the surface and the pass: %d place(s)" % landing)
	if degrade_mismatches != 0:
		failures.append("the promise is not the one the build can keep: %d place(s)"
			% degrade_mismatches)
	if not edge_ok:
		failures.append("a word or a leaf outside the setting's range did not answer quietly")

	if failures.is_empty():
		print("OK: the port's reflection tiers are the scene's, on the port's own mirror")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## Level ground, so every quad of the surface survives `build`'s cut and the material is made.
func _flat_heights() -> PackedFloat64Array:
	var heights := PackedFloat64Array()
	heights.resize(Water.N * Water.N)
	heights.fill(FLAT)
	return heights
