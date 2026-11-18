import MetalKit
import SwiftUI

/// What the 3D view reports to the editor. Camera moves are handled by the view itself.
@MainActor
protocol ViewportInput: AnyObject {
    func viewportTap(_ p: CGPoint, extend: Bool, touch: ViewportTouch)
    /// Return true when the editor takes the drag (moving a sketch point, a handle…); false = navigate.
    func viewportDragBegan(_ p: CGPoint, touch: ViewportTouch) -> Bool
    func viewportDragMoved(_ p: CGPoint)
    func viewportDragEnded(_ p: CGPoint)
    func viewportHover(_ p: CGPoint?)
    func viewportUndo()
    func viewportRedo()
    func viewportPencil(_ action: PencilAction)
    /// Right-click / long press: selects what is under `p` and returns the actions that fit it.
    func viewportContextMenu(at p: CGPoint) -> [ViewportMenuItem]
    func viewportKey(_ key: ViewportKey) -> Bool
    /// Where the touch will probably be a frame from now (Apple Pencil, finger). Comes right after
    /// `viewportDragMoved` with the real point. For live previews only: never place geometry here.
    func viewportDragPredicted(_ p: CGPoint)
    /// True while Apple Pencil handwriting (Scribble) may start over the 3D view, e.g. a dimension is being typed.
    var viewportAcceptsHandwriting: Bool { get }
}

extension ViewportInput {
    func viewportDragPredicted(_ p: CGPoint) {}
    var viewportAcceptsHandwriting: Bool { false }
}

/// What touched the view. Pencil and pointer always draw in sketches; a finger may navigate instead.
enum ViewportTouch { case finger, pencil, pointer }

/// Pencil double-tap / squeeze, already mapped through the user's system preference.
/// ("Show palette" preferences open `PencilPaletteState` directly.)
enum PencilAction { case toggleSelect, previousTool }

/// Plain keys only (no ⌘); arrows give the orbit direction.
enum ViewportKey: Equatable { case escape, delete, enter, space, character(Character), arrow(dx: Int, dy: Int) }

struct ViewportMenuItem {
    let title: String
    let icon: String
    let run: () -> Void
}

#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

final class ViewportPlatformView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate, UIScribbleInteractionDelegate {
    weak var input: ViewportInput?
    var renderer: Renderer?
    private var toolDrag = false
    /// A right/middle-button pointer drag navigates the way the mouse preset says.
    private var pointerNav: MouseNav?
    /// What the running navigation drag does, and what touched: for the fling when it ends.
    private var dragNav: MouseNav = .orbit
    private var dragTouch: ViewportTouch = .finger
    private var lastPan: CGPoint = .zero
    private var lastPinch: CGFloat = 1
    /// The pinch zoomed during this two-finger gesture, so lifting the fingers doesn't fling a pan.
    private var pinchZoomed = false
    /// Touch type of the last touch the finger/pointer recognizers received.
    private var lastTouchType: UITouch.TouchType = .direct
    /// A finger rested on the screen when the Pencil touched down: Pencil taps then extend the selection.
    private var fingerHeld = false
    private var holdUsed = false
    private var holdStart: CGPoint = .zero
    /// The Pencil touch on the glass, for palm and finger rejection.
    private weak var pencilTouch: UITouch?
    /// Where the Pencil palette opens when the squeeze carries no hover position.
    private var lastHover: CGPoint?
    private var lastTouch: CGPoint?
    private var hoverShown = false
    private var tap: UITapGestureRecognizer!
    private var oneFinger: SamplingPanGestureRecognizer!
    private var twoFinger: UIPanGestureRecognizer!
    private var pencilTap: UITapGestureRecognizer!
    private var pencilDrag: PencilDragGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!

