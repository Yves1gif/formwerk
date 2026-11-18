import Foundation

/// Edits that change a sketch's geometry: trim, offset, round corner and mirror.
/// Plain functions on `Sketch` values (no UI), so they can be unit-tested.
/// None of them solves the sketch; the caller does that (`EditorModel.changeSketch`).
enum SketchEdit {
    enum EditError: Error, Equatable {
        /// Offset: the chosen curves don't form chains or loops.
        case notAChain
        /// Offset or round corner: the distance or radius doesn't fit the shape.
        case tooBig
        /// Round corner: the point is not where exactly two lines meet.
        case notACorner
    }

    // MARK: - Curves as plain geometry

    /// A sketch curve with a parameter: lines 0…1, arcs the angle from their start (0…sweep),
    /// circles the absolute angle (0…2π).
    enum CurveShape: Equatable {
        case line(Vec2, Vec2)
        /// Counter-clockwise from `start` by `sweep` (> 0).
        case arc(center: Vec2, radius: Double, start: Double, sweep: Double)
        case circle(center: Vec2, radius: Double)

        var center: Vec2? {
            switch self {
            case .line: nil
            case .arc(let c, _, _, _), .circle(let c, _): c
            }
        }

        var radius: Double {
            switch self {
            case .line: 0
            case .arc(_, let r, _, _), .circle(_, let r): r
            }
        }

        /// End of the parameter range.
        var range: Double {
            switch self {
            case .line: 1
            case .arc(_, _, _, let w): w
            case .circle: 2 * .pi
            }
        }

        /// How much parameter is one sketch unit along the curve (for tolerances).
        var paramPerUnit: Double {
            switch self {
            case .line(let a, let b): 1 / max((b - a).length, 1e-9)
            case .arc(_, let r, _, _), .circle(_, let r): 1 / max(r, 1e-9)
            }
        }

        func point(at t: Double) -> Vec2 {
            switch self {
            case .line(let a, let b): a + (b - a) * t
            case .arc(let c, let r, let s, _): c + Vec2(cos(s + t), sin(s + t)) * r
            case .circle(let c, let r): c + Vec2(cos(t), sin(t)) * r
            }
        }

        /// The parameter of a point known to lie on the curve's line or circle, or nil when it is
        /// outside the curve's range.
        func parameter(of p: Vec2) -> Double? {
            switch self {
            case .line(let a, let b):
                let d = b - a
                let len2 = d.dot(d)
                guard len2 > 1e-18 else { return nil }
                let t = (p - a).dot(d) / len2
                let tol = 1e-7 / len2.squareRoot()
                return t >= -tol && t <= 1 + tol ? min(max(t, 0), 1) : nil
            case .arc(let c, let r, let s, let w):
                let ang = SketchEdit.angle0to2pi((p - c).angle - s)
                let tol = 1e-7 / max(r, 1e-9)
                if ang <= w + tol { return min(ang, w) }
                if ang >= 2 * .pi - tol { return 0 }
                return nil
            case .circle(let c, _):
                return SketchEdit.angle0to2pi((p - c).angle)
            }
        }

        /// The parameter of the curve point closest to `p`.
        func closestParameter(to p: Vec2) -> Double {
            switch self {
            case .line(let a, let b):
                let d = b - a
                return max(0, min(1, (p - a).dot(d) / max(d.dot(d), 1e-18)))
            case .arc(let c, _, let s, let w):
                let ang = SketchEdit.angle0to2pi((p - c).angle - s)
                if ang <= w { return ang }
                return (ang - w) < (2 * .pi - ang) ? w : 0
            case .circle(let c, _):
                return SketchEdit.angle0to2pi((p - c).angle)
            }
        }

        /// Points along the curve between two parameters (for drawing a preview).
        func polyline(from t0: Double, to t1: Double) -> [Vec2] {
            switch self {
            case .line: return [point(at: t0), point(at: t1)]
            case .arc, .circle:
                let n = max(2, Int(ceil(abs(t1 - t0) / (.pi / 32))))
                return (0...n).map { point(at: t0 + (t1 - t0) * Double($0) / Double(n)) }
            }
        }
    }

