//
//  ScratchpadEntries.swift
//  Lotion
//
//  The scratchpad's entries as pieces of its Markdown, so one entry can be
//  edited on its own (in the quick note pane) and put back where it was.
//  An entry is known by the time on its break, `<!-- entry … -->`; the
//  blocks are parsed rather than the lines split, so a break written inside
//  a code block is not mistaken for one.
//

import Foundation

enum ScratchpadEntries {
    struct Entry: Identifiable, Equatable {
        /// The time on the entry's break, as written.
        let id: String
        let date: Date?
        /// The first line of text, or "" while the entry is empty.
        let title: String
        /// The entry's text on one line, for searching and the list.
        let preview: String

        var isEmpty: Bool { preview.isEmpty }
        var displayTitle: String { title.isEmpty ? "Empty entry" : title }
    }

    /// Every entry, in the order of the page (oldest first).
    static func entries(in text: String) -> [Entry] {
        let blocks = BlockMarkdown.parse(text).blocks
        return spans(blocks).map { span in
            let body = blocks[(span.range.lowerBound + 1)..<span.range.upperBound]
            return Entry(id: span.id, date: EntryBreakView.date(span.id), title: title(of: body), preview: preview(of: body))
        }
    }

    /// One entry as a page of its own, its break first.
    static func markdown(of id: String, in text: String) -> String? {
        let blocks = BlockMarkdown.parse(text).blocks
        guard let range = spans(blocks).first(where: { $0.id == id })?.range else { return nil }
        return BlockMarkdown.write(Array(blocks[range]), trailingNewlines: 1)
    }

    /// The entry's Markdown without its break, as it would be copied.
    static func body(of id: String, in text: String) -> String? {
        let blocks = BlockMarkdown.parse(text).blocks
        guard let range = spans(blocks).first(where: { $0.id == id })?.range else { return nil }
        let body = Array(blocks[(range.lowerBound + 1)..<range.upperBound])
        return BlockMarkdown.write(body, trailingNewlines: 0).trimmingCharacters(in: .newlines)
    }

    /// The page with one entry swapped for `markdown` (which starts with a
    /// break of its own). Nil when the entry is gone.
    static func replacing(_ id: String, in text: String, with markdown: String) -> String? {
        let document = BlockMarkdown.parse(text)
        var blocks = document.blocks
        guard let range = spans(blocks).first(where: { $0.id == id })?.range else { return nil }
        blocks.replaceSubrange(range, with: BlockMarkdown.parse(markdown).blocks)
        return BlockMarkdown.write(blocks, trailingNewlines: max(1, document.trailingNewlines))
    }

    /// The page without the entry. The last entry is never removed outright:
    /// a scratchpad always has one to write in.
    static func removing(_ id: String, in text: String) -> String? {
        let document = BlockMarkdown.parse(text)
        var blocks = document.blocks
        let all = spans(blocks)
        guard let range = all.first(where: { $0.id == id })?.range else { return nil }
        if all.count == 1 { return Library.entryMarker() + "\n" }
        blocks.removeSubrange(range)
        return BlockMarkdown.write(blocks, trailingNewlines: max(1, document.trailingNewlines))
    }

    /// The page with an empty entry added at the end; returns its id too.
    static func appendingEntry(to text: String, at date: Date = .now) -> (text: String, id: String) {
        let id = uniqueID(in: text, at: date)
        var page = text
        while page.last?.isNewline == true { page.removeLast() }
        let marker = BlockMarkdown.entryPrefix + id + " -->"
        return (page.isEmpty ? marker + "\n" : page + "\n\n" + marker + "\n", id)
    }

    /// A time no other entry has, a second later each time one is taken, so
    /// two entries started in the same second can still be told apart.
    static func uniqueID(in text: String, at date: Date = .now) -> String {
        let taken = Set(spans(BlockMarkdown.parse(text).blocks).map(\.id))
        var date = date
        var id = date.formatted(.iso8601)
        while taken.contains(id) {
            date += 1
            id = date.formatted(.iso8601)
        }
        return id
    }

    // MARK: Pieces

    private struct Span {
        let id: String
        /// From the entry's break up to the next one.
        let range: Range<Int>
    }

    private static func spans(_ blocks: [Block]) -> [Span] {
        let starts = blocks.indices.filter { blocks[$0].kind == .entry }
        return starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1] : blocks.count
            return Span(id: blocks[start].info, range: start..<end)
        }
    }

    /// The entry's name: its first line of text, as the scroll spy shows it.
    static func title(of body: ArraySlice<Block>) -> String {
        for block in body {
            let line = block.plainText.split(separator: "\n").first.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !line.isEmpty { return String(line.prefix(120)) }
            if block.kind == .image { return block.imageAlt.isEmpty ? "Image" : block.imageAlt }
        }
        return ""
    }

    private static func preview(of body: ArraySlice<Block>) -> String {
        let text = body.map(\.plainText).joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(text.prefix(400))
    }
}
