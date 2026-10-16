//! The engine-free half of voice chat (M13b): the Opus coder, the speech gate and the
//! resampler.
//!
//! It names no audio *device*: `cpal` captures and raylib (or Godot) plays, and each
//! client hands its 48 kHz mono 20 ms frames through here. That is what makes the bytes on
//! the wire the same codec on every host -- which a raylib peer and a Godot peer need
//! before they can hear each other at all.
//!
//! `libopus_sys` with `bundled` compiles libopus from source, so there is no system codec
//! to install. A browser has no such build and no microphone to feed it, so the whole
//! crate is left out there (WASM.md section 5), the same way `crates/mods` leaves its file
//! watcher out.
#![cfg(not(target_arch = "wasm32"))]

/// Opus works at 48 kHz and the wire carries 20 ms frames, so a frame is 960 samples. The
/// playback stream, the detector and the pre-roll are all sized from these two.
pub const SAMPLE_RATE: u32 = 48_000;
pub const FRAME_SAMPLES: usize = 960;

/// Comfortable for voice, and it keeps the full-mesh uplink small.
const BITRATE: i32 = 24_000;

/// The largest packet the wire will accept; mirrors `proto::MAX_VOICE_BYTES`.
const MAX_PACKET_BYTES: usize = 512;

/// Frames kept for an utterance's onset, so its first syllable is whole: 40 ms.
pub const PREROLL_FRAMES: usize = 2;

// Voice activity detection. A fixed threshold either clips quiet talkers or fires on room
// noise, so the gate rides on an adaptive noise floor: it falls quickly onto silence and
// creeps up through it, and a frame is speech when it clears the floor by a margin. The
// hold keeps a word's tail from being cut and the pre-roll keeps its onset from being
// clipped.
const VAD_RATIO: f32 = 3.5; // ~11 dB above the floor
const VAD_FLOOR_MIN: f32 = 0.004; // absolute floor, so a silent room is silent
const VAD_FLOOR_START: f32 = 0.002;
const VAD_FLOOR_FALL: f32 = 0.25; // how fast the floor drops onto quiet input
const VAD_FLOOR_RISE: f32 = 0.002; // how fast it creeps up through noise
const VAD_HOLD_FRAMES: u32 = 15; // 300 ms of tail after the last speech frame

/// The RMS of one frame -- the number the gate is fed, and the one a diagnostic prints.
pub fn frame_rms(frame: &[f32]) -> f32 {
    if frame.is_empty() {
        return 0.0;
    }
    let sum: f32 = frame.iter().map(|sample| sample * sample).sum();
    (sum / frame.len() as f32).sqrt()
}

/// What one frame of audio turned out to be.
#[derive(Debug, PartialEq, Eq)]
pub enum Step {
    /// Below the gate: keep it only for the pre-roll.
    Silence,
    /// The first frame of an utterance; the pre-roll goes out first.
    Onset,
    /// Inside an utterance, including the hold after the last loud frame.
    Speech,
}

/// The speech gate: an adaptive noise floor plus a hold. Split from any thread so it can
/// be tested without a microphone.
pub struct Gate {
    /// The adaptive floor, in RMS.
    pub floor: f32,
    hold: u32,
    active: bool,
}

impl Gate {
    pub fn new() -> Gate {
        Gate {
            floor: VAD_FLOOR_START,
            hold: 0,
            active: false,
        }
    }

    /// Feeds one frame's RMS and reports what it is. The floor falls quickly onto quiet
    /// input and creeps up through noise, but never adapts while an utterance is in
    /// progress, so a loud voice cannot raise its own threshold.
    pub fn push(&mut self, rms: f32) -> Step {
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

/// A never-fed gate: the same as `Gate::new()`, and what clippy asks of a
/// public `new` that takes no arguments.
impl Default for Gate {
    fn default() -> Gate {
        Gate::new()
    }
}

/// A linear resampler, for a microphone that does not run at 48 kHz (44.1 kHz is the
/// common case). Interpolating between the neighbouring samples is plenty for voice.
pub struct Resampler {
    /// Input samples per output sample.
    step: f64,
    /// Position within the current input interval, in `[0, 1)`.
    pos: f64,
    prev: f32,
    primed: bool,
}

impl Resampler {
    pub fn new(input_rate: u32, output_rate: u32) -> Resampler {
        Resampler {
            step: input_rate as f64 / output_rate as f64,
            pos: 0.0,
            prev: 0.0,
            primed: false,
        }
    }

    pub fn push(&mut self, input: &[f32], out: &mut Vec<f32>) {
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
pub struct Encoder {
    state: *mut libopus_sys::OpusEncoder,
}

impl Encoder {
    pub fn new() -> Option<Encoder> {
        let mut error = 0;
        // SAFETY: the call allocates and initialises its own state; `error` is a valid
        // out pointer and the state is destroyed in `Drop`.
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

    pub fn encode(&mut self, frame: &[f32]) -> Option<Vec<u8>> {
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
pub struct Decoder {
    state: *mut libopus_sys::OpusDecoder,
}

impl Decoder {
    pub fn new() -> Option<Decoder> {
        let mut error = 0;
        // SAFETY: the call allocates and initialises its own state; `error` is a valid
        // out pointer and the state is destroyed in `Drop`.
        let state = unsafe { libopus_sys::opus_decoder_create(SAMPLE_RATE as i32, 1, &mut error) };
        if state.is_null() || error != libopus_sys::OPUS_OK as i32 {
            return None;
        }
        Some(Decoder { state })
    }

    pub fn decode(&mut self, payload: &[u8]) -> Option<Vec<f32>> {
        let mut out = vec![0f32; FRAME_SAMPLES];
        // SAFETY: `payload` is a live slice and `out` has room for one frame, which is
        // the frame size the call is given.
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
        // A 440 Hz tone at a realistic level: quiet enough to be a real test of the
        // codec, loud enough that a silent result is a failure.
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
