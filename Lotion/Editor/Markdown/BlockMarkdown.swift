//
//  BlockMarkdown.swift
//  Lotion
//
//  Markdown to blocks and back. Parsing covers CommonMark and GFM's block
//  syntax as notes use it: headings, paragraphs, nested lists, task lists,
//  quotes, fenced code, tables, rules and images. Anything else becomes a raw
//  block that keeps its text. Each block remembers the lines it came from, so
//  a note that is opened and saved without edits is written back unchanged.
//

import AppKit

nonisolated enum BlockMarkdown {
    struct Document {
        var blocks: [Block]
        /// Newlines after the last block, so the file's ending is kept.
        var trailingNewlines: Int
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> Document {
        var source = text
        if source.contains("\r") { source = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
        let lines = source.components(separatedBy: "\n")
        var parser = LineParser(lines: lines)
        parser.run()
        let trailing = parser.blocks.isEmpty ? 0 : lines.count - 1 - parser.previousEnd
        return Document(blocks: parser.blocks, trailingNewlines: trailing)
    }

    /// Blocks for pasted Markdown, without the bookkeeping that keeps a file's spacing.
    static func blocks(from markdown: String) -> [Block] {
        parse(markdown).blocks.map { block in
            var block = block
            block.source = nil
            block.gapBefore = nil
            block.sourcePrevious = nil
            return block
        }
    }

    /// A web address with nothing else on its line, which reads as an embed.
    static func isBareWebLink(_ text: String) -> Bool { LineParser.isBareWebLink(text) }

    private struct Line {
        /// Leading whitespace in columns, tabs counted to the next multiple of four.
        let indent: Int
        /// The line after its leading whitespace.
        let content: Substring
        let isBlank: Bool

        init(_ raw: String) {
            var columns = 0
            var index = raw.startIndex
            while index < raw.endIndex {
                let ch = raw[index]
                if ch == " " { columns += 1 } else if ch == "\t" { columns += 4 - columns % 4 } else { break }
                index = raw.index(after: index)
            }
            indent = columns
            content = raw[index...]
            isBlank = content.allSatisfy { $0 == " " || $0 == "\t" }
        }
    }

    private struct ListMarker {
        let isOrdered: Bool
        let number: Int
        let width: Int
        /// Columns from the marker's start to its content.
        let contentOffset: Int
        let rest: Substring
    }

    private struct LineParser {
        let raw: [String]
        let lines: [Line]
        var blocks: [Block] = []
        var i = 0
        var previousEnd = -1
        /// Open list items: the column of each one's marker and content.
        var listStack: [(marker: Int, content: Int)] = []

        init(lines raw: [String]) {
            self.raw = raw
            lines = raw.map(Line.init)
        }

        mutating func add(_ block: Block, from start: Int, to end: Int) {
            var block = block
            block.source = raw[start...end].joined(separator: "\n")
            if let last = blocks.last {
                block.gapBefore = start - previousEnd
                block.sourcePrevious = last.id
            }
            blocks.append(block)
            previousEnd = end
            i = end + 1
        }

        /// The nesting level for a block whose content starts at `column`.
        mutating func level(at column: Int, isListItem: Bool) -> Int {
            var depth = 0
            while depth < listStack.count, listStack[depth].content <= column { depth += 1 }
            if !isListItem, depth == 0 { listStack.removeAll() }
            return depth
        }

        mutating func run() {
            if let end = frontMatterEnd() {
                add(Block(kind: .raw, text: NSAttributedString(string: raw[0...end].joined(separator: "\n"))), from: 0, to: end)
            }
            while i < lines.count {
                let line = lines[i]
                if line.isBlank { i += 1; continue }
                let content = line.content

                if let fence = fenceOpening(content) {
                    parseFence(fence, line: line)
                } else if isThematicBreak(content) {
                    var block = Block(kind: .divider)
                    block.indent = level(at: line.indent, isListItem: false)
                    add(block, from: i, to: i)
                } else if let (level, title) = atxHeading(content) {
                    _ = self.level(at: line.indent, isListItem: false)
                    add(Block(kind: .heading(level), text: InlineMarkdown.parse(title)), from: i, to: i)
                } else if isTableStart(i) {
                    parseTable(line: line)
                } else if content.hasPrefix(">") {
                    parseQuote(line: line)
                } else if let date = entryMarker(content) {
                    var block = Block(kind: .entry)
                    block.info = date
                    add(block, from: i, to: i)
                } else if isHTMLStart(content) || content.hasPrefix("$$") {
                    parseRawUntilBlank(math: content.hasPrefix("$$"), html: isHTMLStart(content))
                } else if isReferenceDefinition(content) {
                    add(Block(kind: .raw, text: NSAttributedString(string: raw[i])), from: i, to: i)
                } else if let image = imageLine(content) {
                    var block = Block(kind: .image)
                    block.imageAlt = image.alt
                    block.imageSource = image.source
                    block.indent = level(at: line.indent, isListItem: false)
                    add(block, from: i, to: i)
                } else if let marker = listMarker(content) {
                    parseListItem(marker, line: line)
                } else {
                    parseParagraph(line: line)
                }
            }
        }

        // MARK: Blocks

        func frontMatterEnd() -> Int? {
            guard raw.first == "---", raw.count > 1 else { return nil }
            for index in 1..<raw.count where raw[index] == "---" || raw[index] == "..." {
                return index
            }
            return nil
        }

        mutating func parseFence(_ fence: (char: Character, length: Int, info: String), line: Line) {
            let start = i
            let strip = line.indent
            var body: [String] = []
            var end = lines.count - 1
            var j = i + 1
            while j < lines.count {
                let candidate = lines[j]
                if candidate.indent <= strip + 3, isFenceClose(candidate.content, char: fence.char, length: fence.length) {
                    end = j
                    break
                }
                body.append(stripColumns(raw[j], strip))
                j += 1
            }
            if j == lines.count { end = lines.count - 1 }
            var block = Block(kind: .code, text: NSAttributedString(string: body.joined(separator: "\n")))
            block.info = fence.info
            block.indent = level(at: line.indent, isListItem: false)
            add(block, from: start, to: max(start, end))
        }

        mutating func parseTable(line: Line) {
            let start = i
            let headerless = isHeaderless(i)
            let delimiterLine = headerless ? i : i + 1
            let header = headerless ? Array(repeating: "", count: Self.cells(lines[i].content).count) : Self.cells(lines[i].content)
            let alignments = Self.cells(lines[delimiterLine].content).map { cell -> ColumnAlignment in
                let left = cell.hasPrefix(":")
                let right = cell.hasSuffix(":")
                return left && right ? .center : left ? .left : right ? .right : .none
            }
            var rows = [header]
            var j = delimiterLine + 1
            while j < lines.count, !lines[j].isBlank, lines[j].content.contains("|") {
                rows.append(Self.cells(lines[j].content))
                j += 1
            }
            var table = TableData(rows: rows.map { $0.map { InlineMarkdown.parse($0) } }, alignments: alignments)
            table.normalize()
            var block = Block(kind: .table)
            block.table = table
            block.indent = level(at: line.indent, isListItem: false)
            add(block, from: start, to: j - 1)
        }

        mutating func parseQuote(line: Line) {
            let start = i
            var inner: [String] = []
            var j = i
            while j < lines.count, !lines[j].isBlank, lines[j].content.hasPrefix(">") {
                var rest = lines[j].content.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                inner.append(String(rest).trimmingTrailingWhitespace())
                j += 1
            }
            var alert: String?
            if let first = inner.first, let type = Self.alertType(first) {
                alert = type
                inner.removeFirst()
            }
            var block = Block(kind: .quote, text: InlineMarkdown.parse(inner.joined(separator: "\n")))
            block.alert = alert
            block.indent = level(at: line.indent, isListItem: false)
            add(block, from: start, to: j - 1)
        }

        mutating func parseRawUntilBlank(math: Bool, html: Bool) {
            let start = i
            var j = i
            if math, lines[i].content.trimmingCharacters(in: .whitespaces) == "$$" || !lines[i].content.dropFirst(2).contains("$$") {
                // Runs to the closing `$$`.
                j = i + 1
                while j < lines.count, !lines[j].content.hasPrefix("$$"), !lines[j].content.hasSuffix("$$") { j += 1 }
                j = min(j, lines.count - 1)
            } else {
                while j + 1 < lines.count, !lines[j + 1].isBlank { j += 1 }
            }
            _ = level(at: lines[start].indent, isListItem: false)
            add(Block(kind: html ? .html : .raw, text: NSAttributedString(string: raw[start...j].joined(separator: "\n"))), from: start, to: j)
        }

        mutating func parseListItem(_ marker: ListMarker, line: Line) {
            let start = i
            let markerColumn = line.indent
            let level = self.level(at: markerColumn, isListItem: true)
            listStack = Array(listStack.prefix(level))
            listStack.append((markerColumn, markerColumn + marker.contentOffset))

            var rest = marker.rest
            var kind: BlockKind = marker.isOrdered ? .numbered : .bullet
            var checked = false
            if !marker.isOrdered, let task = taskPrefix(rest) {
                kind = .todo
                checked = task.checked
                rest = task.rest
            }
            var text = [String(rest).trimmingTrailingWhitespace()]
            var j = i + 1
            while j < lines.count {
                let next = lines[j]
                if next.isBlank || startsBlock(next.content) { break }
                // Indented to the content, or a lazy continuation of the item's text.
                text.append(String(next.content).trimmingTrailingWhitespace())
                j += 1
            }
            var block = Block(kind: kind, text: InlineMarkdown.parse(Self.joinHardBreaks(text)))
            block.indent = level
            block.checked = checked
            if marker.isOrdered, marker.number != 1 {
                let continues = blocks.last.map { $0.kind == .numbered && $0.indent == level } ?? false
                if !continues { block.start = marker.number }
            }
            add(block, from: start, to: j - 1)
        }

        mutating func parseParagraph(line: Line) {
            let start = i
            var text = [String(line.content).trimmingTrailingWhitespace()]
            var j = i + 1
            var heading: Int?
            while j < lines.count {
                let next = lines[j]
                if next.isBlank { break }
                if next.indent < 4, let level = setextLevel(next.content) {
                    heading = level
                    break
                }
                if startsBlock(next.content) || isTableStart(j) { break }
                text.append(String(next.content).trimmingTrailingWhitespace())
                j += 1
            }
            if let heading {
                _ = level(at: line.indent, isListItem: false)
                add(Block(kind: .heading(heading), text: InlineMarkdown.parse(text.joined(separator: " "))), from: start, to: j)
                return
            }
            // Lines of nothing but images (README badges, often linked) show as images.
            if text.allSatisfy(Self.isImageRow) {
                var block = Block(kind: .html, text: NSAttributedString(string: raw[start..<j].joined(separator: "\n")))
                block.indent = level(at: line.indent, isListItem: false)
                add(block, from: start, to: j - 1)
                return
            }
            if text.count == 1, let embed = Self.embedLine(text[0]) {
                var block = embed
                block.indent = level(at: line.indent, isListItem: false)
                add(block, from: start, to: j - 1)
                return
            }
            if text.count == 1, MediaKind.isEmbeddable(text[0]) {
                var block = Block(kind: .image)
                block.imageSource = text[0]
                block.isBareLink = true
                block.indent = level(at: line.indent, isListItem: false)
                add(block, from: start, to: j - 1)
                return
            }
            var block = Block(kind: .paragraph, text: InlineMarkdown.parse(Self.joinHardBreaks(text)))
            block.indent = level(at: line.indent, isListItem: false)
            add(block, from: start, to: j - 1)
        }

        static let alertTypes = ["NOTE", "TIP", "IMPORTANT", "WARNING", "CAUTION"]

        static let tocMarkers: Set<String> = ["[toc]", "[[toc]]", "[[_toc_]]", "${toc}"]

        /// A line that stands for a rich block: a table of contents, another
        /// note, a file, or a link alone on its line.
        static func embedLine(_ line: String) -> Block? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if tocMarkers.contains(trimmed.lowercased()) {
                var block = Block(kind: .embed)
                block.info = "toc"
                return block
            }
            if trimmed.hasPrefix("![["), trimmed.hasSuffix("]]"), trimmed.count > 5 {
                let name = String(trimmed.dropFirst(3).dropLast(2))
                guard !name.contains("]"), !name.contains("[") else { return nil }
                var block = Block(kind: .embed)
                block.info = "note"
                block.imageSource = name
                return block
            }
            if isBareWebLink(trimmed), !MediaKind.isEmbeddable(trimmed) {
                var block = Block(kind: .embed)
                block.imageSource = trimmed
                return block
            }
            // `[report.zip](report.zip)`: a link to a file beside the note.
            if trimmed.hasPrefix("["), trimmed.hasSuffix(")"), let middle = trimmed.range(of: "]("),
               !trimmed[trimmed.index(after: trimmed.startIndex)..<middle.lowerBound].contains("]") {
                var target = String(trimmed[middle.upperBound...].dropLast())
                if target.hasPrefix("<"), target.hasSuffix(">") { target = String(target.dropFirst().dropLast()) }
                let ext = (target as NSString).pathExtension.lowercased()
                guard !target.isEmpty, !target.contains("://"), !target.hasPrefix("#"), !target.hasPrefix("mailto:"),
                      !ext.isEmpty, !["md", "markdown", "html", "htm"].contains(ext), !target.contains(")") else { return nil }
                var block = Block(kind: .embed)
                block.info = "file"
                block.imageAlt = String(trimmed[trimmed.index(after: trimmed.startIndex)..<middle.lowerBound])
                block.imageSource = target
                return block
            }
            return nil
        }

        static func isBareWebLink(_ text: String) -> Bool {
            guard text.hasPrefix("https://") || text.hasPrefix("http://"), text.count > 10,
                  !text.contains(" "), !text.contains("<"), !text.contains(">"),
                  let url = URL(string: text), let host = url.host, host.contains(".") else { return false }
            return true
        }

        /// `[!NOTE]` and friends, the first line of a GitHub alert.
        static func alertType(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[!"), trimmed.hasSuffix("]") else { return nil }
            let type = trimmed.dropFirst(2).dropLast().uppercased()
            return alertTypes.contains(type) ? type : nil
        }

        static let imageRow = try! NSRegularExpression(
            pattern: #"^\s*(?:(?:\[!\[[^\]]*\]\([^)\s]+(?:\s+"[^"]*")?\)\]\([^)\s]+\)|!\[[^\]]*\]\([^)\s]+(?:\s+"[^"]*")?\))\s*)+$"#)

        /// A line holding only images, each maybe wrapped in a link.
        static func isImageRow(_ line: String) -> Bool {
            imageRow.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) != nil
        }

        static func joinHardBreaks(_ lines: [String]) -> String {
            lines.map { line in
                line.hasSuffix("\\") && !line.hasSuffix("\\\\") ? String(line.dropLast()) : line
            }.joined(separator: "\n")
        }

        // MARK: Line tests

        /// Whether a line interrupts a paragraph or list item's text.
        func startsBlock(_ content: Substring) -> Bool {
            fenceOpening(content) != nil || isThematicBreak(content) || atxHeading(content) != nil
                || content.hasPrefix(">") || listMarker(content) != nil || isHTMLStart(content)
        }

        func fenceOpening(_ content: Substring) -> (char: Character, length: Int, info: String)? {
            guard let first = content.first, first == "`" || first == "~" else { return nil }
            let run = content.prefix { $0 == first }.count
            guard run >= 3 else { return nil }
            let info = content.dropFirst(run).trimmingCharacters(in: .whitespaces)
            if first == "`", info.contains("`") { return nil }
            return (first, run, info)
        }

        func isFenceClose(_ content: Substring, char: Character, length: Int) -> Bool {
            let run = content.prefix { $0 == char }.count
            return run >= length && content.dropFirst(run).allSatisfy { $0 == " " || $0 == "\t" }
        }

        func isThematicBreak(_ content: Substring) -> Bool {
            guard let first = content.first, first == "-" || first == "*" || first == "_" else { return false }
            var count = 0
            for ch in content {
                if ch == first { count += 1 } else if ch != " " && ch != "\t" { return false }
            }
            return count >= 3
        }

        func atxHeading(_ content: Substring) -> (Int, String)? {
            guard content.hasPrefix("#") else { return nil }
            let level = content.prefix { $0 == "#" }.count
            guard level <= 6 else { return nil }
            let rest = content.dropFirst(level)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            var title = rest.trimmingCharacters(in: .whitespaces)
            // An optional closing run of `#`.
            if let lastSpace = title.lastIndex(of: " "), title[title.index(after: lastSpace)...].allSatisfy({ $0 == "#" }) {
                title = String(title[..<lastSpace]).trimmingCharacters(in: .whitespaces)
            } else if title.allSatisfy({ $0 == "#" }) {
                title = ""
            }
            return (level, title)
        }

        func setextLevel(_ content: Substring) -> Int? {
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first, first == "=" || first == "-", trimmed.allSatisfy({ $0 == first }) else { return nil }
            return first == "=" ? 1 : 2
        }

        func listMarker(_ content: Substring) -> ListMarker? {
            guard let first = content.first else { return nil }
            var width = 0
            var number = 0
            var isOrdered = false
            if first == "-" || first == "*" || first == "+" {
                width = 1
            } else if first.isASCII, first.isNumber {
                let digits = content.prefix { $0.isASCII && $0.isNumber }
                guard digits.count <= 9 else { return nil }
                let after = content.dropFirst(digits.count).first
                guard after == "." || after == ")" else { return nil }
                width = digits.count + 1
                number = Int(digits) ?? 1
                isOrdered = true
            } else {
                return nil
            }
            let afterMarker = content.dropFirst(width)
            if afterMarker.isEmpty {
                return ListMarker(isOrdered: isOrdered, number: number, width: width, contentOffset: width + 1, rest: "")
            }
            guard afterMarker.first == " " || afterMarker.first == "\t" else { return nil }
            let spaces = afterMarker.prefix { $0 == " " }.count
            let offset = spaces >= 5 ? width + 1 : width + max(1, spaces)
            return ListMarker(isOrdered: isOrdered, number: number, width: width, contentOffset: offset,
                              rest: afterMarker.drop { $0 == " " || $0 == "\t" })
        }

        func taskPrefix(_ rest: Substring) -> (checked: Bool, rest: Substring)? {
            guard rest.count >= 3, rest.hasPrefix("["), rest.dropFirst(2).first == "]" else { return nil }
            let mark = rest.dropFirst().first
            guard mark == " " || mark == "x" || mark == "X" else { return nil }
            let after = rest.dropFirst(3)
            guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
            return (mark != " ", after.drop { $0 == " " || $0 == "\t" })
        }

        func isTableStart(_ index: Int) -> Bool {
            guard index + 1 < lines.count, lines[index].content.contains("|") else { return false }
            if isDelimiterRow(lines[index + 1].content) {
                return Self.cells(lines[index].content).count == Self.cells(lines[index + 1].content).count
            }
            // No header row: not GFM, but plainly meant as a table.
            return isHeaderless(index)
        }

        /// A table that starts at its `| --- |` line, with rows under it.
        func isHeaderless(_ index: Int) -> Bool {
            guard isDelimiterRow(lines[index].content), index + 1 < lines.count, lines[index + 1].content.contains("|"),
                  !isDelimiterRow(lines[index + 1].content) else { return false }
            return Self.cells(lines[index].content).count >= 1
        }

        func isDelimiterRow(_ content: Substring) -> Bool {
            guard content.contains("-"), content.contains("|") || content.contains(":"),
                  content.allSatisfy({ "|:- \t".contains($0) }) else { return false }
            let columns = Self.cells(content)
            return !columns.isEmpty && columns.allSatisfy { $0.contains("-") }
        }

        /// `<!-- entry 2026-11-06T11:02:00Z -->`: a scratchpad entry starts here.
        func entryMarker(_ content: Substring) -> String? {
            let line = content.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix(BlockMarkdown.entryPrefix), line.hasSuffix(" -->") else { return nil }
            let date = line.dropFirst(BlockMarkdown.entryPrefix.count).dropLast(4).trimmingCharacters(in: .whitespaces)
            return date.contains(" ") ? nil : date
        }

        func isHTMLStart(_ content: Substring) -> Bool {
            guard content.hasPrefix("<") else { return false }
            if content.hasPrefix("<!--") { return true }
            var rest = content.dropFirst()
            if rest.hasPrefix("/") { rest = rest.dropFirst() }
            let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" }
            guard let firstName = name.first, firstName.isLetter else { return false }
            let after = rest.dropFirst(name.count).first
            return after == nil || after == " " || after == ">" || after == "/"
        }

        func isReferenceDefinition(_ content: Substring) -> Bool {
            guard content.hasPrefix("["), let close = content.firstIndex(of: "]") else { return false }
            let after = content[content.index(after: close)...]
            return after.hasPrefix(":") && after.dropFirst().trimmingCharacters(in: .whitespaces).count > 0
        }

        func imageLine(_ content: Substring) -> (alt: String, source: String)? {
            guard content.hasPrefix("!["), let closeAlt = content.range(of: "](") else { return nil }
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasSuffix(")") else { return nil }
            let alt = String(content[content.index(content.startIndex, offsetBy: 2)..<closeAlt.lowerBound])
            guard !alt.contains("]") else { return nil }
            var target = String(trimmed[closeAlt.upperBound...].dropLast())
            if target.hasPrefix("<"), let end = target.firstIndex(of: ">") {
                target = String(target[target.index(after: target.startIndex)..<end])
            } else if let space = target.firstIndex(of: " ") {
                target = String(target[..<space])
            }
            guard !target.isEmpty, !target.contains(")") || target.contains("(") else { return nil }
            return (alt, target)
        }

        func stripColumns(_ line: String, _ columns: Int) -> String {
            var removed = 0
            var index = line.startIndex
            while removed < columns, index < line.endIndex, line[index] == " " {
                removed += 1
                index = line.index(after: index)
            }
            return String(line[index...])
        }

        /// A table row's cells, split on pipes that are not escaped or in code.
        static func cells(_ content: Substring) -> [String] {
            var row = content.trimmingCharacters(in: .whitespaces)
            if row.hasPrefix("|") { row.removeFirst() }
            if row.hasSuffix("|") && !row.hasSuffix("\\|") { row.removeLast() }
            var cells: [String] = []
            var current = ""
            var inCode = false
            var escaped = false
            for ch in row {
                if escaped {
                    // GFM unescapes pipes before inline parsing, in code too.
                    if ch == "|" { current.removeLast() }
                    current.append(ch)
                    escaped = false
                    continue
                }
                if ch == "\\" { current.append(ch); escaped = true; continue }
                if ch == "`" { inCode.toggle() }
                if ch == "|" && !inCode {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                    continue
                }
                current.append(ch)
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
    }

    // MARK: - Writing

    /// The number shown for each numbered item, nil for every other block.
    static func listNumbers(_ blocks: [Block]) -> [Int?] {
        var numbers: [Int?] = Array(repeating: nil, count: blocks.count)
        // The last number used at each depth, nil where a bullet broke the run.
        var counters: [Int?] = []
        for (index, block) in blocks.enumerated() {
            let level = block.indent
            if block.kind.isList {
                if counters.count > level + 1 { counters.removeLast(counters.count - level - 1) }
                while counters.count < level + 1 { counters.append(nil) }
                if block.kind == .numbered {
                    let number = counters[level].map { $0 + 1 } ?? block.start ?? 1
                    numbers[index] = number
                    counters[level] = number
                } else {
                    counters[level] = nil
                }
            } else if level == 0 {
                counters.removeAll()
            } else if counters.count > level {
                counters.removeLast(counters.count - level)
            }
        }
        return numbers
    }

    static let entryPrefix = "<!-- entry "

    static func write(_ blocks: [Block], trailingNewlines: Int) -> String {
        var out = ""
        let numbers = listNumbers(blocks)
        // The content column of the last list item at each depth.
        var columns: [Int] = []
        for (index, block) in blocks.enumerated() {
            let previous = index > 0 ? blocks[index - 1] : nil
            let level = min(block.indent, columns.count)
            let prefix = level > 0 ? String(repeating: " ", count: columns[level - 1]) : ""
            let marker = listMarker(block, number: numbers[index])
            if block.kind.isList {
                columns = Array(columns.prefix(level)) + [prefix.count + marker.count]
            } else {
                columns = Array(columns.prefix(level))
            }

            if let previous {
                let minimum = minimumGap(previous, block)
                if block.sourcePrevious == previous.id, let gap = block.gapBefore {
                    out += String(repeating: "\n", count: max(gap, minimum))
                } else {
                    out += String(repeating: "\n", count: max(canonicalGap(previous, block), minimum))
                }
            }
            let isVerbatim = block.source != nil
                && (index == 0 ? block.sourcePrevious == nil : block.sourcePrevious == previous?.id)
            if isVerbatim, let source = block.source {
                out += source
            } else {
                out += markdown(for: block, prefix: prefix, marker: marker)
            }
        }
        out += String(repeating: "\n", count: trailingNewlines)
        return out
    }

    private static func listMarker(_ block: Block, number: Int?) -> String {
        switch block.kind {
        case .bullet: "- "
        case .todo: block.checked ? "- [x] " : "- [ ] "
        case .numbered: "\(number ?? 1). "
        default: ""
        }
    }

    private static func canonicalGap(_ previous: Block, _ block: Block) -> Int {
        if previous.kind.isList && (block.kind.isList || block.indent > 0) { return 1 }
        if previous.indent > 0 && block.indent > 0 { return block.kind.isList || previous.kind.isList ? 1 : 2 }
        return 2
    }

    /// Fewer newlines than this would merge the two blocks in Markdown.
    private static func minimumGap(_ previous: Block, _ block: Block) -> Int {
        // HTML runs to a blank line; front matter ends at its own fence.
        if previous.kind == .html { return 2 }
        if previous.kind == .raw { return previous.text.string.hasPrefix("---\n") ? 1 : 2 }
        switch block.kind {
        case .heading, .code, .bullet, .numbered, .todo:
            return 1
        case .divider:
            // `---` under a paragraph line would underline it into a heading.
            return previous.kind == .paragraph ? 2 : 1
        case .quote:
            return previous.kind == .quote ? 2 : 1
        default:
            let absorbs: Set<BlockKind> = [.paragraph, .table, .quote, .bullet, .numbered, .todo, .html]
            return absorbs.contains(previous.kind) ? 2 : 1
        }
    }

    /// One block as Markdown, every line after the first indented by `prefix`.
    static func markdown(for block: Block, prefix: String = "", marker: String? = nil) -> String {
        let marker = marker ?? listMarker(block, number: block.start)
        func indented(_ text: String, continuation: String) -> String {
            text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
                index == 0 ? String(line) : (line.isEmpty ? "" : continuation + line)
            }.joined(separator: "\n")
        }
        switch block.kind {
        case .paragraph:
            var text = InlineMarkdown.write(block.text)
            // A link alone on its line would read back as a card; brackets keep it a link.
            if LineParser.isBareWebLink(text) { text = "<\(text)>" }
            return prefix + indented(text, continuation: prefix)
        case .heading(let level):
            let title = InlineMarkdown.write(block.text).replacingOccurrences(of: "\n", with: " ")
            return String(repeating: "#", count: level) + (title.isEmpty ? " " : " " + title)
        case .bullet, .numbered, .todo:
            let text = InlineMarkdown.write(block.text)
            let line = prefix + marker + indented(text, continuation: prefix + String(repeating: " ", count: marker.count))
            return text.isEmpty ? line.trimmingTrailingWhitespace() : line
        case .quote:
            let text = InlineMarkdown.write(block.text)
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            if let alert = block.alert { lines.insert("[!\(alert)]", at: 0) }
            return lines
                .map { $0.isEmpty ? prefix + ">" : prefix + "> " + $0 }
                .joined(separator: "\n")
        case .code:
            let code = block.text.string
            var longest = 0
            for line in code.split(separator: "\n", omittingEmptySubsequences: false) {
                let trimmed = line.drop { $0 == " " }
                longest = max(longest, trimmed.prefix { $0 == "`" }.count)
            }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let body = code.isEmpty ? [] : code.split(separator: "\n", omittingEmptySubsequences: false).map {
                $0.isEmpty ? String($0) : prefix + $0
            }
            return ([prefix + fence + block.info] + body + [prefix + fence]).joined(separator: "\n")
        case .divider:
            return prefix + "---"
        case .image where block.isBareLink:
            return prefix + block.imageSource
        case .image:
            let source = block.imageSource.contains(" ") ? "<\(block.imageSource)>" : block.imageSource
            return prefix + "![\(block.imageAlt.replacingOccurrences(of: "]", with: "\\]"))](\(source))"
        case .table:
            return table(block.table ?? .empty(), prefix: prefix)
        case .raw, .html:
            return block.text.string
        case .entry:
            return entryPrefix + block.info + " -->"
        case .embed:
            switch block.info {
            case "toc": return prefix + "[TOC]"
            case "note": return prefix + "![[\(block.imageSource)]]"
            case "file":
                let target = block.imageSource.contains(" ") ? "<\(block.imageSource)>" : block.imageSource
                return prefix + "[\(block.imageAlt.replacingOccurrences(of: "]", with: "\\]"))](\(target))"
            default: return prefix + block.imageSource
            }
        }
    }

    private static func table(_ table: TableData, prefix: String) -> String {
        let cells = table.rows.map { row in
            row.map { cell in
                InlineMarkdown.write(cell)
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "|", with: "\\|")
            }
        }
        let count = table.columnCount
        var widths = Array(repeating: 3, count: count)
        for row in cells {
            for (column, cell) in row.enumerated() where column < count {
                widths[column] = max(widths[column], cell.count)
            }
        }
        func line(_ row: [String]) -> String {
            prefix + "| " + (0..<count).map { column in
                let cell = column < row.count ? row[column] : ""
                return cell + String(repeating: " ", count: max(0, widths[column] - cell.count))
            }.joined(separator: " | ") + " |"
        }
        let delimiter = prefix + "| " + (0..<count).map { column in
            let width = widths[column]
            switch table.alignments[column] {
            case .none: return String(repeating: "-", count: width)
            case .left: return ":" + String(repeating: "-", count: width - 1)
            case .right: return String(repeating: "-", count: width - 1) + ":"
            case .center: return ":" + String(repeating: "-", count: width - 2) + ":"
            }
        }.joined(separator: " | ") + " |"
        var lines = [line(cells.first ?? []), delimiter]
        for row in cells.dropFirst() { lines.append(line(row)) }
        return lines.joined(separator: "\n")
    }
}

extension String {
    nonisolated func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let previous = index(before: end)
            guard self[previous] == " " || self[previous] == "\t" else { break }
            end = previous
        }
        return String(self[..<end])
    }
}
