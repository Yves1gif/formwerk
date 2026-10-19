import Foundation

/// USDZ files for AR Quick Look (iPad) and for sharing.
/// Written by hand as USDA text (millimetres, Z up, flat faces) and packed as an aligned zip.
enum USDZExport {
    static func write(_ bodies: [ExportBody], to url: URL) throws {
        try Zip.store([("Formwerk.usda", Data(usda(bodies).utf8))], align: 64).write(to: url)
    }

    static func usda(_ bodies: [ExportBody]) -> String {
        var s = """
        #usda 1.0
        (
            defaultPrim = "Formwerk"
            metersPerUnit = 0.001
            upAxis = "Z"
        )

        def Xform "Formwerk" (
            kind = "component"
        )
        {

        """
        func f(_ v: Float) -> String { String(format: "%.4f", v) }
        for (i, b) in bodies.enumerated() {
            let (verts, tris) = MeshExport.welded(b.mesh)
            let c = b.color
            s += """
                def Mesh "Body\(i + 1)"
                {
                    uniform token subdivisionScheme = "none"
                    int[] faceVertexCounts = [\(Array(repeating: "3", count: tris.count).joined(separator: ","))]
                    int[] faceVertexIndices = [\(tris.map { "\($0.x),\($0.y),\($0.z)" }.joined(separator: ","))]
                    point3f[] points = [\(verts.map { "(\(f($0.x)),\(f($0.y)),\(f($0.z)))" }.joined(separator: ","))]
                    color3f[] primvars:displayColor = [(\(f(c.x)),\(f(c.y)),\(f(c.z)))]
                }

            """
        }
        s += "}\n"
        return s
    }
}
