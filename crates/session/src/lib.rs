//! The session layer: peer-to-peer transport and the session state machine.
//!
//! This is the only crate that depends on iroh and tokio. It owns dialing,
//! accepting, framing and the join protocol; the scene never touches it
//! directly, because the JS engine has no sockets. The embedding host drives
//! this crate and bridges it to the scene over the line-based command channel
//! (see `crates/goats/src/main.rs`).
//!
//! There is no client/server split at the transport level -- every endpoint
//! both accepts and dials -- so hosting is just a session whose local player is
//! the server. A `Host` binds and accepts; a `Client` dials a ticket. Both hand
//! the caller a stream of [`Event`]s to drain.
//!
//! Control messages are one-shot and infrequent, so each is written to its own
//! unidirectional stream: iroh streams are cheap, and it keeps the connection
//! free of a framing state machine in both directions. The high-rate transform
//! channel M12 adds will want datagrams instead.

use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use iroh::endpoint::{Connection, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr};
use iroh_tickets::Ticket;
use iroh_tickets::endpoint::EndpointTicket;
use proto::{ClientMessage, PROTOCOL_VERSION, ServerMessage};
use tokio::sync::{Mutex, mpsc};

// The wire types the session exchanges, re-exported so an embedding host (the
// client's network bridge) can name a pose or a world without depending on
// `proto` directly.
pub use proto::{BotState, Datagram, Gait, PeerFrame, PeerState, WorldState};

/// The ALPN, carrying the major wire version so a peer built against a
/// different protocol fails the QUIC handshake instead of misreading messages.
pub fn alpn() -> Vec<u8> {
    format!("goats/{PROTOCOL_VERSION}").into_bytes()
}

/// Something that happened in the session, for the host to hand to the scene.
#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// The seed the world is built from, sent once before everything else.
    Session { seed: u32 },
    /// A player joined, with the name the server assigned them.
    Joined { name: String },
    /// A player left.
    Left { name: String },
    /// The roster as it now stands, including the local player.
    Roster { names: Vec<String> },
    /// A chat line. `direct` marks a whisper, so the console can show it
    /// differently.
    Chat {
        from: String,
        text: String,
        direct: bool,
    },
    /// A remote goat moved. `name` is the server's canonical name, not whatever
    /// the datagram claimed.
    Peer { name: String, state: PeerState },
    /// The server's bots, for a client to mirror instead of simulating.
    World { bots: Vec<BotState> },
    /// A line to print in the console.
    Notice(String),
    /// The connection to the host ended (client side only).
    Disconnected,
}

/// What can go wrong binding, dialing or running a session.
#[derive(Debug)]
pub enum Error {
    Bind(String),
    Connect(String),
    Accept(String),
    Stream(String),
    /// The ticket string did not parse.
    Ticket(String),
    /// The server refused the handshake.
    Refused(String),
    /// A message could not be encoded, framed or decoded.
    Message(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Bind(message) => write!(formatter, "bind: {message}"),
            Error::Connect(message) => write!(formatter, "connect: {message}"),
            Error::Accept(message) => write!(formatter, "accept: {message}"),
            Error::Stream(message) => write!(formatter, "stream: {message}"),
            Error::Ticket(message) => write!(formatter, "ticket: {message}"),
            Error::Refused(message) => write!(formatter, "refused: {message}"),
            Error::Message(message) => write!(formatter, "message: {message}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Stream(error.to_string())
    }
}

impl From<proto::Error> for Error {
    fn from(error: proto::Error) -> Self {
        Error::Message(error.to_string())
    }
}

/// Binds an endpoint that can both host and dial.
///
/// `presets::Minimal` binds local sockets with no relay, so this reaches peers
/// on the same machine or LAN directly and contacts no third party. Switching
/// to `presets::N0` (internet, via n0's relays and hole punching) is a one-line
/// change when that is wanted.
async fn bind_endpoint() -> Result<Endpoint, Error> {
    Endpoint::builder(presets::Minimal)
        .alpns(vec![alpn()])
        .bind()
        .await
        .map_err(|error| Error::Bind(error.to_string()))
}

/// Encodes a message into a frame, writes it to a stream and finishes the
/// stream, since every control message is one-shot.
async fn write_message<T: serde::Serialize>(
    send: &mut SendStream,
    message: &T,
) -> Result<(), Error> {
    let payload = proto::encode(message)?;
    let framed = proto::frame(&payload)?;
    send.write_all(&framed)
        .await
        .map_err(|error| Error::Stream(error.to_string()))?;
    send.finish()
        .map_err(|error| Error::Stream(error.to_string()))?;
    Ok(())
}

/// Reads one framed message. The length prefix is bounds-checked before the
/// buffer is sized, so a corrupt or hostile length cannot allocate wildly.
async fn read_message<T: serde::de::DeserializeOwned>(recv: &mut RecvStream) -> Result<T, Error> {
    let mut header = [0u8; proto::LENGTH_PREFIX_BYTES];
    recv.read_exact(&mut header)
        .await
        .map_err(|error| Error::Stream(error.to_string()))?;
    let length = proto::frame_length(header)?;
    let mut payload = vec![0u8; length];
    recv.read_exact(&mut payload)
        .await
        .map_err(|error| Error::Stream(error.to_string()))?;
    Ok(proto::decode(&payload)?)
}

/// Sends a server message on its own stream.
async fn send_to(connection: &Connection, message: &ServerMessage) -> Result<(), Error> {
    let mut send = connection
        .open_uni()
        .await
        .map_err(|error| Error::Stream(error.to_string()))?;
    write_message(&mut send, message).await
}

/// The server's state: who is in the session, and the connection to reach them.
struct Server {
    /// The local player's name. They have no connection of their own; what they
    /// say arrives through `Host::say`.
    host: String,
    /// The seed the world is built from, handed to every joiner.
    seed: u32,
    /// Names in join order, the host first.
    roster: Vec<String>,
    connections: Vec<(String, Connection)>,
}

impl Server {
    /// Assigns a unique name for `desired`, records the connection, and returns
    /// the name and the roster. One lock hold, so two peers racing for the same
    /// name cannot both win it.
    fn join(&mut self, desired: &str, connection: Connection) -> (String, Vec<String>) {
        let name = proto::unique_name(desired, &self.roster);
        self.roster.push(name.clone());
        self.connections.push((name.clone(), connection));
        (name, self.roster.clone())
    }

