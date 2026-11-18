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

    /// The title as a resource, for VoiceOver announcements.
    var titleResource: LocalizedStringResource {
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
        case .sketch: "Tap Sketch to start. You will draw on the ground."
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
            let tint = s == .done ? Theme.ready : Theme.blue
            HStack(alignment: .top, spacing: Theme.Space.m) {
                Image(systemName: s.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolBounce(on: s == .done)
                    .frame(width: 44, height: 44)
                    .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    if s != .done {
                        HStack(spacing: Theme.Space.xs) {
                            Text("Step \(s.rawValue + 1) of \(total)")
                                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                .monospacedDigit()
                                .numericTransition(Double(s.rawValue))
                            progress(current: s.rawValue, total: total)
                        }
                    }
                    // The instruction slides in as the next piece (a cross-fade with Reduce Motion).
                    VStack(alignment: .leading, spacing: Theme.Space.xxs) {
                        Text(s.title).font(Theme.title(Theme.panelTitleSize, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(s.text).font(.subheadline).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .id(s)
                    .transition(Theme.Motion.push(from: .trailing))
                    // Buttons under the text: long translations ("Anleitung überspringen") no longer squeeze it.
                    HStack {
                        Spacer(minLength: 0)
                        if s == .done {
                            Button("Finish") { finish() }.buttonStyle(PillButtonStyle(prominent: true))
                        } else {
                            Button("Skip tutorial") { finish() }.buttonStyle(PillButtonStyle())
                        }
                    }
                }
                .clipped()
            }
            .padding(Theme.Space.m)
            .frame(maxWidth: 520)
            .glassPanel(radius: Theme.Radius.card)
            .accessibilityElement(children: .contain)
            .transition(Theme.Motion.panel(from: .bottom))
            .formwerkFeedback(.success, trigger: s == .done)
            // Re-check the current step whenever the editor changes.
            .onReceive(model.objectWillChange.receive(on: DispatchQueue.main)) { _ in advanceIfDone() }
            .onChange(of: printShown) { _, _ in advanceIfDone() }
        }
    }

    /// One short bar per step: done steps filled, the current one in blue and longer.
    private func progress(current: Int, total: Int) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<total, id: \.self) { i in
                Capsule()
                    .fill(i <= current ? Theme.blue : Color.primary.opacity(0.15))
                    .opacity(i < current ? 0.45 : 1)
                    .frame(width: i == current ? 16 : 8, height: 4)
            }
        }
        .animation(Theme.Motion.smooth, value: current)
        .accessibilityHidden(true)
    }

    private func advanceIfDone() {
        guard var s = step else { return }
        // Skip ahead over every step the user has already done (e.g. they knew the next move).
        while s != .done, s.isDone(model, printShown: printShown), let next = TutorialStep(rawValue: s.rawValue + 1) {
            s = next
        }
        if s != step {
            withAnimation(Theme.Motion.smooth) { step = s }
            // VoiceOver users hear the next instruction without hunting for the card.
            AccessibilityNotification.Announcement(String(localized: s.titleResource)).post()
        }
    }

    private func finish() {
        tutorialDone = true
        withAnimation(Theme.Motion.snappy) { step = nil }
    }
}
