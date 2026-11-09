//
//  TableEditing.swift
//  Lotion
//
//  Changing a table's shape: rows and columns can be added, moved, aligned
//  and deleted from the context menu or with their shortcuts, and a table
//  copied as Markdown, CSV or TSV. Each change rewrites the table as tidy
//  Markdown in one undoable edit, then goes on editing the cell it leaves.
//  Moving between cells is in TableCellEditing.swift.
//

import AppKit

extension EditorTextView {
    struct TableContext {
        let range: NSRange
        let table: MarkdownTable
        let row: Int
        let column: Int
    }

    /// The table being worked on, and which cell: the one being edited, or
    /// the one the note's caret is in.
    func tableContext() -> TableContext? {
        let text = string as NSString
        if let active = activeCell, let found = table(at: active.tableStart) {
            return TableContext(range: found.range, table: MarkdownTable(text.substring(with: found.range)),
                                row: min(active.row, found.block.rows.count - 1),
                                column: min(active.column, found.block.columnCount - 1))
        }
        let caret = selectedRange().location
        guard let found = tableContaining(caret: caret) else { return nil }
        let cell = found.block.cell(at: min(caret, NSMaxRange(found.range) - 1) - found.range.location)
        return TableContext(range: found.range, table: MarkdownTable(text.substring(with: found.range)),
                            row: cell.row, column: cell.column)
    }

    // MARK: Changing the table

    /// Rewrites the table after `change`, as one undoable edit, then edits
    /// the cell it leaves in `row` and `column` (unless `landing` is false).
    func changeTable(landing: Bool = true, _ change: (inout MarkdownTable, inout Int, inout Int) -> Bool) {
        guard let context = tableContext(), let storage = textStorage else { return }
        var table = context.table, row = context.row, column = context.column
        guard change(&table, &row, &column) else { return }
        let text = storage.string as NSString
        var (markdown, _) = table.markdown()
        if text.character(at: NSMaxRange(context.range) - 1) != 10 { markdown.removeLast() }
        // Its own undo step, not folded into the typing before it.
        breakUndoCoalescing()
        isWritingCell = true
        if shouldChangeText(in: context.range, replacementString: markdown) {
            storage.replaceCharacters(in: context.range, with: markdown)
            didChangeText()
        }
        isWritingCell = false
        breakUndoCoalescing()
        undoManager?.setActionName("Edit Table")
        guard landing else { return }
        beginCellEditing(tableAt: context.range.location, row: min(row, table.rows.count - 1),
                         column: min(column, table.columnCount - 1), caret: .end)
    }

    /// Writes a table out as tidy Markdown, every row with all its cells.
    func rewriteTable(at start: Int) -> Bool {
        guard let found = table(at: start), let storage = textStorage else { return false }
        let text = storage.string as NSString
        var (markdown, _) = MarkdownTable(text.substring(with: found.range)).markdown()
        if text.character(at: NSMaxRange(found.range) - 1) != 10 { markdown.removeLast() }
        guard markdown != text.substring(with: found.range) else { return false }
        breakUndoCoalescing()
        isWritingCell = true
        defer { isWritingCell = false }
        guard shouldChangeText(in: found.range, replacementString: markdown) else { return false }
        storage.replaceCharacters(in: found.range, with: markdown)
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName("Edit Table")
        return true
    }

    @objc func tableAddRow(_ sender: Any?) {
        changeTable { table, row, _ in
            row += 1
            table.rows.insert(Array(repeating: "", count: table.columnCount), at: row)
            return true
        }
    }

    @objc func tableAddRowAbove(_ sender: Any?) {
        changeTable { table, row, _ in
            guard row > 0 else { return false }
            table.rows.insert(Array(repeating: "", count: table.columnCount), at: row)
            return true
        }
    }

    @objc func tableAddColumn(_ sender: Any?) { addColumn(after: true) }
    @objc func tableAddColumnBefore(_ sender: Any?) { addColumn(after: false) }

    private func addColumn(after: Bool) {
        changeTable { table, _, column in
            if after { column += 1 }
            for index in table.rows.indices { table.rows[index].insert("", at: column) }
            table.alignments.insert(.none, at: column)
            return true
        }
    }

