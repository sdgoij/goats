//! `goatsd`: a standalone headless host for a goat session.
//!
//! It runs the same scene the client does (`crates/goats/src/game/`) against a
//! null `rl` (see `src/headless.rs`), so it owns the world the clients mirror:
//! the bots are simulated here and broadcast on the session's datagram channel,
//! and a client joining a `goatsd` session never runs the bot AI at all.
//!
//! The ticket is the whole interface: the host prints it, and a player pastes it
//! into the client's console with `connect <ticket> <name>`. `--listen` also
//! serves that ticket, the connected-client count and a client download link as
//! a small status page (`src/web.rs`); without `--listen` no HTTP server runs.
//!
//! The herd is this end's to size: `--herd N` is written into the scene's own
//! `TUNING.herd.count` before the world builds its goats, so the snapshot every
//! joiner mirrors is `N` goats rather than the default seven. The ceiling is
//! `proto::MAX_HERD` -- a hundred, the same number each client names -- and a herd that
//! large travels as several part-datagrams rather than one (`proto::split_world`), so the
//! `--herd` ceiling is what the *parts* are sized for rather than the datagram budget.

mod headless;
mod web;

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use session::swarm::{Advert, SwarmCommands, SwarmConfig, SwarmEvent};
use session::{Event, Host, ModsOutcome, WorldOutcome, WorldState, describe_mods};

/// The world snapshot cadence, in sim frames (the sim runs at a fixed 60 Hz).
const WORLD_EVERY: u64 = 6;

/// Where the status page points a visitor for the client, unless `--download`
/// says otherwise.
const DEFAULT_DOWNLOAD: &str = "https://github.com/sdgoij/goats/releases";

/// The herd `--herd` asks for when the flag says nothing: the scene's own default
/// (`TUNING.herd.count` in `core.js`, `Bots.COUNT` in the port), which a session-less
/// scene boots at. The ceiling a count is validated against is `proto::MAX_HERD`.
const DEFAULT_HERD: usize = 7;

const USAGE: &str = "\
goatsd [name] [--listen address:port] [--download URL] [--mods DIRECTORY] [--no-mods] [--herd N]
        [--nojoin] [--topicid ID] [--peer ID|TICKET]... [--swarm-key HEX]

  name                the name to host under (default: server)
  -l, --listen ADDR   serve a status page on ADDR; a bare port means 0.0.0.0:port.
                      Without it, no HTTP server is started.
      --download URL  client download link shown on the page
                      (default: the GitHub releases page)
      --mods DIR      require this server's world mods; joiner must match
                      (default search: $GOATS_MODS, then mods/ next to the binary,
                      then mods/ in the current directory)
      --no-mods       require no mods
      --herd N        bots in the world's herd, 0..100 (default: 7). The herd is
                      simulated here and broadcast, so this is what every joiner
                      mirrors; a hundred is a real per-frame cost at both ends.
      --nojoin        do not join the discovery swarm; the session is still
                      reachable by its ticket
      --topicid ID    the swarm topic to join, 64 hex characters (default: the
                      game's own topic)
      --peer ID|TICKET
                      a node already in the swarm to seed from; repeatable, and
                      also read from $GOATS_SWARM_PEERS (comma-separated)
      --swarm-key HEX a persistent swarm endpoint secret, so this host keeps its
                      id across restarts (also $GOATS_SWARM_KEY)
  -h, --help          this text";

/// What the command line asked for.
struct Options {
    name: String,
    listen: Option<String>,
    download: String,
    mods_dir: Option<PathBuf>,
    no_mods: bool,
    herd: usize,
    nojoin: bool,
    topic_id: Option<String>,
    peers: Vec<String>,
    swarm_key: Option<String>,
}

/// Asking for help is not an error, but it ends the process the same way.
enum Parsed {
    Run(Options),
    Help,
}

fn parse_args(args: impl Iterator<Item = String>) -> Result<Parsed, String> {
    let mut options = Options {
        name: "server".to_string(),
        listen: None,
        download: DEFAULT_DOWNLOAD.to_string(),
        mods_dir: None,
        no_mods: false,
        herd: DEFAULT_HERD,
        nojoin: false,
        topic_id: None,
        peers: Vec::new(),
        swarm_key: None,
    };
    let mut named = false;
    let mut args = args;
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(Parsed::Help),
            "-l" | "--listen" => {
                options.listen = Some(args.next().ok_or("--listen needs address:port")?);
            }
            "--download" => {
                options.download = args.next().ok_or("--download needs a URL")?;
            }
            "--mods" => {
                options.mods_dir = Some(PathBuf::from(
                    args.next().ok_or("--mods needs a directory")?,
                ));
            }
            "--no-mods" => options.no_mods = true,
            "--nojoin" => options.nojoin = true,
            "--topicid" => {
                options.topic_id = Some(args.next().ok_or("--topicid needs an id")?);
            }
            "--peer" => {
                options
                    .peers
                    .push(args.next().ok_or("--peer needs an id or a ticket")?);
            }
            "--swarm-key" => {
                options.swarm_key = Some(args.next().ok_or("--swarm-key needs 64 hex characters")?);
            }
            "--herd" => {
                let value = args.next().ok_or("--herd needs a count")?;
                let count: usize = value
                    .parse()
                    .map_err(|_| format!("--herd expects a number, got {value}"))?;
                if count > proto::MAX_HERD {
                    return Err(format!(
                        "--herd {count} is over the {}-goat ceiling",
                        proto::MAX_HERD
                    ));
                }
                options.herd = count;
            }
            other if other.starts_with('-') => return Err(format!("unknown option {other}")),
            other => {
                if named {
                    return Err(format!("unexpected argument {other}"));
                }
                options.name = other.to_string();
                named = true;
            }
        }
    }
    Ok(Parsed::Run(options))
}

