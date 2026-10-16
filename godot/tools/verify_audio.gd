# The audio gate (M22): `audio.js`'s four rules and its own random stream, against its source.
#
#   Godot --headless --path godot --script res://tools/verify_audio.gd
#
# The port had no sound at all until this slice, so there is nothing here to check against an
# earlier port -- only against the JavaScript, which is the point. Four rules carry the whole of
# it, and each is one a lookalike gets subtly wrong:
#
#   * **the variety PRNG.** `arnd` is xorshift32, and the scene writes it with `>>> 0` because
#     its integers are 32-bit and unsigned. GDScript's are 64-bit and signed, so every shift has
#     to be masked -- and a mask in the wrong place is a stream that looks random and is never
#     the scene's. This is the case that would catch it, and nothing else would.
#   * **which variant, and which copy.** A variant at random, then the first copy that is not
#     already in the air, falling back to the first -- because a `Sound` played twice restarts,
#     so a restarted bang is worse than a dropped one.
#   * **how a bang carries.** Full volume inside the blast's own radius, half at twenty-odd
#     metres; and a chained bang quieter with every link, so a cascade reads as a sequence.
#   * **the two gains** and what the beds are scaled by -- the only part of this a *frame*
#     decides rather than an event.
#
# The oracle is `audio.js` transcribed from source: a case that agreed with the port's own
# arithmetic would prove nothing. What no case can hold is what any of it *sounds* like, and
# headless could not play it anyway -- the engine's audio driver is a dummy there, which is also
# why the live half below checks what is *loaded* and what a *frame* sets, and stops there.
#
# Two oracles rather than one, for the reason `verify_peers.gd` records: a single `eval_js`
# carrying several hundred rows of argument literal can report `ok` and log nothing at all.
extends SceneTree

## The PRNG and the pick, transcribed.
const PRNG_JS := """
(function () {
let audioSeed = 0x2f6e2b1;
function arnd() {
    audioSeed ^= audioSeed << 13;
    audioSeed >>>= 0;
    audioSeed ^= audioSeed >>> 17;
    audioSeed ^= audioSeed << 5;
    audioSeed >>>= 0;
    return audioSeed / 4294967296;
}
function pickCopy(mask) {
    for (let i = 0; i < 3; i++) if (!(mask & (1 << i))) return i;
    return 0;
}
const N = __N__;
for (let i = 0; i < N; i++) console.log('rnd ' + i + ' ' + arnd());
const PICKS = __PICKS__;
for (let i = 0; i < PICKS.length; i++) {
    const p = PICKS[i];
    console.log('pick ' + i + ' ' + p[0] + ' ' + p[1] + ' ' + p[2] + ' ' +
        (Math.floor(p[0] * p[1]) % p[1]) + ' ' + pickCopy(p[2]));
}
// The two schedules, drawn from a *fresh* seed `arnd` would not give: a cooldown and a delay
// are composed of constants and a draw, and the composition is what is compared.
const FROM = 0x2f6e2b1;
let s = FROM;
function draw() {
    s ^= s << 13; s >>>= 0;
    s ^= s >>> 17;
    s ^= s << 5; s >>>= 0;
    return s / 4294967296;
}
for (let i = 0; i < 5; i++) console.log('thunder ' + i + ' ' + (8 + draw() * 14));
let d = FROM;
function draw2() {
    d ^= d << 13; d >>>= 0;
    d ^= d >>> 17;
    d ^= d << 5; d >>>= 0;
    return d / 4294967296;
}
for (let i = 0; i < 5; i++) console.log('debris ' + i + ' ' + (0.42 + draw2() * 0.34));
})();
"""

