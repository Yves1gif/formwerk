import simd
import SwiftUI

extension EditorModel {
    // MARK: - Starting and finishing

    /// Starts a new sketch on the selected flat face, or on the ground plane.
    func startSketch() {
        tool = nil
        var ref = PlaneRef.origin(.xy, offset: 0)
        var plane = Plane.xy
        if let (body, face) = selectedFaces.first, face.isPlanar {
            ref = .face(FaceRef(body: body.id, info: face))
            plane = Plane.onFace(normal: face.normal, through: face.centroid)
        }
        var s = SketchSession(featureID: UUID(), isNew: true, planeRef: ref, plane: plane, sketch: Sketch())
        s.modelSnaps = modelSnapPoints(on: plane)
        s.cameraBefore = renderer?.camera
        selection = []
        sketch = s
        lookAt(plane)
    }

    /// Opens an existing sketch for editing (later steps are rolled back meanwhile).
    func editSketch(_ id: UUID) {
        guard let f = design.feature(id), let sf = f.sketch else { return }
        tool = nil
        let plane = output.sketches[id]?.plane ?? planeFor(sf.plane).offset(by: sf.planeOffset ?? 0)
        var s = SketchSession(featureID: id, isNew: false, planeRef: sf.plane, plane: plane, sketch: sf.sketch)
        s.faceOffset = sf.planeOffset ?? 0
        s.tool = .select
        s.solve = SketchSolver.solve(sf.sketch)
        s.cameraBefore = renderer?.camera
        selection = []
        sketch = s
        s.modelSnaps = modelSnapPoints(on: plane)
        sketch?.modelSnaps = s.modelSnaps
        lookAt(plane)
        rebuild()
    }

    private func planeFor(_ ref: PlaneRef) -> Plane {
        switch ref {
        case .origin(let p, let o): return p.plane.offset(by: o)
        case .face(let f): return Plane.onFace(normal: f.normal, through: f.centroid)
        }
    }

    /// Switches an empty new sketch to another origin plane.
    func setSketchPlane(_ p: OriginPlane) {
        guard var s = sketch, s.isNew, s.isEmpty else { return }
        s.planeRef = .origin(p, offset: 0)
        s.faceOffset = 0
        s.plane = p.plane
        s.modelSnaps = modelSnapPoints(on: s.plane)
        sketch = s
        lookAt(s.plane)
    }

    /// How far the sketch plane sits from its origin plane or face (for the inspector's "Offset" field).
    var sketchPlaneOffset: Double {
        guard let s = sketch else { return 0 }
        if case .origin(_, let o) = s.planeRef { return o }
        return s.faceOffset
    }

    /// Moves the sketch plane along its normal: "sketch 5 mm above the ground / this face".
    /// Works for new and existing sketches; the drawing keeps its 2D coordinates.
    func setSketchPlaneOffset(_ d: Double) {
        guard var s = sketch, d.isFinite else { return }
        let old = sketchPlaneOffset
        guard abs(d - old) > 1e-9 else { return }
        switch s.planeRef {
        case .origin(let p, _): s.planeRef = .origin(p, offset: d)
        case .face: s.faceOffset = d
        }
        s.plane = s.plane.offset(by: d - old)
        s.modelSnaps = modelSnapPoints(on: s.plane)
        sketch = s
    }

    private func lookAt(_ plane: Plane) {
        guard let renderer else { return }
        var cam = renderer.camera
        cam.face(plane)
        if output.bodies.isEmpty { cam.target = plane.origin }
        renderer.animate(to: cam)
    }

    func finishSketch() {
        guard let s = sketch else { return }
        let finalSketch = s.sketch
        var d = design
        let regionsExist = !SketchRegions.find(in: finalSketch).isEmpty
        if s.isNew {
            if finalSketch.curves.isEmpty { cancelSketch(); return }
            d.features.append(Feature(id: s.featureID, name: d.nextName(for: .sketch),
                                      operation: .sketch(SketchFeature(plane: s.planeRef, sketch: finalSketch,
                                                                       planeOffset: s.faceOffset != 0 ? s.faceOffset : nil))))
        } else {
            d.update(s.featureID) { f in
                if case .sketch(var sf) = f.operation {
                    sf.sketch = finalSketch
                    sf.plane = s.planeRef
                    sf.planeOffset = s.faceOffset != 0 ? s.faceOffset : nil
                    f.operation = .sketch(sf)
                }
            }
        }
        let id = s.featureID
        sketch = nil
        commit(d, action: String(localized: "Sketch"))
        if regionsExist && s.isNew { pendingRegionSelection = id }
        rebuild()
    }

    func cancelSketch() {
        sketch = nil
        rebuild()
    }

    /// Called whenever the sketch session changes.
    func sketchChanged() {
        guard let s = sketch else { refreshScene(); return }
        let regions = SketchRegions.find(in: s.sketch)
        if regions != s.regions {
            // A user edit that closed a new area: a small "done" buzz.
            if s.regionHapticPending && regions.count > s.regions.count { Haptics.success() }
            var n = s
            n.regions = regions
            n.regionHapticPending = false
            sketch = n
            let plane = s.plane
            worker.regionTriangles(regions, plane: plane) { [weak self] fills in
                guard let self, self.sketch?.regions == regions else { return }
                self.sketch?.regionFills = fills
            }
            return  // the assignment above triggers another refresh
        }
        if s.regionHapticPending {
            // The edit didn't change the areas; forget it so a later drag or undo doesn't buzz.
            sketch?.regionHapticPending = false
            return  // the assignment above triggers another refresh
        }
        refreshScene()
    }

    // MARK: - Editing helpers

    /// Applies a change to the working sketch, solves it and records undo.
    func changeSketch(_ change: (inout Sketch) -> Void, solve: Bool = true) {
        guard var s = sketch else { return }
        let before = s.sketch
        change(&s.sketch)
        if solve {
            let r = SketchSolver.solve(s.sketch)
            if !r.converged && (s.solve?.converged ?? true) && !r.conflicting.isEmpty {
                // Keep the result but tell the user which constraints fight each other.
                show(String(localized: "These constraints contradict each other. Remove one of the red ones."), kind: .error)
            }
            s.sketch = r.sketch
            s.solve = r
        }
        s.undoStack.append(before)
        if s.undoStack.count > 200 { s.undoStack.removeFirst() }
        s.redoStack = []
        s.offsetEdit = nil
        s.trimPreview = []
        s.regionHapticPending = true
        sketch = s
    }

    func sketchUndo() {
        guard var s = sketch, let prev = s.undoStack.popLast() else { return }
        s.redoStack.append(s.sketch)
        s.sketch = prev
        s.solve = SketchSolver.solve(prev)
        s.clicks = []; s.chainStart = nil; s.selected = []
        s.offsetEdit = nil; s.trimPreview = []; s.mirrorSource = []
        sketch = s
    }

    func sketchRedo() {
        guard var s = sketch, let next = s.redoStack.popLast() else { return }
        s.undoStack.append(s.sketch)
        s.sketch = next
        s.solve = SketchSolver.solve(next)
        s.offsetEdit = nil; s.trimPreview = []; s.mirrorSource = []
        sketch = s
    }

    func setSketchTool(_ t: SketchTool) {
        guard var s = sketch else { return }
        if t != s.tool { s.previousTool = s.tool }
        if t != .select { s.lastDrawTool = t }
        s.tool = t
        s.clicks = []
        s.chainStart = nil
        s.trimPreview = []
        s.cursor = nil
        if t != .mirror { s.mirrorSource = [] }
        if t != .select && t != .dimension && t != .mirror { s.selected = [] }
        sketch = s
    }

