import Foundation

/// The whole design: an ordered list of features. This is the source of truth;
/// bodies are always rebuilt from it.
struct Design: Codable, Equatable {
    var formatVersion: Int = 1
    var unit: LengthUnit = .mm
    var features: [Feature] = []
    var bodyStyles: [String: BodyStyle] = [:]
    var printerID: String? = nil
    var material: String? = nil
    /// Imported STEP bodies (OCCT BREP text), stored as separate files in the package.
    var importedShapes: [String: Data] = [:]

    enum CodingKeys: String, CodingKey { case formatVersion, unit, features, bodyStyles, printerID, material }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? 1
        unit = try c.decodeIfPresent(LengthUnit.self, forKey: .unit) ?? .mm
        features = try c.decodeIfPresent([Feature].self, forKey: .features) ?? []
        bodyStyles = try c.decodeIfPresent([String: BodyStyle].self, forKey: .bodyStyles) ?? [:]
        printerID = try c.decodeIfPresent(String.self, forKey: .printerID)
        material = try c.decodeIfPresent(String.self, forKey: .material)
    }

    func feature(_ id: UUID) -> Feature? { features.first { $0.id == id } }
    func index(of id: UUID) -> Int? { features.firstIndex { $0.id == id } }

    mutating func update(_ id: UUID, _ change: (inout Feature) -> Void) {
        if let i = index(of: id) { change(&features[i]) }
    }

    func style(_ body: String) -> BodyStyle { bodyStyles[body] ?? BodyStyle() }

    /// "Sketch 3", "Extrude 2" … the next free number for a kind of feature.
    func nextName(for kind: Feature.Kind) -> String {
        let n = features.filter { $0.kind == kind }.count + 1
        return "\(kind.rawValue) \(n)"
    }
}

struct BodyStyle: Codable, Equatable {
    var colorIndex: Int = 0
    var hidden: Bool = false
    var name: String? = nil
}

struct Feature: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    /// Stable internal name ("Extrude 2"); shown localised via `kind`.
    var name: String
    var suppressed: Bool = false
    var operation: Operation

    enum Kind: String, Codable {
        case sketch = "Sketch", extrude = "Extrude", revolve = "Revolve", pushPull = "PushPull",
             fillet = "Fillet", chamfer = "Chamfer", shell = "Shell", boolean = "Combine",
             transform = "Move", mirror = "Mirror", pattern = "Pattern", hole = "Hole",
             primitive = "Primitive", text = "Text", importBody = "Import", deleteBody = "Delete",
             split = "Split"
    }

    var kind: Kind {
        switch operation {
        case .sketch: .sketch
        case .extrude: .extrude
        case .revolve: .revolve
        case .pushPull: .pushPull
        case .fillet: .fillet
        case .chamfer: .chamfer
        case .shell: .shell
        case .boolean: .boolean
        case .transform: .transform
        case .mirror: .mirror
        case .pattern: .pattern
        case .hole: .hole
        case .primitive: .primitive
        case .text: .text
        case .importBody: .importBody
        case .deleteBody: .deleteBody
        case .split: .split
        }
    }

    var sketch: SketchFeature? { if case .sketch(let s) = operation { return s }; return nil }
}

enum Operation: Codable, Equatable {
    case sketch(SketchFeature)
    case extrude(ExtrudeFeature)
    case revolve(RevolveFeature)
    case pushPull(PushPullFeature)
    case fillet(EdgeFeature)
    case chamfer(EdgeFeature)
    case shell(ShellFeature)
    case boolean(BooleanFeature)
    case transform(TransformFeature)
    case mirror(MirrorFeature)
    case pattern(PatternFeature)
    case hole(HoleFeature)
    case primitive(PrimitiveFeature)
    case text(TextFeature)
    case importBody(ImportFeature)
    case deleteBody(DeleteBodyFeature)
    case split(SplitFeature)
}

// MARK: - References into the model

/// Where a sketch lives.
enum PlaneRef: Codable, Equatable {
    case origin(OriginPlane, offset: Double)
    case face(FaceRef)
}

enum OriginPlane: String, Codable, CaseIterable {
    case xy, xz, yz
    var plane: Plane {
        switch self { case .xy: .xy; case .xz: .xz; case .yz: .yz }
    }
}

/// A face of a body, remembered by what it looks like so it can be found again after a rebuild
/// even when OCCT numbers the faces differently.
struct FaceRef: Codable, Equatable, Hashable {
    var body: String
    var kind: Int
    var centroid: Vec3
    var normal: Vec3
    var area: Double
    var radius: Double = 0
}

struct EdgeRef: Codable, Equatable, Hashable {
    var body: String
    var kind: Int
    var midpoint: Vec3
    var start: Vec3
    var end: Vec3
    var length: Double
    var radius: Double = 0
    /// Kinds and normals of the faces next to the edge.
    var faceKinds: [Int] = []
    var faceNormals: [Vec3] = []
}

enum BodyMode: String, Codable, CaseIterable {
    case newBody, join, cut, intersect
}

// MARK: - Features

struct SketchFeature: Codable, Equatable {
    var plane: PlaneRef
    var sketch: Sketch = Sketch()
    /// Extra distance along the plane's normal, for sketches on a face ("sketch 5 mm above this face").
    /// Origin planes keep their offset in `PlaneRef.origin`. Optional so older files decode unchanged.
    var planeOffset: Double? = nil
}

struct ExtrudeFeature: Codable, Equatable {
    var sketch: UUID
    /// Points inside the chosen regions (sketch coordinates).
    var regionSeeds: [Vec2]
    var distance: Double
    var symmetric: Bool = false
    var mode: BodyMode = .newBody
    var target: String? = nil
    /// Taper of the side walls in radians (draft angle). Positive = narrower towards the far end.
    /// nil or 0 = straight walls. Optional so older files decode unchanged.
    var draftAngle: Double? = nil
}

