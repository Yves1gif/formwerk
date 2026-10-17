import Foundation

/// Rebuilds bodies from a design's feature list.
/// Keeps the state after every feature, so editing a late feature only rebuilds from there.
/// Not thread-safe: use it from one queue.
final class ModelBuilder {
    struct Body {
        let id: String
        let shape: Shape
    }

    enum Status: Equatable {
        case ok
        case warning(String)
        case error(String)

        var message: String? {
            switch self { case .ok: nil; case .warning(let m), .error(let m): m }
        }
    }

    struct SketchInfo {
        var plane: Plane
        var regions: [SketchRegion]
    }

    struct State {
        var bodies: [Body] = []
        var sketches: [UUID: SketchInfo] = [:]
        var statuses: [UUID: Status] = [:]

        func body(_ id: String) -> Body? { bodies.first { $0.id == id } }
        func bodyIndex(_ id: String) -> Int? { bodies.firstIndex { $0.id == id } }

        mutating func replace(_ id: String, with shape: Shape) {
            if let i = bodyIndex(id) { bodies[i] = Body(id: id, shape: shape) }
        }

        mutating func remove(_ id: String) { bodies.removeAll { $0.id == id } }
    }

    private var snapshots: [(hash: Int, state: State)] = []
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    /// Builds features [0, end). `end` = nil builds everything.
    func build(_ design: Design, upTo end: Int? = nil) -> State {
        let features = design.features
        let count = min(end ?? features.count, features.count)
        // Cumulative hash of the feature list: equal prefixes give equal states.
        var hashes: [Int] = []
        var h = Hasher()
        for f in features.prefix(count) {
            // Data's own hash only reads the first bytes, so hash every byte.
            ((try? encoder.encode(f)) ?? Data()).withUnsafeBytes { h.combine(bytes: $0) }
            if case .importBody(let imp) = f.operation {
                (design.importedShapes[imp.shapeKey] ?? Data()).withUnsafeBytes { h.combine(bytes: $0) }
            }
            hashes.append(h.finalize())
            var next = Hasher(); next.combine(hashes.last!); h = next
        }
        var start = 0
        while start < count, start < snapshots.count, snapshots[start].hash == hashes[start] { start += 1 }
        var state = start > 0 ? snapshots[start - 1].state : State()
        if snapshots.count > start { snapshots.removeSubrange(start...) }
        for i in start..<count {
            let f = features[i]
            if !f.suppressed {
                do {
                    try apply(f, to: &state, design: design)
                    if state.statuses[f.id] == nil { state.statuses[f.id] = .ok }
                } catch {
                    state.statuses[f.id] = .error(error.localizedDescription)
                }
            } else {
                state.statuses[f.id] = .ok
            }
            snapshots.append((hashes[i], state))
        }
        return state
    }

    func invalidate() { snapshots.removeAll() }

    // MARK: - Features

