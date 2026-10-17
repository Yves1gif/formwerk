import Foundation

/// Solves sketch constraints with damped Gauss-Newton steps of minimum length
/// (each step moves the geometry as little as possible, so sketches don't jump around).
///
/// Unknowns: the x/y of every free point and the radius of every circle.
/// Afterwards a rank check of the Jacobian tells which points can still move (blue)
/// and which are fully defined (black).
enum SketchSolver {
    struct Result {
        var sketch: Sketch
        var converged: Bool
        var maxError: Double
        /// Remaining degrees of freedom (0 = fully defined).
        var freedom: Int
        var definedPoints: Set<Int>
        var definedCurves: Set<Int>
        /// Constraints that could not be satisfied (shown in red).
        var conflicting: Set<Int>

        var isFullyDefined: Bool { freedom == 0 && conflicting.isEmpty }
    }

    /// `locked`: points pinned to a position for this solve (the point being dragged).
    static func solve(_ input: Sketch, locked: [Int: Vec2] = [:]) -> Result {
        var sketch = input
        for (id, p) in locked { sketch.setPosition(id, p) }
        let system = System(sketch: sketch, locked: Set(locked.keys))
        var x = system.initial
        let n = x.count
        let eqs = system.equations
        let m = eqs.count

        var converged = true
        var maxErr = 0.0
        if m > 0 && n > 0 {
            var r = system.residuals(x)
            var cost = r.reduce(0) { $0 + $1 * $1 }
            var mu = 1e-9
            converged = false
            for _ in 0..<100 {
                if r.map(abs).max() ?? 0 < 1e-10 { converged = true; break }
                let J = system.jacobian(x)
                var improved = false
                for _ in 0..<12 {
                    guard let dx = minimumNormStep(J: J, r: r, m: m, n: n, mu: mu) else { mu *= 10; continue }
                    let xNew = zip(x, dx).map { $0 + $1 }
                    let rNew = system.residuals(xNew)
                    let costNew = rNew.reduce(0) { $0 + $1 * $1 }
                    if costNew < cost || costNew < 1e-20 {
                        x = xNew; r = rNew; cost = costNew
                        mu = max(mu * 0.3, 1e-12)
                        improved = true
                        break
                    }
                    mu *= 10
                }
                if !improved { break }
            }
            maxErr = r.map(abs).max() ?? 0
            if maxErr < 1e-7 { converged = true }
        }

        // Conflicts: constraints whose equations are still clearly violated.
        var conflicting = Set<Int>()
        if !converged {
            let r = system.residuals(x)
            for (k, e) in eqs.enumerated() where abs(r[k]) > 1e-6 {
                if let id = e.constraint { conflicting.insert(id) }
            }
        }

        system.write(x, into: &sketch)

        // Degrees of freedom from the Jacobian's null space.
        let (freedom, determined) = system.analyse(x)
        var definedPoints = Set<Int>()
        for p in sketch.points {
            if let i = system.pointVar[p.id] {
                if determined[i] && determined[i + 1] { definedPoints.insert(p.id) }
            } else {
                definedPoints.insert(p.id) // fixed or locked
            }
        }
        var definedCurves = Set<Int>()
        for c in sketch.curves {
            let pointsOK = c.pointIDs.allSatisfy { definedPoints.contains($0) }
            let radiusOK = system.radiusVar[c.id].map { determined[$0] } ?? true
            if pointsOK && radiusOK { definedCurves.insert(c.id) }
        }
        return Result(sketch: sketch, converged: converged, maxError: maxErr,
                      freedom: freedom, definedPoints: definedPoints,
                      definedCurves: definedCurves, conflicting: conflicting)
    }

