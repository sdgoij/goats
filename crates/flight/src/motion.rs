//! The flight model: take-off, the powered step, release, the fall and landing.

use crate::{Config, Events, Input, Landing, Outcome, Phase, Start, State};

pub(crate) const TAU: f32 = std::f32::consts::TAU;
const PI: f32 = std::f32::consts::PI;

/// Whether a jump becomes a take-off.
///
/// The gameplay rule is a **running jump**: the goat is moving forward and its
/// gait is `run`. The crate takes the two facts rather than a gait string so the
/// clients keep their own vocabulary.
#[must_use]
pub fn can_take_off(capable: bool, running: bool, move_axis: f32) -> bool {
    capable && running && move_axis > 0.0
}

/// Begin powered flight from the state's current position and heading.
///
/// The caller sets `state.y` to the current absolute base (terrain + `py`) and
/// passes the horizontal speed the goat had at the jump. The state is returned in
/// `Phase::Fly`; `energy_cost` is the take-off's cost, which the caller subtracts.
#[must_use]
pub fn start(config: &Config, mut state: State, ground_speed: f32) -> Start {
    let speed = if ground_speed.is_finite() {
        ground_speed
    } else {
        config.min_speed
    };
    state.phase = Phase::Fly;
    state.speed = clamp_speed(config, speed);
    state.vy = config.takeoff_lift;
    state.pitch = config.takeoff_pitch;
    state.roll = 0.0;
    state.flap_cool = 0.0;
    state.flaps = 0;
    state.flight_time = 0.0;
    Start {
        state,
        energy_cost: config.takeoff_energy,
    }
}

/// End a flight into a free fall. A state that is not in `Fly` is returned as it
/// is, so a scripted double-release is harmless.
#[must_use]
pub fn release(mut state: State) -> State {
    if state.phase == Phase::Fly {
        state.phase = Phase::Fall;
        state.flight_time = 0.0;
    }
    state
}

/// Advance one frame.
///
/// `dt` is clamped to `config.max_dt`; a non-positive or non-finite `dt` and a
/// non-finite state are returned untouched. `ground(x, z)` is the scene's own
/// terrain height: the crate calls it at the position it moved to, so the
/// landing and the ceiling are the crate's rules rather than each client's.
///
/// A `Grounded` state is not stepped. The caller only calls this while flying or
/// falling.
#[must_use]
pub fn step<G>(config: &Config, mut state: State, input: Input, dt: f32, ground: G) -> Outcome
where
    G: Fn(f32, f32) -> f32,
{
    let mut events = Events::default();
    if !dt.is_finite() || dt <= 0.0 || !state.is_finite() {
        return Outcome { state, events };
    }
    let dt = dt.min(config.max_dt);

    match state.phase {
        Phase::Grounded => {}
        Phase::Fly => {
            events.drain = config.drain_fly * dt;
            if input.release {
                state.phase = Phase::Fall;
                state.flight_time = 0.0;
                events.released = true;
            } else {
                step_fly(config, &mut state, input, dt, &mut events, &ground);
            }
        }
        Phase::Fall => step_fall(config, &mut state, dt, &mut events, &ground),
    }

    Outcome { state, events }
}