    /// Drops a player and returns the remaining roster.
    fn leave(&mut self, name: &str) -> Vec<String> {
        self.roster.retain(|current| current != name);
        self.connections.retain(|(current, _)| current != name);
        self.roster.clone()
    }

    /// The connections to send to, optionally excluding one player (the one who
    /// already has the news).
    fn targets(&self, except: Option<&str>) -> Vec<Connection> {
        self.connections
            .iter()
            .filter(|(name, _)| Some(name.as_str()) != except)
            .map(|(_, connection)| connection.clone())
            .collect()
    }

    /// Everyone connected.
    fn every(&self) -> Vec<Connection> {
        self.targets(None)
    }

    /// The connection for `name`, if they are a connected player. The host has
    /// none.
    fn connection_of(&self, name: &str) -> Option<Connection> {
        self.connections
            .iter()
            .find(|(current, _)| current == name)
            .map(|(_, connection)| connection.clone())
    }

    /// Whether `name` is anyone in the session, the host included.
    fn knows(&self, name: &str) -> bool {
        self.roster.iter().any(|current| current == name)
    }
}

/// The chat rate limit: at most `CHAT_BURST` messages per `CHAT_WINDOW`.
const CHAT_BURST: u32 = 5;
const CHAT_WINDOW: Duration = Duration::from_secs(3);

/// A rolling window counter. Unbounded chat is a free denial of service and a
/// bandwidth sink, so a peer gets a burst and then has to wait.
fn within_burst(window: &mut Instant, count: &mut u32) -> bool {
    let now = Instant::now();
    if now.duration_since(*window) >= CHAT_WINDOW {
        *window = now;
        *count = 0;
    }
    *count += 1;
    *count <= CHAT_BURST
}

/// Who a chat line is for, worked out under one lock so the sends below can run
/// without holding it.
enum ChatPlan {
    /// A whisper to someone who is not here.
    Unknown { target: String },
    /// A whisper: to the target, to the sender, and to the host if either of
    /// them is the host.
    Direct {
        to: Vec<Connection>,
        host_sees: bool,
        from: String,
        body: String,
    },
    /// Everyone.
    Global {
        to: Vec<Connection>,
        from: String,
        body: String,
    },
}

/// Routes one chat line from `from`. A leading `@name` is a whisper; anything
/// else goes to the whole session. The sender gets their own line back, so every
/// console shows the same transcript.
async fn route_chat(
    state: &Arc<Mutex<Server>>,
    events: &mpsc::UnboundedSender<Event>,
    from: &str,
    raw: &str,
) {
    let text = proto::sanitize_text(raw, proto::MAX_CHAT_BYTES);
    if text.is_empty() {
        return;
    }

    let plan = {
        let server = state.lock().await;
        match proto::direct_message(&text) {
            Some((target, body)) => {
                if !server.knows(target) {
                    ChatPlan::Unknown {
                        target: target.to_string(),
                    }
                } else {
                    let mut to = Vec::new();
                    if let Some(connection) = server.connection_of(target) {
                        to.push(connection);
                    }
                    if let Some(connection) = server.connection_of(from) {
                        to.push(connection);
                    }
                    ChatPlan::Direct {
                        to,
                        host_sees: server.host == target || server.host == from,
                        from: from.to_string(),
                        body: body.to_string(),
                    }
                }
            }
            None => ChatPlan::Global {
                to: server.every(),
                from: from.to_string(),
                body: text.clone(),
            },
        }
    };

    match plan {
        ChatPlan::Unknown { target } => {
            let text = format!("no such player: {target}");
            // The sender is a connection, or the host, who has an event stream
            // instead of one.
            match state.lock().await.connection_of(from) {
                Some(connection) => {
                    let _ = send_to(&connection, &ServerMessage::Notice { text }).await;
                }
                None => {
                    let _ = events.send(Event::Notice(text));
                }
            }
        }
        ChatPlan::Direct {
            to,
            host_sees,
            from,
            body,
        } => {
            let message = ServerMessage::Chat {
                from: from.clone(),
                text: body.clone(),
                direct: true,
            };
            for connection in to {
                let _ = send_to(&connection, &message).await;
            }
            if host_sees {
                let _ = events.send(Event::Chat {
                    from,
                    text: body,
                    direct: true,
                });
            }
        }
        ChatPlan::Global { to, from, body } => {
            let message = ServerMessage::Chat {
                from: from.clone(),
                text: body.clone(),
                direct: false,
            };
            for connection in to {
                let _ = send_to(&connection, &message).await;
            }
            let _ = events.send(Event::Chat {
                from,
                text: body,
                direct: false,
            });
        }
    }
}

/// A session the local player is hosting.
pub struct Host {
    endpoint: Endpoint,
    ticket: String,
    name: String,
    seed: u32,
    server: Arc<Mutex<Server>>,
    sender: mpsc::UnboundedSender<Event>,
    events: mpsc::UnboundedReceiver<Event>,
}

/// A fresh session seed, mixed from the clock so two sessions rarely share one.
/// Not a cryptographic value: it only has to make the weather and the food
/// regrowth differ between sessions, and never be zero (xorshift32 is stuck at
/// zero).
fn new_seed() -> u32 {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(0x9e37_79b9_7f4a_7c15);
    // splitmix64's finalizer, to spread the clock's low bits across the word.
    let mut mixed = nanos ^ 0x9e37_79b9_7f4a_7c15;
    mixed ^= mixed >> 30;
    mixed = mixed.wrapping_mul(0xbf58_476d_1ce4_e5b9);
    mixed ^= mixed >> 27;
    mixed = mixed.wrapping_mul(0x94d0_49bb_1331_11eb);
    mixed ^= mixed >> 31;
    (mixed as u32) | 1
}

impl Host {
    /// Binds, starts accepting, and returns the host. The local player's name
    /// is sanitized and becomes the first entry in the roster.
    pub async fn start(host_name: &str) -> Result<Host, Error> {
        let endpoint = bind_endpoint().await?;
        let ticket = EndpointTicket::new(endpoint.addr()).encode_string();

        let local_name = proto::sanitize_name(host_name);
        let seed = new_seed();
        let server = Arc::new(Mutex::new(Server {
            host: local_name.clone(),
            seed,
            roster: vec![local_name.clone()],
            connections: Vec::new(),
        }));
        let (events, receiver) = mpsc::unbounded_channel();
        let broadcaster = events.clone();
        // The scene learns the seed before anything else, so it can build the
        // same world the joiners will.
        let _ = events.send(Event::Session { seed });

        let accepting = endpoint.clone();
        let state = server.clone();
        tokio::spawn(async move {
            while let Some(incoming) = accepting.accept().await {
                let Ok(connection) = incoming.await else {
                    continue;
                };
                tokio::spawn(handle_connection(
                    connection,
                    state.clone(),
                    broadcaster.clone(),
                ));
            }
        });

        Ok(Host {
            endpoint,
            ticket,
            name: local_name,
            seed,
            server,
            sender: events,
            events: receiver,
        })
    }

