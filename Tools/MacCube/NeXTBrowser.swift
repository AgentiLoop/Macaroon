// NeXT Browser for MacCube: a WebKit (WKWebView) browser dressed as a NeXTSTEP app. Square window with a black
// title bar and resize bar, bevelled Back / Forward / Reload / Home buttons, an address field (web address or
// search words), a favorites bar (a sunken shelf of bevelled buttons), a sunken status line with loading
// progress, and a History panel listing the pages visited. Downloads go to ~/Downloads (as in WebMan), file
// uploads use the open panel, pop-ups open new windows. Menus: Info, File, Edit, View, Go, Favorites, Windows,
// which NeXT Workspace's vertical main menu shows.
import AppKit
import WebKit

let homePage = URL(string: "https://duckduckgo.com/")!

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

// MARK: Browser window

/// WebKit's page scrollbars can't be restyled reliably (pages and newer WebKit override ::-webkit-scrollbar), so
/// they're hidden and the page gets an AppKit PageScroller instead; the page reports its scroll position to it.
/// Pages scroll vertically only: no horizontal scrolling or scrollbar.
let hideScrollbarsCSS = "html,body{scrollbar-width:none !important;overflow-x:hidden !important}::-webkit-scrollbar{display:none !important;width:0 !important;height:0 !important}"

let scrollbarScript = WKUserScript(source: """
    (function(){var s=document.createElement('style');s.textContent='\(hideScrollbarsCSS)';
    (document.head||document.documentElement).appendChild(s);})();
    """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

let scrollReportScript = WKUserScript(source: """
    (function(){function post(){var e=document.scrollingElement||document.documentElement;
    window.webkit.messageHandlers.pageScroll.postMessage([e.scrollTop,e.scrollHeight,e.clientHeight]);}
    addEventListener('scroll',post,{passive:true});addEventListener('resize',post);addEventListener('load',post);
    new ResizeObserver(post).observe(document.documentElement);post();})();
    """, injectionTime: .atDocumentEnd, forMainFrameOnly: true)

/// Routes each page's scroll report to its window's scroller.
final class ScrollReports: NSObject, WKScriptMessageHandler {
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let values = message.body as? [NSNumber], values.count == 3,
              let browser = Browser.all.first(where: { $0.web === message.webView }) else { return }
        browser.scroller.update(top: CGFloat(truncating: values[0]), content: CGFloat(truncating: values[1]), visible: CGFloat(truncating: values[2]))
    }
}
let scrollReports = ScrollReports()

/// The page's scroller, the File Viewer's: on the left, dark track, bevelled knob, both arrow buttons at the bottom.
final class PageScroller: NSView {
    static let bar: CGFloat = 18
    var scroll: (CGFloat) -> Void = { _ in }
    private var top: CGFloat = 0, content: CGFloat = 0, visible: CGFloat = 0
    private let bar = PageScroller.bar
    private var maxTop: CGFloat { max(0, content - visible) }
    private var downButton: NSRect { NSRect(x: 0, y: 0, width: bar, height: bar) }
    private var upButton: NSRect { NSRect(x: 0, y: bar, width: bar, height: bar) }
    private var track: NSRect { NSRect(x: 0, y: 2 * bar, width: bar, height: max(0, bounds.height - 2 * bar)) }
    private var knob: NSRect {
        let height = min(track.height, max(bar, track.height * visible / max(content, 1)))
        return NSRect(x: 0, y: track.maxY - height - (track.height - height) * top / max(maxTop, 1), width: bar, height: height)
    }

    func update(top: CGFloat, content: CGFloat, visible: CGFloat) {
        (self.top, self.content, self.visible) = (top, content, visible)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        fill(trackColor(self), track)
        if maxTop > 0 { bevel(knob.insetBy(dx: 1, dy: 1)) }
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

    private func go(_ newTop: CGFloat) {
        top = min(maxTop, max(0, newTop))
        needsDisplay = true
        scroll(top)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if upButton.contains(p) { return go(top - 40) }
        if downButton.contains(p) { return go(top + 40) }
        guard maxTop > 0, let window else { return }
        let grab = knob.contains(p) ? knob.maxY - p.y : knob.height / 2
        func move(_ y: CGFloat) { go((track.maxY - (y + grab)) / max(track.height - knob.height, 1) * maxTop) }
        move(p.y)
        while let next = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            move(convert(next.locationInWindow, from: nil).y)
        }
    }
}

/// The page view. Pages like DuckDuckGo focus their own search box as they load, which made WebKit take the
/// keyboard from the address field mid-typing; it only takes it now when the user clicks in the page or tabs in.
final class PageView: WKWebView {
    var addressActive: () -> Bool = { false }
    var giveBackFocus: () -> Void = {}
    var userFocused: () -> Void = {}