fn step_fly<G>(
    config: &Config,
    state: &mut State,
    input: Input,
    dt: f32,
    events: &mut Events,
    ground: &G,
) where
    G: Fn(f32, f32) -> f32,
{
    state.flap_cool = (state.flap_cool - dt).max(0.0);

    // W (+1) noses down, S (-1) noses up; A (+1) banks left, D (-1) banks
    // right. `roll` positive is a right bank, hence the negation.
    let move_axis = axis(input.move_axis);
    let turn_axis = axis(input.turn_axis);
    let target_pitch = -move_axis * config.pitch_max;
    let target_roll = -turn_axis * config.bank_max;
    state.pitch = approach(state.pitch, target_pitch, config.pitch_rate * dt);
    state.roll = approach(state.roll, target_roll, config.bank_rate * dt);

    // A right bank lowers yaw, a left bank raises it.
    if config.bank_max > 1e-6 {
        let speed_frac = if config.speed > 1e-6 {
            (state.speed / config.speed).clamp(0.5, 1.5)
        } else {
            1.0
        };
        state.yaw += -(state.roll / config.bank_max) * config.turn_rate * speed_frac * dt;
    }

    state.speed += (config.speed - state.speed) * (dt * config.speed_response).min(1.0);
    state.speed = clamp_speed(config, state.speed);

    let target_vy = state.speed * state.pitch.sin() * config.climb_gain - config.sink;
    state.vy += (target_vy - state.vy) * (dt * config.vy_response).min(1.0);

    if input.flap && state.flap_cool <= 0.0 && input.energy >= config.flap_energy {
        state.vy += config.flap_lift;
        state.speed = clamp_speed(config, state.speed + config.flap_speed);
        state.flap_cool = config.flap_cooldown;
        state.flaps = state.flaps.saturating_add(1);
        events.flapped = true;
        events.flap_cost = config.flap_energy;
    }

    state.flight_time += dt;
    state.x += state.yaw.cos() * state.speed * dt;
    state.z -= state.yaw.sin() * state.speed * dt;
    state.y += state.vy * dt;

    let ground_y = ground(state.x, state.z);
    if ground_y.is_finite() {
        let top = ground_y + config.ceiling;
        if state.y > top {
            state.y = top;
            if state.vy > 0.0 {
                state.vy = 0.0;
                events.ceiling = true;
            }
        }
        resolve_ground(config, state, events, ground_y);
    }
}

fn step_fall<G>(config: &Config, state: &mut State, dt: f32, events: &mut Events, ground: &G)
where
    G: Fn(f32, f32) -> f32,
{
    state.vy += config.gravity * dt;
    state.x += state.yaw.cos() * state.speed * dt;
    state.z -= state.yaw.sin() * state.speed * dt;
    state.y += state.vy * dt;
    state.flight_time += dt;

    // Nose down with the fall. The clamp is symmetric because a release while
    // still climbing starts with a positive `vy`.
    state.pitch = (state.vy * config.fall_pitch_gain).clamp(-config.pitch_max, config.pitch_max);
    state.roll = approach(state.roll, 0.0, config.bank_rate * dt);

    let ground_y = ground(state.x, state.z);
    if ground_y.is_finite() {
        resolve_ground(config, state, events, ground_y);
    }
}

/// The ground rule shared by flight and fall.
///
/// A climb never sinks below the surface; a descent that reaches it lands. The
/// take-off frame sits exactly on the floor with a positive `vy`, which is why
/// the landing needs the `vy <= 0` half.
fn resolve_ground(config: &Config, state: &mut State, events: &mut Events, ground_y: f32) {
    let floor = ground_y + config.rest_height;
    if state.y < floor {
        state.y = floor;
    }
    if state.y <= floor && state.vy <= 0.0 {
        let impact = (-state.vy).max(0.0);
        state.y = floor;
        state.vy = 0.0;
        state.speed = 0.0;
        state.pitch = 0.0;
        state.roll = 0.0;
        state.flap_cool = 0.0;
        state.flight_time = 0.0;
        state.flaps = 0;
        state.phase = Phase::Grounded;
        events.landed = Some(Landing {
            impact,
            damage: config.fall_damage(impact),
        });
    }
}

fn axis(value: f32) -> f32 {
    if value.is_finite() {
        value.clamp(-1.0, 1.0)
    } else {
        0.0
    }
}

fn approach(value: f32, target: f32, max_delta: f32) -> f32 {
    if !value.is_finite() {
        return target;
    }
    let limit = if max_delta.is_finite() {
        max_delta.abs()
    } else {
        0.0
    };
    value + (target - value).clamp(-limit, limit)
}

fn clamp_speed(config: &Config, speed: f32) -> f32 {
    let a = if config.min_speed.is_finite() {
        config.min_speed
    } else {
        0.0
    };
    let b = if config.max_speed.is_finite() {
        config.max_speed
    } else {
        a
    };
    let lo = a.min(b);
    let hi = a.max(b);
    if speed.is_finite() {
        speed.clamp(lo, hi)
    } else {
        lo
    }
}

