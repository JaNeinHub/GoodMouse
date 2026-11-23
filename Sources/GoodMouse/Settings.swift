import Foundation
import CoreGraphics
import Combine
import os

/// How GoodMouse handles the wheel in an app with its own rule.
enum ScrollRule: String, Codable, CaseIterable {
    case smooth    // like everywhere else
    case classic   // no smoothing, N lines per notch, still reversed
    case off       // GoodMouse ignores the app completely
}

/// Per-app rule, matched by bundle id or app name (case-insensitive).
struct AppRule: Codable, Hashable {
    var entry: String
    var scroll: ScrollRule = .classic
    var zoom = false
    var shiftSideways = true   // false: Shift + wheel keeps scrolling vertically (e.g. sneaking in games)

    init(entry: String, scroll: ScrollRule = .classic, zoom: Bool = false) {
        self.entry = entry
        self.scroll = scroll
        self.zoom = zoom
    }

    /// Rules saved by older versions lack newer fields: fall back to the defaults instead of failing.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entry = try c.decode(String.self, forKey: .entry)
        scroll = try c.decodeIfPresent(ScrollRule.self, forKey: .scroll) ?? .classic
        zoom = try c.decodeIfPresent(Bool.self, forKey: .zoom) ?? false
        shiftSideways = try c.decodeIfPresent(Bool.self, forKey: .shiftSideways) ?? true
    }
}

/// Modifier keys that can trigger zoom (same bit values in CGEventFlags and NSEvent.ModifierFlags).
let zoomTriggerMask: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn]

func modifierSymbols(_ f: CGEventFlags) -> String {
    var s = ""
    if f.contains(.maskSecondaryFn) { s += "fn " }
    if f.contains(.maskControl) { s += "⌃" }
    if f.contains(.maskAlternate) { s += "⌥" }
    if f.contains(.maskShift) { s += "⇧" }
    if f.contains(.maskCommand) { s += "⌘" }
    return s
}

/// Immutable snapshot of the settings, read by the event thread.
struct Config {
    var enabled = true
    var smooth = true
    var pxPerNotch = 100.0
    var tauMs = 40.0
    var bounceMs = 60.0
    var reverse = true
    var rules: [String: AppRule] = [:]      // key: lowercased bundle id or app name
    var classicLines = 3
    var backForward = true
    var swapBackForward = false
    var autoscroll = true
    var autoscrollKeepsLinks = true
    var autoscrollSpeed = 1.3
    var zoomTrigger: CGEventFlags = []      // empty = zoom off
    var zoomKeys = ZoomKeys.fallback        // layout-dependent key codes, refreshed on the main thread
    var dockMiddleClick = true              // middle-click a Dock icon: windows to this screen
    var dockModifier: CGEventFlags = [.maskControl, .maskAlternate]   // + left click on a Dock icon; empty = off
}

/// The event thread reads this; the UI writes it through `Settings`.
let sharedConfig = OSAllocatedUnfairLock(initialState: Config())

/// App id up to 2.5. Its settings are copied over once, and copies still running under it count
/// as another GoodMouse.
let legacyBundleID = "local.mousemactool.GoodMouse"

