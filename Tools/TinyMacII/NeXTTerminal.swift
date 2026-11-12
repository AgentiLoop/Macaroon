// NeXT Terminal for TinyMacII: NeXTSTEP's Terminal, black Courier on a white page in the square NeXT window with
// the NeXT scroller on the left. Runs the user's login shell on a pseudo-terminal and understands the VT100/xterm
// sequences shells and full-screen programs use (cursor movement, erasing, scroll regions, the alternate screen,
// bracketed paste); 16, 256 and 24-bit colour, shown in colour or as greys like a NeXT MegaPixel display, always
// kept readable against their background; a white or dark page. Scrollback, mouse selection, Copy and Paste,
// Clear Scrollback, Larger/Smaller text. Menus show in NeXT Workspace's vertical main menu.
import AppKit
import Darwin

var termFont = NSFont(name: "Courier", size: 13) ?? .monospacedSystemFont(ofSize: 12, weight: .regular)

// MARK: Emulator

struct Attr: Equatable {
    var bold = false, faint = false, underline = false, inverse = false
    var fg: Int32 = -1, bg: Int32 = -1 // 0xRRGGBB, -1 for the page's default text / background
}

struct Cell {
    var ch: Character = " "
    var attr = Attr()
}

/// ANSI 16 (xterm's, the bright half a little darker so it reads on a white page) and the 256-colour cube and
/// grey ramp, as 0xRRGGBB.
func paletteColour(_ index: Int) -> Int32 {
    let basic: [Int32] = [0x000000, 0xC23621, 0x25BC24, 0xADAD27, 0x492EE1, 0xD338D3, 0x33BBC8, 0xCBCCCD,
                          0x818383, 0xFC391F, 0x31E722, 0xC7C42C, 0x5833FF, 0xF935F8, 0x14D7DE, 0xE9EBEB]
    switch index {
    case 0..<16: return basic[index]
    case 16..<232:
        let levels: [Int32] = [0, 95, 135, 175, 215, 255], i = index - 16
        return levels[i / 36] << 16 | levels[i / 6 % 6] << 8 | levels[i % 6]
    case 232..<256: let v = Int32(8 + (index - 232) * 10); return v << 16 | v << 8 | v
    default: return -1
    }
}
func rgbColour(_ r: Int, _ g: Int, _ b: Int) -> Int32 { Int32(min(255, max(0, r))) << 16 | Int32(min(255, max(0, g))) << 8 | Int32(min(255, max(0, b))) }

/// How colours are shown: in colour or as NeXT greys, on a white or a dark page (saved between launches).
enum Look {
    static var colours: Bool {
        get { UserDefaults.standard.object(forKey: "Colours") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "Colours") }
    }
    static var dark: Bool {
        get { UserDefaults.standard.bool(forKey: "DarkPage") }
        set { UserDefaults.standard.set(newValue, forKey: "DarkPage") }
    }
    typealias RGB = (r: CGFloat, g: CGFloat, b: CGFloat)
    static var pageText: RGB { dark ? (0.9, 0.9, 0.9) : (0, 0, 0) }
    static var page: RGB { dark ? (0, 0, 0) : (1, 1, 1) }
    static func rgb(_ v: Int32) -> RGB { (CGFloat(v >> 16 & 255) / 255, CGFloat(v >> 8 & 255) / 255, CGFloat(v & 255) / 255) }
    static func grey(_ c: RGB) -> RGB { let l = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b; return (l, l, l) }
    static func color(_ c: RGB) -> NSColor { NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1) }
    /// WCAG relative luminance and contrast ratio.
    static func luminance(_ c: RGB) -> CGFloat {
        func ch(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b)
    }
    static func contrast(_ a: RGB, _ b: RGB) -> CGFloat {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
    /// The contrast floor: text too close to its background (light grey on white, a dim on black) is moved
    /// toward black or white until it reads, like Terminal's and iTerm2's minimum contrast.
    static func readable(_ text: RGB, on back: RGB, minimum: CGFloat = 4.5) -> RGB {
        guard contrast(text, back) < minimum else { return text }
        let target: CGFloat = luminance(back) > 0.18 ? 0 : 1
        var t = text
        for step in 1...10 {
            let f = CGFloat(step) / 10
            t = (text.r + (target - text.r) * f, text.g + (target - text.g) * f, text.b + (target - text.b) * f)
            if contrast(t, back) >= minimum { break }
        }
        return t
    }
}

