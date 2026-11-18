import simd
import SwiftUI

/// Every step of the design at the bottom. Tap to edit, long-press/right-click for more.
/// On iOS/macOS 26 every step is its own interactive glass chip and the chips blend in one
/// glass container; before (and with Reduce Transparency) the chips sit on one glass bar and the
/// "editing" highlight slides between them.
struct TimelineView: View {
    @ObservedObject var model: EditorModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Namespace private var highlight

    var body: some View {
        let features = model.design.features
        if !features.isEmpty {
            strip(features)
                .frame(maxWidth: 900)
                .fixedSize(horizontal: false, vertical: true)
                .animation(Theme.Motion.snappy, value: editingID)
                .animation(Theme.Motion.smooth, value: features.count)
                // A tap on the model (face, edge, body) ticks once on iPhone.
                .formwerkFeedback(.selection, trigger: model.selection)
                .panelAppear(from: .bottom)
        }
    }

    @ViewBuilder
    private func strip(_ features: [Feature]) -> some View {
        if #available(iOS 26, macOS 26, *) {
            if reduceTransparency {
                scroller(features, glassChips: false).glassPanel(radius: Theme.Radius.bar)
            } else {
                scroller(features, glassChips: true)
            }
        } else {
            scroller(features, glassChips: false).glassPanel(radius: Theme.Radius.bar)
        }
    }

    private func scroller(_ features: [Feature], glassChips: Bool) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                FormwerkGlassGroup(spacing: 6) {
                    HStack(spacing: glassChips ? 6 : 4) {
                        ForEach(features) { f in
                            chip(f, glass: glassChips).id(f.id)
                        }
                    }
                    .padding(.horizontal, 6)
                }
            }
            .onChange(of: features.count) { _, _ in
                if let last = features.last { withAnimation(Theme.Motion.smooth) { proxy.scrollTo(last.id, anchor: .trailing) } }
            }
        }
    }

    /// The step being edited (tool or sketch open from the timeline).
    private var editingID: UUID? {
        if let id = model.tool?.editing { return id }
        if let s = model.sketch, !s.isNew { return s.featureID }
        return nil
    }

    private func chip(_ f: Feature, glass: Bool) -> some View {
        let status = model.output.statuses[f.id] ?? .ok
        let editing = editingID == f.id
        // Text stays primary for contrast; the status shows as a coloured badge and a tinted outline.
        let tint: Color? = switch status {
        case .error: Theme.problem
        case .warning: Theme.caution
        case .ok: nil
        }
        return Button { model.editFeature(f.id) } label: {
            HStack(spacing: 6) {
                Image(systemName: icon(f)).font(.caption.weight(.semibold))
                    .foregroundStyle(editing ? Theme.blue : Color.primary)
                    .accessibilityHidden(true)
                Text(displayName(f)).font(.caption.weight(.medium)).lineLimit(1)
                if case .error = status {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption).foregroundStyle(Theme.problem)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
                if case .warning = status {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(Theme.caution)
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, Theme.Space.s)
            .frame(minHeight: 36)
            .modifier(ChipBackground(glass: glass, editing: editing, namespace: highlight))
            .overlay(Capsule().strokeBorder(tint?.opacity(0.6) ?? (editing ? Theme.blue.opacity(0.6) : .clear), lineWidth: 1.5))
            .foregroundStyle(.primary)
            .opacity(f.suppressed ? 0.45 : 1)
            .hoverHighlight(Capsule())
            // 36 pt capsule, 44 pt tap area.
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleButtonStyle(scale: 0.95))
        .help(status.message.map { Text($0) } ?? Text(displayName(f)))
        .accessibilityLabel(Text(displayName(f)))
        .accessibilityValue(accessibilityStatus(f, status))
        .accessibilityAddTraits(editing ? .isSelected : [])
        .contextMenu {
            Button("Edit", systemImage: "pencil") { model.editFeature(f.id) }
            Button(f.suppressed ? "Turn On" : "Turn Off", systemImage: f.suppressed ? "eye" : "eye.slash") { model.toggleSuppressed(f.id) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteFeature(f.id) }
        }
    }

    /// Glass chip (26+, tinted blue while editing) or a quiet capsule whose blue highlight slides
    /// to the chip being edited.
    private struct ChipBackground: ViewModifier {
        let glass: Bool
        let editing: Bool
        let namespace: Namespace.ID

        @ViewBuilder
        func body(content: Content) -> some View {
            if glass {
                content.formwerkGlass(in: Capsule(), interactive: true, tint: editing ? Theme.blue.opacity(0.35) : nil)
            } else {
                content.background {
                    if editing {
                        Capsule().fill(Theme.blue.opacity(0.18))
                            .matchedGeometryEffect(id: "editing", in: namespace)
                    } else {
                        Capsule().fill(Color.primary.opacity(0.06))
                    }
                }
            }
        }
    }

    private func accessibilityStatus(_ f: Feature, _ status: ModelBuilder.Status) -> Text {
        var parts: [Text] = []
        if f.suppressed { parts.append(Text("Turned off")) }
        switch status {
        case .error(let m): parts.append(Text("Has a problem")); parts.append(Text(verbatim: m))
        case .warning(let m): parts.append(Text("Needs a check")); parts.append(Text(verbatim: m))
        case .ok: break
        }
        guard var out = parts.first else { return Text(verbatim: "") }
        for p in parts.dropFirst() { out = out + Text(verbatim: ", ") + p }
        return out
    }

    /// "Extrude 2" → localised kind + its number.
    private func displayName(_ f: Feature) -> String {
        let number = f.name.split(separator: " ").last.flatMap { Int($0) }
        let kind = FeatureNames.localized(f.kind)
        return number.map { "\(kind) \($0)" } ?? kind
    }

    private func icon(_ f: Feature) -> String {
        switch f.kind {
        case .sketch: "pencil.and.outline"
        case .extrude: ToolKind.extrude.icon
        case .revolve: ToolKind.revolve.icon
        case .pushPull: ToolKind.pushPull.icon
        case .fillet: ToolKind.fillet.icon
        case .chamfer: ToolKind.chamfer.icon
        case .shell: ToolKind.shell.icon
        case .boolean: ToolKind.combine.icon
        case .transform: ToolKind.move.icon
        case .mirror: ToolKind.mirror.icon
        case .pattern: ToolKind.pattern.icon
        case .hole: ToolKind.hole.icon
        case .primitive: "cube"
        case .text: ToolKind.text.icon
        case .importBody: "square.and.arrow.down"
        case .deleteBody: "trash"
        case .split: ToolKind.split.icon
        }
    }
}

