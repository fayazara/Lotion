//
//  NoteEditor.swift
//  Lotion
//
//  Hosts EditorTextView in SwiftUI. One text view serves every note: opening
//  a note swaps its text in, gives it its own undo stack, and restores where
//  the caret and scroll were the last time it was open.
//

import AppKit
import SwiftUI

/// Lets the rest of the app reach the editor: focus it, reveal a range.
final class EditorController {
    fileprivate(set) weak var textView: EditorTextView?
    fileprivate var pendingFocus: Note.ID?
    fileprivate var pendingReveal: (note: Note.ID, range: NSRange, select: Bool)?

    func focus(_ note: Note) {
        pendingFocus = note.id
        flush(for: note.id)
    }

    func reveal(_ range: NSRange, in note: Note, select: Bool = false) {
        pendingReveal = (note.id, range, select)
        flush(for: note.id)
    }

    /// Runs requests for the note on screen, once it is laid out.
    fileprivate func flush(for noteID: Note.ID?) {
        guard let textView, let noteID, (textView.delegate as? NoteEditor.Coordinator)?.noteID == noteID else { return }
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            if let reveal = self.pendingReveal, reveal.note == noteID {
                self.pendingReveal = nil
                textView.reveal(reveal.range, select: reveal.select)
            }
            if self.pendingFocus == noteID {
                self.pendingFocus = nil
                textView.window?.makeFirstResponder(textView)
            }
        }
    }
}

struct NoteEditor: NSViewRepresentable {
    let note: Note
    let cover: NoteCover?
    let style: EditorStyle
    let library: Library
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        let textView = EditorTextView.make()
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        scrollView.documentView = textView
        context.coordinator.textView = textView
        controller.textView = textView
        textView.onFocusChange = { [weak coordinator = context.coordinator] in coordinator?.updateReveal() }
        context.coordinator.connectCover()

        context.coordinator.apply(style)
        context.coordinator.load(note)
        context.coordinator.show(cover)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        controller.textView = coordinator.textView
        coordinator.apply(style)
        scrollView.backgroundColor = style.palette.background
        if coordinator.noteID != note.id || coordinator.diskRevision != note.diskRevision {
            coordinator.load(note)
        }
        coordinator.show(cover)
        controller.flush(for: note.id)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.rememberViewState()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        let library: Library
        weak var textView: EditorTextView?
        private(set) var noteID: Note.ID?
        private(set) var diskRevision = 0
        private weak var note: Note?
        private var styler: MarkdownStyler?
        private var undoManagers: [Note.ID: UndoManager] = [:]
        private var viewStates: [Note.ID: (selection: NSRange, scroll: CGFloat)] = [:]
        private var isLoading = false
        /// The lines last restyled for the selection, to hide their marks again when it leaves.
        private var revealedLines: NSRange?
        private var highlightObserver: NSObjectProtocol?