/// Shorten `angle` into `[-π, π)`. The bot autopilot uses it for yaw error; the
/// flight leaves yaw unbounded, as the scene's own turns do.
pub(crate) fn wrap_angle(angle: f32) -> f32 {
    if !angle.is_finite() {
        return 0.0;
    }
    angle - TAU * ((angle + PI) / TAU).floor()
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
            x: 0.0,
            z: 0.0,
            y,
            speed: 9.0,
            phase: Phase::Fly,
            ..State::default()
        }
    }

    #[test]
    fn take_off_is_a_running_jump() {
        assert!(can_take_off(true, true, 1.0));
        assert!(!can_take_off(false, true, 1.0));
        assert!(!can_take_off(true, false, 1.0));
        assert!(!can_take_off(true, true, 0.0));
        assert!(!can_take_off(true, true, -1.0));
    }

    #[test]
    fn start_sets_the_flight_and_its_cost() {
        let config = Config::default();
        let started = start(&config, flying(10.0), 3.0);
        assert_eq!(started.state.phase, Phase::Fly);
        assert_eq!(started.state.speed, config.min_speed);
        assert_eq!(started.state.vy, config.takeoff_lift);
        assert_eq!(started.state.pitch, config.takeoff_pitch);
        assert_eq!(started.energy_cost, config.takeoff_energy);
    }

    #[test]
    fn level_flight_sinks() {
        let config = Config::default();
        let mut state = flying(10.0);
        for _ in 0..60 {
            state = step(&config, state, Input::default(), DT, flat).state;
        }
        assert!(state.phase == Phase::Fly);
        assert!(state.vy < -0.5, "vy was {}", state.vy);
        assert!(state.y < 10.0, "y was {}", state.y);
    }

    #[test]
    fn s_pitches_up_and_climbs() {
        let config = Config::default();
        let mut state = flying(10.0);
        let input = Input {
            move_axis: -1.0,
            ..Input::default()
        };
        for _ in 0..120 {
            state = step(&config, state, input, DT, flat).state;
        }
        assert!(state.pitch > 0.4, "pitch was {}", state.pitch);
        assert!(state.y > 10.5, "y was {}", state.y);
    }

    #[test]
    fn w_pitches_down() {
        let config = Config::default();
        let mut state = flying(10.0);
        let input = Input {
            move_axis: 1.0,
            ..Input::default()
        };
        for _ in 0..60 {
            state = step(&config, state, input, DT, flat).state;
        }
        assert!(state.pitch < -0.4, "pitch was {}", state.pitch);
    }

    #[test]
    fn a_banks_left_and_raises_yaw() {
        let config = Config::default();
        let mut state = flying(10.0);
        let input = Input {
            turn_axis: 1.0,
            ..Input::default()
        };
        for _ in 0..60 {
            state = step(&config, state, input, DT, flat).state;
        }
        assert!(state.roll < -0.4, "roll was {}", state.roll);
        assert!(state.yaw > 0.3, "yaw was {}", state.yaw);
    }

    #[test]
    fn d_banks_right_and_lowers_yaw() {
        let config = Config::default();
        let mut state = flying(10.0);
        let input = Input {
            turn_axis: -1.0,
            ..Input::default()
        };
        for _ in 0..60 {
            state = step(&config, state, input, DT, flat).state;
        }
        assert!(state.roll > 0.4, "roll was {}", state.roll);
        assert!(state.yaw < -0.3, "yaw was {}", state.yaw);
    }

    #[test]
    fn a_flap_lifts_and_has_a_cooldown() {
        let config = Config::default();
        let state = flying(10.0);
        let input = Input {
            flap: true,
            energy: 100.0,
            ..Input::default()
        };
        let first = step(&config, state, input, DT, flat);
        assert!(first.events.flapped);
        assert_eq!(first.events.flap_cost, config.flap_energy);
        assert_eq!(first.state.flaps, 1);
        assert!(first.state.flap_cool > 0.0);
        assert!(first.state.vy > 0.0, "vy was {}", first.state.vy);

        let second = step(&config, first.state, input, DT, flat);
        assert!(!second.events.flapped);
        assert_eq!(second.state.flaps, 1);
    }

    #[test]
    fn a_flap_needs_energy() {
        let config = Config::default();
        let input = Input {
            flap: true,
            energy: config.flap_energy - 0.01,
            ..Input::default()
        };
        let out = step(&config, flying(10.0), input, DT, flat);
        assert!(!out.events.flapped);
        assert_eq!(out.state.flaps, 0);
    }

    #[test]
    fn release_enters_the_fall_and_lands() {
        let config = Config::default();
        let mut state = flying(20.0);
        let input = Input {
            release: true,
            ..Input::default()
        };
        let released = step(&config, state, input, DT, flat);
        assert_eq!(released.state.phase, Phase::Fall);
        assert!(released.events.released);
        assert!(released.events.drain > 0.0);
        state = released.state;

        let mut landing = None;
        for _ in 0..600 {
            let out = step(&config, state, Input::default(), DT, flat);
            state = out.state;
            if let Some(hit) = out.events.landed {
                landing = Some(hit);
                break;
            }
        }
        let hit = landing.expect("the fall must land");
        assert_eq!(state.phase, Phase::Grounded);
        assert!(hit.impact > config.safe_fall);
        assert!(hit.damage > 0.0);
    }

    #[test]
    fn a_gentle_landing_does_no_damage() {
        let config = Config::default();
        let state = State {
            y: 0.05,
            vy: -1.0,
            phase: Phase::Fall,
            ..State::default()
        };
        let mut state = state;
        let mut landing = None;
        for _ in 0..60 {
            let out = step(&config, state, Input::default(), DT, flat);
            state = out.state;
            if let Some(hit) = out.events.landed {
                landing = Some(hit);
                break;
            }
        }
        let hit = landing.expect("the fall must land");
        assert_eq!(hit.damage, 0.0);
        assert!(hit.impact <= config.safe_fall);
    }

    #[test]
    fn the_rest_height_is_the_floor() {
        let config = Config {
            rest_height: -0.08,
            ..Config::default()
        };
        let state = State {
            y: -0.09,
            vy: -1.0,
            phase: Phase::Fall,
            ..State::default()
        };
        let out = step(&config, state, Input::default(), DT, flat);
        assert!(out.events.landed.is_some());
        assert!((out.state.y - -0.08).abs() < 1e-6);
    }

    #[test]
    fn the_ceiling_clamps_a_climb() {
        let config = Config {
            ceiling: 5.0,
            ..Config::default()
        };
        let mut state = flying(4.99);
        state.vy = 2.0;
        let out = step(&config, state, Input::default(), DT, flat);
        assert!(out.events.ceiling);
        assert!(out.state.y <= 5.0 + 1e-6);
        assert!(out.state.vy <= 0.0);
    }

    #[test]
    fn a_non_finite_state_is_returned_untouched() {
        let config = Config::default();
        let mut state = flying(10.0);
        state.x = f32::NAN;
        let out = step(&config, state, Input::default(), DT, flat);
        assert!(out.state.x.is_nan());
        assert!(out.events.landed.is_none());
    }

    #[test]
    fn a_thousand_random_frames_stay_finite() {
        let config = Config::default();
        let mut seed = 0x1234_5678u32;
        let mut state = flying(30.0);
        for _ in 0..1000 {
            let input = Input {
                move_axis: rnd(&mut seed) * 4.0 - 2.0,
                turn_axis: rnd(&mut seed) * 4.0 - 2.0,
                flap: rnd(&mut seed) > 0.7,
                release: rnd(&mut seed) > 0.98,
                energy: rnd(&mut seed) * 100.0,
            };
            let out = step(&config, state, input, DT, |x, z| {
                (x * 0.1).sin() + (z * 0.1).cos()
            });
            assert!(out.state.is_finite(), "frame left a non-finite state");
            state = out.state;
            if state.phase == Phase::Grounded {
                state = flying(30.0);
            }
        }
    }

    fn rnd(seed: &mut u32) -> f32 {
        *seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        (*seed >> 8) as f32 / 16_777_216.0
    }

    #[test]
    fn wrap_angle_shortens_the_error() {
        assert!((wrap_angle(0.1) - 0.1).abs() < 1e-6);
        assert!((wrap_angle(TAU - 0.1) + 0.1).abs() < 1e-5);
        assert!((wrap_angle(-TAU + 0.1) - 0.1).abs() < 1e-5);
    }
}
