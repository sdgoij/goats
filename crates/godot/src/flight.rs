//! The flight controller as a Godot class.
//!
//! This is `crates/flight` behind a `RefCounted`, and it is the port's half of
//! `FLIGHT-RUST.md` §5: the same maths the reference client reaches through the
//! `__flight` global (`crates/flight-js`), behind the same positional arrays. The
//! two bindings are deliberately identical in shape, because a second layout
//! would be a second contract and the point of the crate is that there is one.
//!
//! The scene keeps the state: `PlayerGoat` (and, from R3, the herd) owns the
//! numbers, packs them into a `PackedFloat32Array`, calls one of these methods,
//! and writes the answer back. The class holds only the `Config`, so a tuning
//! write rebuilds one value rather than a world.
//!
//! # The arrays
//!
//! ```text
//! state  [x, z, y, yaw, pitch, roll, speed, vy, flapCool, flaps, flightTime, phase]
//! input  [move, turn, flap, release, energy]
//! step   [state…12, flapped, flapCost, drain, released, ceiling, landed, impact, damage]
//! start  [state…12, energyCost]
//! bot    [move, turn, flap, release, orbitAngle]
//! ```
//!
//! `phase` is 0 grounded, 1 fly, 2 fall, matching [`flight::Phase`]. The booleans
//! are 0/1 numbers for the same reason the reference's are: one array crosses the
//! boundary rather than a dozen property reads.

use godot::prelude::*;

use flight::{Config, Input, Phase, State};

/// The state half of every array, and the index the first event starts at.
const STATE_LEN: usize = 12;

/// The flight controller. One instance is enough for the whole scene: the state
/// is the caller's, so there is nothing per-goat to keep here.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct Flight {
    base: Base<RefCounted>,
    config: Config,
}

#[godot_api]
impl IRefCounted for Flight {
    fn init(base: Base<RefCounted>) -> Self {
        Self {
            base,
            // The crate's defaults are `FLIGHT.md` §6.1's, so a scene that never
            // calls `configure` still flies.
            config: Config::default(),
        }
    }
}

#[godot_api]
impl Flight {
    /// Replace the tuning. The dictionary is the reference's `TUNING.flight` shape
    /// (camelCase, one key per `Config` field); a missing or non-numeric key keeps
    /// the crate's default, and `validate` clamps what did arrive.
    #[func]
    fn configure(&mut self, config: VarDictionary) {
        let mut next = Config::default();
        let set = |key: &str, slot: &mut f32| {
            if let Some(value) = config.get(key)
                && let Ok(number) = value.try_to::<f64>()
            {
                *slot = number as f32;
            }
        };
        set("maxDt", &mut next.max_dt);
        set("restHeight", &mut next.rest_height);
        set("bodyPivot", &mut next.body_pivot);
        set("takeoffLift", &mut next.takeoff_lift);
        set("takeoffPitch", &mut next.takeoff_pitch);
        set("takeoffEnergy", &mut next.takeoff_energy);
        set("speed", &mut next.speed);
        set("minSpeed", &mut next.min_speed);
        set("maxSpeed", &mut next.max_speed);
        set("speedResponse", &mut next.speed_response);
        set("pitchMax", &mut next.pitch_max);
        set("pitchRate", &mut next.pitch_rate);
        set("bankMax", &mut next.bank_max);
        set("bankRate", &mut next.bank_rate);
        set("turnRate", &mut next.turn_rate);
        set("sink", &mut next.sink);
        set("climbGain", &mut next.climb_gain);
        set("vyResponse", &mut next.vy_response);
        set("flapLift", &mut next.flap_lift);
        set("flapSpeed", &mut next.flap_speed);
        set("flapCooldown", &mut next.flap_cooldown);
        set("flapEnergy", &mut next.flap_energy);
        set("drainFly", &mut next.drain_fly);
        set("ceiling", &mut next.ceiling);
        set("gravity", &mut next.gravity);
        set("safeFall", &mut next.safe_fall);
        set("fallDamage", &mut next.fall_damage);
        set("fallHealthFloor", &mut next.fall_health_floor);
        set("fallPitchGain", &mut next.fall_pitch_gain);
        set("botAltitude", &mut next.bot_altitude);
        set("botRadius", &mut next.bot_radius);
        set("botTime", &mut next.bot_time);
        set("botCooldown", &mut next.bot_cooldown);
        set("botTurn", &mut next.bot_turn);
        set("botYawGain", &mut next.bot_yaw_gain);
        set("botPitchGain", &mut next.bot_pitch_gain);
        set("botFlapBelow", &mut next.bot_flap_below);
        set("botTerrainGuard", &mut next.bot_terrain_guard);
        next.validate();
        self.config = next;
    }

