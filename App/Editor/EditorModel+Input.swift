import simd
import SwiftUI

extension EditorModel: ViewportInput {
    func viewportTap(_ p: CGPoint, extend: Bool, touch: ViewportTouch) {
        if touch == .pencil { PencilDrawing.pencilSeen = true }
        if sketch != nil { sketchTap(p, extend: extend, touch: touch); return }
        if let t = tool { toolTap(t, at: p, extend: extend); return }
        selectionTap(p, extend: extend)
    }

    private func selectionTap(_ p: CGPoint, extend: Bool) {
        measurement = nil
        if let hit = sketchHit(p) {
            toggle(hit, extend: extend)
            return
        }
        guard let renderer, let pick = renderer.pick(at: p), let sel = selection(for: pick) else {
            if !extend { selection = [] }
            return
        }
        // Tapping the same face twice quickly selects the whole body.
        if let (last, time) = lastTap, last == sel, Date().timeIntervalSince(time) < 0.4, let b = sel.bodyID {
            lastTap = nil
            let bodySel = Selection.body(b)
            if extend { if !selection.contains(bodySel) { selection.append(bodySel) } } else { selection = [bodySel] }
            selection.removeAll { $0 != bodySel && $0.bodyID == b && $0 != .body(b) }
            return
        }
        lastTap = (sel, Date())
        if case .body = selection.first, case .face(let b, _) = sel, !extend {
            // In body mode, tapping another body adds to the selection.
            let bodySel = Selection.body(b)
            if selection.contains(bodySel) { selection.removeAll { $0 == bodySel } } else { selection.append(bodySel) }
            return
        }
        toggle(sel, extend: extend)
    }

    func selection(for hit: PickHit) -> Selection? {
        switch hit {
        case .face(let i, let f):
            guard i < renderedBodyIDs.count else { return nil }
            return .face(body: renderedBodyIDs[i], face: f)
        case .edge(let i, let e):
            guard i < renderedBodyIDs.count else { return nil }
            return .edge(body: renderedBodyIDs[i], edge: e)
        }
    }

    /// Body ids in the order the renderer draws them (hidden bodies are skipped).
    var renderedBodyIDs: [String] {
        output.bodies.filter { !design.style($0.id).hidden }.map(\.id)
    }

    /// Regions and lines of finished sketches under the cursor.
    func sketchHit(_ p: CGPoint) -> Selection? {
        guard let renderer else { return nil }
        let (o, d) = renderer.camera.ray(at: p, size: renderer.viewSize)
        let tol = renderer.camera.unitsPerPoint(size: renderer.viewSize) * 10
        var best: (Selection, Double)? = nil
        for id in visibleSketches() {
            guard let built = output.sketches[id], let t = built.plane.intersect(rayOrigin: o, rayDir: d) else { continue }
            let q = built.plane.local(o + d * t)
            if let sk = design.feature(id)?.sketch?.sketch {
                for c in sk.curves where c.kind == .line && sk.distance(from: q, to: c) < tol {
                    if best == nil || t < best!.1 - 1e-6 { best = (.sketchLine(sketch: id, curve: c.id), t - 1e-3) }
                }
            }
            if let (i, _) = built.regions.enumerated().filter({ $0.1.contains(q) }).min(by: { $0.1.area < $1.1.area }) {
                if best == nil || t < best!.1 { best = (.region(sketch: id, index: i), t) }
            }
        }
        // A body in front of the sketch wins.
        if let best, let pick = renderer.pick(at: p), case .face(let bi, let f) = pick,
           bi < renderedBodyIDs.count, let body = body(renderedBodyIDs[bi]), let face = body.face(f) {
            let tFace = (face.centroid - o).dot(d)
            if face.isPlanar {
                let plane = Plane.onFace(normal: face.normal, through: face.centroid)
                if let tf = plane.intersect(rayOrigin: o, rayDir: d), tf < best.1 - 0.01 { return nil }
            } else if tFace < best.1 - 1 {
                return nil
            }
        }
        return best?.0
    }

    // MARK: - Taps while a tool is open

