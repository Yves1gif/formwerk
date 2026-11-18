import XCTest

/// Trim, offset, round corner and mirror (SketchEdit), plus the new model fields.
final class SketchEditTests: XCTestCase {
    /// A 40 × 20 rectangle (corners 0,0 … 40,20) with horizontal/vertical constraints.
    private func rectangle() -> (Sketch, [Int], [Int]) {
        var s = Sketch()
        let p = [s.addPoint(Vec2(0, 0)), s.addPoint(Vec2(40, 0)), s.addPoint(Vec2(40, 20)), s.addPoint(Vec2(0, 20))]
        let l = (0..<4).map { s.addLine(p[$0], p[($0 + 1) % 4]) }
        s.addConstraint(.horizontal, [l[0]]); s.addConstraint(.horizontal, [l[2]])
        s.addConstraint(.vertical, [l[1]]); s.addConstraint(.vertical, [l[3]])
        return (s, p, l)
    }

    /// A horizontal line 0…30 crossed by vertical lines at x = 10 and x = 20.
    private func crossedLine() -> (Sketch, Int) {
        var s = Sketch()
        let h = s.addLine(s.addPoint(Vec2(0, 0)), s.addPoint(Vec2(30, 0)))
        s.addLine(s.addPoint(Vec2(10, -5)), s.addPoint(Vec2(10, 5)))
        s.addLine(s.addPoint(Vec2(20, -5)), s.addPoint(Vec2(20, 5)))
        return (s, h)
    }

    private func horizontalPieces(_ s: Sketch) -> [(Double, Double)] {
        s.curves.filter { $0.kind == .line }.map { s.lineEnds($0) }
            .filter { abs($0.0.y) < 1e-9 && abs($0.1.y) < 1e-9 }
            .map { (min($0.0.x, $0.1.x), max($0.0.x, $0.1.x)) }
            .sorted { $0.0 < $1.0 }
    }

    // MARK: - Trim

