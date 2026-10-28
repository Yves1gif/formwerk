import simd
import SwiftUI

extension EditorModel {
    // MARK: - Opening tools

    func start(_ kind: ToolKind) {
        // Only starting a Pro tool is gated; existing Pro steps stay editable (editFeature).
        if let feature = kind.proFeature, !ProStore.shared.requirePro(feature, else: { showPaywall = true }) { return }
        if sketch != nil { finishSketch() }
        measurement = nil
        let d = design
        switch kind {
        case .extrude, .revolve:
            let regions = selectedRegions
            guard let sketchID = regions.first?.0 ?? lastSketchWithRegions() else {
                show(String(localized: "Draw a closed shape in a sketch first, then tap it."))
                return
            }
            let chosen = regions.filter { $0.0 == sketchID }.map(\.1)
            let seeds = chosen.isEmpty ? (output.sketches[sketchID]?.regions.first.map { [$0.samplePoint] } ?? []) : chosen.map(\.samplePoint)
            let target = sketchTargetBody(sketchID)
            if kind == .extrude {
                let e = ExtrudeFeature(sketch: sketchID, regionSeeds: seeds, distance: 10,
                                       mode: target == nil ? .newBody : .join, target: target)
                open(kind, Feature(name: d.nextName(for: .extrude), operation: .extrude(e)))
            } else {
                var axis: Int? = nil
                for s in selection { if case .sketchLine(let sid, let c) = s, sid == sketchID { axis = c } }
                let r = RevolveFeature(sketch: sketchID, regionSeeds: seeds, axisCurve: axis, mode: target == nil ? .newBody : .join, target: target)
                open(kind, Feature(name: d.nextName(for: .revolve), operation: .revolve(r)))
            }

        case .pushPull:
            guard let (body, face) = selectedFaces.first(where: { $0.1.isPlanar }) else {
                show(String(localized: "Tap a flat face first.")); return
            }
            open(kind, Feature(name: d.nextName(for: .pushPull),
                               operation: .pushPull(PushPullFeature(face: FaceRef(body: body.id, info: face), distance: 5))))

        case .fillet, .chamfer:
            var refs = selectedEdges.compactMap { $0.0.edgeRef($0.1.index) }
            if refs.isEmpty, let (body, face) = selectedFaces.first {
                // A face selected: round all of its edges.
                refs = body.edgeFaces.filter { $0.value.contains(face.index) }.keys.sorted().compactMap { body.edgeRef($0) }
            }
            guard !refs.isEmpty else { show(String(localized: "Tap one or more edges first.")); return }
            let f = EdgeFeature(edges: refs, value: kind == .fillet ? 2 : 1)
            open(kind, Feature(name: d.nextName(for: kind == .fillet ? .fillet : .chamfer),
                               operation: kind == .fillet ? .fillet(f) : .chamfer(f)))

        case .shell:
            guard let bodyID = selectedBodies.first ?? (output.bodies.count == 1 ? output.bodies[0].id : nil) else {
                show(String(localized: "Tap the body to hollow out (or a face to leave open).")); return
            }
            let open = selectedFaces.filter { $0.0.id == bodyID }.map { FaceRef(body: bodyID, info: $0.1) }
            self.open(kind, Feature(name: d.nextName(for: .shell),
                                    operation: .shell(ShellFeature(body: bodyID, openFaces: open, thickness: 1.2))))

        case .hole:
            guard let (body, face) = selectedFaces.first(where: { $0.1.isPlanar }) else {
                show(String(localized: "Tap the flat face where the hole goes.")); return
            }
            let plane = Plane.onFace(normal: face.normal, through: face.centroid)
            let h = HoleFeature(face: FaceRef(body: body.id, info: face), positions: [plane.local(face.centroid)])
            open(kind, Feature(name: d.nextName(for: .hole), operation: .hole(h)))

        case .move:
            let bodies = selectedBodies.isEmpty ? output.bodies.map(\.id).prefix(1).map { $0 } : selectedBodies
            guard !bodies.isEmpty else { show(String(localized: "There is nothing to move yet.")); return }
            var box = Box3.empty
            for b in bodies { if let bb = body(b) { box.add(bb.props.bounds) } }
            let t = TransformFeature(bodies: bodies, pivot: box.center)
            open(kind, Feature(name: d.nextName(for: .transform), operation: .transform(t)))

        case .mirror:
            let bodies = selectedBodies.isEmpty ? output.bodies.map(\.id).prefix(1).map { $0 } : selectedBodies
            guard !bodies.isEmpty else { show(String(localized: "There is nothing to mirror yet.")); return }
            var plane = PlaneRef.origin(.yz, offset: 0)
            if let (b, f) = selectedFaces.first(where: { $0.1.isPlanar }) { plane = .face(FaceRef(body: b.id, info: f)) }
            open(kind, Feature(name: d.nextName(for: .mirror), operation: .mirror(MirrorFeature(bodies: bodies, plane: plane))))

        case .pattern:
            let bodies = selectedBodies.isEmpty ? output.bodies.map(\.id).prefix(1).map { $0 } : selectedBodies
            guard let first = bodies.first, let b = body(first) else { show(String(localized: "There is nothing to copy yet.")); return }
            let p = PatternFeature(bodies: bodies, kind: .linear, count: 3, spacing: (b.props.bounds.size.x + 5).rounded(),
                                   axisOrigin: Vec3(0, 0, 0))
            open(kind, Feature(name: d.nextName(for: .pattern), operation: .pattern(p)))

        case .text:
            var plane = PlaneRef.origin(.xy, offset: 0)
            var pos = Vec2(0, 0)
            var target: String? = nil
            if let (b, f) = selectedFaces.first(where: { $0.1.isPlanar }) {
                plane = .face(FaceRef(body: b.id, info: f))
                pos = Plane.onFace(normal: f.normal, through: f.centroid).local(f.centroid)
                target = b.id
            }
            let t = TextFeature(plane: plane, position: pos, text: "Formwerk", size: 8, depth: 1,
                                mode: target == nil ? .newBody : .join, target: target)
            open(kind, Feature(name: d.nextName(for: .text), operation: .text(t)))

        case .combine:
            let bodies = selectedBodies
            guard bodies.count >= 2 else { show(String(localized: "Select two or more bodies (double-tap a body).")); return }
            let b = BooleanFeature(target: bodies[0], tools: Array(bodies.dropFirst()), op: .union)
            open(kind, Feature(name: d.nextName(for: .boolean), operation: .boolean(b)))

        case .split:
            guard let bodyID = selectedBodies.first ?? (output.bodies.count == 1 ? output.bodies[0].id : nil),
                  let b = body(bodyID) else { show(String(localized: "Select the body to split.")); return }
            var plane = PlaneRef.origin(.xy, offset: b.props.bounds.center.z.rounded())
            if let (fb, f) = selectedFaces.first(where: { $0.1.isPlanar && $0.0.id != bodyID }) { plane = .face(FaceRef(body: fb.id, info: f)) }
            open(kind, Feature(name: d.nextName(for: .split), operation: .split(SplitFeature(body: bodyID, plane: plane))))

        case .box, .cylinder:
            let p = PrimitiveFeature(kind: kind == .box ? .box : .cylinder,
                                     origin: kind == .box ? Vec3(-10, -10, 0) : .zero, size: Vec3(20, 20, 20))
            open(kind, Feature(name: d.nextName(for: .primitive), operation: .primitive(p)))

        case .measure:
            selection = []
            tool = ToolSession(kind: .measure, feature: Feature(name: "", operation: .deleteBody(DeleteBodyFeature(bodies: []))))
        }
    }

