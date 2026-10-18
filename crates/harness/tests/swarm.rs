//! The swarm, as the scene sees it.
//!
//! The gossip mechanics are `crates/session/src/swarm.rs`; the bridge that turns
//! them into scene lines is `crates/goats/src/net.rs`. This is the console end:
//! `swarm join` and `swarm leave` queue the right intents, the swarm's events
//! update the local view, and the discovered list is kept -- and replaced, never
//! merged -- so a host that leaves does not linger.
//!
//! No frames are needed: these are the command and event surfaces, not the
//! simulation.

mod support;

use harness::Harness;
use serde_json::json;
use support::net_feed;

const TOPIC: &str = "32b19c7a81bb09d6147d1a2511bbd3668b0c81a68abb7cfbe2f65d97dd195a9e";

fn drain(harness: &mut Harness) -> String {
    harness
        .call("sceneNetDrain", &[])
        .expect("drain")
        .as_str()
        .unwrap_or_default()
        .to_string()
}

#[test]
fn the_swarm_commands_and_state() {
    let mut harness = Harness::start().expect("evaluate the scene");

    // ---- the commands -----------------------------------------------------
    // No arguments means the default topic: the bridge fills that in, so the
    // scene sends `null`, not a string that pretends to be one.
    assert_eq!(
        harness.command("swarm join").expect("swarm join"),
        "ok swarm join"
    );
    let intent = drain(&mut harness);
    assert!(intent.contains(r#""type":"swarm_join""#), "{intent}");
    assert!(intent.contains(r#""topic":null"#), "{intent}");

    // A topic and a seed peer travel as given; the bridge validates them.
    harness
        .command(&format!("swarm join --topic {TOPIC} --peer seed-ticket"))
        .expect("swarm join with a topic");
    let intent = drain(&mut harness);
    assert!(intent.contains(TOPIC), "{intent}");
    assert!(intent.contains(r#""peers":["seed-ticket"]"#), "{intent}");

    // Leaving is an error until joined.
    assert_eq!(
        harness.command("swarm leave").expect("swarm leave"),
        "error not in a swarm"
    );

    // ---- the joined view --------------------------------------------------
    net_feed(
        &mut harness,
        &format!(
            r#"{{"type":"swarm","joined":true,"topic":"{TOPIC}","id":"abc","ticket":"seed","peers":2}}"#
        ),
    )
    .expect("swarm joined");
    net_feed(&mut harness, r#"{"type":"swarm_peers","peers":3}"#).expect("peers");
    let status = harness
        .eval("JSON.stringify(netSwarmStatus())")
        .expect("swarm status")
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(status.contains(TOPIC), "{status}");
    assert!(status.contains(r#""peers":3"#), "{status}");

    let net = harness
        .eval("JSON.stringify(netStatus())")
        .expect("net status")
        .as_str()
        .unwrap_or_default()
        .to_string();
    assert!(
        net.contains(r#""swarm":"#),
        "the net view carries the swarm: {net}"
    );

    // ---- the discovered list ---------------------------------------------
    net_feed(
        &mut harness,
        r#"{"type":"discovered","sessions":[
            {"ticket":"ticket-a","name":"ann","clients":2,"protocol":13},
            {"ticket":"ticket-b","name":"ben","clients":1,"protocol":13}]}"#,
    )
    .expect("discovered");
    assert_eq!(
        harness.eval("netHosts.length").expect("netHosts"),
        json!(2),
        "the scene keeps the list it was told about"
    );
    assert_eq!(
        harness.eval("netHosts[0].ticket").expect("netHosts"),
        json!("ticket-a")
    );

    // A later list replaces the earlier one: a host that has gone must not be
    // remembered as if it were still there.
    net_feed(
        &mut harness,
        r#"{"type":"discovered","sessions":[{"ticket":"ticket-c","name":"cam","clients":1,"protocol":13}]}"#,
    )
    .expect("discovered");
    assert_eq!(
        harness.eval("netHosts.length").expect("netHosts"),
        json!(1),
        "a host that is gone leaves no entry behind"
    );
    assert_eq!(
        harness.eval("netHosts[0].ticket").expect("netHosts"),
        json!("ticket-c")
    );

    // ---- leaving ----------------------------------------------------------
    assert_eq!(
        harness.command("swarm leave").expect("swarm leave"),
        "ok swarm leave"
    );
    let intent = drain(&mut harness);
    assert!(intent.contains(r#""type":"swarm_leave""#), "{intent}");

    // The bridge's answer, as the scene would receive it: the view is cleared
    // even if the gossip task's last list is still in flight.
    net_feed(&mut harness, r#"{"type":"swarm","joined":false}"#).expect("swarm left");
    assert_eq!(harness.eval("netHosts.length").expect("netHosts"), json!(0));
    assert_eq!(
        harness.eval("netSwarmStatus().topic").expect("swarm topic"),
        json!("")
    );
}
