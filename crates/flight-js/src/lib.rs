//! The `__flight` global for the scene.
//!
//! A thin, flat-array binding over [`flight`]. The scene owns the numbers; this
//! module packs them into a [`State`]/[`Input`], calls the crate and unpacks the
//! result. Nothing here knows about raylib, the goat, the network or the mods.
//!
//! The layouts are deliberately positional and stable:
//!
//! ```text
//! state  [x, z, y, yaw, pitch, roll, speed, vy, flapCool, flaps, flightTime, phase]
//! input  [move, turn, flap, release, energy]
//! step   [state..., flapped, flapCost, drain, released, ceiling,
//!         landed, impact, damage]
//! start  [state..., energyCost]
//! bot    [move, turn, flap, release, orbitAngle]
//! ```
//!
//! `phase` is 0 grounded, 1 fly, 2 fall. Floats are `f32` on the Rust side and
//! convert at the boundary; the scene's numbers are f64, and the wire quantizes
//! anyway.

use std::cell::RefCell;
use std::rc::Rc;

use flight::{BotContext, Config, Input, Phase, State};
use slag::{Context, FunctionCall, JsError, JsObject, JsValue};

const STATE_LEN: usize = 12;

/// Install `__flight` into a context, before the scene is evaluated.
///
/// This is the same seam `android::install`/`web::install` use: a native object
/// with functions, set as a global. The client, the headless server and the
/// harness each call it once.
pub fn install(context: &mut Context) {
    let config = Rc::new(RefCell::new(Config::default()));
    let surface = context.create_object().expect("the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "configure",
            context
                .create_function(
                    "configure",
                    1,
                    Box::new(move |call| {
                        if let Some(object) = call.arg(0).and_then(|value| value.as_object()) {
                            let mut config = cell.borrow_mut();
                            apply_config(&mut config, &object);
                            config.validate();
                        }
                        Ok(JsValue::undefined())
                    }),
                )
                .expect("configure"),
        )
        .expect("configure on the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "step",
            context
                .create_function(
                    "step",
                    4,
                    Box::new(move |call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let input = read_input(call.arg(1));
                        let dt = call
                            .arg(2)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let ground = call.arg(3).unwrap_or(JsValue::undefined());
                        let config = *cell.borrow();
                        let outcome = flight::step(&config, state, input, dt, |x, z| {
                            ground_at(call, &ground, x, z)
                        });
                        write_outcome(call, &outcome)
                    }),
                )
                .expect("step"),
        )
        .expect("step on the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "start",
            context
                .create_function(
                    "start",
                    2,
                    Box::new(move |call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let speed = call
                            .arg(1)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let config = *cell.borrow();
                        write_start(call, &flight::start(&config, state, speed))
                    }),
                )
                .expect("start"),
        )
        .expect("start on the flight object");

    surface
        .set(
            "release",
            context
                .create_function(
                    "release",
                    1,
                    Box::new(|call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        write_state_only(call, &flight::release(state))
                    }),
                )
                .expect("release"),
        )
        .expect("release on the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "fallDamage",
            context
                .create_function(
                    "fallDamage",
                    1,
                    Box::new(move |call| {
                        let impact = call
                            .arg(0)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let config = *cell.borrow();
                        Ok(JsValue::number(config.fall_damage(impact) as f64))
                    }),
                )
                .expect("fallDamage"),
        )
        .expect("fallDamage on the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "applyFallDamage",
            context
                .create_function(
                    "applyFallDamage",
                    2,
                    Box::new(move |call| {
                        let health = call
                            .arg(0)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let impact = call
                            .arg(1)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let config = *cell.borrow();
                        Ok(JsValue::number(
                            config.apply_fall_damage(health, impact) as f64
                        ))
                    }),
                )
                .expect("applyFallDamage"),
        )
        .expect("applyFallDamage on the flight object");

    let cell = Rc::clone(&config);
    surface
        .set(
            "botInput",
            context
                .create_function(
                    "botInput",
                    4,
                    Box::new(move |call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let context = read_bot_context(call.arg(1));
                        let dt = call
                            .arg(2)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let ground = call.arg(3).unwrap_or(JsValue::undefined());
                        let config = *cell.borrow();
                        let control = flight::bot_input(&config, &state, context, dt, |x, z| {
                            ground_at(call, &ground, x, z)
                        });
                        call.create_array(&[
                            JsValue::number(control.input.move_axis as f64),
                            JsValue::number(control.input.turn_axis as f64),
                            JsValue::boolean(control.input.flap),
                            JsValue::boolean(control.input.release),
                            JsValue::number(control.orbit_angle as f64),
                        ])
                    }),
                )
                .expect("botInput"),
        )
        .expect("botInput on the flight object");

    surface
        .set(
            "pose",
            context
                .create_function(
                    "pose",
                    1,
                    Box::new(|call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let q = flight::pose(&state);
                        call.create_array(&[
                            JsValue::number(q.x as f64),
                            JsValue::number(q.y as f64),
                            JsValue::number(q.z as f64),
                            JsValue::number(q.w as f64),
                        ])
                    }),
                )
                .expect("pose"),
        )
        .expect("pose on the flight object");

    surface
        .set(
            "axisAngle",
            context
                .create_function(
                    "axisAngle",
                    1,
                    Box::new(|call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let aa = flight::axis_angle(flight::pose(&state));
                        call.create_array(&[
                            JsValue::number(aa.x as f64),
                            JsValue::number(aa.y as f64),
                            JsValue::number(aa.z as f64),
                            JsValue::number(aa.rad as f64),
                        ])
                    }),
                )
                .expect("axisAngle"),
        )
        .expect("axisAngle on the flight object");

    surface
        .set(
            "backPoint",
            context
                .create_function(
                    "backPoint",
                    3,
                    Box::new(|call| {
                        let Some(state) = read_state(call.arg(0)) else {
                            return Ok(JsValue::undefined());
                        };
                        let perch = call
                            .arg(1)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let pivot = call
                            .arg(2)
                            .and_then(|value| value.as_number())
                            .unwrap_or(0.0) as f32;
                        let p = flight::back_point(&state, perch, pivot);
                        call.create_array(&[
                            JsValue::number(p[0] as f64),
                            JsValue::number(p[1] as f64),
                            JsValue::number(p[2] as f64),
                        ])
                    }),
                )
                .expect("backPoint"),
        )
        .expect("backPoint on the flight object");

    context
        .set_global("__flight", surface.as_value())
        .expect("the __flight global");
}

