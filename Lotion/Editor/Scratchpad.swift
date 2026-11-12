//
//  Scratchpad.swift
//  Lotion
//
//  The scratchpad is one endless page of entries. ⌘↩ starts a new entry
//  after the one being written; each entry opens with a break that runs the
//  full width of the page and says when it was started. In the file a break
//  is an HTML comment, `<!-- entry 2026-11-06T11:02:00Z -->`, so the page is
//  still plain Markdown anywhere else.
//

import AppKit

// MARK: - Entries

extension BlockEditorView {
    /// The index of the break that starts the entry holding `index`.
    func entryStart(containing index: Int) -> Int? {
        guard blocks.indices.contains(index) else { return nil }
        return (0...index).last { blocks[$0].kind == .entry }
    }

    /// One past the last block of the entry holding `index`.
    func entryEnd(containing index: Int) -> Int {
        var end = index + 1
        while end < blocks.count, blocks[end].kind != .entry { end += 1 }
        return end
    }

    /// Starts a new entry after the one with the caret (or at the end), and
    /// puts the caret in it. An entry with nothing in it yet is reused.
    func newEntry() {
        guard isScratchpad, !blocks.isEmpty else { return }
        let current = focusedIndex ?? blockSelection?.upperBound ?? blocks.count - 1
        let start = entryStart(containing: current) ?? 0
        let end = entryEnd(containing: current)

        let body = Array(blocks[(start + 1)..<end])
        if body.allSatisfy({ $0.kind == .paragraph && $0.text.length == 0 }), let empty = body.first {
            focus(empty.id, .start)
            revealEntry(at: start)
            return
        }

        // Blank lines left at the end of the entry go; the break replaces them.
        var trailing = 0
        while end - trailing - 1 > start + 1, blocks[end - trailing - 1].kind == .paragraph,
              blocks[end - trailing - 1].text.length == 0 {
            trailing += 1
        }
        var marker = Block(kind: .entry)
        marker.info = Date.now.formatted(.iso8601)
        let paragraph = Block(kind: .paragraph)
        mutate("New Entry", focus: .text(paragraph.id, nil, NSRange(location: 0, length: 0))) { blocks in
            if trailing > 0 { blocks.removeSubrange((end - trailing)..<end) }
            blocks.insert(contentsOf: [marker, paragraph], at: end - trailing)
        }
        if let view = view(for: marker.id) {
            // The new break draws in, rather than appearing all at once.
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.23, 1, 0.32, 1)
                view.animator().alphaValue = 1
            }
        }
        (self.view(for: paragraph.id) as? TextBlockView)?.updatePlaceholder()
        if let index = index(of: marker.id) { revealEntry(at: index) }
    }

    /// Puts the caret at the end of the entry whose break says `id`, with
    /// the entry scrolled into view.
    func revealEntry(id: String) {
        guard let start = blocks.firstIndex(where: { $0.kind == .entry && $0.info == id }) else { return }
        let end = entryEnd(containing: start)
        if let last = blocks[(start + 1)..<end].last(where: { $0.kind.isEditable }) { focus(last.id, .end) }
        revealEntry(at: start)
    }

    /// Scrolls so an entry's break sits near the top, with room to write under it.
    private func revealEntry(at index: Int) {
        guard views.indices.contains(index) else { return }
        let frame = views[index].frame
        let insetTop = enclosingScrollView?.contentInsets.top ?? 0
        let wanted = NSRect(x: 0, y: max(0, frame.minY - insetTop - 24), width: 1, height: min(visibleRect.height * 0.5, 320))
        if !visibleRect.contains(NSRect(x: 0, y: frame.minY, width: 1, height: frame.height + 60)) { scrollToVisible(wanted) }
    }

    /// An entry's name for the scroll spy: its first line of text.
    func entryTitle(at start: Int) -> String {
        let end = entryEnd(containing: start)
        for block in blocks[(start + 1)..<end] {
            let line = block.plainText.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty { return line }
            if block.kind == .image { return block.imageAlt.isEmpty ? "Image" : block.imageAlt }
        }
        return "Empty entry"
    }
}

// MARK: - The break

/// Where an entry starts: a hairline across the whole page with the time
/// the entry was started sitting on it, in line with the text. The first
/// entry has only its time.
final class EntryBreakView: BlockView {
    private var isFirst: Bool { editor?.blocks.first?.id == block.id }

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        updateToolTip()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func update(_ block: Block) {
        super.update(block)
        updateToolTip()
        needsDisplay = true
    }

    private func updateToolTip() {
        toolTip = Self.date(block.info).map { "Started \($0.formatted(date: .complete, time: .shortened))" }
    }

    override func measure(width: CGFloat) -> CGFloat { round(theme.em * 1.5) }

    override var firstLineMidY: CGFloat { round(bounds.midY) }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let label = Self.label(for: block.info) as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: palette.secondary.withAlphaComponent(0.6),
            .kern: 0.2,
        ]
        let size = label.size(withAttributes: attributes)
        let midY = round(bounds.midY)
        let x = editor?.columnX ?? 0
        if !isFirst {
            palette.rule.withAlphaComponent(palette.rule.alphaComponent * 0.6).setFill()
            NSRect(x: 0, y: midY, width: bounds.width, height: 1).fill()
            // The time sits on the line, with the page showing around it.
            palette.background.setFill()
            NSRect(x: x - 8, y: midY - size.height / 2, width: size.width + 16, height: size.height).fill()
        }
        label.draw(at: NSPoint(x: x, y: round(midY - size.height / 2)), withAttributes: attributes)
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        editor?.selectBlocks([block.id])
        return true
    }

    static func date(_ iso: String) -> Date? {
        try? Date(iso, strategy: .iso8601)
    }

    /// "Today · 11:02", "Yesterday · 18:40", "Mon, Nov 3 · 09:12", "Nov 3, 2025 · 09:12".
    static func label(for iso: String) -> String {
        guard let date = date(iso) else { return "Entry" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today · \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday · \(time)" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + " · " + time
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year()) + " · " + time
    }
}
