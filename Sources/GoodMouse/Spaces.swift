import AppKit

/// Read-only Space queries (private SkyLight functions, as used by window switchers). Looked up at
/// runtime: if a macOS version drops them, the hidden-desktop pull just stays off.
enum Spaces {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias DisplaySpaces = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private static let functions: (MainConnection, SpacesForWindows, DisplaySpaces)? = {
        let h = dlopen(nil, RTLD_NOW)
        guard let a = dlsym(h, "CGSMainConnectionID"), let b = dlsym(h, "CGSCopySpacesForWindows"),
              let c = dlsym(h, "CGSCopyManagedDisplaySpaces") else { return nil }
        return (unsafeBitCast(a, to: MainConnection.self), unsafeBitCast(b, to: SpacesForWindows.self),
                unsafeBitCast(c, to: DisplaySpaces.self))
    }()

    /// Normal desktops (not full-screen Spaces) that no screen shows right now, or nil if unavailable.
    static func hiddenDesktops() -> Set<Int>? {
        guard let (connection, _, displaySpaces) = functions,
              let displays = displaySpaces(connection())?.takeRetainedValue() as? [[String: Any]] else { return nil }
        var hidden = Set<Int>()
        for d in displays {
            let current = (d["Current Space"] as? [String: Any])?["id64"] as? Int
            for space in d["Spaces"] as? [[String: Any]] ?? [] {
                guard let id = space["id64"] as? Int, id != current, space["type"] as? Int == 0 else { continue }
                hidden.insert(id)
            }
        }
        return hidden
    }

    /// The Spaces a window belongs to (empty for windows on none, e.g. invisible helper windows).
    static func of(_ window: CGWindowID) -> Set<Int> {
        guard let (connection, spacesForWindows, _) = functions,
              let ids = spacesForWindows(connection(), 7, [window] as CFArray)?.takeRetainedValue() as? [Int] else { return [] }
        return Set(ids)
    }
}

/// Accessibility handles for windows the app doesn't list (those on hidden Spaces), the way AltTab
/// (GPL-3.0) reaches them: build an element from a "remote token" (pid + element number) for each number
/// in turn until the wanted windows turn up. Private HIServices functions, looked up at runtime.
enum RemoteAX {
    private typealias CreateWithToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    private static let functions: (CreateWithToken, GetWindow)? = {
        let h = dlopen(nil, RTLD_NOW)
        guard let a = dlsym(h, "_AXUIElementCreateWithRemoteToken"), let b = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return (unsafeBitCast(a, to: CreateWithToken.self), unsafeBitCast(b, to: GetWindow.self))
    }()

    /// The window id behind an AX window element.
    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let (_, getWindow) = functions else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }

    /// Background thread: the window elements of `pid` for the windows `ids`, searching for at most `budget`
    /// seconds (roughly 100,000 element numbers per second).
    static func windows(pid: pid_t, ids: Set<CGWindowID>, budget: Double) -> [CGWindowID: AXUIElement] {
        guard let (create, getWindow) = functions, !ids.isEmpty else { return [:] }
        // 20 bytes: pid (4) + 0 (4) + "coco" (4) + element number (8).
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: pid, toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f636f), toByteOffset: 8, as: Int32.self)
        }
        let start = nowMs()
        var found: [CGWindowID: AXUIElement] = [:]
        var number: UInt64 = 0
        while found.count < ids.count && nowMs() - start < budget * 1000 {
            token.withUnsafeMutableBytes { $0.storeBytes(of: number, toByteOffset: 12, as: UInt64.self) }
            number += 1
            guard let element = create(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, 0.1)   // a hung app must not stall the search
            var wid: CGWindowID = 0
            guard getWindow(element, &wid) == .success, ids.contains(wid), found[wid] == nil else { continue }
            // Buttons and views of a window report its id too: only the window element itself counts.
            var role: AnyObject?
            guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole else { continue }
            found[wid] = element
        }
        return found
    }
}

/// Remembers the AX elements of windows by window id. Accessibility stops listing a window once its
/// desktop is hidden, but an element taken while it was visible keeps working, so the Dock move can still
/// reach it. Filled when an app is activated or deactivated (one AX query each, off the main thread; the
/// second catches windows opened while the app was in front) and once at launch. Main thread only.
enum WindowCache {
    private static var elements: [CGWindowID: AXUIElement] = [:]
    private static let queue = DispatchQueue(label: "GoodMouse.windowcache", qos: .utility)

    static func start() {
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didDeactivateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { remember(app) }
            }
        }
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular { remember(app) }
    }

    static func remember(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid() else { return }
        queue.async {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            var value: AnyObject?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let windows = value as? [AXUIElement] else { return }
            let found = windows.compactMap { w in RemoteAX.windowID(of: w).map { ($0, w) } }
            DispatchQueue.main.async { store(found) }
        }
    }

    static func store(_ windows: [(CGWindowID, AXUIElement)]) {
        for (id, w) in windows { elements[id] = w }
        guard elements.count > 64 else { return }
        // Drop windows that no longer exist.
        let alive = Set((CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID })
        elements = elements.filter { alive.contains($0.key) }
    }

    /// The remembered element of window `id`, if it still belongs to that window.
    static func element(for id: CGWindowID) -> AXUIElement? {
        guard let e = elements[id] else { return nil }
        if RemoteAX.windowID(of: e) == id { return e }
        elements[id] = nil
        return nil
    }
}
