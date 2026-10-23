import simd
import Combine
import SwiftUI

/// What is selected in the model.
enum Selection: Hashable {
    case face(body: String, face: Int)
    case edge(body: String, edge: Int)
    case body(String)
    /// A closed area of a finished sketch (index into that sketch's regions).
    case region(sketch: UUID, index: Int)
    /// A line of a finished sketch (used as revolve axis).
    case sketchLine(sketch: UUID, curve: Int)

    var bodyID: String? {
        switch self {
        case .face(let b, _), .edge(let b, _), .body(let b): b
        default: nil
        }
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let renderer: Renderer?
    weak var document: FormwerkDocument?
    var undoManager: UndoManager?

    @Published private(set) var design: Design
    @Published private(set) var output = BuildOutput()
    @Published private(set) var isBuilding = false
    @Published var selection: [Selection] = [] { didSet { refreshScene() } }
    @Published var hover: Selection? { didSet { if hover != oldValue { refreshScene() } } }
    @Published var sketch: SketchSession? { didSet { sketchChanged() } }
    @Published var tool: ToolSession? { didSet { toolChanged(oldValue) } }
    @Published var toast: Toast?
    /// Bumps on every camera move, so overlays (dimension labels) follow.
    @Published private(set) var cameraTick = 0
    @Published var section: SectionView? { didSet { refreshScene() } }
    @Published var printCheck: PrintCheckResult? { didSet { refreshScene() } }
    @Published var measurement: Measurement?
    @Published var showAllSketches = false { didSet { refreshScene() } }

    /// All geometry work happens on this worker's serial queue.
    let worker = BuildWorker()
    private var generation = 0
    private var cancellables: Set<AnyCancellable> = []
    var lastTap: (Selection, Date)?
    var dragState: DragState?
    /// After finishing a new sketch, its biggest region gets selected so "Extrude" is one tap away.
    var pendingRegionSelection: UUID?

    init(document: FormwerkDocument?) {
        self.document = document
        self.design = document?.design ?? Design()
        self.renderer = Renderer(device: MTLCreateSystemDefaultDevice())
        renderer?.onCameraChange = { [weak self] _ in
            Task { @MainActor in self?.cameraTick &+= 1 }
        }
        document?.$design
            .receive(on: DispatchQueue.main)
            .sink { [weak self] d in self?.documentChanged(d) }
            .store(in: &cancellables)
        rebuild(fit: true)
    }

    // MARK: - Document

    private func documentChanged(_ d: Design) {
        guard d != design else { return }
        design = d
        selection = []
        if let t = tool, let editing = t.editing, design.feature(editing) == nil { tool = nil }
        if let s = sketch, !s.isNew, design.feature(s.featureID) == nil { sketch = nil }
        rebuild()
    }

    /// Writes a new design into the document (undoable).
    func commit(_ new: Design, action: String) {
        guard new != design else { return }
        if let document {
            document.apply(new, actionName: action, undoManager: undoManager)
        } else {
            design = new
            rebuild()
        }
    }

    func undo() { undoManager?.undo() }
    func redo() { undoManager?.redo() }

    // MARK: - Building

    /// The design shown right now: the document plus the tool's preview feature.
    var effectiveDesign: Design {
        var d = design
        if let t = tool {
            if let editing = t.editing, let i = d.index(of: editing) {
                var f = t.feature
                f.id = editing
                d.features[i] = f
            } else {
                d.features.append(t.feature)
            }
        }
        return d
    }

    /// Features after this index are rolled back (while editing a sketch).
    var buildEnd: Int? {
        if let s = sketch, !s.isNew, let i = design.index(of: s.featureID) { return i }
        return nil
    }

    func rebuild(fit: Bool = false) {
        let d = effectiveDesign
        let end = buildEnd
        generation += 1
        let gen = generation
        isBuilding = true
        worker.build(d, end: end) { [weak self] result in
            guard let self, gen == self.generation else { return }
            self.output = result
            self.isBuilding = false
            self.refreshScene()
            if fit { self.fitView(animated: false) }
            self.updateToolStatus()
        }
    }

    // MARK: - Scene

    func refreshScene() {
        guard let renderer else { return }
        var scene = RenderScene()
        let hoverSel = hover
        for (i, body) in output.bodies.enumerated() {
            let style = design.style(body.id)
            if style.hidden { continue }
            var faceStates = [UInt8](repeating: 0, count: max(body.faces.count + 1, 1))
            var edgeStates: [Int32: UInt8] = [:]
            func mark(_ s: Selection, _ v: UInt8) {
                switch s {
                case .face(let b, let f) where b == body.id && f < faceStates.count: faceStates[f] = max(faceStates[f], v)
                case .edge(let b, let e) where b == body.id: edgeStates[Int32(e)] = max(edgeStates[Int32(e)] ?? 0, v)
                case .body(let b) where b == body.id:
                    for k in faceStates.indices { faceStates[k] = max(faceStates[k], v) }
                default: break
                }
            }
            if let h = hoverSel { mark(h, 1) }
            for s in selection { mark(s, 2) }
            if let check = printCheck, let marks = check.faceMarks[body.id] {
                for (face, state) in marks where face < faceStates.count && faceStates[face] == 0 { faceStates[face] = state }
            }
            let color = Palette.bodies[style.colorIndex % Palette.bodies.count]
            scene.bodies.append(RenderScene.Body(meshKey: body.meshKey, mesh: body.mesh, faceCount: body.faces.count,
                                                 color: color, alpha: 1, faceStates: faceStates, edgeStates: edgeStates))
            _ = i
        }
        renderer.purgeCache(keeping: Set(output.bodies.map(\.meshKey)))

        if let section {
            scene.clipPlane = SIMD4(section.normal.float3, Float(section.offset))
        }

        if let s = sketch {
            addSketchOverlay(s, to: &scene)
            scene.gridPlane = s.plane
        } else {
            addFinishedSketches(to: &scene)
        }
        addToolOverlay(to: &scene)
        if let m = measurement {
            scene.overlayLines.append(GPULineSegment(m.a.float3, m.b.float3, color: SIMD4(0.95, 0.3, 0.2, 1), width: 2))
            scene.overlayPoints.append(GPUPointSprite(m.a.float3, color: SIMD4(0.95, 0.3, 0.2, 1), size: 9))
            scene.overlayPoints.append(GPUPointSprite(m.b.float3, color: SIMD4(0.95, 0.3, 0.2, 1), size: 9))
        }
        if let check = printCheck, check.showBed, let printer = check.printer {
            addBed(printer, to: &scene)
        }
        renderer.scene = scene
    }

    /// Sketches nobody has extruded yet are shown, with their regions tappable.
    func visibleSketches() -> [UUID] {
        var used = Set<UUID>()
        for f in design.features {
            switch f.operation {
            case .extrude(let e): used.insert(e.sketch)
            case .revolve(let r): used.insert(r.sketch)
            default: break
            }
        }
        if let t = tool {
            switch t.feature.operation {
            case .extrude(let e): used.remove(e.sketch)
            case .revolve(let r): used.remove(r.sketch)
            default: break
            }
        }
        return design.features.compactMap { f in
            guard f.kind == .sketch, !f.suppressed, output.sketches[f.id] != nil else { return nil }
            return showAllSketches || !used.contains(f.id) ? f.id : nil
        }
    }

    private func addFinishedSketches(to scene: inout RenderScene) {
        for id in visibleSketches() {
            guard let built = output.sketches[id], let sk = design.feature(id)?.sketch?.sketch else { continue }
            for c in sk.curves {
                let pts = sk.polyline(c).map { built.plane.world($0).float3 }
                let selectedLine = selection.contains(.sketchLine(sketch: id, curve: c.id))
                let color: SIMD4<Float> = selectedLine ? scene.selectColor
                    : c.construction ? SIMD4(0.35, 0.45, 0.6, 0.6) : SIMD4(0.12, 0.3, 0.7, 1)
                for k in 0..<(pts.count - 1) {
                    scene.lines.append(GPULineSegment(pts[k], pts[k + 1], color: color, width: c.construction ? 1 : 1.6))
                }
            }
            for (ri, tris) in built.regionTriangles.enumerated() {
                let sel = selection.contains(.region(sketch: id, index: ri))
                let hov = hover == .region(sketch: id, index: ri)
                let color: SIMD4<Float> = sel ? SIMD4(0.15, 0.5, 1, 0.42) : hov ? SIMD4(0.2, 0.55, 1, 0.26) : SIMD4(0.25, 0.5, 0.95, 0.12)
                scene.fills.append((tris, color))
            }
        }
    }

    private func addBed(_ printer: Printer, to scene: inout RenderScene) {
        let x = printer.bed.x, y = printer.bed.y, z = printer.bed.z
        let ox = -x / 2, oy = -y / 2
        let c = SIMD4<Float>(0.95, 0.55, 0.1, 0.8)
        let corners = [Vec3(ox, oy, 0), Vec3(ox + x, oy, 0), Vec3(ox + x, oy + y, 0), Vec3(ox, oy + y, 0)]
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            scene.lines.append(GPULineSegment(a.float3, b.float3, color: c, width: 2))
            scene.lines.append(GPULineSegment((a + Vec3(0, 0, z)).float3, (b + Vec3(0, 0, z)).float3, color: c * SIMD4(1, 1, 1, 0.4), width: 1))
            scene.lines.append(GPULineSegment(a.float3, (a + Vec3(0, 0, z)).float3, color: c * SIMD4(1, 1, 1, 0.4), width: 1))
        }
    }

