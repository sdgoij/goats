//! Voice chat for the client: capture, voice activity detection, Opus coding
//! and playback.
//!
//! The JS engine cannot touch a sound card, so all of this lives here, in the
//! embedding host. Three things run off the frame loop: `cpal` captures the
//! microphone and frames it, a detector decides when someone is actually
//! speaking, and an Opus encoder turns those frames into packets that the
//! session layer already knows how to relay. Decoding happens off the loop too,
//! but the decoded PCM is handed to raylib *from the frame loop* (`pump`), since
//! raylib's audio calls are easiest to reason about on one thread.
//!
//! There is no push-to-talk key: a frame is speech when it clears an adaptive
//! noise floor by a margin, and a hold plus a small pre-roll keep word tails and
//! onsets intact. That is how most voice chat works, with a proper VAD library
//! (WebRTC, Silero) as the fancier variant; the gate here has no dependency and
//! is easy to tune.

use std::collections::{HashMap, VecDeque};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::thread;
use std::time::Duration;

use crate::net::{Net, VoiceSender};

/// Opus works at 48 kHz and the wire carries 20 ms frames, so a frame is 960
/// samples. The playback stream, the detector and the pre-roll are all sized
/// from these two.
const SAMPLE_RATE: u32 = 48_000;
const FRAME_SAMPLES: usize = 960;

/// Comfortable for voice, and it keeps the full-mesh uplink small.
const BITRATE: i32 = 24_000;

/// The largest packet the wire will accept; mirrors `proto::MAX_VOICE_BYTES`.
const MAX_PACKET_BYTES: usize = 512;

/// Frames the capture callback may queue before dropping. The encoder consumes
/// one per 20 ms, so a backlog means it stalled, and late voice is worse than a
/// gap.
const CAPTURE_BACKLOG: usize = 8;

// Voice activity detection. A fixed threshold either clips quiet talkers or
// fires on room noise, so the gate rides on an adaptive noise floor: it falls
// quickly onto silence and creeps up through it, and a frame is speech when it
// clears the floor by a margin. The hold keeps a word's tail from being cut and
// the pre-roll keeps its onset from being clipped.
const VAD_RATIO: f32 = 3.5; // ~11 dB above the floor
const VAD_FLOOR_MIN: f32 = 0.004; // absolute floor, so a silent room is silent
const VAD_FLOOR_START: f32 = 0.002;
const VAD_FLOOR_FALL: f32 = 0.25; // how fast the floor drops onto quiet input
const VAD_FLOOR_RISE: f32 = 0.002; // how fast it creeps up through noise
const VAD_HOLD_FRAMES: u32 = 15; // 300 ms of tail after the last speech frame
const PREROLL_FRAMES: usize = 2; // 40 ms kept for the onset

/// Packets buffered before a speaker is heard, so playback does not start
/// against an empty mixer. Two packets is ~40 ms, the usual order for voice.
const PLAYOUT_CUSHION_PACKETS: usize = 2;

/// The frame loop's handle on voice: decoded audio waiting for raylib, the
/// per-speaker streams, and the master gain the scene owns.
pub struct Voice {
    decoded: Receiver<(String, Vec<f32>)>,
    speakers: HashMap<String, Speaker>,
    gain: Arc<AtomicU32>,
    /// The gain already written to every stream, so a change can be pushed to
    /// streams that have no new audio this frame (a mute takes effect at once).
    applied_gain: f32,
    running: Arc<AtomicBool>,
}

/// One remote speaker: their raylib stream, plus the audio held back while the
/// playout cushion fills.
struct Speaker {
    stream: raylib_sys::AudioStream,
    /// Samples buffered before playback starts. A 20 ms packet lands while the
    /// mixer is mid-block as often as not, so starting with a cushion keeps the
    /// first words whole. Empty once playing.
    cushion: Vec<f32>,
    playing: bool,
}

