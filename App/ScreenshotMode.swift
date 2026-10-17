import SwiftUI

/// App Store screenshots without touching the screen: launch with `-formwerkShot <scene>`
/// and the app opens a template straight into the editor and sets the scene up itself.
enum ScreenshotMode: String {
    case model, sketch, fillet, print, keychain

    static var current: ScreenshotMode? {
        UserDefaults.standard.string(forKey: "formwerkShot").flatMap(ScreenshotMode.init)
    }

    #if os(iOS)
    /// Covers the start screen with an editor on the template (screenshot mode only).
    @MainActor static func presentOverLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard let shot = current,
                  let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
                  let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene.windows.first?.rootViewController
            else { return }
            var top = root
            while let p = top.presentedViewController { top = p }
            let host = UIHostingController(rootView: NavigationStack { EditorView(document: FormwerkDocument(design: shot.design)) })
            host.modalPresentationStyle = .fullScreen
            top.present(host, animated: false)
        }
    }
    #endif

    @MainActor var design: Design {
        switch self {
        case .keychain: Templates.keychain(text: "LEA")
        case .print: Templates.plantPot()
        default: Templates.wallBracket()
        }
    }

    /// Runs once the first build is done.
    @MainActor func prepare(_ model: EditorModel, showPrint: Binding<Bool>) {
        guard let r = model.renderer else { return }
        var cam = Camera()
        cam.yaw = -.pi / 3.2
        cam.pitch = 0.5
        cam.fit(model.output.bounds)
        cam.distance *= self == .keychain ? 1.0 : 1.35
        r.camera = cam
        switch self {
        case .model:
            if let body = model.output.bodies.first,
               let top = body.faces.filter({ $0.isPlanar && $0.normal.z > 0.9 }).max(by: { $0.centroid.z < $1.centroid.z }) {
                model.selection = [.face(body: body.id, face: top.index)]
            }
        case .sketch:
            if let body = model.output.bodies.first,
               let face = body.faces.first(where: { $0.isPlanar && $0.normal.x > 0.9 }) {
                model.selection = [.face(body: body.id, face: face.index)]
                model.startSketch()
                model.setSketchTool(.circle)
                model.changeSketch { sk in
                    let c = sk.addPoint(Vec2(0, 14))
                    let circle = sk.addCircle(center: c, radius: 4)
                    sk.addConstraint(.diameter, [circle], value: 8)
                    let p = [sk.addPoint(Vec2(-7, 30)), sk.addPoint(Vec2(7, 30)), sk.addPoint(Vec2(7, 36)), sk.addPoint(Vec2(-7, 36))]
                    let l = (0..<4).map { sk.addLine(p[$0], p[($0 + 1) % 4]) }
                    sk.addConstraint(.horizontal, [l[0]]); sk.addConstraint(.vertical, [l[1]])
                    sk.addConstraint(.horizontal, [l[2]]); sk.addConstraint(.vertical, [l[3]])
                    sk.addConstraint(.length, [l[0]], value: 14)
                }
            }
        case .fillet:
            if let body = model.output.bodies.first {
                let edges = body.edges.filter { $0.kind == .line && abs($0.start.y - $0.end.y) > 19 && (($0.start.x < 0.1 && $0.start.z > 39) || ($0.start.x > 39 && $0.start.z < 0.1)) }
                model.selection = edges.map { .edge(body: body.id, edge: $0.index) }
                model.start(.fillet)
            }
        case .print:
            model.runPrintCheck()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { showPrint.wrappedValue = true }
        case .keychain:
            break
        }
    }
}
