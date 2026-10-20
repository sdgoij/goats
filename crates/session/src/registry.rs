//! The mod registry: a gossip topic for the index, `iroh-blobs` for the bytes.
//!
//! The swarm answers "who is hosting a session"; this answers "who has this
//! package". A package is a directory tree rooted at `mod.json`, named by a
//! BLAKE3 collection hash, and the record that names it is a few hundred bytes
//! on a second gossip topic. The transfer is not a new protocol: `iroh-blobs`
//! already moves a tree of blobs as verified streams, so the registry only has
//! to supply the provider set its downloader asks for.
//!
//! The design is `SWARM.md`, "A mod registry". Two things are worth repeating
//! here because they shape the code:
//!
//! - **Records and haves are separate.** A record says what a mod is; a have
//!   says who can serve its root. The author announces both, and a mirror
//!   restates both for what it holds. A record alone is not a promise of bytes.
//! - **Nothing is installed from the topic.** [`Registry::fetch`] is an
//!   explicit call with a destination; the caller still runs the loader and the
//!   join's identity check (`pull`), and no automatic path enables a fetched
//!   client-side mod.
//!
//! The endpoint is not this module's own. A [`Node`] owns the router, and it
//! accepts the blobs protocol beside gossip, so a client that runs both a swarm
//! and a catalogue has one socket, one identity and one ticket. The registry
//! only subscribes to its topic on that node; [`Registry::shutdown`] leaves it
//! running for the swarm, because whoever bound it decides when it closes.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Component, Path, PathBuf};
use std::str::FromStr;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use bytes::Bytes;
use iroh::address_lookup::memory::MemoryLookup;
use iroh::{EndpointAddr, EndpointId, SecretKey};
use iroh_blobs::api::downloader::{ContentDiscovery, DownloadRequest, Downloader, SplitStrategy};
use iroh_blobs::api::{Store, TempTag};
use iroh_blobs::format::collection::Collection;
use iroh_blobs::protocol::GetRequest;
use iroh_blobs::{BlobFormat, Hash, HashAndFormat};
use iroh_gossip::TopicId;
use iroh_gossip::api::{Event as GossipEvent, GossipReceiver, GossipSender};
use n0_future::StreamExt;
use proto::{
    MAX_PACKAGE_BYTES, MAX_REGISTRY_MESSAGE_BYTES, MAX_REGISTRY_RECORDS, ModHave, ModRecord, ModRef,
};
use serde::{Deserialize, Serialize};
use tokio::sync::mpsc;

use crate::Error;
use crate::node::{Node, NodeConfig};
use crate::swarm::{Reach, parse_peer, parse_topic};

/// `SHA-256("goats/mods/v1")`, in the hex form a [`TopicId`] parses. A separate
/// topic from the host list on purpose: a record flood must not evict portals,
/// and a catalogue has a different natural cap from a host list.
pub const DEFAULT_TOPIC: &str = "93a3969b8c2b4e679f4cfdd4704d58f8ccc4413cc6ee25d3bac16796647f783f";

/// How often a provider restates its records and haves. A restatement is a
/// heartbeat: a new neighbour has missed everything before it arrived.
pub const RECORD_EVERY: Duration = Duration::from_secs(30);

/// How long a record or have outlives its last restatement.
pub const RECORD_TTL: Duration = Duration::from_secs(90);

/// The most providers kept for one root. A downloader tries them in order.
pub const MAX_PROVIDERS: usize = 64;

/// The default mirror budget: a gibibyte. A mirror is a disk commitment, so a
/// caller that offers more passes its own number; `0` means no limit.
pub const DEFAULT_MIRROR_BYTES: u64 = 1 << 30;

/// How many commands may queue before a send starts failing. Publishing is
/// rare; this only has to absorb a burst of shares.
const COMMAND_BACKLOG: usize = 16;

/// How a catalogue is reached and what it keeps.
///
/// `topic`, `peers`, `every` and `ttl` are the catalogue's own. `secret` and
/// `reach` only matter to [`Registry::start`], which binds a node of its own;
/// [`Registry::start_on`] takes both from the node it was handed, because a node
/// is bound once and has one identity.
pub struct RegistryConfig {
    pub topic: TopicId,
    /// Peers already in the topic. Empty subscribes without dialing anybody.
    pub peers: Vec<EndpointAddr>,
    pub secret: Option<SecretKey>,
    pub reach: Reach,
    /// The directory the blob store lives in. Created if missing.
    pub store: PathBuf,
    /// Overridable for tests. Production uses [`RECORD_EVERY`].
    pub every: Duration,
    /// Overridable for tests. Production uses [`RECORD_TTL`].
    pub ttl: Duration,
}

impl RegistryConfig {
    /// Production defaults for `topic`, on the WAN.
    pub fn new(topic: TopicId, store: PathBuf) -> RegistryConfig {
        RegistryConfig {
            topic,
            peers: Vec::new(),
            secret: None,
            reach: Reach::Wan,
            store,
            every: RECORD_EVERY,
            ttl: RECORD_TTL,
        }
    }

    /// The game's own registry topic.
    pub fn default_topic() -> TopicId {
        TopicId::from_str(DEFAULT_TOPIC).expect("the default topic is 32 bytes of hex")
    }

    /// The registry's configuration from the environment, or `None` when
    /// `GOATS_MODS_REGISTRY=0`.
    ///
    /// `GOATS_REGISTRY_PEERS` seeds the catalogue with nodes already on its topic.
    /// A client sharing the swarm's node hears the introduction there instead, so
    /// this is the standing form for a node with no swarm (`--nojoin`, a test, a
    /// catalogue-only process). The identity is the node's -- `GOATS_SWARM_KEY`
    /// for a client -- and `GOATS_REGISTRY_TOPIC` selects another catalogue.
    pub fn from_env(store: PathBuf) -> Result<Option<RegistryConfig>, String> {
        if std::env::var("GOATS_MODS_REGISTRY").is_ok_and(|value| value.trim() == "0") {
            return Ok(None);
        }
        let topic = match std::env::var("GOATS_REGISTRY_TOPIC") {
            Ok(text) if !text.trim().is_empty() => {
                parse_topic(&text).map_err(|error| format!("GOATS_REGISTRY_TOPIC: {error}"))?
            }
            _ => RegistryConfig::default_topic(),
        };
        let mut peers = Vec::new();
        if let Ok(list) = std::env::var("GOATS_REGISTRY_PEERS") {
            for entry in list.split(',') {
                let entry = entry.trim();
                if entry.is_empty() {
                    continue;
                }
                peers.push(
                    parse_peer(entry).map_err(|error| format!("GOATS_REGISTRY_PEERS: {error}"))?,
                );
            }
        }
        Ok(Some(RegistryConfig {
            topic,
            peers,
            // No catalogue-owned identity: whoever binds the endpoint owns it, and
            // that node's secret is the identity.
            secret: None,
            reach: Reach::Wan,
            store,
            every: RECORD_EVERY,
            ttl: RECORD_TTL,
        }))
    }
}

