import SwiftUI

/// The first-part tutorial: a small coach card that follows what you do and moves on by itself.
/// It can be skipped at any step and restarted from the Help menu.
enum TutorialStep: Int, CaseIterable {
    case sketch, rectangle, finishSketch, extrude, height, fillet, print, done

    var title: LocalizedStringKey {
        switch self {
        case .sketch: "Start a sketch"
        case .rectangle: "Draw a rectangle"
        case .finishSketch: "Finish the sketch"
        case .extrude: "Make it solid"
        case .height: "Set the height"
        case .fillet: "Round an edge"
        case .print: "Get it ready to print"
        case .done: "You made your first part!"
        }
    }

    var text: LocalizedStringKey {
        switch self {
        case .sketch: "Tap Sketch on the left. You will draw on the ground."
        case .rectangle: "Pick Rectangle, then tap two opposite corners on the grid."
        case .finishSketch: "Tap a side to type its exact length if you like. Then tap Done at the top."
        case .extrude: "The area is selected. Tap Extrude in the bar at the bottom."
        case .height: "Drag the blue arrow up or type a height, then tap Done."
        case .fillet: "Tap one edge of the block, then tap Fillet and Done."
        case .print: "Tap Print at the top right to check your part and export it for your slicer."
        case .done: "Everything stays editable: tap any step in the timeline to change it."
        }
    }

    var icon: String {
        switch self {
        case .sketch, .finishSketch: "pencil.and.outline"
        case .rectangle: "rectangle"
        case .extrude, .height: "square.stack.3d.up"
        case .fillet: "square.on.circle"
        case .print: "printer"
        case .done: "checkmark.seal.fill"
        }
    }

    /// Whether the user has done what this step asks.
    @MainActor func isDone(_ m: EditorModel, printShown: Bool) -> Bool {
        let kinds = m.design.features.map(\.kind)
        switch self {
        case .sketch: return m.sketch != nil || kinds.contains(.sketch)
        case .rectangle: return (m.sketch?.regions.count ?? 0) > 0 || kinds.contains(.sketch)
        case .finishSketch: return m.sketch == nil && kinds.contains(.sketch)
        case .extrude: return m.tool?.kind == .extrude || kinds.contains(.extrude)
        case .height: return m.tool == nil && kinds.contains(.extrude)
        case .fillet: return kinds.contains(.fillet) || kinds.contains(.chamfer)
        case .print: return printShown
        case .done: return false
        }
    }
}

struct TutorialCoach: View {
    @ObservedObject var model: EditorModel
    @Binding var step: TutorialStep?
    let printShown: Bool
    @AppStorage("tutorialDone") private var tutorialDone = false

    var body: some View {
        if let s = step {
            let total = TutorialStep.allCases.count - 1
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: s.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(s == .done ? Theme.ready : Theme.blue)
                    .frame(width: 42, height: 42)
                    .background((s == .done ? Theme.ready : Theme.blue).opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    if s != .done {
                        Text("Step \(s.rawValue + 1) of \(total)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(s.title).font(Theme.title(18, weight: .semibold))
                    Text(s.text).font(.subheadline).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if s == .done {
                    Button("Finish") { finish() }.buttonStyle(PillButtonStyle(prominent: true))
                } else {
                    Button("Skip tutorial") { finish() }.buttonStyle(PillButtonStyle())
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .glassPanel(radius: 20)
            .transition(.move(edge: .top).combined(with: .opacity))
            // Re-check the current step whenever the editor changes.
            .onReceive(model.objectWillChange.receive(on: DispatchQueue.main)) { _ in advanceIfDone() }
            .onChange(of: printShown) { _, _ in advanceIfDone() }
        }
    }

    private func advanceIfDone() {
        guard var s = step else { return }
        // Skip ahead over every step the user has already done (e.g. they knew the next move).
        while s != .done, s.isDone(model, printShown: printShown), let next = TutorialStep(rawValue: s.rawValue + 1) {
            s = next
        }
        if s != step { withAnimation(.snappy) { step = s } }
    }

    private func finish() {
        tutorialDone = true
        withAnimation(.snappy) { step = nil }
    }
}