    /// Ends the current drawing action (Escape / tap the tool again).
    func cancelSketchAction() {
        guard var s = sketch else { return }
        if !s.clicks.isEmpty || s.chainStart != nil {
            s.clicks = []; s.chainStart = nil
        } else if !s.selected.isEmpty {
            s.selected = []
            s.mirrorSource = []
        } else if s.tool != .select {
            s.previousTool = s.tool
            s.tool = .select
        }
        sketch = s
    }

    func deleteSketchSelection() {
        guard let s = sketch, !s.selected.isEmpty else { return }
        var pts = Set<Int>(), curves = Set<Int>(), cons = Set<Int>()
        for item in s.selected {
            switch item {
            case .point(let p): pts.insert(p)
            case .curve(let c): curves.insert(c)
            case .constraint(let k): cons.insert(k)
            }
        }
        changeSketch { $0.delete(points: pts, curves: curves, constraints: cons) }
        sketch?.selected = []
    }

    func toggleConstruction() {
        guard let s = sketch else { return }
        let ids = s.selected.compactMap { if case .curve(let c) = $0 { return c } else { return nil } }
        guard !ids.isEmpty else {
            show(String(localized: "Select lines or circles first."))
            return
        }
        changeSketch({ sk in
            for i in sk.curves.indices where ids.contains(sk.curves[i].id) { sk.curves[i].construction.toggle() }
        }, solve: false)
    }

    // MARK: - Coordinates and snapping

    func planePoint(_ p: CGPoint) -> Vec2? {
        guard let renderer, let s = sketch else { return nil }
        let (o, d) = renderer.camera.ray(at: p, size: renderer.viewSize)
        guard let t = s.plane.intersect(rayOrigin: o, rayDir: d) ?? s.plane.intersect(rayOrigin: o, rayDir: -d).map({ -$0 }) else { return nil }
        return s.plane.local(o + d * t)
    }

    /// Sketch units per screen point.
    var sketchTolerance: Double {
        guard let renderer else { return 1 }
        return renderer.camera.unitsPerPoint(size: renderer.viewSize)
    }

    func screenPoint(_ local: Vec2) -> CGPoint? {
        guard let renderer, let s = sketch else { return nil }
        return renderer.camera.project(s.plane.world(local), size: renderer.viewSize)
    }

    /// Finds what a screen point snaps to: an existing point, the origin, a model corner, a curve, the grid.
    func snap(_ screen: CGPoint, excluding: Set<Int> = []) -> SketchSnap? {
        guard let s = sketch, let p = planePoint(screen) else { return nil }
        let tol = sketchTolerance * 14
        var best: (SketchSnap, Double)? = nil
        func consider(_ snap: SketchSnap, _ d: Double) { if d < tol && (best == nil || d < best!.1) { best = (snap, d) } }
        for pt in s.sketch.points where !excluding.contains(pt.id) {
            let d = (pt.position - p).length
            consider(SketchSnap(position: pt.position, pointID: pt.id, kind: pt.id == Sketch.originID ? .origin : .point), d)
        }
        if best == nil {
            for m in s.modelSnaps { consider(SketchSnap(position: m, pointID: nil, kind: .model), (m - p).length) }
            // Midpoints of lines
            for c in s.sketch.curves where c.kind == .line {
                let (a, b) = s.sketch.lineEnds(c)
                let mid = (a + b) / 2
                consider(SketchSnap(position: mid, pointID: nil, kind: .midpoint(c.id)), (mid - p).length * 1.3)
            }
        }
        if let b = best { return b.0 }
        // On a curve: project onto it.
        for c in s.sketch.curves where s.sketch.distance(from: p, to: c) < tol * 0.6 {
            if c.pointIDs.contains(where: excluding.contains) { continue }
            return SketchSnap(position: project(p, onto: c, in: s.sketch), pointID: nil, kind: .curve(c.id))
        }
        let g = gridStep
        return SketchSnap(position: Vec2((p.x / g).rounded() * g, (p.y / g).rounded() * g), pointID: nil, kind: .grid)
    }

    /// A round grid step that is a few points wide on screen: 0.1, 0.5, 1, 5, 10 …
    var gridStep: Double {
        let raw = sketchTolerance * 10
        let e = pow(10, floor(log10(max(raw, 1e-4))))
        for m in [1.0, 2.0, 5.0, 10.0] where e * m >= raw { return e * m }
        return e * 10
    }

    private func project(_ p: Vec2, onto c: SketchCurve, in sk: Sketch) -> Vec2 {
        switch c.kind {
        case .line:
            let (a, b) = sk.lineEnds(c)
            let d = b - a
            let t = max(0, min(1, (p - a).dot(d) / max(d.dot(d), 1e-12)))
            return a + d * t
        case .circle, .arc:
            let center = sk.position(c.a)
            return center + (p - center).normalized * sk.radius(of: c)
        }
    }

    private func modelSnapPoints(on plane: Plane) -> [Vec2] {
        var pts: [Vec2] = []
        for body in output.bodies {
            for e in body.edges {
                for v in [e.start, e.end] where abs(plane.signedDistance(v)) < 1e-3 { pts.append(plane.local(v)) }
                if e.kind == .circle && abs(plane.signedDistance(e.center)) < 1e-3 { pts.append(plane.local(e.center)) }
            }
        }
        var unique: [Vec2] = []
        for p in pts where !unique.contains(where: { ($0 - p).length < 1e-6 }) { unique.append(p) }
        return unique
    }

    /// Turns a snap into a point of the sketch (reusing existing points so shapes connect).
    private func pointID(for snap: SketchSnap, in sk: inout Sketch) -> Int {
        if let id = snap.pointID { return id }
        let id = sk.addPoint(snap.position)
        switch snap.kind {
        case .model:
            if let i = sk.points.firstIndex(where: { $0.id == id }) { sk.points[i].fixed = true }
        case .curve(let c):
            sk.addConstraint(.pointOnCurve, [id, c])
        case .midpoint(let c):
            sk.addConstraint(.midpoint, [id, c])
        default: break
        }
        return id
    }

    // MARK: - Input

    func sketchTap(_ screen: CGPoint, extend: Bool, touch: ViewportTouch = .pointer) {
        guard var s = sketch else { return }
        if s.editingDimension != nil { sketch?.editingDimension = nil; return }
        // When only the Pencil draws, a finger never places points; it may still select.
        if touch == .finger && PencilDrawing.isActive && s.tool != .select { return }
        switch s.tool {
        case .select:
            if let item = hitSketchItem(screen) {
                if extend || !s.selected.isEmpty && !s.selected.contains(item) && isMultiSelectFriendly(item, s.selected) {
                    if s.selected.contains(item) { s.selected.remove(item) } else { s.selected.insert(item) }
                } else {
                    s.selected = s.selected == [item] ? [] : [item]
                }
            } else {
                s.selected = []
            }
            sketch = s
        case .dimension:
            dimensionTap(screen)
        case .trim:
            trimTap(screen)
        case .fillet:
            cornerTap(screen)
        case .mirror:
            mirrorTap(screen)
        default:
            guard let snap = snap(screen) else { return }
            drawClick(snap)
        }
    }

    private func isMultiSelectFriendly(_ item: SketchItem, _ current: Set<SketchItem>) -> Bool {
        // Building up a constraint selection (two lines, point + line …) works without a modifier key.
        if case .constraint = item { return false }
        return current.count < 3 && !current.contains { if case .constraint = $0 { return true } else { return false } }
    }

