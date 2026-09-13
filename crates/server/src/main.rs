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

mod headless;
mod web;

use std::io::Write;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use session::{Event, Host, WorldState};

/// The world snapshot cadence, in sim frames (the sim runs at a fixed 60 Hz).
const WORLD_EVERY: u64 = 6;

/// Where the status page points a visitor for the client, unless `--download`
/// says otherwise.
const DEFAULT_DOWNLOAD: &str = "https://github.com/sdgoij/goats/releases";

const USAGE: &str = "\
goatsd [name] [--listen address:port] [--download URL] [--mods DIRECTORY] [--no-mods]

  name                the name to host under (default: server)
  -l, --listen ADDR   serve a status page on ADDR; a bare port means 0.0.0.0:port.
                      Without it, no HTTP server is started.
      --download URL  client download link shown on the page
                      (default: the GitHub releases page)
      --mods DIR      require this server's world mods; joiner must match
                      (default search: $GOATS_MODS, then mods/ next to the binary,
                      then mods/ in the current directory)
      --no-mods       require no mods
  -h, --help          this text";

/// What the command line asked for.
struct Options {
    name: String,
    listen: Option<String>,
    download: String,
    mods_dir: Option<PathBuf>,
    no_mods: bool,
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
    if let Some(dir) = std::env::var_os("GOATS_MODS") {
        if !dir.is_empty() {
            return Some(PathBuf::from(dir));
        }
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            let candidate = parent.join("mods");
            if candidate.is_dir() {
                return Some(candidate);
            }
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

    let loader = match resolve_mods_dir(&options) {
        Some(dir) => {
            eprintln!("goatsd: scanning {}", dir.display());
            mods::Loader::discover(&dir)
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

    let mut host = match Host::start_with_mods(&options.name, world_mods).await {
        Ok(host) => host,
        Err(error) => {
            eprintln!("goatsd: could not host: {error}");
            std::process::exit(1);
        }
    };
    let mut sim = match headless::Sim::start(host.seed()) {
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
    println!(
        "goatsd: {}; Ctrl-C to stop",
        if session::internet_enabled() {
            "internet mode (n0 relays + DNS discovery)"
        } else {
            "LAN only (set GOATS_INTERNET=1 for n0 relays + DNS discovery)"
        }
    );
    let _ = std::io::stdout().flush();

    // The status page, only when asked for. It reports the ticket, the client
    // count and where to get the client; the count is kept up to date from the
    // session's roster events below. The listener is bound here, before the loop
    // starts, so a busy port is an error now rather than a surprise later.
    let info = Arc::new(web::Info::new(
        host.ticket().to_string(),
        options.download.clone(),
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
    let mut frames: u64 = 0;

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
                        Ok(json) => publish_world(&host, &json).await,
                        Err(error) => eprintln!("goatsd: could not read the world: {error}"),
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
                Some(event) => report(event, &info),
                None => {
                    println!("goatsd: session finished");
                    break;
                }
            },
            _ = &mut interrupt => {
                println!();
                println!("goatsd: shutting down");
                break;
            }
        }
    }

    // Close the session, but never let a peer that has gone quiet hold the
    // process open; the endpoint is going away either way.
    if tokio::time::timeout(Duration::from_secs(2), host.close())
        .await
        .is_err()
    {
        eprintln!("goatsd: close timed out; exiting anyway");
    }
}

/// Hands one world snapshot to the session, which broadcasts it to the clients.
/// A malformed read is logged rather than fatal: the next one is 100 ms away.
async fn publish_world(host: &Host, json: &str) {
    match serde_json::from_str::<WorldState>(json) {
        Ok(world) => host.publish_world(&world).await,
        Err(error) => eprintln!("goatsd: bad world snapshot: {error}"),
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
        // session log, so they are not reported. The world is the server's own,
        // a bite is handled by the sim above, and a headless host has no audio,
        // so a voice packet is relayed and forgotten.
        Event::Peer { .. } | Event::World { .. } | Event::Consume { .. } | Event::Voice { .. } => {
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
}
