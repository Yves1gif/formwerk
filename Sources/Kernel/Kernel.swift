import Foundation

/// A solid (or compound, face…) owned by the geometry kernel. Immutable: every operation returns a new one.
final class Shape: @unchecked Sendable {
    let ptr: OpaquePointer

    init?(_ p: OpaquePointer?) {
        guard let p else { return nil }
        ptr = p
    }

    deinit { fw_shape_free(ptr) }

    var solidCount: Int { Int(fw_solid_count(ptr)) }
    var faceCount: Int { Int(fw_face_count(ptr)) }
    var edgeCount: Int { Int(fw_edge_count(ptr)) }
    var isValidSolid: Bool { fw_is_valid_solid(ptr) }

    var properties: ShapeProperties {
        lock.lock(); defer { lock.unlock() }
        if let p = cachedProps { return p }
        let p = fw_props(ptr)
        let props = ShapeProperties(volume: p.volume, area: p.area, centerOfMass: Vec3(p.centerOfMass),
                                    bounds: Box3(min: Vec3(p.bboxMin), max: Vec3(p.bboxMax)))
        cachedProps = props
        return props
    }

    func face(_ index: Int) -> FaceInfo? {
        var info = FWFaceInfo()
        guard fw_face_info(ptr, Int32(index), &info) else { return nil }
        return FaceInfo(index: index, raw: info)
    }

    func edge(_ index: Int) -> EdgeInfo? {
        var info = FWEdgeInfo()
        guard fw_edge_info(ptr, Int32(index), &info) else { return nil }
        return EdgeInfo(index: index, raw: info)
    }

    private let lock = NSLock()
    private var cachedFaces: [FaceInfo]?
    private var cachedEdges: [EdgeInfo]?
    private var cachedProps: ShapeProperties?

    /// All faces (computed once; shapes never change).
    var faces: [FaceInfo] {
        lock.lock(); defer { lock.unlock() }
        if let f = cachedFaces { return f }
        let f = faceCount == 0 ? [] : (1...faceCount).compactMap { face($0) }
        cachedFaces = f
        return f
    }

    var edges: [EdgeInfo] {
        lock.lock(); defer { lock.unlock() }
        if let e = cachedEdges { return e }
        let e = edgeCount == 0 ? [] : (1...edgeCount).compactMap { edge($0) }
        cachedEdges = e
        return e
    }

    func faceInfo(_ index: Int) -> FaceInfo? { faces.first { $0.index == index } }
    func edgeInfo(_ index: Int) -> EdgeInfo? { edges.first { $0.index == index } }

    /// Kind and normal of the faces next to an edge, for telling similar edges apart.
    func neighbours(ofEdge edge: Int) -> [(kind: Int, normal: Vec3)] {
        facesOfEdge(edge).compactMap { faceInfo($0) }.map { ($0.kind.rawValue, $0.normal) }
    }

    func edgesOfFace(_ face: Int) -> [Int] {
        var buf = [Int32](repeating: 0, count: 512)
        let n = Int(fw_face_edges(ptr, Int32(face), &buf, 512))
        return buf.prefix(min(n, 512)).map { Int($0) }
    }

    func facesOfEdge(_ edge: Int) -> [Int] {
        var a: Int32 = 0, b: Int32 = 0
        fw_edge_faces(ptr, Int32(edge), &a, &b)
        return [a, b].filter { $0 > 0 }.map { Int($0) }
    }

    func solids() -> [Shape] {
        solidCount == 0 ? [] : (1...solidCount).compactMap { Shape(fw_solid_at(ptr, Int32($0))) }
    }

    func mesh(linear: Double = 0.05, angular: Double = 0.35) -> TriangleMesh {
        TriangleMesh(fw_tessellate(ptr, linear, angular))
    }

    func brep() -> Data {
        var len: Int64 = 0
        guard let buf = fw_shape_to_brep(ptr, &len) else { return Data() }
        defer { fw_free_buffer(buf) }
        return Data(bytes: buf, count: Int(len))
    }
}

struct ShapeProperties {
    var volume: Double
    var area: Double
    var centerOfMass: Vec3
    var bounds: Box3
}

struct FaceInfo {
    enum Kind: Int { case plane, cylinder, cone, sphere, torus, other }
    let index: Int
    let kind: Kind
    let centroid: Vec3
    let normal: Vec3
    let axis: Vec3
    let area: Double
    let radius: Double

    init(index: Int, raw r: FWFaceInfo) {
        self.index = index
        kind = Kind(rawValue: Int(r.kind)) ?? .other
        centroid = Vec3(r.centroid); normal = Vec3(r.normal); axis = Vec3(r.axis)
        area = r.area; radius = r.radius
    }

    var isPlanar: Bool { kind == .plane }
}

struct EdgeInfo {
    enum Kind: Int { case line, circle, other }
    let index: Int
    let kind: Kind
    let midpoint, start, end, center: Vec3
    let length: Double
    let radius: Double

