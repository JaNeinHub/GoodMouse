import Foundation
import IOKit
import IOKit.hid

/// Mouse tracking speed, the same setting as System Settings → Mouse → Tracking speed. Main thread only.
///
/// System Settings only knows its 10 tick values. It stores the speed in the global preference
/// `com.apple.mouse.scaling` and the legacy IOHIDSystem parameter (which also drives the pointer).
/// GoodMouse writes the tick nearest to its own, finer value there, so the macOS slider follows,
/// and then sets the exact value on the HID system (`HIDMouseAcceleration`), which wins.
/// macOS re-applies the tick value at login, after sleep and for newly connected mice, so
/// GoodMouse re-applies its exact value at those moments (`reapply()`).
enum PointerSpeed {
    /// Values at the 10 tick marks of the macOS slider (slowest … fastest).
    static let ticks: [Double] = [0, 0.125, 0.5, 0.6875, 0.875, 1, 1.5, 2, 2.5, 3]
    private static let key = "com.apple.mouse.scaling" as CFString
    private static let ownKey = "trackingSpeed"   // GoodMouse's exact value, in its own defaults
    private static let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private static let legacy: io_connect_t = {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        defer { IOObjectRelease(svc) }
        var c: io_connect_t = 0
        return IOServiceOpen(svc, mach_task_self_, UInt32(kIOHIDParamConnectType), &c) == KERN_SUCCESS ? c : 0
    }()

    /// IOHIDSetAccelerationWithKey, looked up at runtime: deprecated, but it's what the Mouse pane
    /// uses. If a future macOS drops it, GoodMouse simply skips this step.
    private typealias SetAcceleration = @convention(c) (io_connect_t, CFString, Double) -> kern_return_t
    private static let setLegacy: SetAcceleration? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDSetAccelerationWithKey")
        .map { unsafeBitCast($0, to: SetAcceleration.self) }

    static func nearestTick(_ v: Double) -> Double {
        ticks.min { abs($0 - v) < abs($1 - v) }!
    }

    private static func systemValue() -> Double {
        let v = CFPreferencesCopyValue(key, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? NSNumber)?.doubleValue ?? 0.6875   // macOS default
    }

    /// GoodMouse's exact value while System Settings still shows its tick; otherwise the user changed
    /// the speed in System Settings, and that value counts.
    static func current() -> Double {
        let sys = systemValue()
        if let own = UserDefaults.standard.object(forKey: ownKey) as? Double, nearestTick(own) == sys { return own }
        return sys
    }

    static func set(_ value: Double) {
        let v = min(max(value, ticks.first!), ticks.last!)
        let tick = nearestTick(v)
        UserDefaults.standard.set(v, forKey: ownKey)
        if tick != systemValue() {
            CFPreferencesSetValue(key, NSNumber(value: tick), kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            if legacy != 0, let setLegacy { _ = setLegacy(legacy, kIOHIDMouseAccelerationType as CFString, tick) }
            // An open Mouse pane refreshes its slider on this notification.
            DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("TrackingDidChangeNotification"),
                                                                         object: nil, userInfo: nil, deliverImmediately: true)
        }
        applyExact(v)
    }

    /// Puts GoodMouse's exact value back after macOS applied its tick value (login, wake, new mouse).
    static func reapply() {
        guard let own = UserDefaults.standard.object(forKey: ownKey) as? Double else { return }
        if nearestTick(own) == systemValue() {
            if own != nearestTick(own) { applyExact(own) }
        } else {
            UserDefaults.standard.removeObject(forKey: ownKey)   // changed in System Settings meanwhile
        }
    }

    private static func applyExact(_ v: Double) {
        IOHIDEventSystemClientSetProperty(client, kIOHIDMouseAccelerationType as CFString, NSNumber(value: Int(v * 65536)))
    }

    private static var notifyPort: IONotificationPortRef?

    /// Calls `reapply()` shortly after any HID device appears (needs no permission).
    static func watchNewDevices() {
        guard notifyPort == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        notifyPort = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        var iterator: io_iterator_t = 0
        let callback: IOServiceMatchingCallback = { _, it in
            var any = false
            while case let obj = IOIteratorNext(it), obj != 0 { IOObjectRelease(obj); any = true }
            if any { DispatchQueue.main.asyncAfter(deadline: .now() + 1) { PointerSpeed.reapply() } }
        }
        guard IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOHIDDevice"),
                                               callback, nil, &iterator) == KERN_SUCCESS else { return }
        while case let obj = IOIteratorNext(iterator), obj != 0 { IOObjectRelease(obj) }   // existing devices; arms the notification
    }

    /// Slider position 0…9 (tick marks evenly spaced, like the macOS slider) ↔ speed value.
    static func value(atPosition p: Double) -> Double {
        let p = min(max(p, 0), Double(ticks.count - 1))
        let i = min(Int(p), ticks.count - 2)
        return ticks[i] + (ticks[i + 1] - ticks[i]) * (p - Double(i))
    }

    static func position(of value: Double) -> Double {
        for i in 0..<(ticks.count - 1) where value <= ticks[i + 1] {
            let span = ticks[i + 1] - ticks[i]
            return Double(i) + (span > 0 ? max(0, value - ticks[i]) / span : 0)
        }
        return Double(ticks.count - 1)
    }
}
