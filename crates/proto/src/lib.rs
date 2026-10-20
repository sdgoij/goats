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
/// quantized; 9 adds `Gait::Flung` (M19c), which is a variant *inside* the pose
/// datagram and the world snapshot rather than a new message -- a version-8 peer
/// would read the variant index as some other gait, or fail to decode the frame.
/// Bumping for voice mattered because a relay built at 5 does not
/// know the variant: it decodes the datagram as an error and drops it, so
/// without the bump a stale server accepts the join and then silently swallows
/// every packet. The mod set rides the control stream, but it still needs the
/// bump: a version-6 server would ignore the field and accept a client whose
/// world mods differ, which is exactly the silent divergence the set exists to
/// prevent. Version 8 is a stronger case still: a 7 peer would fail to decode
/// every datagram, so the two would agree on a session and see nothing move.
///
/// 11 splits the world snapshot into parts (see [`WorldPart`]): the world datagram's payload
/// changes from the whole `WorldState` to one part of it, so a version-10 peer and this one
/// would not agree on what a world datagram even is. A bump is what makes that a refused
/// handshake -- a version-10 peer fails the ALPN -- rather than a client decoding a part as a
/// whole world and taking a herd of one part for the whole herd, which is the shrinking mirror
/// `466b967` was about. A backwards-compatible variant was not worth it: part 0 of a split
/// world is a *legal-looking* world with fewer bots, which is exactly the shape an old peer
/// would misread rather than reject.
pub const PROTOCOL_VERSION: u16 = 12;

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

/// The largest a herd may be: `TUNING.herd.count`'s ceiling in the scene (`MAX_HERD` in
/// `core.js`, `Bots.MAX_HERD` in the Godot port), and what `goatsd --herd` refuses beyond.
/// It lives here because this is the one language the JavaScript and the GDScript cannot
/// read, and because it is the number the datagram budget below is sized for.
pub const MAX_HERD: usize = 100;

/// The largest datagram payload either end will accept, so a corrupt or hostile
/// one cannot be decoded into something far larger than it is -- and the cap a world
/// part is measured against (see [`MAX_WORLD_PART_BYTES`]).
///
/// A world snapshot no longer has to fit one datagram: its herd is split across parts (see
/// [`split_world`]), so the ceiling is carried by the *parts* rather than by a taller budget.
/// This stays the hard cap every receiver applies, and it is what [`fit_world`] shaves the
/// sheddable state to. Measured with the real encoder, a hundred goats spread across the field
/// cost about 1200 bytes of the world that can *never* be shed (the bots, the sky and the
/// streams), and about 1300 if every one is mid-fling; a running world -- a meadow, sixteen
/// craters, twelve spent devices -- adds about 230. They travel as three parts -- measured at
/// 590, 600 and 365 bytes -- rather than as one ~1500-byte datagram; the cases that pin the
/// arithmetic are in `proto`'s tests and `goatsd`'s `--herd`.
///
/// The cost is why this is not simply "as big as it takes". These are *unreliable* QUIC
/// datagrams: the transport will not split one, so a snapshot past the path MTU is one the path
/// cannot carry at all rather than one that arrives in pieces. So this stays where the transport's
/// guarantee is -- around 1200 bytes, the smallest MTU a QUIC datagram is promised to cross --
/// and it is the *hard cap every receiver applies* rather than a size anything is packed to. A
/// world is packed to [`MAX_WORLD_PART_BYTES`], half of this, so its herd reaches narrow paths
/// too, which is the whole reason it is split. Both clients and `goatsd` read this one constant,
/// so it is one number on the wire.
pub const MAX_DATAGRAM_BYTES: usize = 1200;

/// The largest a single part of a world snapshot is packed to, which is what the herd is
/// split against.
///
/// A snapshot does not have to fit one datagram: its herd is divided across parts (see
/// [`split_world`]) so that each one is small enough to arrive. This is the size a part is
/// *packed* to, and it is deliberately half of [`MAX_DATAGRAM_BYTES`] rather than equal to it: a
/// part that is half the budget sits under the ~1200 bytes QUIC *guarantees* it can carry, so it
/// is sent on every path rather than only on wide ones. Honest headroom, sized from the measured
/// per-bot cost: a hundred goats are ~12 bytes each (~1200 bytes) and part 0 also carries the
/// header, so half the budget splits them across about three parts of about six hundred bytes
/// each (measured 590 + 600 + 365) rather than the one datagram the budget cannot carry.
pub const MAX_WORLD_PART_BYTES: usize = MAX_DATAGRAM_BYTES / 2;

/// The most parts one snapshot may be split into.
///
/// It is a bound on the *herd* (a hundred goats cannot need many parts at
/// [`MAX_WORLD_PART_BYTES`]) and a bound on a peer: a receiver gathers the parts a snapshot
/// announces, so an unbounded count would let a hostile one make a client hold state for a
/// snapshot that can never complete. The smaller the count the better, too, for the reason in
/// [`split_world`]: a snapshot is only usable once every part arrives, so more parts means a
/// snapshot less likely to assemble.
pub const MAX_WORLD_PARTS: u8 = 8;

// The two numbers the world's sizing turns on, pinned at compile time. The herd's ceiling is
// carried by *parts* and never by a taller datagram (see [`split_world`]): an unreliable QUIC
// datagram is not fragmented by the transport, so a snapshot past the path MTU is one the path
// cannot carry at all. Raising the budget to fit a bigger herd -- the shortcut this forbids --
// now fails the build rather than quietly shipping a world no path can deliver.
const _: () = {
    assert!(
        MAX_DATAGRAM_BYTES == 1200,
        "the transport's guaranteed datagram size moved"
    );
    assert!(
        MAX_WORLD_PART_BYTES == 600,
        "a part is packed to half the budget"
    );
    assert!(
        MAX_WORLD_PART_BYTES < MAX_DATAGRAM_BYTES,
        "a part is packed inside the budget, not to its edge"
    );
};

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

//
// The mod registry: a gossip topic that names packages and who can serve them,
// and `iroh-blobs` for the bytes. See `SWARM.md`.
//
// A package is a directory tree rooted at `mod.json`, named by a BLAKE3
// collection hash (`root`). The record also carries the join's FNV digest
// (`hash`), because that is still what a session compares; the two are not the
// same hash and neither replaces the other yet.

/// Which side a record's package runs on. Mirrors `mods::Side` without making
/// this crate depend on the loader.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModSide {
    Client,
    World,
}

/// The largest id a record may carry, matching the loader's own limit.
pub const MAX_RECORD_ID_CHARS: usize = 128;
/// A version is a label, not prose.
pub const MAX_RECORD_VERSION_CHARS: usize = 64;
/// The largest package the registry will advertise, and therefore fetch. The
/// loader caps one asset at 64 MiB; this is a whole tree.
pub const MAX_PACKAGE_BYTES: u64 = 512 * 1024 * 1024;
/// The most records a catalogue keeps. A topic is not a directory.
pub const MAX_REGISTRY_RECORDS: usize = 1024;
/// The largest registry message accepted from a peer. A record is a few hundred
/// bytes; this bounds a hostile one before it reaches the decoder.
pub const MAX_REGISTRY_MESSAGE_BYTES: usize = 4096;

