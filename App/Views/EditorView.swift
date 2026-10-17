import simd
import MetalKit
import SwiftUI
import UniformTypeIdentifiers

/// The design window: 3D view with tools around it.
struct EditorView: View {
    @ObservedObject var document: FormwerkDocument
    @StateObject private var model: EditorModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var showPrint = false
    @State private var showImport = false
    @State private var showWelcome = false
    @State private var showBodies = false

    init(document: FormwerkDocument) {
        self.document = document
        _model = StateObject(wrappedValue: EditorModel(document: document))
    }

    var body: some View {
        ZStack {
            if let renderer = model.renderer {
                ViewportRepresentable(renderer: renderer, input: model)
                    .ignoresSafeArea()
            } else {
                Text("This device can't show 3D graphics (Metal is missing).")
            }

            if model.sketch != nil {
                DimensionLabels(model: model)
                    .ignoresSafeArea()
            }

            VStack(spacing: 10) {
                if model.sketch != nil {
                    SketchTopBar(model: model)
                }
                HStack(alignment: .top, spacing: 12) {
                    if model.sketch != nil {
                        SketchToolbar(model: model)
                    } else {
                        ToolRail(model: model, showPrint: $showPrint, showImport: $showImport)
                    }
                    Spacer(minLength: 0)
                    if model.tool != nil || model.sketch != nil || !model.selection.isEmpty || model.section != nil {
                        Inspector(model: model)
                            .frame(width: 280)
                    }
                }
                Spacer(minLength: 0)
                if model.design.features.isEmpty && model.sketch == nil && model.tool == nil {
                    EmptyDesignCard(model: model, showImport: $showImport)
                    Spacer(minLength: 0)
                }
                if let toast = model.toast {
                    ToastView(toast: toast).transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ContextBar(model: model)
                if model.sketch == nil {
                    TimelineView(model: model)
                }
            }
            .padding(12)
            .animation(.snappy(duration: 0.2), value: model.toast)

            if model.isBuilding {
                VStack {
                    HStack { Spacer(); ProgressView().controlSize(.small).padding(8) }
                    Spacer()
                }
                .allowsHitTesting(false)
            }
        }
        .background(colorScheme == .dark ? Color(red: 0.11, green: 0.118, blue: 0.133) : Color(red: 0.925, green: 0.933, blue: 0.949))
        .onAppear {
            model.undoManager = undoManager
            updateColors()
            if let shot = ScreenshotMode.current {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { shot.prepare(model, showPrint: $showPrint) }
            } else if !welcomeSeen { showWelcome = true }
        }
        .onChange(of: undoManager) { _, u in model.undoManager = u }
        .onChange(of: colorScheme) { _, _ in updateColors() }
        .focusedSceneObject(model)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showPrint, onDismiss: { model.endPrintCheck() }) {
            PrintSheet(model: model)
        }
        .sheet(isPresented: $showWelcome, onDismiss: { welcomeSeen = true }) {
            WelcomeView { showWelcome = false }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: UTType.stepFiles) { result in
            if case .success(let url) = result { model.importSTEP(url) }
        }
        #if os(iOS)
        .toolbarRole(.editor)
        #endif
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.viewportUndo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
            Button { model.viewportRedo() } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            Menu {
                Button("Fit All", systemImage: "arrow.up.left.and.arrow.down.right") { model.fitView() }
                Divider()
                Button("3D View", systemImage: "cube") { model.setView(.iso) }
                Button("Top", systemImage: "square.tophalf.filled") { model.setView(.top) }
                Button("Front", systemImage: "square.bottomhalf.filled") { model.setView(.front) }
                Button("Right", systemImage: "square.righthalf.filled") { model.setView(.right) }
                Divider()
                Button("Perspective / Orthographic", systemImage: "perspective") { model.toggleOrthographic() }
                Button(model.section == nil ? "Section View" : "End Section View", systemImage: "square.split.diagonal") { model.toggleSection() }
                Toggle("Show All Sketches", isOn: $model.showAllSketches)
                Divider()
                Picker("Units", selection: Binding(get: { model.design.unit }, set: { model.setUnit($0) })) {
                    ForEach(LengthUnit.allCases) { u in Text(u.symbol).tag(u) }
                }
                Button("Help", systemImage: "questionmark.circle") { showWelcome = true }
            } label: {
                Label("View", systemImage: "eye")
            }
            Button { showBodies.toggle() } label: { Label("Bodies", systemImage: "square.stack.3d.up") }
                .popover(isPresented: $showBodies) { BodyList(model: model).frame(minWidth: 280, minHeight: 200) }
            Button {
                model.runPrintCheck()
                showPrint = true
            } label: {
                Label("Print", systemImage: "printer")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .keyboardShortcut("p", modifiers: .command)
        }
    }

    private func updateColors() {
        guard let r = model.renderer else { return }
        if colorScheme == .dark {
            r.clearColor = MTLClearColor(red: 0.11, green: 0.118, blue: 0.133, alpha: 1)
            r.gridColor = SIMD4(0.75, 0.78, 0.85, 1)
        } else {
            r.clearColor = MTLClearColor(red: 0.925, green: 0.933, blue: 0.949, alpha: 1)
            r.gridColor = SIMD4(0.3, 0.32, 0.36, 1)
        }
        r.setNeedsDisplay()
    }
}

/// A short message at the bottom.
struct ToastView: View {
    let toast: Toast
    var body: some View {
        Label(toast.text, systemImage: toast.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
            .font(.callout)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .foregroundStyle(toast.kind == .error ? Color.red : Color.primary)
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

/// Shown on a new, empty design: the three ways to start.
struct EmptyDesignCard: View {
    @ObservedObject var model: EditorModel
    @Binding var showImport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("What are you making?").font(Theme.title(26))
            Text("Start with a sketch on the ground, or drop in a basic shape and change it later.")
                .font(.body).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                startButton("Sketch", icon: "pencil.and.outline", prominent: true) { model.startSketch() }
                startButton("Box", icon: "cube") { model.start(.box) }
                startButton("Import STEP", icon: "square.and.arrow.down") { showImport = true }
            }
        }
        .frame(maxWidth: 500)
        .glassPanel(radius: 22, padding: 28)
    }

    private func startButton(_ title: LocalizedStringKey, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 26, weight: .medium))
                Text(title).font(.callout.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(prominent ? Theme.blue : Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The capsule on top while sketching: where you are, how many closed areas, Cancel / Done.
struct SketchTopBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.sketch {
            HStack(spacing: 12) {
                Image(systemName: "pencil.and.outline").foregroundStyle(Theme.blue)
                Text(s.isNew ? "New Sketch" : "Edit Sketch").font(Theme.title(17, weight: .semibold))
                Text("\(s.regions.count) closed areas")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.blue.opacity(0.12), in: Capsule())
                    .foregroundStyle(Theme.blue)
                Button("Cancel") { model.cancelSketch() }
                    .buttonStyle(PillButtonStyle())
                Button("Done") { model.finishSketch() }
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 6)
            .glassPanel(radius: 26)
        }
    }
}
