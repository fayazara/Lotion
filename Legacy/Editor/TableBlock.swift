//
//  TableBlock.swift
//  Lotion
//
//  A pipe table drawn as a block. Its Markdown stays in the note, hidden;
//  the table's first line is laid out as tall as the table, and the table
//  is drawn there. Cells wrap, columns size to their content the way a
//  browser sizes an auto-layout table, and a table wider than the page
//  scrolls sideways by redrawing itself, never by touching the text.
//
//  Cells are measured and drawn with Core Text and kept between restyles,
//  so scrolling and typing next to a table never lay it out again.
//

import AppKit
import CoreText

/// Fonts and spacing shared by every table under one editor style.
struct TableMetrics {
    let body: NSFont
    let header: NSFont
    let palette: ThemePalette
    /// Every cell line is this tall, in the table and in the cell editor.
    let lineHeight: CGFloat
    /// Where the baseline sits in a line, as TextKit places it, so a cell
    /// drawn here and the same cell in the editor line up exactly.
    let bodyBaseline: CGFloat
    let headerBaseline: CGFloat
    let minimumColumn: CGFloat
    private let paragraphs: [NSParagraphStyle]

    static let padding = NSSize(width: 12, height: 8)
    /// Space above and below the grid.
    static let margin: CGFloat = 12
    /// Room under a sideways-scrolling table for its position bar.
    static let indicatorSpace: CGFloat = 10
    static let cornerRadius: CGFloat = 6

    init(body: NSFont, palette: ThemePalette, em: CGFloat) {
        self.body = body
        header = NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask)
        self.palette = palette
        let lineHeight = ceil(MarkdownStyler.lineHeight(body) + round(em * 0.3))
        self.lineHeight = lineHeight
        minimumColumn = round(em * 4)
        paragraphs = [MarkdownTable.Alignment.none, .left, .center, .right].map { alignment in
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = lineHeight
            style.maximumLineHeight = lineHeight
            style.lineBreakMode = .byWordWrapping
            style.alignment = switch alignment {
            case .center: .center
            case .right: .right
            default: .left
            }
            return style
        }
        bodyBaseline = Self.baseline(body, paragraph: paragraphs[0])
        headerBaseline = Self.baseline(header, paragraph: paragraphs[0])
    }

    func paragraphStyle(_ alignment: MarkdownTable.Alignment) -> NSParagraphStyle {
        switch alignment {
        case .none: paragraphs[0]
        case .left: paragraphs[1]
        case .center: paragraphs[2]
        case .right: paragraphs[3]
        }
    }

    private static func baseline(_ font: NSFont, paragraph: NSParagraphStyle) -> CGFloat {
        let storage = NSTextStorage(string: "Xg", attributes: [.font: font, .paragraphStyle: paragraph])
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 1000, height: 1000))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        return layoutManager.location(forGlyphAt: 0).y
    }
}

/// One cell's text as drawn: Markdown marks taken out, styles applied, and
/// its line breaks for the last width asked for.
final class CellContent {
    /// Display text, with Core Text colors.
    let text: NSAttributedString
    /// For each display index (and one past the end), the offset in the cell's Markdown.
    let toSource: [Int]
    /// Width on one line, and of the widest word.
    let maxWidth: CGFloat
    let minWidth: CGFloat

    struct Line {
        let line: CTLine
        let range: NSRange
        let width: CGFloat
    }

    private let typesetter: CTTypesetter
    private var cachedWidth: CGFloat = -1
    private var cachedLines: [Line] = []

    init(_ display: NSAttributedString, toSource: [Int]) {
        let text = NSMutableAttributedString(attributedString: display)
        let whole = NSRange(location: 0, length: text.length)
        let colorKey = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
        display.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            if let color = value as? NSColor { text.addAttribute(colorKey, value: color.cgColor, range: range) }
        }
        self.text = text
        self.toSource = toSource
        typesetter = CTTypesetterCreateWithAttributedString(text)

