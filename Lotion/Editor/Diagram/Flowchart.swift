//
//  Flowchart.swift
//  Lotion
//
//  A Mermaid flowchart, read from the text of a ```mermaid fence. Lotion draws
//  flowcharts itself rather than running Mermaid: nodes are cards with an
//  icon, a title and a line of detail, and edges are right-angled wires
//  between ports. The fence stays standard Mermaid, so the note still
//  renders on GitHub and in Obsidian.
//
//  What is read: `flowchart`/`graph` with a direction; every node shape;
//  `A@{ shape, label, icon }`; edges of every kind with labels, chains
//  (`A --> B --> C`) and `&`; `subgraph … end`; `classDef`, `class`, `:::`,
//  `style` and `linkStyle` for colors. Interaction lines (`click`) are skipped.
//

import Foundation

nonisolated enum FlowDirection {
    case down, up, right, left

    /// Ranks run left to right (or right to left) rather than top to bottom.
    var isHorizontal: Bool { self == .right || self == .left }
    var isReversed: Bool { self == .up || self == .left }

    init?(_ token: String) {
        switch token.uppercased() {
        case "TD", "TB": self = .down
        case "BT": self = .up
        case "LR": self = .right
        case "RL": self = .left
        default: return nil
        }
    }
}

nonisolated enum FlowShape {
    case rect, rounded, stadium, subroutine, cylinder, circle, asymmetric, decision, hexagon, parallelogram, trapezoid, document
}

nonisolated enum FlowLine {
    case solid, dotted, thick, invisible
}

nonisolated enum FlowHead {
    case none, arrow, circle, cross
}

nonisolated struct FlowNode {
    let id: String
    var title: String
    /// Lines after the first, written with `<br>` or a line break in the label.
    var detail: String
    var shape: FlowShape = .rect
    /// An SF Symbol named with `@{ icon: … }`, else one is picked from the shape and title.
    var icon: String?
    var classes: [String] = []
    /// Colors from `style`, as hex.
    var stroke: UInt32?
    var fill: UInt32?
    var group: String?
}

nonisolated struct FlowEdge {
    var from: String
    var to: String
    var label: String
    var line: FlowLine
    var head: FlowHead
    var tail: FlowHead
    var stroke: UInt32?
}

nonisolated struct FlowGroup {
    let id: String
    var title: String
    var parent: String?
}

nonisolated struct Flowchart {
    var direction: FlowDirection = .down
    var nodes: [FlowNode] = []
    var edges: [FlowEdge] = []
    var groups: [FlowGroup] = []
    /// `classDef` colors: stroke and fill, as hex.
    var classColors: [String: (stroke: UInt32?, fill: UInt32?)] = [:]

    func index(of id: String) -> Int? { nodes.firstIndex { $0.id == id } }
}

/// Why a fence could not be drawn.
nonisolated enum DiagramProblem: Error, Equatable {
    case empty
    /// A Mermaid diagram Lotion does not draw (sequence, gantt, …), by its keyword.
    case unsupported(String)
}

