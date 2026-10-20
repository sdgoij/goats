//! The swarm: finding hosts without a registry.
//!
//! A session is reachable only by its ticket, and a ticket comes from its host.
//! A registry closes that gap with a server in the middle; this closes it with
//! iroh-gossip instead. Every participant that joins a **topic** becomes part of
//! an epidemic broadcast tree, and a host restates one small advert -- its
//! session ticket, its name, how many players are in, and the wire version -- on
//! a timer. Everyone else keeps the adverts they hear and forgets one that has
//! not been restated for a while, so a host that crashes disappears without
//! anyone having to detect the crash.
//!
//! Nothing here is a datagram path: the advert names the *session* endpoint, and
//! the players then join it exactly as if the ticket had been pasted. The swarm
//! is a noticeboard.
//!
//! A swarm is a gossip topic, not a service. There is no authority and no
//! membership beyond "who is currently connected", and a topic is public: anyone
//! who knows its 32-byte id can listen. That is the price of having no server;
//! the advert deliberately carries nothing but what a portal needs.
//!
//! ## The first peer
//!
//! Gossip needs an introduction: [`Swarm::join`] takes peers that are already in
//! the topic, and an empty list means "connect to nobody yet". A cold node gets
//! that introduction from one of two places. On a local network the **LAN
//! beacon** announces this endpoint's ticket on a multicast group and dials
//! everybody it hears, which is what makes two clients on one network meet with
//! no ticket at all. Across networks a node needs a seed -- an endpoint id
//! (resolved through n0's DNS with the default [`Reach::Wan`]) or an endpoint
//! ticket, which carries its addresses. `goatsd` is the natural seed: it prints
//! its swarm ticket, and every client that is handed it can join.
//!
//! ## Why the messages are not signed
//!
//! An advert is a claim, and gossip is a public topic. A liar can list a ticket
//! that is not theirs, just as anyone can paste a ticket into a console. Nothing
//! here is authority: the ticket is the identity that matters, and joining it
//! proves the rest. The caps in [`clean`] are what keep a liar from making the
//! list absurd.

use std::collections::{HashMap, HashSet};
use std::net::{Ipv4Addr, SocketAddr};
use std::str::FromStr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use bytes::Bytes;
use iroh::address_lookup::memory::MemoryLookup;
use iroh::{EndpointAddr, EndpointId, SecretKey};
use iroh_gossip::TopicId;
use iroh_gossip::api::{Event as GossipEvent, GossipReceiver, GossipSender};
use iroh_tickets::Ticket;
use iroh_tickets::endpoint::EndpointTicket;
use n0_future::StreamExt;
use serde::{Deserialize, Serialize};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::sync::mpsc;

use crate::Error;
use crate::node::{Node, NodeConfig};

/// The default swarm: SHA-256 of `goats/swarm/v1`, in the hex form a
/// [`TopicId`] parses. A stable hash rather than a random id means every build
/// of the game looks at the same topic without having to share anything first.
pub const DEFAULT_TOPIC: &str = "32b19c7a81bb09d6147d1a2511bbd3668b0c81a68abb7cfbe2f65d97dd195a9e";

/// How often a host restates its advert. Gossip is lossy and a new neighbour has
/// missed everything before it arrived, so the advert is a heartbeat, not a
/// one-off announcement.
pub const ADVERT_EVERY: Duration = Duration::from_secs(30);

/// How long an advert outlives its last restatement. Three announce windows: a
/// host can miss two and still be listed.
pub const ADVERT_TTL: Duration = Duration::from_secs(90);

/// The most hosts a list carries. A topic is not a directory; this is what keeps
/// one misbehaving participant from growing every other participant's list -- and
/// the scene's portal list -- without bound.
pub const MAX_HOSTS: usize = 256;

/// The most a ticket may be, in bytes. A session ticket is a few hundred.
const MAX_TICKET_BYTES: usize = 4096;

/// The most of a display name that is kept, in characters.
const MAX_NAME_CHARS: usize = 64;

/// The largest player count an advert may claim.
const MAX_CLIENTS: usize = 4096;

/// How many commands may queue for the gossip task before a send starts failing.
/// Adverts are rare and small; this only has to absorb a roster burst.
const COMMAND_BACKLOG: usize = 16;

