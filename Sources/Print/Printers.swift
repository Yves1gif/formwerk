import Foundation

/// A 3D printer's build volume and nozzle.
struct Printer: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    /// Build volume in mm.
    let bed: Vec3
    let nozzle: Double

    static let all: [Printer] = [
        Printer(id: "bambu-a1mini", name: "Bambu Lab A1 mini", bed: Vec3(180, 180, 180), nozzle: 0.4),
        Printer(id: "bambu-a1", name: "Bambu Lab A1", bed: Vec3(256, 256, 256), nozzle: 0.4),
        Printer(id: "bambu-p1s", name: "Bambu Lab P1S / X1C", bed: Vec3(256, 256, 256), nozzle: 0.4),
        Printer(id: "bambu-h2d", name: "Bambu Lab H2D", bed: Vec3(325, 320, 325), nozzle: 0.4),
        Printer(id: "prusa-mk4s", name: "Prusa MK4S", bed: Vec3(250, 210, 220), nozzle: 0.4),
        Printer(id: "prusa-coreone", name: "Prusa Core One", bed: Vec3(250, 220, 270), nozzle: 0.4),
        Printer(id: "prusa-mini", name: "Prusa MINI+", bed: Vec3(180, 180, 180), nozzle: 0.4),
        Printer(id: "ender3v3", name: "Creality Ender-3 V3", bed: Vec3(220, 220, 250), nozzle: 0.4),
        Printer(id: "creality-k1", name: "Creality K1", bed: Vec3(220, 220, 250), nozzle: 0.4),
        Printer(id: "neptune4", name: "Elegoo Neptune 4", bed: Vec3(225, 225, 265), nozzle: 0.4),
        Printer(id: "kobra3", name: "Anycubic Kobra 3", bed: Vec3(250, 250, 260), nozzle: 0.4),
    ]

    static let fallback = all[1]

    static func find(_ id: String?) -> Printer { all.first { $0.id == id } ?? fallback }
}

/// Filament materials with their density (g/cm³).
enum Material: String, CaseIterable, Identifiable {
    case pla = "PLA", petg = "PETG", abs = "ABS", asa = "ASA", tpu = "TPU"
    var id: String { rawValue }
    var density: Double {
        switch self { case .pla: 1.24; case .petg: 1.27; case .abs: 1.04; case .asa: 1.07; case .tpu: 1.21 }
    }

    static func find(_ s: String?) -> Material { Material(rawValue: s ?? "") ?? .pla }
}
