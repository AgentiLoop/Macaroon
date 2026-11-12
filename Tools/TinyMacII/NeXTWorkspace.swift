// NeXT Workspace for TinyMacII: NeXTSTEP's Dock (a column of 64-pt tiles on the right edge, double-click to
// launch, "…" on apps that aren't running, drop apps on it to add them) and its vertical main menu (top left:
// the front app's menus, then Hide and Quit; drag it by its black title). The menu mirrors the front app's real
// menu bar through the Accessibility API, so it needs Privacy & Security > Accessibility.
import AppKit
import ApplicationServices

let tileSize: CGFloat = 64
let rowHeight: CGFloat = 20
let menuWidth: CGFloat = 150
let face = NSColor(calibratedWhite: 0.667, alpha: 1)
let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
let boldFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)

func fill(_ color: NSColor, _ rect: NSRect) { color.setFill(); rect.fill() }

/// NeXT's raised bevel: white top and left edges, black bottom and right, dark grey inner shadow.
func bevel(_ r: NSRect) {
    fill(face, r)
    fill(.white, NSRect(x: r.minX, y: r.maxY - 1, width: r.width, height: 1))
    fill(.white, NSRect(x: r.minX, y: r.minY, width: 1, height: r.height))
    fill(.black, NSRect(x: r.minX, y: r.minY, width: r.width, height: 1))
    fill(.black, NSRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height))
    let shade = NSColor(calibratedWhite: 0.333, alpha: 1)
    fill(shade, NSRect(x: r.minX + 1, y: r.minY + 1, width: r.width - 2, height: 1))
    fill(shade, NSRect(x: r.maxX - 2, y: r.minY + 1, width: 1, height: r.height - 2))
}

func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
    p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
    p.hidesOnDeactivate = false
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
    static let standard = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Mail.app",
                           "/System/Applications/TextEdit.app", "/System/Applications/Utilities/Terminal.app",
                           "/System/Applications/Calculator.app", "/System/Applications/System Settings.app"]
    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "DockApps") ?? standard.filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "DockApps") }
    }
}

final class Tile: NSView {
    let path: String? // nil: the Workspace tile at the top
    var changed: () -> Void = {}

    init(path: String?) {
        self.path = path
        super.init(frame: NSRect(x: 0, y: 0, width: tileSize, height: tileSize))
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        bevel(bounds)
        guard let path else { return drawCube() }
        NSWorkspace.shared.icon(forFile: path).draw(in: bounds.insetBy(dx: 8, dy: 8))
        let running = NSWorkspace.shared.runningApplications.contains { $0.bundleURL?.standardizedFileURL.path == path }
        if !running {
            ("…" as NSString).draw(at: NSPoint(x: 4, y: 2), withAttributes: [.font: boldFont, .foregroundColor: NSColor.black])
        }
    }

