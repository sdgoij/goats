//! The line protocol between a game scene and its networking host.
//!
//! The scene has no sockets: it queues intents as JSON lines and receives JSON
//! events back. The native client (`crates/goats/src/net.rs`, and the Godot
//! port's own bridge) speaks this; so does the browser gateway, which is why
//! the types live here rather than in one client. A browser tab sends the same
//! `Command` lines over a WebSocket and gets the same `Event` lines back.
//!
//! The shapes are the contract: `type` is the serde tag, fields stay camel or
//! snake exactly as the scene reads them, and `to_event` is the one translation
//! from the session's Rust event.

use serde::{Deserialize, Serialize};

/// An intent from the scene.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Command {
    /// Host a session as `name`; blank means the protocol default.
    Host {
        #[serde(default)]
        name: String,
    },
    /// Join the session behind `ticket` as `name`. `pull` asks the native
    /// client to fetch the host's world mods and retry once when the join is
    /// refused because they differ (M18d). `mods` is the world-mod set the
    /// caller presents; the native client derives it from its loader and ignores
    /// the field, while a browser gateway has no loader and reads it here.
    Join {
        ticket: String,
        name: String,
        #[serde(default)]
        pull: bool,
        #[serde(default, deserialize_with = "mod_refs")]
        mods: Vec<crate::ModRef>,
    },
    /// Say something. A leading `@name` whispers; the server routes it.
    Say { text: String },
    /// The local goat's pose, sent on the unreliable transform channel. Queued
    /// by the scene at a fraction of the frame rate, not every frame.
    Pose {
        x: f32,
        z: f32,
        yaw: f32,
        phase: f32,
        #[serde(default)]
        speed: f32,
        gait: String,
        /// How far above the ground this goat is, in metres (M19f): the flung arc's
        /// height. Defaulted, so a scene that does not carry it still parses -- the
        /// field is what a *version 10* scene sends, and the version handshake is what
        /// makes that a promise rather than a hope.
        #[serde(default)]
        py: f32,
        /// The flyer's attitude in **degrees** (protocol 12): nose-up is positive pitch,
        /// right-bank positive roll. Defaulted for the same reason `py` is; zero is a
        /// grounded goat, which is what every other gait means.
        #[serde(default)]
        pitch: f32,
        #[serde(default)]
        roll: f32,
    },
    /// The server's world, queued by the scene only while it is hosting. A
    /// client never sends this; the runtime ignores it outside a host session.
    World {
        bots: Vec<crate::BotState>,
        weather: crate::WeatherState,
        streams: crate::Streams,
        eaten: Vec<crate::EatenCell>,
        /// The craters the ground has, and the devices that have gone off (M19e).
        /// Absent is a weaker claim than an empty list: it travels as the wire's own
        /// "keep the list you have", while `[]` says the ground is flat -- and a client
        /// that believed *that* stands in the air where a crater used to be.
        #[serde(default)]
        craters: Option<Vec<crate::Crater>>,
        #[serde(default)]
        spent: Option<Vec<crate::Spent>>,
    },
    /// Every world mod's state, queued beside the world and only when one is
    /// loaded. It travels on a datagram of its own, so a mod may publish more
    /// than the world's budget can carry.
    Mods { mods: serde_json::Value },
    /// A grass cell this client just ate, for the host's scene to record.
    Consume { key: i64 },
    /// A device went off (M19e). Absent `by` means it was this process's own goat or one
    /// of its herd -- the common case, and the only thing a client ever sends. A `by`
    /// names the reporter, and only the host produces one: it is relaying a client's
    /// bang, and leaves that player out, because it has already felt it.
    ///
    /// `x`/`z` are the coordinates *this* process derives for the device. A client's are
    /// not sent anywhere (the host owns the layout, see `Client::report_blast`), and on
    /// the host they are what every other client is told.
    Blast {
        kind: String,
        key: i64,
        x: f32,
        z: f32,
        #[serde(default)]
        by: Option<String>,
    },
    /// A captured voice frame, queued by the audio module rather than by the
    /// scene. The scene never sends this: it carries the sender's own sequence
    /// number and an Opus payload the JSON bridge has no business seeing.
    Voice { seq: u32, payload: Vec<u8> },
    /// Leave whatever session is running.
    Close,
    /// Join a gossip swarm: a topic hosts announce their sessions on. `topic`
    /// absent (or blank) means the default; `peers` seed the first connections,
    /// as endpoint tickets or endpoint ids. Joining twice replaces the swarm.
    SwarmJoin {
        #[serde(default)]
        topic: Option<String>,
        #[serde(default)]
        peers: Vec<String>,
    },
    /// Leave the swarm. Discovery stops and, if this client is hosting, its
    /// advert is withdrawn.
    SwarmLeave,
}