    /// The copy-pasteable ticket a joiner needs.
    pub fn ticket(&self) -> &str {
        &self.ticket
    }

    /// The local player's canonical name -- the sanitized one, which is what the
    /// roster carries, not necessarily what was asked for.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// The seed joiners are told to build the world from.
    pub fn seed(&self) -> u32 {
        self.seed
    }

    /// The endpoint id plus its current direct addresses.
    pub fn address(&self) -> EndpointAddr {
        self.endpoint.addr()
    }

    /// Says something as the local player. The text takes the same routing as a
    /// remote message, so a leading `@name` whispers from the host too, and the
    /// host's own copy comes back as a [`Event::Chat`].
    pub async fn say(&self, text: &str) {
        route_chat(&self.server, &self.sender, &self.name, text).await;
    }

    /// Broadcasts the local player's goat to everyone else. Datagrams, so this
    /// is fire-and-forget: a lost snapshot is replaced by the next one.
    pub async fn publish(&self, state: &PeerState) {
        if !state.is_finite() {
            return;
        }
        let datagram = Datagram::Peer(PeerFrame {
            name: self.name.clone(),
            state: state.clone(),
        });
        self.broadcast(datagram).await;
    }

    /// Broadcasts the server's bots. Only the host may send these, which is what
    /// makes the world authoritative: a client mirrors what it is told and does
    /// not simulate.
    pub async fn publish_world(&self, world: &WorldState) {
        if !world.is_finite() {
            return;
        }
        self.broadcast(Datagram::World(world.clone())).await;
    }

