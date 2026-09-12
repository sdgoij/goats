//! The goats session protocol: the message vocabulary and the framing, shared
//! by the client and the headless server.
//!
//! Nothing here knows about iroh or tokio, so the wire format is testable in
//! isolation and both ends agree on it by construction. The transport lives in
//! `session`; this crate is only the words and the bytes.
//!
//! Payloads are JSON. The control messages are small and infrequent, and a
//! readable frame is worth more here than the bytes it saves. The high-rate
//! transform channel also rides JSON, but as unreliable datagrams and without
//! the length prefix of a stream frame.

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

/// The wire version, bumped whenever a message changes shape. It is also the
/// ALPN suffix, so a peer with a different major version fails the QUIC
/// handshake before it reaches any of this.
pub const PROTOCOL_VERSION: u16 = 3;

/// A frame's length prefix is a big-endian `u32`.
pub const LENGTH_PREFIX_BYTES: usize = 4;

/// The largest payload a peer accepts. A hostile or corrupt length prefix must
/// not be able to make the other end allocate without bound.
pub const MAX_FRAME_BYTES: usize = 64 * 1024;

/// Names are truncated to this many bytes, on a character boundary.
pub const MAX_NAME_BYTES: usize = 24;

/// Chat lines are truncated to this many bytes, on a character boundary.
pub const MAX_CHAT_BYTES: usize = 512;

/// The name a nameless player gets.
pub const DEFAULT_NAME: &str = "goat";

/// The largest datagram payload either end will accept, so a corrupt or hostile
/// one cannot be decoded into something far larger than it is. Comfortably
/// under the smallest MTU a QUIC datagram is guaranteed.
pub const MAX_DATAGRAM_BYTES: usize = 1200;

/// What a client sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientMessage {
    /// The first message on a connection: the wire version and the name the
    /// player would like. The name is only a request -- the server decides,
    /// because it is the one that can tell whether it is already taken.
    Hello { version: u16, name: String },
    /// Something the player typed. A leading `@name` is a direct message, which
    /// only the server routes -- a client cannot make the server whisper to
    /// anyone, or stop it from whispering.
    Chat { text: String },
}

/// What the server sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ServerMessage {
    /// The handshake succeeded, with the canonical name the server assigned,
    /// everyone already in the session, and the session seed the world is built
    /// from.
    Welcome {
        version: u16,
        name: String,
        roster: Vec<String>,
        seed: u32,
    },
    /// The roster changed: someone joined or left.
    Roster {
        names: Vec<String>,
    },
    /// A chat line. `direct` marks a whisper, so the client can show it
    /// differently; `from` is the sender's current name.
    Chat {
        from: String,
        text: String,
        direct: bool,
    },
    /// System news for the console.
    Joined {
        name: String,
    },
    Left {
        name: String,
    },
    /// A system line the server composed: a rate limit, an unknown recipient.
    Notice {
        text: String,
    },
    /// The handshake or a later message was refused. The text goes to the
    /// console.
    Error {
        message: String,
    },
}

/// How a goat is moving, mirroring the scene's `mode`. An enum rather than a
/// string so a peer cannot put arbitrary text (or a megabyte of it) into every
/// other player's datagram path.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Gait {
    Idle,
    Walk,
    Trot,
    Run,
    Jump,
    Sleep,
    Eat,
    Dead,
}

/// One player's goat, as it travels over the unreliable datagram channel.
///
/// Positions are world-space; `phase` is the animation clock in `0..1`; `speed`
/// is the ground speed in m/s, which a receiver can use to extrapolate between
/// snapshots. Not `Eq` because of the floats.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PeerState {
    pub x: f32,
    pub z: f32,
    pub yaw: f32,
    pub phase: f32,
    pub speed: f32,
    pub gait: Gait,
}

impl PeerState {
    /// Whether every number is finite. A NaN or infinity would poison every
    /// peer's interpolation, so the transport refuses to relay one.
    pub fn is_finite(&self) -> bool {
        self.x.is_finite()
            && self.z.is_finite()
            && self.yaw.is_finite()
            && self.phase.is_finite()
            && self.speed.is_finite()
    }
}