    func sketchHover(_ screen: CGPoint?) {
        guard var s = sketch else { return }
        if s.tool == .trim {
            // Show the piece a tap would remove.
            var piece: [Vec2] = []
            if let screen, let p = planePoint(screen), let id = nearestCurve(screen),
               let plan = SketchEdit.trimPlan(s.sketch, curve: id, near: p) {
                piece = plan.removedPiece
            }
            if piece != s.trimPreview || s.cursor != nil { s.trimPreview = piece; s.cursor = nil; sketch = s }
            return
        }
        if let screen, s.tool != .select && s.tool != .dimension && !s.tool.isModifyTool {
            s.cursor = inferredCursor(snap(screen), in: s)
        } else {
            s.cursor = nil
        }
        if s.cursor != sketch?.cursor {
            s.lastSnapTarget = snapFeedback(s.cursor, previous: s.lastSnapTarget, screen: screen)
            sketch = s
        }
    }

    /// While drawing a line, a nearly horizontal or vertical direction shows as exactly that
    /// (the click applies the same rule and adds the constraint).
    private func inferredCursor(_ snap: SketchSnap?, in s: SketchSession) -> SketchSnap? {
        guard var c = snap, s.tool == .line, let start = s.chainStart, c.pointID == nil else { return snap }
        let startPos = s.sketch.position(start)
        let d = c.position - startPos
        let ang = abs(atan2(d.y, d.x))
        if ang < 0.05 || abs(ang - .pi) < 0.05 { c.position.y = startPos.y }
        else if abs(ang - .pi / 2) < 0.05 { c.position.x = startPos.x }
        return c
    }

    /// A name for what the cursor snapped to; plays a haptic tick when it changes to a new target.
    private func snapFeedback(_ cursor: SketchSnap?, previous: String?, screen: CGPoint?) -> String? {
        var target: String? = nil
        if let c = cursor {
            switch c.kind {
            case .point, .origin: target = "p\(c.pointID ?? -1)"
            case .model: target = "m\(Int((c.position.x * 1000).rounded())),\(Int((c.position.y * 1000).rounded()))"
            case .curve(let id): target = "c\(id)"
            case .midpoint(let id): target = "mid\(id)"
            case .grid, .free:
                // Horizontal / vertical inference while drawing a line.
                if let s = sketch, s.tool == .line, let start = s.chainStart {
                    let d = c.position - s.sketch.position(start)
                    if d.length > 1e-9 {
                        if abs(d.y) < 1e-9 { target = "h" } else if abs(d.x) < 1e-9 { target = "v" }
                    }
                }
            }
        }
        if let target, target != previous { Haptics.snap(at: screen, in: nil) }
        return target
    }

    func sketchDragBegan(_ screen: CGPoint, touch: ViewportTouch) -> Bool {
        guard let s = sketch else { return false }
        // When only the Pencil draws, one finger always orbits.
        if touch == .finger && PencilDrawing.isActive { return false }
        if s.tool == .select {
            guard let item = hitSketchItem(screen) else { return false }
            switch item {
            case .point(let id):
                if id == Sketch.originID || s.sketch.point(id)?.fixed == true { return false }
                dragState = .sketchPoint(id: id, before: s.sketch)
                return true
            case .curve(let id):
                guard let c = s.sketch.curve(id), let p = planePoint(screen) else { return false }
                if c.kind == .line {
                    dragState = .sketchLine(id: id, start: p, before: s.sketch, ends: s.sketch.lineEnds(c))
                } else {
                    dragState = .sketchCircle(id: id, before: s.sketch)
                }
                return true
            case .constraint:
                return false
            }
        }
        if s.tool == .dimension || s.tool.isModifyTool { return false }
        // Drawing by dragging: press = first point, release = next point. Pencil and mouse always draw;
        // a finger draws only when it starts on the sketch's own geometry or a tool is mid-action.
        if touch == .finger && s.clicks.isEmpty && s.chainStart == nil && hitSketchItem(screen) == nil { return false }
        guard let snap = snap(screen) else { return false }
        if s.clicks.isEmpty && s.chainStart == nil { drawClick(snap) }
        dragState = .sketchDraw(start: snap)
        return true
    }

    func sketchDragMoved(_ screen: CGPoint) {
        guard let state = dragState, var s = sketch, let p = planePoint(screen) else { return }
        switch state {
        case .sketchPoint(let id, let before):
            let target = snapForDrag(screen, excluding: [id]) ?? p
            let r = SketchSolver.solve(before, locked: [id: target])
            if r.converged || r.maxError < 1e-4 { s.sketch = r.sketch; s.solve = r }
            sketch = s
        case .sketchLine(let id, let start, let before, let ends):
            guard let c = before.curve(id) else { return }
            let delta = p - start
            let r = SketchSolver.solve(before, locked: [c.a: ends.0 + delta, c.b: ends.1 + delta])
            if r.converged { s.sketch = r.sketch; s.solve = r }
            sketch = s
        case .sketchCircle(let id, let before):
            guard let c = before.curve(id) else { return }
            var sk = before
            let center = before.position(c.a)
            if c.kind == .circle {
                if let i = sk.curves.firstIndex(where: { $0.id == id }) { sk.curves[i].radius = max((p - center).length, 0.01) }
                let r = SketchSolver.solve(sk)
                s.sketch = r.sketch; s.solve = r
            } else {
                // Dragging an arc moves its centre; the ends follow.
                let r = SketchSolver.solve(before, locked: [c.a: p])
                if r.converged { s.sketch = r.sketch; s.solve = r }
            }
            sketch = s
        case .sketchDraw:
            s.cursor = inferredCursor(snap(screen), in: s)
            s.lastSnapTarget = snapFeedback(s.cursor, previous: s.lastSnapTarget, screen: screen)
            sketch = s
        case .handle:
            break
        }
    }

    func sketchDragEnded(_ screen: CGPoint) {
        guard let state = dragState else { return }
        dragState = nil
        switch state {
        case .sketchPoint(_, let before), .sketchLine(_, _, let before, _), .sketchCircle(_, let before):
            guard var s = sketch, s.sketch != before else { return }
            s.undoStack.append(before)
            s.redoStack = []
            s.offsetEdit = nil
            sketch = s
        case .sketchDraw(let start):
            guard let end = snap(screen) else { return }
            if (end.position - start.position).length > sketchTolerance * 6 { drawClick(end) }
        case .handle:
            break
        }
    }

    private func snapForDrag(_ screen: CGPoint, excluding: Set<Int>) -> Vec2? {
        guard let s = snap(screen, excluding: excluding) else { return nil }
        if case .grid = s.kind { return planePoint(screen) }  // free dragging, no grid jumps
        return s.position
    }

    /// Hit test: points first, then dimension labels are separate (overlay), then curves.
    func hitSketchItem(_ screen: CGPoint) -> SketchItem? {
        guard let s = sketch, let p = planePoint(screen) else { return nil }
        let tol = sketchTolerance
        var best: (SketchItem, Double)? = nil
        for pt in s.sketch.points {
            let d = (pt.position - p).length
            if d < tol * 16 && (best == nil || d < best!.1) { best = (.point(pt.id), d) }
        }
        if let b = best { return b.0 }
        for c in s.sketch.curves {
            let d = s.sketch.distance(from: p, to: c)
            if d < tol * 12 && (best == nil || d < best!.1) { best = (.curve(c.id), d) }
        }
        return best?.0
    }

    // MARK: - Drawing tools