    /// Sends one datagram to every connected player. Fire-and-forget, and
    /// silently dropped when it exceeds the datagram budget.
    async fn broadcast(&self, datagram: Datagram) {
        let Ok(payload) = proto::encode(&datagram) else {
            return;
        };
        if payload.len() > proto::MAX_DATAGRAM_BYTES {
            return;
        }
        let bytes = Bytes::from(payload);
        for connection in self.server.lock().await.every() {
            let _ = connection.send_datagram(bytes.clone());
        }
    }

    /// The next event, or `None` once the session is finished.
    pub async fn next_event(&mut self) -> Option<Event> {
        self.events.recv().await
    }

    /// Closes the endpoint, which ends every connection and stops accepting.
    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

/// Handles one accepted connection: handshake, then hold the connection open
/// until the peer leaves.
async fn handle_connection(
    connection: Connection,
    state: Arc<Mutex<Server>>,
    events: mpsc::UnboundedSender<Event>,
) {
    // The joiner opens a uni stream and sends `Hello` on it. A peer that sends
    // nothing, or garbage, is dropped rather than allowed to wedge a task.
    let Ok(mut recv) = connection.accept_uni().await else {
        return;
    };
    let hello: ClientMessage = match read_message(&mut recv).await {
        Ok(hello) => hello,
        Err(error) => {
            let _ = send_to(
                &connection,
                &ServerMessage::Error {
                    message: error.to_string(),
                },
            )
            .await;
            connection.close(1u8.into(), b"bad hello");
            return;
        }
    };

    let ClientMessage::Hello { version, name } = hello else {
        let _ = send_to(
            &connection,
            &ServerMessage::Error {
                message: "the first message must be a hello".to_string(),
            },
        )
        .await;
        connection.close(3u8.into(), b"hello");
        return;
    };
    if version != PROTOCOL_VERSION {
        let _ = send_to(
            &connection,
            &ServerMessage::Error {
                message: format!("protocol version {version} is not supported"),
            },
        )
        .await;
        connection.close(2u8.into(), b"version");
        return;
    }

    let (assigned, roster, seed) = {
        let mut server = state.lock().await;
        let (assigned, roster) = server.join(&name, connection.clone());
        (assigned, roster, server.seed)
    };

    if send_to(
        &connection,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            name: assigned.clone(),
            roster: roster.clone(),
            seed,
        },
    )
    .await
    .is_err()
    {
        let remaining = state.lock().await.leave(&assigned);
        let _ = events.send(Event::Roster { names: remaining });
        return;
    }

    let _ = events.send(Event::Joined {
        name: assigned.clone(),
    });
    let _ = events.send(Event::Roster {
        names: roster.clone(),
    });

    // Tell everyone else, not the joiner: their Welcome already carried it.
    for target in state.lock().await.targets(Some(&assigned)) {
        let _ = send_to(
            &target,
            &ServerMessage::Joined {
                name: assigned.clone(),
            },
        )
        .await;
        let _ = send_to(
            &target,
            &ServerMessage::Roster {
                names: roster.clone(),
            },
        )
        .await;
    }

