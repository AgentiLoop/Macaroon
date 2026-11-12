// NeXT Workspace for TinyMacII, after NeXTSTEP 3:
// • Dock: a column of 64-pt tiles on the right edge. Workspace cube on top (double-click: File Viewer), apps
//   (double-click to launch, "…" when not running, drop apps on it to add them), Recycler at the bottom.
// • Main menu: vertical, top left. Submenus cascade to the right as more columns; drag a submenu by its black
//   title to tear it off (it gets a close box). Shows the front app's real menus through Accessibility
//   (needs Privacy & Security > Accessibility), or the Workspace's own menus when a File Viewer is in front.
// • File Viewer: shelf, icon path, NeXT-drawn column browser. Inspector shows the selection's details.
import AppKit
import ApplicationServices

let tileSize: CGFloat = 64
let rowHeight: CGFloat = 20
let menuWidth: CGFloat = 150
let face = NSColor(calibratedWhite: 0.667, alpha: 1)
let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
let smallFont = NSFont(name: "Helvetica", size: 11) ?? .systemFont(ofSize: 11)
let boldFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
let trashPath = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash")

func fill(_ color: NSColor, _ rect: NSRect) { color.setFill(); rect.fill() }

/// NeXT's raised bevel: white top and left edges, black bottom and right, dark grey inner shadow.
/// Works in flipped views too (the browser), where "top" is the low y.
func bevel(_ r: NSRect) {
    let flipped = NSGraphicsContext.current?.isFlipped == true
    let top = flipped ? r.minY : r.maxY - 1, bottom = flipped ? r.maxY - 1 : r.minY, inner = flipped ? r.maxY - 2 : r.minY + 1
    fill(face, r)
    fill(.white, NSRect(x: r.minX, y: top, width: r.width, height: 1))
    fill(.white, NSRect(x: r.minX, y: r.minY, width: 1, height: r.height))
    fill(.black, NSRect(x: r.minX, y: bottom, width: r.width, height: 1))
    fill(.black, NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height))
    let shade = NSColor(calibratedWhite: 0.333, alpha: 1)
    fill(shade, NSRect(x: r.minX + 1, y: inner, width: r.width - 2, height: 1))
    fill(shade, NSRect(x: r.maxX - 2, y: r.minY + 1, width: 1, height: r.height - 2))
}

/// A centred, middle-truncated label under an icon.
func drawLabel(_ text: String, in rect: NSRect) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingMiddle
    (text as NSString).draw(in: rect, withAttributes: [.font: smallFont, .paragraphStyle: style, .foregroundColor: NSColor.black])
}

func isFolder(_ path: String) -> Bool {
    var directory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        && !NSWorkspace.shared.isFilePackage(atPath: path)
}

/// NeXTSTEP-style icons for the shelf and icon path: the root is a NeXT disk, folders are NeXT's flat grey
/// folders (black outline, white top-left edge, dark shadow; the home folder has a house on it). Anything
/// else keeps its own icon.
func drawNeXTIcon(_ path: String, in r: NSRect) {
    func outlined(_ shape: NSBezierPath, _ white: CGFloat) {
        NSColor(calibratedWhite: white, alpha: 1).setFill()
        shape.fill()
        NSColor.black.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
    let u = r.width / 48, x = r.minX, y = r.minY
    func rect(_ a: CGFloat, _ b: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x + a * u, y: y + b * u, width: w * u, height: h * u)
    }

    if path == "/" { // the disk: a dark slab with a light label and an access slot
        fill(NSColor(calibratedWhite: 0.15, alpha: 1), rect(5, 9, 40, 28)) // shadow
        outlined(NSBezierPath(rect: rect(3, 11, 40, 28)), 0.33)
        fill(NSColor(calibratedWhite: 0.55, alpha: 1), rect(4, 38, 38, 1))
        outlined(NSBezierPath(rect: rect(8, 24, 30, 11)), 0.85)
        fill(.black, rect(8, 16, 18, 2))
        fill(NSColor(calibratedWhite: 0.7, alpha: 1), rect(36, 15, 3, 3))
        return
    }
    guard isFolder(path) else { return NSWorkspace.shared.icon(forFile: path).draw(in: r) }

    // Back of the folder with its tab, then the front panel slightly lower; a drop shadow under both
    fill(NSColor(calibratedWhite: 0.2, alpha: 1), rect(6, 6, 40, 30))
    let back = NSBezierPath()
    back.move(to: NSPoint(x: x + 3 * u, y: y + 10 * u))
    back.line(to: NSPoint(x: x + 3 * u, y: y + 40 * u))
    back.line(to: NSPoint(x: x + 6 * u, y: y + 43 * u))
    back.line(to: NSPoint(x: x + 18 * u, y: y + 43 * u))
    back.line(to: NSPoint(x: x + 21 * u, y: y + 38 * u))
    back.line(to: NSPoint(x: x + 43 * u, y: y + 38 * u))
    back.line(to: NSPoint(x: x + 43 * u, y: y + 10 * u))
    back.close()
    outlined(back, 0.6)
    let front = NSBezierPath(rect: rect(3, 8, 40, 26))
    outlined(front, 0.8)
    fill(.white, rect(4, 33, 38, 1)) // NeXT bevel: white top and left, grey bottom and right
    fill(.white, rect(4, 9, 1, 24))
    fill(NSColor(calibratedWhite: 0.5, alpha: 1), rect(4, 9, 38, 1))
    fill(NSColor(calibratedWhite: 0.5, alpha: 1), rect(41, 9, 1, 24))

    if path == NSHomeDirectory() { // a little house on the home folder
        let house = NSBezierPath()
        house.move(to: NSPoint(x: x + 16 * u, y: y + 13 * u))
        house.line(to: NSPoint(x: x + 16 * u, y: y + 21 * u))
        house.line(to: NSPoint(x: x + 13 * u, y: y + 21 * u))
        house.line(to: NSPoint(x: x + 23 * u, y: y + 29 * u))
        house.line(to: NSPoint(x: x + 33 * u, y: y + 21 * u))
        house.line(to: NSPoint(x: x + 30 * u, y: y + 21 * u))
        house.line(to: NSPoint(x: x + 30 * u, y: y + 13 * u))
        house.close()
        outlined(house, 1)
        fill(.black, rect(21, 13, 4, 6)) // door
    }
}

func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    // The widget layer (as in StarPlayrX's torn-off panel): desktop icons + 2, where macOS puts its own desktop
    // widgets. Behind every app window, on every Space, staying put for Show Desktop.
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 2)
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    p.hidesOnDeactivate = false
    p.isReleasedWhenClosed = false
    p.orderFrontRegardless()
    return p
}

// MARK: Accessibility helpers

func axValue(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(e, attribute as CFString, &value) == .success ? value : nil
}
func axChildren(_ e: AXUIElement) -> [AXUIElement] { axValue(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
func axString(_ e: AXUIElement, _ attribute: String) -> String? { axValue(e, attribute) as? String }

// MARK: Dock

enum DockApps {
    static let standard = ["/System/Library/CoreServices/Finder.app", NSHomeDirectory() + "/Applications/NeXT Browser.app", "/System/Applications/Mail.app",
                           NSHomeDirectory() + "/Applications/NeXT Edit.app", NSHomeDirectory() + "/Applications/NeXT Terminal.app",
                           NSHomeDirectory() + "/Applications/NeXT Calculator.app", "/System/Applications/System Settings.app"]
    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "DockApps") ?? standard.filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "DockApps") }
    }
}

