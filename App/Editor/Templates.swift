import Foundation

/// Ready-made starting designs. Built from ordinary features, so everything stays editable.
///
/// Design rules for every template (they are the first thing many people print):
/// - real-world sizes that work without changes (screws, phones, cables),
/// - printable without supports in the obvious orientation (no overhang steeper than 45°),
/// - rounded edges where they help the look or the strength, never on the edge that sits on the bed,
/// - a short, readable timeline: every step is a normal feature you can tap and change.
enum Templates {
    // MARK: - Keychain

    /// A rounded name tag (60 × 20 × 3 mm) with a raised collar around the 6 mm ring hole,
    /// a soft top edge and raised text.
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
        let body = ext.id.uuidString

        // Soft top edge: one straight edge is enough, the fillet follows the tangent arcs all the way round.
        // The bottom edge stays sharp so the first layer sticks.
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: [
            edge(body, Vec3(0, -10, 3), Vec3(40, -10, 3), Vec3(0, 0, 1), Vec3(0, -1, 0)),
        ], value: 1))))

        // Reinforced ring: a 12 mm collar, 1 mm high, around the hole (the ring is 4 mm thick where it pulls).
        var ring = Sketch()
        let collar = ring.addCircle(center: Sketch.originID, radius: 6)
        let bore = ring.addCircle(center: Sketch.originID, radius: 3)
        ring.addConstraint(.diameter, [collar], value: 12)
        ring.addConstraint(.diameter, [bore], value: 6)
        let ringSketch = Feature(name: "Sketch 2", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: 3), sketch: ring)))
        d.features.append(ringSketch)
        d.features.append(Feature(name: "Extrude 2", operation: .extrude(ExtrudeFeature(
            sketch: ringSketch.id, regionSeeds: [Vec2(4.5, 0)], distance: 1, mode: .join, target: body))))

        // Text centred in the free part of the tag (x 8…48).
        d.features.append(Feature(name: "Text 1", operation: .text(TextFeature(
            plane: .origin(.xy, offset: 3), position: Vec2(28, 0), text: text, fontName: "Helvetica-Bold",
            size: 5.5, depth: 1, mode: .join, target: body))))
        return d
    }

    // MARK: - Box

    /// An open box 60 × 40 × 30 mm with 2 mm walls and floor and 6 mm rounded corners.
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
        let body = ext.id.uuidString

        // Round the four upright corners first, so the hollow follows them (outer radius 6, inner radius 4).
        let corners: [(Double, Double)] = [(30, 20), (-30, 20), (-30, -20), (30, -20)]
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: corners.map { c in
            edge(body, Vec3(c.0, c.1, 0), Vec3(c.0, c.1, 30), Vec3(c.0 > 0 ? 1 : -1, 0, 0), Vec3(0, c.1 > 0 ? 1 : -1, 0))
        }, value: 6))))

        let radius = 6.0
        let topArea = 60 * 40 - (4 - Double.pi) * radius * radius
        let top = FaceRef(body: body, kind: 0, centroid: Vec3(0, 0, 30), normal: Vec3(0, 0, 1), area: topArea)
        d.features.append(Feature(name: "Shell 1", operation: .shell(ShellFeature(body: body, openFaces: [top], thickness: 2))))
        return d
    }

    // MARK: - Wall bracket

    /// A 50 × 50 mm corner bracket, 5 mm thick and 30 mm wide, with a rounded inner corner,
    /// two 45° gussets along the sides and a countersunk hole for a 4 mm screw in each leg.
    /// Prints standing on its shelf leg; the gussets are exactly 45°, so no supports.
    static func wallBracket() -> Design {
        var d = Design()
        var sk = Sketch()
        let pts = [Vec2(0, 0), Vec2(50, 0), Vec2(50, 5), Vec2(5, 5), Vec2(5, 50), Vec2(0, 50)].map { sk.addPoint($0) }
        let lines = (0..<6).map { sk.addLine(pts[$0], pts[($0 + 1) % 6]) }
        for (i, l) in lines.enumerated() { sk.addConstraint(i % 2 == 0 ? .horizontal : .vertical, [l]) }
        sk.addConstraint(.coincident, [pts[0], Sketch.originID])
        sk.addConstraint(.length, [lines[0]], value: 50)
        sk.addConstraint(.length, [lines[5]], value: 50)
        sk.addConstraint(.length, [lines[1]], value: 5)
        sk.addConstraint(.length, [lines[4]], value: 5)
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(sketch: sketch.id, regionSeeds: [Vec2(2, 2)], distance: 30, symmetric: true)))
        d.features.append(ext)
        let body = ext.id.uuidString

        // Rounded inner corner: takes the stress out of the bend.
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: [
            edgeY(body, x: 5, z: 5, halfWidth: 15, Vec3(1, 0, 0), Vec3(0, 0, 1)),
        ], value: 4))))

        // Two gussets, 3 mm thick, flush with the sides. Their corners sit inside the legs so they fuse cleanly.
        for (n, offset) in [(2, -15.0), (3, 12.0)] {
            var g = Sketch()
            let gp = [Vec2(2, 2), Vec2(36, 2), Vec2(2, 36)].map { g.addPoint($0) }
            let gl = (0..<3).map { g.addLine(gp[$0], gp[($0 + 1) % 3]) }
            g.addConstraint(.horizontal, [gl[0]])
            g.addConstraint(.vertical, [gl[2]])
            g.addConstraint(.length, [gl[0]], value: 34)
            g.addConstraint(.length, [gl[2]], value: 34)
            let gs = Feature(name: "Sketch \(n)", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: offset), sketch: g)))
            d.features.append(gs)
            d.features.append(Feature(name: "Extrude \(n)", operation: .extrude(ExtrudeFeature(
                sketch: gs.id, regionSeeds: [Vec2(10, 10)], distance: 3, mode: .join, target: body))))
        }

        // Countersunk holes for 4 mm screws (4.5 mm clearance, 8.8 mm head), 8 mm from each leg's end.
        let wallFace = FaceRef(body: body, kind: 0, centroid: Vec3(5, 0, 30.6), normal: Vec3(1, 0, 0), area: 1086)
        let shelfFace = FaceRef(body: body, kind: 0, centroid: Vec3(30.6, 0, 5), normal: Vec3(0, 0, 1), area: 1086)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(
            face: wallFace, positions: [Vec2(0, 42)], kind: .countersink, diameter: 4.5, depth: 0, headDiameter: 8.8, headDepth: 4.4))))
        d.features.append(Feature(name: "Hole 2", operation: .hole(HoleFeature(
            face: shelfFace, positions: [Vec2(42, 0)], kind: .countersink, diameter: 4.5, depth: 0, headDiameter: 8.8, headDepth: 4.4))))
        return d
    }

    // MARK: - Plant pot

    /// A plant pot (Ø 91 mm, 72 mm high, 3 mm walls) with a 45° rim, four 6 mm drainage holes,
    /// and a matching saucer (Ø 98 mm, 12 mm high) as a second body next to it.
    static func plantPot() -> Design {
        var d = Design()
        var sk = Sketch()
        // Half profile, turned around the vertical axis. Wall leans out 7°, the rim steps out at 45°.
        let profile = [Vec2(0, 0), Vec2(35, 0), Vec2(43, 64), Vec2(45.5, 66.5), Vec2(45.5, 72),
                       Vec2(41, 72), Vec2(32.375, 3), Vec2(0, 3)]
        polygon(&sk, profile)
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let rev = Feature(name: "Revolve 1", operation: .revolve(RevolveFeature(sketch: sketch.id, regionSeeds: [Vec2(20, 1.5)], axisCurve: nil)))
        d.features.append(rev)
        let floor = FaceRef(body: rev.id.uuidString, kind: 0, centroid: Vec3(0, 0, 3), normal: Vec3(0, 0, 1), area: .pi * 32.375 * 32.375)
        let r = 16.0, s = r * sin(Double.pi / 3), c = r * cos(Double.pi / 3)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(
            face: floor, positions: [Vec2(0, 0), Vec2(r, 0), Vec2(-c, s), Vec2(-c, -s)], diameter: 6, depth: 0))))

        // Saucer: its own body, turned around a construction line 110 mm to the side.
        var ss = Sketch()
        let axisA = ss.addPoint(Vec2(110, -5)), axisB = ss.addPoint(Vec2(110, 20))
        let axis = ss.addLine(axisA, axisB, construction: true)
        polygon(&ss, [Vec2(110, 0), Vec2(156, 0), Vec2(159, 12), Vec2(157, 12), Vec2(154.5, 2), Vec2(110, 2)])
        let saucer = Feature(name: "Sketch 2", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: ss)))
        d.features.append(saucer)
        d.features.append(Feature(name: "Revolve 2", operation: .revolve(RevolveFeature(
            sketch: saucer.id, regionSeeds: [Vec2(130, 1)], axisCurve: axis))))
        return d
    }

    // MARK: - Phone stand

    /// A phone stand, 70 mm wide: the back leans at 65°, the slot holds phones up to 12 mm thick
    /// (case included), and a 14 mm cable gap runs through the middle for charging.
    /// Prints standing on its base; the back's underside is 25° from vertical.
    static func phoneStand() -> Design {
        var d = Design()
        var sk = Sketch()
        let angle = 65.0 * .pi / 180
        let cs = cos(angle), sn = sin(angle)
        let ledge = Vec2(55, 20)                          // where the phone's bottom edge meets the back
        let topFront = ledge + Vec2(-cs, sn) * 72         // 72 mm of back support
        let topBack = topFront + Vec2(-sn, -cs) * 5       // back is 5 mm thick
        let backFoot = Vec2(topBack.x + (topBack.y - 5) * cs / sn, 5)
        // Base 76 mm deep and 5 mm thick; slot floor 16 mm deep at 20 mm height; front lip 5 mm thick, 7 mm high.
        let outline = [Vec2(0, 0), Vec2(76, 0), Vec2(76, 27), Vec2(71, 27), Vec2(71, 20), ledge,
                       topFront, topBack, backFoot, Vec2(0, 5)]
        polygon(&sk, outline)
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(
            sketch: sketch.id, regionSeeds: [Vec2(40, 2)], distance: 70, symmetric: true)))
        d.features.append(ext)
        let body = ext.id.uuidString

        // 2 mm rounds on the top of the back, the lip and the back of the base (none on the bed).
        let front = Vec3(sn, 0, cs), top = Vec3(-cs, 0, sn), back = Vec3(-sn, 0, -cs)
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: [
            edgeY(body, x: topFront.x, z: topFront.y, halfWidth: 35, front, top),
            edgeY(body, x: topBack.x, z: topBack.y, halfWidth: 35, top, back),
            edgeY(body, x: 76, z: 27, halfWidth: 35, Vec3(1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: 71, z: 27, halfWidth: 35, Vec3(0, 0, 1), Vec3(-1, 0, 0)),
            edgeY(body, x: 0, z: 5, halfWidth: 35, Vec3(-1, 0, 0), Vec3(0, 0, 1)),
        ], value: 2))))

        // Cable gap: 14 mm wide, through the slot, the lip and the base, so the plug fits straight down.
        var cut = Sketch()
        let cp = [Vec2(54, -2), Vec2(80, -2), Vec2(80, 30), Vec2(54, 30)].map { cut.addPoint($0) }
        let cl = (0..<4).map { cut.addLine(cp[$0], cp[($0 + 1) % 4]) }
        cut.addConstraint(.horizontal, [cl[0]]); cut.addConstraint(.horizontal, [cl[2]])
        cut.addConstraint(.vertical, [cl[1]]); cut.addConstraint(.vertical, [cl[3]])
        let cutSketch = Feature(name: "Sketch 2", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: cut)))
        d.features.append(cutSketch)
        d.features.append(Feature(name: "Extrude 2", operation: .extrude(ExtrudeFeature(
            sketch: cutSketch.id, regionSeeds: [Vec2(67, 14)], distance: 14, symmetric: true, mode: .cut, target: body))))
        return d
    }

    // MARK: - Wall hook

    /// A J-shaped wall hook, 20 mm wide: 70 mm back plate with two countersunk holes for 4 mm screws,
    /// 35 mm reach, 20 mm high front lip. Inner and outer bends are rounded almost concentrically.
    /// Prints best lying on its side (layers follow the curve, so the hook doesn't snap).
    static func wallHook() -> Design {
        var d = Design()
        var sk = Sketch()
        let outline = [Vec2(0, 0), Vec2(35, 0), Vec2(35, 20), Vec2(29, 20), Vec2(29, 6), Vec2(5, 6), Vec2(5, 70), Vec2(0, 70)]
        let (pts, lines) = polygon(&sk, outline)
        for (i, l) in lines.enumerated() { sk.addConstraint(i % 2 == 0 ? .horizontal : .vertical, [l]) }
        sk.addConstraint(.coincident, [pts[0], Sketch.originID])
        sk.addConstraint(.length, [lines[0]], value: 35)  // reach
        sk.addConstraint(.length, [lines[1]], value: 20)  // lip height
        sk.addConstraint(.length, [lines[2]], value: 6)   // lip thickness
        sk.addConstraint(.length, [lines[3]], value: 14)
        sk.addConstraint(.length, [lines[6]], value: 5)   // back plate thickness
        sk.addConstraint(.length, [lines[7]], value: 70)  // back plate height
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(
            sketch: sketch.id, regionSeeds: [Vec2(2, 35)], distance: 20, symmetric: true)))
        d.features.append(ext)
        let body = ext.id.uuidString
        let w = 10.0

        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: [
            edgeY(body, x: 5, z: 6, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: 29, z: 6, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, 1)),
        ], value: 5))))
        d.features.append(Feature(name: "Fillet 2", operation: .fillet(EdgeFeature(edges: [
            edgeY(body, x: 0, z: 0, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, -1)),
            edgeY(body, x: 35, z: 0, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, -1)),
        ], value: 10))))
        d.features.append(Feature(name: "Fillet 3", operation: .fillet(EdgeFeature(edges: [
            edgeY(body, x: 0, z: 70, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: 5, z: 70, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: 29, z: 20, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: 35, z: 20, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, 1)),
        ], value: 2))))

        // Countersunk on the hook side, so the screw heads sit flush.
        let front = FaceRef(body: body, kind: 0, centroid: Vec3(5, 0, 39.5), normal: Vec3(1, 0, 0), area: 57 * 20)
        d.features.append(Feature(name: "Hole 1", operation: .hole(HoleFeature(
            face: front, positions: [Vec2(0, 30), Vec2(0, 56)], kind: .countersink, diameter: 4.5, depth: 0,
            headDiameter: 8.8, headDepth: 4.4))))
        return d
    }

    // MARK: - Hex coaster (new)

    /// A hexagonal coaster, 90 mm across the flats and 5 mm thick, with rounded corners,
    /// a soft top edge and a 1.2 mm deep drip tray inside a 4 mm rim.
    static func hexCoaster() -> Design {
        var d = Design()
        var sk = Sketch()
        let apothem = 45.0
        polygon(&sk, hexagon(apothem: apothem))
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let height = 5.0
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(sketch: sketch.id, regionSeeds: [Vec2(0, 0)], distance: height)))
        d.features.append(ext)
        let body = ext.id.uuidString

        // Round the six corners (4 mm).
        let R = apothem / cos(Double.pi / 6)
        let corners: [EdgeRef] = (0..<6).map { k in
            let t = Double(k) * Double.pi / 3
            let p = Vec2(cos(t), sin(t)) * R
            let n1 = Vec3(cos(t - .pi / 6), sin(t - .pi / 6), 0), n2 = Vec3(cos(t + .pi / 6), sin(t + .pi / 6), 0)
            return edge(body, Vec3(p.x, p.y, 0), Vec3(p.x, p.y, height), n1, n2)
        }
        let cornerRadius = 4.0
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: corners, value: cornerRadius))))

        // Soft top edge (1 mm): one side is enough, the round follows the whole outline.
        let n = Vec3(cos(Double.pi / 6), sin(Double.pi / 6), 0)
        let mid = n * apothem + Vec3(0, 0, height)
        let along = Vec3(-sin(Double.pi / 6), cos(Double.pi / 6), 0)
        let side = R - 2 * cornerRadius * tan(Double.pi / 6)
        d.features.append(Feature(name: "Fillet 2", operation: .fillet(EdgeFeature(edges: [
            edge(body, mid - along * (side / 2), mid + along * (side / 2), Vec3(0, 0, 1), n),
        ], value: 1))))

        // Drip tray: a smaller hexagon cut 1.2 mm deep from the top.
        var tray = Sketch()
        polygon(&tray, hexagon(apothem: apothem - 4))
        let traySketch = Feature(name: "Sketch 2", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: height - 1.2), sketch: tray)))
        d.features.append(traySketch)
        d.features.append(Feature(name: "Extrude 2", operation: .extrude(ExtrudeFeature(
            sketch: traySketch.id, regionSeeds: [Vec2(0, 0)], distance: 3, mode: .cut, target: body))))
        return d
    }

    // MARK: - Cable comb (new)

    /// A desk cable comb, 51 × 12 × 16 mm: three slots for cables up to 7 mm with round bottoms.
    /// Stick it to the desk with double-sided tape; prints flat on its base.
    static func cableComb() -> Design {
        var d = Design()
        var sk = Sketch()
        let teeth: [(Double, Double)] = [(0, 8), (15, 22), (29, 36), (43, 51)]
        let base = 5.0, top = 16.0
        var outline = [Vec2(0, 0), Vec2(51, 0)]
        // Walk back over the teeth from right to left.
        for (i, t) in teeth.enumerated().reversed() {
            outline.append(Vec2(t.1, top))
            outline.append(Vec2(t.0, top))
            if i > 0 {
                outline.append(Vec2(t.0, base))
                outline.append(Vec2(teeth[i - 1].1, base))
            }
        }
        // The outline ends at (0, 16); its last line runs down the left tooth back to the origin.
        let (pts, lines) = polygon(&sk, outline)
        for (i, l) in lines.enumerated() { sk.addConstraint(i % 2 == 0 ? .horizontal : .vertical, [l]) }
        sk.addConstraint(.coincident, [pts[0], Sketch.originID])
        let sketch = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xz, offset: 0), sketch: sk)))
        d.features.append(sketch)
        let ext = Feature(name: "Extrude 1", operation: .extrude(ExtrudeFeature(
            sketch: sketch.id, regionSeeds: [Vec2(25, 2)], distance: 12, symmetric: true)))
        d.features.append(ext)
        let body = ext.id.uuidString
        let w = 6.0

        // Round slot bottoms (3 mm in a 7 mm slot) so the cable sits in a cradle.
        var slotEdges: [EdgeRef] = []
        for i in 1..<teeth.count {
            slotEdges.append(edgeY(body, x: teeth[i - 1].1, z: base, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, 1)))
            slotEdges.append(edgeY(body, x: teeth[i].0, z: base, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, 1)))
        }
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: slotEdges, value: 3))))

        // Soft tooth tops (1 mm) so cables slide in easily.
        let topEdges = teeth.flatMap { t in [
            edgeY(body, x: t.0, z: top, halfWidth: w, Vec3(-1, 0, 0), Vec3(0, 0, 1)),
            edgeY(body, x: t.1, z: top, halfWidth: w, Vec3(1, 0, 0), Vec3(0, 0, 1)),
        ] }
        d.features.append(Feature(name: "Fillet 2", operation: .fillet(EdgeFeature(edges: topEdges, value: 1))))
        return d
    }

    // MARK: - Helpers

    /// A closed outline of straight lines through `points`, in order.
    @discardableResult
    private static func polygon(_ sk: inout Sketch, _ points: [Vec2]) -> (points: [Int], lines: [Int]) {
        let ids = points.map { sk.addPoint($0) }
        let lines = ids.indices.map { sk.addLine(ids[$0], ids[($0 + 1) % ids.count]) }
        return (ids, lines)
    }

    /// Corners of a regular hexagon around the origin, corners on the X axis.
    private static func hexagon(apothem: Double) -> [Vec2] {
        let r = apothem / cos(Double.pi / 6)
        return (0..<6).map { k in
            let t = Double(k) * Double.pi / 3
            return Vec2(cos(t), sin(t)) * r
        }
    }

    /// A straight edge between two flat faces.
    private static func edge(_ body: String, _ a: Vec3, _ b: Vec3, _ n1: Vec3, _ n2: Vec3) -> EdgeRef {
        EdgeRef(body: body, kind: 0, midpoint: (a + b) / 2, start: a, end: b, length: (b - a).length,
                faceKinds: [0, 0], faceNormals: [n1, n2])
    }

    /// A straight edge across the width of a side profile drawn on the front plane and extruded both ways.
    private static func edgeY(_ body: String, x: Double, z: Double, halfWidth w: Double, _ n1: Vec3, _ n2: Vec3) -> EdgeRef {
        edge(body, Vec3(x, -w, z), Vec3(x, w, z), n1, n2)
    }
}
