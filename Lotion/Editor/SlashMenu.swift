//
//  SlashMenu.swift
//  Lotion
//
//  Typing `/` opens a menu of blocks under the caret. Typing on filters it,
//  arrows choose, Return inserts, Escape closes.
//

import AppKit
import UniformTypeIdentifiers

struct SlashItem {
    let title: String
    let detail: String
    let symbol: String?
    let glyph: String?
    let kind: BlockKind
    let keywords: [String]
    var alert: String? = nil
    var video = false
    /// A code fence's info string, and what the new block starts with.
    var info: String? = nil
    var starter = ""
    /// Blocks that need more than a kind: "embed", "pdf", "audio", "file", "toc", "note".
    var special: String? = nil

    static let all: [SlashItem] = [
        SlashItem(title: "Text", detail: "Plain paragraph", symbol: nil, glyph: "Aa", kind: .paragraph, keywords: ["paragraph", "plain", "body", "p"]),
        SlashItem(title: "Heading 1", detail: "#", symbol: nil, glyph: "H1", kind: .heading(1), keywords: ["h1", "title", "big", "#"]),
        SlashItem(title: "Heading 2", detail: "##", symbol: nil, glyph: "H2", kind: .heading(2), keywords: ["h2", "subtitle", "##"]),
        SlashItem(title: "Heading 3", detail: "###", symbol: nil, glyph: "H3", kind: .heading(3), keywords: ["h3", "###"]),
        SlashItem(title: "Bulleted List", detail: "-", symbol: "list.bullet", glyph: nil, kind: .bullet, keywords: ["ul", "bullet", "unordered", "list", "-"]),
        SlashItem(title: "Numbered List", detail: "1.", symbol: "list.number", glyph: nil, kind: .numbered, keywords: ["ol", "ordered", "number", "list", "1."]),
        SlashItem(title: "To-do List", detail: "[ ]", symbol: "checklist", glyph: nil, kind: .todo, keywords: ["todo", "task", "check", "checkbox", "checklist", "[]"]),
        SlashItem(title: "Quote", detail: ">", symbol: "text.quote", glyph: nil, kind: .quote, keywords: ["blockquote", "citation", ">"]),
        SlashItem(title: "Callout", detail: "> [!NOTE]", symbol: "info.circle", glyph: nil, kind: .quote, keywords: ["callout", "note", "alert", "tip", "warning", "admonition"], alert: "NOTE"),
        SlashItem(title: "Image", detail: "From your Mac", symbol: "photo", glyph: nil, kind: .image, keywords: ["image", "picture", "photo", "img", "screenshot"]),
        SlashItem(title: "Video", detail: "From your Mac", symbol: "play.rectangle", glyph: nil, kind: .image, keywords: ["video", "movie", "clip", "mp4"], video: true),
        SlashItem(title: "Embed", detail: "A page, video, player or map", symbol: "link", glyph: nil, kind: .embed,
                  keywords: ["embed", "link", "bookmark", "url", "youtube", "video", "spotify", "music", "github", "tweet", "x", "figma", "codepen", "map", "iframe", "card"],
                  special: "embed"),
        SlashItem(title: "PDF", detail: "From your Mac", symbol: "doc.richtext", glyph: nil, kind: .image, keywords: ["pdf", "document", "paper"], special: "pdf"),
        SlashItem(title: "Audio", detail: "From your Mac", symbol: "waveform", glyph: nil, kind: .image, keywords: ["audio", "sound", "music", "mp3", "voice", "memo", "recording"], special: "audio"),
        SlashItem(title: "File", detail: "Attach any file", symbol: "paperclip", glyph: nil, kind: .embed, keywords: ["file", "attachment", "attach", "zip", "upload"], special: "file"),
        SlashItem(title: "Embed Note", detail: "![[Another note]]", symbol: "doc.on.doc", glyph: nil, kind: .embed, keywords: ["note", "embed", "transclude", "include", "page", "[["], special: "note"),
        SlashItem(title: "Table of Contents", detail: "[TOC]", symbol: "list.bullet.indent", glyph: nil, kind: .embed, keywords: ["toc", "contents", "outline", "headings", "index"], special: "toc"),
        SlashItem(title: "Code", detail: "```", symbol: "chevron.left.forwardslash.chevron.right", glyph: nil, kind: .code, keywords: ["code", "snippet", "fence", "```"]),
        SlashItem(title: "Diagram", detail: "Mermaid flowchart", symbol: "point.3.connected.trianglepath.dotted", glyph: nil, kind: .code,
                  keywords: ["diagram", "flowchart", "mermaid", "chart", "graph", "flow", "workflow"], info: "mermaid",
                  starter: "flowchart LR\n  A[Start] --> B{Decide}\n  B -- Yes --> C[Do the thing]\n  B -- No --> D[Skip it]"),
        SlashItem(title: "Table", detail: "Rows and columns", symbol: "tablecells", glyph: nil, kind: .table, keywords: ["grid", "table", "columns"]),
        SlashItem(title: "Divider", detail: "---", symbol: "minus", glyph: nil, kind: .divider, keywords: ["hr", "line", "rule", "separator", "---"]),
    ]

