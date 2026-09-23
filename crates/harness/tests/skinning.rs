//! The `gpu-skinning` client half, on the harness's stub `rl`.
//!
//! The engine's `gpu-skinning` build stops deforming an animated mesh on the CPU
//! and leaves it to the material's shader, so the scene owes it three things: a
//! skinned variant of each of the three vertex shader families, one routing call
//! per animated model, and the *plain* programs kept for everything that has no
//! bone data (`slag/.notes/gpu-skinning.md`; the scene half is
//! `crates/goats/src/game/lighting.js`). Every one of those fails silently on
//! screen -- a mesh drawn through the zero matrix, or a herd drawn at its bind
//! pose -- which is why the routing rules are pinned here.
//!
//! The harness has no GL context, so the cases do what the real engine does and
//! report it as a flag: `rl.GPU_SKINNING`. The stub's shader handles name the
//! program a model was routed to: 0 lit, 1 planar shadow, 2 depth, and 4/5/6 for
//! their skinned variants.
//!
//! One live world at a time, as in `birds.rs`: a second stepped context in the
//! same process aborts, so each case's harness is scoped and dropped before the
//! next one starts.

mod support;

use harness::{Harness, Observations};
use serde_json::json;
use support::Checks;

/// Long enough for the load (one step per frame, then a bot per step) plus a few
/// frames of the herd drawn after it.
const FRAMES: u32 = 30;

/// The goat's model handle; the terrain mesh handles are 1000+.
const GOAT: i64 = 0;

/// The stub's handle for the water surface's own program (M20b). The water is a
/// `makeModel` mesh like the terrain and the celestial spheres, so it shares their
/// handle range and is told apart by the program it is routed to.
const WATER_SHADER: i64 = 9;

/// The programs a model was routed to, in order.
fn routes_of(obs: &Observations, model: i64) -> Vec<i64> {
    obs.model_shader_routes
        .iter()
        .filter(|row| row.first() == Some(&model))
        .filter_map(|row| row.get(1).copied())
        .collect()
}

/// The two celestial spheres' handles: they are `makeModel` meshes too, so they
/// share the terrain's handle range while being routed to their own program
/// (`celestial.rs` is where that is checked).
fn celestial_meshes(harness: &mut Harness) -> Vec<i64> {
    harness.call("sceneCelestial", &[]).expect("sceneCelestial")["meshes"]
        .as_array()
        .map(|meshes| meshes.iter().filter_map(|m| m.as_i64()).collect())
        .unwrap_or_default()
}

/// Every rig in the scene, i.e. every model handle that is neither the terrain's
/// nor the celestial bodies'.
fn rig_routes(obs: &Observations, bodies: &[i64]) -> Vec<i64> {
    obs.model_shader_routes
        .iter()
        .filter(|row| {
            let handle = row.first().copied().unwrap_or(-1);
            (0..1000).contains(&handle) && !bodies.contains(&handle)
        })
        .filter_map(|row| row.get(1).copied())
        .collect()
}

/// Every model handle that is a rig rather than the terrain mesh.
fn rig_handles(obs: &Observations) -> Vec<i64> {
    let mut handles: Vec<i64> = obs
        .model_shader_routes
        .iter()
        .filter_map(|row| row.first().copied())
        .filter(|handle| *handle >= 0 && *handle < 1000)
        .collect();
    handles.sort_unstable();
    handles.dedup();
    handles
}

