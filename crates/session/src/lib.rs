//! The session layer: peer-to-peer transport for the goat sandbox.
//!
//! This is the only crate that depends on iroh and tokio. It owns dialing,
//! accepting and framing; the scene never touches it directly, because the JS
//! engine has no sockets. The embedding host drives this crate and bridges it
//! to the scene over the line-based command channel (see `src/main.rs`).
//!
//! Nothing here knows about goats yet -- that is `proto`'s job. This module is
//! the transport: bind an endpoint, hand out its address, dial one, and move
//! framed messages over a stream.

use iroh::endpoint::presets;
use iroh::{Endpoint, EndpointAddr};

/// The application-level protocol name, carrying the major wire version. A peer
/// built against a different major version fails the QUIC handshake instead of
/// deserialising a message it cannot understand.
pub const ALPN: &[u8] = b"goats/1";

/// What can go wrong binding or dialing.
#[derive(Debug)]
pub enum Error {
    Bind(String),
    Connect(String),
    Accept(String),
    Stream(String),
}

impl std::fmt::Display for Error {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::Bind(message) => write!(formatter, "bind: {message}"),
            Error::Connect(message) => write!(formatter, "connect: {message}"),
            Error::Accept(message) => write!(formatter, "accept: {message}"),
            Error::Stream(message) => write!(formatter, "stream: {message}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<std::io::Error> for Error {
    fn from(error: std::io::Error) -> Self {
        Error::Stream(error.to_string())
    }
}

/// Binds an endpoint that can both host a session and dial one.
///
/// There is no client/server distinction at the transport level: every
/// endpoint accepts and dials, which is what lets a client act as a server.
///
/// `presets::Minimal` binds local sockets with no relay, so this reaches peers
/// on the same machine or LAN directly and contacts no third party. The
/// internet path (n0 relays plus hole punching) is a later step.
pub async fn bind() -> Result<Endpoint, Error> {
    Endpoint::builder(presets::Minimal)
        .alpns(vec![ALPN.to_vec()])
        .bind()
        .await
        .map_err(|error| Error::Bind(error.to_string()))
}

/// The shareable address of a host: the endpoint id plus whatever direct
/// addresses it currently has. This is what a joiner needs; turning it into a
/// copy-pasteable ticket is the next step.
pub fn address(endpoint: &Endpoint) -> EndpointAddr {
    endpoint.addr()
}

#[cfg(test)]
mod tests {
    use super::*;
    use iroh::endpoint::Connection;

    /// The transport's core promise: two endpoints, no relay, exchange bytes
    /// over a stream. If this fails, nothing above it can work.
    #[tokio::test]
    async fn endpoints_exchange_bytes_over_a_stream() {
        // A connect that cannot find a path would otherwise wait on iroh's own
        // long deadline; the test should fail fast instead of hanging.
        tokio::time::timeout(std::time::Duration::from_secs(30), async {
            let host = bind().await.expect("bind host");
            let host_addr = address(&host);

            let server = tokio::spawn(async move {
                let incoming = host.accept().await.expect("an incoming connection");
                let connection: Connection = incoming.await.expect("accept the connection");
                let (mut send, mut recv) =
                    connection.accept_bi().await.expect("accept a bi stream");
                let mut buf = [0u8; 5];
                recv.read_exact(&mut buf).await.expect("read the request");
                send.write_all(&buf).await.expect("echo it back");
                send.finish().expect("finish the stream");
                // Hold the connection open until the client closes it, so the
                // close below is what the far side observes.
                connection.closed().await;
            });

            let client = bind().await.expect("bind client");
            let connection = client
                .connect(host_addr, ALPN)
                .await
                .expect("connect to the host");
            let (mut send, mut recv) = connection.open_bi().await.expect("open a bi stream");
            send.write_all(b"hello").await.expect("write the request");
            send.finish().expect("finish the stream");
            let mut buf = [0u8; 5];
            recv.read_exact(&mut buf).await.expect("read the echo");
            assert_eq!(&buf, b"hello");

            connection.close(1u8.into(), b"done");
            server.await.expect("server task");
            client.close().await;
        })
        .await
        .expect("the loopback session finished");
    }
}