    private func apply(_ f: Feature, to s: inout State, design: Design) throws {
        let fid = f.id.uuidString
        switch f.operation {
        case .sketch(let sk):
            let (plane, warning) = try resolve(sk.plane, in: s)
            s.sketches[f.id] = SketchInfo(plane: plane, regions: SketchRegions.find(in: sk.sketch))
            if let warning { s.statuses[f.id] = .warning(warning) }

        case .extrude(let e):
            guard let info = s.sketches[e.sketch] else { throw KernelError(message: Msg.sketchMissing) }
            let profile = try profileShape(info, seeds: e.regionSeeds)
            let solid = try Kernel.extrude(profile, direction: info.plane.normal, distance: e.distance, symmetric: e.symmetric)
            try combine(solid, mode: e.mode, target: e.target, newID: fid, into: &s)

        case .revolve(let r):
            guard let info = s.sketches[r.sketch], let sketchFeature = design.feature(r.sketch)?.sketch else {
                throw KernelError(message: Msg.sketchMissing)
            }
            let profile = try profileShape(info, seeds: r.regionSeeds)
            var axisOrigin = info.plane.origin, axisDir = info.plane.yDir
            if let cid = r.axisCurve, let c = sketchFeature.sketch.curve(cid), c.kind == .line {
                let (a, b) = sketchFeature.sketch.lineEnds(c)
                axisOrigin = info.plane.world(a)
                axisDir = (info.plane.world(b) - axisOrigin).normalized
            }
            let solid = try Kernel.revolve(profile, axisOrigin: axisOrigin, axis: axisDir, angle: r.angle)
            try combine(solid, mode: r.mode, target: r.target, newID: fid, into: &s)

        case .pushPull(let p):
            let (body, face, warn) = try resolveFace(p.face, in: s)
            s.replace(body.id, with: try Kernel.pushPull(body.shape, face: face, distance: p.distance))
            if warn { s.statuses[f.id] = .warning(Msg.referenceMoved) }

        case .fillet(let e), .chamfer(let e):
            let isFillet = f.kind == .fillet
            var warned = false
            for (bodyID, refs) in Dictionary(grouping: e.edges, by: \.body) {
                guard let body = s.body(bodyID) else { throw KernelError(message: Msg.bodyMissing) }
                var indices: [Int] = []
                for r in refs {
                    let (idx, warn) = try resolveEdge(r, in: body.shape)
                    indices.append(idx); warned = warned || warn
                }
                let result = isFillet
                    ? try Kernel.fillet(body.shape, edges: indices, radius: e.value)
                    : try Kernel.chamfer(body.shape, edges: indices, distance: e.value)
                s.replace(bodyID, with: result)
            }
            if warned { s.statuses[f.id] = .warning(Msg.referenceMoved) }

        case .shell(let sh):
            guard let body = s.body(sh.body) else { throw KernelError(message: Msg.bodyMissing) }
            var faces: [Int] = []
            for r in sh.openFaces { faces.append(try resolveFace(r, in: body.shape).0) }
            s.replace(sh.body, with: try Kernel.shell(body.shape, openFaces: faces, thickness: sh.thickness))

        case .boolean(let b):
            guard var result = s.body(b.target)?.shape else { throw KernelError(message: Msg.bodyMissing) }
            for t in b.tools where t != b.target {
                guard let tool = s.body(t) else { continue }
                let op: Kernel.BoolOp = switch b.op { case .union: .union; case .subtract: .cut; case .intersect: .intersect }
                result = try Kernel.boolean(result, tool.shape, op)
            }
            s.replace(b.target, with: result)
            if !b.keepTools { for t in b.tools where t != b.target { s.remove(t) } }

        case .transform(let t):
            for (i, id) in t.bodies.enumerated() {
                guard let body = s.body(id) else { continue }
                let moved = try Kernel.transform(body.shape, translation: t.translation, axis: t.axis,
                                                 angle: t.angle, pivot: t.pivot, scale: t.uniformScale)
                if t.copy { s.bodies.append(Body(id: "\(fid)-\(i)", shape: moved)) } else { s.replace(id, with: moved) }
            }

        case .mirror(let m):
            let (plane, _) = try resolve(m.plane, in: s)
            for (i, id) in m.bodies.enumerated() {
                guard let body = s.body(id) else { continue }
                let mirrored = try Kernel.mirror(body.shape, plane: plane)
                if !m.keepOriginal {
                    s.replace(id, with: mirrored)
                } else if m.merge {
                    s.replace(id, with: try Kernel.boolean(body.shape, mirrored, .union))
                } else {
                    s.bodies.append(Body(id: "\(fid)-\(i)", shape: mirrored))
                }
            }

        case .pattern(let p):
            guard p.count > 1 else { return }
            for id in p.bodies {
                guard let body = s.body(id) else { continue }
                var merged = body.shape
                for k in 1..<p.count {
                    let copy: Shape
                    switch p.kind {
                    case .linear:
                        copy = try Kernel.transform(body.shape, translation: p.direction.normalized * (p.spacing * Double(k)))
                    case .circular:
                        let full = abs(abs(p.totalAngle) - 2 * .pi) < 1e-6
                        let step = p.totalAngle / Double(full ? p.count : p.count - 1)
                        copy = try Kernel.transform(body.shape, translation: .zero, axis: p.axis,
                                                    angle: step * Double(k), pivot: p.axisOrigin)
                    }
                    if p.merge { merged = try Kernel.boolean(merged, copy, .union) }
                    else { s.bodies.append(Body(id: "\(fid)-\(id)-\(k)", shape: copy)) }
                }
                if p.merge { s.replace(id, with: merged) }
            }

        case .hole(let hole):
            let (body, faceIndex, warn) = try resolveFace(hole.face, in: s)
            guard let info = body.shape.face(faceIndex), info.isPlanar else { throw KernelError(message: Msg.needsFlatFace) }
            let plane = Plane.onFace(normal: info.normal, through: info.centroid)
            var result = body.shape
            for p in hole.positions {
                let tool = try Kernel.holeTool(
                    at: plane.world(p), direction: -plane.normal, diameter: hole.diameter, depth: hole.depth,
                    counterbore: hole.kind == .counterbore ? (hole.headDiameter, hole.headDepth) : nil,
                    countersink: hole.kind == .countersink ? hole.headDiameter : nil)
                result = try Kernel.boolean(result, tool, .cut)
            }
            s.replace(body.id, with: result)
            if warn { s.statuses[f.id] = .warning(Msg.referenceMoved) }

        case .primitive(let p):
            let shape: Shape
            switch p.kind {
            case .box: shape = try Kernel.box(corner: p.origin, size: p.size)
            case .cylinder: shape = try Kernel.cylinder(base: p.origin, axis: Vec3(0, 0, 1), radius: p.size.x / 2, height: p.size.z)
            }
            s.bodies.append(Body(id: fid, shape: shape))

        case .text(let t):
            let (plane, _) = try resolve(t.plane, in: s)
            let loops = TextOutline.regions(for: t.text, fontName: t.fontName, size: t.size, at: t.position)
            guard !loops.isEmpty else { throw KernelError(message: Msg.textEmpty) }
            let faces = try loops.map { try Kernel.face(on: plane, loops: $0) }
            let profile = Kernel.compound(faces)
            switch t.mode {
            case .cut:
                // Engrave: from just above the face down into the body.
                let tool = try Kernel.extrude(profile, direction: -plane.normal, distance: t.depth)
                try combine(tool, mode: .cut, target: t.target, newID: fid, into: &s)
            default:
                let solid = try Kernel.extrude(profile, direction: plane.normal, distance: t.depth)
                try combine(solid, mode: t.mode, target: t.target, newID: fid, into: &s)
            }

        case .importBody(let imp):
            guard let data = design.importedShapes[imp.shapeKey] else { throw KernelError(message: Msg.importMissing) }
            let shape = try Kernel.shape(fromBREP: data)
            let solids = shape.solids()
            if solids.count <= 1 {
                s.bodies.append(Body(id: fid, shape: shape))
            } else {
                for (i, solid) in solids.enumerated() { s.bodies.append(Body(id: i == 0 ? fid : "\(fid)-\(i)", shape: solid)) }
            }

        case .deleteBody(let d):
            for id in d.bodies { s.remove(id) }

        case .split(let sp):
            guard let body = s.body(sp.body) else { throw KernelError(message: Msg.bodyMissing) }
            let (plane, _) = try resolve(sp.plane, in: s)
            let pieces = try Kernel.split(body.shape, plane: plane).solids()
            guard pieces.count > 1 else { throw KernelError(message: Msg.splitMissed) }
            s.replace(sp.body, with: pieces[0])
            for (i, piece) in pieces.dropFirst().enumerated() { s.bodies.append(Body(id: "\(fid)-\(i + 1)", shape: piece)) }
        }
    }

