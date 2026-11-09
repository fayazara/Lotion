//
//  BlockEditorView+Blocks.swift
//  Lotion
//
//  Working with whole blocks: clicks beside the text, selecting blocks
//  (Escape, Shift-arrows, dragging across blocks or from the margin), the
//  hover handle with its menu, dragging blocks to reorder them, and the keys
//  that act on selected blocks.
//

import AppKit

extension BlockEditorView {
    func updateModel(_ block: Block, at index: Int) {
        blocks[index] = block
        views[index].adopt(block)
    }

    // MARK: Clicks

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        LinkPreview.shared.hide()
        closeSlash()
        if cover.mouseDown(at: point, in: self) { return }
        guard !views.isEmpty else { return }
        if point.y > contentBottom + 4 {
            clickBelowContent()
            return
        }
        guard let index = blockIndex(atY: point.y) else { return }
        let view = views[index]
        let local = view.convert(point, from: self)
        if view.bounds.contains(local), view.mouseDownOutsideText(at: local, event: event) { return }
        let inColumn = point.x >= columnX - 12 && point.x <= columnX + columnWidth + 12
        if inColumn, view is TextBlockView, let textView = view.primaryTextView {
            // Beside or between lines of text: let the text view place the caret and track the drag.
            window?.makeFirstResponder(textView)
            textView.mouseDown(with: event)
            return
        }
        trackMarginDrag(from: point, event: event, index: index)
    }

    private func clickBelowContent() {
        if let last = blocks.last, last.kind.isText, last.kind.headingLevel == nil || blocks.count == 1 {
            focus(last.id, .end)
            return
        }
        let paragraph = Block(kind: .paragraph)
        mutate("New Block", focus: .text(paragraph.id, nil, NSRange(location: 0, length: 0))) { blocks in
            blocks.append(paragraph)
        }
    }

    /// From the margin: a drag selects blocks with a band, a click puts the caret on that line.
    private func trackMarginDrag(from start: NSPoint, event: NSEvent, index: Int) {
        var dragged = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            if !dragged, hypot(point.x - start.x, point.y - start.y) < 4 { continue }
            dragged = true
            let band = NSRect(x: min(start.x, point.x), y: min(start.y, point.y), width: abs(point.x - start.x), height: abs(point.y - start.y))
            rubberBand = band
            let hits = views.indices.filter { views[$0].frame.intersects(NSRect(x: columnX, y: band.minY, width: columnWidth, height: max(1, band.height))) }
            if let first = hits.first, let last = hits.last, band.maxX >= columnX - 60, band.minX <= columnX + columnWidth + 60 {
                if window?.firstResponder !== self { window?.makeFirstResponder(self) }
                blockSelection = first...last
                selectionAnchor = start.y < point.y ? first : last
                selectionHead = start.y < point.y ? last : first
            } else {
                blockSelection = nil
            }
            autoscroll(with: next)
        }
        rubberBand = nil
        guard !dragged else { return }
        let view = views[index]
        if view is HTMLBlockView || view is DiagramBlockView {
            selectBlocks([view.block.id])
            return
        }
        guard let textView = view.primaryTextView else {
            if !view.block.kind.isEditable { selectBlocks([view.block.id]) }
            return
        }
        window?.makeFirstResponder(textView)
        let local = textView.convert(NSPoint(x: start.x < columnX ? textView.frame.minX - 1 : 100_000, y: start.y), from: self)
        let clampedX = start.x < columnX ? 0 : textView.bounds.width
        let target = textView.characterIndex(near: NSPoint(x: clampedX, y: local.y))
        textView.setSelectedRange(NSRange(location: target, length: 0))
    }

    // MARK: Text view mouse

    /// Before a text view handles a click. Returns true when the click was handled here.
    func textViewMouseDown(_ textView: BlockTextView, event: NSEvent) -> Bool {
        closeSlash()
        LinkPreview.shared.hide()
        if event.modifierFlags.contains(.command), let storage = textView.textStorage, storage.length > 0 {
            let point = textView.convert(event.locationInWindow, from: nil)
            let index = min(storage.length - 1, textView.characterIndex(near: point))
            for probe in [index, max(0, index - 1)] {
                if let url = storage.attribute(.lotionLink, at: probe, effectiveRange: nil) as? String {
                    open(link: url)
                    return true
                }
            }
        }
        crossBlockDrag = nil
        return false
    }

    func open(link: String) {
        var string = link
        if string.hasPrefix("www.") { string = "https://" + string }
        if string.contains("@"), !string.contains(":") { string = "mailto:" + string }
        if let url = URL(string: string), url.scheme != nil {
            NSWorkspace.shared.open(url)
        } else if let url = resolveImageURL(link) {
            NSWorkspace.shared.open(url)
        }
    }

    /// While a text view tracks a drag: leaving the block turns it into a block selection.
    func textViewDragged(_ textView: BlockTextView) {
        // Only a real drag counts; a click also reports a selection while the button is down.
        guard textView.cell == nil, let event = NSApp.currentEvent, event.type == .leftMouseDragged,
              event.window === window, let from = index(of: textView.blockID) else { return }
        let point = convert(event.locationInWindow, from: nil)
        let frame = views[from].frame
        if point.y < frame.minY - 4 || point.y > frame.maxY + 4 {
            let to = blockIndex(atY: point.y) ?? from
            crossBlockDrag = (from, to)
            needsDisplay = true
        } else if crossBlockDrag != nil {
            crossBlockDrag = nil
            needsDisplay = true
        }
        autoscroll(with: event)
    }

    func textViewMouseUp(_ textView: BlockTextView) {
        guard let drag = crossBlockDrag else { return }
        crossBlockDrag = nil
        needsDisplay = true
        guard drag.from != drag.to else { return }
        textView.setSelectedRange(NSRange(location: textView.selectedRange().location, length: 0))
        selectBlocks(indices: min(drag.from, drag.to)...max(drag.from, drag.to), anchor: drag.from, head: drag.to)
    }

    // MARK: Block selection

    func selectBlocks(_ ids: [UUID]) {
        let indices = ids.compactMap { index(of: $0) }
        guard let low = indices.min(), let high = indices.max() else { return }
        selectBlocks(indices: low...high, anchor: low, head: high)
    }

    func selectBlocks(indices: ClosedRange<Int>, anchor: Int, head: Int) {
        closeSlash()
        endTyping()
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        blockSelection = indices
        selectionAnchor = anchor
        selectionHead = head
        if views.indices.contains(head) { scrollToVisible(views[head].frame.insetBy(dx: 0, dy: -24)) }
    }

    override func becomeFirstResponder() -> Bool { true }

    override func resignFirstResponder() -> Bool {
        blockSelection = nil
        return true
    }

    override func keyDown(with event: NSEvent) {
        if blockSelection != nil {
            interpretKeyEvents([event])
        } else {
            super.keyDown(with: event)
        }
    }

    override func insertText(_ insertString: Any) {}

    override func doCommand(by selector: Selector) {
        guard let selection = blockSelection else { return }
        let last = blocks.count - 1
        switch selector {
        case #selector(moveUp(_:)):
            let target = max(0, selection.lowerBound - 1)
            selectBlocks(indices: target...target, anchor: target, head: target)
        case #selector(moveDown(_:)):
            let target = min(last, selection.upperBound + 1)
            selectBlocks(indices: target...target, anchor: target, head: target)
        case #selector(moveUpAndModifySelection(_:)):
            let head = max(0, selectionHead - 1)
            selectBlocks(indices: min(selectionAnchor, head)...max(selectionAnchor, head), anchor: selectionAnchor, head: head)
        case #selector(moveDownAndModifySelection(_:)):
            let head = min(last, selectionHead + 1)
            selectBlocks(indices: min(selectionAnchor, head)...max(selectionAnchor, head), anchor: selectionAnchor, head: head)
        case #selector(deleteBackward(_:)), #selector(deleteForward(_:)):
            deleteBlocks(selection.map { blocks[$0].id })
        case #selector(insertNewline(_:)):
            let block = blocks[selection.upperBound]
            if block.kind.isEditable || block.kind == .table { focus(block.id, .end) }
        case #selector(cancelOperation(_:)):
            blockSelection = nil
        case #selector(insertTab(_:)):
            indent(blockIndices: selection, by: 1)
        case #selector(insertBacktab(_:)):
            indent(blockIndices: selection, by: -1)
        case #selector(moveToBeginningOfDocument(_:)):
            selectBlocks(indices: 0...0, anchor: 0, head: 0)
        case #selector(moveToEndOfDocument(_:)):
            selectBlocks(indices: last...last, anchor: last, head: last)
        default:
            break
        }
    }

    override func selectAll(_ sender: Any?) {
        selectBlocks(indices: 0...(blocks.count - 1), anchor: 0, head: blocks.count - 1)
    }

    @objc func copy(_ sender: Any?) {
        guard let selection = blockSelection else { return }
        let picked = selection.map { block -> Block in
            var block = blocks[block]
            block.source = nil
            block.gapBefore = nil
            block.sourcePrevious = nil
            return block
        }
        let markdown = BlockMarkdown.write(picked, trailingNewlines: 0)
        let board = NSPasteboard.general
        board.clearContents()
        board.declareTypes([.string, .lotionMarkdown], owner: nil)
        board.setString(markdown, forType: .string)
        board.setString(markdown, forType: .lotionMarkdown)
    }

    @objc func cut(_ sender: Any?) {
        guard let selection = blockSelection else { return }
        copy(sender)
        deleteBlocks(selection.map { blocks[$0].id }, name: "Cut")
    }

    @objc func paste(_ sender: Any?) {
        guard let selection = blockSelection else { return }
        let board = NSPasteboard.general
        let media = Self.media(on: board)
        if !media.isEmpty {
            insertMedia(media, at: selection.upperBound + 1)
            return
        }
        guard let string = board.string(forType: .lotionMarkdown) ?? board.string(forType: .string) else { return }
        let pasted = BlockMarkdown.blocks(from: string)
        guard !pasted.isEmpty else { return }
        let ids = pasted.map(\.id)
        mutate("Paste", focus: .blocks(ids)) { blocks in
            blocks.replaceSubrange(selection, with: pasted)
        }
    }

    @objc func delete(_ sender: Any?) {
        guard let selection = blockSelection else { return }
        deleteBlocks(selection.map { blocks[$0].id })
    }

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)):
            return blockSelection != nil
        case #selector(paste(_:)):
            return blockSelection != nil && NSPasteboard.general.string(forType: .string) != nil
        case #selector(undo(_:)):
            if let item = item as? NSMenuItem, let manager = noteUndoManager { item.title = manager.undoMenuItemTitle }
            return noteUndoManager?.canUndo ?? false
        case #selector(redo(_:)):
            if let item = item as? NSMenuItem, let manager = noteUndoManager { item.title = manager.redoMenuItemTitle }
            return noteUndoManager?.canRedo ?? false
        case #selector(selectAll(_:)):
            return true
        default:
            return responds(to: item.action)
        }
    }

    // Format menu items while blocks are selected.
    @objc func makeHeading1(_ sender: Any?) { turnFocused(into: .heading(1)) }
    @objc func makeHeading2(_ sender: Any?) { turnFocused(into: .heading(2)) }
    @objc func makeHeading3(_ sender: Any?) { turnFocused(into: .heading(3)) }
    @objc func makeBodyText(_ sender: Any?) { turnFocused(into: .paragraph) }
    @objc func toggleBulletList(_ sender: Any?) { toggleFocused(.bullet) }
    @objc func toggleNumberedList(_ sender: Any?) { toggleFocused(.numbered) }
    @objc func toggleChecklist(_ sender: Any?) { toggleFocused(.todo) }
    @objc func toggleQuote(_ sender: Any?) { toggleFocused(.quote) }
    @objc func insertTable(_ sender: Any?) { insertBlockAfterFocus(.table) }
    @objc func insertDivider(_ sender: Any?) { insertBlockAfterFocus(.divider) }
    @objc func moveBlockUp(_ sender: Any?) { moveFocusedBlocks(by: -1) }
    @objc func moveBlockDown(_ sender: Any?) { moveFocusedBlocks(by: 1) }
    @objc func duplicateBlock(_ sender: Any?) { duplicateFocusedBlocks() }

    // MARK: Block operations

    func deleteBlocks(_ ids: [UUID], name: String = "Delete") {
        let indices = ids.compactMap { index(of: $0) }.sorted()
        guard let first = indices.first else { return }
        let removing = Set(ids)
        var remaining = blocks.filter { !removing.contains($0.id) }
        var focus: FocusTarget = .none
        if remaining.isEmpty || (isScratchpad && remaining.allSatisfy { $0.kind == .entry }) {
            // Deleting everything starts the page over: a note keeps an empty
            // title to type into, the scratchpad its first entry.
            let line = Block(kind: isScratchpad ? .paragraph : .heading(1))
            remaining = isScratchpad ? Array(remaining.prefix(1)) + [line] : [line]
            focus = .text(line.id, nil, NSRange(location: 0, length: 0))
        } else if first > 0, let previous = remaining.indices.contains(first - 1) ? remaining[first - 1] : nil, previous.kind.isEditable {
            focus = .text(previous.id, nil, NSRange(location: previous.text.length, length: 0))
        } else if remaining.indices.contains(min(first, remaining.count - 1)) {
            let next = remaining[min(first, remaining.count - 1)]
            focus = next.kind.isEditable ? .text(next.id, nil, NSRange(location: 0, length: 0)) : .blocks([next.id])
        }
        mutate(name, focus: focus) { blocks in blocks = remaining }
    }

    /// The selected blocks, or the focused block with what is nested under it.
    private var operatedRange: ClosedRange<Int>? {
        if let blockSelection { return blockSelection }
        if let index = focusedIndex { return subtree(at: index) }
        return nil
    }

    func moveFocusedBlocks(by delta: Int) {
        guard let range = operatedRange else { return }
        let target = delta < 0 ? range.lowerBound - 1 : range.upperBound + 2
        guard target >= 0, target <= blocks.count else { return }
        moveBlocks(range, to: target)
    }

    /// Moves blocks so they sit before the block now at `target` (or at the end).
    func moveBlocks(_ range: ClosedRange<Int>, to target: Int) {
        guard target < range.lowerBound || target > range.upperBound + 1 else { return }
        let ids = range.map { blocks[$0].id }
        let focus: FocusTarget = blockSelection != nil || focusedIndex == nil ? .blocks(ids) : currentFocus()
        mutate("Move", focus: focus) { blocks in
            let moving = Array(blocks[range])
            blocks.removeSubrange(range)
            let insertAt = target > range.upperBound ? target - moving.count : target
            blocks.insert(contentsOf: moving.map { var block = $0; block.touch(); return block }, at: insertAt)
        }
    }

    func duplicateFocusedBlocks() {
        guard let range = operatedRange else { return }
        let copies = range.map { blocks[$0].duplicate() }
        let focus: FocusTarget
        if blockSelection == nil, let first = copies.first, first.kind.isEditable {
            focus = .text(first.id, nil, NSRange(location: first.text.length, length: 0))
        } else {
            focus = .blocks(copies.map(\.id))
        }
        mutate("Duplicate", focus: focus) { blocks in
            blocks.insert(contentsOf: copies, at: range.upperBound + 1)
        }
    }

    // MARK: Hover handle

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        cover.updateHover(at: point, in: self)
        updateLinkHover(at: point, event: event)
        updateTableEdges(at: point)
        guard point.x >= columnX - 72, point.x <= columnX + columnWidth + 24, point.y <= contentBottom + 4,
              let index = blockIndex(atY: point.y), slash == nil else {
            hideHandle()
            return
        }
        handleIndex = index
        handle.isHidden = false
        updateHandlePosition()
    }

    override func mouseExited(with event: NSEvent) {
        updateTableEdges(at: nil)
        hideHandle()
        LinkPreview.shared.hide()
        cover.updateHover(at: nil, in: self)
    }

    /// Tells tables the pointer is near (their add buttons sit just outside them).
    func updateTableEdges(at point: NSPoint?) {
        let reach = TableBlockView.edgeReach + 6
        for case let table as TableBlockView in views where table.isMaterialized {
            if let point, table.frame.insetBy(dx: -reach, dy: -reach).contains(point) {
                table.pointerMoved(to: table.convert(point, from: self))
            } else {
                table.pointerMoved(to: nil)
            }
        }
    }

    /// Shows the preview of an external link under the pointer, if any.
    func updateLinkHover(at point: NSPoint, event: NSEvent) {
        guard UserDefaults.standard.object(forKey: Prefs.linkPreviews) as? Bool ?? true, let window, let superview, let textView = hitTest(convert(point, to: superview)) as? BlockTextView,
              let storage = textView.textStorage, storage.length > 0,
              let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            LinkPreview.shared.hide()
            return
        }
        let local = textView.convert(point, from: self)
        let inText = NSPoint(x: local.x - textView.textContainerOrigin.x, y: local.y - textView.textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inText, in: container)
        let glyphRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard glyphRect.insetBy(dx: -2, dy: 0).contains(inText), character < storage.length,
              let link = storage.attribute(.lotionLink, at: character, effectiveRange: nil) as? String,
              Favicons.host(of: link) != nil else {
            LinkPreview.shared.hide()
            return
        }
        let fragment = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
            .offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
        let line = window.convertToScreen(textView.convert(fragment, to: nil))
        let pointer = window.convertPoint(toScreen: event.locationInWindow)
        LinkPreview.shared.hover(link, line: line, pointerX: pointer.x, in: window)
    }

    func hideHandle() {
        handle.isHidden = true
        handleIndex = nil
    }

    func updateHandlePosition() {
        guard let index = handleIndex, views.indices.contains(index), !handle.isHidden else { return }
        let view = views[index]
        let size = handle.fittingSize
        var x = columnX - size.width - 6
        if let text = view as? TextBlockView, text.block.indent > 0 { x += CGFloat(text.block.indent) * theme.indentWidth }
        handle.frame = NSRect(x: x, y: round(view.frame.minY + view.firstLineMidY - size.height / 2), width: size.width, height: size.height)
    }

    /// The handle's plus button: a new block below, with the block menu open.
    func handleAddBlock() {
        guard let index = handleIndex, blocks.indices.contains(index) else { return }
        let block = blocks[index]
        if block.kind == .paragraph, block.text.length == 0 {
            focus(block.id, .start)
            focusedTextView?.insertText("/", replacementRange: NSRange(location: 0, length: 0))
            return
        }
        let paragraph = Block(kind: .paragraph)
        let after = subtree(at: index).upperBound
        mutate("New Block", focus: .text(paragraph.id, nil, NSRange(location: 0, length: 0))) { blocks in
            blocks.insert(paragraph, at: after + 1)
        }
        focusedTextView?.insertText("/", replacementRange: NSRange(location: 0, length: 0))
    }

    /// Dragging the handle moves the block; clicking it opens the block menu.
    func handleDrag(_ event: NSEvent) {
        guard let index = handleIndex, blocks.indices.contains(index) else { return }
        let range: ClosedRange<Int> = (blockSelection?.contains(index) == true) ? blockSelection! : subtree(at: index)
        let start = convert(event.locationInWindow, from: nil)
        var dragging = false
        var ghost: NSImageView?
        var target: Int?
        var grab: CGFloat = 0
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            if !dragging, hypot(point.x - start.x, point.y - start.y) > 3 {
                dragging = true
                if window?.firstResponder !== self { window?.makeFirstResponder(self) }
                blockSelection = range
                let rect = views[range.lowerBound].frame.union(views[range.upperBound].frame)
                grab = start.y - rect.minY
                if let rep = bitmapImageRepForCachingDisplay(in: rect) {
                    cacheDisplay(in: rect, to: rep)
                    let image = NSImage(size: rect.size)
                    image.addRepresentation(rep)
                    let view = NSImageView(frame: rect)
                    view.image = image
                    view.alphaValue = 0.55
                    addSubview(view)
                    ghost = view
                }
                handle.isHidden = true
                NSCursor.closedHand.push()
            }
            guard dragging else { continue }
            ghost?.frame.origin = NSPoint(x: columnX, y: point.y - grab)
            let drop = dropIndex(atY: point.y)
            target = drop
            dropIndicator = (range.lowerBound...(range.upperBound + 1)).contains(drop) ? nil : gapY(before: drop)
            autoscroll(with: next)
        }
        ghost?.removeFromSuperview()
        dropIndicator = nil
        if dragging {
            NSCursor.pop()
            if let target { moveBlocks(range, to: target) }
            return
        }
        selectBlocks(indices: range, anchor: range.lowerBound, head: range.upperBound)
        showBlockMenu(for: index)
    }

    private func dropIndex(atY y: CGFloat) -> Int {
        for (index, view) in views.enumerated() where y < view.frame.midY { return index }
        return views.count
    }

    func gapY(before index: Int) -> CGFloat {
        if index == 0 { return views[0].frame.minY - 4 }
        if index >= views.count { return views[views.count - 1].frame.maxY + 4 }
        return round((views[index - 1].frame.maxY + views[index].frame.minY) / 2)
    }

    // MARK: Block menu

    func showBlockMenu(for index: Int) {
        let menu = NSMenu()
        let block = blocks[index]
        let canTurn = block.kind.isText || block.kind == .code || block.kind == .raw
        if canTurn {
            let turn = NSMenuItem(title: "Turn Into", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for item in SlashItem.all where item.kind.isText || item.kind == .code {
                let entry = ClosureMenuItem(title: item.title) { [weak self] in self?.turnFocused(into: item.kind) }
                entry.image = item.menuImage
                entry.state = item.kind == block.kind ? .on : .off
                submenu.addItem(entry)
            }
            turn.submenu = submenu
            menu.addItem(turn)
            menu.addItem(.separator())
        }
        menu.addItem(ClosureMenuItem(title: "Duplicate") { [weak self] in self?.duplicateFocusedBlocks() })
        menu.addItem(ClosureMenuItem(title: "Copy as Markdown") { [weak self] in self?.copy(nil) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Move Up") { [weak self] in self?.moveFocusedBlocks(by: -1) })
        menu.addItem(ClosureMenuItem(title: "Move Down") { [weak self] in self?.moveFocusedBlocks(by: 1) })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Delete") { [weak self] in
            guard let self, let selection = self.blockSelection else { return }
            self.deleteBlocks(selection.map { self.blocks[$0].id })
        })
        menu.popUp(positioning: nil, at: NSPoint(x: handle.frame.minX, y: handle.frame.maxY + 2), in: self)
    }
}