    private func drawClick(_ snap: SketchSnap) {
        guard var s = sketch else { return }
        switch s.tool {
        case .line:
            if let start = s.chainStart {
                let startPos = s.sketch.position(start)
                var end = snap
                // Nearly horizontal or vertical lines become exactly that, with a constraint.
                var autoConstraint: ConstraintKind? = nil
                if end.pointID == nil {
                    let d = end.position - startPos
                    let ang = abs(atan2(d.y, d.x))
                    if ang < 0.05 || abs(ang - .pi) < 0.05 { end.position.y = startPos.y; autoConstraint = .horizontal }
                    else if abs(ang - .pi / 2) < 0.05 { end.position.x = startPos.x; autoConstraint = .vertical }
                } else if let pid = end.pointID {
                    let d = s.sketch.position(pid) - startPos
                    if abs(d.y) < 1e-9 { autoConstraint = .horizontal } else if abs(d.x) < 1e-9 { autoConstraint = .vertical }
                }
                if end.pointID == start || (end.position - startPos).length < 1e-6 { s.chainStart = nil; sketch = s; return }
                var newEnd = 0
                changeSketch { sk in
                    newEnd = self.pointID(for: end, in: &sk)
                    let l = sk.addLine(start, newEnd)
                    if let k = autoConstraint { sk.addConstraint(k, [l]) }
                }
                // Closing onto an existing point ends the chain.
                if end.pointID != nil { sketch?.chainStart = nil } else { sketch?.chainStart = newEnd }
            } else {
                var id = 0
                if let existing = snap.pointID { id = existing } else {
                    changeSketch({ sk in id = self.pointID(for: snap, in: &sk) }, solve: false)
                }
                sketch?.chainStart = id
            }

        case .rectangle:
            if let first = s.clicks.first {
                s.clicks = []
                sketch = s
                let a = first.position, c = snap.position
                guard abs(a.x - c.x) > 1e-6, abs(a.y - c.y) > 1e-6 else { return }
                changeSketch { sk in
                    let p1 = self.pointID(for: first, in: &sk)
                    let p3 = self.pointID(for: snap, in: &sk)
                    let p2 = sk.addPoint(Vec2(c.x, a.y)), p4 = sk.addPoint(Vec2(a.x, c.y))
                    let l1 = sk.addLine(p1, p2), l2 = sk.addLine(p2, p3), l3 = sk.addLine(p3, p4), l4 = sk.addLine(p4, p1)
                    sk.addConstraint(.horizontal, [l1]); sk.addConstraint(.horizontal, [l3])
                    sk.addConstraint(.vertical, [l2]); sk.addConstraint(.vertical, [l4])
                }
            } else {
                s.clicks = [snap]; sketch = s
            }

        case .circle:
            if let center = s.clicks.first {
                s.clicks = []
                sketch = s
                let r = (snap.position - center.position).length
                guard r > 1e-6 else { return }
                changeSketch { sk in
                    let c = self.pointID(for: center, in: &sk)
                    sk.addCircle(center: c, radius: r)
                }
            } else {
                s.clicks = [snap]; sketch = s
            }

        case .arc:
            if s.clicks.count == 2 {
                let center = s.clicks[0], start = s.clicks[1]
                s.clicks = []
                sketch = s
                let r = (start.position - center.position).length
                guard r > 1e-6 else { return }
                let endPos = center.position + (snap.position - center.position).normalized * r
                changeSketch { sk in
                    let c = self.pointID(for: center, in: &sk)
                    let a = self.pointID(for: start, in: &sk)
                    var endSnap = snap
                    if endSnap.pointID == nil { endSnap.position = endPos; endSnap.kind = .free }
                    let b = self.pointID(for: endSnap, in: &sk)
                    sk.addArc(center: c, start: a, end: b)
                }
            } else {
                s.clicks.append(snap); sketch = s
            }

        case .slot:
            if s.clicks.count == 2 {
                let c1 = s.clicks[0].position, c2 = s.clicks[1].position
                s.clicks = []
                sketch = s
                let axis = c2 - c1
                guard axis.length > 1e-6 else { return }
                let n = axis.normalized.perpendicular
                let r = max(abs((snap.position - c1).dot(n)), 0.1)
                changeSketch { sk in
                    let a = sk.addPoint(c1), b = sk.addPoint(c2)
                    let p1 = sk.addPoint(c1 - n * r), p2 = sk.addPoint(c2 - n * r)
                    let p3 = sk.addPoint(c2 + n * r), p4 = sk.addPoint(c1 + n * r)
                    let l1 = sk.addLine(p1, p2), l2 = sk.addLine(p3, p4)
                    let a1 = sk.addArc(center: b, start: p2, end: p3)
                    let a2 = sk.addArc(center: a, start: p4, end: p1)
                    sk.addConstraint(.tangent, [l1, a1]); sk.addConstraint(.tangent, [l2, a1])
                    sk.addConstraint(.tangent, [l1, a2]); sk.addConstraint(.tangent, [l2, a2])
                    sk.addConstraint(.equal, [a1, a2])
                    let axisLine = sk.addLine(a, b, construction: true)
                    _ = axisLine
                }
            } else {
                s.clicks.append(snap); sketch = s
            }

        case .polygon:
            if let center = s.clicks.first {
                s.clicks = []
                sketch = s
                let r = (snap.position - center.position).length
                guard r > 1e-6 else { return }
                let n = max(3, s.polygonSides)
                let a0 = (snap.position - center.position).angle
                changeSketch { sk in
                    let c = self.pointID(for: center, in: &sk)
                    let circle = sk.addCircle(center: c, radius: r, construction: true)
                    var pts: [Int] = []
                    for k in 0..<n {
                        let t = a0 + Double(k) / Double(n) * 2 * .pi
                        let id = sk.addPoint(center.position + Vec2(cos(t), sin(t)) * r)
                        sk.addConstraint(.pointOnCurve, [id, circle])
                        pts.append(id)
                    }
                    var lines: [Int] = []
                    for k in 0..<n { lines.append(sk.addLine(pts[k], pts[(k + 1) % n])) }
                    for k in 1..<n { sk.addConstraint(.equal, [lines[0], lines[k]]) }
                }
            } else {
                s.clicks = [snap]; sketch = s
            }

        case .point:
            changeSketch { sk in _ = self.pointID(for: snap, in: &sk) }

        case .select, .dimension, .trim, .fillet, .mirror:
            break
        }
    }

    // MARK: - Modify tools (trim, round corner, offset, mirror)

    /// The curve closest to a screen point (ignores points, unlike `hitSketchItem`).
    func nearestCurve(_ screen: CGPoint) -> Int? {
        guard let s = sketch, let p = planePoint(screen) else { return nil }
        let tol = sketchTolerance * 14
        var best: (Int, Double)? = nil
        for c in s.sketch.curves {
            let d = s.sketch.distance(from: p, to: c)
            if d < tol && (best == nil || d < best!.1) { best = (c.id, d) }
        }
        return best?.0
    }

    /// Trim: removes the tapped piece of a curve between its crossings.
    private func trimTap(_ screen: CGPoint) {
        guard let s = sketch, let p = planePoint(screen) else { return }
        guard let id = nearestCurve(screen), let trimmed = SketchEdit.trim(s.sketch, curve: id, near: p) else {
            show(String(localized: "Tap the piece of a line or circle you want to remove."))
            return
        }
        changeSketch { $0 = trimmed }
        sketch?.selected = []
    }

