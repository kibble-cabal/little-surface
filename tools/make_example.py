# Runs inside Blender. Builds Little Surface's own example model, an original creature bust: ellipsoids
# merged by voxel remeshing and smoothed, so the surface is one closed skin with no topology worth keeping.
#   Blender --background --factory-startup --python tools/make_example.py -- out.glb [voxel size]
import sys

import bpy

args = sys.argv[sys.argv.index("--") + 1:]
out_path = args[0]
voxel = float(args[1]) if len(args) > 1 else 0.021

bpy.ops.wm.read_factory_settings(use_empty=True)
parts = []


def ellipsoid(x, y, z, sx, sy, sz, mirror=True, rotate=(0, 0, 0)):
    for side in ((1, -1) if mirror and abs(x) > 1e-4 else (1,)):
        bpy.ops.mesh.primitive_uv_sphere_add(segments=48, ring_count=32, location=(x * side, y, z), scale=(sx, sy, sz), rotation=(rotate[0], rotate[1] * side, rotate[2] * side))
        parts.append(bpy.context.active_object)


def remesh_and_smooth(obj, size, smooth):
    mod = obj.modifiers.new("Remesh", "REMESH")
    mod.mode = "VOXEL"
    mod.voxel_size = size
    mod.use_smooth_shade = True
    bpy.ops.object.modifier_apply(modifier=mod.name)
    mod = obj.modifiers.new("Smooth", "LAPLACIANSMOOTH")
    mod.iterations = smooth
    mod.lambda_factor = 0.8
    mod.use_volume_preserve = True
    bpy.ops.object.modifier_apply(modifier=mod.name)


# Blender's -Y is the front, which glTF export turns into +Z.
ellipsoid(0, 0.02, 1.2, 0.72, 0.68, 0.62, mirror=False)      # skull
ellipsoid(0, -0.22, 0.88, 0.5, 0.44, 0.36, mirror=False)     # jaw
ellipsoid(0.33, -0.36, 0.96, 0.25, 0.2, 0.2)                 # cheeks
ellipsoid(0, -0.58, 0.86, 0.19, 0.2, 0.13, mirror=False)     # snout
ellipsoid(0, -0.76, 0.92, 0.08, 0.06, 0.055, mirror=False)   # nose
ellipsoid(0.27, -0.6, 1.24, 0.13, 0.1, 0.13)               # eyes
ellipsoid(0.3, -0.52, 1.4, 0.2, 0.09, 0.07, rotate=(0, 0.2, 0))  # brows
ellipsoid(0.46, 0.02, 1.8, 0.17, 0.09, 0.4, rotate=(0, 0.3, 0))    # ears
ellipsoid(0, 0.05, 0.42, 0.4, 0.38, 0.5, mirror=False)      # neck
ellipsoid(0, 0.03, -0.22, 0.84, 0.48, 0.46, mirror=False)    # chest
ellipsoid(0.72, 0.05, -0.2, 0.34, 0.31, 0.34)                # shoulders
ellipsoid(0.22, -0.34, -0.14, 0.26, 0.14, 0.18)              # collar
ellipsoid(0, 0.36, 0.05, 0.34, 0.2, 0.42, mirror=False)      # upper back

bpy.ops.object.select_all(action="DESELECT")
for part in parts:
    part.select_set(True)
bpy.context.view_layer.objects.active = parts[0]
bpy.ops.object.join()
body = bpy.context.active_object
body.name = "Creature Bust"
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)

# A coarse pass melts the parts together, and a fine one gives the final resolution.
remesh_and_smooth(body, 0.03, 8)
remesh_and_smooth(body, voxel, 6)

# Cut the base flat, as a sculptor's bust stands.
bpy.ops.object.mode_set(mode="EDIT")
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.bisect(plane_co=(0, 0, -0.42), plane_no=(0, 0, 1), clear_outer=False, clear_inner=True, use_fill=True)
bpy.ops.mesh.select_all(action="SELECT")
bpy.ops.mesh.quads_convert_to_tris(quad_method="BEAUTY", ngon_method="BEAUTY")
bpy.ops.mesh.normals_make_consistent(inside=False)
bpy.ops.object.mode_set(mode="OBJECT")
bpy.ops.object.shade_smooth()

bpy.ops.export_scene.gltf(filepath=out_path, export_format="GLB", use_selection=True, export_materials="NONE", export_yup=True, export_apply=True, export_texcoords=False)
print("EXAMPLE", len(body.data.polygons), "triangles")
