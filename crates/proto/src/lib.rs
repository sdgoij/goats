//! The goats session protocol: the message vocabulary and the framing, shared
//! by the client and the headless server.
//!
//! Nothing here knows about iroh or tokio, so the wire format is testable in
//! isolation and both ends agree on it by construction. The transport lives in
//! `session`; this crate is only the words and the bytes.
//!
//! Two codecs, for two channels. The **frames** -- a hello, a chat line, a
//! roster, a ticket -- are JSON: they are small, infrequent, ride the JS bridge
//! (which is JSON by construction) and are what a human reads when a session
//! misbehaves. The **datagrams** are the high-rate channel, ten a second for the
//! world snapshot and fifty for voice, and they are binary and quantized
//! (`[encode_datagram]`, `[decode_datagram]`, and [`wire`] for the encoding
//! itself), because they have a 1200-byte budget to fit in.

use std::collections::BTreeMap;

use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};

mod wire;

/// The wire version, bumped whenever a message changes shape. It is also the
/// ALPN suffix, so a peer with a different major version fails the QUIC
/// handshake before it reaches any of this.
///
/// 5 added the server-owned world; 6 added the voice datagram; 7 added the
/// world-mod set to the handshake; 8 makes the datagram channel binary and
/// quantized. Bumping for voice mattered because a relay built at 5 does not
/// know the variant: it decodes the datagram as an error and drops it, so
/// without the bump a stale server accepts the join and then silently swallows
/// every packet. The mod set rides the control stream, but it still needs the
/// bump: a version-6 server would ignore the field and accept a client whose
/// world mods differ, which is exactly the silent divergence the set exists to
/// prevent. Version 8 is a stronger case still: a 7 peer would fail to decode
/// every datagram, so the two would agree on a session and see nothing move.
pub const PROTOCOL_VERSION: u16 = 8;

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

/// The largest Opus packet accepted on the media channel. Opus at ~24 kbps is
/// ~60 bytes per 20 ms frame; this leaves room for a larger bitrate while keeping
/// a hostile sender from making every peer decode a megabyte.
pub const MAX_VOICE_BYTES: usize = 512;

/// The largest world-mod set either end will compare, so a hostile hello cannot
/// make the server build an unbounded diff.
pub const MAX_MODS: usize = 256;

/// One `side: "world"` mod, by identity and content hash. The host and every
/// client must present the same set, or the world they simulate diverges;
/// `side: "client"` mods are local and never travel.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModRef {
    pub id: String,
    pub version: String,
    pub hash: u64,
}

/// How a client's world-mod set differs from the host's. `missing` is what the
/// host runs and the client lacks; `extra` is the reverse; `differing` is a
/// shared id at a different version or hash.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ModMismatch {
    pub missing: Vec<String>,
    pub extra: Vec<String>,
    pub differing: Vec<String>,
}

impl ModMismatch {
    pub fn is_empty(&self) -> bool {
        self.missing.is_empty() && self.extra.is_empty() && self.differing.is_empty()
    }

    /// A console-ready line naming what is wrong.
    pub fn describe(&self) -> String {
        let mut parts = Vec::new();
        if !self.missing.is_empty() {
            parts.push(format!("missing {}", self.missing.join(", ")));
        }
        if !self.extra.is_empty() {
            parts.push(format!("extra {}", self.extra.join(", ")));
        }
        if !self.differing.is_empty() {
            parts.push(format!("differing {}", self.differing.join(", ")));
        }
        format!("world mods do not match ({})", parts.join("; "))
    }
}

/// Compare the host's world-mod set with a client's. The comparison is exact;
/// ids are cleaned only for the message, and a set over the cap is a mismatch.
pub fn compare_world_mods(host: &[ModRef], client: &[ModRef]) -> ModMismatch {
    let mut mismatch = ModMismatch::default();
    if host.len() > MAX_MODS || client.len() > MAX_MODS {
        mismatch
            .extra
            .push(format!("more than {MAX_MODS} world mods"));
        return mismatch;
    }
    let host_map: BTreeMap<&str, &ModRef> = host.iter().map(|m| (m.id.as_str(), m)).collect();
    let client_map: BTreeMap<&str, &ModRef> = client.iter().map(|m| (m.id.as_str(), m)).collect();
    for (id, host_ref) in &host_map {
        match client_map.get(id) {
            None => mismatch.missing.push(clean_mod_id(id)),
            Some(client_ref) => {
                if host_ref.version != client_ref.version || host_ref.hash != client_ref.hash {
                    mismatch.differing.push(clean_mod_id(id));
                }
            }
        }
    }
    for id in client_map.keys() {
        if !host_map.contains_key(id) {
            mismatch.extra.push(clean_mod_id(id));
        }
    }
    mismatch.missing.sort();
    mismatch.extra.sort();
    mismatch.differing.sort();
    mismatch
}

