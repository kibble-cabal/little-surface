# Little Surface Link: sends meshes between Blender and Little Surface on an iPad.
# Install with Edit > Preferences > Add-ons > Install from Disk. It uses nothing but Blender and Python.

bl_info = {
    "name": "Little Surface Link",
    "author": "Little Surface",
    "version": (1, 0, 0),
    "blender": (4, 2, 0),
    "location": "View3D > Sidebar > Little Surface",
    "description": "Send sculpts and meshes to Little Surface on your iPad, and bring its topology back",
    "category": "Import-Export",
}

import contextlib
import json
import os
import tempfile
import urllib.error
import urllib.parse
import urllib.request

import bpy

PORT = 48620
WATCH_SECONDS = 2.0
SOURCE_KEY = "little_surface_name"


class LinkError(Exception):
    pass


def preferences():
    return bpy.context.preferences.addons[__name__].preferences


def request(method, path, query=None, body=None, timeout=600):
    """Returns the status, headers and body, or raises a LinkError with something to tell the artist."""
    prefs = preferences()
    address = prefs.address.strip()
    if not address:
        raise LinkError("Type the address shown in Little Surface's Blender Link.")
    host = address if ":" in address else f"{address}:{PORT}"
    url = f"http://{host}{path}"
    if query:
        url += "?" + urllib.parse.urlencode(query, quote_via=urllib.parse.quote)
    outgoing = urllib.request.Request(url, data=body, method=method, headers={"X-Little-Surface-Code": prefs.code.strip()})
    # The system proxy has no business seeing a device on the local network.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(outgoing, timeout=timeout) as response:
            return response.status, dict(response.headers.items()), response.read()
    except urllib.error.HTTPError as error:
        raise LinkError(_message(error.read()) or f"Little Surface answered with an error ({error.code}).")
    except (urllib.error.URLError, OSError):
        raise LinkError(f"Couldn't reach {host}. Check the link is on in Little Surface and you're on the same Wi-Fi.")


def _message(data):
    try:
        return json.loads(data).get("message", "")
    except ValueError:
        return ""


def _operator_context(context):
    """Timers run without a window, and the OBJ operators want one when there's one to give them."""
    windows = context.window_manager.windows
    return {"window": windows[0]} if context.window is None and len(windows) else {}


@contextlib.contextmanager
def _undisturbed(context):
    """Blender's OBJ operators leave the mode and selection behind. Someone mid-sculpt should stay there."""
    view_layer = context.view_layer
    active = view_layer.objects.active
    mode = active.mode if active else 'OBJECT'
    selected = list(context.selected_objects)
    try:
        yield
    finally:
        for obj in context.selected_objects:
            obj.select_set(False)
        for obj in selected:
            obj.select_set(True)
        view_layer.objects.active = active
        if active and mode != 'OBJECT':
            with context.temp_override(**_operator_context(context)):
                bpy.ops.object.mode_set(mode=mode)


def send(context, path, query):
    """Sends the selected meshes as one OBJ, and returns what Little Surface said about it."""
    objects = [o for o in context.selected_objects if o.type == 'MESH']
    if not objects:
        raise LinkError("Select a mesh to send.")
    active = context.active_object if context.active_object in objects else objects[0]
    for obj in objects:
        obj.update_from_editmode()
    with tempfile.TemporaryDirectory() as folder, _undisturbed(context):
        file = os.path.join(folder, "send.obj")
        with context.temp_override(**_operator_context(context)):
            bpy.ops.wm.obj_export(filepath=file, export_selected_objects=True, apply_modifiers=True,
                                  export_materials=False, export_uv=False, export_normals=True)
        with open(file, "rb") as source:
            body = source.read()
    query = dict(query, name=active.name)
    _, _, answer = request("POST", path, query=query, body=body)
    return _message(answer) or f"Sent {active.name}."


def bring_in(context, data, name):
    """Brings an OBJ into the scene. The same project's mesh updates in place rather than piling up."""
    with tempfile.TemporaryDirectory() as folder, _undisturbed(context):
        file = os.path.join(folder, "receive.obj")
        with open(file, "wb") as target:
            target.write(data)
        before = set(bpy.data.objects)
        with context.temp_override(**_operator_context(context)):
            bpy.ops.wm.obj_import(filepath=file)
        arrived = [o for o in bpy.data.objects if o not in before]
        if not arrived:
            raise LinkError("The mesh from Little Surface was empty.")
        arrived_object = arrived[0]
        earlier = next((o for o in bpy.data.objects if o.get(SOURCE_KEY) == name and o not in arrived), None)
        if earlier is not None and earlier.type == 'MESH':
            stale = earlier.data
            earlier.data = arrived_object.data
            # The file holds the mesh where it really is, whatever's been moved or applied here since.
            earlier.matrix_world = arrived_object.matrix_world
            bpy.data.objects.remove(arrived_object)
            if stale.users == 0:
                bpy.data.meshes.remove(stale)
            return earlier
        arrived_object.name = name
        arrived_object[SOURCE_KEY] = name
        return arrived_object