    /// One frame. `ground` is the scene's own `Terrain.height_at`, called at the
    /// position the crate moved to, so landing and the ceiling are the crate's
    /// rules rather than the port's.
    #[func]
    fn step(
        &self,
        state: PackedFloat32Array,
        input: PackedFloat32Array,
        dt: f64,
        ground: Callable,
    ) -> PackedFloat32Array {
        let state = read_state(state.as_slice());
        let input = read_input(input.as_slice());
        let outcome = flight::step(&self.config, state, input, dt as f32, |x, z| {
            ground_at(&ground, x, z)
        });
        let mut out = PackedFloat32Array::new();
        write_state(&mut out, &outcome.state);
        push_bool(&mut out, outcome.events.flapped);
        push(&mut out, outcome.events.flap_cost);
        push(&mut out, outcome.events.drain);
        push_bool(&mut out, outcome.events.released);
        push_bool(&mut out, outcome.events.ceiling);
        push_bool(&mut out, outcome.events.landed.is_some());
        let (impact, damage) = outcome
            .events
            .landed
            .map(|landing| (landing.impact, landing.damage))
            .unwrap_or((0.0, 0.0));
        push(&mut out, impact);
        push(&mut out, damage);
        out
    }

    /// Begin powered flight. `speed` is the horizontal speed at the jump. The
    /// answer is the state plus the take-off's energy cost at index 12.
    #[func]
    fn start(&self, state: PackedFloat32Array, speed: f64) -> PackedFloat32Array {
        let started = flight::start(&self.config, read_state(state.as_slice()), speed as f32);
        let mut out = PackedFloat32Array::new();
        write_state(&mut out, &started.state);
        push(&mut out, started.energy_cost);
        out
    }

    /// End a flight into a free fall. A state that is not flying is returned as it
    /// is, so a scripted double-release is harmless.
    #[func]
    fn release(&self, state: PackedFloat32Array) -> PackedFloat32Array {
        let state = flight::release(read_state(state.as_slice()));
        let mut out = PackedFloat32Array::new();
        write_state(&mut out, &state);
        out
    }

    /// The raw damage an impact of `impact` m/s does (`config.fall_damage`).
    #[func]
    fn fall_damage(&self, impact: f64) -> f64 {
        self.config.fall_damage(impact as f32) as f64
    }

    /// `health` after falling at `impact` m/s. Both the damage formula and the
    /// `fallHealthFloor` are the crate's, so a fall and a blast cannot disagree
    /// about either.
    #[func]
    fn apply_fall_damage(&self, health: f64, impact: f64) -> f64 {
        self.config.apply_fall_damage(health as f32, impact as f32) as f64
    }

    /// One frame of the herd's autopilot. `context` is
    /// `[playerX, playerZ, orbitAngle, orbitDir, landing]`; the answer is
    /// `[move, turn, flap, release, orbitAngle]`, which the caller turns into a
    /// `step` input and writes the orbit angle back.
    #[func]
    fn bot_input(
        &self,
        state: PackedFloat32Array,
        context: PackedFloat32Array,
        dt: f64,
        ground: Callable,
    ) -> PackedFloat32Array {
        let at = |index: usize| context.as_slice().get(index).copied().unwrap_or(0.0);
        let context = flight::BotContext {
            player_x: at(0),
            player_z: at(1),
            orbit_angle: at(2),
            orbit_dir: at(3),
            landing: at(4) != 0.0,
        };
        let control = flight::bot_input(
            &self.config,
            &read_state(state.as_slice()),
            context,
            dt as f32,
            |x, z| ground_at(&ground, x, z),
        );
        let mut out = PackedFloat32Array::new();
        out.push(control.input.move_axis);
        out.push(control.input.turn_axis);
        out.push(if control.input.flap { 1.0 } else { 0.0 });
        out.push(if control.input.release { 1.0 } else { 0.0 });
        out.push(control.orbit_angle);
        out
    }