    // Snapshot relay. The transform channel is datagrams: unreliable and
    // unordered, so a lost position is simply replaced by the next one, and it
    // never head-of-line-blocks the control streams. Each datagram is tagged
    // with the name this connection was assigned, so a peer cannot move someone
    // else's goat.
    let relay_connection = connection.clone();
    let relay_state = state.clone();
    let relay_events = events.clone();
    let relay_name = assigned.clone();
    tokio::spawn(async move {
        while let Ok(bytes) = relay_connection.read_datagram().await {
            if bytes.len() > proto::MAX_DATAGRAM_BYTES {
                continue;
            }
            // Only a player's own goat may come up from a client. A client that
            // sends world state has it dropped rather than relayed, so it cannot
            // move the bots.
            let Ok(Datagram::Peer(frame)) = proto::decode::<Datagram>(&bytes) else {
                continue;
            };
            if !frame.state.is_finite() {
                continue;
            }
            // The host is a player too, so its scene sees the peer even though
            // there is no connection for it to receive a datagram on.
            if relay_events
                .send(Event::Peer {
                    name: relay_name.clone(),
                    state: frame.state.clone(),
                })
                .is_err()
            {
                break;
            }
            // Re-tag with the name this connection was assigned; the name in the
            // client's frame is ignored.
            let tagged = Datagram::Peer(PeerFrame {
                name: relay_name.clone(),
                state: frame.state,
            });
            let Ok(payload) = proto::encode(&tagged) else {
                continue;
            };
            let datagram = Bytes::from(payload);
            for target in relay_state.lock().await.targets(Some(&relay_name)) {
                let _ = target.send_datagram(datagram.clone());
            }
        }
    });

    // Then serve them. Each message arrives on its own stream, like every other
    // control message, so the connection stays open until the peer closes it.
    let mut window = Instant::now();
    let mut count = 0u32;
    while let Ok(mut recv) = connection.accept_uni().await {
        match read_message::<ClientMessage>(&mut recv).await {
            Ok(ClientMessage::Chat { text }) => {
                if !within_burst(&mut window, &mut count) {
                    let _ = send_to(
                        &connection,
                        &ServerMessage::Notice {
                            text: "slow down".to_string(),
                        },
                    )
                    .await;
                    continue;
                }
                route_chat(&state, &events, &assigned, &text).await;
            }
            // A second greeting means nothing once you are already in.
            Ok(ClientMessage::Hello { .. }) => {}
            Err(error) => {
                let _ = send_to(
                    &connection,
                    &ServerMessage::Notice {
                        text: format!("ignored a bad message: {error}"),
                    },
                )
                .await;
            }
        }
    }

    let remaining = state.lock().await.leave(&assigned);
    let _ = events.send(Event::Left {
        name: assigned.clone(),
    });
    let _ = events.send(Event::Roster {
        names: remaining.clone(),
    });
    for target in state.lock().await.targets(None) {
        let _ = send_to(
            &target,
            &ServerMessage::Left {
                name: assigned.clone(),
            },
        )
        .await;
        let _ = send_to(
            &target,
            &ServerMessage::Roster {
                names: remaining.clone(),
            },
        )
        .await;
    }
}

/// A session the local player joined, hosted by someone else.
pub struct Client {
    endpoint: Endpoint,
    /// Kept so [`Client::say`] can open a stream; the reader task has its own
    /// clone.
    connection: Connection,
    name: String,
    events: mpsc::UnboundedReceiver<Event>,
}

impl Client {
    /// Parses the ticket, dials the host, completes the handshake, and returns
    /// once the server has accepted us -- so [`Client::name`] is the canonical
    /// name, which may differ from the one requested.
    pub async fn join(ticket: &str, desired_name: &str) -> Result<Client, Error> {
        let ticket: EndpointTicket = ticket
            .parse()
            .map_err(|error: iroh_tickets::ParseError| Error::Ticket(error.to_string()))?;
        let address: EndpointAddr = ticket.into();

        let endpoint = bind_endpoint().await?;
        let connection = endpoint
            .connect(address, &alpn())
            .await
            .map_err(|error| Error::Connect(error.to_string()))?;

        let mut send = connection
            .open_uni()
            .await
            .map_err(|error| Error::Stream(error.to_string()))?;
        write_message(
            &mut send,
            &ClientMessage::Hello {
                version: PROTOCOL_VERSION,
                name: desired_name.to_string(),
            },
        )
        .await?;

        let mut recv = connection
            .accept_uni()
            .await
            .map_err(|error| Error::Accept(error.to_string()))?;
        let welcome: ServerMessage = read_message(&mut recv).await?;
        let (name, roster, seed) = match welcome {
            ServerMessage::Welcome {
                version,
                name,
                roster,
                seed,
            } => {
                if version != PROTOCOL_VERSION {
                    return Err(Error::Refused(format!(
                        "protocol version {version} is not supported"
                    )));
                }
                (name, roster, seed)
            }
            ServerMessage::Error { message } => return Err(Error::Refused(message)),
            other => return Err(Error::Message(format!("unexpected reply: {other:?}"))),
        };

        let (events, receiver) = mpsc::unbounded_channel();
        let _ = events.send(Event::Session { seed });
        let _ = events.send(Event::Roster { names: roster });

        // Snapshots arrive as datagrams, on their own channel beside the
        // control streams, so a burst of movement never queues behind chat.
        let snapshot_connection = connection.clone();
        let snapshot_events = events.clone();
        tokio::spawn(async move {
            while let Ok(bytes) = snapshot_connection.read_datagram().await {
                if bytes.len() > proto::MAX_DATAGRAM_BYTES {
                    continue;
                }
                let Ok(datagram) = proto::decode::<Datagram>(&bytes) else {
                    continue;
                };
                let event = match datagram {
                    Datagram::Peer(frame) => {
                        if !frame.state.is_finite() {
                            continue;
                        }
                        Event::Peer {
                            name: frame.name,
                            state: frame.state,
                        }
                    }
                    Datagram::World(world) => {
                        if !world.is_finite() {
                            continue;
                        }
                        Event::World { bots: world.bots }
                    }
                };
                if snapshot_events.send(event).is_err() {
                    break;
                }
            }
        });

        // The host sends every later update down a fresh uni stream, so read
        // them until the connection ends.
        let reader = connection.clone();
        tokio::spawn(async move {
            loop {
                let Ok(mut recv) = reader.accept_uni().await else {
                    let _ = events.send(Event::Disconnected);
                    break;
                };
                match read_message::<ServerMessage>(&mut recv).await {
                    Ok(ServerMessage::Roster { names }) => {
                        if events.send(Event::Roster { names }).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Chat { from, text, direct }) => {
                        if events.send(Event::Chat { from, text, direct }).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Joined { name }) => {
                        if events.send(Event::Joined { name }).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Left { name }) => {
                        if events.send(Event::Left { name }).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Notice { text }) => {
                        if events.send(Event::Notice(text)).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Error { message }) => {
                        if events.send(Event::Notice(message)).is_err() {
                            break;
                        }
                    }
                    Ok(ServerMessage::Welcome { .. }) => {}
                    Err(error) => {
                        let _ = events.send(Event::Notice(format!("bad message: {error}")));
                    }
                }
            }
        });

        Ok(Client {
            endpoint,
            connection,
            name,
            events: receiver,
        })
    }

