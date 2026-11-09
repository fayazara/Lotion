//
//  SequenceDiagram.swift
//  Lotion
//
//  Mermaid's sequenceDiagram, drawn in the same hand as flowcharts:
//  participants are cards with an icon chip, lifelines are dotted, messages
//  are thin wires with open chevrons, and loop / alt / opt blocks are soft
//  frames with a tinted tag.
//

import AppKit

// MARK: - Model

nonisolated struct SeqParticipant {
    let id: String
    var title: String
    var detail: String
    var isActor: Bool
}

nonisolated enum SeqHead {
    case arrow, none, cross, async
}

nonisolated struct SeqMessage {
    var from: Int
    var to: Int
    var text: String
    var dashed: Bool
    var head: SeqHead
    /// `<<->>`: an arrow at both ends.
    var both: Bool
    /// `+` after the arrow starts the target's activation; `-` ends the sender's.
    var activates: Bool
    var deactivates: Bool
    var number: Int?
}

nonisolated enum SeqNotePlace {
    case over, leftOf, rightOf
}

nonisolated struct SeqNote {
    var place: SeqNotePlace
    var participants: [Int]
    var text: String
}

nonisolated enum SeqEvent {
    case message(SeqMessage)
    case note(SeqNote)
    /// loop, alt, opt, par, critical, break, rect.
    case start(kind: String, label: String)
    /// else, and, option: a new section of the open block.
    case divider(label: String)
    case end
    case activate(Int)
    case deactivate(Int)
}

nonisolated struct SequenceChart {
    var participants: [SeqParticipant] = []
    var events: [SeqEvent] = []

    func index(of id: String) -> Int? { participants.firstIndex { $0.id == id } }
}

// MARK: - Parsing