    private func open(_ kind: ToolKind, _ feature: Feature) {
        selection = []
        tool = ToolSession(kind: kind, feature: feature)
    }

    /// Opens a feature from the timeline for editing.
    func editFeature(_ id: UUID) {
        guard let f = design.feature(id) else { return }
        if f.kind == .sketch { editSketch(id); return }
        if sketch != nil { finishSketch() }
        let kind: ToolKind? = switch f.operation {
        case .extrude: .extrude
        case .revolve: .revolve
        case .pushPull: .pushPull
        case .fillet: .fillet
        case .chamfer: .chamfer
        case .shell: .shell
        case .hole: .hole
        case .transform: .move
        case .mirror: .mirror
        case .pattern: .pattern
        case .text: .text
        case .boolean: .combine
        case .split: .split
        case .primitive(let p): p.kind == .box ? .box : .cylinder
        default: nil
        }
        guard let kind else { return }
        selection = []
        tool = ToolSession(kind: kind, feature: f, editing: id, autoMode: false)
    }

    private func lastSketchWithRegions() -> UUID? {
        visibleSketches().last { !(output.sketches[$0]?.regions.isEmpty ?? true) }
    }

    /// The body a sketch sits on (extrusions from it join that body by default).
    private func sketchTargetBody(_ sketchID: UUID) -> String? {
        if case .sketch(let s)? = design.feature(sketchID)?.operation, case .face(let ref) = s.plane { return ref.body }
        return nil
    }

