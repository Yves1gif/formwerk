import Foundation
import simd

// Memory layouts shared with Shaders.metal.

struct GPUUniforms {
    var viewProj: simd_float4x4
    var cameraPos: SIMD4<Float>
    var viewDir: SIMD4<Float>
    var clipPlane: SIMD4<Float>
    var viewport: SIMD2<Float>
    var clipOn: Float
    var pixelScale: Float
}

struct GPUMeshVertex {
    var px, py, pz: Float
    var nx, ny, nz: Float
    var face: UInt32
}

struct GPUBodyUniforms {
    var color: SIMD4<Float>
    var hoverColor: SIMD4<Float>
    var selectColor: SIMD4<Float>
    var pickBase: UInt32
    var alpha: Float
    var pad: SIMD2<Float> = .zero
}

struct GPULineSegment {
    var ax, ay, az: Float
    var bx, by, bz: Float
    var r, g, b, a: Float
    var width: Float
    var pick: UInt32

    init(_ p: SIMD3<Float>, _ q: SIMD3<Float>, color: SIMD4<Float>, width: Float, pick: UInt32 = 0) {
        ax = p.x; ay = p.y; az = p.z
        bx = q.x; by = q.y; bz = q.z
        r = color.x; g = color.y; b = color.z; a = color.w
        self.width = width
        self.pick = pick
    }
}

struct GPUPointSprite {
    var x, y, z: Float
    var r, g, b, a: Float
    var size: Float
    var pick: UInt32

    init(_ p: SIMD3<Float>, color: SIMD4<Float>, size: Float, pick: UInt32 = 0) {
        x = p.x; y = p.y; z = p.z
        r = color.x; g = color.y; b = color.z; a = color.w
        self.size = size
        self.pick = pick
    }
}

/// What the renderer draws. Built by the editor; cheap to rebuild when only states change.
struct RenderScene {
    struct Body {
        /// Changes whenever the mesh changes (the renderer caches GPU buffers by it).
        var meshKey: String
        var mesh: TriangleMesh
        var faceCount: Int
        var color: SIMD4<Float>
        var alpha: Float = 1
        /// Per face (index 0 unused): 0 normal, 1 hover, 2 selected, 3 overhang, 4 thin.
        var faceStates: [UInt8]
        /// Edge index → 0 normal, 1 hover, 2 selected.
        var edgeStates: [Int32: UInt8]
        var pickable = true
    }

    var bodies: [Body] = []
    /// Extra lines (sketch, grid, axes, gizmos).
    var lines: [GPULineSegment] = []
    /// Lines drawn on top of everything (the active sketch).
    var overlayLines: [GPULineSegment] = []
    var overlayPoints: [GPUPointSprite] = []
    /// Translucent fills (sketch regions): triangles + colour.
    var fills: [(triangles: [SIMD3<Float>], color: SIMD4<Float>)] = []
    var clipPlane: SIMD4<Float>? = nil
    var showGrid = true
    var gridPlane: Plane = .xy
    var edgeColor = SIMD4<Float>(0.13, 0.14, 0.17, 1)
    /// Werk Blue for "you could pick this", Signal Orange for "picked" (design system).
    var hoverColor = SIMD4<Float>(0.12, 0.37, 0.84, 1)
    var selectColor = SIMD4<Float>(1.0, 0.54, 0.165, 1)
}

/// What a tap or hover hit in the 3D view.
enum PickHit: Equatable {
    case face(body: Int, face: Int)
    case edge(body: Int, edge: Int)
}

enum PickCode {
    static let edgeFlag: UInt32 = 1 << 19
    static func face(body: Int, face: Int) -> UInt32 { UInt32(body + 1) << 20 | UInt32(face) }
    static func edge(body: Int, edge: Int) -> UInt32 { UInt32(body + 1) << 20 | edgeFlag | UInt32(edge) }
    static func decode(_ v: UInt32) -> PickHit? {
        guard v != 0 else { return nil }
        let body = Int(v >> 20) - 1
        guard body >= 0 else { return nil }
        let index = Int(v & 0x7FFFF)
        return v & edgeFlag != 0 ? .edge(body: body, edge: index) : .face(body: body, face: index)
    }
}

enum Palette {
    /// Body colours: calm, distinct, readable in light and dark mode.
    static let bodies: [SIMD4<Float>] = [
        SIMD4(0.72, 0.75, 0.80, 1),  // aluminium
        SIMD4(0.36, 0.62, 0.90, 1),  // blue
        SIMD4(0.95, 0.60, 0.25, 1),  // orange
        SIMD4(0.40, 0.76, 0.52, 1),  // green
        SIMD4(0.88, 0.42, 0.48, 1),  // red
        SIMD4(0.66, 0.52, 0.88, 1),  // violet
        SIMD4(0.93, 0.80, 0.30, 1),  // yellow
        SIMD4(0.30, 0.30, 0.33, 1),  // graphite
    ]
}
