// NeXT Apps for MacCube: macOS's Apps (Launchpad) browser dressed as a NeXTSTEP app. Square NeXT window with a
// search field and a shelf of category buttons (All, Productivity, Utilities, Creativity, Reading, Social,
// Entertainment, Other), then every installed app as a raised grey tile with its name, in a
// scroll view with the NeXT scroller on the left. Recently opened apps lead the list. Click a tile to open the app;
// drag it onto NeXT Workspace's Dock to keep it there. Icons are greyscale, like the NeXT Dock, except the NeXT apps'.
import AppKit
import CoreImage

// MARK: Apps

struct App: Hashable {
    let url: URL
    let name: String
    let category: String
    let identifier: String?
}

enum Catalog {
    static let categories = ["All", "Productivity", "Utilities", "Creativity", "Reading", "Social", "Entertainment", "Other"]
    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                          NSHomeDirectory() + "/Applications"]

    /// Apple's App Store categories (LSApplicationCategoryType), grouped the way the Apps panel groups them.
    static func category(_ type: String?, identifier: String?) -> String {
        let fallback: [String: String] = [
            "com.apple.calculator": "Utilities", "com.apple.clock": "Utilities", "com.apple.findmy": "Utilities",
            "com.apple.DiskUtility": "Utilities", "com.apple.Passwords": "Utilities", "com.apple.ScreenContinuity": "Utilities",
            "com.apple.Magnifier": "Utilities", "com.apple.weather": "Reading", "com.apple.stocks": "Productivity",
            "com.apple.podcasts": "Entertainment", "com.apple.mobilephone": "Social", "com.apple.Home": "Productivity",
            "com.apple.Safari": "Reading", "com.apple.finder": "Utilities",
            "com.macaroon.NeXTBrowser": "Reading", "com.macaroon.NeXTEdit": "Productivity",
            "com.macaroon.NeXTTerminal": "Utilities", "com.macaroon.NeXTCalculator": "Utilities",
            "com.macaroon.NeXTWorkspace": "Utilities", "com.macaroon.NeXTApps": "Utilities",
        ]
        guard let kind = type?.replacingOccurrences(of: "public.app-category.", with: "") else {
            return identifier.flatMap { fallback[$0] } ?? "Other"
        }
        switch kind {
        case "productivity", "finance", "business": return "Productivity"
        case "utilities", "developer-tools": return "Utilities"
        case "graphics-design", "photography", "video": return "Creativity"
        case "reference", "news", "books", "education", "weather", "lifestyle", "travel", "medical", "healthcare-fitness":
            return "Reading"
        case "social-networking": return "Social"
        case "entertainment", "music", "sports", "games": return "Entertainment"
        default: return kind.hasSuffix("-games") ? "Entertainment" : identifier.flatMap { fallback[$0] } ?? "Other"
        }
    }

    static func load() -> [App] {
        var seen = Set<String>(), apps: [App] = []
        for folder in folders {
            let dir = URL(fileURLWithPath: folder).standardizedFileURL
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = dir.appendingPathComponent(name)
                let bundle = Bundle(url: url), id = bundle?.bundleIdentifier
                if let id, seen.contains(id) { continue }
                if let id { seen.insert(id) }
                if bundle?.object(forInfoDictionaryKey: "LSUIElement") as? Bool == true, id != "com.macaroon.NeXTWorkspace" { continue }
                let title = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
                let type = bundle?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
                apps.append(App(url: url, name: title, category: category(type, identifier: id), identifier: id))
            }
        }
        return apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Paths of apps opened from here, newest first.
    static var recent: [String] {
        get { UserDefaults.standard.stringArray(forKey: "Recent") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(7)), forKey: "Recent") }
    }
}

// MARK: Icons

enum Icons {
    private static var cache: [URL: NSImage] = [:]
    /// The app's icon, in grey unless it's one of the NeXT apps (whose icons are already NeXT).
    static func icon(_ app: App) -> NSImage {
        if let cached = cache[app.url] { return cached }
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        let image: NSImage
        if app.identifier?.hasPrefix("com.macaroon.") == true {
            image = icon
        } else {
            image = hardGrey(icon) ?? icon
        }
        cache[app.url] = image
        return image
    }

    /// NeXT-style grey: no colour, strong contrast and sharpened edges, so the icon reads as hard line work.
    private static func hardGrey(_ icon: NSImage) -> NSImage? {
        var rect = NSRect(x: 0, y: 0, width: 128, height: 128)
        guard let cg = icon.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        var image = CIImage(cgImage: cg)
        image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 1.7, kCIInputBrightnessKey: -0.06])
        image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.0, kCIInputIntensityKey: 1.6])
        image = image.applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 0.8, kCIInputIntensityKey: 1.0])
        let context = CIContext()
        guard let out = context.createCGImage(image.cropped(to: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)), from: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)) else { return nil }
        return NSImage(cgImage: out, size: NSSize(width: 96, height: 96))
    }
}

