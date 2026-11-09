//
//  BlockTheme.swift
//  Lotion
//
//  Fonts, colors and spacing for blocks, resolved from the editor settings.
//  Text keeps its formatting as semantic attributes (`.lotionBold`, …); the
//  theme turns those into fonts and colors for display.
//

import AppKit

final class BlockTheme {
    let style: EditorStyle
    let palette: ThemePalette
    let body: NSFont
    /// Heading levels 1 through 6.
    let headings: [NSFont]
    let code: NSFont
    let inlineCode: NSFont
    let em: CGFloat

    /// Width of one level of list nesting, and of a list marker's column.
    let indentWidth: CGFloat
    let markerWidth: CGFloat

    private var fontCache: [FontKey: NSFont] = [:]
    private struct FontKey: Hashable {
        let font: NSFont
        let bold: Bool
        let italic: Bool
    }

    init(style: EditorStyle) {
        self.style = style
        palette = style.palette
        let size = style.noteFontSize
        em = size
        body = FontChoice.font(style.noteFont, size: size)
        let scales: [CGFloat] = [2.0, 1.45, 1.2, 1.07, 1.0, 1.0]
        headings = scales.enumerated().map { index, scale in
            FontChoice.font(style.noteFont, size: round(size * scale), weight: index < 2 ? .bold : .semibold)
        }
        code = FontChoice.font(style.codeFont, size: round(size * 0.87 * 2) / 2)
        inlineCode = FontChoice.font(style.codeFont, size: round(size * 0.88 * 2) / 2)
        indentWidth = round(size * 1.6)
        markerWidth = round(size * 1.6)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: font)
    }

    // MARK: Block attributes

    func font(for kind: BlockKind) -> NSFont {
        switch kind {
        case .heading(let level): headings[max(0, min(5, level - 1))]
        case .code, .raw: code
        default: body
        }
    }

    func lineHeightMultiple(for kind: BlockKind) -> CGFloat {
        switch kind {
        case .heading: 1.3
        case .code, .raw: 1.5
        default: style.lineSpacing.multiple
        }
    }

    /// Each line's height. Text is centered in it, so space falls evenly above and below.
    func lineHeight(for kind: BlockKind) -> CGFloat {
        let font = font(for: kind)
        return max(Self.lineHeight(font), round(font.pointSize * lineHeightMultiple(for: kind)))
    }

    /// Lifts glyphs to the middle of a line taller than the font's own.
    func baselineOffset(for kind: BlockKind) -> CGFloat {
        let font = font(for: kind)
        return floor((lineHeight(for: kind) - Self.lineHeight(font)) / 2)
    }

    func paragraphStyle(for kind: BlockKind) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        let height = lineHeight(for: kind)
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        style.lineBreakMode = .byWordWrapping
        // A line break inside a paragraph or list item opens a little room,
        // so its lines group without becoming separate blocks.
        if kind.isText && kind.headingLevel == nil {
            style.paragraphSpacingBefore = round(em * 0.3)
        }
        if kind == .code || kind == .raw {
            let tab = code.advancement(forGlyph: code.glyph(withName: "space")).width * 4
            style.defaultTabInterval = max(8, tab)
            style.tabStops = []
        }
        return style
    }

    func baseAttributes(for kind: BlockKind, checked: Bool = false) -> [NSAttributedString.Key: Any] {
        var color = kind.headingLevel != nil ? palette.heading : palette.text
        if kind == .todo && checked { color = palette.secondary }
        if kind == .raw { color = palette.secondary }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(for: kind),
            .foregroundColor: color,
            .paragraphStyle: paragraphStyle(for: kind),
            .baselineOffset: baselineOffset(for: kind),
        ]
        if kind == .todo && checked {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            attributes[.strikethroughColor] = palette.secondary
        }
        return attributes
    }

    /// Attributes for a table cell's text.
    func cellAttributes(header: Bool) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        let height = max(Self.lineHeight(body), round(body.pointSize * 1.45))
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        return [
            .font: header ? NSFontManager.shared.convert(body, toHaveTrait: .boldFontMask) : body,
            .foregroundColor: header ? palette.text : palette.text,
            .paragraphStyle: style,
            .baselineOffset: floor((height - Self.lineHeight(body)) / 2),
        ]
    }

    // MARK: Display

    /// Text with display attributes derived from its formatting.
    func display(_ text: NSAttributedString, base: [NSAttributedString.Key: Any], code: Bool = false) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text.string, attributes: base)
        guard !code, text.length > 0 else { return result }
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            var semantic: [NSAttributedString.Key: Any] = [:]
            for key in NSAttributedString.Key.semanticKeys { if let value = attrs[key] { semantic[key] = value } }
            guard !semantic.isEmpty else { return }
            result.addAttributes(semantic, range: range)
        }
        applyDisplay(to: result, range: NSRange(location: 0, length: result.length), base: base)
        applyLinkSpacing(to: result, base: base)
        return result
    }

    /// The favicon drawn before an external link, for a font.
    static func linkIconSize(_ font: NSFont) -> CGFloat { round(font.pointSize * 0.92) }

    /// Makes room for favicons: extra space after the character before each
    /// external link, or a first-line indent for a link that starts the text.
    /// Display only; nothing here reaches the Markdown.
    func applyLinkSpacing(to text: NSMutableAttributedString, base: [NSAttributedString.Key: Any]) {
        let length = text.length
        guard length > 0 else { return }
        let full = NSRange(location: 0, length: length)
        text.removeAttribute(.kern, range: full)
        let string = text.string as NSString
        var leadingIndent: CGFloat = 0
        text.enumerateAttribute(.lotionLink, in: full) { value, range, _ in
            guard let link = value as? String, Favicons.host(of: link) != nil else { return }
            if range.location > 0, text.attribute(.lotionLink, at: range.location - 1, effectiveRange: nil) as? String == link { return }
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? body
            let space = Self.linkIconSize(font) + 5
            if range.location == 0 {
                leadingIndent = space
            } else if string.character(at: range.location - 1) != 10 {
                text.addAttribute(.kern, value: space, range: NSRange(location: range.location - 1, length: 1))
            }
        }
        let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
        let current = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
            ?? base[.paragraphStyle] as? NSParagraphStyle ?? NSParagraphStyle.default
        if current.firstLineHeadIndent != leadingIndent, let style = current.mutableCopy() as? NSMutableParagraphStyle {
            style.firstLineHeadIndent = leadingIndent
            text.addAttribute(.paragraphStyle, value: style, range: first)
        }
    }

    /// Re-derives fonts and colors over `range` from the formatting attributes.
    func applyDisplay(to text: NSMutableAttributedString, range: NSRange, base: [NSAttributedString.Key: Any]) {
        guard range.length > 0 else { return }
        let baseFont = base[.font] as? NSFont ?? body
        let baseColor = base[.foregroundColor] as? NSColor ?? palette.text
        text.removeAttribute(.backgroundColor, range: range)
        text.removeAttribute(.underlineStyle, range: range)
        if base[.strikethroughStyle] == nil {
            text.removeAttribute(.strikethroughStyle, range: range)
        }
        text.enumerateAttributes(in: range) { attrs, run, _ in
            var font = baseFont
            var color = baseColor
            if attrs[.lotionCode] != nil {
                font = inlineCode
                text.addAttribute(.backgroundColor, value: palette.inlineCode, range: run)
            }
            let bold = attrs[.lotionBold] != nil
            let italic = attrs[.lotionItalic] != nil
            if bold || italic { font = styled(font, bold: bold, italic: italic) }
            if attrs[.lotionStrike] != nil {
                text.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: run)
            }
            if attrs[.lotionLink] != nil {
                color = palette.accent
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: run)
                text.addAttribute(.underlineColor, value: palette.accent.withAlphaComponent(0.4), range: run)
            } else if attrs[.lotionRaw] != nil {
                color = palette.secondary
            }
            text.addAttribute(.font, value: font, range: run)
            text.addAttribute(.foregroundColor, value: color, range: run)
        }
    }

    func styled(_ font: NSFont, bold: Bool, italic: Bool) -> NSFont {
        let key = FontKey(font: font, bold: bold, italic: italic)
        if let cached = fontCache[key] { return cached }
        var result = font
        let manager = NSFontManager.shared
        if bold {
            // Headings are already bold; go one step heavier.
            result = manager.traits(of: result).contains(.boldFontMask)
                ? (manager.font(withFamily: result.familyName ?? "", traits: [], weight: 11, size: result.pointSize) ?? result)
                : manager.convert(result, toHaveTrait: .boldFontMask)
        }
        if italic {
            let converted = manager.convert(result, toHaveTrait: .italicFontMask)
            if manager.traits(of: converted).contains(.italicFontMask) {
                result = converted
            } else {
                // Fonts without an italic face get a slant.
                let matrix = AffineTransform(m11: 1, m12: 0, m21: 0.2, m22: 1, tX: 0, tY: 0)
                let descriptor = result.fontDescriptor.withMatrix(matrix)
                result = NSFont(descriptor: descriptor, size: result.pointSize) ?? result
            }
        }
        fontCache[key] = result
        return result
    }

    // MARK: Spacing

    /// Space above a block, given the one before it.
    func spacing(before block: Block, after previous: Block?, isAfterTitle: Bool = false) -> CGFloat {
        guard let previous else { return 0 }
        // A scratchpad entry gets room above its break, and starts close under it.
        if block.kind == .entry { return round(em * 1.4) }
        if previous.kind == .entry { return round(em * 0.4) }
        if isAfterTitle { return round(em * 0.9) }
        if let level = block.kind.headingLevel {
            return round(em * (level == 1 ? 1.9 : level == 2 ? 1.5 : 1.15))
        }
        if previous.kind.headingLevel != nil { return round(em * 0.4) }
        // Wider than a line break inside an item, so each item holds together.
        if block.kind.isList && previous.kind.isList { return round(em * 0.6) }
        if block.indent > 0 && previous.kind.isList { return round(em * 0.6) }
        let framed: Set<BlockKind> = [.code, .table, .image, .embed, .divider, .quote, .raw]
        if framed.contains(block.kind) || framed.contains(previous.kind) { return round(em * 0.75) }
        return round(em * 0.7)
    }
}

/// Lays out attributed text the way a block's text view will, for blocks
/// whose text view has not been made yet.
final class TextMeasurer {
    static let shared = TextMeasurer()

    private let storage = NSTextStorage()
    private let layoutManager = NSLayoutManager()
    private let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))

    private init() {
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
    }

    /// The height `text` takes at `width`. Empty text, and text ending in a
    /// newline, get a last line in the base attributes.
    func height(of text: NSAttributedString, width: CGFloat, base: [NSAttributedString.Key: Any]) -> CGFloat {
        let measured = NSMutableAttributedString(attributedString: text)
        if measured.length == 0 || measured.string.hasSuffix("\n") {
            measured.append(NSAttributedString(string: "\u{200B}", attributes: base))
        }
        storage.setAttributedString(measured)
        container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let height = layoutManager.usedRect(for: container).height
        storage.setAttributedString(NSAttributedString())
        return ceil(height)
    }
}
