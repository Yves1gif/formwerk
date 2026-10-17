import simd
import SwiftUI

enum ToolKind: String, Identifiable, CaseIterable {
    case extrude, revolve, pushPull, fillet, chamfer, shell, hole, move, mirror, pattern, text, combine, split, box, cylinder, measure
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .extrude: "Extrude"
        case .revolve: "Revolve"
        case .pushPull: "Push/Pull"
        case .fillet: "Fillet"
        case .chamfer: "Chamfer"
        case .shell: "Hollow"
        case .hole: "Hole"
        case .move: "Move"
        case .mirror: "Mirror"
        case .pattern: "Pattern"
        case .text: "Text"
        case .combine: "Combine"
        case .split: "Split"
        case .box: "Box"
        case .cylinder: "Cylinder"
        case .measure: "Measure"
        }
    }

    var icon: String {
        switch self {
        case .extrude: "square.stack.3d.up"
        case .revolve: "arrow.triangle.2.circlepath"
        case .pushPull: "arrow.up.and.down.square"
        case .fillet: "square.on.circle"
        case .chamfer: "skew"
        case .shell: "cube.transparent"
        case .hole: "circle.dashed"
        case .move: "move.3d"
        case .mirror: "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .pattern: "square.grid.3x1.below.line.grid.1x2"
        case .text: "textformat"
        case .combine: "square.on.square.intersection.dashed"
        case .split: "scissors"
        case .box: "cube"
        case .cylinder: "cylinder"
        case .measure: "ruler"
        }
    }

    /// A short "what now" line for the panel.
    var hint: LocalizedStringKey {
        switch self {
        case .extrude: "Drag the arrow or type the height. Tap more areas to add them."
        case .revolve: "Spins the area around an axis. Pick a sketch line as axis, or use the sketch's vertical axis."
        case .pushPull: "Drag the arrow: out adds material, in removes it."
        case .fillet: "Tap more edges to round them too."
        case .chamfer: "Tap more edges to bevel them too."
        case .shell: "Tap faces to leave them open."
        case .hole: "Tap on the face to add more holes."
        case .move: "Drag an arrow or type the distances."
        case .mirror: "Tap a flat face to mirror across it, or pick a main plane."
        case .pattern: "Copies the body in a row or around an axis."
        case .text: "Tap a flat face to put the text there."
        case .combine: "The first body keeps the result."
        case .split: "Cuts the body in two with a plane."
        case .box, .cylinder: "Type the size. You can change it any time in the timeline."
        case .measure: "Tap two faces, edges or bodies."
        }
    }
}

/// An open tool. Its feature is previewed live and added to the design on "Done".
struct ToolSession {
    var kind: ToolKind
    var feature: Feature
    /// Set when editing an existing feature from the timeline.
    var editing: UUID?
    /// Extrude/text pick join or cut from the drag direction until the user chooses.
    var autoMode = true
    var status: ModelBuilder.Status = .ok
    /// Measure tool picks.
    var picks: [Selection] = []

    var featureID: UUID { editing ?? feature.id }
}

/// A draggable arrow in the 3D view.
enum ToolHandle: Equatable {
    case distance(origin: Vec3, direction: Vec3)
    case moveAxis(Int, origin: Vec3)

    var origin: Vec3 {
        switch self { case .distance(let o, _), .moveAxis(_, let o): o }
    }

    var direction: Vec3 {
        switch self {
        case .distance(_, let d): d
        case .moveAxis(let i, _): i == 0 ? Vec3(1, 0, 0) : i == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1)
        }
    }

    var color: SIMD4<Float> {
        switch self {
        case .distance: SIMD4(0.1, 0.45, 1, 1)
        case .moveAxis(let i, _): i == 0 ? SIMD4(0.9, 0.2, 0.2, 1) : i == 1 ? SIMD4(0.2, 0.7, 0.3, 1) : SIMD4(0.15, 0.4, 0.95, 1)
        }
    }
}