/// A [`PeerState`] plus the name of the player it belongs to. A client sends
/// the state alone; the server fills the name in from the connection it arrived
/// on, which is what stops a peer from moving someone else's goat.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PeerFrame {
    pub name: String,
    pub state: PeerState,
}

/// One server-owned bot goat. `index` selects its coat and scale from the shared
/// `BOT_SPEC` table, so only what moves is on the wire. `phase` is the resolved
/// animation clock: for a one-shot gait (`jump`, `eat`) the server sends the
/// fraction through that clip rather than the raw timer, so a receiver poses it
/// without knowing the bot's private clocks.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BotState {
    pub index: u16,
    pub x: f32,
    pub z: f32,
    pub yaw: f32,
    pub phase: f32,
    pub gait: Gait,
    /// Which idle/jump/eat variant the bot is playing, so its clip cycles too.
    pub variant: i32,
}

impl BotState {
    pub fn is_finite(&self) -> bool {
        self.x.is_finite() && self.z.is_finite() && self.yaw.is_finite() && self.phase.is_finite()
    }
}

/// The server's world, as far as a client has to mirror it: the bots. Weather is
/// still seed-shared and simulated per client for now; it joins this once the
/// server owns it in full.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorldState {
    pub bots: Vec<BotState>,
}

impl WorldState {
    pub fn is_finite(&self) -> bool {
        self.bots.iter().all(BotState::is_finite)
    }
}

/// One datagram. The transform channel carries two kinds of traffic -- a
/// player's own goat, relayed between peers, and the server's bots -- so the
/// payload is tagged. Only the server may send [`Datagram::World`]; a client
/// that sends one has it dropped rather than forwarded.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Datagram {
    Peer(PeerFrame),
    World(WorldState),
}

/// What can go wrong encoding, framing or decoding a message.
#[derive(Debug)]
pub enum Error {
    Encode(String),
    Decode(String),
    FrameTooLarge { size: usize, max: usize },
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Encode(message) => write!(formatter, "encode: {message}"),
            Error::Decode(message) => write!(formatter, "decode: {message}"),
            Error::FrameTooLarge { size, max } => {
                write!(
                    formatter,
                    "frame of {size} bytes exceeds the {max}-byte limit"
                )
            }
        }
    }
}

impl std::error::Error for Error {}

/// Encodes a message to JSON bytes.
pub fn encode<T: Serialize>(message: &T) -> Result<Vec<u8>, Error> {
    serde_json::to_vec(message).map_err(|error| Error::Encode(error.to_string()))
}

/// Decodes a message from JSON bytes.
pub fn decode<T: DeserializeOwned>(payload: &[u8]) -> Result<T, Error> {
    serde_json::from_slice(payload).map_err(|error| Error::Decode(error.to_string()))
}

/// Wraps a payload in a wire frame: a big-endian `u32` length, then the payload.
pub fn frame(payload: &[u8]) -> Result<Vec<u8>, Error> {
    if payload.len() > MAX_FRAME_BYTES {
        return Err(Error::FrameTooLarge {
            size: payload.len(),
            max: MAX_FRAME_BYTES,
        });
    }
    let mut framed = Vec::with_capacity(LENGTH_PREFIX_BYTES + payload.len());
    framed.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    framed.extend_from_slice(payload);
    Ok(framed)
}

/// Reads the length out of a frame header, refusing anything over
/// [`MAX_FRAME_BYTES`] so the caller can size its read buffer safely.
pub fn frame_length(header: [u8; LENGTH_PREFIX_BYTES]) -> Result<usize, Error> {
    let size = u32::from_be_bytes(header) as usize;
    if size > MAX_FRAME_BYTES {
        return Err(Error::FrameTooLarge {
            size,
            max: MAX_FRAME_BYTES,
        });
    }
    Ok(size)
}

/// Cleans a requested name into something safe to show: ANSI escapes and
/// control characters removed, surrounding whitespace trimmed, truncated to
/// [`MAX_NAME_BYTES`] on a character boundary. An empty result becomes
/// [`DEFAULT_NAME`], so a player always has something to be called.
pub fn sanitize_name(desired: &str) -> String {
    let cleaned = sanitize_text(desired, MAX_NAME_BYTES);
    if cleaned.is_empty() {
        DEFAULT_NAME.to_string()
    } else {
        cleaned
    }
}