    /// Round corner: the corner nearest to the tap.
    private func cornerTap(_ screen: CGPoint) {
        guard let s = sketch, let p = planePoint(screen) else { return }
        let tol = sketchTolerance * 22
        let corner = s.sketch.points
            .filter { SketchEdit.corner(s.sketch, at: $0.id) != nil }
            .min { ($0.position - p).length < ($1.position - p).length }
        guard let corner, (corner.position - p).length < tol else {
            show(String(localized: "Tap a corner where two lines meet."))
            return
        }
        roundSketchCorner(corner.id)
    }

    /// Rounds a corner with the last radius (smaller if it doesn't fit) and opens the radius for typing.
    func roundSketchCorner(_ pid: Int) {
        guard let s = sketch else { return }
        guard let corner = SketchEdit.corner(s.sketch, at: pid) else {
            show(String(localized: "Tap a corner where two lines meet."))
            return
        }
        var r = s.cornerRadius
        if r >= corner.maxRadius * 0.95 {
            // A round number that fits comfortably.
            let v = corner.maxRadius * 0.5
            let step = v >= 2 ? 0.5 : 0.1
            let rounded = (v / step).rounded(.down) * step
            r = rounded > 0 ? rounded : v
        }
        switch SketchEdit.roundCorner(s.sketch, at: pid, radius: r) {
        case .success(let result):
            changeSketch { $0 = result.sketch }
            sketch?.selected = []
            sketch?.editingDimension = result.dimension
        case .failure:
            show(String(localized: "The lines are too short for a round corner here."), kind: .error)
        }
    }

    /// Offset: copies the selected shape at a distance (outwards for closed shapes).
    /// One selected line or arc takes its whole connected outline.
    func offsetSketchSelection() {
        guard let s = sketch else { return }
        var ids = s.selected.compactMap { if case .curve(let c) = $0 { return c } else { return nil } }.sorted()
        guard !ids.isEmpty else {
            show(String(localized: "Select a shape first, then tap Offset."))
            return
        }
        if ids.count == 1 {
            let connected = SketchEdit.connectedCurves(s.sketch, from: ids[0])
            if SketchEdit.chain(s.sketch, curves: connected) != nil { ids = connected }
        }
        applyOffset(sources: ids, distance: s.offsetDistance, before: s.sketch, isNew: true)
    }

    /// The offset distance (inspector field). Changing it right after an offset redoes that offset.
    func setOffsetDistance(_ d: Double) {
        guard let s = sketch, d.isFinite, abs(d) > 1e-6 else { return }
        if let edit = s.offsetEdit {
            applyOffset(sources: edit.sources, distance: d, before: edit.before, isNew: false)
        } else {
            sketch?.offsetDistance = d
        }
    }

    func flipOffsetSide() {
        guard let s = sketch else { return }
        setOffsetDistance(-s.offsetDistance)
    }

    private func applyOffset(sources: [Int], distance: Double, before: Sketch, isNew: Bool) {
        switch SketchEdit.offset(before, curves: sources, distance: distance) {
        case .failure(let f):
            show(f == .tooBig
                 ? String(localized: "The offset is too big for this shape.")
                 : String(localized: "Select one closed shape or a chain of connected lines."), kind: .error)
        case .success(let result):
            if isNew {
                changeSketch { $0 = result.sketch }
            } else if var s = sketch {
                // Replaces the previous offset; the undo step from the first offset stays.
                let r = SketchSolver.solve(result.sketch)
                s.sketch = r.sketch
                s.solve = r
                s.regionHapticPending = true
                sketch = s
            }
            sketch?.offsetDistance = distance
            sketch?.offsetEdit = SketchSession.OffsetEdit(before: before, sources: sources)
            sketch?.selected = Set(result.curves.map { SketchItem.curve($0) })
        }
    }

    /// Mirror: remembers the selected curves, then waits for the mirror line.
    func startSketchMirror() {
        guard let s = sketch else { return }
        let ids = s.selected.compactMap { if case .curve(let c) = $0 { return c } else { return nil } }.sorted()
        guard !ids.isEmpty else {
            show(String(localized: "Select the shapes to mirror first, then tap Mirror."))
            return
        }
        setSketchTool(.mirror)
        sketch?.mirrorSource = ids
        sketch?.selected = Set(ids.map { SketchItem.curve($0) })
    }

    private func mirrorTap(_ screen: CGPoint) {
        guard let s = sketch else { return }
        guard !s.mirrorSource.isEmpty else {
            show(String(localized: "Select the shapes to mirror first, then tap Mirror."))
            setSketchTool(.select)
            return
        }
        guard let id = nearestCurve(screen), s.sketch.curve(id)?.kind == .line,
              let (mirrored, created) = SketchEdit.mirror(s.sketch, curves: s.mirrorSource, across: id) else {
            show(String(localized: "Tap a straight line to mirror across."))
            return
        }
        changeSketch { $0 = mirrored }
        setSketchTool(.select)
        sketch?.selected = Set(created.map { SketchItem.curve($0) })
    }

    // MARK: - Dimensions

    private func dimensionTap(_ screen: CGPoint) {
        guard var s = sketch else { return }
        guard let item = hitSketchItem(screen) else { s.clicks = []; s.selected = []; sketch = s; return }
        switch item {
        case .curve(let id):
            guard let c = s.sketch.curve(id) else { return }
            if let pending = s.clicks.first, let pid = pending.pointID, c.kind == .line {
                // point, then line → distance from the line
                s.clicks = []; sketch = s
                let (a, b) = s.sketch.lineEnds(c)
                let d = abs((b - a).normalized.cross(s.sketch.position(pid) - a))
                addDimension(.pointLineDistance, [pid, id], value: d)
                return
            }
            if case .curve(let other)? = s.selected.first, other != id, let oc = s.sketch.curve(other), oc.kind == .line, c.kind == .line {
                // second line → angle
                let (a1, b1) = s.sketch.lineEnds(oc), (a2, b2) = s.sketch.lineEnds(c)
                let d1 = b1 - a1, d2 = b2 - a2
                s.selected = []; sketch = s
                addDimension(.angle, [other, id], value: atan2(d1.cross(d2), d1.dot(d2)))
                return
            }
            switch c.kind {
            case .line:
                let (a, b) = s.sketch.lineEnds(c)
                s.selected = [.curve(id)]; sketch = s
                addDimension(.length, [id], value: (b - a).length)
            case .circle:
                addDimension(.diameter, [id], value: c.radius * 2)
            case .arc:
                addDimension(.radius, [id], value: s.sketch.radius(of: c))
            }
        case .point(let id):
            if let first = s.clicks.first, let fid = first.pointID, fid != id {
                s.clicks = []; sketch = s
                let d = (s.sketch.position(fid) - s.sketch.position(id)).length
                addDimension(.distance, [fid, id], value: d)
            } else {
                s.clicks = [SketchSnap(position: s.sketch.position(id), pointID: id, kind: .point)]
                s.selected = [.point(id)]
                sketch = s
            }
        case .constraint(let k):
            sketch?.editingDimension = k
        }
    }

    /// Adds a dimension with the current value and opens it for typing.
    func addDimension(_ kind: ConstraintKind, _ refs: [Int], value: Double) {
        var newID = 0
        changeSketch { sk in newID = sk.addConstraint(kind, refs, value: value) }
        sketch?.selected = []
        sketch?.editingDimension = newID
    }

