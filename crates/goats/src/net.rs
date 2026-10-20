//! The network bridge: the Rust end of the line-based channel to the scene.
//!
//! The JS engine has no sockets, so every network operation happens here, and
//! the frame loop never awaits: the scene queues intents, the host drains them
//! with `sceneNetDrain()` at a frame boundary and hands them to a runtime
//! thread, and events come back through `sceneNetEvent(line)`. Both directions
//! are JSON lines, which keeps the bridge stubbable and readable.
//!
//! The runtime thread owns the tokio runtime and the session, so nothing that
//! touches iroh is ever polled from the frame loop.
//!
//! The one place where the bridge does more than move lines is a refused join
//! (M18d): when the host's world-mod set is what it objects to, this thread asks
//! the host what it runs, fetches what is missing, installs it, re-derives the
//! set it presents and retries the join once. The fetch and the install are
//! `pull`'s; what lives here is the policy -- consent, the retry, and telling the
//! frame loop to load what arrived.

use std::path::{Path, PathBuf};
use std::thread;

use mods::{AssetMode, Loader};
use serde::Deserialize;
use session::registry::{Registry, RegistryConfig};
use session::swarm::{self, Advert, SwarmCommands, SwarmConfig, SwarmEvent};
use tokio::runtime;
use tokio::sync::mpsc;

use session::bridge::{Command, Event, degrees, parse_blast_kind, parse_gait, to_event as bridge};

/// A delivered frame on its way to the audio module: the speaker's canonical
/// name (stamped by the relay), the sequence number and the encoded payload.
pub type VoiceIn = (String, u32, Vec<u8>);

/// The frames queued for the audio module before the oldest is dropped. Voice is
/// real-time, so a backlog is worse than a gap: 64 frames is more than a second
/// of speech, far past the point where late audio is useful.
const VOICE_BACKLOG: usize = 64;

/// A cloneable handle to the runtime thread's intent queue, for the audio module
/// to queue its captured frames without going through JSON.
#[derive(Clone)]
pub struct VoiceSender(mpsc::UnboundedSender<Command>);

impl VoiceSender {
    pub fn send(&self, seq: u32, payload: Vec<u8>) {
        let _ = self.0.send(Command::Voice { seq, payload });
    }
}

/// What this client does about a join the host refused for mods (M18d).
///
/// Pulling installs code this player did not choose, so it is never silent: the
/// default is that only an explicit `connect <ticket> --pull` fetches, and
/// `--pull` on the command line is the standing "ask me no questions" for a
/// script or a player who has decided to trust this. Without a mods directory
/// there is nowhere to install, so nothing is ever fetched.
pub struct Pull {
    /// Where a fetched mod is installed; `None` with `--no-mods`, or when no
    /// mods directory was found and `--pull` was not given.
    pub mods_dir: Option<PathBuf>,
    /// `--pull`: fetch on any refused join, without the flag on the command.
    pub always: bool,
}

impl Pull {
    /// May this join fetch? `asked` is the console's per-command consent.
    fn allowed(&self, asked: bool) -> bool {
        self.mods_dir.is_some() && (self.always || asked)
    }

    /// Is there anywhere to install if the player did ask?
    fn possible(&self) -> bool {
        self.mods_dir.is_some()
    }
}

/// The registry's switches for this run. The embedding host builds this from the
/// environment; the test constructor passes `None`, so no test starts an extra
/// endpoint or joins a catalogue it did not ask for.
pub struct RegistryOpts {
    pub config: RegistryConfig,
    /// The directory to announce when sharing is on. `None` is the default: a
    /// client reads the catalogue and can fetch from it, but publishes nothing.
    pub share: Option<PathBuf>,
}

impl RegistryOpts {
    /// `GOATS_MODS_REGISTRY=0` disables the registry. `GOATS_MODS_SHARE=1`
    /// announces this client's world mods, which is off by default because it is
    /// a public claim about what this machine has.
    pub fn from_env(mods_dir: &Path) -> Result<Option<RegistryOpts>, String> {
        let Some(config) = RegistryConfig::from_env(mods_dir.join(".registry"))? else {
            return Ok(None);
        };
        let share = std::env::var("GOATS_MODS_SHARE")
            .map(|value| value.trim() != "0")
            .unwrap_or(false)
            .then(|| mods_dir.to_path_buf());
        Ok(Some(RegistryOpts { config, share }))
    }
}

/// What the swarm task needs from the registry: the ticket to publish and the
/// handle it seeds from the tickets it hears. Cloned into the event task, which
/// is why it is the small handle and not the registry itself.
#[derive(Clone)]
struct RegistryBridge {
    peers: session::registry::RegistryPeers,
    ticket: String,
}

/// The frame loop's handle on the networking thread.
pub struct Net {
    commands: mpsc::UnboundedSender<Command>,
    events: mpsc::UnboundedReceiver<String>,
    voice_out: VoiceSender,
    /// The audio module takes this once; frames are dropped while it is here, so
    /// a client without a working microphone never grows a backlog.
    voice_in: Option<mpsc::Receiver<VoiceIn>>,
}

impl Net {
    /// Starts the runtime thread with no swarm: the constructor the cases in this
    /// file use, so a test can never be joined by a beacon it did not ask for.
    /// The game uses [`Net::start_with_swarm`].
    #[cfg(test)]
    pub fn start(world_mods: Vec<session::ModRef>, pull: Pull) -> Net {
        Self::start_with_swarm(world_mods, pull, None, false)
    }

    /// Starts the runtime thread, optionally joining the default swarm before
    /// the first command. A joined swarm is what discovery runs on: the LAN
    /// beacon needs an endpoint to advertise, and auto-joining is what makes the
    /// client zero-config on a local network.
    pub fn start_with_swarm(
        world_mods: Vec<session::ModRef>,
        pull: Pull,
        registry: Option<RegistryOpts>,
        auto_swarm: bool,
    ) -> Net {
        let (command_tx, command_rx) = mpsc::unbounded_channel();
        let (event_tx, event_rx) = mpsc::unbounded_channel();
        let (voice_tx, voice_rx) = mpsc::channel(VOICE_BACKLOG);
        thread::Builder::new()
            .name("net".to_string())
            .spawn(move || {
                let runtime = match runtime::Builder::new_multi_thread().enable_all().build() {
                    Ok(runtime) => runtime,
                    Err(error) => {
                        eprintln!("[net] could not start a runtime: {error}");
                        return;
                    }
                };
                runtime.block_on(run(
                    command_rx, event_tx, voice_tx, world_mods, pull, registry, auto_swarm,
                ));
            })
            .expect("spawn the networking thread");
        Net {
            voice_out: VoiceSender(command_tx.clone()),
            commands: command_tx,
            events: event_rx,
            voice_in: Some(voice_rx),
        }
    }

    /// The next event for the scene, if one is ready. Never blocks, so the frame
    /// loop can drain this at a boundary.
    pub fn next_event(&mut self) -> Option<String> {
        self.events.try_recv().ok()
    }

    /// Queues one intent line from the scene.
    pub fn send(&self, line: &str) {
        match serde_json::from_str::<Command>(line) {
            Ok(command) => {
                if self.commands.send(command).is_err() {
                    eprintln!("[net] the networking thread has stopped");
                }
            }
            Err(error) => eprintln!("[net] ignoring bad intent {line:?}: {error}"),
        }
    }

    /// A handle the audio module queues captured frames through.
    pub fn voice_sender(&self) -> VoiceSender {
        self.voice_out.clone()
    }

    /// Hands the audio module its end of the voice channel. Called once, by
    /// `Voice::start`; a second call gets nothing.
    pub fn take_voice_receiver(&mut self) -> Option<mpsc::Receiver<VoiceIn>> {
        self.voice_in.take()
    }
}