    /// The name the server assigned, which is not necessarily the one asked for.
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Says something. A leading `@name` is a whisper, which the server routes;
    /// the message comes back with everyone else's, so the transcript matches.
    pub async fn say(&self, text: &str) -> Result<(), Error> {
        let mut send = self
            .connection
            .open_uni()
            .await
            .map_err(|error| Error::Stream(error.to_string()))?;
        write_message(
            &mut send,
            &ClientMessage::Chat {
                text: text.to_string(),
            },
        )
        .await
    }

    /// Sends the local player's goat to the host, which relays it to everyone
    /// else. Datagrams, so a failure is not worth reporting: the next snapshot
    /// is along in a few milliseconds. The name is left blank -- the server
    /// stamps the canonical one on the way through.
    pub fn publish(&self, state: &PeerState) {
        if !state.is_finite() {
            return;
        }
        let datagram = Datagram::Peer(PeerFrame {
            name: String::new(),
            state: state.clone(),
        });
        let Ok(payload) = proto::encode(&datagram) else {
            return;
        };
        if payload.len() > proto::MAX_DATAGRAM_BYTES {
            return;
        }
        let _ = self.connection.send_datagram(Bytes::from(payload));
    }

    /// The next event, or `None` once the session is finished.
    pub async fn next_event(&mut self) -> Option<Event> {
        self.events.recv().await
    }

    /// Disconnects, which the host sees as a leave.
    pub async fn close(self) {
        self.endpoint.close().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    /// Every test gets a deadline, so a session that cannot connect fails
    /// instead of waiting on iroh's own long timeouts.
    async fn within<F: std::future::Future>(future: F) -> F::Output {
        tokio::time::timeout(Duration::from_secs(30), future)
            .await
            .expect("the session finished")
    }

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|name| name.to_string()).collect()
    }

    #[test]
    fn the_alpn_carries_the_protocol_version() {
        assert_eq!(alpn(), format!("goats/{PROTOCOL_VERSION}").into_bytes());
    }