impl Voice {
    /// Starts capture, coding and decoding. A host without a microphone still
    /// gets incoming audio: capture simply gives up, with a line on stderr.
    pub fn start(net: &mut Net) -> Voice {
        let running = Arc::new(AtomicBool::new(true));
        let gain = Arc::new(AtomicU32::new(1.0f32.to_bits()));
        let (pcm_tx, pcm_rx) = mpsc::channel();

        // Decoding: one thread, one decoder, one frame at a time. The PCM goes
        // on the std channel above and reaches raylib from the frame loop.
        if let Some(mut voice_rx) = net.take_voice_receiver() {
            let pcm = pcm_tx.clone();
            spawn("voice-out", move || {
                let Some(mut decoder) = Decoder::new() else {
                    eprintln!("[voice] could not create an Opus decoder");
                    return;
                };
                let mut played: u64 = 0;
                while let Some((from, seq, payload)) = voice_rx.blocking_recv() {
                    let Some(samples) = decoder.decode(&payload) else {
                        if debug_on() {
                            eprintln!("[voice] undecodable frame from {from} (seq {seq})");
                        }
                        continue;
                    };
                    played += 1;
                    if debug_on() && (played <= 5 || played.is_multiple_of(100)) {
                        eprintln!(
                            "[voice] {from} seq {seq}: {} bytes -> {} samples",
                            payload.len(),
                            samples.len()
                        );
                    }
                    if pcm.send((from, samples)).is_err() {
                        break;
                    }
                }
            });
        }
        drop(pcm_tx);

        // Capture and coding. The stream is opened on its own thread and kept
        // alive there; the encoder thread only ever sees 20 ms mono frames.
        let sender = net.voice_sender();
        let (raw_tx, raw_rx) = mpsc::sync_channel::<Vec<f32>>(CAPTURE_BACKLOG);
        let capture_running = running.clone();
        spawn("voice-in", move || {
            let Some(stream) = open_input(raw_tx) else {
                eprintln!("[voice] no working microphone; incoming voice still plays");
                return;
            };
            // Dropping the stream stops capture, so hold it until shutdown.
            while capture_running.load(Ordering::Relaxed) {
                thread::sleep(Duration::from_millis(100));
            }
            drop(stream);
        });
        spawn("voice-encode", move || encode_loop(raw_rx, sender));

        Voice {
            decoded: pcm_rx,
            speakers: HashMap::new(),
            gain,
            applied_gain: 1.0,
            running,
        }
    }