// MARK: Grid

final class Grid: NSView, NSDraggingSource {
    static let cell = NSSize(width: 104, height: 100), tile: CGFloat = 64
    var apps: [App] = [] { didSet { layoutGrid() } }
    /// Apps before this index are the "Recently Opened" row.
    var recentCount = 0 { didSet { layoutGrid() } }
    var open: (App) -> Void = { _ in }
    private var pressed: Int?
    private var headerHeight: CGFloat { recentCount > 0 ? 22 : 0 }

    override var isFlipped: Bool { true }
    private var columns: Int { max(1, Int((bounds.width - 8) / Grid.cell.width)) }

    /// Frame of the i-th app's cell: recents in their own row under a heading, then the rest.
    private func cellRect(_ i: Int) -> NSRect {
        let cols = columns
        var index = i, top: CGFloat = 8
        if recentCount > 0 {
            if i < recentCount {
                top += headerHeight
            } else {
                index = i - recentCount
                top += headerHeight + CGFloat((recentCount + cols - 1) / cols) * Grid.cell.height + headerHeight
            }
        }
        let x = 8 + CGFloat(index % cols) * Grid.cell.width, y = top + CGFloat(index / cols) * Grid.cell.height
        return NSRect(x: x, y: y, width: Grid.cell.width, height: Grid.cell.height)
    }