struct RevolveFeature: Codable, Equatable {
    var sketch: UUID
    var regionSeeds: [Vec2]
    /// A line of the sketch used as axis; nil = the sketch's vertical axis through its origin.
    var axisCurve: Int?
    var angle: Double = 2 * .pi
    var mode: BodyMode = .newBody
    var target: String? = nil
}

struct PushPullFeature: Codable, Equatable {
    var face: FaceRef
    var distance: Double
}

struct EdgeFeature: Codable, Equatable {
    var edges: [EdgeRef]
    var value: Double
}

struct ShellFeature: Codable, Equatable {
    var body: String
    var openFaces: [FaceRef]
    var thickness: Double
}

struct BooleanFeature: Codable, Equatable {
    enum Op: String, Codable, CaseIterable { case union, subtract, intersect }
    var target: String
    var tools: [String]
    var op: Op
    var keepTools: Bool = false
}

struct TransformFeature: Codable, Equatable {
    var bodies: [String]
    var translation: Vec3 = .zero
    /// Rotation around `pivot` about `axis` (radians).
    var axis: Vec3 = Vec3(0, 0, 1)
    var angle: Double = 0
    var pivot: Vec3 = .zero
    var uniformScale: Double = 1
    var copy: Bool = false
}

struct MirrorFeature: Codable, Equatable {
    var bodies: [String]
    var plane: PlaneRef
    var keepOriginal: Bool = true
    /// Fuse the mirrored copy with the original (for symmetric parts).
    var merge: Bool = true
}

struct PatternFeature: Codable, Equatable {
    enum Kind: String, Codable { case linear, circular }
    var bodies: [String]
    var kind: Kind
    var count: Int
    /// Linear: direction × spacing between copies.
    var direction: Vec3 = Vec3(1, 0, 0)
    var spacing: Double = 10
    /// Circular: copies spread over `totalAngle` around an axis through `axisOrigin`.
    var axisOrigin: Vec3 = .zero
    var axis: Vec3 = Vec3(0, 0, 1)
    var totalAngle: Double = 2 * .pi
    /// Merge the copies into the original body (typical for printing).
    var merge: Bool = true
}

struct HoleFeature: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case simple, counterbore, countersink }
    var face: FaceRef
    /// Centres of the holes on the face's sketch plane.
    var positions: [Vec2]
    var kind: Kind = .simple
    var diameter: Double = 3.4
    /// 0 = through all.
    var depth: Double = 0
    var headDiameter: Double = 6.5
    var headDepth: Double = 3.4
    /// The printing thread preset the diameter came from (nil = none). Only remembers the choice;
    /// `diameter` stays the size that gets built. Optional so older files decode unchanged.
    var printThread: PrintThread? = nil

    /// Sizes the hole for a thread preset: a tap-drill hole the screw cuts its thread into,
    /// or the hole for a heat-set insert. nil clears the preset and keeps the diameter.
    mutating func apply(_ thread: PrintThread?) {
        printThread = thread
        guard let thread, let size = PrintThread.size(thread.size) else { return }
        kind = .simple
        switch thread.kind {
        case .screwCutsThread:
            diameter = size.tapDrill
        case .heatSetInsert:
            diameter = size.insertHole
            // A blind hole must be deeper than the insert.
            if depth > 0 && depth < size.insertLength + 1 { depth = size.insertLength + 1 }
        }
    }
}

/// A thread for 3D printing, sized as a simple hole (no modelled thread).
struct PrintThread: Codable, Equatable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// The screw cuts its own thread into the plastic (tap-drill size).
        case screwCutsThread = "tap"
        /// A brass heat-set insert is melted in.
        case heatSetInsert = "insert"
    }

    var size: String
    var kind: Kind

    struct Size {
        let name: String
        /// ISO metric coarse tap drill.
        let tapDrill: Double
        /// Hole for common heat-set inserts (CNC Kitchen / ruthex sizes).
        let insertHole: Double
        /// Length of the standard insert.
        let insertLength: Double
    }

    static let sizes: [Size] = [
        Size(name: "M3", tapDrill: 2.5, insertHole: 4.0, insertLength: 5.7),
        Size(name: "M4", tapDrill: 3.3, insertHole: 5.6, insertLength: 8.1),
        Size(name: "M5", tapDrill: 4.2, insertHole: 6.4, insertLength: 9.5),
        Size(name: "M6", tapDrill: 5.0, insertHole: 8.0, insertLength: 12.7),
        Size(name: "M8", tapDrill: 6.8, insertHole: 9.7, insertLength: 12.7),
    ]

    static func size(_ name: String) -> Size? { sizes.first { $0.name == name } }

    /// The hole diameter this preset gives.
    var diameter: Double? {
        guard let s = PrintThread.size(size) else { return nil }
        return kind == .screwCutsThread ? s.tapDrill : s.insertHole
    }
}

struct PrimitiveFeature: Codable, Equatable {
    enum Kind: String, Codable { case box, cylinder }
    var kind: Kind
    var origin: Vec3 = .zero
    var size: Vec3 = Vec3(20, 20, 20)
}

struct TextFeature: Codable, Equatable {
    var plane: PlaneRef
    var position: Vec2
    var text: String
    var fontName: String = "Helvetica-Bold"
    var size: Double = 10
    var depth: Double = 1
    var mode: BodyMode = .join
    var target: String? = nil
}

struct ImportFeature: Codable, Equatable {
    var shapeKey: String
    var fileName: String
}

struct DeleteBodyFeature: Codable, Equatable {
    var bodies: [String]
}

struct SplitFeature: Codable, Equatable {
    var body: String
    var plane: PlaneRef
}
