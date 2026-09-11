"""Author the goat's eyelids in `goat.blend`.

Run inside Blender via the MCP addon, e.g.:

    exec(open(r"C:\\Users\\T\\Desktop\\blendermcptest\\tools\\goat_eyelids.py").read())

Adds a `LidL`/`LidR` bone per eye plus a spherical-cap shell over each eyeball,
weighted 100% to its lid bone. The bone's head sits at the eye centre and its
tail points along +X, so the bone's local Y is the hinge: rotating about it
sweeps the cap down over the eye. Closing is -90 deg on LidL and +90 on LidR
(the eyes face outward, +Y / -Y), which is measured below by how well the closed
cap covers the iris.

Every action gets lid keys -- closed in `GoatSleep`, open everywhere else --
because raylib only resets a bone that a clip actually animates, so a lid keyed
in just one clip would stay stuck in the others. The GLB is exported and the
blend saved.

The geometry is built once; re-running raises rather than duplicating it.
"""

import bpy
import bmesh
import math
import os
from mathutils import Vector

arm = bpy.data.objects['GoatArmature']
goat = bpy.data.objects['Goat']
me = goat.data
ad = arm.animation_data
scene = bpy.context.scene

# Eye centres in Blender space (Z up, goat faces +X), from the mesh's iris faces.
EYE = {'L': Vector((0.93, 0.135, 1.27)), 'R': Vector((0.93, -0.135, 1.27))}
R_EYE, R_LID, HALF = 0.05, 0.0555, math.radians(72)
RINGS, SEGS = 5, 14
CLOSED_DEG = {'L': -90.0, 'R': 90.0}

result = {}


def quat_y(deg):
    r = math.radians(deg) * 0.5
    return (math.cos(r), 0.0, math.sin(r), 0.0)


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


# ---- geometry -------------------------------------------------------------

if 'LidL' in arm.data.bones:
    raise RuntimeError('eyelids already exist; rebuild goat.blend from a clean export')

fur = [i for i, m in enumerate(me.materials) if m and m.name == 'GoatFur'][0]
uv_data = me.uv_layers.active.data
anchor_uv = None
for p in me.polygons:
    if p.material_index != fur:
        continue
    for li in p.loop_indices:
        if (me.vertices[me.loops[li].vertex_index].co - EYE['L']).length < 0.09:
            anchor_uv = tuple(uv_data[li].uv)
            break
    if anchor_uv:
        break

old_v = len(me.vertices)
bm = bmesh.new()
bm.from_mesh(me)
uvl = bm.loops.layers.uv.active
faces = []
for side in ('L', 'R'):
    c = EYE[side]
    pole = bm.verts.new(c + Vector((0, 0, R_LID)))
    rings = []
    for i in range(1, RINGS + 1):
        t = HALF * i / RINGS
        st, ct = math.sin(t), math.cos(t)
        rings.append([bm.verts.new(c + Vector((R_LID * st * math.cos(2 * math.pi * j / SEGS),
                                               R_LID * st * math.sin(2 * math.pi * j / SEGS),
                                               R_LID * ct))) for j in range(SEGS)])
    for j in range(SEGS):
        faces.append((bm.faces.new((pole, rings[0][j], rings[0][(j + 1) % SEGS])), side))
    for i in range(len(rings) - 1):
        for j in range(SEGS):
            faces.append((bm.faces.new((rings[i][j], rings[i + 1][j],
                                        rings[i + 1][(j + 1) % SEGS], rings[i][(j + 1) % SEGS])), side))

# The cap is a radial patch, so a face whose normal points back at the eye centre
# is wound the wrong way.
bm.normal_update()
flipped = 0
for f, side in faces:
    if (f.calc_center_median() - EYE[side]).dot(f.normal) < 0:
        f.normal_flip()
        flipped += 1
    f.material_index = fur
    f.smooth = True
    for lp in f.loops:
        lp[uvl].uv = anchor_uv
bm.normal_update()
bm.to_mesh(me)
bm.free()
me.update()
result['flipped_faces'] = flipped
result['added_verts'] = len(me.vertices) - old_v

lid_v = {'L': [], 'R': []}
for i in range(old_v, len(me.vertices)):
    lid_v['L' if me.vertices[i].co.y > 0 else 'R'].append(i)
for side in ('L', 'R'):
    goat.vertex_groups.new(name='Lid' + side).add(lid_v[side], 1.0, 'REPLACE')