    static func shape(_ c: SketchCurve, in sk: Sketch) -> CurveShape {
        switch c.kind {
        case .line:
            let (a, b) = sk.lineEnds(c)
            return .line(a, b)
        case .circle:
            return .circle(center: sk.position(c.a), radius: c.radius)
        case .arc:
            let (s, w) = sk.arcAngles(c)
            return .arc(center: sk.position(c.a), radius: sk.radius(of: c), start: s, sweep: w)
        }
    }

    static func angle0to2pi(_ a: Double) -> Double {
        var x = a.truncatingRemainder(dividingBy: 2 * .pi)
        if x < 0 { x += 2 * .pi }
        if x >= 2 * .pi { x -= 2 * .pi }
        return x
    }

    /// An angle folded into (-π, π].
    static func signedAngle(_ a: Double) -> Double {
        var x = angle0to2pi(a)
        if x > .pi { x -= 2 * .pi }
        return x
    }

    /// Where two curves cross (only points inside both curves' ranges).
    static func intersections(_ p: CurveShape, _ q: CurveShape) -> [Vec2] {
        let candidates: [Vec2]
        switch (p, q) {
        case let (.line(a, b), .line(c, d)):
            candidates = lineLine(a, b, c, d)
        case let (.line(a, b), _):
            candidates = lineCircle(a, b, q.center!, q.radius)
        case let (_, .line(a, b)):
            candidates = lineCircle(a, b, p.center!, p.radius)
        default:
            candidates = circleCircle(p.center!, p.radius, q.center!, q.radius)
        }
        return candidates.filter { p.parameter(of: $0) != nil && q.parameter(of: $0) != nil }
    }

    /// Crossing of two infinite lines; for overlapping collinear lines, the end points.
    static func lineLine(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ d: Vec2) -> [Vec2] {
        let r = b - a, s = d - c
        let den = r.cross(s)
        if abs(den) < 1e-12 * max(r.length * s.length, 1e-12) {
            if abs((c - a).cross(r)) < 1e-9 * max(r.length, 1) { return [a, b, c, d] }
            return []
        }
        let t = (c - a).cross(s) / den
        return [a + r * t]
    }

    static func lineCircle(_ a: Vec2, _ b: Vec2, _ c: Vec2, _ r: Double) -> [Vec2] {
        let d = b - a, f = a - c
        let A = d.dot(d), B = 2 * f.dot(d), C = f.dot(f) - r * r
        if A < 1e-18 { return [] }
        var disc = B * B - 4 * A * C
        if disc < -1e-9 * max(A * r * r, 1e-12) { return [] }
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
        return h < 1e-9 ? [m] : [m + perp * h, m - perp * h]
    }

    // MARK: - Trim

    /// A place where another curve cuts the trimmed curve.
    struct Cut: Equatable {
        var t: Double
        /// The curve that cuts here.
        var by: Int
    }

    /// Which piece of a curve a tap removes.
    struct TrimPlan: Equatable {
        var curve: Int
        var shape: CurveShape
        /// The piece runs from `lo` to `hi` (nil = the curve's own start/end).
        /// Circles: counter-clockwise from `lo` to `hi`. Both nil: the whole curve goes.
        var lo: Cut?
        var hi: Cut?

        var removesWholeCurve: Bool { lo == nil && hi == nil }

        /// The piece that would be removed, for a hover preview.
        var removedPiece: [Vec2] {
            switch shape {
            case .circle:
                guard let lo, let hi else { return shape.polyline(from: 0, to: 2 * .pi) }
                var end = hi.t
                while end <= lo.t { end += 2 * .pi }
                return shape.polyline(from: lo.t, to: end)
            default:
                return shape.polyline(from: lo?.t ?? 0, to: hi?.t ?? shape.range)
            }
        }
    }

