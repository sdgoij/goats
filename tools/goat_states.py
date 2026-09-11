"""Author the M1 goat state clips (`GoatSleep`, `GoatDeath`) in `goat.blend`.

Run inside Blender via the MCP addon, e.g.:

    exec(open(r"C:\\Users\\T\\Desktop\\blendermcptest\\tools\\goat_states.py").read())

Both actions are keyed every frame, then walked with the depsgraph to measure
ground clearance; a compensating lift is applied and the action rebuilt so the
lowest mesh vertex rests on z = 0 (the rest hooves' height). The GLB is then
exported and the blend saved. `result` carries the measurements plus the eye
points the JS uses for the closed-eye / X-eye sprites.
"""

import bpy
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
CLAMP = [0]


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


def key_frame(frame, root_y, root_q, leg_ab, extra, root_side=0.0):
    root = arm.pose.bones['Root']
    root.location = (0.0, root_y, root_side)
    root.keyframe_insert('location', frame=frame)
    root.rotation_quaternion = root_q
    root.keyframe_insert('rotation_quaternion', frame=frame)
    for leg, (a, b) in leg_ab.items():
        up, lo = BONE[leg]
        arm.pose.bones[up].rotation_quaternion = qzr(a)
        arm.pose.bones[up].keyframe_insert('rotation_quaternion', frame=frame)
        arm.pose.bones[lo].rotation_quaternion = qzr(b)
        arm.pose.bones[lo].keyframe_insert('rotation_quaternion', frame=frame)
    for name in ('Spine', 'Neck', 'Head', 'Tail'):
        arm.pose.bones[name].rotation_quaternion = extra.get(name, Quaternion())
        arm.pose.bones[name].keyframe_insert('rotation_quaternion', frame=frame)


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


# ---- sleep: recumbent, slow breathing, a couple of head shifts -------------

SLEEP_N = 192                      # 8 s at 24 fps
SLEEP_ROOT = -0.27
SLEEP_BREATH = 0.008
SLEEP_HEAD = [(0, -18), (1.5, -19), (2.5, -16), (3.0, -18), (4.5, -20), (6.0, -17), (8.0, -18)]
SLEEP_YAW = [(0, 0), (2.0, 0), (2.6, 10), (3.6, 12), (4.4, 0), (6.0, -9), (6.8, 0), (8.0, 0)]
SLEEP_NECK = [(0, -26), (1.5, -28), (3.0, -26), (4.5, -29), (6.0, -26), (8.0, -26)]
SLEEP_TAIL = [(0, 0), (2.4, 0), (2.7, 10), (3.0, 0), (6.2, 0), (6.5, -7), (6.8, 0), (8.0, 0)]


def build_sleep(foot_lift):
    act = new_action('GoatSleep')
    for i in range(SLEEP_N + 1):
        t = i / 24.0
        br = math.sin(2 * math.pi * t / 4.0)
        root_y = SLEEP_ROOT + SLEEP_BREATH * br
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            off = -0.05 if leg in ('FrontL', 'FrontR') else 0.05
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND + foot_lift)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(interp(SLEEP_NECK, t) + 1.2 * br),
            'Head': qx(interp(SLEEP_HEAD, t) + 1.5 * br) @ qz(interp(SLEEP_YAW, t)),
            'Tail': qz(interp(SLEEP_TAIL, t) + 4.0 * br),
        })
    set_interp(act)


# ---- death: buckle, topple onto the side, hold -----------------------------
#
# The goat rolls about the Root's forward axis far enough to actually lie on
# its side (the old clip only slumped ~10 degrees). The legs stay in the sagittal
# IK plane, so once the body is over they stick out stiffly -- the classic dead
# goat silhouette.

DEATH_N = 56                       # ~2.3 s
DEATH_PIVOT = -0.30                # the ground edge (on -Y) it tips over
D_ROLL = [(1, 0.0), (3, 0.02), (7, 0.10), (12, 0.45), (17, 0.95), (22, 1.30),
          (28, 1.46), (36, 1.52), (56, 1.53)]
