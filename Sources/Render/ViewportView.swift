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
}

/// What touched the view. Pencil and pointer always draw in sketches; a finger may navigate instead.
enum ViewportTouch { case finger, pencil, pointer }

/// Pencil double-tap / squeeze, already mapped through the user's system preference.
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

final class ViewportPlatformView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    weak var input: ViewportInput?
    var renderer: Renderer?
    private var toolDrag = false
    /// A right/middle-button pointer drag navigates the way the mouse preset says.
    private var pointerNav: MouseNav?
    private var lastPan: CGPoint = .zero
    private var lastPinch: CGFloat = 1
    /// Touch type of the last touch the finger/pointer recognizers received.
    private var lastTouchType: UITouch.TouchType = .direct
    /// A finger rested on the screen when the Pencil touched down: Pencil taps then extend the selection.
    private var fingerHeld = false
    private var holdUsed = false
    private var holdStart: CGPoint = .zero
    private var tap: UITapGestureRecognizer!
    private var oneFinger: UIPanGestureRecognizer!
    private var twoFinger: UIPanGestureRecognizer!
    private var pencilTap: UITapGestureRecognizer!
    private var longPress: UILongPressGestureRecognizer!

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
        pencilTap = UITapGestureRecognizer(target: self, action: #selector(onPencilTap(_:)))
        pencilTap.allowedTouchTypes = [pencil]
        pencilTap.delegate = self
        addGestureRecognizer(pencilTap)

        oneFinger = UIPanGestureRecognizer(target: self, action: #selector(onPrimaryPan(_:)))
        oneFinger.minimumNumberOfTouches = 1
        oneFinger.maximumNumberOfTouches = 1
        oneFinger.allowedTouchTypes = [direct, pointer]
        oneFinger.allowedScrollTypesMask = []
        oneFinger.delegate = self
        addGestureRecognizer(oneFinger)

        let pencilPan = UIPanGestureRecognizer(target: self, action: #selector(onPencilPan(_:)))
        pencilPan.maximumNumberOfTouches = 1
        pencilPan.allowedTouchTypes = [pencil]
        addGestureRecognizer(pencilPan)

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
        addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(target: self, action: #selector(onRedo))
        redo.numberOfTouchesRequired = 3
        redo.allowedTouchTypes = [direct]
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
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if g === tap || g === oneFinger { lastTouchType = touch.type }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two-finger pan and pinch work together; a held finger doesn't block the Pencil or an orbit.
        if (g is UIPinchGestureRecognizer && other === twoFinger) || (g === twoFinger && other is UIPinchGestureRecognizer) { return true }
        if g === longPress || other === longPress { return other === pencilTap || g === pencilTap || other === oneFinger || g === oneFinger }
        return false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if !isFirstResponder { becomeFirstResponder() }
        if touches.contains(where: { $0.type == .pencil }) {
            PencilDrawing.pencilSeen = true
            fingerHeld = event?.allTouches?.contains { $0.type == .direct && $0.phase != .ended && $0.phase != .cancelled } ?? false
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

    @objc private func onPrimaryPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began {
            holdUsed = true
            pointerNav = currentTouch == .pointer ? navigation(buttons: g.buttonMask, flags: g.modifierFlags) : nil
        }
        drag(g, touch: currentTouch)
    }

    @objc private func onPencilPan(_ g: UIPanGestureRecognizer) {
        if g.state == .began { pointerNav = nil }
        drag(g, touch: .pencil)
    }

    private func drag(_ g: UIPanGestureRecognizer, touch: ViewportTouch) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let start = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
            toolDrag = pointerNav == nil && (input?.viewportDragBegan(start, touch: touch) ?? false)
            if toolDrag { input?.viewportDragMoved(p) }
            lastPan = p
        case .changed:
            if toolDrag { input?.viewportDragMoved(p) } else {
                let nav = pointerNav ?? (g.modifierFlags.contains(.shift) ? .pan : .orbit)
                navigate(nav, dx: p.x - lastPan.x, dy: p.y - lastPan.y)
            }
            lastPan = p
        default:
            if toolDrag { input?.viewportDragEnded(p) }
            toolDrag = false
            pointerNav = nil
        }
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
        if g.state == .began { lastPan = p }
        if g.state == .changed {
            renderer?.camera.pan(dx: p.x - lastPan.x, dy: p.y - lastPan.y, size: bounds.size)
        }
        lastPan = p
    }

    @objc private func onScroll(_ g: UIPanGestureRecognizer) {
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

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: input?.viewportHover(g.location(in: self))
        default: input?.viewportHover(nil)
        }
    }

    // MARK: Pencil double-tap and squeeze (respecting the user's choice in Settings > Apple Pencil)

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        PencilDrawing.pencilSeen = true
        switch UIPencilInteraction.preferredTapAction {
        case .ignore: return
        case .switchPrevious: input?.viewportPencil(.previousTool)
        default: input?.viewportPencil(.toggleSelect)
        }
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        PencilDrawing.pencilSeen = true
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore, .runSystemShortcut: return
        default: input?.viewportPencil(.previousTool)
        }
    }

    // MARK: Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// Take the keyboard as soon as the view is on screen, so letter keys work without tapping it first.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.becomeFirstResponder() } }
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
            // Trackpad: two fingers orbit, with shift they pan.
            if e.modifierFlags.contains(.shift) {
                renderer?.camera.pan(dx: -e.scrollingDeltaX, dy: -e.scrollingDeltaY, size: bounds.size)
            } else if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.option) {
                renderer?.camera.zoom(factor: exp(Double(e.scrollingDeltaY) * 0.01), at: point(e), size: bounds.size)
            } else {
                renderer?.camera.orbit(dx: -e.scrollingDeltaX, dy: -e.scrollingDeltaY)
            }
        } else {
            // Mouse wheel zooms towards the cursor.
            renderer?.camera.zoom(factor: exp(Double(-e.scrollingDeltaY) * 0.08), at: point(e), size: bounds.size)
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
