# Finding a host: the swarm

A session is addressed by its ticket, and a ticket comes from its host. Pasting
one works, but it means somebody has to hand it around. The swarm closes that gap
without a server in the middle: peers join an [iroh-gossip][gossip] **topic**, and
every host restates one small advert on it. Everyone else keeps the adverts they
hear and forgets one that stops being restated. The scene receives that list and
turns each host into a ring standing in the meadow; walking into a ring joins it.

Nothing about the session changes. The advert names the session's own endpoint,
and a player joins it exactly as if the ticket had been pasted. The swarm never
sees a goat, a datagram or a mod; it is a noticeboard.

[gossip]: https://docs.iroh.computer/connecting/gossip

## From the console

```
swarm join                       join the default topic, listening only
swarm join --topic <64 hex>      join another topic
swarm join --peer <id|ticket>    seed the first connection
swarm leave                      leave the topic
swarm                            show the topic, neighbours and host count
```

`swarm join` replaces the current swarm if one is already joined. `$GOATS_SWARM_PEERS`
(comma-separated ids or tickets) is the standing form of `--peer`, and
`$GOATS_SWARM_KEY` (64 hex characters) gives this node a stable swarm identity. Both
clients speak this vocabulary: the reference through `net.js`, the port through
`main.gd`'s `cmd_swarm_*` behind the same `NetBridge`.

The client **joins at startup** now: the default topic is a zero-config default,
and `GOATS_SWARM=0` opts out for a run (as does `swarm leave`). A config file and
a settings screen are the natural home for persisting a choice later.

### Zero-config on a local network

No ticket and no command: every participant also announces itself on a UDP
multicast group (`239.255.42.99:42378`, TTL 1, so it never leaves the link). The
beacon carries the topic and the sender's endpoint ticket; a listener checks the
topic, puts the ticket in its address lookup, and asks gossip to dial it. Two
copies of the game on one machine, or two machines on one LAN, therefore find
each other by themselves -- launch both, `host` on one, and the ring appears on
the other within a couple of seconds.

The message is only an introduction: the endpoint id in the ticket is what
gossip authenticates, and `GOATS_SWARM_LAN=0` turns the beacon off for a machine
or a build where multicast is unwanted.

### Finding a host across the internet

Gossip still needs an introduction beyond the link. Either side can be the seed,
because its swarm ticket carries its addresses:

```
# Option A -- goatsd is the seed (it joins the default topic by itself)
goatsd                         # prints: goatsd: swarm ticket endpoint...
# in each client:
swarm join --peer <that ticket>

# Option B -- one client seeds the other
# client A:
swarm
# "ticket": "endpoint..."   (the swarm status now carries it)
# client B:
swarm join --peer <A's ticket>

# either way, then:
swarm                          # "peers": 1 or more once the mesh forms
host                           # on one client
```

The other client should then see a ring in the meadow, and `swarm` reports
`hosts: 1`. `$GOATS_SWARM_PEERS` is the same seed list for a build or a launcher
script, so a paired test does not have to retype it. A future default seed (a
`goatsd` on a fixed, persistent `--swarm-key`) is what makes this zero-config on
the internet too.

### What the scene gets

A `discovered` event carries the current list -- ticket, name, player count and
wire version -- whenever it changes, and the scene replaces its old list with it.
The `swarm` event carries the joined topic, this node's swarm id and ticket, and
the neighbour count; `swarm_peers` updates the last of those.