    init(index: Int, raw r: FWEdgeInfo) {
        self.index = index
        kind = Kind(rawValue: Int(r.kind)) ?? .other
        midpoint = Vec3(r.midpoint); start = Vec3(r.start); end = Vec3(r.end); center = Vec3(r.center)
        length = r.length; radius = r.radius
    }
}

/// Triangles of a shape, grouped by face, plus edge polylines. Plain Swift arrays, safe to send anywhere.
struct TriangleMesh: Sendable {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var indices: [UInt32] = []
    /// 1-based face index per vertex.
    var vertexFaces: [Int32] = []
    var edgePolylines: [(edge: Int32, points: [SIMD3<Float>])] = []

    init() {}

    init(_ m: OpaquePointer?) {
        guard let m else { return }
        defer { fw_mesh_free(m) }
        let vc = Int(fw_mesh_vertex_count(m)), tc = Int(fw_mesh_triangle_count(m))
        if vc > 0 {
            let p = fw_mesh_positions(m)!, n = fw_mesh_normals(m)!
            positions = (0..<vc).map { SIMD3<Float>(p[$0 * 3], p[$0 * 3 + 1], p[$0 * 3 + 2]) }
            normals = (0..<vc).map { SIMD3<Float>(n[$0 * 3], n[$0 * 3 + 1], n[$0 * 3 + 2]) }
            vertexFaces = Array(UnsafeBufferPointer(start: fw_mesh_vertex_faces(m), count: vc))
        }
        if tc > 0 { indices = Array(UnsafeBufferPointer(start: fw_mesh_indices(m), count: tc * 3)) }
        let lc = Int(fw_mesh_edge_polyline_count(m))
        if lc > 0 {
            let sizes = fw_mesh_edge_polyline_sizes(m)!, ids = fw_mesh_edge_polyline_ids(m)!
            let pts = fw_mesh_edge_points(m)!
            var o = 0
            for i in 0..<lc {
                let n = Int(sizes[i])
                let line = (0..<n).map { k in SIMD3<Float>(pts[(o + k) * 3], pts[(o + k) * 3 + 1], pts[(o + k) * 3 + 2]) }
                edgePolylines.append((ids[i], line))
                o += n
            }
        }
    }

    var triangleCount: Int { indices.count / 3 }
}

struct KernelError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Swift entry points for the geometry kernel.
enum Kernel {
    private static func run(_ body: (UnsafeMutablePointer<FWError>) -> OpaquePointer?) throws -> Shape {
        var err = FWError()
        let result = body(&err)
        if let s = Shape(result) { return s }
        let msg = withUnsafeBytes(of: &err.message) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        throw KernelError(message: msg.isEmpty ? "geometry error" : msg)
    }

    static func face(on plane: Plane, loops: [[RegionSegment]]) throws -> Shape {
        var segs: [FWSegment] = []
        var sizes: [Int32] = []
        for loop in loops {
            sizes.append(Int32(loop.count))
            for s in loop { segs.append(s.fw) }
        }
        return try run { err in
            fw_make_face(plane.fw, segs, sizes, Int32(sizes.count), err)
        }
    }

    static func box(corner: Vec3, size: Vec3) throws -> Shape {
        try run { fw_make_box(corner.fw, size.fw, $0) }
    }

    static func cylinder(base: Vec3, axis: Vec3, radius: Double, height: Double) throws -> Shape {
        try run { fw_make_cylinder(base.fw, axis.fw, radius, height, $0) }
    }

    static func compound(_ shapes: [Shape]) -> Shape {
        let ptrs: [OpaquePointer?] = shapes.map { $0.ptr }
        return ptrs.withUnsafeBufferPointer { buf in
            Shape(fw_make_compound(buf.baseAddress, Int32(shapes.count)))!
        }
    }

    static func extrude(_ profile: Shape, direction: Vec3, distance: Double, symmetric: Bool = false) throws -> Shape {
        try run { fw_extrude(profile.ptr, direction.fw, distance, symmetric, $0) }
    }

    static func revolve(_ profile: Shape, axisOrigin: Vec3, axis: Vec3, angle: Double) throws -> Shape {
        try run { fw_revolve(profile.ptr, axisOrigin.fw, axis.fw, angle, $0) }
    }

    enum BoolOp: Int32 { case union = 0, cut = 1, intersect = 2 }

    static func boolean(_ a: Shape, _ b: Shape, _ op: BoolOp) throws -> Shape {
        try run { fw_boolean(a.ptr, b.ptr, op.rawValue, $0) }
    }

    static func fillet(_ s: Shape, edges: [Int], radius: Double) throws -> Shape {
        let e = edges.map { Int32($0) }
        return try run { fw_fillet(s.ptr, e, Int32(e.count), radius, $0) }
    }

    static func chamfer(_ s: Shape, edges: [Int], distance: Double) throws -> Shape {
        let e = edges.map { Int32($0) }
        return try run { fw_chamfer(s.ptr, e, Int32(e.count), distance, $0) }
    }

    static func shell(_ s: Shape, openFaces: [Int], thickness: Double) throws -> Shape {
        let f = openFaces.map { Int32($0) }
        return try run { fw_shell(s.ptr, f, Int32(f.count), thickness, $0) }
    }

