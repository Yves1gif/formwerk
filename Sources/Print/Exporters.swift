import Foundation
import simd

/// One body to export: its triangles and display colour.
struct ExportBody {
    let name: String
    let mesh: TriangleMesh
    let color: SIMD4<Float>
}

enum ExportFormat: String, CaseIterable, Identifiable {
    case threeMF = "3MF", stl = "STL", step = "STEP", obj = "OBJ", usdz = "USDZ"
    var id: String { rawValue }
    var fileExtension: String {
        switch self { case .threeMF: "3mf"; case .stl: "stl"; case .step: "step"; case .obj: "obj"; case .usdz: "usdz" }
    }
}

/// Mesh quality for export: chord deviation and angle.
enum ExportQuality: String, CaseIterable, Identifiable {
    case draft, normal, fine
    var id: String { rawValue }
    var linear: Double { switch self { case .draft: 0.1; case .normal: 0.03; case .fine: 0.01 } }
    var angular: Double { switch self { case .draft: 15 * .pi / 180; case .normal: 8 * .pi / 180; case .fine: 4 * .pi / 180 } }
}

enum MeshExport {
    /// Binary STL (all bodies in one file).
    static func stl(_ bodies: [ExportBody]) -> Data {
        var out = Data()
        var header = [UInt8]("Formwerk binary STL".utf8)
        header += [UInt8](repeating: 0, count: 80 - header.count)
        out.append(contentsOf: header)
        let count = bodies.reduce(0) { $0 + $1.mesh.triangleCount }
        appendLE(&out, UInt32(count))
        for b in bodies {
            let m = b.mesh
            for t in 0..<m.triangleCount {
                let a = m.positions[Int(m.indices[t * 3])], bb = m.positions[Int(m.indices[t * 3 + 1])], c = m.positions[Int(m.indices[t * 3 + 2])]
                let raw = simd_cross(bb - a, c - a)
                let n = simd_length(raw) > 0 ? simd_normalize(raw) : SIMD3<Float>(0, 0, 0)
                for v in [n, a, bb, c] {
                    appendLE(&out, v.x.bitPattern); appendLE(&out, v.y.bitPattern); appendLE(&out, v.z.bitPattern)
                }
                out.append(contentsOf: [0, 0])
            }
        }
        return out
    }

    /// Wavefront OBJ with one object per body.
    static func obj(_ bodies: [ExportBody]) -> Data {
        var s = "# Formwerk\n"
        var base = 1
        for b in bodies {
            let (verts, tris) = welded(b.mesh)
            s += "o \(b.name.replacingOccurrences(of: " ", with: "_"))\n"
            for v in verts { s += "v \(fmt(v.x)) \(fmt(v.y)) \(fmt(v.z))\n" }
            for t in tris { s += "f \(Int(t.x) + base) \(Int(t.y) + base) \(Int(t.z) + base)\n" }
            base += verts.count
        }
        return Data(s.utf8)
    }

    /// 3MF: a zip with the model XML. Units are millimetres; each body is its own object with its colour.
    static func threeMF(_ bodies: [ExportBody]) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <metadata name="Application">Formwerk</metadata>
        <resources>
        <basematerials id="1">

