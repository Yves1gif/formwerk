import SwiftUI

@main
struct FormwerkApp: App {
    init() {
        Theme.registerFonts()
        if SelfTest.requested { MainActor.assumeIsolated { SelfTest.run() } }
        #if os(iOS)
        if ScreenshotMode.current != nil { MainActor.assumeIsolated { ScreenshotMode.presentOverLaunch() } }
        #endif
    }

    var body: some Scene {
        documents

        #if os(iOS)
        // The start screen: big title on Werk Blue, "New Design" and the templates.
        DocumentGroupLaunchScene {
            NewDocumentButton("New Design")
            ForEach(TemplateKind.allCases) { t in
                NewDocumentButton(t.title, for: FormwerkDocument.self) { FormwerkDocument(design: t.design()) }
            }
        } background: {
            LinearGradient(colors: [Theme.launchTop, Theme.launchBottom], startPoint: .top, endPoint: .bottom)
        } overlayAccessoryView: { geometry in
            Image("LogoCube")
                .resizable()
                .scaledToFit()
                .frame(width: 96, height: 96)
                .position(x: geometry.titleViewFrame.midX, y: geometry.titleViewFrame.minY - 52)
                .accessibilityHidden(true)
        }
        #endif

        #if os(macOS)
        Settings { SettingsView() }
        #endif
    }

    private var documents: some Scene {
        DocumentGroup(newDocument: { FormwerkDocument() }) { file in
            EditorView(document: file.document)
        }
        .commands { FormwerkCommands() }
    }
}

enum TemplateKind: String, CaseIterable, Identifiable {
    case keychain, box, bracket, pot
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .keychain: "Keychain"
        case .box: "Open box"
        case .bracket: "Wall bracket"
        case .pot: "Plant pot"
        }
    }

    @MainActor func design() -> Design {
        switch self {
        case .keychain: Templates.keychain()
        case .box: Templates.box()
        case .bracket: Templates.wallBracket()
        case .pot: Templates.plantPot()
        }
    }
}

/// Menu bar (Mac) and hardware keyboard shortcuts (iPad). The focused editor answers them.
struct FormwerkCommands: Commands {
    @FocusedObject private var model: EditorModel?
    #if os(macOS)
    @Environment(\.newDocument) private var newDocument
    #endif

    var body: some Commands {
        #if os(macOS)
        CommandGroup(after: .newItem) {
            Menu("New from Template") {
                ForEach(TemplateKind.allCases) { t in
                    Button(t.title) { newDocument { FormwerkDocument(design: t.design()) } }
                }
            }
        }
        #endif
        CommandMenu("Model") {
            Button("New Sketch") { model?.startSketch() }.keyboardShortcut("k", modifiers: [.command, .shift])
            Divider()
            Button("Extrude") { model?.start(.extrude) }.keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Revolve") { model?.start(.revolve) }
            Button("Push/Pull") { model?.start(.pushPull) }
            Button("Fillet") { model?.start(.fillet) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Chamfer") { model?.start(.chamfer) }
            Button("Hollow") { model?.start(.shell) }
            Button("Hole") { model?.start(.hole) }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Text") { model?.start(.text) }
            Divider()
            Button("Box") { model?.start(.box) }
            Button("Cylinder") { model?.start(.cylinder) }
            Divider()
            Button("Move") { model?.start(.move) }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Mirror") { model?.start(.mirror) }
            Button("Pattern") { model?.start(.pattern) }
            Button("Combine") { model?.start(.combine) }
            Button("Split") { model?.start(.split) }
            Divider()
            Button("Measure") { model?.start(.measure) }
        }
        CommandMenu("View") {
            Button("Fit All") { model?.fitView() }.keyboardShortcut("0", modifiers: .command)
            Button("Top") { model?.setView(.top) }.keyboardShortcut("1", modifiers: .command)
            Button("Front") { model?.setView(.front) }.keyboardShortcut("2", modifiers: .command)
            Button("Right") { model?.setView(.right) }.keyboardShortcut("3", modifiers: .command)
            Button("3D View") { model?.setView(.iso) }.keyboardShortcut("4", modifiers: .command)
            Button("Perspective / Orthographic") { model?.toggleOrthographic() }.keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Section View") { model?.toggleSection() }
            Button("Show All Sketches") { model?.showAllSketches.toggle() }
        }
    }
}
