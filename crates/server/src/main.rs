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
    println!("goatsd: LAN only for now (no relay); Ctrl-C to stop");
    let _ = std::io::stdout().flush();

    let mut tick = tokio::time::interval(Duration::from_millis(16));
    // A step does not have to be exactly 16 ms; catch up once and carry on
    // rather than firing a burst of steps after a stall.
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    let mut frames: u64 = 0;

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
                Some(event) => report(event),
                None => {
                    println!("goatsd: session finished");
                    break;
                }
            },
            _ = tokio::signal::ctrl_c() => {
                println!();
                println!("goatsd: shutting down");
                break;
            }
        }
    }

    host.close().await;
}

/// Hands one world snapshot to the session, which broadcasts it to the clients.
/// A malformed read is logged rather than fatal: the next one is 100 ms away.
async fn publish_world(host: &Host, json: &str) {
    match serde_json::from_str::<Vec<session::BotState>>(json) {
        Ok(bots) => host.publish_world(&WorldState { bots }).await,
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
        // session log, so they are not reported. The world is the server's own.
        Event::Peer { .. } | Event::World { .. } => return,
        Event::Disconnected => "disconnected".to_string(),
    };
    println!("{line}");
    let _ = std::io::stdout().flush();
}