        """
        for b in bodies {
            let c = b.color
            let hex = String(format: "#%02X%02X%02X", Int(c.x * 255), Int(c.y * 255), Int(c.z * 255))
            xml += "<base name=\"\(escape(b.name))\" displaycolor=\"\(hex)\"/>\n"
        }
        xml += "</basematerials>\n"
        for (i, b) in bodies.enumerated() {
            let (verts, tris) = welded(b.mesh)
            xml += "<object id=\"\(i + 2)\" name=\"\(escape(b.name))\" type=\"model\" pid=\"1\" pindex=\"\(i)\"><mesh><vertices>\n"
            for v in verts { xml += "<vertex x=\"\(fmt(v.x))\" y=\"\(fmt(v.y))\" z=\"\(fmt(v.z))\"/>\n" }
            xml += "</vertices><triangles>\n"
            for t in tris { xml += "<triangle v1=\"\(t.x)\" v2=\"\(t.y)\" v3=\"\(t.z)\"/>\n" }
            xml += "</triangles></mesh></object>\n"
        }
        xml += "</resources>\n<build>\n"
        for i in bodies.indices { xml += "<item objectid=\"\(i + 2)\"/>\n" }
        xml += "</build>\n</model>\n"

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
        </Types>
        """
        let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """
        return Zip.store([
            ("[Content_Types].xml", Data(contentTypes.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("3D/3dmodel.model", Data(xml.utf8)),
        ])
    }

    /// Merges vertices with the same position (OCCT keeps them separate per face) so the mesh is connected.
    static func welded(_ m: TriangleMesh) -> ([SIMD3<Float>], [SIMD3<Int32>]) {
        var ids: [SIMD3<Int32>: Int32] = [:]
        var verts: [SIMD3<Float>] = []
        var map = [Int32](repeating: 0, count: m.positions.count)
        for (i, p) in m.positions.enumerated() {
            let k = SIMD3<Int32>(Int32((p.x * 10000).rounded()), Int32((p.y * 10000).rounded()), Int32((p.z * 10000).rounded()))
            if let id = ids[k] { map[i] = id } else {
                let id = Int32(verts.count)
                ids[k] = id
                verts.append(p)
                map[i] = id
            }
        }
        var tris: [SIMD3<Int32>] = []
        tris.reserveCapacity(m.triangleCount)
        for t in 0..<m.triangleCount {
            let a = map[Int(m.indices[t * 3])], b = map[Int(m.indices[t * 3 + 1])], c = map[Int(m.indices[t * 3 + 2])]
            if a != b && b != c && a != c { tris.append(SIMD3(a, b, c)) }
        }
        return (verts, tris)
    }

    private static func fmt(_ v: Float) -> String {
        let s = String(format: "%.4f", v)
        // trim zeros: 12.5000 → 12.5
        var t = s
        while t.contains(".") && (t.hasSuffix("0") || t.hasSuffix(".")) { t.removeLast() }
        return t == "-0" ? "0" : t
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func appendLE<T: FixedWidthInteger>(_ d: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
}

/// A minimal ZIP writer (stored, no compression): enough for 3MF.
enum Zip {
    /// `align`: start every file's data at a multiple of this many bytes (USDZ needs 64).
    static func store(_ files: [(String, Data)], align: Int = 1) -> Data {
        var out = Data()
        var central = Data()
        for (name, data) in files {
            let nameData = Data(name.utf8)
            let crc = CRC32.checksum(data)
            let offset = UInt32(out.count)
            // Padding goes into an "extra field" so the data lands on the alignment boundary.
            var pad = 0
            if align > 1 {
                let start = out.count + 30 + nameData.count
                pad = (align - start % align) % align
                if pad > 0 && pad < 4 { pad += align }
            }
            // local file header
            le(&out, UInt32(0x04034b50)); le(&out, UInt16(20)); le(&out, UInt16(0)); le(&out, UInt16(0))
            le(&out, UInt16(0)); le(&out, UInt16(0x21))  // time, date (1980-01-01)
            le(&out, crc); le(&out, UInt32(data.count)); le(&out, UInt32(data.count))
            le(&out, UInt16(nameData.count)); le(&out, UInt16(pad))
            out.append(nameData)
            if pad > 0 {
                le(&out, UInt16(0x1986)); le(&out, UInt16(pad - 4))
                out.append(Data(count: pad - 4))
            }
            out.append(data)
            // central directory entry
            le(&central, UInt32(0x02014b50)); le(&central, UInt16(20)); le(&central, UInt16(20)); le(&central, UInt16(0))
            le(&central, UInt16(0)); le(&central, UInt16(0)); le(&central, UInt16(0x21))
            le(&central, crc); le(&central, UInt32(data.count)); le(&central, UInt32(data.count))
            le(&central, UInt16(nameData.count)); le(&central, UInt16(0)); le(&central, UInt16(0))
            le(&central, UInt16(0)); le(&central, UInt16(0)); le(&central, UInt32(0)); le(&central, offset)
            central.append(nameData)
        }
        let cdOffset = UInt32(out.count)
        out.append(central)
        le(&out, UInt32(0x06054b50)); le(&out, UInt16(0)); le(&out, UInt16(0))
        le(&out, UInt16(files.count)); le(&out, UInt16(files.count))
        le(&out, UInt32(central.count)); le(&out, cdOffset); le(&out, UInt16(0))
        return out
    }

    private static func le<T: FixedWidthInteger>(_ d: inout Data, _ v: T) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }
}
