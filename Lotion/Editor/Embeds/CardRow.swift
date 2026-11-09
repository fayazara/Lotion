import AppKit

/// Lays icons and single lines of text on a shared center line, so a glyph
/// and its label always sit level with each other. Coordinates are flipped.
enum CardRow {
    /// The y at which a line's box starts so that the middle of its capitals
    /// lands on `centerY`. That's where the eye reads a line's center.
    static func top(of font: NSFont, centeredOn centerY: CGFloat) -> CGFloat {
        (centerY - (font.ascender - font.capHeight / 2)).rounded()
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading) + 1
    }

    static func width(_ string: String, font: NSFont) -> CGFloat {
        ceil((string as NSString).size(withAttributes: [.font: font]).width)
    }

    /// Draws one truncating line whose center sits on `centerY`.
    @discardableResult
    static func text(_ string: String, font: NSFont, color: NSColor, x: CGFloat, centerY: CGFloat, maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let width = min(maxWidth, width(string, font: font))
        guard width > 0 else { return 0 }
        let box = NSRect(x: x, y: top(of: font, centeredOn: centerY), width: width + 1, height: lineHeight(font))
        (string as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        return width
    }

    /// Draws an image centered on a point.
    static func icon(_ image: NSImage?, centerX: CGFloat, centerY: CGFloat) {
        guard let image else { return }
        let rect = NSRect(x: (centerX - image.size.width / 2).rounded(), y: (centerY - image.size.height / 2).rounded(),
                          width: image.size.width, height: image.size.height)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// Draws an image whose left edge is at `x`, centered on `centerY`.
    static func icon(_ image: NSImage?, x: CGFloat, centerY: CGFloat) {
        guard let image else { return }
        icon(image, centerX: x + image.size.width / 2, centerY: centerY)
    }
}
