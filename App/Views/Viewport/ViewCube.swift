import SwiftUI

/// What the view cube asks the editor to do.
enum ViewCubeAction: Equatable {
    /// Look straight at one side (animated, framed like the View menu does it).
    case view(EditorModel.StandardView)
    /// The house button: fit everything into view.
    case home
}

/// A small orientation cube for a corner of the 3D view.
/// It turns with the camera (it observes `Renderer.orientation`, published at most once per frame).
/// Tap a side to look at it, tap the house to fit everything, drag the cube to orbit (with inertia).
struct ViewCubeView: View {
    @ObservedObject private var renderer: Renderer
    private let size: CGFloat
    private let onSelect: (ViewCubeAction) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovered: CubeFace?
    @State private var pressed: CubeFace?
    @State private var dragging = false
    @State private var dragLast: CGPoint?

    /// - Parameters:
    ///   - size: edge of the square the cube is drawn in (points); the cube's own side is about size / 1.8.
    ///   - onSelect: called on the main thread when a side or the house is tapped.
    init(renderer: Renderer, size: CGFloat = 72, onSelect: @escaping (ViewCubeAction) -> Void) {
        _renderer = ObservedObject(wrappedValue: renderer)
        self.size = size
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            homeButton
            cube
        }
    }

    // MARK: - Cube

    private var cube: some View {
        let geometry = CubeGeometry(orientation: renderer.orientation, size: size)
        return Canvas { context, _ in
            draw(geometry, in: context)
        }
        .frame(width: size, height: size)
        // The cube is geometry, not reading order: never mirror it for right-to-left languages.
        .environment(\.layoutDirection, .leftToRight)
        .contentShape(Rectangle())
        .gesture(dragGesture)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let p): hovered = currentGeometry.face(at: p)
            case .ended: hovered = nil
            }
        }
        .padding(6)
        .viewCubeGlass(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("View cube"))
        .accessibilityAction(named: Text("Top")) { onSelect(.view(.top)) }
        .accessibilityAction(named: Text("Front")) { onSelect(.view(.front)) }
        .accessibilityAction(named: Text("Right")) { onSelect(.view(.right)) }
        .accessibilityAction(named: Text("Back")) { onSelect(.view(.back)) }
        .accessibilityAction(named: Text("Left")) { onSelect(.view(.left)) }
        .accessibilityAction(named: Text("Bottom")) { onSelect(.view(.bottom)) }
        .accessibilityAction(named: Text("3D View")) { onSelect(.view(.iso)) }
    }

    private var currentGeometry: CubeGeometry { CubeGeometry(orientation: renderer.orientation, size: size) }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !dragging {
                    if hypot(value.translation.width, value.translation.height) < 4 {
                        pressed = currentGeometry.face(at: value.startLocation)
                        return
                    }
                    dragging = true
                    pressed = nil
                    dragLast = value.startLocation
                    renderer.stopInertia()
                }
                let last = dragLast ?? value.startLocation
                // Same direction as dragging in the 3D view: the cube follows the finger like the model does.
                renderer.camera.orbit(dx: Double(value.location.x - last.x), dy: Double(value.location.y - last.y))
                dragLast = value.location
            }
            .onEnded { value in
                if dragging {
                    renderer.flingOrbit(velocity: CGPoint(x: value.velocity.width, y: value.velocity.height))
                } else if let face = currentGeometry.face(at: value.location) {
                    onSelect(.view(face.standardView))
                }
                dragging = false
                dragLast = nil
                pressed = nil
            }
    }

    private func draw(_ g: CubeGeometry, in context: GraphicsContext) {
        let dark = colorScheme == .dark
        let edge = dark ? Color.white.opacity(0.22) : Color.black.opacity(0.18)
        let ink = dark ? Color(white: 0.9) : Color(white: 0.22)
        for f in g.faces {
            var path = Path()
            path.addLines(f.corners)
            path.closeSubpath()
            // Lit from the viewer: the face you look at straight is brightest.
            let shade = dark ? 0.20 + 0.16 * f.facing : 0.80 + 0.20 * f.facing
            context.fill(path, with: .color(Color(white: shade)))
            if f.face == pressed || f.face == hovered {
                context.fill(path, with: .color(Theme.blue.opacity(f.face == pressed ? 0.45 : 0.28)))
            } else if f.facing > 0.995 {
                context.fill(path, with: .color(Theme.blue.opacity(0.16)))
            }
            context.stroke(path, with: .color(edge), style: StrokeStyle(lineWidth: 0.75, lineJoin: .round))

            // The label lies on the face (an affine map is exact for this orthographic cube).
            let opacity = Self.smoothstep(0.15, 0.45, f.facing)
            guard opacity > 0.01 else { continue }
            var ctx = context
            ctx.concatenate(f.labelTransform)
            ctx.opacity = opacity
            var text = ctx.resolve(Text(f.face.label).font(.system(size: 11, weight: .semibold)))
            text.shading = .color(ink)
            let measured = text.measure(in: CGSize(width: 400, height: 100))
            let fit = min(1, g.side * 0.84 / max(measured.width, 1), g.side * 0.6 / max(measured.height, 1))
            ctx.translateBy(x: g.side / 2, y: g.side / 2)
            ctx.scaleBy(x: fit, y: fit)
            ctx.draw(text, at: .zero, anchor: .center)
        }
    }

    private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    // MARK: - Home

    private var homeButton: some View {
        Button {
            onSelect(.home)
        } label: {
            Image(systemName: "house")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: Theme.minTouch, height: Theme.minTouch)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .viewCubeGlass(Circle(), interactive: true)
        .accessibilityLabel(Text("Fit All"))
        .help(Text("Fit All"))
    }
}

