import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

extension Theme {
    /// One spring vocabulary for the whole app. With Reduce Motion every spring becomes a short
    /// ease (opacity still fades, nothing flies or bounces) and the transitions become cross-fades.
    ///
    /// - `snappy`: controls, chips, selection, small state swaps (≈ 0.28 s, no overshoot)
    /// - `smooth`: panels changing size or content (≈ 0.4 s)
    /// - `bouncy`: a moment of delight (tutorial done, first export), use sparingly
    @MainActor
    enum Motion {
        static var reduceMotion: Bool {
            #if os(iOS)
            return UIAccessibility.isReduceMotionEnabled
            #else
            return NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            #endif
        }

        static var snappy: Animation { reduceMotion ? .easeOut(duration: 0.15) : .snappy(duration: 0.28) }
        static var smooth: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4) }
        static var bouncy: Animation { reduceMotion ? .easeOut(duration: 0.18) : .bouncy(duration: 0.45, extraBounce: 0.1) }

        /// A panel growing out of the point it belongs to (e.g. `.topTrailing` for the inspector).
        static func panel(from anchor: UnitPoint) -> AnyTransition {
            reduceMotion ? .opacity : .scale(scale: 0.94, anchor: anchor).combined(with: .opacity)
        }

        /// Sliding in from an edge (toasts, bars).
        static func slide(from edge: Edge) -> AnyTransition {
            reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
        }

        /// Content replaced by the next piece (tutorial steps). Mirrors in right-to-left languages.
        static func push(from edge: Edge) -> AnyTransition {
            reduceMotion ? .opacity : .push(from: edge)
        }
    }

    /// Haptics (iPhone; iPad and Mac have no Taptic Engine, so these do nothing there).
    /// Prefer the declarative `.formwerkFeedback(_:trigger:)` on views that stay on screen; use
    /// `play(_:)` for actions that close the view they live in (Done, Apply), where a SwiftUI
    /// trigger would vanish with the view before it fires.
    @MainActor
    enum Haptics {
        /// Stepper ticks. (`SensoryFeedback.increase/.decrease` only play on watchOS, so a light
        /// impact stands in for them, slightly stronger going up.)
        static let stepUp: SensoryFeedback = .impact(weight: .light, intensity: 0.7)
        static let stepDown: SensoryFeedback = .impact(weight: .light, intensity: 0.5)

        enum Event { case selection, success, error }

        static func play(_ event: Event) {
            #if os(iOS)
            switch event {
            case .selection: UISelectionFeedbackGenerator().selectionChanged()
            case .success: UINotificationFeedbackGenerator().notificationOccurred(.success)
            case .error: UINotificationFeedbackGenerator().notificationOccurred(.error)
            }
            #endif
        }
    }
}

// MARK: - Modifiers

/// Fades and scales a panel in from its anchor the first time it appears.
private struct PanelAppear: ViewModifier {
    let anchor: UnitPoint
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(shown || reduceMotion ? 1 : 0.94, anchor: anchor)
            .opacity(shown ? 1 : 0)
            .onAppear { withAnimation(Theme.Motion.snappy) { shown = true } }
    }
}

/// Rolling digits for numbers that change (a cross-fade with Reduce Motion).
private struct NumericTransition: ViewModifier {
    let value: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText(value: value))
            .animation(Theme.Motion.snappy, value: value)
    }
}

/// A short horizontal shake (e.g. an input that couldn't be read). Off with Reduce Motion.
private struct Shake: ViewModifier {
    let trigger: Int
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.phaseAnimator([CGFloat(0), -6, 6, -3], trigger: trigger) { view, x in
                view.offset(x: x)
            } animation: { _ in
                .linear(duration: 0.06)
            }
        }
    }
}

/// Pointer hover: the system highlight on iPad, a soft tint on Mac.
private struct HoverHighlight<S: SwiftUI.Shape>: ViewModifier {
    let shape: S
    @State private var hovering = false

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .contentShape(.hoverEffect, shape)
            .hoverEffect(.highlight)
        #else
        content
            .overlay(shape.fill(Color.primary.opacity(hovering ? 0.07 : 0)).allowsHitTesting(false))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        #endif
    }
}

/// Shrinks while pressed, springs back on release.
private struct PressScale: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(pressed && !reduceMotion ? scale : 1)
            .opacity(pressed ? 0.85 : 1)
            .animation(Theme.Motion.snappy, value: pressed)
    }
}

/// SF Symbol bounce when `trigger` changes (tool activated, step reached). Off with Reduce Motion.
private struct SymbolBounce<T: Equatable>: ViewModifier {
    let trigger: T
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? nil : trigger)
    }
}

extension View {
    /// Scale + fade in from `anchor` when the view first appears (`.topTrailing` for the inspector,
    /// `.bottom` for bars at the bottom, `.top` for the sketch bar).
    func panelAppear(from anchor: UnitPoint) -> some View {
        modifier(PanelAppear(anchor: anchor))
    }

    /// `.contentTransition(.numericText(value:))` with the app's spring, for any Text showing `value`.
    func numericTransition(_ value: Double) -> some View {
        modifier(NumericTransition(value: value))
    }

    /// Shakes once each time `trigger` changes.
    func shake(trigger: Int) -> some View {
        modifier(Shake(trigger: trigger))
    }

    /// Hover feedback for the pointer: `.hoverEffect(.highlight)` on iPad, a tint on Mac.
    func hoverHighlight<S: SwiftUI.Shape>(_ shape: S) -> some View {
        modifier(HoverHighlight(shape: shape))
    }

    /// Press feedback for custom button styles.
    func pressScale(_ pressed: Bool, to scale: CGFloat = 0.95) -> some View {
        modifier(PressScale(pressed: pressed, scale: scale))
    }

    /// Bounces the SF Symbols inside when `trigger` changes.
    func symbolBounce<T: Equatable>(on trigger: T) -> some View {
        modifier(SymbolBounce(trigger: trigger))
    }

    /// SwiftUI `.sensoryFeedback` on iPhone/iPad; nothing on Mac.
    @ViewBuilder
    func formwerkFeedback<T: Equatable>(_ feedback: SensoryFeedback, trigger: T) -> some View {
        #if os(iOS)
        sensoryFeedback(feedback, trigger: trigger)
        #else
        self
        #endif
    }
}