/// The mods directory, the same search the client uses: an explicit flag, else
/// `$GOATS_MODS`, else `mods/` next to the executable, else `mods/` in the
/// working directory.
fn resolve_mods_dir(options: &Options) -> Option<PathBuf> {
    if options.no_mods {
        return None;
    }
    if let Some(dir) = &options.mods_dir {
        return Some(dir.clone());
    }
    if let Some(dir) = std::env::var_os("GOATS_MODS")
        && !dir.is_empty()
    {
        return Some(PathBuf::from(dir));
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(parent) = exe.parent()
    {
        let candidate = parent.join("mods");
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    let candidate = PathBuf::from("mods");
    if candidate.is_dir() {
        return Some(candidate);
    }
    None
}

/// The world-mod set this server requires every joiner to present, in id order.
/// The server does not simulate the mods yet (that is M14d2), but requiring the
/// set now means a client with different world mods is refused rather than
/// silently diverging.
fn world_mod_refs(loader: &mods::Loader) -> Vec<session::ModRef> {
    let mut refs: Vec<session::ModRef> = loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .map(|manifest| session::ModRef {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            hash: manifest.hash,
        })
        .collect();
    refs.sort_by(|a, b| a.id.cmp(&b.id));
    refs
}

/// The status page's mod facts: the mods this host loaded, and the directory they
/// came from packaged as a `.zip` so a visitor can obtain exactly the set in use.
/// The archive is `None` when there are no mods, or when the directory cannot be
/// read (a page without a download link is better than no page at all).
fn status_page_mods(
    loader: &mods::Loader,
    dir: Option<&std::path::Path>,
) -> (Vec<web::Mod>, Option<Vec<u8>>) {
    let listed: Vec<web::Mod> = loader
        .mods()
        .iter()
        .map(|manifest| web::Mod {
            id: manifest.id.clone(),
            version: manifest.version.clone(),
            side: manifest.side.as_str(),
        })
        .collect();
    let zip = match dir {
        Some(dir) if !listed.is_empty() => match mods::archive_dir(dir) {
            Ok(bytes) => Some(bytes),
            Err(error) => {
                eprintln!("goatsd: could not package the mods for download: {error}");
                None
            }
        },
        _ => None,
    };
    (listed, zip)
}

/// The archives a joiner missing a world mod can fetch (M18): every world mod in
/// its distributable form, so a fetch hands over exactly the mod the digest was
/// taken over. Only world mods -- a client mod is local and never travels.
fn mod_archives(loader: &mods::Loader) -> Vec<(session::ModRef, Vec<u8>)> {
    loader
        .mods()
        .iter()
        .filter(|manifest| manifest.side == mods::Side::World)
        .filter_map(|manifest| {
            let reference = session::ModRef {
                id: manifest.id.clone(),
                version: manifest.version.clone(),
                hash: manifest.hash,
            };
            match mods::archive_source(&manifest.source) {
                Ok(bytes) => Some((reference, bytes)),
                Err(error) => {
                    eprintln!(
                        "goatsd: could not package {} for fetch: {error}",
                        manifest.id
                    );
                    None
                }
            }
        })
        .collect()
}

#[tokio::main]
async fn main() {
    let options = match parse_args(std::env::args().skip(1)) {
        Ok(Parsed::Run(options)) => options,
        Ok(Parsed::Help) => {
            println!("{USAGE}");
            return;
        }
        Err(message) => {
            eprintln!("goatsd: {message}");
            eprintln!("{USAGE}");
            std::process::exit(1);
        }
    };

    let mods_dir = resolve_mods_dir(&options);
    let loader = match &mods_dir {
        Some(dir) => {
            eprintln!("goatsd: scanning {}", dir.display());
            // Hash the assets for the digest but do not keep them (a server has
            // no engine to register them with), while keeping a mod's wasm
            // module: that is code the headless world runs, not data to register.
            mods::Loader::discover_with(dir, mods::AssetMode::KeepWasm)
        }
        None => mods::Loader::empty(),
    };
    for error in loader.errors() {
        eprintln!("goatsd: {error}");
    }
    let world_mods = world_mod_refs(&loader);
    if !world_mods.is_empty() {
        eprintln!(
            "goatsd: {} world mods required of every joiner",
            world_mods.len()
        );
    }
    // The hashes, not just the count: a refused joiner is told what this end
    // had, and this is the line to read that against.
    eprintln!("goatsd: world set: {}", describe_mods(&world_mods));

    // The archives a joiner missing a world mod can fetch (M18): each world mod
    // in its distributable form, packaged once at boot from the same loader the
    // digest came from. A mod the loader could not read is skipped rather than
    // fatal -- the session still runs; only that fetch is refused.
    let archives = mod_archives(&loader);
    if !archives.is_empty() {
        eprintln!(
            "goatsd: {} world mods ready to serve on fetch",
            archives.len()
        );
    }

    // The status page's mod facts: every mod this host loaded, and the directory
    // they came from packaged as a `.zip`, so a visitor can obtain exactly the
    // set in use rather than assembling it by hand. Built once at boot.
    let (listed_mods, mods_zip) = status_page_mods(&loader, mods_dir.as_deref());

    let mut host =
        match Host::start_with_mods_and_archives(&options.name, world_mods, archives).await {
            Ok(host) => host,
            Err(error) => {
                eprintln!("goatsd: could not host: {error}");
                std::process::exit(1);
            }
        };
    let mut sim = match headless::Sim::start(host.seed(), &loader, options.herd) {
        Ok(sim) => sim,
        Err(error) => {
            eprintln!("goatsd: could not start the world: {error}");
            std::process::exit(1);
        }
    };

    println!("goatsd: hosting as {}", host.name());
    println!("ticket {}", host.ticket());
    println!("goatsd: world seed {}", host.seed());
    println!("goatsd: paste that into a client's console with `connect <ticket> <name>`");
    println!("goatsd: internet reach (n0 relays + DNS discovery); Ctrl-C to stop");
    let _ = std::io::stdout().flush();

    // The discovery swarm. `goatsd` is the natural seed for a WAN: it joins by
    // default and prints the id and ticket a client needs to seed from it. A
    // gossip topic with nobody in it cannot be found by anybody, so a deployment
    // that turns this off (`--nojoin`) is reachable by ticket only.
    let mut swarm: Option<SwarmCommands> = None;
    if options.nojoin {
        println!("goatsd: discovery off (--nojoin); reachable by ticket only");
    } else {
        match start_swarm(&options).await {
            Ok((commands, joined)) => {
                println!("goatsd: swarm topic {}", joined.topic());
                println!("goatsd: swarm seed id {}", joined.id());
                println!("goatsd: swarm ticket {}", joined.ticket());
                let _ = std::io::stdout().flush();
                swarm = Some(commands);
                // The task owns the endpoint, so it has to outlive this scope.
                // Its events are drained (a full channel would stall the gossip
                // task); the only one worth a line is the neighbour count.
                tokio::spawn(async move {
                    let mut joined = joined;
                    while let Some(event) = joined.next_event().await {
                        if let SwarmEvent::Peers(count) = event {
                            println!("goatsd: swarm has {count} peer(s)");
                            let _ = std::io::stdout().flush();
                        }
                    }
                });
            }
            Err(error) => {
                eprintln!("goatsd: could not join the swarm: {error}; reachable by ticket only")
            }
        }
    }

    // The status page, only when asked for. It reports the ticket, the client
    // count and where to get the client; the count is kept up to date from the
    // session's roster events below. The listener is bound here, before the loop
    // starts, so a busy port is an error now rather than a surprise later.
    let info = Arc::new(web::Info::new(
        host.ticket().to_string(),
        options.download.clone(),
        proto::PROTOCOL_VERSION,
        listed_mods,
        mods_zip,
    ));
    if let Some(address) = &options.listen {
        let address = if let Ok(port) = address.parse::<u16>() {
            format!("0.0.0.0:{port}")
        } else {
            address.clone()
        };
        match std::net::TcpListener::bind(&address) {
            Ok(listener) => {
                let shown = listener
                    .local_addr()
                    .map_or_else(|_| address.clone(), |bound| bound.to_string());
                println!("goatsd: status page on http://{shown}/");
                let _ = std::io::stdout().flush();
                let info = info.clone();
                if let Err(error) = std::thread::Builder::new()
                    .name("http".to_string())
                    .spawn(move || web::serve(listener, info))
                {
                    eprintln!("goatsd: could not start the status page: {error}");
                }
            }
            Err(error) => {
                eprintln!("goatsd: could not listen on {address}: {error}");
                std::process::exit(1);
            }
        }
    }

    let mut tick = tokio::time::interval(Duration::from_millis(16));
    // A step does not have to be exactly 16 ms; catch up once and carry on
    // rather than firing a burst of steps after a stall.
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    // The swarm advert's clock. The first tick is immediate, so the session is
    // published as soon as it exists.
    let mut swarm_tick = tokio::time::interval(session::swarm::ADVERT_EVERY);
    swarm_tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut frames: u64 = 0;
    // The last thing said about each high-rate datagram, so a shed is reported
    // when it happens and when it stops happening, not on every tick.
    let mut last_world = WorldOutcome::Whole;
    let mut last_mods = ModsOutcome::Sent;

    // Built once and pinned, not re-created each iteration: a signal can land
    // while no handler future is registered, and this loop turns over every
    // 16 ms, so re-creating it is a race that drops Ctrl-C. On Unix, SIGTERM
    // counts too, so `kill` and a service manager stop the server as well.
    let interrupt = async {
        #[cfg(unix)]
        {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
                Ok(mut terminate) => {
                    tokio::select! {
                        _ = tokio::signal::ctrl_c() => {}
                        _ = terminate.recv() => {}
                    }
                }
                Err(_) => {
                    let _ = tokio::signal::ctrl_c().await;
                }
            }
        }
        #[cfg(not(unix))]
        {
            let _ = tokio::signal::ctrl_c().await;
        }
    };
    tokio::pin!(interrupt);

    loop {
        tokio::select! {
            _ = tick.tick() => {
                if let Err(error) = sim.step() {
                    eprintln!("goatsd: world step failed: {error}");
                    break;
                }
                frames += 1;
                if frames.is_multiple_of(WORLD_EVERY) {
                    match sim.world_json() {
                        Ok(json) => publish_world(&host, &json, &mut last_world).await,
                        Err(error) => eprintln!("goatsd: could not read the world: {error}"),
                    }
                    // The mods ride beside it, on a datagram of their own, and only
                    // while a world mod is loaded.
                    match sim.mods_json() {
                        Ok(Some(json)) => publish_mods(&host, &json, &mut last_mods).await,
                        Ok(None) => {}
                        Err(error) => eprintln!("goatsd: could not read the mods: {error}"),
                    }
                }
            }
            event = host.next_event() => match event {
                // A bite a client reported: the scene records it, and the next
                // world snapshot carries the eaten cell back to everyone.
                Some(Event::Consume { key }) => {
                    if let Err(error) = sim.consume(key) {
                        eprintln!("goatsd: could not record a bite: {error}");
                    }
                }
                // A device a client's goat set off (M19e). The client has already fired
                // it, so this is a report: the scene spends the device and applies the
                // bang here -- the ground everyone adopts is this one -- and answers with
                // where the device was, which is what the relay puts on the wire. The
                // reporter is left out of it, because they have already felt it.
                Some(Event::BlastReport { kind, key, by }) => {
                    relay_blast(&host, &mut sim, kind, key, &by).await;
                }
                Some(event) => {
                    // The player count is part of the advert; a roster change is
                    // the moment to restate it rather than wait for the window.
                    if matches!(&event, Event::Roster { .. }) {
                        advertise(&host, swarm.as_ref()).await;
                    }
                    report(event, &info);
                }
                None => {
                    println!("goatsd: session finished");
                    break;
                }
            },
            _ = swarm_tick.tick() => {
                advertise(&host, swarm.as_ref()).await;
            },
            _ = &mut interrupt => {
                println!();
                println!("goatsd: shutting down");
                break;
            }
        }
    }

    // Close the session, but never let a peer that has gone quiet hold the
    // process open; the endpoint is going away either way. The swarm is told
    // first, so a portal goes down now rather than after the TTL.
    if let Some(commands) = &swarm {
        commands.leave();
    }
    if tokio::time::timeout(Duration::from_secs(2), host.close())
        .await
        .is_err()
    {
        eprintln!("goatsd: close timed out; exiting anyway");
    }
}

/// Joins the discovery swarm from the command line: the topic, the seed peers,
/// and the identity (a persistent one matters for a seed, whose id is what
/// clients are pointed at).
async fn start_swarm(options: &Options) -> Result<(SwarmCommands, session::swarm::Swarm), String> {
    let topic = match &options.topic_id {
        Some(text) => session::swarm::parse_topic(text)?,
        None => SwarmConfig::default_topic(),
    };
    let mut peers = session::swarm::peers_from_env()?;
    for peer in &options.peers {
        peers.push(session::swarm::parse_peer(peer)?);
    }
    let secret = match &options.swarm_key {
        Some(text) => Some(session::swarm::parse_secret(text)?),
        None => session::swarm::secret_from_env()?,
    };
    let config = SwarmConfig {
        secret,
        peers,
        lan: std::env::var("GOATS_SWARM_LAN")
            .map(|value| value != "0")
            .unwrap_or(true),
        ..SwarmConfig::new(topic)
    };
    let swarm = session::swarm::Swarm::join(config)
        .await
        .map_err(|error| error.to_string())?;
    let commands = swarm.commands();
    Ok((commands, swarm))
}

/// Restates this host's advert: its session ticket, name and player count.
async fn advertise(host: &Host, swarm: Option<&SwarmCommands>) {
    let Some(swarm) = swarm else {
        return;
    };
    swarm.advertise(Advert {
        ticket: host.ticket().to_string(),
        name: host.name().to_string(),
        clients: host.clients().await,
        protocol: proto::PROTOCOL_VERSION,
    });
}

/// One answer from the scene to a blast report (M19e): where the device it names
/// actually is, in the host's own layout.
#[derive(serde::Deserialize)]
struct BlastAt {
    x: f32,
    z: f32,
}

/// Relays a client's bang (M19e). Everything here is deliberately the host's: the scene
/// spends the device and digs the ground because this is the world everyone mirrors, and
/// the coordinates come from that same scene rather than from the reporter -- who is left
/// out of the relay, having already felt the bang.
async fn relay_blast(
    host: &Host,
    sim: &mut headless::Sim,
    kind: session::BlastKind,
    key: i64,
    by: &str,
) {
    let json = match sim.blast_report(blast_kind_name(kind), key) {
        Ok(json) => json,
        Err(error) => {
            eprintln!("goatsd: could not record a blast: {error}");
            return;
        }
    };
    // Empty means the scene has no device at that key: a client saying something the
    // host cannot check out, and nothing worth relaying to everyone else.
    if json.is_empty() {
        return;
    }
    match serde_json::from_str::<BlastAt>(&json) {
        Ok(at) => host.blast(kind, key, at.x, at.z, by, Some(by)).await,
        Err(error) => eprintln!("goatsd: bad blast report: {error}"),
    }
}

/// The scene spells a device's kind the way `BlastKind` serialises it.
fn blast_kind_name(kind: session::BlastKind) -> &'static str {
    match kind {
        session::BlastKind::Mine => "mine",
        session::BlastKind::Trap => "trap",
    }
}