final class Emulator {
    private(set) var cols: Int, rows: Int
    private(set) var lines: [[Cell]] = []
    private(set) var scrollback: [[Cell]] = []
    private var mainLines: [[Cell]]? // the main screen while the alternate one is up
    static let maxScrollback = 5000
    /// Lines dropped off the top of the scrollback so far, so selections can use absolute line numbers.
    private(set) var trimmed = 0
    private(set) var x = 0, y = 0
    private var attr = Attr()
    private var top = 0, bottom: Int
    private var pendingWrap = false, autowrap = true
    private(set) var cursorVisible = true, appCursor = false, bracketedPaste = false
    private var saved = (x: 0, y: 0, attr: Attr())
    var reply: (String) -> Void = { _ in }
    var titleChanged: (String) -> Void = { _ in }

    private enum State { case ground, escape, csi, osc, oscEscape, charset }
    private var state = State.ground
    private var params = "", osc = ""
    private var pending: [UInt8] = [] // an incomplete UTF-8 sequence at the end of the last read

    init(cols: Int, rows: Int) {
        self.cols = cols
        self.rows = rows
        bottom = rows - 1
        lines = Array(repeating: blank(), count: rows)
    }

    var alternate: Bool { mainLines != nil }
    /// The scrollback shown above the screen (none on the alternate screen).
    var shownScrollback: [[Cell]] { alternate ? [] : scrollback }

    private func blank(_ count: Int? = nil) -> [Cell] { Array(repeating: Cell(ch: " ", attr: Attr(bg: attr.bg)), count: count ?? cols) }

    func feed(_ data: Data) {
        var bytes = pending + [UInt8](data)
        pending = []
        // Keep a UTF-8 sequence cut off by the read for the next one
        var i = bytes.count - 1, back = 0
        while i >= 0, back < 4 {
            let b = bytes[i]
            if b & 0xC0 == 0x80 { i -= 1; back += 1; continue }
            let need = b >= 0xF0 ? 4 : b >= 0xE0 ? 3 : b >= 0xC0 ? 2 : 1
            if need > bytes.count - i { pending = Array(bytes[i...]); bytes.removeLast(bytes.count - i) }
            break
        }
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars { handle(scalar) }
    }

    private func handle(_ s: Unicode.Scalar) {
        let v = s.value
        switch state {
        case .ground:
            switch v {
            case 0x1B: state = .escape
            case 0x07: NSSound.beep()
            case 0x08: if x > 0 { x -= 1 }; pendingWrap = false
            case 0x09: x = min(cols - 1, (x / 8 + 1) * 8); pendingWrap = false
            case 0x0A, 0x0B, 0x0C: lineFeed()
            case 0x0D: x = 0; pendingWrap = false
            case 0..<0x20, 0x7F: break
            default: put(s)
            }
        case .escape:
            state = .ground
            switch s {
            case "[": state = .csi; params = ""
            case "]": state = .osc; osc = ""
            case "(", ")", "*", "+", "#", "%": state = .charset
            case "7": saveCursor()
            case "8": restoreCursor()
            case "D": lineFeed()
            case "E": x = 0; lineFeed()
            case "M": reverseIndex()
            case "c": reset()
            default: break
            }
        case .csi:
            if v >= 0x40 && v <= 0x7E { state = .ground; csi(Character(s)) }
            else if v == 0x1B { state = .escape }
            else if v < 0x20 { state = .ground; handle(s); state = .csi } // controls inside a sequence still act
            else { params.unicodeScalars.append(s) }
        case .osc:
            if v == 0x07 { state = .ground; finishOSC() }
            else if v == 0x1B { state = .oscEscape }
            else { osc.unicodeScalars.append(s) }
        case .oscEscape:
            state = .ground
            finishOSC()
            if s != "\\" { handle(s) }
        case .charset:
            state = .ground
        }
    }

    private func put(_ s: Unicode.Scalar) {
        let category = s.properties.generalCategory
        if category == .nonspacingMark || category == .enclosingMark || s.value == 0x200D || (0xFE00...0xFE0F).contains(s.value) {
            let px = pendingWrap ? x : max(0, x - 1) // joins the character before it
            let combined = String(lines[y][px].ch) + String(s)
            if combined.count == 1 { lines[y][px].ch = Character(combined) }
            return
        }
        if pendingWrap {
            pendingWrap = false
            if autowrap { x = 0; lineFeed() }
        }
        lines[y][x] = Cell(ch: Character(s), attr: attr)
        if x == cols - 1 { pendingWrap = true } else { x += 1 }
    }