/// NeXTSTEP-style Dock icons, drawn in greys with black outlines and a hard drop shadow on a 48-unit grid:
/// File Viewer, OmniWeb-style globe (Safari), NeXTmail envelope (Mail), Edit's page and pencil (TextEdit),
/// Terminal's monitor, Calculator, Preferences' sliders (System Settings) and the Recycler. Other apps get
/// their own icon in greyscale.
enum NeXTIcons {
    private static var r = NSRect.zero
    private static func u(_ v: CGFloat) -> CGFloat { v * r.width / 48 }
    private static func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: r.minX + u(x), y: r.minY + u(y), width: u(w), height: u(h))
    }
    private static func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: r.minX + u(x), y: r.minY + u(y)) }
    private static func grey(_ w: CGFloat) -> NSColor { NSColor(calibratedWhite: w, alpha: 1) }
    /// Fills a shape with a grey, outlines it in black; `shadow` first drops a dark copy down and right.
    private static func shape(_ p: NSBezierPath, _ white: CGFloat, shadow: Bool = false, line: CGFloat = 1) {
        if shadow {
            let s = p.copy() as! NSBezierPath
            s.transform(using: AffineTransform(translationByX: u(2), byY: -u(2)))
            grey(0.15).setFill()
            s.fill()
        }
        grey(white).setFill()
        p.fill()
        NSColor.black.setStroke()
        p.lineWidth = line
        p.stroke()
    }
    private static func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ white: CGFloat, shadow: Bool = false) {
        shape(NSBezierPath(rect: rect(x, y, w, h)), white, shadow: shadow)
    }
    private static func line(_ x1: CGFloat, _ y1: CGFloat, _ x2: CGFloat, _ y2: CGFloat, width: CGFloat = 1, white: CGFloat = 0) {
        let p = NSBezierPath()
        p.move(to: point(x1, y1)); p.line(to: point(x2, y2))
        p.lineWidth = width
        grey(white).setStroke()
        p.stroke()
    }

    static func draw(app path: String, in area: NSRect) {
        if !draw(identifier: Bundle(path: path)?.bundleIdentifier, in: area) { greyscale(NSWorkspace.shared.icon(forFile: path), in: area) }
    }

    /// Draws the NeXT icon for an app by bundle identifier; false when there isn't one.
    @discardableResult
    static func draw(identifier: String?, in area: NSRect) -> Bool {
        r = area
        switch identifier {
        case "com.apple.finder": drawNeXTIcon(NSHomeDirectory(), in: area)
        case "com.apple.Safari", "com.macaroon.NeXTBrowser": globe()
        case "com.apple.mail": mail()
        case "com.apple.TextEdit", "com.macaroon.NeXTEdit": edit()
        case "com.apple.Terminal", "com.macaroon.NeXTTerminal": terminal()
        case "com.apple.calculator", "com.macaroon.NeXTCalculator": calculator()
        case "com.apple.systempreferences": preferences()
        default: return false
        }
        return true
    }

    private static func globe() {
        let ball = NSBezierPath(ovalIn: rect(5, 5, 38, 38))
        shape(ball, 0.6, shadow: true)
        NSGraphicsContext.saveGraphicsState()
        ball.addClip()
        grey(0.85).setFill() // highlight, top left
        NSBezierPath(ovalIn: rect(9, 24, 14, 14)).fill()
        NSColor.black.setStroke()
        for w: CGFloat in [12, 26] { // meridians
            let m = NSBezierPath(ovalIn: rect(24 - w / 2, 5, w, 38)); m.lineWidth = 1; m.stroke()
        }
        for y: CGFloat in [14, 24, 34] { line(5, y, 43, y) } // parallels
        NSGraphicsContext.restoreGraphicsState()
        ball.lineWidth = 1.5
        ball.stroke()
    }

    private static func mail() {
        box(4, 11, 40, 26, 0.9, shadow: true)
        let flap = NSBezierPath()
        flap.move(to: point(4, 37)); flap.line(to: point(24, 22)); flap.line(to: point(44, 37))
        NSColor.black.setStroke(); flap.lineWidth = 1; flap.stroke()
        line(4, 11, 18, 26); line(44, 11, 30, 26)
        box(33, 28, 8, 7, 0.45) // stamp
        line(34, 30, 40, 30, white: 0.8)
    }

    private static func edit() {
        let page = NSBezierPath() // page with a folded corner
        page.move(to: point(8, 4)); page.line(to: point(8, 44)); page.line(to: point(31, 44))
        page.line(to: point(38, 37)); page.line(to: point(38, 4)); page.close()
        shape(page, 1, shadow: true)
        let fold = NSBezierPath()
        fold.move(to: point(31, 44)); fold.line(to: point(31, 37)); fold.line(to: point(38, 37)); fold.close()
        shape(fold, 0.7)
        for y in stride(from: CGFloat(32), through: 10, by: -5) { line(12, y, 34, y, white: 0.5) }
        let pencil = NSBezierPath() // a pencil lying across the page
        pencil.move(to: point(20, 8)); pencil.line(to: point(42, 30)); pencil.line(to: point(46, 26))
        pencil.line(to: point(24, 4)); pencil.close()
        shape(pencil, 0.55)
        let tip = NSBezierPath()
        tip.move(to: point(20, 8)); tip.line(to: point(24, 4)); tip.line(to: point(17, 1)); tip.close()
        shape(tip, 0.9)
    }

    private static func terminal() {
        box(4, 12, 40, 32, 0.6, shadow: true) // monitor
        box(8, 16, 32, 24, 0) // screen
        (">_" as NSString).draw(at: point(11, 25), withAttributes: [.font: NSFont(name: "Courier-Bold", size: u(11)) ?? boldFont, .foregroundColor: NSColor.white])
        box(18, 6, 12, 6, 0.45) // neck
        box(10, 2, 28, 4, 0.6, shadow: true) // base
    }

    private static func calculator() {
        box(9, 3, 30, 42, 0.5, shadow: true)
        box(12, 34, 24, 8, 0.85) // display
        ("42" as NSString).draw(at: point(25, 34.5), withAttributes: [.font: NSFont(name: "Helvetica-Bold", size: u(7)) ?? boldFont])
        for row in 0..<4 {
            for col in 0..<4 {
                box(12 + CGFloat(col) * 6.2, 6 + CGFloat(row) * 6.6, 5, 5, col == 3 ? 0.25 : 0.85)
            }
        }
    }

    private static func preferences() {
        box(4, 6, 40, 36, 0.7, shadow: true)
        for (i, knob) in [CGFloat(14), 30, 21].enumerated() { // three slider tracks with bevelled knobs
            let y = 33 - CGFloat(i) * 10
            box(9, y, 30, 3, 0.25)
            bevel(rect(knob, y - 3, 7, 9))
        }
    }

    static func recycler(in area: NSRect, full: Bool) {
        r = area
        let bin = NSBezierPath() // a tapered can
        bin.move(to: point(11, 38)); bin.line(to: point(15, 4)); bin.line(to: point(33, 4)); bin.line(to: point(37, 38)); bin.close()
        shape(bin, 0.65, shadow: true)
        for x: CGFloat in [18, 24, 30] { line(x, 8, x + (x - 24) * 0.25, 34, white: 0.4) } // ribs
        box(8, 38, 32, 5, 0.75, shadow: true) // rim
        if full { // crumpled paper sticking out
            shape(NSBezierPath(ovalIn: rect(13, 40, 12, 7)), 1)
            shape(NSBezierPath(ovalIn: rect(23, 41, 11, 6)), 0.9)
        }
        // The three-arrow recycling loop
        let loop = NSBezierPath(ovalIn: rect(17, 15, 14, 14))
        loop.lineWidth = u(2.5)
        NSColor.black.setStroke()
        loop.stroke()
        for angle in stride(from: 0.0, to: 360.0, by: 120.0) {
            let a = angle * .pi / 180, c = point(24, 22), radius = u(7)
            let tip = NSPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a))
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: tip.x + u(3) * cos(a + .pi / 2), y: tip.y + u(3) * sin(a + .pi / 2)))
            arrow.line(to: NSPoint(x: tip.x + u(3) * cos(a), y: tip.y + u(3) * sin(a)))
            arrow.line(to: NSPoint(x: tip.x - u(3) * cos(a), y: tip.y - u(3) * sin(a)))
            arrow.close()
            NSColor.black.setFill()
            arrow.fill()
        }
    }

    /// Any other app: its own icon with the colour taken out, to sit with the NeXT greys.
    private static func greyscale(_ icon: NSImage, in area: NSRect) {
        let grey = NSImage(size: area.size, flipped: false) { bounds in
            icon.draw(in: bounds)
            NSColor.black.setFill()
            bounds.fill(using: .saturation) // keep the brightness, drop the colour
            icon.draw(in: bounds, from: .zero, operation: .destinationIn, fraction: 1) // restore the shape
            return true
        }
        grey.draw(in: area)
    }
}