    /// A contact bigger than this (radius in points) is a resting palm, not a finger.
    private static let palmRadius: CGFloat = 30
    /// Pencil hover closer than this (0 = touching, 1 = farthest the iPad senses) shows the snap preview.
    private static let hoverNear: CGFloat = 0.5

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setup()
    }

    required init(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        isMultipleTouchEnabled = true
        let direct = UITouch.TouchType.direct.rawValue as NSNumber
        let pencil = UITouch.TouchType.pencil.rawValue as NSNumber
        let pointer = UITouch.TouchType.indirectPointer.rawValue as NSNumber

        tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.allowedTouchTypes = [direct, pointer]
        tap.delegate = self
        addGestureRecognizer(tap)

        // The Pencil has its own recognizers, so a finger resting on the screen doesn't block them.
        // None of them holds touches back: Pencil input reaches the sketch without delay.
        pencilTap = UITapGestureRecognizer(target: self, action: #selector(onPencilTap(_:)))
        pencilTap.allowedTouchTypes = [pencil]
        pencilTap.delaysTouchesBegan = false
        pencilTap.delaysTouchesEnded = false
        pencilTap.delegate = self
        addGestureRecognizer(pencilTap)

        oneFinger = SamplingPanGestureRecognizer(target: self, action: #selector(onPrimaryPan(_:)))
        oneFinger.minimumNumberOfTouches = 1
        oneFinger.maximumNumberOfTouches = 1
        oneFinger.allowedTouchTypes = [direct, pointer]
        oneFinger.allowedScrollTypesMask = []
        oneFinger.delegate = self
        addGestureRecognizer(oneFinger)

        // A Pencil drag starts after 4 pt instead of the pan recognizer's ~10 pt.
        pencilDrag = PencilDragGestureRecognizer(target: self, action: #selector(onPencilDrag(_:)))
        pencilDrag.allowedTouchTypes = [pencil]
        pencilDrag.delaysTouchesBegan = false
        pencilDrag.delaysTouchesEnded = false
        pencilDrag.cancelsTouchesInView = false
        addGestureRecognizer(pencilDrag)

        twoFinger = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = [direct]
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        // Trackpad / mouse wheel on iPad: scroll orbits, like on the Mac.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.allowedTouchTypes = [direct]
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let undo = UITapGestureRecognizer(target: self, action: #selector(onUndo))
        undo.numberOfTouchesRequired = 2
        undo.allowedTouchTypes = [direct]
        undo.delegate = self  // palm rejection
        addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(target: self, action: #selector(onRedo))
        redo.numberOfTouchesRequired = 3
        redo.allowedTouchTypes = [direct]
        redo.delegate = self
        addGestureRecognizer(redo)

        // Long press (finger) and right-click (pointer) select what's under them; the context bar follows.
        longPress = UILongPressGestureRecognizer(target: self, action: #selector(onLongPress(_:)))
        longPress.allowedTouchTypes = [direct]
        longPress.cancelsTouchesInView = false
        longPress.delegate = self
        addGestureRecognizer(longPress)

        let secondary = UITapGestureRecognizer(target: self, action: #selector(onSecondaryClick(_:)))
        secondary.buttonMaskRequired = .secondary
        secondary.allowedTouchTypes = [pointer]
        addGestureRecognizer(secondary)

        // Pointer and Pencil hover (M2+ iPads) both drive the snap preview.
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let pencilUI = UIPencilInteraction()
        pencilUI.delegate = self
        addInteraction(pencilUI)

        // Pencil strokes on the 3D view draw; they turn into handwriting only while a dimension is typed.
        addInteraction(UIScribbleInteraction(delegate: self))
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if rejectsFinger(touch) { return false }
        if g === tap || g === oneFinger { lastTouchType = touch.type }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two-finger pan and pinch work together; a held finger doesn't block the Pencil or an orbit.
        if (g is UIPinchGestureRecognizer && other === twoFinger) || (g === twoFinger && other is UIPinchGestureRecognizer) { return true }
        let withHold: [UIGestureRecognizer] = [pencilTap, pencilDrag, oneFinger]
        if g === longPress { return withHold.contains { $0 === other } }
        if other === longPress { return withHold.contains { $0 === g } }
        return false
    }

    // MARK: Palm and finger rejection

    private func isPalm(_ t: UITouch) -> Bool { t.type == .direct && t.majorRadius > Self.palmRadius }

    /// When only the Pencil draws: a palm, or a finger that lands while the Pencil is on the glass, is ignored.
    private func rejectsFinger(_ t: UITouch) -> Bool {
        guard t.type == .direct, PencilDrawing.isActive else { return false }
        if isPalm(t) { return true }
        if let p = pencilTouch, p.phase != .ended, p.phase != .cancelled { return true }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        Haptics.canvasView = self
        let real = touches.filter { !isPalm($0) }
        if !real.isEmpty { renderer?.stopInertia() }  // any touch-down catches a spinning view
        if let t = real.first { lastTouch = t.location(in: self) }
        if let p = touches.first(where: { $0.type == .pencil }) {
            PencilDrawing.pencilSeen = true
            pencilTouch = p
            fingerHeld = event?.allTouches?.contains {
                $0.type == .direct && !isPalm($0) && $0.phase != .ended && $0.phase != .cancelled
            } ?? false
            Haptics.prepare()
        }
        super.touchesBegan(touches, with: event)
    }

    private var currentTouch: ViewportTouch { lastTouchType == .indirectPointer ? .pointer : .finger }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        input?.viewportTap(g.location(in: self), extend: g.modifierFlags.contains(.shift), touch: currentTouch)
    }

    @objc private func onPencilTap(_ g: UITapGestureRecognizer) {
        let held = fingerHeld || longPress.state == .began || longPress.state == .changed
        if held { holdUsed = true }
        input?.viewportTap(g.location(in: self), extend: held || g.modifierFlags.contains(.shift), touch: .pencil)
    }

    // MARK: Drags

    @objc private func onPrimaryPan(_ g: SamplingPanGestureRecognizer) {
        let p = g.precisePoint ?? g.location(in: self)
        switch g.state {
        case .began:
            holdUsed = true
            pointerNav = currentTouch == .pointer ? navigation(buttons: g.buttonMask, flags: g.modifierFlags) : nil
            let loc = g.location(in: self), t = g.translation(in: self)
            beginDrag(from: CGPoint(x: loc.x - t.x, y: loc.y - t.y), to: p, touch: currentTouch)
        case .changed:
            moveDrag(to: p, predicted: g.predictedPoint, shift: g.modifierFlags.contains(.shift))
        case .ended:
            endDrag(at: p, velocity: g.velocity(in: self))
        default:
            endDrag(at: p, velocity: nil)
        }
    }

    @objc private func onPencilDrag(_ g: PencilDragGestureRecognizer) {
        let p = g.precisePoint ?? g.location(in: self)
        switch g.state {
        case .began:
            pointerNav = nil
            beginDrag(from: g.startPoint, to: p, touch: .pencil)
        case .changed:
            moveDrag(to: p, predicted: g.predictedPoint, shift: g.modifierFlags.contains(.shift))
        case .ended:
            endDrag(at: p, velocity: g.releaseVelocity)
        default:
            endDrag(at: p, velocity: nil)
        }
    }

    private func beginDrag(from start: CGPoint, to p: CGPoint, touch: ViewportTouch) {
        renderer?.stopInertia()
        dragTouch = touch
        dragNav = pointerNav ?? .orbit
        toolDrag = pointerNav == nil && (input?.viewportDragBegan(start, touch: touch) ?? false)
        if toolDrag { input?.viewportDragMoved(p) }
        lastPan = p
    }

    /// `p` is the newest coalesced sample (sub-point precise); `predicted` only moves the preview.
    private func moveDrag(to p: CGPoint, predicted: CGPoint?, shift: Bool) {
        if toolDrag {
            input?.viewportDragMoved(p)
            if let predicted { input?.viewportDragPredicted(predicted) }
        } else {
            dragNav = pointerNav ?? (shift ? .pan : .orbit)
            navigate(dragNav, dx: p.x - lastPan.x, dy: p.y - lastPan.y)
        }
        lastPan = p
    }

    private func endDrag(at p: CGPoint, velocity: CGPoint?) {
        if toolDrag {
            input?.viewportDragEnded(p)
        } else if let v = velocity, dragTouch != .pointer {
            // A flick keeps the view turning (or sliding) and slows down; the next touch stops it.
            // Mouse drags stop dead, as on the Mac.
            switch dragNav {
            case .orbit: renderer?.flingOrbit(velocity: v)
            case .pan: renderer?.flingPan(velocity: v, size: bounds.size)
            }
        }
        toolDrag = false
        pointerNav = nil
    }

    /// Right and middle mouse buttons on iPad, when the pointer reports them.
    private func navigation(buttons: UIEvent.ButtonMask, flags: UIKeyModifierFlags) -> MouseNav? {
        if buttons.contains(.secondary) { return MousePreset.current.right(shift: flags.contains(.shift)) }
        if buttons.contains(.button(3)) {
            return MousePreset.current.middle(shift: flags.contains(.shift), control: flags.contains(.control))
        }
        return nil
    }

    private func navigate(_ nav: MouseNav, dx: CGFloat, dy: CGFloat) {
        switch nav {
        case .orbit: renderer?.camera.orbit(dx: dx, dy: dy)
        case .pan: renderer?.camera.pan(dx: dx, dy: dy, size: bounds.size)
        }
    }

    @objc private func onTwoFingerPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            pinchZoomed = false
        case .changed:
            renderer?.camera.pan(dx: p.x - lastPan.x, dy: p.y - lastPan.y, size: bounds.size)
        case .ended:
            if !pinchZoomed { renderer?.flingPan(velocity: g.velocity(in: self), size: bounds.size) }
        default:
            break
        }
        lastPan = p
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
        if g.state == .began { renderer?.stopInertia() }
        let t = g.translation(in: self)
        g.setTranslation(.zero, in: self)
        if g.modifierFlags.contains(.shift) {
            renderer?.camera.pan(dx: t.x, dy: t.y, size: bounds.size)
        } else {
            renderer?.camera.orbit(dx: t.x, dy: t.y)
        }
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        if g.state == .began { lastPinch = 1 }
        if g.state == .changed {
            let f = lastPinch / max(g.scale, 0.01)
            renderer?.camera.zoom(factor: Double(f), at: g.location(in: self), size: bounds.size)
            lastPinch = g.scale
            if abs(g.scale - 1) > 0.08 { pinchZoomed = true }
        }
    }

    @objc private func onUndo() { input?.viewportUndo() }
    @objc private func onRedo() { input?.viewportRedo() }

    @objc private func onLongPress(_ g: UILongPressGestureRecognizer) {
        switch g.state {
        case .began:
            holdStart = g.location(in: self)
            holdUsed = false
            // With Pencil drawing the finger may be holding for a multi-select: wait for the release.
            if !PencilDrawing.isActive { holdUsed = true; _ = input?.viewportContextMenu(at: holdStart) }
        case .ended:
            let p = g.location(in: self)
            if !holdUsed && hypot(p.x - holdStart.x, p.y - holdStart.y) < 12 { _ = input?.viewportContextMenu(at: holdStart) }
            holdUsed = false
        default:
            break
        }
    }

    @objc private func onSecondaryClick(_ g: UITapGestureRecognizer) {
        _ = input?.viewportContextMenu(at: g.location(in: self))
    }

    // MARK: Hover

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed:
            let p = g.location(in: self)
            lastHover = p
            // The iPad senses the Pencil up to about 12 mm above the glass; snaps preview only when the tip is
            // close, so they don't flicker while the hand hovers far away. The pointer reports zOffset 0.
            if g.zOffset <= Self.hoverNear {
                if !hoverShown { Haptics.prepare() }
                hoverShown = true
                input?.viewportHover(p)
            } else if hoverShown {
                hoverShown = false
                input?.viewportHover(nil)
            }
        default:
            lastHover = nil
            hoverShown = false
            input?.viewportHover(nil)
        }
    }

    // MARK: Pencil double-tap and squeeze (respecting the user's choice in Settings > Apple Pencil)

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        PencilDrawing.pencilSeen = true
        switch UIPencilInteraction.preferredTapAction {
        case .ignore: return
        case .switchPrevious: input?.viewportPencil(.previousTool)
        case .showColorPalette, .showContextualPalette: togglePalette(at: tap.hoverPose?.location)
        default: input?.viewportPencil(.toggleSelect)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        PencilDrawing.pencilSeen = true
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut: return
        case .showContextualPalette: togglePalette(at: squeeze.hoverPose?.location)
        default:
            if PencilPaletteState.shared.isShown { PencilPaletteState.shared.dismiss(); return }
            input?.viewportPencil(.previousTool)
        }
    }

    /// Opens the tool palette at the Pencil tip (or where the Pencil last hovered or touched); closes it if open.
    private func togglePalette(at hover: CGPoint?) {
        let palette = PencilPaletteState.shared
        if palette.isShown { palette.dismiss(); return }
        let p = hover ?? lastHover ?? lastTouch ?? CGPoint(x: bounds.midX, y: bounds.midY)
        palette.show(at: convert(p, to: nil), for: input)
        Haptics.tick()
    }

    // MARK: Scribble

    func scribbleInteraction(_ interaction: UIScribbleInteraction, shouldBeginAt location: CGPoint) -> Bool {
        input?.viewportAcceptsHandwriting ?? false
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// Take the keyboard as soon as the view is on screen, so letter keys work without tapping it first.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            Haptics.canvasView = self
            DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() }
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            guard let key = p.key, let k = viewportKey(key) else { continue }
            if input?.viewportKey(k) == true { handled = true }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private func viewportKey(_ key: UIKey) -> ViewportKey? {
        switch key.keyCode {
        case .keyboardEscape: return .escape
        case .keyboardDeleteOrBackspace, .keyboardDeleteForward: return .delete
        case .keyboardReturnOrEnter, .keypadEnter: return .enter
        default: break
        }
        guard key.modifierFlags.isDisjoint(with: [.command, .control, .alternate]) else { return nil }
        switch key.keyCode {
        case .keyboardLeftArrow: return .arrow(dx: -1, dy: 0)
        case .keyboardRightArrow: return .arrow(dx: 1, dy: 0)
        case .keyboardUpArrow: return .arrow(dx: 0, dy: -1)
        case .keyboardDownArrow: return .arrow(dx: 0, dy: 1)
        case .keyboardSpacebar: return key.modifierFlags.contains(.shift) ? nil : .space
        default: break
        }
        guard !key.modifierFlags.contains(.shift), let c = key.charactersIgnoringModifiers.lowercased().first, c.isLetter else { return nil }
        return .character(c)
    }
}

