# Developing Little Surface

How to build the app, how it's put together, how it's tested, and what has and hasn't been checked. The [README](../README.md) is for people using the app.

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

## Architecture

There are two layers, and the geometry layer knows nothing about UIKit, SwiftUI or Metal.

**`Core/` (`LittleSurfaceCore`, a Swift package)** holds the geometry and the file formats, and can be tested on the Mac with `swift test`.

| Folder | What it does |
| --- | --- |
| `Mesh`, `Topology` | The editable mesh, its connectivity, and the plans that change it |
| `Spatial`, `Source` | Imported source objects and their BVHs for ray casting and surface projection |
| `Stroke`, `Patch` | Turning strokes into edges, loops and strips, bridging chains with quads, and spotting side-by-side lines worth filling |
| `Editing`, `Selection`, `Brush`, `Symmetry` | Mesh operations, picking, brushes and mirroring |
| `Subdivision`, `Validation` | Catmull-Clark preview and mesh checks |
| `History` | Undo snapshots with a memory budget |
| `IO`, `Document` | OBJ and glTF/GLB, and the versioned project file |
| `Sketch` | Planning strokes and their palette. They're saved and undone with the project but never join the mesh |
| `Timelapse` | The recorder that keeps a compressed frame for every edit, and the director that turns them into timed shots |
| `Link` | The small piece of HTTP the Blender add-on speaks |
| `Engine` | `RetopoEngine`, the entry point the app talks to |

Tools describe what they want as a `TopologyPlan`, which a previewer can draw and `PlanApplier` can commit. A preview and its commit therefore use the same geometry.

**`App/`** holds everything specific to the iPad.

| Folder | What it does |
| --- | --- |
| `Input` | `ViewportView` separates Pencil from fingers and handles navigation, palm rejection and hover |
| `Renderer` | `ViewportRenderer` and the Metal shaders. Faces are pulled slightly toward the eye so they sit on the model, and tint it where they still dip under |
| `Editor` | `EditorModel` connects the engine to SwiftUI and runs imports and previews off the main thread. `TimelapseExporter` renders the video |
| `Link` | `BlenderLinkServer`, the listener for the add-on |
| `Document` | `ProjectDocument` (a `UIDocument`, for autosave and safe writing) and `ProjectLibrary` (recents and thumbnails) |
| `UI` | SwiftUI views: welcome, editor, tool panels and theme. System navigation, inspector and forms with an emerald accent, using Liquid Glass on iPadOS 26 and materials on iPadOS 18 |

**`blender/little_surface_link.py`** is the Blender add-on. It uses only Blender and Python's standard library, and the app bundles it so people can save it from the Blender Link sheet.

### The Blender link

The app listens on TCP port 48620 while the link is on and the project is on screen. Every request carries the six-digit code in `X-Little-Surface-Code`. Ten wrong codes in a row turn the link off.

| Request | What it does |
| --- | --- |
| `GET /status` | Project name, counts and sculpt names, as JSON |
| `GET /mesh` | The mesh as OBJ, or 204 when it's empty |
| `GET /outbox` | The mesh waiting from Send Mesh to Blender, once, or 204 |
| `POST /mesh?name=&replace=1` | Adds an OBJ to the mesh, or replaces the mesh with `replace=1` |
| `POST /sculpt?name=` | Adds an OBJ as a sculpt, or updates the sculpt with that name so the topology follows |

Answers are 409 when the app is busy, 422 for a file it can't read, 400 for an empty body, and 401 for a wrong code.

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
| Core tests (`swift test`, with third-party samples) | 311 run: 310 passed, 0 failed, and the timing test skipped by default |
| App tests (document save and reopen, damaged file, bundled example, shaders compile, timelapse video, Blender link) | 26 of 26 passed |
| UI tests in the running app | 12 of 12 passed |

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
- **Tools:** Quad Strip with preview; Move, Relax and Erase brushes; lasso selection; a one-line patch that explains what's missing and leaves the mesh unchanged; Clear; filling between side-by-side lines (16 × 8 quads). Tapping two lines in Draw Edges, creating the patch and landing in Select. By hand, with touch: an oval drawn with Quad Patch, which made a 9 × 9 grid of 81 quads; a nearly closed stroke made into a Quad Strip ring; a line beside a finished patch filled up to its edge (12 × 4 quads); a loop inside a loop offering a 35 × 5 ring; a line carried on from another's end; and a stroke joining two lines. A stroke between a line's two ends closing it is covered by core tests only.
- **Viewing:** Wireframe, X-ray and Solid; hiding the source and the topology; dark mode in landscape; by hand, two-finger tap to undo.
- **Files:** the system file picker; a damaged GLB giving a clear error; a second model added to a project; a project killed as soon as its import was saved reopened with the model; a project killed after editing reopened with its mesh and selection.