/// Something the registry task reports. The catalogue is also queryable at any
/// time; these events are the "something changed" signal for a UI.
#[derive(Debug, Clone)]
pub enum RegistryEvent {
    /// The record list as it now stands, whenever it changes.
    Records(Vec<ModRecord>),
    /// The gossip stream failed. The task keeps what it has.
    Failed(String),
}

/// A joined registry, with the blob store it serves from.
pub struct Registry {
    topic: TopicId,
    /// The node this catalogue subscribes on, shared with the swarm when there is
    /// one. It owns the endpoint, the router and the store.
    node: Arc<Node>,
    store: Store,
    downloader: Downloader,
    catalogue: Arc<Mutex<Catalogue>>,
    commands: mpsc::Sender<Command>,
    events: mpsc::Receiver<RegistryEvent>,
    /// What this node keeps on other people's behalf: a tag per root, with the
    /// size and age that decide what goes when the budget is reached.
    mirror: Mutex<Mirror>,
    /// The tags that keep what this node shares alive against garbage
    /// collection. They live for as long as the handle does; a restart
    /// re-imports the same trees, which is why the records expire anyway.
    tags: Arc<Mutex<Vec<TempTag>>>,
}

impl Registry {
    /// Binds a node of its own, opens the blob store and joins the topic. This is
    /// the standalone form, for a test or a process that runs only a catalogue; a
    /// client that also runs a swarm calls [`Registry::start_on`] with the node
    /// the swarm joined, so both share one endpoint and one ticket.
    pub async fn start(mut config: RegistryConfig) -> Result<Registry, Error> {
        let node = Node::bind(NodeConfig {
            secret: config.secret.take(),
            reach: config.reach,
            blobs: Some(config.store.clone()),
            session: false,
        })
        .await?;
        Self::start_on(node, config).await
    }

    /// Joins the topic on `node` and starts the task that keeps the catalogue and
    /// restates this node's records.
    ///
    /// The node must have been bound with a blob store (`NodeConfig::blobs`): the
    /// store is where a package's bytes live and what the transfer protocol
    /// serves, and a router cannot gain that protocol after it has spawned.
    /// `config.secret` and `config.reach` are the node's and are not read here.
    pub async fn start_on(node: Arc<Node>, config: RegistryConfig) -> Result<Registry, Error> {
        let RegistryConfig {
            topic,
            peers,
            every,
            ttl,
            ..
        } = config;

        let Some(store) = node.store().cloned() else {
            return Err(Error::Registry(
                "the node has no blob store; bind it with NodeConfig::blobs".to_string(),
            ));
        };

        for peer in &peers {
            node.add_peer(peer.clone());
        }
        let peer_ids: Vec<EndpointId> = peers.iter().map(|peer| peer.id).collect();
        let (sender, receiver) = node
            .gossip()
            .subscribe(topic, peer_ids)
            .await
            .map_err(|error| Error::Registry(format!("subscribe: {error}")))?
            .split();

        let catalogue = Arc::new(Mutex::new(Catalogue::default()));
        let (commands, command_rx) = mpsc::channel(COMMAND_BACKLOG);
        let (event_tx, events) = mpsc::channel(COMMAND_BACKLOG);
        tokio::spawn(run(Task {
            receiver,
            sender,
            commands: command_rx,
            events: event_tx,
            catalogue: catalogue.clone(),
            own_id: node.id(),
            every,
            ttl,
        }));

        let downloader = Downloader::new(&store, node.endpoint());
        Ok(Registry {
            topic,
            node,
            store,
            downloader,
            catalogue,
            commands,
            events,
            mirror: Mutex::new(Mirror::default()),
            tags: Arc::new(Mutex::new(Vec::new())),
        })
    }

    /// Import `dir` as a package, fill in its address on `record`, and announce
    /// it and a have. The returned record is the one on the wire.
    ///
    /// `dir` is the canonical tree (`mods::ModSource::materialize` produces
    /// one from a zip or an in-memory source). The caller builds the rest of the
    /// record from the manifest: id, version, api, side and the FNV digest a
    /// join compares. This fills `root`, `size` and `author`.
    pub async fn share(&self, mut record: ModRecord, dir: &Path) -> Result<ModRecord, String> {
        let (root, size, tags) = import_tree(&self.store, dir).await?;
        self.tags.lock().expect("tags").extend(tags);

        record.root = *root.as_bytes();
        record.size = size;
        record.author = *self.node.id().as_bytes();
        let record = record
            .clean()
            .ok_or_else(|| "the record is not usable".to_string())?;

        self.catalogue
            .lock()
            .expect("catalogue")
            .insert(record.clone(), Instant::now());
        // This node is a provider too, whether or not the broadcast comes back.
        self.catalogue
            .lock()
            .expect("catalogue")
            .have(record.root, self.node.id(), Instant::now());
        // Not `try_send`: a share that the task never hears is a share that is
        // never restated, which is worse than waiting for the queue.
        self.commands
            .send(Command::Publish(record.clone()))
            .await
            .map_err(|_| "the registry task has stopped".to_string())?;
        Ok(record)
    }

    /// Advertise that this node can serve `root`. A fetch is not automatic, so
    /// a mirror calls this after it has the bytes and has decided to keep them.
    pub fn serve(&self, root: [u8; 32]) {
        self.catalogue
            .lock()
            .expect("catalogue")
            .have(root, self.node.id(), Instant::now());
        let _ = self.commands.try_send(Command::Have(vec![root]));
    }

    /// Restate a record this node did not write, for a root it can serve. This
    /// is the mirror half of sharing: the record keeps its original `author`, so
    /// a peer that joins after the author leaves still learns what the package
    /// is, and the have is what makes it fetchable.
    pub async fn relay(&self, record: ModRecord) -> Result<(), String> {
        let record = record
            .clean()
            .ok_or_else(|| "the record is not usable".to_string())?;
        if !self.providers(&record.root).contains(&self.node.id()) {
            return Err("this node does not have the bytes".to_string());
        }
        self.catalogue
            .lock()
            .expect("catalogue")
            .insert(record.clone(), Instant::now());
        self.commands
            .send(Command::Publish(record))
            .await
            .map_err(|_| "the registry task has stopped".to_string())
    }