    @objc func tableMoveRowUp(_ sender: Any?) { moveRow(by: -1) }
    @objc func tableMoveRowDown(_ sender: Any?) { moveRow(by: 1) }

    /// The header stays put; body rows move among themselves.
    private func moveRow(by offset: Int) {
        changeTable { table, row, _ in
            let target = row + offset
            guard row > 0, target > 0, target < table.rows.count else { return false }
            table.rows.swapAt(row, target)
            row = target
            return true
        }
    }

    @objc func tableMoveColumnLeft(_ sender: Any?) { moveColumn(by: -1) }
    @objc func tableMoveColumnRight(_ sender: Any?) { moveColumn(by: 1) }

    private func moveColumn(by offset: Int) {
        changeTable { table, _, column in
            let target = column + offset
            guard target >= 0, target < table.columnCount else { return false }
            for index in table.rows.indices { table.rows[index].swapAt(column, target) }
            table.alignments.swapAt(column, target)
            column = target
            return true
        }
    }

    @objc func tableDeleteRow(_ sender: Any?) {
        changeTable { table, row, _ in
            guard row > 0 else { return false }
            table.rows.remove(at: row)
            row = min(row, table.rows.count - 1)
            return true
        }
    }

    @objc func tableDeleteColumn(_ sender: Any?) {
        changeTable { table, _, column in
            guard table.columnCount > 1 else { return false }
            for index in table.rows.indices { table.rows[index].remove(at: column) }
            table.alignments.remove(at: column)
            column = min(column, table.columnCount - 1)
            return true
        }
    }

    @objc func tableAlignLeft(_ sender: Any?) { align(.left) }
    @objc func tableAlignCenter(_ sender: Any?) { align(.center) }
    @objc func tableAlignRight(_ sender: Any?) { align(.right) }

    private func align(_ alignment: MarkdownTable.Alignment) {
        changeTable { table, _, column in
            table.alignments[column] = table.alignments[column] == alignment ? .none : alignment
            return true
        }
    }

    @objc func copyTableAsMarkdown(_ sender: Any?) { copyTable { $0.markdown().text } }
    @objc func copyTableAsCSV(_ sender: Any?) { copyTable { $0.delimited(by: ",") } }
    @objc func copyTableAsTSV(_ sender: Any?) { copyTable { $0.delimited(by: "\t") } }

    private func copyTable(_ format: (MarkdownTable) -> String) {
        guard let context = tableContext() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(format(context.table), forType: .string)
    }

