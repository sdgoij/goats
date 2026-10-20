//! The whole-body pose and the rider's back point.
//!
//! Both clients draw the goat with the same rotation: yaw about +Y, pitch about
//! the model's +Z, roll about +X. The reference needs the one axis-angle its
//! `drawModelEx` takes; Godot needs a `Quaternion`/`Basis`. A quaternion is the
//! neutral output, and [`axis_angle`] is the raylib form.

use crate::State;

/// A unit quaternion in the model's frame.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Quat {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub w: f32,
}

impl Default for Quat {
    fn default() -> Self {
        Self::IDENTITY
    }
}

impl Quat {
    pub const IDENTITY: Quat = Quat {
        x: 0.0,
        y: 0.0,
        z: 0.0,
        w: 1.0,
    };

    /// A rotation of `rad` radians about `(ax, ay, az)`. A zero axis or a
    /// non-finite angle is the identity, which keeps a bad input from producing a
    /// non-finite pose.
    #[must_use]
    pub fn axis_angle(ax: f32, ay: f32, az: f32, rad: f32) -> Quat {
        let length = (ax * ax + ay * ay + az * az).sqrt();
        if !rad.is_finite() || !length.is_finite() || length < 1e-6 {
            return Quat::IDENTITY;
        }
        let (sin, cos) = (rad * 0.5).sin_cos();
        Quat {
            x: ax / length * sin,
            y: ay / length * sin,
            z: az / length * sin,
            w: cos,
        }
    }

    /// Rotate a vector by this quaternion.
    #[must_use]
    pub fn rotate(self, v: [f32; 3]) -> [f32; 3] {
        let [x, y, z] = v;
        // `v + 2 * q.xyz x (q.xyz x v + w * v)`, the quaternion form of
        // Rodrigues. It allocates nothing and matches `flingDraw`'s formula.
        let tx = self.y * z - self.z * y + self.w * x;
        let ty = self.z * x - self.x * z + self.w * y;
        let tz = self.x * y - self.y * x + self.w * z;
        [
            x + 2.0 * (self.y * tz - self.z * ty),
            y + 2.0 * (self.z * tx - self.x * tz),
            z + 2.0 * (self.x * ty - self.y * tx),
        ]
    }
}

/// `a * b` applies `b` first, then `a`. The pose composes yaw after pitch after
/// roll, the same order `bodyQuatInto` uses in the birds mod.
impl std::ops::Mul for Quat {
    type Output = Quat;

    fn mul(self, other: Quat) -> Quat {
        Quat {
            w: self.w * other.w - self.x * other.x - self.y * other.y - self.z * other.z,
            x: self.w * other.x + self.x * other.w + self.y * other.z - self.z * other.y,
            y: self.w * other.y - self.x * other.z + self.y * other.w + self.z * other.x,
            z: self.w * other.z + self.x * other.y - self.y * other.x + self.z * other.w,
        }
    }
}

/// The single axis and angle `rl.drawModelEx` wants, in radians.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AxisAngle {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub rad: f32,
}

/// The yaw/pitch/roll pose of a flyer.
#[must_use]
pub fn pose(state: &State) -> Quat {
    Quat::axis_angle(0.0, 1.0, 0.0, state.yaw)
        * Quat::axis_angle(0.0, 0.0, 1.0, state.pitch)
        * Quat::axis_angle(1.0, 0.0, 0.0, state.roll)
}

/// A quaternion as the one axis-angle the reference draws with. A quaternion
/// close to identity has no meaningful axis, so it answers the identity.
#[must_use]
pub fn axis_angle(q: Quat) -> AxisAngle {
    let w = q.w.clamp(-1.0, 1.0);
    let s = (1.0 - w * w).max(0.0).sqrt();
    if !s.is_finite() || s < 1e-6 {
        return AxisAngle {
            x: 0.0,
            y: 1.0,
            z: 0.0,
            rad: 0.0,
        };
    }
    AxisAngle {
        x: q.x / s,
        y: q.y / s,
        z: q.z / s,
        rad: 2.0 * w.acos(),
    }
}

