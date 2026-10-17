//! The browser's `NetBridge`: the same class, with no transport behind it.
//!
//! A tab has no UDP socket, so `session` (iroh), `pull` and the tokio runtime
//! they need are compiled out for `wasm32` (`godot/WEB.md`). The scene still
//! creates this node -- it is the one seam every networking call goes through --
//! so the class stays, and every method answers the same "no session" an offline
//! desktop scene gets. Nothing here can host, join, chat or carry voice; the
//! offline game is the whole of the browser build.
//!
//! This module is the `wasm32` arm of `mod net`; the real bridge is `net.rs`.

use godot::prelude::*;

#[derive(GodotClass)]
#[class(base=Node)]
struct NetBridge {
    base: Base<Node>,
}

#[godot_api]
impl INode for NetBridge {
    fn init(base: Base<Node>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl NetBridge {
    #[func]
    fn host(&mut self, _name: GString, _mods: GString) -> GString {
        no_session()
    }

    #[func]
    fn join(&mut self, _ticket: GString, _name: GString, _mods: GString, _pull: bool) -> GString {
        no_session()
    }

    #[func]
    fn set_pull(&mut self, _mods_dir: GString, _always: bool) -> GString {
        no_session()
    }

    #[func]
    fn say(&mut self, _text: GString) -> GString {
        no_session()
    }

    #[func]
    fn consume(&mut self, _key: i64) -> GString {
        no_session()
    }

    #[func]
    #[allow(clippy::too_many_arguments)]
    fn pose(
        &mut self,
        _x: f64,
        _z: f64,
        _yaw: f64,
        _phase: f64,
        _speed: f64,
        _gait: GString,
        _py: f64,
    ) -> GString {
        no_session()
    }

    #[func]
    fn world(&mut self, _json: GString) -> GString {
        no_session()
    }

    #[func]
    fn mods(&mut self, _json: GString) -> GString {
        no_session()
    }

    #[func]
    fn blast(&mut self, _kind: GString, _key: i64, _x: f64, _z: f64, _by: GString) -> GString {
        no_session()
    }

    #[func]
    fn leave(&mut self) -> GString {
        no_session()
    }

    #[func]
    fn poll_events(&mut self) -> PackedStringArray {
        PackedStringArray::new()
    }

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
        GString::from("{\"sent\":0,\"decoded\":0,\"buffered\":0,\"gain\":0}")
    }

    #[func]
    fn shutdown(&mut self) -> GString {
        GString::from("ok")
    }
}

fn no_session() -> GString {
    GString::from("error: networking is not available in the browser")
}
