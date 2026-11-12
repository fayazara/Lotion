//
//  BlockEditorView.swift
//  Lotion
//
//  The note editor: a column of block views in a scroll view. It owns the
//  note's blocks, keeps one view per block, and makes every change to them
//  as an undoable step. Text views edit text inside a block; everything that
//  changes the list of blocks goes through here.
//

import AppKit

final class BlockEditorView: NSView {
    // MARK: State

    var blocks: [Block] = []
    var trailingNewlines = 1
    private(set) var views: [BlockView] = []
    private var indexByID: [UUID: Int] = [:]
    private(set) var theme: BlockTheme

    /// The note's undo history.
    var noteUndoManager: UndoManager?
    /// Called after every change to the blocks.
    var onChange: (() -> Void)?
    /// Another note by name, for `![[Name]]` embeds: its title and Markdown.
    var noteLookup: ((String) -> (title: String, text: String)?)?
    /// Opens another note by name.
    var openNoteNamed: ((String) -> Void)?
    /// The names notes can be embedded by, for the slash menu.
    var noteNames: (() -> [String])?
    /// The note's folder, for images with relative paths.
    var baseURL: URL?
    /// Where remote images and videos are kept once fetched, so they load from disk after.
    var mediaCacheURL: URL?
    /// Copies an image or video into the note's folder; returns its link.
    var attachmentHandler: ((AttachmentInput) -> String?)?

    var readableWidth: CGFloat = 700 { didSet { if readableWidth != oldValue { relayout() } } }
    private(set) var columnX: CGFloat = 0
    private(set) var columnWidth: CGFloat = 600
    private(set) var contentBottom: CGFloat = 0
    var topInset: CGFloat { compactInsets?.top ?? cover.topInset }
    /// Tighter margins for a small window (the quick note pane): the space
    /// above the first block and at each side of the column.
    var compactInsets: (top: CGFloat, side: CGFloat)? { didSet { relayout() } }
    /// Where the slash menu opens from, in this view, instead of under the
    /// caret: the quick note pane's corner button.
    var slashMenuCorner: (() -> NSRect?)?
    /// Called as the slash menu opens (true) and closes (false).
    var onSlashMenuChange: ((Bool) -> Void)?

    /// Blocks selected as whole blocks, by index.
    var blockSelection: ClosedRange<Int>? { didSet { if blockSelection != oldValue { needsDisplay = true } } }
    var selectionAnchor = 0
    var selectionHead = 0

    // Typing
    var typingBlock: UUID?
    var isChangingText = false
    var pendingEdit: (range: NSRange, string: String)?
    var isConvertingLinks = false
    /// While set, putting the caret back doesn't scroll to it.
    var keepsScroll = false

    // Slash menu
    var slash: SlashState?
    let slashMenu = SlashMenuView()

    // Hover handle, drag and selection feedback
    let handle = BlockHandleView()
    var handleIndex: Int?
    var dropIndicator: CGFloat? { didSet { if dropIndicator != oldValue { needsDisplay = true } } }
    var rubberBand: NSRect? { didSet { if rubberBand != oldValue { needsDisplay = true } } }
    var crossBlockDrag: (from: Int, to: Int)?
    var hoverTracking: NSTrackingArea?

    let cover = CoverHeader()
    /// The heading map beside the note, kept current as it scrolls and changes.
    weak var scrollSpy: ScrollSpy?
    /// Showing the scratchpad: no title, entries split by full-width breaks.
    var isScratchpad = false

    init(theme: BlockTheme) {
        self.theme = theme
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        autoresizingMask = [.width]
        cover.install(in: self)
        handle.editor = self
        handle.isHidden = true
        addSubview(handle)
        slashMenu.editor = self
        slashMenu.isHidden = true
        addSubview(slashMenu)
        registerForMediaDrops()
        NotificationCenter.default.addObserver(self, selector: #selector(faviconsDidLoad), name: Favicons.didLoad, object: nil)
    }

    /// Redraws text so newly fetched favicons appear.
    @objc private func faviconsDidLoad() {
        func redraw(_ view: NSView) {
            for subview in view.subviews {
                if subview is BlockTextView { subview.needsDisplay = true } else { redraw(subview) }
            }
        }
        for view in views where view.isMaterialized { redraw(view) }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { noteUndoManager ?? super.undoManager }

    func index(of id: UUID) -> Int? { indexByID[id] }

    /// A table's add buttons float over the blocks around it; they come first.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for case let table as TableBlockView in views where table.isMaterialized {
            if let button = table.addButton(atEditorPoint: local) { return button }
        }
        return super.hitTest(point)
    }
    func view(for id: UUID) -> BlockView? { indexByID[id].map { views[$0] } }
    func isTitle(_ id: UUID) -> Bool { !isScratchpad && blocks.first?.id == id && blocks.first?.kind == .heading(1) }

