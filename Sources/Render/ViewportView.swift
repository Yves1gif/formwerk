import MetalKit
import SwiftUI

/// What the 3D view reports to the editor. Camera moves are handled by the view itself.
@MainActor
protocol ViewportInput: AnyObject {
    func viewportTap(_ p: CGPoint, extend: Bool)
    /// Return true when the editor takes the drag (moving a sketch point, a handle…); false = navigate.
    func viewportDragBegan(_ p: CGPoint, pencil: Bool) -> Bool
    func viewportDragMoved(_ p: CGPoint)
    func viewportDragEnded(_ p: CGPoint)
    func viewportHover(_ p: CGPoint?)
    func viewportUndo()
    func viewportRedo()
    func viewportPencilDoubleTap()
    func viewportKey(_ key: ViewportKey) -> Bool
}

enum ViewportKey { case escape, delete, enter }

#if os(iOS)
import UIKit

final class ViewportPlatformView: MTKView, UIGestureRecognizerDelegate, UIPencilInteractionDelegate {
    weak var input: ViewportInput?
    var renderer: Renderer?
    private var toolDrag = false
    private var lastPan: CGPoint = .zero
    private var lastPinch: CGFloat = 1

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        setup()
    }

    required init(coder: NSCoder) { super.init(coder: coder); setup() }

    private func setup() {
        isMultipleTouchEnabled = true

        let tap = UITapGestureRecognizer(target: self, action: #selector(onTap(_:)))
        tap.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber,
                                 UITouch.TouchType.pencil.rawValue as NSNumber,
                                 UITouch.TouchType.indirectPointer.rawValue as NSNumber]
        addGestureRecognizer(tap)

        let oneFinger = UIPanGestureRecognizer(target: self, action: #selector(onPrimaryPan(_:)))
        oneFinger.minimumNumberOfTouches = 1
        oneFinger.maximumNumberOfTouches = 1
        oneFinger.allowedScrollTypesMask = []
        oneFinger.delegate = self
        addGestureRecognizer(oneFinger)

        let twoFinger = UIPanGestureRecognizer(target: self, action: #selector(onTwoFingerPan(_:)))
        twoFinger.minimumNumberOfTouches = 2
        twoFinger.maximumNumberOfTouches = 2
        twoFinger.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        twoFinger.delegate = self
        addGestureRecognizer(twoFinger)

        // Trackpad / mouse wheel on iPad: scroll orbits, like on the Mac.
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(onScroll(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.maximumNumberOfTouches = 0
        addGestureRecognizer(scroll)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        let undo = UITapGestureRecognizer(target: self, action: #selector(onUndo))
        undo.numberOfTouchesRequired = 2
        undo.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(target: self, action: #selector(onRedo))
        redo.numberOfTouchesRequired = 3
        redo.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        addGestureRecognizer(redo)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(onHover(_:)))
        addGestureRecognizer(hover)

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        addInteraction(pencil)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Two-finger pan and pinch work together.
        (g is UIPinchGestureRecognizer && other is UIPanGestureRecognizer) ||
            (g is UIPanGestureRecognizer && other is UIPinchGestureRecognizer)
    }

    @objc private func onTap(_ g: UITapGestureRecognizer) {
        input?.viewportTap(g.location(in: self), extend: g.modifierFlags.contains(.shift))
    }

    @objc private func onPrimaryPan(_ g: UIPanGestureRecognizer) {
        let p = g.location(in: self)
        switch g.state {
        case .began:
            let start = CGPoint(x: p.x - g.translation(in: self).x, y: p.y - g.translation(in: self).y)
            let pencil = g.numberOfTouches > 0 && isPencil(g)
            toolDrag = input?.viewportDragBegan(start, pencil: pencil) ?? false
            if toolDrag { input?.viewportDragMoved(p) }
            lastPan = p
        case .changed:
            if toolDrag { input?.viewportDragMoved(p) } else {
                let d = CGPoint(x: p.x - lastPan.x, y: p.y - lastPan.y)
                if g.modifierFlags.contains(.shift) {
                    renderer?.camera.pan(dx: d.x, dy: d.y, size: bounds.size)
                } else {
                    renderer?.camera.orbit(dx: d.x, dy: d.y)
                }
            }
            lastPan = p
        default:
            if toolDrag { input?.viewportDragEnded(p) }
            toolDrag = false
        }
    }

    private func isPencil(_ g: UIGestureRecognizer) -> Bool {
        // The touch type isn't exposed on the recognizer; the allowed set tells us when only one is possible.
        lastTouchWasPencil
    }

    private var lastTouchWasPencil = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        lastTouchWasPencil = touches.first?.type == .pencil
        super.touchesBegan(touches, with: event)
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

    @objc private func onHover(_ g: UIHoverGestureRecognizer) {
        switch g.state {
        case .began, .changed: input?.viewportHover(g.location(in: self))
        default: input?.viewportHover(nil)
        }
    }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) { input?.viewportPencilDoubleTap() }

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var handled = false
        for p in presses {
            switch p.key?.keyCode {
            case .keyboardEscape: handled = input?.viewportKey(.escape) ?? false
            case .keyboardDeleteOrBackspace, .keyboardDeleteForward: handled = input?.viewportKey(.delete) ?? false
            case .keyboardReturnOrEnter: handled = input?.viewportKey(.enter) ?? false
            default: break
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
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

    override var acceptsFirstResponder: Bool { true }
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
            toolDrag = input?.viewportDragBegan(down, pencil: false) ?? false
        }
        if toolDrag { input?.viewportDragMoved(p) } else if e.modifierFlags.contains(.shift) {
            renderer?.camera.pan(dx: p.x - last.x, dy: p.y - last.y, size: bounds.size)
        } else {
            renderer?.camera.orbit(dx: p.x - last.x, dy: p.y - last.y)
        }
        last = p
    }

    override func mouseUp(with e: NSEvent) {
        let p = point(e)
        if dragging { if toolDrag { input?.viewportDragEnded(p) } }
        else { input?.viewportTap(p, extend: e.modifierFlags.contains(.shift) || e.modifierFlags.contains(.command)) }
        downPoint = nil; dragging = false; toolDrag = false
    }

    override func rightMouseDown(with e: NSEvent) { last = point(e) }
    override func rightMouseDragged(with e: NSEvent) {
        let p = point(e)
        if e.modifierFlags.contains(.shift) {
            renderer?.camera.pan(dx: p.x - last.x, dy: p.y - last.y, size: bounds.size)
        } else {
            renderer?.camera.orbit(dx: p.x - last.x, dy: p.y - last.y)
        }
        last = p
    }

    override func otherMouseDown(with e: NSEvent) { last = point(e) }
    override func otherMouseDragged(with e: NSEvent) {
        let p = point(e)
        renderer?.camera.pan(dx: p.x - last.x, dy: p.y - last.y, size: bounds.size)
        last = p
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
        let handled: Bool
        switch e.keyCode {
        case 53: handled = input?.viewportKey(.escape) ?? false
        case 51, 117: handled = input?.viewportKey(.delete) ?? false
        case 36, 76: handled = input?.viewportKey(.enter) ?? false
        default: handled = false
        }
        if !handled { super.keyDown(with: e) }
    }
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
