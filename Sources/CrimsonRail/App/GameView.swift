import Foundation
import AppKit
import SceneKit
import simd

/// Where every input the game reads is collected. Kept as plain values that the
/// render callback samples, rather than callbacks that mutate the scene from the
/// main thread while SceneKit is walking it.
struct InputState {
    /// Aim point in view coordinates. With mouse-look this is the view centre,
    /// but menus and the harnesses still read it.
    var aim: CGPoint = .zero
    /// Accumulated mouse movement since the last frame, in points.
    var lookDeltaX: Float = 0
    var lookDeltaY: Float = 0

    /// Movement axes, -1...1.
    var moveForward: Float = 0
    var moveStrafe: Float = 0
    var sprinting = false

    var triggerDown = false
    /// Rising edges, consumed by the game loop.
    var triggerPressed = false
    var reloadPressed = false
    var pausePressed = false
    var confirmPressed = false
    var mouseInside = true
}

protocol GameViewDelegate: AnyObject {
    func gameView(_ view: GameView, didUpdateInput input: InputState)
    func gameViewDidResize(_ view: GameView)
    func gameViewKeyDown(_ view: GameView, key: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool
}

final class GameView: SCNView {
    weak var inputDelegate: GameViewDelegate?
    private(set) var input = InputState()
    private var trackingArea: NSTrackingArea?

    /// Physical key codes, so the controls sit under the same fingers on a
    /// non-QWERTY layout as they do on QWERTY.
    private enum Key {
        static let w: UInt16 = 13, a: UInt16 = 0, s: UInt16 = 1, d: UInt16 = 2
        static let up: UInt16 = 126, down: UInt16 = 125, left: UInt16 = 123, right: UInt16 = 124
        static let r: UInt16 = 15, p: UInt16 = 35, escape: UInt16 = 53
        static let space: UInt16 = 49, f: UInt16 = 3
    }
    private var heldKeys: Set<UInt16> = []

    /// Set while gameplay is running: hides the cursor and switches the mouse
    /// from a screen pointer to a relative look device.
    var capturesAim = false {
        didSet {
            guard capturesAim != oldValue else { return }
            if capturesAim { beginMouseLook() } else { endMouseLook() }
        }
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        rebuildTrackingArea()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        rebuildTrackingArea()
    }

    private func rebuildTrackingArea() {
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        inputDelegate?.gameViewDidResize(self)
    }

    // MARK: Mouse capture

    /// Decouples the hardware mouse from the on-screen cursor so the pointer can
    /// never reach a screen edge and stop generating deltas — the thing that
    /// makes a naive mouse-look implementation refuse to keep turning.
    private func beginMouseLook() {
        NSCursor.hide()
        CGAssociateMouseAndMouseCursorPosition(0)
        // Park the system cursor in the middle of the window so that if capture
        // is lost the pointer is somewhere sensible.
        if let window, let screen = window.screen {
            let mid = NSPoint(x: window.frame.midX, y: window.frame.midY)
            let flipped = CGPoint(x: mid.x, y: screen.frame.maxY - mid.y)
            CGWarpMouseCursorPosition(flipped)
        }
        input.lookDeltaX = 0
        input.lookDeltaY = 0
    }

    private func endMouseLook() {
        CGAssociateMouseAndMouseCursorPosition(1)
        NSCursor.unhide()
        heldKeys.removeAll()
        input.moveForward = 0
        input.moveStrafe = 0
        input.sprinting = false
    }

    private func accumulateLook(_ event: NSEvent) {
        guard capturesAim else {
            // In menus the pointer is a pointer again.
            input.aim = convert(event.locationInWindow, from: nil)
            return
        }
        input.lookDeltaX += Float(event.deltaX)
        input.lookDeltaY += Float(event.deltaY)
    }