result['lid_verts'] = {k: len(v) for k, v in lid_v.items()}

# ---- bones ----------------------------------------------------------------

bpy.ops.object.select_all(action='DESELECT')
arm.select_set(True)
bpy.context.view_layer.objects.active = arm
bpy.ops.object.mode_set(mode='EDIT')
ebs = arm.data.edit_bones
for side in ('L', 'R'):
    b = ebs.new('Lid' + side)
    b.head = EYE[side]
    b.tail = EYE[side] + Vector((0.06, 0, 0))   # local Y = world X = the hinge
    b.parent = ebs['Head']
    b.use_connect = False
    b.use_deform = True
bpy.ops.object.mode_set(mode='OBJECT')
result['bones'] = len(arm.data.bones)

# ---- how well the closed cap covers the iris ------------------------------

iris_idx = {i for i, m in enumerate(me.materials) if m and m.name in ('GoatIris', 'GoatPupil')}
iris = {vi for p in me.polygons if p.material_index in iris_idx for vi in p.vertices}
iris_side = {'L': [i for i in iris if me.vertices[i].co.y > 0],
             'R': [i for i in iris if me.vertices[i].co.y < 0]}


def coverage(deg_l, deg_r):
    arm.pose.bones['LidL'].rotation_mode = 'QUATERNION'
    arm.pose.bones['LidR'].rotation_mode = 'QUATERNION'
    arm.pose.bones['LidL'].rotation_quaternion = quat_y(deg_l)
    arm.pose.bones['LidR'].rotation_quaternion = quat_y(deg_r)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = goat.evaluated_get(dg)
    m = ev.to_mesh()
    out = {}
    for side in ('L', 'R'):
        c = EYE[side]
        dirs = [(m.vertices[i].co - c).normalized() for i in lid_v[side]]
        worst = 0.0
        for i in iris_side[side]:
            d = (m.vertices[i].co - c).normalized()
            worst = max(worst, min(math.degrees(d.angle(ld)) for ld in dirs))
        out[side] = round(worst, 1)
    ev.to_mesh_clear()
    return out


# The lid cap is centred on the eye, so a 0-degree pose sits *above* the eye
# (open) and 90 degrees sweeps it onto the outward face (closed). The gaps below
# are the worst-case angle between an iris vertex and the nearest lid vertex;
# the closed surface interpolates between vertices, so it covers better still.
result['iris_gap_open'] = coverage(0, 0)
result['iris_gap_closed'] = coverage(CLOSED_DEG['L'], CLOSED_DEG['R'])

# ---- key the lids in every clip -------------------------------------------

for name in ['GoatIdle', 'GoatWalk', 'GoatTrot', 'GoatRun', 'GoatJump', 'GoatSleep', 'GoatDeath']:
    act = bpy.data.actions[name]
    ad.action = act
    ad.action_slot = act.slots[0]
    f0, f1 = int(act.frame_range[0]), int(act.frame_range[1])
    closed = (name == 'GoatSleep')
    for side in ('L', 'R'):
        pb = arm.pose.bones['Lid' + side]
        pb.rotation_mode = 'QUATERNION'
        pb.rotation_quaternion = quat_y(CLOSED_DEG[side]) if closed else (1.0, 0.0, 0.0, 0.0)
        pb.keyframe_insert('rotation_quaternion', frame=f0)
        pb.keyframe_insert('rotation_quaternion', frame=f1)
    for fc in fcurves_of(act):
        if 'Lid' in fc.data_path:
            for kp in fc.keyframe_points:
                kp.interpolation = 'BEZIER'
    result[name] = 'closed' if closed else 'open'

for pb in arm.pose.bones:
    pb.rotation_quaternion = (1, 0, 0, 0)
bpy.context.view_layer.update()

bpy.ops.object.select_all(action='DESELECT')
for n in ('Goat', 'GoatArmature'):
    bpy.data.objects[n].select_set(True)
bpy.context.view_layer.objects.active = arm
glb = r"C:\Users\T\Desktop\blendermcptest\goat_animated.glb"
bpy.ops.export_scene.gltf(
    filepath=glb, export_format='GLB', use_selection=True, export_animations=True,
    export_animation_mode='ACTIONS', export_anim_slide_to_zero=True, export_skins=True,
    export_def_bones=False, export_yup=True, export_apply=False, export_image_format='AUTO')
bpy.ops.wm.save_mainfile()
result['glb_size'] = os.path.getsize(glb)
