//
//  TableBlockView.swift
//  Lotion
//
//  A table: one small text view per cell, on a grid that scrolls sideways
//  when it is wider than the column. Columns size to their content.
//

import AppKit

final class TableBlockView: BlockView {
    private(set) var cells: [[BlockTextView]] = []
    private var naturalWidths: [[CGFloat]] = []
    private var columnWidths: [CGFloat] = []
    private var rowHeights: [CGFloat] = []
    private let clip = FlippedView()
    private let grid = TableGridView()
    private var scrollX: CGFloat = 0
    private let addRowButton = RoundAddButton(tip: "Add Row")
    private let addColumnButton = RoundAddButton(tip: "Add Column")
    var addButtons: (row: NSView, column: NSView) { (addRowButton, addColumnButton) }
    /// The pointer in this view, which the add buttons follow along their edges.
    private var pointer: NSPoint?
    private var tracking: NSTrackingArea?

    static let paddingX: CGFloat = 10
    static let paddingY: CGFloat = 6
    static let minimumColumn: CGFloat = 72
    static let maximumColumn: CGFloat = 340
    static let controlSize: CGFloat = 24

    private var table: TableData { block.table ?? .empty() }

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        clip.clipsToBounds = true
        addSubview(clip)
        clip.addSubview(grid)
        grid.owner = self
        addRowButton.action = { [weak self] in self?.addRow() }
        addColumnButton.action = { [weak self] in self?.addColumn() }
        for button in [addRowButton, addColumnButton] {
            button.isHidden = true
            button.alphaValue = 0
            addSubview(button)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isMaterialized: Bool { !cells.isEmpty }

    override var primaryTextView: BlockTextView? {
        materialize()
        return cells.first?.first
    }

    func cell(_ position: CellPosition) -> BlockTextView? {
        materialize()
        guard cells.indices.contains(position.row), cells[position.row].indices.contains(position.column) else { return nil }
        return cells[position.row][position.column]
    }

    var rowCount: Int { table.rows.count }
    var columnCount: Int { table.columnCount }

    // MARK: Building

    override func materialize() {
        guard cells.isEmpty else { return }
        rebuildCells()
    }

    private func cellBase(row: Int, column: Int) -> [NSAttributedString.Key: Any] {
        var attributes = theme.cellAttributes(header: row == 0)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        switch table.alignments.indices.contains(column) ? table.alignments[column] : .none {
        case .center: style.alignment = .center
        case .right: style.alignment = .right
        default: style.alignment = .natural
        }
        attributes[.paragraphStyle] = style
        return attributes
    }

    private func displayCell(row: Int, column: Int) -> NSAttributedString {
        let text = table.rows[row][column]
        let base = cellBase(row: row, column: column)
        return theme.display(text, base: base)
    }

    private func rebuildCells() {
        guard let editor else { return }
        for row in cells { for cell in row { cell.removeFromSuperview() } }
        cells = []
        let data = table
        for row in data.rows.indices {
            var line: [BlockTextView] = []
            for column in 0..<data.columnCount {
                let view = BlockTextView(blockID: block.id, width: 60)
                view.cell = CellPosition(row: row, column: column)
                view.editor = editor
                view.delegate = editor
                view.textStorage?.setAttributedString(displayCell(row: row, column: column))
                configure(view, row: row, column: column)
                grid.addSubview(view)
                line.append(view)
            }
            cells.append(line)
        }
        measureNaturalWidths()
        measuredWidth = -1
        needsLayout = true
    }

    private func configure(_ view: BlockTextView, row: Int, column: Int) {
        view.typingAttributes = cellBase(row: row, column: column)
        view.insertionPointColor = theme.palette.text
        view.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        view.isContinuousSpellCheckingEnabled = theme.style.spellCheck
        view.placeholder = nil
    }

    override func update(_ block: Block) {
        let old = self.block.table
        super.update(block)
        guard !cells.isEmpty else {
            naturalWidths = []
            return
        }
        let new = table
        if old?.rows.count != new.rows.count || old?.columnCount != new.columnCount || old?.alignments != new.alignments {
            let focused = editor?.focusedCell(in: self)
            rebuildCells()
            if let focused { editor?.focusCell(focused.position, in: block.id, placement: .offset(focused.offset)) }
            return
        }
        for row in new.rows.indices {
            for column in 0..<new.columnCount where !(cells[row][column].textStorage?.isEqual(to: new.rows[row][column]) ?? false) {
                let view = cells[row][column]
                let selection = view.selectedRange()
                view.textStorage?.setAttributedString(displayCell(row: row, column: column))
                let length = view.textStorage?.length ?? 0
                view.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
                naturalWidths[row][column] = naturalWidth(view.textStorage ?? NSAttributedString())
            }
        }
        needsLayout = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        if !cells.isEmpty { rebuildCells() }
        grid.needsDisplay = true
    }

    /// Takes a cell's edit, made in its text view.
    func cellDidChange(_ position: CellPosition) {
        guard cells.indices.contains(position.row), naturalWidths.indices.contains(position.row) else { return }
        naturalWidths[position.row][position.column] = naturalWidth(cells[position.row][position.column].textStorage ?? NSAttributedString())
        measuredWidth = -1
    }

    // MARK: Measuring

    private func naturalWidth(_ text: NSAttributedString) -> CGFloat {
        var widest: CGFloat = 0
        let string = text.string as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            widest = max(widest, text.attributedSubstring(from: range).size().width)
        }
        return ceil(widest) + Self.paddingX * 2 + 2
    }

