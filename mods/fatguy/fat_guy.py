"""Build the fat guy with the small guitar, save the .blend, render it, export the .glb.

Run headless:
  blender -b --factory-startup --python fat_guy.py

Everything is primitives, so the result is the same every run: the .blend keeps the
parts loose (44 meshes, editable), and the .glb is exported from a joined duplicate
(one mesh, one primitive per material) so the game draws 12 submissions instead of
44. The duplicate is deleted before the script ends, so the saved scene is intact.
"""

import json
import os
import struct
from math import radians

import bpy
from mathutils import Euler, Matrix, Vector

HERE = os.path.dirname(os.path.abspath(__file__))
BLEND = os.path.join(HERE, "fat_guy.blend")        # the source, beside the mod
PNG = os.path.join(HERE, "fat_guy.png")            # a render, for looking at
GLB = os.path.join(HERE, "assets", "fat_guy.glb")  # the asset the mod ships


# ---- scene reset -----------------------------------------------------------
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
for block in (bpy.data.meshes, bpy.data.materials, bpy.data.lights, bpy.data.cameras, bpy.data.worlds):
    for item in list(block):
        if item.users == 0:
            block.remove(item)


# ---- materials -------------------------------------------------------------
def material(name, rgb, rough=0.6, metal=0.0):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes.get("Principled BSDF")
    if bsdf is None:
        bsdf = next(n for n in mat.node_tree.nodes if n.type == "BSDF_PRINCIPLED")
    bsdf.inputs["Base Color"].default_value = (rgb[0], rgb[1], rgb[2], 1.0)
    bsdf.inputs["Roughness"].default_value = rough
    bsdf.inputs["Metallic"].default_value = metal
    mat.diffuse_color = (rgb[0], rgb[1], rgb[2], 1.0)
    return mat


M = {
    "skin": material("Skin", (0.92, 0.66, 0.50)),
    "skin_dark": material("SkinDark", (0.78, 0.50, 0.36)),
    "shirt": material("Shirt", (0.85, 0.55, 0.15)),
    "trousers": material("Trousers", (0.16, 0.20, 0.36)),
    "shoe": material("Shoe", (0.12, 0.09, 0.08)),
    "hair": material("Hair", (0.24, 0.14, 0.09)),
    "eye": material("Eye", (0.05, 0.04, 0.05), rough=0.2),
    "wood": material("GuitarWood", (0.55, 0.28, 0.12)),
    "wood_dark": material("GuitarNeck", (0.24, 0.13, 0.08)),
    "hole": material("SoundHole", (0.03, 0.02, 0.02), rough=0.9),
    "string": material("String", (0.85, 0.85, 0.80), rough=0.3, metal=0.9),
    "brass": material("Brass", (0.78, 0.62, 0.22), rough=0.3, metal=0.9),
}


# ---- primitive helpers -----------------------------------------------------
def finish(obj, name, mat, scale=None, smooth=True, auto=False):
    obj.name = name
    if scale is not None:
        obj.scale = scale
    if mat is not None:
        obj.data.materials.append(mat)
    if smooth:
        bpy.ops.object.shade_smooth()
    if auto:
        try:
            bpy.ops.object.shade_auto_smooth(angle=radians(45))
        except Exception:
            pass
    return obj


def sphere(name, loc, r, mat, scale=(1, 1, 1), rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=r, location=loc)
    obj = bpy.context.object
    obj.rotation_euler = rot
    return finish(obj, name, mat, scale)


def cyl(name, loc, r, depth, mat, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cylinder_add(vertices=28, radius=r, depth=depth, location=loc)
    obj = bpy.context.object
    obj.rotation_euler = rot
    return finish(obj, name, mat, None, smooth=True, auto=True)


def box(name, loc, size, mat, rot=(0, 0, 0)):
    bpy.ops.mesh.primitive_cube_add(size=1.0, location=loc)
    obj = bpy.context.object
    obj.rotation_euler = rot
    return finish(obj, name, mat, size, smooth=False)


def limb(name, p0, p1, r, mat):
    a, b = Vector(p0), Vector(p1)
    v = b - a
    bpy.ops.mesh.primitive_cylinder_add(vertices=24, radius=r, depth=v.length, location=(a + b) / 2)
    obj = bpy.context.object
    obj.rotation_mode = "QUATERNION"
    obj.rotation_quaternion = v.to_track_quat("Z", "Y")
    return finish(obj, name, mat, None, smooth=True, auto=True)


# ---- the fat guy (faces -Y, feet at z = 0) ---------------------------------
bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0, 0, 0))
guy = bpy.context.object
guy.name = "FatGuy"