    /// The scene's master mute, as a 0..1 gain on everything a peer sends.
    pub fn set_gain(&self, gain: f32) {
        self.gain
            .store(gain.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    /// Hands decoded audio to raylib's mixer. Called once a frame; all raylib
    /// audio calls stay on this thread.
    pub fn pump(&mut self) {
        let gain = f32::from_bits(self.gain.load(Ordering::Relaxed));
        if gain != self.applied_gain {
            self.applied_gain = gain;
            for speaker in self.speakers.values() {
                // SAFETY: every stream came from `LoadAudioStream` and is owned
                // by this map; raylib is only ever touched from this thread.
                unsafe { raylib_sys::SetAudioStreamVolume(speaker.stream, gain) };
            }
        }

        while let Ok((from, samples)) = self.decoded.try_recv() {
            let speaker = speaker_for(&mut self.speakers, from, gain);
            if !speaker.playing {
                speaker.cushion.extend_from_slice(&samples);
                if speaker.cushion.len() < PLAYOUT_CUSHION_PACKETS * FRAME_SAMPLES {
                    continue;
                }
                speaker.playing = true;
                let buffered = std::mem::take(&mut speaker.cushion);
                if gain > 0.0 {
                    feed(speaker.stream, &buffered);
                }
                continue;
            }
            if gain > 0.0 {
                feed(speaker.stream, &samples);
            }
        }
    }
}

/// The stream for one speaker, created on first use.
fn speaker_for(speakers: &mut HashMap<String, Speaker>, from: String, gain: f32) -> &mut Speaker {
    speakers.entry(from.clone()).or_insert_with(|| {
        // SAFETY: a fresh stream from raylib, checked before use.
        let stream = unsafe { raylib_sys::LoadAudioStream(SAMPLE_RATE, 32, 1) };
        if unsafe { raylib_sys::IsAudioStreamValid(stream) } {
            // SAFETY: a live stream, owned by this map from here on.
            unsafe { raylib_sys::SetAudioStreamVolume(stream, gain) };
            unsafe { raylib_sys::PlayAudioStream(stream) };
            if debug_on() {
                eprintln!("[voice] playback stream for {from} (gain {gain})");
            }
        } else {
            eprintln!("[voice] could not open a playback stream for {from}");
        }
        Speaker {
            stream,
            cushion: Vec::new(),
            playing: false,
        }
    })
}

/// Hands one block of PCM to raylib's mixer. raylib keeps a ring buffer, so
/// writing whenever audio arrives is correct: it absorbs the jitter between
/// packets, where gating on `IsAudioStreamProcessed` drops whole packets that
/// land while the mixer is mid-block (which is most of them).
fn feed(stream: raylib_sys::AudioStream, samples: &[f32]) {
    if samples.is_empty() {
        return;
    }
    // SAFETY: `stream` came from `LoadAudioStream`, the slice is live and the
    // frame count matches it, and raylib is only touched from the frame loop.
    unsafe {
        raylib_sys::UpdateAudioStream(stream, samples.as_ptr().cast(), samples.len() as i32);
    }
}

impl Drop for Voice {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        for (_, speaker) in self.speakers.drain() {
            // SAFETY: every stream came from `LoadAudioStream` and is freed once.
            unsafe { raylib_sys::UnloadAudioStream(speaker.stream) };
        }
    }
}

/// The encoder thread: gate on speech, then encode. A frame is spoken if it
/// clears the adapted floor, and a hold keeps it going through short gaps.
fn encode_loop(raw: Receiver<Vec<f32>>, sender: VoiceSender) {
    let Some(mut encoder) = Encoder::new() else {
        eprintln!("[voice] could not create an Opus encoder");
        return;
    };
    let mut gate = Gate::new();
    let mut preroll: VecDeque<Vec<f32>> = VecDeque::new();
    let mut seq = 0u32;
    let mut sent: u64 = 0;
    let mut heard: u64 = 0;
    let mut peak: f32 = 0.0;

    while let Ok(frame) = raw.recv() {
        let rms = frame_rms(&frame);
        heard += 1;
        peak = frame.iter().fold(peak, |max, sample| max.max(sample.abs()));
        // A heartbeat even in silence, so "the callback never fired" and "the
        // microphone is too quiet" do not look the same. Every two seconds.
        if debug_on() && heard.is_multiple_of(100) {
            eprintln!(
                "[voice] in {heard} frames, rms {rms:.4}, peak {peak:.4}, floor {:.4}",
                gate.floor
            );
            peak = 0.0;
        }
        match gate.push(rms) {
            Step::Silence => {
                if preroll.len() == PREROLL_FRAMES {
                    preroll.pop_front();
                }
                preroll.push_back(frame);
                continue;
            }
            Step::Onset => {
                if debug_on() {
                    eprintln!("[voice] speech detected (floor {:.4})", gate.floor);
                }
                // Speech just started: flush what was buffered so the first
                // syllable is whole.
                for buffered in preroll.drain(..) {
                    if send_frame(&mut encoder, &sender, &mut seq, &buffered) {
                        sent += 1;
                    }
                }
            }
            Step::Speech => {}
        }
        if send_frame(&mut encoder, &sender, &mut seq, &frame) {
            sent += 1;
            if debug_on() && sent.is_multiple_of(50) {
                eprintln!("[voice] sent {sent} frames ({:.1} s)", sent as f32 * 0.02);
            }
        }
    }
}

/// What one frame of audio turned out to be.
#[derive(Debug, PartialEq, Eq)]
enum Step {
    /// Below the gate: keep it only for the pre-roll.
    Silence,
    /// The first frame of an utterance; the pre-roll goes out first.
    Onset,
    /// Inside an utterance, including the hold after the last loud frame.
    Speech,
}

/// The speech gate: an adaptive noise floor plus a hold. Split from the thread
/// so it can be tested without a microphone.
struct Gate {
    floor: f32,
    hold: u32,
    active: bool,
}

impl Gate {
    fn new() -> Gate {
        Gate {
            floor: VAD_FLOOR_START,
            hold: 0,
            active: false,
        }
    }