    // MARK: - View

    func fitView(animated: Bool = true) {
        guard let renderer else { return }
        var cam = renderer.camera
        var box = output.bounds
        if box.isEmpty { box = Box3(min: Vec3(-40, -40, 0), max: Vec3(40, 40, 20)) }
        cam.fit(box, aspect: Double(renderer.viewSize.width / max(renderer.viewSize.height, 1)))
        if animated { renderer.animate(to: cam) } else { renderer.camera = cam }
    }

    enum StandardView: String, CaseIterable, Identifiable {
        case iso, top, front, right, bottom, back, left
        var id: String { rawValue }
    }

    func setView(_ v: StandardView) {
        guard let renderer else { return }
        var cam = renderer.camera
        switch v {
        case .iso: cam.yaw = -.pi / 3; cam.pitch = 0.55
        case .top: cam.yaw = -.pi / 2; cam.pitch = Camera.maxPitch
        case .bottom: cam.yaw = -.pi / 2; cam.pitch = -Camera.maxPitch
        case .front: cam.yaw = -.pi / 2; cam.pitch = 0
        case .back: cam.yaw = .pi / 2; cam.pitch = 0
        case .right: cam.yaw = 0; cam.pitch = 0
        case .left: cam.yaw = .pi; cam.pitch = 0
        }
        var box = output.bounds
        if box.isEmpty { box = Box3(min: Vec3(-40, -40, 0), max: Vec3(40, 40, 20)) }
        cam.fit(box, aspect: Double(renderer.viewSize.width / max(renderer.viewSize.height, 1)))
        renderer.animate(to: cam)
    }