    override func mouseMoved(with event: NSEvent) { accumulateLook(event) }
    /// `mouseMoved` stops arriving while a button is held — without this the aim
    /// freezes for the whole of a held-trigger burst.
    override func mouseDragged(with event: NSEvent) { accumulateLook(event) }
    override func rightMouseDragged(with event: NSEvent) { accumulateLook(event) }
    override func otherMouseDragged(with event: NSEvent) { accumulateLook(event) }
    override func mouseEntered(with event: NSEvent) { input.mouseInside = true }
    override func mouseExited(with event: NSEvent) { input.mouseInside = false }

    override func mouseDown(with event: NSEvent) {
        if !capturesAim { input.aim = convert(event.locationInWindow, from: nil) }
        input.triggerDown = true
        input.triggerPressed = true
        inputDelegate?.gameView(self, didUpdateInput: input)
    }

    override func mouseUp(with event: NSEvent) {
        input.triggerDown = false
        inputDelegate?.gameView(self, didUpdateInput: input)
    }

    override func rightMouseDown(with event: NSEvent) {
        input.reloadPressed = true
        inputDelegate?.gameView(self, didUpdateInput: input)
    }

    override func rightMouseUp(with event: NSEvent) {}

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        // Ignore auto-repeat: movement is held-state, not an event stream.
        if !event.isARepeat { heldKeys.insert(event.keyCode) }
        updateMoveAxes(modifiers: event.modifierFlags)

        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if inputDelegate?.gameViewKeyDown(self, key: chars, keyCode: event.keyCode,
                                          modifiers: event.modifierFlags) == true {
            return
        }
        switch event.keyCode {
        case Key.r: input.reloadPressed = true
        case Key.p, Key.escape: input.pausePressed = true
        case Key.space: input.confirmPressed = true
        default:
            // Swallow movement keys so AppKit does not beep at them.
            if ![Key.w, Key.a, Key.s, Key.d, Key.up, Key.down, Key.left, Key.right].contains(event.keyCode) {
                super.keyDown(with: event)
                return
            }
        }
        inputDelegate?.gameView(self, didUpdateInput: input)
    }

    override func keyUp(with event: NSEvent) {
        heldKeys.remove(event.keyCode)
        updateMoveAxes(modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        updateMoveAxes(modifiers: event.modifierFlags)
    }

    private func updateMoveAxes(modifiers: NSEvent.ModifierFlags) {
        var fwd: Float = 0, strafe: Float = 0
        if heldKeys.contains(Key.w) || heldKeys.contains(Key.up) { fwd += 1 }
        if heldKeys.contains(Key.s) || heldKeys.contains(Key.down) { fwd -= 1 }
        if heldKeys.contains(Key.d) || heldKeys.contains(Key.right) { strafe += 1 }
        if heldKeys.contains(Key.a) || heldKeys.contains(Key.left) { strafe -= 1 }
        input.moveForward = fwd
        input.moveStrafe = strafe
        input.sprinting = modifiers.contains(.shift)
    }

    /// Escape reaches views through `cancelOperation` in several AppKit
    /// configurations where `keyDown` never sees it. Handling both costs nothing.
    override func cancelOperation(_ sender: Any?) {
        input.pausePressed = true
        inputDelegate?.gameView(self, didUpdateInput: input)
    }

    /// Suppresses the system beep for keys the game consumes.
    override func performKeyEquivalent(with event: NSEvent) -> Bool { false }

    /// Losing key-window status while captured would strand the mouse detached
    /// from the cursor, so hand control back.
    func releaseCaptureIfNeeded() {
        if capturesAim { capturesAim = false }
    }

    // MARK: Latch consumption

    /// Reads and clears the one-shot values. Called once per frame by the game.
    func consumeEdges() -> InputState {
        var snapshot = input
        // With mouse-look the crosshair is fixed at the centre of the view.
        if capturesAim {
            snapshot.aim = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        input.triggerPressed = false
        input.reloadPressed = false
        input.pausePressed = false
        input.confirmPressed = false
        input.lookDeltaX = 0
        input.lookDeltaY = 0
        return snapshot
    }
}