sphere("Belly", (0, 0.02, 0.98), 0.78, M["shirt"], scale=(1.0, 0.92, 0.95))
sphere("Chest", (0, -0.02, 1.46), 0.55, M["shirt"], scale=(1.15, 0.85, 0.78))
box("Belt", (0, -0.55, 0.62), (1.05, 0.16, 0.14), M["wood_dark"])
sphere("BeltBuckle", (0, -0.64, 0.62), 0.09, M["brass"], scale=(1, 0.5, 1))
for side, x in (("L", -0.26), ("R", 0.26)):
    cyl("Leg" + side, (x, 0, 0.32), 0.17, 0.64, M["trousers"])
    sphere("Foot" + side, (x, -0.07, 0.09), 0.19, M["shoe"], scale=(1.0, 1.45, 0.55))
cyl("Neck", (0, -0.03, 1.86), 0.17, 0.22, M["skin"])
sphere("Head", (0, -0.04, 2.16), 0.39, M["skin"], scale=(1.0, 1.02, 1.10))
for side, x in (("L", -0.145), ("R", 0.145)):
    sphere("Eye" + side, (x, -0.34, 2.24), 0.055, M["eye"], scale=(1, 1, 1.15))
    sphere("Brow" + side, (x, -0.33, 2.33), 0.075, M["hair"], scale=(1.4, 0.5, 0.4))
    sphere("Ear" + side, (0.385 * (1 if x > 0 else -1), -0.02, 2.14), 0.10, M["skin"],
           scale=(0.5, 1.0, 1.2))
sphere("Nose", (0, -0.40, 2.13), 0.095, M["skin_dark"], scale=(0.9, 1.25, 0.85))
sphere("Mouth", (0, -0.37, 1.99), 0.085, M["skin_dark"], scale=(1.2, 0.4, 0.5))
for side, x in (("L", -0.11), ("R", 0.11)):
    box("Tash" + side, (x, -0.38, 2.055), (0.16, 0.06, 0.05), M["hair"],
        rot=(0, 0, radians(8 if x > 0 else -8)))
sphere("Hair", (0, 0.02, 2.33), 0.36, M["hair"], scale=(1.0, 1.0, 0.55))

# ---- the small guitar, in its own frame ------------------------------------
guitar = bpy.data.objects.new("Guitar", None)
bpy.context.collection.objects.link(guitar)
sphere("GuitarLowerBout", (0.115, 0, 0), 0.20, M["wood"], scale=(1.0, 1.15, 0.30))
sphere("GuitarUpperBout", (-0.115, 0, 0), 0.145, M["wood"], scale=(1.0, 1.15, 0.30))
sphere("GuitarWaist", (-0.005, 0, 0), 0.125, M["wood"], scale=(1.0, 1.25, 0.29))
cyl("GuitarHole", (0.10, 0, 0.012), 0.055, 0.06, M["hole"], rot=(radians(90), 0, 0))
box("GuitarBridge", (0.265, 0, 0.02), (0.055, 0.15, 0.03), M["wood_dark"])
box("GuitarNeck", (-0.35, 0, 0.012), (0.42, 0.05, 0.028), M["wood_dark"])
box("GuitarFretboard", (-0.35, 0, 0.028), (0.40, 0.055, 0.008), M["hole"])
box("GuitarHead", (-0.60, 0, 0.014), (0.13, 0.075, 0.035), M["wood_dark"])
for i, y in enumerate((-0.045, 0.045)):
    cyl("Peg" + str(i), (-0.56 - i * 0.05, y * 2.1, 0.02), 0.012, 0.07, M["brass"],
        rot=(radians(90), 0, 0))
for i, y in enumerate((-0.036, -0.012, 0.012, 0.036)):
    box("String" + str(i), (-0.15, y, 0.042), (0.74, 0.006, 0.006), M["string"])
box("Nut", (-0.565, 0, 0.03), (0.02, 0.07, 0.02), M["hole"])
for part in list(bpy.context.scene.objects):
    if part is guitar:
        continue
    if part.name.startswith(("Guitar", "String", "Peg", "Nut")):
        part.parent = guitar

GS = 0.60
GM = (
    Matrix.Translation(Vector((0.02, -0.82, 1.12)))
    @ Euler((radians(14), radians(52), radians(-8)), "XYZ").to_matrix().to_4x4()
    @ Matrix.Diagonal(Vector((GS, GS, GS, 1.0)))
)
guitar.matrix_world = GM
NECK_HAND = GM @ Vector((-0.32, 0, 0.05))
BODY_HAND = GM @ Vector((0.13, 0, 0.07))