    /// Stop serving `root`. The author's withdrawal takes the record down; any
    /// sender's withdrawal removes only its own have.
    pub fn withdraw(&self, root: [u8; 32]) {
        self.catalogue
            .lock()
            .expect("catalogue")
            .withdraw(root, self.node.id());
        // Stop serving it in this process too: the pin is what kept it alive.
        self.mirror.lock().expect("mirror").pins.remove(&root);
        let _ = self.commands.try_send(Command::Withdraw(root));
    }

    /// This node's endpoint id, which is what a provider list contains.
    pub fn id(&self) -> EndpointId {
        self.node.id()
    }

    /// This node's endpoint address, addresses included.
    pub fn addr(&self) -> &EndpointAddr {
        self.node.addr()
    }

    /// A ticket another node can seed from. It is the same ticket the session
    /// uses: one endpoint, one ticket.
    pub fn ticket(&self) -> &str {
        self.node.ticket()
    }

    /// A cloneable handle for another task to seed this catalogue with tickets it
    /// heard. `mod peer` on the console is the caller: it lives on the frame or
    /// event side, while the registry handle lives here.
    pub fn peers(&self) -> RegistryPeers {
        RegistryPeers {
            lookup: self.node.lookup().clone(),
            commands: self.commands.clone(),
            id: self.node.id(),
        }
    }

    pub fn topic(&self) -> TopicId {
        self.topic
    }

    /// The records currently known, in a stable order.
    pub fn records(&self) -> Vec<ModRecord> {
        self.catalogue.lock().expect("catalogue").list()
    }

    /// The record that would satisfy a join's reference, preferring one with a
    /// live provider when two packages claim the same id and version.
    pub fn find(&self, reference: &ModRef) -> Option<ModRecord> {
        self.catalogue.lock().expect("catalogue").find(reference)
    }

    /// The record `id[@version]` names, preferring a package with a live provider
    /// and then the greatest version label. The console's `mod fetch` and `mod
    /// mirror` share this rule, so `birds` and `birds@1.0.0` mean the same thing in
    /// both clients.
    pub fn find_by(&self, id: &str, version: Option<&str>) -> Option<ModRecord> {
        let mut matches: Vec<ModRecord> = self
            .records()
            .into_iter()
            .filter(|record| {
                record.id == id && version.is_none_or(|wanted| record.version == wanted)
            })
            .collect();
        matches.sort_by(|a, b| {
            (self.providers(&a.root).is_empty(), &a.version, a.root).cmp(&(
                self.providers(&b.root).is_empty(),
                &b.version,
                b.root,
            ))
        });
        matches.pop()
    }

    /// The endpoints that restated a have for `root`, author first.
    pub fn providers(&self, root: &[u8; 32]) -> Vec<EndpointId> {
        self.catalogue.lock().expect("catalogue").providers(root)
    }

    /// Pin a fetched root against garbage collection and return the tag name.
    /// A mirror calls this after [`Registry::fetch`] and before [`Registry::serve`]:
    /// the tag is what makes "I keep other people's mods" survive a GC pass.
    pub async fn pin(&self, root: [u8; 32]) -> Result<Vec<u8>, String> {
        let value = HashAndFormat {
            hash: Hash::from(root),
            format: BlobFormat::HashSeq,
        };
        let tag = self
            .store
            .tags()
            .create(value)
            .await
            .map_err(|error| format!("pin: {error}"))?;
        Ok(tag.as_ref().to_vec())
    }

    /// Drop a pin from [`Registry::pin`]; the blobs become collectable. A mirror
    /// that stops keeping a package also stops restating its have and lets it
    /// expire.
    pub async fn unpin(&self, name: &[u8]) -> Result<(), String> {
        self.store
            .tags()
            .delete(name)
            .await
            .map_err(|error| format!("unpin: {error}"))?;
        Ok(())
    }

    /// The next change event, or `None` once the task has ended.
    pub async fn next_event(&mut self) -> Option<RegistryEvent> {
        self.events.recv().await
    }

    /// Download `record`'s package into the store. This is the transfer half of
    /// [`Registry::fetch`]; a mirror uses it without the export.
    pub async fn download(&self, record: &ModRecord) -> Result<(), String> {
        let providers = self.providers(&record.root);
        if providers.is_empty() {
            return Err(format!("{}@{} has no provider", record.id, record.version));
        }
        let root = Hash::from(record.root);
        let request = DownloadRequest::new(
            GetRequest::all(root),
            Providers(providers),
            SplitStrategy::None,
        );
        self.downloader
            .download_with_opts(request)
            .await
            .map_err(|error| format!("download {:?}: {error}", record.id))
    }

    /// Download `record`'s package and export it into `dest`.
    ///
    /// Every chunk is verified by the transport against `root`, and the file
    /// names come from the collection's own index -- which is itself part of
    /// what `root` names. The caller still has to run the loader and compare
    /// the join's identity; this function does not decide whether to install.
    pub async fn fetch(&self, record: &ModRecord, dest: &Path) -> Result<(), String> {
        self.download(record).await?;
        export_collection(&self.store, Hash::from(record.root), dest).await
    }

