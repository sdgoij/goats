//! The networking bridge: `session` and `proto` behind a Godot node.
//!
//! This is `crates/godot`'s other half, and the reason the port can claim wire
//! compatibility rather than resemblance (`godot/PORT.md` section 7): the
//! transport is iroh, the control frames are `proto`'s, the datagrams are
//! `proto::wire`'s, and all of it is *these* crates rather than a reimplementation.
//!
//! The shape is the raylib client's `crates/goats/src/net.rs`, because the
//! constraints are the same: the engine runs a frame loop and must never await,
//! and iroh needs a tokio runtime. So a dedicated thread owns the runtime, the
//! frame loop sends intents down a channel and drains events from a queue, and
//! nothing in either direction blocks a frame.
//!
//! What GDScript gets is the vocabulary the scene already speaks: the same
//! events, as JSON lines, tagged the same way (`"type"`, snake_case variants) so
//! a scene written against `net.js` reads the same paths. A `Host` emits `hosting`
//! and `ticket`; a `Client` emits `welcome`; both emit `session`, `roster`,
//! `joined`, `left`, `chat`, `peer`, `notice` and `disconnected`.

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;

use godot::prelude::*;
use serde::Deserialize;
use serde_json::json;
use session::bridge::degrees;
use session::swarm::{self, Advert, SwarmCommands, SwarmConfig, SwarmEvent};
use session::{BlastKind, Client, Event as Net, Gait, Host, ModRef, PeerState, WorldState};
use tokio::sync::mpsc;

/// Events waiting for the frame loop to drain. Shared with the runtime thread.
type Queue = Arc<Mutex<VecDeque<String>>>;

/// Encoded voice frames waiting for the frame loop to decode, shared with the runtime
/// thread beside the events. An Opus packet is not a line, so it rides a channel of its
/// own rather than a JSON shape -- the same split `crates/goats/src/net.rs` makes with its
/// `VoiceIn`. A frame is the speaker's canonical name (stamped by the relay), the sequence
/// number and the payload.
type VoiceQueue = Arc<Mutex<VecDeque<(String, u32, Vec<u8>)>>>;

/// The server's world, as a host publishes it. The scene builds this as JSON -- the same object
/// the `world` *event* carries, so the port has one shape for the world in both directions -- and
/// it is parsed here because it *is* `proto`'s schema: a typed `WorldState` is what
/// `Host::publish_world` takes, and a scene that sends a field the wire does not have should get
/// an error it can read rather than a snapshot that silently drops it.
#[derive(Debug, Deserialize)]
struct WorldIntent {
    bots: Vec<session::BotState>,
    weather: session::WeatherState,
    streams: session::Streams,
    eaten: Vec<session::EatenCell>,
    /// The ground and the devices that have gone off (M19e). `None` is the wire's own "keep the
    /// list you have" and an empty list is a statement -- flat ground, nothing spent -- which is
    /// why a host sends the lists it has rather than omitting them.
    #[serde(default)]
    craters: Option<Vec<session::Crater>>,
    #[serde(default)]
    spent: Option<Vec<session::Spent>>,
}

/// The `--pull` policy (M18d): where a fetched mod is installed, and whether a join fetches
/// without being asked. This is `crates/goats/src/net.rs`'s `Pull`, ported -- the *policy* is
/// the bridge's rather than the transport's, because the two things it decides are the client's:
/// whether to fetch at all, and where to put what arrives.
#[derive(Clone)]
struct Pull {
    /// Where a fetched mod is installed, and what the retry's digest is re-derived from. `None`
    /// with no mods directory: nothing can be installed, and nothing can be served.
    mods_dir: Option<PathBuf>,
    /// The standing consent -- `GOATS_PULL`, the port's `--pull` on the command line: fetch on a
    /// refusal that was about mods without the flag on the command.
    always: bool,
}

impl Pull {
    /// May this join fetch? `asked` is the console's per-command consent (`connect <ticket>
    /// --pull`). A pull installs code the player did not choose, so it only ever happens
    /// because somebody said so -- here or on the command line.
    fn allowed(&self, asked: bool) -> bool {
        self.mods_dir.is_some() && (self.always || asked)
    }

    /// Is there anywhere to install if the player did ask? This is the `can_pull` a refusal is
    /// phrased with: the feature is a flag away only when there is a directory to put it in.
    fn possible(&self) -> bool {
        self.mods_dir.is_some()
    }
}

/// One intent, from a GDScript call. The raylib client parses these out of JSON
/// lines because its scene is the other side of the bridge; here the call *is*
/// the parse, so the enum is built directly.
enum Command {
    Host {
        name: String,
        /// The world-mod set every joiner must present (`ModHost::world_mod_refs`). Empty is the
        /// common case -- a session with no world mods -- and is what the raylib client's
        /// `--no-mods` presents too.
        mods: Vec<ModRef>,
        /// The pull policy, carried so a host can *serve* its own world mods to a fetching joiner
        /// (M18d): a session hosted from the game window syncs a joiner the way `goatsd` does.
        /// `mods_dir` is where the archives are packaged from; `always` is unused here.
        pull: Pull,
    },
    Join {
        ticket: String,
        name: String,
        /// This client's world-mod set, which the host compares with its own and refuses a
        /// mismatch of (`APIv1.md` section 6.3).
        mods: Vec<ModRef>,
        /// The console's per-command consent (`connect <ticket> --pull`). The standing consent
        /// and the install directory are in `pull`.
        asked: bool,
        /// The `--pull` policy: where a fetched mod lands, and whether this join may fetch.
        pull: Pull,
    },
    Say {
        text: String,
    },
    Consume {
        key: i64,
    },
    Pose(PeerState),
    World(WorldIntent),
    /// The world mods a host owns, on a datagram of their own (M16, `APIv1.md` section 4.13).
    /// Deliberately *untyped*, unlike [`Command::World`]: a world mod's published state is opaque
    /// to the transport by design, so the only schema is that it is JSON, and `proto` bounds it by
    /// the datagram's size rather than by a shape (`ModsState`). It arrives already built -- the
    /// scene asks `ModHost::world_mods_json` for it, which is where a JavaScript world mod's state
    /// and a compiled one's bytes are merged.
    Mods(serde_json::Value),
    /// A device went off (M19e). An absent `by` is this process's own goat or herd, which is
    /// the only thing a scene ever queues; a `by` names the reporter, and only a host produces
    /// one -- it is relaying a client's bang (`blast_report`) and leaves that player out.
    Blast {
        kind: String,
        key: i64,
        x: f32,
        z: f32,
        by: Option<String>,
    },
    /// A captured voice frame, queued by this node's audio half ([`crate::voice`]) rather
    /// than by the scene. The scene never sends one: it carries the encoder's own sequence
    /// number and an Opus payload the event queue has no business seeing.
    Voice {
        seq: u32,
        payload: Vec<u8>,
    },
    /// Join a gossip swarm: a topic hosts announce their sessions on. `topic` absent means
    /// the default every build shares; `peers` seed the first connection, because gossip
    /// cannot find a topic that nobody is in. Joining twice replaces the swarm.
    SwarmJoin {
        topic: Option<String>,
        peers: Vec<String>,
    },
    /// Leave the swarm. Discovery stops and, if this client is hosting, its advert is
    /// withdrawn rather than left for the TTL.
    SwarmLeave,
    /// A no-op. `set_swarm_auto` sends one so the runtime thread starts at boot, which
    /// is what lets the auto-joined swarm begin beaconing before the scene asks for
    /// anything. It reconfigures nothing.
    Noop,
    Close,
}