/// The wire spelling of a mod reference. The scene prints a digest as hex
/// (`mod key`: `id@version#hash`) while the Rust type carries a `u64`, so a
/// browser join may send either a number or that string. Both are accepted.
#[derive(Deserialize)]
struct ModRefWire {
    id: String,
    version: String,
    #[serde(deserialize_with = "mod_hash")]
    hash: u64,
}

#[derive(Deserialize)]
#[serde(untagged)]
enum ModHashWire {
    Number(u64),
    Text(String),
}

fn mod_hash<'de, D>(deserializer: D) -> Result<u64, D::Error>
where
    D: serde::Deserializer<'de>,
{
    use serde::de::Error as _;
    match ModHashWire::deserialize(deserializer)? {
        ModHashWire::Number(value) => Ok(value),
        ModHashWire::Text(text) => {
            let text = text.trim();
            u64::from_str_radix(text.strip_prefix("0x").unwrap_or(text), 16)
                .map_err(|error| D::Error::custom(format!("mod hash: {error}")))
        }
    }
}

fn mod_refs<'de, D>(deserializer: D) -> Result<Vec<crate::ModRef>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let wire: Vec<ModRefWire> = Vec::deserialize(deserializer)?;
    Ok(wire
        .into_iter()
        .map(|module| crate::ModRef {
            id: module.id,
            version: module.version,
            hash: module.hash,
        })
        .collect())
}

/// An event for the scene.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    /// The session seed, which the world is built from. Sent once, first.
    Session { seed: u32 },
    /// This player is hosting, under this name.
    Hosting { name: String },
    /// The ticket to hand out.
    Ticket { ticket: String },
    /// The handshake succeeded; this is the name the server assigned.
    Welcome { name: String },
    /// Another player joined.
    Joined { name: String },
    /// Another player left.
    Left { name: String },
    /// A chat line. `direct` marks a whisper.
    Chat {
        from: String,
        text: String,
        direct: bool,
    },
    /// A remote goat moved. `name` is the server's canonical name.
    Peer {
        name: String,
        state: crate::PeerState,
    },
    /// The server's world -- bots, sky, streams and meadow -- for a client to
    /// mirror instead of simulating. `eaten` is `null` when the host's snapshot
    /// could not carry the meadow (it was over the datagram budget), which the
    /// scene reads as "keep the one you have".
    World {
        bots: Vec<crate::BotState>,
        weather: crate::WeatherState,
        streams: crate::Streams,
        eaten: Option<Vec<crate::EatenCell>>,
        /// The craters and the spent devices, `null` when the host's snapshot could
        /// not carry them (M19e): the scene keeps the list it has, the same way it
        /// does for the meadow.
        craters: Option<Vec<crate::Crater>>,
        spent: Option<Vec<crate::Spent>>,
    },
    /// Every world mod's state, on its own datagram: `{ streams, data }`, opaque
    /// here and to the transport. A client keeps the last one it got.
    Mods { mods: serde_json::Value },
    /// A client's bite, for the host's scene (host side only).
    Consume { key: i64 },
    /// A bang the host relayed (M19e), with the host's own coordinates for the device.
    /// The scene draws the fire, hears the bang at the right distance, digs the same
    /// crater, and applies the blast to the goats *it* simulates -- which is how a peer
    /// gets flung by a mine someone else stepped on.
    Blast {
        kind: crate::BlastKind,
        key: i64,
        x: f32,
        z: f32,
        by: String,
    },
    /// A client's device went off (M19e), on the host. The client has already fired it,
    /// so this is a report rather than a request: the host spends the device -- the
    /// neighbours must not trip it -- applies the bang to the ground and to its own
    /// goats, and relays it to everyone else.
    BlastReport {
        kind: crate::BlastKind,
        key: i64,
        by: String,
    },
    /// A voice packet. The audio module consumes it; the scene never sees one,
    /// so `encode` drops it rather than encoding Opus bytes as a JSON line.
    Voice {
        from: String,
        seq: u32,
        payload: Vec<u8>,
    },
    /// The roster changed.
    Roster { names: Vec<String> },
    /// A line for the console.
    Notice { text: String },
    /// The connection to the host ended.
    Disconnected,
    /// The session could not be started or joined.
    Error { text: String },
    /// A refused join was fixed by fetching the host's world mods (M18d): `ids`
    /// are the mods that were installed, and `text` is one line for the console.
    ///
    /// The frame loop has host work to do on this one -- the assets have to reach
    /// the engine and the entries have to run -- and it is emitted *before* the
    /// retried join's welcome, so the scene is whole by the time the world it
    /// joins arrives.
    Pulled { text: String, ids: Vec<String> },
    /// The swarm's current hosts, whenever the list changes. This is the swarm's
    /// version of the old registry's list: one entry per host a portal can reach.
    Discovered { sessions: Vec<crate::swarm::Advert> },
    /// The swarm was joined or left. `ticket` is this node's swarm endpoint
    /// ticket, which is what another node needs to seed itself from this one; it
    /// is empty when leaving.
    Swarm {
        joined: bool,
        topic: String,
        id: String,
        ticket: String,
        peers: usize,
    },
    /// The number of direct neighbours in the swarm changed. Zero means the node
    /// is subscribed but alone, which is the shape a missing seed takes.
    SwarmPeers { peers: usize },
}

