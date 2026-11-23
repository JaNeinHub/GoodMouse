import CoreGraphics

/// Wheel zoom while the trigger key is held: one ⌘+ / ⌘- per notch, the app's own zoom
/// (browsers reflow the page, like Ctrl+wheel on Windows). Runs on the event thread.
/// Browsers only have fixed zoom levels, so a gliding zoom that reflows doesn't exist.
enum Zoomer {
    static func notch(zoomIn: Bool, _ c: Config) {
        postCommandKey(zoomIn ? c.zoomKeys.zoomIn : c.zoomKeys.zoomOut)
    }

    /// Trigger + middle click: ⌘0 (actual size).
    static func reset(_ c: Config) {
        postCommandKey(c.zoomKeys.reset)
    }
}