D_ROOTY = [(1, -0.08), (8, -0.20), (14, -0.16), (24, -0.10), (56, -0.08)]
D_HEAD = [(1, 0), (7, -14), (14, -6), (22, 10), (30, 16), (56, 16)]
D_NECK = [(1, 0), (7, -11), (14, -4), (22, 8), (30, 12), (56, 12)]
D_TAIL = [(1, 0), (7, 5), (14, 0), (22, -9), (30, -12), (56, -12)]
D_FOFF = [(1, 0.0), (7, -0.05), (14, -0.12), (22, -0.22), (30, -0.28), (56, -0.30)]
D_BOFF = [(1, 0.0), (7, 0.05), (14, 0.12), (22, 0.24), (30, 0.32), (56, 0.34)]


def build_death(residual):
    # The roll is about the Root's forward axis, but a goat tips over its own
    # edge, not its centreline. Emulate a pivot at (0, DEATH_PIVOT, 0) on the
    # ground by rolling about the Root and translating so that edge stays put:
    #   t = p0 - R*p0  ->  y = -y0*sin(th), side = -y0*(1 - cos(th))
    # `residual` is a per-frame vertical correction that sweeps up whatever the
    # legs and the emulation still leave below z = 0.
    act = new_action('GoatDeath')
    for frame in range(1, DEATH_N + 1):
        th = interp(D_ROLL, frame)
        y0 = DEATH_PIVOT
        root_y = interp(D_ROOTY, frame) - y0 * math.sin(th) + residual[frame - 1]
        root_side = -y0 * (1.0 - math.cos(th))
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            front = leg in ('FrontL', 'FrontR')
            off = interp(D_FOFF if front else D_BOFF, frame)
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND)
        key_frame(frame, root_y, qxr(th), ab, {
            'Neck': qx(interp(D_NECK, frame)),
            'Head': qx(interp(D_HEAD, frame)),
            'Tail': qz(interp(D_TAIL, frame)),
        }, root_side)
    set_interp(act)


def frame_mins(act_name, n):
    ad.action = bpy.data.actions[act_name]
    ad.action_slot = bpy.data.actions[act_name].slots[0]
    out = []
    for i in range(n):
        scene.frame_set(i + 1)
        out.append(mesh_z()[0])
    return out


def clip_min_max(act_name, n):
    ad.action = bpy.data.actions[act_name]
    ad.action_slot = bpy.data.actions[act_name].slots[0]
    lo, hi = 9.9, -9.9
    for i in range(n + 1):
        scene.frame_set(i + 1)
        mn, mx = mesh_z()
        lo = min(lo, mn)
        hi = max(hi, mx)
    return lo, hi


# Build, ground against the rest hooves (z = 0), then rebuild with the lift.
CLAMP[0] = 0
build_sleep(0.0)
sleep_min, _ = clip_min_max('GoatSleep', SLEEP_N)
sleep_lift = round(max(0.0, -sleep_min), 4)
if sleep_lift > 0.0:
    build_sleep(sleep_lift)
sleep_lo, sleep_hi = clip_min_max('GoatSleep', SLEEP_N)

build_death([0.0] * DEATH_N)
# Three relaxation passes: changing the root height changes the leg IK, which
# changes what the lowest vertex is, so one pass is not enough to settle.
death_residual = [0.0] * DEATH_N
for _ in range(3):
    build_death(death_residual)
    for i, m in enumerate(frame_mins('GoatDeath', DEATH_N)):
        death_residual[i] += max(0.0, -m)
build_death(death_residual)
death_lo, death_hi = clip_min_max('GoatDeath', DEATH_N)


def eyes_at(act_name, frame):
    ad.action = bpy.data.actions[act_name]
    ad.action_slot = bpy.data.actions[act_name].slots[0]
    scene.frame_set(frame)

    def eye(blender_eye):
        head = arm.pose.bones['Head']
        rest = arm.data.bones['Head'].matrix_local
        p = head.matrix @ (rest.inverted() @ Vector(blender_eye))
        return [round(p.x, 4), round(p.z, 4), round(-p.y, 4)]

    return {"L": eye((0.90, 0.14, 1.19)), "R": eye((0.90, -0.14, 1.19))}


result = {
    "clamped_ik": CLAMP[0],
    "sleep": {"foot_lift": sleep_lift, "mesh_z_min": round(sleep_lo, 4), "mesh_z_max": round(sleep_hi, 4)},
    "death": {"max_residual": round(max(death_residual), 4),
              "mesh_z_min": round(death_lo, 4), "mesh_z_max": round(death_hi, 4)},
    "sleep_eyes_gltf": eyes_at('GoatSleep', 1),
    "death_eyes_gltf": eyes_at('GoatDeath', DEATH_N),
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