final class Tile: NSView {
    let path: String? // nil: the Workspace tile (top) or the Recycler (bottom)
    let recycler: Bool
    var changed: () -> Void = {}

    init(path: String?, recycler: Bool = false) {
        self.path = path
        self.recycler = recycler
        super.init(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        bevel(bounds)
        let art = bounds.insetBy(dx: 8, dy: 8)
        if recycler {
            let full = (try? FileManager.default.contentsOfDirectory(atPath: trashPath))?.isEmpty == false
            return NeXTIcons.recycler(in: art, full: full)
        }
        guard let path else { return drawCube() }
        NeXTIcons.draw(app: path, in: art)
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == path }
        if !running {
            ("…" as NSString).draw(at: NSPoint(x: 4, y: 2), withAttributes: [.font: boldFont, .foregroundColor: NSColor.black])
        }
    }

    /// The real NeXT logo in colour (NeXT_logo.svg in the app's Resources), centred in the tile with a margin;
    /// falls back to the drawn black-and-grey cube if the file is missing.
    func drawCube() {
        if let url = Bundle.main.url(forResource: "NeXT_logo", withExtension: "svg"), let logo = NSImage(contentsOf: url) {
            let area = bounds.insetBy(dx: 5, dy: 5), scale = min(area.width / logo.size.width, area.height / logo.size.height)
            let size = NSSize(width: logo.size.width * scale, height: logo.size.height * scale)
            logo.draw(in: NSRect(x: area.midX - size.width / 2, y: area.midY - size.height / 2, width: size.width, height: size.height))
            return
        }
        drawGreyCube()
    }

    /// The NeXT cube logo in black, white and grey: a black cube tilted 28°, its front face toward you with
    /// "Ne" over "XT" all on that one face (each letter its own grey, where the original has four colours),
    /// narrow side and bottom faces showing, white edges and a hard drop shadow like the other tiles.
    private func drawGreyCube() {
        let a: CGFloat = 15, d: CGFloat = 7 // half the front face, depth of the side faces
        NSGraphicsContext.saveGraphicsState()
        let tilt = NSAffineTransform()
        tilt.translateX(by: bounds.midX, yBy: bounds.midY)
        tilt.rotate(byDegrees: 28)
        tilt.translateX(by: d / 2, yBy: d / 2)
        tilt.concat()
        let front = [NSPoint(x: -a, y: -a), NSPoint(x: a, y: -a), NSPoint(x: a, y: a), NSPoint(x: -a, y: a)]
        let side = [NSPoint(x: -a, y: a), NSPoint(x: -a - d, y: a - d), NSPoint(x: -a - d, y: -a - d), NSPoint(x: -a, y: -a)]
        let bottom = [NSPoint(x: -a, y: -a), NSPoint(x: -a - d, y: -a - d), NSPoint(x: a - d, y: -a - d), NSPoint(x: a, y: -a)]
        func path(_ points: [NSPoint], dx: CGFloat = 0, dy: CGFloat = 0) -> NSBezierPath {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: points[0].x + dx, y: points[0].y + dy))
            points.dropFirst().forEach { p.line(to: NSPoint(x: $0.x + dx, y: $0.y + dy)) }
            p.close()
            return p
        }
        NSColor(calibratedWhite: 0.25, alpha: 1).setFill() // shadow
        for face in [side, bottom, front] { path(face, dx: 2, dy: -2).fill() }
        for face in [side, bottom, front] { // all black, white edges like the logo's
            let p = path(face)
            NSColor.black.setFill()
            p.fill()
            NSColor(calibratedWhite: 0.9, alpha: 1).setStroke()
            p.lineWidth = 0.75
            p.stroke()
        }
        // "Ne" over "XT", all on the front face
        let letters = NSFont(name: "Helvetica-Light", size: 15) ?? NSFont(name: "Helvetica", size: 15) ?? .systemFont(ofSize: 15, weight: .light)
        func letter(_ text: String, _ x: CGFloat, _ y: CGFloat, _ white: CGFloat) {
            (text as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: letters, .foregroundColor: NSColor(calibratedWhite: white, alpha: 1)])
        }
        letter("N", -13, 0, 0.7)
        letter("e", 1, 0, 0.6)
        letter("X", -13, -15, 0.5)
        letter("T", 1, -15, 0.65)
        NSGraphicsContext.restoreGraphicsState()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        if recycler {
            FileViewer.open(trashPath)
        } else if let path {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        } else {
            FileViewer.open(NSHomeDirectory())
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard path != nil else { return nil }
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove from Dock", action: #selector(removeFromDock), keyEquivalent: "")
        remove.target = self
        menu.addItem(remove)
        return menu
    }

    @objc private func removeFromDock() {
        DockApps.paths.removeAll { $0 == path }
        changed()
    }

    private func dropped(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
    }
    private func droppedApps(_ info: NSDraggingInfo) -> [String] {
        dropped(info).filter { $0.pathExtension == "app" }.map(\.path)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if recycler { return dropped(sender).isEmpty ? [] : .delete }
        return droppedApps(sender).isEmpty ? [] : .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if recycler {
            dropped(sender).forEach { try? FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
            FileViewer.viewers.forEach { $0.refresh() }
            needsDisplay = true
            return true
        }
        let apps = droppedApps(sender).filter { !DockApps.paths.contains($0) }
        DockApps.paths += apps
        changed()
        return !apps.isEmpty
    }
}

final class Dock {
    let window = makePanel()

    init() {
        reload()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.window.contentView?.subviews.forEach { $0.needsDisplay = true }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reload()
        }
    }

    func reload() {
        guard let screen = NSScreen.main?.frame else { return }
        let tiles = [Tile(path: nil)] + DockApps.paths.map { Tile(path: $0) } + [Tile(path: nil, recycler: true)]
        let height = CGFloat(tiles.count) * tileSize
        let content = NSView(frame: NSRect(x: 0, y: 0, width: tileSize, height: height))
        for (i, tile) in tiles.enumerated() {
            tile.frame.origin = NSPoint(x: 0, y: height - CGFloat(i + 1) * tileSize)
            tile.changed = { [weak self] in self?.reload() }
            content.addSubview(tile)
        }
        window.contentView = content
        window.setFrame(NSRect(x: screen.maxX - tileSize, y: screen.maxY - height, width: tileSize, height: height), display: true)
    }
}

// MARK: Menus

/// One menu entry: an item of the front app's real menu (through Accessibility) or one of the Workspace's own.
struct Entry {
    enum Kind { case action(() -> Void), submenu(() -> [Entry]) }
    var title: String
    var key = ""
    var enabled = true
    var kind: Kind
}

func axEntries(_ menu: AXUIElement) -> [Entry] {
    axChildren(menu).compactMap { child in
        let title = axString(child, kAXTitleAttribute) ?? ""
        guard !title.isEmpty else { return nil } // NeXT menus have no separators
        let enabled = axValue(child, kAXEnabledAttribute) as? Bool ?? true
        if let submenu = axChildren(child).first {
            return Entry(title: title, enabled: enabled, kind: .submenu { axEntries(submenu) })
        }
        let key = axString(child, kAXMenuItemCmdCharAttribute).map { $0.count == 1 ? $0.lowercased() : "" } ?? ""
        return Entry(title: title, key: key, enabled: enabled, kind: .action { AXUIElementPerformAction(child, kAXPressAction as CFString) })
    }
}