#[test]
fn the_skinned_paths_are_routed() {
    let mut checks = Checks::new();

    // ---- a CPU-skinning build: nothing skinned is compiled or used ----------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let obs = harness.run(FRAMES).expect("run the scene");
        let bodies = celestial_meshes(&mut harness);
        checks.check(
            "a CPU-skinning build compiles no skinned program",
            obs.skinned_shaders.is_empty(),
            &obs.skinned_shaders,
        );
        checks.check(
            "...and never asks for the CPU pass back either",
            obs.cpu_skin_calls.is_empty(),
            &obs.cpu_skin_calls,
        );
        checks.check(
            "...and routes every rig to a plain program",
            !bodies.is_empty() && rig_routes(&obs, &bodies).iter().all(|shader| *shader < 4),
            &obs.model_shader_routes,
        );
        // `L` turns the lighting off by pointing the models back at the shader they
        // were loaded with, and on this build that is the end of it.
        harness.command("lighting off").expect("lighting off");
        let off = harness.observe().expect("observe");
        checks.check(
            "...and the L toggle leaves the loader's own shader alone",
            routes_of(&off, GOAT).last() == Some(&-1),
            routes_of(&off, GOAT),
        );
    }

    // ---- a gpu-skinning build: the rigs ride the skinned programs -----------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness
            .eval("rl.GPU_SKINNING = true")
            .expect("the build flag");
        let obs = harness.run(FRAMES).expect("run the scene");
        let bodies = celestial_meshes(&mut harness);

        checks.check(
            "every skinned program was compiled: three passes and the unlit one",
            obs.skinned_shaders.len() == 4,
            obs.skinned_shaders.keys().collect::<Vec<_>>(),
        );
        checks.check(
            "each declares the bone inputs and a `boneMatrices` array",
            obs.skinned_shaders.values().all(|source| {
                source.contains("in vec4 vertexBoneIndices;")
                    && source.contains("in vec4 vertexBoneWeights;")
                    && source.contains("uniform mat4 boneMatrices[32];")
            }),
            obs.skinned_shaders
                .iter()
                .map(|(handle, source)| (handle, source.lines().count()))
                .collect::<Vec<_>>(),
        );
        // raylib sets the indices up with `glVertexAttribPointer`, so they arrive as
        // unsigned bytes widened to floats; an `ivec4` here reads garbage.
        checks.check(
            "the bone indices are cast with `int()`, not declared `ivec4`",
            obs.skinned_shaders
                .values()
                .all(|source| source.contains("int(vertexBoneIndices.x)")),
            obs.skinned_shaders
                .values()
                .map(|source| source.contains("ivec4"))
                .collect::<Vec<_>>(),
        );

        let goat = routes_of(&obs, GOAT);
        checks.check(
            "the goat is routed to the skinned lit program",
            goat.contains(&4),
            &goat,
        );
        checks.check("...and to the skinned depth pass", goat.contains(&6), &goat);
        let rigs = rig_handles(&obs);
        checks.check(
            "every rig in the scene took a skinned program",
            rigs.iter().all(|handle| {
                let routes = routes_of(&obs, *handle);
                routes.contains(&4) || routes.contains(&6)
            }),
            rigs.iter()
                .map(|handle| (*handle, routes_of(&obs, *handle)))
                .collect::<Vec<_>>(),
        );
        checks.check(
            "the herd is the player's own route",
            rigs.len() > 1
                && rigs
                    .iter()
                    .all(|handle| routes_of(&obs, *handle).contains(&4)),
            &rigs,
        );
        // The terrain is a `makeModel` mesh with no bone data: a skinned program
        // would read the generic attributes and deform the grid. (The celestial
        // spheres and the water surface are `makeModel` meshes too, in the same handle
        // range, and are routed to programs of their own -- `celestial.rs` and
        // `water.rs` are where those are checked.)
        let terrain = obs
            .model_shader_routes
            .iter()
            .filter(|row| {
                let handle = row.first().copied().unwrap_or(-1);
                handle >= 1000 && !bodies.contains(&handle)
            })
            .map(|row| row[1])
            .filter(|shader| *shader != WATER_SHADER)
            .collect::<Vec<_>>();
        checks.check(
            "the terrain mesh keeps the plain lit program",
            !terrain.is_empty() && terrain.iter().all(|shader| *shader == 0),
            &terrain,
        );
        checks.check(
            "nothing fell back to CPU skinning",
            obs.cpu_skin_calls.is_empty(),
            &obs.cpu_skin_calls,
        );

        // The `L` view: raylib's own default shader does not skin either, so the
        // `-1` route has to become the unlit skinned program, or the herd would hold
        // its bind pose for as long as the lighting is off. The run ends with
        // `sceneShutdown`, which unloads the herd, so the lighting goes off first and
        // a bot is added after it -- handle 8, after the goat (0) and the seven the
        // load made -- which is the case a herd resize hits while it is off. The
        // terrain, which has no bone data, is the control: `-1` stays `-1` for it.
        harness.command("lighting off").expect("lighting off");
        harness.call("botAdd", &[json!(0)]).expect("botAdd");
        let off = harness.observe().expect("observe");
        let goat_off = routes_of(&off, GOAT);
        checks.check(
            "with the lighting off the goat takes the unlit skinned program",
            goat_off.last() == Some(&7),
            &goat_off,
        );
        let bot_off = routes_of(&off, 8);
        checks.check(
            "...and a bot added while it is off comes up on it too",
            !bot_off.is_empty() && bot_off.iter().all(|shader| *shader == 7),
            &bot_off,
        );
        let terrain_off = off
            .model_shader_routes
            .iter()
            .filter(|row| {
                let handle = row.first().copied().unwrap_or(-1);
                handle >= 1000 && !bodies.contains(&handle)
            })
            .map(|row| row[1])
            .filter(|shader| *shader != WATER_SHADER)
            .collect::<Vec<_>>();
        checks.check(
            "...while the terrain keeps the loader's own shader",
            terrain_off.contains(&-1),
            &terrain_off,
        );
    }

    // ---- a rig past the array: that model keeps CPU skinning ----------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness
            .eval("rl.GPU_SKINNING = true; rl.MODEL_BONES = 64")
            .expect("the build flag and a bigger rig");
        let obs = harness.run(FRAMES).expect("run the scene");
        let bodies = celestial_meshes(&mut harness);

        checks.check(
            "a rig over `boneMatrices` was given its deform buffers back",
            obs.cpu_skin_calls.first() == Some(&vec![GOAT, 1]),
            &obs.cpu_skin_calls,
        );
        checks.check(
            "...for every rig, not just the goat",
            rig_handles(&obs)
                .iter()
                .all(|handle| obs.cpu_skin_calls.contains(&vec![*handle, 1])),
            &obs.cpu_skin_calls,
        );
        checks.check(
            "...and is routed to a plain program",
            rig_routes(&obs, &bodies).iter().all(|shader| *shader < 4),
            &obs.model_shader_routes,
        );
        // The fallback is per model: the programs are still there for the next one.
        checks.check(
            "the skinned programs were still compiled",
            obs.skinned_shaders.len() == 4,
            obs.skinned_shaders.keys().collect::<Vec<_>>(),
        );
        checks.check(
            "the scene said why, with the counts",
            obs.logs.iter().any(|line| {
                line.contains("64 bones") && line.contains("32") && line.contains("CPU skinning")
            }),
            obs.logs
                .iter()
                .find(|line| line.contains("bones"))
                .cloned()
                .unwrap_or_default(),
        );
        // Such a rig is drawn from its deformed mesh, so the loader's own shader is
        // the right `-1` for it -- not the unlit skinned program.
        harness.command("lighting off").expect("lighting off");
        let off = harness.observe().expect("observe");
        checks.check(
            "...and the L toggle leaves it on the loader's own shader",
            routes_of(&off, GOAT).last() == Some(&-1),
            routes_of(&off, GOAT),
        );
    }

    checks.finish();
}
