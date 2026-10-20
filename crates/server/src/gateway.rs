//! The browser gateway: a WebSocket face for the native session client.
//!
//! A tab has no UDP socket, so it cannot run `session`'s QUIC transport. This
//! listener gives it the same line protocol the native client's networking
//! thread already speaks: the scene's `Command` JSON lines come in over a
//! WebSocket, a real [`session::Client`] dials the ticket named in the `join`,
//! and the resulting [`session::Event`]s go back as the same JSON lines the
//! scene already handles (`session::bridge`).
//!
//! One socket is one player. The gateway opens its own iroh connection per
//! socket, so a native host sees each browser as a normal client with its own
//! name -- not a multiplexed body behind one peer.
//!
//! What it deliberately does not do yet: host (the browser would need a
//! gateway-hosted authoritative world), swarm discovery and voice. Each answers
//! with a `notice` the console prints rather than being silently dropped.
//!
//! TLS is not here. The listener speaks `ws://`; a deployment puts a reverse
//! proxy in front for `wss://`, which is also where an Origin allowlist belongs.

use futures_util::SinkExt;
use futures_util::StreamExt;
use futures_util::stream::SplitSink;
use session::bridge::{self, Command, Event};
use session::{Client, PeerState};
use tokio::net::{TcpListener, TcpStream};
use tokio_tungstenite::WebSocketStream;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;

/// One incoming line is a small JSON command. A world snapshot is only ever sent
/// *out* to a browser, so the uplink has no legitimate large message; the cap
/// makes a hostile one cheap to refuse.
const MAX_INCOMING: usize = 64 * 1024;

type Sink = SplitSink<WebSocketStream<TcpStream>, Message>;

/// Accept browser sockets for as long as the process lives. Each one gets its
/// own task and its own session connection.
pub async fn serve(listener: TcpListener) {
    loop {
        match listener.accept().await {
            Ok((stream, peer)) => {
                tokio::spawn(async move {
                    if let Err(error) = handle(stream).await {
                        eprintln!("goatsd gateway: {peer}: {error}");
                    }
                });
            }
            Err(error) => eprintln!("goatsd gateway: accept: {error}"),
        }
    }
}

/// Run one browser connection until it closes.
async fn handle(stream: TcpStream) -> Result<(), String> {
    let config = WebSocketConfig::default()
        .max_message_size(Some(MAX_INCOMING))
        .max_frame_size(Some(MAX_INCOMING));
    let socket = tokio_tungstenite::accept_async_with_config(stream, Some(config))
        .await
        .map_err(|error| error.to_string())?;
    let (mut sink, mut source) = socket.split();
    let mut client: Option<Client> = None;

    loop {
        tokio::select! {
            message = source.next() => {
                let Some(message) = message else { break };
                let message = message.map_err(|error| error.to_string())?;
                match message {
                    Message::Text(text) => {
                        let command: Command = match serde_json::from_str(&text) {
                            Ok(command) => command,
                            Err(error) => {
                                send(&mut sink, Event::Error {
                                    text: format!("bad command: {error}"),
                                }).await?;
                                continue;
                            }
                        };
                        if !apply(&mut client, command, &mut sink).await? {
                            break;
                        }
                    }
                    Message::Binary(_) => {
                        send(&mut sink, Event::Notice {
                            text: "binary frames are reserved for voice; the gateway takes JSON lines".to_string(),
                        }).await?;
                    }
                    Message::Ping(payload) => {
                        sink.send(Message::Pong(payload)).await.map_err(|error| error.to_string())?;
                    }
                    Message::Pong(_) | Message::Frame(_) => {}
                    Message::Close(_) => break,
                }
            }
            event = async { client.as_mut().expect("guarded").next_event().await }, if client.is_some() => {
                match event {
                    Some(event) => send(&mut sink, bridge::to_event(event)).await?,
                    None => {
                        client = None;
                        send(&mut sink, Event::Disconnected).await?;
                    }
                }
            }
        }
    }

    if let Some(client) = client {
        client.close().await;
    }
    Ok(())
}