/// Runs the Workspace entry with this key equivalent (Cmd+key while a File Viewer is in front).
func perform(key: String, in entries: [Entry]) -> Bool {
    for entry in entries where entry.enabled {
        switch entry.kind {
        case .action(let run) where entry.key == key:
            run()
            return true
        case .submenu(let make) where perform(key: key, in: make()):
            return true
        default:
            continue
        }
    }
    return false
}

final class Row: NSView {
    enum Kind { case title, item, submenu }
    let title: String
    let key: String
    let kind: Kind
    let enabled: Bool
    var highlighted = false { didSet { needsDisplay = true } }
    var closeBox = false { didSet { needsDisplay = true } }
    /// The main menu's level toggle in the top right of its title: filled = floats above apps, hollow = among them.
    var action: (Row) -> Void = { _ in }
    var moved: () -> Void = {}
    var close: () -> Void = {}

    init(_ title: String, _ kind: Kind, key: String = "", enabled: Bool = true) {
        self.title = title
        self.kind = kind
        self.key = key
        self.enabled = enabled
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var closeBoxRect: NSRect { NSRect(x: bounds.maxX - 18, y: 3, width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        if kind == .title {
            fill(.black, bounds)
            (title as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: [.font: boldFont, .foregroundColor: NSColor.white])
            if closeBox { // NeXT's close box on torn-off menus
                bevel(closeBoxRect)
                let x = NSBezierPath()
                let r = closeBoxRect.insetBy(dx: 4, dy: 4)
                x.move(to: NSPoint(x: r.minX, y: r.minY)); x.line(to: NSPoint(x: r.maxX, y: r.maxY))
                x.move(to: NSPoint(x: r.minX, y: r.maxY)); x.line(to: NSPoint(x: r.maxX, y: r.minY))
                NSColor.black.setStroke()
                x.lineWidth = 1.5
                x.stroke()
            }
            return
        }
        if highlighted {
            fill(.white, bounds)
            fill(.black, NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        } else {
            bevel(bounds)
        }
        let color = enabled ? NSColor.black : NSColor(calibratedWhite: 0.333, alpha: 1)
        (title as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: [.font: font, .foregroundColor: color])
        if !key.isEmpty {
            let size = (key as NSString).size(withAttributes: [.font: font])
            (key as NSString).draw(at: NSPoint(x: bounds.maxX - 8 - size.width, y: 3), withAttributes: [.font: font, .foregroundColor: color])
        }
        if kind == .submenu { // NeXT's arrow for items that open a submenu
            let x = bounds.maxX - 12, y = bounds.midY
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x, y: y + 4))
            arrow.line(to: NSPoint(x: x + 6, y: y))
            arrow.line(to: NSPoint(x: x, y: y - 4))
            arrow.close()
            color.setFill()
            arrow.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard kind == .title else {
            if enabled { action(self) }
            return
        }
        window?.orderFrontRegardless() // among app windows, a click brings the menu forward
        let inBox = closeBoxRect.contains(convert(event.locationInWindow, from: nil))
        if closeBox, inBox { return close() }
        // Drag the column by its title
        guard let window else { return }
        let start = NSEvent.mouseLocation, origin = window.frame.origin
        var didMove = false
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            window.setFrameOrigin(NSPoint(x: origin.x + p.x - start.x, y: origin.y + p.y - start.y))
            didMove = true
            moved()
        }
        if didMove { moved() }
    }
}

/// Every menu floats above app windows, on every Space, as on NeXTSTEP: the main menu, its attached submenus
/// and torn-off menus.
enum MenuLevel {
    static let level = NSWindow.Level.floating
    static let behavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
}

/// One menu column. Submenus open as attached columns to the right; dragging one tears it off.
/// As on NeXTSTEP, a torn-off menu gets a close box and stays on screen, floating, until that box is clicked,
/// whichever app is active.
final class MenuColumn {
    static var tornOff: [MenuColumn] = []
    /// The app whose menus are showing (its process id); a menu torn off now belongs to it.
    static var activeOwner = getpid()
    var owner = getpid()
    let panel = makePanel()
    let isMain: Bool
    var title: String
    weak var parent: MenuColumn?
    weak var sourceRow: Row?
    var child: MenuColumn?
    var torn = false
    var rows: [Row] = []

    init(title: String, isMain: Bool = false) {
        self.title = title
        self.isMain = isMain
        panel.level = MenuLevel.level
        panel.collectionBehavior = MenuLevel.behavior
    }

    func build(_ entries: [Entry]) {
        let header = Row(title, .title)
        header.closeBox = torn
        header.moved = { [weak self] in self?.moved() }
        header.close = { [weak self] in self?.close() }
        rows = [header]
        for entry in entries {
            switch entry.kind {
            case .submenu(let make):
                let row = Row(entry.title, .submenu, enabled: entry.enabled)
                row.action = { [weak self] row in
                    guard let self else { return }
                    if row.highlighted { self.closeChild() } else { self.open(make(), title: entry.title, from: row) }
                }
                rows.append(row)
            case .action(let run):
                let row = Row(entry.title, .item, key: entry.key, enabled: entry.enabled)
                row.action = { [weak self] row in
                    row.highlighted = true
                    row.display()
                    run()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        row.highlighted = false
                        self?.collapse()
                    }
                }
                rows.append(row)
            }
        }
        let widest = rows.map { row -> CGFloat in
            let text = (row.title as NSString).size(withAttributes: [.font: row.kind == .title ? boldFont : font]).width
            let key = (row.key as NSString).size(withAttributes: [.font: font]).width
            return text + key + (row.kind == .item ? 24 : 36)
        }.max() ?? 0
        let width = max(isMain ? menuWidth : 110, ceil(widest))
        let height = CGFloat(rows.count) * rowHeight
        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: height - CGFloat(i + 1) * rowHeight, width: width, height: rowHeight)
            content.addSubview(row)
        }
        // Keep the top left corner where it is (the user may have dragged the column)
        let screen = NSScreen.main?.frame ?? .zero
        let placed = panel.frame.height > 0
        let left = placed ? panel.frame.minX : screen.minX, top = placed ? panel.frame.maxY : screen.maxY
        panel.contentView = content
        panel.setFrame(NSRect(x: left, y: top - height, width: width, height: height), display: true)
        panel.orderFrontRegardless()
    }

    /// Opens a submenu as a new column beside this one, its title level with the row that opened it.
    func open(_ entries: [Entry], title: String, from row: Row) {
        closeChild()
        row.highlighted = true
        let column = MenuColumn(title: title)
        column.parent = self
        column.sourceRow = row
        column.panel.level = panel.level // submenus of a floating torn-off menu float with it
        child = column
        column.build(entries)
        column.place()
    }

    func place() {
        if let parent, let row = sourceRow {
            panel.setFrameTopLeftPoint(NSPoint(x: parent.panel.frame.maxX - 1, y: parent.panel.frame.minY + row.frame.maxY))
        }
        child?.place()
    }

    /// The title was dragged: a submenu that is still attached tears off; attached columns follow.
    private func moved() {
        if !isMain, !torn {
            torn = true
            owner = MenuColumn.activeOwner
            sourceRow?.highlighted = false
            if parent?.child === self { parent?.child = nil }
            parent = nil
            MenuColumn.tornOff.append(self)
            rows.first?.closeBox = true
        }
        child?.place()
    }

    func closeChild() {
        child?.close()
        child = nil
        rows.forEach { $0.highlighted = false }
    }

    func close() {
        closeChild()
        panel.orderOut(nil)
        MenuColumn.tornOff.removeAll { $0 === self }
        if let parent, parent.child === self {
            parent.child = nil
            sourceRow?.highlighted = false
        }
    }

    /// After a command: close the attached submenus, as NeXTSTEP does. Torn-off columns stay.
    private func collapse() {
        var top = self
        while let parent = top.parent { top = parent }
        top.closeChild()
    }
}