    private func measureNaturalWidths() {
        let data = table
        naturalWidths = data.rows.indices.map { row in
            (0..<data.columnCount).map { column in
                if cells.indices.contains(row) { return naturalWidth(cells[row][column].textStorage ?? NSAttributedString()) }
                return naturalWidth(displayCell(row: row, column: column))
            }
        }
    }

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }

    override func measure(width: CGFloat) -> CGFloat {
        if naturalWidths.count != table.rows.count { measureNaturalWidths() }
        let data = table
        // The add buttons float outside the table, so the grid has the whole column.
        let available = max(Self.minimumColumn, width - indent)
        var widths: [CGFloat] = (0..<data.columnCount).map { column in
            min(Self.maximumColumn, max(Self.minimumColumn, naturalWidths.map { $0.indices.contains(column) ? $0[column] : 0 }.max() ?? 0))
        }
        // Too wide: narrow the widest columns toward a fair share before scrolling.
        let total = widths.reduce(0, +)
        if total > available {
            let fair = max(Self.minimumColumn * 1.6, available / CGFloat(max(1, widths.count)))
            widths = widths.map { min($0, max(fair, Self.minimumColumn)) }
        }
        // Full width: the spare room goes to each column in proportion to its content.
        let used = widths.reduce(0, +)
        if theme.style.tableWidth == .full, used < available, used > 0 {
            widths = widths.map { $0 * available / used }
        }
        columnWidths = widths.map { floor($0) }
        rowHeights = data.rows.indices.map { row in
            var tallest: CGFloat = 0
            for column in 0..<data.columnCount {
                let text = cells.indices.contains(row) ? NSAttributedString(attributedString: cells[row][column].textStorage ?? NSAttributedString())
                    : displayCell(row: row, column: column)
                let height = TextMeasurer.shared.height(of: text, width: columnWidths[column] - Self.paddingX * 2,
                                                         base: cellBase(row: row, column: column))
                tallest = max(tallest, height)
            }
            return tallest + Self.paddingY * 2
        }
        return rowHeights.reduce(0, +) + 1
    }

    var gridWidth: CGFloat { columnWidths.reduce(0, +) + 1 }
    var gridHeight: CGFloat { rowHeights.reduce(0, +) + 1 }
    private var visibleWidth: CGFloat { max(0, min(gridWidth, bounds.width - indent)) }

    override var selectionShape: (rect: NSRect, radius: CGFloat) { (clip.frame, 6) }

    override func layoutContent() {
        guard columnWidths.count == table.columnCount, rowHeights.count == table.rows.count else { return }
        scrollX = max(0, min(scrollX, gridWidth - visibleWidth))
        clip.frame = NSRect(x: indent, y: 0, width: visibleWidth, height: gridHeight)
        grid.frame = NSRect(x: -scrollX, y: 0, width: gridWidth, height: gridHeight)
        grid.columnWidths = columnWidths
        grid.rowHeights = rowHeights
        grid.palette = theme.palette
        grid.needsDisplay = true
        var y: CGFloat = 0
        for (row, line) in cells.enumerated() where row < rowHeights.count {
            var x: CGFloat = 0
            for (column, view) in line.enumerated() where column < columnWidths.count {
                view.frame = NSRect(x: x + Self.paddingX, y: y + Self.paddingY,
                                    width: max(10, columnWidths[column] - Self.paddingX * 2),
                                    height: max(10, rowHeights[row] - Self.paddingY * 2))
                x += columnWidths[column]
            }
            y += rowHeights[row]
        }
        positionControls()
        updateControls()
    }

    /// How close to an edge the pointer has to be for its add button to show.
    static let edgeReach: CGFloat = 24

    /// Each add button shows only while the pointer is by its edge: the bottom
    /// for a row, the right for a column.
    private func updateControls() {
        let grid = NSRect(x: indent, y: 0, width: visibleWidth, height: gridHeight)
        var nearBottom = false
        var nearRight = false
        if let pointer {
            let reach = Self.edgeReach
            nearBottom = pointer.x >= grid.minX && pointer.x <= grid.maxX && abs(pointer.y - grid.maxY) <= reach
            nearRight = pointer.y >= grid.minY && pointer.y <= grid.maxY && abs(pointer.x - grid.maxX) <= reach
            if nearBottom && nearRight {
                // In the corner, the nearer edge wins.
                if abs(pointer.y - grid.maxY) < abs(pointer.x - grid.maxX) { nearRight = false } else { nearBottom = false }
            }
        }
        for button in [addRowButton, addColumnButton] { button.palette = theme.palette }
        // A button appears where the pointer meets its edge and stays put while shown.
        if nearBottom && addRowButton.isHidden { placeRowButton() }
        if nearRight && addColumnButton.isHidden { placeColumnButton() }
        addRowButton.setShown(nearBottom || addRowButton.isPressedNow)
        addColumnButton.setShown(nearRight || addColumnButton.isPressedNow)
    }

    private static let buttonSide: CGFloat = 22

    private func placeRowButton() {
        let half = Self.buttonSide / 2
        let x = min(max(pointer?.x ?? indent + visibleWidth / 2, indent + half), indent + max(visibleWidth, Self.buttonSide) - half)
        addRowButton.frame = NSRect(x: round(x - half), y: round(gridHeight + 4), width: Self.buttonSide, height: Self.buttonSide)
    }

    private func placeColumnButton() {
        let half = Self.buttonSide / 2
        let y = min(max(pointer?.y ?? gridHeight / 2, half), max(half, gridHeight - half))
        addColumnButton.frame = NSRect(x: round(indent + visibleWidth + 4), y: round(y - half), width: Self.buttonSide, height: Self.buttonSide)
    }

    private func positionControls() {
        if addRowButton.isHidden { placeRowButton() } else { addRowButton.frame.origin.y = round(gridHeight + 4) }
        if addColumnButton.isHidden { placeColumnButton() } else { addColumnButton.frame.origin.x = round(indent + visibleWidth + 4) }
    }

    /// The pointer, in this view's coordinates, passed on by the editor so it
    /// reaches past the table's own edges; nil once it is gone.
    func pointerMoved(to point: NSPoint?) {
        pointer = point
        updateControls()
    }

    /// A shown add button under a point in the editor's coordinates.
    func addButton(atEditorPoint point: NSPoint) -> NSView? {
        guard let editor else { return nil }
        let local = convert(point, from: editor)
        return [addRowButton, addColumnButton].first { !$0.isHidden && $0.frame.contains(local) }
    }

    /// The buttons sit outside the table's frame; let them take clicks there.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for button in [addRowButton, addColumnButton] where !button.isHidden && button.frame.contains(local) {
            return button.hitTest(convert(local, to: button.superview))
        }
        return super.hitTest(point)
    }

    func focusDidChange() {}

    override var firstLineMidY: CGFloat { round((rowHeights.first ?? 30) / 2) }

    // MARK: Scrolling sideways

    override func scrollWheel(with event: NSEvent) {
        let scrollable = gridWidth > visibleWidth + 0.5
        guard scrollable, abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else {
            super.scrollWheel(with: event)
            return
        }
        scrollX = max(0, min(gridWidth - visibleWidth, scrollX - event.scrollingDeltaX))
        grid.frame.origin.x = -scrollX
    }

    /// Scrolls sideways to show a cell's caret.
    func reveal(_ view: BlockTextView) {
        guard gridWidth > visibleWidth else { return }
        let caret = view.convert(view.caretRect, to: grid)
        let rect = view.frame.union(caret)
        if rect.minX - Self.paddingX < scrollX {
            scrollX = max(0, rect.minX - Self.paddingX)
        } else if rect.maxX + Self.paddingX > scrollX + visibleWidth {
            scrollX = min(gridWidth - visibleWidth, rect.maxX + Self.paddingX - visibleWidth)
        }
        grid.frame.origin.x = -scrollX
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// A click in a cell's padding puts the caret in that cell.
    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        let local = grid.convert(point, from: self)
        guard let position = grid.cell(at: local), let view = cell(position) else { return false }
        window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: view.characterIndex(near: view.convert(local, from: grid)), length: 0))
        return true
    }

    private func addRow() { editor?.insertTableRow(in: block.id, at: rowCount) }
    private func addColumn() { editor?.insertTableColumn(in: block.id, at: columnCount) }
}

