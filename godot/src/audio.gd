# The sound (M22): `audio.js` transcribed, and the last of the scene's senses to arrive.
#
# Ten *slots*, each a list of variants and each variant a fixed pool of copies, because the
# scene's own audio is slot-addressed rather than path-addressed: a mod that declares an asset
# for `sfx.bleat` adds a variant to the flock rather than replacing a file (`core.js`
# `ASSET_SLOTS`, `mods.js` `modApplyAssets`). This module reads the same table, so a mod's
# sounds will arrive with the rest of the mod surface.
#
# Three of the ten are **empty in the shipped build** -- `sfx.blast.close`, `sfx.fuse` and
# `sfx.trap` were reserved by M19g and the samples never arrived -- and an empty slot is
# *silence*, not an error, which is why every play below can find nothing and say so quietly.
#
# Four rules are the whole of it, and each is one a lookalike gets subtly wrong:
#
#   * **a variant at random, then a copy that is not already in the air.** A `Sound` played
#     twice restarts, so three copies per variant is what lets two bangs sound like two bangs
#     rather than one that hiccuped. Godot's `playing` is the same question `isSoundPlaying` is.
#   * **a little pitch variation per play**, so a minefield does not sound like a button.
#   * **a bang falls off with distance** -- full volume anywhere inside the blast's own radius,
#     half at twenty-odd metres, tending to silence rather than reaching it -- and a *chained*
#     bang is quieter with every link, so a five-device cascade reads as a sequence rather than
#     as five times the peak.
#   * **its grit comes down a beat later**, at the distance the bang was *heard* at rather than
#     from where the goat now is, so the fall belongs to the same event even though the goat has
#     usually been thrown clear by the time it lands.
#
# The variety PRNG is the scene's own xorshift, transcribed bit for bit and kept **separate from
# the weather's** on purpose: `audio.js` says why ("so the weather sequence stays reproducible"),
# and it means a gate can hold this stream against the JavaScript's without a simulated frame.
#
# What is *not* the scene's: the three beds are `AudioStreamPlayer`s where the client had raylib
# `Music` handles. They are started at zero volume and left playing, which is the scene's own
# trick to avoid a start/stop click at every weather transition.
#
# Every local is annotated rather than inferred -- see the `:=` note in `terrain.gd`.
class_name Audio
extends Node

## `audio.js`'s own numbers, named as it names them.
const MUSIC_VOLUME := 0.20
const SFX_VOLUME := 0.65
const RAIN_VOLUME := 0.9
const WIND_VOLUME := 0.8
const BLAST_VOLUME := 1.0
const BLAST_FALLOFF := 24.0
const BLAST_CLOSE_RANGE := 6.0
const FUSE_VOLUME := 0.5
const TRAP_VOLUME := 0.6
const DEBRIS_VOLUME := 0.55
const DEBRIS_DELAY := 0.42
const DEBRIS_SPREAD := 0.34
const DEBRIS_CAPACITY := 8
## Copies of each effect loaded per variant (`SFX_POOL`).
const SFX_POOL := 3

## The thunder's own schedule (`updateAudio`): the rain has to be at least this wet, the first
## roll comes after `THUNDER_FIRST`, and each roll sets the next `8 + rnd() * 14` out.
const THUNDER_RAIN := 0.55
const THUNDER_FIRST := 6.0
const THUNDER_MIN := 8.0
const THUNDER_SPREAD := 14.0
const THUNDER_VOLUME := 0.8

## The variety PRNG's seed (`audioSeed`), and the divisor that turns its word into a fraction.
const SEED := 0x2F6E2B1
const WORD := 4294967296.0

## Silence in decibels. A gain of zero is `linear_to_db(0)` = -inf, which is not a value an
## `AudioStreamPlayer` wants written at it, so the floor is explicit.
const QUIET := -80.0