/// The handle beside a hovered block: add a block, or drag and open its menu.
final class BlockHandleView: NSView {
    weak var editor: BlockEditorView?
    private let plus = NSButton()
    private let grip = GripView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add Block")
        plus.isBordered = false
        plus.bezelStyle = .shadowlessSquare
        plus.imageScaling = .scaleProportionallyDown
        plus.contentTintColor = .tertiaryLabelColor
        plus.target = self
        plus.action = #selector(add)
        plus.toolTip = "Add a block below"
        grip.toolTip = "Drag to move, click for options"
        grip.onMouseDown = { [weak self] event in self?.editor?.handleDrag(event) }
        addSubview(plus)
        addSubview(grip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var fittingSize: NSSize { NSSize(width: 42, height: 22) }

    override func layout() {
        super.layout()
        plus.frame = NSRect(x: 0, y: 1, width: 20, height: 20)
        grip.frame = NSRect(x: 22, y: 0, width: 18, height: 22)
    }

    @objc private func add() { editor?.handleAddBlock() }
}

private final class GripView: NSView {
    var onMouseDown: ((NSEvent) -> Void)?
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        if hovered {
            NSColor.quaternaryLabelColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        NSColor.tertiaryLabelColor.setFill()
        let dot: CGFloat = 2.6
        for row in 0..<3 {
            for column in 0..<2 {
                let x = bounds.midX - 3.2 + CGFloat(column) * 5.2 - dot / 2 + 1.3
                let y = bounds.midY - 5 + CGFloat(row) * 5 - dot / 2
                NSBezierPath(ovalIn: NSRect(x: x - 1.3, y: y, width: dot, height: dot)).fill()
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        hovered = false
        onMouseDown?(event)
    }
}
