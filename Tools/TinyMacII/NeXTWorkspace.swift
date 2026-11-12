// NeXT Workspace for TinyMacII, after NeXTSTEP 3:
// • Dock: a column of 64-pt tiles on the right edge. Workspace cube on top (double-click: File Viewer), apps
//   (double-click to launch, "…" when not running, drop apps on it to add them), Recycler at the bottom.
// • Main menu: vertical, top left. Submenus cascade to the right as more columns; drag a submenu by its black
//   title to tear it off (it gets a close box). Shows the front app's real menus through Accessibility
//   (needs Privacy & Security > Accessibility), or the Workspace's own menus when a File Viewer is in front.
// • File Viewer: shelf, icon path, column browser (NeXT's NSBrowser). Inspector shows the selection's details.
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

func makePanel() -> NSPanel {
    let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    p.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))
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
    static let standard = ["/System/Library/CoreServices/Finder.app", "/Applications/Safari.app", "/System/Applications/Mail.app",
                           "/System/Applications/TextEdit.app", "/System/Applications/Utilities/Terminal.app",
                           "/System/Applications/Calculator.app", "/System/Applications/System Settings.app"]
    static var paths: [String] {
        get { UserDefaults.standard.stringArray(forKey: "DockApps") ?? standard.filter { FileManager.default.fileExists(atPath: $0) } }
        set { UserDefaults.standard.set(newValue, forKey: "DockApps") }
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
        if recycler {
            let full = (try? FileManager.default.contentsOfDirectory(atPath: trashPath))?.isEmpty == false
            NSImage(named: full ? NSImage.trashFullName : NSImage.trashEmptyName)?.draw(in: bounds.insetBy(dx: 10, dy: 10))
            return
        }
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
        if closeBox, closeBoxRect.contains(convert(event.locationInWindow, from: nil)) { return close() }
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

/// One menu column. Submenus open as attached columns to the right; dragging one tears it off.
final class MenuColumn {
    static var tornOff: [MenuColumn] = []
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
        for torn in MenuColumn.tornOff { torn.close() } // they belong to the previous app
        guard let app, app != .current else {
            column.title = "Workspace"
            return column.build(Self.workspaceEntries)
        }
        let isFinder = app.bundleIdentifier == "com.apple.finder"
        column.title = isFinder ? "Finder" : app.localizedName ?? "Workspace"
        var entries: [Entry] = []
        if AXIsProcessTrusted(), let bar = axValue(AXUIElementCreateApplication(app.processIdentifier), kAXMenuBarAttribute) {
            // Skip the Apple menu; the app's own menu becomes Info, as on NeXTSTEP
            for (i, item) in axChildren(bar as! AXUIElement).dropFirst().enumerated() {
                let name = i == 0 ? "Info" : axString(item, kAXTitleAttribute) ?? ""
                if !name.isEmpty, let menu = axChildren(item).first {
                    entries.append(Entry(title: name, kind: .submenu { axEntries(menu) }))
                }
            }
        } else {
            entries.append(Entry(title: "Allow Menus…", kind: .action {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }))
        }
        entries.append(Entry(title: "Hide", key: "h", kind: .action { _ = app.hide() }))
        if !isFinder { entries.append(Entry(title: "Quit", key: "q", kind: .action { _ = app.terminate() })) }
        column.build(entries)
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
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: x + 16, y: 24, width: 48, height: 48))
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
            NSWorkspace.shared.icon(forFile: path).draw(in: NSRect(x: x + slot / 2 - 24, y: 24, width: 48, height: 48))
            drawLabel(FileManager.default.displayName(atPath: path), in: NSRect(x: x + 4, y: 4, width: slot - 8, height: 16))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let i = Int(convert(event.locationInWindow, from: nil).x / slot), shown = shown
        if i < shown.count { go(shown[i]) }
    }
}