    /// Sets a dimension's value. Returns false when that would break the sketch.
    @discardableResult
    func setDimension(_ id: Int, value: Double) -> Bool {
        guard let s = sketch, let k = s.sketch.constraint(id) else { return false }
        var v = value
        if k.kind == .angle { v = (k.value ?? 0) < 0 ? -abs(value) : abs(value) }
        guard v != 0 || k.kind == .angle else { return false }
        var test = s.sketch
        if let i = test.constraints.firstIndex(where: { $0.id == id }) { test.constraints[i].value = v }
        let r = SketchSolver.solve(test)
        if !r.converged {
            show(String(localized: "That size doesn't fit the other constraints."), kind: .error)
            return false
        }
        changeSketch { sk in
            if let i = sk.constraints.firstIndex(where: { $0.id == id }) { sk.constraints[i].value = v }
        }
        sketch?.editingDimension = nil
        // The next rounded corner uses the radius typed last.
        if k.kind == .radius && s.tool == .fillet { sketch?.cornerRadius = v }
        return true
    }

    // MARK: - Constraint actions

    struct ConstraintAction: Identifiable {
        let id: String
        let title: LocalizedStringKey
        let icon: String
        let run: () -> Void
    }

    var sketchActions: [ConstraintAction] {
        guard let s = sketch else { return [] }
        let sel = s.selected
        let pts = sel.compactMap { if case .point(let p) = $0 { return p } else { return nil } }
        let curves = sel.compactMap { if case .curve(let c) = $0 { return s.sketch.curve(c) } else { return nil } }
        let lines = curves.filter { $0.kind == .line }
        let rounds = curves.filter { $0.kind != .line }
        var out: [ConstraintAction] = []
        func add(_ id: String, _ t: LocalizedStringKey, _ icon: String, _ f: @escaping () -> Void) {
            out.append(ConstraintAction(id: id, title: t, icon: icon, run: f))
        }
        func constrain(_ k: ConstraintKind, _ refs: [Int]) { changeSketch { $0.addConstraint(k, refs) }; sketch?.selected = [] }

        // Right after an offset: flip it to the other side.
        if s.offsetEdit != nil {
            add("offflip", "Other Side", "arrow.left.arrow.right", { self.flipOffsetSide() })
        }
        if lines.count == 1 && curves.count == 1 && pts.isEmpty {
            let l = lines[0]
            add("h", "Horizontal", "arrow.left.and.right", { constrain(.horizontal, [l.id]) })
            add("v", "Vertical", "arrow.up.and.down", { constrain(.vertical, [l.id]) })
            add("len", "Length", "ruler", {
                let (a, b) = s.sketch.lineEnds(l)
                self.addDimension(.length, [l.id], value: (b - a).length)
            })
        }
        if lines.count == 2 && curves.count == 2 && pts.isEmpty {
            let a = lines[0], b = lines[1]
            add("par", "Parallel", "equal", { constrain(.parallel, [a.id, b.id]) })
            add("perp", "Perpendicular", "angle", { constrain(.perpendicular, [a.id, b.id]) })
            add("eq", "Equal", "equal.square", { constrain(.equal, [a.id, b.id]) })
            add("ang", "Angle", "angle", {
                let (a1, b1) = s.sketch.lineEnds(a), (a2, b2) = s.sketch.lineEnds(b)
                let d1 = b1 - a1, d2 = b2 - a2
                self.addDimension(.angle, [a.id, b.id], value: atan2(d1.cross(d2), d1.dot(d2)))
            })
        }
        if lines.count == 1 && rounds.count == 1 && pts.isEmpty {
            add("tan", "Tangent", "circle.and.line.horizontal", { constrain(.tangent, [lines[0].id, rounds[0].id]) })
        }
        if rounds.count == 2 && curves.count == 2 && pts.isEmpty {
            let a = rounds[0], b = rounds[1]
            add("eqr", "Equal", "equal.square", { constrain(.equal, [a.id, b.id]) })
            add("conc", "Concentric", "circle.circle", { constrain(.concentric, [a.id, b.id]) })
            add("tan2", "Tangent", "circle.and.line.horizontal", { constrain(.tangent, [a.id, b.id]) })
        }
        if rounds.count == 1 && curves.count == 1 && pts.isEmpty {
            let c = rounds[0]
            add("dia", c.kind == .circle ? "Diameter" : "Radius", "ruler", {
                if c.kind == .circle { self.addDimension(.diameter, [c.id], value: c.radius * 2) }
                else { self.addDimension(.radius, [c.id], value: s.sketch.radius(of: c)) }
            })
        }
        if pts.count == 2 && curves.isEmpty {
            let a = pts[0], b = pts[1]
            add("co", "Coincident", "smallcircle.filled.circle", { self.mergePoints(a, into: b) })
            add("hp", "Horizontal", "arrow.left.and.right", { constrain(.horizontal, [a, b]) })
            add("vp", "Vertical", "arrow.up.and.down", { constrain(.vertical, [a, b]) })
            add("dist", "Distance", "ruler", {
                self.addDimension(.distance, [a, b], value: (s.sketch.position(a) - s.sketch.position(b)).length)
            })
            add("hd", "Horizontal distance", "arrow.left.and.right.square", {
                self.addDimension(.horizontalDistance, [a, b], value: abs(s.sketch.position(b).x - s.sketch.position(a).x))
            })
            add("vd", "Vertical distance", "arrow.up.and.down.square", {
                self.addDimension(.verticalDistance, [a, b], value: abs(s.sketch.position(b).y - s.sketch.position(a).y))
            })
        }
        if pts.count == 1 && curves.count == 1 {
            let p = pts[0], c = curves[0]
            add("on", c.kind == .line ? "On line" : "On circle", "smallcircle.filled.circle", { constrain(.pointOnCurve, [p, c.id]) })
            if c.kind == .line {
                add("mid", "Midpoint", "line.diagonal.arrow", { constrain(.midpoint, [p, c.id]) })
                add("pld", "Distance", "ruler", {
                    let (a, b) = s.sketch.lineEnds(c)
                    self.addDimension(.pointLineDistance, [p, c.id], value: abs((b - a).normalized.cross(s.sketch.position(p) - a)))
                })
            }
        }
        if pts.count == 2 && lines.count == 1 && curves.count == 1 {
            add("sym", "Symmetric", "arrow.left.and.right.righttriangle.left.righttriangle.right", {
                constrain(.symmetric, [pts[0], pts[1], lines[0].id])
            })
        }
        if lines.count >= 3 && curves.count == lines.count && pts.isEmpty {
            add("eqn", "Equal", "equal.square", {
                self.changeSketch { sk in for l in lines.dropFirst() { sk.addConstraint(.equal, [lines[0].id, l.id]) } }
                self.sketch?.selected = []
            })
        }
        if pts.count == 1 && curves.isEmpty && SketchEdit.corner(s.sketch, at: pts[0]) != nil {
            let p = pts[0]
            add("rnd", "Round Corner", SketchTool.fillet.icon, { self.roundSketchCorner(p) })
        }
        if pts.count == 1 && curves.isEmpty && pts[0] != Sketch.originID {
            let p = pts[0]
            let fixed = s.sketch.constraints.contains { $0.kind == .fix && $0.refs == [p] }
            add("fix", fixed ? "Unfix" : "Fix", fixed ? "lock.open" : "lock", {
                if fixed { self.changeSketch { $0.constraints.removeAll { $0.kind == .fix && $0.refs == [p] } } }
                else { constrain(.fix, [p]) }
            })
        }
        if !curves.isEmpty && pts.isEmpty {
            // Lock whole curves in place (every point of them).
            let curvePoints = Set(curves.flatMap { $0.pointIDs }).subtracting([Sketch.originID])
            let fixedPoints = Set(s.sketch.constraints.filter { $0.kind == .fix }.compactMap { $0.refs.first })
            let allFixed = curvePoints.isSubset(of: fixedPoints)
            add("fixc", allFixed ? "Unfix" : "Fix", allFixed ? "lock.open" : "lock", {
                if allFixed {
                    self.changeSketch { $0.constraints.removeAll { $0.kind == .fix && $0.refs.count == 1 && curvePoints.contains($0.refs[0]) } }
                } else {
                    self.changeSketch { sk in for p in curvePoints.subtracting(fixedPoints).sorted() { sk.addConstraint(.fix, [p]) } }
                }
                self.sketch?.selected = []
            })
            add("off", "Offset", "square.on.square.dashed", { self.offsetSketchSelection() })
            add("mirr", "Mirror", SketchTool.mirror.icon, { self.startSketchMirror() })
        }
        if !curves.isEmpty {
            add("cons", "Construction", "line.3.horizontal.decrease", { self.toggleConstruction() })
        }
        if !sel.isEmpty {
            add("del", "Delete", "trash", { self.deleteSketchSelection() })
        }
        return out
    }

