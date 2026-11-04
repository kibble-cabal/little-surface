# Little Surface

A native iPad app for manual retopology. Import a 3D model, draw topology lines directly on its surface with Apple Pencil, generate real quad geometry between those lines, edit the mesh freely, and export the result to Blender.

Everything runs on the device. There are no accounts, no remote services and no third-party libraries.

**How far this has been tested:** it has only been run in the iPad simulator, never on a real iPad, so Apple Pencil feel and on-device performance are unverified. See [Verified functionality](#verified-functionality) and [Known limitations](#known-limitations).

## Build and run

You need a Mac with Xcode 26.3 or later (the iOS 26 SDK). The app targets iPadOS 18.0 and is designed for the 2020 iPad (8th generation) as its minimum device.

1. Open `LittleSurface.xcodeproj`.
2. Choose the **LittleSurface** scheme and an iPad simulator or device.
3. Press Run.

Nothing else needs setting up:

- **No packages to fetch.** The geometry code is a local Swift package, `Core/`.
- **No Metal Toolchain needed.** The shaders ship as source (`App/Renderer/Shaders.msl`) and compile when the app starts.
- **Run uses the Release configuration on purpose.** The geometry code is far slower in Debug. Tests use Debug.

To run on a real iPad, select your own team under Signing & Capabilities. The project is set to team `45PQ9B4M25` and bundle id `com.audreyserene.littlesurface`.

`project.yml` is the source for the Xcode project. You only need [XcodeGen](https://github.com/yonaskolb/XcodeGen) if you change it, because the generated project is committed.

### Trying it without a Pencil

The simulator has no Pencil, so one finger orbits by default and nothing draws. Open Settings (the gear icon), then set **One finger** to **Draw, as a Pencil would**. To set it for a single launch:

```bash
xcrun simctl launch --terminate-running-process booted com.audreyserene.littlesurface -oneFingerAction draw
```

## Using it

1. On the welcome screen, tap **Example** for the bundled model, or **Import Model** for your own OBJ, GLB or glTF file.
2. With **Draw Edges**, draw two lines on the surface.
3. With **Quad Patch**, tap both lines, check the preview, and tap **Create Patch**.
4. With **Select**, tap or lasso to select, and drag a selected element to move it. The panel on the right holds the topology operations.
5. Tap **Export** to send an OBJ (quads) or GLB (triangulated) to Blender, with or without the source model.

An optional tutorial appears on first launch.

## Architecture

There are two layers, and the geometry layer knows nothing about UIKit, SwiftUI or Metal.

**`Core/` (`LittleSurfaceCore`, a Swift package)** holds the geometry and the file formats, and can be tested on the Mac with `swift test`.

| Folder | What it does |
| --- | --- |
| `Mesh`, `Topology` | The editable mesh, its connectivity, and the plans that change it |
| `Spatial`, `Source` | Imported source objects and their BVHs for ray casting and surface projection |
| `Stroke`, `Patch` | Turning strokes into edges, loops and strips, and bridging chains with quads |
| `Editing`, `Selection`, `Brush`, `Symmetry` | Mesh operations, picking, brushes and mirroring |
| `Subdivision`, `Validation` | Catmull-Clark preview and mesh checks |
| `History` | Undo snapshots with a memory budget |
| `IO`, `Document` | OBJ and glTF/GLB, and the versioned project file |
| `Engine` | `RetopoEngine`, the entry point the app talks to |

Tools describe what they want as a `TopologyPlan`, which a previewer can draw and `PlanApplier` can commit. A preview and its commit therefore use the same geometry.

**`App/`** holds everything specific to the iPad.

| Folder | What it does |
| --- | --- |
| `Input` | `ViewportView` separates Pencil from fingers and handles navigation, palm rejection and hover |
| `Renderer` | `ViewportRenderer` and the Metal shaders |
| `Editor` | `EditorModel` connects the engine to SwiftUI and runs imports and previews off the main thread |
| `Document` | `ProjectDocument` (a `UIDocument`, for autosave and safe writing) and `ProjectLibrary` (recents and thumbnails) |
| `UI` | SwiftUI views: welcome, editor, tool panels and theme |

## Tests

**Core tests**, from `Core/`:

```bash
swift test
```

These cover connectivity, split, faces, weld, strips, patches, symmetry, projection, subdivision, undo and redo, OBJ and GLB round trips, reopening projects, and randomized editing sessions that check the mesh stays valid. Two sets are skipped unless you point them at model files: `LS_SAMPLES=<folder>` imports third-party samples, and `LS_PERF_MODEL=<file>` runs the timing tests, which need an optimized build (`swift test -c release -Xswiftc -enable-testing --filter PerformanceTests`).

**App and UI tests** use the app's own scheme:

```bash
xcodebuild test -project LittleSurface.xcodeproj -scheme LittleSurface -destination 'platform=iOS Simulator,name=iPad (A16)'
```

Replace `iPad (A16)` with any iPad simulator you have installed.

`UITests/WorkflowUITests.swift` drives the running app with synthesized touches, from import through export.

**Checking exports with other tools.** Both scripts need `CHECK_TOOLS` set to a folder holding a Python venv with `trimesh` and `node_modules/gltf-validator`, plus Blender. `tools/verify_export.sh` exports from the core workflow test. `tools/verify_app_exports.sh` checks the files the simulator app left behind after the UI tests.

The bundled example is an original model generated by `tools/make_example.py`. Third-party sample models were used only for import tests and aren't in this repository.

## Verified functionality

All of this ran on an M1 Max Mac using an iPad (A16) simulator on iOS 26.3. A fresh clone also builds without any extra setup, for the simulator and, unsigned, for a device.

| Suite | Result |
| --- | --- |
| Core tests (`swift test`, with third-party samples) | 190 passed, 0 failed; the timing test is skipped by default |
| App tests (document save and reopen, damaged file, bundled example, shaders compile) | 5 of 5 passed |
| UI tests in the running app | 6 of 6 passed |

The timing test was run separately, with the results under [Large models](#large-models).

### The full workflow, run by a UI test

`testFullWorkflow` runs this in the app with synthesized touches:

1. Import the example (71,198 triangles), change view with the gizmo, pinch to zoom, and frame the model.
2. Draw two strokes, preview the patch, and create 128 quads.
3. Undo and redo.
4. Move a vertex, then add and delete a face.
5. Turn on symmetry and check that a stroke mirrors.
6. Preview subdivision and confirm the mesh itself doesn't change.
7. Save, go back, reopen with the same vertex, edge and face counts, and edit again.
8. Export OBJ and GLB through the share sheet, with and without the source.

### Exports checked outside the app

These files came from that UI test and were checked by `tools/verify_app_exports.sh`:

| File | Checked with | Result |
| --- | --- | --- |
| OBJ | Blender 5.2 | 163 vertices, 288 edges, 128 faces, all quads; no non-manifold edges, inconsistent normals or degenerate faces; 8 loose wire edges, kept as OBJ `l` lines; counts match the app |
| GLB | Khronos glTF validator | 0 errors, 0 warnings; 153 vertices, 256 triangles |
| GLB with source | Khronos glTF validator, Blender | 0 errors, 0 warnings; 2 objects, and the source has its full 71,198 triangles |

### Other features exercised in the running app

- **Editing:** Subdivide, Relax, Reverse, Fix Normals, Loop, Ring, Connected, Boundary, Extrude, Split, Delete, Fill, Dissolve, and each one's undo. Operations with nothing selected do nothing.
- **Mesh checks:** the Check Mesh report.
- **Tools:** Quad Strip with preview; Move, Relax and Erase brushes; lasso selection; a refused patch that explains why and leaves the mesh unchanged; closing a drawn loop through the prompt (Close Loop, Keep Open, Cancel).
- **Viewing:** Wireframe, X-ray and Solid; hiding the source and the topology; two-finger tap to undo; dark mode in landscape.
- **Files:** the system file picker; a damaged GLB giving a clear error; a second model added to a project; a project killed as soon as its import was saved reopened with the model; a project killed after editing reopened with its mesh and selection.

### Large models

A 514,232-triangle GLB imported in the background with progress and a Cancel button, and could then be orbited, panned and zoomed. Memory stayed around 263 to 288 MB. Its project file was 7.8 MB, and the camera came back on reopening.

Timings for that model in an optimized build **on the Mac, not an iPad**:

| Step | Time |
| --- | --- |
| Parse | 0.10 s |
| Build BVH | 0.19 s |
| 10,000 ray casts | 0.005 s |
| 240-sample stroke | under 1 ms |
| Encode project (off the main thread) | 1.3 s |
| Decode project | 0.025 s |

Expect an A12 iPad to be several times slower. How much slower hasn't been measured.

## Known limitations

**Not tested on hardware**

- Nothing has run on a physical iPad. Apple Pencil pressure, hover, double-tap, palm rejection and drawing latency have never been exercised with real input. The UI tests draw with a finger, which goes through the same engine calls but not the app's Pencil branch.
- Frame rate, memory limits and heat on the 2020 iPad are unknown. Simulator rendering uses the Mac's GPU.
- The 2020 iPad uses the first-generation Pencil, which has no double-tap or hover, so those features only help on newer hardware.

**Not tested in the app**

- iCloud Drive, and Save to Files from the share sheet. Export was tested up to the share sheet, and the files were read from the app's temporary folder.
- Nearly all of the testing was in portrait, the simulator's default. Only the dark mode UI test ran in landscape, even though the layout is designed landscape first.
- Slide, Weld, Connect, Flip, and merging or applying symmetry at the centerline are covered by core tests only, not UI tests.

**Files**

- Draco-compressed glTF isn't supported.
- Materials and textures are ignored on import.
- A `.gltf` file with external buffers needs access to its neighbouring files, which the file picker may not grant.
- GLB export leaves out wire edges that have no face. OBJ keeps them.

**Behaviour**

- A failed import started from the welcome screen leaves an empty project with that name.
- The self-intersection check is approximate.
- The mesh checks report facts and never declare a mesh animation-ready. That judgement stays with you.
