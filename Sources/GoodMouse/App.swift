import SwiftUI
import ServiceManagement
import ApplicationServices

let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

@main
struct GoodMouseApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    init() {
        // Before anything reads a setting.
        Settings.adoptLegacySettings()
    }

    var body: some Scene {
        // The menu bar icon is a StatusMenu (see below); a SwiftUI app needs at least one scene.
        SwiftUI.Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var healthTimer: Timer?
    private var statusMenu: StatusMenu?
    private var launchExecutableID: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard resolveOtherInstances() else { return }
        statusMenu = StatusMenu()
        launchExecutableID = Self.executableID()
        // macOS applies its own tick value at login, on wake and for new mice: put the exact speed back.
        PointerSpeed.reapply()
        PointerSpeed.watchNewDevices()
        WindowCache.start()
        // An old copy under the previous app id (2.5 or older), e.g. started later by its login item,
        // would reverse the wheel a second time: quit it.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                                                          object: nil, queue: .main) { note in
            if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
               app.bundleIdentifier == legacyBundleID { app.terminate() }
        }
        // Taps can be dropped across sleep; re-arm them on wake.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            self?.checkHealth()
            Engine.shared.configChanged()
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { PointerSpeed.reapply() }
        }
        // Posted whenever the Accessibility list changes: react at once, not only on the next tick.
        DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.accessibility.api"),
                                                            object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.checkHealth() }
        }
        let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)
        checkHealth()
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.checkHealth() }
        timer.tolerance = 1
        healthTimer = timer
    }

    /// GoodMouse only stays in the input chain while macOS still trusts it. An event tap whose
    /// owner lost its permission (e.g. its app file was deleted or rebuilt while running) gets its
    /// events rejected by WindowServer, which can swallow input system-wide.
    func checkHealth() {
        if Self.executableID() != launchExecutableID {
            // This copy was deleted or replaced by a new build: get out of the way and quit.
            Engine.shared.stop()
            NSApp.terminate(nil)
            return
        }
        let trusted = AXIsProcessTrusted()
        if !trusted || AppState.shared.pausedReason != nil {
            Engine.shared.stop()
        } else if !Engine.shared.isRunning {
            Engine.shared.start()
        }
        AppState.shared.tapRunning = Engine.shared.isRunning
    }

    static func pause(reason: String) {
        Engine.shared.stop()
        AppState.shared.pausedReason = reason
        AppState.shared.tapRunning = false
    }

    /// Two copies (e.g. two versions, also old ones under the previous app id) would both reverse
    /// the wheel and cancel each other out. Returns false when this copy quits.
    private func resolveOtherInstances() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let ids = Set([Bundle.main.bundleIdentifier ?? "", legacyBundleID])
        let others = ids.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }
        let otherVersion = others.first?.bundleURL.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "?"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "GoodMouse \(otherVersion) is already running"
        alert.informativeText = "Only one GoodMouse can run at a time. Quit version \(otherVersion) and use this one (\(appVersion))?"
        alert.addButton(withTitle: "Use \(appVersion)")
        alert.addButton(withTitle: "Keep \(otherVersion)")
        guard alert.runModal() == .alertFirstButtonReturn else {
            NSApp.terminate(nil)
            return false
        }
        for app in others { app.terminate() }
        let deadline = Date().addingTimeInterval(3)
        while others.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for app in others where !app.isTerminated { app.forceTerminate() }
        return true
    }

    /// Identity of the executable on disk (inode + modification time); changes on delete or rebuild.
    private static func executableID() -> String? {
        guard let path = Bundle.main.executablePath,
              let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return "\(attrs[.systemFileNumber] ?? 0)-\((attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    /// Opening the app again (Spotlight, Finder) brings the hidden menu bar icon back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        UserDefaults.standard.set(true, forKey: "showMenuBarIcon")
        return false
    }
}