/// A live session. Both ends of the protocol are the same transport -- every
/// endpoint accepts and dials -- so this is only about which half of the API is
/// in hand.
enum Live {
    Host(Host),
    Client(Client),
}

impl Live {
    async fn next_event(&mut self) -> Option<Net> {
        match self {
            Live::Host(host) => host.next_event().await,
            Live::Client(client) => client.next_event().await,
        }
    }

    async fn close(self) {
        match self {
            Live::Host(host) => host.close().await,
            Live::Client(client) => client.close().await,
        }
    }

    /// Says one captured voice frame. A client sends it up to the host to be re-tagged and
    /// relayed; the host sends its own straight out -- `crates/goats/src/net.rs`'s own
    /// `Live::publish_voice`, transcribed, because the rule is the protocol's rather than
    /// the engine's.
    async fn publish_voice(&self, seq: u32, payload: &[u8]) {
        match self {
            Live::Host(host) => host.publish_voice(seq, payload).await,
            Live::Client(client) => client.publish_voice(seq, payload),
        }
    }

    /// A device went off (M19e): this process's own goat or herd, or -- on the host, when `by`
    /// names somebody else -- a bang a client reported. It is `crates/goats/src/net.rs`'s same
    /// four cases, transcribed, because the rule is the protocol rather than the engine.
    ///
    /// Only a host relays, and a reported bang is not fired again here: the reporter fired it,
    /// this process fires *its* copy of it (the ground, the herd -- which the scene has already
    /// done), and `except` is what keeps the bang from landing twice on the one goat that has
    /// already felt it.
    async fn blast(
        &self,
        kind: BlastKind,
        key: i64,
        x: f32,
        z: f32,
        by: Option<&str>,
    ) -> Option<String> {
        match (self, by) {
            (Live::Host(host), Some(reporter)) => {
                host.blast(kind, key, x, z, reporter, Some(reporter)).await;
                None
            }
            (Live::Host(host), None) => {
                host.blast(kind, key, x, z, host.name(), None).await;
                None
            }
            // A client's own bang: report it and let the host say where the device is.
            // `x`/`z` stay behind for exactly that reason.
            (Live::Client(client), None) => client
                .report_blast(kind, key)
                .await
                .err()
                .map(|error| error.to_string()),
            // A client never relays, and nothing that is not its own bang reaches it.
            (Live::Client(_), Some(_)) => None,
        }
    }
}

/// The networking bridge's Godot end.
///
/// `host` and `join` start a session, `say` and `pose` use it, `leave` ends
/// it, and `poll_events` drains what came back. The session lives on its own
/// thread, so none of these block a frame.
///
/// Voice's `#[func]`s hang on this class too (`crate::voice`): the codec's bytes go out and
/// come back through the same session, so its Godot surface belongs on the node that owns the
/// wire rather than on a second class.
#[derive(GodotClass)]
#[class(base=Node)]
struct NetBridge {
    base: Base<Node>,
    /// `None` until the runtime thread is up. Dropping it ends the thread.
    commands: Option<mpsc::UnboundedSender<Command>>,
    /// The thread itself, kept so it can be joined rather than abandoned.
    thread: Option<thread::JoinHandle<()>>,
    queue: Queue,
    /// Encoded voice frames the session delivered, written by the runtime thread and drained
    /// by `pull_voice` on the frame thread.
    voice_in: VoiceQueue,
    /// The `--pull` policy (M18d): where a fetched mod is installed and whether a join fetches
    /// without being asked. Set once by the scene (`set_pull`) from its own knobs -- `GOATS_PULL`
    /// and its mods directory -- and read at each `join`/`host`, so the fetch consent is the
    /// player's rather than a default.
    pull: Pull,
    /// Join the default swarm when the runtime thread starts. Off until the scene asks
    /// (`set_swarm_auto`), so a gate that constructs a bridge is never joined by a beacon it
    /// did not ask for; `main.gd` turns it on from `GOATS_SWARM` (default on).
    swarm_auto: bool,
    /// The codec half (`crate::voice`): the speech gate, the Opus coder and the mix the scene
    /// plays. It lives on this node rather than a second one because the *wire* is here -- a
    /// captured frame goes out and a delivered one comes back through the same session, and
    /// a separate Godot class would only have to reach back in through the scene to say so.
    voice: crate::voice::Voice,
}

#[godot_api]
impl INode for NetBridge {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            commands: None,
            thread: None,
            queue: Queue::default(),
            voice_in: VoiceQueue::default(),
            pull: Pull {
                mods_dir: None,
                always: false,
            },
            swarm_auto: false,
            voice: crate::voice::Voice::new(),
        }
    }

    /// Godot calls this when the node leaves the tree -- which is the last thing
    /// that happens to a running game before the process ends.
    ///
    /// Without it, quitting a game with a live session **segfaults**: the process
    /// tears down while iroh is still closing an endpoint on its own thread. That
    /// is not a test artefact; a player pressing quit crashed the client, and it
    /// was the suite running the herd scene after six other gates that made the
    /// timing tight enough to see.
    fn exit_tree(&mut self) {
        self.stop_runtime();
    }
}

#[godot_api]
impl NetBridge {
    /// Host a session under `name` and start serving, requiring the world-mod set `mods` of
    /// every joiner (`APIv1.md` section 6.2). The ticket arrives as a `ticket` event; the `seed`
    /// as a `session` event.
    ///
    /// `mods` is `ModHost::world_mod_refs`'s JSON -- or an empty string for none, which is what
    /// every gate presents -- and it has to be *this* client's own set: a host that required
    /// anything else would refuse the peers it can actually agree with.
    ///
    /// A host **serves** its own world mods to a fetching joiner (M18d): with a mods directory
    /// (set by `set_pull`), the archives are packaged once here and the session's fetch surface
    /// answers a joiner missing one -- so a session hosted from the game window syncs a joiner
    /// the way `goatsd` does. With no directory there is nothing to hand over, which is a
    /// limitation of that host rather than of the client.
    #[func]
    fn host(&mut self, name: GString, mods: GString) -> GString {
        let pull = self.pull.clone();
        match parse_mod_refs(&mods.to_string()) {
            Ok(mods) => self.queue_command(Command::Host {
                name: name.to_string(),
                mods,
                pull,
            }),
            Err(error) => crate::gstring(format!("error: {error}")),
        }
    }