    private func lineFeed() {
        pendingWrap = false
        if y == bottom { scrollUp(1) } else if y < rows - 1 { y += 1 }
    }

    private func reverseIndex() {
        pendingWrap = false
        if y == top { scrollDown(1) } else if y > 0 { y -= 1 }
    }

    private func scrollUp(_ n: Int) {
        for _ in 0..<min(n, bottom - top + 1) {
            let gone = lines.remove(at: top)
            if top == 0, !alternate {
                scrollback.append(gone)
                if scrollback.count > Emulator.maxScrollback { scrollback.removeFirst(); trimmed += 1 }
            }
            lines.insert(blank(), at: bottom)
        }
    }

    private func scrollDown(_ n: Int) {
        for _ in 0..<min(n, bottom - top + 1) {
            lines.remove(at: bottom)
            lines.insert(blank(), at: top)
        }
    }

    private func saveCursor() { saved = (x, y, attr) }
    private func restoreCursor() {
        (x, y, attr) = (min(saved.x, cols - 1), min(saved.y, rows - 1), saved.attr)
        pendingWrap = false
    }

    private func reset() {
        attr = Attr()
        if let main = mainLines { lines = main; mainLines = nil }
        lines = Array(repeating: blank(), count: rows)
        (x, y, top, bottom) = (0, 0, 0, rows - 1)
        (pendingWrap, autowrap, cursorVisible, appCursor, bracketedPaste) = (false, true, true, false, false)
    }

    func clearScrollback() {
        trimmed += scrollback.count
        scrollback = []
    }

    private func finishOSC() {
        guard let semicolon = osc.firstIndex(of: ";") else { return }
        let code = osc[..<semicolon], text = String(osc[osc.index(after: semicolon)...])
        if code == "0" || code == "2" { titleChanged(text) }
    }

    private func erase(_ row: Int, _ range: Range<Int>) {
        for c in range where c >= 0 && c < cols { lines[row][c] = Cell(ch: " ", attr: Attr(bg: attr.bg)) }
    }

    private func csi(_ final: Character) {
        var p = params
        let mark = p.first.flatMap { "?>=<".contains($0) ? $0 : nil }
        if mark != nil { p.removeFirst() }
        guard !p.contains(where: { " !\"#$%&'()*+,-./".contains($0) }) else { return } // intermediates: unsupported
        let n = p.split(separator: ";", omittingEmptySubsequences: false).map { $0.split(separator: ":").first.flatMap { Int($0) } ?? 0 }
        func arg(_ i: Int, _ fallback: Int = 1) -> Int { i < n.count && n[i] != 0 ? n[i] : fallback }
        if mark == "?" {
            if final == "h" || final == "l" { n.forEach { privateMode($0, final == "h") } }
            return
        }
        guard mark == nil else { return }
        if final != "m" { pendingWrap = false }
        switch final {
        case "A": y = max(y >= top ? top : 0, y - arg(0))
        case "B", "e": y = min(y <= bottom ? bottom : rows - 1, y + arg(0))
        case "C", "a": x = min(cols - 1, x + arg(0))
        case "D": x = max(0, x - arg(0))
        case "E": x = 0; y = min(y <= bottom ? bottom : rows - 1, y + arg(0))
        case "F": x = 0; y = max(y >= top ? top : 0, y - arg(0))
        case "G", "`": x = min(cols - 1, arg(0) - 1)
        case "H", "f": y = min(rows - 1, arg(0) - 1); x = min(cols - 1, arg(1) - 1)
        case "d": y = min(rows - 1, arg(0) - 1)
        case "J":
            switch n.first ?? 0 {
            case 0: erase(y, x..<cols); for r in (y + 1)..<rows { lines[r] = blank() }
            case 1: for r in 0..<y { lines[r] = blank() }; erase(y, 0..<(x + 1))
            case 2: for r in 0..<rows { lines[r] = blank() }
            case 3: clearScrollback()
            default: break
            }
        case "K":
            switch n.first ?? 0 {
            case 0: erase(y, x..<cols)
            case 1: erase(y, 0..<(x + 1))
            default: erase(y, 0..<cols)
            }
        case "L", "M":
            guard y >= top, y <= bottom else { return }
            for _ in 0..<min(arg(0), bottom - y + 1) {
                if final == "L" { lines.remove(at: bottom); lines.insert(blank(), at: y) }
                else { lines.remove(at: y); lines.insert(blank(), at: bottom) }
            }
            x = 0
        case "@":
            let k = min(arg(0), cols - x)
            lines[y].insert(contentsOf: blank(k), at: x)
            lines[y].removeLast(k)
        case "P":
            let k = min(arg(0), cols - x)
            lines[y].removeSubrange(x..<(x + k))
            lines[y].append(contentsOf: blank(k))
        case "X": erase(y, x..<min(cols, x + arg(0)))
        case "S": scrollUp(arg(0))
        case "T": scrollDown(arg(0))
        case "m": sgr(n)
        case "r":
            let t = arg(0) - 1, b = min(rows, arg(1, rows)) - 1
            (top, bottom) = t < b ? (t, b) : (0, rows - 1)
            (x, y) = (0, 0)
        case "s": saveCursor()
        case "u": restoreCursor()
        case "n":
            if n.first == 6 { reply("\u{1B}[\(y + 1);\(x + 1)R") } else if n.first == 5 { reply("\u{1B}[0n") }
        case "c": reply("\u{1B}[?1;2c")
        default: break
        }
    }