/// Draws the table's grid and header under its cells.
final class TableGridView: NSView {
    weak var owner: TableBlockView?
    var columnWidths: [CGFloat] = []
    var rowHeights: [CGFloat] = []
    var palette: ThemePalette?

    override var isFlipped: Bool { true }

    func cell(at point: NSPoint) -> CellPosition? {
        var y: CGFloat = 0
        for (row, height) in rowHeights.enumerated() {
            if point.y >= y && point.y < y + height {
                var x: CGFloat = 0
                for (column, width) in columnWidths.enumerated() {
                    if point.x >= x && point.x < x + width { return CellPosition(row: row, column: column) }
                    x += width
                }
            }
            y += height
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if let owner, owner.mouseDownOutsideText(at: owner.convert(event.locationInWindow, from: nil), event: event) { return }
        super.mouseDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette, !rowHeights.isEmpty else { return }
        let outer = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: outer, xRadius: 6, yRadius: 6)
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        palette.codeBackground.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: rowHeights[0]).fill()
        palette.rule.setFill()
        var y: CGFloat = 0
        for height in rowHeights.dropLast() {
            y += height
            NSRect(x: 0, y: y, width: bounds.width, height: 1).fill()
        }
        var x: CGFloat = 0
        for width in columnWidths.dropLast() {
            x += width
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        palette.rule.setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// A small round button with a plus, for adding a row or a column.
final class RoundAddButton: NSView {
    var action: (() -> Void)?
    var palette: ThemePalette? { didSet { needsDisplay = true } }
    private var isHovered = false { didSet { needsDisplay = true } }
    private var isPressed = false { didSet { needsDisplay = true } }
    /// Held down: stays shown even if the pointer drifts off the edge zone.
    var isPressedNow: Bool { isPressed }
    private var tracking: NSTrackingArea?

    init(tip: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        toolTip = tip
        setAccessibilityRole(.button)
        setAccessibilityLabel(tip)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private var isShown = false

    /// Fades in (0.15 s) or out (0.12 s); appears at once with Reduce Motion.
    func setShown(_ show: Bool) {
        guard show != isShown else { return }
        isShown = show
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            isHidden = !show
            alphaValue = show ? 1 : 0
            return
        }
        if show { isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = show ? 0.15 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: show ? .easeOut : .easeIn)
            animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isShown else { return }
                self.isHidden = true
            }
        })
    }

    // Faded out, it takes no clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { isShown ? super.hitTest(point) : nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette else { return }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        (isHovered ? palette.codeBackground : palette.background).setFill()
        circle.fill()
        palette.rule.setStroke()
        circle.lineWidth = 1
        circle.stroke()
        let plus = NSBezierPath()
        let arm: CGFloat = 4.5
        plus.move(to: NSPoint(x: bounds.midX - arm, y: bounds.midY))
        plus.line(to: NSPoint(x: bounds.midX + arm, y: bounds.midY))
        plus.move(to: NSPoint(x: bounds.midX, y: bounds.midY - arm))
        plus.line(to: NSPoint(x: bounds.midX, y: bounds.midY + arm))
        plus.lineWidth = 1.5
        plus.lineCapStyle = .round
        (isHovered ? palette.text : palette.secondary).withAlphaComponent(isPressed ? 0.6 : 1).setStroke()
        plus.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            if next.type == .leftMouseUp {
                isPressed = false
                if inside { action?() }
                return
            }
        }
        isPressed = false
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}
