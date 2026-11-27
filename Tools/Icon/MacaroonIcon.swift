// Draws Macaroon's app icon: three bands at 45 degrees, one per guest it runs: Windows (four panes, top left),
// Mac (a classic compact Mac, across the middle) and Linux (Tux, bottom right, from Tux.svg next to this file:
// Larry Ewing's Tux, lewing@isc.tamu.edu, made with The GIMP; Wikimedia Commons Tux.svg).
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
func poly(_ points: [NSPoint]) -> NSBezierPath {
    let p = NSBezierPath(); p.move(to: points[0]); points.dropFirst().forEach { p.line(to: $0) }; p.close(); return p
}

let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = rr(tile, 185)

// Drop shadow under the tile
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow(); shadow.shadowColor = c(0, 0.35); shadow.shadowBlurRadius = 24; shadow.shadowOffset = NSSize(width: 0, height: -10)
shadow.set(); c(0xFFFFFF).setFill(); shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Three 45° bands, split where x - y = ±220: Windows top left, Mac across the middle, Linux bottom right
let edge: CGFloat = 220
let winBand = poly([NSPoint(x: 0, y: edge), NSPoint(x: 0, y: size), NSPoint(x: size - edge, y: size)])
let linuxBand = poly([NSPoint(x: edge, y: 0), NSPoint(x: size, y: 0), NSPoint(x: size, y: size - edge)])
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(starting: c(0xF7F0E3), ending: c(0xDCCDB3))!.draw(in: tile, angle: -45)
for (band, from, to) in [(winBand, 0x3A9BF0, 0x0F5AB4), (linuxBand, 0xFFD34E, 0xF0A020)] {
    NSGraphicsContext.saveGraphicsState()
    band.addClip()
    NSGradient(starting: c(from), ending: c(to))!.draw(in: tile, angle: -45)
    NSGraphicsContext.restoreGraphicsState()
}
// White seams between the bands
c(0xFFFFFF, 0.9).setStroke()
for d in [-edge, edge] {
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: max(0, d), y: max(0, -d))); seam.line(to: NSPoint(x: min(size, size + d), y: min(size, size - d)))
    seam.lineWidth = 12; seam.stroke()
}
NSGraphicsContext.restoreGraphicsState()

// Windows: four panes (top left corner band)
do {
    let s: CGFloat = 102, gap: CGFloat = 14, center = NSPoint(x: 285, y: 739)
    let ox = center.x - s - gap / 2, oy = center.y - s - gap / 2
    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        c(0xFFFFFF, 0.95).setFill()
        NSBezierPath(rect: NSRect(x: ox + CGFloat(dx) * (s + gap), y: oy + CGFloat(dy) * (s + gap), width: s, height: s)).fill()
    }
}

// Mac: a classic compact Mac with a smiling screen (middle band)
do {
    NSGraphicsContext.saveGraphicsState()
    let mid = NSPoint(x: 512, y: 512)
    let grow = NSAffineTransform() // as large as the middle band allows (width + height ≤ 2 × 220)
    grow.translateX(by: mid.x, yBy: mid.y); grow.scale(by: 1.09); grow.translateX(by: -mid.x, yBy: -mid.y); grow.concat()
    let o = NSPoint(x: mid.x - 85, y: mid.y - 94)
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

// Linux: Tux (bottom right corner band)
do {
    let svg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Tux.svg")
    guard let tux = NSImage(contentsOf: svg) else { fatalError("Tux.svg missing next to MacaroonIcon.swift") }
    let h: CGFloat = 260, w = h * tux.size.width / tux.size.height
    tux.draw(in: NSRect(x: 739 - w / 2, y: 285 - h / 2, width: w, height: h))
}

// Thin rim
c(0, 0.25).setStroke(); shape.lineWidth = 3; shape.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