    /// Feeds one frame's RMS and reports what it is. The floor falls quickly
    /// onto quiet input and creeps up through noise, but never adapts while an
    /// utterance is in progress, so a loud voice cannot raise its own threshold.
    fn push(&mut self, rms: f32) -> Step {
        if rms < self.floor {
            self.floor += (rms - self.floor) * VAD_FLOOR_FALL;
        } else if rms < self.floor * VAD_RATIO {
            self.floor += (rms - self.floor) * VAD_FLOOR_RISE;
        }

        let speech = rms > self.floor * VAD_RATIO && rms > VAD_FLOOR_MIN;
        let was_active = self.active;
        if speech {
            self.hold = VAD_HOLD_FRAMES;
            self.active = true;
        } else if self.hold > 0 {
            self.hold -= 1;
        } else {
            self.active = false;
        }

        if !self.active {
            Step::Silence
        } else if was_active {
            Step::Speech
        } else {
            Step::Onset
        }
    }
}

/// Encodes one frame and queues it, bumping the sequence number on success.
fn send_frame(encoder: &mut Encoder, sender: &VoiceSender, seq: &mut u32, frame: &[f32]) -> bool {
    if let Some(payload) = encoder.encode(frame) {
        sender.send(*seq, payload);
        *seq = seq.wrapping_add(1);
        true
    } else {
        false
    }
}

/// Whether to print voice diagnostics. Off unless `GOATS_VOICE_DEBUG=1`, so a
/// normal run stays quiet; the seams below are the ones worth watching when a
/// microphone or a peer is not doing what it should.
fn debug_on() -> bool {
    use std::sync::OnceLock;
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("GOATS_VOICE_DEBUG").is_ok_and(|value| value == "1"))
}

fn frame_rms(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let sum: f32 = frame.iter().map(|sample| sample * sample).sum();
    (sum / frame.len() as f32).sqrt()
}

/// Opens the default microphone and frames it into 20 ms mono blocks at 48 kHz.
/// Anything unsupported logs and returns nothing, so the game still runs.
fn open_input(raw: SyncSender<Vec<f32>>) -> Option<cpal::Stream> {
    use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};

    let device = cpal::default_host().default_input_device()?;
    let supported = device.default_input_config().ok()?;
    let channels = supported.channels() as usize;
    let rate = supported.sample_rate();
    let format = supported.sample_format();
    let config = supported.config();
    let name = device
        .description()
        .map_or_else(|_| "unnamed device".to_string(), |d| d.name().to_string());
    eprintln!("[voice] capture: {name}: {rate} Hz, {channels} ch, {format:?}");

    let built = match format {
        cpal::SampleFormat::F32 => build::<f32>(&device, config, channels, rate, raw, |s| s),
        cpal::SampleFormat::I16 => build::<i16>(&device, config, channels, rate, raw, |s| {
            s as f32 / 32_768.0
        }),
        cpal::SampleFormat::U16 => build::<u16>(&device, config, channels, rate, raw, |s| {
            (s as f32 - 32_768.0) / 32_768.0
        }),
        cpal::SampleFormat::F64 => build::<f64>(&device, config, channels, rate, raw, |s| s as f32),
        cpal::SampleFormat::I32 => build::<i32>(&device, config, channels, rate, raw, |s| {
            s as f32 / 2_147_483_648.0
        }),
        other => {
            eprintln!("[voice] unsupported input sample format {other:?}");
            return None;
        }
    };

    match built {
        Ok(stream) => match stream.play() {
            Ok(()) => Some(stream),
            Err(error) => {
                eprintln!("[voice] could not start capture: {error}");
                None
            }
        },
        Err(error) => {
            eprintln!("[voice] could not open the microphone: {error}");
            None
        }
    }
}

/// Builds the input stream for one sample type, downmixing to mono, resampling
/// to 48 kHz and cutting 20 ms frames.
fn build<T: cpal::SizedSample + Send + 'static>(
    device: &cpal::Device,
    config: cpal::StreamConfig,
    channels: usize,
    input_rate: u32,
    raw: SyncSender<Vec<f32>>,
    convert: impl Fn(T) -> f32 + Send + 'static,
) -> Result<cpal::Stream, cpal::Error> {
    use cpal::traits::DeviceTrait;

    let channels = channels.max(1);
    let mut mono: Vec<f32> = Vec::new();
    let mut pending: Vec<f32> = Vec::with_capacity(FRAME_SAMPLES * 2);
    let mut resampler = Resampler::new(input_rate, SAMPLE_RATE);

    device.build_input_stream::<T, _, _>(
        config,
        move |data: &[T], _| {
            mono.clear();
            for frame in data.chunks(channels) {
                let sum: f32 = frame.iter().map(|&sample| convert(sample)).sum();
                mono.push(sum / frame.len() as f32);
            }
            resampler.push(&mono, &mut pending);
            while pending.len() >= FRAME_SAMPLES {
                let frame: Vec<f32> = pending.drain(..FRAME_SAMPLES).collect();
                // The encoder thread is behind: drop rather than block the
                // audio callback, which must never wait.
                let _ = raw.try_send(frame);
            }
        },
        |error| eprintln!("[voice] capture error: {error}"),
        None,
    )
}