    static func matching(_ query: String) -> [SlashItem] {
        let query = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        let prefix = all.filter { item in
            item.title.lowercased().hasPrefix(query) || item.keywords.contains { $0.hasPrefix(query) }
                || item.title.lowercased().split(separator: " ").contains { $0.hasPrefix(query) }
        }
        let contains = all.filter { item in
            !prefix.contains { $0.title == item.title } && item.title.lowercased().contains(query)
        }
        // An exact title first, then titles that start with the query, then the rest, each in menu order.
        func rank(_ item: SlashItem) -> Int {
            let title = item.title.lowercased()
            return title == query ? 0 : title.hasPrefix(query) && !title.contains(" ") ? 1 : title.hasPrefix(query) ? 2 : 3
        }
        let ranked = prefix.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
        return ranked + contains
    }

    var menuImage: NSImage? {
        if let symbol { return NSImage(systemSymbolName: symbol, accessibilityDescription: title) }
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let label = (glyph ?? "") as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.black]
            let textSize = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }
}

final class SlashMenuView: NSView {
    weak var editor: BlockEditorView?
    private(set) var items: [SlashItem] = []
    /// The highlighted row. Setting it only redraws; keyboard moves call
    /// `scrollSelectionVisible` themselves so the pointer never drags the list.
    var selected = 0 { didSet { if selected != oldValue { list.needsDisplay = true } } }
    private let glass = NSGlassEffectView()
    /// The glass's content: clips the list to the surface while it morphs.
    private let clipper = MorphClipView()
    private let list = SlashListView()
    /// The "/" the closed surface shows, as the button it grows out of.
    private let glyph = MorphGlyphView()
    private var morph = Morph()
    /// How far the list is scrolled, in points.
    private(set) var offset: CGFloat = 0

