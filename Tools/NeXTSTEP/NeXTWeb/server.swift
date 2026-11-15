// NeXTWeb's web engine: the half of the NeXTSTEP 3.3 browser (NeXTWeb.m) that runs on the Mac. A 68040 can't run
// a modern web engine, so the pages are loaded and laid out here by WebKit, in a WKWebView that isn't on screen,
// and NeXTWeb gets them as pictures in the NeXT's own 12-bit colour, only the parts that changed. Its mouse
// clicks, keys and scrolling come back and are passed on to the page.
//   swiftc -O server.swift -o NeXTWebServer; ./NeXTWebServer
// listens on 127.0.0.1:3129, which NeXTSTEP reaches as 10.0.2.2:3129 (Previous' SLiRP network). One web view per
// connection. Downloads are saved in ~/Previous/Shared/Downloads, which NeXTSTEP has as /Net/nfs/Downloads.
//
// From NeXTWeb, one line of text each:
//   size W H · open ADDRESS-OR-SEARCH · back · forward · reload · stop · mouse d|u|m|g X Y CLICKS (down, up,
//   move, drag) · key CODE FLAGS · text HEX (paste) · copy · cut · selectall · scroll line|page ±1 ·
//   scrollto PERMILLE · zoom 1|-1|0 (in, out, actual size) · smooth PERCENT (text smoothing: 100 as WebKit
//   draws it, 0 off) · fps N (frames a second at most, 1 to 60; 5 to begin with) · ack (the last frame is drawn)
// To NeXTWeb, messages of a 4-letter tag, a 32-bit length and that many bytes (integers big-endian, text in the
// NeXTSTEP encoding):
//   SIZE "W H" · RECT x y w h (16 bits each) and its pixels · DONE (end of a frame; answered with ack) ·
//   TITL · ADDR · STAT (status line) · NAVI "back forward loading" (1 or 0 each) · SCRL "top height view" ·
//   COPY (text for the pasteboard) · ALRT (a page's alert)
// Pixels are 16 bits, RGBA 4444 with alpha 15, run-length packed: a byte below 128 is followed by that many + 1
// pixels, a byte from 128 by one pixel repeated that many - 126 times.
import Cocoa
import Network
import WebKit

let agent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

/// The part of the page that scrolls: the page itself, or else the scrolling box in the middle of the window.
let scroller = """
    const scroller = (() => {
        const root = document.scrollingElement || document.documentElement;
        if (root.scrollHeight > root.clientHeight + 1) return root;
        for (let e = document.elementFromPoint(innerWidth / 2, innerHeight / 2); e && e !== root; e = e.parentElement) {
            const overflow = getComputedStyle(e).overflowY;
            if ((overflow === 'auto' || overflow === 'scroll') && e.scrollHeight > e.clientHeight + 1) return e;
        }
        return root;
    })();
    """

/// The page zooms that Zoom In and Zoom Out step through.
let zooms: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

/// Turns text smoothing off in a page: a style sheet that also overrules the page's own choice.
let smoothingOff = """
    (() => {
        if (document.getElementById('nextweb-smoothing')) return;
        const style = document.createElement('style');
        style.id = 'nextweb-smoothing';
        style.textContent = '*, *::before, *::after { -webkit-font-smoothing: none !important }';
        (document.head || document.documentElement).appendChild(style);
    })()
    """

/// Mac key codes (US keyboard) for the characters NeXTWeb sends, so that pages see real key events.
let keyCodes: [Character: UInt16] = {
    var codes: [Character: UInt16] = [:]
    let keys: [(String, UInt16)] = [
        ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9), ("b", 11),
        ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17), ("1!", 18), ("2@", 19), ("3#", 20), ("4$", 21),
        ("6^", 22), ("5%", 23), ("=+", 24), ("9(", 25), ("7&", 26), ("-_", 27), ("8*", 28), ("0)", 29), ("]}", 30),
        ("o", 31), ("u", 32), ("[{", 33), ("i", 34), ("p", 35), ("l", 37), ("j", 38), ("'\"", 39), ("k", 40), (";:", 41),
        ("\\|", 42), (",<", 43), ("/?", 44), ("n", 45), ("m", 46), (".>", 47), ("`~", 50), (" ", 49),
    ]
    for (characters, code) in keys {
        for character in characters + characters.uppercased() { codes[character] = code }
    }
    return codes
}()

