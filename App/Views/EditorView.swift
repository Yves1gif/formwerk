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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("welcomeSeen") private var welcomeSeen = false
    @State private var showPrint = false
    @State private var showImport = false
    @State private var showWelcome = false
    @State private var showBodies = false
    @State private var tutorialStep: TutorialStep?
    @State private var startTutorialAfterWelcome = false
    /// The "made for iPhone Duo" note shows once; after that Formwerk simply runs in the phone layout.
    @AppStorage("smallPhoneNoticeSeen") private var smallPhoneNoticeSeen = false
    @AppStorage("tutorialDone") private var tutorialDone = false
    #if os(iOS)
    @State private var arFile: ExportedFile?
    @State private var showInputSettings = false
    #endif

    init(document: FormwerkDocument) {
        self.document = document
        _model = StateObject(wrappedValue: EditorModel(document: document))
    }

    var body: some View {
        ZStack {
            if let renderer = model.renderer {
                ViewportRepresentable(renderer: renderer, input: model)
                    .ignoresSafeArea()
                    .overlay(alignment: compact ? .topLeading : .bottomTrailing) {
                        if model.sketch == nil {
                            ViewCubeView(renderer: renderer) { action in
                                switch action {
                                case .view(let v): model.setView(v)
                                case .home: model.fitView()
                                }
                            }
                            .padding(compact ? 10 : 16)
                            .padding(.bottom, compact ? 0 : 64)  // clear of the timeline
                            .transition(Theme.Motion.panel(from: .bottomTrailing))
                        }
                    }
            } else {
                Text("This device can't show 3D graphics (Metal is missing).")
            }

            if model.sketch != nil {
                DimensionLabels(model: model)
                    .ignoresSafeArea()
            }

            if compact {
                compactLayout
            } else {
                regularLayout
            }

            PencilPaletteOverlay(model: model)
                .ignoresSafeArea()

            if phoneTooSmall {
                UnfoldView { withAnimation(Theme.Motion.snappy) { smallPhoneNoticeSeen = true } }
                    .ignoresSafeArea()
            }

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
            if ScreenshotMode.current == .tutorial {
                tutorialStep = .sketch
            } else if let shot = ScreenshotMode.current {
                prepareWhenBuilt(shot)
            } else if !welcomeSeen {
                showWelcome = true
            } else if !tutorialDone && model.design.features.isEmpty {
                tutorialStep = .sketch
            }
        }
        .onChange(of: undoManager) { _, u in model.undoManager = u }
        .onChange(of: colorScheme) { _, _ in updateColors() }
        .focusedSceneObject(model)
        .toolbar { toolbarContent }
        .sheet(isPresented: $showPrint, onDismiss: { model.endPrintCheck() }) {
            PrintSheet(model: model)
        }
        .sheet(isPresented: $showWelcome, onDismiss: {
            welcomeSeen = true
            if startTutorialAfterWelcome {
                startTutorialAfterWelcome = false
                withAnimation(Theme.Motion.snappy) { tutorialStep = .sketch }
            }
        }) {
            WelcomeView { startTutorial in
                startTutorialAfterWelcome = startTutorial
                if !startTutorial { tutorialDone = true }
                showWelcome = false
            }
        }
        #if os(iOS)
        .sheet(isPresented: $showInputSettings) {
            NavigationStack {
                InputSettingsView()
                    .toolbar { Button("Done") { showInputSettings = false } }
            }
        }
        .fullScreenCover(item: $arFile) { f in ARQuickLookView(url: f.url).ignoresSafeArea() }
        #endif
        .fileImporter(isPresented: $showImport, allowedContentTypes: UTType.stepFiles) { result in
            if case .success(let url) = result { model.importSTEP(url) }
        }
        #if os(iOS)
        .toolbarRole(.editor)
        #endif
    }


    /// Narrow screens (iPhone, a folded iPhone Duo, iPad Slide Over): tools at the bottom,
    /// settings in a panel above them. Wide screens keep the rail on the left and the inspector on the right.
    private var compact: Bool {
        #if os(iOS)
        return sizeClass == .compact
        #else
        return false
        #endif
    }

    /// Made for the iPhone Duo's inner screen (regular width, like an iPad). A normal iPhone or a folded Duo
    /// gets a "please unfold" screen; the phone layout behind it stays reachable with "Open anyway".
    private var phoneTooSmall: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .phone && sizeClass == .compact
            && (ScreenshotMode.current == .unfold || (!smallPhoneNoticeSeen && ScreenshotMode.current == nil))
        #else
        return false
        #endif
    }

    /// Screenshot mode: set the scene up once the model is built (a slow simulator can take a while).
    private func prepareWhenBuilt(_ shot: ScreenshotMode, tries: Int = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 0 ? 1.5 : 0.5)) {
            if (model.isBuilding || model.output.bounds.isEmpty) && tries < 60 {
                prepareWhenBuilt(shot, tries: tries + 1)
            } else {
                shot.prepare(model, showPrint: $showPrint)
            }
        }
    }

    private var showsInspector: Bool {
        model.tool != nil || model.sketch != nil || !model.selection.isEmpty || model.section != nil
    }

    private var regularLayout: some View {
        FormwerkGlassGroup(spacing: 12) {
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
                    if showsInspector {
                        Inspector(model: model)
                            .frame(width: 280)
                            .transition(Theme.Motion.panel(from: .topTrailing))
                    }
                }
                Spacer(minLength: 0)
                if model.design.features.isEmpty && model.sketch == nil && model.tool == nil {
                    EmptyDesignCard(model: model, showImport: $showImport)
                    Spacer(minLength: 0)
                }
                if let toast = model.toast {
                    ToastView(toast: toast).transition(Theme.Motion.slide(from: .bottom))
                }
                TutorialCoach(model: model, step: $tutorialStep, printShown: showPrint)
                ContextBar(model: model)
                if model.sketch == nil {
                    TimelineView(model: model)
                }
            }
        }
        .padding(12)
        .animation(Theme.Motion.snappy, value: model.toast)
        .animation(Theme.Motion.snappy, value: showsInspector)
        .animation(Theme.Motion.snappy, value: model.sketch == nil)
    }

    private var compactLayout: some View {
        VStack(spacing: 8) {
            if model.sketch != nil {
                SketchTopBar(model: model)
            }
            Spacer(minLength: 0)
            if model.design.features.isEmpty && model.sketch == nil && model.tool == nil {
                EmptyDesignCard(model: model, showImport: $showImport)
                Spacer(minLength: 0)
            }
            if let toast = model.toast {
                ToastView(toast: toast).transition(Theme.Motion.slide(from: .bottom))
            }
            TutorialCoach(model: model, step: $tutorialStep, printShown: showPrint)
            if showsInspector {
                ScrollView { Inspector(model: model) }
                    .frame(maxHeight: 260)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(Theme.Motion.panel(from: .bottom))
            }
            ContextBar(model: model)
            if model.sketch == nil && model.tool == nil {
                TimelineView(model: model)
            }
            if model.sketch != nil {
                SketchToolbar(model: model, horizontal: true)
            } else if model.tool == nil {
                ToolRail(model: model, showPrint: $showPrint, showImport: $showImport, horizontal: true)
            }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .animation(Theme.Motion.snappy, value: model.toast)
        .animation(Theme.Motion.snappy, value: showsInspector)
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
                Button("Tutorial", systemImage: "graduationcap") { withAnimation(Theme.Motion.snappy) { tutorialStep = .sketch } }
                Button("Help", systemImage: "questionmark.circle") { showWelcome = true }
                #if os(iOS)
                Button("Pencil, Mouse & Keyboard", systemImage: "applepencil") { showInputSettings = true }
                Divider()
                Button {
                    model.makeUSDZ { url in if let url { arFile = ExportedFile(url: url, format: .usdz) } }
                } label: {
                    Label("View in AR", systemImage: "arkit")
                }
                #endif
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
    /// Bumped when a toast shows or is replaced: bounces the icon.
    @State private var shown = 0
    /// Bumped for error toasts only: plays the error tap on iPhone.
    @State private var errors = 0

    var body: some View {
        // Coloured icon, primary text: red body text on glass is hard to read, and long
        // messages wrap inside a rounded rectangle instead of a stretched capsule.
        Label {
            Text(toast.text).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
        } icon: {
            Image(systemName: toast.kind == .error ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundStyle(toast.kind == .error ? Theme.problem : Theme.blue)
                .contentTransition(.symbolEffect(.replace))
                .symbolBounce(on: shown)
        }
        .font(.callout)
        .padding(.horizontal, Theme.Space.m).padding(.vertical, Theme.Space.s)
        .frame(maxWidth: 520)
        .formwerkGlass(radius: Theme.Radius.panel)
        .accessibilityElement(children: .combine)
        .formwerkFeedback(.error, trigger: errors)
        .onAppear { present() }
        .onChange(of: toast.id) { _, _ in present() }
    }

    private func present() {
        shown += 1
        if toast.kind == .error { errors += 1 }
        AccessibilityNotification.Announcement(toast.text).post()
    }
}

/// Shown on a new, empty design: the three ways to start, on one glass card.
struct EmptyDesignCard: View {
    @ObservedObject var model: EditorModel
    @Binding var showImport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("What are you making?").font(Theme.title(26))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Start with a sketch on the ground, or drop in a basic shape and change it later.")
                    .font(.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Theme.Space.xs) {
                startButton("Sketch", icon: "pencil.and.outline", prominent: true) { model.startSketch() }
                startButton("Box", icon: "cube") { model.start(.box) }
                startButton("Import STEP", icon: "square.and.arrow.down") { showImport = true }
            }
        }
        .frame(maxWidth: 500)
        .glassPanel(radius: Theme.Radius.card, padding: Theme.Space.l)
        .panelAppear(from: .center)
    }

    private func startButton(_ title: LocalizedStringKey, icon: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button(action: action) {
            VStack(spacing: Theme.Space.xs) {
                Image(systemName: icon).font(.system(size: 26, weight: .medium))
                    .accessibilityHidden(true)
                Text(title).font(.callout.weight(.semibold))
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.Space.xs).padding(.vertical, Theme.Space.m)
            .frame(maxWidth: .infinity, minHeight: 96)
            .background(prominent ? Theme.blue : Theme.quietFill, in: shape)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .contentShape(shape)
            .hoverHighlight(shape)
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.96))
    }
}

/// The capsule on top while sketching: where you are, how many closed areas, Cancel / Done.
struct SketchTopBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.sketch {
            // On narrow screens the title and the area count give way to the buttons.
            ViewThatFits(in: .horizontal) {
                bar(s, full: true)
                bar(s, full: false)
            }
            .panelAppear(from: .top)
        }
    }

    private func bar(_ s: SketchSession, full: Bool) -> some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: "pencil.and.outline").foregroundStyle(Theme.blue)
                .accessibilityHidden(true)
            if full {
                Text(s.isNew ? "New Sketch" : "Edit Sketch").font(Theme.title(17, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            Text("\(s.regions.count) closed areas")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .numericTransition(Double(s.regions.count))
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.blue.opacity(0.12), in: Capsule())
                .foregroundStyle(Theme.blue)
                .lineLimit(1)
            Button("Cancel") { model.cancelSketch() }
                .buttonStyle(PillButtonStyle())
            Button("Done") {
                Theme.Haptics.play(.success)
                model.finishSketch()
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .fixedSize()
        .padding(.leading, Theme.Space.m).padding(.trailing, 6).padding(.vertical, 6)
        .glassPanel(radius: Theme.Radius.bar)
    }
}
