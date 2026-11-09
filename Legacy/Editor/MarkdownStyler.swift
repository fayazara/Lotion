//
//  MarkdownStyler.swift
//  Lotion
//
//  Styles Markdown in place: the text stays exactly what is on disk, and
//  attributes carry the look. Syntax marks are hidden: block marks (`#`,
//  list markers, `>`) always, inline marks and fences unless the selection
//  touches their span (`reveal`). Drawing-only attributes tell
//  EditorLayoutManager where to paint code blocks, quote bars, rules,
//  bullets and checkboxes.
//
//  Edits restyle only the blocks they touch. Adding or removing a fence can
//  change every block after it, so that restyles the whole note.
//

import AppKit

extension NSAttributedString.Key {
    /// A `BlockDecoration` spanning a code block, quote or rule.
    static let lotionBlock = NSAttributedString.Key("lotionBlock")
    /// Inline code, drawn on a rounded chip.
    static let lotionInlineCode = NSAttributedString.Key("lotionInlineCode")
    /// A task's hidden `- [ ]`; the value is whether it is checked.
    static let lotionTask = NSAttributedString.Key("lotionTask")
    /// A hidden bullet marker, drawn as a dot.
    static let lotionBullet = NSAttributedString.Key("lotionBullet")
    /// A link target, opened with ⌘-click.
    static let lotionURL = NSAttributedString.Key("lotionURL")
    /// A line's block marks and indent, which the caret never stops inside.
    static let lotionPrefix = NSAttributedString.Key("lotionPrefix")
    /// Marks showing because the selection touches them (hidden ones carry
    /// `lotionHidden`); code blocks carry it throughout.
    static let lotionRevealable = NSAttributedString.Key("lotionRevealable")
    /// Hidden marks: EditorLayoutManager lays them out as null glyphs, taking no space.
    static let lotionHidden = NSAttributedString.Key("lotionHidden")
    /// Code lines past a block's height: laid out as zero-height lines.
    static let lotionCollapsed = NSAttributedString.Key("lotionCollapsed")
    /// On the first character of each code line: its number.
    static let lotionLineNumber = NSAttributedString.Key("lotionLineNumber")
    /// On a code block's closing fence: a `CodeHandle` for resizing the block.
    static let lotionCodeHandle = NSAttributedString.Key("lotionCodeHandle")
    /// A table's Markdown, laid out as null glyphs: the table is drawn from
    /// its `TableBlock` instead.
    static let lotionTableText = NSAttributedString.Key("lotionTableText")
}

/// One instance per block, so neighbouring blocks never merge into one run.
final class BlockDecoration: NSObject {
    enum Kind { case code, quote, rule, table }
    let kind: Kind
    /// A code block's header and number column.
    let code: CodeHeader?
    /// A table's cells and how to lay them out. An edit inside the table
    /// swaps in a new one, leaving the text's attributes as they are.
    var table: TableBlock?
    init(_ kind: Kind, code: CodeHeader? = nil, table: TableBlock? = nil) {
        self.kind = kind
        self.code = code
        self.table = table
    }
}

struct CodeHeader {
    /// The fence's `title="…"`, or nil.
    var title: String?
    var language: String?
    /// Drawn in place of the fences while they are hidden.
    var showsHeader: Bool
    /// Width of the line-number column.
    var numberWidth: CGFloat
    /// Lines folded away below the block's height.
    var hiddenLines: Int
    var isResizable: Bool
    /// Whether a closing fence ends the block.
    var isClosed: Bool
}

/// What dragging a code block's bottom edge needs to know.
final class CodeHandle: NSObject {
    let fenceLocation: Int
    let lineCount: Int
    let visibleLines: Int
    let lineHeight: CGFloat
    init(fenceLocation: Int, lineCount: Int, visibleLines: Int, lineHeight: CGFloat) {
        self.fenceLocation = fenceLocation
        self.lineCount = lineCount
        self.visibleLines = visibleLines
        self.lineHeight = lineHeight
    }
}

final class MarkdownStyler {
    private(set) var style: EditorStyle
    private(set) var palette: ThemePalette
    private(set) var fonts: Fonts
    /// The left gutter heading marks hang into; the text column starts after it.
    private(set) var gutter: CGFloat = 52

