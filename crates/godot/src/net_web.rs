//! The browser's `NetBridge`: the same class, with a WebSocket behind it.
//!
//! A tab has no UDP socket, so `session`'s iroh transport cannot run here. The
//! page passes a gateway URL (`--gateway=ws://...`, from `goatsd --gateway`),
//! and this node speaks the native bridge's JSON lines over it: a `join` line
//! names the ticket, a real session client runs in the gateway, and the events
//! come back as the lines `main.gd` already handles.
//!
//! One socket is one player. The gateway opens its own iroh connection per
//! socket, so a native host sees each browser as a normal client.
//!
//! Hosting, swarm discovery and voice are not available through the gateway
//! yet; `host` refuses synchronously and the swarm/voice calls are silent, which
//! is the shape a browser had before, restricted to the parts that now work.
//!
//! This module is the `wasm32` arm of `mod net`; the real bridge is `net.rs`.

use std::collections::VecDeque;

use godot::classes::WebSocketPeer;
use godot::classes::web_socket_peer::State;
use godot::global::Error as GodotError;
use godot::prelude::*;
use serde_json::{Value, json};

/// Lines queued for the socket, and events queued for the scene. Both are
/// bounded: a scene that stops polling must not grow the heap without limit.
const MAX_LINES: usize = 512;

#[derive(GodotClass)]
#[class(base=Node)]
struct NetBridge {
    base: Base<Node>,
    /// The gateway this client was started with. Empty until the page passes it.
    gateway: String,
    socket: Option<Gd<WebSocketPeer>>,
    /// Lines waiting for the socket to open.
    pending: VecDeque<String>,
    /// Lines waiting for the scene's next `poll_events`.
    events: VecDeque<String>,
    /// Whether the gateway has said `welcome`; a refused join leaves this false
    /// so the next `connect` may start a fresh socket.
    joined: bool,
}

#[godot_api]
impl INode for NetBridge {
    fn init(base: Base<Node>) -> Self {
        Self {
            base,
            gateway: String::new(),
            socket: None,
            pending: VecDeque::new(),
            events: VecDeque::new(),
            joined: false,
        }
    }

    fn exit_tree(&mut self) {
        self.close_socket();
    }
}

#[godot_api]
impl NetBridge {
    /// The page's gateway URL. On a desktop build the scene passes it too, and
    /// the native arm ignores it; only this arm has a socket to point at it.
    #[func]
    fn set_gateway(&mut self, url: GString) -> GString {
        self.gateway = url.to_string();
        crate::gstring("ok")
    }

    /// Hosting is a gateway-hosted room, which this build does not provide yet.
    /// An error here is synchronous, so `cmd_host` can leave `_hosting` alone.
    #[func]
    fn host(&mut self, _name: GString, _mods: GString) -> GString {
        crate::gstring(
            "error: hosting from a browser needs a gateway-hosted room; join a host instead",
        )
    }

    /// Join the session `ticket` names through the gateway. The world-mod set is
    /// the scene's own (`mods.world_mod_refs`), and the gateway presents it to
    /// the host exactly as the native bridge does.
    #[func]
    fn join(&mut self, ticket: GString, name: GString, mods: GString, pull: bool) -> GString {
        if self.socket.is_some() {
            return crate::gstring("error: already in a session (leave first)");
        }
        if self.gateway.is_empty() {
            return crate::gstring(
                "error: no gateway configured (open the page with ?gateway=ws://host:port)",
            );
        }
        let mods: Value = match serde_json::from_str(&mods.to_string()) {
            Ok(mods) => mods,
            Err(error) => return crate::gstring(format!("error: world mods: {error}")),
        };
        let line = json!({
            "type": "join",
            "ticket": ticket.to_string(),
            "name": name.to_string(),
            "mods": mods,
            "pull": pull,
        });
        let mut socket = WebSocketPeer::new_gd();
        let error = socket.connect_to_url(&GString::from(self.gateway.as_str()));
        if error != GodotError::OK {
            return crate::gstring(format!("error: gateway: {error:?}"));
        }
        self.socket = Some(socket);
        self.joined = false;
        self.queue(line.to_string());
        crate::gstring("ok")
    }

    /// The native bridge's pull policy; a browser has nowhere to install into,
    /// so this is a no-op that still answers.
    #[func]
    fn set_pull(&mut self, _mods_dir: GString, _always: bool) -> GString {
        crate::gstring("ok")
    }

    #[func]
    fn say(&mut self, text: GString) -> GString {
        self.send(json!({ "type": "say", "text": text.to_string() }))
    }

    #[func]
    fn consume(&mut self, key: i64) -> GString {
        self.send(json!({ "type": "consume", "key": key }))
    }

    #[func]
    #[allow(clippy::too_many_arguments)]
    fn pose(
        &mut self,
        x: f64,
        z: f64,
        yaw: f64,
        phase: f64,
        speed: f64,
        gait: GString,
        py: f64,
    ) -> GString {
        self.send(json!({
            "type": "pose",
            "x": x,
            "z": z,
            "yaw": yaw,
            "phase": phase,
            "speed": speed,
            "gait": gait.to_string(),
            "py": py,
        }))
    }

    #[func]
    fn world(&mut self, json_text: GString) -> GString {
        let mut value: Value = match serde_json::from_str(&json_text.to_string()) {
            Ok(value) => value,
            Err(error) => return crate::gstring(format!("error: world: {error}")),
        };
        if let Value::Object(map) = &mut value {
            map.insert("type".to_string(), json!("world"));
        }
        self.send(value)
    }

