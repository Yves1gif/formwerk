import simd
import SwiftUI

/// The right panel: settings of the open tool, the sketch status, or facts about the selection.
struct Inspector: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if model.sketch != nil {
                SketchPanel(model: model)
            } else if let tool = model.tool {
                ToolPanel(model: model, tool: tool)
            } else if !model.selection.isEmpty {
                SelectionPanel(model: model)
            }
            if model.section != nil && model.sketch == nil && model.tool == nil {
                Divider()
                SectionPanel(model: model)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassPanel(radius: 18)
    }
}

/// Done / Cancel buttons at the bottom of a panel.
struct PanelButtons: View {
    let done: () -> Void
    let cancel: () -> Void
    var doneEnabled = true

    var body: some View {
        HStack(spacing: 10) {
            Button("Cancel", role: .cancel, action: cancel)
                .buttonStyle(PanelButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button("Done", action: done)
                .buttonStyle(PanelButtonStyle(prominent: true))
                .disabled(!doneEnabled)
                .opacity(doneEnabled ? 1 : 0.5)
        }
        .padding(.top, 4)
    }
}

// MARK: - Sketch

struct SketchPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.sketch {
            VStack(alignment: .leading, spacing: 12) {
                Text(s.tool.title).font(Theme.title(19, weight: .semibold))
                Text(s.tool.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if s.isNew && s.isEmpty, case .origin(let p, _) = s.planeRef {
                    PickerRow(title: "Plane", selection: Binding(get: { p }, set: { model.setSketchPlane($0) })) {
                        Text("Ground (XY)").tag(OriginPlane.xy)
                        Text("Front (XZ)").tag(OriginPlane.xz)
                        Text("Side (YZ)").tag(OriginPlane.yz)
                    }
                }
                status(s)
                HStack {
                    Button { model.sketchUndo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(s.undoStack.isEmpty)
                    Button { model.sketchRedo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(s.redoStack.isEmpty)
                    Spacer()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func status(_ s: SketchSession) -> some View {
        if let r = s.solve, !r.conflicting.isEmpty {
            Label("Some constraints contradict each other (red).", systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.red)
        } else if let r = s.solve, r.isFullyDefined, !s.isEmpty {
            Label("Fully defined", systemImage: "checkmark.seal.fill").font(.callout).foregroundStyle(.green)
        } else if !s.isEmpty {
            Label("Blue parts can still move. Add dimensions to fix them.", systemImage: "circle.dashed")
                .font(.callout).foregroundStyle(.blue)
        }
    }
}

// MARK: - Tools

struct ToolPanel: View {
    @ObservedObject var model: EditorModel
    let tool: ToolSession

    private var unit: LengthUnit { model.design.unit }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: tool.kind.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.blue)
                    .frame(width: 36, height: 36)
                    .background(Theme.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(tool.kind.title).font(Theme.title(21, weight: .semibold))
                if tool.editing != nil { Text("(editing)").font(.caption).foregroundStyle(.secondary) }
            }
            Text(tool.kind.hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            fields
            switch tool.status {
            case .error(let m): Label(m, systemImage: "xmark.octagon.fill").font(.callout).foregroundStyle(.red)
            case .warning(let m): Label(m, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            case .ok: EmptyView()
            }
            if tool.kind == .measure {
                if let m = model.measurement {
                    Text(m.text).font(.title2.monospacedDigit().weight(.semibold))
                }
                Button("Close") { model.cancelTool() }.buttonStyle(.bordered)
            } else {
                PanelButtons(done: { model.applyTool() }, cancel: { model.cancelTool() },
                             doneEnabled: !{ if case .error = tool.status { return true } else { return false } }())
            }
        }
    }

    private func update(_ op: Operation, manual: Bool = false) {
        model.updateTool { t in
            t.feature.operation = op
            if manual { t.autoMode = false }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch tool.feature.operation {
        case .extrude(let e):
            LengthField(title: "Height", value: Binding(get: { e.distance }, set: { v in
                var n = e; n.distance = v == 0 ? 0.1 : v
                if tool.autoMode, n.target != nil { n.mode = v >= 0 ? .join : .cut }
                update(.extrude(n))
            }), unit: unit)
            Toggle("Both directions", isOn: Binding(get: { e.symmetric }, set: { var n = e; n.symmetric = $0; update(.extrude(n)) }))
            modePicker(e.mode) { var n = e; n.mode = $0; update(.extrude(n), manual: true) }
            Text("\(e.regionSeeds.count) areas").font(.caption).foregroundStyle(.secondary)

        case .revolve(let r):
            AngleField(title: "Angle", radians: Binding(get: { r.angle }, set: { var n = r; n.angle = min(max($0, 0.01), 2 * .pi); update(.revolve(n)) }))
            modePicker(r.mode) { var n = r; n.mode = $0; update(.revolve(n), manual: true) }
            Text(r.axisCurve == nil ? "Axis: the sketch's vertical axis" : "Axis: chosen sketch line").font(.caption).foregroundStyle(.secondary)

        case .pushPull(let p):
            LengthField(title: "Distance", value: Binding(get: { p.distance }, set: { var n = p; n.distance = $0 == 0 ? 0.1 : $0; update(.pushPull(n)) }), unit: unit)

        case .fillet(let f):
            LengthField(title: "Radius", value: Binding(get: { f.value }, set: { var n = f; n.value = max($0, 0.01); update(.fillet(n)) }), unit: unit, step: 0.5, range: 0.01...10_000)
            Text("\(f.edges.count) edges").font(.caption).foregroundStyle(.secondary)

        case .chamfer(let f):
            LengthField(title: "Distance", value: Binding(get: { f.value }, set: { var n = f; n.value = max($0, 0.01); update(.chamfer(n)) }), unit: unit, step: 0.5, range: 0.01...10_000)
            Text("\(f.edges.count) edges").font(.caption).foregroundStyle(.secondary)

        case .shell(let s):
            LengthField(title: "Wall", value: Binding(get: { s.thickness }, set: { var n = s; n.thickness = max($0, 0.1); update(.shell(n)) }), unit: unit, step: 0.4, range: 0.1...1000)
            Text(s.openFaces.isEmpty ? "Closed inside (no open face)" : "\(s.openFaces.count) open faces").font(.caption).foregroundStyle(.secondary)

        case .hole(let h):
            holeFields(h)

        case .transform(let m):
            PanelSection("Move") {
                LengthField(title: "X", value: Binding(get: { m.translation.x }, set: { var n = m; n.translation.x = $0; update(.transform(n)) }), unit: unit)
                LengthField(title: "Y", value: Binding(get: { m.translation.y }, set: { var n = m; n.translation.y = $0; update(.transform(n)) }), unit: unit)
                LengthField(title: "Z", value: Binding(get: { m.translation.z }, set: { var n = m; n.translation.z = $0; update(.transform(n)) }), unit: unit)
            }
            PanelSection("Rotate") {
                PickerRow(title: "Around", selection: Binding(get: { axisIndex(m.axis) }, set: { var n = m; n.axis = axisVector($0); update(.transform(n)) })) {
                    Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2)
                }
                AngleField(title: "Angle", radians: Binding(get: { m.angle }, set: { var n = m; n.angle = $0; update(.transform(n)) }))
            }
            Toggle("Keep the original (copy)", isOn: Binding(get: { m.copy }, set: { var n = m; n.copy = $0; update(.transform(n)) }))
            Text("\(m.bodies.count) bodies").font(.caption).foregroundStyle(.secondary)

        case .mirror(let m):
            planePicker(m.plane) { var n = m; n.plane = $0; update(.mirror(n)) }
            Toggle("Keep the original", isOn: Binding(get: { m.keepOriginal }, set: { var n = m; n.keepOriginal = $0; update(.mirror(n)) }))
            if m.keepOriginal {
                Toggle("Join into one body", isOn: Binding(get: { m.merge }, set: { var n = m; n.merge = $0; update(.mirror(n)) }))
            }

        case .pattern(let p):
            PickerRow(title: "Kind", selection: Binding(get: { p.kind }, set: { var n = p; n.kind = $0; update(.pattern(n)) })) {
                Text("In a row").tag(PatternFeature.Kind.linear)
                Text("Around an axis").tag(PatternFeature.Kind.circular)
            }
            Stepper(value: Binding(get: { p.count }, set: { var n = p; n.count = $0; update(.pattern(n)) }), in: 2...200) {
                HStack { Text("Count").foregroundStyle(.secondary); Spacer(); Text("\(p.count)").monospacedDigit() }.font(.callout)
            }
            if p.kind == .linear {
                PickerRow(title: "Direction", selection: Binding(get: { axisIndex(p.direction) }, set: { var n = p; n.direction = axisVector($0); update(.pattern(n)) })) {
                    Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2)
                }
                LengthField(title: "Spacing", value: Binding(get: { p.spacing }, set: { var n = p; n.spacing = $0; update(.pattern(n)) }), unit: unit)
            } else {
                PickerRow(title: "Axis", selection: Binding(get: { axisIndex(p.axis) }, set: { var n = p; n.axis = axisVector($0); update(.pattern(n)) })) {
                    Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2)
                }
                AngleField(title: "Total angle", radians: Binding(get: { p.totalAngle }, set: { var n = p; n.totalAngle = $0; update(.pattern(n)) }))
            }
            Toggle("Join into one body", isOn: Binding(get: { p.merge }, set: { var n = p; n.merge = $0; update(.pattern(n)) }))

        case .text(let t):
            TextField("Text", text: Binding(get: { t.text }, set: { var n = t; n.text = $0; update(.text(n)) }))
                .textFieldStyle(.roundedBorder)
            PickerRow(title: "Font", selection: Binding(get: { t.fontName }, set: { var n = t; n.fontName = $0; update(.text(n)) })) {
                ForEach(TextFonts.all, id: \.self) { f in Text(TextFonts.displayName(f)).tag(f) }
            }
            LengthField(title: "Size", value: Binding(get: { t.size }, set: { var n = t; n.size = max($0, 1); update(.text(n)) }), unit: unit, range: 1...1000)
            LengthField(title: "Depth", value: Binding(get: { t.depth }, set: { var n = t; n.depth = max($0, 0.1); update(.text(n)) }), unit: unit, step: 0.2, range: 0.1...1000)
            PickerRow(title: "Style", selection: Binding(get: { t.mode }, set: { var n = t; n.mode = $0; update(.text(n), manual: true) })) {
                Text("Raised").tag(BodyMode.join)
                Text("Engraved").tag(BodyMode.cut)
                Text("Separate body").tag(BodyMode.newBody)
            }

        case .boolean(let b):
            PickerRow(title: "Operation", selection: Binding(get: { b.op }, set: { var n = b; n.op = $0; update(.boolean(n)) })) {
                Text("Join").tag(BooleanFeature.Op.union)
                Text("Subtract").tag(BooleanFeature.Op.subtract)
                Text("Keep overlap").tag(BooleanFeature.Op.intersect)
            }
            Toggle("Keep the tool bodies", isOn: Binding(get: { b.keepTools }, set: { var n = b; n.keepTools = $0; update(.boolean(n)) }))

        case .split(let s):
            planePicker(s.plane) { var n = s; n.plane = $0; update(.split(n)) }

        case .primitive(let p):
            if p.kind == .box {
                LengthField(title: "Width (X)", value: Binding(get: { p.size.x }, set: { var n = p; n.size.x = max($0, 0.1); n.origin.x = -n.size.x / 2; update(.primitive(n)) }), unit: unit, range: 0.1...100_000)
                LengthField(title: "Depth (Y)", value: Binding(get: { p.size.y }, set: { var n = p; n.size.y = max($0, 0.1); n.origin.y = -n.size.y / 2; update(.primitive(n)) }), unit: unit, range: 0.1...100_000)
                LengthField(title: "Height (Z)", value: Binding(get: { p.size.z }, set: { var n = p; n.size.z = max($0, 0.1); update(.primitive(n)) }), unit: unit, range: 0.1...100_000)
            } else {
                LengthField(title: "Diameter", value: Binding(get: { p.size.x }, set: { var n = p; n.size.x = max($0, 0.1); update(.primitive(n)) }), unit: unit, range: 0.1...100_000)
                LengthField(title: "Height", value: Binding(get: { p.size.z }, set: { var n = p; n.size.z = max($0, 0.1); update(.primitive(n)) }), unit: unit, range: 0.1...100_000)
            }
            LengthField(title: "Lift (Z)", value: Binding(get: { p.origin.z }, set: { var n = p; n.origin.z = $0; update(.primitive(n)) }), unit: unit)

        default:
            EmptyView()
        }
    }

    private func modePicker(_ mode: BodyMode, set: @escaping (BodyMode) -> Void) -> some View {
        PickerRow(title: "Result", selection: Binding(get: { mode }, set: set)) {
            Text("New body").tag(BodyMode.newBody)
            Text("Add").tag(BodyMode.join)
            Text("Cut away").tag(BodyMode.cut)
            Text("Keep overlap").tag(BodyMode.intersect)
        }
    }

    private func planePicker(_ ref: PlaneRef, set: @escaping (PlaneRef) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            PickerRow(title: "Plane", selection: Binding(get: { planeTag(ref) }, set: { tag in
                switch tag {
                case "xy": set(.origin(.xy, offset: planeOffset(ref)))
                case "xz": set(.origin(.xz, offset: planeOffset(ref)))
                case "yz": set(.origin(.yz, offset: planeOffset(ref)))
                default: break
                }
            })) {
                Text("Ground (XY)").tag("xy")
                Text("Front (XZ)").tag("xz")
                Text("Side (YZ)").tag("yz")
                if case .face = ref { Text("Chosen face").tag("face") }
            }
            if case .origin(let p, let o) = ref {
                LengthField(title: "Offset", value: Binding(get: { o }, set: { set(.origin(p, offset: $0)) }), unit: unit)
            }
        }
    }

    private func planeTag(_ r: PlaneRef) -> String {
        switch r {
        case .origin(let p, _): p.rawValue
        case .face: "face"
        }
    }

    private func planeOffset(_ r: PlaneRef) -> Double {
        if case .origin(_, let o) = r { return o }
        return 0
    }

    @ViewBuilder
    private func holeFields(_ h: HoleFeature) -> some View {
        PickerRow(title: "Kind", selection: Binding(get: { h.kind }, set: { var n = h; n.kind = $0; update(.hole(n)) })) {
            Text("Simple").tag(HoleFeature.Kind.simple)
            Text("Counterbore").tag(HoleFeature.Kind.counterbore)
            Text("Countersink").tag(HoleFeature.Kind.countersink)
        }
        HStack {
            Text("Screw").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Menu("Choose…") {
                ForEach(ScrewSize.all, id: \.name) { s in
                    Button("\(s.name) (\(Format.number(s.clearance)) mm)") {
                        var n = h
                        n.diameter = s.clearance
                        n.headDiameter = n.kind == .countersink ? s.countersink : s.headDiameter
                        n.headDepth = s.headDepth
                        update(.hole(n))
                    }
                }
            }
            .fixedSize()
        }
        LengthField(title: "Diameter", value: Binding(get: { h.diameter }, set: { var n = h; n.diameter = max($0, 0.2); update(.hole(n)) }), unit: unit, step: 0.1, range: 0.2...10_000)
        Toggle("Through everything", isOn: Binding(get: { h.depth <= 0 }, set: { var n = h; n.depth = $0 ? 0 : 10; update(.hole(n)) }))
        if h.depth > 0 {
            LengthField(title: "Depth", value: Binding(get: { h.depth }, set: { var n = h; n.depth = max($0, 0.1); update(.hole(n)) }), unit: unit, range: 0.1...10_000)
        }
        if h.kind != .simple {
            LengthField(title: "Head diameter", value: Binding(get: { h.headDiameter }, set: { var n = h; n.headDiameter = max($0, n.diameter + 0.2); update(.hole(n)) }), unit: unit, step: 0.5, range: 0.2...10_000)
        }
        if h.kind == .counterbore {
            LengthField(title: "Head depth", value: Binding(get: { h.headDepth }, set: { var n = h; n.headDepth = max($0, 0.1); update(.hole(n)) }), unit: unit, step: 0.5, range: 0.1...10_000)
        }
        Text("\(h.positions.count) holes").font(.caption).foregroundStyle(.secondary)
    }

    private func axisIndex(_ v: Vec3) -> Int { abs(v.x) > 0.5 ? 0 : abs(v.y) > 0.5 ? 1 : 2 }
    private func axisVector(_ i: Int) -> Vec3 { i == 0 ? Vec3(1, 0, 0) : i == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1) }
}

/// Metric screw holes that print well (clearance holes are a bit bigger than the screw).
struct ScrewSize {
    let name: String
    let clearance: Double
    let headDiameter: Double
    let headDepth: Double
    let countersink: Double

