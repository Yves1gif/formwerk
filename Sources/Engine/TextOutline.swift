import CoreGraphics
import CoreText
import Foundation
import simd

/// Turns text into closed outlines for extruding (name tags, labels).
/// Curves are flattened into short lines, which prints exactly the same.
enum TextOutline {
    /// Regions ready for `Kernel.face`: each is [outer, holes…], outer CCW, holes CW.
    /// The text is centred on `center` (sketch coordinates), `size` = cap height in mm.
    static func regions(for text: String, fontName: String, size: Double, at center: Vec2) -> [[[RegionSegment]]] {
        let contours = outlines(for: text, fontName: fontName, size: size)
        guard !contours.isEmpty else { return [] }

        var box = (min: Vec2(repeating: .infinity), max: Vec2(repeating: -.infinity))
        for c in contours { for p in c { box.min = simd_min(box.min, p); box.max = simd_max(box.max, p) } }
        let shift = center - (box.min + box.max) / 2
        let shifted = contours.map { $0.map { $0 + shift } }

        // Nest contours: a contour inside an odd number of others is a hole.
        let areas = shifted.map { Polygon.signedArea($0) }
        var depth = [Int](repeating: 0, count: shifted.count)
        var parent = [Int?](repeating: nil, count: shifted.count)
        for i in shifted.indices {
            guard let probe = shifted[i].first else { continue }
            var bestArea = Double.infinity
            for j in shifted.indices where j != i && abs(areas[j]) > abs(areas[i]) && Polygon.contains(shifted[j], probe) {
                depth[i] += 1
                if abs(areas[j]) < bestArea { bestArea = abs(areas[j]); parent[i] = j }
            }
        }
        var result: [[[RegionSegment]]] = []
        for i in shifted.indices where depth[i] % 2 == 0 {
            var loops = [orient(shifted[i], ccw: true)]
            for k in shifted.indices where parent[k] == i && depth[k] % 2 == 1 {
                loops.append(orient(shifted[k], ccw: false))
            }
            result.append(loops)
        }
        return result
    }

    private static func orient(_ poly: [Vec2], ccw: Bool) -> [RegionSegment] {
        let pts = (Polygon.signedArea(poly) > 0) == ccw ? poly : poly.reversed()
        return pts.indices.map { .line(pts[$0], pts[($0 + 1) % pts.count]) }
    }

    /// Glyph contours as polygons (mm), baseline at y = 0.
    static func outlines(for text: String, fontName: String, size: Double) -> [[Vec2]] {
        let base = CTFontCreateWithName(fontName as CFString, 100, nil)
        let capHeight = max(CTFontGetCapHeight(base), 1)
        let scale = size / Double(capHeight)
        let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): base])
        let line = CTLineCreateWithAttributedString(attr)
        var contours: [[Vec2]] = []
        let runs = CTLineGetGlyphRuns(line) as? [CTRun] ?? []
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let font = attrs[kCTFontAttributeName as String].map { $0 as! CTFont } ?? base
            for (g, pos) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font, g, nil) else { continue }
                var current: [Vec2] = []
                var last = Vec2.zero
                func add(_ p: CGPoint) {
                    let v = Vec2((Double(p.x) + Double(pos.x)) * scale, (Double(p.y) + Double(pos.y)) * scale)
                    if current.last.map({ ($0 - v).length > 1e-4 }) ?? true { current.append(v) }
                    last = v
                }
                func close() {
                    if current.count > 2 {
                        if (current[0] - current[current.count - 1]).length < 1e-4 { current.removeLast() }
                        if current.count > 2 && abs(Polygon.signedArea(current)) > 1e-4 { contours.append(current) }
                    }
                    current = []
                }
                path.applyWithBlock { el in
                    let e = el.pointee
                    switch e.type {
                    case .moveToPoint:
                        close(); add(e.points[0])
                    case .addLineToPoint:
                        add(e.points[0])
                    case .addQuadCurveToPoint:
                        let p0 = last, c = e.points[0], p1 = e.points[1]
                        for i in 1...8 {
                            let t = CGFloat(i) / 8
                            let x = (1 - t) * (1 - t) * CGFloat(p0.x / scale - Double(pos.x)) + 2 * (1 - t) * t * c.x + t * t * p1.x
                            let y = (1 - t) * (1 - t) * CGFloat(p0.y / scale - Double(pos.y)) + 2 * (1 - t) * t * c.y + t * t * p1.y
                            add(CGPoint(x: x, y: y))
                        }
                    case .addCurveToPoint:
                        let p0 = CGPoint(x: last.x / scale - Double(pos.x), y: last.y / scale - Double(pos.y))
                        let c1 = e.points[0], c2 = e.points[1], p1 = e.points[2]
                        for i in 1...10 {
                            let t = CGFloat(i) / 10, u = 1 - t
                            let x = u * u * u * p0.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * p1.x
                            let y = u * u * u * p0.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * p1.y
                            add(CGPoint(x: x, y: y))
                        }
                    case .closeSubpath:
                        close()
                    @unknown default:
                        break
                    }
                }
                close()
            }
        }
        return contours
    }
}
