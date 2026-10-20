//! The flight tuning, its defaults and its clamps.
//!
//! The values are the ones in `mods/birds/FLIGHT.md` §6.1. Each client's tuning
//! tree still carries the leaves for the console and for mods; it maps them into
//! this struct and calls [`Config::validate`] before stepping. The defaults live
//! here so the two clients cannot start from different numbers.

/// The flight tuning.
///
/// Units are metres, seconds and radians. `validate` is the shared clamp table;
/// a field a client sets from its own tuning tree should go through it.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Config {
    /// The largest `dt` a step accepts. The scene already clamps its frame time;
    /// this is the crate's own guard against a paused or stalled host.
    pub max_dt: f32,
    /// The base's height relative to the terrain at rest. Zero for the model
    /// goat; the cube fallback uses its own `V_DROP` (about -0.08).
    pub rest_height: f32,
    /// Metres above the model's origin that the body rotates about. The flung
    /// arc's own pivot (`explosions.fling.pivot`, 0.7) is the body's centre and
    /// is the right value here too.
    pub body_pivot: f32,

    /// Upward speed at take-off, m/s.
    pub takeoff_lift: f32,
    /// Nose-up angle at take-off, radians.
    pub takeoff_pitch: f32,
    /// Energy a take-off costs.
    pub takeoff_energy: f32,

    /// Cruise airspeed, m/s.
    pub speed: f32,
    pub min_speed: f32,
    pub max_speed: f32,
    /// How quickly airspeed eases back to `speed`, per second.
    pub speed_response: f32,

    /// The pitch clamp, radians.
    pub pitch_max: f32,
    /// How fast pitch follows the input, radians per second.
    pub pitch_rate: f32,
    /// The bank clamp, radians.
    pub bank_max: f32,
    /// How fast bank follows the input, radians per second.
    pub bank_rate: f32,
    /// Yaw rate at full bank and cruise airspeed, radians per second.
    pub turn_rate: f32,

    /// Sink at level pitch, m/s.
    pub sink: f32,
    /// How much of `speed * sin(pitch)` becomes vertical speed.
    pub climb_gain: f32,
    /// How quickly vertical speed follows its target, per second.
    pub vy_response: f32,

    /// Upward impulse of a flap, m/s.
    pub flap_lift: f32,
    /// Airspeed a flap adds, m/s.
    pub flap_speed: f32,
    /// Seconds between flaps.
    pub flap_cooldown: f32,
    /// Energy a flap costs.
    pub flap_energy: f32,

    /// Energy a second while flying.
    pub drain_fly: f32,

    /// Metres above the ground below that the flight may reach.
    pub ceiling: f32,

    /// Gravity for `fall`, m/s². Negative. Not the blast's -72.
    pub gravity: f32,
    /// Downward impact that does no damage, m/s.
    pub safe_fall: f32,
    /// Health per m/s of impact above `safe_fall`.
    pub fall_damage: f32,
    /// The lowest health a fall may leave. Zero permits a lethal fall.
    pub fall_health_floor: f32,
    /// Radians of nose-down pitch per m/s of downward speed while falling.
    pub fall_pitch_gain: f32,

    /// Metres above the ground a bot holds.
    pub bot_altitude: f32,
    /// Radius of the orbit ring around the player, metres.
    pub bot_radius: f32,
    /// Seconds a bot stays up before descending.
    pub bot_time: f32,
    /// Seconds a bot stays on the ground before it may take off again.
    pub bot_cooldown: f32,
    /// Radians per second the orbit angle advances.
    pub bot_turn: f32,
    /// Turn-axis gain per radian of yaw error.
    pub bot_yaw_gain: f32,
    /// Move-axis gain per metre of altitude error.
    pub bot_pitch_gain: f32,
    /// The altitude error below which a bot does not flap, metres.
    pub bot_flap_below: f32,
    /// A bot noses up below this height above its own ground, metres.
    pub bot_terrain_guard: f32,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            max_dt: 0.05,
            rest_height: 0.0,
            body_pivot: 0.7,

            takeoff_lift: 5.0,
            takeoff_pitch: 0.25,
            takeoff_energy: 2.0,

            speed: 9.0,
            min_speed: 5.0,
            max_speed: 14.0,
            speed_response: 1.2,

            pitch_max: 0.55,
            pitch_rate: 1.6,
            bank_max: 0.75,
            bank_rate: 2.2,
            turn_rate: 1.4,

            sink: 1.2,
            climb_gain: 1.0,
            vy_response: 3.0,

            flap_lift: 5.0,
            flap_speed: 1.5,
            flap_cooldown: 0.45,
            flap_energy: 1.2,

            drain_fly: 2.5,

            ceiling: 60.0,

            gravity: -32.0,
            safe_fall: 12.0,
            fall_damage: 2.2,
            fall_health_floor: 0.0,
            fall_pitch_gain: 0.04,

            bot_altitude: 8.0,
            bot_radius: 18.0,
            bot_time: 18.0,
            bot_cooldown: 8.0,
            bot_turn: 0.9,
            bot_yaw_gain: 1.5,
            bot_pitch_gain: 0.12,
            bot_flap_below: 1.0,
            bot_terrain_guard: 2.0,
        }
    }
}