    override func becomeFirstResponder() -> Bool {
        let user: Bool
        switch NSApp.currentEvent?.type {
        case .leftMouseDown?, .rightMouseDown?, .otherMouseDown?, .keyDown?: user = true
        default: user = false
        }
        if !user, addressActive() {
            DispatchQueue.main.async { self.giveBackFocus() }
            return false
        }
        if user { userFocused() }
        return super.becomeFirstResponder()
    }
}

// MARK: Favorites and history

/// A favorite or a visited page.
struct Page: Codable {
    var title: String
    var url: String
    var date = Date()
}

func storedPages(_ key: String) -> [Page] {
    UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([Page].self, from: $0) } ?? []
}

func storePages(_ pages: [Page], _ key: String) { UserDefaults.standard.set(try? JSONEncoder().encode(pages), forKey: key) }

/// Kept in the app's defaults. Favorites in the order added; history newest first, each page once.
var favorites: [Page] = storedPages("favorites") { didSet { storePages(favorites, "favorites"); favoritesChanged() } }
var history: [Page] = storedPages("history") { didSet { storePages(history, "history"); HistoryPanel.current?.reload() } }

/// Goes to a favorite or history page in the front browser window (a new one if none is open).
func showPage(_ page: Page) {
    guard let url = URL(string: page.url) else { return }
    guard let browser = Browser.front else { Browser.open(url); return }
    browser.visit(url)
    browser.window.makeKeyAndOrderFront(nil)
}

/// The favorites bar under the toolbar: a sunken shelf of bevelled buttons, one per favorite, as many as fit
/// (all of them are in the Favorites menu). Click one to go there.
final class FavoritesBar: NSView {
    var visit: (URL) -> Void = { _ in }
    private var buttons: [NeXTButton] = []

    func reload() {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = favorites.map { page in
            let button = NeXTButton(page.title.count > 22 ? String(page.title.prefix(21)) + "…" : page.title) { [weak self] in
                if let url = URL(string: page.url) { self?.visit(url) }
            }
            addSubview(button)
            return button
        }
        layoutButtons()
    }

    private func layoutButtons() {
        var x: CGFloat = 9
        for button in buttons {
            let width = ceil((button.title as NSString).size(withAttributes: [.font: boldFont]).width) + 16
            button.frame = NSRect(x: x, y: 4, width: width, height: bounds.height - 6)
            button.isHidden = x + width > bounds.width - 9
            x += width + 3
        }
        needsDisplay = true
    }
    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutButtons() }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds)
        let shelf = NSRect(x: 6, y: 2, width: bounds.width - 12, height: bounds.height - 2)
        bevel(shelf, sunken: true, color: wellColor)
        guard buttons.isEmpty else { return }
        let hint = "Favorites: Command-d adds this page" as NSString
        let height = hint.size(withAttributes: [.font: font]).height
        hint.draw(at: NSPoint(x: shelf.minX + 6, y: shelf.midY - height / 2), withAttributes: [.font: font, .foregroundColor: dark])
    }
}

