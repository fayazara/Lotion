//
//  MarkdownScanner.swift
//  Lotion
//
//  A line-based Markdown block scanner, just enough for styling: headings,
//  fenced code, quotes, list items and tasks, rules, tables and paragraphs.
//  It works on UTF-16 so every range drops straight into an NSTextStorage,
//  and a 100 KB note scans in about a millisecond.
//

import Foundation

struct MarkdownBlock {
    enum Kind {
        case blank
        case paragraph
        /// `marker` covers the `#`s and the space after them.
        case heading(level: Int, marker: NSRange)
        /// One marker (`> `) per line.
        case quote(markers: [NSRange])
        /// `marker` is the bullet or number; `content` starts after it (and
        /// after the task box, when there is one).
        case listItem(indent: NSRange, marker: NSRange, ordered: Bool, task: NSRange?, checked: Bool, content: Int)
        case rule
        /// `content` spans the lines between the fences.
        case code(language: String?, openFence: NSRange, closeFence: NSRange?, content: NSRange)
        case table(separator: NSRange)
    }

    var kind: Kind
    /// Whole lines, including the final line break.
    var range: NSRange
}

enum MarkdownScanner {
    private struct Line {
        let start: Int
        /// Excludes the line break.
        let end: Int
        /// Where the next line starts.
        let next: Int
        var range: NSRange { NSRange(location: start, length: end - start) }
    }

    private static let space: unichar = 32, tab: unichar = 9, newline: unichar = 10, carriageReturn: unichar = 13
    private static let hash: unichar = 35, gt: unichar = 62, backtick: unichar = 96, tilde: unichar = 126
    private static let dash: unichar = 45, star: unichar = 42, plus: unichar = 43, underscore: unichar = 95
    private static let pipe: unichar = 124, colon: unichar = 58, dot: unichar = 46, paren: unichar = 41
    private static let openBracket: unichar = 91, closeBracket: unichar = 93

    /// The blocks of `text`, in order, and how many fence lines it has.
    static func scan(_ text: NSString) -> (blocks: [MarkdownBlock], fenceLines: Int) {
        let length = text.length
        guard length > 0 else { return ([], 0) }
        var chars = [unichar](repeating: 0, count: length)
        text.getCharacters(&chars, range: NSRange(location: 0, length: length))

        var lines: [Line] = []
        lines.reserveCapacity(length / 32)
        var start = 0
        while start < length {
            var end = start
            while end < length && chars[end] != newline { end += 1 }
            let next = min(end + 1, length)
            let contentEnd = end > start && chars[end - 1] == carriageReturn ? end - 1 : end
            lines.append(Line(start: start, end: contentEnd, next: end < length ? next : length))
            start = end + 1
        }

        var blocks: [MarkdownBlock] = []
        blocks.reserveCapacity(lines.count)
        var fenceLines = 0
        var i = 0

        func indent(_ line: Line) -> Int {
            var p = line.start
            while p < line.end && chars[p] == space { p += 1 }
            return p - line.start
        }

        while i < lines.count {
            let line = lines[i]
            let lead = indent(line)
            let p = line.start + lead

            // Fenced code.
            if lead <= 3, let fence = fenceOpening(chars, at: p, end: line.end) {
                var close: Int?
                var j = i + 1
                while j < lines.count {
                    if isFenceClose(chars, lines[j], fence: fence.char, count: fence.count) { close = j; break }
                    j += 1
                }
                let last = close ?? lines.count - 1
                let contentStart = line.next
                let contentEnd = close.map { lines[$0].start } ?? lines[last].next
                blocks.append(MarkdownBlock(
                    kind: .code(
                        language: fence.language,
                        openFence: line.range,
                        closeFence: close.map { lines[$0].range },
                        content: NSRange(location: contentStart, length: max(0, contentEnd - contentStart))
                    ),
                    range: NSRange(location: line.start, length: lines[last].next - line.start)
                ))
                fenceLines += close == nil ? 1 : 2
                i = last + 1
                continue
            }

            let full = NSRange(location: line.start, length: line.next - line.start)

            if p >= line.end || isBlank(chars, from: p, to: line.end) {
                blocks.append(MarkdownBlock(kind: .blank, range: full))
                i += 1
                continue
            }

            if lead <= 3, chars[p] == hash {
                var q = p
                while q < line.end && chars[q] == hash { q += 1 }
                let level = q - p
                if level <= 6 && (q == line.end || chars[q] == space || chars[q] == tab) {
                    while q < line.end && (chars[q] == space || chars[q] == tab) { q += 1 }
                    blocks.append(MarkdownBlock(kind: .heading(level: level, marker: NSRange(location: line.start, length: q - line.start)), range: full))
                    i += 1
                    continue
                }
            }

            if lead <= 3, isRule(chars, from: p, to: line.end) {
                blocks.append(MarkdownBlock(kind: .rule, range: full))
                i += 1
                continue
            }

            if lead <= 3, chars[p] == gt {
                var markers: [NSRange] = []
                var j = i
                var end = line.next
                while j < lines.count {
                    let quoteLine = lines[j]
                    let quoteLead = indent(quoteLine)
                    var q = quoteLine.start + quoteLead
                    guard quoteLead <= 3, q < quoteLine.end, chars[q] == gt else { break }
                    while q < quoteLine.end && (chars[q] == gt || chars[q] == space) { q += 1 }
                    markers.append(NSRange(location: quoteLine.start, length: q - quoteLine.start))
                    end = quoteLine.next
                    j += 1
                }
                blocks.append(MarkdownBlock(kind: .quote(markers: markers), range: NSRange(location: line.start, length: end - line.start)))
                i = j
                continue
            }

            if let item = listItem(chars, line: line) {
                blocks.append(MarkdownBlock(kind: item, range: full))
                i += 1
                continue
            }

            // A table: a row with pipes over a separator row.
            if i + 1 < lines.count, contains(chars, pipe, in: line), isTableSeparator(chars, lines[i + 1]) {
                var j = i + 2
                while j < lines.count, contains(chars, pipe, in: lines[j]), !isBlank(chars, from: lines[j].start, to: lines[j].end) { j += 1 }
                let end = lines[j - 1].next
                blocks.append(MarkdownBlock(kind: .table(separator: lines[i + 1].range), range: NSRange(location: line.start, length: end - line.start)))
                i = j
                continue
            }

            blocks.append(MarkdownBlock(kind: .paragraph, range: full))
            i += 1
        }
        return (blocks, fenceLines)
    }