/// The quick panel under the menu bar icon: everyday settings at a glance. Its size never changes
/// while open; the rarely used options are in the Advanced options window.
struct QuickPanel: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var state = AppState.shared
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var trackingPosition = PointerSpeed.position(of: PointerSpeed.current())
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("GoodMouse").font(.headline)
                Text(appVersion).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Enabled", isOn: $s.enabled).toggleStyle(.switch).labelsHidden()
            }
            if let reason = state.pausedReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text(reason).foregroundStyle(.orange)
                    Button("Resume") {
                        state.pausedReason = nil
                        (NSApp.delegate as? AppDelegate)?.checkHealth()
                    }
                }
            } else if !state.tapRunning {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Needs Accessibility permission.").foregroundStyle(.orange)
                    Button("Open Accessibility settings") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }

            Divider()
            Text("Wheel").font(.subheadline.bold())
            Toggle("Reverse wheel direction (opposite of trackpad)", isOn: $s.reverse)
            Toggle("Smooth scrolling (Windows style)", isOn: $s.smooth)
            SliderRow(title: "Distance per notch", value: $s.pxPerNotch, range: 30...300, step: 10, format: "%.0f px")
            HStack {
                Text("Zoom: hold")
                TriggerRecorder(trigger: $s.zoomTrigger)
                Text("+ wheel")
                Spacer()
            }
            if s.zoomTrigger != 0 {
                caption("One zoom step (⌘+ / ⌘−) per notch, like Ctrl+wheel on Windows. \(modifierSymbols(CGEventFlags(rawValue: s.zoomTrigger))) + middle click: back to 100 %.")
            }

            Divider()
            Text("Pointer").font(.subheadline.bold())
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Tracking speed")
                    Spacer()
                    Text(String(format: "%.2f", PointerSpeed.value(atPosition: trackingPosition)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $trackingPosition, in: 0...Double(PointerSpeed.ticks.count - 1)) {
                    EmptyView()
                } minimumValueLabel: {
                    Text("Slow").font(.caption)
                } maximumValueLabel: {
                    Text("Fast").font(.caption)
                }
                .onChange(of: trackingPosition) { p in PointerSpeed.set(PointerSpeed.value(atPosition: p)) }
                caption("Same setting as System Settings → Mouse → Tracking speed.")
            }

            Divider()
            Text("Dock: move app to this screen").font(.subheadline.bold())
            Toggle("Middle-click a Dock icon", isOn: $s.dockMiddleClick)
            HStack {
                Text("Click a Dock icon while holding")
                TriggerRecorder(trigger: $s.dockModifier)
            }
            caption("Moves the app's windows to the screen under the pointer and brings the app to the front, also windows hidden on another desktop (e.g. behind a full-screen app).")

            Divider()
            Text("Buttons").font(.subheadline.bold())
            Toggle("Side buttons: back / forward", isOn: $s.backForward)
            Toggle("Middle-click autoscroll", isOn: $s.autoscroll)
            Toggle("Middle-click on links stays native", isOn: $s.autoscrollKeepsLinks)
                .disabled(!s.autoscroll)
                .help("Links open in a new tab as usual. Tabs and buttons too, where the app exposes them to Accessibility (e.g. Safari, not Chrome).")

            Divider()
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            HStack {
                Button("Hide menu bar icon") { showMenuBarIcon = false }
                    .help("GoodMouse keeps running. Open it again (e.g. via Spotlight) to show the icon.")
                Spacer()
                Button("Advanced options…") { AdvancedWindow.show() }
                    .help("App rules and fine tuning")
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// App rules and fine tuning, in a normal macOS settings window.
struct AdvancedView: View {
    @ObservedObject private var s = Settings.shared
    @ObservedObject private var state = AppState.shared
    @State private var newEntry = ""
    @FocusState private var typing: Bool

    var body: some View {
        Form {
            Section("App rules") {
                ForEach($s.appRules, id: \.entry) { $rule in
                    AppRuleRow(rule: $rule) { s.appRules.removeAll { $0.entry == rule.entry } }
                }
                if s.appRules.isEmpty {
                    caption("No apps yet.")
                }
                Menu("Add a running app…") {
                    ForEach(runningApps(), id: \.processIdentifier) { app in
                        Button {
                            if let entry = app.ruleEntry { s.addRule(entry) }
                        } label: {
                            if let icon = app.icon { Image(nsImage: smallIcon(icon)) }
                            Text(app.displayName)
                        }
                    }
                }
                LabeledContent("Add by name") {
                    HStack {
                        // Label hidden: a Form right-aligns the text of labelled fields.
                        TextField("", text: $newEntry, prompt: Text("App name, bundle id or file name"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity)
                            .focused($typing)
                            .onSubmit(addTyped)
                        Button("Add", action: addTyped).disabled(newEntry.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if s.appRules.contains(where: { $0.scroll == .classic }) {
                    Stepper("Classic: lines per notch: \(s.excludedLines)", value: $s.excludedLines, in: 1...10)
                }
                caption("Smooth: like everywhere · Classic: no smoothing or autoscroll, still reversed · Off: GoodMouse ignores the app. 🔍 = zoom allowed. ⇧ = Shift + wheel scrolls sideways (turn off for games).")
            }

            Section("Fine tuning") {
                SliderRow(title: "Glide", value: $s.tauMs, range: 10...120, step: 5, format: "%.0f ms")
                SliderRow(title: "Bounce filter", value: $s.bounceMs, range: 0...150, step: 5, format: "%.0f ms")
                caption("Bounces filtered: \(state.bouncesFiltered)")
                SliderRow(title: "Autoscroll speed", value: $s.autoscrollSpeed, range: 0.3...3, step: 0.1, format: "%.1f×")
                    .disabled(!s.autoscroll)
                Toggle("Swap back and forward", isOn: $s.swapBackForward)
                caption(sideButtonText)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 440, minHeight: 300)
    }

    private var sideButtonText: String {
        guard let b = state.lastSideButton else { return "Last side button: none pressed yet" }
        let back = (b == 3) != s.swapBackForward
        return "Last side button: #\(b) → \(back ? "back" : "forward")"
    }

    private func addTyped() {
        s.addRule(newEntry)
        newEntry = ""
        typing = false   // done: keys no longer go into the field
    }

    private func runningApps() -> [NSRunningApplication] {
        let listed = Set(s.appRules.map { $0.entry.lowercased() })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.ruleEntry != nil
                && $0.bundleIdentifier != Bundle.main.bundleIdentifier
                && !listed.contains($0.ruleEntry!.lowercased()) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

private func caption(_ text: String) -> some View {
    Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
}

private func smallIcon(_ image: NSImage) -> NSImage {
    let copy = image.copy() as! NSImage
    copy.size = NSSize(width: 16, height: 16)
    return copy
}

/// One app rule: real app name and icon when the entry is a bundle id, scroll mode and zoom switch.
private struct AppRuleRow: View {
    @Binding var rule: AppRule
    let remove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rule.entry)
        HStack(spacing: 6) {
            if let url {
                Image(nsImage: smallIcon(NSWorkspace.shared.icon(forFile: url.path)))
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                    .lineLimit(1).truncationMode(.tail)
            } else {
                Image(systemName: "app.dashed").frame(width: 16)
                Text(rule.entry).lineLimit(1).truncationMode(.tail)
                    .help("Matched by name")
            }
            Spacer(minLength: 4)
            Picker("Scrolling", selection: $rule.scroll) {
                Text("Smooth").tag(ScrollRule.smooth)
                Text("Classic").tag(ScrollRule.classic)
                Text("Off").tag(ScrollRule.off)
            }
            .labelsHidden().pickerStyle(.menu).fixedSize()
            Toggle(isOn: $rule.zoom) { Image(systemName: "magnifyingglass") }
                .toggleStyle(.button)
                .disabled(rule.scroll == .off)
                .help(rule.zoom ? "Zoom with the wheel allowed" : "Zoom with the wheel off in this app")
            Toggle(isOn: $rule.shiftSideways) { Text("⇧") }
                .toggleStyle(.button)
                .help(rule.shiftSideways ? "Shift + wheel scrolls sideways (macOS default)"
                                         : "Shift + wheel keeps scrolling vertically in this app")
            Button(action: remove) { Image(systemName: "minus.circle.fill") }
                .buttonStyle(.borderless).foregroundStyle(.secondary)
                .help("Remove rule")
        }
    }
}

/// Click, then press the modifier key(s) to record them (zoom trigger, Dock click). Esc cancels, × turns it off.
private struct TriggerRecorder: View {
    @Binding var trigger: UInt64
    @State private var recording = false
    @State private var peak: CGEventFlags = []
    @State private var hint: String?
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 2) {
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? (peak.isEmpty ? (hint ?? "Press key…") : modifierSymbols(peak))
                               : (trigger == 0 ? "Off" : modifierSymbols(CGEventFlags(rawValue: trigger))))
                    .frame(minWidth: 44)
            }
            .help("Click, then press ⌘, ⌃, ⌥, ⇧ or fn (or a combination). Esc cancels, × turns it off.")
            if trigger != 0 && !recording {
                Button { trigger = 0 } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).help("Turn off")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        peak = []
        hint = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop() } else { hint = "Modifier keys only" }   // Esc cancels
                return nil
            }
            let now = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)).intersection(zoomTriggerMask)
            if now.isEmpty {
                if !peak.isEmpty { trigger = peak.rawValue }   // all keys released: take the combination
                stop()
            } else {
                peak.formUnion(now)
            }
            return nil
        }
    }

    private func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        recording = false
    }
}

