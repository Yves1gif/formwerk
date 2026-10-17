import simd
import SwiftUI
import UniformTypeIdentifiers

/// A finished export, ready for the save dialog or the share sheet.
struct ExportedFile: Identifiable {
    let id = UUID()
    let url: URL
    let format: ExportFormat
}

extension EditorModel {
    var printer: Printer { Printer.find(design.printerID) }
    var material: Material { Material.find(design.material) }

    func setPrinter(_ p: Printer) {
        var d = design
        d.printerID = p.id
        commit(d, action: String(localized: "Printer"))
        runPrintCheck()
    }

    func setMaterial(_ m: Material) {
        var d = design
        d.material = m.rawValue
        commit(d, action: String(localized: "Material"))
        runPrintCheck()
    }

    func runPrintCheck() {
        let inputs = output.bodies.filter { !design.style($0.id).hidden }.map {
            PrintChecker.Input(id: $0.id, mesh: $0.mesh, volume: $0.props.volume, area: $0.props.area,
                               bounds: $0.props.bounds, validSolid: $0.isValid)
        }
        let settings = PrintChecker.Settings(printer: printer, material: material)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = PrintChecker.check(inputs, settings)
            DispatchQueue.main.async { [weak self] in self?.printCheck = r }
        }
    }

    func endPrintCheck() { printCheck = nil }

    /// Tessellates at export quality on the build queue and writes a temporary file.
    func export(_ format: ExportFormat, quality: ExportQuality, name: String, completion: @escaping (ExportedFile?) -> Void) {
        let bodies = output.bodies.filter { !design.style($0.id).hidden }
        guard !bodies.isEmpty else { show(String(localized: "There is nothing to export yet.")); completion(nil); return }
        let styles = bodies.map { design.style($0.id) }
        let safeName = name.isEmpty ? "Formwerk" : name
        worker.run({ () -> Result<URL, Error> in
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent("\(safeName).\(format.fileExtension)")
                if format == .step {
                    try Kernel.writeSTEP(bodies.map(\.shape), to: url)
                    return .success(url)
                }
                let exportBodies = bodies.enumerated().map { i, b in
                    ExportBody(name: styles[i].name ?? "\(safeName) \(i + 1)",
                               mesh: b.shape.mesh(linear: quality.linear, angular: quality.angular),
                               color: Palette.bodies[styles[i].colorIndex % Palette.bodies.count])
                }
                let data: Data = switch format {
                case .stl: MeshExport.stl(exportBodies)
                case .obj: MeshExport.obj(exportBodies)
                default: MeshExport.threeMF(exportBodies)
                }
                try data.write(to: url)
                return .success(url)
            } catch {
                return .failure(error)
            }
        }) { [weak self] result in
            switch result {
            case .success(let url): completion(ExportedFile(url: url, format: format))
            case .failure(let e): self?.show(e.localizedDescription, kind: .error); completion(nil)
            }
        }
    }
}