final class MainMenu {
    let column = MenuColumn(title: "Workspace", isMain: true)
    var app = NSWorkspace.shared.frontmostApplication

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            self?.app = app
            self?.reload()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.app = .current
            self?.reload()
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.contains(.command), let key = event.charactersIgnoringModifiers,
                  perform(key: key, in: MainMenu.workspaceEntries) else { return event }
            return nil
        }
        reload()
    }

    func reload() {
        column.closeChild()
        // Torn-off menus stay up across app switches (only their close box removes them); keep them on top
        MenuColumn.activeOwner = app?.processIdentifier ?? getpid()
        for torn in MenuColumn.tornOff { torn.panel.orderFrontRegardless() }
        guard let app, app != .current else {
            column.title = "Workspace"
            return column.build(Self.workspaceEntries)
        }
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        column.title = isFinder ? "Finder" : app.localizedName ?? "Workspace"
        var entries: [Entry] = []
        let trusted = AXIsProcessTrusted()
        if trusted, let bar = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) {
            // Skip the Apple menu; the app's own menu becomes Info, as on NeXTSTEP
            for (i, item) in axChildren(bar as! AXUIElement).dropFirst().enumerated() {
                let name = i == 0 ? "Info" : axString(item, kAXTitleAttribute) ?? ""
                if !name.isEmpty, let menu = axChildren(item).first {
                    entries.append(Entry(title: name, kind: .submenu { axEntries(menu) }))
                }
            }
            menuRetries = 0
        } else if trusted {
            // Allowed, but the app's menu bar isn't readable yet (it's still launching): try again shortly.
            // If it never becomes readable, the permission granted to this running copy is stale: relaunch.
            menuRetries += 1
            if menuRetries > 10 { relaunch() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                if self?.app == app { self?.reload() }
            }
        } else {
            // macOS only lets an app read other apps' menus once it's allowed under Accessibility. This puts
            // NeXT Workspace in that list (switched off) and opens the pane; the menus appear as soon as it's on.
            entries.append(Entry(title: "Allow Menus…", kind: .action {
                _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")!)
            }))
            waitForTrust()
        }
        entries.append(Entry(title: "Hide", key: "h", kind: .action { _ = app.hide() }))
        if !isFinder { entries.append(Entry(title: "Quit", key: "q", kind: .action { _ = app.terminate() })) }
        column.build(entries)
    }

    /// Checks once a second until Accessibility is allowed. macOS often only applies a new grant to processes
    /// started after it, so relaunch then; the fresh copy reads the menus straight away.
    private var trustTimer: Timer?
    private var menuRetries = 0
    private func waitForTrust() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.trustTimer = nil
            self?.relaunch()
        }
    }

    private func relaunch() {
        let bundle = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", bundle]
        try? task.run()
        exit(0) // exit 0: the LaunchAgent (KeepAlive on failure only) leaves the relaunch to open
    }

    /// NeXTSTEP Workspace Manager's own menu: Info, File, Tools, Windows, Hide, Log Out.
    static var workspaceEntries: [Entry] {
        [
            Entry(title: "Info", kind: .submenu { [
                Entry(title: "Info Panel…", kind: .action {
                    NSApp.activate()
                    NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "NeXT Workspace", .credits: NSAttributedString(string: "A NeXTSTEP-style Workspace for TinyMacII, part of Macaroon.")])
                }),
            ] }),
            Entry(title: "File", kind: .submenu { [
                Entry(title: "Open", key: "o", kind: .action { FileViewer.current?.openSelection() }),
                Entry(title: "New Viewer", key: "n", kind: .action { FileViewer.open(FileViewer.current?.path ?? NSHomeDirectory()) }),
                Entry(title: "New Folder", key: "N", kind: .action { FileViewer.current?.newFolder() }),
                Entry(title: "Recycle", key: "r", kind: .action { FileViewer.current?.recycleSelection() }),
                Entry(title: "Close Window", key: "w", kind: .action { NSApp.keyWindow?.performClose(nil) }),
            ] }),
            Entry(title: "Tools", kind: .submenu { [
                Entry(title: "Inspector…", key: "3", kind: .action { Inspector.shared.show(FileViewer.current?.path) }),
                Entry(title: "Recycler", kind: .action { FileViewer.open(trashPath) }),
            ] }),
            Entry(title: "Windows", kind: .submenu {
                NSApp.windows.filter { $0.isVisible && !$0.title.isEmpty }.map { window in
                    Entry(title: window.title, kind: .action { NSApp.activate(); window.makeKeyAndOrderFront(nil) })
                }
            }),
            Entry(title: "Hide", key: "h", kind: .action { NSApp.hide(nil) }),
            Entry(title: "Log Out", key: "q", kind: .action {
                NSAppleScript(source: "tell application \"System Events\" to log out")?.executeAndReturnError(nil)
            }),
        ]
    }
}

// MARK: File Viewer

/// The shelf along the top of a File Viewer: folders and files kept at hand. Drop things on it to add them.
final class Shelf: NSView {
    var go: (String) -> Void = { _ in }
    let slot: CGFloat = 80
    var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "Shelf") ?? ["~", "/Applications", "~/Documents", "~/Desktop"].map { ($0 as NSString).expandingTildeInPath } }
        set { UserDefaults.standard.set(newValue, forKey: "Shelf"); needsDisplay = true }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        fill(NSColor(calibratedWhite: 0.6, alpha: 1), bounds) // sunken well
        fill(.black, NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1))
        fill(.white, NSRect(x: 0, y: 0, width: bounds.width, height: 1))
        for (i, path) in paths.enumerated() {
            let x = 8 + CGFloat(i) * slot
            drawNeXTIcon(path, in: NSRect(x: x + 16, y: 24, width: 48, height: 48))
            drawLabel(FileManager.default.displayName(atPath: path), in: NSRect(x: x, y: 4, width: slot, height: 16))
        }
    }

    private func index(_ event: NSEvent) -> Int? {
        let i = Int((convert(event.locationInWindow, from: nil).x - 8) / slot)
        return i >= 0 && i < paths.count ? i : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let i = index(event) else { return }
        if event.clickCount == 2 { NSWorkspace.shared.open(URL(fileURLWithPath: paths[i])) } else { go(paths[i]) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let i = index(event) else { return nil }
        let menu = NSMenu()
        let remove = NSMenuItem(title: "Remove from Shelf", action: #selector(remove(_:)), keyEquivalent: "")
        remove.target = self
        remove.representedObject = paths[i]
        menu.addItem(remove)
        return menu
    }

    @objc private func remove(_ sender: NSMenuItem) { paths.removeAll { $0 == sender.representedObject as? String } }

    private func dropped(_ info: NSDraggingInfo) -> [String] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []).map(\.path)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dropped(sender).isEmpty ? [] : .link }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        paths += dropped(sender).filter { !paths.contains($0) }
        return true
    }
}

/// The icon path between shelf and browser: one icon per folder down to the selection; click one to go there.
final class PathView: NSView {
    var go: (String) -> Void = { _ in }
    var path = "/" { didSet { needsDisplay = true } }
    let slot: CGFloat = 160

    private var shown: [String] {
        var all = ["/"]
        for component in (path as NSString).pathComponents.dropFirst() {
            all.append((all.last! as NSString).appendingPathComponent(component))
        }
        return Array(all.suffix(max(1, Int(bounds.width / slot))))
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds)
        for (i, path) in shown.enumerated() {
            let x = CGFloat(i) * slot
            if i > 0 { fill(.black, NSRect(x: x - slot / 2 + 30, y: 48, width: slot - 60, height: 1)) } // the line joining the icons
            drawNeXTIcon(path, in: NSRect(x: x + slot / 2 - 24, y: 24, width: 48, height: 48))
            drawLabel(FileManager.default.displayName(atPath: path), in: NSRect(x: x + 4, y: 4, width: slot - 8, height: 16))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let i = Int(convert(event.locationInWindow, from: nil).x / slot), shown = shown
        if i < shown.count { go(shown[i]) }
    }
}