        let line = CTLineCreateWithAttributedString(text)
        maxWidth = ceil(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line)))
        let characters = text.string as NSString
        var widest: CGFloat = 0
        var start = 0
        func word(to end: Int) {
            guard end > start else { return }
            widest = max(widest, CTLineGetOffsetForStringIndex(line, end, nil) - CTLineGetOffsetForStringIndex(line, start, nil))
        }
        for index in 0..<characters.length {
            let c = characters.character(at: index)
            if c == 32 || c == 9 {
                word(to: index)
                start = index + 1
            }
        }
        word(to: characters.length)
        minWidth = ceil(widest)
    }

    /// The text broken into lines no wider than `width`; a word wider than
    /// that breaks between characters.
    func lines(width: CGFloat) -> [Line] {
        if width == cachedWidth { return cachedLines }
        var lines: [Line] = []
        let length = text.length
        let limit = Double(max(1, width))
        var start = 0
        while start < length {
            var count = CTTypesetterSuggestLineBreak(typesetter, start, limit)
            if count <= 0 { count = max(1, CTTypesetterSuggestClusterBreak(typesetter, start, limit)) }
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
            lines.append(Line(line: line, range: NSRange(location: start, length: count), width: lineWidth))
            start += count
        }
        cachedWidth = width
        cachedLines = lines
        return lines
    }

    /// The display index nearest a point in the cell's content box.
    func index(at point: NSPoint, width: CGFloat, lineHeight: CGFloat, fraction: CGFloat) -> Int {
        let lines = lines(width: width)
        guard !lines.isEmpty else { return 0 }
        let line = lines[min(lines.count - 1, max(0, Int(point.y / lineHeight)))]
        let x = point.x - (width - line.width) * fraction
        let index = CTLineGetStringIndexForPosition(line.line, CGPoint(x: x, y: 0))
        guard index != kCFNotFound else { return line.range.location }
        return min(max(index, line.range.location), NSMaxRange(line.range))
    }

    /// The display range for a range of the cell's Markdown.
    func displayRange(forSource range: NSRange) -> NSRange {
        let start = toSource.firstIndex { $0 >= range.location } ?? text.length
        let end = toSource.firstIndex { $0 >= NSMaxRange(range) } ?? text.length
        return NSRange(location: min(start, text.length), length: max(0, min(end, text.length) - min(start, text.length)))
    }
}

/// The cell being edited, measured as the editor shows it (marks visible)
/// so the table makes room for exactly what the editor draws.
struct CellOverride {
    let row: Int
    let column: Int
    let content: CellContent
    /// The editor's text with its paragraph style, for TextKit's own measure.
    let measured: NSAttributedString
    let version: Int

    func height(width: CGFloat, lineHeight: CGFloat) -> CGFloat {
        guard measured.length > 0 else { return lineHeight }
        let rect = measured.boundingRect(with: NSSize(width: max(1, width), height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin])
        return max(lineHeight, ceil(rect.height - 0.01))
    }
}

/// Where everything in a table sits, from its top-left corner.
struct TableLayout {
    let columnX: [CGFloat]
    let columnWidths: [CGFloat]
    let rowY: [CGFloat]
    let rowHeights: [CGFloat]
    /// The whole grid, which may be wider than the page.
    let width: CGFloat
    let height: CGFloat
    let available: CGFloat

    var overflow: CGFloat { max(0, width - available) }
    var visibleWidth: CGFloat { min(width, available) }
    /// The height the table's first line takes in the note.
    var blockHeight: CGFloat { TableMetrics.margin * 2 + height + (overflow > 0 ? TableMetrics.indicatorSpace : 0) }

    func cellRect(row: Int, column: Int) -> NSRect {
        NSRect(x: columnX[column], y: rowY[row], width: columnWidths[column], height: rowHeights[row])
    }

    func contentRect(row: Int, column: Int) -> NSRect {
        cellRect(row: row, column: column).insetBy(dx: TableMetrics.padding.width, dy: TableMetrics.padding.height)
    }

    func row(atY y: CGFloat) -> Int {
        var row = 0
        while row + 1 < rowY.count, rowY[row + 1] <= y { row += 1 }
        return row
    }

    func column(atX x: CGFloat) -> Int {
        var column = 0
        while column + 1 < columnX.count, columnX[column + 1] <= x { column += 1 }
        return column
    }
}

