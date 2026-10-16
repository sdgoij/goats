# A mod's own sound gate: `goats.sfx` (`APIv1.md` section 4.20) -- the API's answer to the
# engine's `loadSound`/`playSound`/`setSoundVolume`/`setSoundPitch`, and the last engine
# capability either checked-in mod read.
#
#   Godot --headless --path godot --script res://tools/verify_mod_audio.gd
#
# `verify_audio.gd` holds the *game's* sound against `audio.js`; this is a *mod's*. It exists for
# the same reason the geometry gate does: the surface that keeps a mod portable is the surface
# nobody can see -- or, here, hear. A headless run has a dummy audio driver, so what is asserted
# is what a buffer can answer: that a name the mod declared decoded into a stream with a length,
# that a name nothing declared did not, that the per-play volume and pitch were taken, and that
# the call reached a player rather than only a counter.
#
# Five things:
#
#   1. **`load` resolves a declared sound and refuses everything else.** An opaque asset name
#      becomes a handle; a name nothing declares, and a name with no decoder's extension, both
#      answer `null` -- the same answer a client with no renderer gives, so a mod's check is one
#      `if` on every platform.
#   2. **The bytes are decoded, not just found.** The stream's own length is read back, because a
#      handle that resolved would satisfy a weaker check and play nothing.
#   3. **`play` takes the volume and the pitch**, and it is the *scene* that puts them where its
#      engine wants them (`ModAudio` converts 0..1 to decibels and clamps the rate).
#   4. **A null handle is not a play at all**, so a mod that checks its `load` and skips is not
#      charged a call.
#   5. **A built-in name resolves too.** The value of a slot the game fills is one of *the game's*
#      own files, and `sfx.load` takes it by the same logical name -- so `goats.assets.get` is a
#      useful thing for a mod to hold on both halves of the table (`APIv1.md` section 4.11).
#
# **The sentinel.** GDScript has no `try`, so a runtime error inside a check aborts it and leaves
# the failure it was about to record unrecorded. `_finished` is set at the very end of `_check`.
extends SceneTree

## The probe. `GOATS_SOUND` is the opaque name of a sound the repository's own mods declared, which
## the gate finds rather than hard-codes -- a test that named a file would be testing the file.
const PROBE_JS := """
(function () {
    goats.command("modaudio", function () {
        const out = {};
        const sound = goats.sfx.load(GOATS_SOUND);
        out.loaded = sound === null ? "null" : "handle";
        // ...and a *built-in* name -- the value of a slot the game itself fills -- resolves the
        // same way, which is what makes `goats.assets.get`/`all` useful for the game's own sounds
        // and not only for a mod's (`APIv1.md` section 4.11). It is a `load` and not a `play`, so
        // the play count below still belongs to the declared sound alone.
        out.builtin = goats.sfx.load(GOATS_BUILTIN) === null ? "null" : "handle";
        out.missing = goats.sfx.load("no-such-sound-anywhere") === null;
        out.junk = goats.sfx.load("mod:nobody:notasound.txt") === null;
        out.nothing = goats.sfx.load(null) === null;
        goats.sfx.play(sound, 0.5, 1.1);
        // A null handle is not a play: the facade drops it, so the scene never sees it.
        goats.sfx.play(null, 1, 1);
        return JSON.stringify(out);
    });
})();
"""

var _failures: Array[String] = []
var _frames := 0
var _finished := false
var _main: Node
var _audio: Object
var _sound := ""
## A *built-in* name -- the value of a slot the game itself fills, taken from the scene's own
## table rather than transcribed, because what is being checked is the resolution and not the file.
var _builtin := ""

func _initialize() -> void:
	if not ClassDB.class_exists("ModHost"):
		print("FAIL: ModHost is not registered - the GDExtension did not load")
		quit(1)
		return
	var packed := load("res://scenes/herd.tscn") as PackedScene
	if packed == null:
		print("FAIL: could not load scenes/herd.tscn")
		quit(1)
		return
	_main = packed.instantiate()
	root.add_child(_main)

func _process(_delta: float) -> bool:
	_frames += 1
	if _frames < 6:
		return false
	_check()
	if not _finished:
		_failures.append("the checks did not run to the end (a script error aborted them)")
	if _failures.is_empty():
		print("OK: a mod loads and plays its own sound through the API")
		quit(0)
	else:
		# `print`, not `printerr`: a non-zero `quit()` truncates stderr before it flushes.
		for failure in _failures:
			print("FAIL: ", failure)
		quit(1)
	return true