/// Apply one scene command. `Ok(false)` means the socket should close.
async fn apply(
    client: &mut Option<Client>,
    command: Command,
    sink: &mut Sink,
) -> Result<bool, String> {
    match command {
        Command::Join {
            ticket, name, mods, ..
        } => {
            if client.is_some() {
                send(
                    sink,
                    Event::Error {
                        text: "already in a session (leave first)".to_string(),
                    },
                )
                .await?;
                return Ok(true);
            }
            match Client::join_with_mods(&ticket, &name, mods).await {
                Ok(joined) => {
                    // The native bridge says this before the client's own queued
                    // `session` and `roster` events, and the scene keys the
                    // canonical name off it.
                    send(
                        sink,
                        Event::Welcome {
                            name: joined.name().to_string(),
                        },
                    )
                    .await?;
                    *client = Some(joined);
                }
                Err(error) => {
                    send(
                        sink,
                        Event::Error {
                            text: error.to_string(),
                        },
                    )
                    .await?;
                }
            }
        }
        Command::Host { .. } => {
            send(sink, Event::Error {
                text: "hosting from a browser needs a gateway-hosted room, which this build does not provide; join a host instead".to_string(),
            })
            .await?;
        }
        Command::Say { text } => match client.as_ref() {
            Some(joined) => {
                if let Err(error) = joined.say(&text).await {
                    send(
                        sink,
                        Event::Notice {
                            text: error.to_string(),
                        },
                    )
                    .await?;
                }
            }
            None => {
                send(
                    sink,
                    Event::Notice {
                        text: "not in a session".to_string(),
                    },
                )
                .await?;
            }
        },
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
            if let Some(joined) = client.as_ref() {
                joined.publish(&PeerState {
                    x,
                    z,
                    yaw,
                    phase,
                    speed,
                    gait: bridge::parse_gait(&gait),
                    py,
                    pitch: bridge::degrees(pitch),
                    roll: bridge::degrees(roll),
                });
            }
        }
        Command::Consume { key } => {
            if let Some(joined) = client.as_ref()
                && let Err(error) = joined.consume(key).await
            {
                send(
                    sink,
                    Event::Notice {
                        text: error.to_string(),
                    },
                )
                .await?;
            }
        }
        Command::Blast { kind, key, .. } => {
            if let Some(joined) = client.as_ref()
                && let Err(error) = joined
                    .report_blast(bridge::parse_blast_kind(&kind), key)
                    .await
            {
                send(
                    sink,
                    Event::Notice {
                        text: error.to_string(),
                    },
                )
                .await?;
            }
        }
        // No browser capture path yet; a silent drop is the native bridge's
        // rule for a voice frame while offline.
        Command::Voice { .. } => {}
        Command::Close => {
            if let Some(joined) = client.take() {
                joined.close().await;
            }
            send(sink, Event::Disconnected).await?;
            return Ok(false);
        }
        Command::World { .. } | Command::Mods { .. } => {
            send(
                sink,
                Event::Notice {
                    text: "the gateway is a client; it has no world to publish".to_string(),
                },
            )
            .await?;
        }
        Command::SwarmJoin { .. } | Command::SwarmLeave => {
            send(
                sink,
                Event::Notice {
                    text: "swarm discovery is not available through the browser gateway yet"
                        .to_string(),
                },
            )
            .await?;
        }
        Command::ModsRegistry
        | Command::ModsShare
        | Command::ModsFetch { .. }
        | Command::ModsMirror { .. } => {
            send(
                sink,
                Event::Notice {
                    text: "the mod registry is not available through the browser gateway yet"
                        .to_string(),
                },
            )
            .await?;
        }
    }
    Ok(true)
}

/// Encode and send one event. Voice is dropped by `bridge::encode`, as it is on
/// the native path.
async fn send(sink: &mut Sink, event: Event) -> Result<(), String> {
    if let Some(line) = bridge::encode(&event) {
        sink.send(Message::Text(line.into()))
            .await
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}

/// Where a bare port binds, the same spelling `--listen` uses.
pub fn address(value: &str) -> String {
    if value.parse::<u16>().is_ok() {
        format!("0.0.0.0:{value}")
    } else {
        value.to_string()
    }
}

/// The shown address of a bound listener, falling back to what was asked for.
pub fn shown(listener: &TcpListener, asked: &str) -> String {
    match listener.local_addr() {
        Ok(address) => address.to_string(),
        Err(_) => asked.to_string(),
    }
}
