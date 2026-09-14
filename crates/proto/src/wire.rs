//! The datagram channel's packed form.
//!
//! [`Datagram`] is the vocabulary the session speaks; this is how it travels.
//! Every datagram is binary, and the entity fields are quantized, because the
//! world snapshot goes out ten times a second inside a 1200-byte budget and voice
//! fifty. JSON spent most of that budget on key names and decimal digits: one bot
//! was 86 bytes of text and is ~10 here.
//!
//! Three properties matter more than the size:
//!
//! * **A quantized field saturates, it does not wrap.** A hostile or broken value
//!   lands on the edge of the range rather than on an unrelated number somewhere
//!   else in the field.
//! * **Everything decoded is finite.** The wire cannot carry a NaN, which is why
//!   the checks on the receiving side are about the *bridge* (where the scene
//!   hands Rust JSON) rather than about the wire.
//! * **The encoding is idempotent.** A relay decodes a peer's frame and
//!   re-encodes it with the server's name stamped on, so `decode` then `encode`
//!   has to come back to the same bytes or a value would drift every hop.
//!
//! The frames on the control channel stay JSON; see [`crate::encode_frame`].

use serde::{Deserialize, Serialize};

use crate::{
    BotState, Datagram, EatenCell, Error, Gait, PeerFrame, PeerState, Streams, VoiceFrame,
    WeatherState, WorldState,
};

// ---- the quantization grid -------------------------------------------------

/// Positions land on 1 cm, so an `i16` spans ±327.67 m -- well past the field,
/// and finer than the simulation reads a position back at.
const PER_METRE: f32 = 100.0;
/// A yaw lands on 1/10000 of a turn, which is 0.036 degrees. Signed, so it spans
/// any angle `atan2` can produce.
const PER_TURN: f32 = 10_000.0;
/// Speed lands on 1/256 m/s. Signed, because a gait can back up.
const PER_SPEED: f32 = 256.0;
/// The animation clock is 255 steps through a clip.
const PHASE_STEPS: f32 = 255.0;
/// A regrow timer lands on a quarter second. `u16` then spans four and a half
/// hours, and the client counts its own copy down between snapshots anyway.
const PER_SECOND: f32 = 4.0;

/// Rounds `value * scale` and clamps it into `min..=max`.
///
/// Saturation is the point of doing this by hand: `as` on a float that is out of
/// range, or on a NaN, produces an unrelated number, and for a position that
/// means a peer teleporting across the field.
fn quantize(value: f32, scale: f32, min: i64, max: i64) -> i64 {
    let scaled = f64::from(value) * f64::from(scale);
    if scaled.is_nan() {
        return 0;
    }
    scaled.round().clamp(min as f64, max as f64) as i64
}

/// The inverse: `units` back to the value it stands for.
fn dequantize(units: i64, scale: f32) -> f32 {
    units as f32 / scale
}

fn centimetres(metres: f32) -> i16 {
    quantize(metres, PER_METRE, i64::from(i16::MIN), i64::from(i16::MAX)) as i16
}

fn metres(centimetres: i16) -> f32 {
    dequantize(i64::from(centimetres), PER_METRE)
}

fn turns(yaw: f32) -> i16 {
    quantize(yaw, PER_TURN, i64::from(i16::MIN), i64::from(i16::MAX)) as i16
}

fn yaw_of(units: i16) -> f32 {
    dequantize(i64::from(units), PER_TURN)
}

fn speed_units(speed: f32) -> i16 {
    quantize(speed, PER_SPEED, i64::from(i16::MIN), i64::from(i16::MAX)) as i16
}

fn speed_of(units: i16) -> f32 {
    dequantize(i64::from(units), PER_SPEED)
}

fn phase_steps(phase: f32) -> u8 {
    quantize(phase, PHASE_STEPS, 0, i64::from(u8::MAX)) as u8
}

fn phase_of(steps: u8) -> f32 {
    dequantize(i64::from(steps), PHASE_STEPS)
}

fn quarter_seconds(seconds: f32) -> u16 {
    quantize(seconds, PER_SECOND, 0, i64::from(u16::MAX)) as u16
}

fn seconds_of(units: u16) -> f32 {
    dequantize(i64::from(units), PER_SECOND)
}

// ---- the wire types --------------------------------------------------------