        init(library: Library) {
            self.library = library
            super.init()
            highlightObserver = NotificationCenter.default.addObserver(
                forName: CodeHighlighter.didHighlight, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.restyleAll() }
            }
        }

        deinit {
            if let highlightObserver { NotificationCenter.default.removeObserver(highlightObserver) }
        }

        // MARK: Style

        func apply(_ style: EditorStyle) {
            guard let textView else { return }
            if let styler, styler.style == style { return }
            if let styler { styler.update(style: style) } else { styler = MarkdownStyler(style: style) }
            guard let styler else { return }
            let palette = styler.palette
            textView.styler = styler
            textView.palette = palette
            textView.gutter = styler.gutter
            textView.headingFonts = styler.fonts.headings
            textView.bodyFont = styler.fonts.body
            textView.readableWidth = style.readableWidth.points
            textView.backgroundColor = palette.background
            textView.insertionPointColor = palette.text
            textView.selectedTextAttributes = [.backgroundColor: palette.selection]
            textView.isContinuousSpellCheckingEnabled = style.spellCheck
            textView.enclosingScrollView?.backgroundColor = palette.background
            textView.enclosingScrollView?.scrollerKnobStyle = palette.isDark ? .light : .dark
            restyleAll()
            textView.cellStyleDidChange()
            textView.syncCodeViews()
        }

        private func restyleAll() {
            guard let textView, let storage = textView.textStorage, let styler else { return }
            storage.beginEditing()
            styler.restyle(storage, edited: nil)
            storage.endEditing()
            textView.typingAttributes = styler.typingAttributes
            textView.needsDisplay = true
        }

        // MARK: Notes

        func load(_ note: Note) {
            guard let textView else { return }
            let isSameNote = note.id == noteID
            textView.endCellEditing()
            if !isSameNote {
                rememberViewState()
                textView.tableScrollOffsets = [:]
            }
            textView.removeCodeViews()
            let previousSelection = textView.selectedRange()

            isLoading = true
            styler?.reveal = nil
            revealedLines = nil
            self.note = note
            noteID = note.id
            diskRevision = note.diskRevision
            textView.string = note.text
            isLoading = false
            if let styler { textView.typingAttributes = styler.typingAttributes }

            let length = (note.text as NSString).length
            if isSameNote {
                // The file changed on disk: keep the caret near where it was.
                textView.setSelectedRange(NSRange(location: min(previousSelection.location, length), length: 0))
            } else if let state = viewStates[note.id] {
                let selection = NSRange(location: min(state.selection.location, length),
                                        length: min(state.selection.length, max(0, length - state.selection.location)))
                textView.setSelectedRange(selection)
                restoreScroll(state.scroll)
            } else {
                textView.setSelectedRange(NSRange(location: length, length: 0))
                restoreScroll(nil)
            }
        }

        func rememberViewState() {
            guard let textView, let noteID, let scrollView = textView.enclosingScrollView else { return }
            viewStates[noteID] = (textView.selectedRange(), scrollView.contentView.bounds.origin.y)
        }

        private func restoreScroll(_ y: CGFloat?) {
            guard let scrollView = textView?.enclosingScrollView else { return }
            let top = -scrollView.contentInsets.top
            let target = y ?? top
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
            guard let textView else { return }
            textView.onAddCover = { [weak self] in
                guard let self, let note = self.note else { return }
                self.library.addRandomCover(for: note)
            }
            textView.onRemoveCover = { [weak self] in
                guard let self, let note = self.note else { return }
                self.library.setCover(nil, for: note)
            }
            textView.onMoveCover = { [weak self] position in
                guard let self, let note = self.note, var cover = self.library.cover(for: note) else { return }
                cover.position = position
                self.library.setCover(cover, for: note)
            }
            textView.onChangeCover = { [weak self] rect in self?.showCoverPicker(at: rect) }
            textView.onResizeCode = { [weak self] fence, lines, done in
                guard let self, let textView = self.textView, let storage = textView.textStorage, let styler = self.styler else { return }
                if done {
                    styler.previewLines[fence] = nil
                    if lines > 0 { textView.setCodeLines(lines, fenceAt: fence); return }
                } else {
                    styler.previewLines[fence] = lines
                }
                do {
                    storage.beginEditing()
                    styler.restyle(storage, edited: NSRange(location: fence, length: 0))
                    storage.endEditing()
                }
            }
        }

        /// Shows the note's cover, decoding its image off the main thread.
        func show(_ cover: NoteCover?) {
            guard let textView, !didShowCover || cover != shownCover else { return }
            didShowCover = true
            shownCover = cover
            guard let cover else {
                textView.setCover(false, image: nil, position: 0.5, credit: nil, creditURL: nil)
                return
            }
            let url = cover.url(in: library)
            let cached = CoverImages.cached(url)
            textView.setCover(true, image: cached, position: cover.position, credit: cover.credit, creditURL: cover.creditURL)
            guard cached == nil else { return }
            CoverImages.load(url) { [weak self] image in
                guard let self, self.shownCover == cover else { return }
                self.textView?.setCover(true, image: image, position: cover.position, credit: cover.credit, creditURL: cover.creditURL)
            }
        }

        private func showCoverPicker(at rect: NSRect) {
            guard let textView, let note else { return }
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = NSHostingController(rootView: CoverPicker(note: note, library: library))
            popover.show(relativeTo: rect, of: textView, preferredEdge: .maxY)
            coverPopover = popover
        }

        // MARK: NSTextStorageDelegate

        nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                                     range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MainActor.assumeIsolated {
                // Typing leaves the caret after the edit; reveal for where it
                // will be, so the selection change that follows has nothing to redo.
                // Only an edit at or before the caret moves it.
                if let styler, let reveal = styler.reveal, editedRange.location <= NSMaxRange(reveal) {
                    styler.reveal = NSRange(location: max(0, NSMaxRange(reveal) + delta), length: 0)
                }
                styler?.restyle(textStorage, edited: editedRange)
                textView?.storageDidEdit(editedRange, delta: delta)
                textView?.shiftCodeViews(after: editedRange.location, by: delta)
                textView?.setNeedsCodeViewSync()
            }
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let textView, let note else { return }
            // A native copy: the text view's string is bridged, and every
            // comparison or scan of a bridged string walks it slowly.
            var text = textView.string
            text.makeContiguousUTF8()
            library.update(note, text: text)
            // The placeholder draws outside the edited range; redraw while it may show.
            if text.utf16.count <= 3 { textView.needsDisplay = true }
        }

        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange oldSelectedCharRange: NSRange,
                      toCharacterRange newSelectedCharRange: NSRange) -> NSRange {
            self.textView?.snappedSelection(from: oldSelectedCharRange, to: newSelectedCharRange) ?? newSelectedCharRange
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateReveal()
            textView?.invalidatePlaceholders()
        }

        /// Shows the marks of the spans and code block the selection touches,
        /// and hides the ones it left. Only lines with such syntax restyle.
        func updateReveal() {
            guard !isLoading, let textView, let storage = textView.textStorage, let styler else { return }
            let isFocused = textView.window?.firstResponder === textView
            let selection = isFocused ? textView.selectedRange() : nil
            guard selection != styler.reveal else { return }
            let text = storage.string as NSString
            let lines = selection.map { text.lineRange(for: NSRange(location: min($0.location, text.length), length: min($0.length, text.length - min($0.location, text.length)))) }
            var dirty: [NSRange] = []
            for case var range? in [revealedLines, lines] {
                range = NSIntersectionRange(range, NSRange(location: 0, length: text.length))
                var hasSyntax = false
                for key in [NSAttributedString.Key.lotionHidden, .lotionRevealable] where !hasSyntax {
                    storage.enumerateAttribute(key, in: range) { value, _, stop in
                        if value != nil { hasSyntax = true; stop.pointee = true }
                    }
                }
                if hasSyntax { dirty.append(range) }
            }
            styler.reveal = selection
            revealedLines = lines
            guard !dirty.isEmpty else { return }
            storage.beginEditing()
            for range in dirty { styler.restyle(storage, edited: range) }
            storage.endEditing()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            guard let noteID else { return nil }
            if let manager = undoManagers[noteID] { return manager }
            let manager = UndoManager()
            undoManagers[noteID] = manager
            return manager
        }

        func textView(_ textView: NSTextView, shouldSetSpellingState value: Int, range affectedCharRange: NSRange) -> Int {
            guard let storage = textView.textStorage, affectedCharRange.location < storage.length else { return value }
            let index = affectedCharRange.location
            if (storage.attribute(.lotionBlock, at: index, effectiveRange: nil) as? BlockDecoration)?.kind == .code
                || storage.attribute(.lotionTableText, at: index, effectiveRange: nil) != nil
                || storage.attribute(.lotionInlineCode, at: index, effectiveRange: nil) != nil
                || storage.attribute(.lotionURL, at: index, effectiveRange: nil) != nil {
                return 0
            }
            return value
        }
    }
}