/// Cleans text a peer sent: ANSI escapes and control characters out, trimmed,
/// truncated to `max` bytes on a character boundary. Used for both names and
/// chat, since both end up rendered.
pub fn sanitize_text(text: &str, max: usize) -> String {
    let stripped = strip_ansi(text);
    let trimmed = stripped.trim();
    let mut out = String::new();
    for character in trimmed.chars() {
        if out.len() + character.len_utf8() > max {
            break;
        }
        out.push(character);
    }
    out
}

/// Splits a leading `@name body` into the name and the body. Only a *leading*
/// `@` counts, so a sentence that merely mentions a name is not a whisper.
/// Returns `None` when there is no name or no body.
pub fn direct_message(text: &str) -> Option<(&str, &str)> {
    let rest = text.strip_prefix('@')?;
    let end = rest.find(char::is_whitespace)?;
    let name = &rest[..end];
    let body = rest[end..].trim_start();
    if name.is_empty() || body.is_empty() {
        return None;
    }
    Some((name, body))
}

/// Returns a name that is not already in `taken`, appending ` #2`, ` #3`, ...
/// to the sanitized request. The result is always safe to show.
pub fn unique_name(desired: &str, taken: &[String]) -> String {
    let base = sanitize_name(desired);
    if !taken.iter().any(|name| name == &base) {
        return base;
    }
    let mut n = 2u32;
    loop {
        let candidate = with_suffix(&base, n);
        if !taken.iter().any(|name| name == &candidate) {
            return candidate;
        }
        n += 1;
    }
}

/// `base` plus ` #n`, with `base` shortened so the whole thing still fits
/// [`MAX_NAME_BYTES`].
fn with_suffix(base: &str, n: u32) -> String {
    let suffix = format!(" #{n}");
    let room = MAX_NAME_BYTES.saturating_sub(suffix.len());
    let mut head = String::new();
    for character in base.chars() {
        if head.len() + character.len_utf8() > room {
            break;
        }
        head.push(character);
    }
    if head.is_empty() {
        format!("{DEFAULT_NAME}{suffix}")
    } else {
        format!("{head}{suffix}")
    }
}