enum FeatureNames {
    static func localized(_ k: Feature.Kind) -> String {
        switch k {
        case .sketch: String(localized: "Sketch")
        case .extrude: String(localized: "Extrude")
        case .revolve: String(localized: "Revolve")
        case .pushPull: String(localized: "Push/Pull")
        case .fillet: String(localized: "Fillet")
        case .chamfer: String(localized: "Chamfer")
        case .shell: String(localized: "Hollow")
        case .boolean: String(localized: "Combine")
        case .transform: String(localized: "Move")
        case .mirror: String(localized: "Mirror")
        case .pattern: String(localized: "Pattern")
        case .hole: String(localized: "Hole")
        case .primitive: String(localized: "Shape")
        case .text: String(localized: "Text")
        case .importBody: String(localized: "Import")
        case .deleteBody: String(localized: "Delete")
        case .split: String(localized: "Split")
        }
    }
}

/// Dimension values in the sketch. Tap one to type a new value.
struct DimensionLabels: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var camera: CameraTicker

    init(model: EditorModel) {
        self.model = model
        camera = model.cameraTicker
    }

    var body: some View {
        let _ = camera.tick
        ZStack {
            ForEach(model.dimensionLabels) { label in
                DimensionLabelView(model: model, label: label)
                    .position(label.position)
            }
            // Small constraint symbols (parallel, tangent, …) next to the geometry; tap one to select it.
            ForEach(model.constraintGlyphs) { g in
                Image(systemName: g.icon).font(.system(size: 10, weight: .bold))
                    .foregroundStyle(g.conflict ? Theme.problem : g.selected ? Theme.signal : Color.secondary)
                    .frame(width: 18, height: 18).background(Circle().fill(.background.opacity(0.85)))
                    .contentShape(Rectangle().inset(by: -6))
                    .onTapGesture { model.sketch?.selected = [.constraint(g.constraint)] }
                    .position(g.position)
            }
        }
    }
}

struct DimensionLabelView: View {
    @ObservedObject var model: EditorModel
    let label: EditorModel.DimensionLabel
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        if label.editing {
            TextField("", text: $text)
                .font(.callout.monospacedDigit().weight(.semibold))
                .multilineTextAlignment(.center)
                .frame(width: 96)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.blue, lineWidth: 2))
                .focused($focused)
                .onAppear {
                    text = Format.number(label.isAngle ? label.value : label.value / model.design.unit.millimetres, digits: 3)
                    DispatchQueue.main.async { focused = true }
                }
                .onSubmit(commit)
                #if os(iOS)
                .keyboardType(.numbersAndPunctuation)
                #endif
        } else {
            Text(label.text)
                .font(Theme.number(13, weight: .semibold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(label.conflict ? Theme.problem : Color.primary.opacity(0.25)))
                .foregroundStyle(label.conflict ? Theme.problem : Color.primary)
                .contentShape(Rectangle())
                .onTapGesture { model.sketch?.editingDimension = label.id }
                .contextMenu {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        model.sketch?.selected = [.constraint(label.id)]
                        model.deleteSketchSelection()
                    }
                }
        }
    }

    private func commit() {
        let v = label.isAngle ? Expression.parseAngle(text).map { $0 } : Expression.parseLength(text, defaultUnit: model.design.unit)
        guard let v else { model.sketch?.editingDimension = nil; return }
        if label.isAngle {
            model.setDimension(label.id, value: v)
        } else {
            model.setDimension(label.id, value: v)
        }
    }
}

/// All bodies with show/hide and colour.
struct BodyList: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        NavigationStack {
            List {
                if model.output.bodies.isEmpty {
                    Text("No bodies yet. Start with a sketch or a box.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.output.bodies.enumerated()), id: \.element.id) { i, b in
                    let style = model.design.style(b.id)
                    let c = Palette.bodies[style.colorIndex % Palette.bodies.count]
                    HStack {
                        Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z))).frame(width: 14, height: 14)
                        Text(style.name ?? String(localized: "Body \(i + 1)"))
                        Spacer()
                        Text(Format.number(b.props.volume / 1000, digits: 1) + " cm³").font(.caption).foregroundStyle(.secondary)
                        Button {
                            withAnimation(Theme.Motion.snappy) { model.toggleHidden(b.id) }
                        } label: {
                            Image(systemName: style.hidden ? "eye.slash" : "eye")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(minWidth: 28, minHeight: 28)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(Text(style.hidden ? "Show" : "Hide"))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = [.body(b.id)] }
                }
            }
            .navigationTitle("Bodies")
        }
    }
}