/// A filled black triangle, NeXT's arrow: on browser rows that open a folder and on scroller buttons.
func triangle(in r: NSRect, pointing direction: Character) {
    let t = NSBezierPath()
    switch direction {
    case "<": t.move(to: NSPoint(x: r.maxX, y: r.minY)); t.line(to: NSPoint(x: r.minX, y: r.midY)); t.line(to: NSPoint(x: r.maxX, y: r.maxY))
    case "^": t.move(to: NSPoint(x: r.minX, y: r.maxY)); t.line(to: NSPoint(x: r.midX, y: r.minY)); t.line(to: NSPoint(x: r.maxX, y: r.maxY))
    case "v": t.move(to: NSPoint(x: r.minX, y: r.minY)); t.line(to: NSPoint(x: r.midX, y: r.maxY)); t.line(to: NSPoint(x: r.maxX, y: r.minY))
    default: t.move(to: NSPoint(x: r.minX, y: r.minY)); t.line(to: NSPoint(x: r.maxX, y: r.midY)); t.line(to: NSPoint(x: r.minX, y: r.maxY))
    }
    t.close()
    NSColor.black.setFill()
    t.fill()
}

/// NeXTSTEP's column browser, drawn the NeXT way: grey columns, black Helvetica, the selection in white, a black
/// arrow on folders, scrollers on the left with both arrow buttons at the bottom, and a horizontal scroller on top.
final class NeXTBrowser: NSView {
    static let scrollerSize: CGFloat = 18
    var children: (String) -> [String] = { _ in [] }
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    let visible = 4
    private(set) var folders = ["/"] // column i lists the contents of folders[i]
    private var columns: [BrowserColumn] = []
    private var first = 0 // leftmost visible column
    override var isFlipped: Bool { true }

    /// Opens the columns down to `target`, selecting each step (and `target` itself).
    func load(_ target: String) {
        folders = ["/"]
        var selections: [IndexSet] = []
        var parent = "/"
        for component in (target as NSString).pathComponents.dropFirst() {
            let p = (parent as NSString).appendingPathComponent(component)
            guard let i = children(parent).firstIndex(of: p) else { break }
            selections.append([i])
            guard isFolder(p) else { break }
            folders.append(p)
            parent = p
        }
        columns.forEach { $0.removeFromSuperview() }
        columns = folders.indices.map { i in makeColumn(i, selected: i < selections.count ? selections[i] : []) }
        first = max(0, folders.count - visible)
        layoutColumns()
        columns.forEach { $0.reveal() }
    }

    private func makeColumn(_ i: Int, selected: IndexSet) -> BrowserColumn {
        let column = BrowserColumn(items: children(folders[i]))
        column.browser = self
        column.index = i
        column.selected = selected
        addSubview(column)
        return column
    }

    /// A click in a column: select those rows, close the columns after it, open a column for a single folder.
    func select(_ rows: IndexSet, in i: Int) {
        columns[i].selected = rows
        columns[(i + 1)...].forEach { $0.removeFromSuperview() }
        columns.removeSubrange((i + 1)...)
        folders.removeSubrange((i + 1)...)
        if rows.count == 1, let row = rows.first, isFolder(columns[i].items[row]) {
            folders.append(columns[i].items[row])
            columns.append(makeColumn(i + 1, selected: []))
        }
        first = max(0, folders.count - visible)
        layoutColumns()
        onSelect()
    }

    /// The single selected item furthest right, or the folder holding a multiple selection.
    var path: String {
        var p = "/"
        for (i, column) in columns.enumerated() {
            if column.selected.count == 1, let row = column.selected.first { p = column.items[row] }
            else if column.selected.count > 1 { p = folders[i] }
        }
        return p
    }

    var selectedPaths: [String] {
        guard let column = columns.last(where: { !$0.selected.isEmpty }) else { return [] }
        return column.selected.map { column.items[$0] }
    }

    private func layoutColumns() {
        let width = floor(bounds.width / CGFloat(visible)), top = NeXTBrowser.scrollerSize
        for (i, column) in columns.enumerated() {
            column.isHidden = i < first || i >= first + visible
            let last = i == first + visible - 1
            column.frame = NSRect(x: CGFloat(i - first) * width, y: top, width: last ? bounds.width - CGFloat(visible - 1) * width : width, height: bounds.height - top)
        }
        needsDisplay = true
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutColumns() }

    // The horizontal scroller along the top: two arrow buttons on the left, then the track and its knob
    private var leftButton: NSRect { NSRect(x: 0, y: 0, width: NeXTBrowser.scrollerSize, height: NeXTBrowser.scrollerSize) }
    private var rightButton: NSRect { leftButton.offsetBy(dx: NeXTBrowser.scrollerSize, dy: 0) }
    private var track: NSRect { NSRect(x: 2 * NeXTBrowser.scrollerSize, y: 0, width: bounds.width - 2 * NeXTBrowser.scrollerSize, height: NeXTBrowser.scrollerSize) }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds) // the empty column slots
        fill(NSColor(calibratedWhite: 0.333, alpha: 1), track)
        let total = CGFloat(max(folders.count, visible))
        let knob = NSRect(x: track.minX + track.width * CGFloat(first) / total, y: 0, width: track.width * CGFloat(visible) / total, height: track.height)
        if folders.count > visible { bevel(knob.insetBy(dx: 1, dy: 1)) }
        for (button, direction) in [(leftButton, Character("<")), (rightButton, Character(">"))] {
            bevel(button)
            triangle(in: NSRect(x: button.midX - 3, y: button.midY - 4, width: 6, height: 8), pointing: direction)
        }
        fill(.black, NSRect(x: 0, y: NeXTBrowser.scrollerSize - 1, width: bounds.width, height: 1))
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let last = max(0, folders.count - visible)
        if leftButton.contains(p) { first = max(0, first - 1) }
        else if rightButton.contains(p) { first = min(last, first + 1) }
        else if track.contains(p) { first = min(last, max(0, Int((p.x - track.minX) / track.width * CGFloat(max(folders.count, visible))) - visible / 2)) }
        layoutColumns()
    }
}

final class BrowserColumn: NSView, NSDraggingSource {
    let items: [String]
    weak var browser: NeXTBrowser?
    var index = 0
    var selected = IndexSet() { didSet { needsDisplay = true } }
    private var offset: CGFloat = 0 { didSet { needsDisplay = true } }
    private let rowHeight: CGFloat = 18
    private let bar = NeXTBrowser.scrollerSize
    override var isFlipped: Bool { true }

    init(items: [String]) {
        self.items = items
        super.init(frame: .zero)
        clipsToBounds = true // macOS 14+ doesn't clip by default: a part-scrolled top row drew over the scroller above
    }
    required init?(coder: NSCoder) { fatalError() }