    // MARK: Loading

    func load(_ document: BlockMarkdown.Document) {
        MediaZoom.shared.hide(animated: false)
        closeSlash()
        blockSelection = nil
        typingBlock = nil
        // Every block view goes, including any a change failed to clean up.
        for case let view as BlockView in subviews { view.removeFromSuperview() }
        views = []
        var blocks = document.blocks
        if blocks.isEmpty { blocks = [Block(kind: isScratchpad ? .paragraph : .heading(1))] }
        if isScratchpad { Self.normalizeScratchpad(&blocks) }
        trailingNewlines = document.trailingNewlines
        self.blocks = blocks
        views = blocks.map { makeView(for: $0) }
        for view in views { addSubview(view, positioned: .below, relativeTo: handle) }
        rebuildIndex()
        updateNumbers()
        relayout()
    }

    func markdown() -> String {
        BlockMarkdown.write(blocks, trailingNewlines: trailingNewlines)
    }

    func apply(theme: BlockTheme) {
        self.theme = theme
        for view in views { view.apply(theme: theme) }
        cover.applyTheme(theme)
        relayout()
        needsDisplay = true
    }

    private func viewClass(for block: Block) -> BlockView.Type {
        switch block.kind {
        case .code: block.isDiagram ? DiagramBlockView.self : CodeBlockView.self
        case .divider: DividerBlockView.self
        case .entry: EntryBreakView.self
        case .image:
            switch MediaKind.of(block.imageSource) {
            case .pdf: PDFBlockView.self
            case .audio: AudioBlockView.self
            default: MediaBlockView.self
            }
        case .html: IframeHTML.parse(block.text.string) != nil ? EmbedBlockView.self : HTMLBlockView.self
        case .embed:
            switch block.info {
            case "toc": TocBlockView.self
            case "note": NoteEmbedBlockView.self
            case "file": FileBlockView.self
            default: EmbedBlockView.self
            }
        case .table: TableBlockView.self
        default: TextBlockView.self
        }
    }

    private func makeView(for block: Block) -> BlockView {
        viewClass(for: block).init(block: block, theme: theme, editor: self)
    }

    private func rebuildIndex() {
        indexByID = Dictionary(uniqueKeysWithValues: blocks.enumerated().map { ($1.id, $0) })
    }

    /// Replaces the blocks, keeping the views of blocks that stayed.
    func setBlocks(_ newBlocks: [Block]) {
        var blocks = newBlocks
        if blocks.isEmpty { blocks = [Block(kind: .paragraph)] }
        if isScratchpad { Self.normalizeScratchpad(&blocks) }
        Self.normalizeIndents(&blocks)
        let oldTitle = self.blocks.first?.id
        var reusable: [UUID: BlockView] = [:]
        for view in views { reusable[view.block.id] = view }
        var newViews: [BlockView] = []
        newViews.reserveCapacity(blocks.count)
        for block in blocks {
            // Take the old view out once, and keep hold of it: a block that changed
            // kind (a paragraph turned into a table) needs its old view removed, or
            // it stays on screen with nothing behind it.
            let old = reusable.removeValue(forKey: block.id)
            if let view = old, type(of: view) == viewClass(for: block) {
                if !Self.sameContent(view.block, block) {
                    view.update(block)
                } else {
                    view.adopt(block)
                }
                newViews.append(view)
            } else {
                if let old {
                    if let responder = window?.firstResponder as? NSView, responder.isDescendant(of: old) {
                        window?.makeFirstResponder(self)
                    }
                    old.removeFromSuperview()
                }
                let view = makeView(for: block)
                addSubview(view, positioned: .below, relativeTo: handle)
                newViews.append(view)
            }
        }
        for view in reusable.values { view.removeFromSuperview() }
        self.blocks = blocks
        views = newViews
        rebuildIndex()
        updateNumbers()
        if oldTitle != blocks.first?.id || true {
            for view in views.prefix(2) { (view as? TextBlockView)?.updatePlaceholder() }
            if let oldTitle, let old = self.view(for: oldTitle) as? TextBlockView { old.updatePlaceholder() }
        }
        relayout()
    }