/// The LAN beacon's multicast group and port. A client with no seed and no WAN
/// plan still has to find the other client on the same network, and this is the
/// one thing that needs no configuration at all: every participant announces
/// its endpoint ticket on the group, and every participant joins whoever it
/// hears. The TTL is 1, so it does not leave the local network.
///
/// The group is in the administratively-scoped range (239.0.0.0/8), and the
/// message carries the topic, so a beacon for a different swarm is ignored
/// without knowing anything about its sender. `GOATS_SWARM_LAN=0` disables it.
const LAN_GROUP: Ipv4Addr = Ipv4Addr::new(239, 255, 42, 99);
const LAN_PORT: u16 = 42378;
const LAN_EVERY: Duration = Duration::from_secs(2);
const LAN_MAGIC: &[u8; 4] = b"GSW1";
const LAN_MAX_DATAGRAM: usize = 2048;

/// One listed session. It is both what a host broadcasts and what a player
/// receives; the wire has no reason to distinguish them.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Advert {
    /// The session's own ticket, which is what a portal joins.
    pub ticket: String,
    /// The host's display name.
    pub name: String,
    /// Players in the session, the host included, at the last restatement.
    #[serde(default)]
    pub clients: usize,
    /// The wire protocol the session speaks.
    #[serde(default)]
    pub protocol: u16,
}

/// How a swarm endpoint reaches the rest of the world.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reach {
    /// n0's public relays plus DNS lookup. The default, and what makes a bare
    /// endpoint id dialable across networks.
    Wan,
    /// Direct addresses only, which is what a test (or a LAN with tickets in
    /// hand) needs: no relay, no publishing, nothing to reach outside the room.
    Direct,
}

/// What [`Swarm::join`] is asked for.
pub struct SwarmConfig {
    /// The topic that identifies the swarm.
    pub topic: TopicId,
    /// Peers already in the topic. An empty list subscribes without dialing
    /// anybody: the node listens, and is found only if somebody else dials it.
    pub peers: Vec<EndpointAddr>,
    /// A stable identity for this node, if it should keep the same endpoint id
    /// across restarts (a seed wants this; a player generally does not).
    pub secret: Option<SecretKey>,
    pub reach: Reach,
    /// Announce this endpoint on the local network and join the peers heard
    /// there. On by default: it is what makes two clients on one network meet
    /// with no ticket and no seed. Tests that need isolation turn it off.
    pub lan: bool,
    /// Overridable for tests. Production uses [`ADVERT_EVERY`].
    pub advert_every: Duration,
    /// Overridable for tests. Production uses [`ADVERT_TTL`].
    pub advert_ttl: Duration,
}

impl SwarmConfig {
    /// The production defaults for `topic`, on the WAN.
    pub fn new(topic: TopicId) -> SwarmConfig {
        SwarmConfig {
            topic,
            peers: Vec::new(),
            secret: None,
            reach: Reach::Wan,
            lan: true,
            advert_every: ADVERT_EVERY,
            advert_ttl: ADVERT_TTL,
        }
    }

    /// The default topic, as every client and `goatsd` read it.
    pub fn default_topic() -> TopicId {
        TopicId::from_str(DEFAULT_TOPIC).expect("the default topic is 32 bytes of hex")
    }
}

/// Parses a topic id: 64 hex characters. The empty string is *not* the default;
/// callers decide whether an absent flag means "default".
pub fn parse_topic(text: &str) -> Result<TopicId, String> {
    let text = text.trim();
    TopicId::from_str(text).map_err(|_| format!("{text:?} is not a topic id (64 hex characters)"))
}

/// Parses a swarm seed: an endpoint ticket (which carries addresses) or a bare
/// endpoint id (which is resolved through the address lookup).
pub fn parse_peer(text: &str) -> Result<EndpointAddr, String> {
    let text = text.trim();
    if let Ok(ticket) = EndpointTicket::decode_string(text) {
        return Ok(ticket.endpoint_addr().clone());
    }
    EndpointId::from_str(text)
        .map(EndpointAddr::new)
        .map_err(|_| format!("{text:?} is neither an endpoint ticket nor an endpoint id"))
}

