import AppKit
import CoreGraphics

/// Windows-10-style wheel scrolling: every notch adds a fixed distance that glides out
/// with an exponential ease-out. Notches arriving mid-glide add up; reversing direction
/// cancels the rest of the glide. Runs on the event thread.
final class SmoothScroller {
    private var remaining = 0.0          // px still to scroll, sign = direction
    private var carry = 0.0              // sub-pixel remainder
    private var lastDir = 0              // wheel direction before reversal, for the bounce filter
    private var lastNotch = -1e9
    private var lastFrame = 0.0
    private var tauMs = 40.0
    private var timer: Timer?

    /// Returns true when the event was consumed (replaced by our own output).
    func handle(_ e: CGEvent, _ c: Config) -> Bool {
        // Trackpads, Magic Mouse and vendor smooth scrolling (e.g. Logi Options+) send
        // continuous events: leave them alone.
        guard e.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return false }
        let rule = WindowLookup.ruleUnderCursor(c)
        // macOS turns Shift + wheel into sideways scrolling; games use Shift for something else.
        if rule?.shiftSideways == false { e.flags.remove(.maskShift) }
        if rule?.scroll == .off { return false }
        let dy = e.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        if dy == 0 {
            // Horizontal wheels pass unchanged. High-resolution wheels can send sub-notch
            // vertical events without a line delta; keep their direction consistent.
            let fixed = e.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
            if c.reverse && fixed != 0 {
                e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -fixed)
                e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1,
                                       value: -e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            }
            return false
        }

        let t = nowMs()
        let wheelDir = dy > 0 ? 1 : -1
        // Encoder bounce: one opposite tick right after a normal one. Real reversals take >100 ms.
        if lastDir != 0 && wheelDir != lastDir && t - lastNotch < c.bounceMs {
            DispatchQueue.main.async { AppState.shared.bouncesFiltered += 1 }
            return true
        }
        let reversed = wheelDir != lastDir
        lastDir = wheelDir
        lastNotch = t
        let dir = c.reverse ? -wheelDir : wheelDir

        let modifiers = e.flags.intersection(zoomTriggerMask)
        if !c.zoomTrigger.isEmpty && modifiers == c.zoomTrigger && rule?.zoom ?? true {
            // Windows style: wheel away from you zooms in, independent of the scroll direction settings.
            stop()
            let inverted = NSEvent(cgEvent: e)?.isDirectionInvertedFromDevice ?? false
            Zoomer.notch(zoomIn: (inverted ? -wheelDir : wheelDir) > 0, c)
            return true
        }
        let classic = rule?.scroll == .classic
        if !c.smooth || classic || !modifiers.isEmpty {
            // Classic line scrolling (shift-scroll, other modifiers, classic apps, smoothing off).
            stop()
            postScroll(units: .line, vertical: Int32(dir * (classic ? c.classicLines : 1)), flags: e.flags)
            return true
        }

        if reversed { remaining = 0; carry = 0 }
        remaining += Double(dir) * c.pxPerNotch
        tauMs = c.tauMs
        if timer == nil {
            lastFrame = t - 1000.0 / 120
            frame()                                   // first pixels immediately, not one frame later
            if remaining != 0 { timer = makeFrameTimer { [weak self] in self?.frame() } }
        }
        return true
    }

    func stop() {
        remaining = 0; carry = 0
        timer?.invalidate(); timer = nil
    }

    private func frame() {
        let t = nowMs()
        let dt = min(t - lastFrame, 50)
        lastFrame = t
        var step = remaining * (1 - exp(-dt / tauMs))
        if abs(remaining) < 1 { step = remaining }
        remaining -= step
        let f = step + carry
        let i = f.rounded(.towardZero)
        carry = f - i
        if i != 0 { postScroll(units: .pixel, vertical: Int32(i)) }
        if remaining == 0 { stop() }
    }
}