/// User settings, persisted in UserDefaults (domain io.github.janeinhub.GoodMouse).
final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var enabled: Bool { didSet { save(enabled, "enabled") } }

    // Wheel
    @Published var smooth: Bool { didSet { save(smooth, "smooth") } }
    @Published var pxPerNotch: Double { didSet { save(pxPerNotch, "pxPerNotch") } }
    @Published var tauMs: Double { didSet { save(tauMs, "tauMs") } }
    @Published var bounceMs: Double { didSet { save(bounceMs, "bounceMs") } }
    @Published var reverse: Bool { didSet { save(reverse, "reverse") } }

    // Zoom
    @Published var zoomTrigger: UInt64 { didSet { save(NSNumber(value: zoomTrigger), "zoomTrigger") } }

    // Dock: move windows to this screen
    @Published var dockMiddleClick: Bool { didSet { save(dockMiddleClick, "dockMiddleClick") } }
    @Published var dockModifier: UInt64 { didSet { save(NSNumber(value: dockModifier), "dockModifier") } }

    // Per-app rules
    @Published var appRules: [AppRule] { didSet { save((try? JSONEncoder().encode(appRules)) ?? Data(), "appRules") } }
    @Published var excludedLines: Int { didSet { save(excludedLines, "excludedLines") } }

    // Buttons
    @Published var backForward: Bool { didSet { save(backForward, "backForward") } }
    @Published var swapBackForward: Bool { didSet { save(swapBackForward, "swapBackForward") } }
    @Published var autoscroll: Bool { didSet { save(autoscroll, "autoscroll") } }
    @Published var autoscrollKeepsLinks: Bool { didSet { save(autoscrollKeepsLinks, "autoscrollKeepsLinks") } }
    @Published var autoscrollSpeed: Double { didSet { save(autoscrollSpeed, "autoscrollSpeed") } }

    private var zoomKeys = ZoomKeys.fallback

    private static let defaults: [String: Any] = [
        "enabled": true,
        "smooth": true, "pxPerNotch": 100.0, "tauMs": 40.0, "bounceMs": 60.0, "reverse": true,
        "zoomTrigger": 0, "dockMiddleClick": true,
        "dockModifier": CGEventFlags([.maskControl, .maskAlternate]).rawValue, "excludedLines": 3,
        "backForward": true, "swapBackForward": false,
        "autoscroll": true, "autoscrollKeepsLinks": true, "autoscrollSpeed": 1.3,
    ]

    private init() {
        Self.migrate(d)
        d.register(defaults: Self.defaults)
        enabled = d.bool(forKey: "enabled")
        smooth = d.bool(forKey: "smooth")
        pxPerNotch = d.double(forKey: "pxPerNotch")
        tauMs = d.double(forKey: "tauMs")
        bounceMs = d.double(forKey: "bounceMs")
        reverse = d.bool(forKey: "reverse")
        zoomTrigger = UInt64(truncatingIfNeeded: d.integer(forKey: "zoomTrigger")) & zoomTriggerMask.rawValue
        dockMiddleClick = d.bool(forKey: "dockMiddleClick")
        dockModifier = UInt64(truncatingIfNeeded: d.integer(forKey: "dockModifier")) & zoomTriggerMask.rawValue
        appRules = d.data(forKey: "appRules").flatMap { try? JSONDecoder().decode([AppRule].self, from: $0) } ?? []
        excludedLines = d.integer(forKey: "excludedLines")
        backForward = d.bool(forKey: "backForward")
        swapBackForward = d.bool(forKey: "swapBackForward")
        autoscroll = d.bool(forKey: "autoscroll")
        autoscrollKeepsLinks = d.bool(forKey: "autoscrollKeepsLinks")
        autoscrollSpeed = d.double(forKey: "autoscrollSpeed")
        zoomKeys = ZoomKeys.forCurrentLayout()
        publish()

        // ⌘+ sits on a different key per keyboard layout: look it up again when the layout changes.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            zoomKeys = ZoomKeys.forCurrentLayout()
            publish()
        }
    }

    /// Adds an app rule (no smoothing, no zoom) unless the app already has one.
    func addRule(_ entry: String) {
        let e = entry.trimmingCharacters(in: .whitespaces)
        guard !e.isEmpty, !appRules.contains(where: { $0.entry.caseInsensitiveCompare(e) == .orderedSame }) else { return }
        appRules.append(AppRule(entry: e))
    }

    /// First launch under the new app id: take over the settings of 2.5 and older.
    static func adoptLegacySettings() {
        let d = UserDefaults.standard
        guard let own = Bundle.main.bundleIdentifier, own != legacyBundleID,
              d.persistentDomain(forName: own)?.isEmpty ?? true,
              let old = d.persistentDomain(forName: legacyBundleID), !old.isEmpty else { return }
        d.setPersistentDomain(old, forName: own)
    }

    /// Settings written by 1.0 / 1.1 → 1.2 app rules and zoom trigger.
    private static func migrate(_ d: UserDefaults) {
        if d.object(forKey: "appRules") == nil {
            var entries = d.stringArray(forKey: "excludedList")
                ?? d.string(forKey: "excludedApps").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
                ?? []
            entries = entries.filter { !$0.isEmpty }
            let mode: ScrollRule = d.string(forKey: "exclusionMode") == "off" ? .off : .classic
            d.set(try? JSONEncoder().encode(entries.map { AppRule(entry: $0, scroll: mode, zoom: false) }), forKey: "appRules")
        }
        if d.object(forKey: "zoomTrigger") == nil, let old = d.string(forKey: "zoomModifier") {
            let flags: CGEventFlags = old == "control" ? .maskControl : old == "option" ? .maskAlternate : []
            d.set(NSNumber(value: flags.rawValue), forKey: "zoomTrigger")
        }
    }

    private func save(_ value: Any, _ key: String) {
        d.set(value, forKey: key)
        publish()
    }

    private func publish() {
        let c = Config(
            enabled: enabled, smooth: smooth, pxPerNotch: pxPerNotch, tauMs: max(1, tauMs), bounceMs: bounceMs,
            reverse: reverse,
            rules: Dictionary(appRules.map { ($0.entry.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
                              uniquingKeysWith: { first, _ in first }),
            classicLines: max(1, excludedLines),
            backForward: backForward, swapBackForward: swapBackForward,
            autoscroll: autoscroll, autoscrollKeepsLinks: autoscrollKeepsLinks, autoscrollSpeed: autoscrollSpeed,
            zoomTrigger: CGEventFlags(rawValue: zoomTrigger).intersection(zoomTriggerMask),
            zoomKeys: zoomKeys, dockMiddleClick: dockMiddleClick,
            dockModifier: CGEventFlags(rawValue: dockModifier).intersection(zoomTriggerMask))
        sharedConfig.withLock { $0 = c }
        Engine.shared.configChanged()
    }
}

/// Runtime status shown in the menu. Only touched on the main thread.
final class AppState: ObservableObject {
    static let shared = AppState()
    @Published var tapRunning = false
    @Published var pausedReason: String?
    @Published var bouncesFiltered = 0
    @Published var lastSideButton: Int64?
}