/// One package on the registry: what a `.torrent` would say, minus the file
/// list. The list is the collection's own index, fetched as a blob and verified
/// by `root`, so a ten-thousand-file mod does not grow this message.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModRecord {
    pub id: String,
    pub version: String,
    /// The mod API major the package declares.
    pub api: u32,
    pub side: ModSide,
    /// The FNV-1a digest a join compares (`mods::Manifest::hash`). Carried so a
    /// client can tell whether this is the copy a session would accept.
    pub hash: u64,
    /// The BLAKE3 collection hash: the address the bytes are fetched by.
    pub root: [u8; 32],
    /// The package's total size in bytes, for a budget before fetching.
    pub size: u64,
    /// The endpoint that first announced it. Attribution, not proof.
    pub author: [u8; 32],
}

impl ModRecord {
    /// The identity a join compares. The root is deliberately not part of it:
    /// the handshake has no field for an address yet.
    pub fn reference(&self) -> ModRef {
        ModRef {
            id: self.id.clone(),
            version: self.version.clone(),
            hash: self.hash,
        }
    }

    /// Trim and bound what a peer sent, or refuse it. Every string in a record
    /// is displayed and used as a filename, so the check is the same shape as
    /// the loader's: an id of the allowed characters, a sane version, and a root
    /// that is not the zero hash.
    pub fn clean(mut self) -> Option<ModRecord> {
        self.id = self.id.trim().to_string();
        self.version = self.version.trim().to_string();
        let id_ok = !self.id.is_empty()
            && self.id.chars().count() <= MAX_RECORD_ID_CHARS
            && self
                .id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'));
        let version_ok = !self.version.is_empty()
            && self.version.chars().count() <= MAX_RECORD_VERSION_CHARS
            && !self.version.chars().any(char::is_control);
        let sane = self.size <= MAX_PACKAGE_BYTES
            && self.root != [0u8; 32]
            && self.author != [0u8; 32]
            && self.api != 0;
        (id_ok && version_ok && sane).then_some(self)
    }
}

/// "I can serve this root." A have is the peer half of a record: the record
/// says what a mod is, the have says who has the bytes. The sender is the
/// provider, so there is nothing else to carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ModHave {
    pub root: [u8; 32],
}

impl ModHave {
    /// A have for the zero hash means nothing and is dropped.
    pub fn clean(self) -> Option<ModHave> {
        (self.root != [0u8; 32]).then_some(self)
    }
}

/// The first words of [`ModMismatch::describe`], and the only thing that marks a
/// refusal as being about mods.
///
/// A server's refusal is a line rather than a typed field, because the handshake's
/// reply is a fixed shape and adding a kind to it would be a `PROTOCOL_VERSION`
/// change. Its text is therefore the marker, and it lives here so the two ends of
/// it -- the refusal and whoever recognises one -- cannot drift apart. It is a
/// *hint* for the client's UX, never a check: the authority on whether two sets
/// match is [`compare_world_mods`], which the fetching client runs for itself
/// (M18c).
///
/// ```text
/// world mods do not match (missing com.github.sdgoij.goats.birds)
/// ```
pub const MISMATCH_PREFIX: &str = "world mods do not match";

/// How a client's world-mod set differs from the host's. `missing` is what the
/// host runs and the client lacks; `extra` is the reverse; `differing` is a
/// shared id at a different version or hash.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct ModMismatch {
    pub missing: Vec<String>,
    pub extra: Vec<String>,
    pub differing: Vec<DifferingMod>,
}

/// A shared id whose version or content hash disagrees.
///
/// Both sides are kept, not just the id, because "differing" on its own is the
/// hardest refusal to act on: it says nothing about *which* two things differ,
/// and the usual cause -- the same mod content hashed on two platforms -- looks
/// identical from the id alone. The line names both hashes so a mismatch is one
/// look rather than a guess.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DifferingMod {
    pub id: String,
    pub host: ModRef,
    pub client: ModRef,
}

impl DifferingMod {
    fn describe(&self) -> String {
        format!(
            "{} (host {}#{:016x}, you {}#{:016x})",
            self.id, self.host.version, self.host.hash, self.client.version, self.client.hash
        )
    }
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
            let list: Vec<String> = self.differing.iter().map(DifferingMod::describe).collect();
            parts.push(format!("differing {}", list.join("; ")));
        }
        format!("{MISMATCH_PREFIX} ({})", parts.join("; "))
    }
}

/// A world-mod set as one line, for the startup log: both ends print this, so a
/// refusal can be read against what each side actually had.
///
/// ```text
/// none
/// com.github.sdgoij.goats.birds@1.0.0#9f3a1b2c4d5e6f70
/// ```
pub fn describe_mods(mods: &[ModRef]) -> String {
    if mods.is_empty() {
        return "none".to_string();
    }
    mods.iter()
        .map(|m| format!("{}@{}#{:016x}", m.id, m.version, m.hash))
        .collect::<Vec<String>>()
        .join(" ")
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
                    mismatch.differing.push(DifferingMod {
                        id: clean_mod_id(id),
                        host: (*host_ref).clone(),
                        client: (*client_ref).clone(),
                    });
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
    mismatch.differing.sort_by(|a, b| a.id.cmp(&b.id));
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

// ---- the mod-fetch protocol (M18) -------------------------------------------
//
// A joiner that is missing a world mod can fetch it from the host over the same
// endpoint, on a connection of its own. This is a second protocol, with its own
// ALPN and so its own version, because it has to keep working against a host
// built for an older wire version, and because a fetch that fails must not look
// like a session failure. The plan is `ROADMAP.md` M18.

/// The mod-fetch protocol's version. It is the ALPN suffix, so a peer built
/// against a different fetch protocol fails the QUIC handshake before it reaches
/// any of this -- the same rule the session ALPN follows.
pub const MOD_FETCH_VERSION: u8 = 1;

/// The ALPN a fetch connection negotiates, beside the session's own.
pub fn mod_fetch_alpn() -> Vec<u8> {
    format!("goats-mods/{MOD_FETCH_VERSION}").into_bytes()
}

/// The largest archive either end will move in one reply. A mod carries assets
/// (the loader caps a single one at 64 MiB), so this is the same order: a
/// structural guard against a hostile length, not a budget.
pub const MAX_MOD_BLOB_BYTES: u32 = 64 * 1024 * 1024;

/// What a client asks a host for on a fetch connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModFetchRequest {
    /// These mods, in order. The host answers one reply per entry, and only for
    /// an id it holds at the `version` and `hash` asked for.
    Wanted(Vec<ModRef>),
    /// Everything this host can serve. This is how a client learns the host's
    /// world-mod set without the refusal having to carry it -- which is what
    /// keeps adding mod sync from being a `PROTOCOL_VERSION` bump.
    Catalogue,
}

/// The host's answer to one entry of a [`ModFetchRequest::Wanted`]. A `Blob` is a
/// framed head followed, on the same stream, by `length` raw bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ModFetchReply {
    /// The archive follows on this stream: `length` bytes, `mod.json` at the
    /// root, the form the loader reads back.
    Blob { reference: ModRef, length: u32 },
    /// This id cannot be served -- the host does not hold it, holds it at a
    /// different version or hash, or its archive is over [`MAX_MOD_BLOB_BYTES`].
    Unavailable { id: String, reason: String },
    /// The answer to a [`ModFetchRequest::Catalogue`]: every world mod the host
    /// can serve, in id order.
    Catalogue(Vec<ModRef>),
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
    /// A device this client's goat has just tripped (M19e). It is a *report*, not a
    /// permission slip: the client has already fired it locally, and this is so the
    /// host can mark the device spent -- the neighbours must not trip it again -- and
    /// tell the others. Deliberately no coordinates: the host owns the layout, so it
    /// is the one that can say where a key actually is, and a client that lies about a
    /// key gets a blast where the host believes the device is.
    Blast { kind: BlastKind, key: i64 },
}