/// A linear resampler, for a microphone that does not run at 48 kHz (44.1 kHz is
/// the common case). Interpolating between the neighbouring samples is plenty
/// for voice.
struct Resampler {
    /// Input samples per output sample.
    step: f64,
    /// Position within the current input interval, in `[0, 1)`.
    pos: f64,
    prev: f32,
    primed: bool,
}

impl Resampler {
    fn new(input_rate: u32, output_rate: u32) -> Resampler {
        Resampler {
            step: input_rate as f64 / output_rate as f64,
            pos: 0.0,
            prev: 0.0,
            primed: false,
        }
    }

    fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
        if (self.step - 1.0).abs() < f64::EPSILON {
            out.extend_from_slice(input);
            return;
        }
        for &sample in input {
            if !self.primed {
                self.prev = sample;
                self.primed = true;
            }
            while self.pos < 1.0 {
                out.push(self.prev + (sample - self.prev) * self.pos as f32);
                self.pos += self.step;
            }
            self.pos -= 1.0;
            self.prev = sample;
        }
    }
}

/// The Opus encoder, wrapped so the unsafe FFI lives in one place.
struct Encoder {
    state: *mut libopus_sys::OpusEncoder,
}

impl Encoder {
    fn new() -> Option<Encoder> {
        let mut error = 0;
        // SAFETY: the call allocates and initialises its own state; `error` is a
        // valid out pointer and the state is destroyed in `Drop`.
        let state = unsafe {
            libopus_sys::opus_encoder_create(
                SAMPLE_RATE as i32,
                1,
                libopus_sys::OPUS_APPLICATION_VOIP as i32,
                &mut error,
            )
        };
        if state.is_null() || error != libopus_sys::OPUS_OK as i32 {
            return None;
        }
        // SAFETY: `state` is live and the variadic argument is the bitrate the
        // `OPUS_SET_BITRATE_REQUEST` control expects.
        unsafe {
            libopus_sys::opus_encoder_ctl(
                state,
                libopus_sys::OPUS_SET_BITRATE_REQUEST as i32,
                BITRATE,
            );
        }
        Some(Encoder { state })
    }

    fn encode(&mut self, frame: &[f32]) -> Option<Vec<u8>> {
        let mut out = vec![0u8; MAX_PACKET_BYTES];
        // SAFETY: `frame` holds exactly `FRAME_SAMPLES` floats and `out` is
        // `MAX_PACKET_BYTES` long, which is what the call is told.
        let written = unsafe {
            libopus_sys::opus_encode_float(
                self.state,
                frame.as_ptr(),
                FRAME_SAMPLES as i32,
                out.as_mut_ptr(),
                MAX_PACKET_BYTES as i32,
            )
        };
        if written < 0 {
            return None;
        }
        out.truncate(written as usize);
        Some(out)
    }
}

impl Drop for Encoder {
    fn drop(&mut self) {
        // SAFETY: `state` came from `opus_encoder_create` and is freed once.
        unsafe { libopus_sys::opus_encoder_destroy(self.state) };
    }
}

/// The Opus decoder, wrapped the same way.
struct Decoder {
    state: *mut libopus_sys::OpusDecoder,
}

impl Decoder {
    fn new() -> Option<Decoder> {
        let mut error = 0;
        // SAFETY: the call allocates and initialises its own state; `error` is a
        // valid out pointer and the state is destroyed in `Drop`.
        let state = unsafe { libopus_sys::opus_decoder_create(SAMPLE_RATE as i32, 1, &mut error) };
        if state.is_null() || error != libopus_sys::OPUS_OK as i32 {
            return None;
        }
        Some(Decoder { state })
    }

    fn decode(&mut self, payload: &[u8]) -> Option<Vec<f32>> {
        let mut out = vec![0f32; FRAME_SAMPLES];
        // SAFETY: `payload` is a live slice and `out` has room for one frame,
        // which is the frame size the call is given.
        let samples = unsafe {
            libopus_sys::opus_decode_float(
                self.state,
                payload.as_ptr(),
                payload.len() as i32,
                out.as_mut_ptr(),
                FRAME_SAMPLES as i32,
                0,
            )
        };
        if samples < 0 {
            return None;
        }
        out.truncate(samples as usize);
        Some(out)
    }
}

