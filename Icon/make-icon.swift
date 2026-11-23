// Renders the GoodMouse app icon (1024×1024 PNG): the white SF Symbol "computermouse"
// on the dark-grey gradient of iOS 18 dark-mode icons, on the macOS icon grid.
// Usage: swift make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let size = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS app icon grid: 824×824 body, 100 px margin, ~185 px corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.shadowBlurRadius = 24
NSGraphicsContext.saveGraphicsState()
shadow.set()
NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

let gradient = NSGradient(starting: NSColor(srgbRed: 0.20, green: 0.20, blue: 0.215, alpha: 1),
                          ending: NSColor(srgbRed: 0.095, green: 0.095, blue: 0.105, alpha: 1))!
gradient.draw(in: shape, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: 430, weight: .regular)
    .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
let symbol = NSImage(systemSymbolName: "computermouse", accessibilityDescription: nil)!
    .withSymbolConfiguration(config)!
let s = symbol.size
symbol.draw(in: NSRect(x: (CGFloat(size) - s.width) / 2, y: (CGFloat(size) - s.height) / 2,
                       width: s.width, height: s.height))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out) (symbol \(Int(s.width))×\(Int(s.height)))")