## The slot table (`core.js` `ASSET_SLOTS`), the same paths the client embeds. `godot/assets/`
## is a copy rather than a reference because Godot exports only `res://`, the same reason the
## model is one.
const SFX := ASSET_ROOT + "sfx/"
## Everything the game ships lives under here, and a *built-in slot's value* is the part after it:
## a mod is handed logical names, never a path (`APIv1.md` section 0), so the port derives them
## from its own table rather than keeping a second copy of the strings.
const ASSET_ROOT := "res://assets/"
const BEDS := {
	"sfx.music": SFX + "jkstudios-rage-2-187959.mp3",
	"sfx.rain": SFX + "WE Heavy Outside Rain 1.ogg",
	"sfx.wind": SFX + "WE Light Wind Whistle 1.ogg",
}
const SLOTS := {
	"sfx.bleat": [
		SFX + "dragon-studio-goat-baa-390303.mp3",
		SFX + "dragon-studio-goat-kid-bleating-390290.mp3",
		SFX + "dragon-studio-goat-sound-390298.mp3",
		SFX + "dragon-studio-goat-sound-effect-390305.mp3",
		SFX + "mightuser-1-goat-sound-effect-259473.mp3",
		SFX + "freesound_community-happy-goat-6463.mp3",
	],
	"sfx.thunder": [
		SFX + "WE Thunder 1.ogg",
		SFX + "WE Thunder 26.ogg",
		SFX + "WE Thunder 29.ogg",
	],
	"sfx.blast": [
		SFX + "dragon-studio-explosion-sound-effect-425455.mp3",
		SFX + "dragon-studio-loud-explosion-425457.mp3",
		SFX + "freesound_community-medium-explosion-40472.mp3",
		SFX + "soundreality-explosion-fx-343683.mp3",
		SFX + "universfield-epic-cinematic-explosion-454857.mp3",
	],
	"sfx.debris": [
		SFX + "freesound_community-falling-rock-105396.mp3",
		SFX + "freesound_community-gravel-stone-dirt-debris-falling-small-1-3-36216.mp3",
		SFX + "freesound_community-stones-falling-6375.mp3",
		SFX + "universfield-heavy-object-falling-291096.mp3",
	],
	## The three M19g slots, empty on purpose: the samples have not arrived, and silence is the
	## degradation, exactly like a missing texture.
	"sfx.blast.close": [],
	"sfx.fuse": [],
	"sfx.trap": [],
}

## The built-in slot table (`APIv1.md` section 4.11), as *logical names* -- what a mod is handed,
## and what the port resolves back to `res://assets/<name>` when something asks to load one. It is
## derived from the tables above rather than transcribed, so the game's own files are named in
## exactly one place.
##
## An **empty** slot is not a slot the game has. `core.js`'s `ASSET_SLOTS` is the authority, and it
## holds only slots that have files; the three M19g ones above (`sfx.blast.close`, `sfx.fuse`,
## `sfx.trap`) are *reserved* -- `audio.js` reads them by name at play time and `assetList` answers
## an absent slot with an empty list, which is how an unimplemented sound is silence rather than an
## error -- so they belong in this module's play table and not in the asset table. Skipping empty
## lists is that rule, and it is a rule about the *table* rather than about silence: a mod that
## declares one of the three puts it in `goats.assets.slots()` by declaring it, exactly as in the
## reference client, and this derivation does not anticipate that by listing it early.
static func built_in() -> Dictionary:
	var out: Dictionary = {"model.goat": "goat_animated.glb"}
	for key: String in BEDS:
		out[key] = String(BEDS[key]).trim_prefix(ASSET_ROOT)
	for key: String in SLOTS:
		var names: Array = []
		for path: String in SLOTS[key]:
			names.append(path.trim_prefix(ASSET_ROOT))
		if names.is_empty():
			continue
		out[key] = names
	return out

## `SETTINGS.bgm` / `SETTINGS.sfx`, 0..100, and the master mute. The menu's two sliders and its
## `M` key are stage 6; until then these are the defaults and the `M` key is the mute.
var bgm := 90.0
var sfx := 90.0
var muted := false

## The goat a bang's distance is measured from (`blastAttenuation` reads `goat.px/pz`).
var goat: PlayerGoat

## The scene's radius for a bang's own reach (`TUNING.explosions.blast.radius`), read from the
## devices rather than repeated, so retuning one retunes the other.
var blast_radius := 3.2

## Where the master mute is handed on: voice's mixer is Rust and lives on the bridge, so the only
## lever this module has is the gain. `main.gd` points it at `voice.gd`'s `set_muted`, and it is a
## `Callable` rather than a reference because this module does not know voice exists.
var on_mute := Callable()

var _variants := {}
var _beds := {}
var _debris: Array[Dictionary] = []
var _thunder_cooldown := THUNDER_FIRST
var _seed := SEED
var _built := false

func _ready() -> void:
	build()

