import SwiftUI

/// Where the Pencil tool palette is open (BAUPLAN 6.2). The 3D view opens it on an Apple Pencil Pro squeeze or a
/// double-tap set to "Show palette"; `PencilPaletteOverlay` draws it.
@MainActor
final class PencilPaletteState: ObservableObject {
    static let shared = PencilPaletteState()

    /// Centre of the palette in window coordinates (UIKit window = SwiftUI `.global`); nil = closed.
    @Published private(set) var location: CGPoint?
    /// The editor (its `EditorModel`) whose window opened the palette, so a second window doesn't show it too.
    private(set) var owner: ObjectIdentifier?

    var isShown: Bool { location != nil }

    func show(at windowPoint: CGPoint, for owner: AnyObject?) {
        self.owner = owner.map { ObjectIdentifier($0) }
        location = windowPoint
    }

    func dismiss() {
        guard location != nil else { return }
        location = nil
        owner = nil
    }

    func isShown(for model: AnyObject) -> Bool {
        location != nil && owner == ObjectIdentifier(model)
    }
}

/// The Pencil tool palette: a ring of sketch tools around the Pencil tip. Lay it over the 3D view, full window
/// (`.ignoresSafeArea()`); it is transparent to touches while closed.
struct PencilPaletteOverlay: View {
    @ObservedObject var model: EditorModel
    @ObservedObject private var state = PencilPaletteState.shared
    @Environment(\.layoutDirection) private var direction

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let global = state.location, state.isShown(for: model) {
                    let frame = geo.frame(in: .global)
                    let center = clamped(CGPoint(x: global.x - frame.minX, y: global.y - frame.minY), in: geo.size)
                    let anchor = UnitPoint(x: center.x / max(geo.size.width, 1), y: center.y / max(geo.size.height, 1))
                    // Any touch outside the ring closes it.
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onEnded { _ in state.dismiss() })
                        .accessibilityHidden(true)
                    PencilPaletteRing(model: model) { state.dismiss() }
                        .environment(\.layoutDirection, direction)  // the ring itself mirrors as usual
                        .position(center)
                        .transition(.scale(scale: 0.6, anchor: anchor).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // The point comes from UIKit (x from the left), so lay it out left-to-right in Arabic too.
            .environment(\.layoutDirection, .leftToRight)
        }
        .allowsHitTesting(state.isShown(for: model))
        .animation(.snappy(duration: 0.18), value: state.location)
    }

    /// Keeps the whole ring on screen near the edges.
    private func clamped(_ p: CGPoint, in size: CGSize) -> CGPoint {
        let r = PencilPaletteRing.diameter / 2 + 8
        return CGPoint(x: min(max(p.x, r), max(size.width - r, r)), y: min(max(p.y, r), max(size.height - r, r)))
    }
}

/// Eight sketch tools and Undo on a circle. The centre stays empty: it is where the Pencil tip is.
private struct PencilPaletteRing: View {
    @ObservedObject var model: EditorModel
    let close: () -> Void

    static let tools: [SketchTool] = [.select, .line, .rectangle, .circle, .arc, .slot, .polygon, .dimension]
    static let button: CGFloat = 46
    static let radius: CGFloat = 76
    static var diameter: CGFloat { radius * 2 + button }

    var body: some View {
        let count = Self.tools.count + 1
        container {
            ZStack {
                ForEach(Array(Self.tools.enumerated()), id: \.element) { i, t in
                    toolButton(t).offset(offset(i, of: count))
                }
                undoButton.offset(offset(Self.tools.count, of: count))
            }
            .frame(width: Self.diameter, height: Self.diameter)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Tool palette"))
    }

    /// Clockwise from the top.
    private func offset(_ i: Int, of count: Int) -> CGSize {
        let a = -Double.pi / 2 + Double(i) * 2 * Double.pi / Double(count)
        return CGSize(width: Self.radius * cos(a), height: Self.radius * sin(a))
    }

    private var activeTool: SketchTool? { model.sketch?.tool }

    private func toolButton(_ t: SketchTool) -> some View {
        let active = activeTool == t
        return Button { choose(t) } label: {
            chrome(Image(systemName: t.icon), active: active)
        }
        .buttonStyle(.plain)
        .disabled(t == .dimension && model.sketch == nil)
        .accessibilityLabel(Text(t.title))
        .accessibilityAddTraits(active ? .isSelected : [])
        .help(Text(t.title))
    }

    private var undoButton: some View {
        // Undo keeps the palette open, so it can be tapped a few times in a row.
        Button { model.viewportUndo() } label: {
            chrome(Image(systemName: "arrow.uturn.backward"), active: false)
        }
        .buttonStyle(.plain)
        .disabled(model.sketch.map { $0.undoStack.isEmpty } ?? (model.tool == nil && model.undoManager?.canUndo != true))
        .accessibilityLabel(Text("Undo"))
        .help(Text("Undo"))
    }

    private func choose(_ t: SketchTool) {
        if model.sketch != nil {
            model.setSketchTool(t)
        } else if t == .select {
            if model.tool != nil { model.cancelTool() }
        } else {
            // Like the drawing keys: outside a sketch, a drawing tool opens a new sketch with that tool.
            if model.tool != nil { model.cancelTool() }
            model.startSketch()
            model.setSketchTool(t)
        }
        Haptics.tick()
        close()
    }

    @ViewBuilder
    private func chrome(_ icon: Image, active: Bool) -> some View {
        let label = icon
            .font(.system(size: 18, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Color.white : Color.primary)
            .frame(width: Self.button, height: Self.button)
            .contentShape(Circle())
        if #available(iOS 26.0, macOS 26.0, *) {
            label.glassEffect(active ? .regular.tint(.accentColor).interactive() : .regular.interactive(), in: Circle())
        } else {
            label
                .background(Circle().fill(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.regularMaterial)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.08)))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        }
    }

    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content() }
        } else {
            content()
        }
    }
}