/// Menu bar icon with the quick panel in a popover, which stays attached to the icon.
final class StatusMenu: NSObject, NSPopoverDelegate {
    static private(set) weak var shared: StatusMenu?
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private var defaultsObserver: NSObjectProtocol?

    override init() {
        super.init()
        Self.shared = self
        item.button?.image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "GoodMouse")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        updateVisibility()
        // "Hide menu bar icon" and reopening the app both write this preference.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                  object: nil, queue: .main) { [weak self] _ in
            self?.updateVisibility()
        }
    }

    private var iconShown: Bool?

    private func updateVisibility() {
        let show = UserDefaults.standard.object(forKey: "showMenuBarIcon") as? Bool ?? true
        // Setting isVisible writes the defaults itself, which calls this again: act on real changes only.
        guard show != iconShown else { return }
        iconShown = show
        item.isVisible = show
        if !show { close() }
    }

    func close() { popover.performClose(nil) }

    @objc private func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { close(); return }
        // A fresh view each time, so it shows current values (e.g. tracking speed changed in System Settings).
        let host = NSHostingController(rootView: QuickPanel())
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        NSApp.activate(ignoringOtherApps: true)   // key window: the key recorder needs it
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        popover.contentViewController = nil   // ends key recording and monitors of the old view
    }
}

/// The Advanced options window, created once and kept (closing only hides it).
enum AdvancedWindow {
    private static var window: NSWindow?

    static func show() {
        StatusMenu.shared?.close()
        if window == nil {
            let host = NSHostingController(rootView: AdvancedView())
            host.sizingOptions = [.minSize]   // freely resizable; the form scrolls inside
            let w = NSWindow(contentViewController: host)
            w.title = "GoodMouse Advanced Options"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            let maxHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 40
            w.setContentSize(NSSize(width: 520, height: min(620, maxHeight)))
            w.center()
            w.setFrameAutosaveName("AdvancedOptions")   // reopens where the user left it
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // AppKit would focus the text field on open; it should only take keys after a click into it.
        window?.makeFirstResponder(nil)
        DispatchQueue.main.async { window?.makeFirstResponder(nil) }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let format: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
        }
    }
}
