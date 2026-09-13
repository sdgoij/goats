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

use std::collections::VecDeque;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::mpsc::{self, Receiver, SyncSender};
use std::sync::{Arc, Mutex, OnceLock};
use std::thread;
use std::time::Duration;

use crate::net::{Net, VoiceIn, VoiceSender};

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

/// Decoded voice is mixed into one queue that a single raylib stream drains
/// through its callback, and playback starts once this much is buffered, so the
/// stream does not open on an empty queue. Four packets is ~80 ms.
const VOICE_CUSHION_FRAMES: usize = FRAME_SAMPLES * 4;

/// The most audio held before the oldest is dropped, so a stalled mixer cannot
/// grow the queue without bound. Half a second is far past useful for voice.
const VOICE_QUEUE_MAX_FRAMES: usize = SAMPLE_RATE as usize / 2;

/// The mix every decoded packet is appended to. It is a `OnceLock` rather than a
/// field because raylib's stream callback takes no user-data pointer, so a
/// plain `extern "C"` function has to be able to reach it.
static MIX: OnceLock<Arc<Mutex<VecDeque<f32>>>> = OnceLock::new();

/// The master gain, as `f32` bits, read by the callback so a mute is heard at
/// once instead of at the next packet. `1.0` is `0x3F80_0000`.
static MIX_GAIN: AtomicU32 = AtomicU32::new(0x3F80_0000);

/// Cleared on shutdown, so a callback racing the stream's unload stays silent.
static MIX_ON: AtomicBool = AtomicBool::new(true);

/// raylib's stream callback: fill `frames` mono `f32` samples from the mix, with
/// silence for any it cannot supply. raylib asks for exactly what the mixer
/// needs, so there is no half-buffer to size and nothing to zero-fill by hand.
///
/// # Safety
/// raylib calls this with a writable buffer of `frames` mono `f32` samples,
/// which is the format the stream is created with.
unsafe extern "C" fn mix_callback(data: *mut core::ffi::c_void, frames: core::ffi::c_uint) {
    let frames = frames as usize;
    if data.is_null() || frames == 0 {
        return;
    }
    // SAFETY: the contract above.
    let out = unsafe { std::slice::from_raw_parts_mut(data.cast::<f32>(), frames) };
    out.fill(0.0);
    if !MIX_ON.load(Ordering::Relaxed) {
        return;
    }
    let Some(mix) = MIX.get() else {
        return;
    };
    // raylib's own mixer locks a mutex per callback, so this is no worse than
    // its playback path; a poisoned lock just means one buffer of silence.
    let Ok(mut queue) = mix.lock() else {
        return;
    };
    let gain = f32::from_bits(MIX_GAIN.load(Ordering::Relaxed));
    drain_into(&mut queue, out, gain);
}

/// Fills `out` from the mix at `gain`, with silence where the queue runs dry.
/// Split from the callback so the mixing is testable without a device.
fn drain_into(queue: &mut VecDeque<f32>, out: &mut [f32], gain: f32) {
    out.fill(0.0);
    if gain <= 0.0 {
        return;
    }
    let take = out.len().min(queue.len());
    for slot in &mut out[..take] {
        *slot = queue.pop_front().unwrap_or(0.0) * gain;
    }
}

/// The frame loop's handle on voice: decoded audio waiting for the mixer queue,
/// the one stream every speaker goes through, and the master gain the scene owns.
pub struct Voice {
    decoded: Receiver<(String, Vec<f32>)>,
    mix: Arc<Mutex<VecDeque<f32>>>,
    /// Created on the first packet, once the scene has opened the audio device.
    stream: Option<raylib_sys::AudioStream>,
    /// Whether playback has started (the cushion filled).
    playing: bool,
    running: Arc<AtomicBool>,
}