    static func sameContent(_ a: Block, _ b: Block) -> Bool {
        a.kind == b.kind && a.indent == b.indent && a.checked == b.checked && a.info == b.info
            && a.imageSource == b.imageSource && a.imageAlt == b.imageAlt && a.table == b.table
            && a.alert == b.alert && a.isBareLink == b.isBareLink
            && a.text.isEqual(to: b.text)
    }

    /// A scratchpad always opens with an entry's break, and always has a
    /// line to write on after its last one, however it was edited.
    static func normalizeScratchpad(_ blocks: inout [Block]) {
        if blocks.first?.kind != .entry {
            var first = Block(kind: .entry)
            first.info = Date.now.formatted(.iso8601)
            blocks.insert(first, at: 0)
        }
        if blocks.last?.kind == .entry { blocks.append(Block(kind: .paragraph)) }
    }

    /// Keeps nesting possible: a block can sit at most one level under a list item before it.
    static func normalizeIndents(_ blocks: inout [Block]) {
        for index in blocks.indices {
            if blocks[index].kind.headingLevel != nil { blocks[index].indent = 0; continue }
            guard blocks[index].indent > 0 else { continue }
            let maximum: Int
            if index == 0 {
                maximum = 0
            } else {
                let previous = blocks[index - 1]
                maximum = previous.kind.isList ? previous.indent + 1 : previous.indent
            }
            if blocks[index].indent > maximum {
                blocks[index].indent = maximum
                blocks[index].touch()
            }
        }
    }

    private func updateNumbers() {
        let numbers = BlockMarkdown.listNumbers(blocks)
        for (index, view) in views.enumerated() {
            guard let view = view as? TextBlockView else { continue }
            let old = view.number
            view.number = numbers[index]
            if String(old ?? 1).count != String(numbers[index] ?? 1).count { view.invalidateHeight() }
        }
    }

    /// Writes a block the editor changed back into the model and its view.
    func replace(_ block: Block) {
        guard let index = indexByID[block.id] else { return }
        blocks[index] = block
        views[index].update(block)
        relayout(from: index)
    }

