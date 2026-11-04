# Little Surface

Retopology for iPad. Bring in a sculpt, draw your topology on it with Apple Pencil, and take clean quads back to Blender or anything else that reads OBJ or GLB.

Everything stays on your iPad. There's no account and nothing goes to a server.

Little Surface is built for the 2020 iPad and newer, with iPadOS 18 or later. It has been tested in the iPad simulator so far, so how it feels with a real Pencil on a real iPad is still being worked out.

## Getting started

1. On the welcome screen, tap **Example** for a model to practice on, or **Import Model** for your own OBJ, GLB or glTF file.
2. Pick **Draw Edges** and draw two lines side by side on the model.
3. Tap **Fill with Quads** when it's offered.

An optional tutorial appears the first time you open the app.

No Pencil? One finger orbits the view by default. In Settings (the gear icon), set **One finger** to **Draw, as a Pencil would**.

## Drawing topology

- **Lines:** draw with **Draw Edges**. A stroke that starts near the end of a line carries that line on, and a stroke across two or more lines joins them.
- **Loops:** draw a stroke whose ends land near each other and it closes. **Keep Open** undoes that in one tap.
- **Fills:** a fill is offered for two lines side by side, a line beside a finished patch, or a loop inside or around another loop. To choose the sides yourself, tap two lines, or use **Quad Patch** to draw a closed shape.
- **Strips:** **Quad Strip** lays a band of quads along a stroke, or a ring if the stroke closes.
- **Symmetry:** turn it on and your strokes mirror across the model.

## Editing

Use **Select** to tap or lasso points, edges and faces, and drag them to move them. The panel on the right holds operations such as Extrude, Split, Fill, Dissolve, Weld, Relax and Subdivide. The **Move**, **Relax** and **Erase** brushes work directly on the mesh.

Two-finger tap undoes. Your work saves itself a couple of seconds after each change. Undo history lasts until you close the project, so it won't be there when you reopen it.

## Planning with a sketch

Pick the **Sketch** tool to doodle loose lines on the model in color, as you might on paper, then trace over them with real topology. Sketches never become part of the mesh and don't export. You can hide, erase or clear them from the sketch bar.

## Keeping to a poly budget

Tap the triangle count in the status bar to set a target, like 5,000 tris, and watch the count against it as you work. A quad counts as two triangles.

The same panel finds triangles, n-gons, odd poles and bad geometry. Tap one to jump to it, and tap again to go to the next.

**Check Mesh** gives the full list of structural problems. It reports facts, but whether a mesh will deform well is still your call.

## When your sculpt changes

You don't need to redo your topology. Open **Objects**, tap the update button beside your sculpt, and choose the new version. Your quads snap onto the new surface.

## Editing a mesh you already have

Choose **Import > Mesh to Keep Editing…** to open a low-poly mesh from Blender, Maya or anywhere else that writes OBJ, GLB or glTF, and carry on working on it.

## Linking with Blender

Send meshes straight between Blender and your iPad, with no files to move around.

**Set it up once:**

1. In Little Surface, open **Import > Blender Link…**, tap **Get the Add-on…**, and save the file to your computer.
2. In Blender, go to **Edit > Preferences > Add-ons**, choose **Install from Disk**, and pick the file. It needs Blender 4.2 or later.

**Each time:**

1. Turn on **Link with Blender** in the app. The first time, allow local network access when iPadOS asks.
2. Press N in Blender's 3D view, open the **Little Surface** tab, and type in the address and code the app shows.

From there:

| In Blender | What happens |
| --- | --- |
| **Send as Sculpt** | Adds the selection as a model to draw on. Send one with the same name again and it updates, and your topology follows it. |
| **Send as Mesh** | Adds the selection as topology to keep editing. Turn on **Replace the Mesh There** to swap out what's in the app instead. |
| **Get Mesh** | Brings the app's mesh into Blender. Getting it again updates the same object. |
| **Watch for Meshes** | Picks up anything you send with **Send Mesh to Blender** in the app. |

Your iPad and computer need to be on the same Wi-Fi, and the app has to be on screen with the project open. The link is off until you turn it on. The code keeps others on your network out, but the connection isn't encrypted, so keep it to networks you trust.

## Making a timelapse

Tap **Export**, then **Make Timelapse…** to get a short square video of your mesh growing step by step. The camera turns on its own to follow what you were working on and finishes with a slow spin. The video carries the Little Surface name and logo.

- Keep the app on screen while it's made.
- It replays on your current sculpt, not earlier versions of it.
- Very long sessions are thinned out evenly to keep the project small.

## Exporting

Tap **Export** and pick a format:

- **OBJ** keeps quads as quads and is the best choice for Blender.
- **GLB** is triangulated, and leaves out edges that have no face.

You can include the source model as a separate object.

## Good to know

- Draco-compressed glTF files can't be imported.
- Materials and textures are ignored on import.
- A `.gltf` file that keeps its data in separate files may not open. Use GLB if you can.
- A stroke that runs off the model breaks into pieces.
- If an import from the welcome screen fails, it leaves an empty project behind that you can delete.
- Apple Pencil haptics need an Apple Pencil Pro, and hover and double-tap need a Pencil that supports them. The app works without any of these.

## Building it yourself

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
