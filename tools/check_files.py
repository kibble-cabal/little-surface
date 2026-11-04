#!/usr/bin/env python3
"""Compares exports with what the app says it wrote, using Blender's own reader and trimesh.

    python check_files.py <folder holding workflow.* files> <blender_check output>
"""
import json
import sys
from pathlib import Path

import trimesh

folder = Path(sys.argv[1])
expected = json.loads((folder / "workflow.expected.json").read_text())
reports = [json.loads(line.split(" ", 1)[1]) for line in Path(sys.argv[2]).read_text().splitlines() if line.startswith("BLENDER ")]
failures = 0


def check(label, actual, wanted):
    global failures
    ok = actual == wanted
    failures += 0 if ok else 1
    print(f"{'ok  ' if ok else 'FAIL'} {label}: {actual}" + ("" if ok else f" (expected {wanted})"))


obj = next(r for r in reports if r["file"] == "workflow.obj")
for key in ["vertices", "edges", "faces", "quads", "triangles", "ngons"]:
    check(f"Blender OBJ {key}", obj[key], expected[key])
check("Blender OBJ non-manifold edges", obj["nonManifoldEdges"], 0)
check("Blender OBJ inconsistent edges", obj["inconsistentEdges"], 0)
check("Blender OBJ degenerate faces", obj["degenerateFaces"], 0)

glb = next(r for r in reports if r["file"] == "workflow.glb")
if obj["looseEdges"] == 0:
    check("Blender GLB vertices", glb["vertices"], expected["vertices"])
check("Blender GLB triangles", glb["triangles"], expected["quads"] * 2 + expected["triangles"])
check("Blender GLB quads", glb["quads"], 0)
check("Blender GLB inconsistent edges", glb["inconsistentEdges"], 0)

with_source = [r["object"] for r in reports if r["file"] == "workflow_with_source.obj"]
check("Source is a separate OBJ object", len(with_source), 2)
with_source = [r["object"] for r in reports if r["file"] == "workflow_with_source.glb"]
check("Source is a separate GLB node", len(with_source), 2)

scene = trimesh.load(folder / "workflow.glb", force="scene")
geometry = list(scene.geometry.values())
check("trimesh GLB meshes", len(geometry), 1)
check("trimesh GLB faces", len(geometry[0].faces), expected["quads"] * 2 + expected["triangles"])
check("trimesh GLB winding consistent", bool(geometry[0].is_winding_consistent), True)

mesh = trimesh.load(folder / "workflow.obj", force="mesh", process=False)
check("trimesh OBJ triangulated faces", len(mesh.faces), expected["quads"] * 2 + expected["triangles"])

sys.exit(1 if failures else 0)
