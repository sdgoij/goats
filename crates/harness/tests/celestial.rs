//! The sun and the moon as geometry, which is the part of them a test can hold.
//!
//! They used to be a stack of camera-facing sprites placed in the plane `z =
//! goat.pz` at 70 units, drawn while their elevation was within a quarter of the
//! horizon. So the sky shader's halo -- which follows `LIGHT_DIR`, tilt and all --
//! sat about ten degrees off the disc it belonged to, the clouds were lit from a
//! direction no disc was in, and each body was drawn for an hour and a half
//! *below* the horizon, where the terrain slab ends and a disc hangs in the void
//! under the world. They are spheres on the light's own line now, hidden once they
//! are down (`crates/goats/src/game/world.js`, `lighting.js`).
//!
//! `sceneCelestial` reports what the draw uses, so these checks read the numbers
//! the frame does. A world has to be loaded for the bodies and their program to
//! exist; after that the clock and the light are driven straight, with no frames in
//! between, because `updateLight` is the whole of the coupling.
//!
//! The geometry is not the whole of it: where the bodies are drawn *relative to the
//! clouds* is a fact about one frame's order, so the second case reads that instead
//! (the stub's `layers`).
//!
//! ```text
//! cargo test --release -p harness --test celestial -- --nocapture
//! ```

mod support;

use harness::Harness;
use serde_json::Value;
use support::Checks;

/// Long enough to walk the load steps: the sky's textures, the two spheres, the
/// terrain, the shaders and the herd.
const FRAMES: u32 = 30;

/// The clock the sweep walks, in hours: midnight, the dark before dawn, sunrise
/// either side of it, the hour the light changes hands (twice), morning, noon,
/// mid-afternoon, the hour the old moon gate opened, dusk, and night.
const HOURS: [f64; 12] = [
    0.5, 5.0, 5.8, 5.95, 6.4, 9.0, 12.0, 16.0, 17.6, 17.95, 18.9, 22.0,
];

/// One body, as `sceneCelestial` reports it.
struct Body {
    x: f64,
    y: f64,
    z: f64,
    elevation: f64,
    alpha: f64,
}

impl Body {
    fn of(snapshot: &Value, name: &str) -> Body {
        let body = &snapshot[name];
        Body {
            x: at(body, "x"),
            y: at(body, "y"),
            z: at(body, "z"),
            elevation: at(body, "elevation"),
            alpha: at(body, "alpha"),
        }
    }
}

/// The whole picture at one hour.
struct Sky {
    sun: Body,
    moon: Body,
    goat_x: f64,
    goat_z: f64,
    radius: f64,
    sun_dot: f64,
    sun_dir: [f64; 3],
    light_y: f64,
    meshes_ok: bool,
    shaded: bool,
}

impl Sky {
    fn take(harness: &mut Harness, hour: f64) -> Sky {
        harness
            .eval(&format!("worldTime = {hour}"))
            .expect("set the clock");
        harness.call("updateLight", &[]).expect("updateLight");
        let s = harness.call("sceneCelestial", &[]).expect("sceneCelestial");
        Sky {
            sun: Body::of(&s, "sun"),
            moon: Body::of(&s, "moon"),
            goat_x: num(&s["goat"], 0),
            goat_z: num(&s["goat"], 1),
            radius: at(&s, "radius"),
            sun_dot: at(&s, "sunDot"),
            sun_dir: [
                num(&s["sunDir"], 0),
                num(&s["sunDir"], 1),
                num(&s["sunDir"], 2),
            ],
            light_y: num(&s["light"], 1),
            meshes_ok: s["meshes"][0].as_i64().unwrap_or(-1) >= 0
                && s["meshes"][1].as_i64().unwrap_or(-1) >= 0,
            shaded: s["shaded"].as_bool() == Some(true),
        }
    }

    /// Whether each body is where its direction says, one radius out, in all three
    /// axes -- the sun on `sunDir` and the moon on its negation.
    fn on_the_line(&self) -> bool {
        let sx = self.sun.x - self.goat_x;
        let sz = self.sun.z - self.goat_z;
        let reach = (sx * sx + self.sun.y * self.sun.y + sz * sz).sqrt();
        (sx - self.sun_dir[0] * self.radius).abs() < 1e-6
            && (sz - self.sun_dir[2] * self.radius).abs() < 1e-6
            && (reach - self.radius).abs() < 1e-6
            && (self.moon.x - self.goat_x + sx).abs() < 1e-6
            && (self.moon.y + self.sun.y).abs() < 1e-6
            && (self.moon.z - self.goat_z + sz).abs() < 1e-6
    }
}

fn at(value: &Value, name: &str) -> f64 {
    value[name].as_f64().unwrap_or(f64::NAN)
}