    static func pushPull(_ s: Shape, face: Int, distance: Double) throws -> Shape {
        try run { fw_push_pull(s.ptr, Int32(face), distance, $0) }
    }

    /// Rotation (axis/angle about pivot), uniform scale about pivot, then translation.
    static func transform(_ s: Shape, translation: Vec3, axis: Vec3 = Vec3(0, 0, 1), angle: Double = 0,
                          pivot: Vec3 = .zero, scale: Double = 1) throws -> Shape {
        let k = axis.normalized
        let c = cos(angle), sn = sin(angle), t = 1 - c
        // Rodrigues rotation matrix
        var R = [
            [t * k.x * k.x + c, t * k.x * k.y - sn * k.z, t * k.x * k.z + sn * k.y],
            [t * k.x * k.y + sn * k.z, t * k.y * k.y + c, t * k.y * k.z - sn * k.x],
            [t * k.x * k.z - sn * k.y, t * k.y * k.z + sn * k.x, t * k.z * k.z + c],
        ]
        for i in 0..<3 { for j in 0..<3 { R[i][j] *= scale } }
        var m = [Double](repeating: 0, count: 12)
        for i in 0..<3 {
            let rp = R[i][0] * pivot.x + R[i][1] * pivot.y + R[i][2] * pivot.z
            m[i * 4 + 0] = R[i][0]; m[i * 4 + 1] = R[i][1]; m[i * 4 + 2] = R[i][2]
            m[i * 4 + 3] = pivot[i] - rp + translation[i]
        }
        return try run { fw_transform(s.ptr, m, $0) }
    }

    static func mirror(_ s: Shape, plane: Plane) throws -> Shape {
        try run { fw_mirror(s.ptr, plane.fw, $0) }
    }

    static func holeTool(at point: Vec3, direction: Vec3, diameter: Double, depth: Double,
                         counterbore: (Double, Double)? = nil, countersink: Double? = nil) throws -> Shape {
        try run {
            fw_hole_tool(point.fw, direction.fw, diameter, depth,
                         counterbore?.0 ?? 0, counterbore?.1 ?? 0, countersink ?? 0, $0)
        }
    }

    static func split(_ s: Shape, plane: Plane) throws -> Shape {
        try run { fw_split(s.ptr, plane.fw, $0) }
    }

    /// Shortest distance between parts of shapes. kind: 0 whole, 1 face, 2 edge.
    static func distance(_ a: Shape, kind ka: Int, index ia: Int, _ b: Shape, kind kb: Int, index ib: Int)
        -> (distance: Double, a: Vec3, b: Vec3)? {
        var pa = FWVec3(), pb = FWVec3()
        let d = fw_distance(a.ptr, Int32(ka), Int32(ia), b.ptr, Int32(kb), Int32(ib), &pa, &pb)
        return d < 0 ? nil : (d, Vec3(pa), Vec3(pb))
    }

    static func writeSTEP(_ shapes: [Shape], to url: URL) throws {
        var err = FWError()
        let ptrs: [OpaquePointer?] = shapes.map { $0.ptr }
        let ok = ptrs.withUnsafeBufferPointer { buf in
            fw_write_step(buf.baseAddress, Int32(shapes.count), url.path, &err)
        }
        if !ok {
            let msg = withUnsafeBytes(of: &err.message) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
            throw KernelError(message: msg)
        }
    }

    static func readSTEP(_ url: URL) throws -> Shape {
        try run { fw_read_step(url.path, $0) }
    }

    static func shape(fromBREP data: Data) throws -> Shape {
        try data.withUnsafeBytes { raw in
            try run { fw_shape_from_brep(raw.bindMemory(to: CChar.self).baseAddress, Int64(data.count), $0) }
        }
    }
}

// MARK: - Bridging helpers

extension SIMD3 where Scalar == Double {
    init(_ v: FWVec3) { self.init(v.x, v.y, v.z) }
    var fw: FWVec3 { FWVec3(x: x, y: y, z: z) }
}

extension SIMD2 where Scalar == Double {
    var fw: FWVec2 { FWVec2(x: x, y: y) }
}

extension Plane {
    var fw: FWPlane { FWPlane(origin: origin.fw, normal: normal.fw, xDir: xDir.fw) }
}

extension RegionSegment {
    var fw: FWSegment {
        switch self {
        case .line(let a, let b):
            return FWSegment(kind: Int32(FWSegLine.rawValue), a: a.fw, b: b.fw, c: FWVec2())
        case .arc(let c, let r, let s, let w):
            if abs(abs(w) - 2 * .pi) < 1e-9 {
                return FWSegment(kind: Int32(FWSegCircle.rawValue), a: c.fw, b: FWVec2(x: r, y: 0), c: FWVec2())
            }
            return FWSegment(kind: Int32(FWSegArc.rawValue), a: startPoint.fw, b: point(at: 0.5).fw, c: endPoint.fw)
        }
    }
}