    /// Makes two points one (the cleanest way to say "coincident").
    func mergePoints(_ from: Int, into to: Int) {
        guard from != to else { return }
        let (src, dst) = from == Sketch.originID ? (to, from) : (from, to)
        changeSketch { sk in
            for i in sk.curves.indices {
                if sk.curves[i].a == src { sk.curves[i].a = dst }
                if sk.curves[i].b == src { sk.curves[i].b = dst }
                if sk.curves[i].c == src { sk.curves[i].c = dst }
            }
            for i in sk.constraints.indices {
                sk.constraints[i].refs = sk.constraints[i].refs.map { $0 == src ? dst : $0 }
            }
            sk.points.removeAll { $0.id == src }
            // Lines that collapsed to a point go away.
            sk.curves.removeAll { $0.kind == .line && $0.a == $0.b }
        }
        sketch?.selected = []
    }

    // MARK: - Drawing the sketch

    func addSketchOverlay(_ s: SketchSession, to scene: inout RenderScene) {
        let plane = s.plane
        let sk = s.sketch
        let defined = s.solve?.definedCurves ?? []
        let definedPts = s.solve?.definedPoints ?? []
        let conflicts = s.solve?.conflicting ?? []
        let conflictRefs = Set(sk.constraints.filter { conflicts.contains($0.id) }.flatMap { $0.refs })
        let accent = SIMD4<Float>(1.0, 0.45, 0.1, 1)
        let free = SIMD4<Float>(0.1, 0.42, 0.95, 1)
        let black = SIMD4<Float>(0.1, 0.1, 0.12, 1)
        let red = SIMD4<Float>(0.9, 0.15, 0.2, 1)
        for c in sk.curves {
            let pts = sk.polyline(c).map { plane.world($0).float3 }
            var color = defined.contains(c.id) ? black : free
            if conflictRefs.contains(c.id) { color = red }
            if s.selected.contains(.curve(c.id)) { color = accent }
            if c.construction { color.w = 0.45 }
            let width: Float = c.construction ? 1.1 : 2
            for k in 0..<(pts.count - 1) {
                // Construction lines are dashed: draw every other piece of long segments.
                if c.construction {
                    let a = pts[k], b = pts[k + 1]
                    let n = max(1, Int(simd_length(b - a) / Float(sketchTolerance * 8)))
                    for j in stride(from: 0, to: n, by: 2) {
                        let t0 = Float(j) / Float(n), t1 = Float(min(j + 1, n)) / Float(n)
                        scene.overlayLines.append(GPULineSegment(a + (b - a) * t0, a + (b - a) * t1, color: color, width: width))
                    }
                } else {
                    scene.overlayLines.append(GPULineSegment(pts[k], pts[k + 1], color: color, width: width))
                }
            }
        }
        let used = Set(sk.curves.flatMap { $0.pointIDs })
        for p in sk.points where used.contains(p.id) || p.id == Sketch.originID || !sk.curves.contains(where: { $0.pointIDs.contains(p.id) }) {
            var color = definedPts.contains(p.id) ? black : free
            if conflictRefs.contains(p.id) { color = red }
            if s.selected.contains(.point(p.id)) { color = accent }
            if p.id == Sketch.originID { color = SIMD4(0.85, 0.2, 0.2, 1) }
            scene.overlayPoints.append(GPUPointSprite(plane.world(p.position).float3, color: color, size: s.selected.contains(.point(p.id)) ? 11 : 8))
        }
        for m in s.modelSnaps {
            scene.overlayPoints.append(GPUPointSprite(plane.world(m).float3, color: SIMD4(0.5, 0.5, 0.55, 0.6), size: 5))
        }
        for tris in s.regionFills { scene.fills.append((tris, SIMD4(0.2, 0.5, 1.0, 0.13))) }

        // Rubber band for the drawing tool.
        let preview = SIMD4<Float>(0.1, 0.42, 0.95, 0.75)
        if let cursor = s.cursor {
            let cp = plane.world(cursor.position).float3
            let snapColor: SIMD4<Float> = switch cursor.kind {
            case .point, .origin: accent
            case .model, .midpoint: SIMD4(0.2, 0.7, 0.35, 1)
            case .curve: SIMD4(0.2, 0.7, 0.35, 1)
            default: SIMD4(0.1, 0.42, 0.95, 0.9)
            }
            scene.overlayPoints.append(GPUPointSprite(cp, color: snapColor, size: cursor.kind == .grid || cursor.kind == .free ? 7 : 12))
            var outline: [Vec2] = []
            switch s.tool {
            case .line:
                if let start = s.chainStart { outline = [sk.position(start), cursor.position] }
            case .rectangle:
                if let a = s.clicks.first?.position {
                    let c = cursor.position
                    outline = [a, Vec2(c.x, a.y), c, Vec2(a.x, c.y), a]
                }
            case .circle, .polygon:
                if let center = s.clicks.first?.position {
                    let r = (cursor.position - center).length
                    let n = s.tool == .circle ? 64 : max(3, s.polygonSides)
                    let a0 = (cursor.position - center).angle
                    outline = (0...n).map { k in center + Vec2(cos(a0 + Double(k) / Double(n) * 2 * .pi), sin(a0 + Double(k) / Double(n) * 2 * .pi)) * r }
                }
            case .arc:
                if s.clicks.count == 1 { outline = [s.clicks[0].position, cursor.position] }
                else if s.clicks.count == 2 {
                    let c = s.clicks[0].position, a = s.clicks[1].position
                    let r = (a - c).length
                    let a0 = (a - c).angle
                    var a1 = (cursor.position - c).angle
                    while a1 <= a0 { a1 += 2 * .pi }
                    outline = (0...48).map { k in c + Vec2(cos(a0 + (a1 - a0) * Double(k) / 48), sin(a0 + (a1 - a0) * Double(k) / 48)) * r }
                }
            case .slot:
                if s.clicks.count == 1 { outline = [s.clicks[0].position, cursor.position] }
                else if s.clicks.count == 2 {
                    let c1 = s.clicks[0].position, c2 = s.clicks[1].position
                    let n = (c2 - c1).normalized.perpendicular
                    let r = abs((cursor.position - c1).dot(n))
                    outline = [c1 - n * r, c2 - n * r, c2 + n * r, c1 + n * r, c1 - n * r]
                }
            default: break
            }
            for k in 0..<max(outline.count - 1, 0) {
                scene.overlayLines.append(GPULineSegment(plane.world(outline[k]).float3, plane.world(outline[k + 1]).float3, color: preview, width: 1.5))
            }
        }
        for c in s.clicks {
            scene.overlayPoints.append(GPUPointSprite(plane.world(c.position).float3, color: accent, size: 9))
        }
        // Trim: the piece a tap would remove, in red.
        if s.tool == .trim && s.trimPreview.count > 1 {
            for k in 0..<(s.trimPreview.count - 1) {
                scene.overlayLines.append(GPULineSegment(plane.world(s.trimPreview[k]).float3, plane.world(s.trimPreview[k + 1]).float3,
                                                         color: red, width: 3.5))
            }
        }
    }