    func testTrimMiddleSplitsTheLine() throws {
        let (s, h) = crossedLine()
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: h, near: Vec2(15, 0.2)))
        let pieces = horizontalPieces(t)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(pieces[0].0, 0, accuracy: 1e-9); XCTAssertEqual(pieces[0].1, 10, accuracy: 1e-9)
        XCTAssertEqual(pieces[1].0, 20, accuracy: 1e-9); XCTAssertEqual(pieces[1].1, 30, accuracy: 1e-9)
        // New ends stay on the cutting lines, and the sketch still solves.
        XCTAssertEqual(t.constraints.filter { $0.kind == .pointOnCurve }.count, 3)  // 2 cut points + collinear piece
        XCTAssertTrue(SketchSolver.solve(t).converged)
    }

    func testTrimEndShortensAndRemovesLoosePoint() throws {
        let (s, h) = crossedLine()
        let pointsBefore = s.points.count
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: h, near: Vec2(3, 0)))
        let pieces = horizontalPieces(t)
        XCTAssertEqual(pieces.count, 1)
        XCTAssertEqual(pieces[0].0, 10, accuracy: 1e-9)
        XCTAssertEqual(pieces[0].1, 30, accuracy: 1e-9)
        XCTAssertEqual(t.points.count, pointsBefore)  // old end removed, cut point added
    }

    func testTrimWithoutCrossingsDeletesTheCurve() throws {
        var s = Sketch()
        let l = s.addLine(s.addPoint(Vec2(0, 0)), s.addPoint(Vec2(10, 0)))
        s.addConstraint(.length, [l], value: 10)
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: l, near: Vec2(5, 0)))
        XCTAssertTrue(t.curves.isEmpty)
        XCTAssertTrue(t.constraints.isEmpty)
    }

    func testTrimDropsLengthOfTrimmedLine() throws {
        var (s, h) = crossedLine()
        s.addConstraint(.length, [h], value: 30)
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: h, near: Vec2(25, 0)))
        XCTAssertFalse(t.constraints.contains { $0.kind == .length })
        XCTAssertTrue(SketchSolver.solve(t).converged)
    }

    func testTrimCircleLeavesArc() throws {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(Vec2(0, 0)), radius: 10)
        s.addLine(s.addPoint(Vec2(-20, 0)), s.addPoint(Vec2(20, 0)))
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: c, near: Vec2(0, 10)))
        let arc = try XCTUnwrap(t.curve(c))
        XCTAssertEqual(arc.kind, .arc)
        let (_, sweep) = t.arcAngles(arc)
        XCTAssertEqual(sweep, .pi, accuracy: 1e-9)
        let pts = t.polyline(arc)
        XCTAssertEqual(pts[pts.count / 2].y, -10, accuracy: 0.1)  // the lower half stays
        XCTAssertTrue(SketchSolver.solve(t).converged)
    }

    func testTrimCircleWithOneCrossingDeletesIt() throws {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(Vec2(0, 0)), radius: 10)
        s.addLine(s.addPoint(Vec2(0, 0)), s.addPoint(Vec2(20, 0)))  // crosses once
        let t = try XCTUnwrap(SketchEdit.trim(s, curve: c, near: Vec2(0, 10)))
        XCTAssertNil(t.curve(c))
    }

    func testTrimPlanPreviewCoversThePiece() throws {
        let (s, h) = crossedLine()
        let plan = try XCTUnwrap(SketchEdit.trimPlan(s, curve: h, near: Vec2(15, 0)))
        XCTAssertEqual(plan.removedPiece.first!.x, 10, accuracy: 1e-9)
        XCTAssertEqual(plan.removedPiece.last!.x, 20, accuracy: 1e-9)
    }

    // MARK: - Offset

    func testOffsetRectangleOutwardsMakesRoundedWall() throws {
        let (s, _, l) = rectangle()
        guard case .success(let r) = SketchEdit.offset(s, curves: l, distance: 2) else { return XCTFail() }
        XCTAssertEqual(r.curves.count, 8)
        XCTAssertEqual(r.sketch.curves.filter { $0.kind == .arc }.count, 4)
        for c in r.sketch.curves where c.kind == .arc { XCTAssertEqual(r.sketch.radius(of: c), 2, accuracy: 1e-9) }
        let areas = SketchRegions.find(in: r.sketch).map(\.area).sorted()
        XCTAssertEqual(areas.count, 2)
        XCTAssertEqual(areas[0], 240 + 4 * .pi, accuracy: 1e-3)  // the wall: perimeter × d + π d²
        XCTAssertEqual(areas[1], 800, accuracy: 1e-6)
        let solved = SketchSolver.solve(r.sketch)
        XCTAssertTrue(solved.converged)
        XCTAssertTrue(solved.conflicting.isEmpty)
    }

    func testOffsetRectangleInwardsKeepsSharpCorners() throws {
        let (s, _, l) = rectangle()
        // A single selected line takes the whole outline.
        let chain = SketchEdit.connectedCurves(s, from: l[0])
        XCTAssertEqual(Set(chain), Set(l))
        guard case .success(let r) = SketchEdit.offset(s, curves: chain, distance: -2) else { return XCTFail() }
        XCTAssertEqual(r.curves.count, 4)
        XCTAssertFalse(r.sketch.curves.contains { $0.kind == .arc })
        let areas = SketchRegions.find(in: r.sketch).map(\.area).sorted()
        XCTAssertEqual(areas.count, 2)
        XCTAssertEqual(areas[0], 800 - 36 * 16, accuracy: 1e-6)  // the wall ring
        XCTAssertEqual(areas[1], 36 * 16, accuracy: 1e-6)
        XCTAssertTrue(SketchSolver.solve(r.sketch).converged)
    }

    func testOffsetTooBigFails() {
        let (s, _, l) = rectangle()
        XCTAssertEqual(SketchEdit.offset(s, curves: l, distance: -15).failure, .tooBig)
    }

    func testOffsetCircleAndSlot() throws {
        var s = Sketch()
        let c = s.addCircle(center: s.addPoint(Vec2(0, 0)), radius: 10)
        guard case .success(let r) = SketchEdit.offset(s, curves: [c], distance: 3) else { return XCTFail() }
        XCTAssertEqual(r.sketch.curve(r.curves[0])?.radius ?? 0, 13, accuracy: 1e-12)

        // The keychain template's slot (lines tangent to arcs) offsets without corner arcs.
        let d = Templates.keychain()
        guard case .sketch(let f) = d.features[0].operation else { return XCTFail() }
        let slot = SketchSolver.solve(f.sketch).sketch
        let outline = slot.curves.filter { !$0.construction && $0.kind != .circle }.map(\.id)
        XCTAssertEqual(SketchEdit.chain(slot, curves: outline)?.closed, true)
        guard case .success(let o) = SketchEdit.offset(slot, curves: outline, distance: 1.5) else { return XCTFail() }
        XCTAssertEqual(o.curves.count, outline.count)  // smooth joints need no corner arcs
        for id in o.curves { if let c = o.sketch.curve(id), c.kind == .arc { XCTAssertEqual(o.sketch.radius(of: c), 11.5, accuracy: 1e-6) } }
    }

    func testOffsetOpenChain() throws {
        var s = Sketch()
        let a = s.addPoint(Vec2(0, 0)), b = s.addPoint(Vec2(10, 0)), c = s.addPoint(Vec2(10, 10))
        let l1 = s.addLine(a, b), l2 = s.addLine(b, c)
        guard case .success(let r) = SketchEdit.offset(s, curves: [l1, l2], distance: 1) else { return XCTFail() }
        // The left side of a left-turning chain is the inside: two lines meeting at (9, 1).
        XCTAssertEqual(r.curves.count, 2)
        let ends = r.curves.compactMap { r.sketch.curve($0) }.flatMap { [r.sketch.position($0.a), r.sketch.position($0.b)] }
        XCTAssertTrue(ends.contains { ($0 - Vec2(9, 1)).length < 1e-9 })
        guard case .success(let out) = SketchEdit.offset(s, curves: [l1, l2], distance: -1) else { return XCTFail() }
        XCTAssertEqual(out.curves.count, 3)  // the outer side gets a corner arc
    }

    // MARK: - Round corner

    func testRoundCornerOfRectangle() throws {
        var (s, p, l) = rectangle()
        s.addConstraint(.coincident, [p[0], Sketch.originID])
        s.addConstraint(.length, [l[0]], value: 40)
        s.addConstraint(.length, [l[1]], value: 20)
        XCTAssertTrue(SketchSolver.solve(s).isFullyDefined)
        let k = try XCTUnwrap(SketchEdit.corner(s, at: p[2]))
        XCTAssertEqual(k.angle, .pi / 2, accuracy: 1e-12)
        XCTAssertEqual(k.maxRadius, 20, accuracy: 1e-9)
        guard case .success(let r) = SketchEdit.roundCorner(s, at: p[2], radius: 3) else { return XCTFail() }
        let arc = try XCTUnwrap(r.sketch.curve(r.arc))
        XCTAssertEqual(r.sketch.radius(of: arc), 3, accuracy: 1e-9)
        XCTAssertEqual(r.sketch.position(arc.a).x, 37, accuracy: 1e-9)
        XCTAssertEqual(r.sketch.position(arc.a).y, 17, accuracy: 1e-9)
        // Lengths became distances to the old corner, so the size still holds.
        XCTAssertFalse(r.sketch.constraints.contains { $0.kind == .length && $0.refs == [l[1]] })
        let solved = SketchSolver.solve(r.sketch)
        XCTAssertTrue(solved.converged)
        XCTAssertEqual(solved.freedom, 0)
        let area = try XCTUnwrap(SketchRegions.find(in: solved.sketch).first).area
        XCTAssertEqual(area, 800 - 9 * (1 - .pi / 4), accuracy: 1e-4)

        // Changing the radius keeps everything tangent.
        var bigger = solved.sketch
        if let i = bigger.constraints.firstIndex(where: { $0.id == r.dimension }) { bigger.constraints[i].value = 6 }
        let again = SketchSolver.solve(bigger)
        XCTAssertTrue(again.converged)
        XCTAssertEqual(again.sketch.position(p[2]).x, 40, accuracy: 1e-6)  // the virtual corner stays put
    }

    func testRoundCornerTooBigFails() {
        let (s, p, _) = rectangle()
        XCTAssertEqual(SketchEdit.roundCorner(s, at: p[1], radius: 25).failure, .tooBig)
        var t = s
        t.addLine(p[1], t.addPoint(Vec2(50, -10)))  // three curves meet: not a simple corner
        XCTAssertEqual(SketchEdit.roundCorner(t, at: p[1], radius: 2).failure, .notACorner)
    }

    // MARK: - Mirror

    func testMirrorAcrossVerticalLine() throws {
        var s = Sketch()
        let axis = s.addLine(s.addPoint(Vec2(0, -10)), s.addPoint(Vec2(0, 10)), construction: true)
        let line = s.addLine(s.addPoint(Vec2(1, 1)), s.addPoint(Vec2(5, 3)))
        let arc = s.addArc(center: s.addPoint(Vec2(5, 0)), start: s.addPoint(Vec2(8, 0)), end: s.addPoint(Vec2(5, 3)))
        let r = try XCTUnwrap(SketchEdit.mirror(s, curves: [line, arc, axis], across: axis))
        XCTAssertEqual(r.curves.count, 2)
        let ml = try XCTUnwrap(r.sketch.curve(r.curves[0]))
        let (a, b) = r.sketch.lineEnds(ml)
        XCTAssertEqual(a.x, -1, accuracy: 1e-12); XCTAssertEqual(b.x, -5, accuracy: 1e-12); XCTAssertEqual(b.y, 3, accuracy: 1e-12)
        let ma = try XCTUnwrap(r.sketch.curve(r.curves[1]))
        let pts = r.sketch.polyline(ma)
        let mid = pts[pts.count / 2]
        XCTAssertEqual(mid.x, -5 - 3 * cos(Double.pi / 4), accuracy: 0.05)
        XCTAssertEqual(mid.y, 3 * sin(Double.pi / 4), accuracy: 0.05)
        // Every mirrored point (2 of the line, centre + 2 ends of the arc) is tied to its original.
        XCTAssertEqual(r.sketch.constraints.filter { $0.kind == .symmetric }.count, 5)
        XCTAssertTrue(SketchSolver.solve(r.sketch).converged)
    }

    // MARK: - Model fields and kernel

    func testOlderFilesDecodeWithoutNewFields() throws {
        let id = UUID()
        let json = #"{"sketch":"\#(id.uuidString)","regionSeeds":[[1,2]],"distance":5,"symmetric":false,"mode":"newBody"}"#
        let e = try JSONDecoder().decode(ExtrudeFeature.self, from: Data(json.utf8))
        XCTAssertNil(e.draftAngle)
        let sf = try JSONDecoder().decode(SketchFeature.self, from: Data(#"{"plane":{"origin":{"_0":"xy","offset":0}},"sketch":{"points":[],"curves":[],"constraints":[],"nextID":1}}"#.utf8))
        XCTAssertNil(sf.planeOffset)
        // And the new fields survive a round trip.
        var h = HoleFeature(face: FaceRef(body: "b", kind: 0, centroid: .zero, normal: Vec3(0, 0, 1), area: 1), positions: [.zero])
        h.apply(PrintThread(size: "M3", kind: .heatSetInsert))
        XCTAssertEqual(h.diameter, 4.0)
        let back = try JSONDecoder().decode(HoleFeature.self, from: JSONEncoder().encode(h))
        XCTAssertEqual(back.printThread, PrintThread(size: "M3", kind: .heatSetInsert))
        h.apply(PrintThread(size: "M5", kind: .screwCutsThread))
        XCTAssertEqual(h.diameter, 4.2)
    }

    func testSketchPlaneOffset() {
        var sk = Sketch()
        sk.addCircle(center: sk.addPoint(.zero), radius: 5)
        var d = Design()
        let f = Feature(name: "Sketch 1", operation: .sketch(SketchFeature(plane: .origin(.xy, offset: 2), sketch: sk, planeOffset: 3)))
        d.features = [f]
        let state = ModelBuilder().build(d)
        XCTAssertEqual(state.sketches[f.id]?.plane.origin.z ?? 0, 5, accuracy: 1e-12)
    }

    func testDraftNarrowsTowardsTheTop() throws {
        let square: [RegionSegment] = [.line(Vec2(0, 0), Vec2(20, 0)), .line(Vec2(20, 0), Vec2(20, 20)),
                                       .line(Vec2(20, 20), Vec2(0, 20)), .line(Vec2(0, 20), Vec2(0, 0))]
        let face = try Kernel.face(on: .xy, loops: [square])
        let angle = 5.0 * .pi / 180
        let solid = try Kernel.extrude(face, direction: Vec3(0, 0, 1), distance: 10, draftAngle: angle)
        XCTAssertTrue(solid.isValidSolid)
        let top = try XCTUnwrap(solid.faces.first { $0.isPlanar && $0.normal.z > 0.99 })
        let bottom = try XCTUnwrap(solid.faces.first { $0.isPlanar && $0.normal.z < -0.99 })
        XCTAssertEqual(bottom.area, 400, accuracy: 1e-6)
        let side = 20 - 2 * 10 * tan(angle)
        XCTAssertEqual(top.area, side * side, accuracy: 1e-3)
    }
}

private extension Result {
    var failure: Failure? { if case .failure(let f) = self { return f }; return nil }
}
