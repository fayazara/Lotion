//
//  NoteEditor.swift
//  Lotion
//
//  Hosts the block editor in SwiftUI. One editor serves every note: opening
//  a note parses its Markdown into blocks, gives it its own undo history, and
//  restores where the caret and scroll were the last time it was open. Every
//  edit is written back to the note as Markdown.
//

import AppKit
import SwiftUI

/// Lets the rest of the app reach the editor: focus it, reveal a heading or a match.
final class EditorController {
    fileprivate(set) weak var editor: BlockEditorView?
    /// The Markdown editor, while the note shows as Markdown.
    weak var sourceTextView: NSTextView?
    /// The note's headings and the one being read, for the map beside the note.
    let scrollSpy = ScrollSpy()

    /// Requests go to the Markdown editor when it is the one on screen.
    private var source: NSTextView? {
        guard let view = sourceTextView, view.window != nil else { return nil }
        return view
    }
    fileprivate var noteID: Note.ID?
    /// Shows another note, for embeds that link to one.
    var openNote: ((Note.ID) -> Void)?
    private var pending: [(Note.ID, (BlockEditorView) -> Void)] = []

    func focus(_ note: Note) {
        if let source {
            DispatchQueue.main.async {
                source.window?.makeFirstResponder(source)
                source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
            }
            return
        }
        run(on: note) { editor in
            if let first = editor.blocks.first, first.text.length == 0 || editor.blocks.count == 1 {
                editor.focus(first.id, .end)
            } else if let last = editor.blocks.last(where: { $0.kind.isEditable }) {
                editor.focus(last.id, .end)
            }
        }
    }

    func revealHeading(_ ordinal: Int, in note: Note) {
        if let source {
            DispatchQueue.main.async { Self.revealHeading(ordinal, in: source) }
            return
        }
        run(on: note) { $0.revealHeading(ordinal) }
    }

    /// A new scratchpad entry after the one with the caret.
    func newEntry(in note: Note) {
        if let source {
            DispatchQueue.main.async {
                // In Markdown, the entry's line goes after the paragraph with the caret.
                let string = source.string as NSString
                let caret = source.selectedRange().location
                let paragraphEnd = string.range(of: "\n\n", options: [], range: NSRange(location: caret, length: string.length - caret)).location
                let at = paragraphEnd == NSNotFound ? string.length : paragraphEnd
                let insertion = "\n\n" + Library.entryMarker() + "\n\n"
                source.insertText(insertion, replacementRange: NSRange(location: at, length: 0))
                source.scrollRangeToVisible(source.selectedRange())
            }
            return
        }
        run(on: note) { $0.newEntry() }
    }

    func revealMatch(_ query: String, in note: Note) {
        if let source {
            DispatchQueue.main.async {
                let range = (source.string as NSString).range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
                guard range.location != NSNotFound else { return }
                source.setSelectedRange(range)
                source.scrollRangeToVisible(range)
            }
            return
        }
        run(on: note) { $0.revealMatch(query) }
    }

    private static func revealHeading(_ ordinal: Int, in source: NSTextView) {
        let headings = BlockMarkdown.parse(source.string).blocks.filter {
            ($0.kind.headingLevel ?? 9) <= 3 && !$0.text.string.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard headings.indices.contains(ordinal) else { return }
        let title = headings[ordinal].text.string
        let string = source.string as NSString
        var found = NSRange(location: NSNotFound, length: 0)
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byLines) { line, range, _, stop in
            if let line, line.hasPrefix("#"), line.contains(title) {
                found = range
                stop.pointee = true
            }
        }
        guard found.location != NSNotFound else { return }
        source.window?.makeFirstResponder(source)
        source.setSelectedRange(NSRange(location: NSMaxRange(found), length: 0))
        source.scrollRangeToVisible(found)
    }

    private func run(on note: Note, _ action: @escaping (BlockEditorView) -> Void) {
        pending.append((note.id, action))
        flush(for: note.id)
    }

    /// Runs requests for the note on screen, once it is laid out.
    fileprivate func flush(for noteID: Note.ID?) {
        guard let editor, let noteID, self.noteID == noteID else { return }
        DispatchQueue.main.async { [weak self, weak editor] in
            guard let self, let editor, self.noteID == noteID else { return }
            let ready = self.pending.filter { $0.0 == noteID }
            self.pending.removeAll { $0.0 == noteID }
            for (_, action) in ready { action(editor) }
        }
    }
}