    /// Keep serving `record` on other peers' behalf, within `budget` bytes.
    ///
    /// The package is downloaded if this node does not have it, pinned against
    /// garbage collection, announced with a have and its record restated. The
    /// oldest pins are dropped until the total fits, so a mirror has a ceiling
    /// rather than a growing cache. `budget == 0` means no ceiling. A single
    /// package larger than a non-zero budget is refused rather than evicting
    /// everything else for it.
    pub async fn mirror(&self, record: &ModRecord, budget: u64) -> Result<Mirrored, String> {
        if budget > 0 && record.size > budget {
            return Err(format!(
                "{}@{} is {} bytes, over the {budget}-byte mirror budget",
                record.id, record.version, record.size
            ));
        }
        if !self
            .store
            .has(Hash::from(record.root))
            .await
            .map_err(|error| format!("store: {error}"))?
        {
            self.download(record).await?;
        }
        let value = HashAndFormat {
            hash: Hash::from(record.root),
            format: BlobFormat::HashSeq,
        };
        let tag = self
            .store
            .tags()
            .temp_tag(value)
            .await
            .map_err(|error| format!("pin: {error}"))?;

        let (used, evicted) = {
            let mut mirror = self.mirror.lock().expect("mirror");
            // Replace an older pin for the same root rather than counting it twice.
            mirror.pins.remove(&record.root);
            mirror.pins.insert(
                record.root,
                MirrorPin {
                    tag,
                    id: record.id.clone(),
                    size: record.size,
                    at: Instant::now(),
                },
            );
            let mut evicted = Vec::new();
            if budget > 0 {
                loop {
                    let used: u64 = mirror.pins.values().map(|pin| pin.size).sum();
                    if used <= budget {
                        break;
                    }
                    let oldest = mirror
                        .pins
                        .iter()
                        .filter(|(root, _)| **root != record.root)
                        .min_by_key(|(_, pin)| pin.at)
                        .map(|(root, _)| *root);
                    let Some(oldest) = oldest else {
                        break;
                    };
                    if let Some(pin) = mirror.pins.remove(&oldest) {
                        evicted.push(oldest);
                        drop(pin.tag);
                    }
                }
            }
            let used = mirror.pins.values().map(|pin| pin.size).sum();
            (used, evicted)
        };

        self.serve(record.root);
        self.relay(record.clone()).await?;
        Ok(Mirrored {
            id: record.id.clone(),
            root: record.root,
            size: record.size,
            used,
            evicted,
        })
    }

    /// What this node is mirroring, in id order.
    pub fn mirrored(&self) -> Vec<(String, u64)> {
        let mirror = self.mirror.lock().expect("mirror");
        let mut out: Vec<(String, u64)> = mirror
            .pins
            .values()
            .map(|pin| (pin.id.clone(), pin.size))
            .collect();
        out.sort();
        out
    }

    /// Leave the topic and stop the catalogue's task. The node is not closed: the
    /// swarm subscribes on it too, and whoever bound it owns its lifetime. Best
    /// effort: a process that is already going away loses only the withdrawal.
    pub async fn shutdown(mut self) {
        let _ = self.commands.send(Command::Leave).await;
        while self.events.recv().await.is_some() {}
    }
}

/// A cloneable handle that only seeds the catalogue. It carries the node's
/// endpoint lookup and the task's command queue, not the store or the events.
#[derive(Clone)]
pub struct RegistryPeers {
    lookup: MemoryLookup,
    commands: mpsc::Sender<Command>,
    id: EndpointId,
}

impl RegistryPeers {
    /// Seed the catalogue with a peer ticket learned elsewhere. The ticket is an
    /// introduction; whether the peer is in the catalogue's topic is gossip's
    /// answer, not this function's.
    pub fn join(&self, ticket: &str) -> Result<(), String> {
        let addr = crate::swarm::parse_peer(ticket)?;
        if addr.id == self.id {
            return Ok(());
        }
        self.lookup.add_endpoint_info(addr.clone());
        let _ = self.commands.try_send(Command::Peers(vec![addr.id]));
        Ok(())
    }
}

/// What one mirror call did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Mirrored {
    pub id: String,
    pub root: [u8; 32],
    /// The package's size, as the record claimed it.
    pub size: u64,
    /// The total the mirror now holds.
    pub used: u64,
    /// Roots dropped to make room, oldest first.
    pub evicted: Vec<[u8; 32]>,
}

/// The mirror's bookkeeping. The tags are temporary, so what a mirror holds is
/// protected for the process's lifetime and collectable after it: a mirror that
/// is not running is not serving, and a restart re-fetches what it wants.
#[derive(Default)]
struct Mirror {
    pins: BTreeMap<[u8; 32], MirrorPin>,
}

struct MirrorPin {
    tag: TempTag,
    id: String,
    size: u64,
    at: Instant,
}

/// A fixed provider set for one download. Unlike `Shuffled`, the order is the
/// catalogue's: the author first, then whoever else restated a have.
#[derive(Debug, Clone)]
struct Providers(Vec<EndpointId>);

impl ContentDiscovery for Providers {
    fn find_providers(&self, _: HashAndFormat) -> n0_future::stream::Boxed<EndpointId> {
        n0_future::stream::iter(self.0.clone()).boxed()
    }
}

/// The catalogue: records by root, and the providers that restated each root.
#[derive(Default)]
struct Catalogue {
    records: HashMap<[u8; 32], (ModRecord, Instant)>,
    haves: HashMap<[u8; 32], HashMap<EndpointId, Instant>>,
}

impl Catalogue {
    fn insert(&mut self, record: ModRecord, now: Instant) -> bool {
        match self.records.get(&record.root) {
            Some((current, _)) if current == &record => {
                // Restatement: refresh the clock without an event.
                if let Some((_, seen)) = self.records.get_mut(&record.root) {
                    *seen = now;
                }
                false
            }
            _ => {
                self.records.insert(record.root, (record, now));
                while self.records.len() > MAX_REGISTRY_RECORDS
                    && let Some(oldest) = self
                        .records
                        .iter()
                        .min_by_key(|(_, (_, seen))| *seen)
                        .map(|(root, _)| *root)
                {
                    self.records.remove(&oldest);
                }
                true
            }
        }
    }

    fn have(&mut self, root: [u8; 32], provider: EndpointId, now: Instant) {
        // A have can arrive before its record, and a record can be withdrawn
        // while mirrors still hold the bytes. Keep the two independent, but bound
        // the roots -- a topic is public, and a liar can name many.
        if !self.haves.contains_key(&root)
            && self.haves.len() >= MAX_REGISTRY_RECORDS
            && let Some(oldest) = self
                .haves
                .iter()
                .min_by_key(|(_, providers)| providers.values().max().copied().unwrap_or(now))
                .map(|(root, _)| *root)
        {
            self.haves.remove(&oldest);
        }
        let providers = self.haves.entry(root).or_default();
        providers.insert(provider, now);
        while providers.len() > MAX_PROVIDERS
            && let Some(oldest) = providers
                .iter()
                .min_by_key(|(_, seen)| **seen)
                .map(|(id, _)| *id)
        {
            providers.remove(&oldest);
        }
    }

