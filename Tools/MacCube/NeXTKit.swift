// NeXTKit: the NeXTSTEP look shared by the MacCube apps (NeXT Browser, NeXT Edit, NeXT Terminal): colours and
// fonts, bevels, buttons, the sunken status line, the square NeXT window with its black title bar and resize bar,
// and closure-based menu items. Compiled together with each app's own file (see build.sh).
import AppKit

let face = NSColor(calibratedWhite: 0.667, alpha: 1)
let dark = NSColor(calibratedWhite: 0.333, alpha: 1)
let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
let boldFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)

func fill(_ color: NSColor, _ rect: NSRect) { color.setFill(); rect.fill() }

/// NeXT's bevel: raised (white top/left, black bottom/right, dark inner edge) or sunken (the reverse).
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

// MARK: NeXT controls

final class NeXTButton: NSView {
    var title: String { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { needsDisplay = true } }
    let action: () -> Void
    private var pressed = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        bevel(bounds, sunken: pressed, color: pressed ? .white : face)
        centered(title, in: bounds, font: boldFont, color: isEnabled ? .black : dark)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        var inside = true
        pressed = true
        display()
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            inside = bounds.contains(convert(next.locationInWindow, from: nil))
            pressed = inside && next.type == .leftMouseDragged
            display()
            if next.type == .leftMouseUp { break }
        }
        if inside { action() }
    }
}

/// The sunken status line along the bottom of the window.
final class StatusLine: NSView {
    var text = "" { didSet { needsDisplay = true } }
    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds)
        let well = bounds.insetBy(dx: 4, dy: 2)
        bevel(well, sunken: true, color: wellColor)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let height = (text as NSString).size(withAttributes: [.font: font]).height
        (text as NSString).draw(in: NSRect(x: well.minX + 6, y: well.midY - height / 2, width: well.width - 12, height: height),
                                withAttributes: [.font: font, .paragraphStyle: style])
    }
}

/// A square, sunken grey well that holds the address field, drawn exactly like the status line's well.
let wellColor = NSColor(calibratedWhite: 0.75, alpha: 1)
final class SunkenWell: NSView {
    override func draw(_ dirtyRect: NSRect) { bevel(bounds, sunken: true, color: wellColor) }
}

// MARK: NeXT window

final class NeXTWindow: NSWindow {
    static let titleHeight: CGFloat = 23, resizeHeight: CGFloat = 9
    let body: NSView
    private let titleBar = TitleBar()

    init(body size: NSSize) {
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height + NeXTWindow.titleHeight + NeXTWindow.resizeHeight)
        body = NSView(frame: NSRect(x: 0, y: NeXTWindow.resizeHeight, width: size.width, height: size.height))
        super.init(contentRect: frame, styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        hasShadow = true
        let frameView = NSView(frame: frame)
        body.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.layer?.backgroundColor = face.cgColor
        titleBar.frame = NSRect(x: 0, y: frame.height - NeXTWindow.titleHeight, width: frame.width, height: NeXTWindow.titleHeight)
        titleBar.autoresizingMask = [.width, .minYMargin]
        let resizeBar = ResizeBar(frame: NSRect(x: 0, y: 0, width: frame.width, height: NeXTWindow.resizeHeight))
        resizeBar.autoresizingMask = [.width, .maxYMargin]
        [body, titleBar, resizeBar].forEach { frameView.addSubview($0) }
        contentView = frameView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var title: String { didSet { titleBar.needsDisplay = true } }
    override func becomeKey() { super.becomeKey(); titleBar.needsDisplay = true }
    override func resignKey() { super.resignKey(); titleBar.needsDisplay = true }
    /// Asks the delegate first (NeXT Edit's "save changes?"), then closes.
    override func performClose(_ sender: Any?) { if delegate?.windowShouldClose?(self) ?? true { close() } }
    /// A borderless window isn't made key by a click when its app was opened in the background (from NeXT
    /// Workspace's Dock, which never activates itself), so typing went nowhere. Take the click as activation.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        super.sendEvent(event)
    }
}

final class TitleBar: NSView {
    private var miniaturizeBox: NSRect { NSRect(x: 4, y: 4, width: 15, height: 15) }
    private var closeBox: NSRect { NSRect(x: bounds.maxX - 19, y: 4, width: 15, height: 15) }

    override func draw(_ dirtyRect: NSRect) {
        let key = window?.isKeyWindow == true
        fill(key ? .black : dark, bounds)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let title = (window?.title ?? "") as NSString
        let height = title.size(withAttributes: [.font: boldFont]).height
        title.draw(in: NSRect(x: 24, y: floor((bounds.height - height) / 2), width: bounds.width - 48, height: height),
                   withAttributes: [.font: boldFont, .foregroundColor: key ? NSColor.white : face, .paragraphStyle: style])
        bevel(miniaturizeBox)
        NSColor.black.setStroke()
        NSBezierPath(rect: miniaturizeBox.insetBy(dx: 4.5, dy: 4.5)).stroke()
        bevel(closeBox)
        let x = NSBezierPath(), r = closeBox.insetBy(dx: 4, dy: 4)
        x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
        x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
        x.lineWidth = 1.5
        x.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let point = convert(event.locationInWindow, from: nil)
        if closeBox.contains(point) { return window.performClose(nil) }
        if miniaturizeBox.contains(point) { return window.miniaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.performDrag(with: event)
    }
}

/// NeXT's resize bar: the end segments also resize the width, the middle only the height.
final class ResizeBar: NSView {
    private let corner: CGFloat = 28

