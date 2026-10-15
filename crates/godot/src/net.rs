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
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;

use godot::prelude::*;
use serde_json::json;
use session::{Client, Event as Net, Gait, Host, PeerState};
use tokio::sync::mpsc;

/// Events waiting for the frame loop to drain. Shared with the runtime thread.
type Queue = Arc<Mutex<VecDeque<String>>>;

/// One intent, from a GDScript call. The raylib client parses these out of JSON
/// lines because its scene is the other side of the bridge; here the call *is*
/// the parse, so the enum is built directly.
enum Command {
    Host { name: String },
    Join { ticket: String, name: String },
    Say { text: String },
    Consume { key: i64 },
    Pose(PeerState),
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
}

/// The networking bridge's Godot end.
///
/// `host` and `join` start a session, `say` and `pose` use it, `leave` ends
/// it, and `poll_events` drains what came back. The session lives on its own
/// thread, so none of these block a frame.
#[derive(GodotClass)]
#[class(base=Node)]
struct NetBridge {
    base: Base<Node>,
    /// `None` until the runtime thread is up. Dropping it ends the thread.
    commands: Option<mpsc::UnboundedSender<Command>>,
    /// The thread itself, kept so it can be joined rather than abandoned.
    thread: Option<thread::JoinHandle<()>>,
    queue: Queue,
}

#[godot_api]
impl INode for NetBridge {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            commands: None,
            thread: None,
            queue: Queue::default(),
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
    /// Host a session under `name` and start serving. The ticket arrives as a
    /// `ticket` event; the `seed` as a `session` event.
    #[func]
    fn host(&mut self, name: GString) -> GString {
        self.queue_command(Command::Host {
            name: name.to_string(),
        })
    }

    /// Join the session `ticket` names, asking to be called `name`.
    ///
    /// `join`, not `connect`: `Node` already has `connect` for signals, and a
    /// GDExtension method that shadows a base one is resolved by the static type
    /// at the call site rather than by name -- so a GDScript holding a `Node`
    /// would silently reach the wrong method. godot-rust warns about it, and
    /// will make it an error.
    #[func]
    fn join(&mut self, ticket: GString, name: GString) -> GString {
        self.queue_command(Command::Join {
            ticket: ticket.to_string(),
            name: name.to_string(),
        })
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
    /// and `py` the flung arc's height above the ground.
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
    ) -> GString {
        self.queue_command(Command::Pose(PeerState {
            x: x as f32,
            z: z as f32,
            yaw: yaw as f32,
            phase: phase as f32,
            speed: speed as f32,
            gait: parse_gait(&gait.to_string()),
            py: py as f32,
        }))
    }

    /// End the session. The other end sees a `left`, in due course.
    #[func]
    fn leave(&mut self) -> GString {
        self.queue_command(Command::Close)
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
            match start_runtime(self.queue.clone()) {
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
            runtime.block_on(run(receiver, queue));
        })
        .map_err(|error| format!("could not start the networking thread: {error}"))?;
    Ok((commands, thread))
}

/// The session loop. Mirrors `net.rs`: with a session up, wait on a command and
/// an event at once; with none, wait on a command.
async fn run(mut commands: mpsc::UnboundedReceiver<Command>, queue: Queue) {
    let mut live: Option<Live> = None;
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
                    // Voice is the audio module's, not the scene's: Opus bytes
                    // are not a line. It has no consumer here yet.
                    Some(Net::Voice { .. }) => continue,
                    Some(event) => {
                        push(&queue, event_json(event));
                        continue;
                    }
                    None => Outcome::Ended,
                },
            },
            None => Outcome::Command(commands.recv().await),
        };

        match outcome {
            Outcome::Ended => {
                push(&queue, json!({"kind": "disconnected"}).to_string());
                live = None;
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
            Outcome::Command(Some(command)) => {
                if let Some(session) = live.take() {
                    session.close().await;
                }
                live = start(command, &queue).await;
            }
        }
    }
    if let Some(session) = live {
        session.close().await;
    }
}

/// Bring up the session a `Host` or `Join` asks for, replacing whatever was
/// live (the caller has already closed it).
async fn start(command: Command, queue: &Queue) -> Option<Live> {
    match command {
        Command::Host { name } => match Host::start(&name).await {
            Ok(host) => {
                push(
                    queue,
                    json!({"type": "hosting", "name": host.name()}).to_string(),
                );
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
        },
        Command::Join { ticket, name } => match Client::join(&ticket, &name).await {
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
                push(queue, error_event(&format!("could not join: {error}")));
                None
            }
        },
        // Handled in `run`, which has the live session in hand.
        Command::Say { .. } | Command::Consume { .. } | Command::Pose(_) | Command::Close => None,
    }
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

fn notice(text: String) -> String {
    json!({"type": "notice", "text": text}).to_string()
}

fn error_event(text: &str) -> String {
    json!({"type": "error", "text": text}).to_string()
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