    /// dx = -Jᵀ (J Jᵀ + μI)⁻¹ r
    private static func minimumNormStep(J: [Double], r: [Double], m: Int, n: Int, mu: Double) -> [Double]? {
        var A = [Double](repeating: 0, count: m * m)
        for i in 0..<m {
            for j in i..<m {
                var s = 0.0
                let ri = i * n, rj = j * n
                for k in 0..<n { s += J[ri + k] * J[rj + k] }
                A[i * m + j] = s
                A[j * m + i] = s
            }
            A[i * m + i] += mu
        }
        guard let y = LinearAlgebra.choleskySolve(A, r, size: m) else { return nil }
        var dx = [Double](repeating: 0, count: n)
        for i in 0..<m {
            let yi = y[i]
            if yi == 0 { continue }
            let ri = i * n
            for k in 0..<n { dx[k] -= J[ri + k] * yi }
        }
        return dx
    }

    // MARK: - Equation system

    struct Equation {
        let constraint: Int?
        let vars: [Int]
        let f: ([Double]) -> Double
    }

    final class System {
        var pointVar: [Int: Int] = [:]
        var radiusVar: [Int: Int] = [:]
        var fixedPoint: [Int: Vec2] = [:]
        var fixedRadius: [Int: Double] = [:]
        var initial: [Double] = []
        var equations: [Equation] = []
        let sketch: Sketch

        init(sketch: Sketch, locked: Set<Int>) {
            self.sketch = sketch
            let fixedByConstraint = Set(sketch.constraints.filter { $0.kind == .fix }.compactMap { $0.refs.first })
            for p in sketch.points {
                if p.fixed || locked.contains(p.id) || fixedByConstraint.contains(p.id) {
                    fixedPoint[p.id] = p.position
                } else {
                    pointVar[p.id] = initial.count
                    initial.append(p.x); initial.append(p.y)
                }
            }
            for c in sketch.curves where c.kind == .circle {
                radiusVar[c.id] = initial.count
                initial.append(c.radius)
            }
            buildEquations()
        }

        func write(_ x: [Double], into sketch: inout Sketch) {
            for i in sketch.points.indices {
                if let v = pointVar[sketch.points[i].id] {
                    sketch.points[i].x = x[v]; sketch.points[i].y = x[v + 1]
                }
            }
            for i in sketch.curves.indices {
                let c = sketch.curves[i]
                if let v = radiusVar[c.id] { sketch.curves[i].radius = x[v] }
                if c.kind == .arc { sketch.curves[i].radius = (pos(c.b, x) - pos(c.a, x)).length }
            }
        }

        // Accessors used inside equations.
        func pos(_ id: Int, _ x: [Double]) -> Vec2 {
            if let v = pointVar[id] { return Vec2(x[v], x[v + 1]) }
            return fixedPoint[id] ?? .zero
        }

        func radius(_ c: SketchCurve, _ x: [Double]) -> Double {
            switch c.kind {
            case .circle: if let v = radiusVar[c.id] { return x[v] }; return c.radius
            case .arc: return (pos(c.b, x) - pos(c.a, x)).length
            case .line: return 0
            }
        }

        func vars(points: [Int], curves: [SketchCurve] = []) -> [Int] {
            var out: [Int] = []
            for p in points { if let v = pointVar[p] { out.append(v); out.append(v + 1) } }
            for c in curves {
                if let v = radiusVar[c.id] { out.append(v) }
                for p in c.pointIDs { if let v = pointVar[p] { out.append(v); out.append(v + 1) } }
            }
            return Array(Set(out))
        }

        func add(_ cid: Int?, _ vars: [Int], _ f: @escaping ([Double]) -> Double) {
            if vars.isEmpty { return } // nothing can move: the constraint is either met or a conflict we can't fix
            equations.append(Equation(constraint: cid, vars: vars, f: f))
        }

