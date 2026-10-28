import simd
import SwiftUI

/// Putting parts the right way onto the print bed.
extension EditorModel {
    /// Rotation that turns `n` into straight down (−Z): axis and angle.
    static func rotationToDown(_ n: Vec3) -> (axis: Vec3, angle: Double) {
        let down = Vec3(0, 0, -1)
        let a = n.normalized
        let c = max(-1, min(1, a.dot(down)))
        if c > 0.999999 { return (Vec3(0, 0, 1), 0) }
        if c < -0.999999 { return (Vec3(1, 0, 0), .pi) }
        return (a.cross(down).normalized, acos(c))
    }

    /// The transform that rotates bodies so `downNormal` faces the bed, then sets them on it, centred.
    func bedTransform(bodies: [BuiltBody], downNormal: Vec3) -> TransformFeature? {
        guard !bodies.isEmpty else { return nil }
        var box = Box3.empty
        for b in bodies { box.add(b.props.bounds) }
        let pivot = box.center
        let (axis, angle) = Self.rotationToDown(downNormal)
        // Where the vertices end up after the rotation, to find the new footprint.
        let k = axis.normalized, c = cos(angle), s = sin(angle)
        func rotate(_ p: Vec3) -> Vec3 {
            let v = p - pivot
            return pivot + v * c + k.cross(v) * s + k * (k.dot(v)) * (1 - c)
        }
        var rotated = Box3.empty
        for b in bodies {
            for p in b.mesh.positions { rotated.add(rotate(Vec3(Double(p.x), Double(p.y), Double(p.z)))) }
        }
        guard !rotated.isEmpty else { return nil }
        let translation = Vec3(-rotated.center.x, -rotated.center.y, -rotated.min.z)
        return TransformFeature(bodies: bodies.map(\.id), translation: translation, axis: axis, angle: angle, pivot: pivot)
    }

    /// Turns the body so the selected flat face lies on the print bed.
    func layFlat() {
        guard let (body, face) = selectedFaces.first(where: { $0.1.isPlanar }),
              let t = bedTransform(bodies: [body], downNormal: face.normal) else {
            show(String(localized: "Tap a flat face first."))
            return
        }
        var d = design
        d.features.append(Feature(name: d.nextName(for: .transform), operation: .transform(t)))
        selection = []
        commit(d, action: String(localized: "Lay flat"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.fitView() }
    }

    /// Tries the main directions and the biggest flat faces as "down" and keeps the one with the
    /// least overhang (ties: the lower part, which prints faster and steadier).
    func autoOrient() {
        guard ProStore.shared.requirePro(.autoOrient, else: { showPaywall = true }) else { return }
        let bodies = output.bodies.filter { !design.style($0.id).hidden }
        guard !bodies.isEmpty else { return }
        var candidates: [Vec3] = [Vec3(0, 0, -1), Vec3(0, 0, 1), Vec3(1, 0, 0), Vec3(-1, 0, 0), Vec3(0, 1, 0), Vec3(0, -1, 0)]
        let flat = bodies.flatMap { $0.faces.filter(\.isPlanar) }.sorted { $0.area > $1.area }.prefix(12)
        for f in flat where !candidates.contains(where: { ($0 - f.normal).length < 1e-3 }) { candidates.append(f.normal) }

        // Triangles of all bodies, once.
        var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for b in bodies {
            let m = b.mesh
            for t in 0..<m.triangleCount {
                tris.append((m.positions[Int(m.indices[t * 3])], m.positions[Int(m.indices[t * 3 + 1])], m.positions[Int(m.indices[t * 3 + 2])]))
            }
        }
        var best: (score: Double, n: Vec3)? = nil
        let limit = sin(45.0 * .pi / 180)
        for n in candidates {
            let (axis, angle) = Self.rotationToDown(n)
            let k = axis.normalized, c = cos(angle), s = sin(angle)
            func rot(_ p: SIMD3<Float>) -> Vec3 {
                let v = Vec3(Double(p.x), Double(p.y), Double(p.z))
                return v * c + k.cross(v) * s + k * (k.dot(v)) * (1 - c)
            }
            var minZ = Double.infinity, maxZ = -Double.infinity
            var rotatedTris: [(Vec3, Vec3, Vec3)] = []
            rotatedTris.reserveCapacity(tris.count)
            for (a, b, cc) in tris {
                let ra = rot(a), rb = rot(b), rc = rot(cc)
                minZ = min(minZ, ra.z, rb.z, rc.z); maxZ = max(maxZ, ra.z, rb.z, rc.z)
                rotatedTris.append((ra, rb, rc))
            }
            var overhang = 0.0
            for (a, b, cc) in rotatedTris {
                let nrm = (b - a).cross(cc - a)
                let len = nrm.length
                guard len > 1e-12 else { continue }
                if nrm.z / len < -limit && max(a.z, b.z, cc.z) > minZ + 0.05 { overhang += len / 2 }
            }
            let score = overhang + (maxZ - minZ) * 0.5
            if best == nil || score < best!.score - 1e-6 { best = (score, n) }
        }
        guard let n = best?.n, let t = bedTransform(bodies: bodies, downNormal: n) else { return }
        if t.angle.magnitude < 1e-6 && t.translation.length < 1e-6 {
            show(String(localized: "This is already the best way round."))
            return
        }
        var d = design
        d.features.append(Feature(name: d.nextName(for: .transform), operation: .transform(t)))
        commit(d, action: String(localized: "Auto-orient"))
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.runPrintCheck() }
    }
}
