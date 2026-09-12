//! `goatsd`: a standalone headless host for a goat session.
//!
//! It is a lobby for now -- it holds the session, assigns names and reports the
//! roster -- because a server-side world simulation has nothing to do until
//! world sync (M12) exists. It deliberately does not evaluate the scene yet:
//! relaying presence does not need the simulation, and a headless scene would
//! first need a null `rl` module (the harness shows that is workable, but there
//! is no consumer for it until M12).
//!
//! The ticket is the whole interface: the host prints it, and a player pastes it
//! into the client's console with `connect <ticket> <name>`.

use std::io::Write;

use session::{Event, Host};

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

    println!("goatsd: hosting as {}", host.name());
    println!("ticket {}", host.ticket());
    println!("goatsd: paste that into a client's console with `connect <ticket> <name>`");
    println!("goatsd: LAN only for now (no relay); Ctrl-C to stop");
    let _ = std::io::stdout().flush();

    loop {
        tokio::select! {
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

/// One line per event, so a session's comings and goings read as a log.
fn report(event: Event) {
    let line = match event {
        Event::Joined { name } => format!("{name} joined"),
        Event::Left { name } => format!("{name} left"),
        Event::Roster { names } => format!("roster {}", names.join(", ")),
        Event::Notice(text) => format!("notice {text}"),
        Event::Disconnected => "disconnected".to_string(),
    };
    println!("{line}");
    let _ = std::io::stdout().flush();
}
