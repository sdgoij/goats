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

use iroh::endpoint::{Connection, RecvStream, SendStream, presets};
use iroh::{Endpoint, EndpointAddr};
use iroh_tickets::Ticket;
use iroh_tickets::endpoint::EndpointTicket;
use proto::{ClientMessage, PROTOCOL_VERSION, ServerMessage};
use tokio::sync::{Mutex, mpsc};

/// The ALPN, carrying the major wire version so a peer built against a
/// different protocol fails the QUIC handshake instead of misreading messages.
pub fn alpn() -> Vec<u8> {
    format!("goats/{PROTOCOL_VERSION}").into_bytes()
}

/// Something that happened in the session, for the host to hand to the scene.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Event {
    /// A player joined, with the name the server assigned them.
    Joined { name: String },
    /// A player left.
    Left { name: String },
    /// The roster as it now stands, including the local player.
    Roster { names: Vec<String> },
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
    /// Names in join order. The host is first and has no connection.
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
}

/// A session the local player is hosting.
pub struct Host {
    endpoint: Endpoint,
    ticket: String,
    events: mpsc::UnboundedReceiver<Event>,
}

impl Host {
    /// Binds, starts accepting, and returns the host. The local player's name
    /// is sanitized and becomes the first entry in the roster.
    pub async fn start(host_name: &str) -> Result<Host, Error> {
        let endpoint = bind_endpoint().await?;
        let ticket = EndpointTicket::new(endpoint.addr()).encode_string();

        let server = Arc::new(Mutex::new(Server {
            roster: vec![proto::sanitize_name(host_name)],
            connections: Vec::new(),
        }));
        let (events, receiver) = mpsc::unbounded_channel();

        let accepting = endpoint.clone();
        let state = server.clone();
        let sender = events.clone();
        tokio::spawn(async move {
            while let Some(incoming) = accepting.accept().await {
                let Ok(connection) = incoming.await else {
                    continue;
                };
                tokio::spawn(handle_connection(connection, state.clone(), sender.clone()));
            }
        });

        Ok(Host {
            endpoint,
            ticket,
            events: receiver,
        })
    }

    /// The copy-pasteable ticket a joiner needs.
    pub fn ticket(&self) -> &str {
        &self.ticket
    }

    /// The endpoint id plus its current direct addresses.
    pub fn address(&self) -> EndpointAddr {
        self.endpoint.addr()
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

    let ClientMessage::Hello { version, name } = hello;
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

    let (assigned, roster) = {
        let mut server = state.lock().await;
        server.join(&name, connection.clone())
    };

    if send_to(
        &connection,
        &ServerMessage::Welcome {
            version: PROTOCOL_VERSION,
            name: assigned.clone(),
            roster: roster.clone(),
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
    let news = ServerMessage::Roster {
        names: roster.clone(),
    };
    for target in state.lock().await.targets(Some(&assigned)) {
        let _ = send_to(&target, &news).await;
    }

    // The joiner sends nothing else in this milestone; the connection is held
    // open for the roster broadcasts the server sends down it.
    connection.closed().await;

    let remaining = state.lock().await.leave(&assigned);
    let _ = events.send(Event::Left { name: assigned });
    let _ = events.send(Event::Roster {
        names: remaining.clone(),
    });
    let news = ServerMessage::Roster { names: remaining };
    for target in state.lock().await.targets(None) {
        let _ = send_to(&target, &news).await;
    }
}

/// A session the local player joined, hosted by someone else.
pub struct Client {
    endpoint: Endpoint,
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
        let (name, roster) = match welcome {
            ServerMessage::Welcome {
                version,
                name,
                roster,
            } => {
                if version != PROTOCOL_VERSION {
                    return Err(Error::Refused(format!(
                        "protocol version {version} is not supported"
                    )));
                }
                (name, roster)
            }
            ServerMessage::Error { message } => return Err(Error::Refused(message)),
            other => return Err(Error::Message(format!("unexpected reply: {other:?}"))),
        };

        let (events, receiver) = mpsc::unbounded_channel();
        let _ = events.send(Event::Roster { names: roster });

        // The host sends every later update down a fresh uni stream, so read
        // them until the connection ends.
        tokio::spawn(async move {
            loop {
                let Ok(mut recv) = connection.accept_uni().await else {
                    let _ = events.send(Event::Disconnected);
                    break;
                };
                match read_message::<ServerMessage>(&mut recv).await {
                    Ok(ServerMessage::Roster { names }) => {
                        if events.send(Event::Roster { names }).is_err() {
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
            name,
            events: receiver,
        })
    }

    /// The name the server assigned, which is not necessarily the one asked for.
    pub fn name(&self) -> &str {
        &self.name
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

            let mut alice = Client::join(host.ticket(), "alice")
                .await
                .expect("join alice");
            assert_eq!(alice.name(), "alice");

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
            // Drain the join news on both sides.
            assert!(host.next_event().await.is_some());
            assert!(host.next_event().await.is_some());
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

            // The first player is told, without asking.
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
}