/// A manifest id is already restricted, but a hostile peer picks its own: keep
/// only what can safely go into a console line.
fn clean_mod_id(id: &str) -> String {
    let cleaned: String = id
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
        .take(64)
        .collect();
    if cleaned.is_empty() {
        "?".to_string()
    } else {
        cleaned
    }
}

/// What a client sends.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientMessage {
    /// The first message on a connection: the wire version, the name the
    /// player would like, and the world-mod set this client runs. The name is
    /// only a request -- the server decides, because it is the one that can tell
    /// whether it is already taken. The mod set is compared with the host's, and
    /// a mismatch is refused rather than silently diverging.
    Hello {
        version: u16,
        name: String,
        #[serde(default)]
        mods: Vec<ModRef>,
    },
    /// Something the player typed. A leading `@name` is a direct message, which
    /// only the server routes -- a client cannot make the server whisper to
    /// anyone, or stop it from whispering.
    Chat { text: String },
    /// A grass cell this client just ate, so the server can record it and send
    /// it back in the world. A client owns its own goat, so its bites arrive as
    /// reports rather than being simulated by the server.
    Consume { key: i64 },
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
        /// The host's world-mod set, echoed so a client can show it.
        #[serde(default)]
        mods: Vec<ModRef>,
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

/// Which weather the server has settled into. The scene's own spelling, so the
/// JSON crosses the bridge unchanged.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum WeatherKind {
    Clear,
    Cloudy,
    Rain,
    Clearing,
}

/// The server's sky, as far as a client has to mirror it: which state it is in,
/// how far the overcast and the rain have eased, the wind, and the clock.
///
/// Deliberately only the inputs. A goat's speed and energy drain under the
/// weather depend on its own belly, so each client recomputes those rather than
/// taking a number that only fits the server's goat.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WeatherState {
    pub kind: WeatherKind,
    pub cloudiness: f32,
    pub rain_amount: f32,
    pub wind_x: f32,
    pub wind_z: f32,
    pub wind_sway: f32,
    /// Hours into the day, `0..24`.
    pub world_time: f32,
}

impl WeatherState {
    pub fn is_finite(&self) -> bool {
        self.cloudiness.is_finite()
            && self.rain_amount.is_finite()
            && self.wind_x.is_finite()
            && self.wind_z.is_finite()
            && self.wind_sway.is_finite()
            && self.world_time.is_finite()
    }
}

/// The world's PRNG streams, as the server holds them *now* -- not the seed they
/// started from. A client adopts these on join (and keeps adopting them with
/// each snapshot), so a stream it still draws from continues where the server
/// is rather than replaying from zero.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Streams {
    pub weather: u32,
    pub bots: u32,
    pub food: u32,
    pub audio: u32,
}

/// One eaten grass cell: its packed key and the seconds before it returns. The
/// meadow is mutated by everyone, so unlike the procedural world it cannot be
/// rebuilt from a stream -- it travels as state.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EatenCell {
    pub key: i64,
    pub left: f32,
}

impl EatenCell {
    pub fn is_finite(&self) -> bool {
        self.left.is_finite()
    }
}

/// The server's world, as far as a client has to mirror it: the bots, the sky,
/// the PRNG streams, the eaten meadow, and whatever world mods publish. A client
/// that joins takes this whole thing -- it does not keep the world it had
/// generated before joining.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorldState {
    pub bots: Vec<BotState>,
    pub weather: WeatherState,
    pub streams: Streams,
    /// The eaten meadow. `None` means the snapshot could not carry it -- the
    /// world was over its datagram budget and this is the part that goes (see
    /// [`fit_world`]) -- and a client reads that as "keep the meadow you have".
    /// An empty list is a different thing: a meadow with nothing eaten yet,
    /// which a client adopts wholesale. Sending it empty is not an option: that
    /// would put back every tuft the host has eaten, and a client that thinks a
    /// tuft is there cannot eat it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eaten: Option<Vec<EatenCell>>,
    /// World-mod state: `{ streams: {...}, data: { <id>: <published> } }`. A
    /// generic value because the protocol does not know what a mod publishes;
    /// the transport's datagram cap bounds it.
    #[serde(default)]
    pub mods: serde_json::Value,
}