/// Maps a session event onto the line the scene understands. Voice maps to an
/// event [`encode`] drops: it is Opus bytes for the audio module, not a line for
/// the scene.
pub fn to_event(event: crate::Event) -> Event {
    match event {
        crate::Event::Session { seed } => Event::Session { seed },
        crate::Event::Joined { name } => Event::Joined { name },
        crate::Event::Left { name } => Event::Left { name },
        crate::Event::Chat { from, text, direct } => Event::Chat { from, text, direct },
        crate::Event::Peer { name, state } => Event::Peer { name, state },
        crate::Event::World {
            bots,
            weather,
            streams,
            eaten,
            craters,
            spent,
        } => Event::World {
            bots,
            weather,
            streams,
            eaten,
            craters,
            spent,
        },
        // The transport carries a mod's state opaquely; the scene is what has a
        // schema for it.
        crate::Event::Mods { mods } => Event::Mods { mods: mods.0 },
        crate::Event::Consume { key } => Event::Consume { key },
        crate::Event::Blast {
            kind,
            key,
            x,
            z,
            by,
        } => Event::Blast {
            kind,
            key,
            x,
            z,
            by,
        },
        crate::Event::BlastReport { kind, key, by } => Event::BlastReport { kind, key, by },
        crate::Event::Voice { from, seq, payload } => Event::Voice { from, seq, payload },
        crate::Event::Roster { names } => Event::Roster { names },
        crate::Event::Notice(text) => Event::Notice { text },
        crate::Event::Disconnected => Event::Disconnected,
    }
}

/// Encodes an event as the one JSON line the scene reads. `None` for voice,
/// which has no scene-side reader.
pub fn encode(event: &Event) -> Option<String> {
    if matches!(event, Event::Voice { .. }) {
        return None;
    }
    match serde_json::to_string(event) {
        Ok(line) => Some(line),
        Err(error) => {
            eprintln!("[net] could not encode an event: {error}");
            None
        }
    }
}