    override func draw(_ dirtyRect: NSRect) {
        bevel(bounds)
        for x in [corner, bounds.maxX - corner] {
            fill(.black, NSRect(x: x, y: 0, width: 1, height: bounds.height))
            fill(.white, NSRect(x: x + 1, y: 1, width: 1, height: bounds.height - 2))
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let left = x < corner, right = x > bounds.maxX - corner
        let start = NSEvent.mouseLocation, frame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            var f = frame
            f.size.height = max(window.minSize.height, frame.height + start.y - p.y)
            f.origin.y = frame.maxY - f.height
            if right { f.size.width = max(window.minSize.width, frame.width + p.x - start.x) }
            if left {
                f.size.width = max(window.minSize.width, frame.width - (p.x - start.x))
                f.origin.x = frame.maxX - f.width
            }
            window.setFrame(f, display: true)
        }
    }
}

// MARK: Menus

/// A menu item that runs a closure.
final class Item: NSMenuItem {
    let run: () -> Void
    init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc func fire() { run() }
}

func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
    let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    let menu = NSMenu(title: title)
    items.forEach(menu.addItem)
    top.submenu = menu
    return top
}

/// Standard responder-chain items (Cut, Copy…) work in both the address field and the page.
func responder(_ title: String, _ action: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
}

// MARK: NeXT scroll view

/// A scroll view with NeXT's scroller on the left (NSScrollView puts it on the right).
final class NeXTScrollView: NSScrollView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        verticalScroller = NeXTScroller()
        hasVerticalScroller = true
        hasHorizontalScroller = false
        scrollerStyle = .legacy
        autohidesScrollers = false
        borderType = .noBorder
    }
    required init?(coder: NSCoder) { fatalError() }

    override func tile() {
        super.tile()
        guard let scroller = verticalScroller else { return }
        var bar = scroller.frame, content = contentView.frame
        bar.origin.x = 0
        content.origin.x = bar.width
        scroller.frame = bar
        contentView.frame = content
    }
}

/// NeXT's vertical scroller, drawn and tracked here: dark track, bevelled knob, both arrow buttons at the bottom
/// with the black line between it and the content.
final class NeXTScroller: NSScroller {
    static let bar: CGFloat = 18
    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { bar + 1 }
    override class var isCompatibleWithOverlayScrollers: Bool { false }
    override var isFlipped: Bool { false }

    private let bar = NeXTScroller.bar
    private var downButton: NSRect { NSRect(x: 0, y: 0, width: bar, height: bar) }
    private var upButton: NSRect { NSRect(x: 0, y: bar, width: bar, height: bar) }
    private var track: NSRect { NSRect(x: 0, y: 2 * bar, width: bar, height: max(0, bounds.height - 2 * bar)) }
    private var scrollable: Bool { knobProportion < 1 && (scrollView.map { $0.documentView?.frame.height ?? 0 > $0.contentView.bounds.height } ?? false) }
    private var knob: NSRect {
        let height = min(track.height, max(bar, track.height * knobProportion))
        return NSRect(x: 0, y: track.maxY - height - (track.height - height) * doubleValue, width: bar, height: height)
    }
    private var scrollView: NSScrollView? { superview as? NSScrollView }

    override func draw(_ dirtyRect: NSRect) {
        fill(dark, track)
        if scrollable { bevel(knob.insetBy(dx: 1, dy: 1)) }
        for (button, up) in [(upButton, true), (downButton, false)] {
            bevel(button)
            let t = NSBezierPath(), x = button.midX, y = button.midY
            t.move(to: NSPoint(x: x - 4, y: up ? y - 3 : y + 3))
            t.line(to: NSPoint(x: x, y: up ? y + 3 : y - 3))
            t.line(to: NSPoint(x: x + 4, y: up ? y - 3 : y + 3))
            t.close()
            NSColor.black.setFill()
            t.fill()
        }
        fill(.black, NSRect(x: bar, y: 0, width: 1, height: bounds.height))
    }

    /// Scrolls the content so its top is at `top` points (clamped).
    private func scroll(to top: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxTop = max(0, document.frame.height - clip.bounds.height)
        let y = min(maxTop, max(0, top))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: document.isFlipped ? y : maxTop - y))
        scrollView.reflectScrolledClipView(clip)
    }

    private var top: CGFloat {
        guard let scrollView, let document = scrollView.documentView else { return 0 }
        let clip = scrollView.contentView
        return document.isFlipped ? clip.bounds.minY : document.frame.height - clip.bounds.maxY
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let scrollView else { return }
        let p = convert(event.locationInWindow, from: nil)
        if upButton.contains(p) || downButton.contains(p) {
            // Arrow buttons step a line and repeat while held
            let step = (upButton.contains(p) ? -1 : 1) * max(scrollView.verticalLineScroll, 16)
            scroll(to: top + step)
            while window.nextEvent(matching: .leftMouseUp, until: Date(timeIntervalSinceNow: 0.06), inMode: .eventTracking, dequeue: true) == nil {
                scroll(to: top + step)
            }
            return
        }
        guard scrollable, let document = scrollView.documentView else { return }
        let maxTop = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let grab = knob.contains(p) ? knob.maxY - p.y : knob.height / 2
        func move(_ y: CGFloat) { scroll(to: (track.maxY - (y + grab)) / max(track.height - knob.height, 1) * maxTop) }
        move(p.y)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            move(convert(next.locationInWindow, from: nil).y)
        }
    }
}