final class TableBlock {
    /// Display rows, the header first, each as wide as the widest.
    let rows: [[CellContent]]
    /// Each cell's Markdown, relative to where the table starts; nil for a
    /// cell a short row doesn't have.
    let cellRanges: [[NSRange?]]
    /// Every line of the table (separator included), relative to its start.
    let lines: [NSRange]
    let alignments: [MarkdownTable.Alignment]
    let metrics: TableMetrics
    /// The Markdown it was built from, to tell when it needs building again.
    let source: String
    let generation: Int
    var columnCount: Int { alignments.count }

    private var cached: (available: CGFloat, override: Int?, layout: TableLayout)?

    init(rows: [[CellContent]], cellRanges: [[NSRange?]], lines: [NSRange], alignments: [MarkdownTable.Alignment],
         metrics: TableMetrics, source: String, generation: Int) {
        self.rows = rows
        self.cellRanges = cellRanges
        self.lines = lines
        self.alignments = alignments
        self.metrics = metrics
        self.source = source
        self.generation = generation
    }

    /// The display row a table line shows; the separator counts as the first body row.
    func row(forLine line: Int) -> Int {
        switch line {
        case 0: 0
        case 1: min(1, rows.count - 1)
        default: min(rows.count - 1, line - 1)
        }
    }

    /// The cell holding `offset` (relative to the table's start), and where in its Markdown.
    func cell(at offset: Int) -> (row: Int, column: Int, offset: Int) {
        let line = lines.lastIndex { $0.location <= offset } ?? 0
        let row = row(forLine: line)
        let ranges = cellRanges[row]
        let column = ranges.lastIndex { ($0?.location ?? .max) <= offset } ?? 0
        guard let range = ranges[column] else { return (row, column, 0) }
        return (row, column, min(max(0, offset - range.location), range.length))
    }

    func fraction(_ column: Int) -> CGFloat {
        switch alignments[column] {
        case .center: 0.5
        case .right: 1
        default: 0
        }
    }

    // MARK: Layout

    func layout(available: CGFloat, override: CellOverride?) -> TableLayout {
        let available = max(120, available)
        if let cached, cached.available == available, cached.override == override?.version { return cached.layout }
        let layout = makeLayout(available: available, override: override)
        cached = (available, override?.version, layout)
        return layout
    }

    private func content(_ row: Int, _ column: Int, _ override: CellOverride?) -> CellContent {
        if let override, override.row == row, override.column == column { return override.content }
        return rows[row][column]
    }

