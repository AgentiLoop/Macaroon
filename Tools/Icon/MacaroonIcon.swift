// Draws Macaroon's app icon: four quadrants, one per guest it runs: Mac (a classic compact Mac), Windows (four
// panes), Linux (Tux, from Tux.svg next to this file: Larry Ewing's Tux, lewing@isc.tamu.edu, made with The GIMP;
// Wikimedia Commons Tux.svg) and NeXT (the NeXT logo, NeXT_logo.svg next to this file).
// Usage: swift MacaroonIcon.swift <out.png>   (1024×1024, Apple's macOS icon grid: 824-pixel rounded square)
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
func c(_ hex: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 255) / 255, green: CGFloat(hex >> 8 & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}
func rr(_ r: NSRect, _ radius: CGFloat) -> NSBezierPath { NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius) }

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = rr(tile, 185)

// Drop shadow under the tile
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = c(0, 0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set(); c(0xFFFFFF).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Four quadrants
NSGraphicsContext.saveGraphicsState()
shape.addClip()
let half: CGFloat = 412
let mac = NSRect(x: 100, y: 512, width: half, height: half), win = NSRect(x: 512, y: 512, width: half, height: half)
let linux = NSRect(x: 100, y: 100, width: half, height: half), next = NSRect(x: 512, y: 100, width: half, height: half)
for (r, top, bottom) in [(mac, 0xF3EBDD, 0xDCCDB3), (win, 0x2D8CEB, 0x0F5AB4), (linux, 0xFFD34E, 0xF0A020), (next, 0x6E6E6E, 0x3E3E3E)] {
    NSGradient(starting: c(top), ending: c(bottom))!.draw(in: r, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()

// Mac: a classic compact Mac with a smiling screen (top left)
do {
    NSGraphicsContext.saveGraphicsState()
    let grow = NSAffineTransform() // 1.5× about the quadrant's centre, so it fills the quadrant like the others
    grow.translateX(by: mac.midX, yBy: mac.midY); grow.scale(by: 1.5); grow.translateX(by: -mac.midX, yBy: -mac.midY); grow.concat()
    let o = NSPoint(x: mac.midX - 85, y: mac.midY - 94)
    let body = rr(NSRect(x: o.x, y: o.y, width: 170, height: 210), 18)
    c(0xFBF7EE).setFill(); body.fill(); c(0x6B6150).setStroke(); body.lineWidth = 6; body.stroke()
    let screen = rr(NSRect(x: o.x + 22, y: o.y + 80, width: 126, height: 100), 10)
    c(0x5E6A70).setFill(); screen.fill()
    c(0xFFFFFF).setFill()
    NSBezierPath(rect: NSRect(x: o.x + 62, y: o.y + 140, width: 10, height: 18)).fill()
    NSBezierPath(rect: NSRect(x: o.x + 98, y: o.y + 140, width: 10, height: 18)).fill()
    let smile = NSBezierPath(); smile.appendArc(withCenter: NSPoint(x: o.x + 85, y: o.y + 132), radius: 26, startAngle: 200, endAngle: 340)
    c(0xFFFFFF).setStroke(); smile.lineWidth = 7; smile.lineCapStyle = .round; smile.stroke()
    c(0x6B6150).setFill()
    NSBezierPath(rect: NSRect(x: o.x + 95, y: o.y + 40, width: 52, height: 7)).fill() // floppy slot
    rr(NSRect(x: o.x + 10, y: o.y - 22, width: 150, height: 22), 6).fill() // foot
    NSGraphicsContext.restoreGraphicsState()
}

// Windows: four panes (top right)
do {
    let s: CGFloat = 92, gap: CGFloat = 12, ox = win.midX - s - gap / 2, oy = win.midY - s - gap / 2
    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        c(0xFFFFFF, 0.95).setFill()
        NSBezierPath(rect: NSRect(x: ox + CGFloat(dx) * (s + gap), y: oy + CGFloat(dy) * (s + gap), width: s, height: s)).fill()
    }
}

// Linux: Tux (bottom left)
do {
    let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Tux.svg")
    guard let tux = NSImage(contentsOf: svg) else { fatalError("Tux.svg missing next to MacaroonIcon.swift") }
    let h: CGFloat = 300, w = h * tux.size.width / tux.size.height
    tux.draw(in: NSRect(x: linux.midX - w / 2, y: linux.midY - h / 2, width: w, height: h))
}

// NeXT: the real NeXT logo (bottom right), from NeXT_logo.svg next to this file
do {
    let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("NeXT_logo.svg")
    guard let logo = NSImage(contentsOf: svg) else { fatalError("NeXT_logo.svg missing next to MacaroonIcon.swift") }
    let h: CGFloat = 400, w = h * logo.size.width / logo.size.height
    logo.draw(in: NSRect(x: next.midX - w / 2, y: next.midY - h / 2, width: w, height: h))
}

// Thin rim
c(0, 0.25).setStroke(); shape.lineWidth = 3; shape.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
