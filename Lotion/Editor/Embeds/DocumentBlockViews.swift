//
//  DocumentBlockViews.swift
//  Lotion
//
//  Blocks that stand for something beside the text: the note's contents
//  (`[TOC]`), another note (`![[Name]]`), a file kept with the note, a PDF
//  you can page through, and audio with its waveform.
//

import AppKit
import AVFoundation
import PDFKit
import UniformTypeIdentifiers

/// Shared look for document cards.
private enum DocumentStyle {
    static let radius: CGFloat = 12

    static func fill(_ palette: ThemePalette, hovered: Bool = false) -> NSColor {
        let base = palette.isDark ? palette.codeBackground : palette.background.blended(withFraction: 0.5, of: .white) ?? palette.background
        return hovered ? base.blended(withFraction: 0.035, of: palette.text) ?? base : base
    }

    static func border(_ palette: ThemePalette) -> NSColor { palette.text.withAlphaComponent(palette.isDark ? 0.12 : 0.1) }

    static func card(_ rect: NSRect, palette: ThemePalette, hovered: Bool = false) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        fill(palette, hovered: hovered).setFill()
        path.fill()
        border(palette).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    static func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))?.tinted(color)
    }

    static func draw(_ image: NSImage?, centeredIn rect: NSRect) {
        guard let image else { return }
        image.draw(in: NSRect(x: rect.midX - image.size.width / 2, y: rect.midY - image.size.height / 2, width: image.size.width, height: image.size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    static func text(_ string: String, font: NSFont, color: NSColor, in rect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
    }
}

/// Hover tracking for the views below.
class HoverBlockView: BlockView {
    private var tracking: NSTrackingArea?
    var isHovered = false { didSet { if isHovered != oldValue { hoverChanged() } } }
    var hoverPoint: NSPoint?

    func hoverChanged() { needsDisplay = true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) {
        isHovered = false
        hoverPoint = nil
        needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }
    var contentRect: NSRect { NSRect(x: indent, y: 0, width: max(100, bounds.width - indent), height: bounds.height) }

    override var selectionShape: (rect: NSRect, radius: CGFloat) { (contentRect, DocumentStyle.radius) }
}

// MARK: - Table of contents

final class TocBlockView: HoverBlockView {
    private struct Entry {
        let id: UUID
        let title: String
        let level: Int
    }

    private var entries: [Entry] = []
    private static let rowHeight: CGFloat = 26
    private static let header: CGFloat = 34

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    /// Reads the note's headings again; called on every edit.
    func refresh() {
        guard let editor else { return }
        var list: [Entry] = []
        for (index, block) in editor.blocks.enumerated() {
            guard let level = block.kind.headingLevel, level <= 3 else { continue }
            // The note's title heads the page, not its contents.
            if index == 0 && level == 1 { continue }
            let title = block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { list.append(Entry(id: block.id, title: title, level: level)) }
        }
        let changed = list.map(\.title) != entries.map(\.title) || list.map(\.level) != entries.map(\.level)
        entries = list
        if changed {
            invalidateHeight()
            editor.blockHeightMayHaveChanged(block.id)
            needsDisplay = true
        }
    }

    private var minLevel: Int { entries.map(\.level).min() ?? 1 }

    override func measure(width: CGFloat) -> CGFloat {
        Self.header + CGFloat(max(1, entries.count)) * Self.rowHeight + 12
    }

    private func rowRect(_ index: Int) -> NSRect {
        let rect = contentRect
        return NSRect(x: rect.minX + 8, y: Self.header + CGFloat(index) * Self.rowHeight, width: rect.width - 16, height: Self.rowHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        DocumentStyle.card(rect, palette: palette)
        let headerMid: CGFloat = 18
        CardRow.icon(DocumentStyle.symbol("list.bullet.indent", size: 12, color: palette.secondary, weight: .medium), centerX: rect.minX + 24, centerY: headerMid)
        CardRow.text("Contents", font: .systemFont(ofSize: 12, weight: .semibold), color: palette.secondary, x: rect.minX + 38, centerY: headerMid)
        guard !entries.isEmpty else {
            let row = rowRect(0)
            CardRow.text("Headings in this note will be listed here.", font: .systemFont(ofSize: 13), color: palette.marker,
                         x: row.minX + 8, centerY: row.midY, maxWidth: row.width - 16)
            return
        }
        for (index, entry) in entries.enumerated() {
            let row = rowRect(index)
            let hovered = hoverPoint.map { row.contains($0) } ?? false
            if hovered {
                palette.text.withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: row, xRadius: 6, yRadius: 6).fill()
            }
            let depth = CGFloat(entry.level - minLevel)
            let x = row.minX + 8 + depth * 18
            let font: NSFont = entry.level == minLevel ? .systemFont(ofSize: 13.5, weight: .medium) : .systemFont(ofSize: 13)
            CardRow.text(entry.title, font: font, color: hovered ? palette.accent : (entry.level == minLevel ? palette.text : palette.secondary),
                         x: x, centerY: row.midY, maxWidth: row.maxX - x - 8)
        }
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        guard let editor else { return false }
        if event.modifierFlags.intersection([.shift, .command]).isEmpty,
           let index = entries.indices.first(where: { rowRect($0).contains(point) }) {
            let id = entries[index].id
            editor.focus(id, .end)
            if let view = editor.view(for: id) {
                editor.scrollToVisible(NSRect(x: view.frame.minX, y: max(0, view.frame.minY - 24), width: view.frame.width, height: editor.visibleRect.height * 0.6))
            }
            return true
        }
        editor.selectBlocks([block.id])
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        for index in entries.indices { addCursorRect(rowRect(index), cursor: .pointingHand) }
    }
}

// MARK: - Another note

final class NoteEmbedBlockView: HoverBlockView {
    private var rendered: NSAttributedString?
    private var renderedKey: String?
    private var found: (title: String, text: String)?
    private static let header: CGFloat = 44
    private static let maxBody: CGFloat = 280

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func lookUp() {
        found = editor?.noteLookup?(block.imageSource)
        let key = (found?.text ?? "") + "|\(theme.palette.isDark)|\(theme.em)"
        guard key != renderedKey else { return }
        renderedKey = key
        rendered = found.map { Self.excerpt($0.text, theme: theme) }
    }

    override func update(_ block: Block) {
        super.update(block)
        lookUp()
        needsDisplay = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        renderedKey = nil
        lookUp()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { lookUp() }
    }

    /// The other note's blocks, set as plain styled text: headings, lists, quotes.
    static func excerpt(_ markdown: String, theme: BlockTheme) -> NSAttributedString {
        let palette = theme.palette
        let result = NSMutableAttributedString()
        var blocks = BlockMarkdown.parse(markdown).blocks
        if blocks.first?.kind.headingLevel == 1 { blocks.removeFirst() }
        let size = max(12, theme.em - 2)
        for block in blocks.prefix(24) {
            var line = block.plainText.replacingOccurrences(of: "\n", with: " ")
            var font = NSFont.systemFont(ofSize: size)
            var color = palette.text
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            switch block.kind {
            case .heading(let level):
                font = .systemFont(ofSize: size + (level <= 2 ? 3 : 1), weight: .semibold)
                style.paragraphSpacingBefore = 4
            case .bullet, .numbered:
                line = "•  " + line
                style.headIndent = 14 + CGFloat(block.indent) * 14
                style.firstLineHeadIndent = CGFloat(block.indent) * 14
            case .todo:
                line = (block.checked ? "☑︎  " : "☐  ") + line
                style.headIndent = 18 + CGFloat(block.indent) * 14
                style.firstLineHeadIndent = CGFloat(block.indent) * 14
                if block.checked { color = palette.secondary }
            case .quote:
                color = palette.secondary
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            case .code:
                font = .monospacedSystemFont(ofSize: size - 1, weight: .regular)
                color = palette.secondary
                line = block.text.string.split(separator: "\n").prefix(4).joined(separator: "\n")
            case .image, .embed:
                line = block.imageAlt.isEmpty ? "" : "▢  " + block.imageAlt
                color = palette.secondary
            case .table:
                line = "▦  Table"
                color = palette.secondary
            case .divider, .entry, .html, .raw:
                continue
            case .paragraph:
                break
            }
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style]))
        }
        return result
    }

    private func bodyHeight(width: CGFloat) -> CGFloat {
        guard let rendered, rendered.length > 0 else { return 0 }
        let height = rendered.boundingRect(with: NSSize(width: width - 32, height: .greatestFiniteMagnitude),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        return min(Self.maxBody, ceil(height)) + 16
    }

    override func measure(width: CGFloat) -> CGFloat {
        if found == nil { lookUp() }
        guard found != nil else { return 52 }
        return Self.header + bodyHeight(width: max(100, width - indent))
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        DocumentStyle.card(rect, palette: palette, hovered: isHovered)
        guard let found else {
            CardRow.icon(DocumentStyle.symbol("doc.questionmark", size: 13, color: palette.marker), centerX: rect.minX + 24, centerY: rect.midY)
            CardRow.text("No note named “\(block.imageSource)”", font: .systemFont(ofSize: 13), color: palette.secondary,
                         x: rect.minX + 40, centerY: rect.midY, maxWidth: rect.width - 56)
            return
        }
        let headerMid: CGFloat = 23
        CardRow.icon(DocumentStyle.symbol("doc.text", size: 13, color: palette.accent, weight: .medium), centerX: rect.minX + 24, centerY: headerMid)
        CardRow.text(found.title, font: .systemFont(ofSize: 14, weight: .semibold), color: palette.text,
                     x: rect.minX + 40, centerY: headerMid, maxWidth: rect.width - 120)
        let openColor = isHovered ? palette.accent : palette.secondary
        let openFont = NSFont.systemFont(ofSize: 12, weight: .medium)
        let arrowX = rect.maxX - 21
        CardRow.icon(DocumentStyle.symbol("arrow.up.right", size: 10, color: openColor, weight: .medium), centerX: arrowX, centerY: headerMid)
        CardRow.text("Open", font: openFont, color: openColor, x: arrowX - 11 - CardRow.width("Open", font: openFont), centerY: headerMid)

        guard let rendered, rendered.length > 0 else { return }
        DocumentStyle.border(palette).setFill()
        NSRect(x: rect.minX + 1, y: Self.header - 1, width: rect.width - 2, height: 1).fill()
        let body = NSRect(x: rect.minX + 16, y: Self.header + 8, width: rect.width - 32, height: rect.height - Self.header - 16)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: body).addClip()
        rendered.draw(with: NSRect(x: body.minX, y: body.minY, width: body.width, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        // A long note fades out at the bottom.
        let full = rendered.boundingRect(with: NSSize(width: body.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading]).height
        if full > body.height + 1 {
            let fill = DocumentStyle.fill(palette, hovered: isHovered)
            NSGradient(starting: fill.withAlphaComponent(0), ending: fill)?
                .draw(in: NSRect(x: rect.minX + 1, y: rect.maxY - 48, width: rect.width - 2, height: 47), angle: 90)
        }
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.shift, .command]).isEmpty, found != nil {
            editor?.openNoteNamed?(block.imageSource)
        } else {
            editor?.selectBlocks([block.id])
        }
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if found != nil { addCursorRect(contentRect, cursor: .pointingHand) }
    }
}