// MARK: - Geometry

/// The six sides. `u`/`v` are the label's right/down axes, chosen so each label reads upright
/// when you look at that side the way `EditorModel.setView` shows it.
enum CubeFace: CaseIterable {
    case top, bottom, front, back, right, left

    var normal: Vec3 {
        switch self {
        case .top: Vec3(0, 0, 1)
        case .bottom: Vec3(0, 0, -1)
        case .front: Vec3(0, -1, 0)
        case .back: Vec3(0, 1, 0)
        case .right: Vec3(1, 0, 0)
        case .left: Vec3(-1, 0, 0)
        }
    }

    var u: Vec3 {
        switch self {
        case .top, .bottom, .front: Vec3(1, 0, 0)
        case .back: Vec3(-1, 0, 0)
        case .right: Vec3(0, 1, 0)
        case .left: Vec3(0, -1, 0)
        }
    }

    var v: Vec3 {
        switch self {
        case .top: Vec3(0, -1, 0)
        case .bottom: Vec3(0, 1, 0)
        case .front, .back, .right, .left: Vec3(0, 0, -1)
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .top: "Top"
        case .bottom: "Bottom"
        case .front: "Front"
        case .back: "Back"
        case .right: "Right"
        case .left: "Left"
        }
    }

    var standardView: EditorModel.StandardView {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .front: .front
        case .back: .back
        case .right: .right
        case .left: .left
        }
    }
}

/// The cube projected for one camera orientation (orthographic, Z up, screen y down).
struct CubeGeometry {
    struct Face {
        let face: CubeFace
        let corners: [CGPoint]
        /// How straight the face looks at the viewer (0 = edge-on, 1 = head-on).
        let facing: Double
        /// Maps a `side` × `side` label square onto the face.
        let labelTransform: CGAffineTransform
    }

    let side: CGFloat
    /// Visible faces only. They never overlap in this projection, so their order doesn't matter.
    let faces: [Face]

    init(orientation: CameraOrientation, size: CGFloat) {
        let cam = orientation.camera
        let right = cam.right, up = cam.up, toViewer = cam.direction
        let side = size / 1.8  // a corner-on cube spans side × √3; keep it inside the square
        let mid = CGPoint(x: size / 2, y: size / 2)
        func screen(_ w: Vec3) -> CGVector { CGVector(dx: side * CGFloat(w.dot(right)), dy: -side * CGFloat(w.dot(up))) }
        func point(_ w: Vec3) -> CGPoint { let d = screen(w); return CGPoint(x: mid.x + d.dx, y: mid.y + d.dy) }

        var faces: [Face] = []
        for f in CubeFace.allCases {
            let facing = f.normal.dot(toViewer)
            guard facing > 0.02 else { continue }
            let c = f.normal * 0.5, hu = f.u * 0.5, hv = f.v * 0.5
            let corners = [c - hu - hv, c + hu - hv, c + hu + hv, c - hu + hv].map(point)
            let centre = point(c)
            // Per unit of label square: one side length along u and v, in screen points.
            let pu = screen(f.u), pv = screen(f.v)
            let a = pu.dx / side, b = pu.dy / side, cc = pv.dx / side, d = pv.dy / side
            let t = CGAffineTransform(a: a, b: b, c: cc, d: d,
                                      tx: centre.x - side / 2 * (a + cc),
                                      ty: centre.y - side / 2 * (b + d))
            faces.append(Face(face: f, corners: corners, facing: facing, labelTransform: t))
        }
        self.side = side
        self.faces = faces
    }

    /// The visible face under a point in the cube's square, if any.
    func face(at p: CGPoint) -> CubeFace? {
        faces.first { Self.contains($0.corners, p) }?.face
    }

    private static func contains(_ polygon: [CGPoint], _ p: CGPoint) -> Bool {
        var sign: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if abs(cross) < 1e-9 { continue }
            if sign == 0 { sign = cross > 0 ? 1 : -1 } else if (cross > 0 ? 1 : -1) != sign { return false }
        }
        return true
    }
}

// MARK: - Glass

private extension View {
    /// Liquid Glass on iOS 26 / macOS 26, the material panel look before that.
    @ViewBuilder
    func viewCubeGlass<S: SwiftUI.Shape>(_ shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(interactive ? Glass.regular.interactive() : Glass.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 3)
        }
    }
}