impl Voice {
    /// Starts capture, coding and decoding. A host without a microphone still
    /// gets incoming audio: capture simply gives up, with a line on stderr.
    pub fn start(net: &mut Net) -> Voice {
        let running = Arc::new(AtomicBool::new(true));
        let (pcm_tx, pcm_rx) = mpsc::channel();

        // The mix has to exist before any callback can run, and the gadget the
        // callback reads have no other owner.
        let mix = MIX
            .get_or_init(|| Arc::new(Mutex::new(VecDeque::new())))
            .clone();
        MIX_ON.store(true, Ordering::Relaxed);
        MIX_GAIN.store(0x3F80_0000, Ordering::Relaxed); // 1.0

        // In loopback the encoded frames come back to this same client instead of
        // going out over the network and returning, so one person on one machine
        // can hear the whole chain: capture, the gate, Opus, decode, the mix.
        let loopback = loopback_enabled();
        if loopback {
            eprintln!("[voice] loopback: the microphone plays back locally");
        } else if debug_on() {
            // Said out loud so "am I hearing myself from the network or from
            // loopback?" is never a guess.
            eprintln!("[voice] loopback: off");
        }
        let (echo_tx, echo_rx) = mpsc::channel::<VoiceIn>();
        let sender = Outgoing {
            net: net.voice_sender(),
            echo: loopback.then_some(echo_tx),
        };

        // Decoding: one thread, one decoder, one frame at a time. The PCM goes
        // on the std channel above and reaches raylib from the frame loop.
        let incoming = if loopback {
            Some(Incoming::Loop(echo_rx))
        } else {
            net.take_voice_receiver().map(Incoming::Net)
        };
        if let Some(mut incoming) = incoming {
            let pcm = pcm_tx.clone();
            spawn("voice-out", move || {
                let Some(mut decoder) = Decoder::new() else {
                    eprintln!("[voice] could not create an Opus decoder");
                    return;
                };
                let mut played: u64 = 0;
                while let Some((from, seq, payload)) = incoming.next() {
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
            mix,
            stream: None,
            playing: false,
            running,
        }
    }

    /// The scene's master mute, as a 0..1 gain on everything a peer sends.
    pub fn set_gain(&self, gain: f32) {
        MIX_GAIN.store(gain.clamp(0.0, 1.0).to_bits(), Ordering::Relaxed);
    }

    /// Mixes decoded audio into the queue the stream drains. Called once a frame;
    /// every raylib call stays on this thread, while the callback that pulls from
    /// the queue runs on raylib's audio thread.
    pub fn pump(&mut self) {
        while let Ok((_from, samples)) = self.decoded.try_recv() {
            if self.stream.is_none() {
                // Created on the first packet, by which time the scene has opened
                // the audio device. If it has not, the next packet retries rather
                // than caching an unusable stream.
                // SAFETY: a fresh stream from raylib, checked before use.
                let stream = unsafe { raylib_sys::LoadAudioStream(SAMPLE_RATE, 32, 1) };
                if !unsafe { raylib_sys::IsAudioStreamValid(stream) } {
                    eprintln!("[voice] no playback stream yet (audio device not ready?)");
                    return;
                }
                // SAFETY: a live stream owned by this struct from here on, and the
                // callback matches the mono f32 format it is created with.
                unsafe { raylib_sys::SetAudioStreamCallback(stream, Some(mix_callback)) };
                if debug_on() {
                    eprintln!("[voice] playback stream ready");
                }
                self.stream = Some(stream);
            }

            let Ok(mut queue) = self.mix.lock() else {
                return;
            };
            queue.extend(samples);
            while queue.len() > VOICE_QUEUE_MAX_FRAMES {
                queue.pop_front();
            }
            let ready = queue.len() >= VOICE_CUSHION_FRAMES;
            drop(queue);

            if ready && !self.playing {
                self.playing = true;
                if let Some(stream) = self.stream {
                    // SAFETY: the stream is live and owned by this struct.
                    unsafe { raylib_sys::PlayAudioStream(stream) };
                }
                if debug_on() {
                    eprintln!("[voice] playback started");
                }
            }
        }
    }
}

impl Drop for Voice {
    fn drop(&mut self) {
        self.running.store(false, Ordering::Relaxed);
        MIX_ON.store(false, Ordering::Relaxed);
        if let Some(stream) = self.stream.take() {
            // SAFETY: the stream came from `LoadAudioStream` and is freed once.
            unsafe { raylib_sys::UnloadAudioStream(stream) };
        }
    }
}

/// Where one encoded frame goes: out to the session, and (in loopback) back to
/// this client's own decoder so the whole chain can be heard on one machine.
struct Outgoing {
    net: VoiceSender,
    echo: Option<mpsc::Sender<VoiceIn>>,
}

impl Outgoing {
    fn send(&self, seq: u32, payload: Vec<u8>) {
        if let Some(echo) = &self.echo {
            // Named as if it came from a peer, which is what the scene would show.
            let _ = echo.send(("loopback".to_string(), seq, payload.clone()));
        }
        self.net.send(seq, payload);
    }
}

/// Where the decoder's frames come from: the session's relay, or the loopback
/// echo of this client's own encoder. Two channel types, one iterator.
enum Incoming {
    Net(tokio::sync::mpsc::Receiver<VoiceIn>),
    Loop(mpsc::Receiver<VoiceIn>),
}

impl Incoming {
    fn next(&mut self) -> Option<VoiceIn> {
        match self {
            // `blocking_recv` is called from the decode thread, not a runtime one.
            Incoming::Net(receiver) => receiver.blocking_recv(),
            Incoming::Loop(receiver) => receiver.recv().ok(),
        }
    }
}

/// The encoder thread: gate on speech, then encode. A frame is spoken if it
/// clears the adapted floor, and a hold keeps it going through short gaps.
fn encode_loop(raw: Receiver<Vec<f32>>, sender: Outgoing) {
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
fn send_frame(encoder: &mut Encoder, sender: &Outgoing, seq: &mut u32, frame: &[f32]) -> bool {
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

/// Whether the microphone should play back locally instead of over a session.
/// `GOATS_VOICE_LOOPBACK=1`, so one person on one machine can hear the whole
/// chain without a peer; only unset, empty and `0` mean off.
fn loopback_enabled() -> bool {
    std::env::var("GOATS_VOICE_LOOPBACK").is_ok_and(|value| !value.is_empty() && value != "0")
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

    #[test]
    fn the_mix_fills_the_buffer_and_silences_the_rest() {
        let mut queue: VecDeque<f32> = (0..4).map(|i| i as f32 / 4.0).collect();
        let mut out = [1.0f32; 6];
        drain_into(&mut queue, &mut out, 1.0);
        assert_eq!(out[..4], [0.0, 0.25, 0.5, 0.75]);
        assert_eq!(out[4..], [0.0, 0.0]);
        assert!(queue.is_empty());
    }

    #[test]
    fn the_mix_applies_the_gain_and_respects_a_mute() {
        let mut queue: VecDeque<f32> = VecDeque::from([1.0, 1.0]);
        let mut out = [0.0f32; 2];
        drain_into(&mut queue, &mut out, 0.5);
        assert_eq!(out, [0.5, 0.5]);
        assert!(queue.is_empty());

        // Muted: silence, and the queued audio is left for the unmute.
        let mut queue: VecDeque<f32> = VecDeque::from([1.0, 1.0]);
        let mut out = [9.0f32; 2];
        drain_into(&mut queue, &mut out, 0.0);
        assert_eq!(out, [0.0, 0.0]);
        assert_eq!(queue.len(), 2);
    }

    #[test]
    fn the_mix_survives_an_empty_queue() {
        let mut queue: VecDeque<f32> = VecDeque::new();
        let mut out = [1.0f32; 3];
        drain_into(&mut queue, &mut out, 1.0);
        assert_eq!(out, [0.0, 0.0, 0.0]);
    }

    /// The playback wiring, against the real device. raylib's audio device needs
    /// no window, so this runs headless, and it uses the same stream, callback and
    /// queue the game does. It is `#[ignore]`d because a CI runner has no sound
    /// card; run it where there is one, and you should hear a quiet 440 Hz tone:
    ///
    /// ```text
    /// cargo test -p goats --release -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "needs a sound card"]
    fn the_device_pulls_frames_from_the_mix() {
        // SAFETY: raylib audio is independent of a window; nothing else is set up.
        unsafe { raylib_sys::InitAudioDevice() };
        if !unsafe { raylib_sys::IsAudioDeviceReady() } {
            eprintln!("[voice] no audio device here; skipping the device check");
            return;
        }

        let mix = MIX
            .get_or_init(|| Arc::new(Mutex::new(VecDeque::new())))
            .clone();
        MIX_ON.store(true, Ordering::Relaxed);
        MIX_GAIN.store(0x3F80_0000, Ordering::Relaxed); // 1.0

        // One second of a quiet 440 Hz tone.
        let tone: Vec<f32> = (0..SAMPLE_RATE as usize)
            .map(|i| (i as f32 * 440.0 * std::f32::consts::TAU / SAMPLE_RATE as f32).sin() * 0.1)
            .collect();
        let total = tone.len();
        mix.lock().expect("mix").extend(tone);

        // SAFETY: a fresh mono f32 stream, with the production callback.
        let stream = unsafe { raylib_sys::LoadAudioStream(SAMPLE_RATE, 32, 1) };
        assert!(
            unsafe { raylib_sys::IsAudioStreamValid(stream) },
            "the stream could not be created"
        );
        unsafe { raylib_sys::SetAudioStreamCallback(stream, Some(mix_callback)) };
        unsafe { raylib_sys::PlayAudioStream(stream) };

        // Half a second of device time; the mixer should have taken that much.
        thread::sleep(Duration::from_millis(500));
        let left = mix.lock().expect("mix").len();
        unsafe { raylib_sys::UnloadAudioStream(stream) };
        unsafe { raylib_sys::CloseAudioDevice() };

        let pulled = total - left;
        eprintln!("[voice] device pulled {pulled} frames in 500 ms");
        assert!(
            (16_000..28_000).contains(&pulled),
            "expected about 24000 frames in 500 ms, got {pulled} (0 means the mixer \
             never called the callback)"
        );
    }

    /// The other half of the chain: does the microphone actually deliver samples?
    /// A muted device, a Windows privacy block or another application holding the
    /// microphone all show up as digital silence, which the gate then correctly
    /// refuses to send -- and which reads as "voice does not work" on the far end.
    /// `#[ignore]`d because a machine may have no microphone; run it where there is
    /// one and make a little noise:
    ///
    /// ```text
    /// cargo test -p goats --release -- --ignored --nocapture
    /// ```
    #[test]
    #[ignore = "needs a microphone"]
    fn the_microphone_delivers_audio() {
        let (tx, rx) = mpsc::sync_channel::<Vec<f32>>(CAPTURE_BACKLOG);
        let Some(stream) = open_input(tx) else {
            eprintln!("[voice] no input device here; skipping the microphone check");
            return;
        };

        let mut peak: f32 = 0.0;
        let mut frames = 0usize;
        let mut samples = 0usize;
        let mut nonzero = 0usize;
        let deadline = std::time::Instant::now() + Duration::from_millis(1500);
        while std::time::Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(200)) {
                Ok(frame) => {
                    frames += 1;
                    for sample in frame {
                        samples += 1;
                        if sample != 0.0 {
                            nonzero += 1;
                        }
                        peak = peak.max(sample.abs());
                    }
                }
                Err(_) => break,
            }
        }
        drop(stream);

        eprintln!(
            "[voice] microphone delivered {frames} frames ({samples} samples), \
             {nonzero} non-zero, peak {peak:.6}"
        );
        assert!(frames > 0, "the capture callback never ran");
        assert!(
            peak > 0.0,
            "the microphone delivered {samples} samples of digital silence: it is \
             muted, blocked by the OS microphone privacy setting (Windows: 'Let \
             desktop apps access your microphone'), or held by another application"
        );
    }
}