# ---- arms ------------------------------------------------------------------
S_L = Vector((-0.55, -0.04, 1.50))
S_R = Vector((0.55, -0.04, 1.50))
elbow_l = (S_L + NECK_HAND) / 2 + Vector((-0.10, -0.16, -0.10))
elbow_r = (S_R + BODY_HAND) / 2 + Vector((0.10, -0.18, -0.12))
limb("UpperArmL", S_L, elbow_l, 0.155, M["shirt"])
limb("UpperArmR", S_R, elbow_r, 0.155, M["shirt"])
limb("ForeArmL", elbow_l, NECK_HAND, 0.115, M["skin"])
limb("ForeArmR", elbow_r, BODY_HAND, 0.115, M["skin"])
sphere("HandL", NECK_HAND, 0.135, M["skin"], scale=(1.0, 1.0, 1.2))
sphere("HandR", BODY_HAND, 0.135, M["skin"], scale=(1.0, 1.0, 1.2))
for side, p in (("L", S_L), ("R", S_R)):
    sphere("Shoulder" + side, p, 0.19, M["shirt"])

# Tidy: everything still parentless goes under FatGuy (identity, so nothing moves).
for ob in list(bpy.context.scene.objects):
    if ob.parent is None and ob is not guy:
        ob.parent = guy

# ---- light, world, camera --------------------------------------------------
world = bpy.data.worlds.new("World")
bpy.context.scene.world = world
world.use_nodes = True
bg = world.node_tree.nodes.get("Background")
if bg is not None:
    bg.inputs[0].default_value = (0.18, 0.21, 0.26, 1.0)
    bg.inputs[1].default_value = 1.0

for name, loc, energy, size in (
    ("Key", (-3.4, -4.2, 4.6), 350.0, 5.0),
    ("Fill", (4.2, -3.0, 2.4), 110.0, 6.0),
    ("Rim", (0.6, 4.4, 3.6), 220.0, 4.0),
):
    bpy.ops.object.light_add(type="AREA", location=loc)
    lamp = bpy.context.object
    lamp.name = name
    lamp.data.energy = energy
    lamp.data.size = size
    look = Vector((0, 0, 1.2)) - Vector(loc)
    lamp.rotation_mode = "QUATERNION"
    lamp.rotation_quaternion = look.to_track_quat("-Z", "Y")

bpy.ops.object.empty_add(type="PLAIN_AXES", location=(0, 0, 1.15))
target = bpy.context.object
target.name = "LookAt"
bpy.ops.object.camera_add(location=(-2.6, -5.6, 2.5))
cam = bpy.context.object
cam.name = "Camera"
cam.data.lens = 50.0
track = cam.constraints.new("TRACK_TO")
track.target = target
track.track_axis = "TRACK_NEGATIVE_Z"
track.up_axis = "UP_Y"
bpy.context.scene.camera = cam

scene = bpy.context.scene
for engine in ("BLENDER_EEVEE_NEXT", "BLENDER_EEVEE", "CYCLES"):
    try:
        scene.render.engine = engine
        break
    except Exception:
        continue
try:
    scene.view_settings.view_transform = "Standard"
except Exception:
    pass
scene.render.resolution_x = 900
scene.render.resolution_y = 900
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.filepath = PNG

bpy.ops.wm.save_as_mainfile(filepath=BLEND)
bpy.ops.render.render(write_still=True)

# ---- the game-ready export: one mesh, one primitive per material ------------
meshes = [o for o in bpy.data.objects if o.type == "MESH"]
bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
bpy.ops.object.duplicate()
copies = [o for o in bpy.context.selected_objects if o.type == "MESH"]
bpy.context.view_layer.objects.active = copies[0]
bpy.ops.object.join()
joined = bpy.context.object
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
bpy.ops.export_scene.gltf(
    filepath=GLB,
    export_format="GLB",
    export_apply=True,
    use_selection=True,
    export_animations=False,
    export_cameras=False,
    export_lights=False,
)
bpy.data.objects.remove(joined, do_unlink=True)

# ---- verify -----------------------------------------------------------------
with open(GLB, "rb") as fh:
    raw = fh.read()
chunk_len = struct.unpack("<I", raw[12:16])[0]
gltf = json.loads(raw[20:20 + chunk_len].decode("utf-8"))

print("BUILT objects=%d meshes=%d" % (len(bpy.context.scene.objects),
                                      len([o for o in bpy.data.objects if o.type == "MESH"])))
print("GLB bytes=%d meshes=%d primitives=%d nodes=%d" % (
    os.path.getsize(GLB),
    len(gltf.get("meshes", [])),
    sum(len(m.get("primitives", [])) for m in gltf.get("meshes", [])),
    len(gltf.get("nodes", [])),
))
print("SAVED %s" % BLEND)
print("RENDER %s" % PNG)
