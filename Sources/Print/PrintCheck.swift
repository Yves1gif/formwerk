import Foundation
import simd

/// The result of checking bodies for printing. Face marks colour problem areas on the model.
struct PrintCheckResult: Equatable {
    struct Issue: Identifiable, Equatable {
        enum Kind: String { case notClosed, thinWalls, overhangs, tooBig, belowBed, floating, ok }
        let id = UUID()
        let kind: Kind
        let body: String?
        let detail: String
        var isProblem: Bool { kind != .ok }
    }

    var issues: [Issue] = []
    /// body → face index → 3 (overhang) or 4 (thin wall)
    var faceMarks: [String: [Int: UInt8]] = [:]
    var printer: Printer?
    var showBed = true
    var volume: Double = 0       // mm³
    var area: Double = 0         // mm²
    var size: Vec3 = .zero
    var grams: Double = 0
    var metres: Double = 0

    static func == (a: Self, b: Self) -> Bool { a.issues == b.issues && a.faceMarks == b.faceMarks && a.printer == b.printer && a.showBed == b.showBed }
}

/// Mesh-based checks. All work on plain triangles, so it runs off the main thread.
enum PrintChecker {
    struct Input {
        let id: String
        let mesh: TriangleMesh
        let volume: Double
        let area: Double
        let bounds: Box3
        let validSolid: Bool
    }

    struct Settings {
        var printer: Printer
        var material: Material
        var overhangAngle: Double = 45     // degrees from vertical
        var minWall: Double = 0.8          // mm
        var infill: Double = 0.15
        var walls: Double = 2              // perimeters
    }

    static func check(_ bodies: [Input], _ s: Settings) -> PrintCheckResult {
        var r = PrintCheckResult()
        r.printer = s.printer
        var all = Box3.empty
        for b in bodies { all.add(b.bounds) }
        r.size = all.size

        for b in bodies {
            r.volume += b.volume
            r.area += b.area
            if !b.validSolid {
                r.issues.append(.init(kind: .notClosed, body: b.id,
                                      detail: String(localized: "This body has gaps or open faces. Slicers may fill it wrongly.")))
            }
            var marks: [Int: UInt8] = [:]
            let (overhangFaces, overhangArea) = overhangs(b.mesh, bedZ: all.min.z, maxAngle: s.overhangAngle)
            for f in overhangFaces { marks[f] = 3 }
            // Under 0.25 cm² a printer bridges it fine (tiny fillet or letter undersides); only warn above that.
            if overhangArea > 25 {
                r.issues.append(.init(kind: .overhangs, body: b.id,
                                      detail: String(localized: "\(Format.number(overhangArea / 100, digits: 1)) cm² hang over more than \(Int(s.overhangAngle))°. They need supports or a different orientation.")))
            }
            let thin = thinFaces(b.mesh, minWall: s.minWall)
            for f in thin { marks[f] = 4 }
            if !thin.isEmpty {
                r.issues.append(.init(kind: .thinWalls, body: b.id,
                                      detail: String(localized: "Some walls are thinner than \(Format.length(s.minWall)). They may not print.")))
            }
            if !marks.isEmpty { r.faceMarks[b.id] = marks }
        }

        let bed = s.printer.bed
        if all.size.x > bed.x + 1e-6 || all.size.y > bed.y + 1e-6 || all.size.z > bed.z + 1e-6 {
            let fitsRotated = all.size.y <= bed.x && all.size.x <= bed.y && all.size.z <= bed.z
            r.issues.append(.init(kind: .tooBig, body: nil,
                                  detail: fitsRotated
                                    ? String(localized: "Too big for the \(s.printer.name) this way round, but it fits turned by 90°.")
                                    : String(localized: "Too big for the \(s.printer.name) (\(Format.number(bed.x, digits: 0)) × \(Format.number(bed.y, digits: 0)) × \(Format.number(bed.z, digits: 0)) mm).")))
        }
        if bodies.count > 1 {
            let lowest = all.min.z
            let floating = bodies.filter { $0.bounds.min.z > lowest + 0.05 }
            if !floating.isEmpty {
                r.issues.append(.init(kind: .floating, body: floating[0].id,
                                      detail: String(localized: "\(floating.count) bodies don't touch the print bed. Join them or add supports.")))
            }
        }
        if r.issues.isEmpty {
            r.issues.append(.init(kind: .ok, body: nil, detail: String(localized: "Ready to print. No problems found.")))
        }

        // Filament: walls (area × perimeters × nozzle) plus infill of the rest. A rough guide; slicers know better.
        let shell = min(r.area * s.walls * s.printer.nozzle, r.volume)
        let printed = shell + max(r.volume - shell, 0) * s.infill
        r.grams = printed / 1000 * s.material.density
        let filamentArea = Double.pi * 0.875 * 0.875  // 1.75 mm filament
        r.metres = printed / filamentArea / 1000
        return r
    }

