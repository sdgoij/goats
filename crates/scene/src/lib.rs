//! The goat scene as one bundle: the ordered parts, the joined script and the
//! `rl` modules the scene is evaluated against.
//!
//! This is the single source of the running order. The client, the headless
//! server and the test harness all read [`SCENE`], so they cannot disagree about
//! it -- which is what the old client/server drift test existed to prevent. The
//! scene is one flat script joined by `concat!` (the engine has no module
//! system), so every part shares a single top-level scope; adding a part is a
//! file in `crates/goats/src/game/` plus one line in the list below.

// `PARTS` is the running order and `SCENE` is exactly those files joined, so
// the two cannot drift apart.
macro_rules! scene_bundle {
    ($($file:literal),* $(,)?) => {
        /// The scene parts, in the order they are concatenated. Diagnostic
        /// only; [`SCENE`] is what gets evaluated.
        pub const PARTS: &[&str] = &[$($file),*];

        /// The scene, joined exactly as the client joins it.
        pub const SCENE: &str = concat!($(include_str!($file)),*);
    };
}

scene_bundle!(
    "../../goats/src/game/core.js",
    "../../goats/src/game/model.js",
    "../../goats/src/game/world.js",
    "../../goats/src/game/lighting.js",
    "../../goats/src/game/sky.js",
    "../../goats/src/game/audio.js",
    "../../goats/src/game/weather.js",
    "../../goats/src/game/food.js",
    "../../goats/src/game/bots.js",
    "../../goats/src/game/goat.js",
    "../../goats/src/game/ctl.js",
    "../../goats/src/game/menu.js",
    "../../goats/src/game/console.js",
    "../../goats/src/game/net.js",
    "../../goats/src/game/mods.js",
);

/// The null `rl`: every member the scene touches, with the drawing and input
/// calls doing nothing and the few the simulation reads returning something
/// plausible. `goatsd` evaluates the scene against this instead of installing
/// raylib, so a headless host can own the world with no window and no GPU.
pub const NULL_RL: &str = include_str!("null_rl.js");

/// The harness's `rl`: the null module plus recording, the scripted input
/// timeline and the loop control the tests drive. It is evaluated after
/// [`NULL_RL`], which it overlays rather than replacing.
pub const HARNESS_RL: &str = include_str!("harness_rl.js");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_parts_are_all_present_and_in_order() {
        // Every part opens with a `// Part N/15` banner. Finding all of them in
        // the joined scene proves the list and the files still agree -- a part
        // dropped from the list, or a renumbering, leaves a gap.
        assert_eq!(PARTS.len(), 15);
        for n in 1..=PARTS.len() {
            let banner = format!("// Part {n}/{}", PARTS.len());
            assert!(SCENE.contains(&banner), "the scene is missing `{banner}`");
        }
    }
}