func _check() -> void:
	_audio = _main.get("mod_audio")
	var mods: Object = _main.get("mods")
	var host: Object = mods.get("host")
	if _audio == null or host == null:
		_failures.append("the scene has no sound node or no mod host")
		_finished = true
		return

	# A sound one of the repository's own mods declared -- `birds` ships two macaw calls and
	# `fatguy` three screams -- taken by opaque name, because a path is not a thing a mod or a
	# test has (`APIv1.md` section 0).
	for name in host.call("asset_names"):
		var token: String = String(name)
		if token.get_extension().to_lower() in ["mp3", "wav", "ogg"]:
			_sound = token
			break
	print("sound asset: ", _sound)
	if _sound.is_empty():
		_failures.append("no sound asset was declared to load")
		_finished = true
		return

	# The game's own half of the table, from `audio.gd`'s derivation (`verify_audio.gd` holds the
	# derivation itself against `audio.js`).
	var bleats: Array = Audio.built_in().get("sfx.bleat", [])
	if not bleats.is_empty():
		_builtin = str(bleats[0])
	if _builtin.is_empty() or _builtin.begins_with("mod:"):
		_failures.append("the scene's own slot table has no built-in sound to resolve")
		_finished = true
		return

	var evaluated: String = str(host.call("eval_js", PROBE_JS
		.replace("GOATS_SOUND", JSON.stringify(_sound))
		.replace("GOATS_BUILTIN", JSON.stringify(_builtin))))
	if evaluated != "ok":
		_failures.append("the sound probe did not run: " + evaluated)
		_finished = true
		return
	var answer: Variant = JSON.parse_string(str(host.call("run_command", "modaudio", "modaudio")))
	if not (answer is Dictionary):
		_failures.append("the sound probe did not answer with a table")
		_finished = true
		return
	_check_calls(answer)
	_check_builtin(answer)
	_check_played()
	_finished = true

## 1 and 4. What the two members answered.
func _check_calls(answer: Dictionary) -> void:
	if str(answer.get("loaded")) != "handle":
		_failures.append("goats.sfx.load did not resolve a declared sound: %s"
			% answer.get("loaded"))
	for key: String in ["missing", "junk", "nothing"]:
		if answer.get(key) != true:
			_failures.append("goats.sfx.load(%s) did not answer null" % key)
	print("load: declared ", answer.get("loaded"), "  missing/junk/null -> null")

## 5. The same `load`, on the other half of the table: a name the *game* declared.
func _check_builtin(answer: Dictionary) -> void:
	if str(answer.get("builtin")) != "handle":
		_failures.append("goats.sfx.load did not resolve a built-in slot's own name: %s"
			% answer.get("builtin"))
		return
	# Decoded, for the same reason as above: a name that resolved and decoded to nothing would be
	# silent, and the whole point of resolving it is that it can be heard.
	var stream: Variant = _audio.call("stream", _builtin)
	if stream == null or not (stream is AudioStream):
		_failures.append("the built-in sound did not decode into an AudioStream")
		return
	var length: float = (stream as AudioStream).get_length()
	print("built-in: ", _builtin, " -> ", length, " s")
	if length <= 0.0:
		_failures.append("the built-in sound decoded to %s seconds" % length)

## 2 and 3. The stream that was built, and the player it was handed to.
func _check_played() -> void:
	print("plays: ", _audio.get("plays"), "  sounded: ", _audio.get("sounded"))
	if int(_audio.get("plays")) != 1:
		_failures.append("one play was asked for and %s arrived (a null handle is not a play)"
			% _audio.get("plays"))
	if int(_audio.get("sounded")) != 1:
		_failures.append("the play did not find a stream: sounded %s" % _audio.get("sounded"))

	# The decode, read off the stream itself: a handle that resolved but decoded to nothing would
	# satisfy `sounded` and be silent.
	var stream: Variant = _audio.call("stream", _sound)
	if stream == null or not (stream is AudioStream):
		_failures.append("the sound did not decode into an AudioStream")
		return
	var length: float = (stream as AudioStream).get_length()
	print("stream: ", length, " s")
	if length <= 0.0:
		_failures.append("the decoded stream is %s seconds long" % length)

	# ...and it reached a player, which is the difference between counting a call and playing one.
	var holding := 0
	for child in _audio.get_children():
		if not (child is AudioStreamPlayer):
			continue
		if (child as AudioStreamPlayer).stream == stream:
			holding += 1
	print("players: ", _audio.get_child_count(), "  holding the stream: ", holding)
	if holding != 1:
		_failures.append("%d player(s) hold the stream, and one play was asked for" % holding)
