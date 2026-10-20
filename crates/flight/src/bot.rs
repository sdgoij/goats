//! The herd's flight autopilot.
//!
//! A flying bot circles the player on a ring and holds an altitude above the
//! ground, flapping when it is low and descending when its time is up. It is pure
//! input generation: the client still calls [`crate::step`] with the returned
//! controls, so the bot and the player use exactly the same flight model.

use crate::motion::wrap_angle;
use crate::{Config, Input, Phase, State};

/// What the autopilot needs that the flight state does not hold.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BotContext {
    /// The goat the herd orbits.
    pub player_x: f32,
    pub player_z: f32,
    /// The current angle around the ring, radians.
    pub orbit_angle: f32,
    /// `+1` or `-1`: which way the bot circles. Index parity is the usual source.
    pub orbit_dir: f32,
    /// Force a landing before `bot_time` (a leash, or the caller's own reason).
    pub landing: bool,
}

impl Default for BotContext {
    fn default() -> Self {
        Self {
            player_x: 0.0,
            player_z: 0.0,
            orbit_angle: 0.0,
            orbit_dir: 1.0,
            landing: false,
        }
    }
}

/// The frame's input and the orbit angle after this frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BotControl {
    pub input: Input,
    pub orbit_angle: f32,
}

/// Produce one frame of bot controls.
///
/// `ground` is the same terrain function the flight step gets. The returned
/// [`Input`] has unlimited energy because bots have no energy stat; the flap's
/// cooldown is in the state and the step still enforces it.
#[must_use]
pub fn bot_input<G>(
    config: &Config,
    state: &State,
    context: BotContext,
    dt: f32,
    ground: G,
) -> BotControl
where
    G: Fn(f32, f32) -> f32,
{
    if state.phase != Phase::Fly || !state.is_finite() {
        return BotControl {
            input: Input::default(),
            orbit_angle: context.orbit_angle,
        };
    }

    let angle = if dt.is_finite() && dt > 0.0 {
        context.orbit_angle + config.bot_turn * context.orbit_dir * dt
    } else {
        context.orbit_angle
    };

    let target_x = context.player_x + angle.cos() * config.bot_radius;
    let target_z = context.player_z - angle.sin() * config.bot_radius;

    let own_ground = finite_or(ground(state.x, state.z), state.y);
    let target_ground = finite_or(ground(target_x, target_z), own_ground);
    let target_y = (target_ground + config.bot_altitude).min(own_ground + config.ceiling);

    let want_yaw = (-(target_z - state.z)).atan2(target_x - state.x);
    let error = wrap_angle(want_yaw - state.yaw);
    let turn_axis = (error * config.bot_yaw_gain).clamp(-1.0, 1.0);

    // The same sign as the player's controls: a positive move axis noses down,
    // so an altitude error above the target asks for a negative (nose-up) axis.
    let mut move_axis = (-(target_y - state.y) * config.bot_pitch_gain).clamp(-1.0, 1.0);

    let landing = context.landing || state.flight_time >= config.bot_time;
    if landing {
        move_axis = 1.0;
    }
    if state.y < own_ground + config.bot_terrain_guard {
        move_axis = -1.0;
    }

    let flap = !landing && state.y < target_y - config.bot_flap_below && state.flap_cool <= 0.0;

    BotControl {
        input: Input {
            move_axis,
            turn_axis,
            flap,
            release: false,
            energy: f32::INFINITY,
        },
        orbit_angle: angle,
    }
}

fn finite_or(value: f32, fallback: f32) -> f32 {
    if value.is_finite() { value } else { fallback }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DT: f32 = 1.0 / 60.0;

    fn flat(_x: f32, _z: f32) -> f32 {
        0.0
    }

    fn flying(y: f32) -> State {
        State {
            y,
            speed: 9.0,
            phase: Phase::Fly,
            ..State::default()
        }
    }

    #[test]
    fn the_ring_point_turns_the_bot() {
        let config = Config::default();
        let state = flying(10.0);
        let context = BotContext {
            player_x: 0.0,
            player_z: 0.0,
            orbit_angle: std::f32::consts::FRAC_PI_2,
            orbit_dir: 1.0,
            landing: false,
        };
        let control = bot_input(&config, &state, context, DT, flat);
        // The ring point is (0, -18), so the bot must yaw left (positive).
        assert!(control.input.turn_axis > 0.9, "{:?}", control.input);
    }

    #[test]
    fn it_descends_when_the_time_is_up() {
        let config = Config::default();
        let mut state = flying(10.0);
        state.flight_time = config.bot_time + 1.0;
        let control = bot_input(&config, &state, BotContext::default(), DT, flat);
        assert!(control.input.move_axis > 0.9, "{:?}", control.input);
    }

    #[test]
    fn it_flaps_when_low() {
        let config = Config::default();
        let state = flying(6.0);
        let control = bot_input(&config, &state, BotContext::default(), DT, flat);
        assert!(control.input.flap);
    }

    #[test]
    fn it_noses_up_near_the_ground() {
        let config = Config::default();
        let state = flying(1.0);
        let control = bot_input(&config, &state, BotContext::default(), DT, |_, _| 0.0);
        assert!(control.input.move_axis < -0.9, "{:?}", control.input);
    }

    #[test]
    fn the_orbit_angle_advances() {
        let config = Config::default();
        let state = flying(10.0);
        let context = BotContext {
            orbit_angle: 0.0,
            orbit_dir: 1.0,
            ..BotContext::default()
        };
        let control = bot_input(&config, &state, context, DT, flat);
        assert!((control.orbit_angle - config.bot_turn * DT).abs() < 1e-5);
    }

    #[test]
    fn a_grounded_bot_gets_no_input() {
        let config = Config::default();
        let state = State::default();
        let control = bot_input(&config, &state, BotContext::default(), DT, flat);
        assert_eq!(control.input, Input::default());
        assert_eq!(control.orbit_angle, 0.0);
    }
}
