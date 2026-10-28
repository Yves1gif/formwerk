import XCTest

final class KernelTests: XCTestCase {
    func testExtrudedSketchHasExactVolume() throws {
        let state = ModelBuilder().build(Templates.box())
        XCTAssertEqual(state.bodies.count, 1)
        XCTAssertTrue(state.statuses.values.allSatisfy { $0 == .ok })
        let v = state.bodies[0].shape.properties.volume
        // 60 × 40 × 30 box with 6 mm rounded corners, hollowed with 2 mm walls, open at the top
        let outer = 60.0 * 40 - (4 - .pi) * 36
        let inner = 56.0 * 36 - (4 - .pi) * 16
        XCTAssertEqual(v, outer * 30 - inner * 28, accuracy: 1)
        XCTAssertTrue(state.bodies[0].shape.isValidSolid)
    }

    func testFilletReducesVolumeByKnownAmount() throws {
        let box = try Kernel.box(corner: .zero, size: Vec3(10, 10, 10))
        let vertical = box.edges.filter { abs($0.start.z - $0.end.z) > 9 }.map(\.index)
        XCTAssertEqual(vertical.count, 4)
        let filleted = try Kernel.fillet(box, edges: vertical, radius: 1)
        // each rounded corner removes (1 - π/4) r² of the cross-section
        XCTAssertEqual(filleted.properties.volume, 1000 - 4 * (1 - .pi / 4) * 10, accuracy: 1e-3)
    }

    func testPushPullAndHole() throws {
        let box = try Kernel.box(corner: .zero, size: Vec3(20, 20, 10))
        let top = box.faces.first { $0.isPlanar && $0.normal.z > 0.9 }!
        let taller = try Kernel.pushPull(box, face: top.index, distance: 5)
        XCTAssertEqual(taller.properties.bounds.max.z, 15, accuracy: 1e-6)
        let tool = try Kernel.holeTool(at: Vec3(10, 10, 15), direction: Vec3(0, 0, -1), diameter: 4, depth: 0)
        let drilled = try Kernel.boolean(taller, tool, .cut)
        XCTAssertEqual(drilled.properties.volume, 20 * 20 * 15 - .pi * 4 * 15, accuracy: 1e-3)
    }

    func testReferencesSurviveAParameterChange() throws {
        var d = Templates.box()
        d.features.removeSubrange(2...)  // keep sketch + extrude: the template's own rounded corners can't take a fillet
        // add a fillet on the outer vertical edges, then make the box wider
        let state = ModelBuilder().build(d)
        let body = state.bodies[0]
        let edges = body.shape.edges.filter { $0.kind == .line && abs($0.start.z - $0.end.z) > 25 && (abs($0.start.x) > 29.9) }
        XCTAssertEqual(edges.count, 4)
        d.features.append(Feature(name: "Fillet 1", operation: .fillet(EdgeFeature(edges: edges.map { EdgeRef(body: body.id, shape: body.shape, info: $0) }, value: 3))))
        guard case .sketch(var sf) = d.features[0].operation else { return XCTFail() }
        if let i = sf.sketch.constraints.firstIndex(where: { $0.kind == .length && $0.value == 60 }) { sf.sketch.constraints[i].value = 90 }
        sf.sketch = SketchSolver.solve(sf.sketch).sketch
        d.features[0].operation = .sketch(sf)
        let rebuilt = ModelBuilder().build(d)
        for f in d.features { XCTAssertEqual(rebuilt.statuses[f.id], .ok, f.name) }
        XCTAssertEqual(rebuilt.bodies[0].shape.properties.bounds.size.x, 90, accuracy: 1e-6)
    }

    func testTextBecomesSolid() throws {
        let state = ModelBuilder().build(Templates.keychain())
        XCTAssertTrue(state.statuses.values.allSatisfy { $0 == .ok })
        XCTAssertEqual(state.bodies.count, 1)
        XCTAssertGreaterThan(state.bodies[0].shape.properties.bounds.max.z, 3.9)
    }

    func testExportsAreWellFormed() throws {
        let box = try Kernel.box(corner: .zero, size: Vec3(10, 10, 10))
        let mesh = box.mesh(linear: 0.05, angular: 0.3)
        XCTAssertTrue(PrintChecker.isWatertight(mesh))
        let body = ExportBody(name: "Box", mesh: mesh, color: SIMD4(1, 0, 0, 1))
        let stl = MeshExport.stl([body])
        XCTAssertEqual(stl.count, 84 + 50 * mesh.triangleCount)
        let zip = MeshExport.threeMF([body])
        XCTAssertEqual(Array(zip.prefix(4)), [0x50, 0x4B, 0x03, 0x04])  // "PK.."
        let (verts, tris) = MeshExport.welded(mesh)
        XCTAssertEqual(verts.count, 8)
        XCTAssertEqual(tris.count, 12)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("test.step")
        try Kernel.writeSTEP([box], to: url)
        let back = try Kernel.readSTEP(url)
        XCTAssertEqual(back.properties.volume, 1000, accuracy: 1e-6)
    }

    func testPrintCheckFindsOverhangAndSize() throws {
        // A T shape: the arms hang over the bed.
        let stem = try Kernel.box(corner: Vec3(-5, -5, 0), size: Vec3(10, 10, 20))
        let arms = try Kernel.box(corner: Vec3(-30, -5, 20), size: Vec3(60, 10, 5))
        let t = try Kernel.boolean(stem, arms, .union)
        let p = t.properties
        let input = PrintChecker.Input(id: "t", mesh: t.mesh(), volume: p.volume, area: p.area, bounds: p.bounds, validSolid: t.isValidSolid)
        let r = PrintChecker.check([input], .init(printer: Printer.find("bambu-a1mini"), material: .pla))
        XCTAssertTrue(r.issues.contains { $0.kind == .overhangs })
        XCTAssertFalse(r.issues.contains { $0.kind == .tooBig })
        XCTAssertGreaterThan(r.grams, 0)
    }
}
