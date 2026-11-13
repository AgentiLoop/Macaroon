// NeXT Calculator for MacCube: the NeXTSTEP Calculator, square black-titled window, recessed display,
// bevelled grey keys in Helvetica. Keys: digits . + - * / = Return, Esc or C (clear), Backspace,
// Cmd+C / Cmd+V copy and paste the display, Cmd+Q quits.
import AppKit

let face = NSColor(calibratedWhite: 0.667, alpha: 1)
let dark = NSColor(calibratedWhite: 0.333, alpha: 1)
let keyFont = NSFont(name: "Helvetica-Bold", size: 14) ?? .boldSystemFont(ofSize: 14)
let titleFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
let displayFont = NSFont(name: "Helvetica", size: 22) ?? .systemFont(ofSize: 22)

func fill(_ color: NSColor, _ rect: NSRect) { color.setFill(); rect.fill() }

/// NeXT's bevel: raised (white top/left, black bottom/right) or sunken (the reverse), with a dark inner edge.
func bevel(_ r: NSRect, sunken: Bool = false, color: NSColor = face) {
    fill(color, r)
    let light = sunken ? dark : NSColor.white, shadow = sunken ? NSColor.white : NSColor.black
    fill(light, NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1))
    fill(light, NSRect(x: r.minX, y: r.minY, width: 1, height: r.height))
    fill(shadow, NSRect(x: r.minX, y: r.minY, width: r.width, height: 1))
    fill(shadow, NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height))
    if !sunken {
        fill(dark, NSRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 1))
        fill(dark, NSRect(x: r.maxX - 2, y: r.minY + 1, width: 1, height: r.height - 2))
    }
}

func centered(_ text: String, in r: NSRect, font: NSFont, color: NSColor = .black) {
    let size = (text as NSString).size(withAttributes: [.font: font])
    (text as NSString).draw(at: NSPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: [.font: font, .foregroundColor: color])
}

// MARK: Arithmetic

final class Engine {
    private(set) var display = "0"
    private var total: Double?
    private var op: String?
    private var fresh = true

    func press(_ key: String) {
        switch key {
        case "0"..."9", ".":
            if fresh { display = "0"; fresh = false }
            if key == "." && display.contains(".") { return }
            display = display == "0" && key != "." ? key : display + key
        case "C": display = "0"; total = nil; op = nil; fresh = true
        case "CE": display = "0"; fresh = true
        case "±": if display != "0" { display = display.hasPrefix("-") ? String(display.dropFirst()) : "-" + display }
        case "√": show(sqrt(value))
        case "%": show(value / 100)
        case "+", "−", "×", "÷", "=":
            if let op, let total, !(fresh && key != "=") {
                switch op {
                case "+": show(total + value)
                case "−": show(total - value)
                case "×": show(total * value)
                default: show(value == 0 ? .nan : total / value)
                }
            }
            total = value
            op = key == "=" ? nil : key
            fresh = true
        default: break
        }
    }

    func backspace() {
        guard !fresh else { return }
        display = String(display.dropLast())
        if display.isEmpty || display == "-" { display = "0" }
    }

    func paste(_ text: String) {
        guard let number = Double(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")) else { return NSSound.beep() }
        show(number)
        fresh = false
    }

    private var value: Double { Double(display) ?? 0 }

    private func show(_ v: Double) {
        if !v.isFinite { display = "Error" }
        else if v == v.rounded(), abs(v) < 1e15 { display = String(format: "%.0f", v) }
        else { display = String(format: "%.10g", v) }
        fresh = true
    }
}

// MARK: Window

final class CalculatorView: NSView {
    let engine = Engine()
    static let keys = [["C", "CE", "√", "÷"], ["7", "8", "9", "×"], ["4", "5", "6", "−"], ["1", "2", "3", "+"], ["0", ".", "±", "="]]
    static let titleHeight: CGFloat = 23, keyWidth: CGFloat = 52, keyHeight: CGFloat = 36, pad: CGFloat = 8
    static let size = NSSize(width: pad * 2 + keyWidth * 4, height: titleHeight + pad * 3 + 44 + keyHeight * 5)
    private var pressed: String?

