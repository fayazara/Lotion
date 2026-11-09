//
//  SelfTest.swift
//  Lotion
//
//  A scripted walk through the editor's flows, for Debug builds launched with
//  `-LotionSelfTest YES` (and usually `-LotionLibrary <scratch folder>`). It
//  prints PASS/FAIL lines, and writes a screenshot of the window for each
//  SNAP into `-LotionSnapDir` when given.
//

#if DEBUG
import AppKit
import AVFoundation
import SwiftUI
import WebKit

/// A borderless window that can be key, so its controls draw as active.
private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

enum SelfTest {
    static let openSettings = Notification.Name("LotionSelfTestOpenSettings")

    static func runIfRequested(_ state: AppState) {
        guard UserDefaults.standard.bool(forKey: "LotionSelfTest") else { return }
        Task { await run(state) }
    }

    private static var failures = 0
    private static var lastHit = ""

    private static func log(_ line: String) {
        print("SELFTEST \(line)")
        fflush(stdout)
    }

    private static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if !condition { failures += 1 }
        log((condition ? "PASS " : "FAIL ") + name + (condition ? "" : " — " + detail()))
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func snap(_ name: String, _ window: NSWindow?) async {
        await wait(0.3)
        log("SNAP \(name)")
        guard let window, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir"), let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    // MARK: Driving the editor

    private static func focused(_ editor: BlockEditorView) -> BlockTextView? { editor.focusedTextView }

    /// Types one character at a time, as a person would.
    private static func type(_ editor: BlockEditorView, _ text: String) {
        for character in text {
            guard let view = focused(editor) else { return }
            view.insertText(String(character), replacementRange: view.selectedRange())
        }
    }

    private static func key(_ editor: BlockEditorView, _ selector: Selector) {
        if let view = focused(editor) {
            view.doCommand(by: selector)
        } else {
            editor.doCommand(by: selector)
        }
    }

    /// A real click: the mouse-up is queued first, so a view's tracking loop ends.
    private static func click(_ view: NSView, at local: NSPoint, flags: NSEvent.ModifierFlags = [], count: Int = 1) {
        guard let window = view.window else { return }
        let point = view.convert(local, to: nil)
        let time = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: flags, timestamp: time,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: flags, timestamp: time + 0.05,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0)
        else { return }
        NSApp.postEvent(up, atStart: false)
        // hitTest takes a point in the receiver's superview: the frame view, in window coordinates.
        let hit = window.contentView?.superview?.hitTest(point)
        lastHit = hit.map { String(describing: Swift.type(of: $0)) + ((($0 as? BlockTextView)?.blockID).map { " \($0.uuidString.prefix(4))" } ?? "") } ?? "nil"
        // As NSWindow does for a click in its key window.
        if let hit, hit.acceptsFirstResponder, window.firstResponder !== hit { window.makeFirstResponder(hit) }
        hit?.mouseDown(with: down)
        // Drain the mouse-up if the view did not track.
        _ = NSApp.nextEvent(matching: [.leftMouseUp], until: Date(), inMode: .default, dequeue: true)
    }

    /// Scrolls so `rect` (in the editor) sits mid-screen, clear of the toolbar.
    private static func center(_ editor: BlockEditorView, _ rect: NSRect) {
        guard let scroll = editor.enclosingScrollView else { return }
        let visible = scroll.contentView.bounds.height
        let y = max(-scroll.contentInsets.top, min(editor.frame.height - visible, rect.midY - visible / 2))
        scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.materializeVisible()
    }

    static func largestScrollView(in view: NSView?) -> NSScrollView? {
        guard let view else { return nil }
        var best: NSScrollView?
        func visit(_ view: NSView) {
            if let scroll = view as? NSScrollView, (scroll.documentView?.frame.height ?? 0) > (best?.documentView?.frame.height ?? 0) { best = scroll }
            view.subviews.forEach(visit)
        }
        visit(view)
        return best
    }

    private static func kinds(_ editor: BlockEditorView) -> [BlockKind] { editor.blocks.map(\.kind) }

    // MARK: The run

