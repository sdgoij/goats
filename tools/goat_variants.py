"""Author the animation-variant clips for `goat.blend`.

Run inside Blender via the MCP addon:

    exec(open(r"C:\\Users\\T\\Desktop\\blendermcptest\\tools\\goat_variants.py").read())

Adds `GoatIdle2` (grazing), `GoatIdle3` (alert / looking around), `GoatSleep2`
(a second sleeping posture) and `GoatJump2` (a bigger bound), all in the same
style as the originals: the four legs are solved with the 2-link IK against
targets on the ground plane, and the spine/neck/head/tail are keyed from
parametric curves. The GLB is re-exported and the blend saved at the end.

The idle and sleep variants are built to loop: every periodic term divides the
clip length and every control curve starts and ends at the same value.
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


# ---- idle 2: grazing -------------------------------------------------------
# Head down in the grass, slow sway, one front leg shifting its weight, the tail
# flicking off the odd fly. 7 s so every period divides the clip.

IDLE2_N = 168
IDLE2_TAIL = [(0, 0), (1.2, 0), (1.45, 13), (1.75, 0), (4.4, 0), (4.65, -11),
              (4.95, 0), (7.0, 0)]


def build_idle2():
    act = new_action('GoatIdle2')
    for i in range(IDLE2_N + 1):
        t = i / 24.0
        root_y = -0.095 + 0.008 * math.sin(2 * math.pi * t / 7.0)
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            sgn = 1.0 if leg in ('FrontL', 'FrontR') else -1.0
            dx = sgn * 0.022 * math.sin(2 * math.pi * t / 7.0)
            ab[leg] = leg_angles(hx, hz, hx + dx, GROUND)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(-(20 + 4 * math.sin(2 * math.pi * t / 3.5))),
            'Head': qx(-(16 + 5 * math.sin(2 * math.pi * t / (7.0 / 3.0) + 1.0)))
                @ qz(9 * math.sin(2 * math.pi * t / 7.0)),
            'Tail': qz(interp(IDLE2_TAIL, t)),
        })
    set_interp(act)


# ---- idle 3: alert, looking around ----------------------------------------
# Head up, big held turns left and right, tail swishing. 6 s.

IDLE3_N = 144
IDLE3_YAW = [(0, 0), (1.1, 0), (1.9, 27), (3.3, 30), (4.1, 0), (5.1, -26), (6.0, 0)]


def build_idle3():
    act = new_action('GoatIdle3')
    for i in range(IDLE3_N + 1):
        t = i / 24.0
        root_y = -0.078 + 0.006 * math.sin(2 * math.pi * t / 6.0)
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            ab[leg] = leg_angles(hx, hz, hx, GROUND)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(6 + 2 * math.sin(2 * math.pi * t / 3.0)),
            'Head': qx(4 + 2 * math.sin(2 * math.pi * t / 2.0)) @ qz(interp(IDLE3_YAW, t)),
            'Tail': qz(8 * math.sin(2 * math.pi * t / 3.0)),
        })
    set_interp(act)


# ---- sleep 2: curled the other way ----------------------------------------

SLEEP2_N = 192
SLEEP2_ROOT = -0.27
SLEEP2_YAW = [(0, -8), (2.6, -8), (3.3, -19), (4.2, -11), (8.0, -8)]
SLEEP2_TAIL = [(0, 0), (1.8, 0), (2.05, 11), (2.35, 0), (6.2, 0), (6.45, -8), (6.75, 0), (8.0, 0)]


def build_sleep2(foot_lift):
    act = new_action('GoatSleep2')
    for i in range(SLEEP2_N + 1):
        t = i / 24.0
        br = math.sin(2 * math.pi * t / 4.0)
        root_y = SLEEP2_ROOT + 0.006 * br
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            off = 0.04 if leg in ('FrontL', 'FrontR') else -0.02
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND + foot_lift)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(-(26 + 2 * br)),
            'Head': qx(-(20 + 3 * math.sin(2 * math.pi * t / 4.0 + 0.5))) @ qz(interp(SLEEP2_YAW, t)),
            'Tail': qz(interp(SLEEP2_TAIL, t) + 3.0 * br),
        })
    set_interp(act)


# ---- jump 2: a bigger bound ------------------------------------------------
# Deeper crouch, a higher arc and a proper leg tuck at the apex. ~1.33 s.

JUMP2_N = 32
J2_ROOT = [(0, -0.08), (0.12, -0.20), (0.25, -0.26), (0.37, -0.12), (0.5, 0.14),
           (0.62, 0.42), (0.75, 0.54), (0.87, 0.42), (1.0, 0.16), (1.12, -0.06),
           (1.25, -0.22), (1.333, -0.08)]
J2_FOOT = [(0, 0.0), (0.25, 0.0), (0.37, 0.05), (0.5, 0.22), (0.62, 0.36),
           (0.75, 0.38), (0.87, 0.30), (1.0, 0.12), (1.12, 0.0), (1.333, 0.0)]
J2_OFF = [(0, 0.02), (0.25, 0.11), (0.5, 0.06), (0.75, -0.07), (1.0, -0.10),
          (1.2, -0.04), (1.333, 0.0)]
J2_HEAD = [(0, 0), (0.25, -10), (0.5, 6), (0.75, 12), (1.0, 4), (1.333, 0)]
J2_NECK = [(0, 0), (0.25, -8), (0.5, 4), (0.75, 9), (1.0, 3), (1.333, 0)]
J2_TAIL = [(0, 0), (0.25, -6), (0.75, 15), (1.0, 4), (1.333, 0)]


def build_jump2():
    act = new_action('GoatJump2')
    for i in range(JUMP2_N + 1):
        t = i / 24.0
        root_y = interp(J2_ROOT, t)
        hz = HIP_Z + root_y
        foot_z = GROUND + interp(J2_FOOT, t)
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            sgn = 1.0 if leg in ('FrontL', 'FrontR') else -1.0
            ab[leg] = leg_angles(hx, hz, hx + sgn * interp(J2_OFF, t), foot_z)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(interp(J2_NECK, t)),
            'Head': qx(interp(J2_HEAD, t)),
            'Tail': qz(interp(J2_TAIL, t)),
        })
    set_interp(act)


# Build them, ground the sleep variant against the rest hooves, and report.
CLAMP[0] = 0
build_idle2()
idle2_lo, idle2_hi = clip_min_max('GoatIdle2', IDLE2_N)
build_idle3()
idle3_lo, idle3_hi = clip_min_max('GoatIdle3', IDLE3_N)
build_jump2()
jump2_lo, jump2_hi = clip_min_max('GoatJump2', JUMP2_N)

build_sleep2(0.0)
sleep2_min, _ = clip_min_max('GoatSleep2', SLEEP2_N)
sleep2_lift = round(max(0.0, -sleep2_min), 4)
if sleep2_lift > 0.0:
    build_sleep2(sleep2_lift)
sleep2_lo, sleep2_hi = clip_min_max('GoatSleep2', SLEEP2_N)

result = {
    "clamped_ik": CLAMP[0],
    "idle2": {"mesh_z": [round(idle2_lo, 4), round(idle2_hi, 4)], "frames": IDLE2_N + 1},
    "idle3": {"mesh_z": [round(idle3_lo, 4), round(idle3_hi, 4)], "frames": IDLE3_N + 1},
    "sleep2": {"foot_lift": sleep2_lift, "mesh_z": [round(sleep2_lo, 4), round(sleep2_hi, 4)],
               "frames": SLEEP2_N + 1},
    "jump2": {"mesh_z": [round(jump2_lo, 4), round(jump2_hi, 4)], "frames": JUMP2_N + 1},
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
