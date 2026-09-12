"""Author the two goat eating clips (`GoatEat`, `GoatEat2`) in `goat.blend`.

Run inside Blender via the MCP addon, e.g.:

    exec(open(r"C:\\Users\\T\\Desktop\\blendermcptest\\tools\\goat_eat.py").read())

Both clips are one-shot meals: the goat crouches, noses its muzzle down to the
grass in front, chews for a moment with small head bobs, then straightens back
up. They are built in the same style as the other clips -- the four legs are
solved with the 2-link IK against targets on the ground plane, and the
spine/neck/head/tail are keyed from parametric curves. The GLB is re-exported
and the blend saved at the end.

The muzzle must not sink through the ground: the clip is measured with the
depsgraph and `result` reports the mesh z range so the head-down angles can be
dialled in (a grazing goat reaches with a crouch, `Root` dropped, which bends
the legs while the IK keeps the hooves planted).
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


# Chewing: a small, fast head bob, faded in and out at the ends of the hold so
# it joins the smooth reach without a step.
def chew(t, start, end, freq, amp):
    if t < start or t > end:
        return 0.0
    edge = min(t - start, end - t)
    k = min(1.0, edge / 0.12)
    return amp * k * math.sin(2 * math.pi * freq * (t - start))


# ---- eat 1: a leisurely graze ---------------------------------------------
# Crouch, nose all the way down, chew for a beat, straighten up. 2.5 s.

EAT_N = 60
EAT_ROOT = [(0, 0), (0.35, -0.03), (0.7, -0.10), (1.6, -0.10), (1.9, -0.05), (2.3, 0), (2.5, 0)]
EAT_NECK = [(0, 0), (0.35, -22), (0.7, -48), (1.6, -48), (1.95, -18), (2.3, 0), (2.5, 0)]
EAT_HEAD = [(0, 0), (0.35, -20), (0.7, -38), (1.6, -38), (1.95, -15), (2.3, 0), (2.5, 0)]
EAT_YAW = [(0, 0), (0.6, 0), (0.95, 8), (1.3, -6), (1.6, 0), (2.5, 0)]
EAT_TAIL = [(0, 0), (0.5, 0), (0.8, 13), (1.05, 0), (1.7, -9), (2.0, 0), (2.5, 0)]


def build_eat():
    act = new_action('GoatEat')
    for i in range(EAT_N + 1):
        t = i / 24.0
        root_y = interp(EAT_ROOT, t)
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            # a small front-foot shuffle as it noses in
            off = 0.03 * math.sin(2 * math.pi * t / 2.5) if leg in ('FrontL', 'FrontR') else 0.0
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(interp(EAT_NECK, t)),
            'Head': qx(interp(EAT_HEAD, t) + chew(t, 0.78, 1.56, 4.5, 4.5))
                @ qz(interp(EAT_YAW, t)),
            'Tail': qz(interp(EAT_TAIL, t)),
        })
    set_interp(act)


# ---- eat 2: a quick bite and a longer chew, head turned the other way ------

EAT2_N = 52
EAT2_ROOT = [(0, 0), (0.3, -0.03), (0.6, -0.09), (1.5, -0.09), (1.75, -0.05), (2.05, 0), (2.17, 0)]
EAT2_NECK = [(0, 0), (0.3, -26), (0.6, -44), (1.5, -44), (1.8, -20), (2.05, 0), (2.17, 0)]
EAT2_HEAD = [(0, 0), (0.3, -22), (0.6, -34), (1.5, -34), (1.8, -15), (2.05, 0), (2.17, 0)]
EAT2_YAW = [(0, 0), (0.55, 0), (0.9, -9), (1.25, 6), (1.5, 0), (2.17, 0)]
EAT2_TAIL = [(0, 0), (0.45, 0), (0.72, 11), (0.98, 0), (1.6, -8), (1.9, 0), (2.17, 0)]


def build_eat2():
    act = new_action('GoatEat2')
    for i in range(EAT2_N + 1):
        t = i / 24.0
        root_y = interp(EAT2_ROOT, t)
        hz = HIP_Z + root_y
        ab = {}
        for leg in LEGS:
            hx = hip_sign[leg] * HIP_X
            off = 0.03 * math.sin(2 * math.pi * t / 2.17 + 1.0) if leg in ('FrontL', 'FrontR') else 0.0
            ab[leg] = leg_angles(hx, hz, hx + off, GROUND)
        key_frame(i + 1, root_y, Quaternion(), ab, {
            'Neck': qx(interp(EAT2_NECK, t)),
            'Head': qx(interp(EAT2_HEAD, t) + chew(t, 0.68, 1.46, 5.5, 5.0))
                @ qz(interp(EAT2_YAW, t)),
            'Tail': qz(interp(EAT2_TAIL, t)),
        })
    set_interp(act)


CLAMP[0] = 0
build_eat()
eat_lo, eat_hi = clip_min_max('GoatEat', EAT_N)
build_eat2()
eat2_lo, eat2_hi = clip_min_max('GoatEat2', EAT2_N)

result = {
    "clamped_ik": CLAMP[0],
    "eat": {"mesh_z": [round(eat_lo, 4), round(eat_hi, 4)], "frames": EAT_N + 1},
    "eat2": {"mesh_z": [round(eat2_lo, 4), round(eat2_hi, 4)], "frames": EAT2_N + 1},
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