    /// The selection, while the editor has focus: marks touching it show.
    var reveal: NSRange?
    /// Heights being dragged, by the location of the block's opening fence.
    var previewLines: [Int: Int] = [:]
    /// Table fonts and spacing for the current style.
    private(set) var tableMetrics: TableMetrics
    /// Counts style changes, so tables built under an old style rebuild.
    private var generation = 0
    /// Cells already styled, by their Markdown, so editing one cell of a
    /// big table restyles only that cell.
    private var cellCache: [String: CellContent] = [:]
    static let defaultCodeLines = 15
    static let minimumCodeLines = 3
    private var lastFenceLines = -1
    private var listStyles: [CGFloat: NSParagraphStyle] = [:]

    struct Fonts {
        let body: NSFont
        let headings: [NSFont]
        let code: NSFont
        let inlineCode: NSFont
        let bodyLineSpacing: CGFloat
        let codeLineSpacing: CGFloat
        let blankLineHeight: CGFloat
        let em: CGFloat
    }

    init(style: EditorStyle) {
        self.style = style
        palette = style.palette
        fonts = Self.makeFonts(style)
        gutter = Self.gutter(for: fonts)
        tableMetrics = TableMetrics(body: fonts.body, palette: palette, em: fonts.em)
    }

    func update(style newStyle: EditorStyle) {
        guard newStyle != style else { return }
        style = newStyle
        palette = newStyle.palette
        fonts = Self.makeFonts(newStyle)
        gutter = Self.gutter(for: fonts)
        tableMetrics = TableMetrics(body: fonts.body, palette: palette, em: fonts.em)
        generation += 1
        cellCache = [:]
        listStyles = [:]
        cachedStyles = [:]
        codeStyles = [:]
        lastFenceLines = -1
    }

    private static func gutter(for fonts: Fonts) -> CGFloat {
        ceil(max(44, fonts.em * 3.4))
    }

    private static func makeFonts(_ style: EditorStyle) -> Fonts {
        let size = style.noteFontSize
        let body = FontChoice.font(style.noteFont, size: size)
        let scales: [CGFloat] = [2.1, 1.45, 1.2, 1.07, 1.0, 1.0]
        let headings = scales.enumerated().map { index, scale in
            FontChoice.font(style.noteFont, size: round(size * scale), weight: index < 2 ? .bold : .semibold)
        }
        let code = FontChoice.font(style.codeFont, size: round(size * 0.87 * 2) / 2)
        let inlineCode = FontChoice.font(style.codeFont, size: round(size * 0.88 * 2) / 2)
        let bodyHeight = lineHeight(body)
        let codeHeight = lineHeight(code)
        return Fonts(
            body: body,
            headings: headings,
            code: code,
            inlineCode: inlineCode,
            bodyLineSpacing: max(0, round(size * style.lineSpacing.multiple - bodyHeight)),
            codeLineSpacing: max(0, round(code.pointSize * 1.55 - codeHeight)),
            blankLineHeight: round(bodyHeight * 0.7),
            em: size
        )
    }

    private let hidden: [NSAttributedString.Key: Any] = [.lotionHidden: true]
    private var revealedMark: [NSAttributedString.Key: Any] { [.foregroundColor: palette.marker, .lotionRevealable: true] }

    /// Whether the selection touches `range`, ends included.
    private func isRevealed(_ range: NSRange) -> Bool {
        guard let reveal else { return false }
        return reveal.location <= NSMaxRange(range) && NSMaxRange(reveal) >= range.location
    }

    private static let measuringLayoutManager = NSLayoutManager()
    static func lineHeight(_ font: NSFont) -> CGFloat {
        measuringLayoutManager.defaultLineHeight(for: font)
    }

