# A mod's own sound (`APIv1.md` section 4.20): the API's answer to the engine's
# `loadSound`/`playSound`/`setSoundVolume`/`setSoundPitch`, and the last capability either example
# still read through `rl`.
#
# It is the twin of `mod_world.gd` and `mod_hud.gd`, with the one difference that matters: a draw
# is a *frame's* thing and a sound is not. A draw is queued as a record and painted when the frame
# is drawn; a sound is a thing to *do*, so it is reached through the scene's own `Callable` seam
# (`main.gd`'s `_mod_call`) the moment the mod asks -- the same distinction the port drew when it
# made `terrainHeight` cross rather than be pushed.
#
# **And that is why the decode cannot be lazy.** A member reached through that seam runs *inside* a
# mod's own JavaScript, and the extension is borrowed while it does -- so this file calling back
# into `ModHost` for the bytes of a sound would be a re-entrant borrow, which is what it did first
# and what Godot reports as `Bug: Invalid call error code 1337`. So the bytes are read at `prepare`,
# once, when nothing is running (`main.gd` calls it in `_ready`), and `stream` is a cache read and
# nothing else. The cost is that every sound the loaded mods *declared* is decoded at boot rather
# than on first use, which for a handful of short effects is nothing and for a player is invisible.
#
# Three more decisions worth naming:
#
#   * **The bytes are the host's, the decoding is Godot's.** A mod never has a path
#     (`APIv1.md` section 0); it has an opaque name, and `ModHost::asset_bytes` is what turns one
#     into the file the mod declared.
#   * **The format is the name's.** An opaque name ends in the asset's own extension -- that is
#     *why* it does (`APIv1.md` section 4.11, so an engine can pick its decoder from it) -- so this
#     reads the extension rather than guessing, and says so when it has no decoder for one.
#   * **`play` takes the volume and the pitch, rather than the handle keeping them.** raylib's
#     `setSoundVolume`/`setSoundPitch` mutate the *sound*, so two plays of one handle share a
#     volume; Godot's player is per-play. The API asks for per-play values, which is what both
#     examples mean, and each client puts them where its engine wants them.
class_name ModAudio
extends Node

## The `ModHost`, so an opaque asset name can be turned into bytes. Set by the frame, before
## `prepare` is called and therefore long before any mod's hook runs.
var host: Object
## How many players to cycle. A mod's sounds are short and will overlap -- a flock of six birds
## squawking at once -- and `audio.gd`'s own pool is the same handful-sized answer.
const POOL := 8
## How many plays have been asked for, and how many found a sound. Evidence rather than a
## decision, and the thing a headless gate can read where it cannot hear.
var plays := 0
var sounded := 0

var _players: Array[AudioStreamPlayer] = []
var _streams := {}
var _next := 0

## Decode every sound the loaded mods declared, once, at a moment when no mod is running. This is
## the only place in this file that touches `host`, and the header says why it has to be here.
func prepare() -> void:
	if host == null:
		return
	for name in host.call("asset_names"):
		var token: String = String(name)
		if _decodable(token):
			_decode(token)

## The stream behind a sound name, or null. **A cache read and nothing else** -- a name that was
## never declared, or that this build could not decode, is a `null` here, which is the `null`
## `goats.sfx.load` answers.
##
## One thing is loaded here rather than in `prepare`, and it is safe because it touches no host: a
## **built-in** slot's value is one of the game's own files under `res://assets/`, and `res://` is
## this process's own (a mod's bytes are the host's, and only those need the safe moment).
func stream(name: String) -> AudioStream:
	if _streams.has(name):
		return _streams[name]
	if name.begins_with("mod:"):
		return null
	var built: AudioStream = null
	var path: String = Audio.ASSET_ROOT + name
	if ResourceLoader.exists(path):
		var loaded: Variant = ResourceLoader.load(path)
		if loaded is AudioStream:
			built = loaded
	_streams[name] = built
	return built

## Play a sound, `volume` in 0..1 and `pitch` a rate multiplier (`APIv1.md` section 4.20). A mod
## that wants attenuation computes it itself and passes the result, which is what the two examples
## already do -- a bird's squawk is quieter the further the goat is.
func play(name: String, volume: float, pitch: float) -> bool:
	plays += 1
	var sound: AudioStream = stream(name)
	if sound == null:
		return false
	var player: AudioStreamPlayer = _player()
	player.stream = sound
	# `-80` is silent rather than `linear_to_db(0)`, which is `-inf` -- the same floor `audio.gd`
	# uses, so a muted play is quiet and not a special case.
	player.volume_db = linear_to_db(clampf(volume, 0.0, 1.0)) if volume > 0.0 else -80.0
	player.pitch_scale = clampf(pitch, 0.01, 4.0)
	player.play()
	sounded += 1
	return true

## Whether a declared asset's name is one this build has a decoder for, read off the extension the
## opaque name deliberately ends in.
static func _decodable(name: String) -> bool:
	return name.get_extension().to_lower() in ["mp3", "wav", "ogg"]

## Build and remember one stream. A name that fails is remembered as a `null` too, so a bad sound
## is reported once rather than once per boot-time pass.
func _decode(name: String) -> void:
	var built: AudioStream = null
	var bytes: PackedByteArray = host.call("asset_bytes", name)
	if bytes.is_empty():
		print("mod: no bytes for the sound ", name)
	else:
		match name.get_extension().to_lower():
			"mp3":
				built = AudioStreamMP3.load_from_buffer(bytes)
			"wav":
				built = AudioStreamWAV.load_from_buffer(bytes)
			"ogg":
				built = AudioStreamOggVorbis.load_from_buffer(bytes)
	_streams[name] = built

## A player to use: one that is idle, or the oldest when they are all busy. Built on the first
## play, because a mod that never sounds anything costs nothing.
func _player() -> AudioStreamPlayer:
	if _players.is_empty():
		for _at in POOL:
			var player := AudioStreamPlayer.new()
			add_child(player)
			_players.append(player)
	for player: AudioStreamPlayer in _players:
		if not player.playing:
			return player
	var oldest: AudioStreamPlayer = _players[_next]
	_next = (_next + 1) % _players.size()
	return oldest