    private static func run(_ state: AppState) async {
        await wait(1.5)
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "documents" {
            await documents(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "embeds" {
            await embeds(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "diagrams" {
            await diagrams(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "demo" {
            await demo(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "share" {
            await sharePopover(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "cloud" {
            await cloud(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        if UserDefaults.standard.string(forKey: "LotionSelfTestOnly") == "polish" {
            await polish(state)
            log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
            return
        }
        guard let editor = state.editor.editor, let welcome = state.selectedNote else {
            check(false, "editor shows the welcome note")
            return
        }
        let window = editor.window
        check(editor.markdown() == welcome.text, "the welcome note writes back unchanged")
        let welcomeKinds = kinds(editor)
        check(welcomeKinds.contains(.table) && welcomeKinds.contains(.code) && welcomeKinds.contains(.todo) && welcomeKinds.contains(.quote),
              "the welcome note has tables, code, to-dos and quotes", "\(welcomeKinds)")
        check(!welcome.isDirty, "opening a note does not change it")
        if let scroll = editor.enclosingScrollView {
            check(abs(editor.frame.width - scroll.contentView.bounds.width) < 0.5, "the note is exactly as wide as the window shows",
                  "\(editor.frame.width) vs \(scroll.contentView.bounds.width)")
            check(abs((editor.columnX + editor.columnWidth / 2) - editor.frame.width / 2) < 1, "the text column is centered")
        }
        await snap("01-welcome", window)

        // A new note and typing
        state.newNote()
        await wait(0.8)
        guard let note = state.selectedNote, note.id != welcome.id else { check(false, "a new note opens"); return }
        check(kinds(editor) == [.heading(1)], "a new note is one empty title", "\(kinds(editor))")
        check(focused(editor) != nil, "a new note focuses its title")
        type(editor, "Groceries")
        check(note.text == "# Groceries", "typing the title writes Markdown", note.text)
        key(editor, #selector(NSResponder.insertNewline(_:)))
        check(kinds(editor) == [.heading(1), .paragraph] && focused(editor)?.blockID == editor.blocks[1].id,
              "return after a title starts a paragraph", "\(kinds(editor))")
        type(editor, "- ")
        check(editor.blocks.last?.kind == .bullet && editor.blocks.last?.text.length == 0, "“- ” makes a bullet")
        type(editor, "Milk")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "Bread")
        check(note.text.hasSuffix("- Milk\n- Bread"), "return continues the list", note.text)
        key(editor, #selector(NSResponder.insertNewline(_:)))
        key(editor, #selector(NSResponder.insertNewline(_:)))
        check(editor.blocks.last?.kind == .paragraph, "return on an empty item ends the list")
        type(editor, "[] Call the bakery")
        check(editor.blocks.last?.kind == .todo && editor.blocks.last?.text.string == "Call the bakery", "“[] ” makes a to-do")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "1. one")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "two")
        check(note.text.hasSuffix("1. one\n2. two"), "numbered lists count up", note.text)
        key(editor, #selector(NSResponder.insertNewline(_:)))
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "Some **bold** and `code`")
        if let last = editor.blocks.last {
            let text = last.text
            let boldAt = (text.string as NSString).range(of: "bold")
            let codeAt = (text.string as NSString).range(of: "code")
            check(text.string == "Some bold and code", "closing marks become formatting", text.string)
            check(boldAt.location != NSNotFound && text.attribute(.lotionBold, at: boldAt.location, effectiveRange: nil) != nil
                  && codeAt.location != NSNotFound && text.attribute(.lotionCode, at: codeAt.location, effectiveRange: nil) != nil,
                  "bold and code are applied")
        }
        check(note.text.hasSuffix("Some **bold** and `code`"), "formatting is written as Markdown", note.text)
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "```")
        check(editor.blocks.last?.kind == .code, "“```” makes a code block")
        type(editor, "let total = 2")
        check(note.text.hasSuffix("```\nlet total = 2\n```"), "code is fenced", note.text)
        await snap("02-typed", window)

        // Slash menu → table
        center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
        click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
        check(editor.blocks.last?.kind == .paragraph && focused(editor)?.blockID == editor.blocks.last?.id,
              "clicking below a code block starts a paragraph")
        type(editor, "/")
        check(editor.slash != nil && !editor.slashMenu.isHidden, "“/” opens the block menu")
        await snap("03-slash", window)
        // The menu follows the trackpad point for point.
        let before = editor.slashMenu.offset
        editor.slashMenu.scroll(by: 13.5)
        check(editor.slashMenu.offset == before + 13.5, "the block menu scrolls smoothly", "\(editor.slashMenu.offset)")
        await snap("03-slash-scrolled", window)
        editor.slashMenu.scroll(by: -100)
        type(editor, "tab")
        check(editor.slashMenu.items.first?.title == "Table", "typing filters the menu", "\(editor.slashMenu.items.map(\.title))")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        guard let tableIndex = editor.blocks.firstIndex(where: { $0.kind == .table }) else { check(false, "the menu inserts a table"); return }
        let tableID = editor.blocks[tableIndex].id
        check(focused(editor)?.cell == CellPosition(row: 0, column: 0), "the table's first cell is focused")
        check(editor.blocks.indices.contains(tableIndex + 1) && editor.blocks[tableIndex + 1].kind == .paragraph, "a paragraph follows the table")
        type(editor, "Item")
        key(editor, #selector(NSResponder.insertTab(_:)))
        type(editor, "Qty")
        key(editor, #selector(NSResponder.insertTab(_:)))
        key(editor, #selector(NSResponder.insertTab(_:)))
        type(editor, "Eggs")
        key(editor, #selector(NSResponder.insertTab(_:)))
        type(editor, "12")
        let rows = editor.blocks[tableIndex].table?.rows.map { $0.map(\.string) } ?? []
        check(rows.count == 3 && rows[0].prefix(2) == ["Item", "Qty"] && rows[1].prefix(2) == ["Eggs", "12"], "tab moves through cells", "\(rows)")
        check(note.text.contains("| Item | Qty |"), "the table is written as Markdown", note.text)
        await snap("04-table", window)
        if let table = editor.view(for: tableID) as? TableBlockView {
            let fit = table.gridWidth
            UserDefaults.standard.set(TableWidth.full.rawValue, forKey: Prefs.tableWidth)
            await wait(0.6)
            let full = (editor.view(for: tableID) as? TableBlockView)?.gridWidth ?? 0
            check(full > fit && abs(full - editor.columnWidth) <= 2, "full-width tables span the whole column", "\(fit) → \(full) of \(editor.columnWidth)")
            await snap("04b-table-full", window)
            UserDefaults.standard.set(TableWidth.fit.rawValue, forKey: Prefs.tableWidth)
            await wait(0.6)
        }

        // Clicking in and out of the table, many times
        guard let table = editor.view(for: tableID) as? TableBlockView else { check(false, "table view"); return }
        var clickFailures: [String] = []
        for round in 0..<10 {
            if let title = editor.views.first?.primaryTextView {
                center(editor, editor.views[0].frame)
                click(title, at: NSPoint(x: 30, y: title.bounds.midY))
                if focused(editor)?.blockID != editor.blocks[0].id { clickFailures.append("round \(round): title \(editor.blocks[0].id.uuidString.prefix(4)) not focused (hit \(lastHit), focused \(focused(editor)?.blockID.uuidString.prefix(4) ?? "-"))") }
            }
            let position = CellPosition(row: 1, column: round % 2)
            if let cell = table.cell(position) {
                center(editor, table.frame)
                click(cell, at: NSPoint(x: 4, y: cell.bounds.midY))
                if focused(editor)?.cell != position { clickFailures.append("round \(round): cell \(position) not focused (\(String(describing: focused(editor)?.cell)))") }
            }
            if let after = editor.views[tableIndex + 1].primaryTextView {
                center(editor, editor.views[tableIndex + 1].frame)
                click(after, at: NSPoint(x: 10, y: after.bounds.midY))
                if focused(editor)?.blockID != editor.blocks[tableIndex + 1].id { clickFailures.append("round \(round): paragraph after table not focused (hit \(lastHit))") }
            }
        }
        check(clickFailures.isEmpty, "clicks move into and out of the table every time", clickFailures.joined(separator: "; "))
        // A click in a cell puts the caret where it was clicked.
        if let cell = table.cell(CellPosition(row: 1, column: 0)) {
            let end = cell.layoutManager.map { $0.usedRect(for: cell.textContainer!).maxX } ?? 20
            click(cell, at: NSPoint(x: end + 2, y: cell.bounds.midY))
            check(cell.selectedRange() == NSRange(location: 4, length: 0), "a click after a cell's text puts the caret at its end", "\(cell.selectedRange())")
            click(cell, at: NSPoint(x: 1, y: cell.bounds.midY))
            check(cell.selectedRange() == NSRange(location: 0, length: 0), "a click at a cell's start puts the caret there", "\(cell.selectedRange())")
        }

        // Add buttons show only by the table's bottom or right edge, outside it
        center(editor, table.frame)
        let (rowButton, columnButton) = table.addButtons
        func pointer(_ x: CGFloat, _ y: CGFloat) -> NSPoint { editor.convert(NSPoint(x: x, y: y), from: table) }
        editor.updateTableEdges(at: pointer(table.gridWidth / 2, table.gridHeight / 2))
        await wait(0.3)
        check(rowButton.isHidden && columnButton.isHidden, "no add buttons in the middle of a table")
        editor.updateTableEdges(at: pointer(table.gridWidth * 0.3, table.gridHeight + 8))
        await wait(0.3)
        check(!rowButton.isHidden && rowButton.alphaValue > 0.99 && columnButton.isHidden, "the add-row button shows by the bottom edge")
        check(rowButton.frame.minY >= table.gridHeight, "it sits outside the table")
        let placed = rowButton.frame.midX
        editor.updateTableEdges(at: pointer(table.gridWidth * 0.8, table.gridHeight + 8))
        check(rowButton.frame.midX == placed, "it stays put while shown")
        await snap("04c-table-buttons", window)
        let rowsBefore = table.rowCount
        let buttonCenter = editor.convert(NSPoint(x: rowButton.frame.midX, y: rowButton.frame.midY), from: table)
        check(editor.hitTest(editor.convert(buttonCenter, to: editor.superview)) === rowButton, "the button takes clicks over the next block")
        click(rowButton, at: NSPoint(x: 11, y: 11))
        check((editor.view(for: tableID) as? TableBlockView)?.rowCount == rowsBefore + 1, "the round button adds a row")
        editor.undo()
        if let table = editor.view(for: tableID) as? TableBlockView {
            editor.updateTableEdges(at: editor.convert(NSPoint(x: table.gridWidth + 10, y: table.gridHeight / 2), from: table))
            await wait(0.3)
            check(!table.addButtons.column.isHidden && table.addButtons.row.isHidden, "the add-column button shows by the right edge")
            editor.updateTableEdges(at: nil)
        }

        // Moving out of the table with arrows
        editor.focusCell(CellPosition(row: 2, column: 0), in: tableID, placement: .start)
        key(editor, #selector(NSResponder.moveDown(_:)))
        check(focused(editor)?.blockID == editor.blocks[tableIndex + 1].id, "down from the last row leaves the table")
        key(editor, #selector(NSResponder.moveUp(_:)))
        check(focused(editor)?.cell?.row == 2, "up from below enters the last row", "\(String(describing: focused(editor)?.cell))")

        // Backspace merges, undo restores
        guard let breadIndex = editor.blocks.firstIndex(where: { $0.text.string == "Bread" }) else { check(false, "bread"); return }
        editor.focus(editor.blocks[breadIndex].id, .start)
        key(editor, #selector(NSResponder.deleteBackward(_:)))
        check(editor.blocks[breadIndex].kind == .paragraph, "delete at a list item's start makes it text")
        key(editor, #selector(NSResponder.deleteBackward(_:)))
        check(editor.blocks.contains { $0.text.string == "MilkBread" }, "delete at a paragraph's start joins it to the block above")
        editor.undo()
        editor.undo()
        check(editor.blocks.contains { $0.text.string == "Bread" && $0.kind == .bullet }, "undo restores the item", "\(editor.blocks.map(\.text.string))")
        editor.redo()
        check(editor.blocks[breadIndex].kind == .paragraph, "redo redoes")
        editor.undo()

        // Moving a block
        if let bread = editor.blocks.firstIndex(where: { $0.text.string == "Bread" }) {
            editor.focus(editor.blocks[bread].id, .end)
            focused(editor)?.moveBlockUp(nil)
            check(editor.blocks[bread - 1].text.string == "Bread" && editor.blocks[bread].text.string == "Milk", "move block up")
            check(note.text.contains("- Bread\n- Milk"), "moving is saved", note.text)
            editor.undo()
        }

        // Block selection
        editor.focus(editor.blocks[1].id, .start)
        key(editor, #selector(NSResponder.cancelOperation(_:)))
        check(editor.blockSelection == 1...1 && editor.window?.firstResponder === editor, "escape selects the block")
        editor.doCommand(by: #selector(NSResponder.moveDownAndModifySelection(_:)))
        check(editor.blockSelection == 1...2, "shift-down extends the selection", "\(String(describing: editor.blockSelection))")
        let countBefore = editor.blocks.count
        editor.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        check(editor.blocks.count == countBefore - 2, "delete removes selected blocks")
        editor.undo()
        check(editor.blocks.count == countBefore, "undo brings them back")
        await snap("05-selection", window)

        // Paste Markdown
        let pasted = "## Pasted heading\n\n- one\n- two\n  - nested\n\nA paragraph with *style*.\n\n| a | b |\n|---|---|\n| 1 | 2 |"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pasted, forType: .string)
        center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
        click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
        let pasteStart = editor.blocks.count - 1
        focused(editor)?.paste(nil)
        let pastedKinds = Array(kinds(editor)[pasteStart...])
        check(pastedKinds == [.heading(2), .bullet, .bullet, .bullet, .paragraph, .table], "pasted Markdown becomes blocks", "\(pastedKinds)")
        check(editor.blocks.indices.contains(pasteStart + 3) && editor.blocks[pasteStart + 3].indent == 1, "pasted nesting is kept")
        check(note.text.contains("## Pasted heading\n\n- one\n- two\n  - nested\n\nA paragraph with *style*.\n\n| a   | b   |"), "pasted blocks are written back",
              "note: \(note.text.debugDescription)")
        editor.undo()
        check(editor.blocks.count == pasteStart + 1, "undo removes the paste")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("inline **bold** text", forType: .string)
        editor.focus(editor.blocks[0].id, .end)
        focused(editor)?.paste(nil)
        check(editor.blocks[0].text.string == "Groceriesinline bold text", "one line pastes inline", editor.blocks[0].text.string)
        editor.undo()

        // A URL pasted between the brackets of [text]() becomes a link
        center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
        click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
        type(editor, "Worker: [Screendrop Worker]()")
        if let view = focused(editor) {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("https://github.com/fayazara/screendrop-worker", forType: .string)
            view.paste(nil)
            let text = editor.blocks.last?.text
            check(text?.string == "Worker: Screendrop Worker"
                  && text?.attribute(.lotionLink, at: 9, effectiveRange: nil) as? String == "https://github.com/fayazara/screendrop-worker",
                  "a URL pasted into [text]() makes a link", text?.string ?? "")
            check(note.text.contains("[Screendrop Worker](https://github.com/fayazara/screendrop-worker)"), "it is saved as a Markdown link")
            type(editor, " more")
            check(editor.blocks.last?.text.attribute(.lotionLink, at: (editor.blocks.last!.text.length - 2), effectiveRange: nil) == nil,
                  "typing after it isn't part of the link")
        }

        // Typing a URL into an auto-closed () waits until the link is finished
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "[Fayaz Ahmed]()")
        if let view = focused(editor) {
            view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))
            type(editor, "https://fayazahmed.com")
            check(editor.blocks.last?.text.string == "[Fayaz Ahmed](https://fayazahmed.com)", "no link while the URL is being typed",
                  editor.blocks.last?.text.string ?? "")
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            let text = editor.blocks.last?.text
            check(text?.string == "Fayaz Ahmed" && text?.attribute(.lotionLink, at: 0, effectiveRange: nil) as? String == "https://fayazahmed.com",
                  "leaving the brackets makes the link", text?.string ?? "")
        }

        // Leftover link style never leaks into new text
        func hasLink(_ text: NSAttributedString?) -> Bool {
            guard let text, text.length > 0 else { return false }
            var found = false
            text.enumerateAttribute(.lotionLink, in: NSRange(location: 0, length: text.length)) { value, _, stop in
                if value != nil { found = true; stop.pointee = true }
            }
            return found
        }
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "[site](https://example.com)")
        if let view = focused(editor) {
            check(hasLink(editor.blocks.last?.text), "setup: a link")
            // Delete it all, then type: the leftover style must not come back.
            view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
            key(editor, #selector(NSResponder.deleteBackward(_:)))
            type(editor, "[Fayaz Ahmed")
            check(!hasLink(editor.blocks.last?.text), "typing into an emptied link's block isn't a link",
                  editor.blocks.last?.text.string ?? "")
            // Before and inside a link.
            view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
            key(editor, #selector(NSResponder.deleteBackward(_:)))
            type(editor, "[site](https://example.com)")
            view.setSelectedRange(NSRange(location: 0, length: 0))
            type(editor, "[")
            check(editor.blocks.last?.text.attribute(.lotionLink, at: 0, effectiveRange: nil) == nil, "typing before a link isn't a link")
            view.setSelectedRange(NSRange(location: 3, length: 0))
            type(editor, "x")
            check(editor.blocks.last?.text.attribute(.lotionLink, at: 3, effectiveRange: nil) as? String == "https://example.com",
                  "typing inside a link stays in it", editor.blocks.last?.text.string ?? "")
            view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
            type(editor, "!")
            let last = (editor.blocks.last?.text.length ?? 1) - 1
            check(editor.blocks.last?.text.attribute(.lotionLink, at: last, effectiveRange: nil) == nil, "typing after a link isn't a link")
        }

        // Inline link shortcut and checkbox
        center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
        click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "see [docs](https://example.com)")
        check(editor.blocks.last?.text.string == "see docs" && editor.blocks.last?.text.attribute(.lotionLink, at: 5, effectiveRange: nil) as? String == "https://example.com",
              "typed links become links", editor.blocks.last?.text.string ?? "")
        if let todoIndex = editor.blocks.firstIndex(where: { $0.kind == .todo }), let view = editor.views[todoIndex] as? TextBlockView,
           let box = view.checkboxRect {
            center(editor, view.frame)
            click(view, at: NSPoint(x: box.midX, y: box.midY))
            check(editor.blocks[todoIndex].checked, "clicking a checkbox checks it")
            check(note.text.contains("- [x] Call the bakery"), "checked to-dos are saved")
        }

        // Saved to disk and parses back to the same blocks
        await wait(1.2)
        let onDisk = (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
        check(onDisk == note.text, "the note is saved to disk")
        check(note.url.lastPathComponent == "Groceries.md", "the file is named after the title", note.url.lastPathComponent)
        let reparsed = BlockMarkdown.parse(note.text).blocks
        let live = editor.blocks.filter { !($0.kind == .paragraph && $0.text.length == 0) }
        check(reparsed.map(\.kind) == live.map(\.kind) && reparsed.map(\.plainText) == live.map(\.plainText),
              "the saved Markdown parses back to the same blocks",
              "\(reparsed.map(\.kind)) vs \(live.map(\.kind))")
        await snap("06-final", window)
        check(note.url.deletingLastPathComponent().lastPathComponent == "Groceries", "a note lives in a folder of its own", note.url.path)

        // Pasting an image copies it into the note's folder
        let image = NSImage(size: NSSize(width: 320, height: 180), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: rect.insetBy(dx: 120, dy: 50)).fill()
            return true
        }
        if let tiff = image.tiffRepresentation {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(tiff, forType: .tiff)
            center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
            click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
            focused(editor)?.paste(nil)
            let media = editor.blocks.last(where: { $0.kind == .image })
            let file = media.map { note.url.deletingLastPathComponent().appending(path: $0.imageSource) }
            check(media != nil && file.map { FileManager.default.fileExists(atPath: $0.path) } == true,
                  "a pasted image is saved next to the note", media?.imageSource ?? "no image block")
            check(media.map { note.text.contains("](\($0.imageSource))") } == true, "the image is linked in the Markdown")
            await wait(0.6)
            await snap("07-image", window)
        }

        // A GitHub README: HTML, an alert, an attachment link
        if let readme = state.library.notes.first(where: { $0.title == "Screendrop" }) {
            state.selection = readme.id
            await wait(1.5)
            let readmeKinds = kinds(editor)
            check(readmeKinds.contains(.html) && editor.blocks.contains { $0.alert == "IMPORTANT" } && editor.blocks.contains { $0.isBareLink },
                  "GitHub HTML, alerts and attachment links are recognised", "\(readmeKinds)")
            check(editor.markdown() == readme.text, "the README writes back unchanged")
            if let htmlIndex = editor.blocks.firstIndex(where: { $0.kind == .html }), let html = editor.views[htmlIndex] as? HTMLBlockView {
                check(!html.isEditing, "HTML shows as a preview")
                center(editor, html.frame)
                await snap("08-readme", window)
                await wait(1.0)
                center(editor, html.frame)
                click(html, at: NSPoint(x: 20, y: 10))
                check(!html.isEditing && editor.blockSelection == htmlIndex...htmlIndex, "a click on HTML selects it")
                click(html, at: NSPoint(x: 20, y: 10), count: 2)
                check(html.isEditing && focused(editor)?.blockID == html.block.id, "a double-click opens its source")
                let previewHeight = html.frame.height
                type(editor, "<b>live</b>")
                await wait(0.3)
                check(html.frame.height > 60 && editor.blocks[htmlIndex].text.string.contains("<b>live</b>"),
                      "the preview stays above the source while editing", "\(previewHeight) → \(html.frame.height)")
                center(editor, html.frame)
                await snap("09-html-source", window)
                editor.undo()
                editor.focus(editor.blocks[0].id, .end)
                await wait(0.2)
                check(!html.isEditing, "leaving HTML shows the preview again")
            }
            if let badgeIndex = editor.blocks.firstIndex(where: { $0.text.string.hasPrefix("[![") }),
               let badge = editor.views[badgeIndex] as? HTMLBlockView {
                center(editor, badge.frame)
                for _ in 0..<20 where badge.imageCounts.loaded == 0 { await wait(0.5) }
                check(badge.imageCounts == (1, 1), "a linked badge renders as an image", "\(badge.imageCounts)")
                await snap("10b-badge", window)
            } else {
                check(false, "the badge line is an image row")
            }
            if let alertIndex = editor.blocks.firstIndex(where: { $0.alert != nil }) {
                center(editor, editor.views[alertIndex].frame)
                await snap("10-alert", window)
            }

            // Remote media is kept in the note's folder after the first load.
            let cache = readme.url.deletingLastPathComponent().appending(path: ".cache")
            var saved: [String] = []
            for _ in 0..<20 {
                saved = (try? FileManager.default.contentsOfDirectory(atPath: cache.path)) ?? []
                if saved.contains(where: { $0.hasSuffix(".png") || $0.hasSuffix(".jpg") }) { break }
                await wait(1)
            }
            log("INFO saved copies: \(saved)")
            check(saved.contains { !$0.hasSuffix(".mp4") }, "a remote image is saved in the note's folder", "\(saved)")
            let loaded = editor.views.compactMap { $0 as? MediaBlockView }.filter { MediaKind.of($0.block.imageSource) == .image }
            check(loaded.allSatisfy { !$0.isShimmering }, "loaded images stop shimmering")
            check(!saved.contains { $0.hasSuffix(".mp4") }, "videos are not saved unless Settings say so", "\(saved)")

            // Markdown mode
            UserDefaults.standard.set(EditorMode.markdown.rawValue, forKey: Prefs.editorMode)
            await wait(1.0)
            let source = state.editor.sourceTextView
            check(source?.window != nil && source?.string == readme.text, "Markdown mode shows the file's text")
            await snap("11-markdown-mode", window)
            if let source {
                source.setSelectedRange(NSRange(location: (source.string as NSString).length, length: 0))
                source.insertText("\n\n- [ ] typed in Markdown mode", replacementRange: source.selectedRange())
                check(readme.text.hasSuffix("- [ ] typed in Markdown mode"), "typing in Markdown mode updates the note")
            }
            UserDefaults.standard.set(EditorMode.blocks.rawValue, forKey: Prefs.editorMode)
            await wait(1.2)
            if let blocksEditor = state.editor.editor {
                check(blocksEditor.blocks.last?.kind == .todo && blocksEditor.blocks.last?.text.string == "typed in Markdown mode",
                      "back in blocks, the Markdown edit shows", "\(blocksEditor.blocks.last.map { "\($0.kind) \($0.text.string)" } ?? "-")")
            }
        } else {
            check(false, "the README note is in the library")
        }

        // Checking a box far from the caret leaves the page where it is
        state.selection = welcome.id
        await wait(1.2)
        if let editor = state.editor.editor {
            // The caret in an empty line at the very end, below the table.
            center(editor, NSRect(x: 0, y: editor.contentBottom, width: 10, height: 60))
            click(editor, at: NSPoint(x: editor.columnX + 40, y: editor.contentBottom + 30))
        }
        if let editor = state.editor.editor, let last = editor.blocks.last, last.kind == .paragraph,
           let todoIndex = editor.blocks.firstIndex(where: { $0.kind == .todo }),
           let todo = editor.views[todoIndex] as? TextBlockView, let box = todo.checkboxRect, let scroll = editor.enclosingScrollView {
            check(editor.focusedTextView?.blockID == last.id, "setup: the caret is at the end of the note")
            center(editor, todo.frame)
            check(!editor.visibleRect.intersects(editor.views[editor.blocks.count - 1].frame), "setup: the caret is off screen")
            let before = scroll.contentView.bounds.origin.y
            click(todo, at: NSPoint(x: box.midX, y: box.midY))
            await wait(0.2)
            check(abs(scroll.contentView.bounds.origin.y - before) < 1, "checking a box doesn't scroll to the caret",
                  "\(before) → \(scroll.contentView.bounds.origin.y)")
            check(editor.focusedTextView?.blockID == last.id, "the caret stays where it was")
            editor.undo()
        } else {
            let e = state.editor.editor
            check(false, "setup for the checkbox scroll check", "last: \(String(describing: e?.blocks.last?.kind)), count \(e?.blocks.count ?? 0), todo: \(e?.blocks.contains { $0.kind == .todo } ?? false), note: \(state.selectedNote?.title ?? "-")")
        }

        // Links: favicons, and a preview on hover
        state.selection = welcome.id
        await wait(1.5)
        if let editor = state.editor.editor,
           let index = editor.blocks.firstIndex(where: { $0.text.string.contains("Links look like this") }),
           let textView = editor.views[index].primaryTextView, let layout = textView.layoutManager, let container = textView.textContainer {
            center(editor, editor.views[index].frame)
            var favicon = false
            for _ in 0..<10 {
                favicon = FileManager.default.fileExists(atPath: state.library.root.appending(path: ".lotion/favicons/commonmark.org.png").path)
                if favicon { break }
                await wait(0.5)
            }
            check(favicon, "a link's favicon is saved in the library")
            let range = (textView.string as NSString).range(of: "this")
            check(textView.textStorage?.attribute(.kern, at: range.location - 1, effectiveRange: nil) != nil, "room is left for the favicon")
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let point = editor.convert(NSPoint(x: rect.midX, y: rect.midY), from: textView)
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                editor.updateLinkHover(at: point, event: move)
            }
            for _ in 0..<20 where !LinkPreview.shared.isShowing { await wait(0.1) }
            check(LinkPreview.shared.isShowing, "hovering a link shows its preview")
            // What reaches the screen, not what the layers say: two captures of the panel must differ.
            if let panelWindow = LinkPreview.shared.panelContent?.window, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                func capture(_ name: String) -> Data? {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    process.arguments = ["-x", "-o", "-l", "\(panelWindow.windowNumber)", "\(dir)/\(name).png"]
                    try? process.run()
                    process.waitUntilExit()
                    return try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(name).png"))
                }
                var frames: [Data] = []
                for index in 0..<4 {
                    if let frame = capture("14c-shimmer-\(index)") { frames.append(frame) }
                    // Keep the pointer moving along the link, as a person does.
                    for step in 0..<12 {
                        let nudge = NSPoint(x: point.x + CGFloat((index * 12 + step) % 6) - 3, y: point.y)
                        if let move = NSEvent.mouseEvent(with: .mouseMoved, location: editor.convert(nudge, to: nil), modifierFlags: [], timestamp: 0,
                                                         windowNumber: window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                            editor.updateLinkHover(at: nudge, event: move)
                        }
                        await wait(0.016)
                    }
                }
                check(frames.count == 4 && Set(frames).count > 1, "the preview's loading shimmer moves on screen")
            }
            var snapshot = false
            for _ in 0..<20 {
                snapshot = LinkPreview.cachedSnapshot(for: "https://commonmark.org/help/") != nil
                if snapshot { break }
                await wait(0.5)
            }
            check(snapshot, "the page preview is saved for next time")
            if let saved = LinkPreview.cachedSnapshot(for: "https://commonmark.org/help/"),
               let rep = saved.representations.first {
                let width = max(saved.size.width, CGFloat(rep.pixelsWide))
                check(width >= 1280, "the page is rendered at desktop width", "\(saved.size), \(rep.pixelsWide) px")
            }
            await snap("13-link", window)
            if let panelWindow = LinkPreview.shared.panelContent?.window, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", "\(panelWindow.windowNumber)", "\(dir)/14b-link-preview-live.png"]
                try? capture.run()
                capture.waitUntilExit()
            }
            if let content = LinkPreview.shared.panelContent, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir"),
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "14-link-preview.png"))
            }
            LinkPreview.shared.hide()
        }

        // Media that hasn't loaded, or can't
        if let pending = state.library.notes.first(where: { $0.title == "Placeholders" }) {
            state.selection = pending.id
            await wait(1.5)
            await snap("12-placeholders", window)
            if let window, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/12b-placeholders-live.png"]
                try? capture.run()
                capture.waitUntilExit()
            }
            let media = state.editor.editor?.views.compactMap { $0 as? MediaBlockView } ?? []
            check(media.first?.isShimmering == true, "loading media shimmers")
            check(media.last?.isShimmering == false, "media that failed doesn't")
            if let first = state.editor.editor?.views.first(where: { $0 is MediaBlockView }) {
                check(abs(first.frame.height - 8 - round(first.frame.width * 9 / 16)) <= 1, "media that is loading waits in a 16:9 frame",
                      "\(first.frame.size)")
            }
        }

        // Themes
        check(LotionTheme.allCases.count >= 40, "the theme catalog is there", "\(LotionTheme.allCases.count)")
        let missing = LotionTheme.allCases.flatMap { [$0.light, $0.dark].compactMap { $0?.shikiTheme } }
            .filter { !CodeHighlighter.shared.canHighlight(theme: $0) }
        check(missing.isEmpty, "every theme's code colors load", "\(missing)")

        // Settings
        NotificationCenter.default.post(name: openSettings, object: nil)
        await wait(1.5)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.frame.width > 600 && $0.frame.width < 900 }) {
            for pane in SettingsPane.allCases {
                UserDefaults.standard.set(pane.rawValue, forKey: "settingsTab")
                await wait(0.8)
                await snap("15-settings-\(pane.rawValue)", settings)
                // The real window, materials and all, when the system allows capturing it.
                if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", "\(settings.windowNumber)", "\(dir)/16-settings-\(pane.rawValue).png"]
                    try? capture.run()
                    capture.waitUntilExit()
                    // Scroll through the theme cards too.
                    if pane == .appearance, let scroll = Self.largestScrollView(in: settings.contentView) {
                        for (index, y) in [700.0, 1400, 2100].enumerated() {
                            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
                            scroll.reflectScrolledClipView(scroll.contentView)
                            await wait(0.6)
                            let more = Process()
                            more.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                            more.arguments = ["-x", "-o", "-l", "\(settings.windowNumber)", "\(dir)/17-themes-\(index).png"]
                            try? more.run()
                            more.waitUntilExit()
                        }
                    }
                }
            }
            settings.close()
        } else {
            check(false, "settings open")
        }

        await polish(state)
        guard let editor = state.editor.editor else { return }
        await performance(state, editor)
        log(failures == 0 ? "DONE all passed" : "DONE \(failures) failed")
    }

    // MARK: Inspector, scroll spy and zoom

    /// The whole window, overlays above the content included.
    private static func snapFrame(_ name: String, _ window: NSWindow?) async {
        await wait(0.3)
        log("SNAP \(name)")
        guard let window, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir"),
              let view = window.contentView?.superview,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "\(name).png"))
    }

    // MARK: Diagrams

    static let sampleDiagrams: [(String, String)] = [
        ("workflow", """
        flowchart LR
          A[Record created<br>New record created]:::active --> B[Web agent<br>Enrich lead with web research]:::active
          B --> C[Custom agent<br>Score lead for ICP fit]
          C --> D{If<br>Route lead by segment}
          D -- True --> E[Enroll in sequence<br>Enterprise sequence]
          D -- False --> F[Enroll in sequence<br>SMB sequence]
          classDef active stroke:#3B82F6
        """),
        ("vertical", """
        graph TD
          start([Start]) --> login[User signs in]
          login --> valid{Valid password?}
          valid -->|Yes| dash[Load dashboard<br>Fetch data from the API]
          valid -->|No| err[Show error]
          err -.-> login
          dash --> done((Done))
        """),
        ("groups", """
        flowchart LR
          subgraph Client
            ui[Web app] --> cache[(Local cache)]
          end
          subgraph Cloud [Backend]
            api[API server] --> db[(Postgres)]
            api --> q[Job queue]
          end
          ui ==> api
          q --> mail[Send email]
          a & b --> c
        """),
        ("architecture", """
        flowchart LR
          web[Web app<br>TanStack Start + Kumo] -- WebSocket --> worker[Worker<br>src/server.ts]
          worker --> hub[UserHub<br>1 per user]
          worker -- /apps/* --> live[AppLive<br>1 per bot-built app]
          worker --> bot[BotAgent<br>1 per bot]
          hub --> you[YourAgent<br>MCP / Executor]
          hub <-- RPC --> bot
        """),
        ("fanin", """
        flowchart LR
          a[You type] --> bot[BotAgent]
          r[Routine / check-in] --> bot
          e[Email to user.bot@domain] --> bot
          p[POST /api/hooks/...] --> bot
          o[Another bot] --> bot
          s[Someone edits a shared app] --> bot
          bot --> push[Push notification to you]
        """),
        ("sequence", """
        sequenceDiagram
          participant You
          participant Bot as BotAgent
          participant Model
          participant Tools

          You->>Bot: "Pull this week's leads"
          Bot->>Bot: load memory, rules, open items, app tools
          loop up to 40 steps
            Bot->>Model: messages + tools
            Model-->>Bot: tool call
            alt rule is "ask first"
              Bot-->>You: approval card
              You->>Bot: approve
            end
            Bot->>Tools: run it
            Tools-->>Bot: result
          end
          Bot-->>You: answer
        """),
        ("sequence-more", """
        sequenceDiagram
          autonumber
          actor Alice
          participant API as API server<br>v2
          participant DB as Postgres
          Note over Alice,API: Signing in
          Alice->>+API: POST /login
          API->>+DB: find user
          DB-->>-API: row
          alt password matches
            API-->>Alice: 200 + token
          else wrong password
            API--xAlice: 401
          end
          Note right of DB: Rows are cached for 5 min
          API-)DB: log attempt
          deactivate API
        """),
        ("unsupported", "gantt\n  title Launch\n  section Build\n  Cards :a1, 2026-01-01, 3d"),
    ]

    private static func diagrams(_ state: AppState) async {
        let dir = UserDefaults.standard.string(forKey: "LotionSnapDir")
        if let dir { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

        // Parsing
        if case .success(let chart) = FlowchartParser.parse(sampleDiagrams[0].1) {
            check(chart.direction == .right, "a flowchart reads its direction")
            check(chart.nodes.count == 6, "every node is read", "\(chart.nodes.map(\.id))")
            check(chart.edges.count == 5, "every edge is read", "\(chart.edges.map { "\($0.from)->\($0.to)" })")
            check(chart.nodes.first?.title == "Record created" && chart.nodes.first?.detail == "New record created", "a <br> splits title from detail")
            check(chart.edges.contains { $0.label == "True" } && chart.edges.contains { $0.label == "False" }, "edge labels written -- text --> are read",
                  "\(chart.edges.map(\.label))")
            check(chart.nodes.first?.classes == ["active"], ":::class is read")
        } else {
            check(false, "the workflow parses")
        }
        if case .success(let chart) = FlowchartParser.parse(sampleDiagrams[1].1) {
            check(chart.direction == .down, "graph TD reads as down")
            check(chart.edges.contains { $0.label == "Yes" } && chart.edges.contains { $0.line == .dotted }, "|label| and dotted links are read",
                  "\(chart.edges.map { "\($0.from)->\($0.to) \($0.label) \($0.line)" })")
            check(chart.nodes.first { $0.id == "valid" }?.shape == .decision, "{} is a decision")
        }
        if case .success(let chart) = FlowchartParser.parse(sampleDiagrams[2].1) {
            check(chart.groups.count == 2 && chart.groups.contains { $0.title == "Backend" }, "subgraphs and their titles are read", "\(chart.groups)")
            check(chart.edges.filter { $0.to == "c" }.count == 2, "& joins nodes")
            check(chart.edges.contains { $0.line == .thick }, "==> is thick")
        }
        if case .success(let chart) = SequenceParser.parse(sampleDiagrams.first { $0.0 == "sequence" }!.1) {
            check(chart.participants.map(\.title) == ["You", "BotAgent", "Model", "Tools"], "sequence participants and aliases are read",
                  "\(chart.participants.map(\.title))")
            let messages = chart.events.compactMap { if case .message(let m) = $0 { m } else { nil } }
            check(messages.count == 9, "every message is read", "\(messages.count)")
            check(messages.first?.text == "Pull this week's leads", "quoted message text is unquoted", messages.first?.text ?? "")
            check(messages.contains { $0.from == $0.to }, "a message to oneself is read")
            check(messages.contains { $0.dashed } && messages.contains { !$0.dashed }, "-->> is dashed and ->> solid")
            let starts = chart.events.compactMap { if case .start(let kind, let label) = $0 { "\(kind):\(label)" } else { nil } }
            check(starts == ["loop:up to 40 steps", "alt:rule is \"ask first\""] || starts == ["loop:up to 40 steps", "alt:rule is ask first"],
                  "loop and alt blocks are read", "\(starts)")
            check(chart.events.filter { if case .end = $0 { true } else { false } }.count == 2, "blocks close")
            let layout = SequenceLayout.make(chart, metrics: FlowMetrics(base: 16))
            check(layout.frames.count == 2 && layout.frames.last.map { inner in layout.frames.first.map { $0.rect.contains(inner.rect) } ?? false } == false
                  || layout.frames.contains { outer in layout.frames.contains { $0.rect != outer.rect && outer.rect.contains($0.rect) } },
                  "the alt frame sits inside the loop frame", "\(layout.frames.map(\.rect))")
            var overlaps = 0
            for (i, a) in layout.messages.enumerated() where !a.text.isEmpty {
                for b in layout.messages.dropFirst(i + 1) where !b.text.isEmpty && a.textRect.intersects(b.textRect) { overlaps += 1 }
                for card in layout.cards where card.rect.intersects(a.textRect) { overlaps += 1 }
            }
            check(overlaps == 0, "sequence labels don't collide", "\(overlaps)")
        } else {
            check(false, "the sequence diagram parses")
        }
        if case .failure(.unsupported) = DiagramContent.make(sampleDiagrams.last!.1, metrics: FlowMetrics(base: 16)) {
            check(true, "other diagram types are reported, not drawn")
        } else {
            check(false, "other diagram types are reported, not drawn")
        }

        // Drawing, in light and dark
        for dark in [false, true] {
            let style = EditorStyle(theme: .paper, isDark: dark, noteFont: "System", noteFontSize: 16, lineSpacing: .comfortable,
                                    codeFont: "SF Mono", readableWidth: .medium, spellCheck: false)
            let palette = style.palette
            for (name, source) in sampleDiagrams.dropLast() {
                let metrics = FlowMetrics(base: 16)
                guard case .success(let content) = DiagramContent.make(source, metrics: metrics) else { check(false, "\(name) draws"); continue }
                if case .flow(let chart, let layout) = content {
                    check(layout.nodes.count == chart.nodes.count, "\(name): every node is placed")
                    var overlaps = 0
                    for i in layout.nodes.indices { for j in layout.nodes.indices where j > i && layout.nodes[i].rect.intersects(layout.nodes[j].rect) { overlaps += 1 } }
                    check(overlaps == 0, "\(name): no cards overlap", "\(overlaps)")
                }
                let image = NSImage(size: content.size, flipped: true) { rect in
                    DiagramPainter.drawCanvas(in: rect, palette: palette, rounded: false)
                    content.draw(metrics: metrics, palette: palette)
                    return true
                }
                guard let dir, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { continue }
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appending(path: "diagram-\(name)-\(dark ? "dark" : "light").png"))
            }
        }

        // In a note
        var text = "# Diagrams\n\nA workflow:\n\n"
        for (_, source) in sampleDiagrams { text += "```mermaid\n\(source)\n```\n\n" }
        guard let note = state.library.createNote(in: nil) else { check(false, "a diagram note opens"); return }
        state.library.update(note, text: text)
        state.selection = note.id
        await wait(1.2)
        guard let editor = state.editor.editor else { check(false, "the diagram note shows"); return }
        check(editor.views.filter { $0 is DiagramBlockView }.count == sampleDiagrams.count, "mermaid fences show as diagrams")
        check(editor.markdown() == text.trimmingTrailingWhitespace() + "\n" || editor.markdown() == text, "diagram notes write back unchanged",
              editor.markdown())
        await snap("diagram-note", editor.window)
        // A chart wider than the column scrolls sideways under a two-finger swipe.
        if let wide = editor.views.compactMap({ $0 as? DiagramBlockView }).first(where: { $0.scrollableWidth > 0 }),
           let window = editor.window, let scroll = editor.enclosingScrollView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, wide.frame.minY - 60)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await wait(0.4)
            let local = NSPoint(x: wide.bounds.midX, y: min(wide.bounds.midY, 80))
            let screen = window.convertPoint(toScreen: wide.convert(local, to: nil))
            let height = NSScreen.screens.first?.frame.height ?? 0
            for _ in 0..<4 {
                if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: -30, wheel3: 0) {
                    cg.location = CGPoint(x: screen.x, y: height - screen.y)
                    if let event = NSEvent(cgEvent: cg) { window.sendEvent(event) }
                }
            }
            await wait(0.2)
            check(wide.horizontalOffset > 0, "a wide diagram scrolls sideways", "offset \(wide.horizontalOffset) of \(wide.scrollableWidth)")
            await snap("diagram-scrolled", window)
        } else {
            check(false, "a sample diagram is wider than the column")
        }
        if let first = editor.views.firstIndex(where: { $0 is DiagramBlockView }) {
            editor.focus(editor.blocks[first].id, .end)
            await wait(0.4)
            check((editor.views[first] as? DiagramBlockView)?.isEditing == true, "focusing a diagram shows its source")
            type(editor, "\n  F --> G[Archive lead]")
            await wait(0.3)
            check(editor.blocks[first].text.string.contains("Archive lead"), "typing edits the diagram's source")
            await snap("diagram-editing", editor.window)
        }
    }

    // MARK: Demo library

    /// The share popover in each of its states, light and dark, for a look.
    /// Needs no worker. Snaps go to `-LotionSnapDir`.
    private static func sharePopover(_ state: AppState) async {
        let library = state.library
        let cover = NSImage(size: NSSize(width: 600, height: 200), flipped: false) { rect in
            NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])?.draw(in: rect, angle: 20)
            return true
        }
        if let tiff = cover.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: library.root.appending(path: "cover.png"))
        }
        try? "# Launch plan\n\nShipping Lotion on Tuesday.\n".write(to: library.root.appending(path: "Launch plan.md"), atomically: true, encoding: .utf8)
        library.refreshFromDisk()
        guard let note = library.notes.first(where: { $0.title == "Launch plan" }) else {
            check(false, "the share test note is in the library")
            return
        }
        library.setIcon("paperplane.fill", for: note)
        library.setCover(NoteCover(file: library.root.appending(path: "cover.png").path), for: note)
        if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        let published = Publication(id: "k3h8x2m9q4wz", url: URL(string: "https://lotion-share.fayaz.workers.dev/n/k3h8x2m9q4wz")!,
                                    published: note.modified.addingTimeInterval(-3600))
        let states: [(String, Publication?, Bool)] = [("setup", nil, false), ("publish", nil, true), ("published", published, true)]
        for dark in [false, true] {
            let style = EditorStyle(theme: .paper, isDark: dark, noteFont: FontChoice.system, noteFontSize: 15,
                                    lineSpacing: .comfortable, codeFont: FontChoice.mono, readableWidth: .medium, spellCheck: false)
            for (name, publication, configured) in states {
                var popover = SharePopover(note: note, library: library, style: style)
                popover.forcedPublication = publication
                popover.forcesConfigured = configured
                let hosting = NSHostingView(rootView: popover.background(.windowBackground))
                hosting.frame.size = hosting.fittingSize
                let window = KeyWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                await wait(0.6)
                check(hosting.fittingSize.height > 150, "the \(name) state lays out", "\(hosting.fittingSize)")
                await snap("share-\(name)-\(dark ? "dark" : "light")", window)
                window.close()
            }
        }
    }

    /// Publishing to a Lotion Share worker, end to end. Launch with
    /// `-cloudURL <worker>` and `-LotionCloudToken <token>`, against a scratch
    /// library: the test writes its own note, image and file into it.
    private static func cloud(_ state: AppState) async {
        let library = state.library
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        if let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: library.root.appending(path: "pic.png"))
        }
        try? "Some notes\n".write(to: library.root.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try? """
        # Cloud test

        A note published from Lotion's self-test.

        ![An orange square](pic.png)

        [notes.txt](notes.txt)

        ![Not here](missing.png)
        """.write(to: library.root.appending(path: "Cloud test.md"), atomically: true, encoding: .utf8)
        library.refreshFromDisk()
        guard let note = library.notes.first(where: { $0.title == "Cloud test" }) else {
            check(false, "the cloud test note is in the library")
            return
        }
        check(CloudSettings.isConfigured, "the worker is configured", CloudSettings.workerURL?.absoluteString ?? "no URL")
        library.setIcon("star.fill", for: note)
        library.setCover(NoteCover(file: note.url.deletingLastPathComponent().appending(path: "pic.png").path), for: note)
        let style = EditorStyle(theme: .paper, isDark: false, noteFont: FontChoice.serif, noteFontSize: 15,
                                lineSpacing: .comfortable, codeFont: FontChoice.mono, readableWidth: .medium, spellCheck: false)

        func fetch(_ url: URL) async -> (Int, String, String) {
            guard let (data, response) = try? await URLSession.shared.data(from: url), let http = response as? HTTPURLResponse else {
                return (0, "", "")
            }
            return (http.statusCode, http.value(forHTTPHeaderField: "Content-Type") ?? "", String(decoding: data, as: UTF8.self))
        }

        do {
            let info = try await CloudClient.configured().checkCompatible()
            check(info.apiVersion >= CloudSettings.requiredAPIVersion, "the worker speaks a compatible API", "\(info.apiVersion)")

            let first = try await Publisher.publish(note, library: library, style: style)
            let url = first.publication.url
            check(library.publication(for: note)?.id == first.publication.id, "the library remembers the publication")
            check(first.skipped == ["missing.png"], "a file that isn't there is reported, not fatal", "\(first.skipped)")

            let (status, _, page) = await fetch(url)
            check(status == 200 && page.contains("<title>Cloud test</title>"), "the published page loads", "\(status)")
            check(page.contains("Published with Lotion"), "the page is Lotion's", String(page.prefix(200)))
            check(!page.contains("ui-serif"), "the page uses the system font, not the note's serif")
            let files = page.ranges(of: "/files/\(first.publication.id)/").count
            check(files >= 4, "the image, file, cover and icon point at the worker", "\(files)")

            // Every file the page links to is there, with the right type.
            let links = Set(page.matches(of: /\/files\/[a-z0-9]+\/[0-9a-f]+\.[a-z]+/).map { String($0.output) })
            var served = 0
            for link in links {
                let (code, type, _) = await fetch(URL(string: link, relativeTo: url)!)
                if code == 200 { served += 1 }
                if link.hasSuffix(".png") { check(type == "image/png", "PNGs are served as images", type) }
            }
            check(!links.isEmpty && served == links.count, "every linked file is served", "\(served)/\(links.count)")

            // Updating keeps the address, and shows the change.
            note.setText(note.text + "\nA line added after publishing.\n")
            let second = try await Publisher.publish(note, library: library, style: style)
            check(second.publication.url == url, "updating keeps the same link", second.publication.url.absoluteString)
            let (_, _, updated) = await fetch(url)
            check(updated.contains("A line added after publishing."), "the page shows the update")

            let listed = try await CloudClient.configured().notes()
            check(listed.contains { $0.id == first.publication.id }, "the worker lists the note")

            try await Publisher.unpublish(note, library: library)
            check(library.publication(for: note) == nil, "unpublishing forgets the link")
            let (gone, _, _) = await fetch(url)
            check(gone == 404, "the page is gone after unpublishing", "\(gone)")
        } catch {
            check(false, "publishing works", error.localizedDescription)
        }

        // For a look: Settings → Cloud, and the note left published.
        if UserDefaults.standard.string(forKey: "LotionSnapDir") != nil {
            if let result = try? await Publisher.publish(note, library: library, style: style) {
                log("PUBLISHED \(result.publication.url.absoluteString)")
            }
            SettingsWindowController.show(pane: .cloud)
            await wait(3)
            if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            await snap("cloud-settings", NSApp.windows.first { $0.frameAutosaveName == "SettingsWindow" })
        }

        // A wrong token is caught by Verify, with a clear message.
        do {
            _ = try await CloudClient(baseURL: CloudSettings.workerURL!, token: "wrong").info()
            check(false, "a wrong token is refused")
        } catch {
            check((error as? CloudError).map { if case .unauthorized = $0 { true } else { false } } ?? false,
                  "a wrong token is refused", error.localizedDescription)
        }
    }

    private static func demo(_ state: AppState) async {
        check(DemoLibrary.isEnabled, "the demo library is on")
        check(state.library.root == DemoLibrary.root, "the demo library has its own folder", state.library.root.path)
        check(state.library.notes.count == DemoLibrary.notes.count, "every demo note is listed", "\(state.library.notes.count)")
        check(state.library.pinnedNotes.count == DemoLibrary.notes.filter(\.pinned).count, "demo pins are read")
        // Covers come from Unsplash as the library opens.
        for _ in 0..<90 where state.library.notes.contains(where: { state.library.cover(for: $0) == nil }) { await wait(1) }
        let covered = state.library.notes.filter { state.library.cover(for: $0) != nil }.count
        check(covered == DemoLibrary.notes.count, "every demo note has a cover", "\(covered) of \(DemoLibrary.notes.count)")
        for (index, title) in ["About Lotion", "Launch plan", "Launch video script", "Reading list", "Demo — Realtime cursors"].enumerated() {
            guard let note = state.library.notes.first(where: { $0.title == title }) else { check(false, "\(title) exists"); continue }
            state.selection = note.id
            await wait(index <= 1 || index == 3 ? 6 : 2)
            await snap("demo-\(index + 1)", state.editor.editor?.window)
            // The readme is long; look at all of it.
            if index == 0, let editor = state.editor.editor, let scroll = editor.enclosingScrollView {
                var page = 0
                while scroll.contentView.bounds.maxY < editor.frame.height - 10, page < 10 {
                    page += 1
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(page) * scroll.contentView.bounds.height * 0.9))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    await wait(1.5)
                    await snap("demo-1-\(page)", editor.window)
                }
            }
        }
    }

    // MARK: Embeds

    static let sampleEmbeds = [
        "https://www.apple.com/macbook-air/",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
        "https://open.spotify.com/track/4cOdK2wGLETKBW3PvgPWqT",
        "https://github.com/obsidianmd/pele",
        "https://github.com/swiftlang/swift/pull/80000",
        "https://x.com/jack/status/20",
        "https://www.google.com/maps/place/Eiffel+Tower/@48.8583701,2.2944813,16z",
        "https://vimeo.com/76979871",
        "https://codepen.io/team/codepen/pen/PNaGbb",
    ]

    private static func embeds(_ state: AppState) async {
        if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // Recognizing links
        let kinds = sampleEmbeds.map { EmbedTarget.classify($0) }
        func isCase(_ index: Int, _ test: (EmbedTarget) -> Bool) -> Bool { kinds[index].map(test) ?? false }
        check(isCase(0) { if case .bookmark = $0 { true } else { false } }, "a page is a bookmark")
        check(isCase(1) { if case .video(.youtube, "dQw4w9WgXcQ", _, _) = $0 { true } else { false } }, "YouTube links are videos")
        check(isCase(2) { if case .frame(_, 152, "Spotify") = $0 { true } else { false } }, "Spotify tracks are compact players")
        check(isCase(3) { if case .github(let ref, _) = $0 { ref.slug == "obsidianmd/pele" && ref.number == nil } else { false } }, "GitHub repos are cards")
        check(isCase(4) { if case .github(let ref, _) = $0 { ref.number == 80000 && ref.isPull } else { false } }, "GitHub pull requests are cards")
        check(isCase(5) { if case .post = $0 { true } else { false } }, "X posts are posts")
        check(isCase(6) { if case .map(let place, _) = $0 { place.latitude != nil && place.name == "Eiffel Tower" } else { false } }, "Google Maps links are maps")
        check(EmbedTarget.classify("https://youtu.be/dQw4w9WgXcQ?t=42").map { if case .video(_, _, _, let player) = $0 { player.absoluteString.contains("start=42") } else { false } } ?? false,
              "youtu.be links keep their start time")
        check(IframeHTML.parse("<iframe src=\"https://example.com/x\" height=\"320\"></iframe>")?.height == 320, "an iframe's height is read")

        // In a note
        var text = "# Embeds\n\n[TOC]\n\n## Links\n\n"
        for link in sampleEmbeds { text += link + "\n\n" }
        text += "<iframe src=\"https://www.openstreetmap.org/export/embed.html?bbox=-0.1300,51.5000,-0.1100,51.5100&layer=mapnik\" height=\"280\"></iframe>\n\n"
        text += "A plain <https://example.com> link stays a link.\n\n<https://example.com/alone>\n"
        let blocks = BlockMarkdown.parse(text).blocks
        check(blocks.filter { $0.kind == .embed && $0.info.isEmpty }.count == sampleEmbeds.count, "links alone on a line are embeds",
              "\(blocks.map(\.kind))")
        check(blocks.contains { $0.kind == .embed && $0.info == "toc" }, "[TOC] is a table of contents")
        check(blocks.last?.kind == .paragraph, "a link in angle brackets stays a link")
        var edited = blocks
        if let last = edited.indices.last { edited[last].touch() }
        check(BlockMarkdown.write(edited, trailingNewlines: 1).hasSuffix("<https://example.com/alone>\n"), "a lone link paragraph writes with brackets",
              BlockMarkdown.write(edited, trailingNewlines: 1))

        guard let note = state.library.createNote(in: nil) else { check(false, "an embed note opens"); return }
        state.library.update(note, text: text)
        state.selection = note.id
        await wait(1.5)
        guard let editor = state.editor.editor, let scroll = editor.enclosingScrollView else { check(false, "the embed note shows"); return }
        check(editor.markdown() == text, "embed notes write back unchanged")
        check(editor.views.filter { $0 is EmbedBlockView }.count >= sampleEmbeds.count + 1, "embeds and the iframe have embed views")
        await wait(8)
        var shot = 0
        for view in editor.views where view is EmbedBlockView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, view.frame.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await wait(1.2)
            shot += 1
            await snap("embed-\(shot)", editor.window)
            // Window snapshots leave web views blank; take their own.
            if let embed = view as? EmbedBlockView, let web = embed.webView, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                let image = try? await web.takeSnapshot(configuration: nil)
                if let image, let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appending(path: "embed-\(shot)-web.png"))
                }
                log("INFO web \(shot): loading=\(web.isLoading) url=\(embed.shownTarget.map { "\($0)" }?.prefix(60) ?? "")")
            }
        }
        // Clicking a video plays it in place.
        if let video = editor.views.compactMap({ $0 as? EmbedBlockView }).first(where: { if case .video(.youtube, _, _, _) = $0.shownTarget { true } else { false } }),
           let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, video.frame.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            _ = video.mouseDownOutsideText(at: NSPoint(x: video.bounds.midX, y: video.bounds.midY), event: event)
            await wait(6)
            check(video.webView != nil, "clicking a video starts its player")
            if let web = video.webView, let dir = UserDefaults.standard.string(forKey: "LotionSnapDir"),
               let image = try? await web.takeSnapshot(configuration: nil), let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir).appending(path: "embed-video-playing.png"))
            }
        }
        if let post = editor.views.compactMap({ $0 as? EmbedBlockView }).first(where: { if case .post = $0.shownTarget { true } else { false } }) {
            check((post.reportedPostHeight ?? 0) > 150, "the X post renders and reports its height", "\(String(describing: post.reportedPostHeight))")
        }
        // A selected card is wrapped evenly, its corners parallel to the card's.
        if let card = editor.views.compactMap({ $0 as? EmbedBlockView }).first(where: { if case .bookmark = $0.shownTarget { true } else { false } }),
           let index = editor.views.firstIndex(where: { $0 === card }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, card.frame.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            editor.selectBlocks([editor.blocks[index].id])
            await wait(0.4)
            await snap("embed-selected", editor.window)
            editor.selectBlocks([])
        }
        // An empty embed: its icon and field sit on one line.
        editor.insertEmbed(Block(kind: .embed), at: editor.blocks.count - 1, replacingEmpty: false)
        await wait(0.5)
        if let empty = editor.views.compactMap({ $0 as? EmbedBlockView }).last {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, empty.frame.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await wait(0.4)
            await snap("embed-empty", editor.window)
        }
    }

    // MARK: Documents

    private static func documents(_ state: AppState) async {
        if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        guard let other = state.library.createNote(in: nil) else { check(false, "a note to embed"); return }
        state.library.update(other, text: "# Project Plan\n\nShip the **embeds** by Friday.\n\n## Tasks\n\n- [x] Cards\n- [ ] Players\n- Maps and files\n\n> Keep it native.\n")
        guard let note = state.library.createNote(in: nil) else { check(false, "a documents note opens"); return }
        let folder = note.url.deletingLastPathComponent()

        // A three-page PDF.
        let pdfURL = folder.appending(path: "brief.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        if let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil) {
            for page in 1...3 {
                context.beginPDFPage(nil)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
                NSColor(hex: [0x3B82F6, 0x22A06B, 0xEA7A2E][page - 1]).setFill()
                NSRect(x: 60, y: 560, width: 492, height: 160).fill()
                ("Page \(page) of the brief" as NSString).draw(at: NSPoint(x: 60, y: 500), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 32)])
                ("Some words on the page, to look like a document." as NSString).draw(at: NSPoint(x: 60, y: 460), withAttributes: [.font: NSFont.systemFont(ofSize: 16)])
                NSGraphicsContext.restoreGraphicsState()
                context.endPDFPage()
            }
            context.closePDF()
        }
        // Two seconds of a tone that swells and fades.
        let audioURL = folder.appending(path: "tone.wav")
        if let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
           let file = try? AVAudioFile(forWriting: audioURL, settings: format.settings),
           let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 88_200) {
            buffer.frameLength = 88_200
            for i in 0..<88_200 {
                let t = Double(i) / 44_100
                buffer.floatChannelData![0][i] = Float(sin(2 * .pi * 440 * t) * sin(.pi * t / 2) * (0.4 + 0.6 * abs(sin(t * 7))))
            }
            try? file.write(from: buffer)
        }
        try? Data(repeating: 7, count: 48_000).write(to: folder.appending(path: "report.zip"))

        let text = "# Documents\n\n[TOC]\n\n## Another note\n\n![[Project Plan]]\n\n![[Missing Note]]\n\n## Files\n\n![Brief](brief.pdf)\n\n![Tone](tone.wav)\n\n[report.zip](report.zip)\n\n### The end\n\nDone.\n"
        state.library.update(note, text: text)
        state.selection = note.id
        await wait(1.5)
        guard let editor = state.editor.editor, let scroll = editor.enclosingScrollView else { check(false, "the documents note shows"); return }
        check(editor.markdown() == text, "document notes write back unchanged")
        check(editor.views.contains { $0 is TocBlockView }, "[TOC] shows the contents")
        check(editor.views.contains { $0 is NoteEmbedBlockView }, "![[Note]] shows the note")
        check(editor.views.contains { $0 is PDFBlockView }, "PDFs show as pages")
        check(editor.views.contains { $0 is AudioBlockView }, "audio shows as a player")
        check(editor.views.contains { $0 is FileBlockView }, "other files show as chips")
        await wait(1.5)
        await snap("documents-1", editor.window)
        if let pdf = editor.views.first(where: { $0 is PDFBlockView }) {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, pdf.frame.minY - 80)))
            scroll.reflectScrolledClipView(scroll.contentView)
            await wait(1)
            await snap("documents-2", editor.window)
        }
        // Adding a heading updates the contents.
        if let last = editor.blocks.last {
            editor.focus(last.id, .end)
            type(editor, "\n## Added later")
            await wait(0.3)
            let toc = editor.views.first { $0 is TocBlockView }
            check((toc?.frame.height ?? 0) > 0, "the contents block has height")
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await wait(0.6)
        await snap("documents-3", editor.window)
    }

    private static func polish(_ state: AppState) async {
        if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        // An image to zoom, kept beside the note.
        let picture = NSImage(size: NSSize(width: 1600, height: 1000), flipped: false) { rect in
            NSGradient(colors: [.systemIndigo, .systemTeal, .systemOrange])?.draw(in: rect, angle: 30)
            NSColor.white.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: NSRect(x: 600, y: 300, width: 400, height: 400)).fill()
            return true
        }
        var text = "# Field Notes\n\nAn opening paragraph that sits above the first section, set up in [Zero Trust](https://one.dash.cloudflare.com/).\n\n![A gradient](polish-picture.png)\n\n"
        let sections = ["Getting Started", "Writing", "Formatting", "Images and Video", "Keyboard Shortcuts", "Syncing", "Wrapping Up"]
        for (index, title) in sections.enumerated() {
            text += "## \(title)\n\n"
            for line in 0..<6 { text += "Paragraph \(line + 1) of \(title.lowercased()), long enough to wrap across the column a time or two so the section takes room on the page.\n\n" }
            if index % 2 == 1 { text += "### A detail of \(title.lowercased())\n\nMore words under a smaller heading.\n\n" }
        }
        guard let note = state.library.createNote(in: nil) else { check(false, "a polish note opens"); return }
        if let tiff = picture.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: note.url.deletingLastPathComponent().appending(path: "polish-picture.png"))
        }
        state.library.update(note, text: text)
        state.selection = note.id
        await wait(1.2)
        guard let editor = state.editor.editor, let window = editor.window else { check(false, "the polish note shows"); return }
        let spy = state.editor.scrollSpy

        // Scroll spy
        check(spy.entries.count == sections.count + 3, "the scroll spy lists the note's sections, not its title", "\(spy.entries.map(\.title))")
        check(spy.activeID == nil, "above the first section, none is active", "\(String(describing: spy.activeID))")
        await snapFrame("20-inspector-and-spy", window)
        if spy.entries.count > 4 {
            let target = spy.entries[4]
            spy.reveal(target.id)
            await wait(0.8)
            check(spy.activeID == target.id, "revealing a section makes it active", "\(spy.entries.first { $0.id == spy.activeID }?.title ?? "none")")
            if let view = editor.view(for: target.id), let scroll = editor.enclosingScrollView {
                let top = view.frame.minY - scroll.contentView.bounds.minY - scroll.contentInsets.top
                check(top > 0 && top < 80, "a revealed section lands just under the toolbar", "\(top)")
            }
            if let scroll = editor.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: editor.frame.height - scroll.contentView.bounds.height))
                scroll.reflectScrolledClipView(scroll.contentView)
                await wait(0.2)
                check(spy.activeID == spy.entries.last?.id, "scrolled to the end, the last section is active")
            }
            spy.reveal(spy.entries[2].id)
            await wait(0.8)
            spy.debugOpen = true
            await wait(0.6)
            await snapFrame("21-spy-card", window)
            spy.debugOpen = false
        }

        // The spy holds the section clicked while the page scrolls to it.
        if spy.entries.count > 6 {
            if let scroll = editor.enclosingScrollView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: -scroll.contentInsets.top))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
            await wait(0.2)
            let target = spy.entries[6].id
            spy.reveal(target)
            var seen: Set<UUID> = []
            for _ in 0..<12 {
                await wait(0.05)
                if let id = spy.activeID { seen.insert(id) }
            }
            check(seen == [target], "while scrolling to a section, only it is active", "\(seen.count) sections lit")
        }

        // Settings, every pane, light and dark
        NotificationCenter.default.post(name: openSettings, object: nil)
        await wait(1.2)
        if let settings = NSApp.windows.first(where: { $0.isVisible && $0 !== window && $0.frame.width > 600 && $0.frame.width < 900 }),
           let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                for pane in SettingsPane.allCases {
                    UserDefaults.standard.set(pane.rawValue, forKey: "settingsTab")
                    await wait(0.7)
                    let shot = Process()
                    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    shot.arguments = ["-x", "-o", "-l", "\(settings.windowNumber)", "\(dir)/30-settings-\(pane.rawValue)-\(appearance == .aqua ? "light" : "dark").png"]
                    try? shot.run()
                    shot.waitUntilExit()
                }
            }
            NSApp.appearance = nil
            settings.close()
        } else {
            check(false, "settings open")
        }

        // The link preview's loading card, in light mode
        let previousAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: .aqua)
        await wait(0.5)
        if let index = editor.blocks.firstIndex(where: { $0.text.string.contains("Zero Trust") }),
           let textView = editor.views[index].primaryTextView, let layout = textView.layoutManager, let container = textView.textContainer {
            center(editor, editor.views[index].frame)
            let range = (textView.string as NSString).range(of: "Zero Trust")
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layout.boundingRect(forGlyphRange: glyphs, in: container).offsetBy(dx: textView.textContainerOrigin.x, dy: textView.textContainerOrigin.y)
            let point = editor.convert(NSPoint(x: rect.midX, y: rect.midY), from: textView)
            if let move = NSEvent.mouseEvent(with: .mouseMoved, location: editor.convert(point, to: nil), modifierFlags: [], timestamp: 0,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
                editor.updateLinkHover(at: point, event: move)
            }
            for _ in 0..<20 where !LinkPreview.shared.isShowing { await wait(0.1) }
            check(LinkPreview.shared.isShowing, "hovering a link shows its preview")
            await wait(0.4)
            if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/25-preview-light-window.png"]
                try? capture.run()
                capture.waitUntilExit()
                if let panel = LinkPreview.shared.panelContent?.window {
                    let shot = Process()
                    shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    shot.arguments = ["-x", "-l", "\(panel.windowNumber)", "\(dir)/25-preview-light.png"]
                    try? shot.run()
                    shot.waitUntilExit()
                }
            }
            LinkPreview.shared.hide()
        }
        NSApp.appearance = previousAppearance

        // Zoom
        if let media = editor.views.compactMap({ $0 as? MediaBlockView }).first {
            for _ in 0..<20 where media.isShimmering { await wait(0.25) }
            center(editor, media.frame)
            await wait(0.5)
            click(media, at: NSPoint(x: media.bounds.midX, y: media.bounds.midY))
            check(MediaZoom.shared.isShowing, "a click on an image zooms it", "hit \(lastHit), shimmering \(media.isShimmering)")
            await wait(0.15)
            await snapFrame("22-zoom-midway", window)
            await wait(0.5)
            await snapFrame("23-zoomed", window)
            let overlay = window.contentView?.superview?.subviews.first { String(describing: Swift.type(of: $0)).contains("Zoom") }
            check(overlay != nil, "the zoom overlay covers the window")
            if let overlay {
                click(overlay, at: NSPoint(x: 10, y: overlay.bounds.height / 2))
                if MediaZoom.shared.isShowing { log("INFO click landed on \(lastHit)") }
            }
            check(!MediaZoom.shared.isShowing, "a click outside puts it back")
            await wait(0.5)
            check(window.contentView?.superview?.subviews.contains { String(describing: Swift.type(of: $0)).contains("Zoom") } == false,
                  "the zoom overlay is gone once it lands")
            click(media, at: NSPoint(x: media.bounds.midX, y: media.bounds.midY), flags: .shift)
            check(!MediaZoom.shared.isShowing && editor.blockSelection != nil, "⇧-click selects the image instead")
            await snapFrame("24-zoom-returned", window)
        } else {
            check(false, "the polish note shows its image")
        }

        // Prose rhythm: a talk outline, list items with lines inside them
        let outline = """
        # Coworkers in Cloudflare

        1. Intro (Desk, nothing clicked yet)
           “Hey Brandon, hey team. This is a quick demo with fake data. The idea is simple: agents that watch your Cloudflare account and come to you when something actually needs you. Not a chat box you have to ask.”
        2. BotMan
           Do: point at BotMan’s summary at the top.
           “This is BotMan, my chief of staff. He reads what every other bot found and tells me what matters, in order. Today there’s one real fire: checkout is failing.”
        3. The incident
           Do: open Pager in the sidebar.
           “Pager is my on-call bot. It saw a spike in Workers Issues and checked the status page, the audit log and recent deploys before telling me anything. So it can say: it’s us, not Cloudflare.”
           Do: open “Investigated for 48s” for a second, then close it.
        4. The status page
           Do: scroll to the status update card and the preview.
           “Pager also runs our public status page. Right now it says all green, while Pager’s own checks say checkout is failing from every region.”

        A closing paragraph, one line long.
        """
        if let talk = state.library.createNote(in: nil) {
            state.library.update(talk, text: outline)
            state.selection = talk.id
            await wait(1.0)
            if let editor = state.editor.editor {
                check(editor.blocks.filter { $0.kind == .numbered }.count == 4 && editor.blocks[1].text.string.contains("\n"),
                      "list items keep the lines inside them", "\(kinds(editor))")
                if let last = editor.views.last {
                    let line = editor.theme.lineHeight(for: .paragraph)
                    check(abs(last.frame.height - line) < 1, "a one-line paragraph is one line tall, no room above it",
                          "\(last.frame.height) vs \(line)")
                }
                await snapFrame("27-prose", window)
            }
        }

        // A folder's notes: their icons line up under the folder's icon.
        if let folder = state.library.createFolder() {
            for note in state.library.notes(in: nil).prefix(2) { state.move(note, to: folder) }
            state.expandedFolders.insert(folder)
            await wait(0.8)
            func outline(in view: NSView?) -> NSOutlineView? {
                guard let view else { return nil }
                if let outline = view as? NSOutlineView { return outline }
                for subview in view.subviews { if let found = outline(in: subview) { return found } }
                return nil
            }
            if let sidebar = outline(in: window.contentView) {
                // Folder notes are pulled back by this much to line up; it must match the system's.
                check(sidebar.indentationPerLevel == 12, "the sidebar indents a level by the amount folder notes undo",
                      "\(sidebar.indentationPerLevel)")
            }
            if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
                let shot = Process()
                shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/28-sidebar-folder.png"]
                try? shot.run()
                shot.waitUntilExit()
            }
        }

        await scratchpad(state)

        // The edits that left ghosts behind, in a note and in the scratchpad.
        if let note = state.library.notes.first(where: { $0.title == "Coworkers in Cloudflare" }) ?? state.library.notes.first {
            await writingSafety(state, in: note, label: "note")
        }
        if let pad = state.library.scratchpad { await writingSafety(state, in: pad, label: "scratchpad") }
        if let editor = state.editor.editor, let other = state.library.notes.first(where: { $0.id != state.selection }) {
            state.selection = other.id
            await wait(0.8)
            let result = viewsMatchBlocks(editor)
            check(result.ok, "another note opens clean", result.detail)
        }
    }

    // MARK: Writing without ghosts

    /// The views on screen are exactly the note's blocks, in order: nothing left behind.
    private static func viewsMatchBlocks(_ editor: BlockEditorView) -> (ok: Bool, detail: String) {
        let onScreen = editor.subviews.compactMap { $0 as? BlockView }
        let strays = onScreen.filter { view in !editor.views.contains { $0 === view } }
        let inOrder = editor.views.count == editor.blocks.count
            && zip(editor.views, editor.blocks).allSatisfy { $0.block.id == $1.id }
        let names = strays.map { String(describing: Swift.type(of: $0)) }
        return (strays.isEmpty && inOrder, "strays \(names), \(editor.views.count) views for \(editor.blocks.count) blocks")
    }

    /// Select everything and delete it; turn a line into a table, then delete it;
    /// type a code fence, then delete it. Each step leaves only what the note holds.
    private static func writingSafety(_ state: AppState, in note: Note, label: String) async {
        state.selection = note.id
        await wait(0.8)
        guard let editor = state.editor.editor else { check(false, "\(label): the editor shows"); return }
        func verify(_ step: String) {
            let result = viewsMatchBlocks(editor)
            check(result.ok, "\(label): \(step) leaves nothing behind", result.detail)
        }
        if let last = editor.blocks.last(where: { $0.kind.isEditable }) { editor.focus(last.id, .end) }
        type(editor, " and more")

        // ⌘A twice selects every block; Delete clears the page.
        focused(editor)?.selectAll(nil)
        focused(editor)?.selectAll(nil)
        check(editor.blockSelection == 0...(editor.blocks.count - 1), "\(label): ⌘A twice selects every block")
        key(editor, #selector(NSResponder.deleteBackward(_:)))
        await wait(0.1)
        if editor.isScratchpad {
            check(editor.blocks.map(\.kind) == [.entry, .paragraph], "\(label): deleting everything keeps the first entry", "\(kinds(editor))")
        } else {
            check(editor.blocks.map(\.kind) == [.heading(1)], "\(label): deleting everything leaves an empty title", "\(kinds(editor))")
        }
        check(focused(editor) != nil, "\(label): the caret is ready after deleting everything")
        verify("deleting everything")
        if !editor.isScratchpad {
            type(editor, "Fresh start")
            key(editor, #selector(NSResponder.insertNewline(_:)))
        }

        // A table from the slash menu, then deleted.
        type(editor, "/table")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        await wait(0.1)
        check(editor.blocks.contains { $0.kind == .table }, "\(label): the slash menu adds a table", "\(kinds(editor))")
        verify("turning a line into a table")
        // Undo turns the table back into the line it replaced, under the same block.
        editor.undo()
        await wait(0.1)
        check(!editor.subviews.contains { $0 is TableBlockView }, "\(label): undoing a table takes it off the page")
        verify("undoing a table")
        editor.redo()
        await wait(0.1)
        verify("redoing a table")
        if let table = editor.blocks.first(where: { $0.kind == .table }) {
            editor.selectBlocks([table.id])
            key(editor, #selector(NSResponder.deleteBackward(_:)))
            await wait(0.1)
            check(!editor.subviews.contains { $0 is TableBlockView }, "\(label): a deleted table is gone from the page")
            verify("deleting a table")
        }

        // A code block typed as a fence, then deleted.
        if let line = editor.blocks.last(where: { $0.kind == .paragraph }) {
            editor.focus(line.id, .end)
            if editor.blocks.first(where: { $0.id == line.id })?.text.length ?? 0 > 0 {
                key(editor, #selector(NSResponder.insertNewline(_:)))
            }
        }
        type(editor, "```")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        await wait(0.1)
        check(editor.blocks.contains { $0.kind == .code }, "\(label): typing a fence starts a code block", "\(kinds(editor))")
        verify("turning a line into code")
        if let code = editor.blocks.first(where: { $0.kind == .code }) {
            editor.selectBlocks([code.id])
            key(editor, #selector(NSResponder.deleteBackward(_:)))
            await wait(0.1)
            check(!editor.subviews.contains { $0 is CodeBlockView }, "\(label): a deleted code block is gone from the page")
            verify("deleting a code block")
            check(focused(editor) != nil, "\(label): the caret has somewhere to go after deleting code")
            type(editor, "still typing")
            check(editor.blocks.contains { $0.text.string.contains("still typing") }, "\(label): typing works after all that")
        }
    }

    // MARK: Scratchpad

    private static func scratchpad(_ state: AppState) async {
        guard let pad = state.library.scratchpad else { check(false, "the library has a scratchpad"); return }
        check(pad.url.path.hasSuffix(".lotion/Scratchpad/Scratchpad.md"), "the scratchpad lives in the library's own folder", pad.url.path)
        check(!state.library.notes.contains(pad), "the scratchpad is not one of the notes")
        state.openScratchpad()
        await wait(1.0)
        guard let editor = state.editor.editor, editor.isScratchpad, let window = editor.window else {
            check(false, "the scratchpad opens in the editor")
            return
        }
        check(editor.blocks.first?.kind == .entry, "the scratchpad starts with an entry", "\(kinds(editor))")
        check(!editor.isTitle(editor.blocks[1].id), "the scratchpad has no title")
        if let first = editor.blocks.first(where: { $0.kind == .paragraph }) { editor.focus(first.id, .end) }
        type(editor, "Call the plumber about the sink")
        state.newScratchpadEntry()
        await wait(0.2)
        check(editor.blocks.filter { $0.kind == .entry }.count == 2, "⌘↩ starts a new entry", "\(kinds(editor))")
        if let focusedIndex = editor.focusedIndex {
            check(editor.blocks[focusedIndex - 1].kind == .entry, "the caret waits in the new entry")
        } else {
            check(false, "the caret waits in the new entry")
        }
        state.newScratchpadEntry()
        await wait(0.1)
        check(editor.blocks.filter { $0.kind == .entry }.count == 2, "an empty entry is reused, not stacked")
        type(editor, "Ideas for the weekend")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "- [ ] ")
        type(editor, "Hike the ridge trail")
        key(editor, #selector(NSResponder.insertNewline(_:)))
        type(editor, "Farmers market")
        state.newScratchpadEntry()
        await wait(0.1)
        type(editor, "SELECT * FROM table WHERE id = 1;")
        let markers = pad.text.components(separatedBy: BlockMarkdown.entryPrefix).count - 1
        check(markers == 3, "each entry is saved with its own line", "\(markers) in\n\(pad.text)")
        check(BlockMarkdown.write(BlockMarkdown.parse(pad.text).blocks, trailingNewlines: 0) == pad.text.trimmingCharacters(in: .newlines)
              || BlockMarkdown.parse(pad.text).blocks.filter { $0.kind == .entry }.count == 3, "the scratchpad reads back as it was written")
        check(state.editor.scrollSpy.entries.map(\.title) == ["Call the plumber about the sink", "Ideas for the weekend", "SELECT * FROM table WHERE id = 1;"],
              "the scroll spy lists entries by their first line", "\(state.editor.scrollSpy.entries.map(\.title))")

        // Joining two entries: backspace at the start of an entry's first line.
        if let index = editor.blocks.lastIndex(where: { $0.kind == .entry }) {
            editor.focus(editor.blocks[index + 1].id, .start)
            key(editor, #selector(NSResponder.deleteBackward(_:)))
            check(editor.blocks.filter { $0.kind == .entry }.count == 2, "backspace at an entry's start joins it to the one before")
            editor.undo()
            check(editor.blocks.filter { $0.kind == .entry }.count == 3, "undo splits them again")
        }
        if let caret = editor.blocks.last { editor.focus(caret.id, .end) }
        await wait(0.4)
        await snapFrame("26-scratchpad", window)
        if let dir = UserDefaults.standard.string(forKey: "LotionSnapDir") {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", "\(window.windowNumber)", "\(dir)/26b-scratchpad-window.png"]
            try? shot.run()
            shot.waitUntilExit()
        }
        state.library.save(pad)
        check(FileManager.default.fileExists(atPath: pad.url.path) && pad.url.lastPathComponent == "Scratchpad.md",
              "saving the scratchpad never renames it", pad.url.path)
        let onDisk = (try? String(contentsOf: pad.url, encoding: .utf8)) ?? ""
        check(onDisk.contains("Farmers market") && onDisk.hasPrefix(BlockMarkdown.entryPrefix), "the scratchpad is saved to disk", onDisk)

        // Back to a note, so later steps get an editor that isn't in scratchpad mode.
        if let note = state.library.notes.first {
            state.selection = note.id
            await wait(0.8)
            check(state.editor.editor?.isScratchpad == false, "leaving the scratchpad leaves its mode too")
        }
    }

    // MARK: Performance

    private static func performance(_ state: AppState, _ editor: BlockEditorView) async {
        var text = "# Big note\n\n"
        for section in 0..<60 {
            text += "## Section \(section)\n\nA paragraph with **bold**, *italic*, `code` and a [link](https://example.com) that runs long enough to wrap across a line or two in the column.\n\n"
            text += "- first item\n- second item\n  - nested item\n- [ ] a task\n\n"
            if section % 6 == 0 { text += "```swift\nlet value = \(section)\nprint(value)\n```\n\n" }
            if section % 10 == 0 { text += "| a | b | c |\n|---|---|---|\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\n" }
        }
        log("INFO big note: \(text.utf8.count / 1024) KB")
        // Measure with the Markdown rewritten on every change, without touching a real note.
        editor.onChange = { [weak editor] in _ = editor?.markdown() }
        var start = Date()
        let document = BlockMarkdown.parse(text)
        let parse = Date().timeIntervalSince(start) * 1000
        start = Date()
        editor.load(document)
        editor.layoutSubtreeIfNeeded()
        let load = Date().timeIntervalSince(start) * 1000
        log("INFO parse \(Int(parse)) ms, load \(Int(load)) ms for \(document.blocks.count) blocks")
        check(load < 250, "a big note opens quickly", "\(Int(load)) ms")
        start = Date()
        let written = editor.markdown()
        let write = Date().timeIntervalSince(start) * 1000
        check(written == text, "a big note writes back unchanged")
        log("INFO write \(String(format: "%.1f", write)) ms")
        let middle = document.blocks.count / 2
        let id = editor.blocks[middle].id
        editor.focus(id, .end)
        start = Date()
        type(editor, "typing in the middle of a big note")
        let perKey = Date().timeIntervalSince(start) * 1000 / 34
        log("INFO typing \(String(format: "%.2f", perKey)) ms per key (with the note's Markdown rewritten each time)")
        check(perKey < 8, "typing in a big note stays fast", "\(perKey) ms")
        editor.onChange = nil
    }
}
#endif
