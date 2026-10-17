import simd
import SwiftUI

/// The left tool column in model mode: six groups, nothing more.
struct ToolRail: View {
    @ObservedObject var model: EditorModel
    @Binding var showPrint: Bool
    @Binding var showImport: Bool

    var body: some View {
        VStack(spacing: 4) {
            RailButton(title: "Sketch", icon: "pencil.and.outline", active: false) { model.startSketch() }
                .keyboardShortcut("k", modifiers: [])
            Divider().frame(width: 30)
            RailMenu(title: "Shapes", icon: "cube") {
                toolButton(.box)
                toolButton(.cylinder)
                toolButton(.text)
                Divider()
                Button("Import STEP…", systemImage: "square.and.arrow.down") { showImport = true }
            }
            RailMenu(title: "Modify", icon: "wand.and.rays") {
                toolButton(.extrude)
                toolButton(.revolve)
                toolButton(.pushPull)
                Divider()
                toolButton(.fillet)
                toolButton(.chamfer)
                toolButton(.shell)
                toolButton(.hole)
            }
            RailMenu(title: "Arrange", icon: "square.on.square") {
                toolButton(.move)
                toolButton(.mirror)
                toolButton(.pattern)
                Divider()
                toolButton(.combine)
                toolButton(.split)
            }
            RailMenu(title: "Inspect", icon: "magnifyingglass") {
                toolButton(.measure)
                Button(model.section == nil ? "Section View" : "End Section View", systemImage: "square.split.diagonal") { model.toggleSection() }
                Toggle(isOn: $model.showAllSketches) { Label("Show All Sketches", systemImage: "pencil.and.outline") }
            }
            Divider().frame(width: 30)
            RailButton(title: "Print", icon: "printer", active: false) {
                model.runPrintCheck()
                showPrint = true
            }
        }
        .padding(8)
        .glassPanel(radius: 18)
    }

    private func toolButton(_ k: ToolKind) -> some View {
        Button { model.start(k) } label: { Label(k.title, systemImage: k.icon) }
    }
}

struct RailButton: View {
    let title: LocalizedStringKey
    let icon: String
    let active: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium))
                    .frame(width: 30, height: 24)
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: 60, height: 56)
            .background(active ? Theme.blue : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : .primary)
        .help(Text(title))
    }
}

struct RailMenu<Content: View>: View {
    let title: LocalizedStringKey
    let icon: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu {
            content()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 19, weight: .medium)).frame(width: 30, height: 24)
                Text(title).font(.system(size: 10.5, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.6)
            }
            .frame(width: 60, height: 56)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
    }
}

/// Drawing tools while a sketch is open.
struct SketchToolbar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        if let s = model.sketch {
            VStack(alignment: .leading, spacing: 8) {
                VStack(spacing: 4) {
                    ForEach(SketchTool.allCases) { t in
                        let button = RailButton(title: t.title, icon: t.icon, active: s.tool == t) {
                            if s.tool == t { model.cancelSketchAction() } else { model.setSketchTool(t) }
                        }
                        if let key = t.shortcut { button.keyboardShortcut(key, modifiers: []) } else { button }
                    }
                    if s.tool == .polygon {
                        Stepper(value: Binding(get: { s.polygonSides }, set: { model.sketch?.polygonSides = $0 }), in: 3...24) {
                            Text("\(s.polygonSides)").font(.caption.monospacedDigit())
                        }
                        .frame(width: 58)
                        .labelsHidden()
                    }
                }
                .padding(8)
                .glassPanel(radius: 18)
            }
        }
    }
}

/// The bar of actions for what is selected (above the timeline).
struct ContextBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let actions = model.sketch != nil ? sketchActions : modelActions
        if !actions.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(actions) { a in
                        Button(action: a.run) {
                            Label(a.title, systemImage: a.icon)
                        }
                        .buttonStyle(PillButtonStyle(prominent: a.prominent, destructive: a.id == "del"))
                    }
                }
                .padding(6)
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 820)
            .glassPanel(radius: 28)
        }
    }

    struct Action: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let icon: String
        var prominent = false
        let run: () -> Void
    }

    private var sketchActions: [Action] {
        model.sketchActions.map { Action(id: $0.id, title: $0.title, icon: $0.icon, run: $0.run) }
    }

    private var modelActions: [Action] {
        guard model.tool == nil else { return [] }
        var out: [Action] = []
        let sel = model.selection
        let regions = model.selectedRegions
        if !regions.isEmpty {
            out.append(Action(id: "ext", title: "Extrude", icon: ToolKind.extrude.icon, prominent: true) { model.start(.extrude) })
            out.append(Action(id: "rev", title: "Revolve", icon: ToolKind.revolve.icon) { model.start(.revolve) })
            if let sid = regions.first?.0 {
                out.append(Action(id: "edit", title: "Edit Sketch", icon: "pencil") { model.editSketch(sid) })
            }
            return out
        }
        if case .sketchLine(let sid, _)? = sel.first {
            out.append(Action(id: "edit", title: "Edit Sketch", icon: "pencil") { model.editSketch(sid) })
            return out
        }
        let faces = model.selectedFaces
        let edges = model.selectedEdges
        let bodies = sel.compactMap { if case .body(let b) = $0 { return b } else { return nil } }
        if !edges.isEmpty {
            out.append(Action(id: "fil", title: "Fillet", icon: ToolKind.fillet.icon, prominent: true) { model.start(.fillet) })
            out.append(Action(id: "cha", title: "Chamfer", icon: ToolKind.chamfer.icon) { model.start(.chamfer) })
        }
        if let (body, face) = faces.first {
            if face.isPlanar {
                out.append(Action(id: "sk", title: "Sketch", icon: "pencil.and.outline", prominent: true) { model.startSketch() })
                out.append(Action(id: "pp", title: "Push/Pull", icon: ToolKind.pushPull.icon) { model.start(.pushPull) })
                out.append(Action(id: "hole", title: "Hole", icon: ToolKind.hole.icon) { model.start(.hole) })
                out.append(Action(id: "txt", title: "Text", icon: ToolKind.text.icon) { model.start(.text) })
            }
            out.append(Action(id: "fil2", title: "Round edges", icon: ToolKind.fillet.icon) { model.start(.fillet) })
            out.append(Action(id: "shell", title: "Hollow", icon: ToolKind.shell.icon) { model.start(.shell) })
            out.append(Action(id: "body", title: "Select Body", icon: "cube.fill") { model.selection = [.body(body.id)] })
        }
        if !bodies.isEmpty {
            out.append(Action(id: "mv", title: "Move", icon: ToolKind.move.icon, prominent: true) { model.start(.move) })
            out.append(Action(id: "mir", title: "Mirror", icon: ToolKind.mirror.icon) { model.start(.mirror) })
            out.append(Action(id: "pat", title: "Pattern", icon: ToolKind.pattern.icon) { model.start(.pattern) })
            out.append(Action(id: "hol", title: "Hollow", icon: ToolKind.shell.icon) { model.start(.shell) })
            if bodies.count >= 2 {
                out.append(Action(id: "comb", title: "Combine", icon: ToolKind.combine.icon) { model.start(.combine) })
            }
            out.append(Action(id: "split", title: "Split", icon: ToolKind.split.icon) { model.start(.split) })
            out.append(Action(id: "del", title: "Delete", icon: "trash") { model.deleteSelectedBodies() })
        }
        return out
    }
}
