import Foundation

/// Ready-made starting designs. Built from ordinary features, so everything stays editable.
enum Templates {
    /// A rounded name tag with a ring hole and raised text.
    static func keychain(text: String = "Formwerk") -> Design {
        var d = Design()
        var sk = Sketch()
        // Slot outline 60 × 20 mm
        let a = sk.addPoint(Vec2(0, 0)), b = sk.addPoint(Vec2(40, 0))
        let p1 = sk.addPoint(Vec2(0, -10)), p2 = sk.addPoint(Vec2(40, -10))
        let p3 = sk.addPoint(Vec2(40, 10)), p4 = sk.addPoint(Vec2(0, 10))
        let l1 = sk.addLine(p1, p2), l2 = sk.addLine(p3, p4)
        let a1 = sk.addArc(center: b, start: p2, end: p3), a2 = sk.addArc(center: a, start: p4, end: p1)
        sk.addConstraint(.tangent, [l1, a1]); sk.addConstraint(.tangent, [l2, a1])
        sk.addConstraint(.tangent, [l1, a2]); sk.addConstraint(.tangent, [l2, a2])
        sk.addConstraint(.equal, [a1, a2])
        sk.addConstraint(.horizontal, [l1])
        sk.addConstraint(.radius, [a1], value: 10)
        sk.addConstraint(.length, [l1], value: 40)
        // Ring hole
        let hc = sk.addPoint(Vec2(-2, 0))
        let hole = sk.addCircle(center: hc, radius: 3)
        sk.addConstraint(.concentric, [hole, a2])
        sk.addConstraint(.diameter, [hole], value: 6)
        sk = SketchSolver.solve(sk).sketch
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let outer = SketchRegions.find(in: sk).max { $0.area < $1.area }!
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(sketch: sketch.id, regionSeeds: [outer.samplePoint], distance: 3)))
        d.features.append(ext)
        d.features.append(Feature(name: "Text 1", operation: .text(TextFeature(
            plane: .origin(.xy, offset: 3), position: Vec2(23, 0), text: text, fontName: "Helvetica-Bold",
            size: 6, depth: 1, mode: .join, target: ext.id.uuidString))))
        return d
    }

    /// An open box with 1.6 mm walls.
    static func box() -> Design {
        var d = Design()
        var sk = Sketch()
        let p = [sk.addPoint(Vec2(-30, -20)), sk.addPoint(Vec2(30, -20)), sk.addPoint(Vec2(30, 20)), sk.addPoint(Vec2(-30, 20))]
        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
        sk.addConstraint(.horizontal, [l[0]]); sk.addConstraint(.horizontal, [l[2]])
        sk.addConstraint(.vertical, [l[1]]); sk.addConstraint(.vertical, [l[3]])
        sk.addConstraint(.length, [l[0]], value: 60); sk.addConstraint(.length, [l[1]], value: 40)
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(sketch: sketch.id, regionSeeds: [Vec2(0, 0)], distance: 30)))
        d.features.append(ext)
        let top = FaceRef(body: ext.id.uuidString, kind: 0, centroid: Vec3(0, 0, 30), normal: Vec3(0, 0, 1), area: 2400)
        d.features.append(Feature(name: "Shell 1", operation: .shell(ShellFeature(body: ext.id.uuidString, openFaces: [top], thickness: 1.6))))
        return d
    }

    /// An L-shaped shelf bracket with two countersunk M4 screw holes.
    static func wallBracket() -> Design {
        var d = Design()
        var sk = Sketch()
        let pts = [Vec2(0, 0), Vec2(40, 0), Vec2(40, 4), Vec2(4, 4), Vec2(4, 40), Vec2(0, 40)].map { sk.addPoint($0) }
        let lines = (0..<6).map { sk.addLine(pts[$0], pts[($0 + 1) % 6]) }
        for (i, l) in lines.enumerated() { sk.addConstraint(i % 2 == 0 ? .horizontal : .vertical, [l]) }
        sk.addConstraint(.coincident, [pts[0], Sketch.originID])
        sk.addConstraint(.length, [lines[0]], value: 40)
        sk.addConstraint(.length, [lines[5]], value: 40)
        sk.addConstraint(.length, [lines[1]], value: 4)
        sk.addConstraint(.length, [lines[4]], value: 4)
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(sketch: sketch.id, regionSeeds: [Vec2(2, 2)], distance: 20, symmetric: true)))
        d.features.append(ext)
        let body = ext.id.uuidString
        let wallFace = FaceRef(body: body, kind: 0, centroid: Vec3(4, 0, 22), normal: Vec3(1, 0, 0), area: 36 * 20)
        let shelfFace = FaceRef(body: body, kind: 0, centroid: Vec3(22, 0, 4), normal: Vec3(0, 0, 1), area: 36 * 20)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(
            face: wallFace, positions: [Vec2(0, 28)], kind: .countersink, diameter: 4.5, depth: 0, headDiameter: 8.8, headDepth: 4.4))))
        d.features.append(Feature(name: "Hole 2", operation: .hole(HoleFeature(
            face: shelfFace, positions: [Vec2(28, 0)], kind: .countersink, diameter: 4.5, depth: 0, headDiameter: 8.8, headDepth: 4.4))))
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: [
            EdgeRef(body: body, kind: 0, midpoint: Vec3(4, 0, 4), start: Vec3(4, -10, 4), end: Vec3(4, 10, 4), length: 20,
                    faceKinds: [0, 0], faceNormals: [Vec3(1, 0, 0), Vec3(0, 0, 1)]),
        ], value: 3))))
        return d
    }

    /// A plant pot: a turned profile with 4 mm walls and a drain hole.
    static func plantPot() -> Design {
        var d = Design()
        var sk = Sketch()
        let pts = [Vec2(0, 0), Vec2(35, 0), Vec2(45, 60), Vec2(41, 60), Vec2(31.5, 4), Vec2(0, 4)].map { sk.addPoint($0) }
        for i in 0..<6 { sk.addLine(pts[i], pts[(i + 1) % 6]) }
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let rev = Feature(name: "Revolve 1", operation: .revolve(RevolveFeature(sketch: sketch.id, regionSeeds: [Vec2(20, 2)], axisCurve: nil)))
        d.features.append(rev)
        let inner = FaceRef(body: rev.id.uuidString, kind: 0, centroid: Vec3(0, 0, 4), normal: Vec3(0, 0, 1), area: .pi * 31.5 * 31.5)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(face: inner, positions: [Vec2(0, 0)], diameter: 8, depth: 0))))
        return d
    }

    /// A phone stand: side profile with a backrest and a front lip, 70 mm wide.
    static func phoneStand() -> Design {
        var d = Design()
        var sk = Sketch()
        let outline = [Vec2(0, 0), Vec2(75, 0), Vec2(75, 4), Vec2(60, 4), Vec2(60, 14), Vec2(55, 14), Vec2(55, 4),
                       Vec2(26, 4), Vec2(14, 62), Vec2(8, 62), Vec2(20, 4), Vec2(0, 4)]
        let pts = outline.map { sk.addPoint($0) }
        for i in pts.indices { sk.addLine(pts[i], pts[(i + 1) % pts.count]) }
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        d.features.append(Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(
            sketch: sketch.id, regionSeeds: [Vec2(40, 2)], distance: 70, symmetric: true))))
        return d
    }

    /// A J-shaped wall hook with a countersunk screw hole.
    static func wallHook() -> Design {
        var d = Design()
        var sk = Sketch()
        let outline = [Vec2(0, 0), Vec2(30, 0), Vec2(30, 14), Vec2(26, 14), Vec2(26, 4), Vec2(4, 4), Vec2(4, 50), Vec2(0, 50)]
        let pts = outline.map { sk.addPoint($0) }
        for i in pts.indices { sk.addLine(pts[i], pts[(i + 1) % pts.count]) }
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(
            sketch: sketch.id, regionSeeds: [Vec2(2, 25)], distance: 16, symmetric: true)))
        d.features.append(ext)
        let front = FaceRef(body: ext.id.uuidString, kind: 0, centroid: Vec3(4, 0, 27), normal: Vec3(1, 0, 0), area: 46 * 16)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(
            face: front, positions: [Vec2(0, 40)], kind: .countersink, diameter: 4.5, depth: 0, headDiameter: 8.8, headDepth: 4.4))))
        return d
    }
}