### Newer features

- **Sculpt updates:** core tests, and in the running app through the Blender link.
- **Existing meshes:** core tests, and in the running app through the Blender link.
- **Poly budget and jumps:** a UI test.
- **Autosave and undo:** core and app tests, plus the undo checks in the UI tests.
- **Sketch:** a UI test, and by hand: red and blue lines drawn, then the red traced with Draw Edges (22 vertices, 21 edges) with the sketch left in place.
- **Timelapse:** app and core tests, and by hand: a 9.1 s, 273-frame, 1080 × 1080 H.264 video, also exported from a reopened project. Contact sheets and full-size frames were checked for framing, the eased turn, the badge and hidden far-side lines.
- **Blender link:** core and app tests over real sockets, a UI test that posts a mesh into the running app, and a script run in Blender 5.2.2 against the simulator app, over both `127.0.0.1` and the Mac's network address. All 33 checks passed: a wrong code, an empty address and an unreachable one are refused; send as sculpt and as mesh, adding and replacing; a 56-vertex, 54-face quad mesh came back with every vertex in place to 0.001, including after its transforms were applied in Blender; getting it again updates one object; a changed sculpt moved the mesh onto it; names with spaces and pluses; several objects at once; modifiers applied; sending and getting from Edit and Sculpt mode without leaving them. A 1,310,720-triangle sculpt took 2.4 s over the Mac's own network stack. Blender's window was also run: the panel draws, and Watch for Meshes collected a mesh sent with the app's button.

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
- Haptics have never been felt. iPads have no haptic motor, so they only reach an Apple Pencil Pro, which the 2020 iPad can't use. The simulator can't play them either, so the code is only known to compile and be called.

- The add-on's Blender 4.2 minimum comes from the APIs it uses. Only Blender 5.2.2 has actually run it.
- The Blender link has never crossed real Wi-Fi. In the simulator the app shares the Mac's network, so transfer speed on Wi-Fi, a sleeping iPad, and the iPadOS local network permission prompt are all unknown.

**Not tested in the app**

- iCloud Drive, and Save to Files from the share sheet. Export was tested up to the share sheet, and the files were read from the app's temporary folder.
- Nearly all of the testing was in portrait, the simulator's default. Only the dark mode UI test ran in landscape, even though the layout is designed landscape first.
- Slide, Weld, Connect, Flip, and merging or applying symmetry at the centerline are covered by core tests only, not UI tests.
- Two-finger undo has no UI test, because XCTest can't aim a two-finger tap at the viewport under a navigation stack. It was checked by hand with simulated touches.
- Closing a stroke into a loop, the fill offers, carrying a line on and joining lines have only been drawn with touch, so how forgiving they feel with a Pencil is unknown.
- The app has only run on iPadOS 26.3. The iPadOS 18 fallback for Liquid Glass compiles but has never been run.

**Files**

- Draco-compressed glTF isn't supported.
- Materials and textures are ignored on import.
- A `.gltf` file with external buffers needs access to its neighbouring files, which the file picker may not grant.
- GLB export leaves out wire edges that have no face. OBJ keeps them.

**Behaviour**

- A failed import started from the welcome screen leaves an empty project with that name.
- A stroke that runs off the model breaks into separate pieces and doesn't close, even if its ends meet.
- A line drawn beside a closed loop that has no faces gets no fill offer, because a loop beside a line is more often a separate feature than one side of a patch.
- Two loops around a limb only get a ring offer once both are closed, which takes more than one stroke from more than one view.
- Haptics play when a stroke ends, not while it's being drawn.
- In portrait, the inspector covers the right of the viewport rather than moving the model aside.
- The self-intersection check is approximate.
- Undo history is held in memory and doesn't survive reopening a project.
- A timelapse replays on the current sculpt, needs the app kept on screen, and thins its frames evenly past 24 MB.
- A fill between sides with very different point counts can bunch and slant its rows near one end.
- The Blender link is plain HTTP on the local network, protected only by its six-digit code, and it's off by default.
- The mesh checks report facts and never declare a mesh animation-ready. That judgement stays with you.