    /// Columns take their content's width when the table fits. Otherwise
    /// columns whose text fits a fair share of the page keep it on one line,
    /// and the rest share what's left, wrapping. When even the widest words
    /// don't fit, the table is wider than the page and scrolls.
    private func makeLayout(available: CGFloat, override: CellOverride?) -> TableLayout {
        let padding = TableMetrics.padding
        let columns = columnCount
        var minimum = [CGFloat](repeating: metrics.minimumColumn, count: columns)
        var maximum = minimum
        for row in rows.indices {
            for column in 0..<columns {
                let cell = content(row, column, override)
                minimum[column] = max(minimum[column], cell.minWidth + padding.width * 2)
                maximum[column] = max(maximum[column], cell.maxWidth + padding.width * 2)
            }
        }
        // One long word or URL shouldn't make a column wider than most of the page.
        let cap = max(metrics.minimumColumn, round(available * 0.6))
        for column in 0..<columns {
            minimum[column] = min(minimum[column], max(cap, metrics.minimumColumn))
            maximum[column] = max(maximum[column], minimum[column])
        }
        let sumMinimum = minimum.reduce(0, +), sumMaximum = maximum.reduce(0, +)
        var widths: [CGFloat]
        if sumMaximum <= available {
            widths = maximum
        } else if sumMinimum >= available {
            widths = minimum
        } else {
            widths = minimum
            var flexible = Array(0..<columns)
            var remaining = available
            while !flexible.isEmpty {
                let share = remaining / CGFloat(flexible.count)
                let fitting = flexible.filter { maximum[$0] <= share }
                guard !fitting.isEmpty else { break }
                for column in fitting {
                    widths[column] = maximum[column]
                    remaining -= maximum[column]
                }
                flexible.removeAll { fitting.contains($0) }
            }
            let flexMinimum = flexible.reduce(0) { $0 + minimum[$1] }, flexMaximum = flexible.reduce(0) { $0 + maximum[$1] }
            if !flexible.isEmpty, remaining >= flexMinimum, flexMaximum > flexMinimum {
                let share = min(1, (remaining - flexMinimum) / (flexMaximum - flexMinimum))
                for column in flexible { widths[column] = minimum[column] + (maximum[column] - minimum[column]) * share }
            } else if remaining < flexMinimum {
                // Fitted columns took too much; share the page out evenly by need instead.
                let share = (available - sumMinimum) / (sumMaximum - sumMinimum)
                widths = (0..<columns).map { minimum[$0] + (maximum[$0] - minimum[$0]) * share }
            }
        }
        widths = widths.map { floor($0) }
        if sumMaximum > available, sumMinimum < available {
            // Rounding down leaves a sliver; the last column takes it so the grid meets the page edge.
            widths[columns - 1] += available - widths.reduce(0, +)
        }

        var columnX: [CGFloat] = []
        var x: CGFloat = 0
        for width in widths {
            columnX.append(x)
            x += width
        }

        var rowY: [CGFloat] = []
        var rowHeights: [CGFloat] = []
        var y: CGFloat = 0
        for row in rows.indices {
            var height = metrics.lineHeight
            for column in 0..<columns {
                let width = widths[column] - padding.width * 2
                if let override, override.row == row, override.column == column {
                    height = max(height, override.height(width: width, lineHeight: metrics.lineHeight))
                } else {
                    let lines = rows[row][column].lines(width: width).count
                    height = max(height, CGFloat(max(1, lines)) * metrics.lineHeight)
                }
            }
            height += padding.height * 2
            rowY.append(y)
            rowHeights.append(height)
            y += height
        }
        return TableLayout(columnX: columnX, columnWidths: widths, rowY: rowY, rowHeights: rowHeights,
                           width: x, height: y, available: available)
    }

    // MARK: Drawing

    enum Highlight {
        /// The selection runs through the table.
        case all
        /// The selection is inside one cell (a find result, say).
        case cell(row: Int, column: Int, range: NSRange)
    }

    /// Draws the grid with its top-left at `origin`, scrolled `offset` sideways.
    func draw(_ layout: TableLayout, at origin: NSPoint, offset: CGFloat, editing: (row: Int, column: Int)?,
              highlight: Highlight?, clip: NSRect) {
        let palette = metrics.palette
        let frame = NSRect(x: origin.x, y: origin.y, width: layout.visibleWidth, height: layout.height)
        guard frame.insetBy(dx: -2, dy: -2 - TableMetrics.indicatorSpace).intersects(clip),
              let context = NSGraphicsContext.current?.cgContext else { return }
        let radius = TableMetrics.cornerRadius
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        palette.codeBackground.setFill()
        NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: layout.rowHeights[0]).fill()
        if case .all = highlight {
            palette.selection.setFill()
            frame.fill()
        }

        palette.rule.setFill()
        for row in 1..<max(1, rows.count) {
            NSRect(x: frame.minX, y: round(origin.y + layout.rowY[row]) - 0.5, width: frame.width, height: 1).fill()
        }
        for column in 1..<max(1, columnCount) {
            let x = round(origin.x - offset + layout.columnX[column]) - 0.5
            if x > frame.minX, x < frame.maxX { NSRect(x: x, y: frame.minY, width: 1, height: frame.height).fill() }
        }

        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        for row in rows.indices {
            let top = origin.y + layout.rowY[row]
            guard top <= clip.maxY, top + layout.rowHeights[row] >= clip.minY else { continue }
            for column in 0..<columnCount {
                let x = origin.x - offset + layout.columnX[column]
                guard x <= frame.maxX, x + layout.columnWidths[column] >= frame.minX else { continue }
                if let editing, editing.row == row, editing.column == column { continue }
                var range: NSRange?
                if case .cell(row, column, let selected) = highlight { range = selected }
                drawCell(row, column, layout: layout, origin: NSPoint(x: origin.x - offset, y: origin.y),
                         selection: range, context: context)
            }
        }
        context.textMatrix = .identity
        context.restoreGState()