struct ViewportRepresentable: UIViewRepresentable {
    let renderer: Renderer
    weak var input: ViewportInput?

    func makeUIView(context: Context) -> ViewportPlatformView {
        let v = ViewportPlatformView(frame: .zero, device: renderer.device)
        renderer.configure(v)
        v.renderer = renderer
        v.input = input
        return v
    }

    func updateUIView(_ v: ViewportPlatformView, context: Context) {
        v.input = input
        renderer.setNeedsDisplay()
    }
}

/// The newest precise location of a touch (its last coalesced sample) and where UIKit predicts it next.
@MainActor
private func touchSamples(_ t: UITouch, _ event: UIEvent, in view: UIView?) -> (latest: CGPoint, predicted: CGPoint?) {
    let latest = event.coalescedTouches(for: t)?.last ?? t
    let predicted = event.predictedTouches(for: t)?.last
    return (latest.preciseLocation(in: view), predicted?.preciseLocation(in: view))
}

/// A pan recognizer that also keeps the newest coalesced and predicted location of its touch.
final class SamplingPanGestureRecognizer: UIPanGestureRecognizer {
    private(set) var precisePoint: CGPoint?
    private(set) var predictedPoint: CGPoint?

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let t = touches.first {
            let s = touchSamples(t, event, in: view)
            precisePoint = s.latest
            predictedPoint = s.predicted
        }
        super.touchesMoved(touches, with: event)  // the action runs after this, with the fresh samples
    }

    override func reset() {
        super.reset()
        precisePoint = nil
        predictedPoint = nil
    }
}