    #[tokio::test]
    async fn a_client_joins_and_gets_its_name() {
        within(async {
            let mut host = Host::start("host").await.expect("host");
            assert!(host.ticket().starts_with("endpoint"), "{}", host.ticket());

            // Every session opens with the seed the world is built from.
            let host_seed = match host.next_event().await.expect("host seed") {
                Event::Session { seed } => seed,
                other => panic!("expected a seed, got {other:?}"),
            };
            assert_ne!(host_seed, 0);

            let mut alice = Client::join(host.ticket(), "alice")
                .await
                .expect("join alice");
            assert_eq!(alice.name(), "alice");

            // The joiner is given the same seed, so the world it builds matches.
            match alice.next_event().await.expect("client seed") {
                Event::Session { seed } => assert_eq!(seed, host_seed),
                other => panic!("expected a seed, got {other:?}"),
            }

            // The host hears about it, with the roster including itself.
            assert_eq!(
                host.next_event().await.expect("joined"),
                Event::Joined {
                    name: "alice".to_string()
                }
            );
            assert_eq!(
                host.next_event().await.expect("roster"),
                Event::Roster {
                    names: names(&["host", "alice"])
                }
            );

            // The joiner learned the same roster from its Welcome.
            assert_eq!(
                alice.next_event().await.expect("roster"),
                Event::Roster {
                    names: names(&["host", "alice"])
                }
            );

            alice.close().await;
            assert_eq!(
                host.next_event().await.expect("left"),
                Event::Left {
                    name: "alice".to_string()
                }
            );
            host.close().await;
        })
        .await;
    }

    #[tokio::test]
    async fn a_second_player_gets_a_unique_name_and_updates_the_roster() {
        within(async {
            let mut host = Host::start("host").await.expect("host");
            let mut alice = Client::join(host.ticket(), "alice")
                .await
                .expect("join alice");
            // Drain the join news on both sides: the seed and the join pair on
            // the host, and the seed on the joiner.
            assert!(matches!(
                host.next_event().await,
                Some(Event::Session { .. })
            ));
            assert!(host.next_event().await.is_some());
            assert!(host.next_event().await.is_some());
            assert!(matches!(
                alice.next_event().await,
                Some(Event::Session { .. })
            ));
            assert_eq!(
                alice.next_event().await.expect("initial roster"),
                Event::Roster {
                    names: names(&["host", "alice"])
                }
            );

            // The second player asks for a name that is taken.
            let bob = Client::join(host.ticket(), "alice")
                .await
                .expect("join bob");
            assert_eq!(bob.name(), "alice #2");

            // The first player is told without asking: who joined, then the
            // roster.
            assert_eq!(
                alice.next_event().await.expect("joined"),
                Event::Joined {
                    name: "alice #2".to_string()
                }
            );
            assert_eq!(
                alice.next_event().await.expect("roster update"),
                Event::Roster {
                    names: names(&["host", "alice", "alice #2"])
                }
            );

            bob.close().await;
            alice.close().await;
            host.close().await;
        })
        .await;
    }

    #[tokio::test]
    async fn a_bad_ticket_is_refused_before_dialing() {
        // Deliberately not `expect_err`: that would need `Debug` on `Client`,
        // and the client holds an endpoint whose debug output is not something
        // to spread around.
        match Client::join("not a ticket", "bob").await {
            Err(Error::Ticket(_)) => {}
            Err(other) => panic!("expected a ticket error, got {other:?}"),
            Ok(_) => panic!("an invalid ticket must be refused"),
        }
    }