    func toggleOrthographic() {
        guard let renderer else { return }
        renderer.camera.orthographic.toggle()
    }

    // MARK: - Messages

    func show(_ text: String, kind: Toast.Kind = .info) {
        let t = Toast(text: text, kind: kind)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.toast?.id == t.id { self?.toast = nil }
        }
    }

    // MARK: - Selection helpers

    func body(_ id: String) -> BuiltBody? { output.body(id) }

    var selectedBodies: [String] {
        var ids: [String] = []
        for s in selection {
            if let b = s.bodyID, !ids.contains(b) { ids.append(b) }
        }
        return ids
    }

    var selectedFaces: [(BuiltBody, FaceInfo)] {
        selection.compactMap {
            if case .face(let b, let f) = $0, let body = body(b), let info = body.face(f) { return (body, info) }
            return nil
        }
    }

    var selectedEdges: [(BuiltBody, EdgeInfo)] {
        selection.compactMap {
            if case .edge(let b, let e) = $0, let body = body(b), let info = body.edge(e) { return (body, info) }
            return nil
        }
    }

    var selectedRegions: [(UUID, SketchRegion)] {
        selection.compactMap {
            if case .region(let s, let i) = $0, let built = output.sketches[s], i < built.regions.count { return (s, built.regions[i]) }
            return nil
        }
    }

    func toggle(_ s: Selection, extend: Bool) {
        if extend || isAdditive(s) {
            if let i = selection.firstIndex(of: s) { selection.remove(at: i) } else { selection.append(s) }
        } else {
            selection = selection == [s] ? [] : [s]
        }
    }

    /// Edges and regions add up by default: you usually fillet or extrude several at once.
    private func isAdditive(_ s: Selection) -> Bool {
        guard let first = selection.first else { return false }
        switch (first, s) {
        case (.edge, .edge), (.region, .region): return true
        case (.body, .body): return true
        default: return false
        }
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind { case info, error }
    let id = UUID()
    let text: String
    let kind: Kind
}

struct SectionView: Equatable {
    var normal: Vec3 = Vec3(0, 0, 1)
    var offset: Double = 0
    var axis: Int = 2
}

struct Measurement: Equatable {
    var a: Vec3
    var b: Vec3
    var distance: Double
    var text: String
}
