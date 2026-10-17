import Foundation

/// A 2D sketch: points, curves that use them, and constraints between them.
/// Point 0 is the sketch origin and is always fixed.
struct Sketch: Codable, Equatable {
    var points: [SketchPoint] = [SketchPoint(id: 0, x: 0, y: 0, fixed: true)]
    var curves: [SketchCurve] = []
    var constraints: [SketchConstraint] = []
    var nextID: Int = 1

    static let originID = 0

    mutating func newID() -> Int { defer { nextID += 1 }; return nextID }

    func point(_ id: Int) -> SketchPoint? { points.first { $0.id == id } }
    func curve(_ id: Int) -> SketchCurve? { curves.first { $0.id == id } }
    func constraint(_ id: Int) -> SketchConstraint? { constraints.first { $0.id == id } }

    func position(_ id: Int) -> Vec2 { point(id)?.position ?? .zero }

    mutating func setPosition(_ id: Int, _ p: Vec2) {
        if let i = points.firstIndex(where: { $0.id == id }) { points[i].x = p.x; points[i].y = p.y }
    }

    @discardableResult
    mutating func addPoint(_ p: Vec2) -> Int {
        let id = newID()
        points.append(SketchPoint(id: id, x: p.x, y: p.y))
        return id
    }

    @discardableResult
    mutating func addLine(_ a: Int, _ b: Int, construction: Bool = false) -> Int {
        let id = newID()
        curves.append(SketchCurve(id: id, kind: .line, a: a, b: b, construction: construction))
        return id
    }

    @discardableResult
    mutating func addCircle(center: Int, radius: Double, construction: Bool = false) -> Int {
        let id = newID()
        curves.append(SketchCurve(id: id, kind: .circle, a: center, radius: radius, construction: construction))
        return id
    }

    /// Arc around `center` from `start` counter-clockwise to `end`.
    @discardableResult
    mutating func addArc(center: Int, start: Int, end: Int, construction: Bool = false) -> Int {
        let id = newID()
        let r = (position(start) - position(center)).length
        curves.append(SketchCurve(id: id, kind: .arc, a: center, b: start, c: end, radius: r, construction: construction))
        return id
    }

    @discardableResult
    mutating func addConstraint(_ kind: ConstraintKind, _ refs: [Int], value: Double? = nil) -> Int {
        let id = newID()
        constraints.append(SketchConstraint(id: id, kind: kind, refs: refs, value: value))
        return id
    }

    /// Removes curves, points and constraints, and everything that depended on them.
    mutating func delete(points pointIDs: Set<Int>, curves curveIDs: Set<Int>, constraints constraintIDs: Set<Int>) {
        var deadPoints = pointIDs.subtracting([Sketch.originID])
        var deadCurves = curveIDs
        for c in curves where deadPoints.contains(c.a) || deadPoints.contains(c.b) || deadPoints.contains(c.c) {
            deadCurves.insert(c.id)
        }
        // Points that only belonged to deleted curves go too.
        let survivors = curves.filter { !deadCurves.contains($0.id) }
        let used = Set(survivors.flatMap { $0.pointIDs })
        for c in curves where deadCurves.contains(c.id) {
            for p in c.pointIDs where !used.contains(p) && p != Sketch.originID { deadPoints.insert(p) }
        }
        curves.removeAll { deadCurves.contains($0.id) }
        points.removeAll { deadPoints.contains($0.id) }
        let gone = deadPoints.union(deadCurves)
        constraints.removeAll { constraintIDs.contains($0.id) || $0.refs.contains(where: gone.contains) }
    }

    /// Curves that make up closed regions (construction curves don't).
    var profileCurves: [SketchCurve] { curves.filter { !$0.construction } }
}

struct SketchPoint: Codable, Equatable, Identifiable {
    var id: Int
    var x: Double
    var y: Double
    var fixed: Bool = false
    var position: Vec2 { Vec2(x, y) }
}

enum CurveKind: String, Codable { case line, circle, arc }