## Load the beds and the slots, once. Called from `_ready` and from the plays, for the reason
## `water_mesh.gd` builds its material inside `build`: a node added during `_initialize` never
## sees `_ready`, and a silent scene is indistinguishable from a broken one.
func build() -> void:
	if _built:
		return
	_built = true
	for name: String in BEDS:
		var path: String = BEDS[name]
		var player := _player(path)
		if player == null:
			continue
		# A bed loops and starts at silence: the ambience swells with the weather rather than
		# starting and stopping at every transition, which is where the click would be.
		_loop(player.stream)
		player.volume_db = QUIET
		player.play()
		_beds[name] = player
	for name: String in SLOTS:
		var paths: Array = SLOTS[name]
		_variants[name] = _load_slot(paths)

## `audio.js` `arnd`: the variety PRNG, bit for bit. xorshift32, and the shifts are masked
## because GDScript's `int` is 64-bit and signed where the scene's is 32-bit and unsigned.
func rnd() -> float:
	_seed = (_seed ^ ((_seed << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
	_seed = (_seed ^ (_seed >> 17)) & 0xFFFFFFFF
	_seed = (_seed ^ ((_seed << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
	return float(_seed) / WORD

## Take the variety stream from the session seed (`weather.js` `sceneUseSeed` draws the weather,
## the bots and the food first, so this is the **fourth** -- `audioSeed`). It is here so two players
## in a session hear the same bleat picked for the same event rather than each picking their own.
func use_seed(seed: int) -> void:
	var state: int = seed & 0xFFFFFFFF
	if state == 0:
		state = 1
	var value: int = 1
	for draw in 4:
		state = (state ^ ((state << 13) & 0xFFFFFFFF)) & 0xFFFFFFFF
		state = (state ^ (state >> 17)) & 0xFFFFFFFF
		state = (state ^ ((state << 5) & 0xFFFFFFFF)) & 0xFFFFFFFF
		if state == 0:
			state = 1
		value = state
	_seed = value

## The variety stream as the wire carries it. `_seed` is already the unsigned word, which is the
## unit `proto::Streams::audio` is typed in.
func stream() -> int:
	return _seed

func use_stream(value: int) -> void:
	_seed = value & 0xFFFFFFFF

## `blastAttenuation` as a pure rule, from the offset to the bang and the bang's own radius:
## full volume anywhere inside the blast, half at twenty-odd metres, tending to silence rather
## than reaching it.
static func attenuation(dx: float, dz: float, near: float) -> float:
	var d: float = maxf(0.0, sqrt(dx * dx + dz * dz) - near)
	return 1.0 / (1.0 + d / BLAST_FALLOFF)

## How much of a bang survives being the `depth`-th link of a chain: quieter with every link, so
## a five-device cascade reads as a sequence rather than as five times the peak.
static func chain_gain(depth: int) -> float:
	return 1.0 / (1.0 + 0.6 * float(maxi(depth, 0)))

## What a bed is scaled by, as a linear gain: the music gain times the weather's own share, or
## silence while muted. A *rule*, and separate from the decibels Godot wants to be handed -- the
## scene has no decibels, so a case that compared them would be comparing this port's plumbing.
static func bed_gain(music: float, is_muted: bool, scale: float) -> float:
	return 0.0 if is_muted else music * scale

## How loud a bang at `(x, z)` is from where the goat is: `audio.js` `blastAttenuation`.
func blast_attenuation(x: float, z: float) -> float:
	if goat == null:
		return 1.0
	return attenuation(x - goat.px, z - goat.pz, blast_radius)

## Which variant a roll picks, out of `count` (`sfxPick`'s `Math.floor(arnd() * slot.length) %
## slot.length`). Static and pure so a case can hold it without an audio device.
static func variant_of(roll: float, count: int) -> int:
	return int(floor(roll * float(count))) % count

## Which copy of a variant to play: the first that is *not* already in the air, and the first
## one when they all are -- a `Sound` played twice restarts, and a restarted bang is worse than
## a dropped one. `busy` is one flag a copy, in order. Static for the same reason.
static func copy_of(busy: Array) -> int:
	for index in busy.size():
		if not bool(busy[index]):
			return index
	return 0

## One play out of a slot: a variant at random, and inside it a copy that is not already in the
## air (`sfxPick`). Null when the slot is empty, which is a slot nobody has filled.
func pick(slot: String) -> AudioStreamPlayer:
	var variants: Array = _variants.get(slot, [])
	if variants.is_empty():
		return null
	var copies: Array = variants[variant_of(rnd(), variants.size())]
	var busy: Array = []
	for player: AudioStreamPlayer in copies:
		busy.append(player.playing)
	return copies[copy_of(busy)]

## A bleat, at the gain the situation calls for (`playBleat`). A muted bleat draws no random
## numbers at all, which is `audio.js`'s own order and is why the guard is above the pick.
func bleat(gain: float) -> bool:
	build()
	if muted or _variants.get("sfx.bleat", []).is_empty():
		return false
	var player: AudioStreamPlayer = pick("sfx.bleat")
	if player == null:
		return false
	player.volume_db = _db(sfx_gain() * gain)
	player.pitch_scale = 0.9 + rnd() * 0.25
	player.play()
	return true

## The click between a trigger and its bang (`playTrigger`): `sfx.trap` for a trapped tuft,
## `sfx.fuse` for a mine. Played where the device is, so one the goat walks away from still
## ticks behind it.
func trigger(kind: String, x: float, z: float) -> bool:
	build()
	if muted:
		return false
	var slot: String = "sfx.trap" if kind == "trap" else "sfx.fuse"
	if _variants.get(slot, []).is_empty():
		return false
	var player: AudioStreamPlayer = pick(slot)
	if player == null:
		return false
	var scale: float = TRAP_VOLUME if kind == "trap" else FUSE_VOLUME
	player.volume_db = _db(sfx_gain() * scale * blast_attenuation(x, z))
	player.pitch_scale = 0.95 + rnd() * 0.1
	player.play()
	return true

## A bang at `(x, z)`, `depth` links into its chain (`playBlast`). The grit it throws is
## *queued* here and played by `update`, which is what makes the two halves one event.
func bang(x: float, z: float, depth: int) -> bool:
	build()
	if muted:
		return false
	var att: float = blast_attenuation(x, z)
	var chain: float = chain_gain(depth)
	# The close mix, when somebody has filled that slot and the goat is inside its range: the
	# same bang without the room, which is "you got hit" rather than "that went off over there".
	var slot: String = "sfx.blast"
	if not _variants.get("sfx.blast.close", []).is_empty() and goat != null:
		var dx: float = x - goat.px
		var dz: float = z - goat.pz
		if dx * dx + dz * dz <= BLAST_CLOSE_RANGE * BLAST_CLOSE_RANGE:
			slot = "sfx.blast.close"
	if _variants.get(slot, []).is_empty():
		return false
	var player: AudioStreamPlayer = pick(slot)
	if player == null:
		return false
	player.volume_db = _db(sfx_gain() * BLAST_VOLUME * att * chain)
	player.pitch_scale = 0.92 + rnd() * 0.16
	player.play()
	# ...and its grit later. The *delay* is drawn before the sample is picked, because that is
	# the order the scene's object literal evaluates them in and this stream is shared.
	if not _variants.get("sfx.debris", []).is_empty():
		if _debris.size() >= DEBRIS_CAPACITY:
			_debris.remove_at(0)
		var delay: float = DEBRIS_DELAY + rnd() * DEBRIS_SPREAD
		var fall: AudioStreamPlayer = pick("sfx.debris")
		_debris.append({"left": delay, "player": fall, "att": att * chain})
	return true

## One frame: tie the beds to the weather, roll the thunder, and drop whatever grit is due
## (`updateAudio`). `rain_amount` and `wind_sway` are the session's own or the local machine's,
## which is why they arrive rather than being read here.
func update(delta: float, rain_amount: float, wind_sway: float) -> void:
	build()
	_set_bed("sfx.music", 1.0)
	_set_bed("sfx.rain", rain_amount * RAIN_VOLUME)
	_set_bed("sfx.wind", wind_sway * WIND_VOLUME)
	_thunder_cooldown -= delta
	if rain_amount > THUNDER_RAIN and _thunder_cooldown <= 0.0 \
			and not _variants.get("sfx.thunder", []).is_empty():
		var roll: AudioStreamPlayer = pick("sfx.thunder")
		if not muted and roll != null:
			roll.volume_db = _db(sfx_gain() * THUNDER_VOLUME)
			roll.play()
		# The next roll is scheduled whether or not this one was heard, which is the scene's own
		# order: a mute must not compress the thunder into a roll a frame.
		_thunder_cooldown = THUNDER_MIN + rnd() * THUNDER_SPREAD
	# Whatever grit is due. The gain and the mute are read *here* rather than at the bang, so a
	# player who turns the volume down in the second between the two hears the change.
	for index in range(_debris.size() - 1, -1, -1):
		var fall: Dictionary = _debris[index]
		fall["left"] = float(fall["left"]) - delta
		if float(fall["left"]) > 0.0:
			continue
		_debris.remove_at(index)
		if muted:
			continue
		var player: AudioStreamPlayer = fall["player"]
		if player == null:
			continue
		player.volume_db = _db(sfx_gain() * DEBRIS_VOLUME * float(fall["att"]))
		player.pitch_scale = 0.9 + rnd() * 0.2
		player.play()

## The master mute (`setMuted`). The scene also tells the session its voice gain here, which
## `audio.js` does through `voiceGainChanged`: the sound this module owns goes quiet on the line
## below, and a peer's voice goes quiet at the mixer (`on_mute`, above).
func set_muted(next: bool) -> void:
	muted = next
	_set_bed("sfx.music", 1.0)
	if on_mute.is_valid():
		on_mute.call(muted)

## The scene's own read-out, for a probe or the HUD: what is loaded, what is playing and what is
## waiting. `levels` is what the beds are at, which is the only part of this that a picture of a
## frame cannot show.
func state() -> Dictionary:
	return {
		"muted": muted,
		"bleats": _variants.get("sfx.bleat", []).size(),
		"thunders": _variants.get("sfx.thunder", []).size(),
		"blasts": _variants.get("sfx.blast", []).size(),
		"debris": _variants.get("sfx.debris", []).size(),
		"fuses": _variants.get("sfx.fuse", []).size(),
		"traps": _variants.get("sfx.trap", []).size(),
		"close": _variants.get("sfx.blast.close", []).size(),
		"pending": _debris.size(),
		"thunder_cooldown": _thunder_cooldown,
		"beds": _beds.size(),
		"levels": _levels(),
	}

## What each bed is at, in decibels. A bed's level is the one part of this module a *frame*
## decides rather than an event, so it is the one worth reading back.
func _levels() -> Dictionary:
	var out := {}
	for name: String in _beds:
		out[name] = float((_beds[name] as AudioStreamPlayer).volume_db)
	return out

## The word the status line shows (`goat.js`'s `drawHud`): `off` when nothing is loaded, `muted`
## when the master mute is on, `on` otherwise.
func word() -> String:
	build()
	if _beds.is_empty() and _variants.get("sfx.bleat", []).is_empty():
		return "off"
	return "muted" if muted else "on"

## The linear gain the effects are scaled by (`sfxGain`).
func sfx_gain() -> float:
	return SFX_VOLUME * sfx / 100.0

## The linear gain the beds are scaled by (`musicGain`).
func music_gain() -> float:
	return MUSIC_VOLUME * bgm / 100.0

## Set a bed's volume from a *multiple of the music gain*, which is how the scene does it: the
## rain and wind beds are the track's own level scaled by the weather, and a mute is zero.
func _set_bed(name: String, scale: float) -> void:
	if not _beds.has(name):
		return
	var player: AudioStreamPlayer = _beds[name]
	player.volume_db = _db(bed_gain(music_gain(), muted, scale))

## One slot's variants, each with `SFX_POOL` copies of the same stream (`loadSlot`). A slot whose
## files are missing is simply empty.
func _load_slot(paths: Array) -> Array:
	var variants: Array = []
	for path: String in paths:
		var first := _player(path)
		if first == null:
			continue
		var copies: Array = [first]
		for copy in range(1, SFX_POOL):
			var extra := _player(path)
			if extra != null:
				copies.append(extra)
		variants.append(copies)
	return variants

## One loaded player for a file, or null when Godot cannot read it.
func _player(path: String) -> AudioStreamPlayer:
	if not ResourceLoader.exists(path):
		return null
	var stream: AudioStream = load(path) as AudioStream
	if stream == null:
		return null
	var player := AudioStreamPlayer.new()
	player.stream = stream
	add_child(player)
	return player

## Whether a bed repeats. `loop` is not on `AudioStream` itself -- it is each format's own -- so
## this asks the two the bed table uses rather than setting a property that may not be there.
func _loop(stream: AudioStream) -> void:
	if stream is AudioStreamOggVorbis:
		(stream as AudioStreamOggVorbis).loop = true
	elif stream is AudioStreamMP3:
		(stream as AudioStreamMP3).loop = true

## A linear gain as decibels, with zero at the floor rather than at minus infinity.
func _db(gain: float) -> float:
	if gain <= 0.0:
		return QUIET
	return linear_to_db(gain)