/// Hands one world snapshot to the session, which broadcasts it to the clients
/// and sheds the parts that do not fit a datagram. A malformed read is logged
/// rather than fatal: the next one is 100 ms away. The last thing said about the
/// snapshot is what `last` carries, so a report lands on the change rather than
/// ten times a second.
async fn publish_world(host: &Host, json: &str, last: &mut WorldOutcome) {
    match serde_json::from_str::<WorldState>(json) {
        Ok(world) => {
            let outcome = host.publish_world(&world).await;
            if outcome != *last {
                if let Some(text) = outcome.describe() {
                    eprintln!("goatsd: {text}");
                }
                *last = outcome;
            }
        }
        Err(error) => eprintln!("goatsd: bad world snapshot: {error}"),
    }
}

/// Hands the world mods' state to the session, on a datagram of its own. Same
/// rules as the world: a malformed read is logged, and a report lands on the
/// change.
async fn publish_mods(host: &Host, json: &str, last: &mut ModsOutcome) {
    match serde_json::from_str::<serde_json::Value>(json) {
        Ok(state) => {
            let outcome = host.publish_mods(&session::ModsState(state)).await;
            if outcome != *last {
                if let Some(text) = outcome.describe() {
                    eprintln!("goatsd: {text}");
                }
                *last = outcome;
            }
        }
        Err(error) => eprintln!("goatsd: bad world-mod state: {error}"),
    }
}