    /// A withdrawal is scoped to who sent it. The author may take the record
    /// down; a provider may stop listing itself and nothing else. A stranger's
    /// `Gone` is ignored, or anyone could empty every catalogue with one message.
    fn withdraw(&mut self, root: [u8; 32], sender: EndpointId) -> bool {
        let author = self
            .records
            .get(&root)
            .is_some_and(|(record, _)| record.author == *sender.as_bytes());
        let record_changed = if author {
            self.records.remove(&root).is_some()
        } else {
            false
        };
        if let Some(providers) = self.haves.get_mut(&root) {
            providers.remove(&sender);
            if providers.is_empty() {
                self.haves.remove(&root);
            }
        }
        record_changed
    }

    fn prune(&mut self, now: Instant, ttl: Duration) -> bool {
        let before = self.records.len();
        self.records
            .retain(|_, (_, seen)| now.duration_since(*seen) < ttl);
        self.haves.retain(|_, providers| {
            providers.retain(|_, seen| now.duration_since(*seen) < ttl);
            !providers.is_empty()
        });
        self.records.len() != before
    }

    fn list(&self) -> Vec<ModRecord> {
        let mut records: Vec<ModRecord> = self
            .records
            .values()
            .map(|(record, _)| record.clone())
            .collect();
        records.sort_by(|a, b| (&a.id, &a.version, a.root).cmp(&(&b.id, &b.version, b.root)));
        records
    }

    fn find(&self, reference: &ModRef) -> Option<ModRecord> {
        let mut matches: Vec<&ModRecord> = self
            .records
            .values()
            .map(|(record, _)| record)
            .filter(|record| {
                record.id == reference.id
                    && record.version == reference.version
                    && record.hash == reference.hash
            })
            .collect();
        // A record with a live provider is the one worth fetching; falling back
        // to a provider-less record still tells the player what exists.
        matches.sort_by_key(|record| (!self.haves.contains_key(&record.root), record.root));
        matches.first().map(|record| (*record).clone())
    }

    fn providers(&self, root: &[u8; 32]) -> Vec<EndpointId> {
        let mut ids: Vec<EndpointId> = self
            .haves
            .get(root)
            .map(|providers| providers.keys().copied().collect())
            .unwrap_or_default();
        ids.sort();
        if let Some((record, _)) = self.records.get(root)
            && let Ok(author) = EndpointId::from_bytes(&record.author)
            && let Some(index) = ids.iter().position(|id| *id == author)
        {
            let author = ids.remove(index);
            ids.insert(0, author);
        }
        ids.truncate(MAX_PROVIDERS);
        ids
    }
}

enum Command {
    Publish(ModRecord),
    Have(Vec<[u8; 32]>),
    Withdraw([u8; 32]),
    Peers(Vec<EndpointId>),
    Leave,
}

/// One message on the topic. The nonce is what lets a restatement be a new
/// message: gossip deduplicates by content hash, and identical bytes would be
/// dropped before they reached a neighbour.
#[derive(Debug, Serialize, Deserialize)]
enum Wire {
    Record { record: ModRecord, nonce: u64 },
    Have { have: ModHave, nonce: u64 },
    Gone { root: [u8; 32], nonce: u64 },
}

impl Wire {
    fn decode(bytes: &[u8]) -> Option<Wire> {
        if bytes.len() > MAX_REGISTRY_MESSAGE_BYTES {
            return None;
        }
        postcard::from_bytes(bytes).ok()
    }

    fn encode(&self) -> Option<Bytes> {
        postcard::to_allocvec(self).ok().map(Bytes::from)
    }
}

static NONCE: AtomicU64 = AtomicU64::new(0);

fn nonce() -> u64 {
    NONCE.fetch_add(1, Ordering::Relaxed)
}

/// The task's inputs, bundled so the signature stays readable (and clippy's
/// argument count stays honest).
struct Task {
    receiver: GossipReceiver,
    sender: GossipSender,
    commands: mpsc::Receiver<Command>,
    events: mpsc::Sender<RegistryEvent>,
    catalogue: Arc<Mutex<Catalogue>>,
    own_id: EndpointId,
    every: Duration,
    ttl: Duration,
}

async fn run(task: Task) {
    let Task {
        mut receiver,
        sender,
        mut commands,
        events,
        catalogue,
        own_id,
        every,
        ttl,
    } = task;
    let mut own: HashMap<[u8; 32], ModRecord> = HashMap::new();
    let mut haves: HashSet<[u8; 32]> = HashSet::new();
    let mut last: Option<Instant> = None;

    let tick_every = every.min(ttl / 3).max(Duration::from_millis(25));
    let mut ticker = tokio::time::interval(tick_every);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        tokio::select! {
            command = commands.recv() => match command {
                None => break,
                Some(Command::Publish(record)) => {
                    own.insert(record.root, record.clone());
                    haves.insert(record.root);
                    catalogue
                        .lock()
                        .expect("catalogue")
                        .have(record.root, own_id, Instant::now());
                    let _ = broadcast_record(&sender, &record).await;
                    let _ = broadcast_have(&sender, record.root).await;
                    last = Some(Instant::now());
                }
                Some(Command::Have(roots)) => {
                    for root in roots {
                        haves.insert(root);
                        catalogue
                            .lock()
                            .expect("catalogue")
                            .have(root, own_id, Instant::now());
                        let _ = broadcast_have(&sender, root).await;
                    }
                    last = Some(Instant::now());
                }
                Some(Command::Withdraw(root)) => {
                    own.remove(&root);
                    haves.remove(&root);
                    let _ = broadcast_gone(&sender, root).await;
                }
                Some(Command::Peers(peers)) => {
                    let _ = sender.join_peers(peers).await;
                }
                Some(Command::Leave) => break,
            },
            event = receiver.next() => match event {
                None => break,
                Some(Err(error)) => {
                    let _ = events
                        .try_send(RegistryEvent::Failed(error.to_string()));
                }
                Some(Ok(GossipEvent::Received(message))) => {
                    let Some(wire) = Wire::decode(&message.content) else {
                        continue;
                    };
                    let now = Instant::now();
                    match wire {
                        Wire::Record { record, .. } => {
                            let Some(record) = record.clean() else {
                                continue;
                            };
                            let changed = catalogue
                                .lock()
                                .expect("catalogue")
                                .insert(record, now);
                            if changed {
                                let list = catalogue.lock().expect("catalogue").list();
                                let _ = events.try_send(RegistryEvent::Records(list));
                            }
                        }
                        Wire::Have { have, .. } => {
                            let Some(have) = have.clean() else {
                                continue;
                            };
                            // The sender is the provider: a have relayed by a
                            // mirror would be a claim about somebody else.
                            catalogue
                                .lock()
                                .expect("catalogue")
                                .have(have.root, message.delivered_from, now);
                        }
                        Wire::Gone { root, .. } => {
                            let changed = catalogue
                                .lock()
                                .expect("catalogue")
                                .withdraw(root, message.delivered_from);
                            if changed {
                                let list = catalogue.lock().expect("catalogue").list();
                                let _ = events.try_send(RegistryEvent::Records(list));
                            }
                        }
                    }
                }
                Some(Ok(GossipEvent::NeighborUp(_))) => {
                    // A neighbour that just arrived missed every earlier
                    // restatement, and the timer may be most of a window away.
                    for record in own.values() {
                        let _ = broadcast_record(&sender, record).await;
                    }
                    for root in &haves {
                        let _ = broadcast_have(&sender, *root).await;
                    }
                    last = Some(Instant::now());
                }
                Some(Ok(GossipEvent::NeighborDown(_))) => {}
                Some(Ok(GossipEvent::Lagged)) => {}
            },
            _ = ticker.tick() => {
                let now = Instant::now();
                // Refresh this node's own haves before pruning, so serving a
                // package does not quietly lapse in the local catalogue between
                // restatements.
                let changed = {
                    let mut guard = catalogue.lock().expect("catalogue");
                    // A record this node owns is restated on this task's clock,
                    // not merely received; refresh it locally too, or sharing
                    // would expire in the sharer's own catalogue after one TTL.
                    for record in own.values() {
                        guard.insert(record.clone(), now);
                    }
                    for root in &haves {
                        guard.have(*root, own_id, now);
                    }
                    guard.prune(now, ttl)
                };
                if changed {
                    let list = catalogue.lock().expect("catalogue").list();
                    let _ = events.try_send(RegistryEvent::Records(list));
                }
                if last.is_none_or(|when| now.duration_since(when) >= every) {
                    for record in own.values() {
                        let _ = broadcast_record(&sender, record).await;
                    }
                    for root in &haves {
                        let _ = broadcast_have(&sender, *root).await;
                    }
                    last = Some(now);
                }
            }
        }
    }

    // Leaving is not silent: a node that closes the window takes its records
    // with it rather than waiting out the TTL. The node itself stays open -- the
    // swarm is a second subscription on it.
    for root in own.keys() {
        let _ = broadcast_gone(&sender, *root).await;
    }
}