    // MARK: - Dimension labels (drawn by SwiftUI)

    struct DimensionLabel: Identifiable {
        let id: Int
        let text: String
        let position: CGPoint
        let conflict: Bool
        let editing: Bool
        let value: Double
        let isAngle: Bool
    }

    var dimensionLabels: [DimensionLabel] {
        guard let s = sketch else { return [] }
        let sk = s.sketch
        let conflicts = s.solve?.conflicting ?? []
        var out: [DimensionLabel] = []
        for k in sk.constraints where k.kind.isDimension {
            guard let v = k.value, let anchor = labelAnchor(k, sk), let p = screenPoint(anchor) else { continue }
            let text: String
            switch k.kind {
            case .angle: text = Format.angle(abs(v))
            case .diameter: text = "⌀ " + Format.length(v, unit: design.unit)
            case .radius: text = "R " + Format.length(v, unit: design.unit)
            default: text = Format.length(v, unit: design.unit)
            }
            out.append(DimensionLabel(id: k.id, text: text, position: p, conflict: conflicts.contains(k.id),
                                      editing: s.editingDimension == k.id, value: k.kind == .angle ? abs(v) * 180 / .pi : v,
                                      isAngle: k.kind == .angle))
        }
        return out
    }

    // MARK: - Constraint glyphs (small icons next to constrained geometry, drawn by SwiftUI)

    struct ConstraintGlyph: Identifiable {
        /// Unique per glyph: "<constraint id>-<n>" (some constraints show on two curves).
        let id: String
        let constraint: Int
        /// SF Symbol name.
        let icon: String
        let position: CGPoint
        let conflict: Bool
        let selected: Bool
    }

    /// One glyph per geometric constraint (dimensions have their own labels). Tap one to select
    /// the constraint; "Delete" in the context bar removes it.
    var constraintGlyphs: [ConstraintGlyph] {
        guard let s = sketch else { return [] }
        let sk = s.sketch
        let conflicts = s.solve?.conflicting ?? []
        let off = sketchTolerance * 14
        var out: [ConstraintGlyph] = []
        // Glyphs at the same place are fanned out so they don't cover each other.
        var used: [Vec2] = []
        func place(_ k: SketchConstraint, _ n: Int, _ icon: String, _ at: Vec2) {
            var p = at
            while used.contains(where: { ($0 - p).length < off }) { p.x += off }
            used.append(p)
            guard let screen = screenPoint(p) else { return }
            out.append(ConstraintGlyph(id: "\(k.id)-\(n)", constraint: k.id, icon: icon, position: screen,
                                       conflict: conflicts.contains(k.id), selected: s.selected.contains(.constraint(k.id))))
        }
        /// A spot beside a curve: 35 % along a line (dimension labels sit at the middle), or on the circle.
        func beside(_ id: Int) -> Vec2? {
            guard let c = sk.curve(id) else { return nil }
            switch c.kind {
            case .line:
                let (a, b) = sk.lineEnds(c)
                return a + (b - a) * 0.35 - (b - a).normalized.perpendicular * off
            case .circle, .arc:
                let center = sk.position(c.a), r = sk.radius(of: c)
                var ang = 2.3
                if c.kind == .arc { let (a0, w) = sk.arcAngles(c); ang = a0 + w * 0.3 }
                return center + Vec2(cos(ang), sin(ang)) * (r + off)
            }
        }
        for k in sk.constraints where !k.kind.isDimension {
            let r = k.refs
            switch k.kind {
            case .horizontal, .vertical:
                let icon = k.kind == .horizontal ? "arrow.left.and.right" : "arrow.up.and.down"
                if r.count == 1, let p = beside(r[0]) { place(k, 0, icon, p) }
                else if r.count == 2 { place(k, 0, icon, (sk.position(r[0]) + sk.position(r[1])) / 2) }
            case .parallel, .perpendicular, .equal, .tangent, .concentric:
                let icon: String = switch k.kind {
                case .parallel: "equal"
                case .perpendicular: "angle"
                case .equal: "equal.square"
                case .tangent: "circle.and.line.horizontal"
                default: "circle.circle"
                }
                for (n, id) in r.prefix(2).enumerated() { if let p = beside(id) { place(k, n, icon, p) } }
            case .coincident, .pointOnCurve, .midpoint:
                guard let first = r.first, sk.point(first) != nil else { continue }
                let icon = k.kind == .midpoint ? "line.diagonal.arrow" : "smallcircle.filled.circle"
                place(k, 0, icon, sk.position(first) + Vec2(off, off) * 0.7)
            case .fix:
                guard let first = r.first, sk.point(first) != nil else { continue }
                place(k, 0, "lock.fill", sk.position(first) + Vec2(off, -off) * 0.7)
            case .symmetric:
                guard r.count == 3 else { continue }
                place(k, 0, "arrow.left.and.right.righttriangle.left.righttriangle.right",
                      (sk.position(r[0]) + sk.position(r[1])) / 2)
            default:
                continue
            }
        }
        return out
    }

    private func labelAnchor(_ k: SketchConstraint, _ sk: Sketch) -> Vec2? {
        let off = sketchTolerance * 18
        switch k.kind {
        case .length:
            guard let c = sk.curve(k.refs[0]) else { return nil }
            let (a, b) = sk.lineEnds(c)
            return (a + b) / 2 + (b - a).normalized.perpendicular * off
        case .distance, .horizontalDistance, .verticalDistance:
            guard k.refs.count == 2 else { return nil }
            let a = sk.position(k.refs[0]), b = sk.position(k.refs[1])
            var m = (a + b) / 2
            if k.kind == .horizontalDistance { m.y = max(a.y, b.y) + off }
            if k.kind == .verticalDistance { m.x = max(a.x, b.x) + off }
            return m
        case .pointLineDistance:
            guard k.refs.count == 2, let c = sk.curve(k.refs[1]) else { return nil }
            let (a, b) = sk.lineEnds(c)
            let p = sk.position(k.refs[0])
            let d = (b - a).normalized
            let foot = a + d * (p - a).dot(d)
            return (p + foot) / 2
        case .radius, .diameter:
            guard let c = sk.curve(k.refs[0]) else { return nil }
            let center = sk.position(c.a), r = sk.radius(of: c)
            if c.kind == .arc {
                let (a0, w) = sk.arcAngles(c)
                return center + Vec2(cos(a0 + w / 2), sin(a0 + w / 2)) * (r + off)
            }
            return center + Vec2(cos(0.8), sin(0.8)) * (r + off)
        case .angle:
            guard k.refs.count == 2, let l1 = sk.curve(k.refs[0]), let l2 = sk.curve(k.refs[1]) else { return nil }
            let (a1, b1) = sk.lineEnds(l1), (a2, b2) = sk.lineEnds(l2)
            return ((a1 + b1) / 2 + (a2 + b2) / 2) / 2
        default:
            return nil
        }
    }
}