    /// Every edge shared by exactly two triangles (after welding equal positions).
    static func isWatertight(_ m: TriangleMesh) -> Bool {
        guard m.triangleCount > 0 else { return false }
        var ids: [SIMD3<Int32>: Int32] = [:]
        var weld = [Int32](repeating: 0, count: m.positions.count)
        for (i, p) in m.positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 2000).rounded()), Int32((p.y * 2000).rounded()), Int32((p.z * 2000).rounded()))
            if let id = ids[k] { weld[i] = id } else { let id = Int32(ids.count); ids[k] = id; weld[i] = id }
        }
        var edges: [SIMD2<Int32>: Int] = [:]
        for t in 0..<m.triangleCount {
            let a = weld[Int(m.indices[t * 3])], b = weld[Int(m.indices[t * 3 + 1])], c = weld[Int(m.indices[t * 3 + 2])]
            if a == b || b == c || a == c { continue }
            for (u, v) in [(a, b), (b, c), (c, a)] {
                edges[SIMD2(min(u, v), max(u, v)), default: 0] += 1
            }
        }
        return edges.values.allSatisfy { $0 == 2 }
    }

    /// Faces pointing down steeper than the limit, ignoring faces lying on the bed.
    static func overhangs(_ m: TriangleMesh, bedZ: Double, maxAngle: Double) -> (Set<Int>, Double) {
        var faces = Set<Int>()
        var area = 0.0
        let limit = Float(sin(maxAngle * .pi / 180))  // normal.z below -limit = too steep
        for t in 0..<m.triangleCount {
            let i0 = Int(m.indices[t * 3]), i1 = Int(m.indices[t * 3 + 1]), i2 = Int(m.indices[t * 3 + 2])
            let a = m.positions[i0], b = m.positions[i1], c = m.positions[i2]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-9 else { continue }
            let nz = n.z / len
            if nz < -limit {
                let lowest = min(a.z, b.z, c.z)
                if Double(lowest) < bedZ + 0.05 && Double(max(a.z, b.z, c.z)) < bedZ + 0.05 { continue } // on the bed
                faces.insert(Int(m.vertexFaces[i0]))
                area += Double(len) / 2
            }
        }
        return (faces, area)
    }

    /// Faces whose material is thinner than `minWall`: rays from triangle centres inwards.
    static func thinFaces(_ m: TriangleMesh, minWall: Double) -> Set<Int> {
        guard m.triangleCount > 0 else { return [] }
        let bvh = BVH(m)
        var faces = Set<Int>()
        let stride = max(1, m.triangleCount / 4000)  // sample big meshes
        for t in Swift.stride(from: 0, to: m.triangleCount, by: stride) {
            let i0 = Int(m.indices[t * 3]), i1 = Int(m.indices[t * 3 + 1]), i2 = Int(m.indices[t * 3 + 2])
            let a = m.positions[i0], b = m.positions[i1], c = m.positions[i2]
            let n = simd_cross(b - a, c - a)
            let len = simd_length(n)
            guard len > 1e-9 else { continue }
            let dir = -n / len
            let origin = (a + b + c) / 3 + dir * 1e-3
            if let d = bvh.hit(origin: origin, direction: dir, maxDistance: Float(minWall), skip: t), d < Float(minWall) - 1e-3 {
                faces.insert(Int(m.vertexFaces[i0]))
            }
        }
        return faces
    }
}

