//! `goatsd`: a standalone headless host for a goat session.
//!
//! It runs the same scene the client does (`crates/goats/src/game/`) against a
//! null `rl` (see `src/headless.rs`), so it owns the world the clients mirror:
//! the bots are simulated here and broadcast on the session's datagram channel,
//! and a client joining a `goatsd` session never runs the bot AI at all.
//!
//! The ticket is the whole interface: the host prints it, and a player pastes it
//! into the client's console with `connect <ticket> <name>`.

mod headless;

use std::io::Write;
use std::time::Duration;

use session::{Event, Host, WorldState};

/// The world snapshot cadence, in sim frames (the sim runs at a fixed 60 Hz).
const WORLD_EVERY: u64 = 6;

#[tokio::main]
async fn main() {
    let name = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "server".to_string());
    let mut host = match Host::start(&name).await {
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
                Some(event) => report(event),
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

/// One line per event, so a session's comings and goings read as a log.
fn report(event: Event) {
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
        // and a bite is handled by the sim above.
        Event::Peer { .. } | Event::World { .. } | Event::Consume { .. } => return,
        Event::Disconnected => "disconnected".to_string(),
    };
    println!("{line}");
    let _ = std::io::stdout().flush();
}
