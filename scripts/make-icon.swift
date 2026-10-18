// Draws the DevDisk icon (a small treemap on a dark squircle) and writes a 1024px PNG.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
            blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: the shape sits inside a 824px square with a ~185px corner radius.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set()
hex(0x16161a).setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient(starting: hex(0x26262c), ending: hex(0x111114))!.draw(in: shape, angle: -90)

// Treemap tiles, in the app's categorical order: javascript, python, apple, jvm, models.
let inner = body.insetBy(dx: 120, dy: 120)
let gap: CGFloat = 18
let r: CGFloat = 36
func tile(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: UInt32) {
    let rect = NSRect(x: inner.minX + x * inner.width + gap / 2, y: inner.minY + y * inner.height + gap / 2,
                      width: w * inner.width - gap, height: h * inner.height - gap)
    let p = NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r)
    NSGradient(starting: hex(c), ending: hex(c).blended(withFraction: 0.25, of: .black)!)!.draw(in: p, angle: -90)
}
tile(0, 0, 0.58, 1, 0x2a78d6)
tile(0.58, 0.45, 0.42, 0.55, 0xeb6834)
tile(0.58, 0, 0.24, 0.45, 0x1baf7a)
tile(0.82, 0.2, 0.18, 0.25, 0xeda100)
tile(0.82, 0, 0.18, 0.2, 0xe87ba4)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