    // MARK: - Changing and applying

    func updateTool(_ change: (inout ToolSession) -> Void) {
        guard var t = tool else { return }
        change(&t)
        tool = t
    }

    func toolChanged(_ old: ToolSession?) {
        let featureChanged = old?.feature != tool?.feature || (old == nil) != (tool == nil)
        if featureChanged && (tool?.kind != .measure && old?.kind != .measure || tool == nil) {
            rebuild()
        } else {
            refreshScene()
        }
    }

    func updateToolStatus() {
        if let t = tool, t.kind != .measure {
            let s = output.statuses[t.featureID] ?? .ok
            if s != t.status { tool?.status = s }
        }
        if let id = pendingRegionSelection {
            pendingRegionSelection = nil
            if let built = output.sketches[id], !built.regions.isEmpty {
                selection = [.region(sketch: id, index: 0)]
            }
        }
    }

    /// Adds the tool's feature to the design (or updates the edited one).
    func applyTool() {
        guard let t = tool else { return }
        if t.kind == .measure { tool = nil; measurement = nil; return }
        if case .error(let msg) = t.status {
            show(msg, kind: .error)
            return
        }
        var d = design
        if let editing = t.editing, let i = d.index(of: editing) {
            var f = t.feature
            f.id = editing
            d.features[i] = f
        } else {
            d.features.append(t.feature)
        }
        tool = nil
        commit(d, action: localizedName(t.kind))
    }

    func cancelTool() {
        tool = nil
        measurement = nil
    }

    func localizedName(_ k: ToolKind) -> String {
        switch k {
        case .extrude: String(localized: "Extrude")
        case .revolve: String(localized: "Revolve")
        case .pushPull: String(localized: "Push/Pull")
        case .fillet: String(localized: "Fillet")
        case .chamfer: String(localized: "Chamfer")
        case .shell: String(localized: "Hollow")
        case .hole: String(localized: "Hole")
        case .move: String(localized: "Move")
        case .mirror: String(localized: "Mirror")
        case .pattern: String(localized: "Pattern")
        case .text: String(localized: "Text")
        case .combine: String(localized: "Combine")
        case .split: String(localized: "Split")
        case .box: String(localized: "Box")
        case .cylinder: String(localized: "Cylinder")
        case .measure: String(localized: "Measure")
        }
    }

    // MARK: - Timeline and bodies

    func deleteFeature(_ id: UUID) {
        var d = design
        d.features.removeAll { $0.id == id }
        commit(d, action: String(localized: "Delete step"))
    }

    func toggleSuppressed(_ id: UUID) {
        var d = design
        d.update(id) { $0.suppressed.toggle() }
        commit(d, action: String(localized: "Turn step on/off"))
    }

    func deleteSelectedBodies() {
        let ids = selectedBodies
        guard !ids.isEmpty else { return }
        var d = design
        d.features.append(Feature(name: d.nextName(for: .deleteBody), operation: .deleteBody(DeleteBodyFeature(bodies: ids))))
        selection = []
        commit(d, action: String(localized: "Delete body"))
    }

