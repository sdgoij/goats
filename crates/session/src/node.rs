//! One endpoint for discovery and the catalogue.
//!
//! The swarm and the registry were separate endpoints because a router accepts a
//! fixed set of ALPNs at spawn time. That is true, but it is a reason to build the
//! router once, not to build two: a [`Node`] owns the endpoint, the gossip actor
//! and a router that accepts gossip and, when a store is given, `iroh-blobs` too.
//! A [`Swarm`](crate::swarm::Swarm) and a [`Registry`](crate::registry::Registry)
//! then subscribe to their own topics on the same node, so one ticket introduces
//! both, and a client needs one socket rather than two.
//!
//! A node is gossip-only unless it is bound with more: `NodeConfig::blobs` adds
//! the registry's transfer protocol and `NodeConfig::session` the session's
//! ALPNs, so a `Host` can serve on the same endpoint. Both are fixed at bind
//! time, because the router cannot gain an ALPN after it has spawned.

use std::path::PathBuf;
use std::sync::{Arc, Mutex as StdMutex};

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::{Connection, presets};
use iroh::protocol::{AcceptError, ProtocolHandler, Router};
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use iroh_blobs::BlobsProtocol;
use iroh_blobs::api::Store;
use iroh_blobs::store::fs::FsStore;
use iroh_gossip::Gossip;
use iroh_tickets::Ticket;
use iroh_tickets::endpoint::EndpointTicket;
use tokio::sync::mpsc;

use crate::Error;
use crate::swarm::Reach;

/// How a [`Node`] binds.
pub struct NodeConfig {
    pub secret: Option<SecretKey>,
    pub reach: Reach,
    /// The blob store to serve, if this node should accept the registry's transfer
    /// protocol. The directory is created if missing.
    pub blobs: Option<PathBuf>,
    /// Accept the session's ALPNs too, so a `Host` can serve on this endpoint.
    /// The router is what accepts them, and it cannot gain an ALPN after spawn,
    /// so a node that is ever going to host says so at bind time.
    pub session: bool,
}

/// The transport both discovery and the catalogue ride on.
pub struct Node {
    endpoint: Endpoint,
    gossip: Gossip,
    router: Router,
    lookup: MemoryLookup,
    store: Option<Store>,
    /// The session half, when this node accepts one.
    session: Option<SessionPort>,
    addr: EndpointAddr,
    ticket: String,
}

/// The session half of a [`Node`]: what a `Host` serves from.
///
/// The node's router accepts the session's ALPNs and hands each connection here;
/// a host claims the queue once, which is also how the node learns that somebody
/// is now serving a session. A dial before that is closed rather than queued,
/// which is what dialing a node that is not hosting should do.
pub struct SessionPort {
    /// Where the protocol handler offers a connection. `None` between the bind and
    /// the claim, and again if the host goes away.
    slot: Arc<StdMutex<Option<mpsc::UnboundedSender<Connection>>>>,
    sender: mpsc::UnboundedSender<Connection>,
    inbox: StdMutex<Option<mpsc::UnboundedReceiver<Connection>>>,
}

impl SessionPort {
    /// Hands out the connections this node accepts, and starts routing new ones to
    /// them. `None` on a second call: one node serves one session at a time.
    pub fn claim(&self) -> Option<mpsc::UnboundedReceiver<Connection>> {
        let inbox = self.inbox.lock().expect("session inbox").take()?;
        *self.slot.lock().expect("session slot") = Some(self.sender.clone());
        Some(inbox)
    }
}

/// The router side of [`SessionPort`]: one clone per accepted connection.
#[derive(Clone)]
struct SessionProtocol {
    slot: Arc<StdMutex<Option<mpsc::UnboundedSender<Connection>>>>,
}

impl std::fmt::Debug for SessionProtocol {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter.write_str("SessionProtocol")
    }
}

impl ProtocolHandler for SessionProtocol {
    async fn accept(&self, connection: Connection) -> Result<(), AcceptError> {
        let sender = self.slot.lock().expect("session slot").clone();
        if let Some(sender) = sender {
            let _ = sender.send(connection);
        }
        // No host: the connection is dropped here, which closes it. The peer sees
        // a closed connection rather than a queue that grows until somebody hosts.
        Ok(())
    }
}