    // MARK: Layout

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { relayout() }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        if let clip = superview as? NSClipView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll), name: NSView.boundsDidChangeNotification, object: clip)
            NotificationCenter.default.addObserver(self, selector: #selector(clipDidResize), name: NSView.frameDidChangeNotification, object: clip)
            clipDidResize()
        }
    }

    /// The editor is always exactly as wide as what shows of it: notes never scroll sideways.
    @objc private func clipDidResize() {
        guard let clip = superview as? NSClipView else { return }
        let width = clip.bounds.width
        if width > 0, frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        if frame.origin.x != 0 { setFrameOrigin(NSPoint(x: 0, y: frame.origin.y)) }
        relayout()
    }

    @objc private func clipDidScroll() {
        LinkPreview.shared.hide()
        materializeVisible()
        if slash != nil { positionSlashMenu() }
        updateScrollSpyActive()
    }

    func relayout(from start: Int = 0) {
        let width = bounds.width
        let margin = compactInsets?.side ?? max(64, round(width * 0.06))
        let newWidth = min(readableWidth, max(240, width - margin * 2))
        let newX = round((width - newWidth) / 2)
        let moved = newWidth != columnWidth || newX != columnX
        columnWidth = newWidth
        columnX = newX
        let first = moved ? 0 : max(0, min(start, views.count))
        var y = first == 0 ? topInset : views[first - 1].frame.maxY
        for index in first..<views.count {
            y += theme.spacing(before: blocks[index], after: index > 0 ? blocks[index - 1] : nil,
                               isAfterTitle: !isScratchpad && index == 1 && blocks[0].kind == .heading(1))
            let view = views[index]
            let height = view.height(for: columnWidth)
            // A scratchpad's entry breaks run edge to edge.
            let rect = blocks[index].kind == .entry
                ? NSRect(x: 0, y: y, width: width, height: height)
                : NSRect(x: columnX, y: y, width: columnWidth, height: height)
            if view.frame != rect {
                let resized = view.frame.size != rect.size
                view.frame = rect
                view.needsLayout = true
                if resized { view.needsDisplay = true }
            }
            y += height
        }
        contentBottom = y
        let visible = enclosingScrollView?.contentSize.height ?? 600
        let height = max(visible, ceil(y + max(160, visible * 0.35)))
        let clipWidth = (superview as? NSClipView)?.bounds.width ?? frame.width
        if frame.height != height || frame.width != clipWidth { super.setFrameSize(NSSize(width: clipWidth, height: height)) }
        cover.layout(in: self)
        materializeVisible()
        updateHandlePosition()
        if slash != nil { positionSlashMenu() }
        updateScrollSpyEntries()
        needsDisplay = true
    }

    /// Builds the text views of blocks on or near the screen.
    func materializeVisible() {
        let visible = visibleRect.insetBy(dx: 0, dy: -max(600, visibleRect.height))
        guard !views.isEmpty else { return }
        // Views are in order; find the first one that reaches the area.
        var low = 0
        var high = views.count - 1
        while low < high {
            let mid = (low + high) / 2
            if views[mid].frame.maxY < visible.minY { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < views.count, views[index].frame.minY <= visible.maxY {
            if !views[index].isMaterialized { views[index].materialize() }
            index += 1
        }
    }

    func blockHeightMayHaveChanged(_ id: UUID) {
        guard let index = indexByID[id] else { return }
        let view = views[index]
        view.invalidateHeight()
        let height = view.height(for: columnWidth)
        if height != view.frame.height {
            relayout(from: index)
        } else {
            view.needsLayout = true
        }
    }

    /// The block whose row (its spacing above included) holds `y`.
    func blockIndex(atY y: CGFloat) -> Int? {
        guard !views.isEmpty else { return nil }
        if y < views[0].frame.minY { return 0 }
        var low = 0
        var high = views.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            let top = mid == 0 ? 0 : views[mid - 1].frame.maxY
            if top <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    // MARK: Focus

    var focusedTextView: BlockTextView? {
        guard let view = window?.firstResponder as? BlockTextView, view.editor === self else { return nil }
        return view
    }

    var focusedIndex: Int? { focusedTextView.flatMap { indexByID[$0.blockID] } }

    func focus(_ id: UUID, _ placement: CaretPlacement) {
        guard let index = indexByID[id] else { return }
        blockSelection = nil
        let view = views[index]
        view.materialize()
        if let table = view as? TableBlockView {
            focusTable(table, placement)
        } else {
            view.focus(placement)
        }
        if let textView = focusedTextView, !keepsScroll { scrollCaretVisible(textView) }
    }

    private func focusTable(_ table: TableBlockView, _ placement: CaretPlacement) {
        let rows = table.rowCount
        let position: CellPosition
        var cellPlacement = placement
        switch placement {
        case .end:
            position = CellPosition(row: rows - 1, column: table.columnCount - 1)
        case .line(let first, let x):
            var column = 0
            for index in 0..<table.columnCount {
                guard let cell = table.cell(CellPosition(row: 0, column: index)) else { continue }
                if convert(cell.frame, from: cell.superview).minX - TableBlockView.paddingX <= x { column = index }
            }
            position = CellPosition(row: first ? 0 : rows - 1, column: column)
            cellPlacement = .line(first: first, x: x)
        default:
            position = CellPosition(row: 0, column: 0)
        }
        focusCell(position, in: table.block.id, placement: cellPlacement)
    }

    func focusCell(_ position: CellPosition, in id: UUID, placement: CaretPlacement) {
        guard let table = view(for: id) as? TableBlockView, let cell = table.cell(position) else { return }
        blockSelection = nil
        window?.makeFirstResponder(cell)
        table.place(placement, in: cell)
        table.reveal(cell)
        if !keepsScroll { scrollCaretVisible(cell) }
    }

    func focusedCell(in table: TableBlockView) -> (position: CellPosition, offset: Int)? {
        guard let view = focusedTextView, view.blockID == table.block.id, let cell = view.cell else { return nil }
        return (cell, view.selectedRange().location)
    }

    func scrollCaretVisible(_ textView: BlockTextView) {
        let caret = convert(textView.caretRect, from: textView)
        scrollToVisible(caret.insetBy(dx: 0, dy: -48))
    }

    func textViewDidFocus(_ textView: BlockTextView) {
        blockSelection = nil
        if typingBlock != textView.blockID { typingBlock = nil }
        if let index = indexByID[textView.blockID] {
            (views[index] as? TableBlockView)?.focusDidChange()
            (views[index] as? TextBlockView)?.textView?.needsDisplay = true
        }
    }

    func textViewDidBlur(_ textView: BlockTextView) {
        typingBlock = nil
        if let index = indexByID[textView.blockID], !isConvertingLinks {
            isConvertingLinks = true
            convertMarkdownLinks(in: textView, at: index, sparingCaret: false)
            isConvertingLinks = false
        }
        if let html = view(for: textView.blockID) as? HTMLBlockView {
            DispatchQueue.main.async { [weak self, weak html] in
                guard let html, self?.focusedTextView?.blockID != html.block.id else { return }
                html.endEditing()
            }
        }
        if let diagram = view(for: textView.blockID) as? DiagramBlockView {
            DispatchQueue.main.async { [weak self, weak diagram] in
                guard let diagram, self?.focusedTextView?.blockID != diagram.block.id else { return }
                diagram.endEditing()
            }
        }
        if slash?.id == textView.blockID { closeSlash() }
        if let index = indexByID[textView.blockID] {
            DispatchQueue.main.async { [weak self] in
                guard let self, index < self.views.count else { return }
                (self.views[index] as? TableBlockView)?.focusDidChange()
            }
        }
    }

    // MARK: Undo

    enum FocusTarget {
        case text(UUID, CellPosition?, NSRange)
        case blocks([UUID])
        case none
    }

    struct Snapshot {
        let blocks: [Block]
        let focus: FocusTarget
    }

    func currentFocus() -> FocusTarget {
        if let selection = blockSelection {
            return .blocks(selection.compactMap { blocks.indices.contains($0) ? blocks[$0].id : nil })
        }
        if let view = focusedTextView { return .text(view.blockID, view.cell, view.selectedRange()) }
        return .none
    }

    /// Records the current state as the undo step for the change about to happen.
    func registerUndo(_ name: String) {
        endTyping()
        record(Snapshot(blocks: blocks, focus: currentFocus()), name: name)
    }

    private func record(_ snapshot: Snapshot, name: String) {
        guard let manager = noteUndoManager else { return }
        // Every change is its own step, however many happen in one event.
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { editor in
            MainActor.assumeIsolated { editor.restore(snapshot, name: name) }
        }
        manager.setActionName(name)
        manager.endUndoGrouping()
    }

    private func restore(_ snapshot: Snapshot, name: String) {
        endTyping()
        record(Snapshot(blocks: blocks, focus: currentFocus()), name: name)
        closeSlash()
        setBlocks(snapshot.blocks)
        apply(snapshot.focus)
        changed()
    }

    func apply(_ target: FocusTarget) {
        switch target {
        case .text(let id, let cell, let range):
            if let cell {
                focusCell(cell, in: id, placement: .range(range))
            } else {
                focus(id, .range(range))
            }
        case .blocks(let ids):
            selectBlocks(ids)
        case .none:
            break
        }
    }

    func endTyping() { typingBlock = nil }

    func beginTyping(_ textView: BlockTextView) {
        guard typingBlock != textView.blockID else { return }
        registerUndo("Typing")
        typingBlock = textView.blockID
    }

    func undo() {
        endTyping()
        if noteUndoManager?.canUndo == true { noteUndoManager?.undo() }
    }

    func redo() {
        endTyping()
        if noteUndoManager?.canRedo == true { noteUndoManager?.redo() }
    }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }

    func changed() {
        onChange?()
        for case let toc as TocBlockView in views { toc.refresh() }
        // Typing can rename a heading or an entry without changing any height.
        updateScrollSpyEntries()
    }

    // MARK: Structure

    /// Runs a change to the block list as one undo step.
    /// `keepScroll` puts the caret back without scrolling to it, for changes
    /// made elsewhere on the page (a checkbox clicked far from the caret).
    func mutate(_ name: String, focus: FocusTarget? = nil, keepScroll: Bool = false, _ change: (inout [Block]) -> Void) {
        registerUndo(name)
        closeSlash()
        var new = blocks
        change(&new)
        setBlocks(new)
        if let focus {
            keepsScroll = keepScroll
            apply(focus)
            keepsScroll = false
        }
        changed()
    }

    /// The block and the blocks nested under it.
    func subtree(at index: Int) -> ClosedRange<Int> {
        let indent = blocks[index].indent
        var end = index
        while end + 1 < blocks.count, blocks[end + 1].indent > indent { end += 1 }
        return index...end
    }

    // MARK: Drawing

    /// How far a selection sits outside the blocks it holds, on every side.
    static let selectionPadding: CGFloat = 6

    /// The selection wraps the blocks' own shapes at an even distance, its
    /// corners the blocks' radius plus that distance so the curves stay parallel.
    private func drawBlockHighlight(_ range: ClosedRange<Int>) {
        let palette = theme.palette
        var rect = NSRect.null
        var radius: CGFloat = 0
        for index in range {
            let view = views[index]
            let shape = view.selectionShape
            rect = rect.union(convert(shape.rect, from: view))
            radius = max(radius, shape.radius)
        }
        guard !rect.isNull else { return }
        let padding = Self.selectionPadding
        let outer = rect.insetBy(dx: -padding, dy: -padding)
        let corner = radius + padding
        palette.selection.withAlphaComponent(palette.isDark ? 0.3 : 0.18).setFill()
        NSBezierPath(roundedRect: outer, xRadius: corner, yRadius: corner).fill()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        if let selection = blockSelection, views.indices.contains(selection.lowerBound), views.indices.contains(selection.upperBound) {
            drawBlockHighlight(selection)
        }
        if let drag = crossBlockDrag {
            let low = min(drag.from, drag.to)
            let high = max(drag.from, drag.to)
            if views.indices.contains(low), views.indices.contains(high) { drawBlockHighlight(low...high) }
        }
        if let y = dropIndicator {
            palette.accent.setFill()
            NSBezierPath(roundedRect: NSRect(x: columnX, y: y - 1.5, width: columnWidth, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
        }
        if let band = rubberBand {
            palette.accent.withAlphaComponent(0.08).setFill()
            band.fill()
            palette.accent.withAlphaComponent(0.4).setStroke()
            let path = NSBezierPath(rect: band.insetBy(dx: 0.5, dy: 0.5))
            path.lineWidth = 1
            path.stroke()
        }
    }

    // MARK: Lookups for views

    func resolveImageURL(_ source: String) -> URL? {
        if source.hasPrefix("http://") || source.hasPrefix("https://") { return URL(string: source) }
        if source.hasPrefix("file://") { return URL(string: source) }
        let path = source.removingPercentEncoding ?? source
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return baseURL?.appending(path: path)
    }

    // MARK: Reveal

    /// Shows the `ordinal`th heading (levels 1–3), with the caret at its end.
    func revealHeading(_ ordinal: Int) {
        var count = 0
        for block in blocks {
            guard let level = block.kind.headingLevel, level <= 3, !block.plainText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if count == ordinal {
                focus(block.id, .end)
                if let view = view(for: block.id) {
                    let rect = view.frame
                    let target = NSRect(x: rect.minX, y: max(0, rect.minY - 24), width: rect.width, height: visibleRect.height * 0.6)
                    scrollToVisible(target)
                }
                return
            }
            count += 1
        }
    }

    /// Selects the first match of `query` in the note.
    func revealMatch(_ query: String) {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        for block in blocks {
            if block.kind == .table, let table = block.table {
                for (row, cells) in table.rows.enumerated() {
                    for (column, cell) in cells.enumerated() {
                        let range = (cell.string as NSString).range(of: query, options: options)
                        if range.location != NSNotFound {
                            focusCell(CellPosition(row: row, column: column), in: block.id, placement: .range(range))
                            return
                        }
                    }
                }
                continue
            }
            guard block.kind.isEditable else { continue }
            let range = (block.text.string as NSString).range(of: query, options: options)
            if range.location != NSNotFound {
                focus(block.id, .range(range))
                return
            }
        }
    }

    /// Where the caret or selection is, to restore when the note opens again.
    func viewState() -> FocusTarget { currentFocus() }
}

struct SlashState {
    let id: UUID
    /// Where the `/` is in the block's text.
    let location: Int
    var query: String
    var selected = 0
}