    private func privateMode(_ mode: Int, _ on: Bool) {
        switch mode {
        case 1: appCursor = on
        case 7: autowrap = on
        case 25: cursorVisible = on
        case 2004: bracketedPaste = on
        case 47, 1047, 1049:
            if on, mainLines == nil {
                if mode == 1049 { saveCursor() }
                mainLines = lines
                lines = Array(repeating: blank(), count: rows)
            } else if !on, let main = mainLines {
                lines = main
                mainLines = nil
                if mode == 1049 { restoreCursor() }
            }
        default: break
        }
    }

    private func sgr(_ values: [Int]) {
        let n = values.isEmpty ? [0] : values
        var i = 0
        while i < n.count {
            let code = n[i]
            switch code {
            case 0: attr = Attr()
            case 1: attr.bold = true
            case 2: attr.faint = true
            case 4: attr.underline = true
            case 7: attr.inverse = true
            case 22: attr.bold = false; attr.faint = false
            case 24: attr.underline = false
            case 27: attr.inverse = false
            case 30...37: attr.fg = paletteColour(code - 30)
            case 39: attr.fg = -1
            case 40...47: attr.bg = paletteColour(code - 40)
            case 49: attr.bg = -1
            case 90...97: attr.fg = paletteColour(code - 90 + 8)
            case 100...107: attr.bg = paletteColour(code - 100 + 8)
            case 38, 48:
                var colour: Int32?
                if i + 2 < n.count, n[i + 1] == 5 { colour = paletteColour(n[i + 2]); i += 2 }
                else if i + 4 < n.count, n[i + 1] == 2 { colour = rgbColour(n[i + 2], n[i + 3], n[i + 4]); i += 4 }
                if let colour { if code == 38 { attr.fg = colour } else { attr.bg = colour } }
            default: break
            }
            i += 1
        }
    }

    func resize(cols newCols: Int, rows newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != cols || newRows != rows else { return }
        func fit(_ line: [Cell]) -> [Cell] {
            line.count >= newCols ? Array(line.prefix(newCols)) : line + Array(repeating: Cell(), count: newCols - line.count)
        }
        lines = lines.map(fit)
        while lines.count > newRows {
            if y < lines.count - 1, lines.last!.allSatisfy({ $0.ch == " " }) { lines.removeLast(); continue }
            let gone = lines.removeFirst()
            if !alternate { scrollback.append(gone) }
            y -= 1
        }
        while lines.count < newRows {
            if !alternate, let last = scrollback.popLast() { lines.insert(fit(last), at: 0); y += 1 }
            else { lines.append(Array(repeating: Cell(), count: newCols)) }
        }
        if var main = mainLines {
            main = main.map(fit)
            if main.count > newRows { main.removeFirst(main.count - newRows) }
            while main.count < newRows { main.append(Array(repeating: Cell(), count: newCols)) }
            mainLines = main
        }
        (cols, rows, top, bottom) = (newCols, newRows, 0, newRows - 1)
        x = min(x, cols - 1)
        y = max(0, min(y, rows - 1))
        pendingWrap = false
    }
}

// MARK: Shell on a pseudo-terminal

final class Shell {
    let fd: Int32, pid: pid_t
    let path: String
    private var source: DispatchSourceRead?

