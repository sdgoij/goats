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
//! A node without a blob store is a gossip-only node: the swarm is the only thing
//! that can attach. A node with one always serves the blobs protocol, because the
//! router cannot gain an ALPN after it has spawned.

use std::path::PathBuf;
use std::sync::Arc;

use iroh::address_lookup::memory::MemoryLookup;
use iroh::endpoint::presets;
use iroh::protocol::Router;
use iroh::{Endpoint, EndpointAddr, EndpointId, SecretKey};
use iroh_blobs::BlobsProtocol;
use iroh_blobs::api::Store;
use iroh_blobs::store::fs::FsStore;
use iroh_gossip::Gossip;
use iroh_tickets::Ticket;
use iroh_tickets::endpoint::EndpointTicket;

use crate::Error;
use crate::swarm::Reach;

/// How a [`Node`] binds.
pub struct NodeConfig {
    pub secret: Option<SecretKey>,
    pub reach: Reach,
    /// The blob store to serve, if this node should accept the registry's transfer
    /// protocol. The directory is created if missing.
    pub blobs: Option<PathBuf>,
}

/// The transport both discovery and the catalogue ride on.
pub struct Node {
    endpoint: Endpoint,
    gossip: Gossip,
    router: Router,
    lookup: MemoryLookup,
    store: Option<Store>,
    addr: EndpointAddr,
    ticket: String,
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
        let builder = Router::builder(endpoint.clone()).accept(iroh_gossip::ALPN, gossip.clone());
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