    /// Finds the piece of curve `id` between the nearest crossings around `tap`.
    /// All other curves (construction lines too) count as cutting edges.
    static func trimPlan(_ sk: Sketch, curve id: Int, near tap: Vec2) -> TrimPlan? {
        guard let c = sk.curve(id) else { return nil }
        let me = shape(c, in: sk)
        var cuts: [Cut] = []
        for o in sk.curves where o.id != id {
            for p in intersections(me, shape(o, in: sk)) {
                if let t = me.parameter(of: p) { cuts.append(Cut(t: t, by: o.id)) }
            }
        }
        let eps = 1e-6 * me.paramPerUnit
        let tapT = me.closestParameter(to: tap)
        switch me {
        case .circle:
            var ts: [Cut] = []
            for cut in cuts.sorted(by: { $0.t < $1.t }) where ts.last.map({ cut.t - $0.t > eps }) ?? true {
                ts.append(cut)
            }
            if ts.count > 1, ts[0].t + 2 * .pi - ts[ts.count - 1].t < eps { ts.removeLast() }
            guard ts.count >= 2 else { return TrimPlan(curve: id, shape: me, lo: nil, hi: nil) }
            let hi = ts.first { $0.t > tapT } ?? ts[0]
            let lo = ts.last { $0.t <= tapT } ?? ts[ts.count - 1]
            return TrimPlan(curve: id, shape: me, lo: lo, hi: hi)
        default:
            let inner = cuts.filter { $0.t > eps && $0.t < me.range - eps }
            let lo = inner.filter { $0.t < tapT }.max { $0.t < $1.t }
            let hi = inner.filter { $0.t > tapT }.min { $0.t < $1.t }
            return TrimPlan(curve: id, shape: me, lo: lo, hi: hi)
        }
    }

    /// Removes the piece of curve `id` around `tap` (between its nearest crossings with other curves).
    /// A curve that nothing crosses is deleted. New end points stay on the curve that cut them.
    /// Constraints that no longer make sense (length, equal length, midpoint) are dropped.
    static func trim(_ input: Sketch, curve id: Int, near tap: Vec2) -> Sketch? {
        guard let plan = trimPlan(input, curve: id, near: tap), let c = input.curve(id) else { return nil }
        var sk = input
        if plan.removesWholeCurve {
            sk.delete(points: [], curves: [id], constraints: [])
            return sk
        }
        let me = plan.shape
        switch c.kind {
        case .circle:
            guard let lo = plan.lo, let hi = plan.hi else { return nil }
            // What stays is the arc from `hi` counter-clockwise to `lo`.
            let start = cutPoint(&sk, at: me.point(at: hi.t), cutter: hi.by)
            let end = cutPoint(&sk, at: me.point(at: lo.t), cutter: lo.by)
            guard start != end, let i = sk.curves.firstIndex(where: { $0.id == id }) else { return nil }
            sk.curves[i].kind = .arc
            sk.curves[i].b = start
            sk.curves[i].c = end
            return sk

        case .line, .arc:
            let startID = c.kind == .line ? c.a : c.b
            let endID = c.kind == .line ? c.b : c.c
            switch (plan.lo, plan.hi) {
            case (nil, let hi?):
                let p = cutPoint(&sk, at: me.point(at: hi.t), cutter: hi.by)
                setEnd(&sk, id, start: true, to: p)
                dropShapeConstraints(&sk, id)
                removeIfUnused(&sk, startID)
            case (let lo?, nil):
                let p = cutPoint(&sk, at: me.point(at: lo.t), cutter: lo.by)
                setEnd(&sk, id, start: false, to: p)
                dropShapeConstraints(&sk, id)
                removeIfUnused(&sk, endID)
            case (let lo?, let hi?):
                // Split: this curve keeps start…lo, a new curve gets hi…end.
                let p1 = cutPoint(&sk, at: me.point(at: lo.t), cutter: lo.by)
                let p2 = cutPoint(&sk, at: me.point(at: hi.t), cutter: hi.by)
                setEnd(&sk, id, start: false, to: p1)
                dropShapeConstraints(&sk, id)
                if c.kind == .line {
                    let n = sk.addLine(p2, endID, construction: c.construction)
                    // Keep both pieces on one line.
                    let copied = sk.constraints.filter { ($0.kind == .horizontal || $0.kind == .vertical) && $0.refs == [id] }
                    for k in copied { sk.addConstraint(k.kind, [n]) }
                    if copied.isEmpty { sk.addConstraint(.parallel, [id, n]) }
                    sk.addConstraint(.pointOnCurve, [p2, id])
                } else {
                    let n = sk.addArc(center: c.a, start: p2, end: endID, construction: c.construction)
                    sk.addConstraint(.equal, [id, n])
                }
            case (nil, nil):
                break
            }
            return sk
        }
    }