    /// Join the session `ticket` names, asking to be called `name`, and presenting this client's
    /// world-mod set `mods`. With `pull`, a refusal *about the world-mod set* fetches what this
    /// client lacks from the host, installs it, and retries once (M18d).
    ///
    /// `mods` is `ModHost::world_mod_refs`'s JSON (or empty for none). Without it a joiner could
    /// never enter a session whose host runs a world mod -- the host refuses a set that differs,
    /// and "nothing" is not the host's set.
    ///
    /// `pull` is the *per-join* consent, the console's `connect <ticket> --pull`. The standing
    /// consent is [`NetBridge::set_pull`]'s `always`, and the directory a fetch installs into is
    /// its `mods_dir`; both are read here, so a scene sets the policy once and a verb only has to
    /// say whether *this* join asked.
    ///
    /// `join`, not `connect`: `Node` already has `connect` for signals, and a
    /// GDExtension method that shadows a base one is resolved by the static type
    /// at the call site rather than by name -- so a GDScript holding a `Node`
    /// would silently reach the wrong method. godot-rust warns about it, and
    /// will make it an error.
    #[func]
    fn join(&mut self, ticket: GString, name: GString, mods: GString, pull: bool) -> GString {
        let policy = self.pull.clone();
        match parse_mod_refs(&mods.to_string()) {
            Ok(mods) => self.queue_command(Command::Join {
                ticket: ticket.to_string(),
                name: name.to_string(),
                mods,
                asked: pull,
                pull: policy,
            }),
            Err(error) => crate::gstring(format!("error: {error}")),
        }
    }

    /// The browser's gateway URL. The desktop bridge dials iroh itself and has
    /// no WebSocket to point at it, so this is a no-op that keeps the scene's
    /// boot call valid on both targets.
    #[func]
    fn set_gateway(&mut self, _url: GString) -> GString {
        crate::gstring("ok")
    }

    /// Set the `--pull` policy (M18d): the directory a fetched world mod is installed into, and
    /// whether a refused join fetches without being asked. The scene calls this once, at boot,
    /// from its own mods directory and `GOATS_PULL` -- the port's spelling of the raylib client's
    /// `--mods`/`--pull`.
    ///
    /// An empty `mods_dir` is "nowhere to install": a join is refused as it always was, and the
    /// refusal says what it always said, because there is no flag that could help.
    #[func]
    fn set_pull(&mut self, mods_dir: GString, always: bool) -> GString {
        let dir = mods_dir.to_string();
        self.pull = Pull {
            mods_dir: if dir.is_empty() {
                None
            } else {
                Some(PathBuf::from(dir))
            },
            always,
        };
        GString::from("ok")
    }

    /// Say a line. A leading `@name` is a whisper; the routing is the
    /// session's, not this crate's.
    #[func]
    fn say(&mut self, text: GString) -> GString {
        self.queue_command(Command::Say {
            text: text.to_string(),
        })
    }

    /// Report a bite this player took, so the host's meadow can record it. The
    /// cell is the meadow's own `Meadow.key(cx, cz)`, which is what the wire
    /// carries.
    ///
    /// A client's alone, for the same reason a pose is: the host's own meadow is
    /// local to its scene, and there is nobody to tell. A path is not a poison to
    /// a non-biting build -- a goat that never eats never calls this.
    #[func]
    fn consume(&mut self, key: i64) -> GString {
        self.queue_command(Command::Consume { key })
    }