nonisolated enum FlowchartParser {
    static func parse(_ source: String) -> Result<Flowchart, DiagramProblem> {
        var lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0) }
        lines = stripFrontMatter(lines)
        var statements: [String] = []
        for line in lines {
            var text = line
            if let comment = text.range(of: "%%") { text = String(text[..<comment.lowerBound]) }
            for part in splitOutsideQuotes(text, on: ";") {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { statements.append(trimmed) }
            }
        }
        guard let header = statements.first else { return .failure(.empty) }
        let headerWords = header.split(separator: " ").map(String.init)
        guard let keyword = headerWords.first?.lowercased() else { return .failure(.empty) }
        guard keyword == "flowchart" || keyword == "graph" || keyword == "flowchart-elk" else {
            return .failure(.unsupported(headerWords[0]))
        }
        var chart = Flowchart()
        if headerWords.count > 1, let direction = FlowDirection(headerWords[1]) { chart.direction = direction }
        var reader = Reader(chart: chart)
        for statement in statements.dropFirst() { reader.read(statement) }
        return .success(reader.chart)
    }

    static func stripFrontMatter(_ lines: [String]) -> [String] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return lines }
        guard let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return lines }
        return Array(lines[(end + 1)...])
    }

    static func splitOutsideQuotes(_ text: String, on separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        for character in text {
            if character == "\"" { quoted.toggle() }
            if character == separator, !quoted {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Reads statements one at a time into a chart.
    private struct Reader {
        var chart: Flowchart
        var groupStack: [String] = []
        var anonymousGroups = 0

        mutating func read(_ statement: String) {
            let lower = statement.lowercased()
            if lower == "end" {
                _ = groupStack.popLast()
                return
            }
            if lower.hasPrefix("subgraph ") || lower == "subgraph" {
                openGroup(String(statement.dropFirst(8)).trimmingCharacters(in: .whitespaces))
                return
            }
            if lower.hasPrefix("direction ") { return }
            if lower.hasPrefix("classdef ") { readClassDef(String(statement.dropFirst(9))); return }
            if lower.hasPrefix("class ") { readClass(String(statement.dropFirst(6))); return }
            if lower.hasPrefix("style ") { readStyle(String(statement.dropFirst(6))); return }
            if lower.hasPrefix("linkstyle ") { readLinkStyle(String(statement.dropFirst(10))); return }
            if lower.hasPrefix("click ") || lower.hasPrefix("accTitle") || lower.hasPrefix("acctitle") || lower.hasPrefix("accdescr") { return }
            readChain(statement)
        }

        // MARK: Groups

        mutating func openGroup(_ rest: String) {
            var id = rest
            var title = rest
            if let open = rest.firstIndex(of: "["), rest.hasSuffix("]") {
                id = rest[..<open].trimmingCharacters(in: .whitespaces)
                title = unquote(String(rest[rest.index(after: open)..<rest.index(before: rest.endIndex)]))
            } else if rest.hasPrefix("\"") {
                title = unquote(rest)
                id = title
            }
            if id.isEmpty {
                anonymousGroups += 1
                id = "subgraph-\(anonymousGroups)"
            }
            if let existing = chart.groups.firstIndex(where: { $0.id == id }) {
                chart.groups[existing].title = cleanLabel(title).title
            } else {
                chart.groups.append(FlowGroup(id: id, title: cleanLabel(title).title, parent: groupStack.last))
            }
            groupStack.append(id)
        }

        // MARK: Styles

        mutating func readClassDef(_ rest: String) {
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let colors = Self.colors(parts[1])
            for name in parts[0].split(separator: ",") {
                chart.classColors[String(name).trimmingCharacters(in: .whitespaces)] = colors
            }
        }

        mutating func readClass(_ rest: String) {
            let parts = rest.split(separator: " ").map(String.init)
            guard parts.count >= 2 else { return }
            for id in parts[0].split(separator: ",") {
                if let index = chart.index(of: String(id)) { chart.nodes[index].classes.append(parts[1]) }
            }
        }

        mutating func readStyle(_ rest: String) {
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let colors = Self.colors(parts[1])
            let index = node(parts[0])
            if let stroke = colors.stroke { chart.nodes[index].stroke = stroke }
            if let fill = colors.fill { chart.nodes[index].fill = fill }
        }

        mutating func readLinkStyle(_ rest: String) {
            let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let stroke = Self.colors(parts[1]).stroke else { return }
            let targets: [Int] = parts[0] == "default"
                ? Array(chart.edges.indices)
                : parts[0].split(separator: ",").compactMap { Int($0) }
            for index in targets where chart.edges.indices.contains(index) { chart.edges[index].stroke = stroke }
        }

        static func colors(_ declarations: String) -> (stroke: UInt32?, fill: UInt32?) {
            var stroke: UInt32?
            var fill: UInt32?
            for declaration in declarations.split(separator: ",") {
                let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, let color = hex(pair[1]) else { continue }
                if pair[0] == "stroke" { stroke = color }
                if pair[0] == "fill" { fill = color }
            }
            return (stroke, fill)
        }

        static func hex(_ value: String) -> UInt32? {
            var text = value.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
            guard text.hasPrefix("#") else { return named[text.lowercased()] }
            text.removeFirst()
            if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
            guard text.count == 6 || text.count == 8 else { return nil }
            return UInt32(text.prefix(6), radix: 16)
        }

        static let named: [String: UInt32] = [
            "red": 0xE5484D, "green": 0x30A46C, "blue": 0x3B82F6, "orange": 0xF76B15, "purple": 0x8E4EC6,
            "pink": 0xD6409F, "yellow": 0xE2A336, "teal": 0x12A594, "gray": 0x8B8D98, "grey": 0x8B8D98,
        ]

        // MARK: Nodes and edges

        /// The node with this id, made if new.
        mutating func node(_ id: String) -> Int {
            if let index = chart.index(of: id) { return index }
            chart.nodes.append(FlowNode(id: id, title: id, detail: "", group: groupStack.last))
            return chart.nodes.count - 1
        }

        /// `A --> B -- label --> C & D`: a run of node groups joined by links.
        mutating func readChain(_ statement: String) {
            var scanner = Scanner(statement)
            var previous = readNodeGroup(&scanner)
            guard !previous.isEmpty else { return }
            while true {
                scanner.skipSpaces()
                guard let link = scanner.link() else { break }
                scanner.skipSpaces()
                let next = readNodeGroup(&scanner)
                guard !next.isEmpty else { break }
                for from in previous {
                    for to in next {
                        chart.edges.append(FlowEdge(from: from, to: to, label: link.label, line: link.line,
                                                    head: link.head, tail: link.tail, stroke: nil))
                    }
                }
                previous = next
            }
        }

        /// `A[Text] & B:::cls`: ids of the nodes read.
        mutating func readNodeGroup(_ scanner: inout Scanner) -> [String] {
            var ids: [String] = []
            repeat {
                scanner.skipSpaces()
                guard let id = readNode(&scanner) else { break }
                ids.append(id)
                scanner.skipSpaces()
            } while scanner.take("&")
            return ids
        }

        mutating func readNode(_ scanner: inout Scanner) -> String? {
            guard let id = scanner.identifier() else { return nil }
            let index = node(id)
            if let (shape, label) = scanner.shapeAndLabel() {
                let parts = cleanLabel(label)
                chart.nodes[index].shape = shape
                chart.nodes[index].title = parts.title
                chart.nodes[index].detail = parts.detail
            } else if scanner.peek("@{"), let body = scanner.braced() {
                applyAttributes(body, to: index)
            }
            while scanner.take(":::") {
                if let name = scanner.identifier() { chart.nodes[index].classes.append(name) }
            }
            if chart.nodes[index].group == nil { chart.nodes[index].group = groupStack.last }
            return id
        }

        /// `@{ shape: diam, label: "Text", icon: "bolt" }`
        mutating func applyAttributes(_ body: String, to index: Int) {
            for pair in FlowchartParser.splitOutsideQuotes(body, on: ",") {
                let parts = pair.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count == 2 else { continue }
                let value = unquote(parts[1])
                switch parts[0] {
                case "label":
                    let label = cleanLabel(value)
                    chart.nodes[index].title = label.title
                    chart.nodes[index].detail = label.detail
                case "shape":
                    chart.nodes[index].shape = Self.shapes[value.lowercased()] ?? .rect
                case "icon":
                    // `fa:user`, `mdi:account` or an SF Symbol: the last part names it.
                    chart.nodes[index].icon = value.split(separator: ":").last.map(String.init)
                default:
                    break
                }
            }
        }

        static let shapes: [String: FlowShape] = [
            "rect": .rect, "rectangle": .rect, "proc": .rect, "process": .rect,
            "rounded": .rounded, "event": .rounded,
            "stadium": .stadium, "pill": .stadium, "terminal": .stadium,
            "subroutine": .subroutine, "subproc": .subroutine, "fr-rect": .subroutine,
            "cyl": .cylinder, "cylinder": .cylinder, "db": .cylinder, "database": .cylinder,
            "circle": .circle, "circ": .circle, "sm-circ": .circle, "start": .circle, "stop": .circle, "dbl-circ": .circle,
            "diam": .decision, "diamond": .decision, "decision": .decision, "question": .decision,
            "hex": .hexagon, "hexagon": .hexagon, "prepare": .hexagon,
            "lean-r": .parallelogram, "lean-l": .parallelogram, "in-out": .parallelogram,
            "trap-b": .trapezoid, "trap-t": .trapezoid, "priority": .trapezoid, "manual": .trapezoid,
            "doc": .document, "document": .document, "docs": .document, "documents": .document,
            "odd": .asymmetric,
        ]
    }

    /// A label's title and detail, with Mermaid's markup taken out.
    static func cleanLabel(_ raw: String) -> (title: String, detail: String) {
        var text = unquote(raw)
        if text.hasPrefix("`"), text.hasSuffix("`"), text.count >= 2 { text = String(text.dropFirst().dropLast()) }
        for breakTag in ["<br/>", "<br />", "<br>", "\\n"] {
            text = text.replacingOccurrences(of: breakTag, with: "\n", options: .caseInsensitive)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
        text = decodeEntities(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first else { return ("", "") }
        return (first, lines.dropFirst().joined(separator: "\n"))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") || text.contains("#") else { return text }
        var result = text
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("#quot;", "\""), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: character)
        }
        return result
    }

    static func unquote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }
}

/// A cursor over one statement.
nonisolated struct Scanner {
    private let characters: [Character]
    private(set) var position = 0

    init(_ text: String) { characters = Array(text) }

    var isAtEnd: Bool { position >= characters.count }

    private func character(_ offset: Int = 0) -> Character? {
        let index = position + offset
        return index < characters.count ? characters[index] : nil
    }

    mutating func skipSpaces() {
        while let character = character(), character == " " || character == "\t" { position += 1 }
    }

    func peek(_ text: String) -> Bool {
        let wanted = Array(text)
        guard position + wanted.count <= characters.count else { return false }
        return Array(characters[position..<(position + wanted.count)]) == wanted
    }

    mutating func take(_ text: String) -> Bool {
        guard peek(text) else { return false }
        position += text.count
        return true
    }

    /// A node id: letters, digits, `_` and `-` that do not start a link.
    mutating func identifier() -> String? {
        let start = position
        while let character = character() {
            if character.isLetter || character.isNumber || character == "_" || character == "." || character == "/" {
                position += 1
            } else if character == "-", !peekLink() {
                position += 1
            } else {
                break
            }
        }
        return position > start ? String(characters[start..<position]) : nil
    }

    private func peekLink() -> Bool {
        var copy = self
        return copy.link() != nil
    }

    /// The text between matching delimiters, quotes respected.
    private mutating func until(_ close: String) -> String? {
        let start = position
        var quoted = false
        while position < characters.count {
            if characters[position] == "\"" { quoted.toggle() }
            if !quoted, peek(close) {
                let text = String(characters[start..<position])
                position += close.count
                return text
            }
            position += 1
        }
        position = start
        return nil
    }

    /// `@{ … }`
    mutating func braced() -> String? {
        guard take("@{") else { return nil }
        return until("}")
    }

    /// A shape's brackets and the label inside them.
    mutating func shapeAndLabel() -> (FlowShape, String)? {
        let forms: [(String, String, FlowShape)] = [
            ("(((", ")))", .circle), ("([", "])", .stadium), ("[[", "]]", .subroutine), ("[(", ")]", .cylinder),
            ("((", "))", .circle), ("{{", "}}", .hexagon), ("[/", "/]", .parallelogram), ("[\\", "\\]", .parallelogram),
            ("[/", "\\]", .trapezoid), ("[\\", "/]", .trapezoid), ("[", "]", .rect), ("(", ")", .rounded),
            ("{", "}", .decision), (">", "]", .asymmetric),
        ]
        for (open, close, shape) in forms where peek(open) {
            let start = position
            position += open.count
            if let label = until(close) { return (shape, label) }
            position = start
        }
        return nil
    }

    struct Link {
        var label = ""
        var line: FlowLine = .solid
        var head: FlowHead = .arrow
        var tail: FlowHead = .none
    }

    /// One link: `-->`, `---`, `-.->`, `==>`, `~~~`, `--o`, `--x`, `<-->`,
    /// with a label written `-- text -->`, `-->|text|` or `-. text .->`.
    mutating func link() -> Link? {
        let start = position
        var link = Link()
        if take("<") { link.tail = .arrow } else if peek("o--") || peek("o==") || peek("o-.") { position += 1; link.tail = .circle } else if peek("x--") || peek("x==") || peek("x-.") { position += 1; link.tail = .cross }

        guard let first = character(), first == "-" || first == "=" || first == "~" else { position = start; return nil }
        if first == "~" {
            guard take("~~~") else { position = start; return nil }
            while take("~") {}
            link.line = .invisible
            link.head = .none
            link.tail = .none
            return link
        }
        link.line = first == "=" ? .thick : .solid
        // The run of link characters, which may hold a label (`-- text -->`).
        var body = ""
        while let character = character(), "-=.".contains(character) {
            body.append(character)
            position += 1
        }
        if body.contains(".") { link.line = .dotted }
        guard body.count >= 2 || character() == ">" else { position = start; return nil }

        if let head = endHead() {
            link.head = head
        } else if body.count == 2, isLabelStart() {
            // `-- text -->`: read the label up to the closing run.
            skipSpaces()
            let labelStart = position
            var found = false
            while position < characters.count {
                if let c = character(), "-=.".contains(c) {
                    var probe = self
                    var run = ""
                    while let next = probe.character(), "-=.".contains(next) {
                        run.append(next)
                        probe.position += 1
                    }
                    if run.count >= 2 || probe.character() == ">" {
                        let label = String(characters[labelStart..<position])
                        self = probe
                        link.label = FlowchartParser.cleanLabel(label).title
                        if run.contains(".") { link.line = .dotted }
                        link.head = endHead() ?? .none
                        found = true
                        break
                    }
                }
                position += 1
            }
            guard found else { position = start; return nil }
        } else {
            link.head = .none
        }
        skipSpaces()
        if take("|") {
            if let label = until("|") { link.label = FlowchartParser.cleanLabel(label).title }
        }
        return link
    }

    private mutating func endHead() -> FlowHead? {
        if take(">") { return .arrow }
        // `--o B` / `--x B`: a circle or cross, not the start of an id like `--oven`.
        for (mark, head) in [("o", FlowHead.circle), ("x", FlowHead.cross)] where peek(mark) {
            let next = position + 1 < characters.count ? characters[position + 1] : " "
            if next == " " || next == "|" || next == "\t" {
                position += 1
                return head
            }
        }
        return nil
    }

    /// A label follows the opener: a space then text that is not a node shape.
    private func isLabelStart() -> Bool {
        guard character() == " " else { return false }
        var probe = self
        probe.skipSpaces()
        guard let next = probe.character() else { return false }
        return !"-=.>|".contains(next)
    }
}