/// The scene's voice-gain intent, if this line is one: `{"type":"voice_gain",
/// "gain":0.0}`. The gain belongs to the audio module on the frame loop, not to
/// the runtime thread, so `main` intercepts it rather than `Net::send`.
pub fn voice_gain(line: &str) -> Option<f32> {
    #[derive(Deserialize)]
    struct Intent {
        #[serde(rename = "type")]
        kind: String,
        gain: f32,
    }
    let intent: Intent = serde_json::from_str(line).ok()?;
    (intent.kind == "voice_gain").then_some(intent.gain)
}

/// The session the runtime thread is currently running, if any.
enum Live {
    Host(session::Host),
    Client(session::Client),
}

impl Live {
    async fn next_event(&mut self) -> Option<session::Event> {
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

    /// Says something as this player, returning an error to report when the
    /// client could not send it.
    async fn say(&self, text: &str) -> Option<String> {
        match self {
            Live::Host(host) => {
                host.say(text).await;
                None
            }
            Live::Client(client) => client.say(text).await.err().map(|error| error.to_string()),
        }
    }

    /// Sends this player's goat. Fire-and-forget: the channel is unreliable, so
    /// a dropped snapshot is simply replaced by the next one.
    async fn publish(&self, state: &session::PeerState) {
        match self {
            Live::Host(host) => host.publish(state).await,
            Live::Client(client) => client.publish(state),
        }
    }

    /// Sends the world. Only a host has one to send; a client drops it, and there
    /// is then nothing to report. The outcome comes back so the caller can say
    /// what happened when it changes.
    async fn publish_world(
        &self,
        bots: &[session::BotState],
        weather: &session::WeatherState,
        streams: session::Streams,
        eaten: &[session::EatenCell],
        craters: Option<&[session::Crater]>,
        spent: Option<&[session::Spent]>,
    ) -> Option<session::WorldOutcome> {
        match self {
            Live::Host(host) => Some(
                host.publish_world(&session::WorldState {
                    bots: bots.to_vec(),
                    weather: weather.clone(),
                    streams,
                    // The scene only ever queues a world while it is hosting, and
                    // it always has a meadow to send: a `None` here is Rust's,
                    // not the scene's.
                    eaten: Some(eaten.to_vec()),
                    // A list the scene did not send stays `None`, which the wire reads
                    // as "keep the one you have". Sending an empty one instead would
                    // tell every client its ground is flat, which is a worse lie than
                    // saying nothing.
                    craters: craters.map(|list| list.to_vec()),
                    spent: spent.map(|list| list.to_vec()),
                })
                .await,
            ),
            Live::Client(_) => None,
        }
    }

    /// Sends every world mod's state, on its own datagram. Only a host has any.
    async fn publish_mods(&self, mods: serde_json::Value) -> Option<session::ModsOutcome> {
        match self {
            Live::Host(host) => Some(host.publish_mods(&session::ModsState(mods)).await),
            Live::Client(_) => None,
        }
    }

    /// Reports a bite. The host's own scene already recorded its own, so this is
    /// a no-op there; a client tells the host and waits for the snapshot.
    async fn consume(&self, key: i64) -> Option<String> {
        match self {
            Live::Host(_) => None,
            Live::Client(client) => client
                .consume(key)
                .await
                .err()
                .map(|error| error.to_string()),
        }
    }

    /// Says one captured voice frame. A client sends it up to the host to be
    /// re-tagged and relayed; the host sends its own straight out.
    async fn publish_voice(&self, seq: u32, payload: &[u8]) {
        match self {
            Live::Host(host) => host.publish_voice(seq, payload).await,
            Live::Client(client) => client.publish_voice(seq, payload),
        }
    }

    /// A device went off (M19e): this process's own goat or herd, or -- on the host,
    /// when `by` names somebody else -- a bang a client reported.
    ///
    /// Only a host relays, and a reported bang is not fired again here: the reporter
    /// fired it, this process fires *its* copy of it (the ground, the herd), and
    /// `except` is what keeps the bang from landing twice on the one goat that has
    /// already felt it.
    async fn blast(
        &self,
        kind: session::BlastKind,
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

/// The runtime thread: run one command at a time, forwarding session events
/// back to the scene as they arrive.
async fn run(
    mut commands: mpsc::UnboundedReceiver<Command>,
    events: mpsc::UnboundedSender<String>,
    voice: mpsc::Sender<VoiceIn>,
    world_mods: Vec<session::ModRef>,
    pull: Pull,
    registry: Option<RegistryOpts>,
    auto_swarm: bool,
) {
    let mut live: Option<Live> = None;
    // The swarm this client is in, if any, and the task draining its events. The
    // command side is what hosts advertise through; the task is aborted on a
    // topic switch so a stale list cannot overtake the new swarm's.
    let mut swarm: Option<SwarmCommands> = None;
    let mut swarm_task: Option<tokio::task::JoinHandle<()>> = None;
    // What this client presents at its next join. A pull can change it, and the
    // change has to outlive the join that caused it: the host command uses the
    // same set (M18d).
    let mut world_mods = world_mods;
    // The registry: a catalogue on its own topic and the blobs a fetch moves.
    // It is opt-in at the host level (the test constructor passes `None`), and
    // sharing is a second opt-in (`GOATS_MODS_SHARE`).
    let registry = match registry {
        Some(opts) => match Registry::start(opts.config).await {
            Ok(registry) => {
                // The ticket is the only way another node can seed this registry
                // until the swarm carries it, and a console line is hard to copy
                // from a game window. stderr is where the host ticket goes too.
                eprintln!("[net] registry ticket: {}", registry.ticket());
                emit(
                    &events,
                    Event::Notice {
                        text: format!("registry: ticket {}", registry.ticket()),
                    },
                );
                if let Some(dir) = opts.share.as_deref() {
                    share_mods(&registry, dir, &events).await;
                }
                Some(registry)
            }
            Err(error) => {
                emit(
                    &events,
                    Event::Notice {
                        text: format!("registry: {error}"),
                    },
                );
                None
            }
        },
        None => None,
    };
    // The registry is up before the swarm, because the swarm is how a peer learns
    // this ticket and how this node learns everybody else's.
    let registry_bridge = registry.as_ref().map(|registry| RegistryBridge {
        peers: registry.peers(),
        ticket: registry.ticket().to_string(),
    });
    if auto_swarm {
        // Zero-config: join the default topic before the first command, so the
        // LAN beacon and any seed in the environment are already running when a
        // player starts `host` or looks for a session.
        match join_swarm(None, Vec::new(), registry_bridge.as_ref(), &events).await {
            Ok((commands, task)) => {
                swarm = Some(commands);
                swarm_task = Some(task);
            }
            Err(text) => emit(&events, Event::Notice { text }),
        }
    }
    // The last thing said about each high-rate datagram. The host sends them ten
    // times a second, so a report belongs on the change, not on every send.
    let mut last_world = session::WorldOutcome::Whole;
    let mut last_mods = session::ModsOutcome::Sent;
    // How often a hosting client restates its swarm advert. The interval is only
    // polled inside a live session; the swarm task's own timer covers the gaps.
    let mut announce = tokio::time::interval(session::swarm::ADVERT_EVERY);
    announce.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        /// What one turn of the loop produced.
        enum Outcome {
            Command(Option<Command>),
            /// The session's event stream ended.
            Ended,
        }

        // With a session running, wait on both; otherwise only commands exist.
        // Forwarding happens inside the select arm so the borrow of `live` ends
        // before the command is handled below, which needs it mutably.
        let outcome = match live.as_mut() {
            Some(session) => tokio::select! {
                command = commands.recv() => Outcome::Command(command),
                event = session.next_event() => match event {
                    // Voice is the audio module's, not the scene's: Opus bytes
                    // are not a line, so they take the side channel instead of
                    // `emit`. `try_send` drops the frame if nothing is reading.
                    Some(session::Event::Voice { from, seq, payload }) => {
                        let _ = voice.try_send((from, seq, payload));
                        continue;
                    }
                    Some(event) => {
                        // The player count is part of the advert, so a roster
                        // change is the moment to restate it rather than wait
                        // for the next window.
                        if matches!(&event, session::Event::Roster { .. })
                            && let Live::Host(host) = &*session
                        {
                            advertise_host(host, swarm.as_ref()).await;
                        }
                        emit(&events, bridge(event));
                        continue;
                    }
                    None => Outcome::Ended,
                },
                // A host keeps its advert fresh for as long as it is hosting.
                // The swarm task restates the last advert too; this is what
                // refreshes the player count and recovers from a dropped one.
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
                if let Some(session) = live.take() {
                    stop(session, swarm.as_ref()).await;
                }
            }
            // `Say` needs the live session rather than a new one, so it is
            // handled here; everything else reconfigures the session.
            Outcome::Command(Some(command)) => match command {
                Command::Say { text } => match live.as_ref() {
                    Some(session) => {
                        if let Some(error) = session.say(&text).await {
                            emit(&events, Event::Notice { text: error });
                        }
                    }
                    None => emit(
                        &events,
                        Event::Notice {
                            text: "not in a session".to_string(),
                        },
                    ),
                },
                // Poses also need the live session, and are just as silent when
                // there is none: the scene only queues them in a session.
                Command::Pose {
                    x,
                    z,
                    yaw,
                    phase,
                    speed,
                    gait,
                    py,
                    pitch,
                    roll,
                } => {
                    if let Some(session) = live.as_ref() {
                        session
                            .publish(&session::PeerState {
                                x,
                                z,
                                yaw,
                                phase,
                                speed,
                                gait: parse_gait(&gait),
                                py,
                                pitch: degrees(pitch),
                                roll: degrees(roll),
                            })
                            .await;
                    }
                }
                // The server's world: only meaningful while hosting.
                Command::World {
                    bots,
                    weather,
                    streams,
                    eaten,
                    craters,
                    spent,
                } => {
                    if let Some(session) = live.as_ref()
                        && let Some(outcome) = session
                            .publish_world(
                                &bots,
                                &weather,
                                streams,
                                &eaten,
                                craters.as_deref(),
                                spent.as_deref(),
                            )
                            .await
                        && outcome != last_world
                    {
                        if let Some(text) = outcome.describe() {
                            eprintln!("[net] {text}");
                        }
                        last_world = outcome;
                    }
                }
                // Every world mod's state, beside the world and on its own
                // datagram.
                Command::Mods { mods } => {
                    if let Some(session) = live.as_ref()
                        && let Some(outcome) = session.publish_mods(mods).await
                        && outcome != last_mods
                    {
                        if let Some(text) = outcome.describe() {
                            eprintln!("[net] {text}");
                        }
                        last_mods = outcome;
                    }
                }
                // A bite this player took, reported to the host so its scene can
                // record it. Silent while offline, where it is already local.
                Command::Consume { key } => {
                    if let Some(session) = live.as_ref()
                        && let Some(error) = session.consume(key).await
                    {
                        emit(&events, Event::Notice { text: error });
                    }
                }
                // A captured voice frame. Silent while offline, like a pose:
                // the audio module speaks whenever it hears speech, whether or
                // not a session is up.
                Command::Voice { seq, payload } => {
                    if let Some(session) = live.as_ref() {
                        session.publish_voice(seq, &payload).await;
                    }
                }
                // A device went off, here or somewhere else (M19e). Silent while
                // offline: the bang is already local and there is nobody to tell.
                Command::Blast {
                    kind,
                    key,
                    x,
                    z,
                    by,
                } => {
                    if let Some(session) = live.as_ref()
                        && let Some(error) = session
                            .blast(parse_blast_kind(&kind), key, x, z, by.as_deref())
                            .await
                    {
                        emit(&events, Event::Notice { text: error });
                    }
                }
                // Joining a swarm replaces whatever swarm is running, and is
                // independent of the session: a player can look for hosts while
                // offline, and a host can publish while playing.
                Command::SwarmJoin { topic, peers } => {
                    stop_swarm(&mut swarm, &mut swarm_task);
                    match join_swarm(topic, peers, registry_bridge.as_ref(), &events).await {
                        Ok((commands, task)) => {
                            if let Some(Live::Host(host)) = &live {
                                advertise_host(host, Some(&commands)).await;
                            }
                            swarm = Some(commands);
                            swarm_task = Some(task);
                        }
                        Err(text) => emit(&events, Event::Notice { text }),
                    }
                }
                Command::SwarmLeave => {
                    let was_joined = swarm.is_some();
                    stop_swarm(&mut swarm, &mut swarm_task);
                    emit(
                        &events,
                        Event::Discovered {
                            sessions: Vec::new(),
                        },
                    );
                    emit(
                        &events,
                        Event::Swarm {
                            joined: false,
                            topic: String::new(),
                            id: String::new(),
                            ticket: String::new(),
                            peers: 0,
                        },
                    );
                    if !was_joined {
                        emit(
                            &events,
                            Event::Notice {
                                text: "swarm: not in a swarm".to_string(),
                            },
                        );
                    }
                }
                other => {
                    live = start(
                        other,
                        live.take(),
                        &events,
                        &mut world_mods,
                        &pull,
                        swarm.as_ref(),
                        registry.as_ref(),
                    )
                    .await
                }
            },
            Outcome::Command(None) => break,
        }
    }
    if let Some(session) = live {
        stop(session, swarm.as_ref()).await;
    }
    stop_swarm(&mut swarm, &mut swarm_task);
    if let Some(registry) = registry {
        registry.shutdown().await;
    }
}

/// Ends a session, withdrawing its swarm advert first: a host that stops hosting
/// should take its portal down rather than leave it for the TTL.
async fn stop(session: Live, swarm: Option<&SwarmCommands>) {
    if let Live::Host(_) = &session
        && let Some(swarm) = swarm
    {
        swarm.withdraw();
    }
    session.close().await;
}

/// Leaves the current swarm and stops its event task. `leave` is what tells the
/// gossip task to broadcast a withdrawal and shut its router down; the task is
/// aborted so events from the old swarm cannot land after a new one has started.
fn stop_swarm(swarm: &mut Option<SwarmCommands>, task: &mut Option<tokio::task::JoinHandle<()>>) {
    if let Some(commands) = swarm.take() {
        commands.leave();
    }
    if let Some(task) = task.take() {
        task.abort();
    }
}

/// The advert this host publishes: the ticket a portal joins, the name above it,
/// and enough for the scene to say whether it could be joined.
async fn advertise_host(host: &session::Host, swarm: Option<&SwarmCommands>) {
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

/// Joins a swarm and starts the task that turns its events into scene lines.
/// `topic` absent means the default; `peers` are the seed nodes, from the console
/// or a ticket. `registry` is the catalogue this node runs, if any: its ticket is
/// published with the advert, and peers' tickets are handed to its peer set.
async fn join_swarm(
    topic: Option<String>,
    peers: Vec<String>,
    registry: Option<&RegistryBridge>,
    events: &mpsc::UnboundedSender<String>,
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
    if let Some(registry) = registry {
        commands.registry(registry.ticket.clone());
    }
    let announced = Event::Swarm {
        joined: true,
        topic: joined.topic().to_string(),
        id: joined.id().to_string(),
        ticket: joined.ticket().to_string(),
        peers: 0,
    };
    let task = {
        let events = events.clone();
        let registry = registry.cloned();
        tokio::spawn(async move {
            while let Some(event) = joined.next_event().await {
                match event {
                    SwarmEvent::Hosts(hosts) => {
                        emit(&events, Event::Discovered { sessions: hosts })
                    }
                    SwarmEvent::Peers(peers) => emit(&events, Event::SwarmPeers { peers }),
                    SwarmEvent::Failed(text) => emit(
                        &events,
                        Event::Notice {
                            text: format!("swarm: {text}"),
                        },
                    ),
                    // A peer's catalogue is a separate endpoint; this is the
                    // introduction, and a bad or unreachable ticket is gossip's
                    // problem rather than a line for the console.
                    SwarmEvent::Registry(ticket) => {
                        if let Some(registry) = &registry {
                            let _ = registry.peers.join(&ticket);
                        }
                    }
                }
            }
        })
    };
    emit(events, announced);
    Ok((commands, task))
}

/// Announce the mods this client loads (M18f). Sharing is a public claim about
/// what this machine has, so it happens only when `GOATS_MODS_SHARE` asks for
/// it -- never as a side effect of hosting or of joining a topic.
async fn share_mods(registry: &Registry, mods_dir: &Path, events: &mpsc::UnboundedSender<String>) {
    let loader = Loader::discover_with(mods_dir, AssetMode::HashOnly);
    for error in loader.errors() {
        emit(
            events,
            Event::Notice {
                text: format!("registry: {error}"),
            },
        );
    }

    let shared = pull::share(registry, &loader).await;
    for (id, reason) in &shared.failed {
        emit(
            events,
            Event::Notice {
                text: format!("registry: {id} not shared: {reason}"),
            },
        );
    }
    emit(
        events,
        Event::Notice {
            text: format!("registry: {}", shared.describe()),
        },
    );
}

/// Runs one command, replacing whatever session was live.
async fn start(
    command: Command,
    current: Option<Live>,
    events: &mpsc::UnboundedSender<String>,
    world_mods: &mut Vec<session::ModRef>,
    pull: &Pull,
    swarm: Option<&SwarmCommands>,
    registry: Option<&Registry>,
) -> Option<Live> {
    if let Some(session) = current {
        stop(session, swarm).await;
    }
    match command {
        Command::Close => None,
        // Handled in `run`, which has the live session in hand.
        Command::Say { .. }
        | Command::Pose { .. }
        | Command::World { .. }
        | Command::Mods { .. }
        | Command::Consume { .. }
        | Command::Voice { .. }
        | Command::Blast { .. }
        | Command::SwarmJoin { .. }
        | Command::SwarmLeave => None,
        Command::Host { name } => {
            // A host serves what it runs, so a joiner missing a world mod can
            // fetch it here rather than from a status page (M18d). The packaging
            // is a one-off read of the mods directory at the moment the player
            // hosts, and the session's set is fixed at that same moment, so the
            // two cannot drift.
            let archives = match pull.mods_dir.as_deref() {
                Some(dir) => crate::mod_archives(&Loader::discover(dir)),
                None => Vec::new(),
            };
            match session::Host::start_with_mods_and_archives(&name, world_mods.to_vec(), archives)
                .await
            {
                Ok(host) => {
                    // The console shows the ticket, but it cannot be selected in a
                    // game window; stderr puts it where the player launched the
                    // game, which is the only place it can actually be copied from.
                    eprintln!("[net] hosting {} - ticket: {}", host.name(), host.ticket());
                    emit(
                        events,
                        Event::Hosting {
                            name: host.name().to_string(),
                        },
                    );
                    emit(
                        events,
                        Event::Ticket {
                            ticket: host.ticket().to_string(),
                        },
                    );
                    // Hosting is what makes a swarm membership useful: publish
                    // the ticket before returning, so a client already watching
                    // the topic sees a portal as soon as this session exists.
                    advertise_host(&host, swarm).await;
                    Some(Live::Host(host))
                }
                Err(error) => {
                    emit(
                        events,
                        Event::Error {
                            text: format!("could not host: {error}"),
                        },
                    );
                    None
                }
            }
        }
        Command::Join {
            ticket,
            name,
            pull: asked,
            ..
        } => match join(&ticket, &name, asked, pull, world_mods, events, registry).await {
            Ok(client) => {
                // This client is a player now, not a host: whatever it said on
                // the swarm before is no longer true.
                if let Some(swarm) = swarm {
                    swarm.withdraw();
                }
                emit(
                    events,
                    Event::Welcome {
                        name: client.name().to_string(),
                    },
                );
                Some(Live::Client(client))
            }
            Err(text) => {
                emit(events, Event::Error { text });
                None
            }
        },
    }
}

/// Join, and when the refusal was about the world-mod set, fetch what is missing
/// and try exactly once more (M18d).
///
/// The retry is not a second guess. `pull::recover` asks the host what it runs,
/// compares that with the set on disk, and installs only what is missing and
/// verifies -- so a retry happens after something actually changed, and the digest
/// it presents is the one the files now have.
///
/// Consent is settled before the host is asked anything: the default client
/// fetches nothing, and the refusal is what tells the player which flag would
/// change that. Pulling installs code the player did not choose, so the answer
/// has to be theirs.
async fn join(
    ticket: &str,
    name: &str,
    asked: bool,
    pull: &Pull,
    world_mods: &mut Vec<session::ModRef>,
    events: &mpsc::UnboundedSender<String>,
    registry: Option<&Registry>,
) -> Result<session::Client, String> {
    let refusal = match session::Client::join_with_mods(ticket, name, world_mods.clone()).await {
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

    // What the player has, read straight off the disk: `pull` refuses an id that
    // is already there rather than replacing it, and that verdict has to be about
    // the directory as it is now, not as it was when this thread started.
    let before = Loader::discover_with(mods_dir, AssetMode::HashOnly);
    let fetched = match pull::recover_with(ticket, &before, mods_dir, registry).await {
        Ok(pull::Recovery::Pulled(report)) if !report.installed.is_empty() => report,
        // Nothing was installed, so a retry would meet the same refusal: say what
        // stopped it rather than dialing a second time for the same answer.
        outcome => return Err(cannot_join(&refusal, outcome)),
    };

    let ids: Vec<String> = fetched
        .installed
        .iter()
        .map(|reference| reference.id.clone())
        .collect();
    // The frame loop loads these before the retried join's welcome reaches the
    // scene, so the mods and the world they describe arrive together.
    emit(
        events,
        Event::Pulled {
            text: fetched.describe(),
            ids,
        },
    );
    // The digest the retry presents is the set on disk, which is what a fresh walk
    // reads: the loader above was taken before the installs.
    *world_mods = crate::world_mod_refs(&Loader::discover_with(mods_dir, AssetMode::HashOnly));
    session::Client::join_with_mods(ticket, name, world_mods.clone())
        .await
        .map_err(|error| format!("could not join after fetching: {error}"))
}

/// The console's line for a refusal this client will not act on. When fetching is
/// possible but was not asked for, it says how to ask: the whole feature is one
/// flag away, and the refusal is the one moment a player needs to hear about it.
fn refusal_text(error: &session::Error, can_pull: bool) -> String {
    let text = format!("could not join: {error}");
    if can_pull && error.is_mod_mismatch() {
        format!("{text}; `connect <ticket> --pull` fetches what is missing")
    } else {
        text
    }
}

/// Why a fetch did not make a retried join worth attempting. The refusal stays in
/// front -- it is the host's own line, and it names the ids -- and what follows is
/// what this end found out when it looked at the two sets itself.
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

/// The ids a `pulled` event names, or `None` when this line is something else. The
/// frame loop has host work to do before the scene sees a pull's mods, and this is
/// how it finds out -- the same shape [`voice_gain`] uses for the one other event
/// with a side channel.
pub fn pulled_ids(line: &str) -> Option<Vec<String>> {
    #[derive(Deserialize)]
    struct Event {
        #[serde(rename = "type")]
        kind: String,
        #[serde(default)]
        ids: Vec<String>,
    }
    let event: Event = serde_json::from_str(line).ok()?;
    (event.kind == "pulled").then_some(event.ids)
}

/// Serialises an event and queues it for the scene. Voice is dropped: it is
/// Opus bytes for the audio module, and there is no reader for it here.
fn emit(events: &mpsc::UnboundedSender<String>, event: Event) {
    if let Some(line) = session::bridge::encode(&event) {
        let _ = events.send(line);
    }
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use super::*;

    #[test]
    fn the_voice_gain_intent_is_recognized_and_nothing_else_is() {
        assert_eq!(voice_gain(r#"{"type":"voice_gain","gain":0.0}"#), Some(0.0));
        assert_eq!(voice_gain(r#"{"type":"voice_gain","gain":1}"#), Some(1.0));
        // A pose is the runtime thread's, not the audio module's.
        assert_eq!(voice_gain(r#"{"type":"pose","x":1}"#), None);
        assert_eq!(voice_gain("not json"), None);
        assert_eq!(voice_gain(""), None);
    }

    #[test]
    fn intents_parse() {
        match serde_json::from_str::<Command>(r#"{"type":"host"}"#).expect("bare host") {
            Command::Host { name } => assert_eq!(name, "", "a missing name is allowed"),
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(r#"{"type":"host","name":"bob"}"#)
            .expect("named host")
        {
            Command::Host { name } => assert_eq!(name, "bob"),
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(
            r#"{"type":"join","ticket":"endpointX","name":"alice"}"#,
        )
        .expect("join")
        {
            Command::Join {
                ticket,
                name,
                pull,
                mods: _,
            } => {
                assert_eq!(ticket, "endpointX");
                assert_eq!(name, "alice");
                // Absent means "do not fetch" (M18d): the old shape of the
                // command must not start fetching mods by itself.
                assert!(!pull, "a join without the flag must not fetch");
            }
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(
            r#"{"type":"join","ticket":"endpointX","name":"alice","pull":true}"#,
        )
        .expect("join with pull")
        {
            Command::Join { pull, .. } => assert!(pull),
            other => panic!("unexpected {other:?}"),
        }
        assert!(matches!(
            serde_json::from_str::<Command>(r#"{"type":"close"}"#),
            Ok(Command::Close)
        ));
        match serde_json::from_str::<Command>(r#"{"type":"say","text":"hi"}"#).expect("say") {
            Command::Say { text } => assert_eq!(text, "hi"),
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(
            r#"{"type":"pose","x":1.0,"z":2.0,"yaw":0.5,"phase":0.25,"speed":3.0,"gait":"fly","py":1.25,"pitch":20,"roll":-10}"#,
        )
        .expect("pose")
        {
            Command::Pose {
                x,
                z,
                yaw,
                phase,
                speed,
                gait,
                py,
                pitch,
                roll,
            } => {
                assert_eq!((x, z, yaw, phase, speed), (1.0, 2.0, 0.5, 0.25, 3.0));
                assert_eq!(gait, "fly");
                assert_eq!((py, pitch, roll), (1.25, 20.0, -10.0));
            }
            other => panic!("unexpected {other:?}"),
        }
        // `py` may be omitted on the same rule as `speed`: a goat on the ground has no
        // height, and the field is what a flung one adds.
        match serde_json::from_str::<Command>(
            r#"{"type":"pose","x":0,"z":0,"yaw":0,"phase":0,"gait":"idle"}"#,
        )
        .expect("pose")
        {
            Command::Pose { py, .. } => assert_eq!(py, 0.0),
            other => panic!("unexpected {other:?}"),
        }
        // `speed` may be omitted; the scene's placeholder before a gait exists.
        assert!(
            serde_json::from_str::<Command>(
                r#"{"type":"pose","x":0,"z":0,"yaw":0,"phase":0,"gait":"idle"}"#
            )
            .is_ok()
        );
        match serde_json::from_str::<Command>(
            r#"{"type":"world","bots":[{"index":0,"x":1.0,"z":2.0,"yaw":0.0,"phase":0.5,"gait":"trot","variant":1,"py":150}],"weather":{"kind":"rain","cloudiness":0.8,"rain_amount":0.6,"wind_x":1.4,"wind_z":0.2,"wind_sway":1.0,"world_time":9.25},"streams":{"weather":1,"bots":2,"food":3,"audio":4},"eaten":[{"key":99,"left":30.5}]}"#,
        )
        .expect("world")
        {
            Command::World {
                bots,
                weather,
                streams,
                eaten,
                craters,
                spent,
            } => {
                assert_eq!(bots.len(), 1);
                assert_eq!(bots[0].index, 0);
                assert_eq!(bots[0].gait, session::Gait::Trot);
                assert_eq!(bots[0].variant, 1);
                // The flung height rides the scene's world JSON too (M19f), in the
                // centimetres `BotState` is typed in.
                assert_eq!(bots[0].py, 150);
                assert_eq!(weather.kind, session::WeatherKind::Rain);
                assert_eq!(weather.world_time, 9.25);
                assert_eq!(streams.food, 3);
                assert_eq!(eaten.len(), 1);
                assert_eq!(eaten[0].key, 99);
                // A scene that does not carry the craters or the spent devices says
                // nothing about them rather than "there are none" (M19e).
                assert_eq!(craters, None);
                assert_eq!(spent, None);
            }
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(
            r#"{"type":"mods","mods":{"streams":{"com.example.a:sprint":9},"data":{"com.example.a":{"n":1}}}}"#,
        )
        .expect("mods")
        {
            Command::Mods { mods } => {
                assert_eq!(mods["streams"]["com.example.a:sprint"], 9);
                assert_eq!(mods["data"]["com.example.a"]["n"], 1);
            }
            other => panic!("unexpected {other:?}"),
        }
        match serde_json::from_str::<Command>(r#"{"type":"consume","key":123}"#).expect("consume") {
            Command::Consume { key } => assert_eq!(key, 123),
            other => panic!("unexpected {other:?}"),
        }
        // A bang this process fired: no `by`, so the bridge knows it is the scene's own
        // (`net.rs`'s `Live::blast`), and the kind arrives in the scene's own spelling.
        match serde_json::from_str::<Command>(
            r#"{"type":"blast","kind":"trap","key":42,"x":1.5,"z":-2.5}"#,
        )
        .expect("blast")
        {
            Command::Blast {
                kind,
                key,
                x,
                z,
                by,
            } => {
                assert_eq!((kind.as_str(), key, x, z), ("trap", 42, 1.5, -2.5));
                assert_eq!(by, None);
            }
            other => panic!("unexpected {other:?}"),
        }
        // A bang a client reported, which only the host relays: `by` is the reporter, and
        // the relay is what leaves them out.
        match serde_json::from_str::<Command>(
            r#"{"type":"blast","kind":"mine","key":7,"x":0.0,"z":0.0,"by":"alice"}"#,
        )
        .expect("reported blast")
        {
            Command::Blast { by, .. } => assert_eq!(by.as_deref(), Some("alice")),
            other => panic!("unexpected {other:?}"),
        }
        // An unknown intent is rejected, not silently ignored.
        assert!(serde_json::from_str::<Command>(r#"{"type":"nope"}"#).is_err());
    }

    #[test]
    fn events_carry_their_kind() {
        let line = serde_json::to_string(&Event::Roster {
            names: vec!["bob".to_string(), "alice".to_string()],
        })
        .expect("encode");
        assert_eq!(line, r#"{"type":"roster","names":["bob","alice"]}"#);

        let line = serde_json::to_string(&Event::Disconnected).expect("encode");
        assert_eq!(line, r#"{"type":"disconnected"}"#);

        let line = serde_json::to_string(&Event::Session { seed: 7 }).expect("encode");
        assert_eq!(line, r#"{"type":"session","seed":7}"#);

        let line = serde_json::to_string(&Event::Chat {
            from: "alice".to_string(),
            text: "hi".to_string(),
            direct: true,
        })
        .expect("encode");
        assert_eq!(
            line,
            r#"{"type":"chat","from":"alice","text":"hi","direct":true}"#
        );
    }

    #[test]
    fn session_events_map_onto_bridge_events() {
        let line = serde_json::to_string(&bridge(session::Event::Left {
            name: "alice".to_string(),
        }))
        .expect("encode");
        assert_eq!(line, r#"{"type":"left","name":"alice"}"#);

        let line = serde_json::to_string(&bridge(session::Event::Disconnected)).expect("encode");
        assert_eq!(line, r#"{"type":"disconnected"}"#);

        let line = serde_json::to_string(&bridge(session::Event::Roster {
            names: vec!["host".to_string()],
        }))
        .expect("encode");
        assert_eq!(line, r#"{"type":"roster","names":["host"]}"#);

        let line = serde_json::to_string(&bridge(session::Event::Chat {
            from: "alice".to_string(),
            text: "psst".to_string(),
            direct: true,
        }))
        .expect("encode");
        assert_eq!(
            line,
            r#"{"type":"chat","from":"alice","text":"psst","direct":true}"#
        );

        let line =
            serde_json::to_string(&bridge(session::Event::Session { seed: 7 })).expect("encode");
        assert_eq!(line, r#"{"type":"session","seed":7}"#);

        let line = serde_json::to_string(&bridge(session::Event::Peer {
            name: "alice".to_string(),
            state: session::PeerState {
                x: 1.0,
                z: 2.0,
                yaw: 0.0,
                phase: 0.0,
                speed: 0.0,
                gait: session::Gait::Fly,
                py: 1.25,
                pitch: 20,
                roll: -10,
            },
        }))
        .expect("encode");
        assert!(line.contains(r#""type":"peer""#), "{line}");
        assert!(line.contains(r#""name":"alice""#), "{line}");
        // A flight's gait is one of the pinned words (protocol 12), and the attitude travels
        // beside it -- the assertion used to read "idle" from a test that already sent `Fly`.
        assert!(line.contains(r#""gait":"fly""#), "{line}");
        assert!(line.contains(r#""pitch":20"#), "{line}");
        assert!(line.contains(r#""roll":-10"#), "{line}");

        let world_event = |eaten, craters, spent| session::Event::World {
            bots: vec![session::BotState {
                index: 0,
                x: 1.0,
                z: 2.0,
                yaw: 0.0,
                phase: 0.5,
                gait: session::Gait::Idle,
                variant: 0,
                py: 0,
                pitch: 0,
                roll: 0,
            }],
            weather: session::WeatherState {
                kind: session::WeatherKind::Cloudy,
                cloudiness: 0.7,
                rain_amount: 0.0,
                wind_x: 1.0,
                wind_z: 0.0,
                wind_sway: 0.6,
                world_time: 3.0,
            },
            streams: session::Streams {
                weather: 1,
                bots: 2,
                food: 3,
                audio: 4,
            },
            eaten,
            craters,
            spent,
        };
        let line = serde_json::to_string(&bridge(world_event(
            Some(vec![session::EatenCell { key: 5, left: 6.0 }]),
            Some(vec![session::Crater {
                x: 1.0,
                z: 2.0,
                r: 1.6,
                depth: 0.45,
            }]),
            Some(vec![session::Spent {
                key: 11,
                trap: false,
            }]),
        )))
        .expect("encode");
        assert!(line.contains(r#""type":"world""#), "{line}");
        assert!(line.contains(r#""index":0"#), "{line}");
        assert!(line.contains(r#""kind":"cloudy""#), "{line}");
        assert!(line.contains(r#""food":3"#), "{line}");
        assert!(line.contains(r#""key":5"#), "{line}");
        // The craters and the spent devices travel as they are, floats and all
        // (M19e): the ground a client stands on is the host's.
        assert!(line.contains(r#""depth":0.45"#), "{line}");
        assert!(line.contains(r#""trap":false"#), "{line}");

        // A meadow the host could not send reaches the scene as `null`, which is
        // what tells it to keep the one it has rather than clearing it -- see
        // `applyEaten` in `food.js`. The craters and the spent devices read the same
        // way, for the same reason.
        let line = serde_json::to_string(&bridge(world_event(None, None, None))).expect("encode");
        assert!(line.contains(r#""eaten":null"#), "{line}");
        assert!(line.contains(r#""craters":null"#), "{line}");
        assert!(line.contains(r#""spent":null"#), "{line}");

        // The mods are an event of their own, carrying the scene's own JSON
        // through untouched.
        let line = serde_json::to_string(&bridge(session::Event::Mods {
            mods: session::ModsState(
                serde_json::json!({ "data": { "com.example.a": { "n": 1 } } }),
            ),
        }))
        .expect("encode");
        assert!(line.contains(r#""type":"mods""#), "{line}");
        assert!(line.contains(r#""com.example.a""#), "{line}");

        let line =
            serde_json::to_string(&bridge(session::Event::Consume { key: 7 })).expect("encode");
        assert_eq!(line, r#"{"type":"consume","key":7}"#);

        // A bang the host relayed (M19e) reaches the scene whole, coordinates and all:
        // they are the host's, and they are what the receiver's own crater and own goat
        // are made of.
        let line = serde_json::to_string(&bridge(session::Event::Blast {
            kind: session::BlastKind::Mine,
            key: 11,
            x: 1.5,
            z: -2.5,
            by: "alice".to_string(),
        }))
        .expect("encode");
        assert_eq!(
            line,
            r#"{"type":"blast","kind":"mine","key":11,"x":1.5,"z":-2.5,"by":"alice"}"#
        );

        // A report is the other direction and the host's alone; `by` is the reporter,
        // and the scene hands it back with the coordinates so the relay can exclude them.
        let line = serde_json::to_string(&bridge(session::Event::BlastReport {
            kind: session::BlastKind::Trap,
            key: 12,
            by: "alice".to_string(),
        }))
        .expect("encode");
        assert_eq!(
            line,
            r#"{"type":"blast_report","kind":"trap","key":12,"by":"alice"}"#
        );
    }

    /// Waits for the next event containing `wanted`. Events that do not match
    /// are dropped, so the order the assertions below read is the real order.
    fn wait_for(net: &mut Net, wanted: &str) -> String {
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        while std::time::Instant::now() < deadline {
            while let Some(line) = net.next_event() {
                if line.contains(wanted) {
                    return line;
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        panic!("no event containing {wanted:?}");
    }

    /// A bridge that never fetches and has no mods directory: the default.
    fn pull_off() -> Pull {
        Pull {
            mods_dir: None,
            always: false,
        }
    }

    /// A hosting bridge joins a swarm and publishes its session; another bridge
    /// joins the same swarm through the first one's ticket and finds it. This is
    /// the whole discovery path -- join, advertise, receive, leave -- with no
    /// registry and no scene.
    #[test]
    fn a_swarm_finds_a_host_and_leaving_forgets_it() {
        let mut host = Net::start(Vec::new(), pull_off());
        host.send(r#"{"type":"swarm_join"}"#);
        let joined = wait_for(&mut host, "\"joined\":");
        let value: serde_json::Value = serde_json::from_str(&joined).expect("swarm json");
        assert_eq!(value["joined"], serde_json::json!(true), "{joined}");
        let seed = value["ticket"].as_str().expect("a seed ticket").to_string();
        let topic = value["topic"].as_str().expect("a topic").to_string();

        // The player joins the same topic, seeded by the host's swarm ticket.
        // A ticket is what makes this work without the address lookup: it
        // carries the seed's addresses.
        let mut player = Net::start(Vec::new(), pull_off());
        player.send(&format!(
            r#"{{"type":"swarm_join","topic":"{topic}","peers":["{seed}"]}}"#
        ));
        let joined = wait_for(&mut player, "\"joined\":");
        assert!(joined.contains("\"joined\":true"), "{joined}");

        // Hosting publishes the session advert.
        host.send(r#"{"type":"host","name":"bob"}"#);
        let session_ticket = ticket_of(&mut host);
        let discovered = wait_for(&mut player, &session_ticket);
        assert!(
            discovered.contains("\"type\":\"discovered\""),
            "{discovered}"
        );
        assert!(discovered.contains("\"name\":\"bob\""), "{discovered}");

        // Leaving the swarm drops the list, so no portal is left standing.
        player.send(r#"{"type":"swarm_leave"}"#);
        let left = wait_for(&mut player, "\"sessions\":[]");
        assert!(left.contains("\"sessions\":[]"), "{left}");
    }

    /// The zero-config case: two clients start with no ticket, no seed and no
    /// command. Both auto-join the default topic, the LAN beacon introduces
    /// them, and one hosting is enough for the other to find it. This is what a
    /// player does by launching two windows.
    #[test]
    fn two_clients_find_each_other_on_the_lan_with_no_seed() {
        if std::env::var("GOATS_SWARM_LAN").is_ok_and(|value| value == "0") {
            // The machine-wide opt-out; there is nothing to discover with.
            return;
        }
        let mut host = Net::start_with_swarm(Vec::new(), pull_off(), None, true);
        let mut player = Net::start_with_swarm(Vec::new(), pull_off(), None, true);
        // Each joins by itself; the event is what says the endpoint is up before
        // either asks it to do anything.
        wait_for(&mut host, "\"type\":\"swarm\"");
        wait_for(&mut player, "\"type\":\"swarm\"");

        host.send(r#"{"type":"host","name":"bob"}"#);
        let ticket = ticket_of(&mut host);
        let discovered = wait_for(&mut player, &ticket);
        assert!(
            discovered.contains("\"type\":\"discovered\""),
            "{discovered}"
        );
        assert!(discovered.contains("\"name\":\"bob\""), "{discovered}");
    }

    /// The ticket a hosting bridge just announced, which is what a joiner needs.
    fn ticket_of(host: &mut Net) -> String {
        let line = wait_for(host, "\"type\":\"ticket\"");
        let ticket =
            serde_json::from_str::<serde_json::Value>(&line).expect("ticket json")["ticket"]
                .as_str()
                .expect("a ticket string")
                .to_string();
        assert!(ticket.starts_with("endpoint"), "{ticket}");
        ticket
    }

    /// A scratch directory for the cases that write mods to disk. A counter keeps
    /// parallel cases apart, and the directory is emptied first so a re-run does
    /// not read the last run's mods.
    fn scratch(name: &str) -> PathBuf {
        static COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let dir = std::env::temp_dir().join(format!("goats-net-{name}-{n}"));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch directory");
        dir
    }

    /// A world mod in `dir`, ready for the loader: the smallest thing that has an
    /// id, a version and an entry. A host can only serve what it runs, so this is
    /// what the fetch cases need on the far side.
    fn write_world_mod(dir: &Path, id: &str) -> Vec<session::ModRef> {
        let mod_dir = dir.join("a-mod");
        std::fs::create_dir_all(&mod_dir).expect("mod directory");
        std::fs::write(
            mod_dir.join("mod.json"),
            format!(
                r#"{{"id":"{id}","name":"Pulled","version":"1.0.0","api":1,"side":"world","entry":"mod.js"}}"#
            ),
        )
        .expect("manifest");
        std::fs::write(mod_dir.join("mod.js"), "goats.log(\"hello\");\n").expect("entry");
        let loader = Loader::discover(dir);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());
        let world = crate::world_mod_refs(&loader);
        assert_eq!(world.len(), 1, "{world:?}");
        world
    }

    /// The console line for a refusal this client is not going to act on (M18d).
    /// The offer is the point: a player who is missing a mod should not have to
    /// read the source to find out that one flag would fetch it.
    #[test]
    fn a_refusal_offers_the_fetch_when_there_is_somewhere_to_put_it() {
        let mismatch = session::Error::Refused(
            session::ModMismatch {
                missing: vec!["com.example.birds".to_string()],
                ..session::ModMismatch::default()
            }
            .describe(),
        );
        let offered = refusal_text(&mismatch, true);
        assert!(offered.contains("world mods do not match"), "{offered}");
        assert!(offered.contains("`connect <ticket> --pull`"), "{offered}");

        // With nowhere to install the promise would be a lie, so it is not made.
        let bare = refusal_text(&mismatch, false);
        assert!(!bare.contains("--pull"), "{bare}");

        // And no other refusal is answered with a fetch: a version skew is not a
        // mod problem, whatever else it is.
        let skew = session::Error::Refused("protocol version 9 is not supported".to_string());
        let text = refusal_text(&skew, true);
        assert!(text.contains("protocol version 9"), "{text}");
        assert!(!text.contains("--pull"), "{text}");
    }

    /// Every way a fetch can fail to fix a refusal says so in its own words
    /// (M18d). These are the sentences a player acts on, so they are pinned here
    /// rather than discovered in the console.
    #[test]
    fn a_fetch_that_cannot_fix_it_says_why() {
        let refusal = session::Error::Refused(
            session::ModMismatch {
                missing: vec!["com.example.birds".to_string()],
                ..session::ModMismatch::default()
            }
            .describe(),
        );

        let matched = cannot_join(&refusal, Ok(pull::Recovery::Matched));
        assert!(
            matched.contains("already runs the host's mods"),
            "{matched}"
        );

        let nothing = cannot_join(
            &refusal,
            Ok(pull::Recovery::Pulled(pull::Report::default())),
        );
        assert!(nothing.contains("nothing was installed"), "{nothing}");

        let unfixable = cannot_join(
            &refusal,
            Ok(pull::Recovery::Unfixable(session::ModMismatch {
                extra: vec!["com.example.mine".to_string()],
                ..session::ModMismatch::default()
            })),
        );
        // The fresher mismatch leads, because it is the one that is true now: the
        // client may have changed since it was refused.
        assert!(unfixable.contains("extra com.example.mine"), "{unfixable}");
        assert!(unfixable.contains("only you can"), "{unfixable}");

        let unreachable = cannot_join(
            &refusal,
            Ok(pull::Recovery::Unreachable("connect: timeout".to_string())),
        );
        assert!(
            unreachable.contains("does not serve its mods"),
            "{unreachable}"
        );
        assert!(unreachable.contains("connect: timeout"), "{unreachable}");

        let failed = cannot_join(&refusal, Err("the host hung up".to_string()));
        assert!(failed.contains("the fetch failed"), "{failed}");
        assert!(failed.contains("the host hung up"), "{failed}");
    }

    /// The `pulled` event is the one the frame loop has to recognise before the
    /// scene does, because the mods it names have to be loaded first (M18d).
    #[test]
    fn the_pulled_event_names_its_mods_and_nothing_else_does() {
        let line = serde_json::to_string(&Event::Pulled {
            text: "pulled com.example.birds".to_string(),
            ids: vec!["com.example.birds".to_string()],
        })
        .expect("encode");
        assert_eq!(
            pulled_ids(&line),
            Some(vec!["com.example.birds".to_string()])
        );

        // Every other event, and the lines that are not events at all.
        assert_eq!(pulled_ids(r#"{"type":"welcome","name":"alice"}"#), None);
        assert_eq!(pulled_ids(r#"{"type":"pulled"}"#), Some(Vec::new()));
        assert_eq!(pulled_ids("not json"), None);
        assert_eq!(pulled_ids(""), None);
    }

    /// The whole mod-sync path over loopback, with no window (M18d): a host whose
    /// world mod this client lacks refuses the join, the client fetches what it is
    /// missing, installs it and joins -- and the two ways it can decline, a client
    /// that was not asked and one that has nowhere to install.
    #[test]
    fn a_refused_join_fetches_what_the_host_runs_and_the_client_lacks() {
        let host_dir = scratch("host");
        let world = write_world_mod(&host_dir, "com.example.pulled");
        let mut host = Net::start(
            world.clone(),
            Pull {
                mods_dir: Some(host_dir),
                always: false,
            },
        );
        host.send(r#"{"type":"host","name":"bob"}"#);
        let ticket = ticket_of(&mut host);
        let join = format!(r#"{{"type":"join","ticket":"{ticket}","name":"alice"}}"#);

        // No mods directory: there is nowhere to install, so the offer is not made.
        let mut bare = Net::start(Vec::new(), pull_off());
        bare.send(&join);
        let refusal = wait_for(&mut bare, "\"type\":\"error\"");
        assert!(refusal.contains("world mods do not match"), "{refusal}");
        assert!(!refusal.contains("--pull"), "{refusal}");

        // A mods directory but no consent: refused, and told how to ask.
        let client_dir = scratch("client");
        let mut asked = Net::start(
            Vec::new(),
            Pull {
                mods_dir: Some(client_dir.clone()),
                always: false,
            },
        );
        asked.send(&join);
        let refusal = wait_for(&mut asked, "\"type\":\"error\"");
        assert!(refusal.contains("world mods do not match"), "{refusal}");
        assert!(refusal.contains("`connect <ticket> --pull`"), "{refusal}");
        assert!(
            !client_dir.join("pulled-com.example.pulled.zip").exists(),
            "a refusal must install nothing"
        );

        // The command's own consent: the same client, now asking to fetch.
        let mut pulling = Net::start(
            Vec::new(),
            Pull {
                mods_dir: Some(client_dir.clone()),
                always: false,
            },
        );
        pulling.send(&format!(
            r#"{{"type":"join","ticket":"{ticket}","name":"alice","pull":true}}"#
        ));

        // The frame loop sees what to load before the world it belongs to.
        let pulled = wait_for(&mut pulling, "\"type\":\"pulled\"");
        assert!(pulled.contains("com.example.pulled"), "{pulled}");
        assert_eq!(
            pulled_ids(&pulled),
            Some(vec!["com.example.pulled".to_string()])
        );
        let welcome = wait_for(&mut pulling, "\"type\":\"welcome\"");
        assert!(welcome.contains("\"name\":\"alice\""), "{welcome}");

        // It landed beside the player's own mods, under a name that says what it
        // is and does not hide itself on Linux or macOS, and it hashes back to the
        // identity the handshake compares -- which is the whole reason the retry
        // can succeed.
        assert!(client_dir.join("pulled-com.example.pulled.zip").is_file());
        let installed = Loader::discover(&client_dir);
        assert!(installed.errors().is_empty(), "{:?}", installed.errors());
        let found = installed.get("com.example.pulled").expect("installed");
        assert_eq!(found.hash, world[0].hash);
        assert_eq!(found.version, world[0].version);
    }

    /// The whole bridge, end to end and with no window: two `Net` handles, a
    /// real host, a real ticket, and a real joiner. This is the automation of
    /// the two-window check -- everything except the game window itself.
    #[test]
    fn two_bridges_meet_over_loopback() {
        let mut host = Net::start(Vec::new(), pull_off());
        host.send(r#"{"type":"host","name":"bob"}"#);

        // The ticket is what a joiner needs, and it has to be a real one.
        let ticket = ticket_of(&mut host);

        let mut client = Net::start(Vec::new(), pull_off());
        client.send(&format!(
            r#"{{"type":"join","ticket":"{ticket}","name":"alice"}}"#
        ));

        // The joiner is welcomed under the name it asked for, and the host hears
        // about it on its own event stream.
        let welcome = wait_for(&mut client, "\"type\":\"welcome\"");
        assert!(welcome.contains("\"name\":\"alice\""), "{welcome}");
        wait_for(&mut host, "\"type\":\"joined\"");

        // Both sides get the roster, and it names the joiner.
        wait_for(&mut client, "\"type\":\"roster\"");
        let roster = wait_for(&mut host, "\"type\":\"roster\"");
        assert!(roster.contains("alice"), "{roster}");

        // Chat crosses the same bridge. A global line reaches the host under the
        // sender's name; an `@name` from the host reaches the joiner marked
        // direct. `wait_for` drops the lines it does not match, so the earlier
        // `alice` echo on the client's own stream is skipped here.
        client.send(r#"{"type":"say","text":"hello"}"#);
        let heard = wait_for(&mut host, "\"type\":\"chat\"");
        assert!(heard.contains("\"from\":\"alice\""), "{heard}");
        assert!(heard.contains("\"text\":\"hello\""), "{heard}");
        assert!(heard.contains("\"direct\":false"), "{heard}");

        host.send(r#"{"type":"say","text":"@alice psst"}"#);
        let whisper = wait_for(&mut client, "\"direct\":true");
        assert!(whisper.contains("\"text\":\"psst\""), "{whisper}");

        // A pose crosses on the datagram channel, not a stream, and the host's
        // scene sees the joiner's goat under the canonical name. Datagrams are
        // unreliable, so a small burst stands in for the stream a real client
        // sends.
        for _ in 0..10 {
            client.send(
                r#"{"type":"pose","x":1.5,"z":-2.0,"yaw":0.25,"phase":0.5,"speed":2.0,"gait":"trot"}"#,
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let peer = wait_for(&mut host, "\"type\":\"peer\"");
        assert!(peer.contains("\"name\":\"alice\""), "{peer}");
        assert!(peer.contains("\"gait\":\"trot\""), "{peer}");

        // The server's world goes the other way: the host publishes its bots and
        // the joiner mirrors them.
        for _ in 0..10 {
            host.send(
                r#"{"type":"world","bots":[{"index":0,"x":1.0,"z":2.0,"yaw":0.0,"phase":0.5,"gait":"walk","variant":0}],"weather":{"kind":"clear","cloudiness":0.05,"rain_amount":0.0,"wind_x":1.0,"wind_z":0.2,"wind_sway":0.4,"world_time":8.0},"streams":{"weather":1,"bots":2,"food":3,"audio":4},"eaten":[]}"#,
            );
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
        let world = wait_for(&mut client, "\"type\":\"world\"");
        assert!(world.contains("\"index\":0"), "{world}");
        assert!(world.contains("\"gait\":\"walk\""), "{world}");
        assert!(world.contains("\"kind\":\"clear\""), "{world}");
        assert!(world.contains("\"food\":3"), "{world}");

        // A bite is reported up the streams, not over the transform channel: the
        // host's scene hears what the client ate and records it.
        client.send(r#"{"type":"consume","key":8189}"#);
        let bite = wait_for(&mut host, "\"type\":\"consume\"");
        assert!(bite.contains("\"key\":8189"), "{bite}");
    }
}
