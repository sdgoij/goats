//! Swarm discovery and the session's two kinds of ring, as the scene sees it.
//!
//! The swarm (`crates/session/src/swarm.rs`, `goatsd`) is a list of tickets; the
//! scene is what turns one into a place. These cases drive the scene side
//! directly: a `discovered` event becomes rings at deterministic positions,
//! walking into one queues that host's join, and a session in progress ignores
//! them -- but raises the amber exit ring instead, which walking into closes
//! the session.
//!
//! One harness, one test: the cases are a sequence (the join changes the scene's
//! state), and a fresh world is cheap here in a way the scripted `scene_logic`
//! run is not.

mod support;

use harness::Harness;
use serde_json::json;
use support::{f64_of, net_feed};

/// Enough frames for the splash to finish; the portal code runs after that.
const LOADED: u32 = 40;

const SESSIONS: &str = r#"{"type":"discovered","sessions":[
    {"ticket":"ticket-a","name":"ann","clients":2,"protocol":13},
    {"ticket":"ticket-b","name":"ben","clients":1,"protocol":13}]}"#;

/// `PORTALS` is a top-level `const`, so a snippet is the only way in; the module
/// deliberately keeps its methods off the global object.
fn placement(harness: &mut Harness, ticket: &str) -> serde_json::Value {
    harness
        .eval(&format!(r#"PORTALS.placement("{ticket}")"#))
        .expect("PORTALS.placement")
}

#[test]
fn a_discovered_host_is_a_ring_that_joins_it() {
    let mut harness = Harness::start().expect("evaluate the scene");
    harness.run(LOADED).expect("run the scene");

    // ---- the list becomes rings at ticket-derived places -------------------
    net_feed(&mut harness, SESSIONS).expect("discovered");
    assert_eq!(
        harness.eval("netHosts.length").expect("netHosts"),
        json!(2),
        "the scene keeps the list it was told about"
    );
    let a = placement(&mut harness, "ticket-a");
    let again = placement(&mut harness, "ticket-a");
    let b = placement(&mut harness, "ticket-b");
    assert_eq!(a, again, "the same ticket lands in the same place");
    assert_ne!(a, b, "different tickets land in different places");
    let radius = f64_of(a["x"].clone()).hypot(f64_of(a["z"].clone()));
    assert!(
        (20.0..=30.0).contains(&radius),
        "a portal is a short walk out, not a teleport: {radius}"
    );

    // ---- walking into it queues the join -----------------------------------
    // The world is offline here, so the ring is live. `restart` puts the goat
    // back in a state the frame will step (not dead, not mid-menu), and `pos` is
    // the scene's own way of placing it.
    harness.command("heal").expect("heal");
    harness.command("restart").expect("restart");
    harness
        .command(&format!(
            "pos {} {}",
            f64_of(a["x"].clone()),
            f64_of(a["z"].clone())
        ))
        .expect("pos");
    harness.call("sceneNetDrain", &[]).expect("drain");
    // The scripted run leaves the window closed; one more frame is opened the
    // same way `pose_after` in `scene_logic` does it.
    harness.reset_frame().expect("reset the frame counter");
    harness.call("sceneFrame", &[]).expect("one frame");
    let intent = harness
        .call("sceneNetDrain", &[])
        .expect("drain")
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(
        intent.contains(r#""type":"join""#) && intent.contains(r#""ticket":"ticket-a""#),
        "the ring queued its host's join: {intent}"
    );
    assert!(
        intent.contains(r#""name":"goat""#),
        "a fresh client joins as the default name: {intent}"
    );

    // ---- a session makes the host rings inert, and raises the exit ------
    // The server is already listening for this join; the scene must not queue a
    // second one, which is what standing in a second ring would otherwise do.
    // The session seed is the host's, so this client's own streams are saved
    // first and must come back when it leaves.
    let own_streams = harness.eval("sceneStreams()").expect("own streams");
    net_feed(&mut harness, r#"{"type":"session","seed":424242}"#).expect("session");
    let borrowed = harness.eval("sceneStreams()").expect("borrowed streams");
    assert_ne!(
        borrowed, own_streams,
        "the session seed re-derives this client's streams"
    );
    net_feed(&mut harness, r#"{"type":"welcome","name":"eve"}"#).expect("welcome");
    harness.call("sceneNetDrain", &[]).expect("drain");
    harness
        .command(&format!(
            "pos {} {}",
            f64_of(b["x"].clone()),
            f64_of(b["z"].clone())
        ))
        .expect("pos");
    harness.reset_frame().expect("reset the frame counter");
    harness.call("sceneFrame", &[]).expect("one frame");
    let intent = harness
        .call("sceneNetDrain", &[])
        .expect("drain")
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(
        !intent.contains(r#""type":"join""#),
        "a session ignores the host rings: {intent}"
    );

    // ---- the exit ring is the way out ------------------------------------
    // One amber ring stands ten metres from spawn, and walking into it closes
    // the session. It is the only ring live while this client is a client.
    let exit = harness.eval("PORTALS.exit()").expect("PORTALS.exit");
    assert_eq!(
        f64_of(exit["x"].clone()),
        0.0,
        "the exit is on the spawn's z axis"
    );
    assert_eq!(
        f64_of(exit["z"].clone()),
        10.0,
        "the exit is a short walk from spawn"
    );
    harness
        .command(&format!(
            "pos {} {}",
            f64_of(exit["x"].clone()),
            f64_of(exit["z"].clone())
        ))
        .expect("pos");
    harness.reset_frame().expect("reset the frame counter");
    harness.call("sceneFrame", &[]).expect("one frame");
    let intent = harness
        .call("sceneNetDrain", &[])
        .expect("drain")
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(
        intent.contains(r#""type":"close""#),
        "walking into the exit leaves the session: {intent}"
    );
    // ...and the world it left is the one it had before the host's seed.
    let restored = harness.eval("sceneStreams()").expect("restored streams");
    assert_eq!(
        restored, own_streams,
        "leaving a session restores this client's own streams"
    );

    // ---- the list is replaced, not merged ---------------------------------
    net_feed(
        &mut harness,
        r#"{"type":"discovered","sessions":[{"ticket":"ticket-c","name":"cam","clients":1,"protocol":13}]}"#,
    )
    .expect("discovered");
    assert_eq!(
        harness.eval("netHosts.length").expect("netHosts"),
        json!(1),
        "a host that is gone leaves no ring behind"
    );
    assert_eq!(
        harness.eval("netHosts[0].ticket").expect("netHosts"),
        json!("ticket-c")
    );
}