/// Parses a persistent endpoint secret: 32 bytes of hex.
pub fn parse_secret(text: &str) -> Result<SecretKey, String> {
    let text = text.trim();
    let mut bytes = [0u8; 32];
    hex::decode_to_slice(text, &mut bytes)
        .map_err(|_| "an endpoint secret is 64 hex characters".to_string())?;
    Ok(SecretKey::from_bytes(&bytes))
}

/// The seed peers named by `$GOATS_SWARM_PEERS`, comma-separated. Empty when the
/// variable is unset, which is how a LAN-only or test setup runs.
pub fn peers_from_env() -> Result<Vec<EndpointAddr>, String> {
    let Ok(list) = std::env::var("GOATS_SWARM_PEERS") else {
        return Ok(Vec::new());
    };
    let mut peers = Vec::new();
    for entry in list.split(',') {
        let entry = entry.trim();
        if entry.is_empty() {
            continue;
        }
        peers.push(parse_peer(entry).map_err(|error| format!("GOATS_SWARM_PEERS: {error}"))?);
    }
    Ok(peers)
}

/// The persistent secret named by `$GOATS_SWARM_KEY`, if any.
pub fn secret_from_env() -> Result<Option<SecretKey>, String> {
    match std::env::var("GOATS_SWARM_KEY") {
        Ok(text) if !text.trim().is_empty() => parse_secret(&text)
            .map(Some)
            .map_err(|error| format!("GOATS_SWARM_KEY: {error}")),
        _ => Ok(None),
    }
}

/// Something the swarm task reports.
#[derive(Debug, Clone)]
pub enum SwarmEvent {
    /// The current list of hosts, whenever it changes. An empty list is sent when
    /// the last host expires or withdraws.
    Hosts(Vec<Advert>),
    /// How many direct neighbours this node has. Zero means the node is
    /// subscribed but alone.
    Peers(usize),
    /// The gossip stream failed. The task keeps whatever it has; this is a line
    /// for the console, not a shutdown.
    Failed(String),
}

/// A handle to a joined swarm.
///
/// The endpoint, router and gossip actor live on the [`Node`]; this is the
/// subscription's command side plus the event stream, so a caller can drain
/// events in one task and advertise from another. A swarm is one topic on a node
/// that the registry may share, which is why leaving does not close the node.
pub struct Swarm {
    topic: TopicId,
    node: Arc<Node>,
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<SwarmEvent>,
}

impl Swarm {
    /// Binds a gossip-only node, joins `config.topic`, and starts the task that
    /// keeps the list and restates the advert. It returns as soon as the
    /// subscription exists; neighbours arrive as events.
    ///
    /// A caller that also wants the registry binds the [`Node`] itself and uses
    /// [`Swarm::join_on`], so both share one ticket.
    pub async fn join(mut config: SwarmConfig) -> Result<Swarm, Error> {
        let node = Node::bind(NodeConfig {
            secret: config.secret.take(),
            reach: config.reach,
            blobs: None,
        })
        .await?;
        Self::join_on(node, config).await
    }

    /// Joins `config.topic` on `node`. `config.secret` and `config.reach` are the
    /// node's: a node is bound once, and a subscription does not rebind it.
    pub async fn join_on(node: Arc<Node>, config: SwarmConfig) -> Result<Swarm, Error> {
        let SwarmConfig {
            topic,
            peers,
            lan,
            advert_every,
            advert_ttl,
            ..
        } = config;

        for peer in &peers {
            node.add_peer(peer.clone());
        }
        let peer_ids: Vec<EndpointId> = peers.iter().map(|peer| peer.id).collect();
        let (sender, receiver) = node
            .gossip()
            .subscribe(topic, peer_ids)
            .await
            .map_err(|error| Error::Swarm(format!("subscribe: {error}")))?
            .split();

        let (commands, command_rx) = mpsc::channel(COMMAND_BACKLOG);
        let (event_tx, events) = mpsc::channel(COMMAND_BACKLOG);
        if lan {
            spawn_lan(
                topic,
                node.ticket().to_string(),
                node.id(),
                node.lookup().clone(),
                commands.clone(),
                event_tx.clone(),
            );
        }
        tokio::spawn(run(
            receiver,
            sender,
            command_rx,
            event_tx,
            advert_every,
            advert_ttl,
        ));

        Ok(Swarm {
            topic,
            node,
            commands,
            events,
        })
    }