    private var titleBar: NSRect { NSRect(x: 0, y: bounds.height - Self.titleHeight, width: bounds.width, height: Self.titleHeight) }
    private var closeBox: NSRect { NSRect(x: bounds.maxX - 19, y: titleBar.minY + 4, width: 15, height: 15) }
    private var miniaturizeBox: NSRect { NSRect(x: 4, y: titleBar.minY + 4, width: 15, height: 15) }
    private var displayRect: NSRect { NSRect(x: Self.pad, y: titleBar.minY - Self.pad - 44, width: bounds.width - Self.pad * 2, height: 44) }

    private func keyRect(_ row: Int, _ col: Int) -> NSRect {
        NSRect(x: Self.pad + CGFloat(col) * Self.keyWidth, y: displayRect.minY - Self.pad - CGFloat(row + 1) * Self.keyHeight, width: Self.keyWidth, height: Self.keyHeight)
    }

    private func key(at p: NSPoint) -> String? {
        for (row, keys) in Self.keys.enumerated() { for (col, key) in keys.enumerated() where keyRect(row, col).contains(p) { return key } }
        return nil
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(.black, bounds) // the one-pixel window frame
        fill(face, bounds.insetBy(dx: 1, dy: 1))
        let key = window?.isKeyWindow == true
        fill(key ? .black : dark, titleBar)
        centered("Calculator", in: titleBar, font: titleFont, color: key ? .white : face)
        bevel(miniaturizeBox)
        NSColor.black.setStroke()
        NSBezierPath(rect: miniaturizeBox.insetBy(dx: 4.5, dy: 4.5)).stroke()
        bevel(closeBox)
        let x = NSBezierPath(), r = closeBox.insetBy(dx: 4, dy: 4)
        x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
        x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
        x.lineWidth = 1.5
        x.stroke()

        // Recessed display, black digits right-aligned on light grey
        bevel(displayRect, sunken: true, color: NSColor(calibratedWhite: 0.88, alpha: 1))
        let text = engine.display as NSString
        let size = text.size(withAttributes: [.font: displayFont])
        text.draw(at: NSPoint(x: displayRect.maxX - 10 - size.width, y: displayRect.midY - size.height / 2), withAttributes: [.font: displayFont])

        for (row, keys) in Self.keys.enumerated() {
            for (col, k) in keys.enumerated() {
                let rect = keyRect(row, col).insetBy(dx: 1, dy: 1)
                let isOp = "÷×−+=".contains(k), isClear = k == "C" || k == "CE"
                bevel(rect, sunken: k == pressed, color: k == pressed ? .white : isOp ? NSColor(calibratedWhite: 0.55, alpha: 1) : face)
                centered(k, in: rect, font: keyFont, color: isClear ? NSColor(calibratedWhite: 0.15, alpha: 1) : .black)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if closeBox.contains(p) { return NSApp.terminate(nil) }
        if miniaturizeBox.contains(p) { return window.miniaturize(nil) }
        if titleBar.contains(p) { return window.performDrag(with: event) }
        guard let k = key(at: p) else { return }
        flash(k)
    }

    private func flash(_ k: String) {
        pressed = k
        engine.press(k)
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.pressed = nil
            self?.needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        let chars = event.charactersIgnoringModifiers ?? ""
        if event.modifierFlags.contains(.command) {
            switch chars {
            case "c":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(engine.display, forType: .string)
            case "v": engine.paste(NSPasteboard.general.string(forType: .string) ?? ""); needsDisplay = true
            case "q": NSApp.terminate(nil)
            case "w": NSApp.terminate(nil)
            default: super.keyDown(with: event)
            }
            return
        }
        let map = ["*": "×", "x": "×", "/": "÷", "-": "−", "+": "+", "=": "=", "\r": "=", "\u{3}": "=", ".": ".", ",": ".", "%": "%", "c": "C", "\u{1b}": "C"]
        if let first = chars.first, first.isNumber { flash(String(first)) }
        else if let k = map[chars] { flash(k) }
        else if event.keyCode == 51 { engine.backspace(); needsDisplay = true }
        else { super.keyDown(with: event) }
    }
}

final class CalculatorWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func becomeKey() { super.becomeKey(); contentView?.needsDisplay = true }
    override func resignKey() { super.resignKey(); contentView?.needsDisplay = true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let window = CalculatorWindow(contentRect: NSRect(origin: .zero, size: CalculatorView.size), styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let view = CalculatorView(frame: NSRect(origin: .zero, size: CalculatorView.size))
        window.contentView = view
        window.hasShadow = true
        window.title = "Calculator"
        window.setFrameAutosaveName("NeXT Calculator")
        if !window.setFrameUsingName("NeXT Calculator") { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
