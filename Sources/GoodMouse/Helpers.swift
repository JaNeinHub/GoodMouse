import AppKit
import ApplicationServices
import CoreGraphics
import Carbon

/// Tags every event GoodMouse posts so the taps never process their own output.
let ownEventMarker: Int64 = 0x47_4F4F_444D_53   // "GOODMS"

private let timebase: mach_timebase_info_data_t = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return tb
}()

func nowMs() -> Double {
    Double(mach_absolute_time()) * Double(timebase.numer) / Double(timebase.denom) / 1e6
}

func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

/// A window on screen and the process that owns it.
struct ScreenWindow: Equatable {
    var id: CGWindowID
    var pid: pid_t
}

/// Posts a scroll event. Pixel units give smooth, phase-less scrolling (no trackpad
/// gestures, no momentum); line units mimic a classic notched wheel.
/// `location` is where the app hit-tests the event (default: the cursor). With `target`, the event
/// goes straight to that window's app instead of the window under the cursor.
func postScroll(units: CGScrollEventUnit, vertical: Int32, horizontal: Int32 = 0, flags: CGEventFlags = [],
                at location: CGPoint? = nil, target: ScreenWindow? = nil) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: units, wheelCount: 2,
                          wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
    e.location = location ?? cursorLocation()
    e.flags = flags
    e.setIntegerValueField(.eventSourceUserData, value: ownEventMarker)
    if let target {
        // 91 = window under the pointer, 92 = the one that can handle the event (AppKit routes by these).
        for field: UInt32 in [91, 92] { e.setIntegerValueField(CGEventField(rawValue: field)!, value: Int64(target.id)) }
        e.postToPid(target.pid)
    } else {
        e.post(tap: .cgSessionEventTap)
    }
}

/// The app owning the window under the cursor (where wheel and clicks go).
struct TargetApp {
    var bundle: String?
    var name: String?
    var files: [String] = []   // app file and program names, for apps without bundle id or name
}

extension NSRunningApplication {
    /// App file name without ".app" and program file name (e.g. "victoria3"). Some games ship with
    /// an empty bundle id and name (Paradox titles), so these are all that identifies them.
    var fileNames: [String] {
        let names = [bundleURL?.deletingPathExtension().lastPathComponent, executableURL?.lastPathComponent]
        return names.compactMap { $0 }.filter { !$0.isEmpty }
    }

    /// What an app rule for this app is saved as: the bundle id, else the app file name.
    var ruleEntry: String? {
        if let id = bundleIdentifier, !id.isEmpty { return id }
        return fileNames.first
    }

    /// Shown name: the app name, else the app file name.
    var displayName: String {
        if let n = localizedName, !n.isEmpty { return n }
        return fileNames.first ?? "?"
    }
}

/// Only used from the event thread.
enum WindowLookup {
    private static var cache: (t: Double, at: CGPoint, target: TargetApp)?

    /// Cached while the cursor stays put, so continuous scrolling doesn't re-query the window list.
    static func underCursor() -> TargetApp {
        let t = nowMs()
        let loc = cursorLocation()
        if let c = cache, t - c.t < 1000, abs(c.at.x - loc.x) < 4, abs(c.at.y - loc.y) < 4 { return c.target }
        var target = TargetApp()
        if let w = window(at: loc) {
            let app = NSRunningApplication(processIdentifier: w.pid)
            target = TargetApp(bundle: app?.bundleIdentifier, name: app?.localizedName, files: app?.fileNames ?? [])
        }
        cache = (t, loc, target)
        return target
    }

    /// The frontmost normal window at `p` (menu bar, Dock and overlays skipped).
    static func window(at p: CGPoint) -> ScreenWindow? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < 20,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: b), r.contains(p),
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t,
                  let id = w[kCGWindowNumber as String] as? CGWindowID else { continue }
            return ScreenWindow(id: id, pid: pid)
        }
        return nil
    }

    /// The rule for the app under the cursor (matched by bundle id, name or file name), if it has one.
    static func ruleUnderCursor(_ c: Config) -> AppRule? {
        guard !c.rules.isEmpty else { return nil }
        let w = underCursor()
        for key in [w.bundle, w.name].compactMap({ $0 }) + w.files where !key.isEmpty {
            if let r = c.rules[key.lowercased()] { return r }
        }
        return nil
    }
}