    #[func]
    fn mods(&mut self, json_text: GString) -> GString {
        let value: Value = match serde_json::from_str(&json_text.to_string()) {
            Ok(value) => value,
            Err(error) => return crate::gstring(format!("error: mods: {error}")),
        };
        self.send(json!({ "type": "mods", "mods": value }))
    }

    #[func]
    fn blast(&mut self, kind: GString, key: i64, x: f64, z: f64, by: GString) -> GString {
        let by = by.to_string();
        self.send(json!({
            "type": "blast",
            "kind": kind.to_string(),
            "key": key,
            "x": x,
            "z": z,
            "by": if by.is_empty() { Value::Null } else { Value::String(by) },
        }))
    }

    #[func]
    fn leave(&mut self) -> GString {
        self.send(json!({ "type": "close" }))
    }

    #[func]
    fn swarm_join(&mut self, topic: GString, peers: GString) -> GString {
        let topic = topic.to_string();
        let peers: Vec<String> = peers
            .to_string()
            .split(',')
            .map(str::trim)
            .filter(|peer| !peer.is_empty())
            .map(str::to_string)
            .collect();
        self.send(json!({
            "type": "swarm_join",
            "topic": if topic.is_empty() { Value::Null } else { Value::String(topic) },
            "peers": peers,
        }))
    }

    #[func]
    fn swarm_leave(&mut self) -> GString {
        self.send(json!({ "type": "swarm_leave" }))
    }

    #[func]
    fn set_swarm_auto(&mut self, _on: bool) {}

    /// Poll the socket and hand the scene every line that arrived since the last
    /// frame. Called once a frame by `main.gd`, like the native bridge's queue.
    #[func]
    fn poll_events(&mut self) -> PackedStringArray {
        self.pump();
        let mut out = PackedStringArray::new();
        while let Some(line) = self.events.pop_front() {
            out.push(&GString::from(line.as_str()));
        }
        out
    }

    /// No browser capture path yet: these are the native bridge's voice methods,
    /// present so the scene's calls are not errors, and silent.
    #[func]
    fn push_voice(&mut self, _samples: PackedFloat32Array, _rate: f64) -> i64 {
        0
    }

    #[func]
    fn pull_voice(&mut self, _max: i64) -> PackedFloat32Array {
        PackedFloat32Array::new()
    }

    #[func]
    fn set_voice_gain(&mut self, _gain: f64) {}

    #[func]
    fn voice_state(&self) -> GString {
        crate::gstring("{}")
    }

    #[func]
    fn shutdown(&mut self) -> GString {
        self.close_socket();
        crate::gstring("ok")
    }
}

impl NetBridge {
    /// Queue one line for the socket. The join is the first one; a pose queued
    /// while the socket is still connecting waits rather than being dropped.
    fn queue(&mut self, line: String) {
        self.pending.push_back(line);
        while self.pending.len() > MAX_LINES {
            self.pending.pop_front();
        }
    }

    /// Queue a line for a command that has no session-side answer (pose, say,
    /// consume, ...). Returns the native bridge's `ok`.
    fn send(&mut self, value: Value) -> GString {
        if self.socket.is_none() {
            return crate::gstring("error: not in a session");
        }
        self.queue(value.to_string());
        crate::gstring("ok")
    }

    /// Advance the socket, flush what was queued, and collect what arrived.
    fn pump(&mut self) {
        let Some(mut socket) = self.socket.take() else {
            return;
        };
        socket.poll();
        let state = socket.get_ready_state();
        let mut pending = std::mem::take(&mut self.pending);
        let mut drop_socket = false;

        if state == State::OPEN {
            while let Some(line) = pending.pop_front() {
                if socket.send_text(&GString::from(line.as_str())) != GodotError::OK {
                    self.events.push_back(
                        json!({"type":"error","text":"gateway send failed"}).to_string(),
                    );
                    break;
                }
            }
            while socket.get_available_packet_count() > 0 {
                let packet = socket.get_packet();
                let text = String::from_utf8_lossy(packet.as_slice()).to_string();
                for line in text.lines() {
                    let line = line.trim();
                    if line.is_empty() {
                        continue;
                    }
                    // The scene resets itself on `error` and `disconnected`; the
                    // bridge has to do the same, or a second `connect` would
                    // find this dead socket and refuse it.
                    match serde_json::from_str::<Value>(line).ok().and_then(|value| {
                        value
                            .get("type")
                            .and_then(Value::as_str)
                            .map(str::to_string)
                    }) {
                        Some(kind) if kind == "welcome" => self.joined = true,
                        Some(kind) if kind == "error" || kind == "disconnected" => {
                            self.joined = false;
                            drop_socket = true;
                        }
                        _ => {}
                    }
                    self.events.push_back(line.to_string());
                    while self.events.len() > MAX_LINES {
                        self.events.pop_front();
                    }
                }
            }
        } else if state == State::CLOSED {
            self.joined = false;
            pending.clear();
            self.events
                .push_back(json!({"type":"disconnected"}).to_string());
        }

        self.pending = pending;
        if state != State::CLOSED && !drop_socket {
            self.socket = Some(socket);
        } else {
            socket.close();
        }
    }

    fn close_socket(&mut self) {
        if let Some(mut socket) = self.socket.take() {
            socket.close();
        }
        self.pending.clear();
        self.joined = false;
    }
}