/// The scene spells a gait with a string, because that is what `mode` is there;
/// an unknown one falls back to idle rather than being an error, since a bad
/// pose is not worth dropping the connection over.
pub fn parse_gait(name: &str) -> crate::Gait {
    match name {
        "walk" => crate::Gait::Walk,
        "trot" => crate::Gait::Trot,
        "run" => crate::Gait::Run,
        "jump" => crate::Gait::Jump,
        "flung" => crate::Gait::Flung,
        "sleep" => crate::Gait::Sleep,
        "eat" => crate::Gait::Eat,
        "dead" => crate::Gait::Dead,
        "fly" => crate::Gait::Fly,
        "fall" => crate::Gait::Fall,
        _ => crate::Gait::Idle,
    }
}

/// A scene angle in degrees as the wire's one byte. The attitude is a *look*, not a
/// trajectory -- the owner's position and yaw are the authoritative half -- so a
/// degree is plenty, and a value outside `i8` is clamped rather than wrapped: a
/// sideways goat is better than a flipped one.
pub fn degrees(angle: f32) -> i8 {
    if angle.is_finite() {
        angle.round().clamp(-128.0, 127.0) as i8
    } else {
        0
    }
}

/// The scene spells a device's kind with a string -- `BlastKind`'s own serialisation,
/// so the two agree by construction -- and anything else reads as a mine rather than
/// being an error, the way an unknown gait reads as idle.
pub fn parse_blast_kind(name: &str) -> crate::BlastKind {
    match name {
        "trap" => crate::BlastKind::Trap,
        _ => crate::BlastKind::Mine,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_command_line_parses_with_the_scene_spelling() {
        let line = r#"{"type":"join","ticket":"abc","name":"goat"}"#;
        match serde_json::from_str::<Command>(line).unwrap() {
            Command::Join { ticket, name, .. } => {
                assert_eq!(ticket, "abc");
                assert_eq!(name, "goat");
            }
            other => panic!("wrong command: {other:?}"),
        }
    }

    #[test]
    fn a_join_carries_the_world_mods_a_browser_presents() {
        let line = r#"{"type":"join","ticket":"t","name":"n",
            "mods":[{"id":"a","version":"1.0.0","hash":"0123456789abcdef"}]}"#;
        match serde_json::from_str::<Command>(line).unwrap() {
            Command::Join { mods, .. } => assert_eq!(mods.len(), 1),
            other => panic!("wrong command: {other:?}"),
        }
    }

    #[test]
    fn the_world_mod_hash_reads_as_hex_or_a_number() {
        let hex = r#"{"type":"join","ticket":"t","name":"n",
            "mods":[{"id":"a","version":"1.0.0","hash":"77675b54122841b5"}]}"#;
        let number = r#"{"type":"join","ticket":"t","name":"n",
            "mods":[{"id":"a","version":"1.0.0","hash":8603946029754630581}]}"#;
        let read = |line: &str| match serde_json::from_str::<Command>(line).unwrap() {
            Command::Join { mods, .. } => mods[0].hash,
            other => panic!("wrong command: {other:?}"),
        };
        assert_eq!(read(hex), 0x7767_5b54_1228_41b5);
        assert_eq!(read(number), 0x7767_5b54_1228_41b5);
    }

    #[test]
    fn an_event_is_the_json_tag_the_scene_reads() {
        let session = encode(&Event::Session { seed: 7 }).unwrap();
        assert_eq!(session, r#"{"type":"session","seed":7}"#);
        let chat = encode(&Event::Chat {
            from: "a".to_string(),
            text: "hi".to_string(),
            direct: false,
        })
        .unwrap();
        assert_eq!(
            chat,
            r#"{"type":"chat","from":"a","text":"hi","direct":false}"#
        );
    }

    #[test]
    fn voice_is_not_a_scene_line() {
        let voice = Event::Voice {
            from: "a".to_string(),
            seq: 1,
            payload: vec![1, 2, 3],
        };
        assert!(encode(&voice).is_none());
    }

    #[test]
    fn the_session_translation_keeps_the_join_and_roster() {
        assert!(matches!(
            to_event(crate::Event::Joined {
                name: "b".to_string()
            }),
            Event::Joined { name } if name == "b"
        ));
        assert!(matches!(
            to_event(crate::Event::Disconnected),
            Event::Disconnected
        ));
    }
}
