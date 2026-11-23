import AppKit

/// "Move to this screen" from the Dock (ported from AppMover): middle-click or modifier-click a
/// running app's Dock icon → its windows move to the display under the pointer and the app comes
/// to the front.
///
/// - Windows keep their relative position (top-left stays top-left), shrunk if they don't fit.
/// - Windows stranded off-screen (e.g. from a disconnected display) are centered on the target screen.
/// - Minimized windows are moved while still minimized, then the Dock restores them itself (as on a
///   normal click), so the opening animation lands on the target screen. Full-screen windows are left alone.
/// - Clicks on non-running apps, folders, stacks and the Trash aren't moved: a modifier-click goes to
///   the Dock as usual, a middle-click is handled like anywhere else (autoscroll).
/// - Windows on a hidden desktop of another screen (e.g. behind a full-screen app) aren't listed by
///   Accessibility, but an element taken while the window was visible keeps working (WindowCache), and
///   unknown ones are searched for (RemoteAX). Moved through that element, a window goes straight to the
///   target screen's Space, so no screen switches. A window that can't be reached is left to macOS: the
///   click then acts like a normal Dock click.
/// - If the target screen shows a full-screen app, the moved windows land on its desktop behind it;
///   activating the app makes macOS switch that screen to them.
enum DockMover {
    struct Hit {
        let app: NSRunningApplication
        let item: AXUIElement   // the Dock icon
    }

    /// A window on a hidden desktop of another screen.
    private struct HiddenWindow {
        let id: CGWindowID
        let frame: CGRect   // AX coordinates
    }

    private static var busy = false   // searching for unknown hidden windows (main thread)

    /// Event thread: the running app whose Dock icon is at `point` (CG coordinates), if any.
    /// Cheap for clicks elsewhere: the Dock is only asked when the point is inside a Dock window.
    static func hit(at point: CGPoint) -> Hit? {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              isDockWindow(at: point, dockPID: dock.processIdentifier) else { return nil }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        AXUIElementSetMessagingTimeout(dockElement, 0.2)   // never stall input for long
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(dockElement, Float(point.x), Float(point.y), &hit) == .success,
              let item = hit,
              copyAttribute(item, kAXSubroleAttribute) as? String == "AXApplicationDockItem",
              let url = copyAttribute(item, kAXURLAttribute) as? URL else { return nil }

        let running = NSWorkspace.shared.runningApplications
        if let bundleID = Bundle(url: url)?.bundleIdentifier,
           let app = running.first(where: { $0.bundleIdentifier == bundleID }) {
            return Hit(app: app, item: item)
        }
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return running.first { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == path }
            .map { Hit(app: $0, item: item) }
    }

