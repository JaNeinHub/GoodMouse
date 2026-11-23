import AppKit
import SwiftUI

/// Windows-style middle-click autoscroll. Runs on the event thread; only the indicator
/// window is touched on the main thread.
/// Click (toggle): scrolls by distance from the anchor until any click, Esc or wheel.
/// Hold and drag: stops when the middle button is released.
/// The scroll always goes to the view under the anchor, even when the pointer moves over a
/// toolbar, another frame or another app's window.
final class AutoScroller {
    private(set) var active = false
    var onActiveChanged: () -> Void = {}
    private var anchor = CGPoint.zero
    private var anchorWindow: ScreenWindow?
    private var pointerOutside = false   // pointer over another window than the anchor's
    private var lastWindowCheck = 0.0
    private var held = false
    private var movedWhileHeld = false
    private var carry = (x: 0.0, y: 0.0)
    private var lastFrame = 0.0
    private var speed = 1.3
    private var timer: Timer?
    private let deadZone = 12.0

    /// Returns true when the middle click was consumed.
    func middleDown(at p: CGPoint, _ c: Config) -> Bool {
        if active { stop(); return true }
        if let rule = WindowLookup.ruleUnderCursor(c), rule.scroll != .smooth { return false }
        // Links: the hand cursor works in every browser. Tabs and buttons only where the app shows them
        // to Accessibility (Safari does, Chromium browsers don't).
        if c.autoscrollKeepsLinks && (CursorCheck.isPointingHand() || AXHelper.isClickable(at: p)) { return false }
        start(at: p, speed: c.autoscrollSpeed)
        return true
    }

    func middleUp() {
        held = false
        if active && movedWhileHeld { stop() }
    }

    func stop() {
        guard active else { return }
        active = false
        timer?.invalidate(); timer = nil
        DispatchQueue.main.async { AutoScrollIndicator.shared.hide() }
        onActiveChanged()
    }

    private func start(at p: CGPoint, speed: Double) {
        active = true
        anchor = p
        anchorWindow = WindowLookup.window(at: p)
        pointerOutside = false
        lastWindowCheck = 0
        held = true
        movedWhileHeld = false
        carry = (0, 0)
        self.speed = speed
        lastFrame = nowMs()
        timer = makeFrameTimer { [weak self] in self?.frame() }
        DispatchQueue.main.async { AutoScrollIndicator.shared.show(at: p) }
        onActiveChanged()
    }

    private func velocity(_ d: Double) -> Double {
        let m = max(0, abs(d) - deadZone)
        return (d < 0 ? -1 : 1) * (6 * m + 0.02 * m * m) * speed   // px/s
    }

    private func frame() {
        let t = nowMs()
        let dt = min(t - lastFrame, 50) / 1000
        lastFrame = t
        let loc = cursorLocation()
        let dx = loc.x - anchor.x, dy = loc.y - anchor.y
        if let anchorWindow, t - lastWindowCheck > 100 {   // window list query ~10× per second, not every frame
            lastWindowCheck = t
            pointerOutside = WindowLookup.window(at: loc) != anchorWindow
        }
        if held && hypot(dx, dy) > deadZone * 2 { movedWhileHeld = true }
        // Cursor below the anchor scrolls the page down (negative wheel delta), right scrolls right.
        carry.y -= velocity(dy) * dt
        carry.x -= velocity(dx) * dt
        let iy = carry.y.rounded(.towardZero), ix = carry.x.rounded(.towardZero)
        carry.y -= iy; carry.x -= ix
        if iy != 0 || ix != 0 {
            postScroll(units: .pixel, vertical: Int32(iy), horizontal: Int32(ix), at: anchor,
                       target: pointerOutside ? anchorWindow : nil)
        }
    }
}

/// Small round marker at the autoscroll anchor, like the Windows one. Main thread only.
final class AutoScrollIndicator {
    static let shared = AutoScrollIndicator()
    private var panel: NSPanel?
    private let size: CGFloat = 30

    func show(at p: CGPoint) {
        let screenHeight = NSScreen.screens.first?.frame.height ?? 0   // CG → Cocoa coordinates
        let frame = NSRect(x: p.x - size / 2, y: screenHeight - p.y - size / 2, width: size, height: size)
        if panel == nil {
            let pn = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: false)
            pn.isOpaque = false
            pn.backgroundColor = .clear
            pn.hasShadow = true
            pn.level = .statusBar
            pn.ignoresMouseEvents = true
            pn.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            pn.contentView = NSHostingView(rootView: IndicatorView())
            panel = pn
        }
        panel?.setFrame(frame, display: true)
        panel?.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }
}

private struct IndicatorView: View {
    var body: some View {
        ZStack {
            Circle().fill(.regularMaterial)
            Circle().stroke(.secondary, lineWidth: 1)
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .font(.system(size: 13, weight: .semibold))
        }
        .frame(width: 30, height: 30)
    }
}