struct NoteEditor: NSViewRepresentable {
    let note: Note
    let cover: NoteCover?
    let style: EditorStyle
    let library: Library
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(library: library, style: style) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        let editor = BlockEditorView(theme: context.coordinator.theme)
        editor.frame = NSRect(x: 0, y: 0, width: max(400, scrollView.contentSize.width), height: 600)
        scrollView.documentView = editor
        context.coordinator.editor = editor
        context.coordinator.controller = controller
        controller.editor = editor
        editor.scrollSpy = controller.scrollSpy
        controller.scrollSpy.editor = editor
        context.coordinator.connectCover()
        context.coordinator.applyColors(scrollView)
        context.coordinator.load(note)
        controller.noteID = note.id
        context.coordinator.show(cover)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        controller.editor = coordinator.editor
        coordinator.apply(style)
        coordinator.applyColors(scrollView)
        if coordinator.noteID != note.id || coordinator.diskRevision != note.diskRevision {
            coordinator.load(note)
        }
        controller.noteID = note.id
        coordinator.show(cover)
        controller.flush(for: note.id)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        LinkPreview.shared.hide()
        MediaZoom.shared.hide(animated: false)
        coordinator.rememberViewState()
    }

    final class Coordinator {
        let library: Library
        weak var controller: EditorController?
        weak var editor: BlockEditorView?
        private(set) var theme: BlockTheme
        private(set) var noteID: Note.ID?
        private(set) var diskRevision = 0
        private weak var note: Note?
        private var undoManagers: [Note.ID: UndoManager] = [:]
        private var viewStates: [Note.ID: (focus: BlockEditorView.FocusTarget, scroll: CGFloat)] = [:]
        private var highlightObserver: NSObjectProtocol?

        init(library: Library, style: EditorStyle) {
            self.library = library
            Favicons.directory = library.root.appending(path: ".lotion/favicons", directoryHint: .isDirectory)
            LinkPreview.directory = library.root.appending(path: ".lotion/previews", directoryHint: .isDirectory)
            EmbedCache.directory = library.root.appending(path: ".lotion/embeds", directoryHint: .isDirectory)
            theme = BlockTheme(style: style)
            highlightObserver = NotificationCenter.default.addObserver(
                forName: CodeHighlighter.didHighlight, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    for case let code as CodeBlockView in self?.editor?.views ?? [] { code.highlight() }
                }
            }
        }

        deinit {
            if let highlightObserver { NotificationCenter.default.removeObserver(highlightObserver) }
        }

        func apply(_ style: EditorStyle) {
            guard style != theme.style else { return }
            theme = BlockTheme(style: style)
            editor?.readableWidth = style.readableWidth.points
            editor?.apply(theme: theme)
        }

        func applyColors(_ scrollView: NSScrollView) {
            scrollView.backgroundColor = theme.palette.background
            scrollView.scrollerKnobStyle = theme.palette.isDark ? .light : .dark
        }

        // MARK: Notes

        func load(_ note: Note) {
            guard let editor else { return }
            let isSameNote = note.id == noteID
            if !isSameNote { rememberViewState() }
            if isSameNote, editor.markdown() == note.text {
                diskRevision = note.diskRevision
                return
            }
            let previousFocus = isSameNote ? editor.viewState() : nil
            self.note = note
            noteID = note.id
            diskRevision = note.diskRevision
            editor.readableWidth = theme.style.readableWidth.points
            editor.baseURL = note.url.deletingLastPathComponent()
            editor.mediaCacheURL = library.mediaCache(for: note)
            editor.noteUndoManager = undoManager(for: note.id)
            if isSameNote { editor.noteUndoManager?.removeAllActions() }
            editor.onChange = { [weak self, weak editor] in
                guard let self, let editor, let note = self.note else { return }
                var text = editor.markdown()
                text.makeContiguousUTF8()
                if text != note.text { self.library.update(note, text: text) }
            }
            editor.attachmentHandler = { [weak self, weak editor] input in
                guard let self, let note = self.note else { return nil }
                let link: String?
                switch input {
                case .file(let url): link = self.library.addAttachment(copying: url, to: note)
                case .data(let data, let name, let ext): link = self.library.addAttachment(data: data, name: name, ext: ext, to: note)
                }
                // The note may have just moved into a folder of its own.
                editor?.baseURL = note.url.deletingLastPathComponent()
                editor?.mediaCacheURL = self.library.mediaCache(for: note)
                return link
            }
            let library = self.library
            func find(_ name: String) -> Note? {
                let wanted = name.trimmingCharacters(in: .whitespaces).lowercased()
                return library.notes.first { $0.title.lowercased() == wanted }
                    ?? library.notes.first { $0.url.deletingPathExtension().lastPathComponent.lowercased() == wanted }
            }
            editor.noteLookup = { name in find(name).map { ($0.displayTitle, $0.text) } }
            editor.openNoteNamed = { [weak self] name in
                guard let target = find(name) else { return }
                self?.controller?.openNote?(target.id)
            }
            editor.noteNames = { [weak self] in
                library.notes.filter { $0.id != self?.note?.id && !$0.isScratchpad && !$0.title.isEmpty }.map(\.title).sorted()
            }
            editor.isScratchpad = note.isScratchpad
            editor.load(BlockMarkdown.parse(note.text))

            if let previousFocus {
                // The file changed on disk: keep the caret near where it was.
                editor.apply(previousFocus)
            } else if let state = viewStates[note.id] {
                restoreScroll(state.scroll)
                if editor.window?.firstResponder is BlockTextView || editor.window?.firstResponder === editor {
                    editor.apply(state.focus)
                }
            } else {
                restoreScroll(nil)
            }
        }

        private func undoManager(for id: Note.ID) -> UndoManager {
            if let manager = undoManagers[id] { return manager }
            let manager = UndoManager()
            manager.groupsByEvent = false
            undoManagers[id] = manager
            return manager
        }

        func rememberViewState() {
            guard let editor, let noteID, let scrollView = editor.enclosingScrollView else { return }
            viewStates[noteID] = (editor.viewState(), scrollView.contentView.bounds.origin.y)
        }

        private func restoreScroll(_ y: CGFloat?) {
            guard let scrollView = editor?.enclosingScrollView else { return }
            let target = y ?? -scrollView.contentInsets.top
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: target))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            // Layout can settle after the first pass; apply once more.
            DispatchQueue.main.async { [weak scrollView] in
                guard let scrollView else { return }
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: y ?? -scrollView.contentInsets.top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        // MARK: Cover

        private var shownCover: NoteCover?
        private var didShowCover = false
        private var coverPopover: NSPopover?

        func connectCover() {
            guard let editor else { return }
            editor.cover.onAdd = { [weak self] in
                guard let self, let note = self.note else { return }
                self.library.addRandomCover(for: note)
            }
            editor.cover.onRemove = { [weak self] in
                guard let self, let note = self.note else { return }
                self.library.setCover(nil, for: note)
            }
            editor.cover.onMove = { [weak self] position in
                guard let self, let note = self.note, var cover = self.library.cover(for: note) else { return }
                cover.position = position
                self.library.setCover(cover, for: note)
            }
            editor.cover.onChange = { [weak self] rect in self?.showCoverPicker(at: rect) }
            editor.cover.applyTheme(theme)
        }

        /// Shows the note's cover, decoding its image off the main thread.
        func show(_ cover: NoteCover?) {
            guard let editor, !didShowCover || cover != shownCover else { return }
            didShowCover = true
            shownCover = cover
            guard let cover else {
                editor.cover.set(false, image: nil, position: 0.5, credit: nil, creditURL: nil, in: editor)
                return
            }
            let url = cover.url(in: library)
            let cached = CoverImages.cached(url)
            editor.cover.set(true, image: cached, position: cover.position, credit: cover.credit, creditURL: cover.creditURL, in: editor)
            guard cached == nil else { return }
            CoverImages.load(url) { [weak self] image in
                guard let self, let editor = self.editor, self.shownCover == cover else { return }
                editor.cover.set(true, image: image, position: cover.position, credit: cover.credit, creditURL: cover.creditURL, in: editor)
            }
        }

        private func showCoverPicker(at rect: NSRect) {
            guard let editor, let note else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: CoverPicker(note: note, library: library))
            popover.show(relativeTo: rect, of: editor, preferredEdge: .maxY)
            coverPopover = popover
        }
    }
}