## The attenuation, the chain and the gains, transcribed.
const GAINS_JS := """
(function () {
const MUSIC_VOLUME = 0.20, SFX_VOLUME = 0.65, BLAST_FALLOFF = 24;
function blastAttenuation(dx, dz, near) {
    const d = Math.max(0, Math.sqrt(dx * dx + dz * dz) - near);
    return 1 / (1 + d / BLAST_FALLOFF);
}
const ATTS = __ATTS__;
for (let i = 0; i < ATTS.length; i++) {
    const a = ATTS[i];
    console.log('att ' + i + ' ' + a[0] + ' ' + a[1] + ' ' + a[2] + ' ' +
        blastAttenuation(a[0], a[1], a[2]));
}
for (let depth = 0; depth <= 8; depth++) {
    const d = depth > 0 ? depth : 0;
    console.log('chain ' + depth + ' ' + (1 / (1 + 0.6 * d)));
}
const SET = __SET__;
for (let i = 0; i < SET.length; i++) {
    const s = SET[i];
    const bgm = s[0], sfx = s[1], muted = s[2] === 1, scale = s[3];
    const music = MUSIC_VOLUME * bgm / 100;
    const gain = SFX_VOLUME * sfx / 100;
    console.log('gain ' + i + ' ' + bgm + ' ' + sfx + ' ' + s[2] + ' ' + scale + ' ' +
        music + ' ' + gain + ' ' + (muted ? 0 : music * scale));
}
})();
"""

## How many draws of the variety stream are compared. Enough that a mask in the wrong place
## cannot agree by luck: that stream is chaotic after one step.
const DRAWS := 24

const TOLERANCE := 1e-12

