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

use std::thread;

use serde::{Deserialize, Serialize};
use tokio::runtime;
use tokio::sync::mpsc;

/// An intent from the scene.
#[derive(Debug, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Command {
    /// Host a session as `name`; blank means the protocol default.
    Host {
        #[serde(default)]
        name: String,
    },
    /// Join the session behind `ticket` as `name`.
    Join { ticket: String, name: String },
    /// Say something. A leading `@name` whispers; the server routes it.
    Say { text: String },
    /// Leave whatever session is running.
    Close,
}

/// An event for the scene.
#[derive(Debug, Serialize)]
#[serde(tag = "type", rename_all = "snake_case")]
enum Event {
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
    /// The roster changed.
    Roster { names: Vec<String> },
    /// A line for the console.
    Notice { text: String },
    /// The connection to the host ended.
    Disconnected,
    /// The session could not be started or joined.
    Error { text: String },
}

/// The frame loop's handle on the networking thread.
pub struct Net {
    commands: mpsc::UnboundedSender<Command>,
    events: mpsc::UnboundedReceiver<String>,
}

impl Net {
    /// Starts the runtime thread. It runs until the handle is dropped, which
    /// closes the command channel and lets the thread finish.
    pub fn start() -> Net {
        let (command_tx, command_rx) = mpsc::unbounded_channel();
        let (event_tx, event_rx) = mpsc::unbounded_channel();
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
                runtime.block_on(run(command_rx, event_tx));
            })
            .expect("spawn the networking thread");
        Net {
            commands: command_tx,
            events: event_rx,
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
}

/// The runtime thread: run one command at a time, forwarding session events
/// back to the scene as they arrive.
async fn run(
    mut commands: mpsc::UnboundedReceiver<Command>,
    events: mpsc::UnboundedSender<String>,
) {
    let mut live: Option<Live> = None;
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
                    Some(event) => {
                        emit(&events, bridge(event));
                        continue;
                    }
                    None => Outcome::Ended,
                },
            },
            None => Outcome::Command(commands.recv().await),
        };

        match outcome {
            Outcome::Ended => live = None,
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
                other => live = start(other, live.take(), &events).await,
            },
            Outcome::Command(None) => break,
        }
    }
    if let Some(session) = live {
        session.close().await;
    }
}

/// Runs one command, replacing whatever session was live.
async fn start(
    command: Command,
    current: Option<Live>,
    events: &mpsc::UnboundedSender<String>,
) -> Option<Live> {
    if let Some(session) = current {
        session.close().await;
    }
    match command {
        Command::Close => None,
        // Handled in `run`, which has the live session in hand.
        Command::Say { .. } => None,
        Command::Host { name } => match session::Host::start(&name).await {
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
        },
        Command::Join { ticket, name } => match session::Client::join(&ticket, &name).await {
            Ok(client) => {
                emit(
                    events,
                    Event::Welcome {
                        name: client.name().to_string(),
                    },
                );
                Some(Live::Client(client))
            }
            Err(error) => {
                emit(
                    events,
                    Event::Error {
                        text: format!("could not join: {error}"),
                    },
                );
                None
            }
        },
    }
}

/// Maps a session event onto the line the scene understands.
fn bridge(event: session::Event) -> Event {
    match event {
        session::Event::Joined { name } => Event::Joined { name },
        session::Event::Left { name } => Event::Left { name },
        session::Event::Chat { from, text, direct } => Event::Chat { from, text, direct },
        session::Event::Roster { names } => Event::Roster { names },
        session::Event::Notice(text) => Event::Notice { text },
        session::Event::Disconnected => Event::Disconnected,
    }
}

/// Serialises an event and queues it for the scene.
fn emit(events: &mpsc::UnboundedSender<String>, event: Event) {
    match serde_json::to_string(&event) {
        Ok(line) => {
            let _ = events.send(line);
        }
        Err(error) => eprintln!("[net] could not encode an event: {error}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
            Command::Join { ticket, name } => {
                assert_eq!(ticket, "endpointX");
                assert_eq!(name, "alice");
            }
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

    /// The whole bridge, end to end and with no window: two `Net` handles, a
    /// real host, a real ticket, and a real joiner. This is the automation of
    /// the two-window check -- everything except the game window itself.
    #[test]
    fn two_bridges_meet_over_loopback() {
        let mut host = Net::start();
        host.send(r#"{"type":"host","name":"bob"}"#);

        // The ticket is what a joiner needs, and it has to be a real one.
        let ticket_line = wait_for(&mut host, "\"type\":\"ticket\"");
        let ticket = serde_json::from_str::<serde_json::Value>(&ticket_line).expect("ticket json")
            ["ticket"]
            .as_str()
            .expect("a ticket string")
            .to_string();
        assert!(ticket.starts_with("endpoint"), "{ticket}");

        let mut client = Net::start();
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
    }
}