fn ground_at(call: &FunctionCall<'_>, ground: &JsValue, x: f32, z: f32) -> f32 {
    call.call(
        ground,
        &JsValue::undefined(),
        &[JsValue::number(x as f64), JsValue::number(z as f64)],
    )
    .ok()
    .and_then(|value| value.as_number())
    .unwrap_or(0.0) as f32
}

fn read_state(value: Option<JsValue>) -> Option<State> {
    let object = value?.as_object()?;
    let mut values = [0.0f32; STATE_LEN];
    for (index, slot) in values.iter_mut().enumerate() {
        *slot = number_at(&object, index)?;
    }
    Some(State {
        x: values[0],
        z: values[1],
        y: values[2],
        yaw: values[3],
        pitch: values[4],
        roll: values[5],
        speed: values[6],
        vy: values[7],
        flap_cool: values[8],
        flaps: values[9].max(0.0) as u32,
        flight_time: values[10],
        phase: match values[11] as i32 {
            1 => Phase::Fly,
            2 => Phase::Fall,
            _ => Phase::Grounded,
        },
    })
}

fn read_input(value: Option<JsValue>) -> Input {
    let Some(object) = value.and_then(|value| value.as_object()) else {
        return Input::default();
    };
    Input {
        move_axis: number_at(&object, 0).unwrap_or(0.0),
        turn_axis: number_at(&object, 1).unwrap_or(0.0),
        flap: number_at(&object, 2).unwrap_or(0.0) != 0.0,
        release: number_at(&object, 3).unwrap_or(0.0) != 0.0,
        energy: number_at(&object, 4).unwrap_or(f32::INFINITY),
    }
}

