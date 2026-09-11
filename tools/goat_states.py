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


def key_frame(frame, root_y, root_q, leg_ab, extra):
    root = arm.pose.bones['Root']
    root.location = (0.0, root_y, 0.0)
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


# ---- death: buckle, slump onto the side, hold ------------------------------

DEATH_N = 44                       # ~1.8 s
D_ROLL = [(1, 0.0), (8, 0.05), (16, 0.12), (24, 0.17), (32, 0.18), (44, 0.18)]
D_ROOTY = [(1, -0.08), (8, -0.22), (16, -0.30), (24, -0.34), (32, -0.36), (44, -0.36)]
D_HEAD = [(1, 0), (8, -14), (16, -8), (24, 2), (32, 5), (44, 5)]
D_NECK = [(1, 0), (8, -8), (16, -5), (24, 1), (32, 3), (44, 3)]
D_TAIL = [(1, 0), (8, 4), (16, 0), (24, -6), (32, -8), (44, -8)]
D_FOFF = [(1, 0.0), (8, -0.02), (16, -0.05), (24, -0.06), (32, -0.07), (44, -0.07)]
D_BOFF = [(1, 0.0), (8, 0.02), (16, 0.05), (24, 0.06), (32, 0.07), (44, 0.07)]


def build_death(root_lift, foot_lift):
    act = new_action('GoatDeath')
    for frame in range(1, DEATH_N + 1):
        root_y = interp(D_ROOTY, frame) + root_lift
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            front = leg in ('FrontL', 'FrontR')
            off = interp(D_FOFF if front else D_BOFF, frame)
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND + foot_lift)
        key_frame(frame, root_y, qxr(interp(D_ROLL, frame)), ab, {
            'Neck': qx(interp(D_NECK, frame)),
            'Head': qx(interp(D_HEAD, frame)),
            'Tail': qz(interp(D_TAIL, frame)),
        })
    set_interp(act)


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

build_death(0.0, 0.0)
death_min, _ = clip_min_max('GoatDeath', DEATH_N)
death_lift = round(max(0.0, -death_min), 4)
build_death(0.0, death_lift)
death_min2, _ = clip_min_max('GoatDeath', DEATH_N)
death_root_lift = round(max(0.0, -death_min2), 4)
if death_root_lift > 0.0:
    build_death(death_root_lift, death_lift)
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
    "death": {"foot_lift": death_lift, "root_lift": death_root_lift,
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