    static let rowHeight: CGFloat = 38
    static let width: CGFloat = 290
    static let maxRows = 8
    static let inset: CGFloat = 6
    /// Fewer rows when the window is short (the quick note pane).
    var rowLimit = SlashMenuView.maxRows

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A Liquid Glass panel, like the system's own menus.
        glass.style = .regular
        glass.cornerRadius = Self.openRadius
        addSubview(glass)
        list.owner = self
        clipper.wantsLayer = true
        clipper.layer?.masksToBounds = true
        clipper.addSubview(list)
        clipper.addSubview(glyph)
        glass.contentView = clipper
        list.wantsLayer = true
        list.layerUsesCoreImageFilters = true
        glyph.wantsLayer = true
        glyph.layerUsesCoreImageFilters = true
        glyph.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ items: [SlashItem]) {
        let titles = self.items.map(\.title)
        self.items = items
        if titles != items.map(\.title) {
            selected = 0
            offset = 0
        }
        selected = min(selected, max(0, items.count - 1))
        let rows = max(1, min(rowLimit, items.count))
        let height = CGFloat(rows) * Self.rowHeight + Self.inset * 2
        setFrameSize(NSSize(width: Self.width, height: height))
        layoutMorph()
        offset = min(offset, maxOffset)
        list.needsDisplay = true
    }

    var visibleRows: Int { max(1, min(rowLimit, items.count)) }

    var viewportHeight: CGFloat { CGFloat(visibleRows) * Self.rowHeight }
    var maxOffset: CGFloat { max(0, CGFloat(items.count) * Self.rowHeight - viewportHeight) }

    func row(at point: NSPoint) -> Int? {
        guard point.y >= Self.inset, point.y < Self.inset + viewportHeight else { return nil }
        let index = Int(floor((point.y - Self.inset + offset) / Self.rowHeight))
        return items.indices.contains(index) ? index : nil
    }

    /// Brings the selected row fully into view (for arrow keys).
    func scrollSelectionVisible() {
        let top = CGFloat(selected) * Self.rowHeight
        if top < offset { offset = top }
        if top + Self.rowHeight > offset + viewportHeight { offset = top + Self.rowHeight - viewportHeight }
        offset = min(max(0, offset), maxOffset)
        list.needsDisplay = true
    }

    /// Scrolls by points, following the trackpad one to one.
    func scroll(by delta: CGFloat) {
        let next = min(max(0, offset + delta), maxOffset)
        guard next != offset else { return }
        offset = next
        list.needsDisplay = true
    }

    /// Rows that are at least partly on screen.
    var visibleRange: Range<Int> {
        guard !items.isEmpty else { return 0..<0 }
        let first = max(0, Int(floor(offset / Self.rowHeight)))
        let last = min(items.count, Int(ceil((offset + viewportHeight) / Self.rowHeight)))
        return first..<max(first, last)
    }

    func choose(_ index: Int) {
        guard items.indices.contains(index) else { return }
        editor?.applySlash(items[index])
    }

    // MARK: Morph

    /// Opening from a corner button: the surface grows out of the button's
    /// circle, its corners easing from round to the menu's, while the list
    /// slides and fades in and the button's "/" slides and fades away.
    /// Closing runs it back. The button sits at the bottom-right corner.
    static let openRadius: CGFloat = 14
    var closedSize: CGFloat = 36
    private(set) var isClosing = false
    /// The morphing surface, in the menu's coordinates.
    var surfaceFrame: NSRect { glass.frame }
    private var link: CADisplayLink?
    private var completion: (() -> Void)?

    private struct Morph {
        /// 0 is the closed circle, 1 the open menu (overshooting a little).
        var surface: CGFloat = 1
        /// The list's opacity and focus; the glyph's, inverted.
        var fade: CGFloat = 1
        /// How far the list and glyph have slid.
        var motion: CGFloat = 1
        var from = (surface: CGFloat(1), fade: CGFloat(1), motion: CGFloat(1))
        var opening = true
        var start: CFTimeInterval = 0
    }

    private static let openEase = UnitBezier(0.34, 1.25, 0.64, 1)
    private static let closeEase = UnitBezier(0.22, 1, 0.36, 1)
    private static let openDuration = 0.35
    private static let closeDuration = 0.25
    private static let fadeDuration = 0.2
    private static let slide: CGFloat = 40
    private static let shrink: CGFloat = 0.97
    private static let blur: CGFloat = 2

    /// `fromClosed`: the menu was hidden, so it starts as the button.
    func morphOpen(fromClosed: Bool) {
        isClosing = false
        completion = nil
        if fromClosed {
            morph.surface = 0
            morph.fade = 0
            morph.motion = 0
        }
        run(opening: true)
    }

    func morphClose(_ done: @escaping () -> Void) {
        guard !isClosing else { completion = done; return }
        isClosing = true
        completion = done
        run(opening: false)
    }

    /// Shows the menu fully open, with no morph (the main editor's menu).
    func settleOpen() {
        link?.invalidate()
        link = nil
        isClosing = false
        morph.surface = 1
        morph.fade = 1
        morph.motion = 1
        layoutMorph()
    }

    private func run(opening: Bool) {
        morph.from = (morph.surface, morph.fade, morph.motion)
        morph.opening = opening
        morph.start = CACurrentMediaTime()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
            return
        }
        if link == nil {
            let link = displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }
        layoutMorph()
    }

    @objc private func tick() {
        let elapsed = CACurrentMediaTime() - morph.start
        let target: CGFloat = morph.opening ? 1 : 0
        func step(_ from: CGFloat, _ duration: Double, _ ease: UnitBezier) -> CGFloat {
            let t = min(1, elapsed / duration)
            return from + (target - from) * CGFloat(ease.solve(t))
        }
        morph.surface = step(morph.from.surface, morph.opening ? Self.openDuration : Self.closeDuration,
                             morph.opening ? Self.openEase : Self.closeEase)
        morph.fade = step(morph.from.fade, Self.fadeDuration, Self.closeEase)
        morph.motion = step(morph.from.motion, Self.openDuration, Self.closeEase)
        layoutMorph()
        let longest = morph.opening ? Self.openDuration : max(Self.closeDuration, Self.openDuration)
        if elapsed >= longest { finish() }
    }

    private func finish() {
        link?.invalidate()
        link = nil
        let target: CGFloat = morph.opening ? 1 : 0
        morph.surface = target
        morph.fade = target
        morph.motion = target
        layoutMorph()
        isClosing = false
        let done = completion
        completion = nil
        done?()
    }

    /// Puts the surface, list and glyph where the morph has them now.
    private func layoutMorph() {
        let open = bounds
        let size = closedSize
        let closed = NSRect(x: open.maxX - size, y: open.maxY - size, width: size, height: size)
        let p = morph.surface
        // Grown from the bottom-right corner; the open ease may overshoot.
        let width = max(size * 0.5, closed.width + (open.width - closed.width) * p)
        let height = max(size * 0.5, closed.height + (open.height - closed.height) * p)
        let surface = NSRect(x: open.maxX - width, y: open.maxY - height, width: width, height: height)
        let radius = max(0, size / 2 + (Self.openRadius - size / 2) * min(1, max(0, p)))
        glass.frame = surface
        glass.cornerRadius = radius
        clipper.frame = glass.bounds
        clipper.layer?.cornerRadius = radius

        // The list stays where the open menu has it; the surface reveals it.
        list.frame = NSRect(x: -surface.minX, y: -surface.minY, width: open.width, height: open.height)
        let fade = morph.fade
        let motion = morph.motion
        list.alphaValue = fade
        transform(list, x: Self.slide * (1 - motion), scale: Self.shrink + (1 - Self.shrink) * motion, blur: Self.blur * (1 - fade))

        // The "/" rides the surface's bottom-right corner, sliding off left.
        glyph.isHidden = fade >= 1 && motion >= 1
        glyph.frame = NSRect(x: surface.width - size, y: surface.height - size, width: size, height: size)
        glyph.alphaValue = 1 - fade
        transform(glyph, x: -Self.slide * motion, scale: 1, blur: Self.blur * fade)
    }

    private func transform(_ view: NSView, x: CGFloat, scale: CGFloat, blur: CGFloat) {
        guard let layer = view.layer else { return }
        let bounds = view.bounds
        // Scaled about the view's centre (a view's layer anchors at its corner).
        var t = CGAffineTransform(translationX: x + bounds.width * (1 - scale) / 2, y: bounds.height * (1 - scale) / 2)
        t = t.scaledBy(x: scale, y: scale)
        layer.setAffineTransform(t)
        if blur > 0.01 {
            let filter = CIFilter(name: "CIGaussianBlur")
            filter?.setValue(blur, forKey: kCIInputRadiusKey)
            layer.filters = filter.map { [$0] }
        } else if layer.filters != nil {
            layer.filters = nil
        }
    }
}