fn read_bot_context(value: Option<JsValue>) -> BotContext {
    let Some(object) = value.and_then(|value| value.as_object()) else {
        return BotContext::default();
    };
    BotContext {
        player_x: number_at(&object, 0).unwrap_or(0.0),
        player_z: number_at(&object, 1).unwrap_or(0.0),
        orbit_angle: number_at(&object, 2).unwrap_or(0.0),
        orbit_dir: number_at(&object, 3).unwrap_or(1.0),
        landing: number_at(&object, 4).unwrap_or(0.0) != 0.0,
    }
}

fn number_at(object: &JsObject, index: usize) -> Option<f32> {
    object
        .get(&index.to_string())
        .ok()?
        .as_number()
        .map(|number| number as f32)
}

fn state_values(state: &State) -> Vec<JsValue> {
    vec![
        JsValue::number(state.x as f64),
        JsValue::number(state.z as f64),
        JsValue::number(state.y as f64),
        JsValue::number(state.yaw as f64),
        JsValue::number(state.pitch as f64),
        JsValue::number(state.roll as f64),
        JsValue::number(state.speed as f64),
        JsValue::number(state.vy as f64),
        JsValue::number(state.flap_cool as f64),
        JsValue::number(state.flaps as f64),
        JsValue::number(state.flight_time as f64),
        JsValue::number(phase_number(state.phase)),
    ]
}

fn phase_number(phase: Phase) -> f64 {
    match phase {
        Phase::Grounded => 0.0,
        Phase::Fly => 1.0,
        Phase::Fall => 2.0,
    }
}

fn write_outcome(call: &FunctionCall<'_>, outcome: &flight::Outcome) -> Result<JsValue, JsError> {
    let mut out = state_values(&outcome.state);
    out.push(JsValue::boolean(outcome.events.flapped));
    out.push(JsValue::number(outcome.events.flap_cost as f64));
    out.push(JsValue::number(outcome.events.drain as f64));
    out.push(JsValue::boolean(outcome.events.released));
    out.push(JsValue::boolean(outcome.events.ceiling));
    out.push(JsValue::boolean(outcome.events.landed.is_some()));
    let (impact, damage) = outcome
        .events
        .landed
        .map(|landing| (landing.impact, landing.damage))
        .unwrap_or((0.0, 0.0));
    out.push(JsValue::number(impact as f64));
    out.push(JsValue::number(damage as f64));
    call.create_array(&out)
}

fn write_start(call: &FunctionCall<'_>, started: &flight::Start) -> Result<JsValue, JsError> {
    let mut out = state_values(&started.state);
    out.push(JsValue::number(started.energy_cost as f64));
    call.create_array(&out)
}

fn write_state_only(call: &FunctionCall<'_>, state: &State) -> Result<JsValue, JsError> {
    call.create_array(&state_values(state))
}