    private static func isDockWindow(at point: CGPoint, dockPID: pid_t) -> Bool {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == dockPID,
                  w[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.dockWindow)),
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b) else { return false }
            return r.contains(point)
        }
    }

    /// Main thread: moves all windows of the app onto the screen that contains the pointer.
    ///
    /// Restoring minimized windows ourselves and then raising/activating the app interfered with the
    /// opening animation (the window showed for a frame before it). So minimized windows are moved
    /// while still minimized, and the restore is left to the Dock: GoodMouse "presses" the Dock icon
    /// through Accessibility, exactly like a normal click, and touches nothing during the animation.
    static func moveWindows(_ hit: Hit) {
        guard !busy, let target = screenUnderMouse() else { return }
        let windows = movableWindows(of: hit.app)
        let hidden = windows.isEmpty ? hiddenWindows(of: hit.app, besides: target) : []
        guard !hidden.isEmpty else { move(windows, of: hit, to: target); return }
        var known: [CGWindowID: AXUIElement] = [:]
        for h in hidden { if let e = WindowCache.element(for: h.id) { known[h.id] = e } }
        let missing = Set(hidden.map(\.id)).subtracting(known.keys)
        guard !missing.isEmpty else { pull(hidden, known, of: hit, to: target); return }
        // Windows GoodMouse never saw while they were visible (rare): search for them off the main thread.
        busy = true
        let pid = hit.app.processIdentifier
        DispatchQueue.global(qos: .userInitiated).async {
            let found = RemoteAX.windows(pid: pid, ids: missing, budget: 1.5)
            DispatchQueue.main.async {
                busy = false
                pull(hidden, known.merging(found) { a, _ in a }, of: hit, to: target)
            }
        }
    }

    /// Moves windows from hidden desktops through their AX elements: macOS puts them on the target screen's
    /// Space right away, without switching any Space. With no element at all, only the app is activated,
    /// like a normal Dock click.
    private static func pull(_ hidden: [HiddenWindow], _ elements: [CGWindowID: AXUIElement], of hit: Hit,
                             to target: NSScreen) {
        let windows = hidden.compactMap { h -> AXUIElement? in
            guard let e = elements[h.id] else { return nil }
            setFrame(e, place(h.frame, on: target))
            return e
        }
        raise(windows, of: hit.app)
    }

    private static func move(_ windows: [AXUIElement], of hit: Hit, to target: NSScreen) {
        WindowCache.store(windows.compactMap { w in RemoteAX.windowID(of: w).map { ($0, w) } })
        var minimized: [AXUIElement] = [], visible: [AXUIElement] = []
        for w in windows { if isMinimized(w) { minimized.append(w) } else { visible.append(w) } }

        for w in windows {
            if let f = frame(of: w) { setFrame(w, place(f, on: target)) }
        }

        if visible.isEmpty && !minimized.isEmpty {
            // Like a normal Dock click: the Dock restores the window with its own animation and activates the app.
            AXUIElementPerformAction(hit.item, kAXPressAction as CFString)
        } else {
            raise(visible, of: hit.app)
            // The app is already in front, so a Dock press wouldn't restore anything: restore directly.
            for w in minimized { setMinimized(w, false) }
        }
        guard !minimized.isEmpty else { return }

        // After the animation: restore what the Dock left minimized (it restores one window per click),
        // and move windows whose app ignored the new position while minimized.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            for w in minimized {
                if isMinimized(w) {
                    setMinimized(w, false)
                } else if let f = frame(of: w), sourceScreen(for: f) != target {
                    setFrame(w, place(f, on: target))
                }
            }
        }
    }

    /// Normal windows the app has on hidden desktops of other screens (Accessibility doesn't list those).
    /// Hidden desktops of the target screen are left out: there a normal activation already shows them.
    /// Windows on hidden full-screen Spaces stay where they are.
    private static func hiddenWindows(of app: NSRunningApplication, besides target: NSScreen) -> [HiddenWindow] {
        guard let hidden = Spaces.hiddenDesktops() else { return [] }
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { w in
            guard w[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  w[kCGWindowLayer as String] as? Int == 0,
                  w[kCGWindowIsOnscreen as String] as? Bool != true,
                  let id = w[kCGWindowNumber as String] as? CGWindowID,
                  let r = bounds(of: w), r.width >= 100, r.height >= 100,
                  !hidden.isDisjoint(with: Spaces.of(id)),
                  sourceScreen(for: r) != target else { return nil }
            return HiddenWindow(id: id, frame: r)
        }
    }

    private static func bounds(of info: [String: Any]) -> CGRect? {
        guard let b = info[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: b)
    }

    /// Raises the windows and activates the app. If the target screen shows a full-screen app, activating
    /// makes macOS switch that screen to the moved windows.
    private static func raise(_ windows: [AXUIElement], of app: NSRunningApplication) {
        for w in windows { AXUIElementPerformAction(w, kAXRaiseAction as CFString) }
        app.activate()
    }

    /// Standard windows and dialogs of the app on the shown Spaces, including minimized and full-screen ones.
    private static func appWindows(of app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(axApp, 0.5)
        return ((copyAttribute(axApp, kAXWindowsAttribute) as? [AXUIElement]) ?? []).filter { window in
            let subrole = copyAttribute(window, kAXSubroleAttribute) as? String
            return subrole == kAXStandardWindowSubrole || subrole == kAXDialogSubrole
        }
    }

    /// Windows that can be moved: full-screen ones stay where they are.
    private static func movableWindows(of app: NSRunningApplication) -> [AXUIElement] {
        appWindows(of: app).filter { copyAttribute($0, "AXFullScreen") as? Bool != true }
    }

    private static func setFrame(_ window: AXUIElement, _ f: CGRect) {
        setSize(window, f.size)
        setPosition(window, f.origin)
        setSize(window, f.size)   // some apps clamp the size against the old screen first
    }

    private static func isMinimized(_ w: AXUIElement) -> Bool {
        copyAttribute(w, kAXMinimizedAttribute) as? Bool == true
    }

    private static func setMinimized(_ w: AXUIElement, _ on: Bool) {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, on ? kCFBooleanTrue : kCFBooleanFalse)
    }

    // MARK: - Geometry (all CGRects here are in AX coordinates: top-left origin of the primary screen)

    /// Keeps the window's relative position from its source screen; windows on no screen get centered.
    private static func place(_ frame: CGRect, on target: NSScreen) -> CGRect {
        let dst = axRect(target.visibleFrame)
        var size = CGSize(width: min(frame.width, dst.width), height: min(frame.height, dst.height))
        size = CGSize(width: max(size.width, 1), height: max(size.height, 1))

        var origin: CGPoint
        switch sourceScreen(for: frame) {
        case nil:   // orphaned, e.g. left behind by a disconnected display
            origin = CGPoint(x: dst.midX - size.width / 2, y: dst.midY - size.height / 2)
        case target?:   // already there; just clamp below
            origin = frame.origin
        case let source?:
            let src = axRect(source.visibleFrame)
            let fx = src.width > frame.width ? (frame.minX - src.minX) / (src.width - frame.width) : 0.5
            let fy = src.height > frame.height ? (frame.minY - src.minY) / (src.height - frame.height) : 0.5
            origin = CGPoint(x: dst.minX + clamp01(fx) * (dst.width - size.width),
                             y: dst.minY + clamp01(fy) * (dst.height - size.height))
        }
        origin.x = min(max(origin.x, dst.minX), dst.maxX - size.width)
        origin.y = min(max(origin.y, dst.minY), dst.maxY - size.height)
        return CGRect(origin: origin, size: size)
    }

    private static func clamp01(_ v: CGFloat) -> CGFloat { min(max(v, 0), 1) }

    private static func screenUnderMouse() -> NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
    }

    /// Screen with the largest overlap with the window, or nil if the window is on no screen.
    private static func sourceScreen(for axFrame: CGRect) -> NSScreen? {
        var best: (NSScreen, CGFloat)?
        for screen in NSScreen.screens {
            let overlap = axRect(screen.frame).intersection(axFrame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.1 ?? 0) { best = (screen, area) }
        }
        return best?.0
    }

    /// Converts a Cocoa rect (bottom-left origin) to AX coordinates (top-left origin). The transform is its own inverse.
    private static func axRect(_ r: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - AX helpers

    private static func copyAttribute(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let posValue = copyAttribute(window, kAXPositionAttribute),
              let sizeValue = copyAttribute(window, kAXSizeAttribute) else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var p = point
        if let v = AXValueCreate(.cgPoint, &p) { AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v) }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var s = size
        if let v = AXValueCreate(.cgSize, &s) { AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v) }
    }
}
