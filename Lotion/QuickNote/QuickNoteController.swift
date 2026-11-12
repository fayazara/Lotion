//
//  QuickNoteController.swift
//  Lotion
//
//  The quick note pane: a small window that floats over every app and shows
//  one scratchpad entry at a time, opened with a shortcut from anywhere.
//  It edits the entry in a block editor of its own and splices it back into
//  the scratchpad as you type, so the main window (which reloads, as it does
//  for an agent's edits) and the file are never behind for long. Edits made
//  elsewhere come back the other way.
//

import AppKit
import Observation
import ServiceManagement
import SwiftUI

final class QuickNoteController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    static let shared = QuickNoteController()

    /// The app's state, for the library and the main window.
    var state: AppState? {
        didSet { observeScratchpad() }
    }
    let model = QuickNoteModel()

    private var panel: QuickNotePanel?
    private var editor: BlockEditorView?
    private var scrollView: NSScrollView?
    private var slashButton: NSHostingView<SlashButton>?
    private var browser: NSPopover?
    private var browseItem: NSToolbarItem?
    private var theme: BlockTheme
    /// The entry on screen, by the time on its break.
    private var entryID: String?
    /// The entry as it was in the scratchpad when last loaded or written,
    /// to tell an edit made elsewhere from one made here.
    private var entrySnapshot: String?
    /// The scratchpad text this pane last wrote.
    private var lastWritten: String?
    private var pendingWrite: Task<Void, Never>?
    /// The "/" the slash button typed, so closing with it takes it back.
    private var slashTyped: (id: UUID, addedSpace: Bool)?
    /// The text view last typed in, for the slash button.
    private weak var lastTextView: BlockTextView?
    private var appearanceObservation: NSKeyValueObservation?
    /// Counts shows, so a fade-out that ends after the pane came back leaves it be.
    private var showCount = 0

    private static let entryKey = "quickNoteEntry"
    static let keepOnTopKey = "quickNoteKeepOnTop"

    private var library: Library? { state?.library }
    private var scratchpad: Note? { state?.library.scratchpad }

    var isKey: Bool { panel?.isKeyWindow == true }
    #if DEBUG
    /// For the self test.
    var debugEditor: BlockEditorView? { editor }
    var debugPanel: NSPanel? { panel }
    var debugEntryID: String? { entryID }
    #endif
    var isVisible: Bool { panel?.isVisible == true }

    override init() {
        theme = BlockTheme(style: Self.currentStyle())
        super.init()
        model.keepOnTop = UserDefaults.standard.object(forKey: Self.keepOnTopKey) as? Bool ?? true
        model.controller = self
    }

    // MARK: Showing

    /// The shortcut: brings the pane forward, or puts it away once it is
    /// the window being typed in.
    func toggle() {
        if isKey { hide() } else { show() }
    }

    func show() {
        guard let scratchpad else { return }
        let panel = self.panel ?? makePanel()
        // Back to the entry last written in, or the newest one.
        let entries = ScratchpadEntries.entries(in: scratchpad.text)
        let remembered = entryID ?? UserDefaults.standard.string(forKey: Self.entryKey)
        if let remembered, entries.contains(where: { $0.id == remembered }) {
            if remembered != entryID || ScratchpadEntries.markdown(of: remembered, in: scratchpad.text) != entrySnapshot {
                load(remembered)
            }
        } else if let last = entries.last {
            load(last.id)
        } else {
            newEntry()
        }
        restyle()
        showCount += 1
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        if !(panel.firstResponder is BlockTextView) { focusEnd() }
    }

    func hide() {
        flush()
        browser?.close()
        guard let panel, panel.isVisible else { return }
        let shown = showCount
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.showCount == shown else { return }
                panel.orderOut(nil)
                panel.alphaValue = 1
            }
        })
    }

    func setKeepOnTop(_ value: Bool) {
        model.keepOnTop = value
        UserDefaults.standard.set(value, forKey: Self.keepOnTopKey)
        panel?.level = value ? .floating : .normal
    }

    /// Writes what is pending, before the app quits.
    func prepareToQuit() { flush() }

    // MARK: Entries

    /// Starts a new entry at the end of the scratchpad. An empty entry, the
    /// one on screen or the last one, is used instead of adding another.
    func newEntry() {
        flush()
        guard let library, let scratchpad else { return }
        if entryID != nil, isEntryEmpty {
            focusEnd()
            return
        }
        if let last = ScratchpadEntries.entries(in: scratchpad.text).last, last.isEmpty {
            load(last.id)
        } else {
            let (text, id) = ScratchpadEntries.appendingEntry(to: scratchpad.text)
            write(text, to: scratchpad, in: library)
            load(id)
        }
        focusEnd()
    }

    func select(_ id: String) {
        browser?.close()
        flush()
        if id != entryID { load(id) }
        focusEnd()
    }

    func copyEntry() {
        flush()
        guard let scratchpad, let entryID, let body = ScratchpadEntries.body(of: entryID, in: scratchpad.text) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
    }

    /// Removes the entry from the scratchpad and shows the newest one left.
    /// Undo puts it back.
    func deleteEntry() {
        flush()
        guard let library, let scratchpad, let entryID,
              let text = ScratchpadEntries.removing(entryID, in: scratchpad.text) else { return }
        let before = scratchpad.text
        write(text, to: scratchpad, in: library)
        if let last = ScratchpadEntries.entries(in: text).last { load(last.id) }
        focusEnd()
        let deleted = entryID
        // The editor's undo groups only what it opens itself.
        guard let undo = editor?.noteUndoManager else { return }
        undo.beginUndoGrouping()
        undo.registerUndo(withTarget: self) { controller in
            MainActor.assumeIsolated { controller.restore(before, showing: deleted) }
        }
        undo.setActionName("Delete Entry")
        undo.endUndoGrouping()
    }

    private func restore(_ text: String, showing id: String) {
        guard let library, let scratchpad else { return }
        write(text, to: scratchpad, in: library)
        load(id)
        focusEnd()
    }

    /// Makes the entry a note of its own, its first line the title, and
    /// takes it out of the scratchpad.
    func moveToNewNote() {
        flush()
        guard let library, let scratchpad, let entryID,
              let body = ScratchpadEntries.body(of: entryID, in: scratchpad.text),
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let note = library.createNote(in: nil) else { return }
        var blocks = BlockMarkdown.parse(body).blocks
        if let first = blocks.first, first.kind == .paragraph, !first.plainText.contains("\n") {
            blocks[0].kind = .heading(1)
            blocks[0].touch()
        }
        library.update(note, text: BlockMarkdown.write(blocks, trailingNewlines: 1))
        library.save(note)
        if let text = ScratchpadEntries.removing(entryID, in: scratchpad.text) {
            write(text, to: scratchpad, in: library)
            if let last = ScratchpadEntries.entries(in: text).last { load(last.id) }
        }
        openInMainWindow(note: note)
    }

    /// Shows the entry in the main window, and puts the pane away.
    func openEntryInMainWindow() {
        flush()
        guard let state, let scratchpad else { return }
        hide()
        state.searchText = ""
        state.selection = scratchpad.id
        state.showMainWindow()
        NSApp.activate()
        if let entryID { state.editor.revealEntry(entryID, in: scratchpad) }
    }

    private func openInMainWindow(note: Note) {
        guard let state else { return }
        hide()
        state.searchText = ""
        state.selection = note.id
        state.showMainWindow()
        NSApp.activate()
        state.editor.focus(note)
    }

    func toggleBrowser() {
        if let browser, browser.isShown {
            browser.close()
            return
        }
        guard let scratchpad, let browseItem else { return }
        flush()
        model.entries = ScratchpadEntries.entries(in: scratchpad.text).reversed()
        model.currentID = entryID
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: EntryBrowser(model: model))
        popover.show(relativeTo: browseItem)
        browser = popover
    }

    // MARK: The entry on screen

    private var isEntryEmpty: Bool {
        guard let editor else { return true }
        return editor.blocks.allSatisfy { $0.kind == .entry || ($0.kind == .paragraph && $0.text.length == 0) }
    }

    private func load(_ id: String) {
        guard let editor, let library, let scratchpad,
              let markdown = ScratchpadEntries.markdown(of: id, in: scratchpad.text) else { return }
        entryID = id
        entrySnapshot = markdown
        UserDefaults.standard.set(id, forKey: Self.entryKey)
        let undo = UndoManager()
        undo.groupsByEvent = false
        editor.noteUndoManager = undo
        editor.baseURL = scratchpad.url.deletingLastPathComponent()
        editor.mediaCacheURL = library.mediaCache(for: scratchpad)
        editor.load(BlockMarkdown.parse(markdown))
        scrollView?.contentView.scroll(to: NSPoint(x: 0, y: -(scrollView?.contentInsets.top ?? 0)))
        updateTitle()
    }

    /// Takes the entry again after it changed elsewhere, keeping the caret.
    private func reload(_ markdown: String) {
        guard let editor else { return }
        let focus = editor.viewState()
        entrySnapshot = markdown
        editor.load(BlockMarkdown.parse(markdown))
        editor.apply(focus)
        updateTitle()
    }

    private func focusEnd() {
        guard let editor, let panel else { return }
        panel.makeFirstResponder(editor)
        if let last = editor.blocks.last(where: { $0.kind.isEditable }) { editor.focus(last.id, .end) }
    }

    private func updateTitle() {
        guard let editor else { return }
        let start = editor.blocks.firstIndex { $0.kind == .entry } ?? -1
        let end = editor.blocks[(start + 1)...].firstIndex { $0.kind == .entry } ?? editor.blocks.count
        let title = ScratchpadEntries.title(of: editor.blocks[(start + 1)..<end])
        model.title = title.isEmpty ? "Quick Note" : title
        panel?.title = model.title
    }

    // MARK: Writing back

    private func editorDidChange() {
        updateTitle()
        pendingWrite?.cancel()
        pendingWrite = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Puts the entry on screen into the scratchpad, if it has changed.
    private func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        guard let editor, let library, let scratchpad, let id = entryID else { return }
        let markdown = editor.markdown()
        let finalText = ScratchpadEntries.replacing(id, in: scratchpad.text, with: markdown)
            // Deleted elsewhere while being written in here: it goes back at the end.
            ?? Self.trimmed(scratchpad.text) + "\n\n" + markdown
        // The break may have been rewritten, which makes it a new entry.
        let newID = editor.blocks.first { $0.kind == .entry }?.info ?? id
        entryID = newID
        UserDefaults.standard.set(newID, forKey: Self.entryKey)
        if finalText != scratchpad.text { write(finalText, to: scratchpad, in: library) }
        entrySnapshot = ScratchpadEntries.markdown(of: newID, in: scratchpad.text)
    }

    private func write(_ text: String, to scratchpad: Note, in library: Library) {
        lastWritten = text
        library.updateFromOtherEditor(scratchpad, text: text)
    }

    private static func trimmed(_ text: String) -> String {
        var text = text
        while text.last?.isNewline == true { text.removeLast() }
        return text
    }

    // MARK: Edits made elsewhere

    private func observeScratchpad() {
        guard let scratchpad else { return }
        withObservationTracking {
            _ = scratchpad.text
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.scratchpadDidChange()
                    self?.observeScratchpad()
                }
            }
        }
    }

    private func scratchpadDidChange() {
        guard let scratchpad, editor != nil, scratchpad.text != lastWritten else { return }
        lastWritten = nil
        if pendingWrite != nil {
            // Writing here as well: this entry's edit goes into the new text.
            flush()
            return
        }
        guard let entryID else { return }
        if let markdown = ScratchpadEntries.markdown(of: entryID, in: scratchpad.text) {
            if markdown != entrySnapshot { reload(markdown) }
        } else if let last = ScratchpadEntries.entries(in: scratchpad.text).last {
            // The entry was deleted elsewhere.
            load(last.id)
        }
        if browser?.isShown == true {
            model.entries = ScratchpadEntries.entries(in: scratchpad.text).reversed()
            model.currentID = self.entryID
        }
    }

    // MARK: Slash button

    /// Opens the slash menu at the caret's block, as typing "/" would; it
    /// grows out of the button. Pressed again, it closes.
    func toggleSlashMenu() {
        guard let editor, let panel else { return }
        if let slash = editor.slash {
            // Closed before anything was typed: the "/" (and the space before
            // it) that the button typed go again.
            if slash.query.isEmpty, let typed = slashTyped, typed.id == slash.id,
               let textView = editor.focusedTextView, textView.blockID == slash.id {
                let start = typed.addedSpace ? slash.location - 1 : slash.location
                editor.closeSlash()
                textView.insertText("", replacementRange: NSRange(location: start, length: slash.location + 1 - start))
            } else {
                editor.closeSlash()
            }
            slashTyped = nil
            return
        }
        if editor.focusedTextView == nil, let lastTextView, lastTextView.editor === editor, lastTextView.window != nil {
            panel.makeFirstResponder(lastTextView)
        }
        if editor.focusedTextView == nil { focusEnd() }
        guard let textView = editor.focusedTextView, let index = editor.focusedIndex,
              editor.blocks[index].kind.isText, textView.cell == nil else {
            NSSound.beep()
            return
        }
        // "/" opens the menu only at the start of a word.
        let range = textView.selectedRange()
        let string = textView.string as NSString
        let before: unichar? = range.location > 0 ? string.character(at: range.location - 1) : nil
        let addsSpace = before.map { $0 != 32 && $0 != 10 && $0 != 9 } ?? false
        if addsSpace { textView.insertText(" ", replacementRange: range) }
        textView.insertText("/", replacementRange: textView.selectedRange())
        slashTyped = (textView.blockID, addsSpace)
    }

    // MARK: Style

    /// The editor style from the same settings the main window uses. The
    /// pane is narrow, so the text always fills it.
    static func currentStyle() -> EditorStyle {
        let defaults = UserDefaults.standard
        let isDark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return EditorStyle(
            theme: defaults.string(forKey: Prefs.theme).flatMap { LotionTheme(rawValue: $0) } ?? .paper,
            isDark: isDark,
            noteFont: defaults.string(forKey: Prefs.noteFont) ?? FontChoice.system,
            noteFontSize: CGFloat(defaults.object(forKey: Prefs.noteFontSize) as? Double ?? 15),
            lineSpacing: defaults.string(forKey: Prefs.lineSpacing).flatMap(LineSpacing.init(rawValue:)) ?? .comfortable,
            codeFont: defaults.string(forKey: Prefs.codeFont) ?? FontChoice.mono,
            readableWidth: .full,
            spellCheck: defaults.object(forKey: Prefs.spellCheck) as? Bool ?? true,
            tableWidth: defaults.string(forKey: Prefs.tableWidth).flatMap(TableWidth.init(rawValue:)) ?? .fit
        )
    }

    private func restyle() {
        let style = Self.currentStyle()
        if style != theme.style {
            theme = BlockTheme(style: style)
            editor?.readableWidth = style.readableWidth.points
            editor?.apply(theme: theme)
        }
        let palette = theme.palette
        scrollView?.backgroundColor = palette.background
        scrollView?.scrollerKnobStyle = palette.isDark ? .light : .dark
        panel?.backgroundColor = palette.background
        panel?.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
    }

    // MARK: Building

    private func makePanel() -> QuickNotePanel {
        let panel = QuickNotePanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 460),
                                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.controller = self
        panel.title = "Quick Note"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = model.keepOnTop
        panel.level = model.keepOnTop ? .floating : .normal
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 300, height: 220)
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self

        let toolbar = NSToolbar(identifier: "QuickNote")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified

        let container = NSView()

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.automaticallyAdjustsContentInsets = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let editor = BlockEditorView(theme: theme)
        editor.isScratchpad = true
        editor.readableWidth = theme.style.readableWidth.points
        editor.compactInsets = (top: 10, side: 36)
        editor.frame = NSRect(x: 0, y: 0, width: 420, height: 400)
        scrollView.documentView = editor
        configure(editor)

        let button = NSHostingView(rootView: SlashButton(model: model))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.sizingOptions = [.intrinsicContentSize]
        editor.slashMenuCorner = { [weak editor, weak button] in
            guard let editor, let button else { return nil }
            return editor.convert(button.bounds, from: button)
        }
        editor.onSlashMenuChange = { [weak self] isOpen in self?.model.isSlashMenuOpen = isOpen }

        container.addSubview(scrollView)
        container.addSubview(button)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            button.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
        panel.contentView = container

        if !panel.setFrameUsingName("QuickNotePanel") {
            // First time: near the top of the screen, a little right of centre.
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.midX - 210 + 160, y: screen.maxY - 460 - 80))
            }
        }
        panel.setFrameAutosaveName("QuickNotePanel")

        self.panel = panel
        self.editor = editor
        self.scrollView = scrollView
        self.slashButton = button
        observeChanges()
        restyle()
        return panel
    }

    /// The same hooks the main editor gets, pointed at the scratchpad.
    private func configure(_ editor: BlockEditorView) {
        editor.onChange = { [weak self] in self?.editorDidChange() }
        editor.attachmentHandler = { [weak self, weak editor] input in
            guard let self, let library = self.library, let scratchpad = self.scratchpad else { return nil }
            let link: String?
            switch input {
            case .file(let url): link = library.addAttachment(copying: url, to: scratchpad)
            case .data(let data, let name, let ext): link = library.addAttachment(data: data, name: name, ext: ext, to: scratchpad)
            }
            editor?.baseURL = scratchpad.url.deletingLastPathComponent()
            editor?.mediaCacheURL = library.mediaCache(for: scratchpad)
            return link
        }
        func find(_ name: String) -> Note? {
            guard let notes = state?.library.notes else { return nil }
            let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
            return notes.first { $0.title.lowercased() == wanted }
                ?? notes.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == wanted }
        }
        editor.noteLookup = { name in find(name).map { ($0.displayTitle, $0.text) } }
        editor.openNoteNamed = { [weak self] name in
            guard let self, let target = find(name) else { return }
            self.openInMainWindow(note: target)
        }
        editor.noteNames = { [weak self] in
            (self?.state?.library.notes ?? []).filter { !$0.isScratchpad && !$0.title.isEmpty }.map(\.title).sorted()
        }
    }

    private func observeChanges() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(selectionDidChange(_:)), name: NSTextView.didChangeSelectionNotification, object: nil)
        center.addObserver(self, selector: #selector(defaultsDidChange), name: UserDefaults.didChangeNotification, object: nil)
        center.addObserver(self, selector: #selector(codeDidHighlight), name: CodeHighlighter.didHighlight, object: nil)
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { [weak self] in self?.restyle() }
        }
    }

    @objc private func selectionDidChange(_ notification: Notification) {
        guard let view = notification.object as? BlockTextView, let editor, view.editor === editor else { return }
        lastTextView = view
    }

    @objc private func defaultsDidChange() { restyle() }

    @objc private func codeDidHighlight() {
        for case let code as CodeBlockView in editor?.views ?? [] { code.highlight() }
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    func windowDidResignKey(_ notification: Notification) {
        flush()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor?.noteUndoManager
    }

    // MARK: Toolbar

    private static let actionsItem = NSToolbarItem.Identifier("quickNote.actions")
    private static let browseItem = NSToolbarItem.Identifier("quickNote.browse")
    private static let newItem = NSToolbarItem.Identifier("quickNote.new")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.actionsItem, Self.browseItem, Self.newItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.actionsItem:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Actions")
            item.label = "Actions"
            item.toolTip = "Actions"
            item.showsIndicator = false
            item.menu = actionsMenu()
            return item
        case Self.browseItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "square.on.square", accessibilityDescription: "Browse Entries")
            item.label = "Entries"
            item.toolTip = "Browse Entries (⌘P)"
            item.target = self
            item.action = #selector(browseClicked)
            browseItem = item
            return item
        case Self.newItem:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Entry")
            item.label = "New Entry"
            item.toolTip = "New Entry (⌘N)"
            item.target = self
            item.action = #selector(newClicked)
            return item
        default:
            return nil
        }
    }

    @objc private func browseClicked() { toggleBrowser() }
    @objc private func newClicked() { newEntry() }

    private func actionsMenu() -> NSMenu {
        let menu = QuickNoteActionsMenu(title: "Actions")
        menu.controller = self
        return menu
    }
}

