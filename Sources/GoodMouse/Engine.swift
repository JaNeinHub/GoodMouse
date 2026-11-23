import AppKit
import CoreGraphics

/// Owns the event taps on a dedicated high-priority thread, so a busy main thread (menu UI)
/// can never delay input or get the tap disabled by macOS.
///
/// - Main tap (always on while enabled): wheel and middle/side buttons only. Pointer
///   motion, keyboard and left/right clicks never pass through GoodMouse.
/// - Click tap: left/right clicks and Esc, switched on only while autoscroll runs (to stop it),
///   while the Dock modifier combination is held, or while a swallowed click's mouse-up is pending.
/// - Flags tap (listen-only, can't hold back input): modifier key changes, only while the Dock
///   modifier-click is turned on.
final class Engine {
    static let shared = Engine()
    private var mainTap: CFMachPort?
    private var clickTap: CFMachPort?
    private var flagsTap: CFMachPort?
    private var dockModifierHeld = false
    private var runLoop: CFRunLoop?
    private let scroller = SmoothScroller()
    private let autoScroller = AutoScroller()
    private var swallowUp: Set<Int64> = []   // buttons whose matching mouse-up must be dropped
    private var timeouts: [Double] = []        // recent tap timeouts (event thread)

    /// Apps that navigate on a trackpad swipe but ignore mouse buttons 4/5 (list from LinearMouse).
    /// Chrome, VS Code etc. handle the buttons themselves and get them unchanged.
    private let swipeNavigationApps = ["com.apple.", "com.binarynights.ForkLift", "org.mozilla.firefox", "com.operasoftware.Opera"]

    private init() {
        autoScroller.onActiveChanged = { [unowned self] in self.updateClickTap() }
    }

    /// Starts the event thread and installs the taps. Main thread only.
    @discardableResult
    func start() -> Bool {
        if runLoop != nil { return true }
        let ready = DispatchSemaphore(value: 0)
        var installed: CFRunLoop?
        let thread = Thread { [self] in
            if installTaps() { installed = CFRunLoopGetCurrent() }
            ready.signal()
            if installed != nil { CFRunLoopRun() }
        }
        thread.name = "GoodMouse.events"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        runLoop = installed
        return installed != nil
    }