    /// The node this swarm is a subscription on, so a registry (or a second swarm
    /// after `swarm join`) can use the same endpoint and ticket.
    pub fn node(&self) -> &Arc<Node> {
        &self.node
    }

    /// The topic this swarm is.
    pub fn topic(&self) -> TopicId {
        self.topic
    }

    /// This node's endpoint id, which is what a peer list needs when the
    /// address lookup can resolve it.
    pub fn id(&self) -> EndpointId {
        self.node.id()
    }

    /// This node's endpoint address, addresses included.
    pub fn addr(&self) -> &EndpointAddr {
        self.node.addr()
    }

    /// A ticket for this node. Hand it to a node that has nothing else: it
    /// carries the addresses, so no lookup is involved, and it introduces the
    /// catalogue as well as the session.
    pub fn ticket(&self) -> &str {
        self.node.ticket()
    }

    /// A cloneable command side, for the caller that advertises while another
    /// task drains [`Swarm::next_event`].
    pub fn commands(&self) -> SwarmCommands {
        SwarmCommands(self.commands.clone())
    }

    /// The next event, or `None` once the swarm task has ended.
    pub async fn next_event(&mut self) -> Option<SwarmEvent> {
        self.events.recv().await
    }
}

/// The command side of a swarm, cloneable and non-blocking.
#[derive(Clone)]
pub struct SwarmCommands(mpsc::Sender<Command>);

impl SwarmCommands {
    /// Makes `advert` this node's current claim, broadcasting it now and again on
    /// the task's timer until it is withdrawn or replaced.
    pub fn advertise(&self, advert: Advert) {
        if self.0.try_send(Command::Advert(advert)).is_err() {
            // A full queue means the gossip task is wedged or gone; the next
            // timer tick (or a new swarm) is the recovery, and a dropped advert
            // is invisible until then.
        }
    }

    /// Withdraws this node's advert. A host that stops hosting should call this
    /// rather than leave its portal up for the TTL.
    pub fn withdraw(&self) {
        let _ = self.0.try_send(Command::Withdraw);
    }

    /// Leaves the topic. The task broadcasts a withdrawal if it had an advert.
    /// The node stays open, because a catalogue may be a second subscription on
    /// it; whoever bound the node closes it.
    pub fn leave(&self) {
        let _ = self.0.try_send(Command::Leave);
    }
}

enum Command {
    Advert(Advert),
    Withdraw,
    Peers(Vec<EndpointId>),
    Leave,
}

/// One message on the topic. The nonce is not a security measure: gossip
/// deduplicates by content hash, and a restated advert with the same bytes would
/// be dropped before it reached the other side.
#[derive(Debug, Serialize, Deserialize)]
enum Wire {
    Advert { advert: Advert, nonce: u64 },
    Gone { ticket: String, nonce: u64 },
}

impl Wire {
    fn decode(bytes: &[u8]) -> Option<Wire> {
        postcard::from_bytes(bytes).ok()
    }

    fn encode(&self) -> Option<Bytes> {
        postcard::to_allocvec(self).ok().map(Bytes::from)
    }
}