Each `discovered` entry becomes a portal ring in both clients: a place derived from
the ticket (so every player computes the same spot, with FNV-1a written out in both
rather than relying on either language's `hash`), labelled with the host's name and
player count, and joined by walking into it. Rings are drawn only while this client
is offline -- a session refuses a second join -- and a failed join waits for the goat
to step out and back in rather than retrying every frame. A *client* in a session gets
an amber "Exit session" ring ten metres from spawn instead: walking into it leaves, so
a padlock-free session always has a local way out. The reference client draws both
through its scene's own `rl`; the Godot port has `godot/src/portals.gd`, wired to the
same `NetBridge` the console's `swarm` verb reaches.

## `goatsd`

`goatsd` joins the default swarm unless told not to. It is the natural seed for a
WAN: it prints the three things a client needs for the session, and the registry
ticket when the catalogue is on.

```
$ goatsd --swarm-key <64 hex> --registry-key <64 hex> --share-mods
...
goatsd: swarm topic 32b19c7a81bb09d6147d1a2511bbd3668b0c81a68abb7cfbe2f65d97dd195a9e
goatsd: swarm seed id 8f3c...   (64 hex characters)
goatsd: swarm ticket endpoint...
goatsd: registry topic 93a3969b8c2b4e679f4cfdd4704d58f8ccc4413cc6ee25d3bac16796647f783f
goatsd: registry ticket endpoint...
```

Flags:

| flag | meaning |
| --- | --- |
| `--nojoin` | do not join a swarm; the session is still reachable by ticket |
| `--topicid ID` | the topic to join (default: the game's own) |
| `--peer ID\|TICKET` | a node already in the topic to seed from; repeatable |
| `--swarm-key HEX` | a persistent endpoint secret, so the seed keeps its id across restarts |
| `--no-registry` | do not start the mod registry |
| `--registry-store DIR` | where the registry's blob store lives |
| `--registry-key HEX` | a persistent registry identity, so clients can keep pointing at it |
| `--registry-topic ID` | the catalogue to join (default: the game's own) |
| `--registry-peer ID\|TICKET` | a registry node to seed from; repeatable |
| `--share-mods` | announce this server's mods on the registry |

`--swarm-key` (or `$GOATS_SWARM_KEY`) matters for a seed: clients dial it by id,
and a random key would make that id change every restart. `--registry-key`
(`$GOATS_REGISTRY_KEY`) is the same argument for the catalogue, which has its own
endpoint for now. A client in the same swarm learns the registry ticket from the
swarm itself; `$GOATS_REGISTRY_PEERS` is what seeds one with no swarm to hear.

## The first peer

Gossip needs an introduction. A topic with nobody in it cannot be found, and
`iroh-gossip` takes a list of peers that are already in the topic. This is the
one piece of the design that is not self-organising, and it is deliberate: a
topic is not a directory, and there is no global "who is on topic X" lookup.

So a cold client needs at least one seed:

- an **endpoint ticket**, which carries addresses and needs no lookup, or
- an **endpoint id**, which the n0 preset resolves through DNS.

The default topic is a stable hash, `SHA-256("goats/swarm/v1")`, so builds agree
on it without sharing anything first -- but a default topic is not a default
*peer*. Operators running a seed set `GOATS_SWARM_PEERS` (or pass `--peer`) to it,
and the config file the UI will read is where that belongs next.

## Security and limits

- **A topic is public.** Anyone who knows its 32-byte id can subscribe and read
  every advert. That is the price of having no server; the advert carries only a
  session ticket, a display name, a player count and the wire version.
- **Adverts are unsigned claims.** A liar can list a ticket that is not theirs,
  exactly as anyone can paste a ticket into a console. The ticket is the identity
  that matters: joining it proves the rest.
- **Bounded lists.** A receiver keeps at most 256 hosts, drops a ticket with a
  control character or an absurd length, cuts a name to 64 characters, and
  forgets an advert 90 seconds after its last restatement. A host restates every
  30 seconds, so two missed windows remove it.
- **Nothing persists.** Restarting a node forgets the list; hosts publish again
  on the next advertise window.

## The tests

- `crates/session/src/swarm.rs`: two local swarms exchange an advert, a refresh
  replaces it, withdrawal removes it, expiry removes it, leaving takes it down,
  and the parser/cleaner handle hostile input.
- `crates/goats/src/net.rs`: a hosting bridge and a joining bridge meet through a
  real gossip topic; the player receives the host's session, and leaving the
  swarm empties the list.
- `crates/harness/tests/swarm.rs`: `swarm join`/`swarm leave` queue the right
  intents, the joined and peer events update the view, and a `discovered` list is
  replaced rather than merged (a host that left does not linger).

## A mod registry

The same topic can carry more than adverts. A package advert -- mod id, version,
content hash, and where to fetch it -- is a few dozen bytes, and a mod that is
already part of a session's world set has to be fetchable by anyone joining. That
is the next use for this wire: a peer-to-peer index of what is available, on top
of the swarm that already knows who is around.

### Borrow the half of BitTorrent that is missing

The resemblance to a torrent is real: a mod is a blob named by its hash, peers
announce which blobs they hold, and anyone holding one can serve it. Three pieces
are worth taking.

- **Content-addressed chunks.** A range of bytes is verified against the hash
  that names it while it arrives, not after. A peer that sends garbage is caught
  at the first bad chunk, and a transfer that stops halfway can resume against a
  different peer.
- **A manifest, and a set of peers holding it.** The manifest turns one hash into
  a mod; the peer set makes that hash fetchable.
- **A store that can serve what it has.** A peer that completed a download is a
  source, whether or not it wrote the mod.

Three pieces are already in the stack and should not be rebuilt.

- **No tracker.** The gossip topic is the tracker. A record is the announce, a
  restatement is the keep-alive, and a peer that stops restating drops out
  exactly as a host does now.
- **No DHT.** iroh's address lookup already turns an endpoint id into addresses
  across networks. A separate DHT keyed by content hash would exist only to
  answer "which endpoint has this hash" -- and that is the record. What the
  registry adds is the mapping, not another routing table.
- **No chunker.** [`iroh-blobs`][blobs] moves blobs, and trees of blobs, as
  BLAKE3 verified streams over the same QUIC endpoint. It has range requests, so
  a provider serves the ranges it holds and an interrupted fetch resumes; its
  protocol is one more ALPN beside the session and fetch ALPNs, not a new
  transport.

So the split is: **gossip carries the index, blobs carries the bytes**. The one
thing neither has is "who holds this hash", which is what the registry is.

[blobs]: https://docs.rs/iroh-blobs

### The package is a tree, not a zip

A mod already has two shapes: a directory with `mod.json` at its root, or a zip
with that tree inside. The registry needs exactly one, because two zips of the
same files are different bytes once a timestamp or an entry order differs. So the
named unit is the **tree**: `mod.json` at the root, files at their
manifest-relative names, and one BLAKE3 **collection hash** over names and
contents. `session::registry` builds that from a directory -- one blob per file,
then a collection root over their hashes -- and exports it back to one, so
directories are supported by construction rather than by a second format.

A zip remains an interchange format -- the loader reads it and a player can still
drop one in -- but it is not what the registry names. Hashing the archive would
make a mod's identity depend on who zipped it.

There are now two hashes, and they are not the same thing.
`mods::Manifest::hash` is an eight-byte FNV-1a over the logical projection (id,
version, entry, tuning, assets) and is what a join compares. The collection hash
is 32 bytes of BLAKE3 over the bytes and is an *address*. The record carries both
until the handshake does; the FNV one can go when `ModRef` is replaced, and that
is a `PROTOCOL_VERSION` change, not a registry one.

### One record, plus haves

A **record** is the torrent: it names one package and nothing else.

```text
ModRecord {
    id, version, api, side,   // what a manifest already declares
    hash: u64,                // the join's FNV digest, so a client can tell
                              // whether this is the copy a session accepts
    root: [u8; 32],           // the collection hash: the address
    size: u64,                // bytes when complete, for a budget
    author: EndpointId,       // who first announced it; a hint, not a proof
}
```

There is deliberately **no file list**. In a torrent that list is in the
`.torrent` file; here the collection's index is itself a blob, so it arrives
with the download and is verified by `root` as it does. A 10,000-file mod
therefore does not grow the gossip message, and the record stays under a
kilobyte.

A **have** is the peer half: `Have { root }`, restated by anyone who can serve
that root and pinned in their store so garbage collection does not delete it.
Records answer "what is this mod"; haves answer "who can give me these bytes". A
record's author is expected to restate a have; a mirror restates the record too,
which is why `author` is attribution rather than authentication.

### A second topic

The registry is `SHA-256("goats/mods/v1")`, not the host topic. The two lists have
different natural caps -- 256 hosts, a catalogue is larger -- a record flood must
not evict portals, and joining a swarm to find a game has not thereby agreed to
carry a mod catalogue. The mechanism is the one already built: postcard
`Wire::{Record, Have, Gone}` with the same nonce, restated every `RECORD_EVERY`
and forgotten after `RECORD_TTL` without a restatement.

The registry has its own endpoint, so its introduction is a ticket rather than
an endpoint id. The swarm carries it: a node that runs a catalogue restates its
registry ticket beside its advert, and a peer that hears one hands it to the
catalogue's peer set. `$GOATS_REGISTRY_PEERS` is the standing form for a node
with no swarm at all (a test, or `--nojoin`), and `$GOATS_REGISTRY_KEY` gives the
catalogue a stable identity.
A client starts one at startup when it has a mods directory and prints its
ticket, and `GOATS_MODS_REGISTRY=0` turns it off for a run, like `swarm leave`.

### Fetching is a hook, not a protocol

`iroh-blobs`' downloader already takes a set of providers per request. What it
wants from the application is one method:

```rust
fn find_providers(&self, hash: HashAndFormat) -> Boxed<EndpointId>
```

That is the registry. The catalogue maps `root -> endpoint ids that restated a
have`, the downloader tries the author first and then the rest, and every chunk
is verified as it lands. A join that needs a world mod therefore has two sources
and one policy: the host's fetch ALPN while the host is there, the swarm when it
is not. `pull`'s verify-then-install rule does not move -- an exported collection
is re-read by the loader and must match the record's id, version and FNV digest
before it is renamed into `mods/`.

### Opting in

Three separate switches, because they are three different promises.

- **share** (default off): announce records for the mods this client loads and
  serve their blobs. It is public and persistent in a way `host` is not: a
  record on the topic says this node has this mod to everyone on it, not just to
  someone who was handed a ticket.
- **mirror** (default off): keep serving a root you did not author. A mirror
  restates the have for what it holds and pins it against GC; the byte budget and
  eviction are the caller's policy, because only it knows how much disk it is
  offering -- unbounded mirroring is a disk commitment.
- **fetch** (only when the player asked, or `--pull` is standing consent): install
  a mod the registry names. Never implied by joining the topic, and never applied
  to a `side: "client"` mod, which is the player's own choice.

### Security and limits

- **Records and haves are unsigned claims.** A liar can name a root that is not
  the mod, or list a have for bytes they cannot serve. The hash is the authority:
  a download that does not verify installs nothing, and a have that cannot serve
  fails like any unreachable peer. `author` is a hint.
- **Id squatting is not solvable here.** Two packages can claim one id at one
  version with different roots, and the registry shows both. What resolves it is
  still the session: a joiner fetches the `(id, version, hash)` its host's world
  set names, and a record that does not match is not a candidate. "Id X is this
  endpoint's" is a naming authority, which is a server, which this deliberately
  is not.
- **Bounded.** At most 1024 records, each at most 512 bytes; ids and versions
  are cut like host names and a root is exactly 32 bytes. Records are keyed by
  root, so a restatement refreshes rather than duplicates, and two roots may
  claim one id. A record expires 90 seconds after its last restatement.
- **No execution from the network.** A fetched package goes through the loader
  and the same identity check `pull` does today, lands as
  `mods/pulled-<id>/`, and is enabled by no automatic path. World mods are
  enabled by the join's set; client mods are the player's.
- **Budgets.** A download refuses a `size` above the package cap before it
  starts, a mirror keeps its own byte budget, and the downloader's own limits
  bound concurrency.

### What changes

- `mods`: `ModSource::materialize` writes a source (directory, zip or memory)
  as the canonical tree, and `mods::load_dir` reads one back. The collection
  root is not computed here -- it belongs to the store, not the loader.
- `proto`: `ModRecord`, `ModHave` and `ModSide`, postcard on a gossip topic
  rather than session messages, so no wire-version bump. `ModRecord::clean`
  holds every bound.
- `session::registry`, beside `swarm`: the second topic, the catalogue, the
  `ContentDiscovery` implementation and `share`/`serve`/`relay`/`fetch`/`pin`.
  `iroh-blobs` is a dependency of `session`, which is already the only crate that
  owns an endpoint.
- `pull`: `pull_registry` fetches a record's collection, verifies it with the
  loader and installs it as `pulled-<id>/`; `recover_with` keeps the host first
  and uses the registry only for what the host could not serve. The host fetch
  ALPN stays for `Catalogue` and `Wanted`.

### What remains

The client now starts a registry at startup (unless `GOATS_MODS_REGISTRY=0`),
announces its world mods when `GOATS_MODS_SHARE` is on, learns peers' registry
tickets from the swarm, and hands the handle to `recover_with`, so a refused join
falls back to the catalogue for what the host could not serve. What is left: the
console verbs (`mods share`, `mods mirror <root>`, `mods fetch <id>`) and a
mirror's byte budget and eviction, which is the caller's policy. The endpoint is
the registry's own; sharing the swarm's would remove a second socket and make a
portal's ticket the only one a client needs.

### The tests

- two local registries exchange a record and a have; a withdrawal removes, expiry
  removes, only the author may withdraw a record, and a hostile record is refused
  by `ModRecord::clean`;
- a package built from a directory, a wrapped zip or an in-memory source
  materialises to the same tree and the same loader digest;
- a real download crosses `iroh-blobs` from one local registry to another, and
  the exported tree reloads with the identity the record named;
- `pull_registry` installs a world mod from a registry, refuses what the player
  already has, and reports a record it cannot find; and a fetched root can be
  pinned and unpinned.