impl WorldState {
    pub fn is_finite(&self) -> bool {
        self.weather.is_finite()
            && self.bots.iter().all(BotState::is_finite)
            && self
                .eaten
                .as_deref()
                .unwrap_or_default()
                .iter()
                .all(EatenCell::is_finite)
    }
}

/// What became of a world snapshot on its way out of a host.
///
/// A snapshot that does not fit one datagram is not sent at all by
/// [`crate::fit_world`]'s caller, so every way of not sending it is named here
/// rather than dropped in silence: the datagram channel is fire-and-forget, and
/// "the clients stopped receiving the world" is invisible otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorldOutcome {
    /// Sent whole.
    Whole,
    /// Sent without the eaten meadow.
    MeadowShed,
    /// Sent without the meadow or the world-mod state.
    ModsShed,
    /// Not sent: it does not fit even without the optional parts. `size` is what
    /// the bots, the sky and the streams alone come to.
    TooLarge { size: usize },
    /// Not sent: a number in it is not finite, which would poison every peer's
    /// interpolation.
    NotFinite,
}

impl WorldOutcome {
    /// A one-line report for a log, or `None` when nothing went wrong.
    ///
    /// The wording lives here so the client host and `goatsd` say the same thing.
    pub fn describe(&self) -> Option<String> {
        match self {
            WorldOutcome::Whole => None,
            WorldOutcome::MeadowShed => Some(format!(
                "the world is over the {MAX_DATAGRAM_BYTES}-byte datagram budget: \
                 the meadow was left out"
            )),
            WorldOutcome::ModsShed => Some(format!(
                "the world is over the {MAX_DATAGRAM_BYTES}-byte datagram budget: \
                 the meadow and the world-mod state were left out"
            )),
            WorldOutcome::TooLarge { size } => Some(format!(
                "the world does not fit a {MAX_DATAGRAM_BYTES}-byte datagram: the bots, \
                 sky and streams alone are {size} bytes"
            )),
            WorldOutcome::NotFinite => {
                Some("the world has a non-finite number and was not sent".to_string())
            }
        }
    }
}

/// Trims `world` until it fits `budget`, and says whether it can go out at all.
///
/// The shed order is fixed, cheapest loss first: the meadow, then a world mod's
/// published state. **Never** the bots, the sky or the streams -- those are the
/// world itself, and a client that stops receiving them freezes at the last
/// snapshot it got, which is the failure this exists to prevent.
///
/// Both optional parts are all-or-nothing rather than truncated. A client's
/// `applyEaten` replaces its whole map, so a short list would resurrect every
/// cell left out of it; a mod's `apply` would see a state that looks like the mod
/// itself lost its data.
///
/// A refused world is handed back untouched, so the reported `TooLarge` size is
/// what the parts that can never be shed come to on their own.
pub fn fit_world(world: &mut WorldState, budget: usize) -> WorldOutcome {
    if !world.is_finite() {
        return WorldOutcome::NotFinite;
    }
    if datagram_size(world) <= budget {
        return WorldOutcome::Whole;
    }

    let eaten = world.eaten.take();
    if datagram_size(world) <= budget {
        return WorldOutcome::MeadowShed;
    }

    let mods = std::mem::take(&mut world.mods);
    let bare = datagram_size(world);
    if bare <= budget {
        return WorldOutcome::ModsShed;
    }

    // Neither optional part was the problem, so hand the world back untouched
    // and report what the parts that can never be shed come to on their own.
    world.eaten = eaten;
    world.mods = mods;
    WorldOutcome::TooLarge { size: bare }
}

/// What `world` comes to as one encoded datagram, or `usize::MAX` when it cannot
/// be encoded at all -- which is a size nothing fits rather than a size of zero.
fn datagram_size(world: &WorldState) -> usize {
    match encode_datagram(&Datagram::World(world.clone())) {
        Ok(bytes) => bytes.len(),
        Err(_) => usize::MAX,
    }
}