/// The glass's content view, flipped like the menu so frames line up.
private final class MorphClipView: NSView {
    override var isFlipped: Bool { true }
}

/// The corner button's "/", drawn as SwiftUI draws it there.
private final class MorphGlyphView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSFont.systemFont(ofSize: 17, weight: .medium)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: 17) } ?? base
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let size = ("/" as NSString).size(withAttributes: attributes)
        ("/" as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2), withAttributes: attributes)
    }
}

/// A CSS-style cubic-bézier timing curve.
struct UnitBezier {
    private let cx, bx, ax, cy, by, ay: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        cx = 3 * x1
        bx = 3 * (x2 - x1) - cx
        ax = 1 - cx - bx
        cy = 3 * y1
        by = 3 * (y2 - y1) - cy
        ay = 1 - cy - by
    }

    private func x(_ t: Double) -> Double { ((ax * t + bx) * t + cx) * t }
    private func y(_ t: Double) -> Double { ((ay * t + by) * t + cy) * t }
    private func dx(_ t: Double) -> Double { (3 * ax * t + 2 * bx) * t + cx }

    /// The curve's value at time `progress` (0…1).
    func solve(_ progress: Double) -> Double {
        if progress <= 0 { return 0 }
        if progress >= 1 { return 1 }
        var t = progress
        for _ in 0..<8 {
            let error = x(t) - progress
            if abs(error) < 1e-6 { return y(t) }
            let slope = dx(t)
            if abs(slope) < 1e-6 { break }
            t -= error / slope
        }
        // Bisection when Newton's method stalls.
        var low = 0.0, high = 1.0
        t = progress
        while high - low > 1e-6 {
            if x(t) < progress { low = t } else { high = t }
            t = (low + high) / 2
        }
        return y(t)
    }
}