/// Apple Pencil drags: begin after `threshold` points (the pan recognizer waits for about 10), keep the coalesced
/// and predicted samples, and measure the release speed for a fling.
final class PencilDragGestureRecognizer: UIGestureRecognizer {
    var threshold: CGFloat = 4
    private(set) var startPoint: CGPoint = .zero
    private(set) var precisePoint: CGPoint?
    private(set) var predictedPoint: CGPoint?
    /// Points per second when the Pencil lifted; zero if it rested before lifting.
    private(set) var releaseVelocity: CGPoint = .zero
    private weak var tracked: UITouch?
    private var samples: [(point: CGPoint, time: TimeInterval)] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard tracked == nil, let t = touches.first else { return }
        tracked = t
        startPoint = t.preciseLocation(in: view)
        precisePoint = startPoint
        predictedPoint = nil
        samples = [(startPoint, t.timestamp)]
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        for c in event.coalescedTouches(for: t) ?? [t] { samples.append((c.preciseLocation(in: view), c.timestamp)) }
        let now = t.timestamp
        samples.removeAll { now - $0.time > 0.1 }
        let s = touchSamples(t, event, in: view)
        precisePoint = s.latest
        predictedPoint = s.predicted
        switch state {
        case .possible:
            if hypot(s.latest.x - startPoint.x, s.latest.y - startPoint.y) >= threshold { state = .began }
        case .began, .changed:
            state = .changed
        default:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        precisePoint = t.preciseLocation(in: view)
        predictedPoint = nil
        releaseVelocity = velocity(at: t.timestamp)
        state = (state == .began || state == .changed) ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        guard let t = tracked, touches.contains(t) else { return }
        predictedPoint = nil
        state = (state == .began || state == .changed) ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
        precisePoint = nil
        predictedPoint = nil
        releaseVelocity = .zero
        samples = []
    }