/// Removes ANSI escape sequences and control characters. The console draws
/// whatever it is given, so a name is the one place another player's bytes get
/// rendered verbatim; this keeps that from being a way to inject junk.
fn strip_ansi(input: &str) -> String {
    let mut out = String::new();
    let mut characters = input.chars().peekable();
    while let Some(character) = characters.next() {
        if character == '\u{1b}' {
            // CSI: ESC '[' then parameters until a final byte in '@'..='~'.
            // Anything else after an ESC is a two-character escape; drop both.
            if characters.peek() == Some(&'[') {
                characters.next();
                for c in characters.by_ref() {
                    if ('@'..='~').contains(&c) {
                        break;
                    }
                }
            }
            continue;
        }
        if character.is_control() {
            continue;
        }
        out.push(character);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_round_trip() {
        let messages = [
            ClientMessage::Hello {
                version: PROTOCOL_VERSION,
                name: "bob".to_string(),
            },
            ClientMessage::Chat {
                text: "hello".to_string(),
            },
        ];
        for message in &messages {
            let payload = encode(message).expect("encode");
            assert_eq!(&decode::<ClientMessage>(&payload).expect("decode"), message);
        }

        let replies = [
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                name: "bob #2".to_string(),
                roster: vec!["alice".to_string()],
                seed: 0x9e37_79b9,
            },
            ServerMessage::Roster {
                names: vec!["alice".to_string(), "bob #2".to_string()],
            },
            ServerMessage::Error {
                message: "version 2 is not supported".to_string(),
            },
            ServerMessage::Chat {
                from: "alice".to_string(),
                text: "hello".to_string(),
                direct: false,
            },
            ServerMessage::Joined {
                name: "alice".to_string(),
            },
            ServerMessage::Left {
                name: "alice".to_string(),
            },
            ServerMessage::Notice {
                text: "slow down".to_string(),
            },
        ];
        for reply in &replies {
            let payload = encode(reply).expect("encode");
            assert_eq!(&decode::<ServerMessage>(&payload).expect("decode"), reply);
        }
    }

    #[test]
    fn peer_frames_round_trip() {
        let frame = PeerFrame {
            name: "alice".to_string(),
            state: PeerState {
                x: 1.5,
                z: -2.25,
                yaw: 0.75,
                phase: 0.5,
                speed: 1.25,
                gait: Gait::Trot,
            },
        };
        let payload = encode(&frame).expect("encode");
        assert_eq!(decode::<PeerFrame>(&payload).expect("decode"), frame);

        // The enum is the lowercase scene spelling, so the wire form is readable
        // and a bad gait is a decode error rather than an unknown mode.
        assert_eq!(encode(&Gait::Jump).expect("encode"), b"\"jump\"");
        assert!(decode::<Gait>(b"\"gallop\"").is_err());
    }

    #[test]
    fn non_finite_peer_states_are_refused() {
        let mut state = PeerState {
            x: 0.0,
            z: 0.0,
            yaw: 0.0,
            phase: 0.0,
            speed: 0.0,
            gait: Gait::Idle,
        };
        assert!(state.is_finite());
        state.x = f32::NAN;
        assert!(!state.is_finite());
        state.x = 0.0;
        state.z = f32::INFINITY;
        assert!(!state.is_finite());
    }

    #[test]
    fn world_and_datagrams_round_trip() {
        let world = WorldState {
            bots: vec![
                BotState {
                    index: 0,
                    x: 1.0,
                    z: -1.0,
                    yaw: 0.0,
                    phase: 0.5,
                    gait: Gait::Idle,
                    variant: 2,
                },
                BotState {
                    index: 1,
                    x: 2.0,
                    z: 3.0,
                    yaw: 1.0,
                    phase: 0.25,
                    gait: Gait::Eat,
                    variant: 1,
                },
            ],
        };
        let datagram = Datagram::World(world.clone());
        let bytes = encode(&datagram).expect("encode");
        assert_eq!(decode::<Datagram>(&bytes).expect("decode"), datagram);
        assert!(world.is_finite());

        let peer = Datagram::Peer(PeerFrame {
            name: "alice".to_string(),
            state: PeerState {
                x: 0.0,
                z: 0.0,
                yaw: 0.0,
                phase: 0.0,
                speed: 0.0,
                gait: Gait::Walk,
            },
        });
        let bytes = encode(&peer).expect("encode");
        assert_eq!(decode::<Datagram>(&bytes).expect("decode"), peer);

        // A hostile bot position is caught rather than relayed into every
        // client's renderer.
        let broken = WorldState {
            bots: vec![BotState {
                index: 0,
                x: f32::NAN,
                z: 0.0,
                yaw: 0.0,
                phase: 0.0,
                gait: Gait::Idle,
                variant: 0,
            }],
        };
        assert!(!broken.is_finite());
    }

    #[test]
    fn a_frame_carries_its_length() {
        let payload = encode(&ClientMessage::Hello {
            version: 1,
            name: "bob".to_string(),
        })
        .expect("encode");
        let framed = frame(&payload).expect("frame");
        assert_eq!(framed.len(), LENGTH_PREFIX_BYTES + payload.len());

        let mut header = [0u8; LENGTH_PREFIX_BYTES];
        header.copy_from_slice(&framed[..LENGTH_PREFIX_BYTES]);
        assert_eq!(frame_length(header).expect("length"), payload.len());

        // The length prefix is exactly what the receiver needs to size its read,
        // and the payload that follows round-trips.
        let body = &framed[LENGTH_PREFIX_BYTES..];
        assert_eq!(body.len(), payload.len());
        assert!(decode::<ClientMessage>(body).is_ok());
    }

    #[test]
    fn oversized_and_corrupt_frames_are_refused() {
        let too_big = vec![0u8; MAX_FRAME_BYTES + 1];
        assert!(matches!(frame(&too_big), Err(Error::FrameTooLarge { .. })));
        assert!(matches!(
            frame_length([0xff, 0xff, 0xff, 0xff]),
            Err(Error::FrameTooLarge { .. })
        ));
        // A length of MAX_FRAME_BYTES is still allowed.
        assert_eq!(
            frame_length((MAX_FRAME_BYTES as u32).to_be_bytes()).expect("length"),
            MAX_FRAME_BYTES
        );
    }

    #[test]
    fn garbage_payloads_are_refused() {
        let error = decode::<ServerMessage>(b"not json").expect_err("must fail");
        assert!(matches!(error, Error::Decode(_)));
        assert!(error.to_string().contains("decode"));
    }

    #[test]
    fn names_are_cleaned() {
        assert_eq!(sanitize_name("bob"), "bob");
        assert_eq!(sanitize_name("  bob  "), "bob");
        assert_eq!(sanitize_name("bo\u{7}b"), "bob");
        // A whole CSI colour sequence goes, not just the ESC.
        assert_eq!(sanitize_name("\u{1b}[31mred\u{1b}[0m"), "red");
        assert_eq!(sanitize_name(""), DEFAULT_NAME);
        assert_eq!(sanitize_name("   "), DEFAULT_NAME);
        assert_eq!(sanitize_name("\u{1b}[31m"), DEFAULT_NAME);
    }

    #[test]
    fn names_are_truncated_on_a_character_boundary() {
        let long = "g".repeat(MAX_NAME_BYTES * 2);
        let name = sanitize_name(&long);
        assert_eq!(name.len(), MAX_NAME_BYTES);

        // A multi-byte character that would straddle the limit is dropped whole,
        // so the result stays valid UTF-8 (it is a String, so this is really
        // checking the boundary arithmetic).
        let host = "é".repeat(MAX_NAME_BYTES); // 2 bytes each
        let name = sanitize_name(&host);
        assert!(name.len() <= MAX_NAME_BYTES);
        assert_eq!(name.chars().count(), MAX_NAME_BYTES / 2);
    }

    #[test]
    fn names_are_made_unique() {
        let taken: Vec<String> = vec!["bob".to_string(), "bob #2".to_string()];
        assert_eq!(unique_name("alice", &taken), "alice");
        assert_eq!(unique_name("bob", &taken), "bob #3");

        let empty: Vec<String> = Vec::new();
        assert_eq!(unique_name("bob", &empty), "bob");
        // Sanitizing happens first, so two blank requests do not collide by luck.
        assert_eq!(unique_name("   ", &empty), DEFAULT_NAME);
        let blank: Vec<String> = vec![DEFAULT_NAME.to_string()];
        assert_eq!(unique_name("   ", &blank), "goat #2");
    }

    #[test]
    fn chat_is_cleaned_and_truncated() {
        assert_eq!(sanitize_text("  hello  ", MAX_CHAT_BYTES), "hello");
        assert_eq!(sanitize_text("hel\u{7}lo", MAX_CHAT_BYTES), "hello");
        assert_eq!(
            sanitize_text("\u{1b}[31mred\u{1b}[0m", MAX_CHAT_BYTES),
            "red"
        );
        let long = "g".repeat(MAX_CHAT_BYTES * 2);
        assert_eq!(sanitize_text(&long, MAX_CHAT_BYTES).len(), MAX_CHAT_BYTES);
    }

    #[test]
    fn only_a_leading_at_is_a_direct_message() {
        assert_eq!(
            direct_message("@bob hello there"),
            Some(("bob", "hello there"))
        );
        assert_eq!(direct_message("@bob  spaced"), Some(("bob", "spaced")));
        // No name, or no body, is not a whisper.
        assert_eq!(direct_message("@bob"), None);
        assert_eq!(direct_message("@ bob hi"), None);
        assert_eq!(direct_message("@bob   "), None);
        // A mention part-way through is ordinary text.
        assert_eq!(direct_message("hello @bob"), None);
        assert_eq!(direct_message("hello"), None);
    }

    #[test]
    fn suffixed_names_still_fit() {
        let long = "g".repeat(MAX_NAME_BYTES);
        let taken: Vec<String> = vec![long.clone()];
        let unique = unique_name(&long, &taken);
        assert!(unique.len() <= MAX_NAME_BYTES, "{unique}");
        assert!(unique.ends_with(" #2"), "{unique}");
        assert_ne!(unique, long);
    }
}