/// A small bounding-volume hierarchy for ray casts against a mesh.
final class BVH {
    private struct Node { var lo: SIMD3<Float>; var hi: SIMD3<Float>; var left: Int32; var right: Int32; var start: Int32; var count: Int32 }
    private var nodes: [Node] = []
    private var tris: [Int32]
    private let mesh: TriangleMesh
    private var centroids: [SIMD3<Float>]

    init(_ m: TriangleMesh) {
        mesh = m
        tris = (0..<Int32(m.triangleCount)).map { $0 }
        centroids = (0..<m.triangleCount).map { t -> SIMD3<Float> in
            let a: SIMD3<Float> = m.positions[Int(m.indices[t * 3])]
            let b: SIMD3<Float> = m.positions[Int(m.indices[t * 3 + 1])]
            let c: SIMD3<Float> = m.positions[Int(m.indices[t * 3 + 2])]
            return (a + b + c) / 3
        }
        _ = build(0, tris.count)
    }

    private func bounds(_ start: Int, _ count: Int) -> (SIMD3<Float>, SIMD3<Float>) {
        var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
        for k in start..<(start + count) {
            let t = Int(tris[k])
            for j in 0..<3 {
                let p = mesh.positions[Int(mesh.indices[t * 3 + j])]
                lo = simd_min(lo, p); hi = simd_max(hi, p)
            }
        }
        return (lo, hi)
    }

    private func build(_ start: Int, _ count: Int) -> Int32 {
        let (lo, hi) = bounds(start, count)
        let index = nodes.count
        nodes.append(Node(lo: lo, hi: hi, left: -1, right: -1, start: Int32(start), count: Int32(count)))
        if count <= 6 { return Int32(index) }
        let ext = hi - lo
        let axis = ext.x > ext.y ? (ext.x > ext.z ? 0 : 2) : (ext.y > ext.z ? 1 : 2)
        let slice = tris[start..<(start + count)].sorted { centroids[Int($0)][axis] < centroids[Int($1)][axis] }
        tris.replaceSubrange(start..<(start + count), with: slice)
        let half = count / 2
        let l = build(start, half)
        let r = build(start + half, count - half)
        nodes[index].left = l
        nodes[index].right = r
        nodes[index].count = 0
        return Int32(index)
    }

    func hit(origin o: SIMD3<Float>, direction d: SIMD3<Float>, maxDistance: Float, skip: Int) -> Float? {
        var best = maxDistance
        var found = false
        let inv = SIMD3<Float>(1 / d.x, 1 / d.y, 1 / d.z)
        var stack: [Int32] = [0]
        while let ni = stack.popLast() {
            let n = nodes[Int(ni)]
            // slab test
            let t0 = (n.lo - o) * inv, t1 = (n.hi - o) * inv
            let tmin = simd_reduce_max(simd_min(t0, t1)), tmax = simd_reduce_min(simd_max(t0, t1))
            if tmax < max(tmin, 0) || tmin > best { continue }
            if n.count > 0 {
                for k in Int(n.start)..<Int(n.start + n.count) {
                    let t = Int(tris[k])
                    if t == skip { continue }
                    let a = mesh.positions[Int(mesh.indices[t * 3])]
                    let b = mesh.positions[Int(mesh.indices[t * 3 + 1])]
                    let c = mesh.positions[Int(mesh.indices[t * 3 + 2])]
                    if let dist = Self.rayTriangle(o, d, a, b, c), dist > 1e-4, dist < best { best = dist; found = true }
                }
            } else {
                stack.append(n.left); stack.append(n.right)
            }
        }
        return found ? best : nil
    }

    /// Möller–Trumbore
    static func rayTriangle(_ o: SIMD3<Float>, _ d: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Float? {
        let e1 = b - a, e2 = c - a
        let p = simd_cross(d, e2)
        let det = simd_dot(e1, p)
        if abs(det) < 1e-9 { return nil }
        let inv = 1 / det
        let s = o - a
        let u = simd_dot(s, p) * inv
        if u < 0 || u > 1 { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(d, q) * inv
        if v < 0 || u + v > 1 { return nil }
        let t = simd_dot(e2, q) * inv
        return t > 0 ? t : nil
    }
}