    /// Average speed over the last 100 ms of samples.
    private func velocity(at time: TimeInterval) -> CGPoint {
        guard let last = samples.last, let first = samples.first, time - last.time < 0.05 else { return .zero }
        let dt = last.time - first.time
        guard dt > 0.008 else { return .zero }
        return CGPoint(x: (last.point.x - first.point.x) / dt, y: (last.point.y - first.point.y) / dt)
    }
}

#else
import AppKit

final class ViewportPlatformView: MTKView {
    weak var input: ViewportInput?
    var renderer: Renderer?
    private var downPoint: CGPoint?
    private var dragging = false
    private var toolDrag = false
    private var last: CGPoint = .zero
    private var tracking: NSTrackingArea?
    /// Right button: a click shows the context menu, a drag orbits.
    private var rightDown: CGPoint?
    private var rightDragging = false
    private var otherNav: MouseNav = .pan

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { Haptics.canvasView = self }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, !(w.firstResponder is NSTextView) else { return }
            w.makeFirstResponder(self)
        }
    }
    override var isFlipped: Bool { true }  // y grows downwards, like on iPad

    private func point(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        renderer?.stopInertia()
        downPoint = point(e); last = point(e); dragging = false; toolDrag = false
    }

    override func mouseDragged(with e: NSEvent) {
        let p = point(e)
        guard let down = downPoint else { return }
        if !dragging {
            if hypot(p.x - down.x, p.y - down.y) < 3 { return }
            dragging = true
            toolDrag = input?.viewportDragBegan(down, touch: .pointer) ?? false
        }
        if toolDrag { input?.viewportDragMoved(p) } else { navigate(e.modifierFlags.contains(.shift) ? .pan : .orbit, to: p) }
    }

    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if dragging { if toolDrag { input?.viewportDragEnded(p) } }
        else if e.modifierFlags.contains(.control) { showContextMenu(e) }  // Control-click = right-click
        else { input?.viewportTap(p, extend: e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command), touch: .pointer) }
        downPoint = nil; dragging = false; toolDrag = false
    }

    override func rightMouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        renderer?.stopInertia()
        rightDown = point(e); last = point(e); rightDragging = false
    }

    override func rightMouseDragged(with e: NSEvent) {
        let p = point(e)
        if !rightDragging {
            guard let down = rightDown, hypot(p.x - down.x, p.y - down.y) >= 3 else { return }
            rightDragging = true
        }
        navigate(MousePreset.current.right(shift: e.modifierFlags.contains(.shift)), to: p)
    }

    override func rightMouseUp(with e: NSEvent) {
        if rightDown != nil && !rightDragging { showContextMenu(e) }
        rightDown = nil; rightDragging = false
    }

    override func otherMouseDown(with e: NSEvent) {
        renderer?.stopInertia()
        last = point(e)
        let f = e.modifierFlags
        otherNav = e.buttonNumber == 2 ? MousePreset.current.middle(shift: f.contains(.shift), control: f.contains(.control)) : .pan
    }

    override func otherMouseDragged(with e: NSEvent) { navigate(otherNav, to: point(e)) }

    private func navigate(_ nav: MouseNav, to p: CGPoint) {
        switch nav {
        case .orbit: renderer?.camera.orbit(dx: p.x - last.x, dy: p.y - last.y)
        case .pan: renderer?.camera.pan(dx: p.x - last.x, dy: p.y - last.y, size: bounds.size)
        }
        last = p
    }

    /// Selects what's under the cursor and pops up its actions.
    private func showContextMenu(_ e: NSEvent) {
        guard let items = input?.viewportContextMenu(at: point(e)), !items.isEmpty else { return }
        let menu = NSMenu()
        for item in items {
            let action = MenuAction(item.run)
            let m = NSMenuItem(title: item.title, action: #selector(MenuAction.fire), keyEquivalent: "")
            m.target = action
            m.representedObject = action  // keeps the target alive while the menu is open
            m.image = NSImage(systemSymbolName: item.icon, accessibilityDescription: nil)
            menu.addItem(m)
        }
        NSMenu.popUpContextMenu(menu, with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas {
            // Trackpad: two fingers orbit, with shift they pan. Direct: macOS adds its own momentum events.
            if e.phase == .began { renderer?.stopInertia() }
            if e.modifierFlags.contains(.shift) {
                renderer?.camera.pan(dx: -e.scrollingDeltaX, dy: -e.scrollingDeltaY, size: bounds.size)
            } else if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                renderer?.camera.zoom(factor: exp(Double(e.scrollingDeltaY) * 0.01), at: point(e), size: bounds.size)
            } else {
                renderer?.camera.orbit(dx: -e.scrollingDeltaX, dy: -e.scrollingDeltaY)
            }
        } else {
            // Mouse wheel zooms towards the cursor; each notch eases in instead of jumping.
            renderer?.animateZoom(factor: exp(Double(-e.scrollingDeltaY) * 0.08), at: point(e), size: bounds.size)
        }
    }

    override func magnify(with e: NSEvent) {
        renderer?.camera.zoom(factor: 1 / (1 + Double(e.magnification)), at: point(e), size: bounds.size)
    }

    override func mouseMoved(with e: NSEvent) { input?.viewportHover(point(e)) }
    override func mouseExited(with e: NSEvent) { input?.viewportHover(nil) }

    override func keyDown(with e: NSEvent) {
        if let k = viewportKey(e), input?.viewportKey(k) == true { return }
        super.keyDown(with: e)
    }

    private func viewportKey(_ e: NSEvent) -> ViewportKey? {
        switch e.keyCode {
        case 53: return .escape
        case 51, 117: return .delete
        case 36, 76: return .enter
        default: break
        }
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        switch e.keyCode {
        case 123: return .arrow(dx: -1, dy: 0)
        case 124: return .arrow(dx: 1, dy: 0)
        case 125: return .arrow(dx: 0, dy: 1)
        case 126: return .arrow(dx: 0, dy: -1)
        default: break
        }
        guard !flags.contains(.shift), !e.isARepeat else { return nil }
        if e.keyCode == 49 { return .space }
        guard let c = e.charactersIgnoringModifiers?.lowercased().first, c.isLetter else { return nil }
        return .character(c)
    }
}

/// Target for a context-menu item's closure.
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

struct ViewportRepresentable: NSViewRepresentable {
    let renderer: Renderer
    weak var input: ViewportInput?

    func makeNSView(context: Context) -> ViewportPlatformView {
        let v = ViewportPlatformView(frame: .zero, device: renderer.device)
        renderer.configure(v)
        v.renderer = renderer
        v.input = input
        return v
    }

    func updateNSView(_ v: ViewportPlatformView, context: Context) {
        v.input = input
        renderer.setNeedsDisplay()
    }
}
#endif
