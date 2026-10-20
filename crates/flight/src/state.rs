//! The values a flight step takes and returns.
//!
//! The client owns these numbers: the crate is a pure function over them, not a
//! second simulation. That is deliberate — the goat's position, mode, stats,
//! drawing and network state already live in the client, and a hidden world here
//! would be one more thing to keep in step with them.

/// What a flyer is doing.
///
/// The client's own mode machine adds `dead`, `sleep`, `eat`, `jump` and the
/// gaits; this crate only ever steps `Fly` and `Fall`, and returns `Grounded` when
/// a contact ends the flight.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Phase {
    /// On the ground, or not flying. A step leaves this state untouched.
    #[default]
    Grounded,
    /// Powered flight: the player's controls or the bot autopilot.
    Fly,
    /// Released, or dead in the air: true gravity and frozen horizontal momentum.
    Fall,
}

/// The flight numbers. All lengths are metres, speeds are metres per second,
/// angles are radians.
///
/// The model's local frame is +X forward, +Y up and +Z across the body.
/// `yaw` is about +Y (forward is `(cos yaw, 0, -sin yaw)`), `pitch` is about +Z
/// (positive raises the nose) and `roll` is about +X (positive drops the right
/// side, which is a right bank).
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct State {
    /// World position in the ground plane.
    pub x: f32,
    pub z: f32,
    /// Absolute height of the base (the model's origin, its hooves). This is not
    /// a height above the terrain: the crate derives the height above the ground
    /// only when it tests the ground, and the client's `py` is
    /// `y - terrainHeight(x, z)`.
    pub y: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub roll: f32,
    /// Horizontal airspeed.
    pub speed: f32,
    /// Vertical speed.
    pub vy: f32,
    /// Seconds until the next flap is allowed.
    pub flap_cool: f32,
    /// Flaps since take-off, for a rider's wingbeat and the HUD.
    pub flaps: u32,
    /// Seconds in the current `Fly` or `Fall`.
    pub flight_time: f32,
    pub phase: Phase,
}

impl State {
    /// Whether every field is finite. A client that reads a non-finite state
    /// should recover the entity rather than step it again.
    #[must_use]
    pub fn is_finite(&self) -> bool {
        self.x.is_finite()
            && self.z.is_finite()
            && self.y.is_finite()
            && self.yaw.is_finite()
            && self.pitch.is_finite()
            && self.roll.is_finite()
            && self.speed.is_finite()
            && self.vy.is_finite()
            && self.flap_cool.is_finite()
            && self.flight_time.is_finite()
    }
}

/// One frame's controls.
///
/// The axes are the scene's own held-key signs, so both clients map their input
/// the same way: `move_axis` is W `+1` / S `-1`, `turn_axis` is A `+1` / D `-1`.
/// In flight, W is nose-down and S is nose-up; A is a left bank and D a right
/// bank. The crate applies the mode-specific meaning, not the client.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Input {
    pub move_axis: f32,
    pub turn_axis: f32,
    /// Space, gated by the caller's energy? No: `energy` is here, so the crate
    /// refuses a flap the goat cannot pay for.
    pub flap: bool,
    /// E: leave the flight into a free fall.
    pub release: bool,
    /// The energy the flyer has *before* this frame. The crate refuses a flap it
    /// cannot pay for; the client subtracts `Events::flap_cost` and
    /// `Events::drain` afterwards.
    pub energy: f32,
}

impl Default for Input {
    fn default() -> Self {
        Self {
            move_axis: 0.0,
            turn_axis: 0.0,
            flap: false,
            release: false,
            // An unlimited flyer, which is what a bot is: bots have no energy
            // stat. A player's client passes its real energy.
            energy: f32::INFINITY,
        }
    }
}

/// Where a flight ended and what it cost.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Landing {
    /// Downward speed at contact, m/s, never negative.
    pub impact: f32,
    /// Raw damage from [`crate::Config::fall_damage`]. The caller applies it
    /// with [`crate::Config::apply_fall_damage`] so the health floor is shared.
    pub damage: f32,
}

/// What happened in a step. These are the consequences the client applies: a
/// flap's energy and cooldown, a landing's damage, the release the mod needs to
/// detach a bird.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Events {
    pub flapped: bool,
    /// Energy the flap cost; zero when it was refused.
    pub flap_cost: f32,
    /// Energy the flight drained this frame (`drain_fly * dt`).
    pub drain: f32,
    /// The release input was taken: the state is now in `Fall`.
    pub released: bool,
    /// The ceiling clamped the climb.
    pub ceiling: bool,
    /// The flight or fall met the ground this frame.
    pub landed: Option<Landing>,
}

/// The new state and what happened.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Outcome {
    pub state: State,
    pub events: Events,
}

/// What a take-off did. The state is in `Fly`; the client pays `energy_cost`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Start {
    pub state: State,
    pub energy_cost: f32,
}