/// The gossip task: owns the endpoint's router and the receiver, keeps the list,
/// and restates the advert.
async fn run(
    mut receiver: GossipReceiver,
    sender: GossipSender,
    mut commands: mpsc::Receiver<Command>,
    events: mpsc::Sender<SwarmEvent>,
    advert_every: Duration,
    advert_ttl: Duration,
) {
    let mut own: Option<Advert> = None;
    let mut last_broadcast: Option<Instant> = None;
    let mut hosts: HashMap<String, (Advert, Instant)> = HashMap::new();
    let mut neighbours: HashSet<EndpointId> = HashSet::new();

    // Prune on a cadence fine enough for the TTL to mean something, and restate
    // on the advert's own window. One timer drives both: `tick_every` is the
    // smaller of the two, and the broadcast checks its own deadline.
    let tick_every = advert_every
        .min(advert_ttl / 3)
        .max(Duration::from_millis(25));
    let mut ticker = tokio::time::interval(tick_every);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            command = commands.recv() => match command {
                None => break,
                Some(Command::Advert(advert)) => {
                    own = Some(advert.clone());
                    let _ = broadcast_advert(&sender, &advert).await;
                    last_broadcast = Some(Instant::now());
                }
                Some(Command::Withdraw) => {
                    if let Some(advert) = own.take() {
                        let _ = broadcast_gone(&sender, &advert.ticket).await;
                    }
                }
                // A peer heard on the LAN. Gossip dials it by id, and the
                // beacon has already put its ticket in the address lookup.
                Some(Command::Peers(peers)) => {
                    let _ = sender.join_peers(peers).await;
                }
                Some(Command::Leave) => break,
            },
            event = receiver.next() => match event {
                None => break,
                Some(Err(error)) => {
                    let _ = events.send(SwarmEvent::Failed(error.to_string())).await;
                }
                Some(Ok(GossipEvent::Received(message))) => {
                    match Wire::decode(&message.content) {
                        Some(Wire::Advert { advert, .. }) => {
                            // Our own advert comes back on some paths; it is not a
                            // discovered host.
                            if own.as_ref().is_some_and(|own| own.ticket == advert.ticket) {
                                continue;
                            }
                            let Some(advert) = clean(advert) else {
                                continue;
                            };
                            let unchanged = hosts
                                .get(&advert.ticket)
                                .is_some_and(|(current, _)| current == &advert);
                            hosts.insert(advert.ticket.clone(), (advert, Instant::now()));
                            if hosts.len() > MAX_HOSTS
                                && let Some(oldest) = hosts
                                    .iter()
                                    .min_by_key(|(_, (_, seen))| *seen)
                                    .map(|(ticket, _)| ticket.clone())
                            {
                                hosts.remove(&oldest);
                            }
                            if !unchanged {
                                let _ = events.send(SwarmEvent::Hosts(list(&hosts))).await;
                            }
                        }
                        Some(Wire::Gone { ticket, .. })
                            if hosts.remove(&ticket).is_some() =>
                        {
                            let _ = events.send(SwarmEvent::Hosts(list(&hosts))).await;
                        }
                        Some(Wire::Gone { .. }) => {}
                        None => {}
                    }
                }
                Some(Ok(GossipEvent::NeighborUp(id))) => {
                    let before = neighbours.len();
                    neighbours.insert(id);
                    if neighbours.len() != before {
                        let _ = events.send(SwarmEvent::Peers(neighbours.len())).await;
                    }
                    // A neighbour that just arrived missed every earlier
                    // broadcast, and the timer may be most of a window away.
                    if let Some(advert) = &own {
                        let _ = broadcast_advert(&sender, advert).await;
                        last_broadcast = Some(Instant::now());
                    }
                }
                Some(Ok(GossipEvent::NeighborDown(id))) => {
                    let before = neighbours.len();
                    neighbours.remove(&id);
                    if neighbours.len() != before {
                        let _ = events.send(SwarmEvent::Peers(neighbours.len())).await;
                    }
                }
                // The protocol dropped messages because this task fell behind.
                // The periodic restatement is what heals it; a host that stays
                // silent for a full window is dropped by the TTL anyway.
                Some(Ok(GossipEvent::Lagged)) => {}
            },
            _ = ticker.tick() => {
                let now = Instant::now();
                let before = hosts.len();
                hosts.retain(|_, (_, seen)| now.duration_since(*seen) < advert_ttl);
                if hosts.len() != before {
                    let _ = events.send(SwarmEvent::Hosts(list(&hosts))).await;
                }
                if last_broadcast.is_none_or(|when| now.duration_since(when) >= advert_every) {
                    if let Some(advert) = &own {
                        let _ = broadcast_advert(&sender, advert).await;
                    }
                    last_broadcast = Some(now);
                }
            }
        }
    }

    // Leaving is not silent: a node that closes the window should take its
    // portal with it rather than wait out the TTL. This is best effort -- the
    // process may be going away -- which is why the TTL exists. The node itself
    // stays open: a catalogue may be a second subscription on it.
    if let Some(advert) = own {
        let _ = broadcast_gone(&sender, &advert.ticket).await;
    }
}