    private func toolTap(_ t: ToolSession, at p: CGPoint, extend: Bool) {
        if t.kind == .measure { measureTap(p); return }
        if t.kind == .extrude || t.kind == .revolve, let hit = sketchHit(p), case .region(let sid, let i) = hit,
           let built = output.sketches[sid], i < built.regions.count {
            let seed = built.regions[i].samplePoint
            updateTool { t in
                switch t.feature.operation {
                case .extrude(var e) where e.sketch == sid:
                    if let k = e.regionSeeds.firstIndex(where: { built.regions[i].contains($0) }) {
                        if e.regionSeeds.count > 1 { e.regionSeeds.remove(at: k) }
                    } else { e.regionSeeds.append(seed) }
                    t.feature.operation = .extrude(e)
                case .revolve(var r) where r.sketch == sid:
                    if let k = r.regionSeeds.firstIndex(where: { built.regions[i].contains($0) }) {
                        if r.regionSeeds.count > 1 { r.regionSeeds.remove(at: k) }
                    } else { r.regionSeeds.append(seed) }
                    t.feature.operation = .revolve(r)
                default: break
                }
            }
            return
        }
        if t.kind == .revolve, let hit = sketchHit(p), case .sketchLine(let sid, let c) = hit {
            updateTool { t in
                if case .revolve(var r) = t.feature.operation, r.sketch == sid { r.axisCurve = c; t.feature.operation = .revolve(r) }
            }
            return
        }
        guard let renderer, let pick = renderer.pick(at: p), let sel = selection(for: pick) else { return }
        switch (sel, t.feature.operation) {
        case (.edge(let b, let e), .fillet(var f)), (.edge(let b, let e), .chamfer(var f)):
            guard let built = body(b), let ref = built.edgeRef(e) else { return }
            if let k = f.edges.firstIndex(where: { ($0.midpoint - ref.midpoint).length < 1e-4 && $0.body == b }) {
                if f.edges.count > 1 { f.edges.remove(at: k) }
            } else { f.edges.append(ref) }
            updateTool { t in t.feature.operation = t.kind == .fillet ? .fillet(f) : .chamfer(f) }
        case (.face(let b, let fi), .shell(var s)) where b == s.body:
            guard let ref = body(b)?.faceRef(fi) else { return }
            if let k = s.openFaces.firstIndex(where: { ($0.centroid - ref.centroid).length < 1e-4 }) { s.openFaces.remove(at: k) }
            else { s.openFaces.append(ref) }
            updateTool { $0.feature.operation = .shell(s) }
        case (.face(let b, let fi), .hole(var h)):
            guard let built = body(b), let face = built.face(fi), face.isPlanar,
                  (face.normal - h.face.normal).length < 1e-6, b == h.face.body else {
                show(String(localized: "Holes go on the face you started with. Make another hole step for other faces."))
                return
            }
            let plane = Plane.onFace(normal: face.normal, through: face.centroid)
            let (o, d) = renderer.camera.ray(at: p, size: renderer.viewSize)
            guard let tt = plane.intersect(rayOrigin: o, rayDir: d) else { return }
            var pos = plane.local(o + d * tt)
            pos = Vec2((pos.x * 2).rounded() / 2, (pos.y * 2).rounded() / 2)  // half-millimetre steps
            if let k = h.positions.firstIndex(where: { ($0 - pos).length < h.diameter }) {
                if h.positions.count > 1 { h.positions.remove(at: k) }
            } else { h.positions.append(pos) }
            updateTool { $0.feature.operation = .hole(h) }
        case (.face(let b, let fi), .text(var tx)):
            guard let built = body(b), let face = built.face(fi), face.isPlanar else { return }
            let plane = Plane.onFace(normal: face.normal, through: face.centroid)
            let (o, d) = renderer.camera.ray(at: p, size: renderer.viewSize)
            guard let tt = plane.intersect(rayOrigin: o, rayDir: d) else { return }
            tx.plane = .face(FaceRef(body: b, info: face))
            tx.position = plane.local(o + d * tt)
            tx.target = b
            if tx.mode == .newBody { tx.mode = .join }
            updateTool { $0.feature.operation = .text(tx) }
        case (.face(let b, let fi), .mirror(var m)):
            guard let built = body(b), let face = built.face(fi), face.isPlanar else { return }
            m.plane = .face(FaceRef(body: b, info: face))
            updateTool { $0.feature.operation = .mirror(m) }
        case (.face(let b, let fi), .split(var sp)) where b != sp.body:
            guard let built = body(b), let face = built.face(fi), face.isPlanar else { return }
            sp.plane = .face(FaceRef(body: b, info: face))
            updateTool { $0.feature.operation = .split(sp) }
        case (.face(let b, _), .transform(var m)):
            if let k = m.bodies.firstIndex(of: b) { if m.bodies.count > 1 { m.bodies.remove(at: k) } } else { m.bodies.append(b) }
            updateTool { $0.feature.operation = .transform(m) }
        case (.face(let b, _), .pattern(var pt)):
            if let k = pt.bodies.firstIndex(of: b) { if pt.bodies.count > 1 { pt.bodies.remove(at: k) } } else { pt.bodies.append(b) }
            updateTool { $0.feature.operation = .pattern(pt) }
        case (.face(let b, _), .boolean(var bo)) where b != bo.target:
            if let k = bo.tools.firstIndex(of: b) { if bo.tools.count > 1 { bo.tools.remove(at: k) } } else { bo.tools.append(b) }
            updateTool { $0.feature.operation = .boolean(bo) }
        default:
            break
        }
    }

