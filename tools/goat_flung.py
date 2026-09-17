"""Author the M19f `GoatFlung` clip in `goat.blend`.

Run inside Blender against `goat.blend`, e.g.:

    blender --background goat.blend --python tools/goat_flung.py

The contract is *The mechanics* in `ROADMAP.md`: one action, phase 0 at the instant
of the blast, phase 1 at ground contact, auto-grounded at both ends and with no root
motion that carries the goat's *height* -- the arc in `goat.js` owns that. What the
clip owns is the tumble: the placeholder (`flingDraw`) rolls the goat itself, and the
moment the model has this clip the roll is dropped, because two rotations fight.

The tumble is a rotation of the `Root` about the goat's *barrel* rather than about
its hooves, so it is a rotation plus the translation that keeps the pivot where it
is (`t = p - R*p`, derived in the Root's own frame rather than in world axes, since
that is the frame `pose.bones[...].location` is expressed in). The vertical part of
that translation is root motion; the ROADMAP's "rootless" is about the *arc's*
height, and this clip is grounded at both ends so the goat never sits above or below
the ground it takes off from or lands on.

Like `goat_states.py`, every frame is keyed and the clip is walked with the
depsgraph to measure ground clearance; a per-frame residual lifts whatever still
passes below z = 0, so the tumble cannot clip through the ground it is flying over.
"""

import bpy
import json
import math
import os
from mathutils import Quaternion, Vector

arm = bpy.data.objects['GoatArmature']
ad = arm.animation_data
scene = bpy.context.scene
goat = bpy.data.objects['Goat']

L1, L2, GROUND, HIP_X, HIP_Z = 0.26, 0.28, 0.02, 0.34, 0.56
LEGS = ['FrontL', 'FrontR', 'BackL', 'BackR']
BONE = {'FrontL': ('UpperFrontL', 'LowerFrontL'), 'FrontR': ('UpperFrontR', 'LowerFrontR'),
        'BackL': ('UpperBackL', 'LowerBackL'), 'BackR': ('UpperBackR', 'LowerBackR')}
hip_sign = {'FrontL': 1, 'FrontR': 1, 'BackL': -1, 'BackR': -1}
FRONT = ('FrontL', 'FrontR')
CLAMP = [0]

FLUNG_N = 48                       # 2 s at 24 fps; the arc stretches it
TURNS = 1.0                        # whole turns over the clip: it lands on its feet

# The barrel: the rotation's centre, which is the goat's own centre of mass, measured
# off the rest mesh rather than guessed (see below, once the pose is at rest). A tumble
# about the hooves would swing the body a metre and a half below the arc it is flying
# on, which is why the clip carries the compensating translation (`t = p - R*p`) and
# why the pivot has to be the middle of the body.
ad.action = None
scene.frame_set(1)


def fcurves_of(a):
    try:
        return list(a.fcurves)
    except AttributeError:
        pass
    out = []
    for layer in a.layers:
        for strip in layer.strips:
            for cb in strip.channelbags:
                out.extend(cb.fcurves)
    return out


def qx(d): return Quaternion((math.cos(math.radians(d) / 2), math.sin(math.radians(d) / 2), 0, 0))
def qz(d): return Quaternion((math.cos(math.radians(d) / 2), 0, 0, math.sin(math.radians(d) / 2)))
def qzr(r): return Quaternion((math.cos(r * 0.5), 0.0, 0.0, math.sin(r * 0.5)))
def qxr(r): return Quaternion((math.cos(r * 0.5), math.sin(r * 0.5), 0.0, 0.0))


def leg_angles(hx, hz, tx, tz):
    dx, dz = tx - hx, tz - hz
    d = math.hypot(dx, dz)
    dmax, dmin = (L1 + L2) * 0.999, abs(L1 - L2) + 1e-4
    if d > dmax or d < dmin:
        CLAMP[0] += 1
    d = max(dmin, min(d, dmax))
    beta = math.atan2(-dx, -dz)
    cosd = max(-1.0, min(1.0, (d * d - L1 * L1 - L2 * L2) / (2 * L1 * L2)))
    delta = -math.acos(cosd)
    return beta - math.atan2(L2 * math.sin(delta), L1 + L2 * math.cos(delta)), delta


def new_action(name):
    if name in bpy.data.actions:
        bpy.data.actions.remove(bpy.data.actions[name])
    act = bpy.data.actions.new(name)
    act.use_fake_user = True
    ad.action = act
    act.slots.new(id_type='OBJECT', name='GoatArmature')
    ad.action_slot = act.slots[0]
    for pb in arm.pose.bones:
        pb.rotation_mode = 'QUATERNION'
    return act


def set_interp(act):
    for fc in fcurves_of(act):
        for kp in fc.keyframe_points:
            kp.interpolation = 'BEZIER'
            kp.handle_left_type = 'AUTO_CLAMPED'
            kp.handle_right_type = 'AUTO_CLAMPED'