/// Announce this endpoint on the local network and join whoever else is there.
///
/// The socket binds the group's port with `SO_REUSEADDR` (and `SO_REUSEPORT` on
/// unix), so two clients on one machine -- the common way to test this -- both
/// receive. A machine with no multicast route loses nothing else: tickets and
/// seeds still work, and the failure is reported as a notice rather than taking
/// the swarm down.
fn spawn_lan(
    topic: TopicId,
    ticket: String,
    own: EndpointId,
    lookup: MemoryLookup,
    commands: mpsc::Sender<Command>,
    events: mpsc::Sender<SwarmEvent>,
) {
    let message = {
        let mut bytes = Vec::with_capacity(LAN_MAGIC.len() + 32 + ticket.len());
        bytes.extend_from_slice(LAN_MAGIC);
        bytes.extend_from_slice(topic.as_bytes());
        bytes.extend_from_slice(ticket.as_bytes());
        bytes
    };
    tokio::spawn(async move {
        let socket = match lan_socket() {
            Ok(socket) => socket,
            Err(error) => {
                let _ = events
                    .send(SwarmEvent::Failed(format!("lan: {error}")))
                    .await;
                return;
            }
        };
        let group = SocketAddr::new(LAN_GROUP.into(), LAN_PORT);
        let mut seen: HashSet<EndpointId> = HashSet::new();
        let mut ticker = tokio::time::interval(LAN_EVERY);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut buf = vec![0u8; LAN_MAX_DATAGRAM.max(message.len())];
        loop {
            tokio::select! {
                _ = ticker.tick() => {
                    let _ = socket.send_to(&message, group).await;
                    // `run` owns the receiver; when it ends -- a `Leave`, or the
                    // client dropping the handle -- this beacon has nothing left
                    // to be found for.
                    if commands.is_closed() {
                        break;
                    }
                }
                received = socket.recv_from(&mut buf) => {
                    let Ok((len, _)) = received else { continue };
                    let Some((id, addr)) = lan_parse(&buf[..len], topic) else {
                        continue;
                    };
                    // Our own beacon loops back; and a peer is introduced once,
                    // not every two seconds.
                    if id == own || !seen.insert(id) {
                        continue;
                    }
                    lookup.add_endpoint_info(addr);
                    if commands.send(Command::Peers(vec![id])).await.is_err() {
                        break;
                    }
                }
            }
        }
    });
}

/// The multicast socket the beacon sends and receives on.
fn lan_socket() -> std::io::Result<tokio::net::UdpSocket> {
    let socket = Socket::new(Domain::IPV4, Type::DGRAM, Some(Protocol::UDP))?;
    // Two clients on one machine are the normal case here, and both have to
    // receive the group's traffic.
    socket.set_reuse_address(true)?;
    #[cfg(unix)]
    socket.set_reuse_port(true)?;
    socket.set_nonblocking(true)?;
    socket.bind(&SocketAddr::new(Ipv4Addr::UNSPECIFIED.into(), LAN_PORT).into())?;
    // Loopback is what lets the two processes on one host hear each other; the
    // TTL of 1 keeps the beacon inside the local network.
    socket.set_multicast_loop_v4(true)?;
    socket.set_multicast_ttl_v4(1)?;
    socket.join_multicast_v4(&LAN_GROUP, &Ipv4Addr::UNSPECIFIED)?;
    tokio::net::UdpSocket::from_std(socket.into())
}

/// One beacon, decoded. Anything that is not this swarm's topic -- or not a
/// ticket this build can read -- is ignored, which is the only filter needed on
/// a group anyone on the link can post to.
fn lan_parse(bytes: &[u8], topic: TopicId) -> Option<(EndpointId, EndpointAddr)> {
    let rest = bytes.strip_prefix(LAN_MAGIC)?;
    if rest.len() <= 32 {
        return None;
    }
    let (announced, ticket) = rest.split_at(32);
    if announced != topic.as_bytes() {
        return None;
    }
    let ticket: EndpointTicket = std::str::from_utf8(ticket).ok()?.parse().ok()?;
    let addr = ticket.endpoint_addr();
    Some((addr.id, addr.clone()))
}

