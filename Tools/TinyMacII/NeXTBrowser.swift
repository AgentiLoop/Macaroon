// NeXT Browser for TinyMacII: a WebKit (WKWebView) browser dressed as a NeXTSTEP app. Square window with a black
// title bar and resize bar, bevelled Back / Forward / Reload / Home buttons, an address field (web address or
// search words), a sunken status line with loading progress. Downloads go to ~/Downloads (as in WebMan), file
// uploads use the open panel, pop-ups open new windows. Menus: Info, File, Edit, View, Go, Windows, which
// NeXT Workspace's vertical main menu shows.
import AppKit
import WebKit

let face = NSColor(calibratedWhite: 0.667, alpha: 1)
let dark = NSColor(calibratedWhite: 0.333, alpha: 1)
let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
let boldFont = NSFont(name: "Helvetica-Bold", size: 12) ?? .boldSystemFont(ofSize: 12)
let homePage = URL(string: "https://duckduckgo.com/")!

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

/// Turns what was typed into a URL: a full URL as is, "example.com" over https, anything else a search.
func address(_ typed: String) -> URL? {
    let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return nil }
    if text.contains("://") || text.hasPrefix("about:") { return URL(string: text) }
    if text.contains(" ") || !text.contains(".") {
        var search = URLComponents(string: "https://duckduckgo.com/")!
        search.queryItems = [URLQueryItem(name: "q", value: text)]
        return search.url
    }
    return URL(string: "https://" + text)
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
        bevel(well, sunken: true, color: NSColor(calibratedWhite: 0.75, alpha: 1))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingMiddle
        let height = (text as NSString).size(withAttributes: [.font: font]).height
        (text as NSString).draw(in: NSRect(x: well.minX + 6, y: well.midY - height / 2, width: well.width - 12, height: height),
                                withAttributes: [.font: font, .paragraphStyle: style])
    }
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
    override func performClose(_ sender: Any?) { close() }
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

// MARK: Browser window

final class Browser: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static var all: [Browser] = []
    static var front: Browser? { all.first { $0.window.isKeyWindow } ?? all.last }
    static var lastFind = ""

    let window = NeXTWindow(body: NSSize(width: 1000, height: 680))
    let web: WKWebView
    let field = NSTextField()
    let status = StatusLine()
    private var back: NeXTButton!, forward: NeXTButton!, reload: NeXTButton!
    private var watchers: [NSKeyValueObservation] = []

    @discardableResult
    static func open(_ url: URL?, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> Browser {
        let browser = Browser(url, configuration: configuration)
        all.append(browser)
        NSApp.activate()
        browser.window.makeKeyAndOrderFront(nil)
        return browser
    }

    private init(_ url: URL?, configuration: WKWebViewConfiguration) {
        web = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        let body = window.body, w = body.bounds.width, h = body.bounds.height
        let toolbar: CGFloat = 36, statusHeight: CGFloat = 22
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 480, height: 300)
        window.title = "NeXT Browser"

        back = NeXTButton("Back") { [weak self] in self?.web.goBack() }
        forward = NeXTButton("Forward") { [weak self] in self?.web.goForward() }
        reload = NeXTButton("Reload") { [weak self] in self?.reloadOrStop() }
        let home = NeXTButton("Home") { [weak self] in self?.web.load(URLRequest(url: homePage)) }
        var x: CGFloat = 6
        for (button, width) in [(back!, CGFloat(64)), (forward!, 72), (reload!, 64), (home, 58)] {
            button.frame = NSRect(x: x, y: h - toolbar + 5, width: width, height: 26)
            button.autoresizingMask = [.minYMargin]
            body.addSubview(button)
            x += width + 4
        }
        field.frame = NSRect(x: x + 6, y: h - toolbar + 6, width: w - x - 12, height: 24)
        field.autoresizingMask = [.width, .minYMargin]
        field.font = font
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.placeholderString = "Type a web address or search words"
        field.target = self
        field.action = #selector(go)
        body.addSubview(field)

        web.frame = NSRect(x: 0, y: statusHeight, width: w, height: h - toolbar - statusHeight)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        body.addSubview(web)
        status.frame = NSRect(x: 0, y: 0, width: w, height: statusHeight)
        status.autoresizingMask = [.width, .maxYMargin]
        body.addSubview(status)

        watchers = [
            web.observe(\.title) { [weak self] web, _ in self?.window.title = web.title?.isEmpty == false ? web.title! : "NeXT Browser" },
            web.observe(\.url) { [weak self] web, _ in
                guard let self, self.field.currentEditor() == nil else { return }
                self.field.stringValue = web.url?.absoluteString ?? ""
            },
            web.observe(\.canGoBack) { [weak self] web, _ in self?.back.isEnabled = web.canGoBack },
            web.observe(\.canGoForward) { [weak self] web, _ in self?.forward.isEnabled = web.canGoForward },
            web.observe(\.isLoading) { [weak self] web, _ in self?.reload.title = web.isLoading ? "Stop" : "Reload" },
            web.observe(\.estimatedProgress) { [weak self] web, _ in
                if web.isLoading { self?.status.text = "Loading \(Int(web.estimatedProgress * 100))%  \(web.url?.host ?? "")" }
            },
        ]
        back.isEnabled = false
        forward.isEnabled = false
        let offset = CGFloat(Browser.all.count % 8) * 24
        // Open at about half the screen at most (never below the minimum size), so it doesn't fill a small VM display
        if let visible = NSScreen.main?.visibleFrame {
            let size = NSSize(width: max(window.minSize.width, min(window.frame.width, visible.width * 0.55)),
                              height: max(window.minSize.height, min(window.frame.height, visible.height * 0.6)))
            window.setFrame(NSRect(origin: window.frame.origin, size: size), display: false)
        }
        window.center()
        window.setFrameOrigin(NSPoint(x: window.frame.minX + offset, y: window.frame.minY - offset))
        if let url { web.load(URLRequest(url: url)) }
    }

    @objc func go() {
        guard let url = address(field.stringValue) else { return NSSound.beep() }
        web.load(URLRequest(url: url))
        window.makeFirstResponder(web)
    }

    func reloadOrStop() { if web.isLoading { web.stopLoading() } else { web.reload() } }

    func openLocation() {
        window.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func zoom(_ factor: CGFloat?) { web.pageZoom = factor.map { min(3, max(0.5, web.pageZoom * $0)) } ?? 1 }

    func find(again: Bool) {
        if !again || Browser.lastFind.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Find"
            alert.addButton(withTitle: "Find")
            alert.addButton(withTitle: "Cancel")
            let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            input.stringValue = Browser.lastFind
            alert.accessoryView = input
            alert.window.initialFirstResponder = input
            guard alert.runModal() == .alertFirstButtonReturn, !input.stringValue.isEmpty else { return }
            Browser.lastFind = input.stringValue
        }
        let options = WKFindConfiguration()
        options.wraps = true
        web.find(Browser.lastFind, configuration: options) { [weak self] result in
            if !result.matchFound { self?.status.text = "“\(Browser.lastFind)” not found"; NSSound.beep() }
        }
    }

    func printPage() {
        let operation = web.printOperation(with: .shared)
        operation.view?.frame = web.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func windowWillClose(_ notification: Notification) {
        watchers = []
        Browser.all.removeAll { $0 === self }
    }

    // MARK: Navigation

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { status.text = "Done  \(webView.url?.host ?? "")" }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }

    private func failed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        status.text = error.localizedDescription
    }

    // MARK: Downloads (into ~/Downloads, never overwriting)

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let base = (suggestedFilename as NSString).deletingPathExtension, ext = (suggestedFilename as NSString).pathExtension
        var destination = folder.appendingPathComponent(suggestedFilename), n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        status.text = "Downloading \(destination.lastPathComponent)…"
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) { status.text = "Download finished: saved in Downloads" }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { status.text = "Download failed: \(error.localizedDescription)" }

    // MARK: Pages asking for things

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        Browser.open(nil, configuration: configuration).web // pop-ups and target=_blank links get their own window
    }

    func webViewDidClose(_ webView: WKWebView) { window.close() }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        completionHandler(panel.runModal() == .OK ? panel.urls : nil)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Alert"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Confirm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
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

