import XCTest

final class SketchTests: XCTestCase {
    /// A 40 × 20 rectangle anchored at the origin.
    private func rectangle() -> (Sketch, [Int], [Int]) {
        var s = Sketch()
        let p = [s.addPoint(Vec2(0.3, 0.2)), s.addPoint(Vec2(38, 1)), s.addPoint(Vec2(39, 22)), s.addPoint(Vec2(-1, 19))]
        let l = (0..<4).map { s.addLine(p[$0], p[($0 + 1) % 4]) }
        s.addConstraint(.horizontal, [l[0]]); s.addConstraint(.horizontal, [l[2]])
        s.addConstraint(.vertical, [l[1]]); s.addConstraint(.vertical, [l[3]])
        return (s, p, l)
    }

    func testRectangleBecomesFullyDefined() {
        var (s, p, l) = rectangle()
        XCTAssertEqual(SketchSolver.solve(s).freedom, 4)
        s.addConstraint(.coincident, [p[0], Sketch.originID])
        s.addConstraint(.length, [l[0]], value: 40)
        s.addConstraint(.length, [l[1]], value: 20)
        let r = SketchSolver.solve(s)
        XCTAssertTrue(r.converged)
        XCTAssertTrue(r.isFullyDefined)
        XCTAssertEqual(r.sketch.position(p[2]).x, 40, accuracy: 1e-6)
        XCTAssertEqual(r.sketch.position(p[2]).y, 20, accuracy: 1e-6)
    }

    func testConflictIsReported() {
        var (s, _, l) = rectangle()
        s.addConstraint(.length, [l[0]], value: 40)
        s.addConstraint(.length, [l[2]], value: 30)  // opposite side of a rectangle can't differ
        let r = SketchSolver.solve(s)
        XCTAssertFalse(r.converged)
        XCTAssertFalse(r.conflicting.isEmpty)
    }

    func testDraggingMovesOnlyFreeGeometry() {
        var (s, p, _) = rectangle()
        s = SketchSolver.solve(s).sketch
        let r = SketchSolver.solve(s, locked: [p[2]: Vec2(50, 30)])
        XCTAssertTrue(r.converged)
        XCTAssertEqual(r.sketch.position(p[1]).x, 50, accuracy: 1e-6)  // vertical side follows
        XCTAssertEqual(r.sketch.position(p[3]).y, 30, accuracy: 1e-6)  // horizontal side follows
    }

    func testTangentArcSlot() {
        let d = Templates.keychain()
        guard case .sketch(let f) = d.features[0].operation else { return XCTFail() }
        let r = SketchSolver.solve(f.sketch)
        XCTAssertTrue(r.converged)
        let regions = SketchRegions.find(in: r.sketch)
        XCTAssertEqual(regions.count, 2)  // tag with hole + the hole itself
        XCTAssertEqual(regions[0].loops.count, 2)
        let expected: Double = 40.0 * 20.0 + Double.pi * 100.0 - Double.pi * 9.0
        XCTAssertEqual(regions[0].area, expected, accuracy: 0.01)  // solver tolerance
    }

    func testRegionsOfCrossingShapes() {
        var s = Sketch()
        s.addCircle(center: s.addPoint(Vec2(0, 0)), radius: 10)
        s.addCircle(center: s.addPoint(Vec2(10, 0)), radius: 10)
        let areas = SketchRegions.find(in: s).map(\.area).sorted()
        XCTAssertEqual(areas.count, 3)
        let union: Double = 2.0 * Double.pi * 100.0 - areas[0]
        XCTAssertEqual(areas.reduce(0, +), union, accuracy: 1e-6)
    }

    func testOpenLinesMakeNoRegion() {
        var s = Sketch()
        let a = s.addPoint(Vec2(0, 0)), b = s.addPoint(Vec2(10, 0)), c = s.addPoint(Vec2(10, 10))
        s.addLine(a, b); s.addLine(b, c)
        XCTAssertTrue(SketchRegions.find(in: s).isEmpty)
    }

    func testDeletingAPointRemovesItsLinesAndConstraints() {
        var (s, p, _) = rectangle()
        s.delete(points: [p[0]], curves: [], constraints: [])
        XCTAssertEqual(s.curves.count, 2)
        XCTAssertTrue(s.constraints.allSatisfy { k in k.refs.allSatisfy { r in s.curve(r) != nil || s.point(r) != nil } })
    }

    func testExpressions() {
        XCTAssertEqual(Expression.parseLength("20+5"), 25)
        XCTAssertEqual(Expression.parseLength("50/2"), 25)
        XCTAssertEqual(Expression.parseLength("12,5"), 12.5)
        XCTAssertEqual(Expression.parseLength("1in"), 25.4)
        XCTAssertEqual(Expression.parseLength("2 cm"), 20)
        XCTAssertEqual(Expression.parseLength("(10+2)*3"), 36)
        XCTAssertEqual(Expression.parseLength("3", defaultUnit: .cm), 30)
        XCTAssertNil(Expression.parseLength("abc"))
        XCTAssertNil(Expression.parseLength("5/0"))
        XCTAssertEqual(Expression.parseAngle("90")!, .pi / 2, accuracy: 1e-12)
    }

    func testDesignRoundTripsThroughJSON() throws {
        let d = Templates.keychain()
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(Design.self, from: data)
        XCTAssertEqual(back.features, d.features)
    }
}