    init?(cols: Int, rows: Int, output: @escaping (Data) -> Void, exited: @escaping () -> Void) {
        let shell = getpwuid(getuid()).flatMap { $0.pointee.pw_shell.map { String(cString: $0) } }.flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        path = shell
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["TERM_PROGRAM"] = "NeXT_Terminal"
        env["SHELL"] = shell
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        env["COLORTERM"] = "truecolor" // 24-bit colour is understood (shown in colour or as greys)
        // Prepared before forking: the child only calls chdir, execve and _exit
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup("-" + (shell as NSString).lastPathComponent), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let file = strdup(shell), home = strdup(NSHomeDirectory())
        defer { (argv + envp + [file, home]).forEach { free($0) } }
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let child = forkpty(&master, nil, nil, &size)
        if child == 0 {
            chdir(home)
            execve(file, argv, envp)
            _exit(127)
        }
        guard child > 0 else { return nil }
        fd = master
        pid = child
        let source = DispatchSource.makeReadSource(fileDescriptor: master, queue: .main)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let n = read(master, &buffer, buffer.count)
            if n > 0 { return output(Data(buffer[0..<n])) }
            if n < 0, errno == EINTR || errno == EAGAIN { return }
            self?.source?.cancel()
            self?.source = nil
            DispatchQueue.global().async { waitpid(child, nil, 0) }
            exited()
        }
        source.setCancelHandler { close(master) }
        source.resume()
        self.source = source
    }

    var tty: String { ptsname(fd).map { (String(cString: $0) as NSString).lastPathComponent } ?? "" }

    func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        bytes.withUnsafeBytes { raw in
            while offset < bytes.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, bytes.count - offset)
                if n > 0 { offset += n } else if errno != EINTR && errno != EAGAIN { break }
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &size) { ioctl(fd, 0x8008_7467 /* TIOCSWINSZ */, $0) }
    }

    func terminate() {
        guard let source else { return }
        kill(pid, SIGHUP)
        source.cancel()
        self.source = nil
        let pid = pid
        DispatchQueue.global().async { waitpid(pid, nil, 0) }
    }
}

// MARK: Terminal view

struct Position: Comparable {
    var line: Int, col: Int // absolute line (counting lines trimmed from the scrollback)
    static func < (a: Position, b: Position) -> Bool { a.line != b.line ? a.line < b.line : a.col < b.col }
}

final class TerminalView: NSView {
    static let inset: CGFloat = 4
    let emulator: Emulator
    var send: (String) -> Void = { _ in }
    private(set) var charWidth: CGFloat = 8, lineHeight: CGFloat = 15
    private var bold = termFont
    private var selection: (Position, Position)?

