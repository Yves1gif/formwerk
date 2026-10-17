import Foundation

/// A body after a rebuild, with everything the UI needs precomputed off the main thread.
struct BuiltBody: Identifiable {
    let id: String
    let shape: Shape
    let mesh: TriangleMesh
    let meshKey: String
    let props: ShapeProperties
    let faces: [FaceInfo]
    let edges: [EdgeInfo]
    /// edge index → indices of its neighbouring faces
    let edgeFaces: [Int: [Int]]
    let isValid: Bool

    func face(_ i: Int) -> FaceInfo? { faces.first { $0.index == i } }
    func edge(_ i: Int) -> EdgeInfo? { edges.first { $0.index == i } }

    func faceRef(_ i: Int) -> FaceRef? { face(i).map { FaceRef(body: id, info: $0) } }

    func edgeRef(_ i: Int) -> EdgeRef? {
        guard let e = edge(i) else { return nil }
        let n = (edgeFaces[i] ?? []).compactMap { face($0) }
        return EdgeRef(body: id, kind: e.kind.rawValue, midpoint: e.midpoint, start: e.start, end: e.end,
                       length: e.length, radius: e.radius, faceKinds: n.map { $0.kind.rawValue }, faceNormals: n.map(\.normal))
    }
}

struct BuiltSketch {
    let plane: Plane
    let regions: [SketchRegion]
    let regionTriangles: [[SIMD3<Float>]]
}

struct BuildOutput {
    var bodies: [BuiltBody] = []
    var statuses: [UUID: ModelBuilder.Status] = [:]
    var sketches: [UUID: BuiltSketch] = [:]

    func body(_ id: String) -> BuiltBody? { bodies.first { $0.id == id } }
    var bounds: Box3 {
        var b = Box3.empty
        for body in bodies { b.add(body.props.bounds) }
        return b
    }
}

/// Runs every kernel call on one serial queue: rebuilds, tessellation, measuring, exporting.
/// OCCT may change a shape's cached triangulation while meshing, so nothing else may touch shapes concurrently.
final class BuildWorker: @unchecked Sendable {
    let queue = DispatchQueue(label: "com.yvesf.formwerk.build", qos: .userInitiated)
    private let builder = ModelBuilder()
    private var bodyCache: [ObjectIdentifier: (shape: Shape, body: BuiltBody)] = [:]
    private var sketchCache: [UUID: (plane: Plane, regions: [SketchRegion], built: BuiltSketch)] = [:]
    private var meshSerial = 0

    /// Builds on the queue and calls back on the main thread.
    func build(_ design: Design, end: Int?, completion: @escaping @MainActor (BuildOutput) -> Void) {
        queue.async {
            let out = self.buildNow(design, end: end)
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(out) } }
        }
    }

    /// Runs any kernel work on the queue and returns the result on the main thread.
    func run<T>(_ work: @escaping () -> T, completion: @escaping @MainActor (T) -> Void) {
        queue.async {
            let r = work()
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(r) } }
        }
    }

    private func buildNow(_ design: Design, end: Int?) -> BuildOutput {
        let state = builder.build(design, upTo: end)
        var out = BuildOutput()
        out.statuses = state.statuses
        var keep: [ObjectIdentifier: (shape: Shape, body: BuiltBody)] = [:]
        for b in state.bodies {
            let key = ObjectIdentifier(b.shape)
            if let cached = bodyCache[key], cached.body.id == b.id {
                out.bodies.append(cached.body)
                keep[key] = cached
                continue
            }
            let built = describe(b)
            out.bodies.append(built)
            keep[key] = (b.shape, built)
        }
        bodyCache = keep

        var sketches: [UUID: BuiltSketch] = [:]
        for (id, info) in state.sketches {
            if let c = sketchCache[id], c.plane == info.plane, c.regions == info.regions {
                sketches[id] = c.built
                continue
            }
            let built = BuiltSketch(plane: info.plane, regions: info.regions,
                                    regionTriangles: info.regions.map { Self.triangles(of: $0, on: info.plane) })
            sketches[id] = built
            sketchCache[id] = (info.plane, info.regions, built)
        }
        out.sketches = sketches
        return out
    }

    private func describe(_ b: ModelBuilder.Body) -> BuiltBody {
        let props = b.shape.properties
        let size = max(props.bounds.diagonal, 1)
        let mesh = b.shape.mesh(linear: min(max(size * 0.0006, 0.005), 0.2), angular: 0.3)
        let faces = b.shape.faces
        let edges = b.shape.edges
        var edgeFaces: [Int: [Int]] = [:]
        for e in edges { edgeFaces[e.index] = b.shape.facesOfEdge(e.index) }
        meshSerial += 1
        return BuiltBody(id: b.id, shape: b.shape, mesh: mesh, meshKey: "\(b.id)#\(meshSerial)", props: props,
                         faces: faces, edges: edges, edgeFaces: edgeFaces, isValid: b.shape.isValidSolid)
    }

    /// Triangles of a sketch region for drawing (lets the kernel triangulate holes and arcs).
    static func triangles(of region: SketchRegion, on plane: Plane) -> [SIMD3<Float>] {
        guard let face = try? Kernel.face(on: plane, loops: region.loops) else { return [] }
        let m = face.mesh(linear: 0.05, angular: 0.25)
        var tris: [SIMD3<Float>] = []
        tris.reserveCapacity(m.indices.count)
        for i in m.indices { tris.append(m.positions[Int(i)]) }
        return tris
    }

    /// Fills for a sketch that is being edited (computed on the queue, regions may change at any time).
    func regionTriangles(_ regions: [SketchRegion], plane: Plane, completion: @escaping @MainActor ([[SIMD3<Float>]]) -> Void) {
        run({ regions.map { Self.triangles(of: $0, on: plane) } }, completion: completion)
    }
}