/// One datagram, packed. The variant tag is postcard's: one byte, where
/// `#[serde(tag = "kind")]` cost twenty.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) enum WireDatagram {
    Peer(WirePeer),
    World(WireWorld),
    Voice(WireVoice),
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WirePeer {
    name: String,
    x: i16,
    z: i16,
    yaw: i16,
    phase: u8,
    speed: i16,
    gait: Gait,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WireWorld {
    bots: Vec<WireBot>,
    /// The sky and the streams carry no entity count, so they travel as they are
    /// and postcard's `f32`/`u32` fields are already fixed-width.
    weather: WeatherState,
    streams: Streams,
    /// `None` when the snapshot could not carry the meadow -- see
    /// [`WorldState::eaten`].
    eaten: Option<Vec<WireEaten>>,
    /// A world mod's published state, as the JSON the scene handed over. The
    /// transport has no schema for it (see [`WorldState::mods`]), so it travels
    /// as opaque bytes: it costs exactly its JSON length, and a `Vec<u8>` under
    /// postcard is a length and the bytes rather than an array of numbers.
    mods: Option<Vec<u8>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WireBot {
    index: u16,
    x: i16,
    z: i16,
    yaw: i16,
    phase: u8,
    gait: Gait,
    variant: i32,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WireEaten {
    key: i64,
    left: u16,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub(crate) struct WireVoice {
    from: String,
    seq: u32,
    payload: Vec<u8>,
}

// ---- packing ---------------------------------------------------------------

impl WireDatagram {
    /// Packs a datagram for the wire. The one fallible part is a world mod's
    /// published state, which has to become JSON bytes.
    pub(crate) fn pack(datagram: &Datagram) -> Result<WireDatagram, Error> {
        Ok(match datagram {
            Datagram::Peer(frame) => WireDatagram::Peer(WirePeer::pack(frame)),
            Datagram::World(world) => WireDatagram::World(WireWorld::pack(world)?),
            Datagram::Voice(frame) => WireDatagram::Voice(WireVoice {
                from: frame.from.clone(),
                seq: frame.seq,
                payload: frame.payload.clone(),
            }),
        })
    }

    pub(crate) fn unpack(self) -> Result<Datagram, Error> {
        Ok(match self {
            WireDatagram::Peer(peer) => Datagram::Peer(peer.unpack()),
            WireDatagram::World(world) => Datagram::World(world.unpack()?),
            WireDatagram::Voice(voice) => Datagram::Voice(VoiceFrame {
                from: voice.from,
                seq: voice.seq,
                payload: voice.payload,
            }),
        })
    }
}

impl WirePeer {
    fn pack(frame: &PeerFrame) -> WirePeer {
        WirePeer {
            name: frame.name.clone(),
            x: centimetres(frame.state.x),
            z: centimetres(frame.state.z),
            yaw: turns(frame.state.yaw),
            phase: phase_steps(frame.state.phase),
            speed: speed_units(frame.state.speed),
            gait: frame.state.gait,
        }
    }

    fn unpack(self) -> PeerFrame {
        PeerFrame {
            name: self.name,
            state: PeerState {
                x: metres(self.x),
                z: metres(self.z),
                yaw: yaw_of(self.yaw),
                phase: phase_of(self.phase),
                speed: speed_of(self.speed),
                gait: self.gait,
            },
        }
    }
}

impl WireWorld {
    fn pack(world: &WorldState) -> Result<WireWorld, Error> {
        Ok(WireWorld {
            bots: world.bots.iter().map(WireBot::pack).collect(),
            weather: world.weather.clone(),
            streams: world.streams,
            eaten: world
                .eaten
                .as_deref()
                .map(|cells| cells.iter().map(WireEaten::pack).collect()),
            mods: match &world.mods {
                // The vocabulary says "not sent" with `null`; the wire says it by
                // leaving the bytes out.
                serde_json::Value::Null => None,
                value => Some(
                    serde_json::to_vec(value).map_err(|error| Error::Encode(error.to_string()))?,
                ),
            },
        })
    }

    fn unpack(self) -> Result<WorldState, Error> {
        Ok(WorldState {
            bots: self.bots.into_iter().map(WireBot::unpack).collect(),
            weather: self.weather,
            streams: self.streams,
            eaten: self
                .eaten
                .map(|cells| cells.into_iter().map(WireEaten::unpack).collect()),
            mods: match self.mods {
                None => serde_json::Value::Null,
                Some(bytes) => serde_json::from_slice(&bytes).map_err(|error| {
                    Error::Decode(format!("world mod state is not JSON: {error}"))
                })?,
            },
        })
    }
}

impl WireBot {
    fn pack(bot: &BotState) -> WireBot {
        WireBot {
            index: bot.index,
            x: centimetres(bot.x),
            z: centimetres(bot.z),
            yaw: turns(bot.yaw),
            phase: phase_steps(bot.phase),
            gait: bot.gait,
            variant: bot.variant,
        }
    }

    fn unpack(self) -> BotState {
        BotState {
            index: self.index,
            x: metres(self.x),
            z: metres(self.z),
            yaw: yaw_of(self.yaw),
            phase: phase_of(self.phase),
            gait: self.gait,
            variant: self.variant,
        }
    }
}

impl WireEaten {
    fn pack(cell: &EatenCell) -> WireEaten {
        WireEaten {
            key: cell.key,
            left: quarter_seconds(cell.left),
        }
    }

    fn unpack(self) -> EatenCell {
        EatenCell {
            key: self.key,
            left: seconds_of(self.left),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One quantum of each field, for the tolerance the round trips use.
    const CENTIMETRE: f32 = 1.0 / PER_METRE;
    const TURN: f32 = 1.0 / PER_TURN;
    const PHASE: f32 = 1.0 / PHASE_STEPS;

    fn a_bot() -> BotState {
        BotState {
            index: 3,
            x: 12.34,
            z: -7.65,
            yaw: 1.2345,
            phase: 0.4,
            gait: Gait::Trot,
            variant: 2,
        }
    }

    fn a_peer() -> PeerFrame {
        PeerFrame {
            name: "alice".to_string(),
            state: PeerState {
                x: -3.21,
                z: 0.99,
                yaw: -2.5,
                phase: 0.75,
                speed: 1.25,
                gait: Gait::Run,
            },
        }
    }

    #[test]
    fn a_quantized_field_lands_on_its_grid() {
        assert_eq!(metres(centimetres(1.2345)), 1.23);
        assert_eq!(centimetres(1.234), 123);
        assert_eq!(centimetres(-1.236), -124);
        assert_eq!(yaw_of(turns(1.0)), 1.0);
        assert_eq!(phase_of(phase_steps(1.0)), 1.0);
        assert_eq!(seconds_of(quarter_seconds(42.5)), 42.5);
        assert_eq!(seconds_of(quarter_seconds(42.6)), 42.5);
    }

    #[test]
    fn a_quantized_field_saturates_rather_than_wraps() {
        // A position past the field, a hostile 1e30, and the two values that `as`
        // turns into nonsense: the edge of the range, never a number from
        // somewhere else in it.
        assert_eq!(centimetres(1.0e30), i16::MAX);
        assert_eq!(centimetres(-1.0e30), i16::MIN);
        assert_eq!(centimetres(400.0), i16::MAX, "past ±327.67 m");
        assert_eq!(centimetres(f32::NAN), 0);
        assert_eq!(centimetres(f32::INFINITY), i16::MAX);
        assert_eq!(quarter_seconds(-1.0), 0);
        assert_eq!(quarter_seconds(1.0e9), u16::MAX);
        assert_eq!(phase_steps(2.0), u8::MAX);
        assert_eq!(phase_steps(-1.0), 0);
    }

    #[test]
    fn a_peer_frame_round_trips_to_the_quantum() {
        let frame = a_peer();
        let packed = WirePeer::pack(&frame).unpack();
        assert_eq!(packed.name, frame.name);
        assert_eq!(packed.state.gait, frame.state.gait);
        assert!((packed.state.x - frame.state.x).abs() <= CENTIMETRE);
        assert!((packed.state.z - frame.state.z).abs() <= CENTIMETRE);
        assert!((packed.state.yaw - frame.state.yaw).abs() <= TURN);
        assert!((packed.state.phase - frame.state.phase).abs() <= PHASE);
        assert!((packed.state.speed - frame.state.speed).abs() <= 1.0 / PER_SPEED);
    }

    #[test]
    fn packing_is_idempotent() {
        // What a relay does: a peer's frame is decoded, the name is stamped on,
        // and it is re-encoded. If the second encode differed from the first, a
        // value would drift a little further every hop.
        let bot = WireBot::pack(&a_bot());
        let once = postcard::to_allocvec(&bot).expect("pack");
        let twice = postcard::to_allocvec(&WireBot::pack(&bot.clone().unpack())).expect("pack");
        assert_eq!(once, twice);

        let peer = WirePeer::pack(&a_peer());
        let once = postcard::to_allocvec(&peer).expect("pack");
        let twice = postcard::to_allocvec(&WirePeer::pack(&peer.clone().unpack())).expect("pack");
        assert_eq!(once, twice);
    }

    #[test]
    fn a_bot_is_a_handful_of_bytes() {
        // The size this whole exercise is for. 86 bytes of JSON per bot, ten
        // times a second, against a 1200-byte budget.
        let bytes = postcard::to_allocvec(&WireBot::pack(&a_bot())).expect("pack");
        assert!(bytes.len() <= 14, "{} bytes: {bytes:?}", bytes.len());
    }

    #[test]
    fn a_voice_payload_travels_as_bytes() {
        // Not base64, and not an array of numbers: 20 ms of Opus is ~60 bytes and
        // the channel carries fifty of them a second.
        let payload: Vec<u8> = (0..60).collect();
        let wire = WireVoice {
            from: "alice".to_string(),
            seq: 7,
            payload: payload.clone(),
        };
        let bytes = postcard::to_allocvec(&wire).expect("pack");
        assert!(bytes.len() <= 80, "{} bytes", bytes.len());
        let back: WireVoice = postcard::from_bytes(&bytes).expect("unpack");
        assert_eq!(back.payload, payload);
    }
}
