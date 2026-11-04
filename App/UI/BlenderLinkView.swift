import LittleSurfaceCore
import SwiftUI

/// Connects the open project to Blender on the same network.
struct BlenderLinkView: View {
    let model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var sharesAddOn = false

    var body: some View {
        let stats = model.state.statistics
        NavigationStack {
            Form {
                Section {
                    Toggle("Link with Blender", isOn: Binding(get: { model.linkIsOn }, set: { model.setBlenderLink($0) }))
                        .accessibilityIdentifier("Blender Link Toggle")
                } footer: {
                    Text("Your iPad and computer need to be on the same Wi-Fi. The link stops while you're out of this project or the app.")
                }
                if model.linkIsOn {
                    Section("Type these into Blender") {
                        LabeledContent("Address", value: model.linkAddress ?? "Not on a network")
                            .accessibilityIdentifier("Blender Link Address")
                        LabeledContent("Code", value: model.linkCode)
                            .accessibilityIdentifier("Blender Link Code")
                    }
                    Section {
                        Text(model.linkStatus)
                            .font(.footnote)
                            .foregroundStyle(Theme.quiet)
                            .accessibilityIdentifier("Blender Link Status")
                        Button("Send Mesh to Blender") { model.sendMeshToBlender() }
                            .disabled(stats.faces == 0 && stats.edges == 0)
                            .accessibilityIdentifier("Send Mesh to Blender")
                    } footer: {
                        Text("Blender picks it up while Watch for Meshes is on in its Little Surface panel.")
                    }
                }
                Section("Setting up Blender") {
                    Button("Get the Add-on…") { sharesAddOn = true }
                        .disabled(BlenderLinkView.addOnURL == nil)
                        .accessibilityIdentifier("Get Blender Add-on")
                    Text("Save the file to your computer. In Blender, open Edit > Preferences > Add-ons, choose Install from Disk, and pick the file. You'll find a Little Surface tab in the 3D view's sidebar.")
                        .font(.footnote)
                        .foregroundStyle(Theme.quiet)
                }
            }
            .navigationTitle("Blender Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("Blender Link Done")
                }
            }
            .sheet(isPresented: $sharesAddOn) {
                if let url = BlenderLinkView.addOnURL { ShareSheet(url: url).ignoresSafeArea() }
            }
        }
    }

    static var addOnURL: URL? { Bundle.main.url(forResource: "little_surface_link", withExtension: "py") }
}