// MARK: - A file

final class FileBlockView: HoverBlockView {
    private let revealButton = NSButton(title: "Show in Finder", target: nil, action: nil)

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        revealButton.bezelStyle = .glass
        revealButton.controlSize = .small
        revealButton.target = self
        revealButton.action = #selector(reveal)
        revealButton.isHidden = true
        addSubview(revealButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var url: URL? { editor?.resolveImageURL(block.imageSource) }
    private var exists: Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    override func hoverChanged() {
        revealButton.isHidden = !isHovered || !exists
        needsDisplay = true
    }

    override func measure(width: CGFloat) -> CGFloat { 60 }

    override func layoutContent() {
        let size = revealButton.fittingSize
        revealButton.frame = NSRect(x: contentRect.maxX - size.width - 12, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        DocumentStyle.card(rect, palette: palette, hovered: isHovered)
        let ext = (block.imageSource as NSString).pathExtension
        let icon: NSImage
        if let url, exists { icon = NSWorkspace.shared.icon(forFile: url.path) } else { icon = NSWorkspace.shared.icon(for: UTType(filenameExtension: ext) ?? .data) }
        icon.draw(in: NSRect(x: rect.minX + 12, y: rect.midY - 18, width: 36, height: 36), from: .zero, operation: .sourceOver, fraction: exists ? 1 : 0.5,
                  respectFlipped: true, hints: nil)
        let name = block.imageAlt.isEmpty ? (block.imageSource as NSString).lastPathComponent : block.imageAlt
        CardRow.text(name, font: .systemFont(ofSize: 14, weight: .medium), color: palette.text,
                     x: rect.minX + 58, centerY: rect.midY - 8, maxWidth: rect.width - 200)
        var detail: [String] = []
        if let type = UTType(filenameExtension: ext)?.localizedDescription { detail.append(type) } else if !ext.isEmpty { detail.append(ext.uppercased()) }
        if let url, exists, let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
            detail.append(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
        } else if !exists {
            detail.append("Missing")
        }
        CardRow.text(detail.joined(separator: " · "), font: .systemFont(ofSize: 12), color: palette.secondary,
                     x: rect.minX + 58, centerY: rect.midY + 9, maxWidth: rect.width - 200)
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        if event.clickCount == 2, let url, exists {
            NSWorkspace.shared.open(url)
        } else {
            editor?.selectBlocks([block.id])
        }
        return true
    }

    @objc private func reveal() {
        guard let url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - PDF

final class PDFBlockView: HoverBlockView {
    private var document: PDFDocument?
    private var page = 0
    private var pageImage: NSImage?
    private var imageKey: String?
    private var failed = false
    private var loadedSource: String?
    private let previous = NSButton()
    private let next = NSButton()
    private let shimmer = Shimmer()
    private var isZoomed = false { didSet { needsDisplay = true } }
    private static let footer: CGFloat = 44

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        for (button, symbol, action) in [(previous, "chevron.left", #selector(showPrevious)), (next, "chevron.right", #selector(showNext))] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.bezelStyle = .glass
            button.controlSize = .small
            button.imagePosition = .imageOnly
            button.target = self
            button.action = action
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, loadedSource != block.imageSource { load() }
    }

    override func update(_ block: Block) {
        super.update(block)
        if window != nil, loadedSource != block.imageSource { load() }
    }

    private func load() {
        loadedSource = block.imageSource
        document = nil
        failed = false
        page = 0
        pageImage = nil
        imageKey = nil
        guard let url = editor?.resolveImageURL(block.imageSource) else { failed = true; return }
        if url.isFileURL {
            document = PDFDocument(url: url)
            failed = document == nil
            documentDidLoad()
        } else {
            let cache = editor?.mediaCacheURL
            Task { [weak self] in
                let local = MediaLoader.savedCopy(of: url, in: cache)
                var data = local.flatMap { try? Data(contentsOf: $0) }
                if data == nil { data = try? await URLSession.shared.data(from: url).0 }
                guard let self, self.loadedSource == url.absoluteString || self.loadedSource == self.block.imageSource else { return }
                self.document = data.flatMap { PDFDocument(data: $0) }
                self.failed = self.document == nil
                self.documentDidLoad()
            }
        }
    }

    private func documentDidLoad() {
        invalidateHeight()
        editor?.blockHeightMayHaveChanged(block.id)
        needsLayout = true
        needsDisplay = true
    }

    private var pageCount: Int { document?.pageCount ?? 0 }

    private func pageSize(_ index: Int) -> NSSize {
        guard let page = document?.page(at: index) else { return NSSize(width: 612, height: 792) }
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : NSSize(width: box.height, height: box.width)
    }

    /// The page, fitted to the column and no taller than a screenful.
    private var pageRect: NSRect {
        let rect = contentRect
        let area = NSRect(x: rect.minX + 1, y: 1, width: rect.width - 2, height: rect.height - Self.footer - 1)
        let size = pageSize(page)
        let scale = min(area.width / size.width, area.height / size.height)
        let fitted = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        return NSRect(x: area.midX - fitted.width / 2, y: area.minY + (area.height - fitted.height) / 2, width: fitted.width, height: fitted.height)
    }

    override func measure(width: CGFloat) -> CGFloat {
        let available = max(100, width - indent)
        guard document != nil else { return failed ? 64 : 320 }
        let size = pageSize(0)
        return min(720, round(available * size.height / max(1, size.width))) + Self.footer
    }

    override func layoutContent() {
        let rect = contentRect
        let size = previous.fittingSize
        next.frame = NSRect(x: rect.maxX - size.width - 10, y: rect.maxY - Self.footer + (Self.footer - size.height) / 2, width: size.width, height: size.height)
        previous.frame = NSRect(x: next.frame.minX - size.width - 4, y: next.frame.minY, width: size.width, height: size.height)
        previous.isHidden = pageCount < 2
        next.isHidden = pageCount < 2
        previous.isEnabled = page > 0
        next.isEnabled = page < pageCount - 1
        shimmer.update(window != nil && document == nil && !failed ? [rect] : [], radius: DocumentStyle.radius, in: self, isDark: theme.palette.isDark)
    }

    private func renderedPage() -> NSImage? {
        guard let document, let pdfPage = document.page(at: page) else { return nil }
        let target = pageRect.size
        let key = "\(page)|\(Int(target.width))"
        if key != imageKey {
            let scale = window?.backingScaleFactor ?? 2
            pageImage = pdfPage.thumbnail(of: NSSize(width: target.width * scale, height: target.height * scale), for: .cropBox)
            imageKey = key
        }
        return pageImage
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        DocumentStyle.card(rect, palette: palette)
        let name = (block.imageAlt.isEmpty ? (block.imageSource as NSString).lastPathComponent : block.imageAlt).removingPercentEncoding ?? block.imageSource
        if failed {
            CardRow.icon(DocumentStyle.symbol("doc.richtext", size: 14, color: palette.marker), centerX: rect.minX + 24, centerY: rect.midY)
            CardRow.text("Can’t open “\(name)”", font: .systemFont(ofSize: 13), color: palette.secondary,
                         x: rect.minX + 40, centerY: rect.midY, maxWidth: rect.width - 56)
            return
        }
        // The page sits on a soft backdrop, like paper on a desk.
        let area = NSRect(x: rect.minX + 1, y: 1, width: rect.width - 2, height: rect.height - Self.footer - 1)
        NSGraphicsContext.saveGraphicsState()
        let top = NSBezierPath()
        let r = DocumentStyle.radius - 1
        top.move(to: NSPoint(x: area.minX, y: area.maxY))
        top.line(to: NSPoint(x: area.minX, y: area.minY + r))
        top.appendArc(withCenter: NSPoint(x: area.minX + r, y: area.minY + r), radius: r, startAngle: 180, endAngle: 270)
        top.line(to: NSPoint(x: area.maxX - r, y: area.minY))
        top.appendArc(withCenter: NSPoint(x: area.maxX - r, y: area.minY + r), radius: r, startAngle: 270, endAngle: 360)
        top.line(to: NSPoint(x: area.maxX, y: area.maxY))
        top.close()
        palette.text.withAlphaComponent(palette.isDark ? 0.06 : 0.035).setFill()
        top.fill()
        top.addClip()
        if !isZoomed, let image = renderedPage() {
            let page = pageRect
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
            NSColor.white.setFill()
            page.fill()
            NSGraphicsContext.restoreGraphicsState()
            image.draw(in: page, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        }
        NSGraphicsContext.restoreGraphicsState()
        DocumentStyle.border(palette).setFill()
        NSRect(x: rect.minX + 1, y: rect.maxY - Self.footer, width: rect.width - 2, height: 1).fill()

        let footerY = rect.maxY - Self.footer
        let footerMid = footerY + Self.footer / 2
        CardRow.icon(DocumentStyle.symbol("doc.richtext", size: 13, color: NSColor(hex: 0xE5484D), weight: .medium), centerX: rect.minX + 24, centerY: footerMid)
        CardRow.text(name, font: .systemFont(ofSize: 13.5, weight: .medium), color: palette.text,
                     x: rect.minX + 40, centerY: footerMid, maxWidth: rect.width - 200)
        if pageCount > 0 {
            let label = "\(page + 1) of \(pageCount)"
            let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            let right = pageCount > 1 ? previous.frame.minX - 10 : rect.maxX - 14
            CardRow.text(label, font: font, color: palette.secondary, x: right - CardRow.width(label, font: font), centerY: footerMid)
        }
    }

    @objc private func showPrevious() { turn(to: page - 1) }
    @objc private func showNext() { turn(to: page + 1) }

    private func turn(to index: Int) {
        guard index >= 0, index < pageCount else { return }
        page = index
        needsLayout = true
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: showPrevious()
        case 124: showNext()
        default: super.keyDown(with: event)
        }
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        let selects = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if event.clickCount == 2, let url = editor?.resolveImageURL(block.imageSource) {
            NSWorkspace.shared.open(url)
            return true
        }
        if !selects, pageRect.contains(point), let pdfPage = document?.page(at: page) {
            let size = pageSize(page)
            let scale = min(2200 / size.width, 2200 / size.height)
            let image = pdfPage.thumbnail(of: NSSize(width: size.width * scale, height: size.height * scale), for: .cropBox)
            let shown = page
            MediaZoom.shared.show(MediaZoom.Request(
                content: .image(image),
                rect: { [weak self] in (self?.window != nil && self?.page == shown) ? self?.pageRect : nil },
                source: self,
                radius: 2,
                backdrop: theme.palette.background,
                setOriginalHidden: { [weak self] hidden in self?.isZoomed = hidden },
                onDoubleClick: { [weak self] in
                    guard let self, let url = self.editor?.resolveImageURL(self.block.imageSource) else { return }
                    NSWorkspace.shared.open(url)
                }
            ))
            return true
        }
        editor?.selectBlocks([block.id])
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if document != nil { addCursorRect(pageRect, cursor: ZoomCursor.zoomIn) }
    }
}

// MARK: - Audio

final class AudioBlockView: HoverBlockView {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var samples: [Float] = []
    private var duration: Double = 0
    private var current: Double = 0
    private var isPlaying = false
    private var loadedSource: String?
    private static let barCount = 72

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, loadedSource != block.imageSource { load() }
        if window == nil { player?.pause(); isPlaying = false }
    }

    override func update(_ block: Block) {
        super.update(block)
        if window != nil, loadedSource != block.imageSource { load() }
    }

    private func load() {
        loadedSource = block.imageSource
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player?.pause()
        player = nil
        samples = []
        duration = 0
        current = 0
        isPlaying = false
        guard let url = editor?.resolveImageURL(block.imageSource) else { return }
        let playable = MediaLoader.playableURL(url, cache: editor?.mediaCacheURL)
        let item = AVPlayerItem(url: playable)
        let player = AVPlayer(playerItem: item)
        self.player = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.current = time.seconds.isFinite ? time.seconds : 0
                self.needsDisplay = true
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isPlaying = false
                self.player?.seek(to: .zero)
                self.needsDisplay = true
            }
        }
        Task { [weak self] in
            let asset = AVURLAsset(url: playable)
            let seconds = (try? await asset.load(.duration))?.seconds ?? 0
            let levels = playable.isFileURL ? await Self.levels(of: playable, bars: Self.barCount) : []
            guard let self, self.loadedSource == self.block.imageSource else { return }
            self.duration = seconds.isFinite ? seconds : 0
            self.samples = levels
            self.needsDisplay = true
        }
    }

    /// Loudness in `bars` slices of a local file, from 0 to 1.
    nonisolated static func levels(of url: URL, bars: Int) async -> [Float] {
        await Task.detached(priority: .utility) {
            guard let file = try? AVAudioFile(forReading: url) else { return [] }
            let format = file.processingFormat
            let total = AVAudioFrameCount(file.length)
            guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: min(total, 48_000 * 60 * 20)) else { return [] }
            try? file.read(into: buffer)
            guard let channel = buffer.floatChannelData?[0] else { return [] }
            let frames = Int(buffer.frameLength)
            let step = max(1, frames / bars)
            var result: [Float] = []
            for bar in 0..<bars {
                let start = bar * step
                guard start < frames else { break }
                var peak: Float = 0
                var index = start
                while index < min(frames, start + step) {
                    peak = max(peak, abs(channel[index]))
                    index += 8
                }
                result.append(peak)
            }
            let top = result.max() ?? 1
            return result.map { top > 0 ? sqrt($0 / top) : 0 }
        }.value
    }

    override func measure(width: CGFloat) -> CGFloat { 72 }

    private var buttonRect: NSRect { NSRect(x: contentRect.minX + 16, y: (bounds.height - 40) / 2, width: 40, height: 40) }
    private var waveRect: NSRect {
        let rect = contentRect
        return NSRect(x: rect.minX + 70, y: 34, width: rect.width - 70 - 90, height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        DocumentStyle.card(rect, palette: palette, hovered: isHovered)
        let button = buttonRect
        palette.accent.setFill()
        NSBezierPath(ovalIn: button).fill()
        DocumentStyle.draw(DocumentStyle.symbol(isPlaying ? "pause.fill" : "play.fill", size: 15, color: .white, weight: .semibold),
                           centeredIn: button.offsetBy(dx: isPlaying ? 0 : 1.5, dy: 0).integral)
        let name = (block.imageAlt.isEmpty ? (block.imageSource as NSString).deletingPathExtension.components(separatedBy: "/").last ?? "" : block.imageAlt)
            .removingPercentEncoding ?? block.imageSource
        CardRow.text(name, font: .systemFont(ofSize: 13.5, weight: .medium), color: palette.text,
                     x: rect.minX + 70, centerY: 22, maxWidth: rect.width - 170)

        // Waveform, played part in the accent.
        let wave = waveRect
        let progress = duration > 0 ? CGFloat(current / duration) : 0
        let bars = samples.isEmpty ? Array(repeating: Float(0.35), count: Self.barCount) : samples
        let gap: CGFloat = 2
        let barWidth = max(1.5, (wave.width - gap * CGFloat(bars.count - 1)) / CGFloat(bars.count))
        for (index, level) in bars.enumerated() {
            let x = wave.minX + CGFloat(index) * (barWidth + gap)
            guard x + barWidth <= wave.maxX + 0.5 else { break }
            let height = max(3, wave.height * CGFloat(level))
            let bar = NSRect(x: x, y: wave.midY - height / 2, width: barWidth, height: height)
            let played = (x - wave.minX) / max(1, wave.width) < progress
            (played ? palette.accent : palette.text.withAlphaComponent(palette.isDark ? 0.22 : 0.16)).setFill()
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        }
        let time = "\(Self.clock(current)) / \(Self.clock(duration))"
        let timeFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        CardRow.text(time, font: timeFont, color: palette.secondary, x: rect.maxX - 16 - CardRow.width(time, font: timeFont), centerY: wave.midY)
    }

    static func clock(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) : String(format: "%d:%02d", total / 60, total % 60)
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        let selects = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if !selects, buttonRect.insetBy(dx: -4, dy: -4).contains(point), let player {
            if isPlaying { player.pause() } else { player.play() }
            isPlaying.toggle()
            needsDisplay = true
            return true
        }
        if !selects, waveRect.insetBy(dx: 0, dy: -8).contains(point), let player, duration > 0 {
            let fraction = max(0, min(1, (point.x - waveRect.minX) / waveRect.width))
            player.seek(to: CMTime(seconds: duration * Double(fraction), preferredTimescale: 600))
            current = duration * Double(fraction)
            needsDisplay = true
            return true
        }
        editor?.selectBlocks([block.id])
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(buttonRect, cursor: .pointingHand)
        addCursorRect(waveRect.insetBy(dx: 0, dy: -8), cursor: .pointingHand)
    }
}
