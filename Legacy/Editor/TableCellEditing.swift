//
//  TableCellEditing.swift
//  Lotion
//
//  Tables are drawn, not laid out as text, so a cell is edited in a small
//  text view placed over it. Every change is written straight into the
//  note's Markdown through the note's own text view, so saving, undo and
//  the file on disk all see one ordinary edit; the table redraws from it.
//
//  The caret moves through a table the way it moves through text: arrows
//  cross cell edges and step out above and below, Tab walks the cells,
//  Return goes down a row. Arrowing or clicking into a table from the note
//  lands in the cell it reaches.
//

import AppKit

/// The cell the cell editor is editing.
struct ActiveCell {
    var tableStart: Int
    var row: Int
    var column: Int
    /// Where the cell's Markdown is in the note: exactly what was last written there.
    var source: NSRange
    var override: CellOverride?
}

/// Where the caret goes in a cell that starts editing.
enum CellCaret {
    case start, end, all
    /// An offset into the cell's Markdown.
    case offset(Int)
    /// Nearest a horizontal position (the note's coordinates), on the cell's first or last line.
    case line(x: CGFloat, last: Bool)
}

enum TableScrollGesture {
    case idle, undecided, page
    case table(Int)
}

/// What a click in a table's block lands on.
enum TableHit {
    case cell(tableStart: Int, row: Int, column: Int)
    case above(tableStart: Int)
    case below(tableStart: Int)
    /// In the block's margin beside a table narrower than the page.
    case beside(tableStart: Int, upper: Bool)
}

/// Where a table is drawn, in the note's coordinates.
struct TableGeometry {
    /// The grid's top-left corner, before sideways scroll.
    let origin: NSPoint
    let layout: TableLayout
    let offset: CGFloat
    /// The whole block: the first line's box, margins included.
    let blockRect: NSRect
    /// The part of the grid on screen.
    var gridFrame: NSRect { NSRect(x: origin.x, y: origin.y, width: layout.visibleWidth, height: layout.height) }
}

/// Clips the cell editor to the table's visible part; clicks outside the
/// editor fall through to the note.
final class TableEditorClip: NSView {
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        clipsToBounds = true
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

// MARK: - Cell editor

final class TableCellEditor: NSTextView {
    weak var host: EditorTextView?
    /// Set while text is put in programmatically, which isn't an edit.
    var isLoading = false

    static func make(host: EditorTextView) -> TableCellEditor {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let editor = TableCellEditor(frame: .zero, textContainer: container)
        editor.host = host
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = false
        editor.usesFindBar = false
        editor.drawsBackground = false
        editor.textContainerInset = .zero
        editor.isVerticallyResizable = false
        editor.isHorizontallyResizable = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        editor.isAutomaticDataDetectionEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isGrammarCheckingEnabled = false
        editor.focusRingType = .none
        return editor
    }

    override func didChangeText() {
        super.didChangeText()
        if !isLoading { host?.cellEditorDidChangeText() }
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        host?.cellEditorDidResign()
        return true
    }

    // MARK: Keys

    override func insertTab(_ sender: Any?) { host?.cellTab(forward: true) }
    override func insertBacktab(_ sender: Any?) { host?.cellTab(forward: false) }
    override func insertNewline(_ sender: Any?) { host?.cellReturn() }
    /// A cell is one line of Markdown; there is no line break to put in it.
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) {}
    override func insertParagraphSeparator(_ sender: Any?) { host?.cellReturn() }
    override func cancelOperation(_ sender: Any?) { host?.leaveTable(downward: true) }

    override func moveUp(_ sender: Any?) {
        guard isCaretOnEdgeLine(last: false) else { return super.moveUp(sender) }
        host?.cellVertical(up: true, x: caretX())
    }

    override func moveDown(_ sender: Any?) {
        guard isCaretOnEdgeLine(last: true) else { return super.moveDown(sender) }
        host?.cellVertical(up: false, x: caretX())
    }

    override func moveLeft(_ sender: Any?) {
        guard selectedRange() == NSRange(location: 0, length: 0) else { return super.moveLeft(sender) }
        host?.cellHorizontal(forward: false)
    }

    override func moveRight(_ sender: Any?) {
        let end = (string as NSString).length
        guard selectedRange() == NSRange(location: end, length: 0) else { return super.moveRight(sender) }
        host?.cellHorizontal(forward: true)
    }

    override func deleteBackward(_ sender: Any?) {
        guard selectedRange() == NSRange(location: 0, length: 0) else { return super.deleteBackward(sender) }
        host?.cellDeleteBackwardAtStart()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, host?.performTableShortcut(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Whether the caret is on the first (or last) line of the cell's text.
    private func isCaretOnEdgeLine(last: Bool) -> Bool {
        guard selectedRange().length == 0, let layoutManager, let textContainer else { return true }
        let length = (string as NSString).length
        guard length > 0 else { return true }
        let caret = selectedRange().location
        let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let used = layoutManager.usedRect(for: textContainer)
        return last ? line.maxY >= used.maxY - 1 : line.minY <= used.minY + 1
    }

    /// The caret's horizontal position, in the note's coordinates.
    private func caretX() -> CGFloat {
        guard let layoutManager, let textContainer, let host else { return 0 }
        let length = (string as NSString).length
        let caret = selectedRange().location
        var x: CGFloat = 0
        if length > 0 {
            let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, length - 1))
            let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
            x = caret >= length ? rect.maxX : rect.minX
        }
        return convert(NSPoint(x: x, y: 0), to: host).x
    }