async fn broadcast_record(sender: &GossipSender, record: &ModRecord) -> Option<()> {
    let wire = Wire::Record {
        record: record.clone(),
        nonce: nonce(),
    };
    sender.broadcast(wire.encode()?).await.ok()
}

async fn broadcast_have(sender: &GossipSender, root: [u8; 32]) -> Option<()> {
    let wire = Wire::Have {
        have: ModHave { root },
        nonce: nonce(),
    };
    sender.broadcast(wire.encode()?).await.ok()
}

async fn broadcast_gone(sender: &GossipSender, root: [u8; 32]) -> Option<()> {
    let wire = Wire::Gone {
        root,
        nonce: nonce(),
    };
    sender.broadcast(wire.encode()?).await.ok()
}

/// Import a tree as a collection: one blob per file, named by its
/// manifest-relative path, and a root naming all of them. The returned tags
/// keep every blob alive until the caller drops them.
async fn import_tree(store: &Store, dir: &Path) -> Result<(Hash, u64, Vec<TempTag>), String> {
    if !dir.join("mod.json").is_file() {
        return Err(format!("{}: no mod.json at the root", dir.display()));
    }
    let files = walk(dir)?;
    if files.is_empty() {
        return Err(format!("{}: no files to share", dir.display()));
    }
    let mut collection = Collection::default();
    let mut tags = Vec::new();
    let mut size = 0u64;
    for (relative, path) in files {
        let length = std::fs::metadata(&path)
            .map_err(|error| format!("{}: {error}", path.display()))?
            .len();
        size = size.saturating_add(length);
        if size > MAX_PACKAGE_BYTES {
            return Err(format!(
                "{}: the tree is over the {MAX_PACKAGE_BYTES}-byte package limit",
                dir.display()
            ));
        }
        let bytes = std::fs::read(&path).map_err(|error| format!("{}: {error}", path.display()))?;
        let tag = store
            .add_bytes(Bytes::from(bytes))
            .temp_tag()
            .await
            .map_err(|error| format!("{}: {error}", path.display()))?;
        collection.push(relative, tag.hash());
        tags.push(tag);
    }
    let root = collection
        .store(store)
        .await
        .map_err(|error| format!("collection: {error}"))?;
    let hash = root.hash();
    tags.push(root);
    Ok((hash, size, tags))
}

/// Every regular file below `dir`, as `(manifest-relative name with '/', path)`,
/// sorted. Symlinks are refused: the package is bytes, and a link's target is
/// not part of it.
fn walk(dir: &Path) -> Result<Vec<(String, PathBuf)>, String> {
    fn visit(dir: &Path, relative: &str, out: &mut Vec<(String, PathBuf)>) -> Result<(), String> {
        let mut entries: Vec<std::fs::DirEntry> = std::fs::read_dir(dir)
            .map_err(|error| format!("{}: {error}", dir.display()))?
            .collect::<Result<_, _>>()
            .map_err(|error| format!("{}: {error}", dir.display()))?;
        entries.sort_by_key(|entry| entry.file_name());
        for entry in entries {
            let name = entry.file_name();
            let name = name
                .to_str()
                .ok_or_else(|| format!("{}: {name:?} is not UTF-8", dir.display()))?;
            let child = match relative.is_empty() {
                true => name.to_string(),
                false => format!("{relative}/{name}"),
            };
            let kind = entry
                .file_type()
                .map_err(|error| format!("{}: {error}", entry.path().display()))?;
            if kind.is_symlink() {
                return Err(format!(
                    "{}: symlinks are not part of a package",
                    entry.path().display()
                ));
            }
            if kind.is_dir() {
                visit(&entry.path(), &child, out)?;
            } else if kind.is_file() {
                out.push((child, entry.path()));
            } else {
                return Err(format!(
                    "{}: not a regular file or directory",
                    entry.path().display()
                ));
            }
        }
        Ok(())
    }

    let mut files = Vec::new();
    visit(dir, "", &mut files)?;
    files.sort_by(|a, b| a.0.cmp(&b.0));
    Ok(files)
}