/// One line per event, so a session's comings and goings read as a log. The
/// roster is also what keeps the status page's client count current.
fn report(event: Event, info: &web::Info) {
    if let Event::Roster { names } = &event {
        // The roster carries the host first, so the clients are the rest.
        info.set_clients(names.len().saturating_sub(1));
    }
    let line = match event {
        Event::Session { seed } => format!("session seed {seed}"),
        Event::Joined { name } => format!("{name} joined"),
        Event::Left { name } => format!("{name} left"),
        Event::Roster { names } => format!("roster {}", names.join(", ")),
        Event::Chat { from, text, direct } => {
            if direct {
                format!("dm {from} -> {text}")
            } else {
                format!("{from}: {text}")
            }
        }
        Event::Notice(text) => format!("notice {text}"),
        // Positions arrive many times a second; logging each would bury the
        // session log, so they are not reported. The world and the mods are the
        // server's own, a bite and a blast are handled by the sim above, and a
        // headless host has no audio, so a voice packet is relayed and forgotten.
        // `Blast` is the *relayed* bang, which a host never receives: it is what the
        // clients get, and this server is the one that sends it.
        Event::Peer { .. }
        | Event::World { .. }
        | Event::Mods { .. }
        | Event::Consume { .. }
        | Event::Voice { .. }
        | Event::Blast { .. }
        | Event::BlastReport { .. } => {
            return;
        }
        Event::Disconnected => "disconnected".to_string(),
    };
    println!("{line}");
    let _ = std::io::stdout().flush();
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Parsed, String> {
        parse_args(args.iter().map(|arg| arg.to_string()))
    }

    fn options(args: &[&str]) -> Options {
        match parse(args) {
            Ok(Parsed::Run(options)) => options,
            Ok(Parsed::Help) => panic!("unexpected help"),
            Err(message) => panic!("unexpected error: {message}"),
        }
    }

    #[test]
    fn the_defaults_are_server_with_no_status_page() {
        let options = options(&[]);
        assert_eq!(options.name, "server");
        assert!(options.listen.is_none(), "no page unless asked for");
        assert_eq!(options.download, DEFAULT_DOWNLOAD);
        assert_eq!(options.herd, DEFAULT_HERD, "the scene's own default herd");
    }

    #[test]
    fn the_herd_flag_sets_the_count() {
        assert_eq!(
            options(&["--herd", "42"]).herd,
            42,
            "the flag drives the herd"
        );
        assert_eq!(
            options(&["--herd", "0"]).herd,
            0,
            "an empty herd is allowed"
        );
        let ceiling = proto::MAX_HERD.to_string();
        assert_eq!(
            options(&["--herd", &ceiling]).herd,
            proto::MAX_HERD,
            "the ceiling itself is allowed"
        );
    }

    #[test]
    fn a_herd_over_the_ceiling_is_refused() {
        let over = (proto::MAX_HERD + 1).to_string();
        let refusals: [(&[&str], &str); 4] = [
            (&["--herd", over.as_str()], "over the ceiling"),
            (&["--herd"], "a missing count"),
            (&["--herd", "many"], "a non-number"),
            (&["--herd", "-1"], "a negative count"),
        ];
        for (args, why) in refusals {
            match parse(args) {
                Err(message) => assert!(!message.is_empty(), "{why}: an empty message"),
                Ok(_) => panic!("{why} should be refused"),
            }
        }
    }

    #[test]
    fn a_name_and_the_long_flags_are_read() {
        let options = options(&[
            "ubergoat",
            "--listen",
            "0.0.0.0:8080",
            "--download",
            "https://example.test/dl",
        ]);
        assert_eq!(options.name, "ubergoat");
        assert_eq!(options.listen.as_deref(), Some("0.0.0.0:8080"));
        assert_eq!(options.download, "https://example.test/dl");
    }

    #[test]
    fn the_short_listen_flag_works() {
        let options = options(&["-l", "127.0.0.1:9000"]);
        assert_eq!(options.listen.as_deref(), Some("127.0.0.1:9000"));
    }

    #[test]
    fn help_is_asked_for_not_failed_on() {
        assert!(matches!(parse(&["--help"]), Ok(Parsed::Help)));
        assert!(matches!(parse(&["-h"]), Ok(Parsed::Help)));
    }

    #[test]
    fn bad_arguments_are_refused() {
        assert!(parse(&["--listen"]).is_err(), "a missing value");
        assert!(parse(&["--download"]).is_err(), "a missing value");
        assert!(parse(&["--nope"]).is_err(), "an unknown option");
        assert!(parse(&["one", "two"]).is_err(), "two names");
    }

    #[test]
    fn goatsd_joins_a_swarm_by_default() {
        let defaults = options(&[]);
        assert!(!defaults.nojoin, "the swarm is on unless it is turned off");
        assert!(
            defaults.topic_id.is_none(),
            "the game's own topic is the default"
        );
        assert!(defaults.peers.is_empty());
        assert!(defaults.swarm_key.is_none());
    }

    #[test]
    fn the_swarm_flags_are_read() {
        let topic = "a".repeat(64);
        let key = "b".repeat(64);
        let parsed = options(&[
            "--nojoin",
            "--topicid",
            &topic,
            "--peer",
            "seed-one",
            "--peer",
            "seed-two",
            "--swarm-key",
            &key,
        ]);
        assert!(parsed.nojoin);
        assert_eq!(parsed.topic_id.as_deref(), Some(topic.as_str()));
        assert_eq!(parsed.peers, vec!["seed-one", "seed-two"]);
        assert_eq!(parsed.swarm_key.as_deref(), Some(key.as_str()));
    }

    /// The status page, wired from the real fixture mods the way `main` does it:
    /// the mods are listed with their versions and the directory is packaged for
    /// download, so a visitor can obtain exactly the set the session requires.
    #[test]
    fn the_status_page_lists_and_packages_the_fixture_mods() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let loader = mods::Loader::discover_with(&dir, mods::AssetMode::KeepWasm);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());

        let (listed, zip) = status_page_mods(&loader, Some(&dir));
        assert!(
            listed
                .iter()
                .any(|module| module.id == "com.github.sdgoij.goats.birds"),
            "the birds fixture must be listed"
        );
        let zip = zip.expect("the mods directory packaged");
        assert_eq!(&zip[..2], b"PK", "a zip archive");

        let info = web::Info::new(
            "ticket".to_string(),
            "https://example.test".to_string(),
            proto::PROTOCOL_VERSION,
            listed,
            Some(zip),
        );
        let page = info.page();
        assert!(page.contains("com.github.sdgoij.goats.birds@"), "{page}");
        assert!(
            page.contains(&format!(
                "Protocol version: <strong>{}</strong>",
                proto::PROTOCOL_VERSION
            )),
            "{page}"
        );
        assert!(page.contains("href=\"/mods.zip\""), "{page}");
    }

    /// The fetch archives (M18), wired from the real fixture mods the way `main`
    /// does it: one per world mod, in its distributable form, keyed by the very
    /// digest the handshake compares. A client mod is local and never served.
    #[test]
    fn the_fetch_archives_hold_the_world_mods_as_zips() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
            .join("mods");
        let loader = mods::Loader::discover_with(&dir, mods::AssetMode::KeepWasm);
        assert!(loader.errors().is_empty(), "{:?}", loader.errors());

        let archives = mod_archives(&loader);
        let expected: Vec<&str> = loader
            .mods()
            .iter()
            .filter(|manifest| manifest.side == mods::Side::World)
            .map(|manifest| manifest.id.as_str())
            .collect();
        assert!(
            expected.contains(&"com.github.sdgoij.goats.birds"),
            "{expected:?}"
        );
        assert_eq!(
            archives
                .iter()
                .map(|(reference, _)| reference.id.as_str())
                .collect::<Vec<&str>>(),
            expected,
            "one archive per world mod, and nothing else"
        );

        for (reference, bytes) in &archives {
            assert_eq!(&bytes[..2], b"PK", "{} is not an archive", reference.id);
            let manifest = loader
                .mods()
                .iter()
                .find(|manifest| manifest.id == reference.id)
                .expect("the mod it was built from");
            assert_eq!(
                reference.hash, manifest.hash,
                "keyed by the loader's digest"
            );
            assert_eq!(reference.version, manifest.version);
        }
    }
}
