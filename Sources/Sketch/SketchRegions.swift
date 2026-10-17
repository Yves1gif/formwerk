import Foundation

/// A closed area of a sketch that can be extruded: an outer loop and holes.
struct SketchRegion: Equatable {
    /// Outer loop counter-clockwise, holes clockwise.
    var loops: [[RegionSegment]]
    var area: Double
    /// A point inside the region (used to find the same region again after edits).
    var samplePoint: Vec2
    /// Flattened outline for drawing and point-in-region tests.
    var polygons: [[Vec2]]

    func contains(_ p: Vec2) -> Bool {
        guard let outer = polygons.first, Polygon.contains(outer, p) else { return false }
        return !polygons.dropFirst().contains { Polygon.contains($0, p) }
    }
}

/// One piece of a region boundary.
enum RegionSegment: Equatable {
    case line(Vec2, Vec2)
    /// Arc around `center` with `radius`, from angle `start` sweeping `sweep` (negative = clockwise).
    case arc(center: Vec2, radius: Double, start: Double, sweep: Double)

    var startPoint: Vec2 {
        switch self {
        case .line(let a, _): a
        case .arc(let c, let r, let s, _): c + Vec2(cos(s), sin(s)) * r
        }
    }

    var endPoint: Vec2 {
        switch self {
        case .line(_, let b): b
        case .arc(let c, let r, let s, let w): c + Vec2(cos(s + w), sin(s + w)) * r
        }
    }

    func point(at t: Double) -> Vec2 {
        switch self {
        case .line(let a, let b): a + (b - a) * t
        case .arc(let c, let r, let s, let w): c + Vec2(cos(s + w * t), sin(s + w * t)) * r
        }
    }

    var reversed: RegionSegment {
        switch self {
        case .line(let a, let b): .line(b, a)
        case .arc(let c, let r, let s, let w): .arc(center: c, radius: r, start: s + w, sweep: -w)
        }
    }

    var length: Double {
        switch self {
        case .line(let a, let b): (b - a).length
        case .arc(_, let r, _, let w): abs(w) * r
        }
    }

    /// Signed area contribution (shoelace of the chord plus the circular segment).
    var areaTerm: Double {
        let a = startPoint, b = endPoint
        var t = (a.x * b.y - b.x * a.y) / 2
        if case .arc(_, let r, _, let w) = self { t += r * r / 2 * (w - sin(w)) }
        return t
    }

    func flattened(maxStep: Double = .pi / 32) -> [Vec2] {
        switch self {
        case .line(let a, _): return [a]
        case .arc(_, _, _, let w):
            let n = max(2, Int(ceil(abs(w) / maxStep)))
            return (0..<n).map { point(at: Double($0) / Double(n)) }
        }
    }
}