        if let editing, editing.row < rows.count, editing.column < columnCount {
            // The cell being edited gets a quiet accent edge.
            // Inset and rounded so it sits inside the table's own rounded corners.
            let cell = layout.cellRect(row: editing.row, column: editing.column)
                .offsetBy(dx: origin.x - offset, dy: origin.y).insetBy(dx: 2, dy: 2)
            let radius = TableMetrics.cornerRadius - 1.5
            let ring = NSBezierPath(roundedRect: cell, xRadius: radius, yRadius: radius)
            ring.lineWidth = 1.5
            palette.accent.withAlphaComponent(0.75).setStroke()
            ring.stroke()
        }

        if layout.overflow > 0 {
            // Fades where the grid runs on past the page.
            let fade: CGFloat = 18
            let clear = palette.background.withAlphaComponent(0), solid = palette.background.withAlphaComponent(0.92)
            if offset < layout.overflow {
                NSGradient(starting: clear, ending: solid)?
                    .draw(in: NSRect(x: frame.maxX - fade, y: frame.minY, width: fade, height: frame.height), angle: 0)
            }
            if offset > 0 {
                NSGradient(starting: solid, ending: clear)?
                    .draw(in: NSRect(x: frame.minX, y: frame.minY, width: fade, height: frame.height), angle: 0)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        palette.codeBorder.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        if layout.overflow > 0 {
            // Where the visible part sits in the whole width.
            let bar = max(28, frame.width * frame.width / layout.width)
            let travel = frame.width - bar
            let progress = min(1, max(0, offset / layout.overflow))
            palette.marker.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: NSRect(x: frame.minX + travel * progress, y: frame.maxY + 5, width: bar, height: 3),
                         xRadius: 1.5, yRadius: 1.5).fill()
        }
    }

    private func drawCell(_ row: Int, _ column: Int, layout: TableLayout, origin: NSPoint, selection: NSRange?, context: CGContext) {
        let content = rows[row][column]
        guard content.text.length > 0 else { return }
        let box = layout.contentRect(row: row, column: column).offsetBy(dx: origin.x, dy: origin.y)
        let baselineOffset = row == 0 ? metrics.headerBaseline : metrics.bodyBaseline
        let fraction = fraction(column)
        let palette = metrics.palette
        for (index, line) in content.lines(width: box.width).enumerated() {
            let top = box.minY + CGFloat(index) * metrics.lineHeight
            let baseline = top + baselineOffset
            let x = box.minX + (box.width - line.width) * fraction
            func span(_ range: NSRange) -> (CGFloat, CGFloat)? {
                let piece = NSIntersectionRange(range, line.range)
                guard piece.length > 0 else { return nil }
                return (x + CTLineGetOffsetForStringIndex(line.line, piece.location, nil),
                        x + CTLineGetOffsetForStringIndex(line.line, NSMaxRange(piece), nil))
            }
            if let selection, let (left, right) = span(selection) {
                palette.selection.setFill()
                NSRect(x: left, y: top, width: right - left, height: metrics.lineHeight).fill()
            }
            content.text.enumerateAttribute(.lotionInlineCode, in: line.range) { value, range, _ in
                guard value != nil, let (left, right) = span(range) else { return }
                let font = content.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? metrics.body
                let chip = NSRect(x: left - 3, y: baseline - font.ascender - 2, width: right - left + 6,
                                  height: font.ascender - font.descender + 4)
                palette.inlineCode.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 5, yRadius: 5).fill()
            }
            context.textPosition = CGPoint(x: x, y: baseline)
            CTLineDraw(line.line, context)
            content.text.enumerateAttribute(.strikethroughStyle, in: line.range) { value, range, _ in
                guard value != nil, let (left, right) = span(range) else { return }
                let font = content.text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? metrics.body
                palette.secondary.setFill()
                NSRect(x: left, y: round(baseline - font.xHeight / 2) - 0.5, width: right - left, height: 1).fill()
            }
        }
    }
}