/// The ⌘ menu, rebuilt each time it opens so Keep on Top shows its state.
private final class QuickNoteActionsMenu: NSMenu, NSMenuDelegate {
    weak var controller: QuickNoteController?

    override init(title: String) {
        super.init(title: title)
        delegate = self
    }

    required init(coder: NSCoder) { fatalError() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        removeAllItems()
        guard let controller else { return }
        let keepOnTop = ClosureMenuItem(title: "Keep on Top") { [weak controller] in
            guard let controller else { return }
            controller.setKeepOnTop(!controller.model.keepOnTop)
        }
        keepOnTop.state = controller.model.keepOnTop ? .on : .off
        addItem(keepOnTop)
        addItem(.separator())
        addItem(item("Open in Main Window", "macwindow") { $0.openEntryInMainWindow() })
        addItem(item("Copy Entry", "doc.on.doc") { $0.copyEntry() })
        addItem(item("Move to New Note", "doc.badge.plus") { $0.moveToNewNote() })
        addItem(.separator())
        addItem(item("Delete Entry", "trash") { $0.deleteEntry() })
    }

    private func item(_ title: String, _ symbol: String, _ action: @escaping (QuickNoteController) -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title) { [weak controller] in
            if let controller { action(controller) }
        }
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }
}

// MARK: - Window

final class QuickNotePanel: NSPanel {
    weak var controller: QuickNoteController?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // Esc puts the pane away, unless the slash menu or a selection is using it.
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
           let editor = (contentView?.subviews.compactMap { ($0 as? NSScrollView)?.documentView as? BlockEditorView }.first),
           editor.slash == nil, editor.blockSelection == nil, attachedSheet == nil {
            controller?.hide()
            return
        }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "\r", "n":
                controller?.newEntry()
                return true
            case "p":
                controller?.toggleBrowser()
                return true
            default:
                break
            }
        }
        if super.performKeyEquivalent(with: event) { return true }
        // While another app is active the menus aren't Lotion's, but their
        // shortcuts (format, undo, copy) should still work here.
        if !NSApp.isActive, let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) { return true }
        return false
    }
}

// MARK: - Open at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}
