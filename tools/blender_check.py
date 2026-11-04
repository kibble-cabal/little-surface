# Runs inside Blender. Imports each file and prints its topology as one JSON line per mesh object.
#   Blender --background --factory-startup --python tools/blender_check.py -- file.obj file.glb
import json
import os
import sys

import bmesh
import bpy


def report(path):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    if path.lower().endswith(".obj"):
        bpy.ops.wm.obj_import(filepath=path)
    else:
        bpy.ops.import_scene.gltf(filepath=path)
    for obj in bpy.data.objects:
        if obj.type != "MESH":
            continue
        bm = bmesh.new()
        bm.from_mesh(obj.data)
        faces = list(bm.faces)
        inconsistent = sum(1 for e in bm.edges if len(e.link_faces) == 2 and not e.is_contiguous)
        print("BLENDER " + json.dumps({
            "file": os.path.basename(path),
            "object": obj.name,
            "vertices": len(bm.verts),
            "edges": len(bm.edges),
            "faces": len(faces),
            "quads": sum(1 for f in faces if len(f.verts) == 4),
            "triangles": sum(1 for f in faces if len(f.verts) == 3),
            "ngons": sum(1 for f in faces if len(f.verts) > 4),
            "nonManifoldEdges": sum(1 for e in bm.edges if len(e.link_faces) > 2),
            "looseEdges": sum(1 for e in bm.edges if len(e.link_faces) == 0),
            "boundaryEdges": sum(1 for e in bm.edges if len(e.link_faces) == 1),
            "inconsistentEdges": inconsistent,
            "degenerateFaces": sum(1 for f in faces if f.calc_area() < 1e-12),
        }))
        bm.free()


for file_path in sys.argv[sys.argv.index("--") + 1:]:
    report(file_path)