    private func measureTap(_ p: CGPoint) {
        guard let renderer, let pick = renderer.pick(at: p), let sel = selection(for: pick) else {
            selection = []; measurement = nil; return
        }
        var picks = tool?.picks ?? []
        if picks.count >= 2 { picks = [] ; measurement = nil }
        picks.append(sel)
        tool?.picks = picks
        selection = picks
        if picks.count == 2 { measure(picks[0], picks[1]) }
    }

    // MARK: - Drags

    func viewportDragBegan(_ p: CGPoint, touch: ViewportTouch) -> Bool {
        if touch == .pencil { PencilDrawing.pencilSeen = true }
        if sketch != nil { return sketchDragBegan(p, touch: touch) }
        guard let renderer else { return false }
        for h in handles {
            guard let tip = renderer.camera.project(handleTip(h), size: renderer.viewSize) else { continue }
            if hypot(tip.x - p.x, tip.y - p.y) < 30 {
                dragState = .handle(h, startValue: handleValue(h), startPoint: p)
                return true
            }
        }
        return false
    }

    func viewportDragMoved(_ p: CGPoint) {
        if sketch != nil { sketchDragMoved(p); return }
        guard case .handle(let h, let startValue, let startPoint) = dragState, let renderer else { return }
        let size = renderer.viewSize
        let (o0, d0) = renderer.camera.ray(at: startPoint, size: size)
        let (o1, d1) = renderer.camera.ray(at: p, size: size)
        guard let t0 = axisParameter(origin: h.origin, direction: h.direction, rayOrigin: o0, rayDirection: d0),
              let t1 = axisParameter(origin: h.origin, direction: h.direction, rayOrigin: o1, rayDirection: d1) else { return }
        setHandleValue(h, startValue + (t1 - t0))
    }

    func viewportDragEnded(_ p: CGPoint) {
        if sketch != nil { sketchDragEnded(p); return }
        dragState = nil
    }

    // MARK: - Hover

    func viewportHover(_ p: CGPoint?) {
        if sketch != nil { sketchHover(p); return }
        guard let p, let renderer, dragState == nil else { hover = nil; return }
        if let hit = sketchHit(p) { hover = hit; return }
        hover = renderer.pick(at: p).flatMap { selection(for: $0) }
    }

    func viewportUndo() {
        if sketch != nil { sketchUndo() } else if tool != nil { cancelTool() } else { undo() }
    }

    func viewportRedo() {
        if sketch != nil { sketchRedo() } else { redo() }
    }

    func viewportPencil(_ action: PencilAction) {
        // Double-tap switches between drawing and selecting; squeeze goes back to the previous tool.
        PencilDrawing.pencilSeen = true
        guard let s = sketch else { return }
        switch action {
        case .toggleSelect: setSketchTool(s.tool == .select ? s.lastDrawTool : .select)
        case .previousTool: setSketchTool(s.previousTool ?? (s.tool == .select ? s.lastDrawTool : .select))
        }
    }

    // MARK: - Right-click / long press

    func viewportContextMenu(at p: CGPoint) -> [ViewportMenuItem] {
        if var s = sketch {
            // Sketch actions show in the context bar.
            guard s.editingDimension == nil, let item = hitSketchItem(p) else { return [] }
            if !s.selected.contains(item) { s.selected = [item]; sketch = s }
            return []
        }
        guard tool == nil, let renderer else { return [] }
        measurement = nil
        guard let hit = sketchHit(p) ?? renderer.pick(at: p).flatMap({ selection(for: $0) }) else {
            selection = []
            return []
        }
        if !selection.contains(hit) { selection = [hit] }
        return contextActions()
    }