    /// The faces of the chosen sketch regions, combined.
    private func profileShape(_ info: SketchInfo, seeds: [Vec2]) throws -> Shape {
        var chosen: [SketchRegion] = []
        for seed in seeds {
            // The smallest region around the seed (regions don't overlap, but be safe).
            if let r = info.regions.filter({ $0.contains(seed) }).min(by: { $0.area < $1.area }), !chosen.contains(r) {
                chosen.append(r)
            }
        }
        guard !chosen.isEmpty else { throw KernelError(message: Msg.regionMissing) }
        let faces = try chosen.map { try Kernel.face(on: info.plane, loops: $0.loops) }
        return faces.count == 1 ? faces[0] : Kernel.compound(faces)
    }

    private func combine(_ solid: Shape, mode: BodyMode, target: String?, newID: String, into s: inout State) throws {
        if mode == .newBody || s.bodies.isEmpty {
            if mode == .newBody || mode == .join { s.bodies.append(Body(id: newID, shape: solid)) }
            else if s.bodies.isEmpty { throw KernelError(message: Msg.nothingToCut) }
            return
        }
        let targets: [Body]
        if let target, let body = s.body(target) {
            targets = [body]
        } else {
            // Every body the new solid touches.
            let box = solid.properties.bounds
            targets = s.bodies.filter { overlaps($0.shape.properties.bounds, box) }
        }
        if targets.isEmpty {
            if mode == .join { s.bodies.append(Body(id: newID, shape: solid)); return }
            throw KernelError(message: Msg.nothingToCut)
        }
        for body in targets {
            let op: Kernel.BoolOp = switch mode { case .cut: .cut; case .intersect: .intersect; default: .union }
            s.replace(body.id, with: try Kernel.boolean(body.shape, solid, op))
            if mode == .join { break } // join into one body only
        }
    }

    private func overlaps(_ a: Box3, _ b: Box3) -> Bool {
        let eps = 1e-6
        return a.min.x <= b.max.x + eps && b.min.x <= a.max.x + eps &&
            a.min.y <= b.max.y + eps && b.min.y <= a.max.y + eps &&
            a.min.z <= b.max.z + eps && b.min.z <= a.max.z + eps
    }

    // MARK: - Reference resolution