/// What the server sends.
///
/// Not `Eq` any more, since `Blast` carries the host's coordinates (M19e): the world's
/// float fields were always the reason `WorldState` is only `PartialEq`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
    /// A device went off somewhere in the session (M19e). The host's coordinates for
    /// it, not the reporter's, and the goat that tripped it -- `by` is the herd's name
    /// when a bot did. A client draws the fire and the smoke, hears the bang at the
    /// right distance, and applies the blast to the goats *it* simulates (its own,
    /// whoever it is): that is how a peer gets flung by a mine someone else stepped on.
    Blast {
        kind: BlastKind,
        key: i64,
        x: f32,
        z: f32,
        by: String,
    },
    /// The handshake or a later message was refused. The text goes to the
    /// console.
    Error {
        message: String,
    },
}

/// Which device went off. The scene's own two kinds, and the only two a client may
/// report: a mod's own device has its own channel to invent (M19g).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum BlastKind {
    Mine,
    Trap,
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
    /// Thrown by a blast (M19c): the arc is the owner's, and everyone else sees it
    /// as this gait plus the fraction through it.
    Flung,
    Sleep,
    Eat,
    Dead,
    /// Powered flight (protocol 12): a loop, with the attitude in `pitch`/`roll` and
    /// the height above the ground in `py`.
    Fly,
    /// Released free fall (protocol 12): a one-shot, posed from its own progress.
    Fall,
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
    /// How far above the ground the goat is, in metres (M19f). It is the arc's height
    /// and it is *not* eased on arrival, for the reason the arc is absolute: easing a
    /// parabola flattens its apex, so a flung peer would fly through a lower arc than
    /// the one its owner simulated. Zero is every other gait.
    pub py: f32,
    /// The flyer's nose-up angle, in degrees (protocol 12). Zero when grounded, which
    /// is why it is defaulted for the JSON bridge; the datagram path is positional
    /// and versioned, so a missing field there is a refusal.
    #[serde(default)]
    pub pitch: i8,
    /// The flyer's right-bank angle, in degrees. See [`PeerState::pitch`].
    #[serde(default)]
    pub roll: i8,
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
            && self.py.is_finite()
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
    /// How far above the ground the bot is, in **centimetres** (M19f): the flung arc's
    /// height, which is the one thing `Gait::Flung` and a phase could not say. It is
    /// the scene's own `py` -- a height above the terrain directly below, so a client
    /// with the same ground (which the snapshot's craters give it) puts the bot where
    /// the host had it. Zero for every grounded gait, which is why it costs a byte
    /// rather than two on the wire; signed, because the ground can move under a bot
    /// between snapshots (a crater opens where it was standing) and a height that has
    /// gone slightly negative is a bot standing in a hole rather than a wrapped one.
    ///
    /// `serde(default)` is for the *JSON* bridges only -- the scene hands the host a
    /// world, and the host hands the scene one back, so a payload without the field is
    /// a grounded bot, which is what zero means. The datagram path is positional and
    /// versioned (`PROTOCOL_VERSION`), which is where a missing field is a refusal
    /// rather than a default.
    #[serde(default)]
    pub py: i16,
    /// The flyer's nose-up angle, in degrees (protocol 12): the one part of an attitude
    /// that `Gait::Fly` and a height could not say. Zero for every grounded gait.
    #[serde(default)]
    pub pitch: i8,
    /// The flyer's right-bank angle, in degrees. See [`BotState::pitch`].
    #[serde(default)]
    pub roll: i8,
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

/// One crater on the ground (M19d/M19e): where, how wide, and how deep it is *right
/// now*. `depth` is the live value rather than the depth it was dug at, because a
/// client mirrors the ground instead of healing it -- the host heals, and every
/// snapshot carries the dish as it stands. The raised lip is not here: it is
/// `TUNING.explosions.crater.lip`, which both ends share (a world mod's tuning is part
/// of its hash).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct Crater {
    pub x: f32,
    pub z: f32,
    pub r: f32,
    /// Metres deep at the centre, now: it eases to zero as the crater heals.
    pub depth: f32,
}

impl Crater {
    pub fn is_finite(&self) -> bool {
        self.x.is_finite() && self.z.is_finite() && self.r.is_finite() && self.depth.is_finite()
    }
}

/// A device that has gone off: its packed cell key and which kind it was. The scene
/// keeps mines and trapped tufts in separate sets (a device that fires *moves*, and a
/// trap moves to a tuft), and so does this.
///
/// Where the device moved to is deliberately absent: the destination is derived from
/// the key that fired, so a client that has the key has the whole field -- which is
/// what keeps the move off the wire (see the device notes in ROADMAP.md).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Spent {
    pub key: i64,
    pub trap: bool,
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
/// the PRNG streams and the eaten meadow. A client that joins takes this whole
/// thing -- it does not keep the world it had generated before joining.
///
/// World-mod state is **not** here: it travels on its own datagram
/// ([`ModsState`]), so a mod publishing more than the world can carry degrades
/// that mod rather than the world.
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
    /// The craters on the ground. `None` means the snapshot could not carry them -- the
    /// world was over its datagram budget and this is a part that goes (see
    /// [`fit_world`]) -- and a client reads that as "keep the craters you have".
    /// All-or-nothing, never truncated: a crater is *geometry*, so a client missing one
    /// disagrees with the host about the ground under the goat and visibly stands in the
    /// air (or in the floor).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub craters: Option<Vec<Crater>>,
    /// The devices that have gone off, for the same reason and with the same `None`
    /// meaning. This is the part that goes *first* when the world is over budget: a
    /// client that misses one leaves a mine standing that the host has moved, which is
    /// noisy and survivable, and the next snapshot settles it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent: Option<Vec<Spent>>,
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
            && self
                .craters
                .as_deref()
                .unwrap_or_default()
                .iter()
                .all(Crater::is_finite)
    }

    /// The part of a snapshot that travels on part 0 alone: everything but the herd.
    pub fn head(&self) -> WorldHead {
        WorldHead {
            weather: self.weather.clone(),
            streams: self.streams,
            eaten: self.eaten.clone(),
            craters: self.craters.clone(),
            spent: self.spent.clone(),
        }
    }
}

/// The header of a world snapshot: the sky, the four PRNG streams and the sheddable state
/// (the meadow, the craters, the spent devices). It is [`WorldState`] minus the herd, and it
/// rides the *first* part of a split snapshot (see [`WorldPart`]) because the whole snapshot no
/// longer fits one datagram once the herd is at [`MAX_HERD`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WorldHead {
    pub weather: WeatherState,
    pub streams: Streams,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub eaten: Option<Vec<EatenCell>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub craters: Option<Vec<Crater>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub spent: Option<Vec<Spent>>,
}

impl WorldHead {
    pub fn is_finite(&self) -> bool {
        self.weather.is_finite()
            && self
                .eaten
                .as_deref()
                .unwrap_or_default()
                .iter()
                .all(EatenCell::is_finite)
            && self
                .craters
                .as_deref()
                .unwrap_or_default()
                .iter()
                .all(Crater::is_finite)
    }
}