enum Polygon {
    static func contains(_ poly: [Vec2], _ p: Vec2) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let x = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < x { inside.toggle() }
            }
            j = i
        }
        return inside
    }

    static func signedArea(_ poly: [Vec2]) -> Double {
        var s = 0.0
        for i in 0..<poly.count {
            let a = poly[i], b = poly[(i + 1) % poly.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }
}

/// Finds all closed regions formed by a sketch's (non-construction) curves:
/// splits curves where they cross, builds a planar graph, walks its faces and nests holes.
enum SketchRegions {
    static func find(in sketch: Sketch) -> [SketchRegion] {
        let curves = sketch.profileCurves.map { Piece(curve: $0, sketch: sketch) }
        if curves.isEmpty { return [] }

        // 1. Where does each curve get cut?
        var cuts = curves.map { $0.endParams }
        for i in 0..<curves.count {
            for j in (i + 1)..<curves.count {
                for (ti, tj) in Piece.intersections(curves[i], curves[j]) {
                    cuts[i].append(ti); cuts[j].append(tj)
                }
            }
        }

        // 2. Split into edges between merged vertices.
        var vertices: [Vec2] = []
        func vertex(_ p: Vec2) -> Int {
            if let i = vertices.firstIndex(where: { ($0 - p).length < 1e-6 }) { return i }
            vertices.append(p); return vertices.count - 1
        }
        var edges: [Edge] = []
        for (i, piece) in curves.enumerated() {
            let ts = Array(Set(cuts[i].map { ($0 * 1e9).rounded() / 1e9 })).sorted()
            var params = ts
            if piece.closed {
                // A full circle needs at least two vertices to form a loop.
                if params.count < 2 { params = [0, 0.5] }
                params.append(params[0] + 1)
            }
            for k in 0..<(params.count - 1) {
                let t0 = params[k], t1 = params[k + 1]
                if t1 - t0 < 1e-9 { continue }
                let seg = piece.segment(from: t0, to: t1)
                if seg.length < 1e-7 { continue }
                let a = vertex(seg.startPoint), b = vertex(seg.endPoint)
                if a == b && seg.length < 1e-5 { continue }
                edges.append(Edge(a: a, b: b, segment: seg))
            }
        }

        // 3. Remove dangling edges (open ends can't bound a region).
        var alive = [Bool](repeating: true, count: edges.count)
        var changed = true
        while changed {
            changed = false
            var degree = [Int](repeating: 0, count: vertices.count)
            for (i, e) in edges.enumerated() where alive[i] { degree[e.a] += 1; degree[e.b] += 1 }
            for (i, e) in edges.enumerated() where alive[i] && (degree[e.a] < 2 || degree[e.b] < 2) {
                alive[i] = false; changed = true
            }
        }

        // 4. Half-edges with their leaving direction at the start vertex.
        struct HalfEdge { let from: Int; let to: Int; let segment: RegionSegment; let angle: Double }
        var halves: [HalfEdge] = []
        for (i, e) in edges.enumerated() where alive[i] {
            for seg in [e.segment, e.segment.reversed] {
                let from = seg == e.segment ? e.a : e.b, to = seg == e.segment ? e.b : e.a
                // Direction towards a point a little along the curve: separates tangent curves.
                let step = min(0.05, 0.01 / max(seg.length, 1e-9))
                let dir = seg.point(at: step) - seg.startPoint
                halves.append(HalfEdge(from: from, to: to, segment: seg, angle: dir.angle))
            }
        }
        var outgoing = [[Int]](repeating: [], count: vertices.count)
        for (i, h) in halves.enumerated() { outgoing[h.from].append(i) }
        for v in outgoing.indices { outgoing[v].sort { halves[$0].angle < halves[$1].angle } }

        // twin index: halves come in pairs (2k, 2k+1)
        func twin(_ i: Int) -> Int { i ^ 1 }

        // 5. Walk faces: from each half-edge, turn to the next edge clockwise from the way back.
        var used = [Bool](repeating: false, count: halves.count)
        var cycles: [[RegionSegment]] = []
        for start in halves.indices where !used[start] {
            var cycle: [RegionSegment] = []
            var h = start
            var guardCount = 0
            while !used[h] && guardCount < halves.count + 1 {
                used[h] = true
                cycle.append(halves[h].segment)
                let v = halves[h].to
                let back = twin(h)
                let ring = outgoing[v]
                guard let pos = ring.firstIndex(of: back) else { break }
                // previous in CCW order = first clockwise
                h = ring[(pos - 1 + ring.count) % ring.count]
                guardCount += 1
            }
            if h == start && !cycle.isEmpty { cycles.append(cycle) }
        }

        // 6. Counter-clockwise cycles are region outlines; clockwise ones are outlines of islands seen from outside.
        struct Loop { let segments: [RegionSegment]; let area: Double; let polygon: [Vec2] }
        let loops = cycles.map { segs -> Loop in
            let area = segs.reduce(0) { $0 + $1.areaTerm }
            return Loop(segments: segs, area: area, polygon: segs.flatMap { $0.flattened() })
        }
        let outers = loops.filter { $0.area > 1e-9 }
        let islands = loops.filter { $0.area < -1e-9 }

        var holes = [[Loop]](repeating: [], count: outers.count)
        for island in islands {
            guard let probe = island.polygon.first else { continue }
            // The smallest outline around the island. Faces of the island itself are never larger than it.
            var best: Int? = nil
            for (i, o) in outers.enumerated() where o.area > -island.area + 1e-9 {
                if Polygon.contains(o.polygon, probe), best == nil || o.area < outers[best!].area { best = i }
            }
            if let b = best { holes[b].append(island) }
        }

        return outers.enumerated().map { i, o in
            let holeLoops = holes[i]
            let polys = [o.polygon] + holeLoops.map { $0.polygon }
            let area = o.area + holeLoops.reduce(0) { $0 + $1.area }
            return SketchRegion(loops: [o.segments] + holeLoops.map { $0.segments },
                                area: area,
                                samplePoint: interiorPoint(polys),
                                polygons: polys)
        }
        .sorted { $0.area > $1.area }
    }

    /// A point well inside a region: the middle of the widest inside span on a few scanlines.
    static func interiorPoint(_ polys: [[Vec2]]) -> Vec2 {
        guard let outer = polys.first, !outer.isEmpty else { return .zero }
        let ys = outer.map(\.y)
        let y0 = ys.min()!, y1 = ys.max()!
        var best = (width: -1.0, point: outer[0])
        for k in 1...9 {
            let y = y0 + (y1 - y0) * Double(k) / 10 + 1e-7
            var xs: [Double] = []
            for poly in polys {
                for i in 0..<poly.count {
                    let a = poly[i], b = poly[(i + 1) % poly.count]
                    if (a.y > y) != (b.y > y) { xs.append(a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x)) }
                }
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count {
                let w = xs[i + 1] - xs[i]
                if w > best.width { best = (w, Vec2((xs[i] + xs[i + 1]) / 2, y)) }
                i += 2
            }
        }
        return best.point
    }

    private struct Edge { let a: Int; let b: Int; let segment: RegionSegment }

    /// A sketch curve with a 0…1 parameter.
    private struct Piece {
        enum Shape { case line(Vec2, Vec2), arc(Vec2, Double, Double, Double) } // center, r, start, sweep
        let shape: Shape
        let closed: Bool

        init(curve c: SketchCurve, sketch s: Sketch) {
            switch c.kind {
            case .line:
                let (a, b) = s.lineEnds(c)
                shape = .line(a, b); closed = false
            case .circle:
                shape = .arc(s.position(c.a), c.radius, 0, 2 * .pi); closed = true
            case .arc:
                let (a0, w) = s.arcAngles(c)
                shape = .arc(s.position(c.a), s.radius(of: c), a0, w); closed = false
            }
        }

        var endParams: [Double] { closed ? [] : [0, 1] }

        func segment(from t0: Double, to t1: Double) -> RegionSegment {
            switch shape {
            case .line(let a, let b):
                return .line(a + (b - a) * t0, a + (b - a) * t1)
            case .arc(let c, let r, let s, let w):
                return .arc(center: c, radius: r, start: s + w * t0, sweep: w * (t1 - t0))
            }
        }

        /// Parameter of a point known to lie on the curve, or nil when outside its range.
        func param(of p: Vec2) -> Double? {
            switch shape {
            case .line(let a, let b):
                let d = b - a
                let t = (p - a).dot(d) / max(d.dot(d), 1e-18)
                return t >= -1e-9 && t <= 1 + 1e-9 ? min(max(t, 0), 1) : nil
            case .arc(let c, _, let s, let w):
                var ang = (p - c).angle - s
                while ang < -1e-9 { ang += 2 * .pi }
                while ang >= 2 * .pi - 1e-12 { ang -= 2 * .pi }
                if closed { return ang / (2 * .pi) }
                if ang <= w + 1e-9 { return min(ang / w, 1) }
                if abs(ang - 2 * .pi) < 1e-9 { return 0 }
                return nil
            }
        }

        static func intersections(_ p: Piece, _ q: Piece) -> [(Double, Double)] {
            var points: [Vec2] = []
            switch (p.shape, q.shape) {
            case let (.line(a, b), .line(c, d)):
                let r = b - a, s = d - c
                let den = r.cross(s)
                if abs(den) < 1e-12 {
                    // Overlapping collinear lines: their end points cut each other.
                    if abs((c - a).cross(r)) < 1e-9 * max(r.length, 1) { points = [a, b, c, d] }
                } else {
                    let t = (c - a).cross(s) / den
                    points = [a + r * t]
                }
            case let (.line(a, b), .arc(c, rad, _, _)), let (.arc(c, rad, _, _), .line(a, b)):
                points = lineCircle(a, b, c, rad)
            case let (.arc(c1, r1, _, _), .arc(c2, r2, _, _)):
                points = circleCircle(c1, r1, c2, r2)
            }
            var out: [(Double, Double)] = []
            for pt in points {
                if let t1 = p.param(of: pt), let t2 = q.param(of: pt) { out.append((t1, t2)) }
            }
            return out
        }

        static func lineCircle(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ r: Double) -> [Vec2] {
            let d = b - a, f = a - c
            let A = d.dot(d), B = 2 * f.dot(d), C = f.dot(f) - r * r
            var disc = B * B - 4 * A * C
            if disc < -1e-9 * max(A, 1) || A < 1e-18 { return [] }
            disc = max(disc, 0)
            let sq = disc.squareRoot()
            let t1 = (-B - sq) / (2 * A), t2 = (-B + sq) / (2 * A)
            return sq < 1e-12 ? [a + d * t1] : [a + d * t1, a + d * t2]
        }

        static func circleCircle(_ c1: Vec2, _ r1: Double, _ c2: Vec2, _ r2: Double) -> [Vec2] {
            let d = (c2 - c1).length
            if d < 1e-12 || d > r1 + r2 + 1e-9 || d < abs(r1 - r2) - 1e-9 { return [] }
            let a = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
            let h = max(r1 * r1 - a * a, 0).squareRoot()
            let m = c1 + (c2 - c1) * (a / d)
            let perp = (c2 - c1).perpendicular / d
            return h < 1e-12 ? [m] : [m + perp * h, m - perp * h]
        }
    }
}