var _failures: Array[String] = []
var _frames := 0
var _live: Audio

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return

	var host: Object = ClassDB.instantiate("ModHost")
	var oracle_rnd := {}
	var oracle_pick := {}
	var oracle_thunder: Array[float] = []
	var oracle_debris: Array[float] = []
	var oracle_att := {}
	var oracle_chain := {}
	var oracle_gain := {}

	var prng_source: String = PRNG_JS.replace("__N__", str(DRAWS)) \
		.replace("__PICKS__", JSON.stringify(_picks()))
	for line in _oracle(host, prng_source, "prng"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log rnd ") and parts.size() == 4:
			oracle_rnd[int(parts[2])] = float(parts[3])
		elif line.begins_with("log pick ") and parts.size() == 8:
			oracle_pick[int(parts[2])] = PackedInt32Array([int(parts[6]), int(parts[7])])
		elif line.begins_with("log thunder ") and parts.size() == 4:
			oracle_thunder.append(float(parts[3]))
		elif line.begins_with("log debris ") and parts.size() == 4:
			oracle_debris.append(float(parts[3]))

	var gains_source: String = GAINS_JS.replace("__ATTS__", JSON.stringify(_atts())) \
		.replace("__SET__", JSON.stringify(_settings()))
	for line in _oracle(host, gains_source, "gains"):
		var parts: PackedStringArray = line.split(" ")
		if line.begins_with("log att ") and parts.size() == 7:
			oracle_att[int(parts[2])] = PackedFloat64Array([
				float(parts[3]), float(parts[4]), float(parts[5]), float(parts[6])])
		elif line.begins_with("log chain ") and parts.size() == 4:
			oracle_chain[int(parts[2])] = float(parts[3])
		elif line.begins_with("log gain ") and parts.size() == 10:
			oracle_gain[int(parts[2])] = PackedFloat64Array([
				float(parts[7]), float(parts[8]), float(parts[9])])

	print("oracle answered ", oracle_rnd.size(), " draw(s), ", oracle_pick.size(),
		" pick(s), ", oracle_att.size(), " attenuation(s), ", oracle_chain.size(),
		" chain(s), ", oracle_gain.size(), " gain(s)")
	host.free()

	# 1. The stream. A fresh node's `_seed` is the scene's, so this compares the algorithm and
	#    not the state a frame left behind.
	var fresh := Audio.new()
	var rnd_mismatches := 0
	var first_rnd := ""
	for index in DRAWS:
		var mine: float = fresh.rnd()
		var wanted: float = float(oracle_rnd.get(index, NAN))
		if absf(mine - wanted) > TOLERANCE:
			rnd_mismatches += 1
			if first_rnd == "":
				first_rnd = "draw %d: scene %.17f, port %.17f" % [index, wanted, mine]
	fresh.free()
	print("stream: %d draw(s), %d mismatch(es)" % [DRAWS, rnd_mismatches])
	if first_rnd != "":
		print("  first: ", first_rnd)

	# 2. The variant and the copy.
	var picks: Array = _picks()
	var pick_mismatches := 0
	var first_pick := ""
	for index in picks.size():
		var row: Array = picks[index]
		var mine := PackedInt32Array([
			Audio.variant_of(float(row[0]), int(row[1])),
			Audio.copy_of(_busy(int(row[2]))),
		])
		var wanted: PackedInt32Array = oracle_pick.get(index, PackedInt32Array())
		if wanted.size() != 2 or mine[0] != wanted[0] or mine[1] != wanted[1]:
			pick_mismatches += 1
			if first_pick == "":
				first_pick = "roll %.4f of %d with 0x%x busy: scene %s, port %s" % [
					float(row[0]), int(row[1]), int(row[2]), wanted, mine]
	print("picks: %d row(s), %d mismatch(es)" % [picks.size(), pick_mismatches])
	if first_pick != "":
		print("  first: ", first_pick)

	# 3. The schedule's composition: a constant plus a draw, from the seed the stream starts at.
	var schedule := Audio.new()
	var thunder_ok := true
	var debris_ok := true
	var first_schedule := ""
	for index in oracle_thunder.size():
		var mine: float = Audio.THUNDER_MIN + schedule.rnd() * Audio.THUNDER_SPREAD
		if absf(mine - oracle_thunder[index]) > TOLERANCE:
			thunder_ok = false
			if first_schedule == "":
				first_schedule = "thunder %d: scene %.17f, port %.17f" % [
					index, oracle_thunder[index], mine]
	schedule.free()
	var delay := Audio.new()
	for index in oracle_debris.size():
		var mine: float = Audio.DEBRIS_DELAY + delay.rnd() * Audio.DEBRIS_SPREAD
		if absf(mine - oracle_debris[index]) > TOLERANCE:
			debris_ok = false
			if first_schedule == "":
				first_schedule = "debris %d: scene %.17f, port %.17f" % [
					index, oracle_debris[index], mine]
	delay.free()
	print("schedule: %d thunder(s) and %d debris delay(s), %s"
		% [oracle_thunder.size(), oracle_debris.size(),
			"ok" if (thunder_ok and debris_ok) else "WRONG"])
	if first_schedule != "":
		print("  first: ", first_schedule)

	# 4. The attenuation and the chain.
	var atts: Array = _atts()
	var att_mismatches := 0
	var first_att := ""
	for index in atts.size():
		var row: Array = atts[index]
		var mine: float = Audio.attenuation(float(row[0]), float(row[1]), float(row[2]))
		var wanted: PackedFloat64Array = oracle_att.get(index, PackedFloat64Array())
		if wanted.size() != 4 or absf(mine - wanted[3]) > TOLERANCE:
			att_mismatches += 1
			if first_att == "":
				first_att = "offset (%.1f, %.1f) near %.1f: scene %.17f, port %.17f" % [
					float(row[0]), float(row[1]), float(row[2]),
					wanted[3] if wanted.size() == 4 else NAN, mine]
	print("attenuation: %d offset(s), %d mismatch(es)" % [atts.size(), att_mismatches])
	if first_att != "":
		print("  first: ", first_att)

	var chain_mismatches := 0
	var first_chain := ""
	for depth in 9:
		var mine: float = Audio.chain_gain(depth)
		var wanted: float = float(oracle_chain.get(depth, NAN))
		if absf(mine - wanted) > TOLERANCE:
			chain_mismatches += 1
			if first_chain == "":
				first_chain = "depth %d: scene %.17f, port %.17f" % [depth, wanted, mine]
	print("chain: 9 depth/depths, %d mismatch(es)" % chain_mismatches)
	if first_chain != "":
		print("  first: ", first_chain)

	# 5. The two gains and the bed scaling, over the settings grid the menu will drive.
	var settings: Array = _settings()
	var gain_mismatches := 0
	var first_gain := ""
	var probe := Audio.new()
	for index in settings.size():
		var row: Array = settings[index]
		probe.bgm = float(row[0])
		probe.sfx = float(row[1])
		probe.muted = int(row[2]) == 1
		var mine := PackedFloat64Array([
			probe.music_gain(), probe.sfx_gain(),
			Audio.bed_gain(probe.music_gain(), probe.muted, float(row[3])),
		])
		var wanted: PackedFloat64Array = oracle_gain.get(index, PackedFloat64Array())
		if wanted.size() != 3 or absf(mine[0] - wanted[0]) > TOLERANCE \
				or absf(mine[1] - wanted[1]) > TOLERANCE \
				or absf(mine[2] - wanted[2]) > TOLERANCE:
			gain_mismatches += 1
			if first_gain == "":
				first_gain = "bgm %.0f sfx %.0f muted %d scale %.2f: scene %s, port %s" % [
					float(row[0]), float(row[1]), int(row[2]), float(row[3]), wanted, mine]
	probe.free()
	print("gains: %d setting(s), %d mismatch(es)" % [settings.size(), gain_mismatches])
	if first_gain != "":
		print("  first: ", first_gain)

	if rnd_mismatches != 0:
		_failures.append("the variety stream is not the scene's: %d of %d draw(s)"
			% [rnd_mismatches, DRAWS])
	if pick_mismatches != 0:
		_failures.append("the variant/copy rule is not the scene's: %d of %d row(s)"
			% [pick_mismatches, picks.size()])
	if not (thunder_ok and debris_ok):
		_failures.append("a schedule is not the scene's composition")
	if att_mismatches != 0:
		_failures.append("the attenuation is not the scene's: %d of %d offset(s)"
			% [att_mismatches, atts.size()])
	if chain_mismatches != 0:
		_failures.append("the chain gain is not the scene's: %d place(s)" % chain_mismatches)
	if gain_mismatches != 0:
		_failures.append("a gain is not the scene's: %d of %d setting(s)"
			% [gain_mismatches, settings.size()])

	# The live half needs a tree: an `AudioStreamPlayer` has to be in one to be played, and what
	# the slots *loaded* is the one thing no arithmetic here can answer.
	_live = Audio.new()
	root.add_child(_live)

func _process(delta: float) -> bool:
	_frames += 1
	if _frames == 1:
		_live_load()
		return false
	if _frames == 2:
		_live_frame(delta)
		_report()
		return true
	return false

## What the ten slots loaded. The seven the scene ships and the three M19g reserved: a slot with
## no sample is *silence*, which is why the empty ones are counted rather than skipped.
func _live_load() -> void:
	_live.build()
	var state: Dictionary = _live.state()
	var wanted := {
		"bleats": 6, "thunders": 3, "blasts": 5, "debris": 4,
		"fuses": 0, "traps": 0, "close": 0, "beds": 3,
	}
	print("loaded: ", _counts(state))
	for key: String in wanted:
		if int(state.get(key, -1)) != int(wanted[key]):
			_failures.append("the %s slot loaded %s, want %d" % [
				key, state.get(key, -1), int(wanted[key])])
	# Building twice must not double anything: `_ready` and the plays both call it.
	_live.build()
	if int(_live.state()["beds"]) != 3 or int(_live.state()["bleats"]) != 6:
		_failures.append("a second build loaded the slots twice")
	if _live.word() != "on":
		_failures.append("a loaded, unmuted port says the audio is '%s'" % _live.word())
	# An empty slot is silence rather than a failure -- and that is the shipped state of three.
	if _live.pick("sfx.fuse") != null or _live.pick("sfx.trap") != null \
			or _live.pick("sfx.blast.close") != null:
		_failures.append("an empty slot handed back a player")

## What a frame sets, and the one event a probe can watch: the grit a bang queued.
func _live_frame(delta: float) -> void:
	# The beds ride the weather: rain and wind at full, so the two scales are their own volumes.
	_live.update(delta, 1.0, 1.0)
	var levels: Dictionary = _live.state()["levels"]
	var music: float = _db(_live.music_gain())
	var want_rain: float = _db(Audio.bed_gain(_live.music_gain(), false,
		Audio.RAIN_VOLUME))
	var want_wind: float = _db(Audio.bed_gain(_live.music_gain(), false,
		Audio.WIND_VOLUME))
	if absf(float(levels.get("sfx.music", NAN)) - music) > 1e-6 \
			or absf(float(levels.get("sfx.rain", NAN)) - want_rain) > 1e-6 \
			or absf(float(levels.get("sfx.wind", NAN)) - want_wind) > 1e-6:
		_failures.append("the beds are not at the levels the weather asks for: %s" % levels)
	print("beds: music %.2f dB, rain %.2f dB, wind %.2f dB"
		% [float(levels.get("sfx.music", NAN)), float(levels.get("sfx.rain", NAN)),
			float(levels.get("sfx.wind", NAN))])

	# A bang queues its grit, and the grit lands when its delay is up -- read through the
	# pending count rather than by ear, which is all a headless run has.
	var queued: int = int(_live.state()["pending"])
	if not _live.bang(4.0, 4.0, 0):
		_failures.append("a bang with the blast slot loaded played nothing")
	if int(_live.state()["pending"]) != queued + 1:
		_failures.append("a bang did not queue its grit")
	_live.update(Audio.DEBRIS_DELAY + Audio.DEBRIS_SPREAD + 0.01, 0.0, 0.0)
	if int(_live.state()["pending"]) != queued:
		_failures.append("the grit never landed")
	print("bang: 1 queued and dropped, pending back to %d" % int(_live.state()["pending"]))

	# The thunder rolls off the rain, and schedules the next one whether or not it was heard.
	var quiet: Audio = Audio.new()
	root.add_child(quiet)
	quiet.set_muted(true)
	quiet.update(Audio.THUNDER_FIRST + 0.1, 1.0, 0.0)
	var cooldown: float = float(quiet.state()["thunder_cooldown"])
	if cooldown < Audio.THUNDER_MIN or cooldown > Audio.THUNDER_MIN + Audio.THUNDER_SPREAD:
		_failures.append("a muted roll did not reschedule: cooldown %.3f" % cooldown)
	if quiet.word() != "muted":
		_failures.append("a muted port says the audio is '%s'" % quiet.word())
	print("mute: '%s' while muted, '%s' while not, and a muted roll still reschedules to %.2f s"
		% [quiet.word(), _live.word(), cooldown])
	quiet.queue_free()
	_live.queue_free()

func _report() -> void:
	if _failures.is_empty():
		print("OK: the port's sound is the scene's, slot for slot and draw for draw")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)