    /// The point for a new curve end at `pos`: an existing curve point there, or a new point
    /// that stays on the cutting curve.
    private static func cutPoint(_ sk: inout Sketch, at pos: Vec2, cutter: Int) -> Int {
        var used = Set<Int>()
        for c in sk.curves where c.kind != .circle {
            let (s, e) = ends(c)
            used.insert(s); used.insert(e)
        }
        if let existing = sk.points.first(where: { used.contains($0.id) && ($0.position - pos).length < 1e-6 }) {
            return existing.id
        }
        let p = sk.addPoint(pos)
        if sk.curve(cutter) != nil { sk.addConstraint(.pointOnCurve, [p, cutter]) }
        return p
    }

    private static func setEnd(_ sk: inout Sketch, _ id: Int, start: Bool, to p: Int) {
        guard let i = sk.curves.firstIndex(where: { $0.id == id }) else { return }
        switch (sk.curves[i].kind, start) {
        case (.line, true): sk.curves[i].a = p
        case (.line, false): sk.curves[i].b = p
        case (.arc, true): sk.curves[i].b = p
        case (.arc, false): sk.curves[i].c = p
        case (.circle, _): break
        }
    }

    /// Constraints that measured the old extent of a line (its length, equal length, its midpoint).
    private static func dropShapeConstraints(_ sk: inout Sketch, _ id: Int) {
        guard let c = sk.curve(id), c.kind == .line else { return }
        sk.constraints.removeAll { k in
            switch k.kind {
            case .length: return k.refs == [id]
            case .equal: return k.refs.contains(id)
            case .midpoint: return k.refs.count == 2 && k.refs[1] == id
            default: return false
            }
        }
    }

    private static func removeIfUnused(_ sk: inout Sketch, _ p: Int) {
        guard p != Sketch.originID, !sk.curves.contains(where: { $0.pointIDs.contains(p) }) else { return }
        sk.delete(points: [p], curves: [], constraints: [])
    }

    // MARK: - Round corner (sketch fillet)

    struct Corner {
        var point: Int
        var lines: (SketchCurve, SketchCurve)
        /// The far ends of the two lines.
        var ends: (Int, Int)
        var position: Vec2
        var directions: (Vec2, Vec2)
        var lengths: (Double, Double)
        /// Angle between the two lines (0…π).
        var angle: Double

        var maxRadius: Double { min(lengths.0, lengths.1) * tan(angle / 2) }
    }

    /// A point where exactly two lines (and nothing else) meet, at a real corner.
    static func corner(_ sk: Sketch, at pid: Int) -> Corner? {
        let users = sk.curves.filter { $0.pointIDs.contains(pid) }
        guard users.count == 2, users.allSatisfy({ $0.kind == .line && $0.a != $0.b }) else { return nil }
        let l1 = users[0], l2 = users[1]
        let e1 = l1.a == pid ? l1.b : l1.a, e2 = l2.a == pid ? l2.b : l2.a
        let p = sk.position(pid)
        let d1 = sk.position(e1) - p, d2 = sk.position(e2) - p
        guard d1.length > 1e-9, d2.length > 1e-9 else { return nil }
        let u1 = d1.normalized, u2 = d2.normalized
        let angle = acos(max(-1, min(1, u1.dot(u2))))
        guard angle > 0.01, angle < .pi - 0.01 else { return nil }
        return Corner(point: pid, lines: (l1, l2), ends: (e1, e2), position: p, directions: (u1, u2),
                      lengths: (d1.length, d2.length), angle: angle)
    }

    struct RoundedCorner {
        var sketch: Sketch
        var arc: Int
        /// The radius dimension, ready for typing.
        var dimension: Int
    }

