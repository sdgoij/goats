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
WAN: it prints the three things a client needs.

```
$ goatsd --swarm-key <64 hex>
...
goatsd: swarm topic 32b19c7a81bb09d6147d1a2511bbd3668b0c81a68abb7cfbe2f65d97dd195a9e
goatsd: swarm seed id 8f3c...   (64 hex characters)
goatsd: swarm ticket endpoint...
```

Flags:

| flag | meaning |
| --- | --- |
| `--nojoin` | do not join a swarm; the session is still reachable by ticket |
| `--topicid ID` | the topic to join (default: the game's own) |
| `--peer ID\|TICKET` | a node already in the topic to seed from; repeatable |
| `--swarm-key HEX` | a persistent endpoint secret, so the seed keeps its id across restarts |

`--swarm-key` (or `$GOATS_SWARM_KEY`) matters for a seed: clients dial it by id,
and a random key would make that id change every restart.

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

## Later: a mod registry

The same topic can carry more than adverts. A package advert -- mod id, version,
content hash, and where to fetch it -- is a few dozen bytes, and a mod that is
already part of a session's world set has to be fetchable by anyone joining. That
is the next use for this wire: a peer-to-peer index of what is available, on top
of the swarm that already knows who is around.
