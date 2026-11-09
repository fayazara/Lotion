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
    private let list = SlashListView()
    /// How far the list is scrolled, in points.
    private(set) var offset: CGFloat = 0

    static let rowHeight: CGFloat = 38
    static let width: CGFloat = 290
    static let maxRows = 8
    static let inset: CGFloat = 6

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A Liquid Glass panel, like the system's own menus.
        glass.style = .regular
        glass.cornerRadius = 14
        addSubview(glass)
        list.owner = self
        glass.contentView = list
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
        let rows = max(1, min(Self.maxRows, items.count))
        let height = CGFloat(rows) * Self.rowHeight + Self.inset * 2
        setFrameSize(NSSize(width: Self.width, height: height))
        glass.frame = bounds
        list.frame = bounds
        offset = min(offset, maxOffset)
        list.needsDisplay = true
    }

    var visibleRows: Int { max(1, min(Self.maxRows, items.count)) }

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
        slash = state
        slashMenu.show(items)
        slashMenu.isHidden = false
        hideHandle()
        positionSlashMenu()
    }

    func positionSlashMenu() {
        guard let state = slash, let textView = view(for: state.id)?.primaryTextView, let layoutManager = textView.layoutManager,
              let container = textView.textContainer, state.location < (textView.string as NSString).length else { return }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: state.location, length: 1), actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let anchor = convert(rect.offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y), from: textView)
        let size = slashMenu.frame.size
        var y = anchor.maxY + 6
        if y + size.height > visibleRect.maxY - 8, anchor.minY - size.height - 6 > visibleRect.minY { y = anchor.minY - size.height - 6 }
        let x = min(max(8, anchor.minX - 8), bounds.width - size.width - 8)
        slashMenu.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func closeSlash() {
        guard slash != nil || !slashMenu.isHidden else { return }
        slash = nil
        slashMenu.isHidden = true
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