    func layoutGrid() {
        let height = apps.isEmpty ? 0 : cellRect(apps.count - 1).maxY + 8
        setFrameSize(NSSize(width: frame.width, height: max(height, enclosingScrollView?.contentSize.height ?? 0)))
        needsDisplay = true
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        layoutGrid()
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, dirtyRect)
        if recentCount > 0 {
            heading("Recently Opened", y: 8)
            heading("Applications", y: cellRect(recentCount).minY - headerHeight)
        }
        for (i, app) in apps.enumerated() {
            let cell = cellRect(i)
            guard cell.intersects(dirtyRect) else { continue }
            let tile = NSRect(x: cell.midX - Grid.tile / 2, y: cell.minY + 4, width: Grid.tile, height: Grid.tile)
            bevel(tile, sunken: pressed == i, color: pressed == i ? .white : face)
            Icons.icon(app).draw(in: tile.insetBy(dx: 8, dy: 8), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineBreakMode = .byTruncatingTail
            (app.name as NSString).draw(in: NSRect(x: cell.minX + 2, y: tile.maxY + 4, width: cell.width - 4, height: 16),
                                        withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
        }
    }

    private func heading(_ text: String, y: CGFloat) {
        (text as NSString).draw(at: NSPoint(x: 12, y: y + 2), withAttributes: [.font: boldFont, .foregroundColor: NSColor.black])
        fill(dark, NSRect(x: 8, y: y + 19, width: bounds.width - 16, height: 1))
        fill(.white, NSRect(x: 8, y: y + 20, width: bounds.width - 16, height: 1))
    }

    private func index(at point: NSPoint) -> Int? {
        apps.indices.first { i in
            let cell = cellRect(i)
            return NSRect(x: cell.midX - Grid.tile / 2, y: cell.minY + 4, width: Grid.tile, height: Grid.tile + 20).contains(point)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window, let i = index(at: convert(event.locationInWindow, from: nil)) else { return }
        pressed = i
        needsDisplay = true
        let start = event.locationInWindow
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                pressed = nil
                needsDisplay = true
                if index(at: convert(next.locationInWindow, from: nil)) == i { open(apps[i]) }
                return
            }
            if hypot(next.locationInWindow.x - start.x, next.locationInWindow.y - start.y) > 4 {
                // Dragged: hand the app over as a file, so it can be dropped on the NeXT Dock or anywhere else
                pressed = nil
                needsDisplay = true
                let item = NSDraggingItem(pasteboardWriter: apps[i].url as NSURL)
                let cell = cellRect(i)
                item.setDraggingFrame(NSRect(x: cell.midX - Grid.tile / 2, y: cell.minY + 4, width: Grid.tile, height: Grid.tile), contents: Icons.icon(apps[i]))
                beginDraggingSession(with: [item], event: next, source: self)
                return
            }
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}

// MARK: Window

final class AppsWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate, NSTextFieldDelegate {
    static let shared = AppsWindow()
    let window = NeXTWindow(body: NSSize(width: 760, height: 540))
    private let grid = Grid()
    private let search = NSTextField()
    private var buttons: [NeXTButton] = []
    private var all: [App] = []
    private var category = "All" { didSet { refresh() } }

    private override init() {
        super.init()
        window.title = "Applications"
        window.minSize = NSSize(width: 360, height: 260)
        window.isReleasedWhenClosed = false
        window.delegate = self
        let body = window.body, w = body.bounds.width, h = body.bounds.height

        // Search field in a sunken well, across the top
        let well = SunkenWell(frame: NSRect(x: 8, y: h - 32, width: w - 16, height: 24))
        well.autoresizingMask = [.width, .minYMargin]
        body.addSubview(well)
        search.frame = well.bounds.insetBy(dx: 4, dy: 3)
        search.autoresizingMask = [.width]
        search.isBordered = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.font = font
        search.textColor = .black
        search.placeholderAttributedString = NSAttributedString(string: "Search", attributes: [.font: font, .foregroundColor: dark])
        search.appearance = NSAppearance(named: .aqua)
        search.delegate = self
        well.addSubview(search)

        // The category shelf: one bevelled button per category, the chosen one pressed in
        let shelf = NSView(frame: NSRect(x: 8, y: h - 62, width: w - 16, height: 24))
        shelf.autoresizingMask = [.width, .minYMargin]
        body.addSubview(shelf)
        buttons = Catalog.categories.map { name in NeXTButton(name) { [weak self] in self?.category = name } }
        buttons.forEach(shelf.addSubview)
        shelf.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(layoutShelf(_:)), name: NSView.frameDidChangeNotification, object: shelf)
        layoutShelf(Notification(name: NSView.frameDidChangeNotification, object: shelf))

        let scroll = NeXTScrollView(frame: NSRect(x: 0, y: 0, width: w, height: h - 70))
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = face
        grid.frame = NSRect(origin: .zero, size: scroll.contentSize)
        grid.autoresizingMask = [.width]
        grid.open = { [weak self] in self?.open($0) }
        scroll.documentView = grid
        scroll.verticalLineScroll = 24
        body.addSubview(scroll)

        reload()
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.reloadSoon() }
        }
    }

    /// Category buttons share the shelf's width in proportion to their titles.
    @objc private func layoutShelf(_ note: Notification) {
        guard let shelf = note.object as? NSView else { return }
        let widths = buttons.map { ($0.title as NSString).size(withAttributes: [.font: boldFont]).width + 16 }
        let total = widths.reduce(0, +), scale = shelf.bounds.width / total
        var x: CGFloat = 0
        for (button, width) in zip(buttons, widths) {
            button.frame = NSRect(x: x.rounded(), y: 0, width: (x + width * scale).rounded() - x.rounded(), height: shelf.bounds.height)
            x += width * scale
        }
    }

    private var pending = false
    /// Apps installed or removed while open show up within a few seconds.
    private func reloadSoon() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.pending = false; self?.reload() }
    }

    func reload() {
        all = Catalog.load()
        refresh()
    }

    private func refresh() {
        let query = search.stringValue.trimmingCharacters(in: .whitespaces)
        var shown = all.filter { category == "All" || $0.category == category }
        if !query.isEmpty { shown = shown.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        // Recently opened lead the full list, as in the Apps panel
        let recent = category == "All" && query.isEmpty
            ? Catalog.recent.compactMap { path in all.first { $0.url.path == path } } : []
        grid.recentCount = recent.count
        grid.apps = recent + shown
        window.title = category == "All" ? "Applications" : "Applications — \(category)"
        highlightCategory()
    }

    /// The chosen category's button is pushed in and lit with a black title; the others have mid-grey titles.
    private func highlightCategory() {
        for button in buttons {
            let chosen = button.title == category
            button.latched = chosen
            button.textColor = chosen ? .black : NSColor(calibratedWhite: 0.4, alpha: 1)
        }
    }

    func open(_ app: App) {
        Catalog.recent = [app.url.path] + Catalog.recent.filter { $0 != app.url.path }
        NSWorkspace.shared.openApplication(at: app.url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { DispatchQueue.main.async { NSAlert(error: error).runModal() } }
        }
        refresh()
    }

    func controlTextDidChange(_ obj: Notification) { refresh() }

    /// Return opens the first match, as in the Apps panel.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)), let first = grid.apps.dropFirst(grid.recentCount).first ?? grid.apps.first {
            open(first)
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            search.stringValue = ""
            refresh()
            return true
        }
        return false
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
    }
}

// MARK: Menus and app

func buildMenus() {
    let windows = menu("Windows", [responder("Miniaturize Window", "performMiniaturize:", "m"), Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) }])
    NSApp.mainMenu = NSMenu()
    [
        menu("NeXT Apps", [
            Item("Info Panel…") { NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "The Apps panel in NeXTSTEP dress for MacCube, part of Macaroon.")]) },
            .separator(), responder("Hide", "hide:", "h"), Item("Quit", "q") { NSApp.terminate(nil) },
        ]),
        menu("Edit", [responder("Cut", "cut:", "x"), responder("Copy", "copy:", "c"), responder("Paste", "paste:", "v"), responder("Select All", "selectAll:", "a")]),
        menu("View", [Item("Find", "f") { AppsWindow.shared.show() }, Item("Reload", "r") { AppsWindow.shared.reload() }]),
        windows,
    ].forEach(NSApp.mainMenu!.addItem)
    NSApp.windowsMenu = windows.submenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        AppsWindow.shared.show()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppsWindow.shared.show()
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