struct SketchCurve: Codable, Equatable, Identifiable {
    var id: Int
    var kind: CurveKind
    /// line: start; circle/arc: centre
    var a: Int
    /// line: end; arc: start point
    var b: Int = -1
    /// arc: end point
    var c: Int = -1
    /// circle radius (arcs keep it in sync with their points)
    var radius: Double = 0
    var construction: Bool = false

    var pointIDs: [Int] {
        switch kind {
        case .line: [a, b]
        case .circle: [a]
        case .arc: [a, b, c]
        }
    }
}

enum ConstraintKind: String, Codable, CaseIterable {
    // Geometric
    case coincident          // [p, q]
    case pointOnCurve        // [p, curve]
    case horizontal          // [line] or [p, q]
    case vertical            // [line] or [p, q]
    case parallel            // [line, line]
    case perpendicular       // [line, line]
    case equal               // [line, line] lengths or [circle/arc, circle/arc] radii
    case tangent             // [line, circle/arc] or [circle/arc, circle/arc]
    case concentric          // [circle/arc, circle/arc]
    case midpoint            // [p, line]
    case symmetric           // [p, q, line]
    case fix                 // [p]
    // Dimensions (have a value)
    case distance            // [p, q]
    case horizontalDistance  // [p, q]
    case verticalDistance    // [p, q]
    case length              // [line]
    case pointLineDistance   // [p, line]
    case radius              // [circle/arc]
    case diameter            // [circle/arc]
    case angle               // [line, line], value in radians

    var isDimension: Bool {
        switch self {
        case .distance, .horizontalDistance, .verticalDistance, .length, .pointLineDistance,
             .radius, .diameter, .angle: true
        default: false
        }
    }
}

struct SketchConstraint: Codable, Equatable, Identifiable {
    var id: Int
    var kind: ConstraintKind
    var refs: [Int]
    var value: Double?
    /// Where the dimension label sits, relative to the measured geometry (sketch units).
    var labelOffset: Vec2? = nil
}

// MARK: - Curve geometry helpers

extension Sketch {
    func lineEnds(_ c: SketchCurve) -> (Vec2, Vec2) { (position(c.a), position(c.b)) }

    func radius(of c: SketchCurve) -> Double {
        c.kind == .arc ? (position(c.b) - position(c.a)).length : c.radius
    }

    /// Start angle and counter-clockwise sweep of an arc.
    func arcAngles(_ c: SketchCurve) -> (start: Double, sweep: Double) {
        let center = position(c.a)
        let a0 = (position(c.b) - center).angle
        var a1 = (position(c.c) - center).angle
        while a1 <= a0 + 1e-12 { a1 += 2 * .pi }
        return (a0, a1 - a0)
    }

    /// Points along a curve for drawing.
    func polyline(_ c: SketchCurve, segments: Int = 64) -> [Vec2] {
        switch c.kind {
        case .line:
            let (p, q) = lineEnds(c); return [p, q]
        case .circle:
            let center = position(c.a)
            return (0...segments).map { i in
                let t = Double(i) / Double(segments) * 2 * .pi
                return center + Vec2(cos(t), sin(t)) * c.radius
            }
        case .arc:
            let center = position(c.a), r = radius(of: c)
            let (a0, sweep) = arcAngles(c)
            let n = max(4, Int(Double(segments) * sweep / (2 * .pi)))
            return (0...n).map { i in
                let t = a0 + sweep * Double(i) / Double(n)
                return center + Vec2(cos(t), sin(t)) * r
            }
        }
    }

    /// Distance from a point to a curve (for picking).
    func distance(from p: Vec2, to c: SketchCurve) -> Double {
        switch c.kind {
        case .line:
            let (a, b) = lineEnds(c)
            let d = b - a
            let t = max(0, min(1, (p - a).dot(d) / max(d.dot(d), 1e-12)))
            return (a + d * t - p).length
        case .circle:
            return abs((p - position(c.a)).length - c.radius)
        case .arc:
            let center = position(c.a), r = radius(of: c)
            let (a0, sweep) = arcAngles(c)
            var ang = (p - center).angle
            while ang < a0 { ang += 2 * .pi }
            if ang - a0 <= sweep { return abs((p - center).length - r) }
            let s = position(c.b), e = position(c.c)
            return min((p - s).length, (p - e).length)
        }
    }
}
