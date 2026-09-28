//! The GLSL dialect (D2): one source, two dialects.
//!
//! The scene's shaders are desktop GLSL 3.30, and Android compiles GLSL ES 3.00,
//! so `lighting.js`'s `glsl()` translates a source as it is handed to the engine
//! (`loadGlsl`), and the client says which dialect the build wants
//! (`crates/goats/src/lib.rs`; ANDROID.md D2 and P0.5). There is no GL here, so
//! what the harness can hold is the *text*: every source the run compiled, checked
//! for its version line, for the ES3 precision prelude that has to follow it, and
//! for the spellings only desktop GLSL 2.x has. Whether a driver accepts the
//! result is a device's answer, not this one.
//!
//! The ES3 pass turns the `gpu-skinning` build on even though Android ships
//! without it: the four skinned vertex sources are compiled by no other run, and
//! they are the ones carrying a `boneMatrices[32]` array -- exactly the kind of
//! declaration a dialect change can break.
//!
//! One live world at a time, as in `skinning.rs`: a second stepped context in the
//! same process aborts, so each harness is scoped and dropped before the next.

mod support;

use harness::{Harness, Observations};
use support::Checks;

/// Long enough for the load (one step per frame, then a bot per step) and a few
/// frames of drawing after it.
const FRAMES: u32 = 30;

/// Every source the run compiled -- both stages of every program -- as
/// `(where, source)`, so a failure names the program instead of dumping the set.
fn sources(obs: &Observations) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for (i, program) in obs.shader_programs.iter().enumerate() {
        out.push((format!("program {i} vertex"), program.vertex.clone()));
        out.push((format!("program {i} fragment"), program.fragment.clone()));
    }
    out
}

fn first_line(source: &str) -> &str {
    source.lines().next().unwrap_or("")
}

fn line(source: &str, n: usize) -> &str {
    source.lines().nth(n).unwrap_or("")
}

/// The spellings a source written for desktop GLSL 2.x would have and GLSL ES
/// 3.00 would not. The scene's sources are all written the ES3 way already --
/// which is also the desktop 3.30 way -- so the translation never rewrites one;
/// this is what keeps that true as shaders are added.
const LEGACY_SPELLINGS: &[&str] = &[
    "texture2D",
    "varying",
    "attribute",
    "gl_FragColor",
    "gl_FragData",
];

#[test]
fn the_shaders_speak_the_builds_dialect() {
    let mut checks = Checks::new();

    // ---- desktop: the scene's own dialect, untouched ------------------------
    {
        let mut harness = Harness::start().expect("evaluate the scene");
        let obs = harness.run(FRAMES).expect("run the scene");

        checks.check(
            "a desktop run compiles its programs",
            !obs.shader_programs.is_empty(),
            obs.shader_programs.len(),
        );
        let wrong: Vec<(String, String)> = sources(&obs)
            .into_iter()
            .filter(|(_, source)| first_line(source) != "#version 330")
            .map(|(where_, source)| (where_, first_line(&source).to_string()))
            .collect();
        checks.check(
            "every source a desktop build compiles is `#version 330`",
            wrong.is_empty(),
            wrong,
        );
        checks.check(
            "...and none of them carries the ES3 prelude",
            sources(&obs)
                .iter()
                .all(|(_, source)| !source.contains("precision highp float;")),
            obs.shader_programs.len(),
        );
    }

    // ---- ES3: the phone's dialect, over everything the scene compiles -------
    {
        let mut harness = Harness::start().expect("evaluate the scene");

        // The translation on its own, before the run. Desktop is the default, so a
        // host that never says (the server, this harness) gets the sources it had.
        let noop = harness.eval("glsl(LIT_FS) === LIT_FS").expect("eval");
        checks.check(
            "the default dialect is desktop, where `glsl` changes nothing",
            noop.as_bool() == Some(true),
            noop,
        );

        harness
            .eval("setGlslDialect(true)")
            .expect("setGlslDialect");
        let head = harness
            .eval("glsl('#version 330\\nin vec3 p;').split('\\n').slice(0, 3).join('|')")
            .expect("eval");
        checks.check(
            "ES3 replaces the version line and declares the precisions ahead of it",
            head.as_str() == Some("#version 300 es|precision highp float;|precision highp int;"),
            head,
        );

        harness
            .eval("setGlslDialect(false)")
            .expect("setGlslDialect off");
        let back = harness.eval("glsl(LIT_FS) === LIT_FS").expect("eval");
        harness
            .eval("setGlslDialect(true)")
            .expect("setGlslDialect on");
        checks.check(
            "the flag is the whole state, so desktop is reachable again",
            back.as_bool() == Some(true),
            back,
        );

        let bare = harness.eval("glsl('in vec3 p;')").expect("eval");
        checks.check(
            "a source with no version line is passed on, not half-translated",
            bare.as_str() == Some("in vec3 p;"),
            bare,
        );

        // A `gpu-skinning` build, so the skinned sources are in the set.
        harness
            .eval("rl.GPU_SKINNING = true")
            .expect("the build flag");
        let obs = harness.run(FRAMES).expect("run the scene");

        // lit, its skinned twin, the planar shadow, the depth pass and its twin,
        // the unlit skinned program, the water, the celestial bodies, the sky.
        checks.check(
            "the ES3 run compiles the whole set, the skinned variants included",
            obs.shader_programs.len() == 10,
            obs.shader_programs.len(),
        );

        let all = sources(&obs);
        let wrong_version: Vec<(String, String)> = all
            .iter()
            .filter(|(_, source)| first_line(source) != "#version 300 es")
            .map(|(where_, source)| (where_.clone(), first_line(source).to_string()))
            .collect();
        checks.check(
            "every source the ES3 build compiles is `#version 300 es`",
            wrong_version.is_empty(),
            wrong_version,
        );

        let wrong_head: Vec<(String, String)> = all
            .iter()
            .filter(|(_, source)| {
                line(source, 1) != "precision highp float;"
                    || line(source, 2) != "precision highp int;"
            })
            .map(|(where_, source)| {
                (
                    where_.clone(),
                    format!("{:?} / {:?}", line(source, 1), line(source, 2)),
                )
            })
            .collect();
        checks.check(
            "...with the ES3 precisions ahead of every declaration",
            wrong_head.is_empty(),
            wrong_head,
        );

        checks.check(
            "...and nothing still asking for `#version 330`",
            all.iter()
                .all(|(_, source)| !source.contains("#version 330")),
            all.len(),
        );

        let mut legacy: Vec<(String, &str)> = Vec::new();
        for (where_, source) in &all {
            for word in LEGACY_SPELLINGS {
                if source.contains(*word) {
                    legacy.push((where_.clone(), word));
                }
            }
        }
        checks.check(
            "no source uses a spelling only desktop GLSL 2.x has",
            legacy.is_empty(),
            legacy,
        );

        // The four skinned vertex sources: only this run compiles them, and they are
        // the ones whose bone array makes them the likeliest to break on a dialect.
        let skinned: Vec<&str> = obs
            .shader_programs
            .iter()
            .filter(|program| program.vertex.contains("boneMatrices"))
            .map(|program| first_line(&program.vertex))
            .collect();
        checks.check(
            "the skinned vertex sources went through the dialect too",
            skinned.len() == 4 && skinned.iter().all(|line| *line == "#version 300 es"),
            skinned,
        );
    }

    checks.finish();
}