    /// A two-column table with an empty row, its first header cell selected.
    @objc func insertTable(_ sender: Any?) {
        guard activeCell == nil else { return }
        let text = string as NSString
        let caret = selectedRange()
        var line = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))
        if line.length > 0, text.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let atEmptyLine = line.length == 0
        let insertion = atEmptyLine ? caret.location : NSMaxRange(line)
        var markdown = (atEmptyLine ? "" : "\n") + "| Column 1 | Column 2 |\n| --- | --- |\n|  |  |"
        if insertion < text.length { markdown += "\n" }
        let range = NSRange(location: insertion, length: 0)
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: markdown) else { return }
        textStorage?.replaceCharacters(in: range, with: markdown)
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName("Insert Table")
        let tableStart = insertion + (atEmptyLine ? 0 : 1)
        // Styling runs as the text changes, so the table is ready to edit.
        beginCellEditing(tableAt: tableStart, row: 0, column: 0, caret: .all)
    }

    // MARK: Menu and shortcuts

    func tableMenu() -> NSMenu {
        let menu = NSMenu()
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = []) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.target = self
            return item
        }
        let arrow = { (key: NSEvent.SpecialKey) in String(Character(UnicodeScalar(key.rawValue)!)) }
        let copy = NSMenu()
        copy.items = [item("Markdown", #selector(copyTableAsMarkdown)), item("CSV", #selector(copyTableAsCSV)),
                      item("TSV", #selector(copyTableAsTSV))]
        let copyItem = NSMenuItem(title: "Copy Table As", action: nil, keyEquivalent: "")
        copyItem.submenu = copy
        let align = NSMenu()
        align.items = [item("Left", #selector(tableAlignLeft)), item("Center", #selector(tableAlignCenter)),
                       item("Right", #selector(tableAlignRight))]
        let alignItem = NSMenuItem(title: "Align Column", action: nil, keyEquivalent: "")
        alignItem.submenu = align
        menu.items = [
            copyItem, .separator(), alignItem, .separator(),
            item("Add Row", #selector(tableAddRow), arrow(.downArrow), [.control, .command]),
            item("Add Row Above", #selector(tableAddRowAbove), arrow(.upArrow), [.control, .command]),
            item("Add Column", #selector(tableAddColumn), arrow(.rightArrow), [.control, .command]),
            item("Add Column Before", #selector(tableAddColumnBefore), arrow(.leftArrow), [.control, .command]),
            .separator(),
            item("Move Row Up", #selector(tableMoveRowUp), arrow(.upArrow), [.option, .command]),
            item("Move Row Down", #selector(tableMoveRowDown), arrow(.downArrow), [.option, .command]),
            item("Move Column Left", #selector(tableMoveColumnLeft), arrow(.leftArrow), [.option, .command]),
            item("Move Column Right", #selector(tableMoveColumnRight), arrow(.rightArrow), [.option, .command]),
            .separator(),
            item("Delete Row", #selector(tableDeleteRow), arrow(.delete), [.control, .command]),
            item("Delete Column", #selector(tableDeleteColumn), arrow(.delete), [.control, .shift, .command]),
        ]
        return menu
    }

    /// Whether a table command can act on the cell the caret is in; nil for other items.
    func validateTableItem(_ action: Selector?) -> Bool? {
        let tableActions: Set<Selector> = [
            #selector(tableAddRow), #selector(tableAddRowAbove), #selector(tableAddColumn), #selector(tableAddColumnBefore),
            #selector(tableMoveRowUp), #selector(tableMoveRowDown), #selector(tableMoveColumnLeft), #selector(tableMoveColumnRight),
            #selector(tableDeleteRow), #selector(tableDeleteColumn), #selector(tableAlignLeft), #selector(tableAlignCenter),
            #selector(tableAlignRight), #selector(copyTableAsMarkdown), #selector(copyTableAsCSV), #selector(copyTableAsTSV),
        ]
        guard let action, tableActions.contains(action) else { return nil }
        guard let context = tableContext() else { return false }
        let row = context.row, column = context.column, rows = context.table.rows.count, columns = context.table.columnCount
        switch action {
        case #selector(tableAddRowAbove), #selector(tableDeleteRow): return row > 0
        case #selector(tableMoveRowUp): return row > 1
        case #selector(tableMoveRowDown): return row > 0 && row < rows - 1
        case #selector(tableMoveColumnLeft): return column > 0
        case #selector(tableMoveColumnRight): return column < columns - 1
        case #selector(tableDeleteColumn): return columns > 1
        default: return true
        }
    }

    /// The table shortcuts, while the caret is in a table.
    func performTableShortcut(_ event: NSEvent) -> Bool {
        guard tableContext() != nil, let key = event.specialKey else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let action: Selector? = switch (modifiers, key) {
        case ([.control, .command], .downArrow): #selector(tableAddRow)
        case ([.control, .command], .upArrow): #selector(tableAddRowAbove)
        case ([.control, .command], .rightArrow): #selector(tableAddColumn)
        case ([.control, .command], .leftArrow): #selector(tableAddColumnBefore)
        case ([.option, .command], .upArrow): #selector(tableMoveRowUp)
        case ([.option, .command], .downArrow): #selector(tableMoveRowDown)
        case ([.option, .command], .leftArrow): #selector(tableMoveColumnLeft)
        case ([.option, .command], .rightArrow): #selector(tableMoveColumnRight)
        case ([.control, .command], .delete): #selector(tableDeleteRow)
        case ([.control, .shift, .command], .delete): #selector(tableDeleteColumn)
        default: nil
        }
        guard let action else { return false }
        if validateTableItem(action) == true { perform(action, with: nil) }
        return true
    }
}