    /// The next chat line, skipping the roster and system noise around it.
    async fn host_chat(host: &mut Host) -> Event {
        loop {
            if let event @ Event::Chat { .. } = host.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    async fn client_chat(client: &mut Client) -> Event {
        loop {
            if let event @ Event::Chat { .. } = client.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    async fn client_notice(client: &mut Client) -> Event {
        loop {
            if let event @ Event::Notice(_) = client.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    /// The next relayed goat snapshot, skipping the seed and roster noise.
    async fn host_peer(host: &mut Host) -> Event {
        loop {
            if let event @ Event::Peer { .. } = host.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    async fn client_peer(client: &mut Client) -> Event {
        loop {
            if let event @ Event::Peer { .. } = client.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    /// The next server world snapshot, skipping seed, roster and peer noise.
    async fn client_world(client: &mut Client) -> Event {
        loop {
            if let event @ Event::World { .. } = client.next_event().await.expect("an event") {
                return event;
            }
        }
    }

    #[tokio::test]
    async fn the_servers_world_reaches_its_clients() {
        within(async {
            let host = Host::start("host").await.expect("host");
            let mut alice = Client::join(host.ticket(), "alice").await.expect("alice");

            let world = WorldState {
                bots: vec![
                    BotState {
                        index: 0,
                        x: 1.0,
                        z: 2.0,
                        yaw: 0.5,
                        phase: 0.25,
                        gait: proto::Gait::Walk,
                        variant: 0,
                    },
                    BotState {
                        index: 1,
                        x: -3.0,
                        z: 0.0,
                        yaw: 0.0,
                        phase: 0.75,
                        gait: proto::Gait::Idle,
                        variant: 2,
                    },
                ],
            };
            for _ in 0..10 {
                host.publish_world(&world).await;
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            match client_world(&mut alice).await {
                Event::World { bots } => assert_eq!(bots, world.bots),
                other => panic!("expected a world, got {other:?}"),
            }

            alice.close().await;
            host.close().await;
        })
        .await;
    }

    #[tokio::test]
    async fn a_snapshot_is_relayed_with_the_servers_name() {
        within(async {
            let mut host = Host::start("host").await.expect("host");
            let mut alice = Client::join(host.ticket(), "alice").await.expect("alice");
            let mut bob = Client::join(host.ticket(), "bob").await.expect("bob");

            let alice_state = PeerState {
                x: 1.0,
                z: 2.0,
                yaw: 0.5,
                phase: 0.25,
                speed: 3.0,
                gait: proto::Gait::Run,
            };
            // Datagrams are unreliable, so a handful of attempts stand in for
            // the twenty a second a real client sends.
            for _ in 0..10 {
                alice.publish(&alice_state);
                tokio::time::sleep(Duration::from_millis(20)).await;
            }

            // The host's scene sees Alice; the name is the server's, and Bob
            // gets her too rather than the sender getting an echo.
            match host_peer(&mut host).await {
                Event::Peer { name, state } => {
                    assert_eq!(name, "alice");
                    assert_eq!(state, alice_state);
                }
                other => panic!("expected a peer, got {other:?}"),
            }
            match client_peer(&mut bob).await {
                Event::Peer { name, state } => {
                    assert_eq!(name, "alice");
                    assert_eq!(state, alice_state);
                }
                other => panic!("expected a peer, got {other:?}"),
            }

            // And the host's own goat goes out to both clients.
            let host_state = PeerState {
                x: -4.0,
                z: 0.5,
                yaw: 0.0,
                phase: 0.0,
                speed: 0.0,
                gait: proto::Gait::Idle,
            };
            for _ in 0..10 {
                host.publish(&host_state).await;
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            for client in [&mut alice, &mut bob] {
                // Bob still has Alice's earlier snapshots queued, so step past
                // whatever is already there until the host's goat arrives.
                loop {
                    if let Event::Peer { name, state } = client_peer(client).await
                        && name == "host"
                    {
                        assert_eq!(state, host_state);
                        break;
                    }
                }
            }

            alice.close().await;
            bob.close().await;
            host.close().await;
        })
        .await;
    }

    #[tokio::test]
    async fn chat_is_global_and_whispers_are_not() {
        within(async {
            let mut host = Host::start("host").await.expect("host");
            let mut alice = Client::join(host.ticket(), "alice").await.expect("alice");
            let mut bob = Client::join(host.ticket(), "bob").await.expect("bob");

            // Global: everyone sees it, the sender included.
            alice.say("hello all").await.expect("say");
            let expected = Event::Chat {
                from: "alice".to_string(),
                text: "hello all".to_string(),
                direct: false,
            };
            assert_eq!(client_chat(&mut bob).await, expected);
            // The sender sees their own line too, so every console agrees.
            assert_eq!(client_chat(&mut alice).await, expected);
            assert_eq!(host_chat(&mut host).await, expected);

            // A whisper reaches the target and comes back to the sender, and
            // nobody else -- the host in particular never sees it.
            alice.say("@bob psst").await.expect("whisper");
            let whisper = Event::Chat {
                from: "alice".to_string(),
                text: "psst".to_string(),
                direct: true,
            };
            assert_eq!(client_chat(&mut bob).await, whisper);
            assert_eq!(client_chat(&mut alice).await, whisper);

            // A whisper to someone who is not here says so.
            alice.say("@nobody hi").await.expect("whisper nobody");
            match client_notice(&mut alice).await {
                Event::Notice(text) => assert_eq!(text, "no such player: nobody"),
                other => panic!("unexpected {other:?}"),
            }

            bob.close().await;
            alice.close().await;
            host.close().await;
        })
        .await;
    }

    #[tokio::test]
    async fn chat_is_rate_limited() {
        within(async {
            let host = Host::start("host").await.expect("host");
            let mut alice = Client::join(host.ticket(), "alice").await.expect("alice");

            for _ in 0..(CHAT_BURST + 3) {
                alice.say("spam").await.expect("say");
            }

            // The burst gets through; the rest is refused with a notice.
            assert_eq!(
                client_notice(&mut alice).await,
                Event::Notice("slow down".to_string())
            );

            alice.close().await;
            host.close().await;
        })
        .await;
    }
}
