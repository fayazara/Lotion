//
//  MarkdownSourceEditor.swift
//  Lotion
//
//  The note as plain Markdown, for when you want the file itself: a plain
//  text view in the code font, with the syntax tinted and nothing hidden.
//

import AppKit
import SwiftUI

enum EditorMode: String {
    case blocks, markdown
}

struct MarkdownSourceEditor: NSViewRepresentable {
    let note: Note
    let style: EditorStyle
    let library: Library
    let controller: EditorController

    func makeCoordinator() -> Coordinator { Coordinator(library: library) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SourceTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        context.coordinator.textView = textView
        controller.sourceTextView = textView
        context.coordinator.apply(style, to: scrollView)
        context.coordinator.load(note)
        DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        controller.sourceTextView = context.coordinator.textView
        context.coordinator.apply(style, to: scrollView)
        context.coordinator.load(note)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flush()
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let library: Library
        weak var textView: NSTextView?
        private weak var note: Note?
        private var noteID: Note.ID?
        private var diskRevision = 0
        private var style: EditorStyle?
        private var undoManagers: [Note.ID: UndoManager] = [:]
        private var isLoading = false

        init(library: Library) { self.library = library }

        func apply(_ style: EditorStyle, to scrollView: NSScrollView) {
            guard style != self.style, let textView else { return }
            self.style = style
            let palette = style.palette
            scrollView.backgroundColor = palette.background
            scrollView.scrollerKnobStyle = palette.isDark ? .light : .dark
            textView.backgroundColor = palette.background
            textView.insertionPointColor = palette.text
            textView.selectedTextAttributes = [.backgroundColor: palette.selection]
            textView.isContinuousSpellCheckingEnabled = false
            (textView as? SourceTextView)?.readableWidth = style.readableWidth.points
            highlight()
        }

        func load(_ note: Note) {
            guard let textView else { return }
            if note.id == noteID, note.diskRevision == diskRevision { return }
            self.note = note
            noteID = note.id
            diskRevision = note.diskRevision
            guard textView.string != note.text else { return }
            isLoading = true
            textView.string = note.text
            isLoading = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            highlight()
        }

        func flush() {
            guard let note, let text = textView?.string, text != note.text else { return }
            library.update(note, text: text)
        }

        func textDidChange(_ notification: Notification) {
            guard !isLoading, let note, let textView else { return }
            var text = textView.string
            text.makeContiguousUTF8()
            library.update(note, text: text)
            highlight()
        }

        func undoManager(for view: NSTextView) -> UndoManager? {
            guard let noteID else { return nil }
            if let manager = undoManagers[noteID] { return manager }
            let manager = UndoManager()
            undoManagers[noteID] = manager
            return manager
        }

        // MARK: Tinting

        func highlight() {
            guard let textView, let storage = textView.textStorage, let style else { return }
            let palette = style.palette
            let size = style.noteFontSize - 1
            let font = FontChoice.font(style.codeFont, size: size)
            let bold = FontChoice.font(style.codeFont, size: size, weight: .bold)
            let paragraph = NSMutableParagraphStyle()
            let lineHeight = round(size * style.lineSpacing.multiple)
            paragraph.minimumLineHeight = lineHeight
            paragraph.maximumLineHeight = lineHeight
            let natural = NSLayoutManager().defaultLineHeight(for: font)
            let base: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: palette.text, .paragraphStyle: paragraph,
                .baselineOffset: floor((lineHeight - natural) / 2),
            ]
            textView.typingAttributes = base
            let string = storage.string as NSString
            let full = NSRange(location: 0, length: string.length)
            storage.beginEditing()
            storage.setAttributes(base, range: full)
            guard string.length < 400_000 else { storage.endEditing(); return }
            var inFence = false
            string.enumerateSubstrings(in: full, options: [.byLines]) { line, range, _, _ in
                guard let line else { return }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                    inFence.toggle()
                    storage.addAttribute(.foregroundColor, value: palette.marker, range: range)
                    return
                }
                if inFence {
                    storage.addAttribute(.foregroundColor, value: palette.secondary, range: range)
                    return
                }
                Self.tint(line, at: range.location, in: storage, palette: palette, bold: bold)
            }
            storage.endEditing()
        }

        private static let patterns: [(NSRegularExpression, Int)] = [
            #"^\s{0,3}(#{1,6})\s"#, #"^\s*([-*+]|\d+[.)])\s"#, #"^\s*[-*+]\s(\[[ xX]\])"#, #"^\s{0,3}(>+)"#,
            #"^\s{0,3}((?:[-*_]\s*){3,})$"#, #"(`[^`]+`)"#, #"(\*\*|__)(?=\S)"#, #"(?<=\S)(\*\*|__)"#,
            #"\]\(([^)\s]+)\)"#, #"(<[A-Za-z/!][^>]*>)"#, #"(\|)"#,
        ].enumerated().compactMap { index, pattern in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, index) }
        }

        private static func tint(_ line: String, at offset: Int, in storage: NSTextStorage, palette: ThemePalette, bold: NSFont) {
            let ns = line as NSString
            let range = NSRange(location: 0, length: ns.length)
            for (regex, index) in patterns {
                for match in regex.matches(in: line, range: range) {
                    let group = match.range(at: 1)
                    guard group.location != NSNotFound else { continue }
                    let target = NSRange(location: offset + group.location, length: group.length)
                    switch index {
                    case 0:
                        // A heading: its marks dim, its text bold.
                        storage.addAttribute(.foregroundColor, value: palette.marker, range: target)
                        storage.addAttribute(.font, value: bold, range: NSRange(location: offset + NSMaxRange(group), length: ns.length - NSMaxRange(group)))
                    case 5:
                        storage.addAttribute(.foregroundColor, value: palette.accent, range: target)
                    case 8:
                        storage.addAttribute(.foregroundColor, value: palette.secondary, range: target)
                    default:
                        storage.addAttribute(.foregroundColor, value: palette.marker, range: target)
                    }
                }
            }
        }
    }
}

/// Keeps the Markdown in a readable column, like the block editor's.
final class SourceTextView: NSTextView {
    var readableWidth: CGFloat = 700 { didSet { updateInsets() } }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateInsets()
    }

    private func updateInsets() {
        let horizontal = max(56, (bounds.width - readableWidth) / 2)
        let inset = NSSize(width: round(horizontal), height: 60)
        if textContainerInset != inset { textContainerInset = inset }
    }
}