nonisolated enum SequenceParser {
    static let blockKinds: Set<String> = ["loop", "alt", "opt", "par", "critical", "break", "rect"]
    static let dividerKinds: Set<String> = ["else", "and", "option"]
    /// Longest first, so `-->>` isn't read as `-->`.
    static let arrows: [(token: String, dashed: Bool, head: SeqHead, both: Bool)] = [
        ("<<-->>", true, .arrow, true), ("<<->>", false, .arrow, true),
        ("-->>", true, .arrow, false), ("->>", false, .arrow, false),
        ("--x", true, .cross, false), ("-x", false, .cross, false),
        ("--)", true, .async, false), ("-)", false, .async, false),
        ("-->", true, .none, false), ("->", false, .none, false),
    ]

    static func isSequence(_ source: String) -> Bool {
        statements(source).first?.lowercased().hasPrefix("sequencediagram") == true
    }

    private static func statements(_ source: String) -> [String] {
        let lines = FlowchartParser.stripFrontMatter(source.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        return lines.compactMap { line in
            var text = line
            if let comment = text.range(of: "%%") { text = String(text[..<comment.lowerBound]) }
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    static func parse(_ source: String) -> Result<SequenceChart, DiagramProblem> {
        let lines = statements(source)
        guard lines.count > 1 else { return .failure(.empty) }
        var chart = SequenceChart()
        var numbering: Int?
        // `box … end` groups participants; its `end` closes nothing we draw.
        var openings: [Bool] = []

        func participant(_ raw: String) -> Int {
            let id = raw.trimmingCharacters(in: .whitespaces)
            if let index = chart.index(of: id) { return index }
            chart.participants.append(SeqParticipant(id: id, title: id, detail: "", isActor: false))
            return chart.participants.count - 1
        }

        for line in lines.dropFirst() {
            let words = line.split(separator: " ", maxSplits: 1).map(String.init)
            let keyword = words[0].lowercased()
            let rest = words.count > 1 ? words[1].trimmingCharacters(in: .whitespaces) : ""

            switch keyword {
            case "participant", "actor", "create":
                var body = rest
                var isActor = keyword == "actor"
                if keyword == "create" {
                    let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                    guard parts.count == 2 else { continue }
                    isActor = parts[0].lowercased() == "actor"
                    body = parts[1]
                }
                let (id, alias): (String, String?) = {
                    if let range = body.range(of: " as ") {
                        return (String(body[..<range.lowerBound]), String(body[range.upperBound...]))
                    }
                    return (body, nil)
                }()
                let index = participant(id)
                let label = FlowchartParser.cleanLabel(alias ?? id)
                chart.participants[index].title = label.title
                chart.participants[index].detail = label.detail
                chart.participants[index].isActor = isActor
                continue
            case "autonumber":
                numbering = 1
                continue
            case "activate", "deactivate":
                guard !rest.isEmpty else { continue }
                let index = participant(rest)
                chart.events.append(keyword == "activate" ? .activate(index) : .deactivate(index))
                continue
            case "note":
                if let note = parseNote(rest, participant: participant) { chart.events.append(.note(note)) }
                continue
            case "box":
                openings.append(false)
                continue
            case "end":
                if openings.popLast() == true { chart.events.append(.end) }
                continue
            case "destroy", "title", "accTitle:", "accDescr:", "links", "link", "properties", "details":
                continue
            default:
                break
            }
            if blockKinds.contains(keyword) {
                openings.append(true)
                chart.events.append(.start(kind: keyword, label: FlowchartParser.cleanLabel(rest).title))
                continue
            }
            if dividerKinds.contains(keyword) {
                chart.events.append(.divider(label: FlowchartParser.cleanLabel(rest).title))
                continue
            }
            if var message = parseMessage(line, participant: participant) {
                if let number = numbering {
                    message.number = number
                    numbering = number + 1
                }
                chart.events.append(.message(message))
            }
        }
        // Close anything left open so frames still draw.
        for open in openings.reversed() where open { chart.events.append(.end) }
        guard !chart.participants.isEmpty else { return .failure(.empty) }
        return .success(chart)
    }

    private static func parseMessage(_ line: String, participant: (String) -> Int) -> SeqMessage? {
        let (head, text): (String, String) = {
            guard let colon = line.firstIndex(of: ":") else { return (line, "") }
            return (String(line[..<colon]), String(line[line.index(after: colon)...]))
        }()
        for arrow in arrows {
            guard let range = head.range(of: arrow.token) else { continue }
            let from = head[..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            var to = head[range.upperBound...].trimmingCharacters(in: .whitespaces)
            var activates = false, deactivates = false
            if to.hasPrefix("+") { activates = true; to.removeFirst() }
            else if to.hasPrefix("-") { deactivates = true; to.removeFirst() }
            to = to.trimmingCharacters(in: .whitespaces)
            guard !from.isEmpty, !to.isEmpty else { return nil }
            let label = FlowchartParser.cleanLabel(text)
            let body = [label.title, label.detail].filter { !$0.isEmpty }.joined(separator: "\n")
            return SeqMessage(from: participant(from), to: participant(to), text: body, dashed: arrow.dashed,
                              head: arrow.head, both: arrow.both, activates: activates, deactivates: deactivates)
        }
        return nil
    }

    private static func parseNote(_ rest: String, participant: (String) -> Int) -> SeqNote? {
        guard let colon = rest.firstIndex(of: ":") else { return nil }
        let where_ = rest[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
        let original = rest[..<colon].trimmingCharacters(in: .whitespaces)
        let place: SeqNotePlace
        let names: String
        if where_.hasPrefix("right of ") { place = .rightOf; names = String(original.dropFirst(9)) }
        else if where_.hasPrefix("left of ") { place = .leftOf; names = String(original.dropFirst(8)) }
        else if where_.hasPrefix("over ") { place = .over; names = String(original.dropFirst(5)) }
        else { return nil }
        let ids = names.split(separator: ",").map { participant(String($0)) }
        guard !ids.isEmpty else { return nil }
        let label = FlowchartParser.cleanLabel(String(rest[rest.index(after: colon)...]))
        return SeqNote(place: place, participants: ids, text: [label.title, label.detail].filter { !$0.isEmpty }.joined(separator: "\n"))
    }
}

// MARK: - Layout

struct SequenceLayout {
    struct Card { var rect: CGRect; var title: String; var detail: String; var symbol: String }
    struct Message {
        var from: CGPoint
        var to: CGPoint
        /// A message to oneself loops out to the right and back.
        var loop: CGRect?
        var textRect: CGRect
        var text: String
        var dashed: Bool
        var head: SeqHead
        var both: Bool
        var number: Int?
    }
    struct Note { var rect: CGRect; var text: String }
    struct Frame { var rect: CGRect; var kind: String; var label: String; var dividers: [(y: CGFloat, label: String)]; var depth: Int }

    var size: CGSize = .zero
    var cards: [Card] = []
    var lifelines: [(x: CGFloat, top: CGFloat, bottom: CGFloat)] = []
    var messages: [Message] = []
    var notes: [Note] = []
    var frames: [Frame] = []
    var activations: [CGRect] = []

    static let margin: CGFloat = 28
    static let cardPadding: CGFloat = 10
    static let chip: CGFloat = 26
    static let selfLoop: CGFloat = 30
    static let bar: CGFloat = 10

    static func make(_ chart: SequenceChart, metrics: FlowMetrics) -> SequenceLayout {
        var layout = SequenceLayout()
        let count = chart.participants.count
        guard count > 0 else { return layout }
        let textFont = metrics.detail

        func textSize(_ text: String) -> CGSize {
            text.isEmpty ? .zero : metrics.size(of: text, font: textFont)
        }

        // Cards and how wide each is.
        var widths: [CGFloat] = []
        var cardHeight: CGFloat = cardPadding * 2 + chip
        for person in chart.participants {
            let title = metrics.size(of: person.title, font: metrics.title).width
            let detail = metrics.size(of: person.detail, font: metrics.detail).width
            widths.append(min(260, max(112, cardPadding + chip + 9 + max(title, detail) + 16)))
            if !person.detail.isEmpty { cardHeight = max(cardHeight, cardPadding * 2 + chip + 4 + CardRow.lineHeight(metrics.detail)) }
        }

        // Columns: far enough apart for every message drawn between them.
        var centers: [CGFloat] = []
        for i in 0..<count {
            centers.append(i == 0 ? widths[0] / 2 : centers[i - 1] + widths[i - 1] / 2 + widths[i] / 2 + 40)
        }
        var needs: [(a: Int, b: Int, room: CGFloat)] = []
        var leftRoom: CGFloat = 0
        var rightRoom: CGFloat = 0
        for event in chart.events {
            switch event {
            case .message(let m):
                let text = textSize(m.text).width + (m.number == nil ? 0 : 22)
                if m.from == m.to {
                    let room = selfLoop + 14 + text + 20
                    if m.from + 1 < count { needs.append((m.from, m.from + 1, room)) } else { rightRoom = max(rightRoom, room) }
                } else {
                    needs.append((min(m.from, m.to), max(m.from, m.to), text + 48))
                }
            case .note(let n):
                let width = min(240, textSize(n.text).width) + 28
                guard let first = n.participants.first else { continue }
                switch n.place {
                case .rightOf:
                    if first + 1 < count { needs.append((first, first + 1, width + 24)) } else { rightRoom = max(rightRoom, width + 16) }
                case .leftOf:
                    if first > 0 { needs.append((first - 1, first, width + 24)) } else { leftRoom = max(leftRoom, width + 16) }
                case .over:
                    if n.participants.count == 1 {
                        if first > 0 { needs.append((first - 1, first, width / 2 + widths[first - 1] / 2 + 12)) }
                        if first + 1 < count { needs.append((first, first + 1, width / 2 + widths[first + 1] / 2 + 12)) }
                    }
                }
            default:
                break
            }
        }
        for need in needs.sorted(by: { ($0.b - $0.a) < ($1.b - $1.a) }) {
            let deficit = need.room - (centers[need.b] - centers[need.a])
            guard deficit > 0 else { continue }
            // Spread a wide message over every gap it crosses.
            let gaps = CGFloat(need.b - need.a)
            for i in (need.a + 1)..<count { centers[i] += deficit * CGFloat(min(i - need.a, need.b - need.a)) / gaps }
        }
        let left = max(widths[0] / 2, leftRoom)
        for i in centers.indices { centers[i] += left - widths[0] / 2 }

        // Down the page, one event at a time.
        let top: CGFloat = 0
        var y = top + cardHeight + 26
        var active: [[CGFloat]] = Array(repeating: [], count: count)
        var stack: [(index: Int, kind: String, label: String, top: CGFloat, dividers: [(CGFloat, String)], members: Set<Int>, reach: CGFloat, depth: Int)] = []
        var finished: [(Frame, Set<Int>, CGFloat)] = []
        let lineHeight = CardRow.lineHeight(textFont)

        func touch(_ columns: [Int], reach: CGFloat = 0) {
            for i in stack.indices {
                stack[i].members.formUnion(columns)
                stack[i].reach = max(stack[i].reach, reach)
            }
        }
        func edge(_ column: Int, toward x: CGFloat) -> CGFloat {
            let depth = CGFloat(active[column].count)
            guard depth > 0 else { return centers[column] }
            let half = bar / 2 + (depth - 1) * 4
            return x > centers[column] ? centers[column] + half : centers[column] - bar / 2
        }

        for event in chart.events {
            switch event {
            case .message(let m):
                let size = textSize(m.text)
                let numberWidth: CGFloat = m.number == nil ? 0 : 22
                if m.from == m.to {
                    let x = edge(m.from, toward: .greatestFiniteMagnitude)
                    let height = max(24, size.height + 8)
                    let loop = CGRect(x: x, y: y + 2, width: selfLoop, height: height)
                    let textRect = CGRect(x: loop.maxX + 12 + numberWidth, y: loop.midY - size.height / 2, width: size.width + 2, height: size.height)
                    layout.messages.append(Message(from: CGPoint(x: x, y: loop.minY), to: CGPoint(x: x, y: loop.maxY), loop: loop,
                                                   textRect: textRect, text: m.text, dashed: m.dashed, head: m.head, both: m.both, number: m.number))
                    touch([m.from], reach: textRect.maxX)
                    y = loop.maxY + 22
                } else {
                    let labelTop = y
                    let lineY = (m.text.isEmpty ? y + 4 : y + size.height + 7).rounded()
                    if m.activates { active[m.to].append(lineY) }
                    let fromX = edge(m.from, toward: centers[m.to])
                    let toX = edge(m.to, toward: centers[m.from])
                    let mid = (fromX + toX) / 2 + numberWidth / 2
                    let textRect = CGRect(x: (mid - size.width / 2).rounded(), y: labelTop, width: size.width + 2, height: size.height)
                    layout.messages.append(Message(from: CGPoint(x: fromX, y: lineY), to: CGPoint(x: toX, y: lineY), loop: nil,
                                                   textRect: textRect, text: m.text, dashed: m.dashed, head: m.head, both: m.both, number: m.number))
                    if m.deactivates, let start = active[m.from].popLast() {
                        layout.activations.append(activation(centers[m.from], depth: active[m.from].count, from: start, to: lineY))
                    }
                    touch([m.from, m.to])
                    y = lineY + 24
                }
            case .note(let n):
                guard let first = n.participants.first else { continue }
                let size = metrics.size(of: n.text, font: textFont, width: 240)
                let width = size.width + 28
                let height = size.height + 16
                let rect: CGRect
                switch n.place {
                case .over:
                    let last = n.participants.last ?? first
                    let a = centers[min(first, last)], b = centers[max(first, last)]
                    let span = max(width, b - a + 48)
                    rect = CGRect(x: ((a + b) / 2 - span / 2).rounded(), y: y, width: span, height: height)
                case .rightOf:
                    rect = CGRect(x: centers[first] + 16, y: y, width: width, height: height)
                case .leftOf:
                    rect = CGRect(x: centers[first] - 16 - width, y: y, width: width, height: height)
                }
                layout.notes.append(Note(rect: rect, text: n.text))
                touch(n.participants, reach: rect.maxX)
                y = rect.maxY + 20
            case .start(let kind, let label):
                stack.append((finished.count + stack.count, kind, label, y, [], [], 0, 0))
                y += 30 + 12
            case .divider(let label):
                guard !stack.isEmpty else { continue }
                stack[stack.count - 1].dividers.append((y, label))
                y += 30 + 8
            case .end:
                guard let frame = stack.popLast() else { continue }
                let bottom = y - 4
                let placed = Frame(rect: CGRect(x: 0, y: frame.top, width: 0, height: bottom - frame.top), kind: frame.kind, label: frame.label,
                                   dividers: frame.dividers.map { (y: $0.0, label: $0.1) }, depth: frame.depth)
                finished.append((placed, frame.members, frame.reach))
                if !stack.isEmpty { stack[stack.count - 1].depth = max(stack[stack.count - 1].depth, frame.depth + 1) }
                // Members and reach carry up to the frames around it.
                touch(Array(frame.members), reach: frame.reach)
                y = bottom + 20
            case .activate(let column):
                active[column].append(y - 10)
            case .deactivate(let column):
                if let start = active[column].popLast() {
                    layout.activations.append(activation(centers[column], depth: active[column].count, from: start, to: y - 10))
                }
            }
        }
        let bottom = y
        for column in active.indices {
            for (depth, start) in active[column].enumerated() {
                layout.activations.append(activation(centers[column], depth: depth, from: start, to: bottom - 8))
            }
        }

        // Frames wrap the lifelines they touch, wider for each frame they hold.
        let lastFrame = finished
        for (frame, members, reach) in lastFrame {
            var rect = frame.rect
            let pad = 30 + CGFloat(frame.depth) * 12
            let columns = members.isEmpty ? Set(0..<count) : members
            let minX = (columns.map { centers[$0] }.min() ?? 0) - pad - 18
            var maxX = max((columns.map { centers[$0] }.max() ?? 0) + pad + 18, reach + 16 + CGFloat(frame.depth) * 12)
            let header = metrics.size(of: frame.kind, font: metrics.label).width + 20 + metrics.size(of: frame.label, font: textFont).width + 36
            maxX = max(maxX, minX + header)
            rect.origin.x = minX
            rect.size.width = maxX - minX
            layout.frames.append(Frame(rect: rect, kind: frame.kind, label: frame.label, dividers: frame.dividers, depth: frame.depth))
        }
        layout.frames.sort { $0.depth > $1.depth }

        // Cards on top; lifelines run from them to the bottom.
        for (i, person) in chart.participants.enumerated() {
            let rect = CGRect(x: (centers[i] - widths[i] / 2).rounded(), y: top, width: widths[i], height: cardHeight)
            let node = FlowNode(id: person.id, title: person.title, detail: person.detail)
            let symbol = person.isActor ? "person" : FlowIcons.symbol(for: node)
            layout.cards.append(Card(rect: rect, title: person.title, detail: person.detail, symbol: symbol))
            layout.lifelines.append((centers[i], rect.maxY, bottom))
        }

        // Shift everything clear of the margin and size the canvas.
        var bounds = layout.cards.reduce(CGRect.null) { $0.union($1.rect) }
        for frame in layout.frames { bounds = bounds.union(frame.rect) }
        for note in layout.notes { bounds = bounds.union(note.rect) }
        for message in layout.messages { bounds = bounds.union(message.textRect); if let loop = message.loop { bounds = bounds.union(loop) } }
        bounds = bounds.union(CGRect(x: centers[0], y: 0, width: 1, height: bottom))
        let dx = margin - bounds.minX
        let dy = margin - bounds.minY
        layout.shift(dx: dx, dy: dy)
        layout.size = CGSize(width: ceil(bounds.width + margin * 2), height: ceil(bounds.height + margin * 2))
        return layout
    }

    private static func activation(_ center: CGFloat, depth: Int, from: CGFloat, to: CGFloat) -> CGRect {
        CGRect(x: center - bar / 2 + CGFloat(depth) * 4, y: from - 6, width: bar, height: max(12, to - from + 12))
    }

    private mutating func shift(dx: CGFloat, dy: CGFloat) {
        func move(_ r: CGRect) -> CGRect { r.offsetBy(dx: dx, dy: dy) }
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + dx, y: p.y + dy) }
        for i in cards.indices { cards[i].rect = move(cards[i].rect) }
        lifelines = lifelines.map { ($0.x + dx, $0.top + dy, $0.bottom + dy) }
        for i in messages.indices {
            messages[i].from = move(messages[i].from)
            messages[i].to = move(messages[i].to)
            messages[i].loop = messages[i].loop.map(move)
            messages[i].textRect = move(messages[i].textRect)
        }
        for i in notes.indices { notes[i].rect = move(notes[i].rect) }
        for i in frames.indices {
            frames[i].rect = move(frames[i].rect)
            frames[i].dividers = frames[i].dividers.map { (y: $0.y + dy, label: $0.label) }
        }
        activations = activations.map(move)
    }
}

// MARK: - Painting

struct SequencePainter {
    let layout: SequenceLayout
    let metrics: FlowMetrics
    let palette: ThemePalette

    private var ink: DiagramInk { DiagramInk(palette: palette) }

    func draw() {
        for frame in layout.frames { drawFrameBody(frame) }
        drawLifelines()
        for bar in layout.activations { drawActivation(bar) }
        drawMessages()
        for note in layout.notes { drawNote(note) }
        for frame in layout.frames { drawFrameHeader(frame) }
        for card in layout.cards { drawCard(card) }
    }

    private static let tints: [String: UInt32] = [
        "loop": 0x3B82F6, "alt": 0x8B5CF6, "opt": 0x14B8A6, "par": 0xF59E0B,
        "critical": 0xEF4444, "break": 0xEF4444, "rect": 0x64748B,
    ]

    private func tint(_ kind: String) -> NSColor { NSColor(hex: Self.tints[kind] ?? 0x64748B) }

    private func drawFrameBody(_ frame: SequenceLayout.Frame) {
        let path = NSBezierPath(roundedRect: frame.rect, xRadius: 12, yRadius: 12)
        tint(frame.kind).withAlphaComponent(palette.isDark ? 0.05 : 0.035).setFill()
        path.fill()
        tint(frame.kind).withAlphaComponent(palette.isDark ? 0.28 : 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
        for divider in frame.dividers {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: frame.rect.minX + 1, y: divider.y))
            line.line(to: NSPoint(x: frame.rect.maxX - 1, y: divider.y))
            line.setLineDash([4, 4], count: 2, phase: 0)
            line.lineWidth = 1
            line.stroke()
        }
    }

    private func drawFrameHeader(_ frame: SequenceLayout.Frame) {
        let color = tint(frame.kind)
        let font = metrics.label
        let row = frame.rect.minY + 16
        let tagWidth = CardRow.width(frame.kind, font: font) + 14
        let tag = NSRect(x: frame.rect.minX + 10, y: row - 10, width: tagWidth, height: 20)
        color.withAlphaComponent(palette.isDark ? 0.22 : 0.14).setFill()
        NSBezierPath(roundedRect: tag, xRadius: 6, yRadius: 6).fill()
        CardRow.text(frame.kind, font: font, color: palette.isDark ? color.blended(withFraction: 0.35, of: .white) ?? color : color,
                     x: tag.minX + 7, centerY: row)
        if !frame.label.isEmpty {
            CardRow.text(frame.label, font: metrics.detail, color: palette.secondary, x: tag.maxX + 8, centerY: row,
                         maxWidth: frame.rect.maxX - tag.maxX - 18)
        }
        for divider in frame.dividers where !divider.label.isEmpty {
            CardRow.text(divider.label, font: metrics.detail, color: palette.secondary, x: frame.rect.minX + 14, centerY: divider.y + 15,
                         maxWidth: frame.rect.width - 28)
        }
    }

    private func drawLifelines() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(palette.text.withAlphaComponent(palette.isDark ? 0.2 : 0.16).cgColor)
        context.setLineWidth(1)
        context.setLineDash(phase: 0, lengths: [3, 4])
        for line in layout.lifelines {
            context.move(to: CGPoint(x: line.x, y: line.top))
            context.addLine(to: CGPoint(x: line.x, y: line.bottom))
        }
        context.strokePath()
        context.restoreGState()
    }

    private func drawActivation(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        ink.cardFill.setFill()
        path.fill()
        ink.wire.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func drawMessages() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let color = palette.text.withAlphaComponent(palette.isDark ? 0.5 : 0.42)
        for message in layout.messages {
            let path = CGMutablePath()
            var tip = message.to
            var direction: CGPoint
            if let loop = message.loop {
                let r: CGFloat = 8
                path.move(to: CGPoint(x: loop.minX, y: loop.minY))
                path.addArc(tangent1End: CGPoint(x: loop.maxX, y: loop.minY), tangent2End: CGPoint(x: loop.maxX, y: loop.maxY), radius: r)
                path.addArc(tangent1End: CGPoint(x: loop.maxX, y: loop.maxY), tangent2End: CGPoint(x: loop.minX, y: loop.maxY), radius: r)
                path.addLine(to: CGPoint(x: loop.minX + 1, y: loop.maxY))
                tip = CGPoint(x: loop.minX, y: loop.maxY)
                direction = CGPoint(x: -1, y: 0)
            } else {
                direction = CGPoint(x: message.to.x > message.from.x ? 1 : -1, y: 0)
                path.move(to: message.from)
                path.addLine(to: CGPoint(x: message.to.x - direction.x, y: message.to.y))
            }
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(1.25)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if message.dashed { context.setLineDash(phase: 0, lengths: [4, 4]) }
            context.strokePath()
            context.restoreGState()
            head(message.head, at: tip, direction: direction, color: color)
            if message.both, message.loop == nil {
                head(message.head, at: message.from, direction: CGPoint(x: -direction.x, y: 0), color: color)
            }
            if !message.text.isEmpty {
                let style = NSMutableParagraphStyle()
                style.alignment = message.loop == nil ? .center : .left
                (message.text as NSString).draw(with: message.textRect, options: [.usesLineFragmentOrigin],
                                                attributes: [.font: metrics.detail, .foregroundColor: palette.text.withAlphaComponent(0.82), .paragraphStyle: style])
            }
            if let number = message.number { drawNumber(number, beside: message) }
        }
    }

    private func drawNumber(_ number: Int, beside message: SequenceLayout.Message) {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        let text = "\(number)"
        let side = max(16, CardRow.width(text, font: font) + 8)
        let center = CGPoint(x: message.textRect.minX - side / 2 - 5, y: message.textRect.midY)
        let disc = NSRect(x: center.x - side / 2, y: center.y - 8, width: side, height: 16)
        palette.accent.withAlphaComponent(palette.isDark ? 0.28 : 0.16).setFill()
        NSBezierPath(roundedRect: disc, xRadius: 8, yRadius: 8).fill()
        let color = palette.isDark ? palette.accent.blended(withFraction: 0.55, of: .white) ?? palette.accent : palette.accent
        CardRow.text(text, font: font, color: color, x: center.x - CardRow.width(text, font: font) / 2, centerY: center.y)
    }

    private func head(_ head: SeqHead, at tip: CGPoint, direction d: CGPoint, color: NSColor) {
        let normal = CGPoint(x: -d.y, y: d.x)
        let path = NSBezierPath()
        switch head {
        case .none:
            return
        case .arrow:
            let size: CGFloat = 6
            path.move(to: NSPoint(x: tip.x - d.x * size + normal.x * size * 0.8, y: tip.y - d.y * size + normal.y * size * 0.8))
            path.line(to: tip)
            path.line(to: NSPoint(x: tip.x - d.x * size - normal.x * size * 0.8, y: tip.y - d.y * size - normal.y * size * 0.8))
        case .async:
            let size: CGFloat = 6
            path.move(to: NSPoint(x: tip.x - d.x * size + normal.x * size * 0.8, y: tip.y - d.y * size + normal.y * size * 0.8))
            path.line(to: tip)
        case .cross:
            let c = NSPoint(x: tip.x - d.x * 5, y: tip.y - d.y * 5)
            for sign in [-1.0, 1.0] {
                path.move(to: NSPoint(x: c.x - 3.5, y: c.y - 3.5 * sign))
                path.line(to: NSPoint(x: c.x + 3.5, y: c.y + 3.5 * sign))
            }
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    private func drawNote(_ note: SequenceLayout.Note) {
        let amber = NSColor(hex: 0xE2A336)
        let path = NSBezierPath(roundedRect: note.rect, xRadius: 10, yRadius: 10)
        ink.cardFill.setFill()
        path.fill()
        amber.withAlphaComponent(palette.isDark ? 0.14 : 0.12).setFill()
        path.fill()
        amber.withAlphaComponent(palette.isDark ? 0.4 : 0.45).setStroke()
        path.lineWidth = 1
        path.stroke()
        (note.text as NSString).draw(with: note.rect.insetBy(dx: 14, dy: 8), options: [.usesLineFragmentOrigin],
                                     attributes: [.font: metrics.detail, .foregroundColor: palette.text.withAlphaComponent(0.85)])
    }

    private func drawCard(_ card: SequenceLayout.Card) {
        let rect = card.rect
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 12, yRadius: 12)
        NSGraphicsContext.saveGraphicsState()
        if !palette.isDark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        ink.cardFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        ink.cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()

        let p = SequenceLayout.cardPadding
        let hue = FlowIcons.hue(for: card.symbol, dark: palette.isDark)
        let chip = NSRect(x: rect.minX + p, y: rect.minY + p, width: SequenceLayout.chip, height: SequenceLayout.chip)
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 7, yRadius: 7)
        hue.withAlphaComponent(palette.isDark ? 0.2 : 0.12).setFill()
        chipPath.fill()
        hue.withAlphaComponent(0.18).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()
        CardRow.icon(NSImage(systemSymbolName: card.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium))?.tinted(hue), centerX: chip.midX, centerY: chip.midY)
        let x = chip.maxX + 9
        CardRow.text(card.title, font: metrics.title, color: palette.text, x: x, centerY: chip.midY, maxWidth: rect.maxX - 12 - x)
        if !card.detail.isEmpty {
            CardRow.text(card.detail, font: metrics.detail, color: palette.secondary, x: chip.minX,
                         centerY: chip.maxY + 4 + CardRow.lineHeight(metrics.detail) / 2, maxWidth: rect.width - p * 2)
        }
    }
}
