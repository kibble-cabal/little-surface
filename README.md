# Little Surface

Retopology for iPad. Bring in a sculpt, draw your topology on it with Apple Pencil, and take clean quads back to Blender or anything else that reads OBJ or GLB.

Everything stays on your iPad. There's no account and nothing goes to a server.

Little Surface is built for the 2020 iPad and newer, with iPadOS 18 or later. It has been tested in the iPad simulator so far, so how it feels with a real Pencil on a real iPad is still being worked out.

## Getting started

1. On the welcome screen, tap **+**, then **Example** for a model to practice on, or **Import Model** for your own OBJ, GLB or glTF file.
2. Draw two lines side by side on the model.
3. Quads appear between them in pencil. Draw somewhere else and they turn to ink.

No Pencil? One finger turns the model by default. Under **… > Settings**, set **One finger** to **Draws, as a Pencil would**.

## Drawing

There's one pencil, and the mark says what you mean:

- **Lines:** draw a line and it becomes edges. Start from the end of another line to carry it on, or draw across lines to connect them.
- **Loops:** bring a stroke back to its start and it closes.
- **Quad size:** zoom sets it. Zoom in for smaller quads and out for bigger ones. A stroke that starts or ends on existing topology matches it instead.
- **Fills:** when your lines enclose an area, it fills with quads in pencil. Draw through them and they reshape. They turn to ink when you move on, and undo takes them away while leaving your line.
- **Marks:** a stroke that can't become topology stays as a pencil line. Trace over it, or leave it. Marks don't export.
- **Moving a point:** rest the Pencil on a point for a moment, then drag. Points show up as you zoom in.
- **Picking:** tap a line, a quad or a mark, and **Delete** appears. If you tap an empty loop, **Fill** appears too.

Fingers always move the view: two fingers pan and pinch to zoom. Tap with two fingers to undo, or three to redo.

## Brushes

The three buttons at the top are **Draw**, **Smooth** and **Erase**. Double-tap a Pencil that supports it to switch between drawing and erasing.

- **Smooth** evens out the points under it.
- **Erase** rubs out the quads, lines and marks under it.

Both have a size slider on the left. Your work saves itself a couple of seconds after each change. Undo history lasts until you close the project.

## Symmetry

Tap the symmetry button and your strokes mirror across the model. Touch and hold it to pick the axis.

## The … menu

### Keeping to a poly budget

Open **Poly Budget** to see your triangle count and set a target, like 5,000 tris. The count then stays on screen as you work. A quad counts as two triangles.

The same sheet finds triangles, n-gons, odd poles and bad geometry. Tap one to jump to it, and tap again to go to the next.

### When your sculpt changes

You don't need to redo your topology. Open **Sculpts**, tap **Update** beside your sculpt, and choose the new version. Your quads snap onto the new surface.

### Editing a mesh you already have

Choose **Open Mesh** to open a low-poly mesh from Blender, Maya or anywhere else that writes OBJ, GLB or glTF, and carry on working on it.

### Seeing your topology alone

**Hide Model** takes the sculpt out of view so you can check the flow of your lines.

## Linking with Blender

Send meshes straight between Blender and your iPad, with no files to move around.

**Set it up once:**

1. In Little Surface, open **… > Blender Link**, tap **Get the Add-on…**, and save the file to your computer.
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

Open **… > Export**, then **Make Timelapse** to get a short square video of your mesh growing step by step. The camera turns on its own to follow what you were working on and finishes with a slow spin. The video carries the Little Surface name and logo.

- Keep the app on screen while it's made.
- It replays on your current sculpt, not earlier versions of it.
- Very long sessions are thinned out evenly to keep the project small.

## Exporting

Open **… > Export** and pick a format:

- **OBJ** keeps quads as quads and is the best choice for Blender.
- **GLB** is triangulated, and leaves out edges that have no face.

You can include the sculpt as a separate object.

## Good to know

- Draco-compressed glTF files can't be imported.
- Materials and textures are ignored on import.
- A `.gltf` file that keeps its data in separate files may not open. Use GLB if you can.
- A stroke that runs off the model breaks into pieces.
- Part of a stroke that runs over finished quads is dropped, unless the whole stroke does, which leaves a mark.
- If an import from the welcome screen fails, it leaves an empty project behind that you can delete.
- Apple Pencil haptics need an Apple Pencil Pro, and hover and double-tap need a Pencil that supports them. The app works without any of these.

## Building it yourself

See [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).