    /// Takes GoodMouse out of the input chain at once. Main thread only.
    /// Disabling a tap is a direct WindowServer call, so this works even if the event thread hangs.
    func stop() {
        guard let rl = runLoop else { return }
        runLoop = nil
        for tap in [mainTap, clickTap, flagsTap].compactMap({ $0 }) { CGEvent.tapEnable(tap: tap, enable: false) }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue) { [self] in
            scroller.stop()
            autoScroller.stop()
            swallowUp.removeAll()
            for tap in [mainTap, clickTap, flagsTap].compactMap({ $0 }) { CFMachPortInvalidate(tap) }
            mainTap = nil
            clickTap = nil
            flagsTap = nil
            dockModifierHeld = false
            CFRunLoopStop(CFRunLoopGetCurrent())
        }
        CFRunLoopWakeUp(rl)
    }

    var isRunning: Bool { runLoop != nil }

    /// Called from the main thread when settings change or the Mac wakes up.
    func configChanged() { perform { self.refreshTaps() } }

    private func perform(_ block: @escaping () -> Void) {
        guard let rl = runLoop else { return }
        CFRunLoopPerformBlock(rl, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(rl)
    }

    private func installTaps() -> Bool {
        func mask(_ types: [CGEventType]) -> CGEventMask {
            types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        }
        let callback: CGEventTapCallBack = { _, type, event, _ in Engine.shared.handle(type, event) }
        guard let main = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask([.scrollWheel, .otherMouseDown, .otherMouseUp]),
                                           callback: callback, userInfo: nil),
              let click = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                            eventsOfInterest: mask([.leftMouseDown, .leftMouseUp, .rightMouseDown,
                                                                    .rightMouseUp, .keyDown]),
                                            callback: callback, userInfo: nil),
              let flags = CGEvent.tapCreate(tap: .cghidEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                            eventsOfInterest: mask([.flagsChanged]),
                                            callback: callback, userInfo: nil) else { return false }
        mainTap = main
        clickTap = click
        flagsTap = flags
        for tap in [main, click, flags] {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        }
        refreshTaps()
        return true
    }

    private func refreshTaps() {
        let c = sharedConfig.withLock { $0 }
        if !c.enabled {
            scroller.stop()
            autoScroller.stop()
            swallowUp.removeAll()
        }
        if let mainTap { CGEvent.tapEnable(tap: mainTap, enable: c.enabled) }
        let watchFlags = c.enabled && !c.dockModifier.isEmpty
        if !watchFlags { dockModifierHeld = false }
        if let flagsTap, CGEvent.tapIsEnabled(tap: flagsTap) != watchFlags { CGEvent.tapEnable(tap: flagsTap, enable: watchFlags) }
        updateClickTap()
    }

    private func updateClickTap() {
        guard let clickTap else { return }
        let needed = autoScroller.active || dockModifierHeld || swallowUp.contains(0) || swallowUp.contains(1)
        if CGEvent.tapIsEnabled(tap: clickTap) != needed { CGEvent.tapEnable(tap: clickTap, enable: needed) }
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(e)
        if type == .tapDisabledByTimeout {
            // macOS switched the tap off because input waited on us. Re-arm, but never loop:
            // three timeouts within 10 s → pause GoodMouse and leave input alone.
            let t = nowMs()
            timeouts = timeouts.filter { t - $0 < 10_000 } + [t]
            if timeouts.count >= 3 {
                DispatchQueue.main.async { AppDelegate.pause(reason: "macOS reported slow input handling. GoodMouse paused itself.") }
                return pass
            }
            refreshTaps()
            return pass
        }
        if type == .tapDisabledByUserInput {
            refreshTaps()
            return pass
        }
        let c = sharedConfig.withLock { $0 }
        guard c.enabled, e.getIntegerValueField(.eventSourceUserData) != ownEventMarker else { return pass }

        switch type {
        case .flagsChanged:
            let held = !c.dockModifier.isEmpty && e.flags.intersection(zoomTriggerMask) == c.dockModifier
            if held != dockModifierHeld {
                dockModifierHeld = held
                updateClickTap()
            }
            return pass

        case .scrollWheel:
            autoScroller.stop()
            return scroller.handle(e, c) ? nil : pass

        case .otherMouseDown:
            let button = e.getIntegerValueField(.mouseEventButtonNumber)
            swallowUp.remove(button)   // a lost mouse-up must not eat a later one
            if autoScroller.active {
                autoScroller.stop()
                return swallow(button)
            }
            if button == 2 && c.dockMiddleClick && moveToThisScreen(at: e.location) { return swallow(button) }
            let rule = WindowLookup.ruleUnderCursor(c)
            if rule?.scroll == .off { return pass }
            if button == 2 && !c.zoomTrigger.isEmpty && e.flags.intersection(zoomTriggerMask) == c.zoomTrigger
                && rule?.zoom ?? true && !CursorCheck.isPointingHand() {
                // Trigger key + middle click: zoom back to 100 % (on links the click stays native, e.g. ⌘-click).
                Zoomer.reset(c)
                return swallow(button)
            }
            if button == 2 && c.autoscroll && autoScroller.middleDown(at: e.location, c) {
                return swallow(button)
            }
            if button == 3 || button == 4 {
                // Standard: button 3 = back, 4 = forward.
                let back = (button == 3) != c.swapBackForward
                DispatchQueue.main.async { AppState.shared.lastSideButton = button }
                if c.backForward && postNavigationSwipe(back: back) { return swallow(button) }
                if c.swapBackForward { e.setIntegerValueField(.mouseEventButtonNumber, value: back ? 3 : 4) }
            }
            return pass

        case .otherMouseUp:
            let button = e.getIntegerValueField(.mouseEventButtonNumber)
            if button == 2 { autoScroller.middleUp() }
            if swallowUp.remove(button) != nil { return nil }
            if c.swapBackForward && (button == 3 || button == 4) && WindowLookup.ruleUnderCursor(c)?.scroll != .off {
                e.setIntegerValueField(.mouseEventButtonNumber, value: button == 3 ? 4 : 3)
            }
            return pass

        case .leftMouseDown, .rightMouseDown:
            if autoScroller.active {
                // A click ends autoscroll and is not passed on (like on Windows).
                autoScroller.stop()
                return swallow(type == .leftMouseDown ? 0 : 1)
            }
            if type == .leftMouseDown && !c.dockModifier.isEmpty
                && e.flags.intersection(zoomTriggerMask) == c.dockModifier && moveToThisScreen(at: e.location) {
                return swallow(0)
            }
            return pass

        case .leftMouseUp, .rightMouseUp:
            let swallowed = swallowUp.remove(type == .leftMouseUp ? 0 : 1) != nil
            updateClickTap()
            return swallowed ? nil : pass

        case .keyDown:
            if autoScroller.active && e.getIntegerValueField(.keyboardEventKeycode) == 53 {   // Esc
                autoScroller.stop()
                return nil
            }
            return pass

        default:
            return pass
        }
    }

    /// Click on a running app's Dock icon: move its windows to the screen under the pointer.
    private func moveToThisScreen(at p: CGPoint) -> Bool {
        guard let hit = DockMover.hit(at: p) else { return false }
        DispatchQueue.main.async { DockMover.moveWindows(hit) }
        return true
    }

    private func swallow(_ button: Int64) -> Unmanaged<CGEvent>? {
        swallowUp.insert(button)
        updateClickTap()
        return nil
    }

    /// Sends the same navigation-swipe gesture a two-finger trackpad swipe produces, so it works
    /// regardless of keyboard layout (⌘[ is a different physical key on German keyboards).
    /// Private CGEvent fields as used by LinearMouse/WebKit (MIT): 110 = HID type, 115 = swipe
    /// direction, 132 = gesture phase.
    private func postNavigationSwipe(back: Bool) -> Bool {
        guard let id = WindowLookup.underCursor().bundle,
              swipeNavigationApps.contains(where: { id.hasPrefix($0) }),
              let gestureType = CGEventType(rawValue: UInt32(NSEvent.EventType.gesture.rawValue)) else { return false }
        let navigationSwipe: Int64 = 16
        let direction: Int64 = back ? 0x04 : 0x08   // swipeLeft / swipeRight
        for phase: Int64 in [1, 4] {                 // began, ended
            guard let g = CGEvent(source: nil) else { return false }
            g.type = gestureType
            g.setIntegerValueField(CGEventField(rawValue: 110)!, value: navigationSwipe)
            g.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
            if phase == 1 { g.setIntegerValueField(CGEventField(rawValue: 115)!, value: direction) }
            g.post(tap: .cgSessionEventTap)
        }
        return true
    }
}
