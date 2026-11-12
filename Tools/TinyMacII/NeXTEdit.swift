// NeXT Edit for TinyMacII: a simple text editor (NeXTSTEP's Edit, in the spirit of SimpleText) dressed as a
// NeXTSTEP app. Square window with black title bar and resize bar, white page with the NeXT scroller on the left.
// Plain text and RTF: New, Open, Save, Save As, Revert, Print; Font panel, bold/italic, sizes, alignment, Find panel.
// Unsaved windows ask before closing or quitting. Menus show in NeXT Workspace's vertical main menu.
import AppKit
import UniformTypeIdentifiers

let textFont = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)

final class Document: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static var all: [Document] = []
    static var front: Document? { all.first { $0.window.isKeyWindow } ?? all.last }
    private static var untitled = 0

    let window = NeXTWindow(body: NSSize(width: 560, height: 520))
    let text = NSTextView()
    private(set) var url: URL?
    private var name: String
    var rich = false

    @discardableResult
    static func open(_ url: URL?) -> Document? {
        if let url, let existing = all.first(where: { $0.url?.standardizedFileURL == url.standardizedFileURL }) {
            existing.window.makeKeyAndOrderFront(nil)
            return existing
        }
        let document = Document()
        if let url {
            guard document.read(url) else { return nil }
        }
        all.append(document)
        let offset = CGFloat((all.count - 1) % 8) * 24
        document.window.center()
        document.window.setFrameOrigin(NSPoint(x: document.window.frame.minX + offset, y: document.window.frame.minY - offset))
        NSApp.activate(ignoringOtherApps: true)
        document.window.makeKeyAndOrderFront(nil)
        document.window.makeFirstResponder(document.text)
        return document
    }

    private override init() {
        Document.untitled += 1
        name = Document.untitled == 1 ? "UNTITLED" : "UNTITLED-\(Document.untitled)"
        super.init()
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 240, height: 160)

        let scroll = NeXTScrollView(frame: window.body.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.drawsBackground = true
        scroll.backgroundColor = .white
        let size = scroll.contentSize
        text.frame = NSRect(origin: .zero, size: size)
        text.minSize = NSSize(width: 0, height: size.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.appearance = NSAppearance(named: .aqua) // black on white, also in Dark Mode
        text.backgroundColor = .white
        text.insertionPointColor = .black
        text.font = textFont
        text.typingAttributes = [.font: textFont, .foregroundColor: NSColor.black]
        text.allowsUndo = true
        text.usesFindPanel = true
        text.usesFontPanel = true
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        text.isRichText = false
        text.importsGraphics = false
        text.delegate = self
        scroll.documentView = text
        window.body.addSubview(scroll)
        updateTitle()
    }

    // MARK: Reading and writing

    private func read(_ url: URL) -> Bool {
        do {
            let data = try Data(contentsOf: url)
            let type = UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .rtf) == true {
                let string = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
                setRich(true)
                text.textStorage?.setAttributedString(string)
            } else {
                var encoding = String.Encoding.utf8
                let string = (try? String(contentsOf: url, usedEncoding: &encoding)) ?? String(decoding: data, as: UTF8.self)
                setRich(false)
                text.string = string
                text.textStorage?.setAttributes([.font: textFont, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: text.textStorage?.length ?? 0))
            }
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        self.url = url
        name = url.lastPathComponent
        text.undoManager?.removeAllActions()
        window.isDocumentEdited = false
        updateTitle()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return true
    }

    @discardableResult
    func save(as choose: Bool = false) -> Bool {
        var target = url
        if choose || target == nil {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = url?.lastPathComponent ?? (rich ? "\(name).rtf" : "\(name).txt")
            panel.allowedContentTypes = [rich ? .rtf : .plainText]
            panel.allowsOtherFileTypes = true
            guard panel.runModal() == .OK, let chosen = panel.url else { return false }
            target = chosen
        }
        guard let target, let storage = text.textStorage else { return false }
        do {
            if rich {
                let data = try storage.data(from: NSRange(location: 0, length: storage.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                try data.write(to: target, options: .atomic)
            } else {
                try text.string.write(to: target, atomically: true, encoding: .utf8)
            }
        } catch {
            NSAlert(error: error).runModal()
            return false
        }
        url = target
        name = target.lastPathComponent
        window.isDocumentEdited = false
        updateTitle()
        NSDocumentController.shared.noteNewRecentDocumentURL(target)
        return true
    }

    func revert() {
        guard let url, window.isDocumentEdited else { return NSSound.beep() }
        let alert = NSAlert()
        alert.messageText = "Revert"
        alert.informativeText = "Revert to the saved \(name)? Your changes will be lost."
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { read(url) }
    }

    /// Switches between plain text (one font, saved as .txt) and rich text (fonts and styles, saved as .rtf).
    func setRich(_ on: Bool) {
        rich = on
        text.isRichText = on
        if !on, let storage = text.textStorage {
            storage.setAttributes([.font: textFont, .foregroundColor: NSColor.black], range: NSRange(location: 0, length: storage.length))
        }
        updateTitle()
    }

    func makePlain() {
        guard rich else { return }
        let alert = NSAlert()
        alert.messageText = "Make Plain Text"
        alert.informativeText = "Converting to plain text removes all fonts and styles."
        alert.addButton(withTitle: "Convert")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setRich(false)
        if let url, url.pathExtension.lowercased() == "rtf" { self.url = nil; name = url.deletingPathExtension().lastPathComponent }
        changed()
    }

    func makeRich() {
        guard !rich else { return }
        setRich(true)
        if let url, url.pathExtension.lowercased() != "rtf" { self.url = nil; name = url.deletingPathExtension().lastPathComponent }
        changed()
    }

    private func changed() {
        window.isDocumentEdited = true
        updateTitle()
    }

    /// NeXT titles: the file name, then its folder after an em dash; an edited document shows it in the title.
    private func updateTitle() {
        let folder = url.map { ($0.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }
        window.title = (folder.map { "\(name)   —\($0)" } ?? name) + (window.isDocumentEdited ? "  (edited)" : "")
    }

    func textDidChange(_ notification: Notification) {
        if !window.isDocumentEdited { changed() }
    }

    func printDocument() {
        let info = NSPrintInfo.shared
        info.isVerticallyCentered = false
        let operation = NSPrintOperation(view: text, printInfo: info)
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: Closing

    /// Asks about unsaved changes. Returns false when the user cancels.
    func confirmClose() -> Bool {
        guard window.isDocumentEdited else { return true }
        window.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "Close"
        alert.informativeText = "\(name) has changes. Save them?"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmClose() }
    func windowWillClose(_ notification: Notification) { Document.all.removeAll { $0 === self } }
}

// MARK: Menus

func openPanel() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = [.text, .rtf]
    guard panel.runModal() == .OK else { return }
    panel.urls.forEach { Document.open($0) }
}

func buildMenus() {
    let front = { Document.front }
    let windows = menu("Windows", [responder("Miniaturize Window", "performMiniaturize:", "m"), Item("Close Window", "w") { NSApp.keyWindow?.performClose(nil) }])
    let fontMenu = NSFontManager.shared
    func fontItem(_ title: String, _ key: String, _ tag: Int, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
        item.target = fontMenu
        item.tag = tag
        return item
    }
    func align(_ title: String, _ action: String, _ key: String) -> NSMenuItem { responder(title, action, key, [.command, .option]) }
    NSApp.mainMenu = NSMenu()
    [
        menu("NeXT Edit", [
            Item("Info Panel…") { NSApp.orderFrontStandardAboutPanel(options: [.credits: NSAttributedString(string: "A simple text editor in NeXTSTEP dress for TinyMacII, part of Macaroon.")]) },
            .separator(), responder("Hide", "hide:", "h"), Item("Quit", "q") { NSApp.terminate(nil) },
        ]),
        menu("Document", [
            Item("New", "n") { Document.open(nil) },
            Item("Open…", "o") { openPanel() },
            .separator(),
            Item("Save", "s") { front()?.save() },
            Item("Save As…", "S") { front()?.save(as: true) },
            Item("Revert to Saved", "u") { front()?.revert() },
            Item("Close", "w") { NSApp.keyWindow?.performClose(nil) },
            .separator(), Item("Print…", "p") { front()?.printDocument() },
        ]),
        menu("Edit", [
            responder("Undo", "undo:", "z"), responder("Redo", "redo:", "Z"), .separator(),
            responder("Cut", "cut:", "x"), responder("Copy", "copy:", "c"), responder("Paste", "paste:", "v"),
            responder("Delete", "delete:", ""), responder("Select All", "selectAll:", "a"), .separator(),
            menu("Find", [
                { let i = responder("Find Panel…", "performFindPanelAction:", "f"); i.tag = Int(NSFindPanelAction.showFindPanel.rawValue); return i }(),
                { let i = responder("Find Next", "performFindPanelAction:", "g"); i.tag = Int(NSFindPanelAction.next.rawValue); return i }(),
                { let i = responder("Find Previous", "performFindPanelAction:", "G"); i.tag = Int(NSFindPanelAction.previous.rawValue); return i }(),
                { let i = responder("Enter Selection", "performFindPanelAction:", "e"); i.tag = Int(NSFindPanelAction.setFindString.rawValue); return i }(),
                responder("Jump to Selection", "centerSelectionInVisibleArea:", "j"),
            ]),
            responder("Spelling…", "showGuessPanel:", ":"),
        ]),
        menu("Format", [
            menu("Font", [
                fontItem("Font Panel…", "t", 0, #selector(NSFontManager.orderFrontFontPanel(_:))),
                fontItem("Bold", "b", Int(NSFontTraitMask.boldFontMask.rawValue), #selector(NSFontManager.addFontTrait(_:))),
                fontItem("Italic", "i", Int(NSFontTraitMask.italicFontMask.rawValue), #selector(NSFontManager.addFontTrait(_:))),
                responder("Underline", "underline:", "U"),
                .separator(),
                fontItem("Larger", "+", 3, #selector(NSFontManager.modifyFont(_:))),
                fontItem("Smaller", "-", 4, #selector(NSFontManager.modifyFont(_:))),
                .separator(),
                responder("Copy Font", "copyFont:", "3"), responder("Paste Font", "pasteFont:", "4"),
            ]),
            menu("Text", [
                align("Align Left", "alignLeft:", "{"), align("Center", "alignCenter:", "|"),
                align("Align Right", "alignRight:", "}"), responder("Justify", "alignJustified:", ""),
                .separator(), responder("Show Ruler", "toggleRuler:", "r"),
                responder("Copy Ruler", "copyRuler:", "1"), responder("Paste Ruler", "pasteRuler:", "2"),
            ]),
            .separator(),
            Item("Make Rich Text") { front()?.makeRich() },
            Item("Make Plain Text") { front()?.makePlain() },
        ]),
        windows,
    ].forEach(NSApp.mainMenu!.addItem)
    NSApp.windowsMenu = windows.submenu
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var opened = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenus()
        if !opened { Document.open(nil) } // started on its own: a new untitled document
    }

    /// Files opened from NeXT Workspace's File Viewer, the Finder or dropped on the Dock tile.
    func application(_ application: NSApplication, open urls: [URL]) {
        opened = true
        urls.forEach { Document.open($0) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Document.open(nil) }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for document in Document.all where !document.confirmClose() { return .terminateCancel }
        return .terminateNow
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