fn apply_config(config: &mut Config, object: &JsObject) {
    set(object, "maxDt", &mut config.max_dt);
    set(object, "restHeight", &mut config.rest_height);
    set(object, "bodyPivot", &mut config.body_pivot);
    set(object, "takeoffLift", &mut config.takeoff_lift);
    set(object, "takeoffPitch", &mut config.takeoff_pitch);
    set(object, "takeoffEnergy", &mut config.takeoff_energy);
    set(object, "speed", &mut config.speed);
    set(object, "minSpeed", &mut config.min_speed);
    set(object, "maxSpeed", &mut config.max_speed);
    set(object, "speedResponse", &mut config.speed_response);
    set(object, "pitchMax", &mut config.pitch_max);
    set(object, "pitchRate", &mut config.pitch_rate);
    set(object, "bankMax", &mut config.bank_max);
    set(object, "bankRate", &mut config.bank_rate);
    set(object, "turnRate", &mut config.turn_rate);
    set(object, "sink", &mut config.sink);
    set(object, "climbGain", &mut config.climb_gain);
    set(object, "vyResponse", &mut config.vy_response);
    set(object, "flapLift", &mut config.flap_lift);
    set(object, "flapSpeed", &mut config.flap_speed);
    set(object, "flapCooldown", &mut config.flap_cooldown);
    set(object, "flapEnergy", &mut config.flap_energy);
    set(object, "drainFly", &mut config.drain_fly);
    set(object, "ceiling", &mut config.ceiling);
    set(object, "gravity", &mut config.gravity);
    set(object, "safeFall", &mut config.safe_fall);
    set(object, "fallDamage", &mut config.fall_damage);
    set(object, "fallHealthFloor", &mut config.fall_health_floor);
    set(object, "fallPitchGain", &mut config.fall_pitch_gain);
    set(object, "botAltitude", &mut config.bot_altitude);
    set(object, "botRadius", &mut config.bot_radius);
    set(object, "botTime", &mut config.bot_time);
    set(object, "botCooldown", &mut config.bot_cooldown);
    set(object, "botTurn", &mut config.bot_turn);
    set(object, "botYawGain", &mut config.bot_yaw_gain);
    set(object, "botPitchGain", &mut config.bot_pitch_gain);
    set(object, "botFlapBelow", &mut config.bot_flap_below);
    set(object, "botTerrainGuard", &mut config.bot_terrain_guard);
}

fn set(object: &JsObject, key: &str, slot: &mut f32) {
    if let Ok(value) = object.get(key)
        && let Some(number) = value.as_number()
    {
        *slot = number as f32;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn context() -> Context {
        let mut context = Context::new().expect("a Slag context");
        install(&mut context);
        context
    }

    fn number(array: &JsValue, index: usize) -> f64 {
        array
            .as_object()
            .and_then(|object| object.get(&index.to_string()).ok())
            .and_then(|value| value.as_number())
            .unwrap()
    }

    #[test]
    fn the_global_steps_a_flying_goat() {
        let mut context = context();
        let value = context
            .eval(
                r#"
                __flight.configure({ speed: 9, minSpeed: 5, maxSpeed: 14 });
                const state = [0, 0, 10, 0, 0, 0, 9, 0, 0, 0, 0, 1];
                const out = __flight.step(state, [0, 0, 0, 0, 100], 1 / 60, () => 0);
                out[11];
                "#,
            )
            .expect("the binding evaluates");
        assert_eq!(value.as_number(), Some(1.0));
    }

    #[test]
    fn the_ground_callback_is_used() {
        let mut context = context();
        let value = context
            .eval(
                r#"
                const state = [0, 0, 1, 0, 0, 0, 9, -10, 0, 0, 0, 2];
                const out = __flight.step(state, [0, 0, 0, 0, 100], 1 / 60, () => 5);
                out[17];
                "#,
            )
            .expect("the binding evaluates");
        assert_eq!(value.as_boolean(), Some(true));
    }

    #[test]
    fn the_pose_and_back_point_cross() {
        let mut context = context();
        let value = context
            .eval(
                r#"
                const state = [2, 4, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1];
                const q = __flight.pose(state);
                const p = __flight.backPoint(state, 1.15, 0.7);
                [q[0], q[1], q[2], q[3], p[0], p[1], p[2]];
                "#,
            )
            .expect("the binding evaluates");
        assert_eq!(number(&value, 3), 1.0);
        assert_eq!(number(&value, 4), 2.0);
        assert!((number(&value, 5) - 4.15).abs() < 1e-6);
        assert_eq!(number(&value, 6), 4.0);
    }

    #[test]
    fn a_start_costs_energy() {
        let mut context = context();
        let value = context
            .eval(
                r#"
                __flight.configure({ takeoffEnergy: 3.5 });
                const state = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
                const out = __flight.start(state, 9);
                out[12];
                "#,
            )
            .expect("the binding evaluates");
        assert_eq!(value.as_number(), Some(3.5));
    }
}