    /// Rounds the corner at `pid` with a tangent arc. The lines get shorter and stay tangent;
    /// the old corner stays as a loose point on both lines, so dimensions to it keep working.
    static func roundCorner(_ input: Sketch, at pid: Int, radius r: Double) -> Result<RoundedCorner, EditError> {
        guard let k = corner(input, at: pid) else { return .failure(.notACorner) }
        guard r > 1e-6 else { return .failure(.tooBig) }
        let t = r / tan(k.angle / 2)
        guard t < k.lengths.0 - 1e-6, t < k.lengths.1 - 1e-6 else { return .failure(.tooBig) }
        let (u1, u2) = k.directions
        let p = k.position
        let tp1 = p + u1 * t, tp2 = p + u2 * t
        let center = p + (u1 + u2).normalized * (r / sin(k.angle / 2))

        var sk = input
        let (l1, l2) = k.lines
        let t1 = sk.addPoint(tp1), t2 = sk.addPoint(tp2), c = sk.addPoint(center)
        for (line, newEnd) in [(l1, t1), (l2, t2)] {
            guard let i = sk.curves.firstIndex(where: { $0.id == line.id }) else { continue }
            if sk.curves[i].a == pid { sk.curves[i].a = newEnd } else { sk.curves[i].b = newEnd }
        }
        // A length now means "from the old corner to the far end".
        let farEnd = [l1.id: k.ends.0, l2.id: k.ends.1]
        for i in sk.constraints.indices.reversed() {
            let con = sk.constraints[i]
            if con.kind == .length, con.refs.count == 1, let far = farEnd[con.refs[0]] {
                sk.constraints[i].kind = .distance
                sk.constraints[i].refs = [pid, far]
                sk.constraints[i].labelOffset = nil
            } else if con.kind == .equal, con.refs.contains(where: { farEnd[$0] != nil }) {
                sk.constraints.remove(at: i)
            } else if con.kind == .midpoint, con.refs.count == 2, farEnd[con.refs[1]] != nil {
                sk.constraints.remove(at: i)
            }
        }
        let arc = (tp1 - center).cross(tp2 - center) > 0
            ? sk.addArc(center: c, start: t1, end: t2)
            : sk.addArc(center: c, start: t2, end: t1)
        sk.addConstraint(.tangent, [l1.id, arc])
        sk.addConstraint(.tangent, [l2.id, arc])
        sk.addConstraint(.pointOnCurve, [pid, l1.id])
        sk.addConstraint(.pointOnCurve, [pid, l2.id])
        let dim = sk.addConstraint(.radius, [arc], value: r)
        return .success(RoundedCorner(sketch: sk, arc: arc, dimension: dim))
    }

    // MARK: - Mirror

    /// Adds mirrored copies of `curves` across the line `axis`. Each new point is tied to its original
    /// with a symmetry constraint; points on the axis are shared. Returns the new curves.
    static func mirror(_ input: Sketch, curves ids: [Int], across axisID: Int) -> (sketch: Sketch, curves: [Int])? {
        var sk = input
        guard let axis = sk.curve(axisID), axis.kind == .line else { return nil }
        let (a, b) = sk.lineEnds(axis)
        guard (b - a).length > 1e-9 else { return nil }
        let d = (b - a).normalized
        let scale = max((b - a).length, 1)
        let sources = ids.filter { $0 != axisID }.compactMap { sk.curve($0) }
        guard !sources.isEmpty else { return nil }

        var map: [Int: Int] = [:]
        func mirrored(_ pid: Int) -> Int {
            if let m = map[pid] { return m }
            let p = sk.position(pid)
            if abs(d.cross(p - a)) < 1e-7 * scale { map[pid] = pid; return pid }
            let foot = a + d * (p - a).dot(d)
            let q = sk.addPoint(foot * 2 - p)
            sk.addConstraint(.symmetric, [pid, q, axisID])
            map[pid] = q
            return q
        }
        var out: [Int] = []
        for c in sources {
            switch c.kind {
            case .line:
                let p = mirrored(c.a), q = mirrored(c.b)
                out.append(sk.addLine(p, q, construction: c.construction))
            case .circle:
                let center = mirrored(c.a)
                let n = sk.addCircle(center: center, radius: c.radius, construction: c.construction)
                sk.addConstraint(.equal, [c.id, n])
                out.append(n)
            case .arc:
                // Mirroring turns counter-clockwise into clockwise, so start and end swap.
                let center = mirrored(c.a), start = mirrored(c.c), end = mirrored(c.b)
                out.append(sk.addArc(center: center, start: start, end: end, construction: c.construction))
            }
        }
        return (sk, out)
    }

    // MARK: - Offset

    /// A curve of a chain in travel direction, with its point IDs.
    struct ChainItem {
        var curve: SketchCurve
        var reversed: Bool
        var startID: Int
        var endID: Int
    }

    private static func ends(_ c: SketchCurve) -> (Int, Int) {
        c.kind == .line ? (c.a, c.b) : (c.b, c.c)
    }

