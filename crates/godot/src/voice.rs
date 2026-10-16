//! Voice chat (M13b): the codec half of the bridge.
//!
//! The game's audio is Godot's. `audio.gd` plays the ten slots, and the two *devices* stay
//! in GDScript: an `AudioEffectCapture` reads the microphone and an `AudioStreamGenerator`
//! plays the mix (this session's "(a)" -- Godot owns both sound cards). What Godot cannot do
//! is the *coding*: the wire carries Opus frames, and two peers must agree on those bytes
//! before they can hear each other at all. So the codec, the speech gate and the resampler
//! are `crates/voice`'s -- the same crate `crates/goats`'s `audio.rs` uses, so the raylib
//! client and this one put byte-identical frames on the wire.
//!
//! This module is the glue. It resamples and frames whatever the scene captured, decides
//! what is speech, hands the packets to the session the bridge already owns, and mixes what
//! comes back for the scene to play.
//!
//! **The bytes never cross GDScript.** A captured frame is encoded here and queued straight
//! through the bridge's own intent channel (`Command::Voice`, published in `net.rs`'s run
//! loop); a delivered `VoiceFrame` is decoded here too, out of the queue the runtime thread
//! filled (`net::drain_voice`). The scene only ever hands over samples and takes them back,
//! which is why the `#[func]`s below speak floats rather than packets.
//!
//! There is no push-to-talk key: a frame is speech when it clears an adaptive noise floor by
//! a margin, and a hold plus a small pre-roll keep word tails and onsets intact (`voice`'s
//! `Gate`, documented there). That gate is fed the same numbers whether the samples came
//! from `cpal` in the raylib client or from Godot's capture bus here -- the samples are
//! always 48 kHz mono 20 ms frames by the time the gate sees them -- so the two hosts decide
//! when to speak alike.

use std::collections::VecDeque;
use std::sync::OnceLock;

use voice::{
    Decoder, Encoder, FRAME_SAMPLES, Gate, PREROLL_FRAMES, Resampler, SAMPLE_RATE, Step, frame_rms,
};

/// The most decoded audio held before the oldest is dropped, so a scene that stops draining
/// the mix cannot grow the queue without bound. Half a second is far past useful for voice
/// (`crates/goats/src/audio.rs`'s own bound).
const VOICE_QUEUE_MAX_FRAMES: usize = SAMPLE_RATE as usize / 2;

/// The codec half's state, one per [`NetBridge`] node.
///
/// It is a plain struct rather than a Godot class because it has no place in the tree and
/// nothing to draw: the bridge owns the wire, so the bridge owns this, and the `#[func]`s at
/// the bottom of this file are the whole of what GDScript sees.
pub(crate) struct Voice {
    /// The speech gate. `Silence` frames are held for the pre-roll and dropped, `Onset`
    /// flushes what was held, `Speech` goes straight out (`voice`'s `Gate`).
    gate: Gate,
    /// The Opus coder, created when the node is. `None` only if libopus refused to build a
    /// state, in which case voice is silent rather than the game being taken down.
    encoder: Option<Encoder>,
    decoder: Option<Decoder>,
    /// The resampler and the rate it was built for, made on the first block: the scene's bus
    /// rate is a constant, but a gate may hand it another, and a resampler is per-rate.
    resampler: Option<(u32, Resampler)>,
    /// 48 kHz samples not yet a whole 20 ms frame.
    pending: Vec<f32>,
    /// The last few silence frames, for an utterance's onset (`PREROLL_FRAMES`).
    preroll: VecDeque<Vec<f32>>,
    /// The sequence number the encoder is on. It rides the wire beside the payload so a
    /// receiver can order frames that arrive out of order or late.
    seq: u32,
    /// Decoded audio waiting for the scene to play it, at 48 kHz mono.
    mix: VecDeque<f32>,
    /// The master gain the scene owns, applied as the mix is drained. `1.0` is unmuted.
    gain: f32,
    /// Counters, for `voice_state` and a gate's evidence.
    sent: u64,
    decoded: u64,
}

impl Voice {
    /// A codec ready to speak, with the coder built up front so a failure is one line at
    /// boot rather than a surprise on the first word.
    pub(crate) fn new() -> Voice {
        let encoder = Encoder::new();
        let decoder = Decoder::new();
        if encoder.is_none() || decoder.is_none() {
            eprintln!("[voice] could not create the Opus coder; voice will be silent");
        }
        Voice {
            gate: Gate::new(),
            encoder,
            decoder,
            resampler: None,
            pending: Vec::new(),
            preroll: VecDeque::new(),
            seq: 0,
            mix: VecDeque::new(),
            gain: 1.0,
            sent: 0,
            decoded: 0,
        }
    }