    init(emulator: Emulator) {
        self.emulator = emulator
        super.init(frame: .zero)
        updateFont()
        // The cursor blinks while the window is key, like Terminal's
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            self.blinkOn.toggle()
            self.setNeedsDisplay(self.cursorRect)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Cell height is AppKit's own line height for the font (what NSString drawing lays text out in), so the
    /// cursor block lines up with the glyphs instead of sitting above them.
    static func metrics() -> (CGFloat, CGFloat) {
        (("M" as NSString).size(withAttributes: [.font: termFont]).width, ceil(NSLayoutManager().defaultLineHeight(for: termFont)))
    }

    private var blinkOn = true
    private var cursorRect: NSRect {
        NSRect(x: Self.inset + CGFloat(emulator.x) * charWidth, y: Self.inset + CGFloat(emulator.shownScrollback.count + emulator.y) * lineHeight,
               width: charWidth, height: lineHeight)
    }
    /// Shows the cursor solid again (after typing or output), restarting the blink.
    func resetBlink() {
        blinkOn = true
        setNeedsDisplay(cursorRect)
    }

    func updateFont() {
        (charWidth, lineHeight) = Self.metrics()
        bold = NSFontManager.shared.convert(termFont, toHaveTrait: .boldFontMask)
        needsDisplay = true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    private var lineCount: Int { emulator.shownScrollback.count + emulator.rows }
    private func line(_ i: Int, _ scrollback: [[Cell]]) -> [Cell] { i < scrollback.count ? scrollback[i] : emulator.lines[i - scrollback.count] }

    private var clip: NSClipView? { enclosingScrollView?.contentView }
    var isAtBottom: Bool { guard let clip else { return true }; return clip.bounds.maxY >= frame.height - lineHeight }

    /// After output or a resize: grow to hold the scrollback and screen, and follow the bottom if we were there.
    func contentChanged(follow: Bool) {
        let height = max(clip?.bounds.height ?? 0, 2 * Self.inset + CGFloat(lineCount) * lineHeight)
        if frame.height != height { setFrameSize(NSSize(width: frame.width, height: height)) }
        needsDisplay = true
        if follow { scrollToBottom() }
    }

    func scrollToBottom() {
        guard let clip, let scroll = enclosingScrollView else { return }
        clip.scroll(to: NSPoint(x: 0, y: max(0, frame.height - clip.bounds.height)))
        scroll.reflectScrolledClipView(clip)
    }

    override func draw(_ dirtyRect: NSRect) {
        let page = Look.page, pageText = Look.pageText, colours = Look.colours
        fill(Look.color(page), dirtyRect)
        let inset = Self.inset, scrollback = emulator.shownScrollback
        let first = max(0, Int((dirtyRect.minY - inset) / lineHeight))
        let last = min(lineCount, Int((dirtyRect.maxY - inset) / lineHeight) + 1)
        guard first < last else { return }
        for i in first..<last {
            let cells = line(i, scrollback), top = inset + CGFloat(i) * lineHeight
            var c = 0
            while c < cells.count {
                let a = cells[c].attr, selected = isSelected(i, c)
                var end = c + 1
                while end < cells.count, cells[end].attr == a, isSelected(i, end) == selected { end += 1 }
                var fg = a.fg >= 0 ? Look.rgb(a.fg) : pageText, bg = a.bg >= 0 ? Look.rgb(a.bg) : page
                if a.inverse { swap(&fg, &bg) }
                if selected { bg = (0.667, 0.667, 0.667) }
                if a.faint { fg = ((fg.r + bg.r) / 2, (fg.g + bg.g) / 2, (fg.b + bg.b) / 2) }
                if !colours { fg = Look.grey(fg); bg = Look.grey(bg) }
                fg = Look.readable(fg, on: bg)
                let rect = NSRect(x: inset + CGFloat(c) * charWidth, y: top, width: CGFloat(end - c) * charWidth, height: lineHeight)
                if bg != page { fill(Look.color(bg), rect) }
                let text = String(cells[c..<end].map(\.ch))
                if text.contains(where: { $0 != " " }) {
                    var attributes: [NSAttributedString.Key: Any] = [.font: a.bold ? bold : termFont, .foregroundColor: Look.color(fg)]
                    if a.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                    (text as NSString).draw(at: rect.origin, withAttributes: attributes)
                }
                c = end
            }
        }
        // The cursor: a black block while typing goes here, an outline otherwise
        let row = scrollback.count + emulator.y
        guard emulator.cursorVisible, (first..<last).contains(row) else { return }
        let r = cursorRect
        if window?.isKeyWindow == true, window?.firstResponder === self {
            guard blinkOn else { return }
            fill(Look.color(pageText), r)
            let cell = emulator.lines[emulator.y][min(emulator.x, emulator.cols - 1)]
            (String(cell.ch) as NSString).draw(at: r.origin, withAttributes: [.font: cell.attr.bold ? bold : termFont, .foregroundColor: Look.color(page)])
        } else {
            Look.color(pageText).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }

    // MARK: Selection, Copy and Paste

    private var ordered: (Position, Position)? { selection.map { $0.0 < $0.1 ? ($0.0, $0.1) : ($0.1, $0.0) } }

    private func isSelected(_ i: Int, _ c: Int) -> Bool {
        guard let (a, b) = ordered else { return false }
        let p = Position(line: i + emulator.trimmed, col: c)
        return a <= p && p < b
    }

    private func position(_ event: NSEvent) -> Position {
        let p = convert(event.locationInWindow, from: nil)
        let i = max(0, min(lineCount - 1, Int((p.y - Self.inset) / lineHeight)))
        let c = max(0, min(emulator.cols, Int(((p.x - Self.inset) / charWidth).rounded())))
        return Position(line: i + emulator.trimmed, col: c)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let start = position(event)
        selection = nil
        needsDisplay = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            autoscroll(with: next)
            let end = position(next)
            selection = start == end ? nil : (start, end)
            needsDisplay = true
            if next.type == .leftMouseUp { break }
        }
    }

    var selectedText: String {
        guard let (a, b) = ordered else { return "" }
        let scrollback = emulator.shownScrollback
        var out: [String] = []
        for absolute in a.line...b.line {
            let i = absolute - emulator.trimmed
            guard i >= 0, i < lineCount else { continue }
            let cells = line(i, scrollback)
            let from = min(absolute == a.line ? a.col : 0, cells.count), to = min(absolute == b.line ? b.col : cells.count, cells.count)
            var text = String(cells[from..<max(from, to)].map(\.ch))
            while text.last == " " { text.removeLast() }
            out.append(text)
        }
        return out.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard selection != nil else { return NSSound.beep() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(selectedText, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard var text = NSPasteboard.general.string(forType: .string) else { return }
        text = text.replacingOccurrences(of: "\r\n", with: "\r").replacingOccurrences(of: "\n", with: "\r")
        send(emulator.bracketedPaste ? "\u{1B}[200~" + text + "\u{1B}[201~" : text)
    }

    override func selectAll(_ sender: Any?) {
        selection = (Position(line: emulator.trimmed, col: 0), Position(line: emulator.trimmed + lineCount - 1, col: emulator.cols))
        needsDisplay = true
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
        if flags.contains(.command) { return super.keyDown(with: event) }
        if selection != nil { selection = nil; needsDisplay = true }
        let cursor = emulator.appCursor ? "\u{1B}O" : "\u{1B}["
        let option = flags.contains(.option)
        let text: String?
        switch event.keyCode {
        case 126: text = cursor + "A"
        case 125: text = cursor + "B"
        case 124: text = option ? "\u{1B}f" : cursor + "C" // Option-arrows move by word, as in Terminal
        case 123: text = option ? "\u{1B}b" : cursor + "D"
        case 115: text = "\u{1B}[H"
        case 119: text = "\u{1B}[F"
        case 116: text = "\u{1B}[5~"
        case 121: text = "\u{1B}[6~"
        case 117: text = "\u{1B}[3~"
        case 51: text = "\u{7F}"
        case 36, 76: text = "\r"
        case 48: text = flags.contains(.shift) ? "\u{1B}[Z" : "\t"
        case 53: text = "\u{1B}"
        default:
            if flags.contains(.control), event.charactersIgnoringModifiers == " " || event.charactersIgnoringModifiers == "2" { text = "\u{0}" }
            else { text = event.characters }
        }
        guard let text, !text.isEmpty else { return }
        send(text)
        resetBlink()
        scrollToBottom()
    }
}

// MARK: Terminal window

final class Session: NSObject, NSWindowDelegate {
    static var all: [Session] = []
    static var front: Session? { all.first { $0.window.isKeyWindow } ?? all.last }

    let window: NeXTWindow
    let emulator = Emulator(cols: 80, rows: 24)
    let view: TerminalView
    private let scroll: NeXTScrollView
    private var shell: Shell?
    private var title: String?

    static func open() {
        let session = Session()
        all.append(session)
        let offset = CGFloat((all.count - 1) % 8) * 24
        session.window.center()
        session.window.setFrameOrigin(NSPoint(x: session.window.frame.minX + offset, y: session.window.frame.minY - offset))
        NSApp.activate(ignoringOtherApps: true)
        session.window.makeKeyAndOrderFront(nil)
        session.window.makeFirstResponder(session.view)
    }

    private override init() {
        let (cw, lh) = TerminalView.metrics(), inset = TerminalView.inset
        window = NeXTWindow(body: NSSize(width: ceil(80 * cw + 2 * inset + NeXTScroller.bar + 1), height: ceil(24 * lh + 2 * inset)))
        view = TerminalView(emulator: emulator)
        scroll = NeXTScrollView(frame: window.body.bounds)
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 240, height: 140)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = Look.color(Look.page)
        view.frame = NSRect(origin: .zero, size: scroll.contentSize)
        view.autoresizingMask = [.width]
        scroll.documentView = view
        scroll.verticalLineScroll = view.lineHeight
        window.body.addSubview(scroll)
        scroll.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(resized), name: NSView.frameDidChangeNotification, object: scroll.contentView)

        emulator.reply = { [weak self] in self?.shell?.write($0) }
        emulator.titleChanged = { [weak self] in self?.title = $0.isEmpty ? nil : $0; self?.updateTitle() }
        view.send = { [weak self] in self?.shell?.write($0) }
        shell = Shell(cols: emulator.cols, rows: emulator.rows,
                      output: { [weak self] data in self?.output(data) },
                      exited: { [weak self] in self?.window.close() })
        if shell == nil { output(Data("Could not start a shell.\r\n".utf8)) }
        resized()
        updateTitle()
    }

    private func output(_ data: Data) {
        let follow = view.isAtBottom
        emulator.feed(data)
        view.resetBlink()
        view.contentChanged(follow: follow)
    }

    @objc func resized() {
        let size = scroll.contentSize, inset = TerminalView.inset
        let cols = max(10, Int((size.width - 2 * inset) / view.charWidth)), rows = max(3, Int((size.height - 2 * inset) / view.lineHeight))
        if cols != emulator.cols || rows != emulator.rows {
            emulator.resize(cols: cols, rows: rows)
            shell?.resize(cols: cols, rows: rows)
            updateTitle()
        }
        view.contentChanged(follow: true)
    }

    func lookChanged() {
        scroll.backgroundColor = Look.color(Look.page)
        view.needsDisplay = true
    }

    func fontChanged() {
        view.updateFont()
        scroll.verticalLineScroll = view.lineHeight
        resized()
    }

    func clearScrollback() {
        emulator.clearScrollback()
        view.contentChanged(follow: true)
    }

    /// NeXT Terminal titles: the shell and its tty, or what the program running in it asks for.
    private func updateTitle() {
        window.title = title ?? "\(shell?.path ?? "Terminal") (\(shell?.tty ?? ""))  \(emulator.cols)×\(emulator.rows)"
    }

    func windowDidBecomeKey(_ notification: Notification) { view.needsDisplay = true }
    func windowDidResignKey(_ notification: Notification) { view.needsDisplay = true }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        shell?.terminate()
        shell = nil
        Session.all.removeAll { $0 === self }
    }
}

// MARK: Menus

func setFontSize(_ size: CGFloat) {
    termFont = NSFont(descriptor: termFont.fontDescriptor, size: min(36, max(8, size))) ?? termFont
    Session.all.forEach { $0.fontChanged() }
}

private var lookItems: [NSMenuItem] = []
func updateLookItems() {
    lookItems[0].state = Look.colours ? .on : .off
    lookItems[1].state = Look.colours ? .off : .on
    lookItems[2].state = Look.dark ? .on : .off
}
func setLook(colours: Bool? = nil, dark: Bool? = nil) {
    if let colours { Look.colours = colours }
    if let dark { Look.dark = dark }
    updateLookItems()
    Session.all.forEach { $0.lookChanged() }
}

func buildMenus() {
    lookItems = [Item("Colours") { setLook(colours: true) }, Item("NeXT Greys") { setLook(colours: false) },
                 Item("Dark Page") { setLook(dark: !Look.dark) }]
    updateLookItems()
    let front = { Session.front }
    let windows = menu("Windows", [responder("Miniaturize Window", "performMiniaturize:", "m"), Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) }])
    NSApp.mainMenu = NSMenu()
    [
        menu("NeXT Terminal", [
            Item("Info Panel…") { NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "A terminal in NeXTSTEP dress for TinyMacII, part of Macaroon.")]) },
            .separator(), responder("Hide", "hide:", "h"), Item("Quit", "q") { NSApp.terminate(nil) },
        ]),
        menu("Shell", [
            Item("New", "n") { Session.open() },
            Item("Close", "w") { NSApp.keyWindow?.performClose(nil) },
        ]),
        menu("Edit", [
            responder("Copy", "copy:", "c"), responder("Paste", "paste:", "v"), responder("Select All", "selectAll:", "a"),
            .separator(), Item("Clear Scrollback", "k") { front()?.clearScrollback() },
        ]),
        menu("Font", [
            Item("Larger", "+") { setFontSize(termFont.pointSize + 1) },
            Item("Smaller", "-") { setFontSize(termFont.pointSize - 1) },
            Item("Normal Size", "0") { setFontSize(13) },
            .separator(),
        ] + lookItems),
        windows,
    ].forEach(NSApp.mainMenu!.addItem)
    NSApp.windowsMenu = windows.submenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        Session.open()
    }

    /// Borderless NeXT windows don't become key by themselves when the app is brought forward (it's started in
    /// the background from NeXT Workspace's Dock), which left the cursor hollow and still until a click.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard NSApp.keyWindow == nil, let session = Session.front else { return }
        session.window.makeKeyAndOrderFront(nil)
        session.window.makeFirstResponder(session.view)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Session.open() }
        return true
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
