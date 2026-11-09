//
//  BlockEditorView+Text.swift
//  Lotion
//
//  Typing: the text views' delegate, keys that cross blocks, Markdown
//  shortcuts as you type, formatting, links, and copy and paste.
//

import AppKit

extension NSPasteboard.PasteboardType {
    /// Lotion's own copy, as Markdown, so pasting back keeps blocks and formatting.
    static let lotionMarkdown = NSPasteboard.PasteboardType("com.fayazahmed.lotion.markdown")
}

extension BlockEditorView: NSTextViewDelegate {
    // MARK: Changes

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString string: String?) -> Bool {
        guard let textView = textView as? BlockTextView, let index = index(of: textView.blockID) else { return true }
        let kind = blocks[index].kind
        if let string, string.contains("\n") || string.contains("\u{2028}") {
            // Cells and headings are one line.
            if textView.cell != nil || kind.headingLevel != nil {
                let flat = string.replacingOccurrences(of: "\u{2028}", with: " ").replacingOccurrences(of: "\n", with: " ")
                textView.insertText(flat, replacementRange: range)
                return false
            }
            if string.contains("\u{2028}") {
                textView.insertText(string.replacingOccurrences(of: "\u{2028}", with: "\n"), replacementRange: range)
                return false
            }
        }
        beginTyping(textView)
        isChangingText = true
        pendingEdit = (range, string ?? "")
        if let string, !string.isEmpty, kind != .code, kind != .raw, kind != .html { avoidExtendingLink(textView, at: range) }
        return true
    }

    /// Typed text joins a link only when typed strictly inside it, with the
    /// same link on both sides. Anywhere else — an emptied block, a line's
    /// start, either edge of a link — it is plain, whatever style was left
    /// over from text that was deleted.
    private func avoidExtendingLink(_ textView: BlockTextView, at range: NSRange) {
        guard let storage = textView.textStorage, textView.typingAttributes[.lotionLink] != nil else { return }
        let start = min(range.location, storage.length)
        let end = min(NSMaxRange(range), storage.length)
        let before = start > 0 ? storage.attribute(.lotionLink, at: start - 1, effectiveRange: nil) as? String : nil
        let after = end < storage.length ? storage.attribute(.lotionLink, at: end, effectiveRange: nil) as? String : nil
        if let before, before == after { return }
        var attributes = textView.typingAttributes
        attributes[.lotionLink] = nil
        textView.typingAttributes = displayTypingAttributes(attributes, for: textView)
    }

    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? BlockTextView, let index = index(of: textView.blockID) else { return }
        isChangingText = false
        let edit = pendingEdit
        pendingEdit = nil
        syncModel(from: textView, at: index)
        hideHandle()
        if let edit, applyShortcuts(textView, at: index, edit: edit) { return }
        afterTextChange(textView, at: index, edit: edit)
    }

    func afterTextChange(_ textView: BlockTextView, at index: Int, edit: (range: NSRange, string: String)?) {
        let view = views[index]
        LinkPreview.shared.hide()
        // A paste is finished; while typing, the link being written is left alone.
        convertMarkdownLinks(in: textView, at: index, sparingCaret: (edit?.string.count ?? 0) <= 1)
        refreshLinkSpacing(textView, at: index)
        if let cell = textView.cell, let table = view as? TableBlockView {
            table.cellDidChange(cell)
            blockHeightMayHaveChanged(textView.blockID)
            table.layoutContent()
            table.reveal(textView)
        } else {
            if let code = view as? CodeBlockView { code.highlight() }
            (view as? HTMLBlockView)?.sourceDidChange()
            (view as? DiagramBlockView)?.sourceDidChange()
            blockHeightMayHaveChanged(textView.blockID)
        }
        updateSlash(textView, edit: edit)
        scrollCaretVisible(textView)
        changed()
    }

    private static let markdownLink = try! NSRegularExpression(pattern: #"\[([^\]\[\n]+)\]\(([^()\s]+)\)"#)

    /// Turns every complete `[text](url)` in a block into a link, however it
    /// got there: typed, pasted whole, or a URL pasted between the brackets.
    /// With `sparingCaret`, one the caret is still inside is left for later:
    /// `[text](h)` is not a link yet while the URL is being typed.
    func convertMarkdownLinks(in textView: BlockTextView, at index: Int, sparingCaret: Bool) {
        let kind = blocks[index].kind
        guard kind.isText || textView.cell != nil, let storage = textView.textStorage,
              storage.string.contains("](") else { return }
        let selection = textView.selectedRange()
        let matches = Self.markdownLink.matches(in: storage.string, range: NSRange(location: 0, length: storage.length))
            .filter { !hasCode(storage, in: $0.range) }
            .filter { !sparingCaret || !(selection.location > $0.range.location && selection.location < NSMaxRange($0.range)) }
        guard !matches.isEmpty else { return }
        registerUndo("Link")
        var caret = textView.selectedRange().location
        storage.beginEditing()
        for match in matches.reversed() {
            let string = storage.string as NSString
            let label = storage.attributedSubstring(from: match.range(at: 1))
            let url = string.substring(with: match.range(at: 2))
            let linked = NSMutableAttributedString(attributedString: label)
            let labelRange = NSRange(location: 0, length: linked.length)
            linked.removeAttribute(.lotionLink, range: labelRange)
            linked.addAttribute(.lotionLink, value: url, range: labelRange)
            storage.replaceCharacters(in: match.range, with: linked)
            let replaced = NSRange(location: match.range.location, length: linked.length)
            theme.applyDisplay(to: storage, range: replaced, base: baseAttributes(for: textView))
            if caret >= NSMaxRange(match.range) {
                caret -= match.range.length - linked.length
            } else if caret > match.range.location {
                caret = NSMaxRange(replaced)
            }
        }
        storage.endEditing()
        textView.setSelectedRange(NSRange(location: min(caret, storage.length), length: 0))
        var attributes = textView.typingAttributes
        attributes[.lotionLink] = nil
        textView.typingAttributes = displayTypingAttributes(attributes, for: textView)
        syncModel(from: textView, at: index)
        endTyping()
    }

    /// Keeps room for favicons right as text moves around links.
    func refreshLinkSpacing(_ textView: BlockTextView, at index: Int) {
        let kind = blocks[index].kind
        guard kind.isText || textView.cell != nil, let storage = textView.textStorage else { return }
        var hasLink = false
        storage.enumerateAttribute(.lotionLink, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
            if value != nil { hasLink = true; stop.pointee = true }
        }
        var hasKern = false
        if !hasLink {
            storage.enumerateAttribute(.kern, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value != nil { hasKern = true; stop.pointee = true }
            }
        }
        guard hasLink || hasKern || ((storage.length > 0 ? storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil)?.firstLineHeadIndent ?? 0) > 0 else { return }
        let selection = textView.selectedRange()
        storage.beginEditing()
        theme.applyLinkSpacing(to: storage, base: baseAttributes(for: textView))
        storage.endEditing()
        textView.setSelectedRange(selection)
        syncModel(from: textView, at: index)
    }

    func syncModel(from textView: BlockTextView, at index: Int) {
        guard let storage = textView.textStorage else { return }
        let text = NSAttributedString(attributedString: storage)
        var block = blocks[index]
        if let cell = textView.cell, var table = block.table {
            guard table.rows.indices.contains(cell.row), table.rows[cell.row].indices.contains(cell.column) else { return }
            table.rows[cell.row][cell.column] = text
            block.table = table
        } else {
            block.text = text
        }
        block.touch()
        updateModel(block, at: index)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? BlockTextView else { return }
        if !isChangingText {
            endTyping()
            // The caret has left a link being written: now it can become one.
            if let index = index(of: textView.blockID), textView.selectedRange().length == 0, !isConvertingLinks {
                isConvertingLinks = true
                convertMarkdownLinks(in: textView, at: index, sparingCaret: true)
                isConvertingLinks = false
            }
        }
        if let slash, slash.id == textView.blockID, !isChangingText {
            let caret = textView.selectedRange()
            if caret.length > 0 || caret.location <= slash.location || caret.location > slash.location + 1 + (slash.query as NSString).length {
                closeSlash()
            }
        }
        if textView.cell != nil, let table = view(for: textView.blockID) as? TableBlockView { table.reveal(textView) }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let textView = textView as? BlockTextView, let index = index(of: textView.blockID) else { return false }
        if slash != nil, handleSlashCommand(selector) { return true }
        if textView.cell != nil { return handleCellCommand(selector, textView, at: index) }
        let kind = blocks[index].kind
        let selection = textView.selectedRange()
        let length = textView.textStorage?.length ?? 0

        switch selector {
        case #selector(insertNewline(_:)):
            if kind == .code || kind == .raw || kind == .html {
                if kind == .code { insertCodeNewline(textView) ; return true }
                return false
            }
            return handleReturn(textView, at: index)
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            if kind.headingLevel != nil { return true }
            textView.insertText("\n", replacementRange: selection)
            return true
        case #selector(deleteBackward(_:)):
            guard selection.length == 0, selection.location == 0 else { return false }
            return handleBackspaceAtStart(at: index)
        case #selector(deleteForward(_:)):
            guard selection.length == 0, selection.location == length else { return false }
            return handleDeleteAtEnd(at: index)
        case #selector(moveUp(_:)):
            guard textView.caretIsOnFirstLine() else { return false }
            return moveVertically(from: textView, at: index, up: true)
        case #selector(moveDown(_:)):
            guard textView.caretIsOnLastLine() else { return false }
            return moveVertically(from: textView, at: index, up: false)
        case #selector(moveLeft(_:)):
            guard selection.length == 0, selection.location == 0 else { return false }
            return moveHorizontally(from: index, back: true)
        case #selector(moveRight(_:)):
            guard selection.length == 0, selection.location == length else { return false }
            return moveHorizontally(from: index, back: false)
        case #selector(moveUpAndModifySelection(_:)):
            guard textView.caretIsOnFirstLine(), selection.location == 0 || length == 0 || textView.selectedRange().length == length else { return false }
            selectionAnchor = index
            selectBlocks(indices: max(0, index - 1)...index, anchor: index, head: max(0, index - 1))
            return true
        case #selector(moveDownAndModifySelection(_:)):
            guard textView.caretIsOnLastLine(), NSMaxRange(selection) == length else { return false }
            selectBlocks(indices: index...min(blocks.count - 1, index + 1), anchor: index, head: min(blocks.count - 1, index + 1))
            return true
        case #selector(insertTab(_:)):
            if kind == .code { insertCodeIndent(textView, outdent: false); return true }
            indent(blockIndices: index...index, by: 1)
            return true
        case #selector(insertBacktab(_:)):
            if kind == .code { insertCodeIndent(textView, outdent: true); return true }
            indent(blockIndices: index...index, by: -1)
            return true
        case #selector(cancelOperation(_:)):
            selectBlocks(indices: index...index, anchor: index, head: index)
            return true
        case #selector(moveToBeginningOfDocument(_:)) where kind != .html:
            if let first = blocks.firstIndex(where: { $0.kind.isEditable || $0.kind == .table }) { focus(blocks[first].id, .start) }
            enclosingScrollView?.contentView.scroll(to: NSPoint(x: 0, y: -(enclosingScrollView?.contentInsets.top ?? 0)))
            return true
        case #selector(moveToEndOfDocument(_:)) where kind != .html:
            if let last = blocks.lastIndex(where: { $0.kind.isEditable || $0.kind == .table }) { focus(blocks[last].id, .end) }
            return true
        default:
            return false
        }
    }

    // MARK: Return, Delete

    private func handleReturn(_ textView: BlockTextView, at index: Int) -> Bool {
        let block = blocks[index]
        let text = textView.textStorage.map { NSAttributedString(attributedString: $0) } ?? NSAttributedString()
        let selection = textView.selectedRange()

        // "```swift" then Return starts a code block.
        if block.kind == .paragraph, text.string.hasPrefix("```"), !text.string.dropFirst(3).contains("`"), !text.string.contains("\n") {
            let info = String(text.string.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            convert(index: index, to: .code, info: info, keepText: false)
            return true
        }
        // Return in an empty list item or quote ends the list.
        if block.kind.isList || block.kind == .quote, text.length == 0 {
            if block.indent > 0 {
                indent(blockIndices: subtree(at: index), by: -1, name: "Outdent")
            } else {
                convert(index: index, to: .paragraph)
            }
            return true
        }

        let newKind = block.kind.continuation
        if selection.location == 0, selection.length == 0, text.length > 0 {
            // At the start: a new empty block above, the caret stays.
            var above = Block(kind: block.kind.isList ? block.kind : .paragraph)
            above.indent = block.kind.isList || block.kind == .paragraph ? block.indent : 0
            mutate("New Block", focus: .text(block.id, nil, NSRange(location: 0, length: 0))) { blocks in
                blocks.insert(above, at: index)
            }
            return true
        }
        let before = text.attributedSubstring(from: NSRange(location: 0, length: selection.location))
        let afterStart = NSMaxRange(selection)
        let after = text.attributedSubstring(from: NSRange(location: afterStart, length: text.length - afterStart))
        var next = Block(kind: newKind, text: after)
        next.indent = (block.kind.isList || block.kind == .paragraph) ? block.indent : 0
        mutate("New Block", focus: .text(next.id, nil, NSRange(location: 0, length: 0))) { blocks in
            blocks[index].text = before
            blocks[index].touch()
            blocks.insert(next, at: index + 1)
        }
        return true
    }

    private func handleBackspaceAtStart(at index: Int) -> Bool {
        let block = blocks[index]
        if block.kind.isText && block.kind != .paragraph {
            convert(index: index, to: .paragraph)
            return true
        }
        if block.kind == .paragraph && block.indent > 0 {
            indent(blockIndices: subtree(at: index), by: -1, name: "Outdent")
            return true
        }
        if block.kind == .code || block.kind == .raw || block.kind == .html, block.text.length == 0 {
            convert(index: index, to: .paragraph)
            return true
        }
        guard index > 0 else { return true }
        let previous = blocks[index - 1]
        if previous.kind.isText || previous.kind == .raw {
            let join = previous.text.length
            let merged = NSMutableAttributedString(attributedString: previous.text)
            merged.append(block.kind == .code ? NSAttributedString(string: block.text.string) : block.text)
            mutate("Delete", focus: .text(previous.id, nil, NSRange(location: join, length: 0))) { blocks in
                blocks[index - 1].text = merged
                blocks[index - 1].touch()
                blocks.remove(at: index)
            }
            return true
        }
        switch previous.kind {
        case .entry where index - 1 == 0:
            // The first entry's break stays: there is nothing before it to join.
            break
        case .divider, .entry:
            mutate(previous.kind == .entry ? "Join Entries" : "Delete", focus: .text(block.id, nil, NSRange(location: 0, length: 0))) { blocks in
                blocks.remove(at: index - 1)
            }
        case .code where block.text.length == 0 && block.kind == .paragraph:
            mutate("Delete", focus: .text(previous.id, nil, NSRange(location: previous.text.length, length: 0))) { blocks in
                blocks.remove(at: index)
            }
        case .code where !previous.isDiagram:
            focus(previous.id, .end)
        case .image, .table, .html, .code, .embed:
            if block.text.length == 0 && block.kind == .paragraph && index + 1 < blocks.count {
                mutate("Delete", focus: .blocks([previous.id])) { blocks in blocks.remove(at: index) }
            } else {
                selectBlocks([previous.id])
            }
        default:
            break
        }
        return true
    }

    private func handleDeleteAtEnd(at index: Int) -> Bool {
        guard index + 1 < blocks.count else { return true }
        let block = blocks[index]
        let next = blocks[index + 1]
        let join = block.text.length
        if next.kind.isText || next.kind == .raw || (next.kind == .code && block.kind == .code) {
            let merged = NSMutableAttributedString(attributedString: block.text)
            merged.append(block.kind == .code ? NSAttributedString(string: next.text.string) : next.text)
            mutate("Delete", focus: .text(block.id, nil, NSRange(location: join, length: 0))) { blocks in
                blocks[index].text = merged
                blocks[index].touch()
                blocks.remove(at: index + 1)
            }
        } else if next.kind == .divider || next.kind == .entry {
            mutate("Delete", focus: .text(block.id, nil, NSRange(location: join, length: 0))) { blocks in
                blocks.remove(at: index + 1)
            }
        }
        return true
    }

    // MARK: Moving between blocks

    /// Arrows move through text and tables; HTML, like images, is passed over.
    private func isNavigable(_ block: Block) -> Bool {
        (block.kind.isEditable && block.kind != .html && !block.isDiagram) || block.kind == .table
    }

    private func moveVertically(from textView: BlockTextView, at index: Int, up: Bool) -> Bool {
        let x = convert(textView.caretRect, from: textView).minX
        var target = index + (up ? -1 : 1)
        while blocks.indices.contains(target), !isNavigable(blocks[target]) { target += up ? -1 : 1 }
        guard blocks.indices.contains(target) else {
            // Nowhere to go: the caret goes to the block's start or end.
            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: up ? 0 : length, length: 0))
            return true
        }
        focus(blocks[target].id, .line(first: !up, x: x))
        return true
    }

    private func moveHorizontally(from index: Int, back: Bool) -> Bool {
        var target = index + (back ? -1 : 1)
        while blocks.indices.contains(target), !isNavigable(blocks[target]) { target += back ? -1 : 1 }
        guard blocks.indices.contains(target) else { return true }
        focus(blocks[target].id, back ? .end : .start)
        return true
    }

    // MARK: Table cells

    private func handleCellCommand(_ selector: Selector, _ textView: BlockTextView, at index: Int) -> Bool {
        guard let cell = textView.cell, let table = views[index] as? TableBlockView else { return false }
        let id = blocks[index].id
        let selection = textView.selectedRange()
        let length = textView.textStorage?.length ?? 0
        let rows = table.rowCount
        let columns = table.columnCount
        func go(_ row: Int, _ column: Int, _ placement: CaretPlacement) {
            focusCell(CellPosition(row: row, column: column), in: id, placement: placement)
        }
        func leave(down: Bool) {
            let target = index + (down ? 1 : -1)
            if blocks.indices.contains(target) {
                focus(blocks[target].id, down ? .start : .end)
            } else if down {
                let paragraph = Block(kind: .paragraph)
                mutate("New Block", focus: .text(paragraph.id, nil, NSRange(location: 0, length: 0))) { blocks in
                    blocks.insert(paragraph, at: index + 1)
                }
            }
        }
        switch selector {
        case #selector(insertTab(_:)):
            if cell.column + 1 < columns { go(cell.row, cell.column + 1, .range(NSRange(location: 0, length: Int.max / 2))) }
            else if cell.row + 1 < rows { go(cell.row + 1, 0, .range(NSRange(location: 0, length: Int.max / 2))) }
            else {
                insertTableRow(in: id, at: rows)
                go(rows, 0, .start)
            }
            return true
        case #selector(insertBacktab(_:)):
            if cell.column > 0 { go(cell.row, cell.column - 1, .range(NSRange(location: 0, length: Int.max / 2))) }
            else if cell.row > 0 { go(cell.row - 1, columns - 1, .range(NSRange(location: 0, length: Int.max / 2))) }
            return true
        case #selector(insertNewline(_:)):
            if cell.row + 1 < rows { go(cell.row + 1, cell.column, .end) } else { leave(down: true) }
            return true
        case #selector(insertLineBreak(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)):
            return true
        case #selector(moveUp(_:)):
            guard textView.caretIsOnFirstLine() else { return false }
            let x = convert(textView.caretRect, from: textView).minX
            if cell.row > 0 { go(cell.row - 1, cell.column, .line(first: false, x: x)) } else { leave(down: false) }
            return true
        case #selector(moveDown(_:)):
            guard textView.caretIsOnLastLine() else { return false }
            let x = convert(textView.caretRect, from: textView).minX
            if cell.row + 1 < rows { go(cell.row + 1, cell.column, .line(first: true, x: x)) } else { leave(down: true) }
            return true
        case #selector(moveLeft(_:)):
            guard selection.length == 0, selection.location == 0 else { return false }
            if cell.column > 0 { go(cell.row, cell.column - 1, .end) }
            else if cell.row > 0 { go(cell.row - 1, columns - 1, .end) }
            else { leave(down: false) }
            return true
        case #selector(moveRight(_:)):
            guard selection.length == 0, selection.location == length else { return false }
            if cell.column + 1 < columns { go(cell.row, cell.column + 1, .start) }
            else if cell.row + 1 < rows { go(cell.row + 1, 0, .start) }
            else { leave(down: true) }
            return true
        case #selector(deleteBackward(_:)):
            // Delete never reaches across cells.
            return selection.length == 0 && selection.location == 0
        case #selector(deleteForward(_:)):
            return selection.length == 0 && selection.location == length
        case #selector(cancelOperation(_:)):
            selectBlocks([id])
            return true
        default:
            return false
        }
    }

    // MARK: Code

    private func insertCodeNewline(_ textView: BlockTextView) {
        let string = textView.string as NSString
        let caret = textView.selectedRange().location
        let line = string.lineRange(for: NSRange(location: min(caret, string.length), length: 0))
        let lineText = string.substring(with: NSRange(location: line.location, length: caret - line.location))
        var indentation = String(lineText.prefix { $0 == " " || $0 == "\t" })
        if let last = lineText.trimmingCharacters(in: .whitespaces).last, "{[(:".contains(last) { indentation += "    " }
        textView.insertText("\n" + indentation, replacementRange: textView.selectedRange())
    }

    private func insertCodeIndent(_ textView: BlockTextView, outdent: Bool) {
        let selection = textView.selectedRange()
        let string = textView.string as NSString
        if selection.length == 0 && !outdent {
            textView.insertText("    ", replacementRange: selection)
            return
        }
        let lines = string.lineRange(for: selection)
        let block = string.substring(with: lines)
        var parts = block.components(separatedBy: "\n")
        let hadTrailing = block.hasSuffix("\n")
        if hadTrailing { parts.removeLast() }
        parts = parts.map { line in
            if outdent {
                var line = Substring(line)
                var removed = 0
                while removed < 4, line.first == " " { line = line.dropFirst(); removed += 1 }
                if removed == 0, line.first == "\t" { line = line.dropFirst() }
                return String(line)
            }
            return line.isEmpty ? line : "    " + line
        }
        let replacement = parts.joined(separator: "\n") + (hadTrailing ? "\n" : "")
        textView.insertText(replacement, replacementRange: lines)
        textView.setSelectedRange(NSRange(location: lines.location, length: (replacement as NSString).length - (hadTrailing ? 1 : 0)))
    }

    // MARK: Markdown shortcuts

    /// Turns Markdown typed at a block's start into the block it describes,
    /// and closed inline marks into formatting. Returns true if it changed blocks.
    private func applyShortcuts(_ textView: BlockTextView, at index: Int, edit: (range: NSRange, string: String)) -> Bool {
        let block = blocks[index]
        guard edit.string.count == 1, textView.selectedRange().length == 0, block.kind != .code, block.kind != .raw, block.kind != .html else { return false }
        let string = textView.string
        let caret = edit.range.location + 1
        let prefix = (string as NSString).substring(to: min(caret, (string as NSString).length))

        if textView.cell == nil {
            if edit.string == " ", let (kind, checked, start) = blockShortcut(prefix, in: block.kind) {
                registerUndo("Format")
                let rest = (textView.textStorage?.attributedSubstring(from: NSRange(location: caret, length: (string as NSString).length - caret))) ?? NSAttributedString()
                var new = blocks
                new[index].kind = kind
                new[index].checked = checked
                new[index].start = start
                new[index].text = rest
                if !kind.isList { new[index].indent = block.kind.isList ? 0 : new[index].indent }
                new[index].touch()
                setBlocks(new)
                focus(block.id, .start)
                changed()
                return true
            }
            if block.kind == .paragraph, string == "```" {
                convert(index: index, to: .code, keepText: false, name: "Format")
                return true
            }
            if block.kind == .paragraph, string == "---" || string == "***" {
                registerUndo("Format")
                var new = blocks
                new[index] = Block(id: block.id, kind: .divider)
                let next = Block(kind: .paragraph)
                new.insert(next, at: index + 1)
                setBlocks(new)
                focus(next.id, .start)
                changed()
                return true
            }
        }
        if "*_~`)".contains(edit.string), applyInlineShortcut(textView, at: index, caret: caret) {
            afterTextChange(textView, at: index, edit: nil)
            return true
        }
        return false
    }

    private func blockShortcut(_ prefix: String, in kind: BlockKind) -> (BlockKind, Bool, Int?)? {
        if kind == .bullet {
            switch prefix {
            case "[] ", "[ ] ": return (.todo, false, nil)
            case "[x] ", "[X] ": return (.todo, true, nil)
            default: return nil
            }
        }
        guard kind == .paragraph else { return nil }
        switch prefix {
        case "# ": return (.heading(1), false, nil)
        case "## ": return (.heading(2), false, nil)
        case "### ": return (.heading(3), false, nil)
        case "#### ": return (.heading(4), false, nil)
        case "- ", "* ", "+ ": return (.bullet, false, nil)
        case "[] ", "[ ] ", "- [ ] ": return (.todo, false, nil)
        case "[x] ", "- [x] ": return (.todo, true, nil)
        case "> ": return (.quote, false, nil)
        default:
            let body = prefix.dropLast(2)
            if prefix.hasSuffix(". ") || prefix.hasSuffix(") "), !body.isEmpty, body.count <= 4, body.allSatisfy({ $0.isASCII && $0.isNumber }),
               let number = Int(body) {
                return (.numbered, false, number == 1 ? nil : number)
            }
            return nil
        }
    }

    /// `**bold**`, `*italic*`, `_italic_`, `~~strike~~`, `` `code` `` and
    /// `[text](url)`, converted as the closing mark is typed.
    private func applyInlineShortcut(_ textView: BlockTextView, at index: Int, caret: Int) -> Bool {
        guard let storage = textView.textStorage else { return false }
        let string = storage.string as NSString
        let newline = string.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: caret))
        let lineStart = newline.location == NSNotFound ? 0 : newline.location + 1
        let line = string.substring(with: NSRange(location: lineStart, length: caret - lineStart))

        if line.hasSuffix(")"), let match = line.range(of: #"\[([^\]\[]+)\]\(([^()\s]+)\)$"#, options: .regularExpression) {
            let whole = String(line[match])
            guard let close = whole.range(of: "](") else { return false }
            let label = String(whole[whole.index(after: whole.startIndex)..<close.lowerBound])
            let url = String(whole[close.upperBound...].dropLast())
            let start = lineStart + (line.distance(from: line.startIndex, to: match.lowerBound) == 0 ? 0 : (line[..<match.lowerBound] as Substring).utf16.count)
            let range = NSRange(location: start, length: (whole as NSString).length)
            guard !hasCode(storage, in: range) else { return false }
            registerUndo("Format")
            storage.beginEditing()
            storage.replaceCharacters(in: range, with: label)
            let labelRange = NSRange(location: start, length: (label as NSString).length)
            storage.addAttribute(.lotionLink, value: url, range: labelRange)
            theme.applyDisplay(to: storage, range: labelRange, base: baseAttributes(for: textView))
            storage.endEditing()
            finishShortcut(textView, at: index, caret: NSMaxRange(labelRange), clearing: .lotionLink)
            return true
        }

        let rules: [(String, NSAttributedString.Key)] = [("**", .lotionBold), ("__", .lotionBold), ("~~", .lotionStrike), ("`", .lotionCode), ("*", .lotionItalic), ("_", .lotionItalic)]
        for (mark, key) in rules where line.hasSuffix(mark) {
            let markLength = (mark as NSString).length
            let lineNS = line as NSString
            let closeAt = lineNS.length - markLength
            // A single mark that is half of a double one belongs to the double rule.
            if markLength == 1, closeAt > 0, lineNS.substring(with: NSRange(location: closeAt - 1, length: 1)) == mark { continue }
            let searchRange = NSRange(location: 0, length: closeAt)
            let open = lineNS.range(of: mark, options: .backwards, range: searchRange)
            guard open.location != NSNotFound else { continue }
            let contentStart = NSMaxRange(open)
            let content = lineNS.substring(with: NSRange(location: contentStart, length: closeAt - contentStart))
            guard !content.isEmpty, content.first != " ", content.last != " " else { continue }
            if markLength == 1 {
                if open.location > 0, lineNS.substring(with: NSRange(location: open.location - 1, length: 1)) == mark { continue }
                if content.hasPrefix(mark) { continue }
                if mark == "_", open.location > 0, let before = lineNS.substring(with: NSRange(location: open.location - 1, length: 1)).first,
                   before.isLetter || before.isNumber { continue }
            }
            let absoluteOpen = lineStart + open.location
            let whole = NSRange(location: absoluteOpen, length: caret - absoluteOpen)
            guard !hasCode(storage, in: whole) || key == .lotionCode else { continue }
            registerUndo("Format")
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: lineStart + closeAt, length: markLength), with: "")
            storage.replaceCharacters(in: NSRange(location: absoluteOpen, length: markLength), with: "")
            let contentRange = NSRange(location: absoluteOpen, length: (content as NSString).length)
            storage.addAttribute(key, value: true, range: contentRange)
            theme.applyDisplay(to: storage, range: contentRange, base: baseAttributes(for: textView))
            storage.endEditing()
            finishShortcut(textView, at: index, caret: NSMaxRange(contentRange), clearing: key)
            return true
        }
        return false
    }

    private func hasCode(_ storage: NSTextStorage, in range: NSRange) -> Bool {
        var found = false
        storage.enumerateAttribute(.lotionCode, in: NSIntersectionRange(range, NSRange(location: 0, length: storage.length))) { value, _, stop in
            if value != nil { found = true; stop.pointee = true }
        }
        return found
    }

    private func finishShortcut(_ textView: BlockTextView, at index: Int, caret: Int, clearing key: NSAttributedString.Key) {
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        var attributes = textView.typingAttributes
        attributes[key] = nil
        textView.typingAttributes = displayTypingAttributes(attributes, for: textView)
        syncModel(from: textView, at: index)
        endTyping()
    }

    // MARK: Converting blocks

    func convert(index: Int, to kind: BlockKind, info: String = "", keepText: Bool = true, name: String = "Turn Into") {
        let block = blocks[index]
        var converted = block
        converted.kind = kind
        converted.touch()
        if kind == .code || kind == .raw {
            converted.text = NSAttributedString(string: keepText ? block.text.string : "")
            converted.info = info
        } else if block.kind == .code || block.kind == .raw {
            converted.text = NSAttributedString(string: block.text.string)
        } else if !keepText {
            converted.text = NSAttributedString()
        }
        if kind != .todo { converted.checked = false }
        if kind != .quote { converted.alert = nil }
        if kind.isList == false && kind != .paragraph { converted.indent = kind == .code || kind == .quote ? converted.indent : 0 }
        let caret: NSRange
        if let view = focusedTextView, view.blockID == block.id, keepText { caret = view.selectedRange() } else { caret = NSRange(location: keepText ? converted.text.length : 0, length: 0) }
        mutate(name, focus: .text(block.id, nil, caret)) { blocks in
            blocks[index] = converted
        }
    }

    /// Turns the focused or selected blocks into `kind`.
    func turnFocused(into kind: BlockKind) {
        let indices: [Int]
        if let selection = blockSelection { indices = Array(selection) } else if let index = focusedIndex { indices = [index] } else { return }
        let targets = indices.filter { blocks[$0].kind.isText || blocks[$0].kind == .code || blocks[$0].kind == .raw }
        guard !targets.isEmpty else { return }
        if targets.count == 1, blockSelection == nil {
            if kind == .code, blocks[targets[0]].kind == .code { return }
            convert(index: targets[0], to: kind)
            return
        }
        let ids = targets.map { blocks[$0].id }
        mutate("Turn Into", focus: .blocks(ids)) { blocks in
            for index in targets {
                let old = blocks[index]
                blocks[index].kind = kind
                if kind == .code { blocks[index].text = NSAttributedString(string: old.text.string) }
                if old.kind == .code || old.kind == .raw { blocks[index].text = NSAttributedString(string: old.text.string) }
                if kind != .todo { blocks[index].checked = false }
                blocks[index].touch()
            }
        }
    }

    func toggleFocused(_ kind: BlockKind) {
        let index = blockSelection?.lowerBound ?? focusedIndex
        guard let index else { return }
        turnFocused(into: blocks[index].kind == kind ? .paragraph : kind)
    }

    func insertBlockAfterFocus(_ kind: BlockKind) {
        let index = blockSelection?.upperBound ?? focusedIndex ?? (blocks.count - 1)
        insertBlock(kind, after: index, replacingEmpty: true)
    }

    /// Adds a block of `kind` after `index`, or in place of the block there when it is an empty paragraph.
    func insertBlock(_ kind: BlockKind, after index: Int, replacingEmpty: Bool) {
        var block = Block(kind: kind)
        if kind == .table { block.table = .empty() }
        let replace = replacingEmpty && blocks.indices.contains(index) && blocks[index].kind == .paragraph && blocks[index].text.length == 0
        if replace { block = Block(id: blocks[index].id, kind: kind); if kind == .table { block.table = .empty() } }
        var trailing: Block?
        let position = replace ? index : index + 1
        if kind == .divider || kind == .table || kind == .image || kind == .embed {
            // Something to type into after it.
            if position + 1 >= blocks.count + (replace ? 0 : 1) || !(blocks.indices.contains(position + (replace ? 1 : 0)) && blocks[position + (replace ? 1 : 0)].kind.isText) {
                trailing = Block(kind: .paragraph)
            }
        }
        let focusTarget: FocusTarget
        switch kind {
        case .divider: focusTarget = trailing.map { .text($0.id, nil, NSRange(location: 0, length: 0)) } ?? .blocks([block.id])
        case .table: focusTarget = .text(block.id, CellPosition(row: 0, column: 0), NSRange(location: 0, length: 0))
        default: focusTarget = .text(block.id, nil, NSRange(location: 0, length: 0))
        }
        mutate("Insert", focus: focusTarget) { blocks in
            if replace { blocks[index] = block } else { blocks.insert(block, at: min(blocks.count, index + 1)) }
            if let trailing { blocks.insert(trailing, at: min(blocks.count, position + 1)) }
        }
        if kind == .divider, trailing == nil, position + 1 < blocks.count { focus(blocks[position + 1].id, .start) }
    }

    func toggleChecked(_ id: UUID) {
        guard let index = index(of: id) else { return }
        let focus = currentFocus()
        mutate(blocks[index].checked ? "Uncheck" : "Check", focus: focus, keepScroll: true) { blocks in
            blocks[index].checked.toggle()
            blocks[index].touch()
        }
    }

    func setCodeLanguage(_ language: String, for id: UUID) {
        guard let index = index(of: id) else { return }
        let rest = blocks[index].info.split(separator: " ", maxSplits: 1).dropFirst().first.map { " " + $0 } ?? ""
        mutate("Change Language") { blocks in
            blocks[index].info = language + (language.isEmpty ? "" : rest)
            blocks[index].touch()
        }
    }

    /// Indents (or outdents, with a negative `delta`) blocks and what is nested under them.
    func indent(blockIndices: ClosedRange<Int>, by delta: Int, name: String? = nil) {
        var range = blockIndices
        range = range.lowerBound...subtree(at: range.upperBound).upperBound
        let first = range.lowerBound
        let block = blocks[first]
        let allowed = block.kind.isList || block.kind == .paragraph || block.kind == .code || block.kind == .quote || block.kind == .image
        guard allowed || delta < 0 else { return }
        if delta > 0 {
            guard first > 0 else { return }
            let previous = blocks[first - 1]
            let maximum = previous.kind.isList ? previous.indent + 1 : previous.indent
            guard block.indent + delta <= maximum else { return }
        } else {
            guard block.indent > 0 else { return }
        }
        let focus = currentFocus()
        mutate(name ?? (delta > 0 ? "Indent" : "Outdent"), focus: focus) { blocks in
            for index in range {
                blocks[index].indent = max(0, blocks[index].indent + delta)
                blocks[index].touch()
            }
        }
    }

    // MARK: Formatting

    func baseAttributes(for textView: BlockTextView) -> [NSAttributedString.Key: Any] {
        guard let index = index(of: textView.blockID) else { return [:] }
        if let cell = textView.cell {
            return theme.cellAttributes(header: cell.row == 0).merging(textView.typingAttributes.filter { $0.key == .paragraphStyle }) { $1 }
        }
        return (views[index] as? TextBlockView)?.baseAttributes ?? theme.baseAttributes(for: blocks[index].kind)
    }

    /// Typing attributes with fonts and colors matching their formatting.
    func displayTypingAttributes(_ attributes: [NSAttributedString.Key: Any], for textView: BlockTextView) -> [NSAttributedString.Key: Any] {
        let sample = NSMutableAttributedString(string: " ", attributes: attributes)
        theme.applyDisplay(to: sample, range: NSRange(location: 0, length: 1), base: baseAttributes(for: textView))
        return sample.attributes(at: 0, effectiveRange: nil)
    }

    func toggleFormat(_ key: NSAttributedString.Key, in textView: BlockTextView) {
        guard let index = index(of: textView.blockID), blocks[index].kind != .code, blocks[index].kind != .raw,
              let storage = textView.textStorage else { return }
        let selection = textView.selectedRange()
        if selection.length == 0 {
            var attributes = textView.typingAttributes
            attributes[key] = attributes[key] == nil ? true : nil
            textView.typingAttributes = displayTypingAttributes(attributes, for: textView)
            return
        }
        var all = true
        storage.enumerateAttribute(key, in: selection) { value, _, stop in
            if value == nil { all = false; stop.pointee = true }
        }
        registerUndo("Format")
        storage.beginEditing()
        if all { storage.removeAttribute(key, range: selection) } else { storage.addAttribute(key, value: true, range: selection) }
        theme.applyDisplay(to: storage, range: selection, base: baseAttributes(for: textView))
        storage.endEditing()
        textView.setSelectedRange(selection)
        syncModel(from: textView, at: index)
        afterTextChange(textView, at: index, edit: nil)
    }

    func editLink(in textView: BlockTextView) {
        guard let index = index(of: textView.blockID), blocks[index].kind != .code, blocks[index].kind != .raw,
              let storage = textView.textStorage else { return }
        var selection = textView.selectedRange()
        var existing: String?
        if selection.location < storage.length || selection.location > 0 {
            let probe = selection.length > 0 ? selection.location : max(0, min(selection.location, storage.length - 1))
            var range = NSRange()
            if storage.length > 0, let url = storage.attribute(.lotionLink, at: probe, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) as? String {
                existing = url
                if selection.length == 0 { selection = range }
            }
        }
        let clipboard = NSPasteboard.general.string(forType: .string).flatMap { Self.isURL($0) ? $0.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        textView.setSelectedRange(selection)
        let rect = textView.firstRect(forCharacterRange: selection, actualRange: nil)
        let local = textView.window.map { textView.convert($0.convertFromScreen(rect), from: nil) } ?? textView.caretRect
        LinkPopover.show(relativeTo: local, of: textView, url: existing ?? clipboard ?? "") { [weak self, weak textView] url in
            guard let self, let textView, let index = self.index(of: textView.blockID), let storage = textView.textStorage else { return }
            self.window?.makeFirstResponder(textView)
            let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
            self.registerUndo("Link")
            storage.beginEditing()
            var range = selection
            if range.length == 0 {
                guard !trimmed.isEmpty else { storage.endEditing(); return }
                storage.replaceCharacters(in: range, with: NSAttributedString(string: trimmed, attributes: textView.typingAttributes))
                range = NSRange(location: range.location, length: (trimmed as NSString).length)
            }
            if trimmed.isEmpty { storage.removeAttribute(.lotionLink, range: range) } else { storage.addAttribute(.lotionLink, value: trimmed, range: range) }
            self.theme.applyDisplay(to: storage, range: range, base: self.baseAttributes(for: textView))
            storage.endEditing()
            textView.setSelectedRange(NSRange(location: NSMaxRange(range), length: 0))
            self.syncModel(from: textView, at: index)
            self.afterTextChange(textView, at: index, edit: nil)
        }
    }

    static func isURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        return trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") || trimmed.hasPrefix("mailto:") || trimmed.hasPrefix("www.")
    }

    // MARK: Copy and paste

    func copy(from textView: BlockTextView) -> Bool {
        guard let storage = textView.textStorage, let index = index(of: textView.blockID) else { return false }
        let selection = textView.selectedRange()
        guard selection.length > 0 else { return true }
        let piece = storage.attributedSubstring(from: selection)
        let board = NSPasteboard.general
        board.clearContents()
        let kind = blocks[index].kind
        if kind == .code || kind == .raw || kind == .html {
            board.setString(piece.string, forType: .string)
            return true
        }
        board.declareTypes([.string, .lotionMarkdown, .rtf], owner: nil)
        board.setString(piece.string, forType: .string)
        if selection.length == storage.length, textView.cell == nil {
            var whole = blocks[index]
            whole.source = nil
            board.setString(BlockMarkdown.markdown(for: whole), forType: .lotionMarkdown)
        } else {
            board.setString(InlineMarkdown.write(piece), forType: .lotionMarkdown)
        }
        if let rtf = try? piece.data(from: NSRange(location: 0, length: piece.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) {
            board.setData(rtf, forType: .rtf)
        }
        return true
    }

    func paste(into textView: BlockTextView, plain: Bool = false) -> Bool {
        guard let index = index(of: textView.blockID) else { return false }
        let board = NSPasteboard.general
        let kind = blocks[index].kind
        if textView.cell == nil, kind != .code, kind != .raw, kind != .html, !plain {
            let media = Self.media(on: board)
            if !media.isEmpty {
                // After the block, or in place of it when it is empty.
                insertMedia(media, at: blocks[index].text.length == 0 && kind == .paragraph ? nil : index + 1)
                return true
            }
        }
        guard let string = board.string(forType: .lotionMarkdown) ?? board.string(forType: .string) else { return false }
        let selection = textView.selectedRange()
        if kind == .code || kind == .raw || kind == .html {
            textView.insertText(board.string(forType: .string) ?? string, replacementRange: selection)
            return true
        }
        // A URL pasted over selected text links it.
        if selection.length > 0, Self.isURL(string), let storage = textView.textStorage {
            registerUndo("Link")
            storage.beginEditing()
            storage.addAttribute(.lotionLink, value: string.trimmingCharacters(in: .whitespacesAndNewlines), range: selection)
            theme.applyDisplay(to: storage, range: selection, base: baseAttributes(for: textView))
            storage.endEditing()
            syncModel(from: textView, at: index)
            afterTextChange(textView, at: index, edit: nil)
            return true
        }
        if textView.cell != nil {
            let flat = string.replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ")
            let text = plain ? NSAttributedString(string: flat) : InlineMarkdown.parse(flat)
            insertInline(text, into: textView)
            return true
        }
        if plain {
            textView.insertText(string, replacementRange: selection)
            return true
        }
        // A link pasted on an empty line becomes an embed: a card, a player or a map.
        let link = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .paragraph, textView.cell == nil, (textView.textStorage?.length ?? 1) == 0, blocks[index].text.length == 0,
           BlockMarkdown.isBareWebLink(link), !MediaKind.isEmbeddable(link) {
            var embed = Block(id: blocks[index].id, kind: .embed)
            embed.imageSource = link
            embed.indent = blocks[index].indent
            let next = Block(kind: .paragraph)
            mutate("Paste Link", focus: .text(next.id, nil, NSRange(location: 0, length: 0))) { blocks in
                blocks[index] = embed
                blocks.insert(next, at: index + 1)
            }
            return true
        }
        // A link pasted into text stays in the text.
        if (textView.textStorage?.length ?? 0) > 0, BlockMarkdown.isBareWebLink(link) || MediaKind.isEmbeddable(link) {
            insertInline(InlineMarkdown.parse(link), into: textView)
            return true
        }
        let pasted = BlockMarkdown.blocks(from: string)
        guard !pasted.isEmpty else { return true }
        if pasted.count == 1, pasted[0].kind == .paragraph {
            insertInline(pasted[0].text, into: textView)
            return true
        }
        insertBlocks(pasted, splitting: index, at: selection)
        return true
    }

    private func insertInline(_ text: NSAttributedString, into textView: BlockTextView) {
        let display = theme.display(text, base: baseAttributes(for: textView))
        textView.insertText(display, replacementRange: textView.selectedRange())
    }

    /// Puts blocks into the note at the caret: text before it joins the first
    /// pasted paragraph, text after it joins the last.
    func insertBlocks(_ pasted: [Block], splitting index: Int, at selection: NSRange) {
        let block = blocks[index]
        let text = (view(for: block.id) as? TextBlockView)?.textView?.textStorage.map { NSAttributedString(attributedString: $0) } ?? block.text
        let before = text.attributedSubstring(from: NSRange(location: 0, length: min(selection.location, text.length)))
        let afterStart = min(text.length, NSMaxRange(selection))
        let after = text.attributedSubstring(from: NSRange(location: afterStart, length: text.length - afterStart))
        var inserted = pasted
        var current = block
        current.touch()
        if before.length == 0 && block.kind == .paragraph {
            // The empty start of a paragraph takes the first pasted block's place.
            current = inserted.removeFirst()
            current = Block(id: block.id, kind: current.kind, text: current.text).copying(from: current)
        } else if inserted.first?.kind == .paragraph {
            let joined = NSMutableAttributedString(attributedString: before)
            joined.append(inserted.removeFirst().text)
            current.text = joined
        } else {
            current.text = before
        }
        var all = [current] + inserted
        var caretBlock = all.count - 1
        var caretOffset = all[caretBlock].kind.isEditable ? all[caretBlock].text.length : 0
        if after.length > 0 {
            if all[all.count - 1].kind.isText {
                let joined = NSMutableAttributedString(attributedString: all[all.count - 1].text)
                joined.append(after)
                all[all.count - 1].text = joined
            } else {
                var tail = Block(kind: block.kind.isText ? block.kind.continuation : .paragraph, text: after)
                tail.indent = block.indent
                all.append(tail)
                caretBlock = all.count - 1
                caretOffset = 0
            }
        }
        let target = all[caretBlock]
        let focusTarget: FocusTarget = target.kind.isEditable ? .text(target.id, nil, NSRange(location: caretOffset, length: 0)) : .blocks([target.id])
        let baseIndent = block.indent
        mutate("Paste", focus: focusTarget) { blocks in
            let shifted = all.enumerated().map { offset, item -> Block in
                var item = item
                if offset > 0, baseIndent > 0, item.kind.isList || item.kind == .paragraph { item.indent += baseIndent }
                return item
            }
            blocks.replaceSubrange(index...index, with: shifted)
        }
    }

    func selectAll(from textView: BlockTextView) -> Bool {
        let length = textView.textStorage?.length ?? 0
        let selection = textView.selectedRange()
        guard length == 0 || (selection.location == 0 && selection.length == length) else { return false }
        selectBlocks(indices: 0...(blocks.count - 1), anchor: 0, head: blocks.count - 1)
        return true
    }

    // MARK: Menus

    func validate(_ item: NSValidatedUserInterfaceItem, from textView: BlockTextView) -> Bool? {
        guard let action = item.action else { return nil }
        switch action {
        case #selector(BlockTextView.undo(_:)):
            if let item = item as? NSMenuItem, let manager = noteUndoManager { item.title = manager.undoMenuItemTitle }
            return noteUndoManager?.canUndo ?? false
        case #selector(BlockTextView.redo(_:)):
            if let item = item as? NSMenuItem, let manager = noteUndoManager { item.title = manager.redoMenuItemTitle }
            return noteUndoManager?.canRedo ?? false
        default:
            return nil
        }
    }

    func contextMenu(for textView: BlockTextView, event: NSEvent) -> NSMenu? {
        guard let cell = textView.cell else { return nil }
        let menu = NSMenu()
        let id = textView.blockID
        func item(_ title: String, _ action: @escaping () -> Void) {
            let entry = ClosureMenuItem(title: title, action: action)
            menu.addItem(entry)
        }
        item("Insert Row Above") { [weak self] in self?.insertTableRow(in: id, at: cell.row) }
        item("Insert Row Below") { [weak self] in self?.insertTableRow(in: id, at: cell.row + 1) }
        item("Insert Column Left") { [weak self] in self?.insertTableColumn(in: id, at: cell.column) }
        item("Insert Column Right") { [weak self] in self?.insertTableColumn(in: id, at: cell.column + 1) }
        menu.addItem(.separator())
        let align = NSMenuItem(title: "Align Column", action: nil, keyEquivalent: "")
        let alignMenu = NSMenu()
        for (title, alignment) in [("Left", ColumnAlignment.left), ("Center", .center), ("Right", .right)] {
            alignMenu.addItem(ClosureMenuItem(title: title) { [weak self] in self?.setTableAlignment(alignment, column: cell.column, in: id) })
        }
        align.submenu = alignMenu
        menu.addItem(align)
        menu.addItem(.separator())
        item("Delete Row") { [weak self] in self?.deleteTableRow(in: id, at: cell.row) }
        item("Delete Column") { [weak self] in self?.deleteTableColumn(in: id, at: cell.column) }
        item("Delete Table") { [weak self] in self?.deleteBlocks([id]) }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "")
        return menu
    }

    func addCursorRects(for textView: BlockTextView) {}

    // MARK: Tables

    func insertTableRow(in id: UUID, at row: Int) {
        guard let index = index(of: id), var table = blocks[index].table else { return }
        let position = max(1, min(row, table.rows.count))
        table.rows.insert(Array(repeating: NSAttributedString(), count: table.columnCount), at: position)
        mutate("Add Row", focus: .text(id, CellPosition(row: position, column: 0), NSRange(location: 0, length: 0))) { blocks in
            blocks[index].table = table
            blocks[index].touch()
        }
    }

    func insertTableColumn(in id: UUID, at column: Int) {
        guard let index = index(of: id), var table = blocks[index].table else { return }
        let position = max(0, min(column, table.columnCount))
        for row in table.rows.indices { table.rows[row].insert(NSAttributedString(), at: position) }
        table.alignments.insert(.none, at: position)
        mutate("Add Column", focus: .text(id, CellPosition(row: 0, column: position), NSRange(location: 0, length: 0))) { blocks in
            blocks[index].table = table
            blocks[index].touch()
        }
    }

    func deleteTableRow(in id: UUID, at row: Int) {
        guard let index = index(of: id), var table = blocks[index].table else { return }
        guard table.rows.count > 1 else { deleteBlocks([id]); return }
        table.rows.remove(at: row)
        let focusRow = min(row, table.rows.count - 1)
        mutate("Delete Row", focus: .text(id, CellPosition(row: focusRow, column: 0), NSRange(location: 0, length: 0))) { blocks in
            blocks[index].table = table
            blocks[index].touch()
        }
    }

    func deleteTableColumn(in id: UUID, at column: Int) {
        guard let index = index(of: id), var table = blocks[index].table else { return }
        guard table.columnCount > 1 else { deleteBlocks([id]); return }
        for row in table.rows.indices { table.rows[row].remove(at: column) }
        table.alignments.remove(at: column)
        let focusColumn = min(column, table.columnCount - 1)
        mutate("Delete Column", focus: .text(id, CellPosition(row: 0, column: focusColumn), NSRange(location: 0, length: 0))) { blocks in
            blocks[index].table = table
            blocks[index].touch()
        }
    }

    func setTableAlignment(_ alignment: ColumnAlignment, column: Int, in id: UUID) {
        guard let index = index(of: id), var table = blocks[index].table, table.alignments.indices.contains(column) else { return }
        table.alignments[column] = table.alignments[column] == alignment ? .none : alignment
        let focus = currentFocus()
        mutate("Align Column", focus: focus, keepScroll: true) { blocks in
            blocks[index].table = table
            blocks[index].touch()
        }
    }
}

extension Block {
    /// This block with another's content, keeping its own identity.
    func copying(from other: Block) -> Block {
        var copy = self
        copy.kind = other.kind
        copy.text = other.text
        copy.indent = other.indent
        copy.checked = other.checked
        copy.start = other.start
        copy.info = other.info
        copy.table = other.table
        copy.imageSource = other.imageSource
        copy.imageAlt = other.imageAlt
        copy.isBareLink = other.isBareLink
        copy.alert = other.alert
        copy.source = nil
        return copy
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