/// One Opus packet on the media channel. `from` is stamped by the relay, like a
/// pose's name; a client leaves it blank. `seq` is the sender's own frame
/// counter, which a receiver uses to notice loss and order a jitter buffer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VoiceFrame {
    pub from: String,
    pub seq: u32,
    pub payload: Vec<u8>,
}

impl VoiceFrame {
    pub fn is_within_limit(&self) -> bool {
        self.payload.len() <= MAX_VOICE_BYTES
    }
}

/// One datagram. The transform channel carries three kinds of traffic -- a
/// player's own goat, relayed between peers; the server's world; and voice -- so
/// the payload is tagged. Only the server may send [`Datagram::World`]; a client
/// that sends one has it dropped rather than forwarded.
///
/// The tag is one byte on the wire ([`encode_datagram`]); this enum is the
/// vocabulary, not the encoding.
#[derive(Debug, Clone, PartialEq)]
pub enum Datagram {
    Peer(PeerFrame),
    World(WorldState),
    Voice(VoiceFrame),
}

impl Datagram {
    /// Whether every number in it is finite. A NaN or an infinity would poison
    /// every peer's interpolation, so the encoder refuses one outright and the
    /// receivers refuse to relay one.
    pub fn is_finite(&self) -> bool {
        match self {
            Datagram::Peer(frame) => frame.state.is_finite(),
            Datagram::World(world) => world.is_finite(),
            Datagram::Voice(_) => true,
        }
    }
}