private final class SlashListView: NSView {
    weak var owner: SlashMenuView?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        if owner.items.isEmpty {
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
            ("No results" as NSString).draw(at: NSPoint(x: 14, y: SlashMenuView.inset + 10), withAttributes: attributes)
            return
        }
        NSGraphicsContext.saveGraphicsState()
        // Rows slide under the panel's inset edges rather than over them.
        NSBezierPath(rect: NSRect(x: 0, y: SlashMenuView.inset, width: bounds.width, height: owner.viewportHeight)).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        for index in owner.visibleRange {
            let item = owner.items[index]
            let row = NSRect(x: SlashMenuView.inset, y: SlashMenuView.inset + CGFloat(index) * SlashMenuView.rowHeight - owner.offset,
                             width: bounds.width - SlashMenuView.inset * 2, height: SlashMenuView.rowHeight)
            if index == owner.selected {
                NSColor.labelColor.withAlphaComponent(0.1).setFill()
                NSBezierPath(roundedRect: row, xRadius: 8, yRadius: 8).fill()
            }
            let tile = NSRect(x: row.minX + 6, y: row.midY - 13, width: 26, height: 26)
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: tile, xRadius: 5, yRadius: 5).fill()
            NSColor.separatorColor.setStroke()
            let border = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            border.lineWidth = 0.5
            border.stroke()
            if let symbol = item.symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
                let tinted = image.tinted(.secondaryLabelColor)
                let size = tinted.size
                tinted.draw(in: NSRect(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2, width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            } else if let glyph = item.glyph {
                let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor]
                let size = (glyph as NSString).size(withAttributes: attributes)
                (glyph as NSString).draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2), withAttributes: attributes)
            }
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            (item.title as NSString).draw(at: NSPoint(x: tile.maxX + 10, y: row.minY + 4), withAttributes: title)
            let detail: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            (item.detail as NSString).draw(at: NSPoint(x: tile.maxX + 10, y: row.minY + 20), withAttributes: detail)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        guard let owner, let row = owner.row(at: convert(event.locationInWindow, from: nil)), row != owner.selected else { return }
        owner.selected = row
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner, let row = owner.row(at: convert(event.locationInWindow, from: nil)) else { return }
        owner.choose(row)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { return }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * SlashMenuView.rowHeight
        owner.scroll(by: -delta)
        // Keep the highlight under the pointer as the list moves beneath it.
        if let row = owner.row(at: convert(event.locationInWindow, from: nil)) { owner.selected = row }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let image = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return image
    }
}

// MARK: - The editor's side

