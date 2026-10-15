# The reflection gate (M20e): the setting's three tiers against `water.js`'s own.
#
#   Godot --headless --path godot --script res://tools/verify_water_reflect.gd
#
# M20e is the one part of the water that is mostly a *look*, and the port answers it with its
# own screen-space march in `water.gdshader` rather than with Godot's `ssr_enabled` -- because
# Godot's is computed from the opaque pass and does not reach an alpha-blended surface (a
# measurement: toggling it moves a frame by 0.000064 with this water transparent and by
# 0.003081 with it temporarily opaque). So what a headless run can hold is the part that is a
# *rule*, plus the plumbing that carries it:
#
#   * the leaf and its clamp, which `tuningCoerce` does and not `waterReflectTier`;
#   * the promise `waterReflectTier` makes -- the wish rounded, and a tier the build cannot
#     keep falling to the one below it rather than to nothing;
#   * the three words `setting reflect` and the menu's combo box spell (`ctl.js` `CTL_REFLECT`);
#   * the *budget* each tier buys, which is the port's own invention and is checked against the
#     shader's own ceiling and against the order the tiers are meant to have;
#   * and that the tier and its budget reach the surface's material, under names the shader
#     actually declares -- a misspelling is silent on both sides, which is the one thing a
#     name can be checked for at all here.
#
# What no case can hold is whether the march *looks* right -- the same gap M20b and M20c
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

	# 3. The budget each tier buys, and the shader's own ceiling. The ceiling is a `const`, so
	#    no engine call reaches it -- it is read out of the source, and a budget the shader
	#    would clip has to be caught here or nowhere.
	var shader: Shader = load("res://src/water.gdshader")
	var ceiling: int = _max_steps(shader.code)
	var budget: Array[String] = []
	if ceiling <= 0:
		budget.append("the shader's MAX_STEPS could not be read (%d)" % ceiling)
	for which in WaterReflect.NAMES.size():
		if WaterReflect.steps_of(which) > ceiling:
			budget.append("tier %s marches %d step(s), more than the shader's %d"
				% [WaterReflect.tier_word(which), WaterReflect.steps_of(which), ceiling])
	if WaterReflect.steps_of(WaterReflect.SKY) != 0 \
			or WaterReflect.reach_of(WaterReflect.SKY) != 0.0:
		budget.append("the sky tier marches something; it is meant to sample nothing at all")
	if WaterReflect.steps_of(WaterReflect.MIRROR) <= WaterReflect.steps_of(WaterReflect.GROUND):
		budget.append("the mirror does not march further than the ground")
	if WaterReflect.reach_of(WaterReflect.MIRROR) <= WaterReflect.reach_of(WaterReflect.GROUND):
		budget.append("the mirror does not reach further than the ground")
	if WaterReflect.reach_of(WaterReflect.GROUND) <= 0.0:
		budget.append("the ground tier reaches nowhere")
	print("budget: ceiling %d, sky %d/%.1f, ground %d/%.1f, mirror %d/%.1f, %d problem(s)"
		% [ceiling, WaterReflect.steps_of(0), WaterReflect.reach_of(0),
			WaterReflect.steps_of(1), WaterReflect.reach_of(1),
			WaterReflect.steps_of(2), WaterReflect.reach_of(2), budget.size()])
	for problem in budget:
		print("  ", problem)

	# 4. The plumbing: the surface's shader must *declare* the names the tier is pushed under
	#    (a misspelling is silent on both sides), and `apply` must land the tier and its budget
	#    on the material.
	var declared: PackedStringArray = []
	for uniform: Dictionary in shader.get_shader_uniform_list():
		declared.append(String(uniform["name"]))
	var missing: Array[String] = []
	for needed in ["water_reflect", "water_steps", "water_reach"]:
		if not declared.has(needed):
			missing.append(needed)
	print("declared: ", ", ".join(declared))
	if not missing.is_empty():
		print("  missing: ", ", ".join(missing))

	var surface := WaterMesh.new()
	surface.build(_flat_heights(), Vector2(0.0, 0.0))
	var reflect := WaterReflect.new()
	var headless: bool = DisplayServer.get_name() == "headless"
	var landing := 0
	var first_landing := ""
	for wish in [0.0, 1.0, 2.0]:
		reflect.set_wish(wish)
		reflect.apply(surface)
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
		if int(material.get_shader_parameter("water_steps")) != WaterReflect.steps_of(want):
			landing += 1
			if first_landing == "":
				first_landing = "wish %.1f: the material marches %d step(s), want %d" % [
					wish, int(material.get_shader_parameter("water_steps")),
					WaterReflect.steps_of(want)]
		if float(material.get_shader_parameter("water_reach")) != WaterReflect.reach_of(want):
			landing += 1
			if first_landing == "":
				first_landing = "wish %.1f: the material reaches %.1f m, want %.1f" % [
					wish, float(material.get_shader_parameter("water_reach")),
					WaterReflect.reach_of(want)]
	print("landing: 3 wish(es), %d mismatch(es)" % landing)
	if first_landing != "":
		print("  first: ", first_landing)

	# 5. The degrade: the promise falls a tier rather than drawing nothing, and the port's half
	#    of it is a *frame* -- a screen-space march needs one, so `--headless` answers sky
	#    however the leaf is set.
	var degrade_mismatches := 0
	var first_degrade := ""
	print("display server: ", DisplayServer.get_name(), ", can march: ", reflect.can_ground())
	if reflect.can_ground() != (not headless):
		degrade_mismatches += 1
		first_degrade = "the ability to march does not follow the renderer"
	for wish in [0.0, 1.0, 2.0]:
		reflect.set_wish(wish)
		var want: int = WaterReflect.promise(wish, not headless, not headless)
		if reflect.tier() != want:
			degrade_mismatches += 1
			if first_degrade == "":
				first_degrade = "wish %.1f: tier %d, want %d" % [wish, reflect.tier(), want]
	var report: Dictionary = reflect.report()
	if int(report["reflect"]) != roundi(reflect.wish) or int(report["tier"]) != reflect.tier() \
			or int(report["steps"]) != WaterReflect.steps_of(reflect.tier()) \
			or float(report["reach"]) != WaterReflect.reach_of(reflect.tier()):
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
		and WaterReflect.clamp_wish(-5.0) == 0.0 and WaterReflect.clamp_wish(9.0) == 2.0
	print("edges: ", "ok" if edge_ok else "WRONG")

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
	if not budget.is_empty():
		failures.append("the tiers' own budget is not the one they are meant to have")
	if not missing.is_empty():
		failures.append("the shader does not declare: %s" % ", ".join(missing))
	if landing != 0:
		failures.append("the tier does not reach the surface's material: %d place(s)" % landing)
	if degrade_mismatches != 0:
		failures.append("the promise is not the one the build can keep: %d place(s)"
			% degrade_mismatches)
	if not edge_ok:
		failures.append("a word or a leaf outside the setting's range did not answer quietly")

	if failures.is_empty():
		print("OK: the port's reflection tiers are the scene's, on the port's own march")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for f in failures:
			print("FAIL: ", f)
		quit(1)

## The march's ceiling, out of the shader's own source: it is a `const`, so no engine call can
## reach it, and a budget the shader would silently clip has to be caught here or nowhere.
func _max_steps(code: String) -> int:
	var pattern := RegEx.new()
	if pattern.compile("const\\s+int\\s+MAX_STEPS\\s*=\\s*(\\d+)") != OK:
		return -1
	var found: RegExMatch = pattern.search(code)
	if found == null:
		return -1
	return int(found.get_string(1))

## Level ground, so every quad of the surface survives `build`'s cut and the material is made.
func _flat_heights() -> PackedFloat64Array:
	var heights := PackedFloat64Array()
	heights.resize(Water.N * Water.N)
	heights.fill(FLAT)
	return heights
