import simd
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

/// Check the model for printing and export it for a slicer.
/// Top: a hero summary (ready or what to check, size, filament, time). Bottom: one big Export button.
struct PrintSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    /// Successful exports; Apple's rating prompt comes after the third, when someone clearly likes the app.
    @AppStorage("exportCount") private var exportCount = 0
    @State private var format: ExportFormat = .threeMF
    @State private var quality: ExportQuality = .normal
    @State private var exporting = false
    @State private var shareFile: ExportedFile?
    @State private var fileName = "Formwerk"
    @Namespace private var formatSelection

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    hero
                } footer: {
                    if model.printCheck != nil {
                        Text("Rough guide with 2 walls and 15% infill. Your slicer gives the exact amount.")
                    }
                }

                Section("Printer") {
                    Picker("Printer", selection: Binding(get: { model.printer }, set: { model.setPrinter($0) })) {
                        ForEach(Printer.all) { p in Text(p.name).tag(p) }
                    }
                    Picker("Material", selection: Binding(get: { model.material }, set: { model.setMaterial($0) })) {
                        ForEach(Material.allCases) { m in Text(m.rawValue).tag(m) }
                    }
                    Toggle("Show print bed", isOn: Binding(get: { model.printCheck?.showBed ?? true }, set: { model.printCheck?.showBed = $0 }))
                }

                if let r = model.printCheck, !r.issues.isEmpty {
                    Section("Check") {
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
                    }
                }

                Section("Orientation") {
                    Button {
                        withAnimation(Theme.Motion.smooth) { model.autoOrient() }
                    } label: {
                        Label("Auto-orient for least overhang", systemImage: "rotate.3d")
                    }
                    Text("Tip: to rest a part on a certain face, select that face and use Lay flat.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Export") {
                    TextField("File name", text: $fileName)
                    formatPicker
                        .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                    if format != .step {
                        Picker("Quality", selection: $quality) {
                            Text("Draft").tag(ExportQuality.draft)
                            Text("Normal").tag(ExportQuality.normal)
                            Text("Fine").tag(ExportQuality.fine)
                        }
                        .pickerStyle(.segmented)
                    }
                    Text(formatHint).font(.caption).foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                        .animation(Theme.Motion.snappy, value: format)
                }
            }
            .formStyle(.grouped)
            .formwerkBottomBar { exportBar }
            .navigationTitle(Text("Print"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .formwerkFeedback(.success, trigger: exportCount)
            #if os(iOS)
            .sheet(item: $shareFile) { file in ShareSheet(url: file.url) }
            #else
            .onChange(of: shareFile?.id) { _, _ in if let f = shareFile { save(f); shareFile = nil } }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 680)
        #endif
        .onAppear {
            model.runPrintCheck()
        }
    }

    // MARK: Hero

    /// Status icon, "Ready to print" or what to check, and the three numbers people ask for.
    private var hero: some View {
        let r = model.printCheck
        let problems = r?.issues.filter(\.isProblem) ?? []
        let severe = problems.contains { $0.kind == .notClosed || $0.kind == .tooBig }
        let ready = r != nil && problems.isEmpty
        let tint: Color = r == nil ? .secondary : ready ? Theme.ready : severe ? Theme.problem : Theme.caution
        let symbol = r == nil ? "hourglass" : ready ? "checkmark.seal.fill"
            : severe ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill"
        return VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolBounce(on: ready)
                    .frame(width: 56, height: 56)
                    .background(tint.opacity(0.14), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Group {
                        if r == nil {
                            Text("Checking…")
                        } else if ready {
                            Text("Ready to print")
                        } else {
                            Text("Check before printing")
                        }
                    }
                    .font(Theme.title(Theme.sheetTitleSize, weight: .bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    Group {
                        if r != nil && !problems.isEmpty {
                            Text("Things to check: \(problems.count)")
                        } else {
                            Text(verbatim: "\(model.printer.name) · \(model.material.rawValue)")
                        }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
                }
                Spacer(minLength: 0)
                if r == nil { ProgressView() }
            }
            if let r {
                HStack(spacing: Theme.Space.xs) {
                    metric("Size",
                           "\(Format.number(r.size.x, digits: 0))×\(Format.number(r.size.y, digits: 0))×\(Format.number(r.size.z, digits: 0))",
                           detail: "mm", number: r.size.x + r.size.y + r.size.z)
                    metric("Filament", "≈ \(Format.number(r.grams, digits: 0)) g",
                           detail: "\(Format.number(r.metres, digits: 1)) m", number: r.grams)
                    metric("Time", printTime(r.grams), number: r.grams)
                }
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
            }
        }
        .padding(.vertical, Theme.Space.xs)
        .animation(Theme.Motion.smooth, value: r == nil)
        .animation(Theme.Motion.snappy, value: symbol)
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, detail: String? = nil, number: Double) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.xxs) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(Theme.number(17, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.6)
                .numericTransition(number)
            if let detail {
                Text(verbatim: detail).font(Theme.number(12)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Theme.Space.s)
        .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// A rough print time from the filament weight: about 24 g per hour on the fast CoreXY /
    /// input-shaping printers, 14 g per hour on the others, plus 5 minutes to heat up.
    /// Like the filament number, only a guide: the slicer knows the real time.
    private func printTime(_ grams: Double) -> String {
        guard grams > 0 else { return "–" }
        let fast = ["bambu", "prusa-coreone", "creality-k1", "neptune4", "kobra3"].contains { model.printer.id.hasPrefix($0) }
        let seconds = grams / (fast ? 24 : 14) * 3600 + 300
        let rounded = max((seconds / 300).rounded() * 300, 300)
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.allowedUnits = rounded >= 3600 ? [.hour, .minute] : [.minute]
        f.maximumUnitCount = 2
        return "≈ " + (f.string(from: rounded) ?? "")
    }

    // MARK: Export

    /// The export formats as a glass segmented control; the blue thumb slides to the pick.
    private var formatPicker: some View {
        HStack(spacing: 2) {
            ForEach(ExportFormat.allCases) { f in
                let selected = format == f
                Button {
                    withAnimation(Theme.Motion.snappy) { format = f }
                } label: {
                    Text(f.rawValue)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .padding(.horizontal, 6)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .background {
                            if selected {
                                Capsule().fill(Theme.blue)
                                    .matchedGeometryEffect(id: "format", in: formatSelection)
                            }
                        }
                        .contentShape(Capsule())
                        .hoverHighlight(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle(scale: 0.94))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .formwerkGlass(in: Capsule(), interactive: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Format"))
        .formwerkFeedback(.selection, trigger: format)
    }

    /// The one big action, pinned under the form.
    private var exportBar: some View {
        Button(action: export) {
            HStack(spacing: Theme.Space.xs) {
                if exporting {
                    ProgressView().controlSize(.small).tint(.white)
                } else {
                    Image(systemName: "square.and.arrow.up").fontWeight(.semibold)
                }
                Text("Export \(format.rawValue)")
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 34)
        }
        .formwerkGlassButton(prominent: true)
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .disabled(exporting || model.output.bodies.isEmpty)
        .keyboardShortcut("e", modifiers: .command)
        .frame(maxWidth: 520)
        .padding(.horizontal, Theme.Space.m)
        .padding(.vertical, Theme.Space.s)
    }

    private func export() {
        exporting = true
        model.export(format, quality: quality, name: fileName) { file in
            exporting = false
            shareFile = file
            if file != nil {
                exportCount += 1
                if exportCount == 3 { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { requestReview() } }
            }
        }
    }

    private var formatHint: LocalizedStringKey {
        switch format {
        case .threeMF: "Best for Bambu Studio, PrusaSlicer and OrcaSlicer: keeps units, colours and bodies."
        case .stl: "Works with every slicer."
        case .step: "Exact geometry for other CAD apps."
        case .obj: "For 3D graphics apps."
        case .usdz: "For AR and Apple's 3D apps, in real size."
        }
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
        case .ok: Theme.ready
        case .notClosed, .tooBig: Theme.problem
        default: Theme.caution
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

/// First-launch help (and Help in the View menu): a calm hero, the three steps as benefit rows,
/// the few gestures you need, then "Show me how" or "Skip".
struct WelcomeView: View {
    /// true = start the guided tutorial
    let done: (Bool) -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.xl) {
                hero
                VStack(alignment: .leading, spacing: Theme.Space.l) {
                    benefit("1 · Sketch", "Draw a closed shape. Tap a line to type its exact size.", icon: "pencil.and.outline")
                    benefit("2 · Extrude", "Pull the arrow to make it solid. Round edges, add holes.", icon: "square.stack.3d.up")
                    benefit("3 · Print", "Check it, then send 3MF to Bambu Studio or PrusaSlicer.", icon: "printer")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    #if os(iOS)
                    tip("hand.draw", "One finger turns the view, two fingers move and zoom.")
                    tip("applepencil", "Draw and pick with Apple Pencil, or tap with your finger.")
                    tip("arrow.uturn.backward", "Two-finger tap: undo. Three-finger tap: redo.")
                    #else
                    tip("computermouse", "Drag to turn the view, right-drag too. Scroll wheel zooms; on a trackpad two fingers turn and pinch zooms.")
                    tip("keyboard", "Shortcuts: K sketch, L line, R rectangle, C circle, D dimension, Esc to stop.")
                    #endif
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.m)
                .background(Theme.quietFill, in: RoundedRectangle(cornerRadius: Theme.Radius.panel, style: .continuous))
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, Theme.Space.xl)
            .padding(.top, Theme.Space.xxl)
            .padding(.bottom, Theme.Space.l)
            .frame(maxWidth: .infinity)
        }
        .formwerkBottomBar { buttons }
        #if os(macOS)
        .frame(width: 720, height: 660)
        #endif
    }

    private var hero: some View {
        VStack(spacing: Theme.Space.m) {
            Image("LogoCube")
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 104, height: 104)
                .shadow(color: Theme.blue.opacity(0.35), radius: 24, y: 10)
                .accessibilityHidden(true)
            Text("Welcome to Formwerk")
                .font(Theme.title(34))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Text("Three steps from idea to print. No account, no ads, no subscription.")
                .font(.title3).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .panelAppear(from: .bottom)
    }

    private var buttons: some View {
        VStack(spacing: Theme.Space.xs) {
            Button { done(true) } label: {
                Text("Show me how (1 min)")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .formwerkGlassButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            Button { done(false) } label: {
                Text("Skip")
                    .frame(maxWidth: .infinity, minHeight: 30)
            }
            .formwerkGlassButton()
            .keyboardShortcut(.cancelAction)
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
        .frame(maxWidth: 400)
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
    }

    private func benefit(_ title: LocalizedStringKey, _ text: LocalizedStringKey, icon: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.blue)
                .frame(width: 52, height: 52)
                .background(Theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                Text(title).font(Theme.title(19, weight: .semibold))
                Text(text).font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.s) {
            Image(systemName: icon).font(.body).frame(width: 28).foregroundStyle(Theme.blue)
                .accessibilityHidden(true)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
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
