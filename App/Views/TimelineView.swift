import simd
import SwiftUI

/// Every step of the design at the bottom. Tap to edit, long-press/right-click for more.
struct TimelineView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let features = model.design.features
        if !features.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(features) { f in
                            chip(f).id(f.id)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: features.count) { _, _ in
                    if let last = features.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                }
            }
            .frame(maxWidth: 900)
            .fixedSize(horizontal: false, vertical: true)
            .glassPanel(radius: 24)
        }
    }

    private func chip(_ f: Feature) -> some View {
        let status = model.output.statuses[f.id] ?? .ok
        let editing = model.tool?.editing == f.id || (model.sketch?.featureID == f.id && model.sketch?.isNew == false)
        let tint: Color = switch status {
        case .error: .red
        case .warning: .orange
        case .ok: .primary
        }
        return Button { model.editFeature(f.id) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon(f)).font(.caption.weight(.semibold))
                Text(displayName(f)).font(.caption.weight(.medium)).lineLimit(1)
                if case .error = status { Image(systemName: "exclamationmark.circle.fill").font(.caption2) }
                if case .warning = status { Image(systemName: "exclamationmark.triangle.fill").font(.caption2) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(editing ? Theme.blue.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .foregroundStyle(tint)
            .opacity(f.suppressed ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .help(status.message.map { Text($0) } ?? Text(displayName(f)))
        .contextMenu {
            Button("Edit", systemImage: "pencil") { model.editFeature(f.id) }
            Button(f.suppressed ? "Turn On" : "Turn Off", systemImage: f.suppressed ? "eye" : "eye.slash") { model.toggleSuppressed(f.id) }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { model.deleteFeature(f.id) }
        }
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

    var body: some View {
        let _ = model.cameraTick
        ZStack {
            ForEach(model.dimensionLabels) { label in
                DimensionLabelView(model: model, label: label)
                    .position(label.position)
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
                .background(RoundedRectangle(cornerRadius: 7).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.accentColor, lineWidth: 2))
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
                .background(RoundedRectangle(cornerRadius: 6).fill(.background.opacity(0.9)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(label.conflict ? Color.red : Color.primary.opacity(0.25)))
                .foregroundStyle(label.conflict ? Color.red : Color.primary)
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
                        Button { model.toggleHidden(b.id) } label: {
                            Image(systemName: style.hidden ? "eye.slash" : "eye")
                        }
                        .buttonStyle(.borderless)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { model.selection = [.body(b.id)] }
                }
            }
            .navigationTitle("Bodies")
        }
    }
}