final class Browser: NSObject, NSWindowDelegate, NSTextFieldDelegate, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static var all: [Browser] = []
    /// The key browser window; when another window is key (the History panel), the browser window nearest the front.
    static var front: Browser? {
        all.first { $0.window.isKeyWindow } ?? NSApp.orderedWindows.lazy.compactMap { window in all.first { $0.window === window } }.first ?? all.last
    }
    static var lastFind = ""

    let window = NeXTWindow(body: NSSize(width: 1000, height: 680))
    let web: PageView
    let field = NSTextField()
    let status = StatusLine()
    let scroller = PageScroller()
    let favoritesBar = FavoritesBar()
    private var back: NeXTButton!, forward: NeXTButton!, reload: NeXTButton!
    private var watchers: [NSKeyValueObservation] = []
    /// The user is in the address field (from a click, Open Location or a new window) until they go or click the page.
    private var addressActive = false

    @discardableResult
    static func open(_ url: URL?, configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> Browser {
        let browser = Browser(url, configuration: configuration)
        all.append(browser)
        NSApp.activate(ignoringOtherApps: true)
        browser.window.makeKeyAndOrderFront(nil)
        if url == nil || url == homePage { browser.openLocation() } // a new window starts in the address field
        return browser
    }

    private init(_ url: URL?, configuration: WKWebViewConfiguration) {
        let controller = configuration.userContentController // shared with pop-ups, so add the style once
        if !controller.userScripts.contains(where: { $0.source == scrollbarScript.source }) {
            controller.addUserScript(scrollbarScript)
            controller.addUserScript(scrollReportScript)
            controller.add(scrollReports, name: "pageScroll")
        }
        web = PageView(frame: .zero, configuration: configuration)
        super.init()
        let body = window.body, w = body.bounds.width, h = body.bounds.height
        let toolbar: CGFloat = 36, favoritesHeight: CGFloat = 26, statusHeight: CGFloat = 22
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
        // Square NeXT text field: a sunken white well with the borderless field inside it
        let well = SunkenWell(frame: NSRect(x: x + 6, y: h - toolbar + 6, width: w - x - 12, height: 24))
        well.autoresizingMask = [.width, .minYMargin]
        body.addSubview(well)
        field.frame = well.bounds.insetBy(dx: 4, dy: 3)
        field.autoresizingMask = [.width, .height]
        field.font = font
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false // the well's grey shows through: no rounded white box inside
        field.textColor = .black
        field.appearance = NSAppearance(named: .aqua) // black text and caret while editing, even in Dark Mode
        field.focusRingType = .none
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = "Type a web address or search words"
        field.target = self
        field.action = #selector(go)
        field.delegate = self
        well.addSubview(field)

        favoritesBar.frame = NSRect(x: 0, y: h - toolbar - favoritesHeight, width: w, height: favoritesHeight)
        favoritesBar.autoresizingMask = [.width, .minYMargin]
        favoritesBar.visit = { [weak self] in self?.visit($0) }
        favoritesBar.reload()
        body.addSubview(favoritesBar)

        let pageHeight = h - toolbar - favoritesHeight - statusHeight
        scroller.frame = NSRect(x: 0, y: statusHeight, width: PageScroller.bar + 1, height: pageHeight)
        scroller.autoresizingMask = [.height]
        scroller.scroll = { [weak self] top in
            self?.web.evaluateJavaScript("(document.scrollingElement||document.documentElement).scrollTop=\(top)")
        }
        body.addSubview(scroller)
        web.frame = NSRect(x: PageScroller.bar + 1, y: statusHeight, width: w - PageScroller.bar - 1, height: pageHeight)
        web.autoresizingMask = [.width, .height]
        web.navigationDelegate = self
        web.addressActive = { [weak self] in self?.addressActive ?? false }
        web.userFocused = { [weak self] in self?.addressActive = false }
        web.giveBackFocus = { [weak self] in
            guard let self else { return }
            self.window.makeFirstResponder(self.field)
            let end = self.field.stringValue.utf16.count
            self.field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
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
        addressActive = false
        web.load(URLRequest(url: url))
        window.makeFirstResponder(web)
    }

    /// Goes to a favorite or history page.
    func visit(_ url: URL) {
        addressActive = false
        web.load(URLRequest(url: url))
        window.makeFirstResponder(web)
    }

    private var pageTitle: String { web.title?.isEmpty == false ? web.title! : web.url?.host ?? "Untitled" }

    func addFavorite() {
        guard let url = web.url?.absoluteString else { return NSSound.beep() }
        guard !favorites.contains(where: { $0.url == url }) else { status.text = "Already in Favorites"; return }
        favorites.append(Page(title: pageTitle, url: url))
        status.text = "Added to Favorites"
    }

    func removeFavorite() {
        guard let url = web.url?.absoluteString, favorites.contains(where: { $0.url == url }) else { return NSSound.beep() }
        favorites.removeAll { $0.url == url }
        status.text = "Removed from Favorites"
    }

    func reloadOrStop() { if web.isLoading { web.stopLoading() } else { web.reload() } }

    func controlTextDidBeginEditing(_ obj: Notification) { addressActive = true }

    func openLocation() {
        addressActive = true
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        status.text = "Done  \(webView.url?.host ?? "")"
        guard let url = webView.url, url.scheme?.hasPrefix("http") == true else { return }
        let earlier = history.filter { $0.url != url.absoluteString }
        history = Array(([Page(title: pageTitle, url: url.absoluteString)] + earlier).prefix(500))
    }
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

// MARK: History panel

/// The history as a NeXT list: grey rows in black Helvetica (title, address, when), the selection in white.
final class HistoryList: NSView {
    static let rowHeight: CGFloat = 18
    static let dates: DateFormatter = {
        let dates = DateFormatter()
        dates.dateStyle = .short
        dates.timeStyle = .short
        return dates
    }()
    var selected: Int? { didSet { needsDisplay = true; onSelect() } }
    var onSelect: () -> Void = {}
    var onOpen: () -> Void = {}
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        fill(face, bounds)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let textHeight = ceil(font.ascender - font.descender), when: CGFloat = 120
        let half = floor((bounds.width - when - 24) / 2)
        for (row, page) in history.enumerated() {
            let r = NSRect(x: 0, y: CGFloat(row) * HistoryList.rowHeight, width: bounds.width, height: HistoryList.rowHeight)
            guard r.intersects(dirtyRect) else { continue }
            if row == selected { fill(.white, r) }
            let y = r.minY + floor((r.height - textHeight) / 2)
            func text(_ string: String, _ x: CGFloat, _ width: CGFloat) {
                (string as NSString).draw(in: NSRect(x: x, y: y, width: width, height: textHeight),
                                          withAttributes: [.font: font, .foregroundColor: NSColor.black, .paragraphStyle: style])
            }
            text(page.title, 6, half)
            text(page.url, half + 12, half)
            text(HistoryList.dates.string(from: page.date), bounds.width - when - 6, when)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let row = Int(convert(event.locationInWindow, from: nil).y / HistoryList.rowHeight)
        selected = row < history.count ? row : nil
        if selected != nil, event.clickCount == 2 { onOpen() }
    }

    /// As tall as its rows, and at least as tall as the scroll view shows.
    func fit() {
        guard let clip = enclosingScrollView?.contentView else { return }
        setFrameSize(NSSize(width: clip.bounds.width, height: max(clip.bounds.height, CGFloat(history.count) * HistoryList.rowHeight)))
        needsDisplay = true
    }
}

/// The History panel (Go > History…): the pages visited, newest first, in a sunken list with NeXT's scroller on
/// the left. Double-click a page or press Open to go there in the front browser window; Remove forgets the
/// selected page, Clear History all of them.
final class HistoryPanel: NSObject, NSWindowDelegate {
    static var current: HistoryPanel?
    let window = NeXTWindow(body: NSSize(width: 640, height: 360))
    private let list = HistoryList()
    private var open: NeXTButton!, remove: NeXTButton!, clear: NeXTButton!

    static func show() {
        let panel = current ?? HistoryPanel()
        current = panel
        panel.reload()
        panel.window.makeKeyAndOrderFront(nil)
    }

    private override init() {
        super.init()
        let body = window.body, w = body.bounds.width, h = body.bounds.height
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 400, height: 200)
        window.title = "History"
        let well = SunkenWell(frame: NSRect(x: 8, y: 42, width: w - 16, height: h - 50))
        well.autoresizingMask = [.width, .height]
        body.addSubview(well)
        let scroll = NeXTScrollView(frame: well.bounds.insetBy(dx: 1, dy: 1))
        scroll.autoresizingMask = [.width, .height]
        scroll.backgroundColor = face
        list.autoresizingMask = [.width]
        scroll.documentView = list
        well.addSubview(scroll)
        list.onSelect = { [weak self] in self?.enable() }
        list.onOpen = { [weak self] in self?.openSelected() }

        clear = NeXTButton("Clear History") { history = [] }
        remove = NeXTButton("Remove") { [weak self] in
            guard let row = self?.list.selected, row < history.count else { return }
            history.remove(at: row)
        }
        open = NeXTButton("Open") { [weak self] in self?.openSelected() }
        clear.frame = NSRect(x: 8, y: 8, width: 110, height: 26)
        clear.autoresizingMask = [.maxXMargin, .maxYMargin]
        remove.frame = NSRect(x: w - 164, y: 8, width: 76, height: 26)
        open.frame = NSRect(x: w - 84, y: 8, width: 76, height: 26)
        [remove!, open!].forEach { $0.autoresizingMask = [.minXMargin, .maxYMargin] }
        [clear!, remove!, open!].forEach { body.addSubview($0) }
        window.center()
    }

    func reload() {
        list.selected = nil
        list.fit()
        enable()
    }

    private func enable() {
        open.isEnabled = list.selected != nil
        remove.isEnabled = list.selected != nil
        clear.isEnabled = !history.isEmpty
    }

    private func openSelected() {
        guard let row = list.selected, row < history.count else { return }
        showPage(history[row])
    }

    func windowDidResize(_ notification: Notification) { list.fit() }
}

// MARK: Menus

/// The Favorites menu: Add and Remove for the page in the front window, then every favorite.
let favoritesItem = menu("Favorites", [])

func favoritesChanged() {
    Browser.all.forEach { $0.favoritesBar.reload() }
    var items: [NSMenuItem] = [
        Item("Add to Favorites", "d") { Browser.front?.addFavorite() },
        Item("Remove from Favorites") { Browser.front?.removeFavorite() },
    ]
    if !favorites.isEmpty { items.append(.separator()) }
    items += favorites.map { page in Item(page.title) { showPage(page) } }
    favoritesItem.submenu?.removeAllItems()
    items.forEach { favoritesItem.submenu?.addItem($0) }
}

func buildMenus() {
    favoritesChanged()
    let front = { Browser.front }
    let windows = menu("Windows", [responder("Miniaturize Window", "performMiniaturize:", "m"), Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) }])
    NSApp.mainMenu = NSMenu()
    [
        menu("NeXT Browser", [
            Item("Info Panel…") { NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "A WebKit browser in NeXTSTEP dress for MacCube, part of Macaroon.")]) },
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
            .separator(), Item("History…", "y") { HistoryPanel.show() },
        ]),
        favoritesItem, windows,
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