impl Drop for Decoder {
    fn drop(&mut self) {
        // SAFETY: `state` came from `opus_decoder_create` and is freed once.
        unsafe { libopus_sys::opus_decoder_destroy(self.state) };
    }
}

/// Starts a named thread, reporting a failure rather than panicking: voice is
/// not worth taking the game down for.
fn spawn(name: &str, body: impl FnOnce() + Send + 'static) {
    if let Err(error) = thread::Builder::new().name(name.to_string()).spawn(body) {
        eprintln!("[voice] could not start the {name} thread: {error}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_quiet_room_never_opens_the_gate() {
        let mut gate = Gate::new();
        for _ in 0..50 {
            assert_eq!(gate.push(0.0005), Step::Silence);
        }
    }

    #[test]
    fn speech_opens_the_gate_holds_the_tail_then_closes() {
        let mut gate = Gate::new();
        for _ in 0..20 {
            assert_eq!(gate.push(0.0005), Step::Silence);
        }
        // A loud frame opens it. 0.05 RMS is normal speech; the floor is around
        // 0.0005 by now, so the margin is wide.
        assert_eq!(gate.push(0.05), Step::Onset);
        // The hold keeps transmitting through the gaps between words...
        for _ in 0..VAD_HOLD_FRAMES {
            assert_eq!(gate.push(0.0005), Step::Speech);
        }
        // ...and then it closes.
        assert_eq!(gate.push(0.0005), Step::Silence);
    }

    #[test]
    fn the_gate_reports_a_new_onset_after_closing() {
        let mut gate = Gate::new();
        assert_eq!(gate.push(0.05), Step::Onset);
        for _ in 0..VAD_HOLD_FRAMES {
            gate.push(0.0005);
        }
        assert_eq!(gate.push(0.0005), Step::Silence);
        assert_eq!(gate.push(0.05), Step::Onset);
    }

    #[test]
    fn the_resampler_is_identity_at_48k() {
        let mut resampler = Resampler::new(SAMPLE_RATE, SAMPLE_RATE);
        let input: Vec<f32> = (0..100).map(|i| i as f32).collect();
        let mut out = Vec::new();
        resampler.push(&input, &mut out);
        assert_eq!(out, input);
    }

    #[test]
    fn the_resampler_keeps_the_rate() {
        // 4410 samples at 44.1 kHz are 100 ms, which is 4800 samples at 48 kHz.
        let mut resampler = Resampler::new(44_100, SAMPLE_RATE);
        let input: Vec<f32> = (0..4_410).map(|i| i as f32 / 4_410.0).collect();
        let mut out = Vec::new();
        resampler.push(&input, &mut out);
        assert!(
            (out.len() as i64 - 4_800).abs() <= 2,
            "expected about 4800 samples, got {}",
            out.len()
        );
    }

    #[test]
    fn rms_measures_a_frame() {
        assert_eq!(frame_rms(&[]), 0.0);
        let loud = frame_rms(&[1.0f32; FRAME_SAMPLES]);
        assert!((loud - 1.0).abs() < 1e-6, "got {loud}");
        assert!(frame_rms(&[0.0f32; FRAME_SAMPLES]) == 0.0);
    }

    #[test]
    fn a_frame_survives_the_opus_round_trip() {
        let mut encoder = Encoder::new().expect("encoder");
        let mut decoder = Decoder::new().expect("decoder");
        // A 440 Hz tone at a realistic level: quiet enough to be a real test of
        // the codec, loud enough that a silent result is a failure.
        let tone: Vec<f32> = (0..FRAME_SAMPLES)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / SAMPLE_RATE as f32).sin() * 0.3)
            .collect();

        let payload = encoder.encode(&tone).expect("encode");
        assert!(!payload.is_empty(), "the encoder produced no bytes");
        assert!(payload.len() <= MAX_PACKET_BYTES, "{} bytes", payload.len());

        let decoded = decoder.decode(&payload).expect("decode");
        assert_eq!(decoded.len(), FRAME_SAMPLES);
        let peak = decoded.iter().fold(0f32, |max, s| max.max(s.abs()));
        assert!(peak > 0.05, "the decoded frame is near-silent: peak {peak}");
    }
}