def interp(ctrl, x):
    if x <= ctrl[0][0]:
        return ctrl[0][1]
    if x >= ctrl[-1][0]:
        return ctrl[-1][1]
    for (x0, y0), (x1, y1) in zip(ctrl, ctrl[1:]):
        if x0 <= x <= x1:
            return y0 + (y1 - y0) * ((x - x0) / (x1 - x0) if x1 > x0 else 0.0)
    return ctrl[-1][1]


def mesh_z():
    dg = bpy.context.evaluated_depsgraph_get()
    go = goat.evaluated_get(dg)
    me = go.to_mesh()
    zs = [(go.matrix_world @ v.co).z for v in me.vertices]
    go.to_mesh_clear()
    return min(zs), max(zs)


def mesh_centre():
    dg = bpy.context.evaluated_depsgraph_get()
    go = goat.evaluated_get(dg)
    me = go.to_mesh()
    xs = [(go.matrix_world @ v.co) for v in me.vertices]
    c = Vector((sum(p.x for p in xs) / len(xs),
                sum(p.y for p in xs) / len(xs),
                sum(p.z for p in xs) / len(xs)))
    go.to_mesh_clear()
    return c


# ---- the clip ---------------------------------------------------------------
#
# The shape of the arc, in the clip's own time (0 = the blast, 1 = the ground):
#
#   * the shove: legs braced, head thrown back, the spine arched;
#   * the flight: the legs splay (front forward, back behind) at the peak, then tuck
#     under for the turn's second half, which is what a thrown body does;
#   * the landing: legs down and bent, head up and forward, so the goat reads as
#     ready to run rather than as a second get-up clip the player has to wait out.
#
# In the sagittal plane the legs are IK'd to the ground under the body, the way every
# other clip does it -- so `hz` is the hip's height *relative to the body* and the
# hoof offset `off` is what splays them. Far enough out and the reach clamps, which
# is the IK saying "fully extended" rather than an error.
L_HZ = [(0, 0.56), (0.10, 0.50), (0.35, 0.47), (0.60, 0.45), (0.85, 0.48), (1.0, 0.46)]
L_FOFF = [(0, 0.0), (0.10, 0.24), (0.35, 0.34), (0.60, 0.02), (0.80, -0.10), (1.0, 0.0)]
L_BOFF = [(0, 0.0), (0.10, -0.22), (0.35, -0.33), (0.60, -0.02), (0.80, 0.10), (1.0, 0.0)]
SPINE = [(0, 0), (0.10, 7), (0.35, 2), (0.60, -9), (0.85, -3), (1.0, 2)]
NECK = [(0, -16), (0.10, -20), (0.35, -6), (0.60, 14), (0.85, 2), (1.0, -6)]
HEAD = [(0, -12), (0.10, -14), (0.35, -4), (0.60, 11), (0.85, 1), (1.0, -4)]
TAIL = [(0, -4), (0.10, -22), (0.35, -30), (0.60, -16), (0.85, -8), (1.0, -2)]
YAW = [(0, 0), (0.35, 6), (0.60, -5), (1.0, 0)]
# The turn: a shade slower at the start (the blast shoves before it spins) and it
# finishes a whole turn, which is what puts the hooves back under the goat.
TURN = [(0, 0.0), (0.15, 0.10), (0.5, 0.52), (0.85, 0.93), (1.0, 1.0)]

ROOT_REST = arm.data.bones['Root'].matrix_local
ROOT_R3 = ROOT_REST.to_3x3()
ROOT_R3_INV = ROOT_R3.inverted()
WORLD_SIDE = Vector((0.0, 1.0, 0.0))     # the goat faces +X, so +Y is its side
BODY_PIVOT = mesh_centre()               # in armature space, which is world here
PIVOT_L = ROOT_REST.inverted() @ BODY_PIVOT


def flung_root(theta):
    """The Root's rotation and the translation that keeps it about the barrel."""
    r_world = Quaternion(WORLD_SIDE, theta)
    r_local = ROOT_R3_INV.to_quaternion() @ r_world @ ROOT_R3.to_quaternion()
    return r_local, PIVOT_L - (r_local @ PIVOT_L)


