import CoreGraphics
import Foundation
import simd

/// Orbit camera around a target point. Z is up (as in 3D printing).
struct Camera: Equatable {
    var target: Vec3 = Vec3(0, 0, 0)
    var distance: Double = 180
    /// Rotation around Z (radians), 0 = looking from +X.
    var yaw: Double = -.pi / 3
    /// Height angle (radians), positive = looking down from above.
    var pitch: Double = 0.55
    var fovY: Double = 35 * .pi / 180
    var orthographic = false

    static let maxPitch = 89.5 * Double.pi / 180

    var direction: Vec3 { Vec3(cos(pitch) * cos(yaw), cos(pitch) * sin(yaw), sin(pitch)) }
    var eye: Vec3 { target + direction * distance }
    var forward: Vec3 { -direction }
    var right: Vec3 {
        let r = forward.cross(Vec3(0, 0, 1))
        return r.length < 1e-9 ? Vec3(1, 0, 0) : r.normalized
    }
    var up: Vec3 { right.cross(forward).normalized }

    var viewMatrix: simd_double4x4 {
        let f = forward, r = right, u = up, e = eye
        return simd_double4x4(rows: [
            SIMD4(r.x, r.y, r.z, -r.dot(e)),
            SIMD4(u.x, u.y, u.z, -u.dot(e)),
            SIMD4(-f.x, -f.y, -f.z, f.dot(e)),
            SIMD4(0, 0, 0, 1),
        ])
    }

    func projectionMatrix(aspect: Double) -> simd_double4x4 {
        let near = max(distance * 0.02, 0.05), far = distance * 30 + 1000
        if orthographic {
            let h = distance * tan(fovY / 2), w = h * aspect
            return simd_double4x4(rows: [
                SIMD4(1 / w, 0, 0, 0),
                SIMD4(0, 1 / h, 0, 0),
                SIMD4(0, 0, -1 / (far - near), -near / (far - near)),
                SIMD4(0, 0, 0, 1),
            ])
        }
        let y = 1 / tan(fovY / 2), x = y / aspect
        // Metal clip space: z in [0, 1]
        return simd_double4x4(rows: [
            SIMD4(x, 0, 0, 0),
            SIMD4(0, y, 0, 0),
            SIMD4(0, 0, far / (near - far), near * far / (near - far)),
            SIMD4(0, 0, -1, 0),
        ])
    }

    func viewProjection(size: CGSize) -> simd_double4x4 {
        projectionMatrix(aspect: Double(max(size.width, 1) / max(size.height, 1))) * viewMatrix
    }

    /// Screen point (points, origin top-left) for a world position.
    func project(_ p: Vec3, size: CGSize) -> CGPoint? {
        let c = viewProjection(size: size) * SIMD4(p.x, p.y, p.z, 1)
        if c.w <= 1e-9 { return nil }
        let ndc = SIMD2(c.x / c.w, c.y / c.w)
        return CGPoint(x: (ndc.x + 1) / 2 * size.width, y: (1 - ndc.y) / 2 * size.height)
    }

    /// The ray from the eye through a screen point.
    func ray(at point: CGPoint, size: CGSize) -> (origin: Vec3, direction: Vec3) {
        let nx = Double(point.x / max(size.width, 1)) * 2 - 1
        let ny = 1 - Double(point.y / max(size.height, 1)) * 2
        let aspect = Double(size.width / max(size.height, 1))
        let h = tan(fovY / 2), w = h * aspect
        if orthographic {
            let o = eye + right * (nx * w * distance) + up * (ny * h * distance)
            return (o, forward)
        }
        let d = (forward + right * (nx * w) + up * (ny * h)).normalized
        return (eye, d)
    }

    /// World units per screen point at the target's depth.
    func unitsPerPoint(size: CGSize) -> Double {
        2 * distance * tan(fovY / 2) / Double(max(size.height, 1))
    }

    mutating func orbit(dx: Double, dy: Double) {
        yaw -= dx * 0.008
        pitch = min(max(pitch + dy * 0.008, -Camera.maxPitch), Camera.maxPitch)
    }

    mutating func pan(dx: Double, dy: Double, size: CGSize) {
        let s = unitsPerPoint(size: size)
        target += right * (-dx * s) + up * (dy * s)
    }

    /// Zooms by `factor` (< 1 = closer) towards the point under the cursor.
    mutating func zoom(factor: Double, at point: CGPoint?, size: CGSize) {
        let f = min(max(factor, 0.2), 5)
        if let point {
            let (o, d) = ray(at: point, size: size)
            let plane = Plane(origin: target, normal: forward, xDir: right)
            if let t = plane.intersect(rayOrigin: o, rayDir: d) {
                let hit = o + d * t
                target += (hit - target) * (1 - f)
            }
        }
        distance = min(max(distance * f, 1), 20000)
    }

    /// Frames a bounding box.
    /// `aspect` = width / height of the view; narrow (portrait phone) views need to back off further.
    mutating func fit(_ box: Box3, aspect: Double = 1.5) {
        guard !box.isEmpty else { return }
        target = box.center
        let fitHeight = max(box.diagonal, 10) / (2 * tan(fovY / 2))
        distance = fitHeight / min(max(aspect, 0.2), 1) * 1.25
    }

    /// Looks straight at a plane (for sketching).
    mutating func face(_ plane: Plane) {
        let n = plane.normal.normalized
        pitch = asin(min(max(n.z, -1), 1))
        pitch = min(max(pitch, -Camera.maxPitch), Camera.maxPitch)
        if abs(n.z) < 0.999 {
            yaw = atan2(n.y, n.x)
        } else {
            // Top/bottom view: the screen's right is (-sin yaw, cos yaw, 0); make it the plane's x axis.
            yaw = atan2(-plane.xDir.x, plane.xDir.y)
        }
        // Keep looking at the same spot, moved onto the plane.
        target -= plane.normal * plane.signedDistance(target)
    }

    static func interpolate(_ a: Camera, _ b: Camera, _ t: Double) -> Camera {
        var c = b
        let s = t * t * (3 - 2 * t)
        c.target = a.target + (b.target - a.target) * s
        c.distance = a.distance + (b.distance - a.distance) * s
        var dyaw = b.yaw - a.yaw
        while dyaw > .pi { dyaw -= 2 * .pi }
        while dyaw < -.pi { dyaw += 2 * .pi }
        c.yaw = a.yaw + dyaw * s
        c.pitch = a.pitch + (b.pitch - a.pitch) * s
        return c
    }
}

extension simd_double4x4 {
    var float: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4<Float>(Float(columns.0.x), Float(columns.0.y), Float(columns.0.z), Float(columns.0.w)),
            SIMD4<Float>(Float(columns.1.x), Float(columns.1.y), Float(columns.1.z), Float(columns.1.w)),
            SIMD4<Float>(Float(columns.2.x), Float(columns.2.y), Float(columns.2.z), Float(columns.2.w)),
            SIMD4<Float>(Float(columns.3.x), Float(columns.3.y), Float(columns.3.z), Float(columns.3.w))))
    }
}