fn num(value: &Value, index: usize) -> f64 {
    value[index].as_f64().unwrap_or(f64::NAN)
}

/// The handles of the two bodies, as `sceneCelestial` reports them.
fn celestial_meshes(harness: &mut Harness) -> Vec<i64> {
    harness.call("sceneCelestial", &[]).expect("sceneCelestial")["meshes"]
        .as_array()
        .map(|meshes| meshes.iter().filter_map(|m| m.as_i64()).collect())
        .unwrap_or_default()
}

/// Where in the last frame's order each draw of a kind happened. An empty `handles`
/// matches any.
fn rows_of(layers: &[[i64; 3]], kind: i64, handles: &[i64]) -> Vec<usize> {
    layers
        .iter()
        .enumerate()
        .filter(|(_, row)| row[0] == kind && (handles.is_empty() || handles.contains(&row[1])))
        .map(|(position, _)| position)
        .collect()
}

#[test]
fn the_sun_and_moon_sit_on_the_light() {
    let mut checks = Checks::new();
    let mut harness = Harness::start().expect("evaluate the scene");
    let obs = harness.run(FRAMES).expect("run the scene");
    harness.eval("cloudiness = 0").expect("a clear sky");

    // The spheres are on their own program, not the scene's lit one: a body drawn
    // through that would be shaded by the *scene's* light and carry its shadow-map
    // uniforms. The stub names the celestial program 8 (its fragment shader declares
    // `shaded`); `lighting.js` compiles it and routes the two meshes to it.
    let meshes: Vec<i64> = harness.call("sceneCelestial", &[]).expect("sceneCelestial")["meshes"]
        .as_array()
        .map(|list| list.iter().filter_map(|m| m.as_i64()).collect())
        .unwrap_or_default();
    checks.check(
        "the spheres are routed to the celestial program",
        meshes.len() == 2
            && obs
                .model_shader_routes
                .iter()
                .filter(|row| row.first().copied().is_some_and(|h| meshes.contains(&h)))
                .all(|row| row.get(1).copied() == Some(8)),
        &obs.model_shader_routes,
    );

    let mut structure = String::new();
    let mut worst_dot = (0.0f64, 0.0f64);
    let mut off_line = (0.0f64, String::new());
    let mut drawn_down = (0.0f64, String::new());
    let mut dim_up = (0.0f64, String::new());
    let mut wrong_light = (0.0f64, String::new());
    let mut no_tilt = (0.0f64, String::new());

    for hour in HOURS {
        let sky = Sky::take(&mut harness, hour);
        if !sky.meshes_ok || !sky.shaded {
            structure = format!("{hour}h: meshes {:?} shaded {}", sky.meshes_ok, sky.shaded);
        }

        // The scene's light is exactly one of the two bodies. This is what the old
        // sprite placement failed: its discs carried no tilt, so the halo and the
        // clouds were lit from a direction no disc was in.
        let dot_err = (sky.sun_dot.abs() - 1.0).abs();
        if dot_err >= worst_dot.0 {
            worst_dot = (dot_err, hour);
        }

        if !sky.on_the_line() && off_line.1.is_empty() {
            off_line = (
                hour,
                format!(
                    "sun ({:.3},{:.3},{:.3}) dir ({:.3},{:.3},{:.3}) r {:.1} dot {:.4}",
                    sky.sun.x,
                    sky.sun.y,
                    sky.sun.z,
                    sky.sun_dir[0],
                    sky.sun_dir[1],
                    sky.sun_dir[2],
                    sky.radius,
                    sky.sun_dot
                ),
            );
        }

        // The glitch this replaces: a body below the horizon was still drawn, and
        // with the terrain slab ending 35 units out it hung in the void under the
        // world rather than setting.
        if ((sky.sun.elevation > 0.0) != (sky.sun.alpha > 0.0)
            || (sky.moon.elevation > 0.0) != (sky.moon.alpha > 0.0))
            && drawn_down.1.is_empty()
        {
            drawn_down = (
                hour,
                format!(
                    "sun elev {:.3} alpha {} moon elev {:.3} alpha {}",
                    sky.sun.elevation, sky.sun.alpha, sky.moon.elevation, sky.moon.alpha
                ),
            );
        }

        // A body well up -- past the fade band -- is drawn at full opacity.
        if ((sky.sun.elevation >= 0.1 && sky.sun.alpha != 255.0)
            || (sky.moon.elevation >= 0.1 && sky.moon.alpha != 255.0))
            && dim_up.1.is_empty()
        {
            dim_up = (
                hour,
                format!("sun {} moon {}", sky.sun.alpha, sky.moon.alpha),
            );
        }

        // ...and the light comes from whichever body is up: its elevation is that of
        // the body above the horizon. The hours just past the horizon are in the sweep
        // for this one -- a threshold above zero had the light come from a body that
        // was still down while the other was still drawn.
        let up = sky.sun.elevation.max(sky.moon.elevation);
        if ((sky.light_y - up).abs() > 1e-6 || sky.light_y < 0.0) && wrong_light.1.is_empty() {
            wrong_light = (
                hour,
                format!(
                    "light.y {:.4}, bodies up {:.4} / {:.4}",
                    sky.light_y, sky.sun.elevation, sky.moon.elevation
                ),
            );
        }

        // The tilt is in the drawn position, not only in the light: the bodies are
        // off the `z = goat.pz` plane the sprites were pinned to.
        let tilt = sky.sun_dir[2];
        if (tilt < 0.1 || (sky.sun.z - sky.goat_z).abs() < 1.0) && no_tilt.1.is_empty() {
            no_tilt = (
                hour,
                format!(
                    "sunDir.z {:.3}, sun.z - goat.z {:.3}",
                    tilt,
                    sky.sun.z - sky.goat_z
                ),
            );
        }
    }

    checks.check(
        "the bodies are meshes with their own program",
        structure.is_empty(),
        &structure,
    );
    checks.check(
        "the light is exactly one of the two bodies",
        worst_dot.0 < 0.0001,
        worst_dot,
    );
    checks.check(
        "each body sits along its direction, one radius out, in three axes",
        off_line.1.is_empty(),
        &off_line,
    );
    checks.check(
        "a body above the horizon is drawn and one below it is not",
        drawn_down.1.is_empty(),
        &drawn_down,
    );
    checks.check(
        "...at full opacity, once it is clear of the horizon fade",
        dim_up.1.is_empty(),
        &dim_up,
    );
    checks.check(
        "the light comes from whichever of them is up",
        wrong_light.1.is_empty(),
        &wrong_light,
    );
    checks.check(
        "the arc's tilt is in the drawn position, not only in the light",
        no_tilt.1.is_empty(),
        &no_tilt,
    );

    // The named ends of the cycle.
    let noon = Sky::take(&mut harness, 12.0);
    checks.check(
        "at noon the sun is high and the moon is down",
        noon.sun.elevation > 0.9 && noon.moon.alpha == 0.0,
        format!(
            "sun {:.3} moon alpha {}",
            noon.sun.elevation, noon.moon.alpha
        ),
    );
    let midnight = Sky::take(&mut harness, 0.0);
    checks.check(
        "at midnight the moon is high and the sun is down",
        midnight.moon.elevation > 0.9 && midnight.sun.alpha == 0.0,
        format!(
            "moon {:.3} sun alpha {}",
            midnight.moon.elevation, midnight.sun.alpha
        ),
    );

    // Cover takes the bodies rather than hiding them behind anything: they are drawn
    // over the sky's march, so a downpour leaves a smudge where the sun was.
    let clear = Sky::take(&mut harness, 12.0);
    harness.eval("cloudiness = 1").expect("overcast");
    let overcast = Sky::take(&mut harness, 12.0);
    checks.check(
        "an overcast sky takes most of the sun",
        overcast.sun.alpha < clear.sun.alpha / 2.0,
        (clear.sun.alpha, overcast.sun.alpha),
    );

    checks.finish();
}