## The linear-gain-to-decibels step the port uses, so a case compares the same *kind* of number
## the module writes to a player.
func _db(gain: float) -> float:
	return Audio.QUIET if gain <= 0.0 else linear_to_db(gain)

func _counts(state: Dictionary) -> String:
	var parts: Array[String] = []
	for key in ["bleats", "thunders", "blasts", "debris", "fuses", "traps", "close", "beds"]:
		parts.append("%s %d" % [key, int(state.get(key, -1))])
	return ", ".join(parts)

## Run one oracle script and hand back its lines, `log ` included.
func _oracle(host: Object, source: String, which: String) -> PackedStringArray:
	var evaluated: String = host.call("eval_js", source)
	if evaluated != "ok":
		print("FAIL: the JavaScript oracle (", which, ") did not run: ", evaluated)
		quit(1)
		return PackedStringArray()
	var lines := PackedStringArray()
	for line in host.call("poll_lines"):
		lines.append(String(line))
	return lines

## The pick grid: a roll, a variant count, and which copies are already in the air. The rolls
## include both ends of the range and the values that land on a variant boundary.
func _picks() -> Array:
	var rolls := [0.0, 0.1, 0.3333, 0.5, 0.6667, 0.9999, 0.999999]
	var counts := [1, 2, 3, 5, 6]
	var masks := [0, 1, 2, 3, 4, 5, 6, 7]
	var out: Array = []
	for roll: float in rolls:
		for count: int in counts:
			for mask: int in masks:
				out.append([roll, count, mask])
	return out

## The attenuation grid: an offset and the radius the scene's own blast has.
func _atts() -> Array:
	var out: Array = []
	for dx: float in [-30.0, -12.0, -3.2, -1.0, 0.0, 1.0, 3.2, 12.0, 30.0]:
		for dz: float in [0.0, 2.5, -9.0]:
			for near: float in [0.0, 3.2]:
				out.append([dx, dz, near])
	return out

## The settings grid: the menu's two sliders, the mute, and the scale a bed is multiplied by.
func _settings() -> Array:
	var out: Array = []
	for bgm: float in [0.0, 50.0, 90.0, 100.0]:
		for sfx: float in [0.0, 90.0, 100.0]:
			for muted: int in [0, 1]:
				for scale: float in [0.0, 0.5, 0.9, 1.0]:
					out.append([bgm, sfx, muted, scale])
	return out

## Which copies of a variant are already in the air, as the flags `copy_of` reads.
func _busy(mask: int) -> Array:
	var out: Array = []
	for index in Audio.SFX_POOL:
		out.append((mask & (1 << index)) != 0)
	return out