async fn broadcast_advert(sender: &GossipSender, advert: &Advert) -> Result<(), ()> {
    let wire = Wire::Advert {
        advert: advert.clone(),
        nonce: nonce(),
    };
    let Some(bytes) = wire.encode() else {
        return Err(());
    };
    sender.broadcast(bytes).await.map_err(|_| ())
}

async fn broadcast_gone(sender: &GossipSender, ticket: &str) -> Result<(), ()> {
    let wire = Wire::Gone {
        ticket: ticket.to_string(),
        nonce: nonce(),
    };
    let Some(bytes) = wire.encode() else {
        return Err(());
    };
    sender.broadcast(bytes).await.map_err(|_| ())
}

/// A nonce that makes every restatement a different message, so gossip's
/// content-hash deduplication does not swallow it. The clock plus a counter is
/// enough: this is not an identity, and it never reaches the list.
fn nonce() -> u64 {
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let clock = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_nanos() as u64)
        .unwrap_or(0);
    clock ^ COUNTER.fetch_add(1, Ordering::Relaxed).rotate_left(17)
}

/// The list as the scene sees it: newest facts only, in a stable order so two
/// polls that changed nothing produce the same bytes.
fn list(hosts: &HashMap<String, (Advert, Instant)>) -> Vec<Advert> {
    let mut list: Vec<Advert> = hosts.values().map(|(advert, _)| advert.clone()).collect();
    list.sort_by(|a, b| (&a.name, &a.ticket).cmp(&(&b.name, &b.ticket)));
    list
}