    /// The attributes new text starts with.
    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: fonts.body, .foregroundColor: palette.text, .paragraphStyle: paragraph(.body)]
    }

    // MARK: Styling

    /// Restyles `storage`. With an `edited` range, only blocks near it are
    /// restyled, unless the note's fences changed.
    func restyle(_ storage: NSTextStorage, edited: NSRange?) {
        let text = storage.string as NSString
        let (blocks, fenceLines) = MarkdownScanner.scan(text)
        var dirty = NSRange(location: 0, length: text.length)
        if let edited, fenceLines == lastFenceLines {
            // One line of context on each side catches quotes and tables
            // that an edit joined or split.
            let start = text.lineRange(for: NSRange(location: max(0, edited.location - 1), length: 0)).location
            let endProbe = min(text.length, NSMaxRange(edited) + 1)
            let end = NSMaxRange(text.lineRange(for: NSRange(location: endProbe, length: 0)))
            dirty = NSRange(location: start, length: max(0, end - start))
        }
        lastFenceLines = fenceLines

        for block in blocks {
            let range = block.range
            if NSMaxRange(range) < dirty.location { continue }
            if range.location > NSMaxRange(dirty) { break }
            apply(block, to: storage, text: text)
        }
    }

    private func apply(_ block: MarkdownBlock, to storage: NSTextStorage, text: NSString) {
        let range = block.range
        switch block.kind {
        case .blank:
            storage.setAttributes([.font: fonts.body, .foregroundColor: palette.text, .paragraphStyle: paragraph(.blank)], range: range)

        case .paragraph:
            storage.setAttributes(typingAttributes, range: range)
            styleInline(storage, text: text, range: range)

        case .heading(let level, let marker):
            let font = fonts.headings[level - 1]
            storage.setAttributes([
                .font: font,
                .foregroundColor: level == 6 ? palette.secondary : palette.text,
                .paragraphStyle: headingParagraph(level: level, atTop: range.location == 0),
            ], range: range)
            // A bare `#` is still being typed; it hides once a space follows.
            let last = marker.length > 0 ? text.character(at: NSMaxRange(marker) - 1) : 0
            if last == 32 || last == 9 {
                storage.addAttributes([.lotionHidden: true, .lotionPrefix: true], range: marker)
            } else {
                storage.addAttribute(.foregroundColor, value: palette.marker, range: marker)
            }
            styleInline(storage, text: text, range: NSRange(location: NSMaxRange(marker), length: NSMaxRange(range) - NSMaxRange(marker)))

        case .quote(let markers):
            let decoration = BlockDecoration(.quote)
            storage.setAttributes([
                .font: fonts.body, .foregroundColor: palette.secondary,
                .paragraphStyle: paragraph(.body), .lotionBlock: decoration,
            ], range: range)
            for marker in markers {
                let width = (text.substring(with: marker) as NSString).size(withAttributes: [.font: fonts.body]).width
                let line = text.paragraphRange(for: marker)
                storage.addAttribute(.paragraphStyle, value: hangingParagraph(markerWidth: width), range: line)
                storage.addAttributes([.foregroundColor: NSColor.clear, .lotionPrefix: true], range: marker)
            }
            styleInline(storage, text: text, range: range)

        case .listItem(let indent, let marker, let ordered, let task, let checked, let content):
            styleListItem(storage, text: text, range: range, indent: indent, marker: marker,
                          ordered: ordered, task: task, checked: checked, content: content)

        case .rule:
            storage.setAttributes([
                .font: fonts.body, .foregroundColor: NSColor.clear,
                .paragraphStyle: paragraph(.body), .lotionBlock: BlockDecoration(.rule),
            ], range: range)

        case .code(let language, let openFence, let closeFence, let content):
            styleCode(storage, text: text, range: range, language: language, openFence: openFence, closeFence: closeFence, content: content)

        case .table(let separator):
            styleTable(storage, text: text, range: range, separator: separator)
        }
    }

    // MARK: Tables

    /// A table's Markdown lays out as null glyphs, its first line as tall as
    /// the table (see EditorLayoutManager), and the table is drawn from a
    /// `TableBlock`. An unchanged table keeps the block it has, so edits
    /// around it never rebuild or re-lay it out.
    private func styleTable(_ storage: NSTextStorage, text: NSString, range: NSRange, separator: NSRange) {
        let source = text.substring(with: range)
        var existingRange = NSRange(), textRange = NSRange()
        let decoration = storage.attribute(.lotionBlock, at: range.location, longestEffectiveRange: &existingRange,
                                           in: NSRange(location: 0, length: storage.length)) as? BlockDecoration
        let isTableText = storage.attribute(.lotionTableText, at: range.location, longestEffectiveRange: &textRange, in: range) != nil
        let canReuse = decoration?.table?.generation == generation && existingRange == range && isTableText && textRange == range
        if canReuse, decoration?.table?.source == source { return }

        var lines: [NSRange] = []
        var index = range.location
        while index < NSMaxRange(range) {
            var line = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(line)
            if line.length > 0, text.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
            lines.append(line)
        }
        let separatorLine = lines.firstIndex { NSIntersectionRange($0, separator).length > 0 || $0.location == separator.location } ?? 1
        var alignments = MarkdownTable.alignments(text.substring(with: separator))
        var cellRanges: [[NSRange?]] = []
        for (number, line) in lines.enumerated() where number != separatorLine {
            cellRanges.append(MarkdownTable.cellRanges(in: text, line: line).map {
                NSRange(location: $0.location - range.location, length: $0.length)
            })
        }
        let columns = max(1, alignments.count, cellRanges.map(\.count).max() ?? 0)
        alignments += Array(repeating: .none, count: max(0, columns - alignments.count))
        alignments = Array(alignments.prefix(columns))
        let rows: [[CellContent]] = cellRanges.enumerated().map { row, ranges in
            (0..<columns).map { column in
                guard column < ranges.count, let relative = ranges[column] else { return tableCell("", header: row == 0) }
                return tableCell((source as NSString).substring(with: relative), header: row == 0)
            }
        }
        cellRanges = cellRanges.map { $0 + Array(repeating: nil, count: max(0, columns - $0.count)) }
        let block = TableBlock(rows: rows, cellRanges: cellRanges,
                               lines: lines.map { NSRange(location: $0.location - range.location, length: $0.length) },
                               alignments: alignments, metrics: tableMetrics, source: source, generation: generation)
        if canReuse, let decoration {
            // Typing in a cell: its text already has the table's attributes,
            // so swap in the new cells and leave the layout alone. The editor
            // lays out the first line again only if the table's height changed
            // (EditorTextView.refreshTable), which re-laying every hidden row
            // of a big table on each keystroke would make slow.
            decoration.table = block
            return
        }
        // Clear: the first character stays a glyph (see EditorLayoutManager).
        storage.setAttributes([
            .font: fonts.body, .foregroundColor: NSColor.clear, .paragraphStyle: paragraph(.table),
            .lotionBlock: BlockDecoration(.table, table: block), .lotionTableText: true,
        ], range: range)
    }

    /// One cell's Markdown, styled and with its marks taken out.
    func tableCell(_ source: String, header: Bool) -> CellContent {
        let key = (header ? "H" : "B") + source
        if let cached = cellCache[key] { return cached }
        let styled = inlineStyled(source, font: header ? tableMetrics.header : tableMetrics.body, revealAll: false)
        let ns = source as NSString
        let escapes = Set(MarkdownTable.escapedPipes(in: ns, line: NSRange(location: 0, length: ns.length)).map { $0 - 1 })
        let display = NSMutableAttributedString()
        var toSource: [Int] = []
        func keep(_ from: Int, _ to: Int) {
            guard to > from else { return }
            display.append(styled.attributedSubstring(from: NSRange(location: from, length: to - from)))
            toSource.append(contentsOf: from..<to)
        }
        styled.enumerateAttribute(.lotionHidden, in: NSRange(location: 0, length: styled.length)) { value, range, _ in
            guard value == nil else { return }
            var start = range.location
            for index in range.location..<NSMaxRange(range) where escapes.contains(index) {
                keep(start, index)
                start = index + 1
            }
            keep(start, NSMaxRange(range))
        }
        toSource.append(ns.length)
        let content = CellContent(display, toSource: toSource)
        if cellCache.count > 5000 { cellCache = [:] }
        cellCache[key] = content
        return content
    }

    /// `source` with its inline Markdown styled: marks hidden, or all shown (for the cell editor).
    func inlineStyled(_ source: String, font: NSFont, revealAll: Bool) -> NSMutableAttributedString {
        let styled = NSMutableAttributedString(string: source, attributes: [.font: font, .foregroundColor: palette.text])
        let whole = NSRange(location: 0, length: styled.length)
        let saved = reveal
        reveal = revealAll ? whole : nil
        styleInline(styled, text: source as NSString, range: whole)
        reveal = saved
        return styled
    }

    // MARK: Lists

    private func styleListItem(_ storage: NSTextStorage, text: NSString, range: NSRange, indent: NSRange, marker: NSRange,
                               ordered: Bool, task: NSRange?, checked: Bool, content: Int) {
        let font = fonts.body
        let em = fonts.em
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        // Each leading space indents by a fixed step, so nested items line up
        // under their parent's text whatever the font.
        let indentStep = round(em * 0.65)
        var indentWidth: CGFloat = 0
        for i in 0..<indent.length {
            let isTab = text.character(at: indent.location + i) == 9
            indentWidth += isTab ? indentStep * 2 : indentStep
        }

        // The marker, the task box and the spaces after them take a fixed width.
        let prefix = NSRange(location: marker.location, length: content - marker.location)
        let prefixText = text.substring(with: prefix) as NSString
        let natural = prefixText.size(withAttributes: [.font: font]).width
        var prefixTarget: CGFloat = ordered ? 0 : round(em * 1.3)
        if let task {
            // Measure as if checked, so checked and unchecked items line up.
            let box = NSRange(location: task.location - prefix.location + 1, length: 1)
            let checkedWidth = prefixText.replacingCharacters(in: box, with: "x").size(withAttributes: [.font: font]).width
            prefixTarget = ceil(max(em * 1.95, checkedWidth))
        }
        let prefixWidth = prefixTarget > 0 ? max(prefixTarget, natural) : natural

        storage.setAttributes([
            .font: font, .foregroundColor: palette.text,
            .paragraphStyle: listParagraph(headIndent: indentWidth + prefixWidth),
        ], range: range)

        if indent.length > 0 {
            for i in 0..<indent.length {
                let isTab = text.character(at: indent.location + i) == 9
                let target = isTab ? indentStep * 2 : indentStep
                let width = isTab ? (text.substring(with: NSRange(location: indent.location + i, length: 1)) as NSString).size(withAttributes: [.font: font]).width : spaceWidth
                storage.addAttribute(.kern, value: target - width, range: NSRange(location: indent.location + i, length: 1))
            }
        }
        if prefixTarget > 0, prefix.length > 0, prefixWidth > natural {
            storage.addAttribute(.kern, value: prefixWidth - natural, range: NSRange(location: NSMaxRange(prefix) - 1, length: 1))
        }

        storage.addAttribute(.lotionPrefix, value: true, range: NSRange(location: range.location, length: content - range.location))
        if let task {
            let hidden = NSRange(location: marker.location, length: NSMaxRange(task) - marker.location)
            storage.addAttributes([.foregroundColor: NSColor.clear, .lotionTask: checked], range: hidden)
            if checked {
                let body = NSRange(location: content, length: NSMaxRange(range) - content)
                storage.addAttributes([
                    .foregroundColor: palette.secondary,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: palette.marker,
                ], range: body)
            }
        } else if ordered {
            storage.addAttribute(.foregroundColor, value: palette.accent, range: marker)
        } else {
            storage.addAttributes([.foregroundColor: NSColor.clear, .lotionBullet: true], range: marker)
        }
        styleInline(storage, text: text, range: NSRange(location: content, length: NSMaxRange(range) - content))
    }

    // MARK: Code

    private func styleCode(_ storage: NSTextStorage, text: NSString, range: NSRange, language: String?,
                           openFence: NSRange, closeFence: NSRange?, content: NSRange) {
        // Colors from the last highlight stay until the new ones are ready.
        var previous: [(NSRange, NSColor)] = []
        let highlighter = CodeHighlighter.shared
        let supported = highlighter.supportedLanguage(language)
        let code = text.substring(with: content)
        let runs = supported.flatMap { highlighter.runs(for: code, language: $0, theme: palette.shikiTheme) }
        if supported != nil, runs == nil, content.length > 0,
           storage.attribute(.lotionBlock, at: content.location, effectiveRange: nil) is BlockDecoration {
            storage.enumerateAttribute(.foregroundColor, in: content) { value, subrange, _ in
                if let color = value as? NSColor { previous.append((subrange, color)) }
            }
        }

        // Fences show while the selection is in the block; otherwise a header
        // (title and language) takes the opening fence's place. A block longer
        // than its height (`lines=N` on the fence, or the default) scrolls in
        // a viewport of that height (CodeBlockViews.swift).
        let revealed = isRevealed(range)
        let fenceColor = revealed ? palette.marker : NSColor.clear
        let info = Self.fenceInfo(text.substring(with: openFence))
        var lineStarts: [Int] = []
        var index = content.location
        while index < NSMaxRange(content) {
            lineStarts.append(index)
            index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
        }
        let isResizable = closeFence != nil && lineStarts.count > Self.minimumCodeLines
        let wanted = previewLines[openFence.location] ?? info.lines ?? Self.defaultCodeLines
        let visible = min(lineStarts.count, max(Self.minimumCodeLines, wanted))
        let scrolls = isResizable && visible < lineStarts.count
        let numberWidth = codeNumberWidth(lines: lineStarts.count)
        let header = CodeHeader(title: info.title, language: language, showsHeader: !revealed, numberWidth: numberWidth,
                                hiddenLines: 0, isResizable: isResizable, isClosed: closeFence != nil)
        storage.setAttributes([
            .font: fonts.code, .foregroundColor: palette.text, .paragraphStyle: codeParagraph(numberWidth),
            .lotionBlock: BlockDecoration(.code, code: header), .lotionRevealable: true,
        ], range: range)
        let openLine = text.paragraphRange(for: openFence)
        storage.addAttributes([.foregroundColor: fenceColor, .paragraphStyle: paragraph(.codeOpen)], range: openLine)
        if let closeFence {
            let closeLine = text.paragraphRange(for: closeFence)
                        // Hidden, the closing fence's row is the block's bottom edge, or its resize handle.
            let closeStyle: ParagraphKind = revealed ? .codeClose : isResizable ? .codeHandle : .codeEdge
            storage.addAttributes([.foregroundColor: fenceColor, .paragraphStyle: paragraph(closeStyle)], range: closeLine)
            if isResizable {
                storage.addAttribute(.lotionCodeHandle, value: CodeHandle(
                    fenceLocation: openFence.location, lineCount: lineStarts.count, visibleLines: visible,
                    lineHeight: Self.lineHeight(fonts.code) + fonts.codeLineSpacing), range: closeLine)
            }
        } else if content.length > 0 {
            // An unclosed block still gets its bottom padding on its last line.
            let lastLine = text.paragraphRange(for: NSRange(location: NSMaxRange(content) - 1, length: 0))
            storage.addAttribute(.paragraphStyle, value: paragraph(.codeClose), range: lastLine)
        }
        if scrolls {
            storage.addAttribute(.lotionCodeViewport, value: CodeViewport(
                visibleLines: visible, lineHeight: Self.lineHeight(fonts.code) + fonts.codeLineSpacing,
                numberWidth: numberWidth, paragraph: codeParagraph(numberWidth)), range: content)
        } else {
            for (number, start) in lineStarts.enumerated() {
                storage.addAttribute(.lotionLineNumber, value: number + 1, range: NSRange(location: start, length: 1))
            }
        }

        if let runs {
            var italic: NSFont?, bold: NSFont?
            for run in runs {
                let target = NSRange(location: content.location + run.location, length: run.length)
                guard NSMaxRange(target) <= NSMaxRange(content) else { continue }
                if let hex = run.color, let color = highlighter.color(hex) {
                    storage.addAttribute(.foregroundColor, value: color, range: target)
                }
                if run.italic {
                    italic = italic ?? NSFontManager.shared.convert(fonts.code, toHaveTrait: .italicFontMask)
                    storage.addAttribute(.font, value: italic!, range: target)
                } else if run.bold {
                    bold = bold ?? NSFontManager.shared.convert(fonts.code, toHaveTrait: .boldFontMask)
                    storage.addAttribute(.font, value: bold!, range: target)
                }
            }
        } else {
            for (subrange, color) in previous where NSMaxRange(subrange) <= NSMaxRange(content) {
                storage.addAttribute(.foregroundColor, value: color, range: subrange)
            }
        }
    }

    /// `title="…"` and `lines=N` from a fence's info string.
    static func fenceInfo(_ line: String) -> (title: String?, lines: Int?) {
        let ns = line as NSString
        let whole = NSRange(location: 0, length: ns.length)
        let title = titlePattern.firstMatch(in: line, range: whole).map { match in
            ns.substring(with: match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2))
        }
        let lines = linesPattern.firstMatch(in: line, range: whole).flatMap { Int(ns.substring(with: $0.range(at: 1))) }
        return (title, lines)
    }

    private static let titlePattern = try! NSRegularExpression(pattern: #"\btitle=(?:"([^"]*)"|(\S+))"#)
    static let linesPattern = try! NSRegularExpression(pattern: #"\s*\blines=(\d+)"#)

    private var codeStyles: [CGFloat: NSParagraphStyle] = [:]

    private func codeNumberWidth(lines: Int) -> CGFloat {
        let digit = ("0" as NSString).size(withAttributes: [.font: fonts.code]).width
        return ceil(digit * CGFloat(max(2, String(lines).count))) + 18
    }

    /// Code lines start after the number column.
    private func codeParagraph(_ numberWidth: CGFloat) -> NSParagraphStyle {
        if let cached = codeStyles[numberWidth] { return cached }
        let style = base()
        style.firstLineHeadIndent = gutter + numberWidth
        style.headIndent = gutter + numberWidth
        style.lineSpacing = fonts.codeLineSpacing
        codeStyles[numberWidth] = style
        return style
    }

    // MARK: Inline

    private static let inlineCode = try! NSRegularExpression(pattern: "(`+)(?!`)(.+?)(?<!`)\\1(?!`)")
    private static let link = try! NSRegularExpression(pattern: #"(!?\[)([^\]\n]*)(\]\(([^)\s]*)(?:\s+"[^"\n]*")?\))"#)
    private static let autolink = try! NSRegularExpression(pattern: #"<(https?://[^>\s]+)>"#)
    private static let bareURL = try! NSRegularExpression(pattern: #"(?<![\w/(<\[])https?://[^\s<>()\[\]]+[^\s<>()\[\].,;:!?'"]"#)
    private static let bold = try! NSRegularExpression(pattern: #"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italicStar = try! NSRegularExpression(pattern: #"(?<![*\\])\*(?![\s*])(.+?)(?<![\s\\*])\*(?!\*)"#)
    private static let italicUnderscore = try! NSRegularExpression(pattern: #"(?<![\w_])_(?![\s_])(.+?)(?<![\s_])_(?![\w_])"#)
    private static let strike = try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#)

    private func styleInline(_ storage: NSMutableAttributedString, text: NSString, range: NSRange) {
        guard range.length > 0 else { return }
        var protected: [NSRange] = []
        func isProtected(_ r: NSRange) -> Bool {
            protected.contains { NSIntersectionRange($0, r).length > 0 }
        }

        for match in Self.inlineCode.matches(in: text as String, range: range) {
            let ticks = match.range(at: 1).length
            let whole = match.range
            storage.addAttributes([.font: fonts.inlineCode, .lotionInlineCode: true], range: whole)
            hideMarkers(storage, whole, length: ticks)
            protected.append(whole)
        }

        for match in Self.link.matches(in: text as String, range: range) where !isProtected(match.range) {
            let url = text.substring(with: match.range(at: 4))
            storage.addAttribute(.lotionURL, value: url, range: match.range)
            storage.addAttribute(.foregroundColor, value: palette.accent, range: match.range(at: 2))
            let marks = [match.range(at: 1), match.range(at: 3)]
            if isRevealed(match.range) {
                for mark in marks { storage.addAttributes(revealedMark, range: mark) }
            } else {
                for mark in marks { storage.addAttributes(hidden, range: mark) }
            }
            protected.append(match.range(at: 3))
        }
        for match in Self.autolink.matches(in: text as String, range: range) where !isProtected(match.range) {
            storage.addAttributes([.lotionURL: text.substring(with: match.range(at: 1)), .foregroundColor: palette.accent], range: match.range)
            protected.append(match.range)
        }
        for match in Self.bareURL.matches(in: text as String, range: range) where !isProtected(match.range) {
            storage.addAttributes([.lotionURL: text.substring(with: match.range), .foregroundColor: palette.accent], range: match.range)
            protected.append(match.range)
        }

        for match in Self.bold.matches(in: text as String, range: range) where !isProtected(match.range) {
            let markerLength = match.range(at: 1).length
            addTrait(.boldFontMask, to: storage, range: match.range(at: 2))
            hideMarkers(storage, match.range, length: markerLength)
        }
        for regex in [Self.italicStar, Self.italicUnderscore] {
            for match in regex.matches(in: text as String, range: range) where !isProtected(match.range) {
                addTrait(.italicFontMask, to: storage, range: match.range(at: 1))
                hideMarkers(storage, match.range, length: 1)
            }
        }
        for match in Self.strike.matches(in: text as String, range: range) where !isProtected(match.range) {
            storage.addAttributes([
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: palette.secondary,
            ], range: match.range(at: 1))
            hideMarkers(storage, match.range, length: 2)
        }
    }

    /// Hides a span's opening and closing marks, or dims them while the selection touches the span.
    private func hideMarkers(_ storage: NSMutableAttributedString, _ range: NSRange, length: Int) {
        let marks = [NSRange(location: range.location, length: length), NSRange(location: NSMaxRange(range) - length, length: length)]
        if isRevealed(range) {
            for mark in marks { storage.addAttributes(revealedMark, range: mark) }
        } else {
            for mark in marks { storage.addAttributes(hidden, range: mark) }
        }
    }

    private func addTrait(_ trait: NSFontTraitMask, to storage: NSMutableAttributedString, range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
            guard let font = value as? NSFont else { return }
            storage.addAttribute(.font, value: Self.font(font, with: trait), range: subrange)
        }
    }

    /// `font` made bold or italic. The font manager leaves the system font
    /// upright when asked for italic, so its descriptor is the fallback.
    private static var traitFonts: [String: NSFont] = [:]
    static func font(_ font: NSFont, with trait: NSFontTraitMask) -> NSFont {
        let key = "\(font.fontName) \(font.pointSize) \(trait.rawValue)"
        if let cached = traitFonts[key] { return cached }
        var result = NSFontManager.shared.convert(font, toHaveTrait: trait)
        let symbolic: NSFontDescriptor.SymbolicTraits = trait.contains(.italicFontMask) ? .italic : .bold
        if !result.fontDescriptor.symbolicTraits.contains(symbolic) {
            let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(symbolic))
            result = NSFont(descriptor: descriptor, size: font.pointSize) ?? result
        }
        traitFonts[key] = result
        return result
    }

    // MARK: Paragraph styles

    private enum ParagraphKind: Hashable { case body, blank, code, codeOpen, codeClose, codeEdge, codeHandle, table }

    /// Space inside a code block, around its header and code.
    static let codeInset: CGFloat = 12
    static let codeHandleHeight: CGFloat = 28
    private var cachedStyles: [ParagraphKind: NSParagraphStyle] = [:]

    private func base() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.firstLineHeadIndent = gutter
        style.headIndent = gutter
        style.tailIndent = -gutter
        style.lineBreakMode = .byWordWrapping
        return style
    }

    private func paragraph(_ kind: ParagraphKind) -> NSParagraphStyle {
        if let cached = cachedStyles[kind] { return cached }
        let style = base()
        switch kind {
        case .body:
            style.lineSpacing = fonts.bodyLineSpacing
        case .blank:
            style.minimumLineHeight = fonts.blankLineHeight
            style.maximumLineHeight = fonts.blankLineHeight
        case .code:
            style.lineSpacing = fonts.codeLineSpacing
        case .codeOpen:
            // Space above sits outside the block; the header's own inset is drawn.
            style.paragraphSpacingBefore = Self.codeInset + 6
            style.paragraphSpacing = 6
            style.lineSpacing = fonts.codeLineSpacing
        case .codeClose:
            style.lineSpacing = fonts.codeLineSpacing
            style.paragraphSpacing = Self.codeInset + 6
        case .codeEdge:
            // Just the bottom inset.
            style.minimumLineHeight = Self.codeInset
            style.maximumLineHeight = Self.codeInset
            style.paragraphSpacing = 12
        case .codeHandle:
            style.minimumLineHeight = Self.codeHandleHeight
            style.maximumLineHeight = Self.codeHandleHeight
            style.paragraphSpacing = 12
        case .table:
            // Heights come from the table's layout; no spacing of its own.
            break
        }
        cachedStyles[kind] = style
        return style
    }

    private func headingParagraph(level: Int, atTop: Bool) -> NSParagraphStyle {
        let style = base()
        let font = fonts.headings[level - 1]
        // Keeps an empty heading full height, its marks hidden.
        style.minimumLineHeight = Self.lineHeight(font)
        style.lineSpacing = max(0, round(font.pointSize * 1.3 - Self.lineHeight(font)))
        let before: [CGFloat] = [0.9, 0.75, 0.55, 0.4, 0.4, 0.4]
        style.paragraphSpacingBefore = atTop ? 0 : round(fonts.em * before[level - 1])
        style.paragraphSpacing = round(fonts.em * 0.15)
        return style
    }

    private func hangingParagraph(markerWidth: CGFloat) -> NSParagraphStyle {
        let style = base()
        style.firstLineHeadIndent = max(0, gutter - markerWidth)
        style.lineSpacing = fonts.bodyLineSpacing
        return style
    }

    private func listParagraph(headIndent: CGFloat) -> NSParagraphStyle {
        if let cached = listStyles[headIndent] { return cached }
        let style = base()
        style.headIndent = gutter + headIndent
        style.lineSpacing = fonts.bodyLineSpacing
        listStyles[headIndent] = style
        return style
    }
}