    /// The same actions as the context bar, as plain strings for the Mac's menu.
    private func contextActions() -> [ViewportMenuItem] {
        var out: [ViewportMenuItem] = []
        func add(_ title: String, _ icon: String, _ run: @escaping () -> Void) { out.append(ViewportMenuItem(title: title, icon: icon, run: run)) }
        func addTool(_ k: ToolKind) { add(localizedName(k), k.icon) { self.start(k) } }
        if let sid = selectedRegions.first?.0 {
            addTool(.extrude); addTool(.revolve)
            add(String(localized: "Edit Sketch"), "pencil") { self.editSketch(sid) }
            return out
        }
        if case .sketchLine(let sid, _)? = selection.first {
            add(String(localized: "Edit Sketch"), "pencil") { self.editSketch(sid) }
            return out
        }
        if !selectedEdges.isEmpty { addTool(.fillet); addTool(.chamfer) }
        if let (body, face) = selectedFaces.first {
            if face.isPlanar {
                add(String(localized: "Sketch"), "pencil.and.outline") { self.startSketch() }
                addTool(.pushPull); addTool(.hole); addTool(.text)
                add(String(localized: "Lay flat"), "arrow.down.to.line") { self.layFlat() }
            }
            add(String(localized: "Round edges"), ToolKind.fillet.icon) { self.start(.fillet) }
            addTool(.shell)
            let id = body.id
            add(String(localized: "Select Body"), "cube.fill") { self.selection = [.body(id)] }
        }
        let bodies = selection.compactMap { if case .body(let b) = $0 { return b } else { return nil } }
        if !bodies.isEmpty {
            addTool(.move); addTool(.mirror); addTool(.pattern); addTool(.shell)
            if bodies.count >= 2 { addTool(.combine) }
            addTool(.split)
            add(String(localized: "Delete"), "trash") { self.deleteSelectedBodies() }
        }
        return out
    }

    // MARK: - Keyboard

    func viewportKey(_ key: ViewportKey) -> Bool {
        switch key {
        case .escape:
            if sketch != nil { cancelSketchAction() }
            else if tool != nil { cancelTool() }
            else { selection = [] }
            return true
        case .delete:
            if sketch != nil { deleteSketchSelection(); return true }
            if !selectedBodies.isEmpty && selection.allSatisfy({ if case .body = $0 { return true } else { return false } }) {
                deleteSelectedBodies(); return true
            }
            return false
        case .enter:
            if sketch?.editingDimension != nil { return false }
            if tool != nil { applyTool(); return true }
            if sketch != nil { finishSketch(); return true }
            return false
        case .space:
            return repeatLastTool()
        case .arrow(let dx, let dy):
            orbitStep(dx: dx, dy: dy)
            return true
        case .character(let c):
            return letterKey(c)
        }
    }

    /// Single-letter tools (BAUPLAN 6.3). Only the 3D view answers them, so typing into a number field never starts a tool.
    private func letterKey(_ c: Character) -> Bool {
        if sketch?.editingDimension != nil { return false }
        if c == "k" { if sketch == nil { if tool != nil { cancelTool() }; startSketch() }; return true }
        if let t = SketchTool.allCases.first(where: { $0.shortcut?.character == c }) {
            // In a sketch: same as tapping the toolbar button (pressing the active tool again stops it).
            if let s = sketch {
                if s.tool == t { cancelSketchAction() } else { setSketchTool(t) }
                return true
            }
            // Outside a sketch, a drawing key opens a new sketch with that tool.
            guard t != .select, t != .dimension else { return false }
            if tool != nil { cancelTool() }
            startSketch()
            setSketchTool(t)
            return true
        }
        switch c {
        case "e": start(.extrude)
        case "f":
            // Fillet the selected edges (or a face's edges); with nothing to round, fit the view.
            if sketch == nil && (!selectedEdges.isEmpty || !selectedFaces.isEmpty) { start(.fillet) } else { fitView() }
        case "h": start(.hole)
        case "m": start(.measure)
        default: return false
        }
        return true
    }

    /// Space: back to the last drawing tool in a sketch, or the tool of the newest timeline step.
    private func repeatLastTool() -> Bool {
        if let s = sketch {
            guard s.editingDimension == nil else { return false }
            if s.tool == .select { setSketchTool(s.lastDrawTool) }
            return true
        }
        guard tool == nil, let f = design.features.last(where: { $0.kind != .deleteBody && $0.kind != .importBody }) else { return false }
        if f.kind == .sketch { startSketch(); return true }
        guard let k = toolKind(for: f) else { return false }
        start(k)
        return true
    }

    private func toolKind(for f: Feature) -> ToolKind? {
        switch f.operation {
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
    }

    /// Arrow keys turn the view in 15° steps, the same way as dragging.
    private func orbitStep(dx: Int, dy: Int) {
        guard let renderer else { return }
        var cam = renderer.camera
        let step = Double.pi / 12
        cam.yaw -= Double(dx) * step
        cam.pitch = min(max(cam.pitch + Double(dy) * step, -Camera.maxPitch), Camera.maxPitch)
        renderer.animate(to: cam, duration: 0.15)
    }
}