    static let all: [ScrewSize] = [
        ScrewSize(name: "M2", clearance: 2.4, headDiameter: 4.4, headDepth: 2.2, countersink: 4.4),
        ScrewSize(name: "M2.5", clearance: 2.9, headDiameter: 5.5, headDepth: 2.7, countersink: 5.5),
        ScrewSize(name: "M3", clearance: 3.4, headDiameter: 6.5, headDepth: 3.4, countersink: 6.6),
        ScrewSize(name: "M4", clearance: 4.5, headDiameter: 8.0, headDepth: 4.4, countersink: 8.8),
        ScrewSize(name: "M5", clearance: 5.5, headDiameter: 10.0, headDepth: 5.4, countersink: 10.6),
        ScrewSize(name: "M6", clearance: 6.6, headDiameter: 11.0, headDepth: 6.4, countersink: 12.8),
        ScrewSize(name: "M8", clearance: 9.0, headDiameter: 15.0, headDepth: 8.6, countersink: 17.6),
    ]
}

enum TextFonts {
    static let all = ["Helvetica-Bold", "AvenirNext-Heavy", "Futura-Bold", "ArialRoundedMTBold", "Menlo-Bold", "Georgia-Bold", "Courier-Bold"]
    static func displayName(_ f: String) -> String {
        switch f {
        case "Helvetica-Bold": "Helvetica"
        case "AvenirNext-Heavy": "Avenir Next"
        case "Futura-Bold": "Futura"
        case "ArialRoundedMTBold": "Arial Rounded"
        case "Menlo-Bold": "Menlo"
        case "Georgia-Bold": "Georgia"
        case "Courier-Bold": "Courier"
        default: f
        }
    }
}

// MARK: - Selection facts

struct SelectionPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let unit = model.design.unit
        VStack(alignment: .leading, spacing: 10) {
            if let first = model.selection.first {
                switch first {
                case .face(let b, let f):
                    if let face = model.body(b)?.face(f) {
                        header(model.selection.count == 1 ? "Face" : "\(model.selection.count) items", icon: "square")
                        fact("Area", Format.number(face.area, digits: 1) + " mm²")
                        if face.kind == .cylinder { fact("Diameter", Format.length(face.radius * 2, unit: unit)) }
                        if face.isPlanar { fact("Height", Format.length(face.centroid.z, unit: unit)) }
                    }
                case .edge(let b, let e):
                    if let edge = model.body(b)?.edge(e) {
                        let total = model.selectedEdges.reduce(0) { $0 + $1.1.length }
                        header(model.selection.count == 1 ? "Edge" : "\(model.selection.count) edges", icon: "line.diagonal")
                        fact("Length", Format.length(total, unit: unit))
                        if edge.kind == .circle { fact("Diameter", Format.length(edge.radius * 2, unit: unit)) }
                    }
                case .body:
                    bodyFacts(unit)
                case .region(let s, let i):
                    if let r = model.output.sketches[s]?.regions[safe: i] {
                        header("Sketch area", icon: "pencil.and.outline")
                        fact("Area", Format.number(r.area, digits: 1) + " mm²")
                    }
                case .sketchLine:
                    header("Sketch line", icon: "line.diagonal")
                    Text("Use it as axis for Revolve.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func bodyFacts(_ unit: LengthUnit) -> some View {
        let ids = model.selectedBodies
        let bodies = ids.compactMap { model.body($0) }
        let volume = bodies.reduce(0) { $0 + $1.props.volume }
        var box = Box3.empty
        let _ = bodies.forEach { box.add($0.props.bounds) }
        header(bodies.count == 1 ? "Body" : "\(bodies.count) bodies", icon: "cube.fill")
        fact("Volume", Format.number(volume / 1000, digits: 2) + " cm³")
        fact("Size", "\(Format.number(box.size.x, digits: 1)) × \(Format.number(box.size.y, digits: 1)) × \(Format.number(box.size.z, digits: 1)) mm")
        HStack(spacing: 6) {
            ForEach(Palette.bodies.indices, id: \.self) { i in
                let c = Palette.bodies[i]
                Button { model.setColor(i, for: ids) } label: {
                    Circle().fill(Color(red: Double(c.x), green: Double(c.y), blue: Double(c.z)))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(0.25)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func header(_ title: LocalizedStringKey, icon: String) -> some View {
        Label(title, systemImage: icon).font(Theme.title(19, weight: .semibold))
    }

    private func fact(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value).font(Theme.number()) }.font(.callout)
    }
}

struct SectionPanel: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.section {
            let box = model.output.bounds
            let lo = box.isEmpty ? -50 : box.min[s.axis] - 1
            let hi = box.isEmpty ? 50 : box.max[s.axis] + 1
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Section", systemImage: "square.split.diagonal").font(.headline)
                    Spacer()
                    Button("End") { model.toggleSection() }.buttonStyle(.bordered).controlSize(.small)
                }
                Picker("Axis", selection: Binding(get: { s.axis }, set: { model.setSectionAxis($0) })) {
                    Text("X").tag(0); Text("Y").tag(1); Text("Z").tag(2)
                }
                .pickerStyle(.segmented)
                Slider(value: Binding(get: { s.offset }, set: { model.section?.offset = $0 }), in: lo...max(hi, lo + 1))
                Text(Format.length(s.offset, unit: model.design.unit)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension EditorModel {
    func toggleSection() {
        if section == nil {
            let box = output.bounds
            section = SectionView(normal: Vec3(0, 0, 1), offset: box.isEmpty ? 0 : box.center.z, axis: 2)
        } else {
            section = nil
        }
    }

    func setSectionAxis(_ a: Int) {
        let box = output.bounds
        let n = a == 0 ? Vec3(1, 0, 0) : a == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1)
        section = SectionView(normal: n, offset: box.isEmpty ? 0 : box.center[a], axis: a)
    }
}