    func resolve(_ ref: PlaneRef, in s: State) throws -> (Plane, String?) {
        switch ref {
        case .origin(let p, let offset):
            return (p.plane.offset(by: offset), nil)
        case .face(let fr):
            let (body, index, warn) = try resolveFace(fr, in: s)
            guard let info = body.shape.face(index), info.isPlanar else { throw KernelError(message: Msg.needsFlatFace) }
            return (Plane.onFace(normal: info.normal, through: info.centroid), warn ? Msg.referenceMoved : nil)
        }
    }

    func resolveFace(_ ref: FaceRef, in s: State) throws -> (Body, Int, Bool) {
        guard let body = s.body(ref.body) else { throw KernelError(message: Msg.bodyMissing) }
        let (index, warn) = try resolveFace(ref, in: body.shape)
        return (body, index, warn)
    }

    /// Finds the face that looks most like the reference. Returns its index and whether the match is doubtful
    /// (another face fits almost as well).
    func resolveFace(_ ref: FaceRef, in shape: Shape) throws -> (Int, Bool) {
        let scale = max(shape.properties.bounds.diagonal, 1)
        let scored = shape.faces.map { f -> (Int, Double) in
            var score = (f.centroid - ref.centroid).length / scale * 10
            score += (1 - f.normal.dot(ref.normal)) * 5
            score += min(abs(f.area - ref.area) / max(ref.area, 1e-6), 2)
            score += abs(f.radius - ref.radius) / max(ref.radius, 1)
            if f.kind.rawValue != ref.kind { score += 100 }
            return (f.index, score)
        }
        return try pick(scored, missing: Msg.faceMissing)
    }

    func resolveEdge(_ ref: EdgeRef, in shape: Shape) throws -> (Int, Bool) {
        let scale = max(shape.properties.bounds.diagonal, 1)
        let scored = shape.edges.map { e -> (Int, Double) in
            let ends = min((e.start - ref.start).length + (e.end - ref.end).length,
                           (e.start - ref.end).length + (e.end - ref.start).length)
            var score = (e.midpoint - ref.midpoint).length / scale * 10 + ends / scale * 5
            score += min(abs(e.length - ref.length) / max(ref.length, 1e-6), 2)
            score += abs(e.radius - ref.radius) / max(ref.radius, 1)
            if e.kind.rawValue != ref.kind { score += 100 }
            if !ref.faceKinds.isEmpty {
                // The faces on both sides say a lot about which edge this is.
                let n = shape.neighbours(ofEdge: e.index)
                if n.map(\.kind).sorted() != ref.faceKinds.sorted() { score += 20 }
                for rn in ref.faceNormals {
                    let best = n.map { $0.normal.dot(rn) }.max() ?? -1
                    score += (1 - best) * 3
                }
            }
            return (e.index, score)
        }
        return try pick(scored, missing: Msg.edgeMissing)
    }

    private func pick(_ scored: [(Int, Double)], missing: String) throws -> (Int, Bool) {
        let sorted = scored.sorted { $0.1 < $1.1 }
        guard let best = sorted.first, best.1 < 100 else { throw KernelError(message: missing) }
        let second = sorted.count > 1 ? sorted[1].1 : .infinity
        let doubtful = best.1 > 8 || second - best.1 < max(0.5, best.1 * 0.25)
        return (best.0, doubtful && best.1 > 0.05)
    }
}

extension FaceRef {
    init(body: String, info f: FaceInfo) {
        self.init(body: body, kind: f.kind.rawValue, centroid: f.centroid, normal: f.normal, area: f.area, radius: f.radius)
    }
}

extension EdgeRef {
    init(body: String, shape: Shape, info e: EdgeInfo) {
        let n = shape.neighbours(ofEdge: e.index)
        self.init(body: body, kind: e.kind.rawValue, midpoint: e.midpoint, start: e.start, end: e.end,
                  length: e.length, radius: e.radius, faceKinds: n.map(\.kind), faceNormals: n.map(\.normal))
    }
}

/// Error texts from the builder, localised.
enum Msg {
    static var sketchMissing: String { String(localized: "The sketch for this step is missing.") }
    static var bodyMissing: String { String(localized: "The body for this step no longer exists.") }
    static var regionMissing: String { String(localized: "The chosen sketch area no longer exists. Edit the step and pick it again.") }
    static var referenceMoved: String { String(localized: "The model changed a lot here. Check that this step still uses the right face or edge.") }
    static var needsFlatFace: String { String(localized: "This needs a flat face.") }
    static var faceMissing: String { String(localized: "The face for this step can't be found any more.") }
    static var edgeMissing: String { String(localized: "The edge for this step can't be found any more.") }
    static var nothingToCut: String { String(localized: "There is no body here to cut from.") }
    static var textEmpty: String { String(localized: "Enter some text.") }
    static var importMissing: String { String(localized: "The imported file is missing from this design.") }
    static var splitMissed: String { String(localized: "The plane doesn't cut through this body.") }
}
