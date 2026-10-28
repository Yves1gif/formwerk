import SwiftUI

/// Apple Pencil, mouse and keyboard settings (Mac Settings window, iPad sheet).
struct InputSettingsView: View {
    @AppStorage(PencilDrawing.key) private var pencil: PencilDrawing = .auto
    @AppStorage(MousePreset.key) private var mouse: MousePreset = .formwerk

    var body: some View {
        Form {
            #if os(iOS)
            Section {
                Picker("Drawing in sketches", selection: $pencil) {
                    ForEach(PencilDrawing.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Apple Pencil")
            } footer: {
                Text(pencil.detail)
            }
            #endif

            Section {
                Picker("Mouse buttons", selection: $mouse) {
                    ForEach(MousePreset.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Mouse and trackpad")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mouse.detail)
                    Text("Right-click selects what's under the pointer and shows what you can do with it.")
                }
            }

            Section {
                key("L", "Line")
                key("R", "Rectangle")
                key("C", "Circle")
                key("A", "Arc")
                key("O", "Slot")
                key("P", "Polygon")
                key("D", "Dimension")
                key("E", "Extrude")
                key("F", "Fillet, or Fit All when nothing is selected")
                key("H", "Hole")
                key("M", "Measure")
                key("K", "New Sketch")
                keyRow(Text("Space"), "Repeat the last tool")
                keyRow(Text("Arrow keys"), "Orbit the view by 15°")
                keyRow(Text(verbatim: "esc"), "Cancel")
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Single keys work while no text field is being edited. Drawing keys start a sketch when none is open.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Input")
    }

    private func key(_ k: String, _ action: LocalizedStringKey) -> some View {
        keyRow(Text(verbatim: k), action)
    }

    private func keyRow(_ k: Text, _ action: LocalizedStringKey) -> some View {
        LabeledContent {
            k.font(.body.monospaced().weight(.semibold))
        } label: {
            Text(action)
        }
    }
}