func buildMenus() {
    let front = { Browser.front }
    let windows = menu("Windows", [responder("Miniaturize Window", "performMiniaturize:", "m"), Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) }])
    NSApp.mainMenu = NSMenu()
    [
        menu("NeXT Browser", [
            Item("Info Panel…") { NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "A WebKit browser in NeXTSTEP dress for TinyMacII, part of Macaroon.")]) },
            .separator(), responder("Hide", "hide:", "h"), Item("Quit", "q") { NSApp.terminate(nil) },
        ]),
        menu("File", [
            Item("New Window", "n") { Browser.open(homePage) },
            Item("Open Location…", "l") { (front() ?? Browser.open(nil)).openLocation() },
            Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) },
            .separator(), Item("Print…", "p") { front()?.printPage() },
        ]),
        menu("Edit", [
            responder("Undo", "undo:", "z"), responder("Redo", "redo:", "z", [.command, .shift]), .separator(),
            responder("Cut", "cut:", "x"), responder("Copy", "copy:", "c"), responder("Paste", "paste:", "v"),
            responder("Select All", "selectAll:", "a"), .separator(),
            Item("Find…", "f") { front()?.find(again: false) }, Item("Find Again", "g") { front()?.find(again: true) },
        ]),
        menu("View", [
            Item("Reload", "r") { front()?.web.reload() }, Item("Stop", ".") { front()?.web.stopLoading() }, .separator(),
            Item("Larger Text", "+") { front()?.zoom(1.1) }, Item("Smaller Text", "-") { front()?.zoom(1 / 1.1) },
            Item("Actual Size", "0") { front()?.zoom(nil) },
        ]),
        menu("Go", [
            Item("Back", "[") { front()?.web.goBack() }, Item("Forward", "]") { front()?.web.goForward() },
            Item("Home", "h", [.command, .shift]) { front()?.web.load(URLRequest(url: homePage)) },
        ]),
        windows,
    ].forEach(NSApp.mainMenu!.addItem)
    NSApp.windowsMenu = windows.submenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        Browser.open(homePage)
    }

    /// Links opened from other apps (NeXT Browser as the default browser) and files dropped on it.
    func application(_ application: NSApplication, open urls: [URL]) { urls.forEach { Browser.open($0) } }

    /// Clicking the Dock tile with no windows open brings a new one, as NeXT apps did.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Browser.open(homePage) }
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