/// Write a collection's children under `dest`, refusing any name that could
/// escape it. The names are verified by the root hash but chosen by the author,
/// so they get the same treatment as a mod's own relative paths.
async fn export_collection(store: &Store, root: Hash, dest: &Path) -> Result<(), String> {
    let collection = Collection::load(root, store)
        .await
        .map_err(|error| format!("collection {:?}: {error}", root.to_hex()))?;
    std::fs::create_dir_all(dest).map_err(|error| format!("{}: {error}", dest.display()))?;

    let mut seen = HashSet::new();
    for (name, hash) in collection.iter() {
        let relative = safe_relative(name)?;
        if !seen.insert(relative.clone()) {
            return Err(format!("'{name}': the collection names it twice"));
        }
        let target = dest.join(&relative);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("{}: {error}", parent.display()))?;
        }
        store
            .export(*hash, &target)
            .await
            .map_err(|error| format!("{}: {error}", target.display()))?;
    }
    Ok(())
}

/// A collection name reduced to a relative path, or refused. Only normal
/// components are allowed, and a backslash is not a separator here: the
/// collection format uses `/`, so a name containing `\` is either an accident or
/// an attempt to mean something different on Windows.
fn safe_relative(name: &str) -> Result<PathBuf, String> {
    if name.is_empty() || name.chars().any(char::is_control) {
        return Err(format!("{name:?} is not a usable file name"));
    }
    if name.contains('\\') {
        return Err(format!("'{name}' contains a backslash"));
    }
    if name
        .split('/')
        .any(|part| part.is_empty() || part == "." || part == "..")
    {
        return Err(format!("'{name}' is not a plain relative path"));
    }
    let path = Path::new(name);
    if path.is_absolute() {
        return Err(format!("'{name}' is absolute"));
    }
    let mut out = PathBuf::new();
    for component in path.components() {
        match component {
            Component::Normal(part) => out.push(part),
            _ => return Err(format!("'{name}' is not a relative file name")),
        }
    }
    if out.as_os_str().is_empty() {
        return Err(format!("'{name}' is not a file name"));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::swarm::{Swarm, SwarmConfig};
    use iroh_tickets::Ticket;
    use iroh_tickets::endpoint::EndpointTicket;
    use std::sync::atomic::{AtomicU32, Ordering};
    use tokio::time::timeout;

    static COUNTER: AtomicU32 = AtomicU32::new(0);

    fn workspace(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "goats-registry-{}-{}-{name}",
            std::process::id(),
            COUNTER.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn config(name: &str) -> RegistryConfig {
        RegistryConfig {
            topic: TopicId::from_bytes([11u8; 32]),
            peers: Vec::new(),
            secret: None,
            reach: Reach::Direct,
            store: workspace(name).join("store"),
            every: Duration::from_millis(50),
            ttl: Duration::from_millis(2000),
        }
    }

    fn write_mod(dir: &Path) {
        write_mod_id(dir, "com.example.tree");
    }

    fn write_mod_id(dir: &Path, id: &str) {
        std::fs::create_dir_all(dir.join("assets")).unwrap();
        std::fs::write(
            dir.join("mod.json"),
            format!(
                r#"{{ "id": "{id}", "name": "Tree", "version": "1",
                    "api": 1, "side": "world", "entry": "mod.js" }}"#
            ),
        )
        .unwrap();
        std::fs::write(dir.join("mod.js"), format!("// {id}\n")).unwrap();
        std::fs::write(dir.join("assets/tree.bin"), b"bytes").unwrap();
    }

    fn record() -> ModRecord {
        ModRecord {
            id: "com.example.tree".to_string(),
            version: "1".to_string(),
            api: 1,
            side: proto::ModSide::World,
            hash: 0xabc,
            root: [0u8; 32],
            size: 0,
            author: [0u8; 32],
        }
    }

    fn seed(registry: &Registry) -> EndpointAddr {
        EndpointTicket::decode_string(registry.ticket())
            .expect("a ticket")
            .endpoint_addr()
            .clone()
    }

    async fn records(
        registry: &mut Registry,
        wanted: impl Fn(&[ModRecord]) -> bool,
    ) -> Vec<ModRecord> {
        loop {
            match timeout(Duration::from_secs(20), registry.next_event())
                .await
                .expect("no registry event in time")
                .expect("the registry ended")
            {
                RegistryEvent::Records(list) if wanted(&list) => return list,
                _ => {}
            }
        }
    }

    #[test]
    fn the_default_topic_is_a_stable_hash() {
        assert_eq!(
            RegistryConfig::default_topic().to_string(),
            DEFAULT_TOPIC,
            "the default is part of the wire contract"
        );
    }

    #[test]
    fn a_collection_name_cannot_escape_its_destination() {
        assert_eq!(
            safe_relative("assets/tree.bin").unwrap(),
            PathBuf::from("assets/tree.bin")
        );
        for bad in ["", "../escape", "/absolute", "a\\b", "a//b", "."] {
            assert!(safe_relative(bad).is_err(), "accepted {bad:?}");
        }
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn two_registries_exchange_a_record_and_its_bytes() {
        let host = Registry::start(config("host"))
            .await
            .expect("host registry");
        let mut watcher = Registry::start(RegistryConfig {
            peers: vec![seed(&host)],
            ..config("watcher")
        })
        .await
        .expect("watcher registry");

        let source = workspace("source");
        write_mod(&source);
        let shared = host
            .share(record(), &source)
            .await
            .expect("shared the tree");
        assert_ne!(shared.root, [0u8; 32]);
        assert_eq!(shared.author, *host.id().as_bytes());

        let listed = records(&mut watcher, |list| !list.is_empty()).await;
        assert_eq!(listed, vec![shared.clone()]);
        // A record and its have are separate messages; gossip may deliver them
        // in either order, and the provide set is what a fetch actually uses.
        for _ in 0..200 {
            if !watcher.providers(&shared.root).is_empty() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        assert_eq!(watcher.providers(&shared.root), vec![host.id()]);
        assert_eq!(
            watcher.find(&shared.reference()).map(|record| record.root),
            Some(shared.root)
        );

        let fetched = workspace("fetched").join("tree");
        watcher
            .fetch(&shared, &fetched)
            .await
            .expect("fetched the collection");
        assert_eq!(
            std::fs::read(fetched.join("assets/tree.bin")).unwrap(),
            b"bytes"
        );
        assert_eq!(
            std::fs::read_to_string(fetched.join("mod.js")).unwrap(),
            "// com.example.tree\n"
        );
        let tag = watcher.pin(shared.root).await.expect("pinned");
        watcher.unpin(&tag).await.expect("unpinned");

        watcher.shutdown().await;
        host.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_withdrawn_record_leaves_the_catalogue() {
        let host = Registry::start(config("gone-host"))
            .await
            .expect("host registry");
        let mut watcher = Registry::start(RegistryConfig {
            peers: vec![seed(&host)],
            ..config("gone-watcher")
        })
        .await
        .expect("watcher registry");

        let source = workspace("gone-source");
        write_mod(&source);
        let shared = host.share(record(), &source).await.expect("shared");
        records(&mut watcher, |list| !list.is_empty()).await;

        host.withdraw(shared.root);
        let listed = records(&mut watcher, |list| list.is_empty()).await;
        assert!(listed.is_empty());
        assert!(watcher.providers(&shared.root).is_empty());

        watcher.shutdown().await;
        host.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn an_unrestated_record_expires_but_is_not_fetched_into_a_new_catalogue() {
        let host = Registry::start(RegistryConfig {
            every: Duration::from_secs(3600),
            ..config("ttl-host")
        })
        .await
        .expect("host registry");
        let mut watcher = Registry::start(RegistryConfig {
            peers: vec![seed(&host)],
            every: Duration::from_secs(3600),
            ttl: Duration::from_millis(150),
            ..config("ttl-watcher")
        })
        .await
        .expect("watcher registry");

        let source = workspace("ttl-source");
        write_mod(&source);
        host.share(record(), &source).await.expect("shared");
        records(&mut watcher, |list| !list.is_empty()).await;
        let listed = records(&mut watcher, |list| list.is_empty()).await;
        assert!(listed.is_empty());

        watcher.shutdown().await;
        host.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_sharer_keeps_its_own_record_past_the_ttl() {
        let host = Registry::start(RegistryConfig {
            every: Duration::from_secs(3600),
            ttl: Duration::from_millis(150),
            ..config("own-ttl")
        })
        .await
        .expect("host registry");

        let source = workspace("own-ttl-source");
        write_mod(&source);
        let shared = host.share(record(), &source).await.expect("shared");
        tokio::time::sleep(Duration::from_millis(400)).await;

        // The timer is the only thing keeping this alive: `every` is an hour
        // away, so the local refresh is what has to hold.
        assert_eq!(host.records(), vec![shared.clone()]);
        assert_eq!(host.providers(&shared.root), vec![host.id()]);
        host.shutdown().await;
    }

    #[tokio::test(flavor = "multi_thread")]
    async fn a_mirror_evicts_the_oldest_pin_to_stay_within_budget() {
        let registry = Registry::start(config("mirror-budget"))
            .await
            .expect("registry");
        let a = workspace("mirror-a");
        write_mod_id(&a, "com.example.a");
        let b = workspace("mirror-b");
        write_mod_id(&b, "com.example.b");
        let mut first = record();
        first.id = "com.example.a".to_string();
        let mut second = record();
        second.id = "com.example.b".to_string();
        let first = registry.share(first, &a).await.expect("shared a");
        let second = registry.share(second, &b).await.expect("shared b");

        // Room for one of the two, so pinning the second evicts the first.
        let budget = first.size.max(second.size);
        assert!(registry.mirror(&first, budget).await.is_ok());
        let mirrored = registry.mirror(&second, budget).await.expect("mirrored b");
        assert_eq!(mirrored.evicted, vec![first.root]);
        assert_eq!(mirrored.used, second.size);
        assert_eq!(registry.mirrored(), vec![(second.id.clone(), second.size)]);

        // A package that cannot fit at all is refused rather than emptying the
        // mirror for it.
        assert!(registry.mirror(&first, first.size - 1).await.is_err());

        registry.shutdown().await;
    }

    /// One node serves both: the swarm is a subscription and the catalogue is a
    /// second one, so the ticket a portal hands out introduces the catalogue too
    /// and no second socket exists to seed.
    #[tokio::test(flavor = "multi_thread")]
    async fn a_swarm_and_a_registry_share_one_ticket() {
        let node = Node::bind(NodeConfig {
            secret: None,
            reach: Reach::Direct,
            blobs: Some(workspace("shared-node").join("store")),
            session: false,
        })
        .await
        .expect("node");
        let swarm = Swarm::join_on(
            node.clone(),
            SwarmConfig {
                peers: Vec::new(),
                lan: false,
                ..SwarmConfig::new(TopicId::from_bytes([12u8; 32]))
            },
        )
        .await
        .expect("swarm");
        let registry = Registry::start_on(node.clone(), config("shared-registry"))
            .await
            .expect("registry");

        assert_eq!(swarm.id(), registry.id());
        assert_eq!(swarm.ticket(), registry.ticket());
        assert_eq!(registry.id(), node.id());

        registry.shutdown().await;
        node.shutdown().await;
    }

    #[test]
    fn a_catalogue_keeps_both_packages_when_an_id_is_squatted() {
        let mut catalogue = Catalogue::default();
        let now = Instant::now();
        let mut first = record();
        first.root = [1u8; 32];
        first.author = [2u8; 32];
        let mut second = record();
        second.root = [3u8; 32];
        second.author = [4u8; 32];
        assert!(catalogue.insert(first.clone(), now));
        assert!(catalogue.insert(second.clone(), now));
        assert_eq!(catalogue.list().len(), 2);
        // The reference is the same, so `find` still answers -- it just cannot
        // choose between them on identity alone.
        assert!(catalogue.find(&first.reference()).is_some());
    }

    #[test]
    fn only_the_author_can_withdraw_a_record() {
        let mut catalogue = Catalogue::default();
        let now = Instant::now();
        let mut record = record();
        record.root = [1u8; 32];
        let author = SecretKey::from_bytes(&[2u8; 32]).public();
        let stranger = SecretKey::from_bytes(&[3u8; 32]).public();
        record.author = *author.as_bytes();
        catalogue.insert(record.clone(), now);
        catalogue.have(record.root, author, now);
        catalogue.have(record.root, stranger, now);

        // A stranger can stop advertising itself, but not the record.
        assert!(!catalogue.withdraw(record.root, stranger));
        assert_eq!(catalogue.list(), vec![record.clone()]);
        assert_eq!(catalogue.providers(&record.root), vec![author]);

        assert!(catalogue.withdraw(record.root, author));
        assert!(catalogue.list().is_empty());
        assert!(catalogue.providers(&record.root).is_empty());
    }
}