    private static func scale(of sk: Sketch, _ curves: [SketchCurve]) -> Double {
        var m = 1.0
        for c in curves { for p in c.pointIDs { let v = sk.position(p); m = max(m, abs(v.x), abs(v.y)) } }
        return m
    }

    /// Orders lines and arcs into one chain (open, or a closed loop). Ends match by position.
    static func chain(_ sk: Sketch, curves ids: [Int]) -> (items: [ChainItem], closed: Bool)? {
        let cs = ids.compactMap { sk.curve($0) }
        guard !cs.isEmpty, cs.count == ids.count, cs.allSatisfy({ $0.kind != .circle }) else { return nil }
        let tol = 1e-6 * scale(of: sk, cs)
        func same(_ p: Int, _ q: Int) -> Bool { p == q || (sk.position(p) - sk.position(q)).length < tol }
        func degree(_ p: Int) -> Int {
            cs.reduce(0) { n, c in let (s, e) = ends(c); return n + (same(s, p) ? 1 : 0) + (same(e, p) ? 1 : 0) }
        }
        for c in cs {
            let (s, e) = ends(c)
            if degree(s) > 2 || degree(e) > 2 { return nil }
        }
        // Open chains start at a loose end.
        var first = 0, firstReversed = false
        if let i = cs.indices.first(where: { degree(ends(cs[$0]).0) == 1 }) {
            first = i
        } else if let i = cs.indices.first(where: { degree(ends(cs[$0]).1) == 1 }) {
            first = i; firstReversed = true
        }
        func item(_ i: Int, reversed: Bool) -> ChainItem {
            let (s, e) = ends(cs[i])
            return ChainItem(curve: cs[i], reversed: reversed, startID: reversed ? e : s, endID: reversed ? s : e)
        }
        var items = [item(first, reversed: firstReversed)]
        var used: Set<Int> = [first]
        var cur = items[0].endID
        while used.count < cs.count {
            guard let j = cs.indices.first(where: { !used.contains($0) && (same(ends(cs[$0]).0, cur) || same(ends(cs[$0]).1, cur)) }) else { break }
            let rev = !same(ends(cs[j]).0, cur)
            let it = item(j, reversed: rev)
            items.append(it)
            used.insert(j)
            cur = it.endID
        }
        guard used.count == cs.count else { return nil }
        let closed = items.count > 1 && same(cur, items[0].startID)
        return (items, closed)
    }

    /// All lines and arcs connected to `id` through shared end points (same construction kind).
    static func connectedCurves(_ sk: Sketch, from id: Int) -> [Int] {
        guard let start = sk.curve(id) else { return [] }
        if start.kind == .circle { return [id] }
        let pool = sk.curves.filter { $0.kind != .circle && $0.construction == start.construction }
        let tol = 1e-6 * scale(of: sk, pool)
        var result = [id]
        var frontier = [start]
        var seen: Set<Int> = [id]
        while let c = frontier.popLast() {
            let (s, e) = ends(c)
            for o in pool where !seen.contains(o.id) {
                let (os, oe) = ends(o)
                let touches = [os, oe].contains { q in [s, e].contains { p in p == q || (sk.position(p) - sk.position(q)).length < tol } }
                if touches { seen.insert(o.id); result.append(o.id); frontier.append(o) }
            }
        }
        return result
    }

    /// Groups curves into connected pieces (each circle on its own).
    static func components(_ sk: Sketch, curves ids: [Int]) -> [[Int]] {
        let cs = ids.compactMap { sk.curve($0) }
        let tol = 1e-6 * scale(of: sk, cs)
        var groups: [[Int]] = []
        var left = cs
        while let first = left.first {
            left.removeFirst()
            if first.kind == .circle { groups.append([first.id]); continue }
            var group = [first]
            var changed = true
            while changed {
                changed = false
                for (i, o) in left.enumerated().reversed() where o.kind != .circle {
                    let (os, oe) = ends(o)
                    let touches = group.contains { g in
                        let (s, e) = ends(g)
                        return [os, oe].contains { q in [s, e].contains { p in p == q || (sk.position(p) - sk.position(q)).length < tol } }
                    }
                    if touches { group.append(o); left.remove(at: i); changed = true }
                }
            }
            groups.append(group.map(\.id))
        }
        return groups
    }

    struct OffsetResult {
        var sketch: Sketch
        var curves: [Int]
    }