/// One part of a split world snapshot.
///
/// A world is published as [`split_world`]'s parts, which together are *one* snapshot: part 0
/// carries the [`WorldHead`] and every part carries a contiguous slice of the herd, so a herd
/// too large for one datagram travels as several rather than as none -- the failure a single
/// over-budget datagram gives, since the transport will not fragment one. Every part states its
/// place: the snapshot's `seq`, which part it is of how many (`part`, `parts`), the herd's
/// total size (`herd`) and the index of its first bot (`first`).
///
/// The channel is lossy, so the sequence is monotone per host and a receiver drops a part older
/// than the snapshot it is gathering rather than applying it late; a snapshot whose parts do
/// not all arrive is simply not emitted (a partial snapshot is the bug, not the fix -- see
/// `466b967`), and at the host's ten-a-second cadence the next one is a hundred milliseconds
/// away. Keeping `parts` small matters for the same reason: a snapshot is only usable once
/// every part is in.
#[derive(Debug, Clone, PartialEq)]
pub struct WorldPart {
    pub seq: u32,
    pub part: u8,
    pub parts: u8,
    pub herd: u16,
    pub first: u16,
    pub head: Option<WorldHead>,
    pub bots: Vec<BotState>,
}

impl WorldPart {
    /// The whole `world` as one part: every bot, the header on part 0. Used to measure a world
    /// as a datagram and by tests; a published snapshot is [`split_world`]'s parts instead.
    pub fn whole(world: &WorldState, seq: u32) -> WorldPart {
        WorldPart {
            seq,
            part: 0,
            parts: 1,
            herd: world.bots.len() as u16,
            first: 0,
            head: Some(world.head()),
            bots: world.bots.clone(),
        }
    }

    pub fn is_finite(&self) -> bool {
        self.head.as_ref().is_none_or(WorldHead::is_finite)
            && self.bots.iter().all(BotState::is_finite)
    }
}

/// What every world mod contributes: `{ streams: {...}, data: { <id>: <published> } }`,
/// exactly the JSON the scene's `sceneWorldMods()` returns.
///
/// Opaque on purpose -- the transport has no schema for what a mod publishes, so
/// it carries the value and bounds it by the datagram cap -- and on a datagram of
/// its own, so that the world's budget cannot cap what a mod may say and a lost
/// one costs only a mod's state rather than everyone's world.
#[derive(Debug, Clone, PartialEq)]
pub struct ModsState(pub serde_json::Value);

/// What became of the world-mod datagram.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModsOutcome {
    /// Sent.
    Sent,
    /// Not sent: it does not fit one datagram. Because that datagram is every
    /// world mod at once, all of their state is held back until it shrinks -- the
    /// per-mod answer (a datagram each, so a greedy mod loses only its own state)
    /// is the next step.
    TooLarge { size: usize },
}

impl ModsOutcome {
    /// A one-line report for a log, or `None` when nothing went wrong.
    pub fn describe(&self) -> Option<String> {
        match self {
            ModsOutcome::Sent => None,
            ModsOutcome::TooLarge { size } => Some(format!(
                "the world-mod state is {size} bytes and does not fit its \
                 {MAX_DATAGRAM_BYTES}-byte datagram: a world mod is publishing too much"
            )),
        }
    }
}

/// Whether the world-mod state fits a datagram of its own.
///
/// There is nothing to shed inside it -- the transport cannot tell one mod's
/// contribution from another's -- so this is a size check and a report.
pub fn fit_mods(mods: &ModsState) -> ModsOutcome {
    match encode_datagram(&Datagram::Mods(mods.clone())) {
        Ok(bytes) if bytes.len() <= MAX_DATAGRAM_BYTES => ModsOutcome::Sent,
        Ok(bytes) => ModsOutcome::TooLarge { size: bytes.len() },
        Err(_) => ModsOutcome::TooLarge { size: usize::MAX },
    }
}

/// What became of a world snapshot on its way out of a host.
///
/// A snapshot that does not fit one datagram is not sent at all, so every way of
/// not sending it is named here rather than dropped in silence: the datagram
/// channel is fire-and-forget, and "the clients stopped receiving the world" is
/// invisible otherwise.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorldOutcome {
    /// Sent whole.
    Whole,
    /// Sent without some of the parts that can be given up. Each flag says whether that
    /// part was left out -- the parts go in one order, least essential first (see
    /// [`fit_world`]), so this is a prefix of `spent`, `meadow`, `craters`.
    Shed {
        spent: bool,
        meadow: bool,
        craters: bool,
    },
    /// Not sent: it does not fit even with all three gone. `size` is what the bots,
    /// the sky and the streams alone come to.
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
            WorldOutcome::Shed {
                spent,
                meadow,
                craters,
            } => {
                let mut parts = Vec::new();
                if *spent {
                    parts.push("the spent devices");
                }
                if *meadow {
                    parts.push("the meadow");
                }
                if *craters {
                    parts.push("the craters");
                }
                Some(format!(
                    "the world is over the {MAX_DATAGRAM_BYTES}-byte datagram budget: {} \
                     left out",
                    parts.join(" and ")
                ))
            }
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

/// Trims `world` until it can be published as parts, and says what it had to give up.
///
/// The bots, the sky and the streams are the world itself -- a client that stops
/// receiving them freezes at the last snapshot it got -- and a world mod's state is not
/// on this datagram at all (see [`ModsState`]). Everything else can be given up, and it
/// goes in one order, **least essential first**:
///
/// 1. the spent devices -- a client that misses one leaves a mine standing that the
///    host has moved: noisy, survivable, and self-correcting on the next snapshot;
/// 2. the meadow -- content: a client with a tuft the host has eaten can eat it, report
///    it, and be corrected;
/// 3. the craters -- which go last of the three because a crater is *geometry*: a client
///    missing one disagrees with the host about the ground under the goat, and the goat
///    visibly stands in the air or in the floor.
///
/// Each of the three is all-or-nothing rather than truncated. A client's `applyEaten`
/// replaces its whole map and its crate list replaces its whole list, so a short one
/// would resurrect every cell left out of it. A refused world is handed back untouched,
/// so the reported `TooLarge` size is what the parts that can never be shed come to on
/// their own.
///
/// "Fits" now means the snapshot can go out as its parts ([`split_world`]), not that it is
/// under one datagram: the herd is never shed, so at [`MAX_HERD`] the bots alone are over
/// [`MAX_WORLD_PART_BYTES`] and the snapshot is three part-datagrams rather than a refused one.
/// The three shedables still ride part 0, and `budget` is what *every* part is measured against --
/// the host passes [`MAX_WORLD_PART_BYTES`], so the shed threshold is one *part*, which is smaller
/// than the one-datagram budget a world was measured against before the herd was split. A meadow
/// therefore gives way sooner than it did; it is content rather than geometry and it self-corrects,
/// which is why it is shed before the craters.
pub fn fit_world(world: &mut WorldState, budget: usize) -> WorldOutcome {
    if !world.is_finite() {
        return WorldOutcome::NotFinite;
    }
    if fits(world, budget) {
        return WorldOutcome::Whole;
    }

    let spent = world.spent.take();
    if fits(world, budget) {
        return WorldOutcome::Shed {
            spent: spent.is_some(),
            meadow: false,
            craters: false,
        };
    }

    let meadow = world.eaten.take();
    if fits(world, budget) {
        return WorldOutcome::Shed {
            spent: spent.is_some(),
            meadow: meadow.is_some(),
            craters: false,
        };
    }

    let craters = world.craters.take();
    if fits(world, budget) {
        return WorldOutcome::Shed {
            spent: spent.is_some(),
            meadow: meadow.is_some(),
            craters: craters.is_some(),
        };
    }

    world.spent = spent;
    world.eaten = meadow;
    world.craters = craters;
    WorldOutcome::TooLarge {
        size: bare_size(world),
    }
}