        func buildEquations() {
            let s = sketch
            // Arcs keep start and end on the same circle.
            for c in s.curves where c.kind == .arc {
                add(nil, vars(points: [c.a, c.b, c.c])) { [unowned self] x in
                    (self.pos(c.c, x) - self.pos(c.a, x)).length - (self.pos(c.b, x) - self.pos(c.a, x)).length
                }
            }
            for k in s.constraints {
                let r = k.refs
                let v = k.value ?? 0
                func curve(_ i: Int) -> SketchCurve? { i < r.count ? s.curve(r[i]) : nil }
                func line(_ i: Int) -> SketchCurve? { curve(i).flatMap { $0.kind == .line ? $0 : nil } }
                func round(_ i: Int) -> SketchCurve? { curve(i).flatMap { $0.kind != .line ? $0 : nil } }
                // Sign of a quantity in the current sketch, so that signed equations keep their side.
                func sign(_ value: Double) -> Double { value < 0 ? -1 : 1 }
                let x0 = initial

                switch k.kind {
                case .coincident:
                    guard r.count == 2 else { continue }
                    let vs = vars(points: r)
                    add(k.id, vs) { [unowned self] x in self.pos(r[0], x).x - self.pos(r[1], x).x }
                    add(k.id, vs) { [unowned self] x in self.pos(r[0], x).y - self.pos(r[1], x).y }

                case .pointOnCurve:
                    guard r.count == 2, let c = curve(1) else { continue }
                    let p = r[0]
                    if c.kind == .line {
                        add(k.id, vars(points: [p], curves: [c])) { [unowned self] x in
                            let a = self.pos(c.a, x), b = self.pos(c.b, x)
                            let d = b - a
                            return d.cross(self.pos(p, x) - a) / max(d.length, 1e-9)
                        }
                    } else {
                        add(k.id, vars(points: [p], curves: [c])) { [unowned self] x in
                            (self.pos(p, x) - self.pos(c.a, x)).length - self.radius(c, x)
                        }
                    }

                case .horizontal, .vertical:
                    let ids: [Int]
                    if let l = line(0) { ids = [l.a, l.b] } else if r.count == 2 { ids = r } else { continue }
                    let horizontal = k.kind == .horizontal
                    add(k.id, vars(points: ids)) { [unowned self] x in
                        let a = self.pos(ids[0], x), b = self.pos(ids[1], x)
                        return horizontal ? a.y - b.y : a.x - b.x
                    }

                case .parallel, .perpendicular:
                    guard let l1 = line(0), let l2 = line(1) else { continue }
                    let parallel = k.kind == .parallel
                    add(k.id, vars(points: [], curves: [l1, l2])) { [unowned self] x in
                        let d1 = (self.pos(l1.b, x) - self.pos(l1.a, x)).normalized
                        let d2 = (self.pos(l2.b, x) - self.pos(l2.a, x)).normalized
                        return parallel ? d1.cross(d2) : d1.dot(d2)
                    }

                case .equal:
                    guard let c1 = curve(0), let c2 = curve(1) else { continue }
                    if c1.kind == .line && c2.kind == .line {
                        add(k.id, vars(points: [], curves: [c1, c2])) { [unowned self] x in
                            (self.pos(c1.b, x) - self.pos(c1.a, x)).length - (self.pos(c2.b, x) - self.pos(c2.a, x)).length
                        }
                    } else if c1.kind != .line && c2.kind != .line {
                        add(k.id, vars(points: [], curves: [c1, c2])) { [unowned self] x in
                            self.radius(c1, x) - self.radius(c2, x)
                        }
                    }

                case .tangent:
                    guard let c1 = curve(0), let c2 = curve(1) else { continue }
                    if let l = [c1, c2].first(where: { $0.kind == .line }), let c = [c1, c2].first(where: { $0.kind != .line }) {
                        add(k.id, vars(points: [], curves: [l, c])) { [unowned self] x in
                            let a = self.pos(l.a, x), b = self.pos(l.b, x)
                            let d = b - a
                            return abs(d.cross(self.pos(c.a, x) - a)) / max(d.length, 1e-9) - self.radius(c, x)
                        }
                    } else if c1.kind != .line && c2.kind != .line {
                        // Outside or inside tangency, whichever the sketch shows now.
                        let dist0 = (pos(c1.a, x0) - pos(c2.a, x0)).length
                        let inside = dist0 < max(radius(c1, x0), radius(c2, x0))
                        add(k.id, vars(points: [], curves: [c1, c2])) { [unowned self] x in
                            let d = (self.pos(c1.a, x) - self.pos(c2.a, x)).length
                            let r1 = self.radius(c1, x), r2 = self.radius(c2, x)
                            return inside ? d - abs(r1 - r2) : d - (r1 + r2)
                        }
                    }

                case .concentric:
                    guard let c1 = round(0), let c2 = round(1) else { continue }
                    let vs = vars(points: [c1.a, c2.a])
                    add(k.id, vs) { [unowned self] x in self.pos(c1.a, x).x - self.pos(c2.a, x).x }
                    add(k.id, vs) { [unowned self] x in self.pos(c1.a, x).y - self.pos(c2.a, x).y }

                case .midpoint:
                    guard r.count == 2, let l = line(1) else { continue }
                    let p = r[0]
                    let vs = vars(points: [p, l.a, l.b])
                    add(k.id, vs) { [unowned self] x in self.pos(p, x).x - (self.pos(l.a, x).x + self.pos(l.b, x).x) / 2 }
                    add(k.id, vs) { [unowned self] x in self.pos(p, x).y - (self.pos(l.a, x).y + self.pos(l.b, x).y) / 2 }

                case .symmetric:
                    guard r.count == 3, let l = line(2) else { continue }
                    let p = r[0], q = r[1]
                    let vs = vars(points: [p, q, l.a, l.b])
                    add(k.id, vs) { [unowned self] x in
                        let a = self.pos(l.a, x), d = (self.pos(l.b, x) - a).normalized
                        let mid = (self.pos(p, x) + self.pos(q, x)) / 2
                        return d.cross(mid - a)
                    }
                    add(k.id, vs) { [unowned self] x in
                        let d = (self.pos(l.b, x) - self.pos(l.a, x)).normalized
                        return (self.pos(q, x) - self.pos(p, x)).dot(d)
                    }

                case .fix:
                    continue // handled by treating the point as fixed

                case .distance:
                    guard r.count == 2 else { continue }
                    add(k.id, vars(points: r)) { [unowned self] x in (self.pos(r[0], x) - self.pos(r[1], x)).length - v }

                case .horizontalDistance, .verticalDistance:
                    guard r.count == 2 else { continue }
                    let horizontal = k.kind == .horizontalDistance
                    let d0 = pos(r[1], x0) - pos(r[0], x0)
                    let sg = sign(horizontal ? d0.x : d0.y)
                    add(k.id, vars(points: r)) { [unowned self] x in
                        let d = self.pos(r[1], x) - self.pos(r[0], x)
                        return sg * (horizontal ? d.x : d.y) - v
                    }

                case .length:
                    guard let l = line(0) else { continue }
                    add(k.id, vars(points: [l.a, l.b])) { [unowned self] x in (self.pos(l.b, x) - self.pos(l.a, x)).length - v }

                case .pointLineDistance:
                    guard r.count == 2, let l = line(1) else { continue }
                    let p = r[0]
                    let d0 = (pos(l.b, x0) - pos(l.a, x0)).normalized
                    let sg = sign(d0.cross(pos(p, x0) - pos(l.a, x0)))
                    add(k.id, vars(points: [p, l.a, l.b])) { [unowned self] x in
                        let a = self.pos(l.a, x), d = (self.pos(l.b, x) - a).normalized
                        return sg * d.cross(self.pos(p, x) - a) - v
                    }

                case .radius, .diameter:
                    guard let c = round(0) else { continue }
                    let factor = k.kind == .diameter ? 2.0 : 1.0
                    add(k.id, vars(points: [], curves: [c])) { [unowned self] x in factor * self.radius(c, x) - v }

                case .angle:
                    guard let l1 = line(0), let l2 = line(1) else { continue }
                    add(k.id, vars(points: [], curves: [l1, l2])) { [unowned self] x in
                        let d1 = self.pos(l1.b, x) - self.pos(l1.a, x)
                        let d2 = self.pos(l2.b, x) - self.pos(l2.a, x)
                        var diff = atan2(d1.cross(d2), d1.dot(d2)) - v
                        while diff > .pi { diff -= 2 * .pi }
                        while diff < -.pi { diff += 2 * .pi }
                        return diff
                    }
                }
            }
        }