extension BlockEditorView {
    func updateSlash(_ textView: BlockTextView, edit: (range: NSRange, string: String)?) {
        guard let index = index(of: textView.blockID) else { return }
        let string = textView.string as NSString
        if slash == nil, let edit, edit.string == "/", textView.cell == nil, blocks[index].kind.isText {
            let location = edit.range.location
            let before: unichar? = location > 0 ? string.character(at: location - 1) : nil
            if before == nil || before == 32 || before == 10 || before == 9 {
                slash = SlashState(id: textView.blockID, location: location, query: "")
            }
        }
        guard var state = slash else { return }
        guard state.id == textView.blockID, state.location < string.length, string.character(at: state.location) == 47 else {
            closeSlash()
            return
        }
        let caret = textView.selectedRange().location
        guard caret > state.location else { closeSlash(); return }
        let query = string.substring(with: NSRange(location: state.location + 1, length: caret - state.location - 1))
        if query.contains("\n") || (query as NSString).length > 24 { closeSlash(); return }
        let items = SlashItem.matching(query)
        if items.isEmpty, query.hasSuffix(" ") || (query as NSString).length > 12 { closeSlash(); return }
        state.query = query
        let wasHidden = slashMenu.isHidden
        let isOpening = wasHidden || slashMenu.isClosing
        slash = state
        if let corner = slashMenuCorner?() {
            // Pinned to a corner: as many rows as fit above it.
            let room = corner.maxY - visibleRect.minY - 12 - SlashMenuView.inset * 2
            slashMenu.rowLimit = max(3, min(SlashMenuView.maxRows, Int(room / SlashMenuView.rowHeight)))
        }
        slashMenu.show(items)
        slashMenu.isHidden = false
        hideHandle()
        positionSlashMenu()
        if isOpening {
            if let corner = slashMenuCorner?() {
                // It morphs out of the corner button, which steps aside for it.
                slashMenu.closedSize = min(corner.width, corner.height)
                onSlashMenuChange?(true)
                slashMenu.morphOpen(fromClosed: wasHidden)
            } else {
                slashMenu.settleOpen()
                onSlashMenuChange?(true)
            }
        }
    }

    func positionSlashMenu() {
        guard let state = slash, let textView = view(for: state.id)?.primaryTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, state.location < (textView.string as NSString).length else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: state.location, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let anchor = convert(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y), from: textView)
        let size = slashMenu.frame.size
        if let corner = slashMenuCorner?() {
            // Its bottom-right corner sits on the corner button's.
            slashMenu.setFrameOrigin(NSPoint(x: corner.maxX - size.width, y: corner.maxY - size.height))
            return
        }
        var y = anchor.maxY + 6
        if y + size.height > visibleRect.maxY - 8, anchor.minY - size.height - 6 > visibleRect.minY { y = anchor.minY - size.height - 6 }
        let x = min(max(8, anchor.minX - 8), bounds.width - size.width - 8)
        slashMenu.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func closeSlash() {
        guard slash != nil || !slashMenu.isHidden else { return }
        slash = nil
        if slashMenuCorner?() != nil, !slashMenu.isHidden {
            // Back into the corner button, which returns once it's there.
            slashMenu.morphClose { [weak self] in
                guard let self, self.slash == nil else { return }
                self.slashMenu.isHidden = true
                self.onSlashMenuChange?(false)
            }
            return
        }
        slashMenu.isHidden = true
        onSlashMenuChange?(false)
    }