impl Config {
    /// Clamp every field to the range the game can survive. A non-finite value
    /// falls back to the default: a mod's `tuning.set` is already validated, but
    /// a hand-written `Config` in a test or adapter is not.
    pub fn validate(&mut self) {
        let d = Self::default();
        self.max_dt = sane(self.max_dt, d.max_dt, 0.001, 0.25);
        self.rest_height = sane(self.rest_height, d.rest_height, -1.0, 1.0);
        self.body_pivot = sane(self.body_pivot, d.body_pivot, 0.0, 2.0);

        self.takeoff_lift = sane(self.takeoff_lift, d.takeoff_lift, 0.0, 50.0);
        self.takeoff_pitch = sane(self.takeoff_pitch, d.takeoff_pitch, -1.4, 1.4);
        self.takeoff_energy = sane(self.takeoff_energy, d.takeoff_energy, 0.0, 100.0);

        self.min_speed = sane(self.min_speed, d.min_speed, 0.0, 200.0);
        self.max_speed = sane(self.max_speed, d.max_speed, 0.0, 200.0);
        if self.max_speed < self.min_speed {
            self.max_speed = self.min_speed;
        }
        self.speed = sane(self.speed, d.speed, self.min_speed, self.max_speed);
        self.speed_response = sane(self.speed_response, d.speed_response, 0.0, 50.0);

        self.pitch_max = sane(self.pitch_max, d.pitch_max, 0.0, 1.4);
        self.pitch_rate = sane(self.pitch_rate, d.pitch_rate, 0.0, 50.0);
        self.bank_max = sane(self.bank_max, d.bank_max, 0.0, 1.4);
        self.bank_rate = sane(self.bank_rate, d.bank_rate, 0.0, 50.0);
        self.turn_rate = sane(self.turn_rate, d.turn_rate, 0.0, 50.0);

        self.sink = sane(self.sink, d.sink, 0.0, 100.0);
        self.climb_gain = sane(self.climb_gain, d.climb_gain, 0.0, 10.0);
        self.vy_response = sane(self.vy_response, d.vy_response, 0.0, 50.0);

        self.flap_lift = sane(self.flap_lift, d.flap_lift, 0.0, 50.0);
        self.flap_speed = sane(self.flap_speed, d.flap_speed, 0.0, 50.0);
        self.flap_cooldown = sane(self.flap_cooldown, d.flap_cooldown, 0.0, 10.0);
        self.flap_energy = sane(self.flap_energy, d.flap_energy, 0.0, 100.0);
        self.drain_fly = sane(self.drain_fly, d.drain_fly, 0.0, 100.0);

        self.ceiling = sane(self.ceiling, d.ceiling, 1.0, 1000.0);

        self.gravity = sane(self.gravity, d.gravity, -200.0, -0.1);
        self.safe_fall = sane(self.safe_fall, d.safe_fall, 0.0, 200.0);
        self.fall_damage = sane(self.fall_damage, d.fall_damage, 0.0, 100.0);
        self.fall_health_floor = sane(self.fall_health_floor, d.fall_health_floor, 0.0, 100.0);
        self.fall_pitch_gain = sane(self.fall_pitch_gain, d.fall_pitch_gain, 0.0, 10.0);

        self.bot_altitude = sane(self.bot_altitude, d.bot_altitude, 0.0, 200.0);
        self.bot_radius = sane(self.bot_radius, d.bot_radius, 1.0, 200.0);
        self.bot_time = sane(self.bot_time, d.bot_time, 0.1, 600.0);
        self.bot_cooldown = sane(self.bot_cooldown, d.bot_cooldown, 0.0, 600.0);
        self.bot_turn = sane(self.bot_turn, d.bot_turn, 0.0, 10.0);
        self.bot_yaw_gain = sane(self.bot_yaw_gain, d.bot_yaw_gain, 0.0, 20.0);
        self.bot_pitch_gain = sane(self.bot_pitch_gain, d.bot_pitch_gain, 0.0, 10.0);
        self.bot_flap_below = sane(self.bot_flap_below, d.bot_flap_below, 0.0, 50.0);
        self.bot_terrain_guard = sane(self.bot_terrain_guard, d.bot_terrain_guard, 0.0, 50.0);
    }