def build_flung(residual):
    act = new_action('GoatFlung')
    root = arm.pose.bones['Root']
    for i in range(FLUNG_N + 1):
        t = i / float(FLUNG_N)
        theta = TURNS * 2.0 * math.pi * interp(TURN, t)
        r_local, t_local = flung_root(theta)
        hz = interp(L_HZ, t)
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            off = interp(L_FOFF if leg in FRONT else L_BOFF, t)
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND)
        root.rotation_quaternion = r_local
        root.keyframe_insert('rotation_quaternion', frame=i + 1)
        # `location` is in the Root's own frame, whose Y runs up the bone -- so the
        # residual is added there, as a world-space height, exactly as the sleep and
        # death clips do it.
        root.location = (t_local.x, t_local.y + residual[i], t_local.z)
        root.keyframe_insert('location', frame=i + 1)
        for leg, (a, b) in ab.items():
            up, lo = BONE[leg]
            arm.pose.bones[up].rotation_quaternion = qzr(a)
            arm.pose.bones[up].keyframe_insert('rotation_quaternion', frame=i + 1)
            arm.pose.bones[lo].rotation_quaternion = qzr(b)
            arm.pose.bones[lo].keyframe_insert('rotation_quaternion', frame=i + 1)
        extra = {
            'Spine': qx(interp(SPINE, t)),
            'Neck': qx(interp(NECK, t)),
            'Head': qx(interp(HEAD, t)) @ qz(interp(YAW, t)),
            'Tail': qx(interp(TAIL, t)),
        }
        for name in ('Spine', 'Neck', 'Head', 'Tail'):
            arm.pose.bones[name].rotation_quaternion = extra[name]
            arm.pose.bones[name].keyframe_insert('rotation_quaternion', frame=i + 1)
    set_interp(act)


def frame_mins(n):
    ad.action = bpy.data.actions['GoatFlung']
    ad.action_slot = bpy.data.actions['GoatFlung'].slots[0]
    out = []
    for i in range(n + 1):
        scene.frame_set(i + 1)
        out.append(mesh_z()[0])
    return out


def clip_min_max(n):
    ad.action = bpy.data.actions['GoatFlung']
    ad.action_slot = bpy.data.actions['GoatFlung'].slots[0]
    lo, hi = 9.9, -9.9
    for i in range(n + 1):
        scene.frame_set(i + 1)
        mn, mx = mesh_z()
        lo = min(lo, mn)
        hi = max(hi, mx)
    return lo, hi


# Build with no lift, then relax twice, because the *landing* correction is two-sided
# and changes what the frames before it clear.
CLAMP[0] = 0
residual = [0.0] * (FLUNG_N + 1)
for _ in range(3):
    build_flung(residual)
    mins = frame_mins(FLUNG_N)
    for i, m in enumerate(mins):
        residual[i] += max(0.0, -m)
    # The landing is the one frame that has to be *exactly* on the plane: a bent leg
    # rotates the hoof's rigid geometry, so the pose that reads as a crouch leaves the
    # hoof hanging a few centimetres up. Lifting cannot fix that, so the correction is
    # two-sided and ramped in over the last fifth of the clip, which reads as the goat
    # settling onto its feet.
    settle = mins[FLUNG_N]
    if settle > 0.0:
        for i in range(FLUNG_N + 1):
            t = i / float(FLUNG_N)
            if t > 0.8:
                residual[i] -= settle * (t - 0.8) / 0.2
build_flung(residual)
lo, hi = clip_min_max(FLUNG_N)

# What the clip owns, measured: how far the body's centre wanders from where it
# started (a tumble about the centre of mass keeps it near its own rest position --
# the *arc* is what moves it through the world), the root's own height range, and the
# clearance at the two frames the goat is on the ground.
drift = 0.0
for i in range(FLUNG_N + 1):
    scene.frame_set(i + 1)
    drift = max(drift, (mesh_centre() - BODY_PIVOT).length)
scene.frame_set(1)
start_lo = mesh_z()[0]
scene.frame_set(FLUNG_N + 1)
end_lo = mesh_z()[0]

roots = []
ad.action = bpy.data.actions['GoatFlung']
ad.action_slot = bpy.data.actions['GoatFlung'].slots[0]
for i in range(FLUNG_N + 1):
    scene.frame_set(i + 1)
    roots.append(arm.pose.bones['Root'].location.y)

result = {
    "clamped_ik": CLAMP[0],
    "frames": FLUNG_N + 1,
    "body_pivot": [round(v, 4) for v in BODY_PIVOT],
    "mesh_z_min": round(lo, 4),
    "mesh_z_max": round(hi, 4),
    "start_ground": round(start_lo, 4),
    "end_ground": round(end_lo, 4),
    "max_residual": round(max(residual), 4),
    "centre_drift": round(drift, 4),
    "root_y_min": round(min(roots), 4),
    "root_y_max": round(max(roots), 4),
    "actions": sorted(a.name for a in bpy.data.actions),
}

bpy.ops.object.select_all(action='DESELECT')
for name in ('Goat', 'GoatArmature'):
    bpy.data.objects[name].select_set(True)
bpy.context.view_layer.objects.active = bpy.data.objects['GoatArmature']
glb = r"C:\Users\T\Desktop\blendermcptest\goat_animated.glb"
bpy.ops.export_scene.gltf(
    filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
    export_animation_mode='ACTIONS', export_anim_slide_to_zero=True, export_skins=True,
    export_def_bones=False, export_yup=True, export_apply=False, export_image_format='AUTO')
bpy.ops.wm.save_mainfile()
result["glb_size"] = os.path.getsize(glb)
print("FLUNG_RESULT " + json.dumps(result))