    /// Publish this player's goat: `x`, `z` and `yaw` in metres and turns,
    /// `phase` through the clip, `speed` in metres per second, `gait` by name,
    /// `py` the flung arc's height above the ground, and `pitch`/`roll` the
    /// flyer's attitude in degrees (protocol 12).
    ///
    /// Datagrams are unreliable by design, so this is called about twenty times
    /// a second and a lost one does not matter -- the next replaces it. It is
    /// the client's alone: a host's own goat is already local to its scene.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn pose(
        &mut self,
        x: f64,
        z: f64,
        yaw: f64,
        phase: f64,
        speed: f64,
        gait: GString,
        py: f64,
        pitch: f64,
        roll: f64,
    ) -> GString {
        self.queue_command(Command::Pose(PeerState {
            x: x as f32,
            z: z as f32,
            yaw: yaw as f32,
            phase: phase as f32,
            speed: speed as f32,
            gait: parse_gait(&gait.to_string()),
            py: py as f32,
            pitch: degrees(pitch as f32),
            roll: degrees(roll as f32),
        }))
    }

    /// Publish the server's world. The scene queues this only while it is *hosting*, and it
    /// carries the JSON the `world` event carries, so the two directions of a world are one
    /// shape: `sceneWorldBots`'s bots, `sceneWeatherState`'s sky, `sceneStreams`'s four PRNG
    /// states, the meadow's eaten cells, the ground's craters and the devices that have gone off.
    ///
    /// Returns `ok`, or `error: ...` for a payload `proto` cannot read -- the one failure a
    /// scene can act on, and otherwise invisible: a dropped snapshot is a world nobody has.
    #[func]
    fn world(&mut self, json: GString) -> GString {
        match serde_json::from_str::<WorldIntent>(&json.to_string()) {
            Ok(intent) => self.queue_command(Command::World(intent)),
            Err(error) => GString::from(format!("error: {error}").as_str()),
        }
    }

    /// Publish the world mods' state. The scene queues this only while it is *hosting*, and only
    /// when there is something to send -- `ModHost::world_mods_json` answers the empty string when
    /// no world mod contributes anything, which is the common case and the reason a vanilla session
    /// never opens this datagram at all.
    ///
    /// It is opaque here on purpose (`ABIv1.md` section 3.3, `APIv1.md` section 4.13): what a mod
    /// publishes is its own business, and the transport's only job is to carry it beside the world
    /// rather than inside it -- a mod's state may be bigger than the world's budget, and losing it
    /// costs a mod rather than everyone's world.
    ///
    /// Returns `ok`, or `error: ...` for a payload that is not JSON at all, which is the one thing
    /// this end can refuse; the *size* refusal is `proto`'s and arrives as a notice.
    #[func]
    fn mods(&mut self, json: GString) -> GString {
        match serde_json::from_str::<serde_json::Value>(&json.to_string()) {
            Ok(state) => self.queue_command(Command::Mods(state)),
            Err(error) => GString::from(format!("error: {error}").as_str()),
        }
    }

    /// Report a device that went off (M19e): `kind` is `mine` or `trap`, `key` the cell it was
    /// in, and `x`/`z` where *this* process derived it. An empty `by` is this player's own goat
    /// or herd -- the common case, and the only thing a scene queues. A `by` names the reporter,
    /// and only a host sends one: it is relaying a client's report (see `blast_report`).
    ///
    /// The two session halves do different things with it, and neither is this crate's decision:
    /// a client's own bang is a *report* (`Client::report_blast`), so its `x`/`z` are dropped and
    /// the host derives where the key actually is; a host's is a broadcast with its own
    /// coordinates. Like a pose, it is silent with no session -- offline there is already a hole
    /// in the ground and nobody to tell.
    #[func]
    fn blast(&mut self, kind: GString, key: i64, x: f64, z: f64, by: GString) -> GString {
        let by = by.to_string();
        self.queue_command(Command::Blast {
            kind: kind.to_string(),
            key,
            x: x as f32,
            z: z as f32,
            by: if by.is_empty() { None } else { Some(by) },
        })
    }

    /// End the session. The other end sees a `left`, in due course.
    #[func]
    fn leave(&mut self) -> GString {
        self.queue_command(Command::Close)
    }

    /// Join the swarm `topic` names, seeded by `peers` (`--peer` on the console, comma-
    /// separated). An empty topic is the default every build shares, and empty peers is a
    /// listen-only membership -- which finds nothing until another node joins the topic.
    ///
    /// The swarm is independent of the session: a player can look for hosts while offline,
    /// and a host keeps its advert on the topic for as long as it is hosting. Joining twice
    /// replaces the swarm, and the events from the one being replaced are discarded.
    #[func]
    fn swarm_join(&mut self, topic: GString, peers: GString) -> GString {
        let topic = topic.to_string();
        let peers = peers
            .to_string()
            .split(',')
            .map(str::trim)
            .filter(|peer| !peer.is_empty())
            .map(str::to_string)
            .collect();
        self.queue_command(Command::SwarmJoin {
            topic: if topic.trim().is_empty() {
                None
            } else {
                Some(topic)
            },
            peers,
        })
    }

    /// Leave the swarm, withdrawing this host's advert if there is one.
    #[func]
    fn swarm_leave(&mut self) -> GString {
        self.queue_command(Command::SwarmLeave)
    }

    /// Whether the runtime joins the default swarm when it starts. The game turns this on at
    /// boot (`main.gd`, from `GOATS_SWARM`); a gate leaves it off, because a bridge that
    /// started advertising on the shared multicast group would join every other gate's
    /// bridge on the machine.
    #[func]
    fn set_swarm_auto(&mut self, on: bool) {
        self.swarm_auto = on;
        if on && self.commands.is_none() {
            // Start the runtime here rather than on the first session command: discovery
            // should be live from boot, so the `swarm` status and the portal list are
            // populated before the player decides to host or join anything.
            let _ = self.queue_command(Command::Noop);
        }
    }

    /// Drain the events the session produced since the last call, as JSON
    /// lines. Never blocks; a frame loop calls it once per frame.
    #[func]
    fn poll_events(&mut self) -> PackedStringArray {
        let mut out = PackedStringArray::new();
        for line in lock(&self.queue).drain(..) {
            out.push(&GString::from(line.as_str()));
        }
        out
    }

    /// Hand the codec a block of captured audio -- mono `samples` at `rate` Hz, read off the
    /// scene's capture bus every frame -- and queue whatever speech it heard for the session.
    /// Answers how many frames were encoded, which is usually none or one.
    ///
    /// This is the uplink, and the whole of it: the gate, the coder and the framing are
    /// `crate::voice`'s, and the frame travels the channel a pose does (`Command::Voice`).
    /// Silent with no session, exactly as a pose is.
    #[func]
    fn push_voice(&mut self, samples: PackedFloat32Array, rate: f64) -> i64 {
        let frames = self.voice.feed(samples.as_slice(), rate as u32);
        let count = frames.len() as i64;
        for (seq, payload) in frames {
            self.queue_command(Command::Voice { seq, payload });
        }
        count
    }

    /// The downlink, once a frame: decode everything the session delivered since the last
    /// call and hand back up to `max` samples of the mix at the current gain, 48 kHz mono.
    ///
    /// The scene pushes them into its generator and asks for no more than it has room for, so
    /// nothing is dropped in between. The decoding is `crate::voice`'s; the frames it decodes
    /// were queued by the run loop (`queue_voice`).
    #[func]
    fn pull_voice(&mut self, max: i64) -> PackedFloat32Array {
        for (from, seq, payload) in drain_voice(&self.voice_in) {
            self.voice.receive(&from, seq, &payload);
        }
        let pcm = self.voice.drain(max.max(0) as usize);
        let mut out = PackedFloat32Array::new();
        for sample in pcm {
            out.push(sample);
        }
        out
    }

    /// The scene's master mute, as a 0..1 gain on everything a peer sends (`audio.js`'s
    /// `voice_gain` intent). It reaches the mix at once rather than at the next packet, which
    /// is why the gain lives here and never goes on the wire.
    #[func]
    fn set_voice_gain(&mut self, gain: f64) {
        self.voice.set_gain(gain as f32);
    }

    /// What the codec has done, for a gate or the HUD:
    /// `{"sent":N,"decoded":N,"buffered":N,"gain":F}`.
    #[func]
    fn voice_state(&self) -> GString {
        let (sent, decoded, buffered, gain) = self.voice.state();
        crate::gstring(format!(
            "{{\"sent\":{sent},\"decoded\":{decoded},\"buffered\":{buffered},\"gain\":{gain}}}"
        ))
    }

    /// End the session and wait for the runtime thread to finish.
    ///
    /// Called automatically when the node leaves the tree, so a script only needs
    /// it when it means to stop early -- a probe about to quit, or a node that was
    /// never added to the tree at all.
    #[func]
    fn shutdown(&mut self) -> GString {
        self.stop_runtime();
        GString::from("ok")
    }
}

impl NetBridge {
    /// Make sure the runtime thread is up, then hand it the intent.
    fn queue_command(&mut self, command: Command) -> GString {
        if self.commands.is_none() {
            match start_runtime(self.queue.clone(), self.voice_in.clone(), self.swarm_auto) {
                Ok((commands, thread)) => {
                    self.commands = Some(commands);
                    self.thread = Some(thread);
                }
                Err(error) => return crate::gstring(format!("error: {error}")),
            }
        }
        match self.commands.as_ref() {
            // The thread has stopped; the channel is the only way to know.
            Some(commands) if commands.send(command).is_err() => {
                GString::from("error: the networking thread has stopped")
            }
            Some(_) => GString::from("ok"),
            None => GString::from("error: no runtime"),
        }
    }

