//! The flight mechanics, shared by the raylib scene and the Godot client.
//!
//! This crate is the one implementation of the captured-bird flight model: the
//! take-off rule, the powered step, the release and free fall, fall damage, the
//! herd's flight autopilot and the pose maths. It is pure: no engine, no wire, no
//! tuning tree. The raylib client reaches it through a `__flight` native global
//! (`crates/goats/src/flight_js.rs`), the Godot client through the GDExtension
//! (`crates/godot/src/flight.rs`), and the tests call it directly.
//!
//! # The client owns the world
//!
//! [`State`] is a plain value. The client holds it beside the goat's or bot's own
//! fields, passes it to [`step`], and writes the returned numbers back. The crate
//! is a function over those numbers, not a second simulation: the client already
//! owns the position, mode, stats, drawing, collisions and network state, and a
//! hidden world here would be one more thing to keep in step with them.
//!
//! # Coordinates
//!
//! The model's local frame is +X forward, +Y up and +Z across the body.
//!
//! - `yaw` is about +Y; forward is `(cos yaw, 0, -sin yaw)`, so a positive yaw is
//!   a left turn.
//! - `pitch` is about +Z; positive raises the nose.
//! - `roll` is about +X; positive drops the right side, which is a right bank.
//!
//! The controls follow the scene's held-key signs. `move_axis` is W `+1` / S `-1`
//! and `turn_axis` is A `+1` / D `-1`; in flight W noses down, S noses up, A banks
//! left and D banks right. The mode-specific meaning lives here so the two clients
//! cannot disagree about it.
//!
//! # Events, not side effects
//!
//! The crate never touches health, energy, modes, sound or the bird. [`Events`]
//! carries the consequences — a flap's cost, the frame's drain, a landing's
//! impact and damage, a release — and the client applies them.
//!
//! ```
//! use flight::{Config, Input, Phase, State};
//!
//! let config = Config::default();
//! let state = State { y: 10.0, speed: 9.0, phase: Phase::Fly, ..State::default() };
//! let out = flight::step(&config, state, Input::default(), 1.0 / 60.0, |_, _| 0.0);
//! assert_eq!(out.state.phase, Phase::Fly);
//! ```

mod bot;
mod config;
mod motion;
mod pose;
mod state;

pub use bot::{BotContext, BotControl, bot_input};
pub use config::Config;
pub use motion::{can_take_off, release, start, step};
pub use pose::{AxisAngle, Quat, axis_angle, back_point, pose};
pub use state::{Events, Input, Landing, Outcome, Phase, Start, State};