        func residuals(_ x: [Double]) -> [Double] { equations.map { $0.f(x) } }

        /// Dense Jacobian (row-major, m × n) by central differences on each equation's own variables.
        func jacobian(_ x: [Double]) -> [Double] {
            let n = x.count
            var J = [Double](repeating: 0, count: equations.count * n)
            var xs = x
            for (i, e) in equations.enumerated() {
                for v in e.vars {
                    let h = 1e-7 * max(1, abs(x[v]))
                    xs[v] = x[v] + h
                    let fp = e.f(xs)
                    xs[v] = x[v] - h
                    let fm = e.f(xs)
                    xs[v] = x[v]
                    J[i * n + v] = (fp - fm) / (2 * h)
                }
            }
            return J
        }

        /// Rank of the Jacobian and, per unknown, whether the constraints pin it down.
        func analyse(_ x: [Double]) -> (freedom: Int, determined: [Bool]) {
            let n = x.count
            if n == 0 { return (0, []) }
            let m = equations.count
            if m == 0 { return (n, [Bool](repeating: false, count: n)) }
            let (rank, pivots, R) = LinearAlgebra.rowEchelon(jacobian(x), rows: m, cols: n)
            let free = (0..<n).filter { !pivots.keys.contains($0) }
            var determined = [Bool](repeating: false, count: n)
            for (col, row) in pivots {
                // A pivot unknown is pinned when no free unknown can move it.
                determined[col] = free.allSatisfy { abs(R[row * n + $0]) < 1e-7 }
            }
            return (n - rank, determined)
        }
    }
}