    // MARK: Formatting, undo, menus

    @objc func toggleBold(_ sender: Any?) { wrapMarkdownSelection(with: "**") }
    @objc func toggleItalic(_ sender: Any?) { wrapMarkdownSelection(with: "_") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrapMarkdownSelection(with: "~~") }
    @objc func toggleInlineCode(_ sender: Any?) { wrapMarkdownSelection(with: "`") }
    @objc func insertLink(_ sender: Any?) { insertMarkdownLink() }

    /// Undo is the note's: cell edits are on its stack.
    @objc func undo(_ sender: Any?) { host?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { host?.undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let manager = host?.undoManager
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = manager?.undoMenuItemTitle ?? "Undo"
            return manager?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = manager?.redoMenuItemTitle ?? "Redo"
            return manager?.canRedo ?? false
        default:
            if let validated = host?.validateTableItem(item.action) { return validated }
            return super.validateUserInterfaceItem(item)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let host else { return super.menu(for: event) }
        let menu = host.tableMenu()
        // Spelling and the usual editing items follow the table's.
        if let standard = super.menu(for: event), !standard.items.isEmpty {
            menu.addItem(.separator())
            for item in standard.items {
                standard.removeItem(item)
                menu.addItem(item)
            }
        }
        return menu
    }

    /// Sideways swipes scroll the table under the editor.
    override func scrollWheel(with event: NSEvent) {
        if let host { host.scrollWheel(with: event) } else { super.scrollWheel(with: event) }
    }
}

// MARK: - The note's side

extension EditorTextView {
    var tableColumnWidth: CGFloat { (textContainer?.size.width ?? bounds.width) - gutter * 2 }

    /// The table whose Markdown includes `index`.
    func table(at index: Int) -> (range: NSRange, block: TableBlock)? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard let block = (storage.attribute(.lotionBlock, at: index, longestEffectiveRange: &range,
                                             in: NSRange(location: 0, length: storage.length)) as? BlockDecoration)?.table
        else { return nil }
        return (range, block)
    }

    /// The table a caret at `caret` would be inside: in its Markdown, or
    /// just after it when the note ends with the table.
    func tableContaining(caret: Int) -> (range: NSRange, block: TableBlock)? {
        guard let storage = textStorage else { return nil }
        if let found = table(at: caret) { return found }
        let text = storage.string as NSString
        if caret == text.length, caret > 0, text.character(at: caret - 1) != 10 { return table(at: caret - 1) }
        return nil
    }