/// What can go wrong encoding, framing or decoding a message.
#[derive(Debug)]
pub enum Error {
    Encode(String),
    Decode(String),
    /// A datagram carried a number that is not finite, and was not sent. A NaN
    /// would poison every peer's interpolation, and quantization would turn it
    /// into an unrelated number.
    NotFinite,
    FrameTooLarge {
        size: usize,
        max: usize,
    },
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Encode(message) => write!(formatter, "encode: {message}"),
            Error::Decode(message) => write!(formatter, "decode: {message}"),
            Error::NotFinite => {
                write!(formatter, "a number in the message is not finite")
            }
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

/// Encodes a control message to JSON bytes.
///
/// This is the framing channel -- hello, welcome, chat, roster, notices, errors
/// -- which asks for readable bytes over compact ones. A datagram is
/// [`encode_datagram`].
pub fn encode_frame<T: Serialize>(message: &T) -> Result<Vec<u8>, Error> {
    serde_json::to_vec(message).map_err(|error| Error::Encode(error.to_string()))
}

/// Decodes a control message from JSON bytes.
pub fn decode_frame<T: DeserializeOwned>(payload: &[u8]) -> Result<T, Error> {
    serde_json::from_slice(payload).map_err(|error| Error::Decode(error.to_string()))
}

/// Encodes a datagram to its packed binary form.
///
/// A datagram whose numbers are not finite is refused rather than sent: it would
/// poison every peer's interpolation, and quantization would turn a NaN into a
/// number that means something else. The receivers check too -- a peer's bytes
/// are not trusted -- but a value that cannot be true should not leave here.
pub fn encode_datagram(datagram: &Datagram) -> Result<Vec<u8>, Error> {
    if !datagram.is_finite() {
        return Err(Error::NotFinite);
    }
    let packed = wire::WireDatagram::pack(datagram)?;
    postcard::to_allocvec(&packed).map_err(|error| Error::Encode(error.to_string()))
}

/// Decodes a datagram from its packed binary form.
///
/// Everything this can produce is finite: the wire cannot carry a NaN (see
/// `wire`), so the checks that remain are about the bridge, where the scene
/// hands Rust JSON.
pub fn decode_datagram(payload: &[u8]) -> Result<Datagram, Error> {
    let packed: wire::WireDatagram =
        postcard::from_bytes(payload).map_err(|error| Error::Decode(error.to_string()))?;
    packed.unpack()
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
                mods: vec![ModRef {
                    id: "com.example.a".to_string(),
                    version: "1.0.0".to_string(),
                    hash: 0xabc,
                }],
            },
            ClientMessage::Chat {
                text: "hello".to_string(),
            },
        ];
        for message in &messages {
            let payload = encode_frame(message).expect("encode");
            assert_eq!(
                &decode_frame::<ClientMessage>(&payload).expect("decode"),
                message
            );
        }

        let replies = [
            ServerMessage::Welcome {
                version: PROTOCOL_VERSION,
                name: "bob #2".to_string(),
                roster: vec!["alice".to_string()],
                seed: 0x9e37_79b9,
                mods: vec![],
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
            let payload = encode_frame(reply).expect("encode");
            assert_eq!(
                &decode_frame::<ServerMessage>(&payload).expect("decode"),
                reply
            );
        }
    }

    #[test]
    fn world_mod_sets_are_compared() {
        let a = ModRef {
            id: "com.a".to_string(),
            version: "1".to_string(),
            hash: 1,
        };
        let b = ModRef {
            id: "com.b".to_string(),
            version: "1".to_string(),
            hash: 2,
        };
        assert!(compare_world_mods(&[a.clone()], &[a.clone()]).is_empty());

        let missing = compare_world_mods(&[a.clone(), b.clone()], &[a.clone()]);
        assert_eq!(missing.missing, vec!["com.b".to_string()]);
        assert!(missing.extra.is_empty());
        assert!(missing.describe().contains("missing com.b"));

        let extra = compare_world_mods(&[a.clone()], &[a.clone(), b.clone()]);
        assert_eq!(extra.extra, vec!["com.b".to_string()]);

        let changed = ModRef {
            id: "com.a".to_string(),
            version: "2".to_string(),
            hash: 1,
        };
        let differing = compare_world_mods(&[a.clone()], &[changed]);
        assert_eq!(differing.differing, vec!["com.a".to_string()]);

        // A hostile id is cleaned for the message, not for the comparison.
        let hostile = ModRef {
            id: "\u{1b}[31mEVIL".to_string(),
            version: "1".to_string(),
            hash: 9,
        };
        let cleaned = compare_world_mods(&[], &[hostile]);
        assert_eq!(cleaned.extra, vec!["31mEVIL".to_string()]);

        // Over the cap is a mismatch, whatever the contents.
        let many: Vec<ModRef> = (0..=MAX_MODS)
            .map(|i| ModRef {
                id: format!("m{i}"),
                version: "1".to_string(),
                hash: i as u64,
            })
            .collect();
        assert!(!compare_world_mods(&many, &[]).is_empty());
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
        let payload = encode_frame(&frame).expect("encode");
        assert_eq!(decode_frame::<PeerFrame>(&payload).expect("decode"), frame);

        // The enum is the lowercase scene spelling, so the wire form is readable
        // and a bad gait is a decode error rather than an unknown mode.
        assert_eq!(encode_frame(&Gait::Jump).expect("encode"), b"\"jump\"");
        assert!(decode_frame::<Gait>(b"\"gallop\"").is_err());
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

    /// A value on the animation clock's grid. The wire is lossy (255 steps
    /// through a clip), so a fixture that is meant to come back identical has to
    /// start on the grid; `wire`'s own tests are where the loss is measured.
    fn on_the_phase_grid(value: f32) -> f32 {
        (value * 255.0).round() / 255.0
    }

    #[test]
    fn world_and_datagrams_round_trip() {
        // Every number here is on the quantization grid, so this is an exact
        // round trip of the *envelope*: the variant, the field set, the sky, the
        // streams and a mod's bytes. Positions land on 1 cm, yaw on 1/10000 of a
        // turn, `left` on a quarter second, so any two-decimal value is exact.
        let world = WorldState {
            bots: vec![
                BotState {
                    index: 0,
                    x: 1.0,
                    z: -1.0,
                    yaw: 0.0,
                    phase: on_the_phase_grid(0.5),
                    gait: Gait::Idle,
                    variant: 2,
                },
                BotState {
                    index: 1,
                    x: 2.75,
                    z: 3.25,
                    yaw: 1.0,
                    phase: on_the_phase_grid(0.25),
                    gait: Gait::Eat,
                    variant: 1,
                },
            ],
            weather: WeatherState {
                kind: WeatherKind::Rain,
                cloudiness: 0.9,
                rain_amount: 0.75,
                wind_x: 1.2,
                wind_z: -0.3,
                wind_sway: 1.1,
                world_time: 13.5,
            },
            streams: Streams {
                weather: 0x1111_2222,
                bots: 0x3333_4444,
                food: 0x5555_6666,
                audio: 0x7777_8888,
            },
            eaten: Some(vec![
                EatenCell {
                    key: 12345,
                    left: 42.5,
                },
                EatenCell { key: -7, left: 3.0 },
            ]),
            mods: serde_json::json!({
                "streams": { "com.example.dash:sprint": 1234 },
                "data": { "com.example.dash": { "cooldown": 1.5 } },
            }),
        };
        let datagram = Datagram::World(world.clone());
        let bytes = encode_datagram(&datagram).expect("encode");
        assert_eq!(decode_datagram(&bytes).expect("decode"), datagram);
        assert!(world.is_finite());

        // The weather kind is the scene's own spelling in the *frames*, so
        // nothing has to map it at the bridge.
        assert_eq!(
            encode_frame(&WeatherKind::Clearing).expect("encode"),
            b"\"clearing\""
        );
        assert!(decode_frame::<WeatherKind>(b"\"hail\"").is_err());

        let peer = Datagram::Peer(PeerFrame {
            name: "alice".to_string(),
            state: PeerState {
                x: 0.0,
                z: -12.5,
                yaw: -1.0,
                phase: on_the_phase_grid(0.75),
                speed: 1.25,
                gait: Gait::Walk,
            },
        });
        let bytes = encode_datagram(&peer).expect("encode");
        assert_eq!(decode_datagram(&bytes).expect("decode"), peer);

        // A hostile bot position or weather value is caught rather than relayed
        // into every client's renderer.
        let mut broken = world.clone();
        broken.bots[0].x = f32::NAN;
        assert!(!broken.is_finite());
        let mut broken = world.clone();
        broken.weather.wind_x = f32::INFINITY;
        assert!(!broken.is_finite());
        let mut broken = world.clone();
        broken.eaten.as_mut().expect("a meadow")[0].left = f32::NAN;
        assert!(!broken.is_finite());
    }

    /// A world shaped like a session that has been running for a couple of
    /// minutes: the default herd, a settled sky, the streams, `eaten` meadow
    /// cells and a world mod's published flock. The sizes are the real ones --
    /// this is the fixture the datagram budget is argued about with.
    fn a_running_world(eaten: usize) -> WorldState {
        WorldState {
            bots: (0..7).map(bot).collect(),
            weather: WeatherState {
                kind: WeatherKind::Cloudy,
                cloudiness: 0.812,
                rain_amount: 0.0,
                wind_x: 1.234,
                wind_z: -0.456,
                wind_sway: 0.789,
                world_time: 13.512,
            },
            streams: Streams {
                weather: 0x1f2e_3d4c,
                bots: 0x2a3b_4c5d,
                food: 0x3c4d_5e6f,
                audio: 0x4d5e_6f70,
            },
            eaten: Some(
                (0..eaten as i64)
                    .map(|i| EatenCell {
                        key: 33_570_816 + i,
                        left: 61.234,
                    })
                    .collect(),
            ),
            mods: serde_json::json!({
                "streams": { "com.github.sdgoij.goats.birds:flock": 1_234_567 },
                "data": { "com.github.sdgoij.goats.birds": [
                    [20.0, 9.0, -20.0, 0.5, 3.0],
                    [26.0, 9.0, -26.0, 0.5, 3.0],
                ]},
            }),
        }
    }

    /// A bot as the scene sends one.
    fn bot(index: u16) -> BotState {
        BotState {
            index,
            x: 1.234 + f32::from(index),
            z: -12.345 - f32::from(index),
            yaw: 0.5,
            phase: 0.123,
            gait: Gait::Walk,
            variant: 1,
        }
    }

    /// The world with no world mod's state in it, as the scene sends one when
    /// nothing is loaded (and not `null`, which is what a shed one carries).
    fn without_mods(world: &mut WorldState) {
        world.mods = serde_json::json!({ "streams": {}, "data": {} });
    }

    #[test]
    fn an_over_budget_world_sheds_the_meadow_first() {
        let mut world = a_running_world(10);
        let full = datagram_size(&world);
        let budget = full - 1;
        let outcome = fit_world(&mut world, budget);
        assert_eq!(outcome, WorldOutcome::MeadowShed);
        assert!(world.eaten.is_none(), "the meadow goes first");
        assert_eq!(world.bots.len(), 7, "the bots are never shed");
        assert!(datagram_size(&world) <= budget);
        assert!(outcome.describe().is_some());
    }

    #[test]
    fn an_over_budget_world_without_the_meadow_sheds_the_mod_state_too() {
        let mut world = a_running_world(10);
        let meadow_shed = {
            let mut probe = world.clone();
            probe.eaten = None;
            datagram_size(&probe)
        };
        let bare = {
            let mut probe = world.clone();
            probe.eaten = None;
            probe.mods = serde_json::Value::Null;
            datagram_size(&probe)
        };
        assert!(bare < meadow_shed, "the mod state should be worth bytes");
        let budget = meadow_shed - 1;
        assert_eq!(fit_world(&mut world, budget), WorldOutcome::ModsShed);
        assert!(world.eaten.is_none() && world.mods.is_null(), "{world:?}");
        assert!(datagram_size(&world) <= budget);
    }

    #[test]
    fn a_world_the_bots_alone_cannot_fit_is_refused_untouched() {
        let mut world = a_running_world(10);
        let before = world.clone();
        let bare = {
            let mut probe = world.clone();
            probe.eaten = None;
            probe.mods = serde_json::Value::Null;
            datagram_size(&probe)
        };
        let outcome = fit_world(&mut world, bare - 1);
        assert_eq!(outcome, WorldOutcome::TooLarge { size: bare });
        assert_eq!(world, before, "a refusal leaves the world as it was");
        assert!(
            outcome
                .describe()
                .is_some_and(|text| text.contains(&bare.to_string())),
            "the report should name the size: {outcome:?}"
        );
    }

    #[test]
    fn a_world_that_fits_is_left_alone() {
        let mut world = a_running_world(2);
        let before = world.clone();
        assert_eq!(
            fit_world(&mut world, MAX_DATAGRAM_BYTES),
            WorldOutcome::Whole
        );
        assert_eq!(world, before);
        assert!(datagram_size(&world) <= MAX_DATAGRAM_BYTES);
        assert_eq!(WorldOutcome::Whole.describe(), None);
    }

    #[test]
    fn a_shed_meadow_round_trips_as_missing_not_empty() {
        // The distinction a client's "keep what you have" depends on: left out
        // (because the snapshot was over budget) must not decode into an empty
        // meadow, which would put every eaten tuft back and leave the client
        // unable to eat. An empty meadow is a different, real state and travels.
        let mut shed = a_running_world(3);
        shed.eaten = None;
        let shed_bytes = encode_datagram(&Datagram::World(shed)).expect("encode");
        match decode_datagram(&shed_bytes).expect("decode") {
            Datagram::World(decoded) => assert_eq!(decoded.eaten, None),
            other => panic!("expected a world, got {other:?}"),
        }

        let mut empty = a_running_world(3);
        empty.eaten = Some(Vec::new());
        let empty_bytes = encode_datagram(&Datagram::World(empty)).expect("encode");
        match decode_datagram(&empty_bytes).expect("decode") {
            Datagram::World(decoded) => assert_eq!(decoded.eaten, Some(Vec::new())),
            other => panic!("expected a world, got {other:?}"),
        }

        // The two are distinguishable on the wire, which is the whole point.
        assert_ne!(shed_bytes, empty_bytes);
    }

    #[test]
    fn a_non_finite_world_is_named_rather_than_sent() {
        let mut world = a_running_world(2);
        world.bots[0].x = f32::NAN;
        assert_eq!(
            fit_world(&mut world, MAX_DATAGRAM_BYTES),
            WorldOutcome::NotFinite
        );
        assert!(WorldOutcome::NotFinite.describe().is_some());
    }

    #[test]
    fn the_vanilla_world_now_fits_with_room_for_a_mod() {
        // What M16 was planned from, re-stated for the binary wire. Under JSON the
        // worst case a player can reach without any mod was 1600 bytes and
        // climbing against a 1200-byte cap; binary and quantized it fits whole,
        // with most of the budget still free. This is the guard against the
        // budget eroding again: the next field added to `WorldState` has to
        // argue for its bytes.
        let mut world = a_running_world(20);
        world.bots = (0..10).map(bot).collect();
        without_mods(&mut world);
        let size = datagram_size(&world);
        assert_eq!(
            fit_world(&mut world, MAX_DATAGRAM_BYTES),
            WorldOutcome::Whole,
            "{size} bytes"
        );
        assert!(world.eaten.is_some(), "nothing had to be shed");
        assert!(
            size < MAX_DATAGRAM_BYTES / 3,
            "{size} bytes of a {MAX_DATAGRAM_BYTES}-byte budget leaves no room for a mod"
        );
    }

    #[test]
    fn a_greedy_world_mod_is_what_makes_the_snapshot_shed() {
        // The shed path is still the safety net -- a mod may publish far more than
        // it should -- and the meadow is still what goes first, so the world
        // itself keeps arriving and the mod keeps its state.
        let mut world = a_running_world(20);
        world.bots = (0..10).map(bot).collect();
        without_mods(&mut world);
        // Sized from the measurement rather than by hand, so the test says what
        // it means: the blob is big enough to push the snapshot over the cap, and
        // the meadow is worth more than the overshoot, so the meadow alone is
        // what has to go.
        let base = datagram_size(&world);
        let room = MAX_DATAGRAM_BYTES.saturating_sub(base);
        world.mods = serde_json::json!({
            "data": { "com.example.big": { "blob": "x".repeat(room + 40) } },
        });
        let full = datagram_size(&world);
        assert!(
            full > MAX_DATAGRAM_BYTES,
            "{full} bytes against {base} before the mod"
        );

        assert_eq!(
            fit_world(&mut world, MAX_DATAGRAM_BYTES),
            WorldOutcome::MeadowShed
        );
        assert!(world.eaten.is_none(), "the meadow goes first");
        assert_eq!(world.bots.len(), 10, "the bots are never shed");
        assert!(world.mods.is_object(), "the mod keeps its state");
        assert!(datagram_size(&world) <= MAX_DATAGRAM_BYTES);
    }

    #[test]
    fn voice_frames_round_trip_as_bytes() {
        let frame = VoiceFrame {
            from: "alice".to_string(),
            seq: 7,
            payload: vec![0u8, 1, 2, 253, 254, 255],
        };
        let datagram = Datagram::Voice(frame.clone());
        let bytes = encode_datagram(&datagram).expect("encode");
        assert_eq!(decode_datagram(&bytes).expect("decode"), datagram);

        // The payload is raw bytes on the wire -- not base64, which cost a third
        // more than it saved, and not an array of numbers. 20 ms of Opus is ~60
        // bytes here, fifty times a second.
        assert!(
            bytes.len() <= frame.payload.len() + 16,
            "{} bytes for a {} byte payload",
            bytes.len(),
            frame.payload.len()
        );

        assert!(frame.is_within_limit());
        let too_big = VoiceFrame {
            from: String::new(),
            seq: 0,
            payload: vec![0; MAX_VOICE_BYTES + 1],
        };
        assert!(!too_big.is_within_limit());
    }

    #[test]
    fn a_non_finite_datagram_is_refused_at_the_encoder() {
        // Quantization cannot represent a NaN, so without this it would become an
        // unrelated number -- for a position, a peer teleporting across the
        // field. The encoder refuses it instead, as well as the receivers.
        let peer = |x: f32, z: f32| {
            Datagram::Peer(PeerFrame {
                name: "alice".to_string(),
                state: PeerState {
                    x,
                    z,
                    yaw: 0.0,
                    phase: 0.0,
                    speed: 0.0,
                    gait: Gait::Idle,
                },
            })
        };
        assert!(matches!(
            encode_datagram(&peer(f32::NAN, 0.0)),
            Err(Error::NotFinite)
        ));
        assert!(matches!(
            encode_datagram(&peer(0.0, f32::INFINITY)),
            Err(Error::NotFinite)
        ));
        // A finite one goes out, so this is a check and not a blanket refusal.
        assert!(encode_datagram(&peer(1.0, 2.0)).is_ok());
    }

    #[test]
    fn a_consume_report_round_trips() {
        let message = ClientMessage::Consume { key: 8189_0001 };
        let payload = encode_frame(&message).expect("encode");
        assert_eq!(
            &decode_frame::<ClientMessage>(&payload).expect("decode"),
            &message
        );
    }

    #[test]
    fn a_frame_carries_its_length() {
        let payload = encode_frame(&ClientMessage::Hello {
            version: 1,
            name: "bob".to_string(),
            mods: vec![],
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
        assert!(decode_frame::<ClientMessage>(body).is_ok());
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
        let error = decode_frame::<ServerMessage>(b"not json").expect_err("must fail");
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