    /// Raw fall damage for an impact speed. Zero below `safe_fall`.
    #[must_use]
    pub fn fall_damage(&self, impact: f32) -> f32 {
        if !impact.is_finite() {
            return 0.0;
        }
        ((impact - self.safe_fall).max(0.0) * self.fall_damage).max(0.0)
    }

    /// Apply a fall to a health value, respecting `fall_health_floor`. A caller
    /// that wants to know whether the goat died compares the answer with zero.
    #[must_use]
    pub fn apply_fall_damage(&self, health: f32, impact: f32) -> f32 {
        if !health.is_finite() {
            return self.fall_health_floor;
        }
        (health - self.fall_damage(impact)).max(self.fall_health_floor)
    }
}

/// A finite value clamped to `[min, max]`, or `fallback` when the value is not
/// finite. `min`/`max` are expected to be ordered.
fn sane(value: f32, fallback: f32, min: f32, max: f32) -> f32 {
    if value.is_finite() {
        value.clamp(min, max)
    } else {
        fallback
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_defaults_are_the_design() {
        let c = Config::default();
        assert_eq!(c.speed, 9.0);
        assert_eq!(c.max_speed, 14.0);
        assert_eq!(c.pitch_max, 0.55);
        assert_eq!(c.bank_max, 0.75);
        assert_eq!(c.flap_cooldown, 0.45);
        assert_eq!(c.safe_fall, 12.0);
        assert_eq!(c.body_pivot, 0.7);
        assert!(c.gravity < 0.0);
    }

    #[test]
    fn validate_resets_non_finite_values() {
        let mut c = Config {
            speed: f32::NAN,
            gravity: f32::INFINITY,
            pitch_max: f32::NEG_INFINITY,
            ..Config::default()
        };
        c.validate();
        assert_eq!(c.speed, Config::default().speed);
        assert_eq!(c.gravity, Config::default().gravity);
        assert_eq!(c.pitch_max, Config::default().pitch_max);
    }

    #[test]
    fn validate_keeps_speed_ordered() {
        let mut c = Config {
            min_speed: 30.0,
            max_speed: 10.0,
            speed: 100.0,
            ..Config::default()
        };
        c.validate();
        assert!(c.max_speed >= c.min_speed);
        assert!(c.speed >= c.min_speed && c.speed <= c.max_speed);
    }

    #[test]
    fn fall_damage_is_zero_below_the_threshold() {
        let c = Config::default();
        assert_eq!(c.fall_damage(1.0), 0.0);
        assert_eq!(c.fall_damage(c.safe_fall), 0.0);
        assert!(c.fall_damage(c.safe_fall + 10.0) > 0.0);
    }

    #[test]
    fn apply_fall_damage_respects_the_floor() {
        let mut c = Config {
            fall_health_floor: 1.0,
            ..Config::default()
        };
        let after = c.apply_fall_damage(100.0, 100.0);
        assert_eq!(after, 1.0);

        c.fall_health_floor = 0.0;
        let after = c.apply_fall_damage(100.0, 100.0);
        assert_eq!(after, 0.0);
    }
}