/// A received advert, cleaned to what is safe to show. A hostile peer can send
/// anything; the caps and the control-character scrub are the whole defence, and
/// an advert that has no ticket or no name is dropped rather than displayed.
fn clean(mut advert: Advert) -> Option<Advert> {
    advert.ticket = advert.ticket.trim().to_string();
    if advert.ticket.is_empty()
        || advert.ticket.len() > MAX_TICKET_BYTES
        || advert.ticket.chars().any(char::is_control)
    {
        return None;
    }
    advert.name = advert
        .name
        .trim()
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .take(MAX_NAME_CHARS)
        .collect();
    advert.name = advert.name.trim().to_string();
    if advert.name.is_empty() {
        return None;
    }
    advert.clients = advert.clients.min(MAX_CLIENTS);
    Some(advert)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::time::timeout;

    fn topic(byte: u8) -> TopicId {
        TopicId::from_bytes([byte; 32])
    }

    fn config(topic: TopicId) -> SwarmConfig {
        SwarmConfig {
            topic,
            peers: Vec::new(),
            secret: None,
            reach: Reach::Direct,
            // The other tests seed each other explicitly; a beacon on the shared
            // group would let two parallel cases find each other.
            lan: false,
            advert_every: Duration::from_millis(50),
            advert_ttl: Duration::from_millis(2000),
        }
    }

    fn advert(ticket: &str, name: &str) -> Advert {
        Advert {
            ticket: ticket.to_string(),
            name: name.to_string(),
            clients: 1,
            protocol: 13,
        }
    }

    async fn next(swarm: &mut Swarm) -> SwarmEvent {
        timeout(Duration::from_secs(20), swarm.next_event())
            .await
            .expect("no swarm event in time")
            .expect("the swarm ended")
    }

    /// Waits for a host list matching `wanted`, skipping neighbour events.
    async fn hosts(swarm: &mut Swarm, wanted: impl Fn(&[Advert]) -> bool) -> Vec<Advert> {
        loop {
            if let SwarmEvent::Hosts(list) = next(swarm).await
                && wanted(&list)
            {
                return list;
            }
        }
    }

    fn seed(swarm: &Swarm) -> EndpointAddr {
        EndpointTicket::decode_string(swarm.ticket())
            .expect("a ticket")
            .endpoint_addr()
            .clone()
    }

    #[test]
    fn the_default_topic_is_a_stable_hash() {
        assert_eq!(
            SwarmConfig::default_topic().to_string(),
            DEFAULT_TOPIC,
            "the default is part of the wire contract"
        );
        assert!(parse_topic("not a topic").is_err());
        assert!(parse_topic("").is_err());
    }

    #[test]
    fn a_peer_may_be_a_ticket_or_an_id() {
        let secret = SecretKey::from_bytes(&[9u8; 32]);
        let id = secret.public();
        assert_eq!(parse_peer(&id.to_string()).expect("id").id, id);

        let addr = EndpointAddr::new(id);
        let ticket = EndpointTicket::new(addr.clone()).encode_string();
        let parsed = parse_peer(&ticket).expect("ticket");
        assert_eq!(parsed.id, addr.id);
    }

    #[test]
    fn an_advert_is_cut_to_what_can_be_displayed() {
        let mut hostile = advert("ticket", "");
        assert!(clean(hostile.clone()).is_none(), "a blank name is dropped");
        hostile.name = "ok".to_string();
        hostile.ticket = "ticket\r\nX: y".to_string();
        assert!(
            clean(hostile.clone()).is_none(),
            "a control character is dropped"
        );
        hostile.ticket = "x".repeat(MAX_TICKET_BYTES + 1);
        assert!(clean(hostile).is_none(), "an oversized ticket is dropped");

        let long = "n".repeat(MAX_NAME_CHARS + 20);
        let cleaned = clean(advert("ticket", &long)).expect("a long name is kept short");
        assert_eq!(cleaned.name.chars().count(), MAX_NAME_CHARS);
        assert_eq!(clean(advert("ticket", "bob")).expect("valid").clients, 1);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn two_swarms_exchange_a_host_and_its_withdrawal() {
        let topic = topic(7);
        let host = Swarm::join(config(topic)).await.expect("host swarm");
        let mut watcher = Swarm::join(SwarmConfig {
            peers: vec![seed(&host)],
            ..config(topic)
        })
        .await
        .expect("watcher swarm");

        host.commands().advertise(advert("ticket-a", "bob"));
        let listed = hosts(&mut watcher, |list| !list.is_empty()).await;
        assert_eq!(listed, vec![advert("ticket-a", "bob")]);

        host.commands().withdraw();
        hosts(&mut watcher, |list| list.is_empty()).await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_advert_expires_when_its_host_stops_restating_it() {
        let topic = topic(8);
        // The host does not restate: its advertise window is far past the test.
        let host = Swarm::join(SwarmConfig {
            advert_every: Duration::from_secs(3600),
            ..config(topic)
        })
        .await
        .expect("host swarm");
        let mut watcher = Swarm::join(SwarmConfig {
            peers: vec![seed(&host)],
            advert_every: Duration::from_secs(3600),
            advert_ttl: Duration::from_millis(150),
            ..config(topic)
        })
        .await
        .expect("watcher swarm");

        host.commands().advertise(advert("ticket-a", "bob"));
        // The one restatement is the neighbour-up broadcast, not the timer: the
        // advert is set before the watcher connects, or after, either way the
        // list has it once.
        hosts(&mut watcher, |list| !list.is_empty()).await;
        let listed = hosts(&mut watcher, |list| list.is_empty()).await;
        assert!(listed.is_empty());
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn the_lan_beacon_finds_a_host_with_no_seed() {
        // No peers and no `goatsd`: the two nodes have to hear each other on the
        // multicast group. Two sockets on one port is the case the reuse flags
        // exist for, and it is also the way a player tests two windows.
        let topic = topic(10);
        let lan = || SwarmConfig {
            lan: true,
            advert_every: Duration::from_millis(50),
            ..config(topic)
        };
        let host = Swarm::join(lan()).await.expect("host swarm");
        let mut watcher = Swarm::join(lan()).await.expect("watcher swarm");

        host.commands().advertise(advert("ticket-lan", "bob"));
        let listed = hosts(&mut watcher, |list| !list.is_empty()).await;
        assert_eq!(listed, vec![advert("ticket-lan", "bob")]);
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn leaving_takes_the_portal_down() {
        let topic = topic(9);
        let host = Swarm::join(config(topic)).await.expect("host swarm");
        let mut watcher = Swarm::join(SwarmConfig {
            peers: vec![seed(&host)],
            ..config(topic)
        })
        .await
        .expect("watcher swarm");

        host.commands().advertise(advert("ticket-a", "bob"));
        hosts(&mut watcher, |list| !list.is_empty()).await;

        host.commands().leave();
        hosts(&mut watcher, |list| list.is_empty()).await;
    }
}