    /// Adds an offset copy of the chosen curves at `distance`.
    /// Closed loops and circles: positive = outwards. Open chains: positive = to the left of the chain.
    /// Outer corners get round arcs (good printable walls); inner corners are cut where the copies cross.
    /// Several separate shapes can be offset at once.
    static func offset(_ input: Sketch, curves ids: [Int], distance: Double) -> Result<OffsetResult, EditError> {
        guard abs(distance) > 1e-9 else { return .failure(.tooBig) }
        var sk = input
        var created: [Int] = []
        let groups = components(input, curves: ids)
        guard !groups.isEmpty else { return .failure(.notAChain) }
        for group in groups {
            if group.count == 1, let c = input.curve(group[0]), c.kind == .circle {
                let r = c.radius + distance
                guard r > 1e-6 else { return .failure(.tooBig) }
                created.append(sk.addCircle(center: c.a, radius: r, construction: c.construction))
                continue
            }
            guard let (items, closed) = chain(input, curves: group) else { return .failure(.notAChain) }
            switch offsetChain(&sk, input, items, closed: closed, distance: distance) {
            case .success(let ids): created += ids
            case .failure(let f): return .failure(f)
            }
        }
        return .success(OffsetResult(sketch: sk, curves: created))
    }

    private static func segment(_ it: ChainItem, in sk: Sketch) -> RegionSegment {
        let c = it.curve
        switch c.kind {
        case .line:
            let (a, b) = sk.lineEnds(c)
            return it.reversed ? .line(b, a) : .line(a, b)
        default:
            let (s, w) = sk.arcAngles(c)
            let seg = RegionSegment.arc(center: sk.position(c.a), radius: sk.radius(of: c), start: s, sweep: w)
            return it.reversed ? seg.reversed : seg
        }
    }

    /// Direction of travel at the start or end of a segment.
    static func tangent(_ s: RegionSegment, atEnd: Bool) -> Vec2 {
        switch s {
        case .line(let a, let b): return (b - a).normalized
        case .arc(_, _, let st, let w):
            let phi = atEnd ? st + w : st
            let t = Vec2(-sin(phi), cos(phi))
            return w >= 0 ? t : -t
        }
    }

    /// The segment moved sideways by `o` (positive = to the left of travel).
    static func offsetSegment(_ s: RegionSegment, by o: Double) -> RegionSegment? {
        switch s {
        case .line(let a, let b):
            let n = (b - a).normalized.perpendicular
            return .line(a + n * o, b + n * o)
        case .arc(let c, let r, let st, let w):
            // Travelling counter-clockwise, left is towards the centre.
            let r2 = w > 0 ? r - o : r + o
            return r2 > 1e-6 ? .arc(center: c, radius: r2, start: st, sweep: w) : nil
        }
    }

    private static func withEnd(_ s: RegionSegment, _ x: Vec2) -> RegionSegment {
        switch s {
        case .line(let a, _): return .line(a, x)
        case .arc(let c, let r, let st, let w):
            let d = signedAngle((x - c).angle - (st + w))
            return .arc(center: c, radius: r, start: st, sweep: w + d)
        }
    }

    private static func withStart(_ s: RegionSegment, _ x: Vec2) -> RegionSegment {
        switch s {
        case .line(_, let b): return .line(x, b)
        case .arc(let c, let r, let st, let w):
            let d = signedAngle((x - c).angle - st)
            return .arc(center: c, radius: r, start: st + d, sweep: w - d)
        }
    }

    /// Crossings of the full lines/circles that two segments lie on.
    private static func crossings(_ p: RegionSegment, _ q: RegionSegment) -> [Vec2] {
        switch (p, q) {
        case let (.line(a, b), .line(c, d)):
            let r = b - a, s = d - c
            let den = r.cross(s)
            if abs(den) < 1e-12 { return [] }
            return [a + r * ((c - a).cross(s) / den)]
        case let (.line(a, b), .arc(c, r, _, _)), let (.arc(c, r, _, _), .line(a, b)):
            return lineCircle(a, b, c, r)
        case let (.arc(c1, r1, _, _), .arc(c2, r2, _, _)):
            return circleCircle(c1, r1, c2, r2)
        }
    }