    /// Resample `samples` (mono, at `rate`) to 48 kHz, cut whole 20 ms frames off the front,
    /// and return every frame the gate decided to send, encoded. The caller queues them.
    ///
    /// This is `crates/goats/src/audio.rs`'s `build` and `encode_loop` folded together: a
    /// frame at a time is the only shape that matters, and the two steps are joined here
    /// because both live on the frame thread rather than on a capture callback.
    pub(crate) fn feed(&mut self, samples: &[f32], rate: u32) -> Vec<(u32, Vec<u8>)> {
        let mut out: Vec<(u32, Vec<u8>)> = Vec::new();
        if samples.is_empty() || rate == 0 {
            return out;
        }
        // A resampler is built for one input rate, so a changed rate gets a fresh one. The
        // identity case (48 kHz in) is `Resampler`'s own fast path.
        let stale = match self.resampler {
            Some((known, _)) => known != rate,
            None => true,
        };
        if stale {
            self.resampler = Some((rate, Resampler::new(rate, SAMPLE_RATE)));
        }
        if let Some((_, resampler)) = &mut self.resampler {
            resampler.push(samples, &mut self.pending);
        }
        while self.pending.len() >= FRAME_SAMPLES {
            let frame: Vec<f32> = self.pending.drain(..FRAME_SAMPLES).collect();
            self.step(frame, &mut out);
        }
        out
    }

    /// One 20 ms frame through the gate: hold and drop it, flush the pre-roll and send it, or
    /// send it. `crates/goats/src/audio.rs`'s `encode_loop` body, without the diagnostics.
    fn step(&mut self, frame: Vec<f32>, out: &mut Vec<(u32, Vec<u8>)>) {
        let rms = frame_rms(&frame);
        match self.gate.push(rms) {
            Step::Silence => {
                if self.preroll.len() == PREROLL_FRAMES {
                    self.preroll.pop_front();
                }
                self.preroll.push_back(frame);
            }
            Step::Onset => {
                if debug_on() {
                    eprintln!("[voice] speech detected (floor {:.4})", self.gate.floor);
                }
                // Speech just started: flush what was buffered so the first syllable is whole.
                let held: Vec<Vec<f32>> = self.preroll.drain(..).collect();
                for buffered in held {
                    self.encode(buffered, out);
                }
                self.encode(frame, out);
            }
            Step::Speech => self.encode(frame, out),
        }
    }

    /// Encode one frame and record it, bumping the sequence number on success.
    fn encode(&mut self, frame: Vec<f32>, out: &mut Vec<(u32, Vec<u8>)>) {
        let Some(encoder) = self.encoder.as_mut() else {
            return;
        };
        if let Some(payload) = encoder.encode(&frame) {
            out.push((self.seq, payload));
            self.seq = self.seq.wrapping_add(1);
            self.sent += 1;
            if debug_on() && self.sent.is_multiple_of(50) {
                eprintln!(
                    "[voice] sent {} frames ({:.1} s)",
                    self.sent,
                    self.sent as f32 * 0.02
                );
            }
        }
    }

    /// Decode one delivered frame and append it to the mix, dropping the oldest if a stalled
    /// scene has let it grow past the bound.
    pub(crate) fn receive(&mut self, from: &str, seq: u32, payload: &[u8]) {
        let Some(decoder) = self.decoder.as_mut() else {
            return;
        };
        let Some(samples) = decoder.decode(payload) else {
            if debug_on() {
                eprintln!("[voice] undecodable frame from {from} (seq {seq})");
            }
            return;
        };
        self.decoded += 1;
        self.mix.extend(samples);
        while self.mix.len() > VOICE_QUEUE_MAX_FRAMES {
            self.mix.pop_front();
        }
    }

    /// Up to `max` samples of the mix, at the master gain, removed from the queue. The scene
    /// pushes them into its generator, so it asks for exactly the room it has.
    pub(crate) fn drain(&mut self, max: usize) -> Vec<f32> {
        let take = max.min(self.mix.len());
        let mut out = Vec::with_capacity(take);
        for _ in 0..take {
            out.push(self.mix.pop_front().unwrap_or(0.0) * self.gain);
        }
        out
    }

    /// The scene's master mute, as a 0..1 gain on everything a peer sends.
    pub(crate) fn set_gain(&mut self, gain: f32) {
        self.gain = gain.clamp(0.0, 1.0);
    }

    /// `(sent, decoded, buffered, gain)`, for `voice_state`.
    pub(crate) fn state(&self) -> (u64, u64, usize, f32) {
        (self.sent, self.decoded, self.mix.len(), self.gain)
    }
}

/// Whether to print voice diagnostics. Off unless `GOATS_VOICE_DEBUG=1`, the same knob and
/// the same default as the raylib client's audio module, so a normal run stays quiet.
fn debug_on() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| std::env::var("GOATS_VOICE_DEBUG").is_ok_and(|value| value == "1"))
}