    func setColor(_ index: Int, for bodies: [String]) {
        var d = design
        for b in bodies { var s = d.style(b); s.colorIndex = index; d.bodyStyles[b] = s }
        commit(d, action: String(localized: "Colour"))
    }

    func toggleHidden(_ body: String) {
        var d = design
        var s = d.style(body); s.hidden.toggle(); d.bodyStyles[body] = s
        if s.hidden { selection.removeAll { $0.bodyID == body } }
        commit(d, action: String(localized: "Show/hide body"))
    }

    func setUnit(_ u: LengthUnit) {
        var d = design
        d.unit = u
        commit(d, action: String(localized: "Units"))
    }

    // MARK: - Import

    func importSTEP(_ url: URL) {
        guard ProStore.shared.requirePro(.stepImport, else: { showPaywall = true }) else { return }
        let access = url.startAccessingSecurityScopedResource()
        worker.run({ () -> Result<Data, Error> in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do { return .success(try Kernel.readSTEP(url).brep()) } catch { return .failure(error) }
        }) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let data):
                var d = self.design
                let key = UUID().uuidString
                d.importedShapes[key] = data
                d.features.append(Feature(name: d.nextName(for: .importBody),
                                          operation: .importBody(ImportFeature(shapeKey: key, fileName: url.lastPathComponent))))
                self.commit(d, action: String(localized: "Import"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.fitView() }
            case .failure(let e):
                self.show(e.localizedDescription, kind: .error)
            }
        }
    }

    // MARK: - Handles

    var handles: [ToolHandle] {
        guard let t = tool, sketch == nil else { return [] }
        switch t.feature.operation {
        case .extrude(let e):
            guard let built = output.sketches[e.sketch] else { return [] }
            let regions = e.regionSeeds.compactMap { seed in built.regions.first { $0.contains(seed) } }
            guard let r = regions.first else { return [] }
            let base = built.plane.world(r.samplePoint)
            return [.distance(origin: base, direction: built.plane.normal)]
        case .pushPull(let p):
            return [.distance(origin: p.face.centroid, direction: p.face.normal)]
        case .transform(let m):
            return [0, 1, 2].map { .moveAxis($0, origin: m.pivot + m.translation) }
        default:
            return []
        }
    }

    /// The value a handle changes.
    func handleValue(_ h: ToolHandle) -> Double {
        guard let t = tool else { return 0 }
        switch (h, t.feature.operation) {
        case (.distance, .extrude(let e)): return e.distance
        case (.distance, .pushPull(let p)): return p.distance
        case (.moveAxis(let i, _), .transform(let m)): return m.translation[i]
        default: return 0
        }
    }

    func setHandleValue(_ h: ToolHandle, _ v: Double) {
        let value = (v / gridLikeStep).rounded() * gridLikeStep
        updateTool { t in
            switch (h, t.feature.operation) {
            case (.distance, .extrude(var e)):
                e.distance = value == 0 ? gridLikeStep : value
                if t.autoMode, e.target != nil { e.mode = e.distance >= 0 ? .join : .cut }
                t.feature.operation = .extrude(e)
            case (.distance, .pushPull(var p)):
                p.distance = value == 0 ? gridLikeStep : value
                t.feature.operation = .pushPull(p)
            case (.moveAxis(let i, _), .transform(var m)):
                m.translation[i] = value
                t.feature.operation = .transform(m)
            default: break
            }
        }
    }

    /// Dragged values snap to a round step that suits the zoom level.
    private var gridLikeStep: Double {
        guard let renderer else { return 1 }
        let raw = renderer.camera.unitsPerPoint(size: renderer.viewSize) * 6
        let e = pow(10, floor(log10(max(raw, 1e-3))))
        for m in [1.0, 2.0, 5.0, 10.0] where e * m >= raw { return e * m }
        return e * 10
    }

    /// Where the arrow tip of a handle is drawn.
    func handleTip(_ h: ToolHandle) -> Vec3 {
        let len = handleLength
        switch h {
        case .distance(let o, let d):
            let v = handleValue(h)
            return o + d.normalized * v + d.normalized * (v >= 0 ? len : -len)
        case .moveAxis(_, let o): return o + h.direction * len
        }
    }

    private var handleLength: Double {
        guard let renderer else { return 10 }
        return renderer.camera.unitsPerPoint(size: renderer.viewSize) * 60
    }

    func addToolOverlay(to scene: inout RenderScene) {
        for h in handles {
            let start: Vec3
            switch h {
            case .distance(let o, let d): start = o + d * handleValue(h)
            case .moveAxis(_, let o): start = o
            }
            let tip = handleTip(h)
            scene.overlayLines.append(GPULineSegment(start.float3, tip.float3, color: h.color, width: 3))
            scene.overlayPoints.append(GPUPointSprite(tip.float3, color: h.color, size: 18))
            if case .distance(let o, _) = h {
                scene.overlayLines.append(GPULineSegment(o.float3, start.float3, color: h.color * SIMD4(1, 1, 1, 0.5), width: 1.5))
            }
        }
        // Hole positions
        if let t = tool, case .hole(let hole) = t.feature.operation, let (plane, _) = facePlane(hole.face) {
            for p in hole.positions {
                scene.overlayPoints.append(GPUPointSprite(plane.world(p).float3, color: SIMD4(1, 0.45, 0.1, 1), size: 10))
            }
        }
        // Edges/faces the tool works on
        if let t = tool {
            switch t.feature.operation {
            case .fillet(let e), .chamfer(let e):
                for ref in e.edges {
                    scene.overlayPoints.append(GPUPointSprite(ref.midpoint.float3, color: SIMD4(1, 0.45, 0.1, 1), size: 9))
                }
            case .shell(let s):
                for ref in s.openFaces {
                    scene.overlayPoints.append(GPUPointSprite(ref.centroid.float3, color: SIMD4(1, 0.45, 0.1, 1), size: 9))
                }
            default: break
            }
        }
    }

    func facePlane(_ ref: FaceRef) -> (Plane, BuiltBody)? {
        guard let b = body(ref.body) else { return nil }
        guard let best = b.faces.filter(\.isPlanar).min(by: {
            ($0.centroid - ref.centroid).length + (1 - $0.normal.dot(ref.normal)) * 100 <
                ($1.centroid - ref.centroid).length + (1 - $1.normal.dot(ref.normal)) * 100
        }) else { return nil }
        return (Plane.onFace(normal: best.normal, through: best.centroid), b)
    }

    // MARK: - Measuring

    func measure(_ a: Selection, _ b: Selection) {
        func part(_ s: Selection) -> (Shape, Int, Int)? {
            switch s {
            case .face(let id, let f): return body(id).map { ($0.shape, 1, f) }
            case .edge(let id, let e): return body(id).map { ($0.shape, 2, e) }
            case .body(let id): return body(id).map { ($0.shape, 0, 0) }
            default: return nil
            }
        }
        guard let pa = part(a), let pb = part(b) else { return }
        let unit = design.unit
        worker.run({ Kernel.distance(pa.0, kind: pa.1, index: pa.2, pb.0, kind: pb.1, index: pb.2) }) { [weak self] r in
            guard let self, let r else { return }
            self.measurement = Measurement(a: r.a, b: r.b, distance: r.distance, text: Format.length(r.distance, unit: unit))
            self.refreshScene()
        }
    }
}

/// Closest point on an axis line to a view ray: the parameter along the axis.
func axisParameter(origin o: Vec3, direction d: Vec3, rayOrigin r: Vec3, rayDirection v: Vec3) -> Double? {
    let dn = d.normalized
    let w0 = o - r
    let a = dn.dot(dn), b = dn.dot(v), c = v.dot(v), dd = dn.dot(w0), e = v.dot(w0)
    let denom = a * c - b * b
    if abs(denom) < 1e-9 { return nil }
    return (b * e - c * dd) / denom
}