    private static func offsetChain(_ sk: inout Sketch, _ source: Sketch, _ items: [ChainItem], closed: Bool,
                                    distance: Double) -> Result<[Int], EditError> {
        let segs = items.map { segment($0, in: source) }
        let n = segs.count
        let scale = Self.scale(of: source, items.map(\.curve))
        // Closed loops: positive = outwards, which is to the right of a counter-clockwise loop.
        var o = distance
        if closed {
            let area = segs.reduce(0) { $0 + $1.areaTerm }
            if area > 0 { o = -distance }
        }
        var off: [RegionSegment] = []
        for s in segs {
            guard let m = offsetSegment(s, by: o) else { return .failure(.tooBig) }
            off.append(m)
        }
        // Corner arcs, keyed by the segment they follow.
        var corners: [Int: RegionSegment] = [:]
        var cornerCenter: [Int: Int] = [:]
        let joints = closed ? n : n - 1
        for i in 0..<joints {
            let j = (i + 1) % n
            let v = segs[i].endPoint
            let e = off[i].endPoint, s = off[j].startPoint
            if (e - s).length < 1e-7 * scale { continue }  // smooth joint: the copies meet already
            let turn = tangent(segs[i], atEnd: true).cross(tangent(segs[j], atEnd: false))
            if turn * o < 0 {
                // Outer corner: round it around the original corner point.
                let a0 = (e - v).angle
                let sweep = signedAngle((s - v).angle - a0)
                corners[i] = .arc(center: v, radius: abs(o), start: a0, sweep: sweep)
                cornerCenter[i] = items[i].endID
            } else {
                // Inner corner: cut both copies where they cross.
                let mid = (e + s) / 2
                guard let x = crossings(off[i], off[j]).min(by: { ($0 - mid).length < ($1 - mid).length }) else {
                    return .failure(.tooBig)
                }
                off[i] = withEnd(off[i], x)
                off[j] = withStart(off[j], x)
            }
        }
        // A copy that turned around or vanished means the distance is too big for this shape.
        for (k, m) in off.enumerated() {
            switch (segs[k], m) {
            case let (.line(a, b), .line(c, d)):
                if (d - c).dot(b - a) <= 0 || (d - c).length < 1e-6 { return .failure(.tooBig) }
            case let (.arc(_, _, _, w0), .arc(_, _, _, w1)):
                if w0 * w1 <= 0 || abs(w1) < 1e-6 { return .failure(.tooBig) }
            default:
                return .failure(.tooBig)
            }
        }

        // Build the new curves. Points are shared between neighbouring pieces.
        var made: [(Vec2, Int)] = []
        func pointID(_ p: Vec2) -> Int {
            if let m = made.first(where: { ($0.0 - p).length < 1e-6 * scale }) { return m.1 }
            let id = sk.addPoint(p)
            made.append((p, id))
            return id
        }
        let construction = items[0].curve.construction
        func addPiece(_ piece: RegionSegment, center: Int?) -> Int {
            switch piece {
            case .line(let a, let b):
                let p = pointID(a), q = pointID(b)
                return sk.addLine(p, q, construction: construction)
            case .arc(let c, _, _, let w):
                let ps = pointID(piece.startPoint), pe = pointID(piece.endPoint)
                var cid = 0
                if let center { cid = center } else { cid = sk.addPoint(c) }
                return w > 0
                    ? sk.addArc(center: cid, start: ps, end: pe, construction: construction)
                    : sk.addArc(center: cid, start: pe, end: ps, construction: construction)
            }
        }
        var out: [Int] = []
        var pieceIDs: [Int] = []   // offset copy of segment k
        var cornerIDs: [Int: Int] = [:]
        for k in 0..<n {
            let src = items[k].curve
            let id = addPiece(off[k], center: src.kind == .arc ? src.a : nil)
            pieceIDs.append(id)
            out.append(id)
            if src.kind == .line { sk.addConstraint(.parallel, [src.id, id]) }
            if let corner = corners[k] {
                let cid = addPiece(corner, center: cornerCenter[k])
                cornerIDs[k] = cid
                out.append(cid)
            }
        }
        for (k, cid) in cornerIDs {
            sk.addConstraint(.tangent, [pieceIDs[k], cid])
            sk.addConstraint(.tangent, [pieceIDs[(k + 1) % n], cid])
        }
        return .success(out)
    }
}