/// Keys that aren't characters, by the codes NeXTWeb gives them → (Mac key code, the characters of its event).
let specialKeys: [Int: (UInt16, String)] = [
    13: (36, "\r"), 3: (76, "\u{3}"), 9: (48, "\t"), 25: (48, "\u{19}"), 8: (51, "\u{7F}"), 27: (53, "\u{1B}"),
    1001: (123, "\u{F702}"), 1002: (126, "\u{F700}"), 1003: (124, "\u{F703}"), 1004: (125, "\u{F701}"),
]

/// A window that is never on screen but tells its web view that it is the key window, so that pages are
/// focused, show their insertion point and take keys.
final class PageWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override var canBecomeKey: Bool { true }
}

final class Session: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    static var all: [Session] = []
    let connection: NWConnection
    let window = PageWindow(contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
    let web: WKWebView
    var width = 800, height = 600
    private var input = Data()
    private var shown: [UInt16] = []        // the frame NeXTWeb has
    private var told: [String: String] = [:]   // the last message of each kind NeXTWeb got
    private var notice: String?            // for the status line: why the last page didn't load, or a download
    private var downloads: [WKDownload: String] = [:]   // the files being downloaded, by name
    private var smoothing = 100             // text smoothing in percent (smooth)
    private var rate = 5                    // frames a second at most (fps)
    private var snapshotStarted: Date?      // a snapshot is being taken
    private var frameSent: Date?            // a frame is on its way and not yet drawn
    private var late = false                // a snapshot was due while one was being taken or a frame was on its way
    private var lastInput = Date()          // when NeXTWeb last asked for something
    private var lastLarge = Date.distantPast   // when the last frame over 8 KB went out
    private var timer: Timer?
    private var events = 0

    init(_ connection: NWConnection) {
        self.connection = connection
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: configuration)
        super.init()
        web.customUserAgent = agent
        web.navigationDelegate = self
        web.uiDelegate = self
        // Off screen WebKit would stop animating and loading lazily; and the NeXT has one pixel per point
        if web.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) { web.setValue(false, forKey: "windowOcclusionDetectionEnabled") }
        if web.responds(to: Selector(("_setOverrideDeviceScaleFactor:"))) { web.setValue(1.0, forKey: "overrideDeviceScaleFactor") }
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle, .transient]
        window.contentView = web
        window.orderFrontRegardless()
        window.makeFirstResponder(web)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: .main)
        receive()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() {
        guard let index = Session.all.firstIndex(where: { $0 === self }) else { return }
        Session.all.remove(at: index)
        timer?.invalidate()
        connection.cancel()
        web.stopLoading()
        window.close()
    }

    // MARK: From NeXTWeb

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            self.input.append(data ?? Data())
            while let end = self.input.firstIndex(of: 10) {
                let line = String(data: self.input[self.input.startIndex..<end], encoding: .ascii) ?? ""
                self.input.removeSubrange(self.input.startIndex...end)
                self.command(line)
            }
            if complete || error != nil { self.close() } else { self.receive() }
        }
    }

    private func command(_ line: String) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let words = (parts.count > 1 ? parts[1] : "").split(separator: " ").map(String.init)
        let numbers = words.map { Int($0) ?? 0 }
        if parts.first != "ack", !line.hasPrefix("mouse m") { lastInput = Date() }
        switch parts.first ?? "" {
        case "size" where numbers.count == 2:
            width = min(max(numbers[0], 64), 2048)
            height = min(max(numbers[1], 64), 2048)
            window.setContentSize(NSSize(width: width, height: height))
        case "open" where parts.count == 2: open(parts[1])
        case "back": web.goBack()
        case "forward": web.goForward()
        case "reload": notice = nil; web.reload()
        case "stop": web.stopLoading()
        case "mouse" where words.count == 4: mouse(words[0], x: numbers[1], y: numbers[2], clicks: numbers[3])
        case "key" where numbers.count == 2: key(numbers[0], flags: numbers[1])
        case "text" where words.count == 1: insert(words[0])
        case "copy", "cut":
            let cut = parts[0] == "cut"
            web.evaluateJavaScript("""
                (() => {
                    const e = document.activeElement;
                    const field = e && typeof e.selectionStart === 'number' && e.selectionEnd > e.selectionStart;
                    const text = field ? e.value.substring(e.selectionStart, e.selectionEnd) : String(getSelection());
                    if (\(cut) && text) document.execCommand('delete');
                    return text;
                })()
                """) { [weak self] text, _ in
                if let text = text as? String, !text.isEmpty { self?.say("COPY", text, always: true) }
            }
        case "selectall": web.evaluateJavaScript("document.execCommand('selectAll')")
        case "scroll" where words.count == 2:
            let step = words[0] == "page" ? "(scroller.clientHeight - 40)" : "40"
            web.evaluateJavaScript("(() => { \(scroller) scroller.scrollBy({top: \(numbers[1]) * \(step), behavior: 'instant'}) })()")
        case "scrollto" where numbers.count == 1:
            web.evaluateJavaScript("(() => { \(scroller) scroller.scrollTo({top: (scroller.scrollHeight - scroller.clientHeight) * \(numbers[0]) / 1000, behavior: 'instant'}) })()")
        case "zoom" where numbers.count == 1:
            let at = zooms.firstIndex { $0 >= web.pageZoom - 0.001 } ?? zooms.count - 1
            web.pageZoom = numbers[0] == 0 ? 1 : zooms[min(max(at + numbers[0], 0), zooms.count - 1)]
        case "smooth" where numbers.count == 1: smooth(numbers[0])
        case "fps" where numbers.count == 1:
            rate = min(max(numbers[0], 1), 60)
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1 / Double(rate), repeats: true) { [weak self] _ in self?.tick() }
        case "ack":
            frameSent = nil
            if late { snapshot() }
        default: break
        }
    }

    /// Text smoothing in percent. 100 is WebKit's own; 0 turns it off in the page, so that text has no grey
    /// edges at all; in between, the edges are sharpened after the page is drawn (sharpen).
    private func smooth(_ percent: Int) {
        smoothing = min(max(percent, 0), 100)
        let scripts = web.configuration.userContentController
        scripts.removeAllUserScripts()
        if smoothing == 0 { scripts.addUserScript(WKUserScript(source: smoothingOff, injectionTime: .atDocumentStart, forMainFrameOnly: false)) }
        web.evaluateJavaScript(smoothing == 0 ? smoothingOff : "document.getElementById('nextweb-smoothing')?.remove()")
    }

    /// A web address, a host name, or words to search the web for.
    private func open(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        var url: URL?
        if text.contains("://") || text.hasPrefix("about:") || text.hasPrefix("data:") {
            url = URL(string: text)
        } else if !text.contains(" "), text.contains(".") || text.hasPrefix("localhost") {
            url = URL(string: "https://" + text)
        }
        if url == nil {
            var search = URLComponents(string: "https://duckduckgo.com/")!
            search.queryItems = [URLQueryItem(name: "q", value: text)]
            url = search.url
        }
        notice = nil
        web.load(URLRequest(url: url!))
    }

    private func mouse(_ what: String, x: Int, y: Int, clicks: Int) {
        let types: [String: NSEvent.EventType] = ["d": .leftMouseDown, "u": .leftMouseUp, "m": .mouseMoved, "g": .leftMouseDragged]
        guard let type = types[what] else { return }
        events += 1
        guard let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: events, clickCount: max(clicks, 1), pressure: what == "d" || what == "g" ? 1 : 0)
        else { return }
        switch type {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        default: web.mouseMoved(with: event)
        }
    }

    /// code: a character in the NeXTSTEP encoding or one of specialKeys. flags: 1 shift, 2 control, 4 alternate.
    private func key(_ code: Int, flags: Int) {
        var keyCode: UInt16 = 0, characters = ""
        if let special = specialKeys[code] {
            (keyCode, characters) = special
        } else if let character = String(data: Data([UInt8(truncatingIfNeeded: code)]), encoding: .nextstep) {
            characters = character
            keyCode = keyCodes[Character(character)] ?? 0
        } else {
            return
        }
        var modifiers: NSEvent.ModifierFlags = []
        if flags & 1 != 0 { modifiers.insert(.shift) }
        if flags & 2 != 0 { modifiers.insert(.control) }
        if flags & 4 != 0 { modifiers.insert(.option) }
        if code > 1000 { modifiers.formUnion([.function, .numericPad]) }
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                               context: nil, characters: characters, charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: keyCode)
            else { return }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
    }

    /// Pasted text: bytes in the NeXTSTEP encoding, as hexadecimal.
    private func insert(_ hex: String) {
        let digits = Array(hex.utf8)
        let bytes = stride(from: 0, to: digits.count - 1, by: 2).compactMap { UInt8(String(bytes: digits[$0...$0 + 1], encoding: .ascii) ?? "", radix: 16) }
        guard let text = String(data: Data(bytes), encoding: .nextstep) else { return }
        web.callAsyncJavaScript("document.execCommand('insertText', false, text)", arguments: ["text": text], in: nil, in: .page)
    }

    // MARK: To NeXTWeb

    private func message(_ tag: String, _ payload: Data) -> Data {
        var data = Data(tag.utf8)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        return data + payload
    }

    /// Sends text of one kind, unless that is what NeXTWeb has already.
    private func say(_ tag: String, _ text: String, always: Bool = false) {
        guard always || told[tag] != text else { return }
        told[tag] = text
        connection.send(content: message(tag, text.data(using: .nextstep, allowLossyConversion: true) ?? Data()), completion: .idempotent)
    }

    /// Five times a second, or as often as fps asked for: the page's title, address and state, and then how it
    /// looks now.
    private func tick() {
        let host = web.url?.host ?? ""
        say("TITL", web.title?.isEmpty == false ? web.title! : host.isEmpty ? "NeXTWeb" : host)
        say("ADDR", web.url?.absoluteString ?? "")
        say("NAVI", "\(web.canGoBack ? 1 : 0) \(web.canGoForward ? 1 : 0) \(web.isLoading ? 1 : 0)")
        let zoom = web.pageZoom == 1 ? "" : "   Zoom \(Int((web.pageZoom * 100).rounded()))%"
        let smooth = smoothing == 100 ? "" : smoothing == 0 ? "   Smoothing Off" : "   Smoothing \(smoothing)%"
        let frames = rate == 5 ? "" : "   \(rate) fps"
        say("STAT", (web.isLoading ? "Loading \(host)  \(Int(web.estimatedProgress * 100))%" : notice ?? (host.isEmpty ? "" : "Done  \(host)")) + zoom + smooth + frames)
        snapshot()
    }

    /// Takes a picture of the page and sends what changed. While one is being taken, or NeXTWeb hasn't drawn the
    /// frame before, it is put off (late) until that frame is drawn (ack): waiting for the next tick instead
    /// would cost a frame that takes a little longer than a tick every second one.
    private func snapshot() {
        let now = Date()
        late = true
        if let started = snapshotStarted, now.timeIntervalSince(started) < 5 { return }
        if let sent = frameSent, now.timeIntervalSince(sent) < 10 { return }
        late = false
        snapshotStarted = now
        web.evaluateJavaScript("(() => { \(scroller) return [scroller.scrollTop, scroller.scrollHeight, scroller.clientHeight] })()") { [weak self] metrics, _ in
            guard let self else { return }
            if let metrics = metrics as? [Double], metrics.count == 3 { self.say("SCRL", metrics.map { String(Int($0)) }.joined(separator: " ")) }
            let configuration = WKSnapshotConfiguration()
            configuration.snapshotWidth = NSNumber(value: self.width)
            self.web.takeSnapshot(with: configuration) { image, _ in
                self.snapshotStarted = nil
                guard let image = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                self.send(self.pixels(of: image))
            }
        }
    }

    /// A snapshot as the NeXT's pixels, top row first.
    private func pixels(of image: CGImage) -> [UInt16] {
        let width = width, height = height
        var rgb = [UInt8](repeating: 0, count: width * height * 4)
        rgb.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        if smoothing > 0, smoothing < 100 { Session.sharpen(&rgb, width: width, height: height, amount: 100 - smoothing) }
        var pixels = [UInt16](repeating: 0, count: width * height)
        rgb.withUnsafeBufferPointer { rgb in
            pixels.withUnsafeMutableBufferPointer { pixels in
                for i in 0..<width * height {
                    pixels[i] = Session.nibble[Int(rgb[4 * i])] << 12 | Session.nibble[Int(rgb[4 * i + 1])] << 8 | Session.nibble[Int(rgb[4 * i + 2])] << 4 | 15
                }
            }
        }
        return pixels
    }
    private static let nibble: [UInt16] = (0..<256).map { UInt16(($0 * 15 + 127) / 255) }

    /// Text smoothing between 0 and 100%: every pixel that lies between its neighbours, as the grey edges of
    /// smoothed text do, moves toward the darkest or the lightest of the 9 around it, whichever is nearer, by
    /// `amount` percent. Flat areas stay as they are; edges in pictures get sharper too.
    private static func sharpen(_ rgb: inout [UInt8], width: Int, height: Int, amount: Int) {
        let source = rgb
        source.withUnsafeBufferPointer { source in
            rgb.withUnsafeMutableBufferPointer { rgb in
                for y in 0..<height {
                    let top = max(y - 1, 0), bottom = min(y + 1, height - 1)
                    for x in 0..<width {
                        let left = max(x - 1, 0), right = min(x + 1, width - 1)
                        for channel in 0..<3 {
                            var darkest = 255, lightest = 0
                            for row in top...bottom {
                                for column in left...right {
                                    let value = Int(source[(row * width + column) * 4 + channel])
                                    darkest = min(darkest, value)
                                    lightest = max(lightest, value)
                                }
                            }
                            let at = (y * width + x) * 4 + channel, value = Int(source[at])
                            let nearer = value - darkest < lightest - value ? darkest : lightest
                            rgb[at] = UInt8(value + (nearer - value) * amount / 100)
                        }
                    }
                }
            }
        }
    }

    /// Sends what differs between the frame NeXTWeb has and this one: bands of changed rows, each as narrow as
    /// its changes.
    private func send(_ frame: [UInt16]) {
        let width = width, height = height
        guard frame.count == width * height else { return }
        var data = Data()
        if shown.count != frame.count || told["SIZE"] != "\(width) \(height)" {
            told["SIZE"] = "\(width) \(height)"
            data += message("SIZE", Data("\(width) \(height)".utf8))
            shown = [UInt16](repeating: 0, count: frame.count)   // no pixel of a frame is 0: all of it gets sent
        }
        var rects = 0
        frame.withUnsafeBufferPointer { new in
            shown.withUnsafeBufferPointer { old in
                func changed(_ row: Int) -> Bool { memcmp(new.baseAddress! + row * width, old.baseAddress! + row * width, width * 2) != 0 }
                var row = 0
                while row < height {
                    guard changed(row) else { row += 1; continue }
                    // a band: up to 48 rows, over gaps of up to 8 unchanged ones
                    var end = row + 1, next = row + 1
                    while next < height, next - row < 48, next - end < 8 {
                        if changed(next) { end = next + 1 }
                        next += 1
                    }
                    var left = width, right = 0
                    for y in row..<end {
                        let a = new.baseAddress! + y * width, b = old.baseAddress! + y * width
                        var x = 0
                        while x < left, a[x] == b[x] { x += 1 }
                        left = x
                        x = width
                        while x > right, a[x - 1] == b[x - 1] { x -= 1 }
                        right = x
                    }
                    if right > left {
                        var payload = Data()
                        for value in [left, row, right - left, end - row] { withUnsafeBytes(of: UInt16(value).bigEndian) { payload.append(contentsOf: $0) } }
                        payload.append(contentsOf: Session.pack(new, x: left, y: row, width: right - left, height: end - row, stride: width))
                        data += message("RECT", payload)
                        rects += 1
                    }
                    row = end
                }
            }
        }
        guard !data.isEmpty else { return }
        // A page that animates by itself gets a large frame every 1.5 seconds: more would keep the NeXT busy
        // drawing. Small changes, and anything in the 2 seconds after input, go at once. With a frame rate
        // chosen (fps), large frames go at that rate too.
        let now = Date()
        if data.count > 8192 {
            if rate == 5, now.timeIntervalSince(lastInput) > 2, now.timeIntervalSince(lastLarge) < 1.5 { return }
            lastLarge = now
        }
        if rects > 0 {
            data += message("DONE", Data())
            frameSent = Date()
        }
        shown = frame
        connection.send(content: data, completion: .idempotent)
    }

    private static func pack(_ pixels: UnsafeBufferPointer<UInt16>, x: Int, y: Int, width: Int, height: Int, stride: Int) -> [UInt8] {
        var rect = [UInt16]()
        rect.reserveCapacity(width * height)
        for row in y..<y + height { rect.append(contentsOf: pixels[row * stride + x..<row * stride + x + width]) }
        var packed = [UInt8]()
        packed.reserveCapacity(rect.count)
        let count = rect.count
        var i = 0
        while i < count {
            var run = 1
            while i + run < count, run < 129, rect[i + run] == rect[i] { run += 1 }
            if run > 1 {
                packed += [UInt8(run + 126), UInt8(rect[i] >> 8), UInt8(rect[i] & 255)]
                i += run
            } else {
                var end = i + 1
                while end < count, end - i < 128, !(end + 1 < count && rect[end] == rect[end + 1]) { end += 1 }
                packed.append(UInt8(end - i - 1))
                for pixel in rect[i..<end] { packed += [UInt8(pixel >> 8), UInt8(pixel & 255)] }
                i = end
            }
        }
        return packed
    }

    // MARK: Pages

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { notice = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        let error = error as NSError
        // not failures: a load that was stopped, and one that became a download (WebKit's "Frame load interrupted")
        if error.code == NSURLErrorCancelled || (error.domain == "WebKitErrorDomain" && error.code == 102) { return }
        notice = error.localizedDescription
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { webView.reload() }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
        if ["http", "https", "about", "data", "blob"].contains(scheme) { return decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow) }
        notice = "NeXTWeb can't open \(scheme): addresses"
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        decisionHandler(navigationResponse.canShowMIMEType && !disposition.lowercased().hasPrefix("attachment") ? .allow : .download)
    }

    // MARK: Downloads

    // Files a page can't show, attachments and download links are saved in the folder NeXTSTEP shares with the Mac.
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Previous/Shared/Downloads")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = suggestedFilename.replacingOccurrences(of: "/", with: "-") as NSString
        var file = folder.appendingPathComponent(name as String), copy = 1
        while FileManager.default.fileExists(atPath: file.path) {    // a file of that name is there: name-2, name-3…
            copy += 1
            file = folder.appendingPathComponent("\(name.deletingPathExtension)-\(copy)" + (name.pathExtension.isEmpty ? "" : "." + name.pathExtension))
        }
        downloads[download] = file.lastPathComponent
        notice = "Downloading \(file.lastPathComponent)"
        completionHandler(file)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let name = downloads.removeValue(forKey: download) { notice = "Downloaded \(name) to /Net/nfs/Downloads" }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        notice = "Couldn't download \(downloads.removeValue(forKey: download) ?? "the file"): \(error.localizedDescription)"
    }

    /// Links and scripts that want a new window get this one.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        say("ALRT", message, always: true)
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        completionHandler(defaultText)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let tcp = NWProtocolTCP.Options()
tcp.noDelay = true
let parameters = NWParameters(tls: nil, tcp: tcp)
parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 3129)
parameters.allowLocalEndpointReuse = true
let listener: NWListener
do { listener = try NWListener(using: parameters) } catch { print(error); exit(1) }
listener.newConnectionHandler = { Session.all.append(Session($0)) }
listener.stateUpdateHandler = { state in
    if case .failed(let error) = state { print(error); exit(1) }
}
listener.start(queue: .main)
app.run()