    // MARK: Pieces

    private static func fenceOpening(_ c: [unichar], at p: Int, end: Int) -> (char: unichar, count: Int, language: String?)? {
        guard p < end, c[p] == backtick || c[p] == tilde else { return nil }
        let fenceChar = c[p]
        var q = p
        while q < end && c[q] == fenceChar { q += 1 }
        let count = q - p
        guard count >= 3 else { return nil }
        if fenceChar == backtick && c[q..<end].contains(backtick) { return nil }
        while q < end && (c[q] == space || c[q] == tab) { q += 1 }
        var e = q
        while e < end && c[e] != space && c[e] != tab && c[e] != 123 /* { */ { e += 1 }
        let language = e > q ? String(utf16CodeUnits: Array(c[q..<e]), count: e - q).lowercased() : nil
        return (fenceChar, count, language)
    }

    private static func isFenceClose(_ c: [unichar], _ line: Line, fence: unichar, count: Int) -> Bool {
        var p = line.start
        while p < line.end && c[p] == space { p += 1 }
        guard p - line.start <= 3 else { return false }
        var q = p
        while q < line.end && c[q] == fence { q += 1 }
        guard q - p >= count else { return false }
        return isBlank(c, from: q, to: line.end)
    }

    private static func isBlank(_ c: [unichar], from: Int, to: Int) -> Bool {
        var p = from
        while p < to {
            if c[p] != space && c[p] != tab { return false }
            p += 1
        }
        return true
    }

    private static func isRule(_ c: [unichar], from: Int, to: Int) -> Bool {
        let mark = c[from]
        guard mark == dash || mark == star || mark == underscore else { return false }
        var count = 0
        for p in from..<to {
            if c[p] == mark { count += 1 } else if c[p] != space && c[p] != tab { return false }
        }
        return count >= 3
    }

    private static func listItem(_ c: [unichar], line: Line) -> MarkdownBlock.Kind? {
        var p = line.start
        while p < line.end && (c[p] == space || c[p] == tab) { p += 1 }
        let indent = NSRange(location: line.start, length: p - line.start)
        guard p < line.end else { return nil }
        let markerStart = p
        var ordered = false
        if c[p] == dash || c[p] == star || c[p] == plus {
            p += 1
        } else {
            var q = p
            while q < line.end && q - p < 9 && c[q] >= 48 && c[q] <= 57 { q += 1 }
            guard q > p, q < line.end, c[q] == dot || c[q] == paren else { return nil }
            p = q + 1
            ordered = true
        }
        // A marker must be followed by a space (or end an otherwise empty item).
        guard p == line.end || c[p] == space || c[p] == tab else { return nil }
        let marker = NSRange(location: markerStart, length: p - markerStart)
        while p < line.end && (c[p] == space || c[p] == tab) { p += 1 }

        var task: NSRange?
        var checked = false
        if p + 2 < line.end,
           c[p] == openBracket, c[p + 2] == closeBracket,
           c[p + 1] == space || c[p + 1] == 120 || c[p + 1] == 88,
           p + 3 == line.end || c[p + 3] == space || c[p + 3] == tab {
            task = NSRange(location: p, length: 3)
            checked = c[p + 1] != space
            p += 3
            while p < line.end && (c[p] == space || c[p] == tab) { p += 1 }
        }
        return .listItem(indent: indent, marker: marker, ordered: ordered, task: task, checked: checked, content: p)
    }

    private static func contains(_ c: [unichar], _ char: unichar, in line: Line) -> Bool {
        c[line.start..<line.end].contains(char)
    }

    private static func isTableSeparator(_ c: [unichar], _ line: Line) -> Bool {
        var dashes = 0, pipes = 0
        for p in line.start..<line.end {
            switch c[p] {
            case dash: dashes += 1
            case pipe: pipes += 1
            case colon, space, tab: break
            default: return false
            }
        }
        return dashes >= 3 && pipes >= 1
    }
}