    func handleSlashCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(moveUp(_:)):
            if !slashMenu.items.isEmpty { slashMenu.selected = (slashMenu.selected - 1 + slashMenu.items.count) % slashMenu.items.count; slashMenu.scrollSelectionVisible() }
            return true
        case #selector(moveDown(_:)):
            if !slashMenu.items.isEmpty { slashMenu.selected = (slashMenu.selected + 1) % slashMenu.items.count; slashMenu.scrollSelectionVisible() }
            return true
        case #selector(insertNewline(_:)), #selector(insertTab(_:)):
            if slashMenu.items.isEmpty { closeSlash(); return selector == #selector(insertTab(_:)) }
            slashMenu.choose(slashMenu.selected)
            return true
        case #selector(cancelOperation(_:)):
            closeSlash()
            return true
        default:
            return false
        }
    }

    func applySlash(_ item: SlashItem) {
        guard let state = slash, let index = index(of: state.id), let textView = view(for: state.id)?.primaryTextView,
              let storage = textView.textStorage else { closeSlash(); return }
        closeSlash()
        let end = min(storage.length, state.location + 1 + (state.query as NSString).length)
        storage.replaceCharacters(in: NSRange(location: state.location, length: end - state.location), with: "")
        textView.setSelectedRange(NSRange(location: state.location, length: 0))
        syncModel(from: textView, at: index)
        endTyping()
        let block = blocks[index]
        let isEmpty = storage.length == 0
        if let alert = item.alert {
            var callout = Block(kind: .quote)
            callout.alert = alert
            if isEmpty { callout = Block(id: block.id, kind: .quote).copying(from: callout) }
            mutate("Insert", focus: .text(callout.id, nil, NSRange(location: 0, length: 0))) { blocks in
                if isEmpty { blocks[index] = callout } else { blocks.insert(callout, at: index + 1) }
            }
            return
        }
        if let special = item.special {
            applySpecial(special, at: index, replacingEmpty: isEmpty)
            return
        }
        if let info = item.info {
            var fence = Block(kind: item.kind, text: NSAttributedString(string: item.starter))
            fence.info = info
            if isEmpty { fence = Block(id: block.id, kind: item.kind, text: fence.text).copying(from: fence) }
            let caret = NSRange(location: (item.starter as NSString).length, length: 0)
            mutate("Insert", focus: .text(fence.id, nil, caret)) { blocks in
                if isEmpty { blocks[index] = fence } else { blocks.insert(fence, at: index + 1) }
            }
            return
        }
        switch item.kind {
        case .image:
            changed()
            chooseMedia(video: item.video)
        case .table, .divider:
            insertBlock(item.kind, after: index, replacingEmpty: isEmpty)
        default:
            if isEmpty {
                if block.kind != item.kind { convert(index: index, to: item.kind, name: "Insert") } else { changed() }
            } else {
                insertBlock(item.kind, after: index, replacingEmpty: false)
            }
        }
    }

    /// Inserts a block that needs more than its kind.
    private func applySpecial(_ special: String, at index: Int, replacingEmpty isEmpty: Bool) {
        switch special {
        case "pdf":
            changed()
            chooseFiles([.pdf])
        case "audio":
            changed()
            chooseFiles([.audio])
        case "file":
            changed()
            chooseFiles([])
        case "note":
            let names = noteNames?() ?? []
            let menu = NSMenu()
            if names.isEmpty {
                let empty = NSMenuItem(title: "No other notes yet", action: nil, keyEquivalent: "")
                empty.isEnabled = false
                menu.addItem(empty)
            }
            for name in names.prefix(60) {
                menu.addItem(ClosureMenuItem(title: name) { [weak self] in
                    var block = Block(kind: .embed)
                    block.info = "note"
                    block.imageSource = name
                    self?.insertEmbed(block, at: index, replacingEmpty: isEmpty)
                })
            }
            let anchor = view(for: blocks[index].id).map { NSPoint(x: $0.frame.minX, y: $0.frame.maxY + 4) } ?? .zero
            menu.popUp(positioning: nil, at: anchor, in: self)
        default:
            var block = Block(kind: .embed)
            if special == "toc" { block.info = "toc" }
            insertEmbed(block, at: index, replacingEmpty: isEmpty)
        }
    }

    func insertEmbed(_ embed: Block, at index: Int, replacingEmpty: Bool) {
        let replace = replacingEmpty && blocks.indices.contains(index) && blocks[index].kind == .paragraph && blocks[index].text.length == 0
        var block = embed
        if replace { block = Block(id: blocks[index].id, kind: .embed).copying(from: embed) }
        let position = replace ? index : index + 1
        let needsParagraph = !(blocks.indices.contains(position + (replace ? 1 : 0)) && blocks[position + (replace ? 1 : 0)].kind.isText)
        let paragraph = Block(kind: .paragraph)
        // An empty embed waits for its link; the rest put the caret after them.
        let focus: FocusTarget = embed.info.isEmpty && embed.imageSource.isEmpty ? .none
            : needsParagraph ? .text(paragraph.id, nil, NSRange(location: 0, length: 0)) : .blocks([block.id])
        mutate("Insert", focus: focus) { blocks in
            if replace { blocks[index] = block } else { blocks.insert(block, at: min(blocks.count, index + 1)) }
            if needsParagraph { blocks.insert(paragraph, at: min(blocks.count, position + 1)) }
        }
    }
}