/// Whether `world` can go out as parts: its herd splits within [`MAX_WORLD_PARTS`] and every
/// part is within `budget`. The herd is measured and packed by the real encoder, not an
/// estimate -- a part's cost depends on its bots' varints.
fn fits(world: &WorldState, budget: usize) -> bool {
    match split_world(world, 0) {
        Ok(parts) => parts.iter().all(|part| part_size(part) <= budget),
        Err(_) => false,
    }
}

/// Splits `world` into the parts that carry it, or refuses when the herd cannot be split within
/// [`MAX_WORLD_PARTS`] parts.
///
/// The herd is packed greedily, each part measured with the real encoder against
/// [`MAX_WORLD_PART_BYTES`], so a hundred goats at the ceiling become about three parts of about
/// six hundred bytes each rather than one datagram at the budget's edge (or, on a narrow
/// path, none at all). Part 0 carries the [`WorldHead`] -- the sky, the streams and the
/// sheddable state it is left with -- and every part carries a slice of the herd from `first`.
/// The sheddables are measured *with* part 0, so a meadow the first part cannot carry is what
/// makes [`fit_world`] shed it rather than something that overflows after the bots are placed.
///
/// `Err` is [`WorldOutcome::TooLarge`] naming the bare size (the header and every bot), which is
/// what [`fit_world`] reports and what a reader needs when a snapshot is refused.
pub fn split_world(world: &WorldState, seq: u32) -> Result<Vec<WorldPart>, WorldOutcome> {
    pack_herd(world, seq).map_err(|size| WorldOutcome::TooLarge { size })
}

/// Reassembles the parts of one snapshot into the whole world, or `None` when they are not a
/// complete, consistent snapshot: a missing part, a part 0 with no header, parts that disagree
/// on the snapshot's sequence or the herd, or a herd whose bot indices are not `0..herd`.
///
/// This is what makes a partial snapshot *not* a world. A snapshot carrying fewer bots than the
/// host has would faithfully shrink the mirror, which is the bug this exists to prevent
/// (`466b967`), not the fix; so a receiver emits nothing until every part of a snapshot is in.
pub fn join_world(parts: &[WorldPart]) -> Option<WorldState> {
    let count = parts.iter().map(|part| part.parts).max()?;
    if count == 0 || parts.len() != count as usize {
        return None;
    }
    let first = parts.iter().find(|part| part.part == 0)?;
    let seq = first.seq;
    let herd = first.herd;
    let head = first.head.clone()?;
    let mut seen = vec![false; count as usize];
    let mut bots = Vec::new();
    for part in parts {
        let at = part.part as usize;
        if at >= count as usize || seen[at] || part.seq != seq || part.herd != herd {
            return None;
        }
        seen[at] = true;
        bots.extend(part.bots.iter().cloned());
    }
    if seen.iter().any(|seen| !seen) || bots.len() != herd as usize {
        return None;
    }
    bots.sort_by_key(|bot| bot.index);
    if bots
        .iter()
        .enumerate()
        .any(|(at, bot)| bot.index as usize != at)
    {
        return None;
    }
    Some(WorldState {
        bots,
        weather: head.weather,
        streams: head.streams,
        eaten: head.eaten,
        craters: head.craters,
        spent: head.spent,
    })
}

/// Packs the herd into parts, each measured to [`MAX_WORLD_PART_BYTES`], the header and the
/// world's sheddable state on part 0. Returns the bare size when the herd needs more than
/// [`MAX_WORLD_PARTS`] parts, or no bot fits a part.
fn pack_herd(world: &WorldState, seq: u32) -> Result<Vec<WorldPart>, usize> {
    let herd = world.bots.len();
    let mut parts: Vec<WorldPart> = Vec::new();
    let mut at = 0usize;
    // An empty herd still needs one part: it is the header and "no bots", which is a world a
    // client has to act on (`466b967`), not nothing to send.
    while at < herd || parts.is_empty() {
        let mut part = WorldPart {
            seq,
            part: 0,
            parts: 1,
            herd: herd as u16,
            first: at as u16,
            head: parts.is_empty().then(|| world.head()),
            bots: Vec::new(),
        };
        while at < herd {
            part.bots.push(world.bots[at].clone());
            if part_size(&part) > MAX_WORLD_PART_BYTES {
                part.bots.pop();
                break;
            }
            at += 1;
        }
        // A part that cannot hold even one bot is the *header's* problem -- a meadow the first
        // part cannot carry, which `fit_world` sheds -- or, with no bot in a later part, the
        // herd's. Either way a herd is all-or-nothing: never drop a bot to make the count work.
        if part.bots.is_empty() && at < herd {
            return Err(bare_size(world));
        }
        parts.push(part);
        if parts.len() > MAX_WORLD_PARTS as usize {
            return Err(bare_size(world));
        }
    }
    let count = parts.len() as u8;
    for (index, part) in parts.iter_mut().enumerate() {
        part.part = index as u8;
        part.parts = count;
    }
    Ok(parts)
}

/// What `world` comes to as one encoded datagram, or `usize::MAX` when it cannot
/// be encoded at all -- which is a size nothing fits rather than a size of zero.
fn datagram_size(world: &WorldState) -> usize {
    part_size(&WorldPart::whole(world, 0))
}

/// One part's size on the wire.
fn part_size(part: &WorldPart) -> usize {
    match encode_datagram(&Datagram::World(part.clone())) {
        Ok(bytes) => bytes.len(),
        Err(_) => usize::MAX,
    }
}