    /// A shaded cube, the Workspace's own tile.
    private func drawCube() {
        let c = NSPoint(x: bounds.midX, y: bounds.midY), s: CGFloat = 20
        func face(_ points: [NSPoint], _ white: CGFloat) {
            let path = NSBezierPath()
            path.move(to: points[0])
            points.dropFirst().forEach { path.line(to: $0) }
            path.close()
            NSColor(calibratedWhite: white, alpha: 1).setFill()
            path.fill()
        }
        face([NSPoint(x: c.x, y: c.y + s), NSPoint(x: c.x + s, y: c.y + s / 2), c, NSPoint(x: c.x - s, y: c.y + s / 2)], 0.35)
        face([NSPoint(x: c.x - s, y: c.y + s / 2), c, NSPoint(x: c.x, y: c.y - s), NSPoint(x: c.x - s, y: c.y - s / 2)], 0.05)
        face([c, NSPoint(x: c.x + s, y: c.y + s / 2), NSPoint(x: c.x + s, y: c.y - s / 2), NSPoint(x: c.x, y: c.y - s)], 0.2)
    }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else { return }
        if let path {
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory())) // a File Viewer on the home folder
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

    private func droppedApps(_ info: NSDraggingInfo) -> [String] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        return urls.filter { $0.pathExtension == "app" }.map(\.path)
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { droppedApps(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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
        let tiles = [Tile(path: nil)] + DockApps.paths.map { Tile(path: $0) }
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

// MARK: Vertical main menu

final class Row: NSView {
    enum Kind { case title, item, submenu }
    let title: String
    let kind: Kind
    let action: (Row) -> Void

    init(_ title: String, _ kind: Kind, action: @escaping (Row) -> Void = { _ in }) {
        self.title = title
        self.kind = kind
        self.action = action
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let color: NSColor
        if kind == .title {
            fill(.black, bounds)
            color = .white
        } else {
            bevel(bounds)
            color = .black
        }
        (title as NSString).draw(at: NSPoint(x: 6, y: 3), withAttributes: [.font: kind == .title ? boldFont : font, .foregroundColor: color])
        if kind == .submenu { // NeXT's little arrow for items that open a submenu
            let x = bounds.maxX - 12, y = bounds.midY
            let arrow = NSBezierPath()
            arrow.move(to: NSPoint(x: x, y: y + 4))
            arrow.line(to: NSPoint(x: x + 6, y: y))
            arrow.line(to: NSPoint(x: x, y: y - 4))
            arrow.close()
            NSColor.black.setFill()
            arrow.fill()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if kind == .title { window?.performDrag(with: event) } else { action(self) }
    }
}

final class MainMenu: NSObject {
    let window = makePanel()
    var app = NSWorkspace.shared.frontmostApplication

    override init() {
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app != .current else { return }
            self?.app = app
            self?.reload()
        }
        reload()
    }

    func reload() {
        let isFinder = app?.bundleIdentifier == "com.apple.finder"
        var rows = [Row(isFinder ? "Workspace" : app?.localizedName ?? "Workspace", .title)]
        if AXIsProcessTrusted(), let app {
            let app = AXUIElementCreateApplication(app.processIdentifier)
            let bar = axValue(app, kAXMenuBarAttribute).map { $0 as! AXUIElement }
            // Skip the Apple menu; the app's own menu becomes Info, as on NeXTSTEP
            for (i, item) in (bar.map(axChildren) ?? []).dropFirst().enumerated() {
                let name = i == 0 ? "Info" : axString(item, kAXTitleAttribute) ?? ""
                if !name.isEmpty { rows.append(Row(name, .submenu) { [weak self] row in self?.popUp(item, from: row) }) }
            }
        } else {
            rows.append(Row("Allow Menus…", .item) { _ in
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            })
        }
        rows.append(Row("Hide", .item) { [weak self] _ in _ = self?.app?.hide() })
        if !isFinder { rows.append(Row("Quit", .item) { [weak self] _ in _ = self?.app?.terminate() }) }

        let height = CGFloat(rows.count) * rowHeight
        let content = NSView(frame: NSRect(x: 0, y: 0, width: menuWidth, height: height))
        for (i, row) in rows.enumerated() {
            row.frame = NSRect(x: 0, y: height - CGFloat(i + 1) * rowHeight, width: menuWidth, height: rowHeight)
            content.addSubview(row)
        }
        // Keep the top left corner where it is (the user may have dragged the menu)
        let screen = NSScreen.main?.frame ?? .zero
        let placed = window.frame.height > 0
        let left = placed ? window.frame.minX : screen.minX, top = placed ? window.frame.maxY : screen.maxY
        window.contentView = content
        window.setFrame(NSRect(x: left, y: top - height, width: menuWidth, height: height), display: true)
    }

    /// Opens the app's real submenu to the right of the row, like NeXTSTEP's cascading menus.
    private func popUp(_ item: AXUIElement, from row: Row) {
        guard let axMenu = axChildren(item).first else { return }
        buildMenu(axMenu, depth: 0).popUp(positioning: nil, at: NSPoint(x: row.bounds.maxX, y: row.bounds.maxY), in: row)
    }

    private func buildMenu(_ axMenu: AXUIElement, depth: Int) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.font = font
        for child in axChildren(axMenu) {
            let title = axString(child, kAXTitleAttribute) ?? ""
            if title.isEmpty {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: title, action: #selector(press(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = child
            item.isEnabled = axValue(child, kAXEnabledAttribute) as? Bool ?? true
            if let key = axString(child, kAXMenuItemCmdCharAttribute), key.count == 1 {
                item.keyEquivalent = key.lowercased()
                item.keyEquivalentModifierMask = .command
            }
            if depth < 3, let submenu = axChildren(child).first {
                item.submenu = buildMenu(submenu, depth: depth + 1)
                item.action = nil
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func press(_ sender: NSMenuItem) {
        guard let element = sender.representedObject else { return }
        AXUIElementPerformAction(element as! AXUIElement, kAXPressAction as CFString)
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
let dock = Dock()
let mainMenu = MainMenu()
application.run()
