//! The terrain field's hot loop, for the mesh builder.
//!
//! `terrain.gd` is the single source of truth for the ground: the goat, the herd,
//! the grass, the water and the drawn mesh all read it. It is a transcription of
//! `world.js`, and it stays in GDScript because the scene is GDScript and the
//! oracle compares those two. What this module adds is *speed*: building the mesh
//! needs the field at every vertex of three grids -- ~7200 samples on a move --
//! and one of those samples is ~7 us in GDScript, so a rebuild cost ~90 ms and a
//! browser frame could not hide it.
//!
//! So the sampling loop lives here, as a static field on a `RefCounted` class.
//! `terrain_mesh.gd` calls it when the extension is loaded and falls back to its
//! own transcription when it is not (a headless host without the library, a mod
//! build), so the ground is the same either way. The two are checked against each
//! other by `tools/verify_terrain_mesh.gd`.
//!
//! The port is a transcription down to the order of the arithmetic: same
//! constants, same `sin`-based hash, same clamp-then-cubic `smoothstep`. The
//! build is pure and has no state, so it is safe on the browser's single thread.

use godot::prelude::*;

/// The field's tuning, which `terrain.gd` keeps in static vars because the scene
/// can retune it (`tune terrain.relief ...`). Passed in rather than copied, so a
/// retune moves the drawn mesh and the gameplay field together.
#[derive(Clone, Copy)]
pub struct Field {
    pub relief: f64,
    pub flat: f64,
    pub ramp: f64,
    pub mountain: f64,
    pub mountain_flat: f64,
    pub mountain_ramp: f64,
}

/// `core.js`'s `hash`, verbatim: a `sin`-based scatter in `0..1`.
fn value_hash(n: f64) -> f64 {
    let s = (n * 127.1).sin() * 43758.5453;
    s - s.floor()
}

/// `weather.js`'s `vnoise2`, verbatim: smooth value noise on the integer lattice.
fn vnoise2(x: f64, y: f64) -> f64 {
    let xi = x.floor();
    let yi = y.floor();
    let xf = x - xi;
    let yf = y - yi;
    let u = xf * xf * (3.0 - 2.0 * xf);
    let v = yf * yf * (3.0 - 2.0 * yf);
    let a = value_hash(xi * 57.0 + yi * 131.0);
    let b = value_hash((xi + 1.0) * 57.0 + yi * 131.0);
    let c = value_hash(xi * 57.0 + (yi + 1.0) * 131.0);
    let d = value_hash((xi + 1.0) * 57.0 + (yi + 1.0) * 131.0);
    (a * (1.0 - u) + b * u) * (1.0 - v) + (c * (1.0 - u) + d * u) * v
}