/// Where a rider sits on the goat's back.
///
/// The drawn goat rotates about `pivot` above its base rather than about its
/// hooves, so the back point is the corrected origin plus the rotated shoulder
/// offset:
///
/// ```text
/// feet = (x, y, z)
/// back = feet + (0, pivot, 0) + R * (0, perch_h - pivot, 0)
/// ```
///
/// At zero pitch/roll this is `feet + (0, perch_h, 0)`; at a pitch it swings the
/// rider about the same point the mesh swings about.
#[must_use]
pub fn back_point(state: &State, perch_h: f32, pivot: f32) -> [f32; 3] {
    let local = pose(state).rotate([0.0, perch_h - pivot, 0.0]);
    [
        state.x + local[0],
        state.y + pivot + local[1],
        state.z + local[2],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::f32::consts::{FRAC_PI_2, PI};

    fn at(yaw: f32, pitch: f32, roll: f32) -> State {
        State {
            yaw,
            pitch,
            roll,
            ..State::default()
        }
    }

    #[test]
    fn zero_is_the_identity() {
        let q = pose(&at(0.0, 0.0, 0.0));
        assert_eq!(q, Quat::IDENTITY);
        let v = q.rotate([1.0, 2.0, 3.0]);
        assert_eq!(v, [1.0, 2.0, 3.0]);
    }

    #[test]
    fn yaw_about_plus_y_maps_forward_to_minus_z() {
        let v = pose(&at(FRAC_PI_2, 0.0, 0.0)).rotate([1.0, 0.0, 0.0]);
        assert!(v[0].abs() < 1e-6, "{v:?}");
        assert!(v[2] < -0.999, "{v:?}");
    }

    #[test]
    fn pitch_about_plus_z_raises_the_nose() {
        let v = pose(&at(0.0, FRAC_PI_2, 0.0)).rotate([1.0, 0.0, 0.0]);
        assert!(v[1] > 0.999, "{v:?}");
    }

    #[test]
    fn roll_about_plus_x_drops_the_right_side() {
        // The model's up +Y tips toward +Z, which is its right side; that is a
        // right bank, so a positive roll.
        let v = pose(&at(0.0, 0.0, FRAC_PI_2)).rotate([0.0, 1.0, 0.0]);
        assert!(v[2] > 0.999, "{v:?}");
    }

    #[test]
    fn the_axis_angle_round_trips_a_quarter_turn() {
        let aa = axis_angle(Quat::axis_angle(0.0, 1.0, 0.0, FRAC_PI_2));
        assert!((aa.x).abs() < 1e-6, "{aa:?}");
        assert!((aa.y - 1.0).abs() < 1e-6, "{aa:?}");
        assert!((aa.z).abs() < 1e-6, "{aa:?}");
        assert!((aa.rad - FRAC_PI_2).abs() < 1e-5, "{aa:?}");
    }

    #[test]
    fn a_whole_turn_is_the_identity_axis_angle() {
        let aa = axis_angle(Quat::axis_angle(0.0, 1.0, 0.0, 2.0 * PI));
        assert_eq!(aa.rad, 0.0);
        assert_eq!(aa.axis_len(), 1.0);
    }

    impl AxisAngle {
        fn axis_len(&self) -> f32 {
            (self.x * self.x + self.y * self.y + self.z * self.z).sqrt()
        }
    }

    #[test]
    fn the_back_point_is_perch_h_at_rest() {
        let state = State {
            x: 2.0,
            y: 3.0,
            z: 4.0,
            ..State::default()
        };
        let p = back_point(&state, 1.15, 0.7);
        assert!((p[0] - 2.0).abs() < 1e-6);
        assert!((p[1] - 4.15).abs() < 1e-6);
        assert!((p[2] - 4.0).abs() < 1e-6);
    }

    #[test]
    fn the_back_point_rotates_about_the_pivot() {
        let state = State {
            x: 0.0,
            y: 0.0,
            z: 0.0,
            pitch: FRAC_PI_2,
            ..State::default()
        };
        // A nose-up quarter turn swings the pitched-up shoulder forward: the
        // local (0, perch - pivot, 0) goes to (-(perch - pivot), 0, 0).
        let p = back_point(&state, 1.15, 0.7);
        assert!((p[0] - -0.45).abs() < 1e-5, "{p:?}");
        assert!((p[1] - 0.7).abs() < 1e-5, "{p:?}");
        assert!(p[2].abs() < 1e-5, "{p:?}");
    }
}