/// The cloud layer is composited *over* the bodies, which is the whole of "the sun
/// is behind the cloud": the sky is drawn in two passes -- the air, then the clouds
/// -- with `drawCelestial` in between, so a cloud that drifts over the sun takes it
/// per pixel, out of the sky's own march, instead of the sun being painted on top
/// of the cloud.
///
/// None of that is a number the scene can report, so the stub keeps one frame's
/// draw order (`Observations::layers`) and these checks read it. The single-pass
/// fallback is the same fact from the other side: take away the blend mode the
/// cloud layer needs and the sky is one layer, with the bodies over it again.
#[test]
fn the_bodies_are_under_the_cloud_layer() {
    let mut checks = Checks::new();

    // `sky.js`'s `SKY_LAYER_*` and the stub's row kinds. `BLEND_ALPHA_PREMULTIPLY`
    // is raylib's mode for ONE / ONE-MINUS-SRC-ALPHA, which is what attenuates what
    // the cloud layer is drawn over; the sun's glare is drawn `ADDITIVE`.
    const SKY: i64 = 0;
    const MODEL: i64 = 1;
    const BILLBOARD: i64 = 2;
    const AIR: i64 = 1;
    const CLOUD: i64 = 2;
    const ADDITIVE: i64 = 1;
    const PREMULTIPLIED: i64 = 5;

    let mut harness = Harness::start().expect("evaluate the scene");
    let obs = harness.run(FRAMES).expect("run the scene");
    let bodies = celestial_meshes(&mut harness);
    let sun = bodies.first().copied().unwrap_or(-1);
    let moon = bodies.get(1).copied().unwrap_or(-1);
    let terrain = harness
        .eval("terrainMesh")
        .expect("terrainMesh")
        .as_i64()
        .unwrap_or(-1);
    let layers = &obs.layers;

    let air = layers.iter().position(|row| row == &[SKY, AIR, 0]);
    let cloud = layers
        .iter()
        .position(|row| row == &[SKY, CLOUD, PREMULTIPLIED]);
    checks.check(
        "the sky is drawn as two layers, the cloud pass premultiplied",
        air.is_some() && cloud.is_some(),
        (air, cloud, layers),
    );

    // The pass itself has to return premultiplied light and what it lets through:
    // the blend mode alone would not make the numbers right.
    checks.check(
        "the cloud pass returns premultiplied light and its transmittance",
        ["skyLayer > 1.5", "vec4(scatter, 1.0 - trans)"]
            .iter()
            .all(|marker| obs.sky_fs.contains(marker)),
        obs.sky_fs.len(),
    );

    // The body that is up -- the two are antipodal, so a frame has exactly one --
    // and the sun's glare land between the two passes. That is what "behind the
    // clouds" is; a body drawn after the cloud pass would be over the clouds
    // however the shader is written.
    let body_rows = rows_of(layers, MODEL, &bodies);
    let glare_rows = rows_of(layers, BILLBOARD, &[]);
    let between =
        |position: usize| air.is_some_and(|a| position > a) && cloud.is_some_and(|c| position < c);
    checks.check(
        "the body that is up, and the sun's glare, are drawn between the two passes",
        body_rows.len() == 1
            && body_rows.iter().all(|position| between(*position))
            && !glare_rows.is_empty()
            && glare_rows.iter().all(|position| between(*position)),
        (air, cloud, &body_rows, &glare_rows),
    );

    // ...additively, which is the other half of a glare: it adds light to the sky it
    // hangs in instead of greying that sky toward its own colour.
    checks.check(
        "the sun's glare is drawn additively",
        !glare_rows.is_empty()
            && glare_rows
                .iter()
                .all(|position| layers[*position][2] == ADDITIVE),
        &glare_rows,
    );

    // The other end of the line gets the same treatment, which is the only way to
    // watch the moon do it: one frame at midnight, with the sun down. The run ended
    // with `sceneShutdown`, so the frame is driven directly.
    harness.eval("worldTime = 0").expect("midnight");
    harness.reset_frame().expect("the frame counter");
    harness
        .call("sceneFrame", &[])
        .expect("one frame at midnight");
    let night = harness.observe().expect("observe");
    let night_air = rows_of(&night.layers, SKY, &[AIR]).first().copied();
    let night_cloud = rows_of(&night.layers, SKY, &[CLOUD]).first().copied();
    let moon_rows = rows_of(&night.layers, MODEL, &[moon]);
    checks.check(
        "at midnight it is the moon that is drawn under the cloud layer",
        moon_rows.len() == 1
            && night_air.is_some_and(|a| moon_rows[0] > a)
            && night_cloud.is_some_and(|c| moon_rows[0] < c)
            && rows_of(&night.layers, MODEL, &[sun]).is_empty(),
        (&night.layers, &moon_rows),
    );

    // ...and the world is over the cloud layer, not under it: the terrain is the
    // first model drawn after it.
    let ground_rows = rows_of(layers, MODEL, &[terrain]);
    checks.check(
        "the ground is drawn over the cloud layer",
        terrain > 0
            && !ground_rows.is_empty()
            && ground_rows
                .iter()
                .all(|position| cloud.is_some_and(|c| *position > c)),
        (cloud, terrain, &ground_rows),
    );

    // ---- the single pass, where the blend mode is not there ------------------
    let mut plain = Harness::start().expect("evaluate the scene");
    plain
        .eval("rl.BLEND_ALPHA_PREMULTIPLY = undefined")
        .expect("a build without the premultiplied blend mode");
    let fallback = plain.run(FRAMES).expect("run the scene");
    let split = plain.call("skySplitOn", &[]).expect("skySplitOn");
    let over = rows_of(&fallback.layers, MODEL, &celestial_meshes(&mut plain));
    let whole = rows_of(&fallback.layers, SKY, &[]);
    checks.check(
        "without the blend mode the sky is one pass and the bodies are over it",
        split == Value::Bool(false)
            && !fallback
                .layers
                .iter()
                .any(|row| row[0] == SKY && row[1] == CLOUD)
            && !over.is_empty()
            && over
                .iter()
                .all(|position| whole.first().is_some_and(|first| position > first)),
        (split, &fallback.layers),
    );

    checks.finish();
}