    /// Close the channel, then wait for the thread it was driving.
    ///
    /// Dropping the sender is what ends the loop -- `recv` returns `None`, the
    /// session closes itself and the runtime is dropped on the thread that owns
    /// it. Calling this twice is harmless.
    fn stop_runtime(&mut self) {
        self.commands = None;
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Spawn the thread that owns the tokio runtime.
///
/// A thread rather than a runtime field on the node: the runtime must outlive
/// every borrow of the node, and the frame loop must never be the thread that
/// drives it.
fn start_runtime(
    queue: Queue,
    voice_in: VoiceQueue,
    auto_swarm: bool,
) -> Result<(mpsc::UnboundedSender<Command>, thread::JoinHandle<()>), String> {
    let (commands, receiver) = mpsc::unbounded_channel();
    let thread = thread::Builder::new()
        .name("goats-net".to_string())
        .spawn(move || {
            let runtime = match tokio::runtime::Builder::new_multi_thread()
                .enable_all()
                .build()
            {
                Ok(runtime) => runtime,
                Err(error) => {
                    push(
                        &queue,
                        json!({"type": "error", "text": format!("could not start a runtime: {error}")})
                            .to_string(),
                    );
                    return;
                }
            };
            runtime.block_on(run(receiver, queue, voice_in, auto_swarm));
        })
        .map_err(|error| format!("could not start the networking thread: {error}"))?;
    Ok((commands, thread))
}

/// The session loop. Mirrors `net.rs`: with a session up, wait on a command and
/// an event at once; with none, wait on a command.
async fn run(
    mut commands: mpsc::UnboundedReceiver<Command>,
    queue: Queue,
    voice_in: VoiceQueue,
    auto_swarm: bool,
) {
    let mut live: Option<Live> = None;
    // The swarm this client is in, if any, and the task draining its events. The command
    // side is what hosts advertise through; the task is aborted on a topic switch so a
    // stale list cannot overtake the new swarm's.
    let mut swarm: Option<SwarmCommands> = None;
    let mut swarm_task: Option<tokio::task::JoinHandle<()>> = None;
    if auto_swarm {
        // Zero-config: the default topic is joined before the first command, so the LAN
        // beacon is already introducing this client to the network when the scene asks.
        match join_swarm(None, Vec::new(), &queue).await {
            Ok((commands, task)) => {
                swarm = Some(commands);
                swarm_task = Some(task);
            }
            Err(text) => push(&queue, notice(text)),
        }
    }
    // How often a hosting client restates its advert. The interval is only polled inside a
    // live session; the swarm task's own timer covers the gaps.
    let mut announce = tokio::time::interval(session::swarm::ADVERT_EVERY);
    announce.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // What became of the last world publication. `Host::publish_world` asks to be reported on
    // only when the outcome *changes*, because a host publishes ten times a second and "the
    // snapshot is too big" is one fact rather than ten a second.
    let mut last_world: Option<session::WorldOutcome> = None;
    // The same for the mods datagram, which is a *second* report rather than a second question: a
    // world mod publishing too much is one fact per change, not ten a second.
    let mut last_mods: Option<session::ModsOutcome> = None;
    loop {
        enum Outcome {
            Command(Option<Command>),
            /// The session's event stream ended.
            Ended,
        }

        // Forwarding happens inside the select arm so the borrow of `live` ends
        // before the command below needs it mutably.
        let outcome = match live.as_mut() {
            Some(session) => tokio::select! {
                command = commands.recv() => Outcome::Command(command),
                event = session.next_event() => match event {
                    // Voice is the codec half's, not the scene's: Opus bytes are not a line,
                    // so they take the voice queue instead of the event queue, and
                    // `pull_voice` decodes them on the frame thread.
                    Some(Net::Voice { from, seq, payload }) => {
                        queue_voice(&voice_in, (from, seq, payload));
                        continue;
                    }
                    Some(event) => {
                        // The player count is part of the advert, so a roster change is
                        // the moment to restate it rather than wait for the next window.
                        if matches!(&event, Net::Roster { .. })
                            && let Live::Host(host) = &*session
                        {
                            advertise_host(host, swarm.as_ref()).await;
                        }
                        push(&queue, event_json(event));
                        continue;
                    }
                    None => Outcome::Ended,
                },
                // A host keeps its advert fresh for as long as it is hosting: this is
                // what refreshes the player count and recovers from a dropped message.
                _ = announce.tick() => {
                    if let Live::Host(host) = session {
                        advertise_host(host, swarm.as_ref()).await;
                    }
                    continue;
                },
            },
            None => Outcome::Command(commands.recv().await),
        };

        match outcome {
            Outcome::Ended => {
                push(&queue, json!({"kind": "disconnected"}).to_string());
                if let Some(session) = live.take() {
                    stop(session, swarm.as_ref()).await;
                }
            }
            Outcome::Command(None) => break,
            // `Say` and `Pose` use the live session rather than replacing it, so
            // they are handled here; everything else reconfigures it.
            Outcome::Command(Some(Command::Say { text })) => match live.as_mut() {
                Some(Live::Host(host)) => host.say(&text).await,
                Some(Live::Client(client)) => {
                    if let Err(error) = client.say(&text).await {
                        push(&queue, notice(error.to_string()));
                    }
                }
                None => push(&queue, notice("not in a session".to_string())),
            },
            Outcome::Command(Some(Command::Pose(state))) => match live.as_mut() {
                Some(Live::Client(client)) => client.publish(&state),
                // A host's own goat is local to its scene; there is nobody to
                // publish it to but the clients, and `Host::publish` is that.
                Some(Live::Host(host)) => host.publish(&state).await,
                None => {}
            },
            // A bite this player took, reported to the host so its meadow can
            // record it -- and the next world snapshot carries it back to
            // everyone. Silent while offline, where the meadow is already local,
            // and on a host, which *is* the meadow.
            Outcome::Command(Some(Command::Consume { key })) => {
                if let Some(Live::Client(client)) = live.as_mut()
                    && let Err(error) = client.consume(key).await
                {
                    push(&queue, notice(error.to_string()));
                }
            }
            // The world a host owns. A client that queues one is dropped in silence -- the
            // scene never does, and a notice would be noise -- and the outcome is reported only
            // when it changes, which is `publish_world`'s own contract.
            Outcome::Command(Some(Command::World(intent))) => {
                if let Some(Live::Host(host)) = live.as_ref() {
                    let state = WorldState {
                        bots: intent.bots,
                        weather: intent.weather,
                        streams: intent.streams,
                        // A host always has a meadow, and an empty list is a statement rather
                        // than an absence: `None` would tell every client to keep the meadow it
                        // has, which for a joiner is the one it generated itself.
                        eaten: Some(intent.eaten),
                        craters: intent.craters,
                        spent: intent.spent,
                    };
                    let outcome = host.publish_world(&state).await;
                    if last_world != Some(outcome) {
                        if let Some(report) = outcome.describe() {
                            push(&queue, notice(report));
                        }
                        last_world = Some(outcome);
                    }
                }
            }
            // The world mods. A client that queues one is dropped in silence -- the scene never
            // does, and it is a host's member -- and the outcome is reported only when it changes,
            // which is `publish_world`'s contract for the same reason: "the state is too big" is
            // one fact, not one per publish.
            Outcome::Command(Some(Command::Mods(state))) => {
                if let Some(Live::Host(host)) = live.as_ref() {
                    let outcome = host.publish_mods(&session::ModsState(state)).await;
                    if last_mods != Some(outcome) {
                        if let Some(report) = outcome.describe() {
                            push(&queue, notice(report));
                        }
                        last_mods = Some(outcome);
                    }
                }
            }
            // A device that went off (M19e). Silent while offline, where the bang is already
            // local and there is nobody to tell -- the same rule a pose follows.
            Outcome::Command(Some(Command::Blast {
                kind,
                key,
                x,
                z,
                by,
            })) => {
                if let Some(session) = live.as_ref()
                    && let Some(error) = session
                        .blast(parse_blast_kind(&kind), key, x, z, by.as_deref())
                        .await
                {
                    push(&queue, notice(error));
                }
            }
            // A captured voice frame. Silent while offline, like a pose: the codec speaks
            // whenever it hears speech, whether or not a session is up.
            Outcome::Command(Some(Command::Voice { seq, payload })) => {
                if let Some(session) = live.as_ref() {
                    session.publish_voice(seq, &payload).await;
                }
            }
            // Joining a swarm replaces whatever swarm is running, and is independent of
            // the session: a player can look for hosts while offline, and a host can
            // publish while playing.
            Outcome::Command(Some(Command::SwarmJoin { topic, peers })) => {
                stop_swarm(&mut swarm, &mut swarm_task);
                match join_swarm(topic, peers, &queue).await {
                    Ok((commands, task)) => {
                        if let Some(Live::Host(host)) = &live {
                            advertise_host(host, Some(&commands)).await;
                        }
                        swarm = Some(commands);
                        swarm_task = Some(task);
                    }
                    Err(text) => push(&queue, notice(text)),
                }
            }
            Outcome::Command(Some(Command::SwarmLeave)) => {
                let was_joined = swarm.is_some();
                stop_swarm(&mut swarm, &mut swarm_task);
                push(
                    &queue,
                    json!({"type": "discovered", "sessions": []}).to_string(),
                );
                push(
                    &queue,
                    json!({
                        "type": "swarm",
                        "joined": false,
                        "topic": "",
                        "id": "",
                        "ticket": "",
                        "peers": 0,
                    })
                    .to_string(),
                );
                if !was_joined {
                    push(&queue, notice("swarm: not in a swarm".to_string()));
                }
            }
            Outcome::Command(Some(Command::Noop)) => {}
            Outcome::Command(Some(command)) => {
                if let Some(session) = live.take() {
                    stop(session, swarm.as_ref()).await;
                }
                live = start(command, &queue, swarm.as_ref()).await;
            }
        }
    }
    if let Some(session) = live {
        stop(session, swarm.as_ref()).await;
    }
    stop_swarm(&mut swarm, &mut swarm_task);
}

/// Ends a session, withdrawing its swarm advert first: a host that stops hosting should
/// take its portal down rather than leave it for the TTL.
async fn stop(session: Live, swarm: Option<&SwarmCommands>) {
    if let Live::Host(_) = &session
        && let Some(swarm) = swarm
    {
        swarm.withdraw();
    }
    session.close().await;
}

/// Leaves the current swarm and stops its event task. `leave` is what tells the gossip
/// task to broadcast a withdrawal and shut its router down; the task is aborted so events
/// from the old swarm cannot land after a new one has started.
fn stop_swarm(swarm: &mut Option<SwarmCommands>, task: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(commands) = swarm.take() {
        commands.leave();
    }
    if let Some(task) = task.take() {
        task.abort();
    }
}

/// The advert this host publishes: the ticket a portal joins, the name above it, and
/// enough for the scene to say whether it could be joined.
async fn advertise_host(host: &Host, swarm: Option<&SwarmCommands>) {
    let Some(swarm) = swarm else {
        return;
    };
    swarm.advertise(Advert {
        ticket: host.ticket().to_string(),
        name: host.name().to_string(),
        clients: host.clients().await,
        protocol: proto::PROTOCOL_VERSION,
    });
}

/// Joins a swarm and starts the task that turns its events into scene lines. `topic`
/// absent means the default; `peers` are the seed nodes, from the console or a ticket.
async fn join_swarm(
    topic: Option<String>,
    peers: Vec<String>,
    queue: &Queue,
) -> Result<(SwarmCommands, tokio::task::JoinHandle<()>), String> {
    let topic = match topic
        .as_deref()
        .map(str::trim)
        .filter(|text| !text.is_empty())
    {
        Some(text) => swarm::parse_topic(text)?,
        None => SwarmConfig::default_topic(),
    };
    let mut seeds = swarm::peers_from_env()?;
    for peer in peers {
        seeds.push(swarm::parse_peer(&peer)?);
    }
    let config = SwarmConfig {
        secret: swarm::secret_from_env()?,
        peers: seeds,
        lan: std::env::var("GOATS_SWARM_LAN")
            .map(|value| value != "0")
            .unwrap_or(true),
        ..SwarmConfig::new(topic)
    };
    let mut joined = session::swarm::Swarm::join(config)
        .await
        .map_err(|error| format!("swarm: {error}"))?;
    let commands = joined.commands();
    let announced = json!({
        "type": "swarm",
        "joined": true,
        // `TopicId` serialises as its 32 bytes by default; the scene's topic is the hex
        // string `parse_topic` reads back, so it is stringified here as the reference
        // bridge does.
        "topic": joined.topic().to_string(),
        "id": joined.id().to_string(),
        "ticket": joined.ticket(),
        "peers": 0,
    })
    .to_string();
    let task = {
        let queue = queue.clone();
        tokio::spawn(async move {
            while let Some(event) = joined.next_event().await {
                let line = match event {
                    SwarmEvent::Hosts(hosts) => json!({
                        "type": "discovered",
                        "sessions": hosts,
                    })
                    .to_string(),
                    SwarmEvent::Peers(peers) => json!({
                        "type": "swarm_peers",
                        "peers": peers,
                    })
                    .to_string(),
                    SwarmEvent::Failed(text) => notice(format!("swarm: {text}")),
                };
                push(&queue, line);
            }
        })
    };
    push(queue, announced);
    Ok((commands, task))
}

/// Bring up the session a `Host` or `Join` asks for, replacing whatever was
/// live (the caller has already closed it).
async fn start(command: Command, queue: &Queue, swarm: Option<&SwarmCommands>) -> Option<Live> {
    match command {
        Command::Host { name, mods, pull } => {
            // A host serves what it runs, so a joiner missing a world mod can fetch it here
            // rather than from a status page (M18d). The packaging is a one-off read of the mods
            // directory at the moment the player hosts, and the session's set is fixed at that
            // same moment, so the two cannot drift.
            let archives = match pull.mods_dir.as_deref() {
                Some(dir) => mod_archives(dir),
                None => Vec::new(),
            };
            match Host::start_with_mods_and_archives(&name, mods, archives).await {
                Ok(host) => {
                    push(
                        queue,
                        json!({"type": "hosting", "name": host.name()}).to_string(),
                    );
                    // A swarm membership is what makes the session findable, so a host
                    // that already has one publishes now rather than waiting for the
                    // next advert window.
                    advertise_host(&host, swarm).await;
                    // The ticket is what a joiner needs; the console prints it too,
                    // but a game window cannot be selected, so it travels here.
                    push(
                        queue,
                        json!({"type": "ticket", "ticket": host.ticket()}).to_string(),
                    );
                    Some(Live::Host(host))
                }
                Err(error) => {
                    push(queue, error_event(&format!("could not host: {error}")));
                    None
                }
            }
        }
        Command::Join {
            ticket,
            name,
            mods,
            asked,
            pull,
        } => match join(&ticket, &name, mods, asked, &pull, queue).await {
            Ok(client) => {
                // The canonical name, which may differ from the one asked for:
                // names are first come, first served.
                push(
                    queue,
                    json!({"type": "welcome", "name": client.name()}).to_string(),
                );
                Some(Live::Client(client))
            }
            Err(error) => {
                push(queue, error_event(&error));
                None
            }
        },
        // Handled in `run`, which has the live session in hand.
        Command::Say { .. }
        | Command::Consume { .. }
        | Command::Pose(_)
        | Command::World(_)
        | Command::Mods(_)
        | Command::Blast { .. }
        | Command::Voice { .. }
        | Command::SwarmJoin { .. }
        | Command::SwarmLeave
        | Command::Noop
        | Command::Close => None,
    }
}

/// Join, and when the refusal was about the world-mod set, fetch what is missing and try exactly
/// once more (M18d). This is `crates/goats/src/net.rs`'s `join`, ported -- the transport and the
/// install are `session`'s and `pull`'s, and what is left here is the policy.
///
/// The retry is not a second guess: `pull::recover` asks the host what it runs, compares that with
/// the set on disk, and installs only what is missing and verifies -- so a retry happens after
/// something actually changed, and the digest it presents is the one the files now have.
///
/// Consent is settled before the host is asked anything: the default client fetches nothing, and
/// the refusal is what tells the player which flag would change that. Pulling installs code the
/// player did not choose, so the answer has to be theirs.
async fn join(
    ticket: &str,
    name: &str,
    mods: Vec<ModRef>,
    asked: bool,
    pull: &Pull,
    queue: &Queue,
) -> Result<Client, String> {
    let refusal = match Client::join_with_mods(ticket, name, mods).await {
        Ok(client) => return Ok(client),
        Err(error) => error,
    };
    if !refusal.is_mod_mismatch() || !pull.allowed(asked) {
        return Err(refusal_text(&refusal, pull.possible()));
    }
    // `allowed` implies a directory, so this is a guard rather than a case.
    let Some(mods_dir) = pull.mods_dir.as_deref() else {
        return Err(refusal_text(&refusal, false));
    };

    // What the player has, read straight off the disk: `pull` refuses an id that is already there
    // rather than replacing it, and that verdict has to be about the directory as it is now, not
    // as it was when this thread started.
    let before = mods::Loader::discover_with(mods_dir, mods::AssetMode::HashOnly);
    let fetched = match pull::recover(ticket, &before, mods_dir).await {
        Ok(pull::Recovery::Pulled(report)) if !report.installed.is_empty() => report,
        // Nothing was installed, so a retry would meet the same refusal: say what stopped it
        // rather than dialing a second time for the same answer.
        outcome => return Err(cannot_join(&refusal, outcome)),
    };

    let ids: Vec<String> = fetched
        .installed
        .iter()
        .map(|reference| reference.id.clone())
        .collect();
    // The frame loop loads these before the retried join's welcome reaches the scene, so the mods
    // and the world they describe arrive together: `pulled` is queued *before* the retried join,
    // and a queue is read in order.
    push(
        queue,
        json!({"type": "pulled", "text": fetched.describe(), "ids": ids}).to_string(),
    );
    // The digest the retry presents is the set on disk, which is what a fresh walk reads: the
    // loader above was taken before the installs. It is re-derived here rather than asked of the
    // scene, because the scene has not drained `pulled` yet and the retry is this thread's.
    let world_mods = world_mod_refs(&mods::Loader::discover_with(
        mods_dir,
        mods::AssetMode::HashOnly,
    ));
    Client::join_with_mods(ticket, name, world_mods)
        .await
        .map_err(|error| format!("could not join after fetching: {error}"))
}

/// The console's line for a refusal this client will not act on. When fetching is possible but was
/// not asked for, it says how to ask: the whole feature is one flag away, and the refusal is the
/// one moment a player needs to hear about it.
fn refusal_text(error: &session::Error, can_pull: bool) -> String {
    let text = format!("could not join: {error}");
    if can_pull && error.is_mod_mismatch() {
        format!("{text}; `connect <ticket> --pull` fetches what is missing")
    } else {
        text
    }
}

/// Why a fetch did not make a retried join worth attempting. The refusal stays in front -- it is
/// the host's own line, and it names the ids -- and what follows is what this end found out when
/// it looked at the two sets itself.
fn cannot_join(refusal: &session::Error, outcome: Result<pull::Recovery, String>) -> String {
    match outcome {
        Ok(pull::Recovery::Pulled(report)) => {
            format!("{refusal}; nothing was installed ({})", report.describe())
        }
        Ok(pull::Recovery::Matched) => {
            format!("{refusal}; this client already runs the host's mods, so fetching cannot help")
        }
        Ok(pull::Recovery::Unfixable(mismatch)) => format!(
            "could not join: {}; fetching cannot settle it: only you can add or drop a mod",
            mismatch.describe()
        ),
        Ok(pull::Recovery::Unreachable(reason)) => {
            format!("{refusal}; this host does not serve its mods ({reason})")
        }
        Err(error) => format!("{refusal}; the fetch failed ({error})"),
    }
}

/// The world-mod set a loader presents, in the shape the handshake compares. The scene's own
/// `world_mod_refs` reads its `ModHost`; this one is the bridge's, over a fresh walk of the
/// directory the retry presents -- the same loader `crates/mods` builds the host's digest with.
fn world_mod_refs(loader: &mods::Loader) -> Vec<ModRef> {
    let mut refs: Vec<ModRef> = loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .map(|manifest| ModRef {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            hash: manifest.hash,
        })
        .collect();
    refs.sort_by(|a, b| a.id.cmp(&b.id));
    refs
}

/// The archives a host serves a fetching joiner (M18): every world mod in its distributable form,
/// so a fetch hands over exactly the mod the digest was taken over. Only world mods -- a client
/// mod is local and never travels. The walk is `HashOnly` because `archive_source` re-reads the
/// bytes from disk; this end only needs the digests. This is `crates/goats/src/lib.rs`'s
/// `mod_archives` and `crates/server/src/main.rs`'s, over the same `mods` crate.
fn mod_archives(dir: &Path) -> Vec<(ModRef, Vec<u8>)> {
    let loader = mods::Loader::discover_with(dir, mods::AssetMode::HashOnly);
    loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .filter_map(|manifest| {
            let reference = ModRef {
                id: manifest.id.clone(),
                version: manifest.version.clone(),
                hash: manifest.hash,
            };
            match mods::archive_source(&manifest.source) {
                Ok(bytes) => Some((reference, bytes)),
                Err(error) => {
                    eprintln!("[net] could not package {} for fetch: {error}", manifest.id);
                    None
                }
            }
        })
        .collect()
}

/// A session event as the line the scene reads.
///
/// The client's own vocabulary, field for field: `crates/goats/src/net.rs`
/// serialises its `Event` with `#[serde(tag = "type", rename_all =
/// "snake_case")]`, so the tag is `type`, `BlastReport` is `blast_report`, a
/// peer's pose is nested under `state` rather than flattened, and the world's
/// fields sit directly on the event. Matching it exactly is what makes "a scene
/// written against `net.js` reads these unchanged" true rather than aspirational.
fn event_json(event: Net) -> String {
    let value = match event {
        Net::Session { seed } => json!({"type": "session", "seed": seed}),
        Net::Joined { name } => json!({"type": "joined", "name": name}),
        Net::Left { name } => json!({"type": "left", "name": name}),
        Net::Roster { names } => json!({"type": "roster", "names": names}),
        Net::Chat { from, text, direct } => {
            json!({"type": "chat", "from": from, "text": text, "direct": direct})
        }
        Net::Peer { name, state } => json!({"type": "peer", "name": name, "state": state}),
        // The server's world: bots, sky, streams and meadow, for a client to
        // mirror instead of simulating. `eaten`, `craters` and `spent` are null
        // when the host's snapshot was over the datagram budget and shed them --
        // which the scene reads as "keep the one you have".
        Net::World {
            bots,
            weather,
            streams,
            eaten,
            craters,
            spent,
        } => json!({
            "type": "world",
            "bots": bots,
            "weather": weather,
            "streams": streams,
            "eaten": eaten,
            "craters": craters,
            "spent": spent,
        }),
        // Every world mod's state, opaque here and to the transport.
        Net::Mods { mods } => json!({"type": "mods", "mods": mods.0}),
        // A bite, for the host's scene: the next world snapshot carries it back.
        Net::Consume { key } => json!({"type": "consume", "key": key}),
        // A bang the host relayed, with the host's own coordinates for the
        // device -- which is why a client cannot lie about where it went off.
        Net::Blast {
            kind,
            key,
            x,
            z,
            by,
        } => json!({
            "type": "blast",
            "kind": kind,
            "key": key,
            "x": x,
            "z": z,
            "by": by,
        }),
        Net::BlastReport { kind, key, by } => json!({
            "type": "blast_report",
            "kind": kind,
            "key": key,
            "by": by,
        }),
        Net::Notice(text) => json!({"type": "notice", "text": text}),
        Net::Disconnected => json!({"type": "disconnected"}),
        // Filtered before it gets here (Opus bytes are not a line), but the
        // match has to be total.
        Net::Voice { .. } => json!({"type": "voice"}),
    };
    value.to_string()
}

/// The world-mod set a client presents, as `ModHost::world_mod_refs` writes it: a JSON array of
/// `{id, version, hash}` (`APIv1.md` section 6.2). An empty string is the empty set, so a bare
/// `host("x", "")` is a session with no world mods -- what the gates and a `--no-mods` client
/// present. Anything else that will not parse is an `error: ...` the scene can read, which is far
/// better than silently presenting nothing and being refused for a reason that is not the truth.
fn parse_mod_refs(json: &str) -> Result<Vec<ModRef>, String> {
    if json.trim().is_empty() {
        return Ok(Vec::new());
    }
    serde_json::from_str::<Vec<ModRef>>(json).map_err(|error| error.to_string())
}

fn notice(text: String) -> String {
    json!({"type": "notice", "text": text}).to_string()
}

fn error_event(text: &str) -> String {
    json!({"type": "error", "text": text}).to_string()
}

/// The scene spells a device's kind with a string -- `BlastKind`'s own serialisation, so the two
/// agree by construction -- and anything else reads as a mine rather than being an error, the way
/// an unknown gait reads as idle.
fn parse_blast_kind(name: &str) -> BlastKind {
    match name {
        "trap" => BlastKind::Trap,
        _ => BlastKind::Mine,
    }
}

fn parse_gait(name: &str) -> Gait {
    match name {
        "walk" => Gait::Walk,
        "trot" => Gait::Trot,
        "run" => Gait::Run,
        "jump" => Gait::Jump,
        "flung" => Gait::Flung,
        "sleep" => Gait::Sleep,
        "eat" => Gait::Eat,
        "dead" => Gait::Dead,
        "fly" => Gait::Fly,
        "fall" => Gait::Fall,
        _ => Gait::Idle,
    }
}

/// The queue lock, surviving a panic on the runtime thread rather than
/// poisoning every later read.
fn lock(queue: &Queue) -> MutexGuard<'_, VecDeque<String>> {
    queue.lock().unwrap_or_else(|error| error.into_inner())
}

fn push(queue: &Queue, line: String) {
    lock(queue).push_back(line);
}

/// Queue one delivered voice frame, surviving a poisoned lock as `push` does.
fn queue_voice(queue: &VoiceQueue, frame: (String, u32, Vec<u8>)) {
    queue
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .push_back(frame);
}

/// Take every voice frame delivered since the last call, for the codec half to decode. The
/// frame loop owns this drain (`pull_voice`), so it runs on the frame thread.
fn drain_voice(queue: &VoiceQueue) -> Vec<(String, u32, Vec<u8>)> {
    queue
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .drain(..)
        .collect()
}
