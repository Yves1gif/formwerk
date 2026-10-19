import SwiftUI

extension EditorModel {
    /// Makes a USDZ of the visible bodies and hands back its URL.
    func makeUSDZ(completion: @escaping (URL?) -> Void) {
        let bodies = output.bodies.filter { !design.style($0.id).hidden }
        guard !bodies.isEmpty else { show(String(localized: "There is nothing to export yet.")); completion(nil); return }
        let styles = bodies.map { design.style($0.id) }
        worker.run({ () -> URL? in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ar-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("Formwerk.usdz")
            let export = bodies.enumerated().map { i, b in
                ExportBody(name: "Body\(i + 1)", mesh: b.shape.mesh(linear: 0.05, angular: 0.3),
                           color: Palette.bodies[styles[i].colorIndex % Palette.bodies.count])
            }
            return (try? USDZExport.write(export, to: url)) != nil ? url : nil
        }) { [weak self] url in
            if url == nil { self?.show(String(localized: "Couldn't make the AR file."), kind: .error) }
            completion(url)
        }
    }
}

#if os(iOS)
import QuickLook

/// AR Quick Look: place the part on your desk at real size.
struct ARQuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let ql = QLPreviewController()
        ql.dataSource = context.coordinator
        return UINavigationController(rootViewController: ql)
    }

    func updateUIViewController(_ vc: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
#endif