final class FileViewer: NSObject, NSWindowDelegate, NSBrowserDelegate {
    static var viewers: [FileViewer] = []
    static var current: FileViewer? { viewers.first { $0.window.isKeyWindow } ?? viewers.last }

    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 540), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    let browser = NSBrowser()
    let shelf = Shelf()
    let pathView = PathView()
    private var cache: [String: [NSString]] = [:]
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
        window.backgroundColor = face
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

        browser.delegate = self
        browser.target = self
        browser.action = #selector(selectionChanged)
        browser.doubleAction = #selector(openSelection)
        browser.minColumnWidth = 160
        browser.maxVisibleColumns = 4
        browser.allowsMultipleSelection = true
        browser.separatesColumns = true
        browser.isTitled = false
        browser.hasHorizontalScroller = true
        browser.setDraggingSourceOperationMask(.every, forLocal: true)
        browser.setDraggingSourceOperationMask(.every, forLocal: false)
        [shelf, pathView, browser].forEach { window.contentView?.addSubview($0) }
        window.center()
        let offset = CGFloat(FileViewer.viewers.count) * 24
        window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        go(start)
    }

    /// The selected file or folder (or the deepest open folder).
    var path: String {
        let p = browser.path()
        return p.isEmpty ? "/" : p
    }

    var selectedPaths: [String] {
        let column = browser.selectedColumn
        guard column >= 0, let rows = browser.selectedRowIndexes(inColumn: column) else { return [] }
        return rows.compactMap { browser.item(atRow: $0, inColumn: column) as? String }
    }

    func go(_ target: String) {
        var p = "/"
        for component in (target as NSString).pathComponents.dropFirst() {
            p = (p as NSString).appendingPathComponent(component)
            if component.hasPrefix(".") { revealed.insert(p) }
        }
        browser.loadColumnZero()
        browser.setPath(target)
        selectionChanged()
    }

    func refresh() {
        let keep = path
        cache = [:]
        browser.loadColumnZero()
        browser.setPath(FileManager.default.fileExists(atPath: keep) ? keep : (keep as NSString).deletingLastPathComponent)
        selectionChanged()
    }

    @objc func selectionChanged() {
        pathView.path = path
        window.title = path
        if Inspector.shared.panel.isVisible { Inspector.shared.update(path) }
    }

    @objc func openSelection() {
        for p in selectedPaths where !isFolder(p) { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
    }

    func recycleSelection() {
        let paths = selectedPaths
        guard !paths.isEmpty else { return NSSound.beep() }
        paths.forEach { try? FileManager.default.trashItem(at: URL(fileURLWithPath: $0), resultingItemURL: nil) }
        browser.setPath((paths[0] as NSString).deletingLastPathComponent)
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

    // Browser contents: items are full paths, shown by name
    private func children(_ item: Any?) -> [NSString] {
        let folder = item as? String ?? "/"
        if let cached = cache[folder] { return cached }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        let list = names.map { (folder as NSString).appendingPathComponent($0) }
            .filter { !($0 as NSString).lastPathComponent.hasPrefix(".") || revealed.contains($0) }
            .sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
            .map { $0 as NSString }
        cache[folder] = list
        return list
    }

    func rootItem(for browser: NSBrowser) -> Any? { "/" as NSString }
    func browser(_ browser: NSBrowser, numberOfChildrenOfItem item: Any?) -> Int { children(item).count }
    func browser(_ browser: NSBrowser, child index: Int, ofItem item: Any?) -> Any { children(item)[index] }
    func browser(_ browser: NSBrowser, isLeafItem item: Any?) -> Bool { !isFolder(item as? String ?? "/") }
    func browser(_ browser: NSBrowser, objectValueForItem item: Any?) -> Any? { ((item as? String ?? "/") as NSString).lastPathComponent }

    func browser(_ sender: NSBrowser, willDisplayCell cell: Any, atRow row: Int, column: Int) {
        guard let cell = cell as? NSBrowserCell, let path = sender.item(atRow: row, inColumn: column) as? String else { return }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icon.size = NSSize(width: 16, height: 16)
        cell.image = icon
        cell.font = font
    }

    // Drag files out of the browser (to the Recycler, the shelf, the Dock or other apps)
    func browser(_ browser: NSBrowser, canDragRowsWith rowIndexes: IndexSet, inColumn column: Int, with event: NSEvent) -> Bool { true }
    func browser(_ browser: NSBrowser, writeRowsWith rowIndexes: IndexSet, inColumn column: Int, to pasteboard: NSPasteboard) -> Bool {
        let urls = rowIndexes.compactMap { browser.item(atRow: $0, inColumn: column) as? String }.map { URL(fileURLWithPath: $0) as NSURL }
        pasteboard.clearContents()
        return pasteboard.writeObjects(urls)
    }
}

// MARK: Inspector

final class Inspector {
    static let shared = Inspector()
    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300), styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
    private let icon = NSImageView(frame: NSRect(x: 126, y: 236, width: 48, height: 48))
    private let text = NSTextField(wrappingLabelWithString: "")

    init() {
        panel.title = "Inspector"
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = face
        text.frame = NSRect(x: 16, y: 16, width: 268, height: 210)
        text.font = font
        text.isSelectable = true
        panel.contentView?.addSubview(icon)
        panel.contentView?.addSubview(text)
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

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
_ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
let dock = Dock()
let mainMenu = MainMenu()
application.run()
