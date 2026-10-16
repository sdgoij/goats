# Voice chat's device half (M13b): the microphone and the ear.
#
# The *codec* is Rust (`crates/godot/src/voice.rs` over `crates/voice`): the Opus coder, the
# speech gate and the resampler are the same code the raylib client runs, so a frame on the
# wire is the same bytes whichever client sent it. What Rust cannot do is touch a sound card
# in Godot -- and this session's "(a)" chose Godot for *both* devices -- so this node is the
# two ends the codec is missing:
#
#   * **the microphone**, an `AudioStreamPlayer` over an `AudioStreamMicrophone` on a bus of
#     its own carrying an `AudioEffectCapture` (`BUS`), muted at its output so the player
#     never hears themselves. The bus runs at the project's mix rate, so the samples are
#     handed to the codec at *that* rate and the shared resampler takes them to 48 kHz -- the
#     port does not retune the audio server to suit the codec, it resamples like any other
#     host with an unusual rate (`crates/goats`'s own `Resampler`).
#   * **the ear**, an `AudioStreamGenerator` at the wire's 48 kHz (`SAMPLE_RATE`) into which
#     the decoded mix is pushed. Godot's generator is stereo, so a mono sample is pushed as
#     both channels.
#
# Nothing here knows about the wire: the scene's `NetBridge` owns the session and hangs the
# codec's `#[func]`s on itself (`push_voice`/`pull_voice`/`set_voice_gain`), and this module is
# the frame the scene calls once to move samples both ways. The master mute is `audio.gd`'s and
# arrives here as `set_muted`, which is the same gain the raylib client's mixer reads.

class_name Voice
extends Node

## The bus the microphone is captured on. A bus of its own so the game's own sound never
## reaches the capture, and muted at its output so the microphone is not heard twice.
const BUS := "Capture"
## The wire's rate, and so the generator's: `crates/voice`'s `SAMPLE_RATE`, the one Opus is
## built for.
const SAMPLE_RATE := 48000.0
## How much decoded audio the generator holds, in seconds. A tenth is the engine's own default
## and enough that a late frame is a gap rather than a click.
const BUFFER_LENGTH := 0.1

## The bridge whose session voice travels on, set by the scene. Nothing happens until it is,
## which is what keeps a headless gate (no audio device, no bridge) safe.
var bridge: Node = null

## The capture effect, the two players and the generator's playback, built in `_ready`.
var _capture: AudioEffectCapture = null
var _mic: AudioStreamPlayer = null
var _player: AudioStreamPlayer = null
var _playback: AudioStreamGeneratorPlayback = null
var _muted := false

func _ready() -> void:
	var index := AudioServer.get_bus_index(BUS)
	if index < 0:
		AudioServer.add_bus()
		index = AudioServer.bus_count - 1
		AudioServer.set_bus_name(index, BUS)
	# A bus of this name already carrying a capture effect is one an earlier `Voice` set up (a
	# gate that built a scene and then another); reuse it rather than stacking a second.
	if AudioServer.get_bus_effect_count(index) > 0 \
			and AudioServer.get_bus_effect(index, 0) is AudioEffectCapture:
		_capture = AudioServer.get_bus_effect(index, 0)
	else:
		_capture = AudioEffectCapture.new()
		AudioServer.add_bus_effect(index, _capture)
	# Muted at the output: the capture still sees the microphone (effects run before the bus is
	# summed), but it is not played back through the speakers as well.
	AudioServer.set_bus_mute(index, true)
	# The microphone, played *onto* the capture bus. `AudioStreamMicrophone` needs the project's
	# `audio/driver/enable_input` (set in `project.godot`), or it is silence.
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = BUS
	add_child(_mic)
	_mic.play()

	var generator := AudioStreamGenerator.new()
	generator.mix_rate = SAMPLE_RATE
	generator.buffer_length = BUFFER_LENGTH
	_player = AudioStreamPlayer.new()
	_player.stream = generator
	add_child(_player)
	_player.play()
	_playback = _player.get_stream_playback()

## The frame: send what the microphone has, play what the session sent. Called once a frame by
## the scene on *both* sides of its pause, because a session's speech does not stop when the
## world does -- the same reason the raylib client pumps its mixer outside its own pause gate.
func update() -> void:
	if bridge == null:
		return
	_send()
	_play()

func _send() -> void:
	if _capture == null:
		return
	var available := _capture.get_frames_available()
	if available <= 0:
		return
	# `get_buffer` returns exactly what is asked for, or nothing, so asking for what is
	# available is the whole buffer and no microphone frame is left behind.
	var block := _capture.get_buffer(available)
	if block.is_empty():
		return
	# The bus is stereo; the wire is mono, so the channels are averaged (`crates/goats`'s own
	# downmix, per frame).
	var mono := PackedFloat32Array()
	mono.resize(block.size())
	for i in block.size():
		mono[i] = (block[i].x + block[i].y) * 0.5
	bridge.call("push_voice", mono, AudioServer.get_mix_rate())

func _play() -> void:
	if _playback == null:
		return
	var room := _playback.get_frames_available()
	if room <= 0:
		return
	# Ask the codec for exactly the room the generator has, so nothing decoded is dropped in the
	# handoff; whatever does not fit waits for the next frame.
	var pcm: PackedFloat32Array = bridge.call("pull_voice", room)
	if pcm.is_empty():
		return
	var stereo := PackedVector2Array()
	stereo.resize(pcm.size())
	for i in pcm.size():
		stereo[i] = Vector2(pcm[i], pcm[i])
	_playback.push_buffer(stereo)

## The scene's master mute (`audio.set_muted` hands it here). Voice is the codec's and the
## wire's, so the only lever the scene has is the gain -- `audio.js`'s `voice_gain` intent,
## applied at the mix.
func set_muted(next: bool) -> void:
	_muted = next
	if bridge != null:
		bridge.call("set_voice_gain", 0.0 if _muted else 1.0)

## The codec's own counters, for a probe: `{"sent":..,"decoded":..,"buffered":..,"gain":..}`,
## or empty before the bridge is set. It is the bridge's `voice_state` passed straight through.
func state() -> String:
	if bridge == null:
		return ""
	return String(bridge.call("voice_state"))
