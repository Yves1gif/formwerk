import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Run the app with `-formwerkSelfTest` to build sample designs, render them off-screen,
/// run the print check and export files, then quit. Results go to the app's temporary folder.
/// Used to verify the whole pipeline (kernel → mesh → Metal → export) without touching the screen.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("-formwerkSelfTest") }

    static func run() {
        Task { @MainActor in
            let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest")
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var log = "Formwerk self-test \(Date())\n"
            func note(_ s: String) { log += s + "\n"; print("SELFTEST " + s) }

            for (name, design) in [("keychain", Templates.keychain()), ("bracket", Templates.wallBracket()), ("pot", Templates.plantPot()), ("box", Templates.box())] {
                let doc = FormwerkDocument(design: design)
                let model = EditorModel(document: doc)
                await waitForBuild(model)
                note("\(name): \(model.output.bodies.count) bodies, statuses: " +
                     design.features.map { "\($0.name)=\(model.output.statuses[$0.id].map { "\($0)" } ?? "-")" }.joined(separator: ", "))
                for b in model.output.bodies {
                    note("  body volume \(Format.number(b.props.volume, digits: 1)) mm³, triangles \(b.mesh.triangleCount), valid \(b.isValid)")
                }
                guard let r = model.renderer else { note("no renderer"); continue }
                r.setOffscreenSize(CGSize(width: 800, height: 500))
                r.camera = Camera()
                model.fitView(animated: false)
                model.refreshScene()
                save(r.renderImage(width: 1600, height: 1000), to: dir.appendingPathComponent("\(name)-3d.png"))

                // Picking in the middle of the view should find a face.
                let hit = r.pick(at: CGPoint(x: 400, y: 250))
                note("  pick centre: \(hit.map { "\($0)" } ?? "nothing")")

                // Select a face, then render the highlight.
                if let h = hit, let sel = model.selection(for: h) { model.selection = [sel] }
                save(r.renderImage(width: 1600, height: 1000), to: dir.appendingPathComponent("\(name)-selected.png"))
                model.selection = []

                // Print check
                model.runPrintCheck()
                for _ in 0..<50 where model.printCheck == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                if let c = model.printCheck {
                    note("  print check: " + c.issues.map { "\($0.kind.rawValue): \($0.detail)" }.joined(separator: " | "))
                    note("  filament ≈ \(Format.number(c.grams, digits: 1)) g")
                    model.printCheck?.showBed = true
                    model.setView(.iso)
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    save(r.renderImage(width: 1600, height: 1000), to: dir.appendingPathComponent("\(name)-printcheck.png"))
                    model.printCheck = nil
                }

                // Exports
                for f in ExportFormat.allCases {
                    let file: ExportedFile? = await withCheckedContinuation { c in
                        model.export(f, quality: .normal, name: name) { c.resume(returning: $0) }
                    }
                    if let file {
                        let size = (try? FileManager.default.attributesOfItem(atPath: file.url.path)[.size] as? Int) ?? 0
                        let dest = dir.appendingPathComponent(file.url.lastPathComponent)
                        try? FileManager.default.copyItem(at: file.url, to: dest)
                        note("  export \(f.rawValue): \(size) bytes")
                    } else {
                        note("  export \(f.rawValue): FAILED")
                    }
                }

                // Sketch mode on the top face
                if name == "box" {
                    model.startSketch()
                    model.changeSketch { sk in
                        let c = sk.addPoint(Vec2(0, 0))
                        let circle = sk.addCircle(center: c, radius: 8)
                        sk.addConstraint(.coincident, [c, Sketch.originID])
                        sk.addConstraint(.diameter, [circle], value: 16)
                        let p = [sk.addPoint(Vec2(-25, -15)), sk.addPoint(Vec2(-10, -15)), sk.addPoint(Vec2(-10, -5)), sk.addPoint(Vec2(-25, -5))]
                        let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
                        sk.addConstraint(.horizontal, [l[0]]); sk.addConstraint(.vertical, [l[1]])
                        sk.addConstraint(.horizontal, [l[2]]); sk.addConstraint(.vertical, [l[3]])
                        sk.addConstraint(.length, [l[0]], value: 15)
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    note("  sketch: \(model.sketch?.regions.count ?? -1) regions, fully defined \(model.sketch?.solve?.isFullyDefined ?? false), labels \(model.dimensionLabels.map(\.text))")
                    model.refreshScene()
                    save(r.renderImage(width: 1600, height: 1000), to: dir.appendingPathComponent("\(name)-sketch.png"))
                    model.finishSketch()
                    await waitForBuild(model)
                    if let first = model.selectedRegions.first {
                        note("  after sketch: region selected (area \(Format.number(first.1.area, digits: 1)))")
                        model.start(.extrude)
                        model.setHandleValue(.distance(origin: .zero, direction: Vec3(0, 0, 1)), 10)
                        await waitForBuild(model)
                        note("  extrude preview status: \(model.tool?.status ?? .ok), bodies \(model.output.bodies.count)")
                        model.refreshScene()
                        save(r.renderImage(width: 1600, height: 1000), to: dir.appendingPathComponent("\(name)-extrude.png"))
                        model.applyTool()
                        await waitForBuild(model)
                        note("  features now: \(doc.design.features.map(\.name))")
                    } else {
                        note("  after sketch: NO region selected")
                    }
                }
            }
            try? log.write(to: dir.appendingPathComponent("log.txt"), atomically: true, encoding: .utf8)
            print("SELFTEST DONE \(dir.path)")
            exit(0)
        }
    }

    private static func waitForBuild(_ model: EditorModel) async {
        try? await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<200 where model.isBuilding { try? await Task.sleep(nanoseconds: 50_000_000) }
    }

    private static func save(_ image: CGImage?, to url: URL) {
        guard let image, let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
