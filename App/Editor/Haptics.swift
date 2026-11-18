import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Haptic feedback for sketching. On iPad the taps play in the barrel of Apple Pencil Pro (iPads have no Taptic
/// Engine), on iPhone in the phone, on the Mac on a Force Touch trackpad while a finger rests on it.
@MainActor
enum Haptics {
    /// The view whose coordinates `snap(at:in:)` points are in when no view is passed. The 3D view registers itself.
    static weak var canvasView: AnyObject? {
        didSet { if canvasView !== oldValue { prepare() } }
    }

    /// A sketch point snapped to a corner, a line, a midpoint or the grid. `point` is in the view's coordinates.
    /// Respects the "Pencil haptics" setting. Calls closer than 40 ms are dropped, so a jittery snap doesn't buzz.
    static func snap(at point: CGPoint?, in view: AnyObject?) {
        guard PencilHaptics.isOn else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnap > 0.04 else { return }
        lastSnap = now
        #if os(iOS)
        let v = (view ?? canvasView) as? UIView
        makeGenerators(for: v)
        if let canvas, let v {
            // With Apple Pencil Pro this is the barrel haptic; with a finger on iPhone, the Taptic Engine.
            canvas.alignmentOccurred(at: point ?? CGPoint(x: v.bounds.midX, y: v.bounds.midY))
            canvas.prepare()
        } else {
            selection?.selectionChanged()
            selection?.prepare()
        }
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #endif
    }

    /// A light tick, e.g. picking a tool from the Pencil palette.
    static func tick() {
        #if os(iOS)
        makeGenerators(for: canvasView as? UIView)
        selection?.selectionChanged()
        selection?.prepare()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    /// Something finished well (a sketch closed, a step applied).
    static func success() {
        #if os(iOS)
        makeGenerators(for: canvasView as? UIView)
        notification?.notificationOccurred(.success)
        notification?.prepare()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }

    /// Something didn't work (over-constrained sketch, a step failed).
    static func warning() {
        #if os(iOS)
        makeGenerators(for: canvasView as? UIView)
        notification?.notificationOccurred(.warning)
        notification?.prepare()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    /// Wakes the haptic hardware up, so the next snap plays without delay (call when a drag or hover starts).
    static func prepare() {
        #if os(iOS)
        makeGenerators(for: canvasView as? UIView)
        canvas?.prepare()
        selection?.prepare()
        #endif
    }

    private static var lastSnap: TimeInterval = 0

    #if os(iOS)
    private static weak var generatorView: UIView?
    private static var canvas: UICanvasFeedbackGenerator?
    private static var selection: UISelectionFeedbackGenerator?
    private static var notification: UINotificationFeedbackGenerator?

    /// The generators are cached and only made again when the view changes.
    private static func makeGenerators(for view: UIView?) {
        if selection != nil && view === generatorView { return }
        generatorView = view
        if let view {
            canvas = UICanvasFeedbackGenerator(view: view)
            selection = UISelectionFeedbackGenerator(view: view)
            notification = UINotificationFeedbackGenerator(view: view)
        } else {
            canvas = nil
            selection = UISelectionFeedbackGenerator()
            notification = UINotificationFeedbackGenerator()
        }
    }
    #endif
}
