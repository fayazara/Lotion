//
//  MarkdownTable.swift
//  Lotion
//
//  Pipe tables as rows of cells: where each cell's text sits in a line (for
//  styling and moving the caret), and a model for edits that restructure
//  the table (adding, moving, deleting rows and columns), written back as
//  tidy Markdown. Escaped pipes (`\|`) stay inside their cell.
//

import AppKit

struct MarkdownTable: Equatable {
    enum Alignment: Equatable { case none, left, center, right }

    /// The header first; the separator row isn't one of them.
    var rows: [[String]]
    var alignments: [Alignment]

    var columnCount: Int { max(alignments.count, rows.map(\.count).max() ?? 0) }

    // MARK: Reading

    /// The cells' text in a row, trimmed; empty cells are empty strings.
    static func cells(_ line: String) -> [String] {
        let ns = line as NSString
        return cellRanges(in: ns, line: NSRange(location: 0, length: ns.length)).map { range in
            ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        }
    }

    /// Each cell's text in `line` (no line break), trimmed of spaces. An
    /// empty cell is the empty range just after its pipe.
    static func cellRanges(in text: NSString, line: NSRange) -> [NSRange] {
        let pipes = pipePositions(in: text, line: line)
        var bounds: [(Int, Int)] = []
        var start = line.location
        for pipe in pipes {
            if pipe == pipes.first, isBlank(text, from: line.location, to: pipe) {
                start = pipe + 1
                continue
            }
            bounds.append((start, pipe))
            start = pipe + 1
        }
        if !isBlank(text, from: start, to: NSMaxRange(line)) { bounds.append((start, NSMaxRange(line))) }
        return bounds.map { from, to in
            var a = from, b = to
            while a < b, isSpace(text.character(at: a)) { a += 1 }
            while b > a, isSpace(text.character(at: b - 1)) { b -= 1 }
            return a == b ? NSRange(location: from, length: 0) : NSRange(location: a, length: b - a)
        }
    }

    /// Unescaped pipes in `line`.
    static func pipePositions(in text: NSString, line: NSRange) -> [Int] {
        var pipes: [Int] = []
        var index = line.location
        while index < NSMaxRange(line) {
            let c = text.character(at: index)
            if c == 92 { index += 2; continue } // backslash escapes the next character
            if c == 124 { pipes.append(index) }
            index += 1
        }
        return pipes
    }

    /// Pipes escaped with a backslash, which belong to their cell's text.
    static func escapedPipes(in text: NSString, line: NSRange) -> [Int] {
        var pipes: [Int] = []
        var index = line.location
        while index + 1 < NSMaxRange(line) {
            if text.character(at: index) == 92 {
                if text.character(at: index + 1) == 124 { pipes.append(index + 1) }
                index += 2
                continue
            }
            index += 1
        }
        return pipes
    }

    /// A cell's Markdown as typed: `\|` reads as `|`.
    static func unescaped(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "\\|", with: "|")
    }

    /// Typed cell text as Markdown: a pipe stays in its cell.
    static func escaped(_ text: String) -> String {
        unescaped(text).replacingOccurrences(of: "|", with: "\\|")
    }

    /// Where `offset` into a cell's Markdown falls in its unescaped text.
    static func unescapedIndex(_ markdown: NSString, offset: Int) -> Int {
        let escapes = escapedPipes(in: markdown, line: NSRange(location: 0, length: markdown.length))
        return offset - escapes.filter { $0 - 1 < offset }.count
    }

    static func alignments(_ separator: String) -> [Alignment] {
        cells(separator).map { cell in
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            switch (left, right) {
            case (true, true): return .center
            case (false, true): return .right
            case (true, false): return .left
            default: return .none
            }
        }
    }

    /// The table in `text`'s lines: a header, a separator, then body rows.
    init(_ text: String) {
        var lines = text.components(separatedBy: "\n")
        if lines.last?.isEmpty == true { lines.removeLast() }
        alignments = lines.count > 1 ? Self.alignments(lines[1]) : []
        rows = lines.enumerated().filter { $0.offset != 1 }.map { Self.cells($0.element) }
        normalize()
    }

    init(rows: [[String]], alignments: [Alignment]) {
        self.rows = rows
        self.alignments = alignments
        normalize()
    }

    /// Every row as wide as the widest.
    private mutating func normalize() {
        let count = max(1, columnCount)
        rows = rows.map { $0 + Array(repeating: "", count: max(0, count - $0.count)) }
        alignments += Array(repeating: .none, count: max(0, count - alignments.count))
    }

    // MARK: Writing

    /// Markdown for the table, and where each cell's text starts in it.
    func markdown() -> (text: String, cellStarts: [[Int]]) {
        var text = ""
        var starts: [[Int]] = []
        func row(_ cells: [String]) {
            var rowStarts: [Int] = []
            text += "|"
            for cell in cells {
                text += " "
                rowStarts.append(text.utf16.count)
                text += cell + " |"
            }
            text += "\n"
            starts.append(rowStarts)
        }
        for (index, cells) in rows.enumerated() {
            row(cells)
            if index == 0 {
                let marks = alignments.map { alignment -> String in
                    switch alignment {
                    case .none: "---"
                    case .left: ":---"
                    case .center: ":---:"
                    case .right: "---:"
                    }
                }
                text += "| " + marks.joined(separator: " | ") + " |\n"
            }
        }
        return (text, starts)
    }

    /// Comma- or tab-separated values, quoted where needed.
    func delimited(by separator: String) -> String {
        rows.map { row in
            row.map { cell in
                let plain = cell.replacingOccurrences(of: "\\|", with: "|")
                guard plain.contains(separator) || plain.contains("\"") || plain.contains("\n") else { return plain }
                return "\"" + plain.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            }.joined(separator: separator)
        }.joined(separator: "\n") + "\n"
    }

    // MARK: Pieces

    private static func isSpace(_ c: unichar) -> Bool { c == 32 || c == 9 }

    private static func isBlank(_ text: NSString, from: Int, to: Int) -> Bool {
        var index = from
        while index < to {
            if !isSpace(text.character(at: index)) { return false }
            index += 1
        }
        return true
    }
}