    func tableGeometry(_ range: NSRange, _ block: TableBlock) -> TableGeometry {
        let layout = block.layout(available: tableColumnWidth, override: cellOverride(forTableAt: range.location))
        let origin = textContainerOrigin
        var fragment = NSRect.zero
        if let layoutManager {
            let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
            if glyph < layoutManager.numberOfGlyphs { fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil) }
        }
        let offset = min(max(0, tableScrollOffsets[range.location] ?? 0), layout.overflow)
        let left = origin.x + gutter
        return TableGeometry(
            origin: NSPoint(x: left, y: origin.y + fragment.minY + TableMetrics.margin),
            layout: layout, offset: offset,
            blockRect: NSRect(x: left - 4, y: origin.y + fragment.minY, width: tableColumnWidth + 8,
                              height: max(fragment.height, layout.blockHeight))
        )
    }

    func cellOverride(forTableAt location: Int) -> CellOverride? {
        guard let activeCell, activeCell.tableStart == location else { return nil }
        return activeCell.override
    }

    func editingCell(inTableAt location: Int) -> (row: Int, column: Int)? {
        guard let activeCell, activeCell.tableStart == location else { return nil }
        return (activeCell.row, activeCell.column)
    }

    /// How the note's selection shows in a table: inside one cell (a find
    /// result), or across the table.
    func tableHighlight(_ range: NSRange, _ block: TableBlock) -> TableBlock.Highlight? {
        let selection = selectedRange()
        guard selection.length > 0, NSIntersectionRange(selection, range).length > 0 else { return nil }
        let relative = NSRange(location: selection.location - range.location, length: selection.length)
        for (row, cells) in block.cellRanges.enumerated() {
            for (column, cell) in cells.enumerated() {
                guard let cell, relative.location >= cell.location, NSMaxRange(relative) <= NSMaxRange(cell) else { continue }
                let local = NSRange(location: relative.location - cell.location, length: relative.length)
                return .cell(row: row, column: column, range: block.rows[row][column].displayRange(forSource: local))
            }
        }
        return .all
    }

    func invalidateTables(touching ranges: [NSRange]) {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        for range in ranges where range.length > 0 {
            let clamped = NSIntersectionRange(range, whole)
            guard clamped.length > 0 else { continue }
            storage.enumerateAttribute(.lotionBlock, in: clamped) { value, run, _ in
                guard let block = (value as? BlockDecoration)?.table, let found = table(at: run.location) else { return }
                setNeedsDisplay(tableGeometry(found.range, block).blockRect)
            }
        }
    }

    /// Redraws a table after its cells changed. Only when its height
    /// changed is its first line, which carries that height, laid out again,
    /// and what's below it redrawn as it moves.
    func refreshTable(_ range: NSRange) {
        guard let layoutManager, let found = table(at: range.location) else { return setNeedsDisplay(visibleRect) }
        let glyph = layoutManager.glyphIndexForCharacter(at: found.range.location)
        let current = glyph < layoutManager.numberOfGlyphs ? layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).height : 0
        let geometry = tableGeometry(found.range, found.block)
        let visible = visibleRect
        if abs(current - geometry.layout.blockHeight) < 0.5 {
            setNeedsDisplay(geometry.blockRect.intersection(visible))
            return
        }
        layoutManager.invalidateLayout(forCharacterRange: NSRange(location: found.range.location, length: 1), actualCharacterRange: nil)
        let top = max(visible.minY, geometry.blockRect.minY)
        if top < visible.maxY { setNeedsDisplay(NSRect(x: visible.minX, y: top, width: visible.width, height: visible.maxY - top)) }
    }

    private func invalidateTable(_ range: NSRange) { refreshTable(range) }

    // MARK: Starting and ending

    func beginCellEditing(tableAt start: Int, row: Int, column: Int, caret: CellCaret) {
        guard let found = table(at: start), let window else { return }
        let block = found.block
        let row = min(max(0, row), block.rows.count - 1)
        let column = min(max(0, column), block.columnCount - 1)
        guard let relative = block.cellRanges[row][column] else {
            // A row short of cells: write the table out whole, then edit.
            if rewriteTable(at: start), let again = table(at: start), again.block.cellRanges[row][column] != nil {
                beginCellEditing(tableAt: start, row: row, column: column, caret: caret)
            }
            return
        }
        let text = string as NSString
        var source = NSRange(location: found.range.location + relative.location, length: relative.length)
        // An empty cell's text goes between its padding spaces: `| x |`.
        if source.length == 0, source.location + 1 < NSMaxRange(found.range),
           text.character(at: source.location) == 32, text.character(at: source.location + 1) == 32 {
            source.location += 1
        }

        if let previous = activeCell, previous.tableStart != found.range.location, let old = table(at: previous.tableStart) {
            activeCell = nil
            invalidateTable(old.range)
        }
        breakUndoCoalescing()
        activeCell = ActiveCell(tableStart: found.range.location, row: row, column: column, source: source, override: nil)
        // The note's own selection waits at the cell. After each edit the
        // note lays itself out as far as its selection; left far below, that
        // would mean every table under this one, on every keystroke.
        if selectedRange() != NSRange(location: source.location, length: 0) {
            setSelectedRange(NSRange(location: source.location, length: 0))
        }

        let editor = cellEditor
        if cellEditorClip.superview !== self { addSubview(cellEditorClip) }
        if editor.superview !== cellEditorClip { cellEditorClip.addSubview(editor) }
        cellEditorClip.isHidden = false
        editor.isLoading = true
        editor.string = MarkdownTable.unescaped(text.substring(with: source))
        editor.isLoading = false
        editor.isContinuousSpellCheckingEnabled = isContinuousSpellCheckingEnabled
        restyleCellEditor()
        positionCellEditor(revealing: true)
        if window.firstResponder !== editor { window.makeFirstResponder(editor) }
        watchClicksOutsideCell()

        let length = (editor.string as NSString).length
        let selection: NSRange
        switch caret {
        case .start: selection = NSRange(location: 0, length: 0)
        case .end: selection = NSRange(location: length, length: 0)
        case .all: selection = NSRange(location: 0, length: length)
        case .offset(let offset):
            let markdown = text.substring(with: source) as NSString
            selection = NSRange(location: min(length, MarkdownTable.unescapedIndex(markdown, offset: offset)), length: 0)
        case .line(let x, let last):
            var index = last ? length : 0
            if let layoutManager = editor.layoutManager, let container = editor.textContainer, length > 0 {
                layoutManager.ensureLayout(for: container)
                let used = layoutManager.usedRect(for: container)
                let y = last ? used.maxY - 2 : used.minY + 2
                index = editor.characterIndexForInsertion(at: NSPoint(x: convert(NSPoint(x: x, y: 0), to: editor).x, y: y))
            }
            selection = NSRange(location: min(length, max(0, index)), length: 0)
        }
        editor.setSelectedRange(selection)
        editor.scrollToVisible(editor.bounds)
    }

    /// Stops editing. Focus that was in the cell goes back to the note,
    /// unless the cell editor is already handing it on elsewhere.
    func endCellEditing(focusingNote: Bool = true) {
        guard let active = activeCell else { return }
        activeCell = nil
        if let monitor = cellClickMonitor {
            NSEvent.removeMonitor(monitor)
            cellClickMonitor = nil
        }
        breakUndoCoalescing()
        if focusingNote, window?.firstResponder === cellEditor { window?.makeFirstResponder(self) }
        cellEditorClip.isHidden = true
        if let found = table(at: active.tableStart) { invalidateTable(found.range) }
    }

    /// A click anywhere outside the note's text (the inspector, the toolbar,
    /// empty window space) ends cell editing, even where it takes no focus.
    /// Clicks in the note are handled by its own mouseDown.
    private func watchClicksOutsideCell() {
        guard cellClickMonitor == nil else { return }
        cellClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.activeCell != nil, event.window === self.window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.visibleRect.contains(point) { return event }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.activeCell != nil, self.window?.firstResponder === self.cellEditor else { return }
                self.endCellEditing(focusingNote: false)
                self.window?.makeFirstResponder(nil)
            }
            return event
        }
    }

    /// The cell editor lost focus to something else (the sidebar, the find bar).
    func cellEditorDidResign() {
        guard let active = activeCell else { return }
        endCellEditing(focusingNote: false)
        // Keyboard focus coming back to the note returns to this cell.
        setSelectedRange(NSRange(location: min(active.source.location, (string as NSString).length), length: 0))
    }

    /// The caret steps out of the table, onto the line above or below it.
    func leaveTable(downward: Bool) {
        guard let active = activeCell, let found = table(at: active.tableStart) else { return endCellEditing() }
        endCellEditing()
        let text = string as NSString
        let target: Int
        if downward {
            let end = NSMaxRange(found.range)
            if text.character(at: end - 1) != 10 {
                // The note ends with the table: give the caret a line to land on.
                replace(NSRange(location: end, length: 0), with: "\n", select: NSRange(location: end + 1, length: 0))
                return
            }
            target = end
        } else if found.range.location == 0 {
            replace(NSRange(location: 0, length: 0), with: "\n", select: NSRange(location: 0, length: 0))
            return
        } else {
            target = found.range.location - 1
        }
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    // MARK: Following the caret in

    /// A caret moving into a table from the note carries on into a cell:
    /// from above into the first row, from below into the last, by arrow
    /// left and right into the nearest end. Runs once the move is done.
    func scheduleCellActivation(from old: NSRange, to new: NSRange) {
        // The same for a scrolling code block's hidden code: on into its view.
        if activeCell == nil, new.length == 0, window?.firstResponder === self, codeViewport(at: new.location) != nil {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window?.firstResponder === self, self.selectedRange() == new else { return }
                self.focusCode(at: new.location)
            }
            return
        }
        guard activeCell == nil, new.length == 0, window?.firstResponder === self,
              tableContaining(caret: new.location) != nil else { return }
        let event = NSApp.currentEvent
        let key = event?.type == .keyDown ? event?.keyCode : nil
        let x = caretPoint(at: old.location)?.x ?? 0
        DispatchQueue.main.async { [weak self] in
            guard let self, self.activeCell == nil, self.window?.firstResponder === self, self.selectedRange() == new,
                  let found = self.tableContaining(caret: new.location) else { return }
            let block = found.block, start = found.range.location
            let lastRow = block.rows.count - 1, lastColumn = block.columnCount - 1
            let column = { self.column(atX: x, in: found) }
            switch key {
            case 124: self.beginCellEditing(tableAt: start, row: 0, column: 0, caret: .start)
            case 123: self.beginCellEditing(tableAt: start, row: lastRow, column: lastColumn, caret: .end)
            case 125: self.beginCellEditing(tableAt: start, row: 0, column: column(), caret: .line(x: x, last: false))
            case 126: self.beginCellEditing(tableAt: start, row: lastRow, column: column(), caret: .line(x: x, last: true))
            default: self.beginEditingCell(containing: new.location, in: found)
            }
        }
    }

    /// Up from the line below a table, or down from the line above it,
    /// goes into its nearest row. TextKit's own line moves would step over
    /// the table's one tall line.
    func enterTableVertically(up: Bool) -> Bool {
        let caret = selectedRange()
        guard activeCell == nil, caret.length == 0, let layoutManager, let storage = textStorage else { return false }
        let text = storage.string as NSString
        let location = caret.location
        let line = text.lineRange(for: NSRange(location: min(location, text.length), length: 0))
        let found: (range: NSRange, block: TableBlock)?
        if up {
            guard line.location > 0, let above = table(at: line.location - 1), NSMaxRange(above.range) == line.location else { return false }
            found = above
        } else {
            guard let below = table(at: NSMaxRange(line)), below.range.location == NSMaxRange(line), NSMaxRange(line) > location else { return false }
            found = below
        }
        guard let found else { return false }
        // Only from the caret's first (or last) visual line of its paragraph.
        if location < text.length, line.length > 0 {
            let caretGlyph = layoutManager.glyphIndexForCharacter(at: location)
            let edgeCharacter = up ? line.location : max(line.location, NSMaxRange(line) - 1)
            let edgeGlyph = layoutManager.glyphIndexForCharacter(at: edgeCharacter)
            let caretLine = layoutManager.lineFragmentRect(forGlyphAt: caretGlyph, effectiveRange: nil)
            let edgeLine = layoutManager.lineFragmentRect(forGlyphAt: edgeGlyph, effectiveRange: nil)
            guard abs(caretLine.minY - edgeLine.minY) < 0.5 else { return false }
        }
        let x = caretPoint(at: location)?.x ?? textContainerOrigin.x + gutter
        let row = up ? found.block.rows.count - 1 : 0
        beginCellEditing(tableAt: found.range.location, row: row, column: column(atX: x, in: found), caret: .line(x: x, last: up))
        return true
    }

    func activateCellIfCaretInTable() {
        let selection = selectedRange()
        if activeCell == nil, window?.firstResponder === self, selection.length == 0, codeViewport(at: selection.location) != nil {
            return focusCode(at: selection.location)
        }
        guard activeCell == nil, window?.firstResponder === self, selection.length == 0,
              let found = tableContaining(caret: selection.location) else { return }
        beginEditingCell(containing: selection.location, in: found)
    }

    private func beginEditingCell(containing location: Int, in found: (range: NSRange, block: TableBlock)) {
        if location >= NSMaxRange(found.range) {
            beginCellEditing(tableAt: found.range.location, row: found.block.rows.count - 1,
                             column: found.block.columnCount - 1, caret: .end)
            return
        }
        let cell = found.block.cell(at: location - found.range.location)
        beginCellEditing(tableAt: found.range.location, row: cell.row, column: cell.column, caret: .offset(cell.offset))
    }

    private func column(atX x: CGFloat, in found: (range: NSRange, block: TableBlock)) -> Int {
        let geometry = tableGeometry(found.range, found.block)
        return geometry.layout.column(atX: x - geometry.origin.x + geometry.offset)
    }

    private func caretPoint(at index: Int) -> NSPoint? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(index, storage.length - 1))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let x = index >= storage.length ? rect.maxX : rect.minX
        return NSPoint(x: x + textContainerOrigin.x, y: rect.minY + textContainerOrigin.y)
    }

    // MARK: Writing

    func cellEditorDidChangeText() {
        guard var active = activeCell, let storage = textStorage else { return }
        let editor = cellEditor
        // A cell is one line: breaks that arrive by paste or drop become spaces.
        if editor.string.contains(where: { $0 == "\n" || $0 == "\r" }), let editorStorage = editor.textStorage {
            let selection = editor.selectedRange()
            let flat = editor.string.replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
            editor.isLoading = true
            editorStorage.replaceCharacters(in: NSRange(location: 0, length: editorStorage.length), with: flat)
            editor.isLoading = false
            editor.setSelectedRange(NSRange(location: min(selection.location, (flat as NSString).length), length: 0))
        }
        var markdown = MarkdownTable.escaped(editor.string)
        // A trailing backslash would escape the cell's closing pipe.
        if markdown.hasSuffix("\\") { markdown += " " }
        let text = storage.string as NSString
        guard NSMaxRange(active.source) <= text.length else { return endCellEditing() }
        let old = text.substring(with: active.source)
        if old != markdown {
            // Only the part that changed, so the note's typing undo coalesces as usual.
            let change = Self.difference(old, markdown)
            let target = NSRange(location: active.source.location + change.range.location, length: change.range.length)
            isWritingCell = true
            if shouldChangeText(in: target, replacementString: change.replacement) {
                storage.replaceCharacters(in: target, with: change.replacement)
                didChangeText()
            }
            isWritingCell = false
            active.source.length = (markdown as NSString).length
            activeCell?.source = active.source
        }
        restyleCellEditor()
        positionCellEditor(revealing: true)
        editor.scrollRangeToVisible(editor.selectedRange())
    }

    /// The smallest replacement that turns `old` into `new`.
    static func difference(_ old: String, _ new: String) -> (range: NSRange, replacement: String) {
        let a = Array(old.utf16), b = Array(new.utf16)
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        // Never split a surrogate pair.
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }
        let replacement = String(utf16CodeUnits: Array(b[prefix..<(b.count - suffix)]), count: b.count - suffix - prefix)
        return (NSRange(location: prefix, length: a.count - suffix - prefix), replacement)
    }

    /// The cell editor's text styled as the note styles inline Markdown, its
    /// marks showing, and the table told how much room it takes.
    private func restyleCellEditor() {
        guard let active = activeCell, let styler, let found = table(at: active.tableStart) else { return }
        let metrics = found.block.metrics
        let editor = cellEditor
        let font = active.row == 0 ? metrics.header : metrics.body
        let paragraph = metrics.paragraphStyle(found.block.alignments[active.column])
        let styled = styler.inlineStyled(editor.string, font: font, revealAll: true)
        let whole = NSRange(location: 0, length: styled.length)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        if !editor.hasMarkedText(), let storage = editor.textStorage, storage.length == styled.length {
            storage.beginEditing()
            styled.enumerateAttributes(in: whole) { attributes, range, _ in storage.setAttributes(attributes, range: range) }
            storage.endEditing()
        }
        editor.typingAttributes = [.font: font, .foregroundColor: metrics.palette.text, .paragraphStyle: paragraph]
        editor.insertionPointColor = metrics.palette.text
        editor.selectedTextAttributes = [.backgroundColor: metrics.palette.selection]
        Self.overrideVersion += 1
        activeCell?.override = CellOverride(row: active.row, column: active.column,
                                            content: CellContent(styled, toSource: Array(0...styled.length)),
                                            measured: styled, version: Self.overrideVersion)
        invalidateTable(found.range)
    }

    private static var overrideVersion = 0

    /// Puts the cell editor over its cell. `revealing` scrolls a wide table
    /// to show the cell; a sideways scroll by the user doesn't.
    func positionCellEditor(revealing: Bool = false) {
        guard let active = activeCell else { return }
        guard let found = table(at: active.tableStart), active.row < found.block.rows.count,
              active.column < found.block.columnCount else { return endCellEditing() }
        var geometry = tableGeometry(found.range, found.block)
        let cell = geometry.layout.cellRect(row: active.row, column: active.column)
        if revealing {
            var offset = geometry.offset
            let visible = geometry.layout.visibleWidth
            if cell.minX < offset { offset = cell.minX } else if cell.maxX > offset + visible { offset = cell.maxX - visible }
            offset = min(max(0, offset), geometry.layout.overflow)
            if offset != geometry.offset {
                tableScrollOffsets[found.range.location] = offset
                setNeedsDisplay(geometry.blockRect)
                geometry = tableGeometry(found.range, found.block)
            }
        }
        let clip = geometry.gridFrame
        if cellEditorClip.frame != clip { cellEditorClip.frame = clip }
        let content = geometry.layout.contentRect(row: active.row, column: active.column)
        let frame = NSRect(x: content.minX - geometry.offset, y: content.minY, width: content.width, height: content.height)
        if cellEditor.frame != frame { cellEditor.frame = frame }
    }

    /// Repositions the cell editor once layout settles.
    func setNeedsCellEditorPosition() {
        guard activeCell != nil, !needsCellEditorPosition else { return }
        needsCellEditorPosition = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsCellEditorPosition = false
            self.positionCellEditor()
        }
    }

    /// After a theme or font change.
    func cellStyleDidChange() {
        guard activeCell != nil else { return }
        restyleCellEditor()
        positionCellEditor(revealing: true)
    }

    /// The note's text changed. Scroll offsets follow their tables; an
    /// outside change (an undo) brings the cell editor up to date.
    func storageDidEdit(_ edited: NSRange, delta: Int) {
        if delta != 0, !tableScrollOffsets.isEmpty {
            let start = edited.location
            tableScrollOffsets = Dictionary(tableScrollOffsets.map { key, value in
                (key > start ? max(0, key + delta) : key, value)
            }, uniquingKeysWith: { first, _ in first })
        }
        if !isWritingCell, let found = tableContaining(caret: edited.location) {
            // An edit made outside the cell editor (an undo, a replace) may change the table's height.
            let start = found.range.location
            DispatchQueue.main.async { [weak self] in
                guard let self, let again = self.table(at: start) else { return }
                self.refreshTable(again.range)
            }
        }
        guard var active = activeCell, !isWritingCell else { return }
        if edited.location < active.tableStart {
            active.tableStart = max(0, active.tableStart + delta)
            activeCell = active
        }
        DispatchQueue.main.async { [weak self] in self?.syncCellEditor() }
    }

    /// Reloads the cell from the note, following the selection an undo left behind.
    private func syncCellEditor() {
        guard let active = activeCell else { return }
        let selection = selectedRange()
        if let found = tableContaining(caret: selection.location), NSLocationInRange(selection.location, found.range) {
            let cell = found.block.cell(at: selection.location - found.range.location)
            let end = NSMaxRange(selection) - found.range.location
            let endCell = found.block.cell(at: end)
            let offset = endCell.row == cell.row && endCell.column == cell.column ? endCell.offset : cell.offset
            beginCellEditing(tableAt: found.range.location, row: cell.row, column: cell.column, caret: .offset(offset))
        } else if let found = table(at: active.tableStart) {
            beginCellEditing(tableAt: found.range.location, row: active.row, column: active.column, caret: .end)
        } else {
            endCellEditing()
        }
    }

    // MARK: Moving between cells

    func cellTab(forward: Bool) {
        guard let active = activeCell, let found = table(at: active.tableStart) else { return }
        let columns = found.block.columnCount
        var row = active.row, column = active.column + (forward ? 1 : -1)
        if column >= columns { column = 0; row += 1 }
        if column < 0 { column = columns - 1; row -= 1 }
        if row < 0 { return }
        if row >= found.block.rows.count {
            // Tab past the last cell adds a row.
            changeTable { table, row, column in
                table.rows.append(Array(repeating: "", count: table.columnCount))
                row = table.rows.count - 1
                column = 0
                return true
            }
            return
        }
        beginCellEditing(tableAt: found.range.location, row: row, column: column, caret: .all)
    }

    /// Return: the same column one row down, adding a row at the end. On an
    /// empty last row it leaves the table instead, taking that row away.
    func cellReturn() {
        guard let active = activeCell, let context = tableContext() else { return }
        let rows = context.table.rows
        if active.row == rows.count - 1, active.row > 1, rows[active.row].allSatisfy(\.isEmpty) {
            changeTable(landing: false) { table, row, _ in
                table.rows.removeLast()
                row = table.rows.count - 1
                return true
            }
            leaveTable(downward: true)
            return
        }
        if active.row + 1 < rows.count {
            beginCellEditing(tableAt: active.tableStart, row: active.row + 1, column: active.column, caret: .end)
        } else {
            changeTable { table, row, _ in
                table.rows.append(Array(repeating: "", count: table.columnCount))
                row = table.rows.count - 1
                return true
            }
        }
    }

    func cellVertical(up: Bool, x: CGFloat) {
        guard let active = activeCell, let found = table(at: active.tableStart) else { return }
        let row = active.row + (up ? -1 : 1)
        guard row >= 0, row < found.block.rows.count else { return leaveTable(downward: !up) }
        beginCellEditing(tableAt: found.range.location, row: row, column: active.column, caret: .line(x: x, last: up))
    }

    func cellHorizontal(forward: Bool) {
        guard let active = activeCell, let found = table(at: active.tableStart) else { return }
        let columns = found.block.columnCount
        var row = active.row, column = active.column + (forward ? 1 : -1)
        if column >= columns { column = 0; row += 1 }
        if column < 0 { column = columns - 1; row -= 1 }
        guard row >= 0, row < found.block.rows.count else { return leaveTable(downward: forward) }
        beginCellEditing(tableAt: found.range.location, row: row, column: column, caret: forward ? .start : .end)
    }

    /// Backspace at a cell's start never joins cells: in an empty row it
    /// deletes the row, otherwise it steps to the end of the cell before.
    func cellDeleteBackwardAtStart() {
        guard let active = activeCell, let context = tableContext() else { return }
        if active.row > 0, context.table.rows[active.row].allSatisfy(\.isEmpty) {
            changeTable { table, row, _ in
                table.rows.remove(at: row)
                row -= 1
                return true
            }
            return
        }
        if active.column > 0 {
            beginCellEditing(tableAt: active.tableStart, row: active.row, column: active.column - 1, caret: .end)
        } else if active.row > 0 {
            beginCellEditing(tableAt: active.tableStart, row: active.row - 1, column: context.table.columnCount - 1, caret: .end)
        }
    }

    // MARK: From the note

    /// Backspace at the start of a line after a table steps into its last
    /// cell rather than pulling the line into the table.
    func deleteBackwardIntoTable() -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, let found = table(at: caret.location - 1),
              NSMaxRange(found.range) == caret.location else { return false }
        let text = string as NSString
        let lineIsEmpty = caret.location == text.length || text.character(at: caret.location) == 10
        guard !lineIsEmpty else { return false }
        beginCellEditing(tableAt: found.range.location, row: found.block.rows.count - 1,
                         column: found.block.columnCount - 1, caret: .end)
        return true
    }

    /// Forward delete at the end of a line before a table steps into its
    /// first cell rather than pulling the table onto the line.
    func deleteForwardIntoTable() -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, let found = table(at: caret.location + 1), found.range.location == caret.location + 1 else { return false }
        let text = string as NSString
        let lineStart = text.lineRange(for: NSRange(location: caret.location, length: 0)).location
        guard lineStart != caret.location else { return false }
        beginCellEditing(tableAt: found.range.location, row: 0, column: 0, caret: .start)
        return true
    }

    /// The table under a point, found from where tables are drawn: the
    /// lines crossing the point, and any table among their characters.
    func table(atPoint point: NSPoint) -> (range: NSRange, block: TableBlock, geometry: TableGeometry)? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let probe = NSRect(x: 0, y: point.y - textContainerOrigin.y - 1, width: textContainer.size.width, height: 2)
        let glyphs = layoutManager.glyphRange(forBoundingRect: probe, in: textContainer)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        var result: (range: NSRange, block: TableBlock, geometry: TableGeometry)?
        storage.enumerateAttribute(.lotionBlock, in: NSIntersectionRange(characters, NSRange(location: 0, length: storage.length))) { value, run, stop in
            guard (value as? BlockDecoration)?.table != nil, let found = table(at: run.location) else { return }
            let geometry = tableGeometry(found.range, found.block)
            if geometry.blockRect.contains(point) {
                result = (found.range, found.block, geometry)
                stop.pointee = true
            }
        }
        return result
    }

    func tableHit(at point: NSPoint) -> TableHit? {
        guard let (range, block, geometry) = table(atPoint: point) else { return nil }
        let found = (range: range, block: block)
        let grid = geometry.gridFrame
        if point.y < grid.minY { return .above(tableStart: found.range.location) }
        if point.y >= grid.maxY { return .below(tableStart: found.range.location) }
        if point.x < grid.minX || point.x >= grid.maxX { return .beside(tableStart: found.range.location, upper: point.y < grid.midY) }
        let x = point.x - geometry.origin.x + geometry.offset
        let layout = geometry.layout
        return .cell(tableStart: found.range.location, row: layout.row(atY: point.y - geometry.origin.y), column: layout.column(atX: x))
    }

    /// A click in a table edits the cell under it, the caret where it was clicked.
    func handleTableClick(_ event: NSEvent, at point: NSPoint) -> Bool {
        guard let hit = tableHit(at: point) else { return false }
        switch hit {
        case .cell(let start, let row, let column):
            if event.modifierFlags.contains(.command), let target = tableLink(at: point) {
                let url = URL(string: target).flatMap { $0.scheme != nil ? $0 : nil } ?? URL(string: "https://" + target)
                if let url { NSWorkspace.shared.open(url) }
                return true
            }
            beginCellEditing(tableAt: start, row: row, column: column, caret: .end)
            // The editor places the caret and follows a drag, as any text view does.
            if activeCell != nil { cellEditor.mouseDown(with: event) }
        case .above(let start):
            if start > 0 {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: start - 1, length: 0))
            } else {
                beginCellEditing(tableAt: start, row: 0, column: 0, caret: .start)
            }
        case .below(let start):
            guard let found = table(at: start) else { return true }
            let end = NSMaxRange(found.range)
            if (string as NSString).character(at: end - 1) == 10 {
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: end, length: 0))
            } else {
                beginCellEditing(tableAt: start, row: found.block.rows.count - 1, column: found.block.columnCount - 1, caret: .end)
            }
        case .beside(let start, let upper):
            // Beside the table isn't in it: the caret goes to the nearer line around it.
            guard let found = table(at: start) else { return true }
            let end = NSMaxRange(found.range)
            let endsWithBreak = (string as NSString).character(at: end - 1) == 10
            let target = (upper || !endsWithBreak) && start > 0 ? start - 1 : endsWithBreak ? end : nil
            window?.makeFirstResponder(self)
            if let target { setSelectedRange(NSRange(location: target, length: 0)) }
        }
        return true
    }

    /// The link under a point in a table cell.
    func tableLink(at point: NSPoint) -> String? {
        guard case .cell(let start, let row, let column)? = tableHit(at: point), let found = table(at: start) else { return nil }
        if let active = activeCell, active.tableStart == start, active.row == row, active.column == column { return nil }
        let geometry = tableGeometry(found.range, found.block)
        let box = geometry.layout.contentRect(row: row, column: column)
        let local = NSPoint(x: point.x - geometry.origin.x + geometry.offset - box.minX, y: point.y - geometry.origin.y - box.minY)
        let content = found.block.rows[row][column]
        guard content.text.length > 0 else { return nil }
        let index = content.index(at: local, width: box.width, lineHeight: found.block.metrics.lineHeight,
                                  fraction: found.block.fraction(column))
        let probe = min(index, content.text.length - 1)
        return content.text.attribute(.lotionURL, at: probe, effectiveRange: nil) as? String
    }

    // MARK: Sideways scrolling

    /// Sideways swipes over a table wider than the page scroll the table.
    /// A gesture picks its direction once, on its first movement, so a
    /// slightly diagonal swipe never mixes the two.
    func handleTableScroll(_ event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            // A mouse wheel: each notch decides on its own; Shift turns it sideways.
            let dx = event.scrollingDeltaX != 0 ? event.scrollingDeltaX
                : (event.modifierFlags.contains(.shift) ? event.scrollingDeltaY : 0)
            guard dx != 0, abs(dx) >= abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift),
                  let start = scrollableTable(at: point) else { return false }
            scrollTable(at: start, by: dx * (event.hasPreciseScrollingDeltas ? 1 : 12))
            return true
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { scrollGesture = .undecided }
        if case .undecided = scrollGesture {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            guard dx != 0 || dy != 0 else { return false }
            if abs(dx) > abs(dy), let start = scrollableTable(at: point) {
                scrollGesture = .table(start)
            } else {
                scrollGesture = .page
            }
        }
        guard case .table(let start) = scrollGesture else { return false }
        scrollTable(at: start, by: event.scrollingDeltaX)
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { scrollGesture = .idle }
        return true
    }

    private func scrollableTable(at point: NSPoint) -> Int? {
        guard case .cell(let start, _, _)? = tableHit(at: point), let found = table(at: start),
              tableGeometry(found.range, found.block).layout.overflow > 0 else { return nil }
        return start
    }

    func scrollTable(at start: Int, by delta: CGFloat) {
        guard let found = table(at: start) else { return }
        let geometry = tableGeometry(found.range, found.block)
        let offset = min(max(0, geometry.offset - delta), geometry.layout.overflow)
        guard offset != geometry.offset else { return }
        tableScrollOffsets[start] = offset
        setNeedsDisplay(geometry.blockRect)
        if activeCell?.tableStart == start { positionCellEditor() }
    }
}