/// `smoothstep`, clamped before the cubic.
fn smoothstep(lo: f64, hi: f64, v: f64) -> f64 {
    let t = ((v - lo) / (hi - lo)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// `terrain.gd`'s `shape`, verbatim: four octaves of rolling hills.
fn shape(x: f64, z: f64) -> f64 {
    let broad = 0.58 * vnoise2(x * 0.033 + 13.7, z * 0.033 + 5.1);
    let middle = 0.25 * vnoise2(x * 0.081 + 41.3, z * 0.081 + 27.9);
    let fine = 0.12 * vnoise2(x * 0.191 + 77.1, z * 0.191 + 61.3);
    let grain = 0.05 * vnoise2(x * 0.29 + 5.3, z * 0.29 + 33.7);
    broad + middle + fine + grain
}

/// `terrain.gd`'s `ridge`, verbatim: two folded octaves under a low-frequency mask.
fn ridge(x: f64, z: f64) -> f64 {
    let broad = 1.0 - (2.0 * vnoise2(x * 0.0105 + 91.3, z * 0.0105 + 17.9) - 1.0).abs();
    let fine = 1.0 - (2.0 * vnoise2(x * 0.028 + 3.7, z * 0.028 + 55.1) - 1.0).abs();
    let crest = 0.72 * broad + 0.28 * fine;
    let mask = smoothstep(0.30, 0.70, vnoise2(x * 0.0062 + 7.3, z * 0.0062 + 41.7));
    crest * crest * mask
}

/// `terrain.gd`'s `base_height`, verbatim: the bowl, the hills and the range.
pub fn base_height(x: f64, z: f64, f: Field) -> f64 {
    let d = (x * x + z * z).sqrt();
    let t = smoothstep(f.flat, f.flat + f.ramp, d);
    let tm = smoothstep(f.mountain_flat, f.mountain_flat + f.mountain_ramp, d);
    (shape(x, z) - 0.5) * 2.0 * f.relief * t + ridge(x, z) * f.mountain * tm
}

/// The field sampler, as a class the scene can instantiate. One stateless
/// instance is enough; `terrain_mesh.gd` keeps one.
#[derive(GodotClass)]
#[class(base=RefCounted)]
struct TerrainField {
    base: Base<RefCounted>,
}

#[godot_api]
impl IRefCounted for TerrainField {
    fn init(base: Base<RefCounted>) -> Self {
        Self { base }
    }
}

#[godot_api]
impl TerrainField {
    /// The slope at a world point over a fixed metric step, as the surface
    /// perimeter measures it. `terrain_mesh.gd`'s `_edge_slope`, and the same
    /// narrow-to-`Vector2` as the scene's: the normal and the material only ever see
    /// the f32 vector.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn slope(
        &self,
        x: f64,
        z: f64,
        step: f64,
        relief: f64,
        flat: f64,
        ramp: f64,
        mountain: f64,
        mountain_flat: f64,
        mountain_ramp: f64,
    ) -> Vector2 {
        let field = Field {
            relief,
            flat,
            ramp,
            mountain,
            mountain_flat,
            mountain_ramp,
        };
        let d = step;
        let dx = (base_height(x + d, z, field) - base_height(x - d, z, field)) / (2.0 * d);
        let dz = (base_height(x, z + d, field) - base_height(x, z - d, field)) / (2.0 * d);
        Vector2::new(dx as f32, dz as f32)
    }

    /// The heights of a square grid after its anchor moved by `(di, dj)` cells.
    ///
    /// `prev` is the grid at the old anchor, row-major at `n` by `n`. A
    /// destination cell whose source index (`i + di`, `j + dj`) is inside the grid
    /// describes the same world point and is copied; the rest is sampled. With
    /// `full` (the first build, a teleport, a retune) every cell is sampled.
    ///
    /// Returns a new array; the caller owns it, which is what lets the scene keep
    /// the previous grid for the next shift without a double buffer.
    #[func]
    #[allow(clippy::too_many_arguments)]
    fn fill_heights(
        &self,
        prev: PackedFloat64Array,
        x0: f64,
        z0: f64,
        cell: f64,
        n: i64,
        di: i64,
        dj: i64,
        full: bool,
        relief: f64,
        flat: f64,
        ramp: f64,
        mountain: f64,
        mountain_flat: f64,
        mountain_ramp: f64,
    ) -> PackedFloat64Array {
        let field = Field {
            relief,
            flat,
            ramp,
            mountain,
            mountain_flat,
            mountain_ramp,
        };
        let n = n.max(0) as usize;
        let count = n * n;
        let mut out = vec![0.0_f64; count];
        let src = prev.as_slice();
        let can_shift = !full && src.len() == count && (di != 0 || dj != 0);
        for j in 0..n {
            let wz = z0 + j as f64 * cell;
            let row = &mut out[j * n..(j + 1) * n];
            let sj = j as i64 + dj;
            if can_shift && sj >= 0 && (sj as usize) < n {
                let srow = &src[sj as usize * n..(sj as usize + 1) * n];
                for (i, slot) in row.iter_mut().enumerate() {
                    let si = i as i64 + di;
                    *slot = if si >= 0 && (si as usize) < n {
                        srow[si as usize]
                    } else {
                        base_height(x0 + i as f64 * cell, wz, field)
                    };
                }
            } else {
                for (i, slot) in row.iter_mut().enumerate() {
                    *slot = base_height(x0 + i as f64 * cell, wz, field);
                }
            }
        }
        PackedFloat64Array::from(out)
    }
}