    /// The flyer's whole-body rotation: yaw about +Y, pitch about +Z, roll about
    /// +X. Godot takes a `Quaternion` directly, which is the neutral output the
    /// crate chose so that raylib's single axis-angle is the derived one.
    #[func]
    fn pose(&self, state: PackedFloat32Array) -> Quaternion {
        let state = read_state(state.as_slice());
        let q = flight::pose(&state);
        Quaternion::new(q.x, q.y, q.z, q.w)
    }

    /// Where a rider sits on the back. `pivot` is the height above the feet the
    /// body rotates about, and `perch` the height of the saddle; at rest this is
    /// the feet plus `perch`, and at a pitch it swings the rider about the pivot.
    /// The caller draws the body at `feet + pivot` and offsets the model by
    /// `-pivot`, which is the same rotation applied to the same point.
    #[func]
    fn back_point(&self, state: PackedFloat32Array, perch: f64, pivot: f64) -> Vector3 {
        let state = read_state(state.as_slice());
        let point = flight::back_point(&state, perch as f32, pivot as f32);
        Vector3::new(point[0], point[1], point[2])
    }
}

/// The scene's ground, through the `Callable` the caller handed over. A refused
/// call reads as 0, which is the crate's own "no ground here" fallback.
fn ground_at(ground: &Callable, x: f32, z: f32) -> f32 {
    let answer = ground.callv(&varray![&Variant::from(x as f64), &Variant::from(z as f64)]);
    answer
        .try_to::<f64>()
        .map(|value| value as f32)
        .unwrap_or(0.0)
}

fn read_state(values: &[f32]) -> State {
    let at = |index: usize| values.get(index).copied().unwrap_or(0.0);
    State {
        x: at(0),
        z: at(1),
        y: at(2),
        yaw: at(3),
        pitch: at(4),
        roll: at(5),
        speed: at(6),
        vy: at(7),
        flap_cool: at(8),
        flaps: at(9).max(0.0) as u32,
        flight_time: at(10),
        phase: match at(11) as i32 {
            1 => Phase::Fly,
            2 => Phase::Fall,
            _ => Phase::Grounded,
        },
    }
}

fn read_input(values: &[f32]) -> Input {
    let at = |index: usize| values.get(index).copied();
    Input {
        move_axis: at(0).unwrap_or(0.0),
        turn_axis: at(1).unwrap_or(0.0),
        flap: at(2).unwrap_or(0.0) != 0.0,
        release: at(3).unwrap_or(0.0) != 0.0,
        energy: at(4).unwrap_or(f32::INFINITY),
    }
}

fn write_state(out: &mut PackedFloat32Array, state: &State) {
    out.push(state.x);
    out.push(state.z);
    out.push(state.y);
    out.push(state.yaw);
    out.push(state.pitch);
    out.push(state.roll);
    out.push(state.speed);
    out.push(state.vy);
    out.push(state.flap_cool);
    out.push(state.flaps as f32);
    out.push(state.flight_time);
    out.push(match state.phase {
        Phase::Grounded => 0.0,
        Phase::Fly => 1.0,
        Phase::Fall => 2.0,
    });
    debug_assert_eq!(out.len(), STATE_LEN);
}

fn push(out: &mut PackedFloat32Array, value: f32) {
    out.push(value);
}

fn push_bool(out: &mut PackedFloat32Array, value: bool) {
    push(out, if value { 1.0 } else { 0.0 });
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The array layout is the contract the two clients share, so it is checked
    /// here as well as in `flight-js`. A `State` that satisfies `is_finite` is
    /// enough: the maths itself is the crate's tests.
    #[test]
    fn the_state_array_round_trips() {
        let state = State {
            x: 1.0,
            z: 2.0,
            y: 3.0,
            yaw: 0.4,
            pitch: 0.1,
            roll: -0.2,
            speed: 9.0,
            vy: 1.5,
            flap_cool: 0.3,
            flaps: 2,
            flight_time: 0.75,
            phase: Phase::Fall,
        };
        let mut packed = PackedFloat32Array::new();
        write_state(&mut packed, &state);
        assert_eq!(packed.len(), STATE_LEN);
        let back = read_state(packed.as_slice());
        assert_eq!(back, state);
    }

    #[test]
    fn a_short_input_is_the_default_input() {
        assert_eq!(read_input(&[]), Input::default());
        let input = read_input(&[1.0, -1.0, 1.0, 0.0, 4.0]);
        assert!(input.flap);
        assert!(!input.release);
        assert_eq!(input.energy, 4.0);
    }
}