def fetch(context, path):
    """Brings in what the app has at this path. Returns the object, or None when there's nothing waiting."""
    status, headers, data = request("GET", path)
    if status == 204 or not data:
        return None
    lowered = {key.lower(): value for key, value in headers.items()}
    name = urllib.parse.unquote(lowered.get("x-little-surface-name", "Little Surface"))
    return bring_in(context, data, name)


def _watch():
    prefs = preferences()
    if not prefs.watch:
        return None
    try:
        status, headers, data = request("GET", "/outbox", timeout=1.5)
        if status == 200 and data:
            lowered = {key.lower(): value for key, value in headers.items()}
            bring_in(bpy.context, data, urllib.parse.unquote(lowered.get("x-little-surface-name", "Little Surface")))
    except LinkError:
        pass  # The iPad may just be asleep. It'll answer when it's back.
    return WATCH_SECONDS


def _watch_changed(self, context):
    if self.watch and not bpy.app.timers.is_registered(_watch):
        bpy.app.timers.register(_watch, first_interval=WATCH_SECONDS, persistent=True)


class LittleSurfacePreferences(bpy.types.AddonPreferences):
    bl_idname = __name__

    address: bpy.props.StringProperty(name="Address", description="Shown in Little Surface under Import > Blender Link")
    code: bpy.props.StringProperty(name="Code", description="The six digits shown beside the address")
    replaces_mesh: bpy.props.BoolProperty(name="Replace the Mesh There", description="Replace Little Surface's mesh instead of adding to it. Undo there brings it back", default=False)
    watch: bpy.props.BoolProperty(name="Watch for Meshes", description="Bring in meshes as soon as they're sent from the iPad", default=False, update=_watch_changed)

    def draw(self, context):
        layout = self.layout
        layout.prop(self, "address")
        layout.prop(self, "code")


class _LinkOperator(bpy.types.Operator):
    bl_options = {'REGISTER'}

    def execute(self, context):
        try:
            self.report({'INFO'}, self.run(context))
            return {'FINISHED'}
        except LinkError as error:
            self.report({'ERROR'}, str(error))
            return {'CANCELLED'}


class LITTLESURFACE_OT_check(_LinkOperator):
    bl_idname = "little_surface.check"
    bl_label = "Check Connection"
    bl_description = "See whether Little Surface answers"

    def run(self, context):
        _, _, data = request("GET", "/status", timeout=5)
        status = json.loads(data)
        return f"Connected to {status['project']}: {status['vertices']} vertices, {status['faces']} faces."


class LITTLESURFACE_OT_send_sculpt(_LinkOperator):
    bl_idname = "little_surface.send_sculpt"
    bl_label = "Send as Sculpt"
    bl_description = "Send the selection as a model to draw on. If one with this name is there already, it's updated and the topology follows"

    def run(self, context):
        return send(context, "/sculpt", {})


class LITTLESURFACE_OT_send_mesh(_LinkOperator):
    bl_idname = "little_surface.send_mesh"
    bl_label = "Send as Mesh"
    bl_description = "Send the selection as topology to keep editing"

    def run(self, context):
        return send(context, "/mesh", {"replace": "1"} if preferences().replaces_mesh else {})


class LITTLESURFACE_OT_get_mesh(_LinkOperator):
    bl_idname = "little_surface.get_mesh"
    bl_label = "Get Mesh"
    bl_description = "Bring in the topology from Little Surface"

    def run(self, context):
        obj = fetch(context, "/mesh")
        if obj is None:
            raise LinkError("Little Surface's mesh is empty.")
        return f"Brought in {obj.name}."


class LITTLESURFACE_PT_panel(bpy.types.Panel):
    bl_label = "Little Surface"
    bl_idname = "LITTLESURFACE_PT_panel"
    bl_space_type = 'VIEW_3D'
    bl_region_type = 'UI'
    bl_category = "Little Surface"

    def draw(self, context):
        prefs = preferences()
        layout = self.layout
        layout.prop(prefs, "address")
        layout.prop(prefs, "code")
        layout.operator(LITTLESURFACE_OT_check.bl_idname, icon='LINKED')
        layout.label(text="To iPad")
        layout.operator(LITTLESURFACE_OT_send_sculpt.bl_idname, icon='SCULPTMODE_HLT')
        layout.operator(LITTLESURFACE_OT_send_mesh.bl_idname, icon='MESH_DATA')
        layout.prop(prefs, "replaces_mesh")
        layout.label(text="From iPad")
        layout.operator(LITTLESURFACE_OT_get_mesh.bl_idname, icon='IMPORT')
        layout.prop(prefs, "watch")


_classes = (
    LittleSurfacePreferences,
    LITTLESURFACE_OT_check,
    LITTLESURFACE_OT_send_sculpt,
    LITTLESURFACE_OT_send_mesh,
    LITTLESURFACE_OT_get_mesh,
    LITTLESURFACE_PT_panel,
)


def register():
    for cls in _classes:
        bpy.utils.register_class(cls)
    if preferences().watch:
        bpy.app.timers.register(_watch, first_interval=WATCH_SECONDS, persistent=True)


def unregister():
    if bpy.app.timers.is_registered(_watch):
        bpy.app.timers.unregister(_watch)
    for cls in reversed(_classes):
        bpy.utils.unregister_class(cls)


if __name__ == "__main__":
    register()