    private var maxOffset: CGFloat { max(0, CGFloat(items.count) * rowHeight - bounds.height) }
    private var upButton: NSRect { NSRect(x: 0, y: bounds.height - 2 * bar, width: bar, height: bar) }
    private var downButton: NSRect { NSRect(x: 0, y: bounds.height - bar, width: bar, height: bar) }
    private var trackHeight: CGFloat { bounds.height - 2 * bar }
    private var knob: NSRect {
        let content = CGFloat(items.count) * rowHeight
        let height = max(bar, trackHeight * bounds.height / max(content, 1))
        return NSRect(x: 0, y: (trackHeight - height) * offset / max(maxOffset, 1), width: bar, height: height)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        offset = min(offset, maxOffset)
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textHeight = ceil(font.ascender - font.descender)
        let firstRow = max(0, Int(offset / rowHeight)), lastRow = min(items.count, Int((offset + bounds.height) / rowHeight) + 1)
        for row in firstRow..<max(firstRow, lastRow) {
            let r = NSRect(x: bar, y: CGFloat(row) * rowHeight - offset, width: bounds.width - bar - 1, height: rowHeight)
            if selected.contains(row) { fill(.white, r) }
            let folder = isFolder(items[row])
            ((items[row] as NSString).lastPathComponent as NSString).draw(
                in: NSRect(x: r.minX + 6, y: r.minY + floor((rowHeight - textHeight) / 2), width: r.width - (folder ? 26 : 10), height: textHeight),
                withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            if folder { triangle(in: NSRect(x: r.maxX - 13, y: r.midY - 4, width: 6, height: 8), pointing: ">") }
        }
        // Scroller on the left: dark track, bevelled knob, both arrow buttons at the bottom
        fill(NSColor(calibratedWhite: 0.333, alpha: 1), NSRect(x: 0, y: 0, width: bar, height: trackHeight))
        if maxOffset > 0 { bevel(knob.insetBy(dx: 1, dy: 1)) }
        for (button, direction) in [(upButton, Character("^")), (downButton, Character("v"))] {
            bevel(button)
            triangle(in: NSRect(x: button.midX - 4, y: button.midY - 3, width: 8, height: 6), pointing: direction)
        }
        fill(.black, NSRect(x: bar, y: 0, width: 1, height: bounds.height))
        fill(.black, NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height))
    }

    func reveal() {
        guard let row = selected.first else { return }
        let y = CGFloat(row) * rowHeight
        if y < offset || y + rowHeight > offset + bounds.height { offset = min(maxOffset, max(0, y - bounds.height / 2)) }
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * rowHeight
        offset = min(maxOffset, max(0, offset - delta))
    }

    override func mouseDown(with event: NSEvent) {
        guard let browser, let window else { return }
        let p = convert(event.locationInWindow, from: nil)
        if p.x < bar { return scroller(p, event) }
        let row = Int((p.y + offset) / rowHeight)
        guard row < items.count else { return }
        var rows: IndexSet = [row]
        if event.modifierFlags.contains(.command) {
            rows = selected
            if rows.contains(row) { rows.remove(row) } else { rows.insert(row) }
        } else if event.modifierFlags.contains(.shift), let anchor = selected.first {
            rows = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
        } else if selected.contains(row), event.clickCount == 1 {
            rows = selected // keep a multiple selection so it can be dragged
        }
        browser.select(rows, in: index)
        if event.clickCount == 2 { return browser.onOpen() }
        // Drag the selection out (to the Recycler, the shelf, the Dock or another app)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let q = convert(next.locationInWindow, from: nil)
            guard hypot(q.x - p.x, q.y - p.y) > 4 else { continue }
            let dragged = selected.map { row -> NSDraggingItem in
                let item = NSDraggingItem(pasteboardWriter: URL(fileURLWithPath: items[row]) as NSURL)
                item.setDraggingFrame(NSRect(x: q.x - 16, y: q.y - 16, width: 32, height: 32), contents: NSWorkspace.shared.icon(forFile: items[row]))
                return item
            }
            beginDraggingSession(with: dragged, event: next, source: self)
            return
        }
    }

    private func scroller(_ p: NSPoint, _ event: NSEvent) {
        if upButton.contains(p) { offset = max(0, offset - rowHeight); return }
        if downButton.contains(p) { offset = min(maxOffset, offset + rowHeight); return }
        guard maxOffset > 0, let window else { return }
        let grab = knob.contains(p) ? p.y - knob.minY : knob.height / 2
        func move(_ y: CGFloat) { offset = min(maxOffset, max(0, (y - grab) / max(trackHeight - knob.height, 1) * maxOffset)) }
        move(p.y)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            move(convert(next.locationInWindow, from: nil).y)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .every }
}

final class FileViewer: NSObject, NSWindowDelegate {
    static var viewers: [FileViewer] = []
    static var current: FileViewer? { viewers.first { $0.window.isKeyWindow } ?? viewers.last }

    let window = NeXTWindow(body: NSSize(width: 760, height: 540))
    let browser = NeXTBrowser()
    let shelf = Shelf()
    let pathView = PathView()
    private var cache: [String: [String]] = [:]
    private var revealed: Set<String> = [] // hidden folders on a path we were asked to show (e.g. ~/.Trash)

    static func open(_ path: String) {
        let viewer = FileViewer(path)
        viewers.append(viewer)
        NSApp.activate()
        viewer.window.makeKeyAndOrderFront(nil)
    }

