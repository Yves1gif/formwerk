import simd
import Foundation
import SwiftUI

enum SketchTool: String, CaseIterable, Identifiable {
    case select, line, rectangle, circle, arc, slot, polygon, point, dimension
    var id: String { rawValue }

    var icon: String {
        switch self {
        case .select: "cursorarrow"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .circle: "circle"
        case .arc: "circle.bottomhalf.filled"
        case .slot: "capsule"
        case .polygon: "hexagon"
        case .point: "smallcircle.filled.circle"
        case .dimension: "ruler"
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .select: "Select"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .circle: "Circle"
        case .arc: "Arc"
        case .slot: "Slot"
        case .polygon: "Polygon"
        case .point: "Point"
        case .dimension: "Dimension"
        }
    }

    var shortcut: KeyEquivalent? {
        switch self {
        case .select: "s"
        case .line: "l"
        case .rectangle: "r"
        case .circle: "c"
        case .arc: "a"
        case .slot: "o"
        case .polygon: "p"
        case .point: nil
        case .dimension: "d"
        }
    }

    /// What to do next, shown under the toolbar.
    var hint: LocalizedStringKey {
        switch self {
        case .select: "Tap to select. Drag points to move them."
        case .line: "Tap the start, then each next point. Tap the first point to close."
        case .rectangle: "Tap two opposite corners."
        case .circle: "Tap the centre, then a point on the circle."
        case .arc: "Tap the centre, the start, then the end (counter-clockwise)."
        case .slot: "Tap the two centres, then the width."
        case .polygon: "Tap the centre, then a corner."
        case .point: "Tap to place a point."
        case .dimension: "Tap a line, circle or two points to add a dimension."
        }
    }
}

enum SketchItem: Hashable {
    case point(Int)
    case curve(Int)
    case constraint(Int)
}

/// Where the cursor snaps to.
struct SketchSnap: Equatable {
    enum Kind: Equatable { case point, origin, model, curve(Int), midpoint(Int), grid, free }
    var position: Vec2
    var pointID: Int?
    var kind: Kind
}

/// An open sketch being edited. Changes stay here until "Done".
struct SketchSession {
    var featureID: UUID
    var isNew: Bool
    var planeRef: PlaneRef
    var plane: Plane
    var sketch: Sketch
    var solve: SketchSolver.Result?
    var tool: SketchTool = .line
    /// The tool before the current one (Pencil squeeze / double-tap go back to it).
    var previousTool: SketchTool?
    /// The last drawing tool, so Space and the Pencil can return to it from Select.
    var lastDrawTool: SketchTool = .line
    /// Points/positions placed so far by the current drawing action.
    var clicks: [SketchSnap] = []
    /// Line chains continue from this point.
    var chainStart: Int?
    var cursor: SketchSnap?
    var selected: Set<SketchItem> = []
    var regions: [SketchRegion] = []
    var regionFills: [[SIMD3<Float>]] = []
    var editingDimension: Int?
    var undoStack: [Sketch] = []
    var redoStack: [Sketch] = []
    /// Model vertices lying on the sketch plane (snap targets).
    var modelSnaps: [Vec2] = []
    var cameraBefore: Camera?
    var polygonSides = 6

    var isEmpty: Bool { sketch.curves.isEmpty }
}

/// What a drag in the 3D view is doing.
enum DragState {
    case sketchPoint(id: Int, before: Sketch)
    case sketchLine(id: Int, start: Vec2, before: Sketch, ends: (Vec2, Vec2))
    case sketchCircle(id: Int, before: Sketch)
    case sketchDraw(start: SketchSnap)
    case handle(ToolHandle, startValue: Double, startPoint: CGPoint)
}
