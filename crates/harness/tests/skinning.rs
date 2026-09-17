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
use support::Checks;

/// Long enough for the load (one step per frame, then a bot per step) plus a few
/// frames of the herd drawn after it.
const FRAMES: u32 = 30;

/// The goat's model handle; the terrain mesh handles are 1000+.
const GOAT: i64 = 0;

/// The programs a model was routed to, in order.
fn routes_of(obs: &Observations, model: i64) -> Vec<i64> {
    obs.model_shader_routes
        .iter()
        .filter(|row| row.first() == Some(&model))
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
            "...and routes every model to a plain program",
            obs.model_shader_routes
                .iter()
                .all(|row| row.get(1).copied().unwrap_or(-1) < 4),
            &obs.model_shader_routes,
        );
    }

    // ---- a gpu-skinning build: the rigs ride the skinned programs -----------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness
            .eval("rl.GPU_SKINNING = true")
            .expect("the build flag");
        let obs = harness.run(FRAMES).expect("run the scene");

        checks.check(
            "one skinned program per family was compiled",
            obs.skinned_shaders.len() == 3,
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
        // would read the generic attributes and deform the grid.
        let terrain = obs
            .model_shader_routes
            .iter()
            .filter(|row| row.first().copied().unwrap_or(-1) >= 1000)
            .map(|row| row[1])
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
    }

    // ---- a rig past the array: that model keeps CPU skinning ----------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        harness
            .eval("rl.GPU_SKINNING = true; rl.MODEL_BONES = 64")
            .expect("the build flag and a bigger rig");
        let obs = harness.run(FRAMES).expect("run the scene");

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
            obs.model_shader_routes
                .iter()
                .all(|row| row.get(1).copied().unwrap_or(-1) < 4),
            &obs.model_shader_routes,
        );
        // The fallback is per model: the programs are still there for the next one.
        checks.check(
            "the skinned programs were still compiled",
            obs.skinned_shaders.len() == 3,
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
    }

    checks.finish();
}