/// The pointing-hand cursor is what every browser shows over links, also in Chrome and
/// Electron apps, which don't expose their web content to Accessibility by default.
enum CursorCheck {
    private static let hand: (hot: CGPoint, size: CGSize) = (NSCursor.pointingHand.hotSpot, NSCursor.pointingHand.image.size)

    static func isPointingHand() -> Bool {
        guard let cur = NSCursor.currentSystem else { return false }
        let size = cur.image.size
        guard size.width > 0, size.height > 0, hand.size.width > 0 else { return false }
        // Compare shape (aspect ratio and relative hotspot), so an enlarged accessibility cursor matches too.
        let close = { (a: CGFloat, b: CGFloat) in abs(a - b) < 0.03 }
        return close(size.width / size.height, hand.size.width / hand.size.height)
            && close(cur.hotSpot.x / size.width, hand.hot.x / hand.size.width)
            && close(cur.hotSpot.y / size.height, hand.hot.y / hand.size.height)
    }
}

/// Key codes for ⌘+, ⌘- and ⌘0 on the current keyboard layout (German: "+" is where US has "]").
struct ZoomKeys {
    var zoomIn: CGKeyCode
    var zoomOut: CGKeyCode
    var reset: CGKeyCode
    static let fallback = ZoomKeys(zoomIn: 24, zoomOut: 27, reset: 29)   // US "=", "-", "0"

    /// Main thread only (Text Input Sources).
    static func forCurrentLayout() -> ZoomKeys {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var map: [String: CGKeyCode] = [:]
        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var len = 0
                guard UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                     OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars) == noErr,
                      len == 1 else { continue }
                let ch = String(utf16CodeUnits: chars, count: 1)
                if map[ch] == nil { map[ch] = CGKeyCode(code) }
            }
        }
        // Apps accept ⌘+ and ⌘= for zoom in: prefer an unshifted "+", else "=".
        return ZoomKeys(zoomIn: map["+"] ?? map["="] ?? fallback.zoomIn, zoomOut: map["-"] ?? fallback.zoomOut,
                        reset: map["0"] ?? fallback.reset)
    }
}

/// Presses ⌘+key once (key down + up), tagged as GoodMouse's own event.
func postCommandKey(_ code: CGKeyCode) {
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
        e.flags = .maskCommand
        e.setIntegerValueField(.eventSourceUserData, value: ownEventMarker)
        e.post(tap: .cgSessionEventTap)
    }
}

enum AXHelper {
    private static let system = AXUIElementCreateSystemWide()
    private static let clickable: Set<String> = ["AXLink", "AXButton", "AXRadioButton", "AXTab", "AXMenuButton",
                                                 "AXPopUpButton", "AXCheckBox", "AXDisclosureTriangle", "AXMenuItem"]
    private static let boundary: Set<String> = ["AXWebArea", "AXScrollArea", "AXWindow", "AXApplication"]

    /// True when the element under `p` (or one of its close ancestors) is a link, tab or button,
    /// where a middle click has a native meaning (open in new tab, close tab, …).
    static func isClickable(at p: CGPoint) -> Bool {
        AXUIElementSetMessagingTimeout(system, 0.2)   // never stall input for long on a hung app
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &hit) == .success,
              var cur = hit else { return false }
        for _ in 0..<12 {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &role)
            if let r = role as? String {
                if clickable.contains(r) { return true }
                if boundary.contains(r) { return false }
            }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let p = parent, CFGetTypeID(p) == AXUIElementGetTypeID() else { return false }
            cur = p as! AXUIElement
        }
        return false
    }
}

/// A repeating 120 Hz timer on the current (event) thread's run loop.
func makeFrameTimer(_ tick: @escaping () -> Void) -> Timer {
    let t = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in tick() }
    t.tolerance = 0
    RunLoop.current.add(t, forMode: .common)
    return t
}
