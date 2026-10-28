import simd
import SwiftUI

/// The left tool column in model mode: six groups, nothing more.
struct ToolRail: View {
    @ObservedObject var model: EditorModel
    @Binding var showPrint: Bool
    @Binding var showImport: Bool
    /// iPhone (narrow screens): a row at the bottom instead of a column on the left.
    var horizontal = false

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
        let rail = layout {
            RailButton(title: "Sketch", icon: "pencil.and.outline", active: false) { model.startSketch() }
            Divider().frame(width: horizontal ? nil : 30, height: horizontal ? 30 : nil)
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
            Divider().frame(width: horizontal ? nil : 30, height: horizontal ? 30 : nil)
            RailButton(title: "Print", icon: "printer", active: false) {
                model.runPrintCheck()
                showPrint = true
            }
        }
        if horizontal {
            ScrollView(.horizontal, showsIndicators: false) { rail.padding(6) }
                .fixedSize(horizontal: false, vertical: true)
                .glassPanel()
        } else {
            rail.padding(8).glassPanel()
        }
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
            RailLabel(title: title, icon: icon)
                .background(active ? Theme.blue : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(active ? Color.white : .primary)
        .help(Text(title))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(active ? .isSelected : [])
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
            RailLabel(title: title, icon: icon)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
        .help(Text(title))
        .accessibilityLabel(Text(title))
    }
}

/// Icon over a short caption, 60 pt wide. Long words (German, Hindi) may wrap to a second line
/// instead of shrinking to an unreadable size.
struct RailLabel: View {
    let title: LocalizedStringKey
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 19, weight: .medium))
                .frame(width: 30, height: 24)
                .accessibilityHidden(true)
            Text(title).font(.system(size: 10.5, weight: .semibold))
                .lineLimit(2).minimumScaleFactor(0.85)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
        .frame(width: 60)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
    }
}

/// Drawing tools while a sketch is open.
struct SketchToolbar: View {
    @ObservedObject var model: EditorModel
    var horizontal = false

    var body: some View {
        if let s = model.sketch {
            let layout = horizontal ? AnyLayout(HStackLayout(spacing: 4)) : AnyLayout(VStackLayout(spacing: 4))
            let tools = layout {
                    ForEach(SketchTool.allCases) { t in
                        // Its letter key is handled by the 3D view (EditorModel.letterKey), not here:
                        // a SwiftUI shortcut without ⌘ would also fire while typing a dimension.
                        RailButton(title: t.title, icon: t.icon, active: s.tool == t) {
                            if s.tool == t { model.cancelSketchAction() } else { model.setSketchTool(t) }
                        }
                    }
                    if s.tool == .polygon {
                        PolygonSidesControl(sides: s.polygonSides, horizontal: horizontal) { model.sketch?.polygonSides = $0 }
                    }
            }
            if horizontal {
                ScrollView(.horizontal, showsIndicators: false) { tools.padding(6) }
                    .fixedSize(horizontal: false, vertical: true)
                    .glassPanel()
            } else {
                tools.padding(8).glassPanel()
            }
        }
    }
}

/// Number of polygon sides, sized for the 60 pt rail: − / count / +, each 44 pt tall.
/// (A system Stepper is 94 pt wide and got clipped, and its number was hidden.)
struct PolygonSidesControl: View {
    let sides: Int
    var horizontal = false
    let set: (Int) -> Void

    var body: some View {
        let layout = horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
        layout {
            stepButton("plus", label: "More sides", enabled: sides < 24) { set(min(sides + 1, 24)) }
            VStack(spacing: 0) {
                Text("\(sides)").font(Theme.number(17, weight: .semibold))
                Text("Sides").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 56)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sides"))
            .accessibilityValue(Text("\(sides)"))
            .accessibilityAdjustableAction { dir in
                switch dir {
                case .increment: set(min(sides + 1, 24))
                case .decrement: set(max(sides - 1, 3))
                @unknown default: break
                }
            }
            stepButton("minus", label: "Fewer sides", enabled: sides > 3) { set(max(sides - 1, 3)) }
        }
        .padding(.vertical, 2)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
    }

    private func stepButton(_ icon: String, label: LocalizedStringKey, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .bold))
                .frame(width: horizontal ? Theme.minTouch : 56, height: horizontal ? 56 : Theme.minTouch)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .accessibilityLabel(Text(label))
    }
}

/// The bar of actions for what is selected (above the timeline).
struct ContextBar: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        let actions = model.sketch != nil ? sketchActions : modelActions
        if !actions.isEmpty {
            let row = HStack(spacing: 6) {
                ForEach(actions) { a in
                    Button(action: a.run) {
                        Label(a.title, systemImage: a.icon)
                    }
                    .buttonStyle(PillButtonStyle(prominent: a.prominent, destructive: a.id == "del"))
                }
            }
            .padding(6)
            // Hug the buttons when they fit; scroll sideways on narrow screens (iPhone).
            ViewThatFits(in: .horizontal) {
                row.fixedSize().glassPanel(radius: Theme.Radius.bar)
                ScrollView(.horizontal, showsIndicators: false) { row }
                    .frame(maxWidth: 820)
                    .glassPanel(radius: Theme.Radius.bar)
            }
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
                out.append(Action(id: "flat", title: "Lay flat", icon: "arrow.down.to.line") { model.layFlat() })
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