    init(_ start: String) {
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 360)
        let (w, h): (CGFloat, CGFloat) = (760, 540)
        shelf.frame = NSRect(x: 0, y: h - 84, width: w, height: 84)
        pathView.frame = NSRect(x: 0, y: h - 164, width: w, height: 80)
        browser.frame = NSRect(x: 0, y: 0, width: w, height: h - 164)
        shelf.autoresizingMask = [.width, .minYMargin]
        pathView.autoresizingMask = [.width, .minYMargin]
        browser.autoresizingMask = [.width, .height]
        shelf.go = { [weak self] in self?.go($0) }
        pathView.go = { [weak self] in self?.go($0) }
        browser.children = { [weak self] in self?.children($0) ?? [] }
        browser.onSelect = { [weak self] in self?.selectionChanged() }
        browser.onOpen = { [weak self] in self?.openSelection() }
        [shelf, pathView, browser].forEach { window.body.addSubview($0) }
        // Open at about half the screen at most (never below the minimum size), so it doesn't fill a small VM display
        if let visible = NSScreen.main?.visibleFrame {
            let size = NSSize(width: max(window.minSize.width, min(window.frame.width, visible.width * 0.55)),
                              height: max(window.minSize.height, min(window.frame.height, visible.height * 0.6)))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        }
        window.center()
        let offset = CGFloat(FileViewer.viewers.count) * 24
        window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        go(start)
    }

    /// The selected file or folder (or the deepest open folder).
    var path: String { browser.path }

    var selectedPaths: [String] { browser.selectedPaths }

    func go(_ target: String) {
        var p = "/"
        for component in (target as NSString).pathComponents.dropFirst() {
            p = (p as NSString).appendingPathComponent(component)
            if component.hasPrefix(".") { revealed.insert(p) }
        }
        browser.load(target)
        selectionChanged()
    }

    func refresh() {
        let keep = path
        cache = [:]
        browser.load(FileManager.default.fileExists(atPath: keep) ? keep : (keep as NSString).deletingLastPathComponent)
        selectionChanged()
    }

    func selectionChanged() {
        pathView.path = path
        window.title = path
        if Inspector.shared.panel.isVisible { Inspector.shared.update(path) }
    }

    func openSelection() {
        for p in selectedPaths where !isFolder(p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    func recycleSelection() {
        let paths = selectedPaths
        guard !paths.isEmpty else { return NSSound.beep() }
        paths.forEach { try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }
        cache = [:]
        go((paths[0] as NSString).deletingLastPathComponent)
        FileViewer.viewers.forEach { $0.refresh() }
    }

    func newFolder() {
        let folder = isFolder(path) ? path : (path as NSString).deletingLastPathComponent
        var name = "New Folder", n = 2
        while FileManager.default.fileExists(atPath: (folder as NSString).appendingPathComponent(name)) { name = "New Folder \(n)"; n += 1 }
        let created = (folder as NSString).appendingPathComponent(name)
        guard (try? FileManager.default.createDirectory(atPath: created, withIntermediateDirectories: false)) != nil else { return NSSound.beep() }
        cache = [:]
        go(created)
    }

    func windowWillClose(_ notification: Notification) { FileViewer.viewers.removeAll { $0 === self } }

    /// A folder's contents as full paths, sorted by name, without hidden files.
    private func children(_ folder: String) -> [String] {
        if let cached = cache[folder] { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let list = names.map { (folder as NSString).appendingPathComponent($0) }
            .filter { !($0 as NSString).lastPathComponent.hasPrefix(".") || revealed.contains($0) }
            .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
        cache[folder] = list
        return list
    }
}
// MARK: NeXT windows

/// A NeXTSTEP window: square corners, black title bar (dark grey when inactive) with the title centred,
/// miniaturize button on the left, close button on the right, and a resize bar along the bottom.
/// Put content in `body`; it fills the space between the title bar and the resize bar.
final class NeXTWindow: NSWindow {
    static let titleHeight: CGFloat = 23
    static let resizeHeight: CGFloat = 9
    let body: NSView
    private let titleBar = NeXTTitleBar()
    private let resizeBar: NeXTResizeBar?

    init(body size: NSSize, resizable: Bool = true) {
        let barHeight = resizable ? NeXTWindow.resizeHeight : 0
        let frame = NSRect(x: 0, y: 0, width: size.width, height: size.height + NeXTWindow.titleHeight + barHeight)
        body = NSView(frame: NSRect(x: 0, y: barHeight, width: size.width, height: size.height))
        resizeBar = resizable ? NeXTResizeBar(frame: NSRect(x: 0, y: 0, width: size.width, height: barHeight)) : nil
        super.init(contentRect: frame, styleMask: [.borderless, .miniaturizable], backing: .buffered, defer: false)
        hasShadow = true
        backgroundColor = .black // the one-pixel frame around everything
        let frameView = NSView(frame: frame)
        body.autoresizingMask = [.width, .height]
        body.wantsLayer = true
        body.layer?.backgroundColor = face.cgColor
        titleBar.frame = NSRect(x: 0, y: frame.height - NeXTWindow.titleHeight, width: frame.width, height: NeXTWindow.titleHeight)
        titleBar.autoresizingMask = [.width, .minYMargin]
        frameView.addSubview(body)
        frameView.addSubview(titleBar)
        if let resizeBar {
            resizeBar.autoresizingMask = [.width, .maxYMargin]
            frameView.addSubview(resizeBar)
        }
        contentView = frameView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var title: String { didSet { titleBar.needsDisplay = true } }
    override func becomeKey() { super.becomeKey(); titleBar.needsDisplay = true }
    override func resignKey() { super.resignKey(); titleBar.needsDisplay = true }
    override func performClose(_ sender: Any?) {
        if delegate?.windowShouldClose?(self) == false { return }
        close()
    }
}

final class NeXTTitleBar: NSView {
    private var miniaturizeBox: NSRect { NSRect(x: 4, y: 4, width: 15, height: 15) }
    private var closeBox: NSRect { NSRect(x: bounds.maxX - 19, y: 4, width: 15, height: 15) }

    override func draw(_ dirtyRect: NSRect) {
        let key = window?.isKeyWindow == true
        fill(key ? .black : NSColor(calibratedWhite: 0.333, alpha: 1), bounds)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byTruncatingMiddle
        let title = (window?.title ?? "") as NSString
        let height = title.size(withAttributes: [.font: boldFont]).height
        title.draw(in: NSRect(x: 24, y: floor((bounds.height - height) / 2), width: bounds.width - 48, height: height),
                   withAttributes: [.font: boldFont, .foregroundColor: key ? NSColor.white : NSColor(calibratedWhite: 0.667, alpha: 1), .paragraphStyle: style])
        bevel(miniaturizeBox)
        let square = NSBezierPath(rect: miniaturizeBox.insetBy(dx: 4.5, dy: 4.5))
        NSColor.black.setStroke()
        square.stroke()
        bevel(closeBox)
        let x = NSBezierPath()
        let r = closeBox.insetBy(dx: 4, dy: 4)
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

/// NeXT's resize bar: drag it to resize; the end segments resize the width too, the middle only the height.
final class NeXTResizeBar: NSView {
    private let corner: CGFloat = 28

    override func draw(_ dirtyRect: NSRect) {
        bevel(bounds)
        fill(.black, NSRect(x: corner, y: 0, width: 1, height: bounds.height))
        fill(.black, NSRect(x: bounds.maxX - corner, y: 0, width: 1, height: bounds.height))
        fill(.white, NSRect(x: corner + 1, y: 1, width: 1, height: bounds.height - 2))
        fill(.white, NSRect(x: bounds.maxX - corner + 1, y: 1, width: 1, height: bounds.height - 2))
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let left = x < corner, right = x > bounds.maxX - corner
        let start = NSEvent.mouseLocation, frame = window.frame
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            let dx = p.x - start.x, dy = start.y - p.y
            var f = frame
            f.size.height = max(window.minSize.height, frame.height + dy)
            f.origin.y = frame.maxY - f.height // the top edge stays put
            if right { f.size.width = max(window.minSize.width, frame.width + dx) }
            if left {
                f.size.width = max(window.minSize.width, frame.width - dx)
                f.origin.x = frame.maxX - f.width
            }
            window.setFrame(f, display: true)
        }
    }
}



// MARK: Inspector

final class Inspector {
    static let shared = Inspector()
    let panel = NeXTWindow(body: NSSize(width: 300, height: 300), resizable: false)
    private let icon = NSImageView(frame: NSRect(x: 126, y: 236, width: 48, height: 48))
    private let text = NSTextField(wrappingLabelWithString: "")

    init() {
        panel.title = "Inspector"
        panel.isReleasedWhenClosed = false
        text.frame = NSRect(x: 16, y: 16, width: 268, height: 210)
        text.font = font
        text.isSelectable = true
        panel.body.addSubview(icon)
        panel.body.addSubview(text)
    }

    func show(_ path: String?) {
        update(path ?? NSHomeDirectory())
        if !panel.isVisible { panel.center() }
        NSApp.activate()
        panel.orderFront(nil)
    }

    func update(_ path: String) {
        icon.image = NSWorkspace.shared.icon(forFile: path)
        let attributes = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
        let kind = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.localizedTypeDescriptionKey]))?.localizedTypeDescription ?? ""
        let size = (attributes[.size] as? NSNumber).map { ByteCountFormatter.string(fromByteCount: $0.int64Value, countStyle: .file) } ?? ""
        let modified = (attributes[.modificationDate] as? Date).map { DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .short) } ?? ""
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        let rwx = (0..<9).map { bit in mode & (1 << (8 - bit)) != 0 ? Array("rwx")[bit % 3] : "-" }
        text.stringValue = """
        \(FileManager.default.displayName(atPath: path))

        Path: \((path as NSString).deletingLastPathComponent)
        Kind: \(kind)
        Size: \(isFolder(path) ? "—" : size)
        Modified: \(modified)
        Owner: \(attributes[.ownerAccountName] as? String ?? "")  Group: \(attributes[.groupOwnerAccountName] as? String ?? "")
        Permissions: \(String(rwx))
        """
    }
}

// build.sh: `NeXTWorkspace --icon <bundle id> <file.png>` writes a 1024-pixel app icon layer, the Dock tile's drawing on transparent (build.sh puts it on NeXT grey)
// scaled up 16× (same lines and shadows), and exits. The Workspace's own icon is the NeXT cube.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--icon" {
    let id = CommandLine.arguments[2]
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.cgContext.scaleBy(x: 1024 / tileSize, y: 1024 / tileSize)
    if id == "com.macaroon.NeXTWorkspace" {
        Tile(path: nil).drawCube()
    } else if !NeXTIcons.draw(identifier: id, in: NSRect(x: 8, y: 8, width: tileSize - 16, height: tileSize - 16)) {
        exit(1)
    }
    NSGraphicsContext.current = nil
    guard (try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[3]))) != nil else { exit(1) }
    exit(0)
}

let application = NSApplication.shared
// Only one Workspace: a copy started by the LaunchAgent and one from a relaunch (open -n) would each show a
// main menu and a Dock. The newest wins (it has the fresh Accessibility grant); a normal quit exits 0, so
// the LaunchAgent doesn't restart the old one.
for other in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
where other != .current { other.terminate() }
application.setActivationPolicy(.accessory)
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
let dock = Dock()
let mainMenu = MainMenu()
application.run()
