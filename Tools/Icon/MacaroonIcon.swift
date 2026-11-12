// Draws Macaroon's app icon: a macaroon over four quadrants, one per guest it runs:
// Mac (a classic compact Mac), Windows (four panes), Linux (a penguin) and NeXT (the black cube).
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
for (r, top, bottom) in [(mac, 0xF3EBDD, 0xDCCDB3), (win, 0x2D8CEB, 0x0F5AB4), (linux, 0xFFD34E, 0xF0A020), (next, 0x3A3A3A, 0x0E0E0E)] {
    NSGradient(starting: c(top), ending: c(bottom))!.draw(in: r, angle: -90)
}
NSGraphicsContext.restoreGraphicsState()

// Mac: a classic compact Mac with a smiling screen (top left)
do {
    let o = NSPoint(x: mac.minX + 95, y: mac.minY + 120)
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
}

// Windows: four panes (top right)
do {
    let s: CGFloat = 92, gap: CGFloat = 12, ox = win.midX - s - gap / 2 + 25, oy = win.midY - s - gap / 2 + 20
    for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
        c(0xFFFFFF, 0.95).setFill()
        NSBezierPath(rect: NSRect(x: ox + CGFloat(dx) * (s + gap), y: oy + CGFloat(dy) * (s + gap), width: s, height: s)).fill()
    }
}

// Linux: a penguin (bottom left)
do {
    let cx = linux.midX - 30, by = linux.minY + 95
    c(0x1B1B1B).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 80, y: by, width: 160, height: 200)).fill() // body
    NSBezierPath(ovalIn: NSRect(x: cx - 58, y: by + 160, width: 116, height: 110)).fill() // head
    c(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 55, y: by + 15, width: 110, height: 150)).fill() // belly
    NSBezierPath(ovalIn: NSRect(x: cx - 34, y: by + 205, width: 26, height: 32)).fill() // eyes
    NSBezierPath(ovalIn: NSRect(x: cx + 8, y: by + 205, width: 26, height: 32)).fill()
    c(0x1B1B1B).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 24, y: by + 212, width: 12, height: 14)).fill()
    NSBezierPath(ovalIn: NSRect(x: cx + 14, y: by + 212, width: 12, height: 14)).fill()
    c(0xF7A21B).setFill()
    let beak = NSBezierPath(); beak.move(to: NSPoint(x: cx - 22, y: by + 200)); beak.line(to: NSPoint(x: cx + 22, y: by + 200))
    beak.line(to: NSPoint(x: cx, y: by + 178)); beak.close(); beak.fill()
    NSBezierPath(ovalIn: NSRect(x: cx - 78, y: by - 14, width: 64, height: 30)).fill() // feet
    NSBezierPath(ovalIn: NSRect(x: cx + 14, y: by - 14, width: 64, height: 30)).fill()
}

// NeXT: the black cube, tilted, with "NeXT" on its front face (bottom right)
do {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: next.midX + 30, yBy: next.midY - 30); t.rotate(byDegrees: 28); t.concat()
    let a: CGFloat = 92, d: CGFloat = 40
    func poly(_ p: [NSPoint]) -> NSBezierPath { let b = NSBezierPath(); b.move(to: p[0]); p.dropFirst().forEach { b.line(to: $0) }; b.close(); return b }
    let front = poly([NSPoint(x: -a, y: -a), NSPoint(x: a, y: -a), NSPoint(x: a, y: a), NSPoint(x: -a, y: a)])
    let side = poly([NSPoint(x: -a, y: a), NSPoint(x: -a - d, y: a - d), NSPoint(x: -a - d, y: -a - d), NSPoint(x: -a, y: -a)])
    let bottom = poly([NSPoint(x: -a, y: -a), NSPoint(x: -a - d, y: -a - d), NSPoint(x: a - d, y: -a - d), NSPoint(x: a, y: -a)])
    for (p, g) in [(side, 0x050505), (bottom, 0x050505), (front, 0x111111)] {
        c(g).setFill(); p.fill(); c(0x8A8A8A).setStroke(); p.lineWidth = 3; p.stroke()
    }
    let font = NSFont(name: "Helvetica-Bold", size: 86) ?? .boldSystemFont(ofSize: 86)
    for (text, x, y, colour) in [("N", -76, 0, 0xE8E8E8), ("e", 6, 0, 0xB0B0B0), ("X", -76, -86, 0x9A9A9A), ("T", 6, -86, 0xD0D0D0)] {
        (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: c(colour)])
    }
    NSGraphicsContext.restoreGraphicsState()
}

// The macaroon in the middle, over all four
do {
    let cx: CGFloat = 512, cy: CGFloat = 512, w: CGFloat = 330
    NSGraphicsContext.saveGraphicsState()
    let sh = NSShadow(); sh.shadowColor = c(0, 0.4); sh.shadowBlurRadius = 22; sh.shadowOffset = NSSize(width: 0, height: -12); sh.set()
    func shell(_ y: CGFloat, top: Bool) {
        let r = NSRect(x: cx - w / 2, y: y, width: w, height: 105)
        let p = rr(r, 52)
        NSGradient(starting: c(top ? 0xFFB3C9 : 0xF58BAA), ending: c(top ? 0xF27CA0 : 0xE0628C))!.draw(in: p, angle: -90)
        // the macaroon "foot": a ruffled band where the shell meets the filling
        let footY = top ? r.minY : r.maxY - 18
        let foot = NSBezierPath()
        foot.move(to: NSPoint(x: r.minX + 18, y: footY + 9))
        var x = r.minX + 18
        while x < r.maxX - 18 { foot.appendOval(in: NSRect(x: x, y: footY + 2, width: 18, height: 14)); x += 15 }
        c(top ? 0xE8749A : 0xD65A84).setFill(); foot.fill()
    }
    shell(cy + 22, top: true)
    shell(cy - 127, top: false)
    NSGraphicsContext.restoreGraphicsState()
    let cream = rr(NSRect(x: cx - w / 2 + 14, y: cy - 30, width: w - 28, height: 60), 30)
    NSGradient(starting: c(0xFFF8EC), ending: c(0xF2E2C4))!.draw(in: cream, angle: -90)
    // highlight on the top shell
    c(0xFFFFFF, 0.45).setFill()
    NSBezierPath(ovalIn: NSRect(x: cx - 110, y: cy + 92, width: 120, height: 22)).fill()
}

// Thin rim
c(0, 0.25).setStroke(); shape.lineWidth = 3; shape.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
