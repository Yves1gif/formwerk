import simd
import SwiftUI
import UniformTypeIdentifiers

/// Check the model for printing and export it for a slicer.
struct PrintSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var format: ExportFormat = .threeMF
    @State private var quality: ExportQuality = .normal
    @State private var exporting = false
    @State private var shareFile: ExportedFile?
    @State private var fileName = "Formwerk"

    var body: some View {
        NavigationStack {
            Form {
                Section("Printer") {
                    Picker("Printer", selection: Binding(get: { model.printer }, set: { model.setPrinter($0) })) {
                        ForEach(Printer.all) { p in Text(p.name).tag(p) }
                    }
                    Picker("Material", selection: Binding(get: { model.material }, set: { model.setMaterial($0) })) {
                        ForEach(Material.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    Toggle("Show print bed", isOn: Binding(get: { model.printCheck?.showBed ?? true }, set: { model.printCheck?.showBed = $0 }))
                }

                Section("Check") {
                    if let r = model.printCheck {
                        ForEach(r.issues) { issue in
                            Label {
                                Text(issue.detail).fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: icon(issue.kind)).foregroundStyle(color(issue.kind))
                            }
                        }
                        if !r.faceMarks.isEmpty {
                            HStack(spacing: 14) {
                                legend(.orange, "Overhang")
                                legend(.red, "Too thin")
                            }
                            .font(.caption)
                        }
                    } else {
                        ProgressView()
                    }
                }

                if let r = model.printCheck {
                    Section("Estimate") {
                        HStack(spacing: 10) {
                            tile("Size", "\(Format.number(r.size.x, digits: 0))×\(Format.number(r.size.y, digits: 0))×\(Format.number(r.size.z, digits: 0))")
                            tile("Filament", "≈ \(Format.number(r.grams, digits: 0)) g")
                            tile("Length", "≈ \(Format.number(r.metres, digits: 1)) m")
                        }
                        Text("Rough guide with 2 walls and 15% infill. Your slicer gives the exact amount.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }

                Section("Export") {
                    TextField("File name", text: $fileName)
                    Picker("Format", selection: $format) {
                        ForEach(ExportFormat.allCases) { f in Text(f.rawValue).tag(f) }
                    }
                    .pickerStyle(.segmented)
                    if format != .step {
                        Picker("Quality", selection: $quality) {
                            Text("Draft").tag(ExportQuality.draft)
                            Text("Normal").tag(ExportQuality.normal)
                            Text("Fine").tag(ExportQuality.fine)
                        }
                    }
                    Text(formatHint).font(.caption).foregroundStyle(.secondary)
                    Button {
                        exporting = true
                        model.export(format, quality: quality, name: fileName) { file in
                            exporting = false
                            shareFile = file
                        }
                    } label: {
                        HStack {
                            if exporting { ProgressView().controlSize(.small).tint(.white) }
                            Label("Export \(format.rawValue)", systemImage: "square.and.arrow.up")
                        }
                    }
                    .buttonStyle(PanelButtonStyle(prominent: true))
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .disabled(exporting || model.output.bodies.isEmpty)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(Text("Print"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            #if os(iOS)
            .sheet(item: $shareFile) { file in ShareSheet(url: file.url) }
            #else
            .onChange(of: shareFile?.id) { _, _ in if let f = shareFile { save(f); shareFile = nil } }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 620)
        #endif
        .onAppear { model.runPrintCheck() }
    }

    private var formatHint: LocalizedStringKey {
        switch format {
        case .threeMF: "Best for Bambu Studio, PrusaSlicer and OrcaSlicer: keeps units, colours and bodies."
        case .stl: "Works with every slicer."
        case .step: "Exact geometry for other CAD apps."
        case .obj: "For 3D graphics apps."
        }
    }

    private func tile(_ t: LocalizedStringKey, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t).font(.caption).foregroundStyle(.secondary)
            Text(v).font(Theme.number(16)).lineLimit(1).minimumScaleFactor(0.6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ t: LocalizedStringKey, _ v: String) -> some View {
        HStack { Text(t); Spacer(); Text(v).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func legend(_ c: Color, _ t: LocalizedStringKey) -> some View {
        HStack(spacing: 4) { RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 12, height: 12); Text(t) }
    }

    private func icon(_ k: PrintCheckResult.Issue.Kind) -> String {
        switch k {
        case .ok: "checkmark.circle.fill"
        case .notClosed: "exclamationmark.octagon.fill"
        case .tooBig: "arrow.up.left.and.arrow.down.right"
        case .overhangs: "arrow.down.right.and.arrow.up.left"
        case .thinWalls: "line.3.horizontal"
        case .belowBed, .floating: "arrow.down.to.line"
        }
    }

    private func color(_ k: PrintCheckResult.Issue.Kind) -> Color {
        switch k {
        case .ok: .green
        case .notClosed, .tooBig: .red
        default: .orange
        }
    }

    #if os(macOS)
    private func save(_ file: ExportedFile) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.url.lastPathComponent
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let dest = panel.url {
            try? FileManager.default.removeItem(at: dest)
            do { try FileManager.default.copyItem(at: file.url, to: dest) } catch { model.show(error.localizedDescription, kind: .error) }
        }
    }
    #endif
}

#if os(iOS)
/// The system share sheet: "Open in Bambu Handy", "Save to Files", AirDrop …
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif

/// First-launch help: three steps and the few gestures you need.
struct WelcomeView: View {
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Welcome to Formwerk").font(Theme.title(36))
                    Text("Three steps from idea to print. Free, no account, no limits.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 14) {
                    step("1 · Sketch", "Draw a closed shape. Tap a line to type its exact size.", icon: "pencil.and.outline")
                    step("2 · Extrude", "Pull the arrow to make it solid. Round edges, add holes.", icon: "square.stack.3d.up")
                    step("3 · Print", "Check it, then send 3MF to Bambu Studio or PrusaSlicer.", icon: "printer")
                }
                VStack(alignment: .leading, spacing: 14) {
                    #if os(iOS)
                    tip("hand.draw", "One finger turns the view, two fingers move and zoom.")
                    tip("applepencil", "Draw and pick with Apple Pencil, or tap with your finger.")
                    tip("arrow.uturn.backward", "Two-finger tap: undo. Three-finger tap: redo.")
                    #else
                    tip("computermouse", "Drag to turn the view, right-drag too. Scroll wheel zooms; on a trackpad two fingers turn and pinch zooms.")
                    tip("keyboard", "Shortcuts: K sketch, L line, R rectangle, C circle, D dimension, Esc to stop.")
                    #endif
                }
                HStack {
                    Spacer()
                    Button("Start designing", action: done)
                        .buttonStyle(PanelButtonStyle(prominent: true))
                        .frame(width: 220)
                }
            }
            .padding(40)
        }
        #if os(macOS)
        .frame(width: 720, height: 600)
        #endif
    }

    private func step(_ title: LocalizedStringKey, _ text: LocalizedStringKey, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.blue)
                .frame(maxWidth: .infinity, minHeight: 70)
                .background(Theme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title).font(Theme.title(18, weight: .semibold))
            Text(text).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 30).foregroundStyle(Theme.blue)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if os(macOS)
struct SettingsView: View {
    var body: some View {
        Form {
            Section("About") {
                Text("Formwerk is free and open source (MPL-2.0).")
                Text("Geometry by Open CASCADE Technology (LGPL-2.1).")
                Link("Source code", destination: URL(string: "https://github.com/Yves1gif/formwerk")!)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 220)
    }
}
#endif
