import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Who draws in a sketch on iPad: only the Pencil (fingers navigate) or fingers too.
enum PencilDrawing: String, CaseIterable, Identifiable {
    case auto, on, off
    var id: String { rawValue }
    static let key = "pencilOnlyDraws"

    var title: LocalizedStringKey {
        switch self {
        case .auto: "Automatic"
        case .on: "Only Apple Pencil draws"
        case .off: "Fingers draw too"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .auto: "Once you use Apple Pencil, the Pencil draws and one finger orbits the view."
        case .on: "Apple Pencil draws and drags. One finger orbits, two fingers pan and zoom."
        case .off: "One finger draws, as without a Pencil. Drag on empty space to orbit."
        }
    }

    static var current: PencilDrawing {
        UserDefaults.standard.string(forKey: key).flatMap(PencilDrawing.init) ?? .auto
    }

    /// Set once a Pencil touches the view; "Automatic" then lets only the Pencil draw.
    @MainActor static var pencilSeen = false

    /// True when only the Pencil draws in sketches and one finger orbits.
    @MainActor static var isActive: Bool {
        switch current {
        case .on: return true
        case .off: return false
        case .auto:
            #if os(iOS)
            return pencilSeen || UIPencilInteraction.prefersPencilOnlyDrawing
            #else
            return false
            #endif
        }
    }
}

/// What a mouse drag does to the camera.
enum MouseNav { case orbit, pan }

/// Mouse button layouts known from other CAD apps. Left-drag and the wheel stay the same.
enum MousePreset: String, CaseIterable, Identifiable {
    case formwerk, fusion, blender, solidworks
    var id: String { rawValue }
    static let key = "mousePreset"

    static var current: MousePreset {
        UserDefaults.standard.string(forKey: key).flatMap(MousePreset.init) ?? .formwerk
    }

    var title: LocalizedStringKey {
        switch self {
        case .formwerk: "Formwerk"
        case .fusion: "Fusion 360"
        case .blender: "Blender"
        case .solidworks: "SolidWorks"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .formwerk: "Right-drag orbits, middle-drag pans, the wheel zooms."
        case .fusion: "Middle-drag pans, Shift + middle-drag orbits."
        case .blender: "Middle-drag orbits, Shift + middle-drag pans."
        case .solidworks: "Middle-drag orbits, Control + middle-drag pans."
        }
    }

    /// Middle-button drag.
    func middle(shift: Bool, control: Bool) -> MouseNav {
        switch self {
        case .formwerk: .pan
        case .fusion: shift ? .orbit : .pan
        case .blender: shift ? .pan : .orbit
        case .solidworks: control ? .pan : .orbit
        }
    }

    /// Right-button drag: orbits in every preset, Shift pans.
    func right(shift: Bool) -> MouseNav { shift ? .pan : .orbit }
}