enum LinearAlgebra {
    /// Solves A y = b for a symmetric positive definite A (row-major).
    static func choleskySolve(_ A: [Double], _ b: [Double], size n: Int) -> [Double]? {
        var L = [Double](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var s = A[i * n + j]
                for k in 0..<j { s -= L[i * n + k] * L[j * n + k] }
                if i == j {
                    if s <= 0 { return nil }
                    L[i * n + i] = s.squareRoot()
                } else {
                    L[i * n + j] = s / L[j * n + j]
                }
            }
        }
        var y = b
        for i in 0..<n {
            var s = y[i]
            for k in 0..<i { s -= L[i * n + k] * y[k] }
            y[i] = s / L[i * n + i]
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            var s = y[i]
            for k in (i + 1)..<n { s -= L[k * n + i] * y[k] }
            y[i] = s / L[i * n + i]
        }
        return y
    }

    /// Reduced row echelon form with partial pivoting.
    /// Returns the rank, pivot column → row, and the reduced matrix.
    static func rowEchelon(_ input: [Double], rows m: Int, cols n: Int) -> (Int, [Int: Int], [Double]) {
        var A = input
        let scale = max(1, A.map(abs).max() ?? 1)
        let tol = 1e-9 * scale
        var pivots: [Int: Int] = [:]
        var row = 0
        for col in 0..<n where row < m {
            var best = row
            for r in row..<m where abs(A[r * n + col]) > abs(A[best * n + col]) { best = r }
            if abs(A[best * n + col]) < tol { continue }
            if best != row {
                for k in 0..<n { A.swapAt(best * n + k, row * n + k) }
            }
            let p = A[row * n + col]
            for k in 0..<n { A[row * n + k] /= p }
            for r in 0..<m where r != row {
                let f = A[r * n + col]
                if f == 0 { continue }
                for k in 0..<n { A[r * n + k] -= f * A[row * n + k] }
            }
            pivots[col] = row
            row += 1
        }
        return (row, pivots, A)
    }
}