/// What the never-sheddable part of `world` comes to: the header and every bot, no meadow, no
/// craters, no spent devices.
fn bare_size(world: &WorldState) -> usize {
    let mut probe = world.clone();
    probe.eaten = None;
    probe.craters = None;
    probe.spent = None;
    datagram_size(&probe)
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

/// One datagram. The transform channel carries four kinds of traffic -- a
/// player's own goat, relayed between peers; the server's world; the world mods'
/// state; and voice -- so the payload is tagged. Only the server may send
/// [`Datagram::World`] or [`Datagram::Mods`]; a client that sends one has it
/// dropped rather than forwarded.
///
/// The tag is one byte on the wire ([`encode_datagram`]); this enum is the
/// vocabulary, not the encoding.
#[derive(Debug, Clone, PartialEq)]
pub enum Datagram {
    Peer(PeerFrame),
    World(WorldPart),
    Mods(ModsState),
    Voice(VoiceFrame),
}

impl Datagram {
    /// Whether every number in it is finite. A NaN or an infinity would poison
    /// every peer's interpolation, so the encoder refuses one outright and the
    /// receivers refuse to relay one.
    pub fn is_finite(&self) -> bool {
        match self {
            Datagram::Peer(frame) => frame.state.is_finite(),
            Datagram::World(part) => part.is_finite(),
            // A mod's payload is JSON: it cannot carry a NaN (`JSON.stringify`
            // would have written `null`), and the transport does not look inside
            // it anyway.
            Datagram::Mods(_) | Datagram::Voice(_) => true,
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
/// hands Rust JSON. A world part is also checked against [`MAX_HERD`] and
/// [`MAX_WORLD_PARTS`] here, on *decode*, because this is the one place a peer's bytes
/// become typed: it bounds what a client will allocate for a herd it is told to hold, and
/// it is what makes [`MAX_HERD`] the ceiling for `goatsd --herd` and the chunker rather
/// than only a client-side clamp.
pub fn decode_datagram(payload: &[u8]) -> Result<Datagram, Error> {
    let packed: wire::WireDatagram =
        postcard::from_bytes(payload).map_err(|error| Error::Decode(error.to_string()))?;
    let datagram = packed.unpack()?;
    if let Datagram::World(part) = &datagram {
        if part.herd as usize > MAX_HERD || part.bots.len() > MAX_HERD {
            return Err(Error::Decode(format!(
                "the herd is {} bots, over the {MAX_HERD} ceiling",
                part.herd
            )));
        }
        if part.parts == 0 || part.parts > MAX_WORLD_PARTS || part.part >= part.parts {
            return Err(Error::Decode(format!(
                "a world part is {} of {}, over the {MAX_WORLD_PARTS}-part ceiling",
                part.part, part.parts
            )));
        }
    }
    Ok(datagram)
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
        assert!(compare_world_mods(std::slice::from_ref(&a), std::slice::from_ref(&a)).is_empty());

        let missing = compare_world_mods(&[a.clone(), b.clone()], std::slice::from_ref(&a));
        assert_eq!(missing.missing, vec!["com.b".to_string()]);
        assert!(missing.extra.is_empty());
        assert!(missing.describe().contains("missing com.b"));
        // Every refusal opens with the marker, which is what lets a client
        // recognise one without the protocol carrying a kind (M18d).
        assert!(missing.describe().starts_with(MISMATCH_PREFIX));

        let extra = compare_world_mods(std::slice::from_ref(&a), &[a.clone(), b.clone()]);
        assert_eq!(extra.extra, vec!["com.b".to_string()]);

        let changed = ModRef {
            id: "com.a".to_string(),
            version: "2".to_string(),
            hash: 1,
        };
        let differing = compare_world_mods(std::slice::from_ref(&a), &[changed]);
        assert_eq!(differing.differing.len(), 1);
        assert_eq!(differing.differing[0].id, "com.a");
        // Both sides are in the line, because "differing" alone is the refusal
        // nobody can act on -- the usual cause is the same content hashed on two
        // platforms, which the id cannot show.
        let text = differing.describe();
        assert!(
            text.contains("differing com.a (host 1#0000000000000001"),
            "{text}"
        );
        assert!(text.contains("you 2#0000000000000001"), "{text}");

        // The same set renders as one line, for a startup log.
        assert_eq!(describe_mods(&[]), "none");
        assert_eq!(
            describe_mods(std::slice::from_ref(&a)),
            "com.a@1#0000000000000001"
        );
        assert_eq!(
            describe_mods(&[a, b]),
            "com.a@1#0000000000000001 com.b@1#0000000000000002"
        );

        // A hostile id is cleaned for the message, not for the comparison.
        let hostile = ModRef {
            id: "\u{1b}[31mEVIL".to_string(),
            version: "1".to_string(),
            hash: 9,
        };
        let cleaned = compare_world_mods(&[], &[hostile]);
        assert_eq!(cleaned.extra, vec!["31mEVIL".to_string()]);
        assert!(cleaned.describe().starts_with(MISMATCH_PREFIX));

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
                py: 0.0,
                pitch: 20,
                roll: -15,
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
            py: 0.0,
            pitch: 0,
            roll: 0,
        };
        assert!(state.is_finite());
        state.x = f32::NAN;
        assert!(!state.is_finite());
        state.x = 0.0;
        state.py = f32::NAN;
        assert!(!state.is_finite());
        state.py = 0.0;
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
        // round trip of the *envelope*: the variant, the field set, the sky and
        // the streams. Positions land on 1 cm, yaw on 1/10000 of a turn, `left`
        // on a quarter second, so any two-decimal value is exact.
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
                    py: 0,
                    pitch: 0,
                    roll: 0,
                },
                BotState {
                    index: 1,
                    x: 2.75,
                    z: 3.25,
                    yaw: 1.0,
                    phase: on_the_phase_grid(0.25),
                    gait: Gait::Eat,
                    variant: 1,
                    py: 0,
                    pitch: 0,
                    roll: 0,
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
            craters: Some(vec![
                Crater {
                    x: 1.23,
                    z: -4.56,
                    r: 1.6,
                    depth: 0.45,
                },
                Crater {
                    x: -7.0,
                    z: 2.0,
                    r: 1.4,
                    depth: 0.2,
                },
            ]),
            spent: Some(vec![
                Spent {
                    key: 33_570_816,
                    trap: false,
                },
                Spent {
                    key: 33_570_817,
                    trap: true,
                },
            ]),
        };
        let datagram = Datagram::World(WorldPart::whole(&world, 7));
        let bytes = encode_datagram(&datagram).expect("encode");
        assert_eq!(decode_datagram(&bytes).expect("decode"), datagram);
        assert!(world.is_finite());

        // A split snapshot round-trips part for part, and `join_world` puts the herd back
        // together: this is the shape a hundred goats travel in.
        let parts = split_world(&world, 9).expect("split");
        for part in &parts {
            let bytes = encode_datagram(&Datagram::World(part.clone())).expect("encode");
            assert_eq!(
                &decode_datagram(&bytes).expect("decode"),
                &Datagram::World(part.clone())
            );
        }
        let reassembled: Vec<WorldPart> = parts
            .iter()
            .map(|part| {
                match decode_datagram(&encode_datagram(&Datagram::World(part.clone())).unwrap())
                    .unwrap()
                {
                    Datagram::World(part) => part,
                    other => panic!("expected a world part, got {other:?}"),
                }
            })
            .collect();
        assert_eq!(join_world(&reassembled).as_ref(), Some(&world));

        // A world mod's state rides its own datagram, and the transport does not
        // look inside it: it is the scene's JSON, round-tripped as bytes.
        let mods = Datagram::Mods(a_mods_state());
        let bytes = encode_datagram(&mods).expect("encode");
        assert_eq!(decode_datagram(&bytes).expect("decode"), mods);

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
                py: 2.5,
                pitch: 10,
                roll: -10,
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
    /// cells, a handful of craters and the devices that have gone off. The sizes
    /// are the real ones -- this is the fixture the datagram budget is argued
    /// about with.
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
            craters: Some(craters(8)),
            spent: Some(spent_devices(6)),
        }
    }

    /// Eight craters, spread over the field the way a few minutes of walking a
    /// minefield leaves them.
    fn craters(count: usize) -> Vec<Crater> {
        (0..count)
            .map(|i| Crater {
                x: -12.0 + i as f32 * 3.25,
                z: 6.5 - i as f32 * 2.0,
                r: 1.4 + 0.05 * (i % 6) as f32,
                depth: 0.45 - 0.1 * (i % 4) as f32,
            })
            .collect()
    }

    /// The devices a session has set off so far: four-byte keys, which is what a
    /// packed cell key costs as a `postcard` varint.
    fn spent_devices(count: usize) -> Vec<Spent> {
        (0..count as i64)
            .map(|i| Spent {
                key: 33_570_816 + i * 8192,
                trap: i % 3 == 0,
            })
            .collect()
    }

    /// What a world mod publishes: the `birds` flock, as `sceneWorldMods()`
    /// shapes it -- a stream state per mod and a row per entity.
    fn a_mods_state() -> ModsState {
        ModsState(serde_json::json!({
            "streams": { "com.github.sdgoij.goats.birds:flock": 1_234_567 },
            "data": { "com.github.sdgoij.goats.birds": [
                [20.0, 9.0, -20.0, 0.5, 3.0],
                [26.0, 9.0, -26.0, 0.5, 3.0],
            ]},
        }))
    }

    /// A bot as the scene sends one. Flung, because that is the row the height field
    /// exists for: the shed-order cases below want a bot with every field populated.
    fn bot(index: u16) -> BotState {
        BotState {
            index,
            x: 1.234 + f32::from(index),
            z: -12.345 - f32::from(index),
            yaw: 0.5,
            phase: 0.123,
            gait: Gait::Walk,
            variant: 1,
            py: 250,
            pitch: 25,
            roll: -25,
        }
    }

    #[test]
    fn an_over_budget_world_sheds_in_the_documented_order() {
        // Least essential first, and each step is met by a budget only that step can
        // reach: the spent devices, then the meadow, then the craters.
        let full = a_running_world(10);

        let spent_only = {
            let mut probe = full.clone();
            probe.spent = None;
            datagram_size(&probe)
        };
        let mut world = full.clone();
        let outcome = fit_world(&mut world, spent_only);
        assert_eq!(
            outcome,
            WorldOutcome::Shed {
                spent: true,
                meadow: false,
                craters: false
            }
        );
        assert!(world.spent.is_none(), "the spent devices go first");
        assert!(world.eaten.is_some(), "the meadow is still there");
        assert!(world.craters.is_some(), "and so are the craters");
        assert!(outcome.describe().is_some_and(|t| t.contains("spent")));

        let meadow_too = {
            let mut probe = full.clone();
            probe.spent = None;
            probe.eaten = None;
            datagram_size(&probe)
        };
        let mut world = full.clone();
        let outcome = fit_world(&mut world, meadow_too);
        assert_eq!(
            outcome,
            WorldOutcome::Shed {
                spent: true,
                meadow: true,
                craters: false
            }
        );
        assert!(world.eaten.is_none(), "then the meadow");
        assert!(
            world.craters.is_some(),
            "the craters are geometry, so they go last of the three"
        );
        assert!(outcome.describe().is_some_and(|t| t.contains("meadow")));

        let everything = {
            let mut probe = full.clone();
            probe.spent = None;
            probe.eaten = None;
            probe.craters = None;
            datagram_size(&probe)
        };
        let mut world = full.clone();
        let outcome = fit_world(&mut world, everything);
        assert_eq!(
            outcome,
            WorldOutcome::Shed {
                spent: true,
                meadow: true,
                craters: true
            }
        );
        assert!(world.craters.is_none(), "and the craters, at the last");
        assert_eq!(world.bots.len(), 7, "the bots are never shed");
        assert!(datagram_size(&world) <= everything);
    }

    #[test]
    fn a_big_meadow_is_what_makes_the_snapshot_shed() {
        // The shed path is still the safety net, and a long session with several
        // players eating is how it is reached: 260 cells is a meadow well past the
        // point where the world fits. The spent devices and the meadow are enough
        // to get under the budget, which is what the order is for -- the craters
        // stay, because a client missing one stands in the air.
        let world = a_running_world(260);
        let full = datagram_size(&world);
        assert!(full > MAX_DATAGRAM_BYTES, "{full} bytes");

        let mut world = world;
        let outcome = fit_world(&mut world, MAX_DATAGRAM_BYTES);
        assert!(matches!(outcome, WorldOutcome::Shed { .. }), "{outcome:?}");
        assert!(world.spent.is_none(), "the spent devices go first");
        assert!(world.eaten.is_none(), "then the meadow");
        assert_eq!(world.bots.len(), 7, "the bots are never shed");
        assert!(datagram_size(&world) <= MAX_DATAGRAM_BYTES);
        assert!(outcome.describe().is_some());
    }

    #[test]
    fn a_world_at_the_herd_ceiling_splits_within_the_budget() {
        // The invariant the budget exists for, restated for parts: at the ceiling -- the herd at
        // `MAX_HERD`, every bot flung, sixteen craters, twelve spent devices and a meadow -- the
        // snapshot goes out whole and *every emitted part* fits the packing budget. `fit_world`
        // never sheds a bot, so a herd the parts could not carry would refuse the whole world
        // (the frozen herd) rather than shrink it.
        let mut world = a_running_world(10);
        world.bots = (0..MAX_HERD as u16)
            .map(|index| {
                let mut bot = bot(index);
                bot.gait = Gait::Flung;
                bot.py = 250;
                bot
            })
            .collect();
        world.craters = Some(craters(16));
        world.spent = Some(spent_devices(12));

        assert_eq!(
            fit_world(&mut world, MAX_WORLD_PART_BYTES),
            WorldOutcome::Whole,
            "the budget carries the ceiling"
        );

        let parts = split_world(&world, 0).expect("the herd splits");
        // More than one part at the ceiling: this is the chunking, not a raise of the budget --
        // a hundred goats do not fit one datagram at the headroom a part is packed for.
        assert!(
            parts.len() >= 2,
            "the ceiling needs its herd split: {} part(s)",
            parts.len()
        );
        assert!(parts.len() <= MAX_WORLD_PARTS as usize);
        for part in &parts {
            let size = part_size(part);
            assert!(
                size <= MAX_WORLD_PART_BYTES,
                "a part is {size} bytes, over the {MAX_WORLD_PART_BYTES}-byte budget"
            );
        }
        // The herd is all there and comes back whole: never a partial snapshot.
        let joined = join_world(&parts).expect("the parts are one snapshot");
        assert_eq!(joined.bots.len(), MAX_HERD);
        assert_eq!(joined, world);
    }

    #[test]
    fn an_over_ceiling_herd_is_refused_at_decode() {
        // The ceiling belongs in `proto` because it is the one language the JavaScript and
        // the GDScript cannot read, and it is enforced where a peer's bytes become typed: a
        // payload claiming a herd over `MAX_HERD` is an error, not an allocation. This is what
        // makes `goatsd --herd`'s validation and the chunker's bound one number rather than
        // two, and it is a bad peer's problem rather than a client's.
        let head = a_running_world(0).head();
        let mut over = WorldPart {
            seq: 1,
            part: 0,
            parts: 1,
            herd: MAX_HERD as u16 + 1,
            first: 0,
            head: Some(head.clone()),
            bots: Vec::new(),
        };
        let bytes = encode_datagram(&Datagram::World(over.clone())).expect("encode");
        let error = decode_datagram(&bytes).expect_err("a herd over the ceiling is refused");
        assert!(matches!(error, Error::Decode(_)), "{error:?}");
        assert!(error.to_string().contains("ceiling"), "{error}");

        // The ceiling itself is not over it: a boundary, not an off-by-one.
        over.herd = MAX_HERD as u16;
        let bytes = encode_datagram(&Datagram::World(over)).expect("encode");
        assert!(decode_datagram(&bytes).is_ok());
    }

    #[test]
    fn a_crater_costs_the_bytes_the_budget_claims() {
        // `postcard` varints its integers, so a crater is *at most* its four `i16`
        // fields (eight bytes) and a spent device at most a four-byte key plus a bool
        // -- and in practice less, because a 45 cm depth and a 1.4 m radius are small
        // numbers. This is the upper bound the budget table in ROADMAP.md argues about,
        // asserted so the table cannot quietly become wrong.
        let mut world = a_running_world(10);
        world.craters = Some(Vec::new());
        world.spent = Some(Vec::new());
        let empty = datagram_size(&world);

        world.craters = Some(craters(16));
        let with_craters = datagram_size(&world) - empty;
        assert!(
            with_craters <= 16 * 8,
            "16 craters cost {with_craters} bytes, over the {}-byte bound",
            16 * 8
        );

        world.craters = Some(Vec::new());
        world.spent = Some(spent_devices(12));
        let with_spent = datagram_size(&world) - empty;
        assert!(
            with_spent <= 12 * 5,
            "12 spent devices cost {with_spent} bytes, over the {}-byte bound",
            12 * 5
        );
    }

    #[test]
    fn a_world_the_bots_alone_cannot_fit_is_refused_untouched() {
        let mut world = a_running_world(10);
        let before = world.clone();
        let bare = {
            let mut probe = world.clone();
            probe.spent = None;
            probe.eaten = None;
            probe.craters = None;
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
        let shed_bytes =
            encode_datagram(&Datagram::World(WorldPart::whole(&shed, 0))).expect("encode");
        match decode_datagram(&shed_bytes).expect("decode") {
            Datagram::World(part) => assert_eq!(part.head.expect("a head").eaten, None),
            other => panic!("expected a world, got {other:?}"),
        }

        let mut empty = a_running_world(3);
        empty.eaten = Some(Vec::new());
        let empty_bytes =
            encode_datagram(&Datagram::World(WorldPart::whole(&empty, 0))).expect("encode");
        match decode_datagram(&empty_bytes).expect("decode") {
            Datagram::World(part) => {
                assert_eq!(part.head.expect("a head").eaten, Some(Vec::new()))
            }
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
    fn the_vanilla_world_fits_with_room_to_spare() {
        // The common mod-free world: the default herd and a meadow well along. Under JSON this
        // was 1600 bytes and climbing against a 1200-byte cap; binary and quantized it fits
        // whole, with most of the budget still free. This is the guard that the budget does not
        // *erode* -- the next field added to `WorldState` has to argue for its bytes.
        //
        // `a_world_at_the_herd_ceiling_splits_within_the_budget` above is the other half: the
        // same shape with the herd at `MAX_HERD`, which splits into parts rather than shrinking
        // the herd -- which is why the ceiling could be raised to a hundred without raising the
        // budget out from under it.
        //
        // The water (M20) is the third system to argue for none: the level is a
        // function of the seed's rain on both ends rather than a state, so nothing
        // about it is in `WorldState` at all, and the scene holds the other half of
        // that claim (`water.rs`'s `the_world_snapshot_carries_no_water`, which pins
        // the keys a host actually publishes).
        let mut world = a_running_world(20);
        let size = datagram_size(&world);
        assert_eq!(
            fit_world(&mut world, MAX_DATAGRAM_BYTES),
            WorldOutcome::Whole,
            "{size} bytes"
        );
        assert!(world.eaten.is_some(), "nothing had to be shed");
        assert!(
            size < MAX_DATAGRAM_BYTES / 3,
            "{size} bytes of a {MAX_DATAGRAM_BYTES}-byte budget"
        );
    }

    #[test]
    fn a_world_mods_state_has_a_datagram_of_its_own() {
        // The mods are not on the world's datagram at all, which is the point:
        // they cannot push the world out, and the world's cap cannot bound what a
        // mod publishes. Both travel whole, and the flock's state is the same
        // bytes either way.
        let world = a_running_world(20);
        let mods = a_mods_state();
        assert_eq!(fit_mods(&mods), ModsOutcome::Sent);
        assert_eq!(ModsOutcome::Sent.describe(), None);

        let round_tripped =
            decode_datagram(&encode_datagram(&Datagram::Mods(mods.clone())).expect("encode"))
                .expect("decode");
        assert_eq!(round_tripped, Datagram::Mods(mods));

        // A world that is at its limit still leaves the mods alone. A byte over the
        // budget sheds the spent devices (they are the cheapest thing to lose) and
        // nothing else.
        let mut tight = world;
        let budget = datagram_size(&tight) - 1;
        assert_eq!(
            fit_world(&mut tight, budget),
            WorldOutcome::Shed {
                spent: true,
                meadow: false,
                craters: false
            }
        );
        assert_eq!(fit_mods(&a_mods_state()), ModsOutcome::Sent);
    }

    #[test]
    fn an_over_budget_mods_state_is_reported_rather_than_dropped_in_silence() {
        // There is nothing to shed inside it -- the transport cannot tell one
        // mod's contribution from another's -- so the report is all the caller
        // gets, and it has to name the size.
        let big = ModsState(serde_json::json!({
            "streams": {},
            "data": { "com.example.big": { "blob": "x".repeat(MAX_DATAGRAM_BYTES) } },
        }));
        let outcome = fit_mods(&big);
        match outcome {
            ModsOutcome::TooLarge { size } => {
                assert!(size > MAX_DATAGRAM_BYTES, "{size} bytes");
                assert!(
                    outcome
                        .describe()
                        .is_some_and(|text| text.contains(&size.to_string())),
                    "{outcome:?}"
                );
            }
            other => panic!("expected a refusal, got {other:?}"),
        }

        // And a state that fits is sent, so this is a check rather than a blanket
        // refusal.
        assert_eq!(fit_mods(&a_mods_state()), ModsOutcome::Sent);
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
                    py: 0.0,
                    pitch: 0,
                    roll: 0,
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

    fn record() -> ModRecord {
        ModRecord {
            id: "com.example.birds".to_string(),
            version: "1.2.0".to_string(),
            api: 1,
            side: ModSide::World,
            hash: 0xabc,
            root: [7u8; 32],
            size: 1024,
            author: [9u8; 32],
        }
    }

    #[test]
    fn a_record_names_the_join_identity() {
        let record = record();
        assert_eq!(
            record.reference(),
            ModRef {
                id: "com.example.birds".to_string(),
                version: "1.2.0".to_string(),
                hash: 0xabc,
            }
        );
    }

    #[test]
    fn a_record_round_trips_and_is_cleaned() {
        let payload = postcard::to_allocvec(&record()).expect("encode");
        let decoded: ModRecord = postcard::from_bytes(&payload).expect("decode");
        assert_eq!(decoded, record());

        let padded = ModRecord {
            id: "  com.example.birds ".to_string(),
            version: " 1.2.0 ".to_string(),
            ..record()
        };
        assert_eq!(padded.clean(), Some(record()));
    }

    #[test]
    fn a_hostile_record_is_refused() {
        // Every cap has to hold, because a record is displayed and becomes a
        // directory name once it is installed.
        for broken in [
            ModRecord {
                id: String::new(),
                ..record()
            },
            ModRecord {
                id: "../../escape".to_string(),
                ..record()
            },
            ModRecord {
                id: "x".repeat(MAX_RECORD_ID_CHARS + 1),
                ..record()
            },
            ModRecord {
                version: String::new(),
                ..record()
            },
            ModRecord {
                version: "1\n2".to_string(),
                ..record()
            },
            ModRecord {
                version: "v".repeat(MAX_RECORD_VERSION_CHARS + 1),
                ..record()
            },
            ModRecord { api: 0, ..record() },
            ModRecord {
                root: [0u8; 32],
                ..record()
            },
            ModRecord {
                author: [0u8; 32],
                ..record()
            },
            ModRecord {
                size: MAX_PACKAGE_BYTES + 1,
                ..record()
            },
        ] {
            assert!(broken.clone().clean().is_none(), "accepted {broken:?}");
        }
        assert!(ModHave { root: [0u8; 32] }.clean().is_none());
        assert!(ModHave { root: [1u8; 32] }.clean().is_some());
    }
}