impl Node {
    /// Binds the endpoint, starts gossip and builds the one router this process
    /// will use. The store, when present, is opened before the router so the blobs
    /// protocol can be accepted from the first connection.
    pub async fn bind(config: NodeConfig) -> Result<Arc<Node>, Error> {
        let mut builder = match config.reach {
            Reach::Wan => Endpoint::builder(presets::N0),
            Reach::Direct => Endpoint::builder(presets::Minimal),
        };
        // Tickets are learned into this table rather than by a DNS lookup: gossip
        // dials by id, and a peer handed a ticket carries its addresses.
        let lookup = MemoryLookup::new();
        builder = builder.address_lookup(lookup.clone());
        if let Some(secret) = config.secret {
            builder = builder.secret_key(secret);
        }
        let endpoint = builder
            .bind()
            .await
            .map_err(|error| Error::Node(format!("bind: {error}")))?;

        let store = match &config.blobs {
            Some(path) => {
                let opened = FsStore::load(path)
                    .await
                    .map_err(|error| Error::Node(format!("store {}: {error}", path.display())))?;
                Some(Store::from(opened))
            }
            None => None,
        };

        let gossip = Gossip::builder().spawn(endpoint.clone());
        // The session's ALPNs go on the same router as gossip and blobs: a client
        // that finds this node by one ticket can join the session it hosts without
        // a second endpoint, and a client that does not host never dials them.
        let session = config.session.then(|| {
            let (sender, inbox) = mpsc::unbounded_channel();
            let slot = Arc::new(StdMutex::new(None));
            (
                SessionPort {
                    slot: slot.clone(),
                    sender,
                    inbox: StdMutex::new(Some(inbox)),
                },
                SessionProtocol { slot },
            )
        });
        let mut builder =
            Router::builder(endpoint.clone()).accept(iroh_gossip::ALPN, gossip.clone());
        if let Some((_, handler)) = &session {
            builder = builder.accept(crate::alpn(), handler.clone());
            builder = builder.accept(proto::mod_fetch_alpn(), handler.clone());
        }
        let router = match &store {
            Some(store) => builder
                .accept(iroh_blobs::ALPN, BlobsProtocol::new(store, None))
                .spawn(),
            None => builder.spawn(),
        };

        let addr = endpoint.addr();
        let ticket = EndpointTicket::new(addr.clone()).encode_string();
        Ok(Arc::new(Node {
            endpoint,
            gossip,
            router,
            lookup,
            store,
            session: session.map(|(port, _)| port),
            addr,
            ticket,
        }))
    }

    /// The endpoint a session or downloader dials through.
    pub fn endpoint(&self) -> &Endpoint {
        &self.endpoint
    }

    /// The gossip actor, which any number of topics can subscribe on.
    pub fn gossip(&self) -> &Gossip {
        &self.gossip
    }

    /// The blob store, when this node serves the registry.
    pub fn store(&self) -> Option<&Store> {
        self.store.as_ref()
    }

    /// The session half, when this node was bound to accept a session.
    pub fn session(&self) -> Option<&SessionPort> {
        self.session.as_ref()
    }

    /// The lookup a ticket learned out of band is added to.
    pub fn lookup(&self) -> &MemoryLookup {
        &self.lookup
    }

    pub fn addr(&self) -> &EndpointAddr {
        &self.addr
    }

    pub fn id(&self) -> EndpointId {
        self.addr.id
    }

    /// The one ticket: a portal's session and this node's catalogue share it.
    pub fn ticket(&self) -> &str {
        &self.ticket
    }

    /// Adds a peer's addresses to the lookup, so a later dial by id resolves.
    pub fn add_peer(&self, addr: EndpointAddr) {
        self.lookup.add_endpoint_info(addr);
    }

    /// Stops accepting connections and closes the endpoint. The store, if any, is
    /// shut down by the blobs protocol's own shutdown.
    pub async fn shutdown(&self) {
        let _ = self.router.shutdown().await;
    }
}
