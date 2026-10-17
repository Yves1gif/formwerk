import Foundation
import simd

typealias Vec2 = SIMD2<Double>
typealias Vec3 = SIMD3<Double>

extension SIMD2 where Scalar == Double {
    var length: Double { simd_length(self) }
    var normalized: Vec2 { let l = length; return l > 1e-12 ? self / l : Vec2(1, 0) }
    var perpendicular: Vec2 { Vec2(-y, x) }
    func cross(_ o: Vec2) -> Double { x * o.y - y * o.x }
    func dot(_ o: Vec2) -> Double { simd_dot(self, o) }
    var angle: Double { atan2(y, x) }
}

extension SIMD3 where Scalar == Double {
    var length: Double { simd_length(self) }
    var normalized: Vec3 { let l = length; return l > 1e-12 ? self / l : Vec3(0, 0, 1) }
    func cross(_ o: Vec3) -> Vec3 { simd_cross(self, o) }
    func dot(_ o: Vec3) -> Double { simd_dot(self, o) }
    var float3: SIMD3<Float> { SIMD3<Float>(Float(x), Float(y), Float(z)) }
}

/// A plane with its own 2D coordinates (u along xDir, v along normal × xDir).
struct Plane: Codable, Equatable, Hashable {
    var origin: Vec3
    var normal: Vec3
    var xDir: Vec3

    var yDir: Vec3 { normal.cross(xDir) }

    static let xy = Plane(origin: .zero, normal: Vec3(0, 0, 1), xDir: Vec3(1, 0, 0))
    static let xz = Plane(origin: .zero, normal: Vec3(0, -1, 0), xDir: Vec3(1, 0, 0))
    static let yz = Plane(origin: .zero, normal: Vec3(1, 0, 0), xDir: Vec3(0, 1, 0))

    func world(_ p: Vec2) -> Vec3 { origin + xDir * p.x + yDir * p.y }
    func local(_ p: Vec3) -> Vec2 { let d = p - origin; return Vec2(d.dot(xDir), d.dot(yDir)) }
    func signedDistance(_ p: Vec3) -> Double { (p - origin).dot(normal) }

    /// Intersects a ray with the plane. Returns the distance along the ray.
    func intersect(rayOrigin: Vec3, rayDir: Vec3) -> Double? {
        let denom = rayDir.dot(normal)
        if abs(denom) < 1e-9 { return nil }
        let t = (origin - rayOrigin).dot(normal) / denom
        return t >= 0 ? t : nil
    }

    func offset(by d: Double) -> Plane { Plane(origin: origin + normal * d, normal: normal, xDir: xDir) }

    /// A sketch plane on a model face: world axes stay recognisable and the origin is the world
    /// origin projected onto the face. That keeps sketch coordinates stable when the face grows.
    static func onFace(normal n: Vec3, through point: Vec3) -> Plane {
        let normal = n.normalized
        let worldX = Vec3(1, 0, 0), worldY = Vec3(0, 1, 0)
        var x = worldX - normal * worldX.dot(normal)
        if x.length < 0.3 { x = worldY - normal * worldY.dot(normal) }
        x = x.normalized
        // The world origin projected onto the face's plane.
        return Plane(origin: normal * point.dot(normal), normal: normal, xDir: x)
    }
}

/// Axis-aligned bounding box.
struct Box3: Equatable {
    var min: Vec3
    var max: Vec3
    static let empty = Box3(min: Vec3(repeating: .infinity), max: Vec3(repeating: -.infinity))
    var isEmpty: Bool { min.x > max.x }
    var size: Vec3 { isEmpty ? .zero : max - min }
    var center: Vec3 { isEmpty ? .zero : (min + max) / 2 }
    var diagonal: Double { size.length }
    mutating func add(_ p: Vec3) { min = simd_min(min, p); max = simd_max(max, p) }
    mutating func add(_ b: Box3) { if !b.isEmpty { add(b.min); add(b.max) } }
}

enum LengthUnit: String, Codable, CaseIterable, Identifiable {
    case mm, cm, m, inch
    var id: String { rawValue }
    var millimetres: Double {
        switch self { case .mm: 1; case .cm: 10; case .m: 1000; case .inch: 25.4 }
    }
    var symbol: String {
        switch self { case .mm: "mm"; case .cm: "cm"; case .m: "m"; case .inch: "in" }
    }
}

/// Formats lengths for labels: trims trailing zeros, uses the user's decimal separator.
enum Format {
    static func number(_ v: Double, digits: Int = 2) -> String {
        let f = NumberFormatter()
        f.locale = .current
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = digits
        f.minimumIntegerDigits = 1
        return f.string(from: NSNumber(value: abs(v) < 1e-9 ? 0 : v)) ?? String(v)
    }

    static func length(_ mm: Double, unit: LengthUnit = .mm) -> String {
        "\(number(mm / unit.millimetres, digits: unit == .mm ? 2 : 3)) \(unit.symbol)"
    }

    static func angle(_ radians: Double) -> String { "\(number(radians * 180 / .pi, digits: 1))°" }
}
