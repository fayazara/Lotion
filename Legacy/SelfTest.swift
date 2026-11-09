//
//  SelfTest.swift
//  Lotion
//
//  A scripted walk through the main flows, for Debug builds launched with
//  `-LotionSelfTest YES` (and usually `-LotionLibrary <scratch folder>`). It
//  prints PASS/FAIL lines, and SNAP lines where a screenshot is worth taking.
//

#if DEBUG
import AppKit

enum SelfTest {
    static let openSettings = Notification.Name("LotionSelfTestOpenSettings")
    static func runIfRequested(_ state: AppState) {
        guard UserDefaults.standard.bool(forKey: "LotionSelfTest") else { return }
        Task { await run(state) }
    }

    private static func log(_ line: String) {
        print("SELFTEST \(line)")
        fflush(stdout)
    }

    private static func check(_ condition: Bool, _ name: String) {
        log((condition ? "PASS " : "FAIL ") + name)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func snap(_ name: String) async {
        log("SNAP \(name)")
        await wait(1.8)
    }

    private static func type(_ textView: NSTextView, _ text: String) {
        textView.insertText(text, replacementRange: textView.selectedRange())
    }

    private static func run(_ state: AppState) async {
        let library = state.library
        let fm = FileManager.default
        await wait(1.5)
        await snap("01-welcome")

        state.newFolder()
        await wait(0.5)
        check(state.renamingFolder == "New Folder", "new folder enters rename")
        await snap("02-folder-rename")
        state.renameFolder(state.renamingFolder ?? "New Folder", to: "Ideas")
        check(library.folders == ["Ideas"] && fm.fileExists(atPath: library.root.appending(path: "Ideas").path), "folder renamed on disk")

        state.newNote(inFolder: "Ideas")
        await wait(0.8)
        guard let textView = state.editor.textView, let note = state.selectedNote else {
            check(false, "editor shows the new note")
            return
        }
        check(textView.string == "# ", "new note starts with a title mark")
        check(textView.window?.firstResponder === textView, "new note focuses the editor")
        await snap("03-new-note")

        type(textView, "Shopping list")
        func isHidden(at index: Int) -> Bool {
            textView.textStorage?.attribute(.lotionHidden, at: index, effectiveRange: nil) != nil
        }
        check(isHidden(at: 0), "heading marks are hidden")
        func caretHeights() -> (shown: CGFloat, wanted: CGFloat) {
            let editor = textView as? EditorTextView
            let shown = textView.subviews.first { $0 is NSTextInsertionIndicator }?.frame.height ?? editor?.drawnCaret?.height ?? -1
            return (shown, (textView as? EditorTextView)?.caretRect()?.height ?? -2)
        }
        let titleCaret = caretHeights()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        check(textView.selectedRange().location == 2, "the caret skips a heading's hidden marks")
        textView.deleteBackward(nil)
        check(textView.string == "Shopping list", "delete at a heading's start removes its marks")
        textView.insertText("# ", replacementRange: NSRange(location: 0, length: 0))
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        type(textView, "- [ ] Milk")
        textView.insertNewline(nil)
        check(textView.string.hasSuffix("- [ ] Milk\n- [ ] "), "return continues a checklist")
        let bodyCaret = caretHeights()
        log("INFO caret heights: title \(titleCaret), body \(bodyCaret)")
        // The caret only draws in the active app, which a background test run isn't.
        check(titleCaret.wanted > bodyCaret.wanted + 6, "a title's caret is taller than body text's")
        type(textView, "Bread")
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        check(textView.string.hasSuffix("- [ ] Bread\n"), "return on an empty item ends the list")
        textView.insertNewline(nil)
        type(textView, "1. First")
        textView.insertNewline(nil)
        check(textView.string.hasSuffix("1. First\n2. "), "numbered list counts up")
        type(textView, "Second")
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        textView.insertNewline(nil)
        type(textView, "```swift")
        textView.insertNewline(nil)
        check(textView.string.hasSuffix("```swift\n\n```"), "a new fence closes itself")
        type(textView, "let total = items.reduce(0, +)")
        await wait(1.2)
        check(note.url.lastPathComponent == "Shopping list.md" && note.folder == "Ideas", "file renamed after its title")
        check((try? String(contentsOf: note.url, encoding: .utf8)) == note.text, "text saved to disk")
        await snap("04-typed")

        textView.undoManager?.undo()
        check(!textView.string.contains("reduce"), "undo works in the note")
        textView.undoManager?.redo()
        check(textView.string.contains("reduce"), "redo works in the note")

        textView.setSelectedRange(NSRange(location: 2, length: 8))
        textView.toggleBold(nil)
        check(textView.string.hasPrefix("# **Shopping** list"), "bold wraps the selection")
        let italic = MarkdownStyler.font(.systemFont(ofSize: 15), with: .italicFontMask)
        check(italic.fontDescriptor.symbolicTraits.contains(.italic), "italic text is set in an italic font")
        check(!isHidden(at: 2), "inline marks show while the selection touches them")
        await snap("04b-revealed")
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        check(isHidden(at: 2), "inline marks hide once the caret leaves")
        textView.setSelectedRange(NSRange(location: 4, length: 8))
        textView.toggleBold(nil)
        check(textView.string.hasPrefix("# Shopping list"), "bold again unwraps it")

        let beforeTask = textView.string
        textView.setSelectedRange(NSRange(location: (beforeTask as NSString).length, length: 0))
        textView.insertNewline(nil)
        type(textView, "[]")
        type(textView, " ")
        check(textView.string.hasSuffix("\n- [ ] "), "typing [] and a space makes a checklist item")
        textView.deleteBackward(nil)
        check(textView.string.hasSuffix("```\n"), "delete at an item's start removes its marker")
        textView.deleteBackward(nil)
        check(textView.string == beforeTask, "and then joins the line above")

        // Click the first checkbox, as a user would.
        let box = (textView.string as NSString).range(of: "- [ ] Milk")
        if box.location != NSNotFound, let layoutManager = textView.layoutManager, let container = textView.textContainer {
            let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: box.location + 3, length: 1), actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            rect.origin.x += textView.textContainerOrigin.x
            rect.origin.y += textView.textContainerOrigin.y
            let point = textView.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                                              windowNumber: textView.window?.windowNumber ?? 0, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                textView.mouseDown(with: event)
            }
        }
        check(textView.string.contains("- [x] Milk"), "clicking a checkbox checks it")
        textView.undoManager?.undo()
        check(textView.string.contains("- [ ] Milk"), "undo unchecks it")

        // Another app edits the file.
        await wait(1.0)
        let external = note.text + "\nAdded elsewhere.\n"
        try? external.write(to: note.url, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.modificationDate: Date.now.addingTimeInterval(5)], ofItemAtPath: note.url.path)
        library.refreshFromDisk()
        await wait(0.3)
        check(textView.string == external, "an outside edit reaches the open note")

        // Covers.
        let editor = textView as? EditorTextView
        library.addRandomCover(for: note)
        await wait(1.5)
        check(library.cover(for: note) != nil && editor?.hasCover == true, "Add Cover shows a wallpaper")
        check(fm.fileExists(atPath: library.root.appending(path: ".lotion/covers.json").path), "covers are saved beside the notes")
        await snap("05a-cover")
        editor?.onChangeCover?(NSRect(x: textView.bounds.width - 320, y: 200, width: 280, height: 28))
        await wait(1.0)
        await snap("05b-cover-picker")
        for window in NSApp.windows where String(describing: Swift.type(of: window)).contains("Popover") { window.close() }
        if let page = try? await UnsplashClient.photos(query: "mountains", page: 1), let photo = page.photos.first {
            await library.setUnsplashCover(photo, for: note)
            await wait(1.5)
            check(library.cover(for: note)?.credit == photo.user.name, "an Unsplash photo becomes the cover, credited")
            await snap("05c-unsplash-cover")
        } else {
            log("INFO Unsplash unreachable; skipped")
        }

        state.togglePin(note)
        check(library.pinnedNotes.contains(note), "pin")
        await snap("05-pinned")
        state.togglePin(note)

        state.move(note, to: nil)
        check(note.folder == nil && fm.fileExists(atPath: library.root.appending(path: "Shopping list.md").path), "move to top level")
        state.move(note, to: "Ideas")
        check(note.folder == "Ideas", "move back into folder")
        check(library.cover(for: note) != nil, "the cover follows the note when it moves")

        state.searchText = "milk"
        await wait(0.6)
        check(library.search("milk").map(\.note) == [note], "search finds by body text")
        await snap("06-search")
        state.searchText = ""

        state.newNote(useSelection: false)
        let blank = state.selectedNote
        await wait(0.4)
        state.selection = note.id
        await wait(0.4)
        check(blank.map { !fm.fileExists(atPath: $0.url.path) && library.note(id: $0.id) == nil } ?? false, "an untouched new note is discarded")
        check(state.editor.textView?.string == note.text, "switching back shows the note")

        library.refreshFromDisk()
        check(library.note(id: note.id) === note, "refresh keeps note identity")

        state.renameFolder("Ideas", to: "Errands")
        check(note.folder == "Errands" && fm.fileExists(atPath: note.url.path), "renaming a folder moves its notes")
        state.renamingFolder = nil

        NotificationCenter.default.post(name: openSettings, object: nil)
        await wait(0.8)
        await snap("07-settings")
        NSApp.windows.first { $0.title != "Lotion" && $0.isVisible && $0.styleMask.contains(.titled) && $0 !== textView.window }?.close()

        await tablesAndCode(state)
        await tableClicks(state)
        await headingPlaceholder(state)
        await codeBlocks(state)

        state.delete(note)
        check(library.errorMessage == nil && !fm.fileExists(atPath: note.url.path), "delete moves the note to the Trash")
        state.deleteFolder("Errands")
        check(!library.folders.contains("Errands"), "delete folder")
        await snap("08-end")
        await tablePerformance(state)
        await performance(state)
        log("DONE")
    }

    /// Tables draw as a grid and edit in place, cell by cell; long code
    /// blocks fold to a height saved on their fence.
    private static func tablesAndCode(_ state: AppState) async {
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView as? EditorTextView, let storage = textView.textStorage else { return }
        let code = (1...30).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let objects = "| Durable Object | What it owns |\n| --- | --- |\n"
            + "| `UserHub` | Your bot list, app connections, shared memory, installed skills, push subscriptions |\n"
            + "| `BotAgent` | One bot: chat, memory, rules, routines, files, browser, secrets |\n"
            + "| **AppLive** | Live updates for a [web app](https://example.com) a bot built |\n"
        let people = "| Name | Role | Since |\n| --- | :---: | ---: |\n| Ada | Engineer | 2019 |\n| Grace | Admiral | 1943 |\n"
        let source = "# Tables\n\n" + objects + "\n" + people + "\nAfter.\n\n```swift title=\"compute.swift\"\n\(code)\n```\n"
        textView.string = ""
        textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        await wait(0.6)
        let text = { textView.string as NSString }
        func table(containing needle: String) -> (range: NSRange, block: TableBlock)? {
            textView.table(at: text().range(of: needle).location)
        }

        // Layout: no column narrower than its widest word, and the table's
        // first line is exactly as tall as the table drawn over it.
        if let found = table(containing: "UserHub") {
            let geometry = textView.tableGeometry(found.range, found.block)
            let layout = geometry.layout
            let pad = TableMetrics.padding.width * 2
            let fits = found.block.rows.allSatisfy { cells in
                cells.enumerated().allSatisfy { column, cell in layout.columnWidths[column] + 0.5 >= min(cell.minWidth + pad, layout.available * 0.6) }
            }
            check(fits, "table columns are at least as wide as their widest word")
            check(found.block.rows[1][0].text.string == "UserHub", "inline code marks are hidden in a cell")
            check(found.block.rows[3][0].text.string == "AppLive" && found.block.rows[3][1].text.string.contains("web app a bot"),
                  "bold and link marks are hidden in a cell")
            if let layoutManager = textView.layoutManager {
                let first = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: found.range.location), effectiveRange: nil)
                let after = text().range(of: "| Name").location
                let next = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: after - 1), effectiveRange: nil)
                check(abs(first.height - layout.blockHeight) < 0.5, "a table's first line is as tall as the table")
                check(next.minY >= first.maxY - 0.5, "text after a table starts below it")
            }
            let narrowFits = layout.width <= layout.available + 0.5
            check(narrowFits, "a table with long text wraps its cells instead of running off the page")
        } else {
            check(false, "the first table is found")
        }

        // Editing a cell writes its Markdown in place.
        guard let people0 = table(containing: "| Name") else { return check(false, "the second table is found") }
        textView.beginCellEditing(tableAt: people0.range.location, row: 1, column: 0, caret: .end)
        let editor = textView.cellEditor
        check(textView.window?.firstResponder === editor && editor.string == "Ada", "a cell opens in the cell editor")
        editor.insertText(" L.", replacementRange: editor.selectedRange())
        check(text().range(of: "| Ada L. | Engineer | 2019 |").location != NSNotFound, "typing in a cell edits its Markdown")
        check(textView.undoManager?.canUndo == true, "cell typing is undoable")
        log("INFO undo action after cell typing: \(textView.undoManager?.undoActionName ?? "nil")")
        editor.insertTab(nil)
        check(editor.string == "Engineer" && editor.selectedRange() == NSRange(location: 0, length: 8), "Tab selects the next cell")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("|x", replacementRange: editor.selectedRange())
        check(text().range(of: "| Engineer\\|x |").location != NSNotFound, "a typed pipe is escaped in a cell")
        await wait(0.2)

        textView.tableAddRow(nil)
        await wait(0.2)
        check(text().range(of: "| Ada L. | Engineer\\|x | 2019 |\n|  |  |  |").location != NSNotFound, "Add Row inserts an empty row")
        check(textView.activeCell?.row == 2, "Add Row edits the new row")
        textView.tableMoveColumnLeft(nil)
        await wait(0.2)
        check(text().range(of: "| Role | Name | Since |").location != NSNotFound, "Move Column Left swaps columns")
        check(textView.undoManager?.undoActionName == "Edit Table", "table edits are undoable")
        textView.tableMoveColumnRight(nil)
        await wait(0.2)
        textView.cellEditor.setSelectedRange(NSRange(location: 0, length: 0))
        textView.cellEditor.deleteBackward(nil)
        await wait(0.2)
        check(text().range(of: "|  |  |  |").location == NSNotFound
              && text().range(of: "| Ada L. | Engineer\\|x | 2019 |\n| Grace").location != NSNotFound, "Backspace in an empty row deletes the row")

        // Moving through and out of a table.
        guard let people = table(containing: "| Name") else { return }
        textView.beginCellEditing(tableAt: people.range.location, row: 0, column: 1, caret: .end)
        textView.cellEditor.insertNewline(nil)
        check(textView.activeCell?.row == 1 && textView.activeCell?.column == 1, "Return moves down a row")
        textView.cellEditor.moveDown(nil)
        textView.cellEditor.moveDown(nil)
        let below = NSMaxRange(people.range)
        check(textView.activeCell == nil && textView.selectedRange().location == below
              && textView.window?.firstResponder === textView, "arrowing down out of the last row lands below the table")
        textView.moveUp(nil)
        await wait(0.3)
        check(textView.activeCell != nil && textView.window?.firstResponder === textView.cellEditor, "arrowing up into a table edits a cell")
        textView.cellEditor.setSelectedRange(NSRange(location: (textView.cellEditor.string as NSString).length, length: 0))
        textView.cellEditor.insertText("zz", replacementRange: textView.cellEditor.selectedRange())
        check(text().range(of: "zz").location != NSNotFound, "typing after arrowing in edits the cell")
        // An outside change to the cell's Markdown (what undo does) reaches the cell editor.
        let zz = text().range(of: "zz")
        if zz.location != NSNotFound {
            textView.replace(zz, with: "", select: NSRange(location: zz.location, length: 0))
            await wait(0.3)
        }
        check(text().range(of: "zz").location == NSNotFound && !textView.cellEditor.string.contains("zz")
              && textView.activeCell != nil, "an outside change to a cell refreshes the cell editor")
        textView.cellEditor.cancelOperation(nil)
        check(textView.activeCell == nil, "Escape leaves the table")
        await snap("08a-tables")

        let after = text().range(of: "After.")
        textView.setSelectedRange(NSRange(location: after.location, length: 0))
        await wait(0.3)
        var scrolling = 0
        storage.enumerateAttribute(.lotionCodeViewport, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil, range.location > after.location { scrolling += range.length }
        }
        check(scrolling > 0, "a long code block scrolls in a viewport")
        let fence = text().range(of: "```swift").location
        textView.setCodeLines(8, fenceAt: fence)
        check(text().range(of: "```swift title=\"compute.swift\" lines=8").location != NSNotFound, "resizing saves lines=N on the fence")

        // A table whose words can't fit scrolls sideways, by redrawing, not restyling.
        let url = "https://example.com/" + String(repeating: "a-very-long-path-segment/", count: 4)
        let wide = "\n| One | Two | Three | Four |\n| --- | --- | --- | --- |\n| \(url) | \(url) | \(url) | far right |\n"
        textView.setSelectedRange(NSRange(location: text().length, length: 0))
        textView.insertText(wide, replacementRange: textView.selectedRange())
        await wait(0.4)
        if let found = table(containing: "far right") {
            let before = found.block
            check(textView.tableGeometry(found.range, found.block).layout.overflow > 0, "a table too wide for the page overflows")
            textView.beginCellEditing(tableAt: found.range.location, row: 1, column: 3, caret: .end)
            await wait(0.2)
            let offset = textView.tableScrollOffsets[found.range.location] ?? 0
            check(offset > 0, "editing a cell off the page scrolls the table to it")
            textView.scrollTable(at: found.range.location, by: 60)
            check((textView.tableScrollOffsets[found.range.location] ?? 0) < offset, "scrolling moves the table sideways")
            check(textView.table(at: found.range.location)?.block === before, "scrolling a table never rebuilds it")
            await snap("08b-wide-table")
            textView.endCellEditing()
        }
    }

    /// An empty heading typed below other text shows its placeholder on its own line.
    private static func headingPlaceholder(_ state: AppState) async {
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView as? EditorTextView, let window = textView.window,
              let layoutManager = textView.layoutManager else { return }
        textView.string = ""
        textView.insertText("# Notes\n\n- [x] Pick a theme in Settings\n", replacementRange: NSRange(location: 0, length: 0))
        window.makeFirstResponder(textView)
        textView.insertText("#", replacementRange: textView.selectedRange())
        textView.insertText(" ", replacementRange: textView.selectedRange())
        textView.insertText("\n\nFenced code is highlighted.", replacementRange: textView.selectedRange())
        let text = textView.string as NSString
        let heading = text.range(of: "\n# \n").location + 1
        textView.setSelectedRange(NSRange(location: heading + 2, length: 0))
        await wait(0.3)
        textView.display()
        let origin = textView.textContainerOrigin
        let headingLine = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: heading), effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
        let task = text.range(of: "Pick a theme").location
        let taskLine = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: task), effectiveRange: nil)
            .offsetBy(dx: origin.x, dy: origin.y)
        let placeholder = textView.placeholderRects.last ?? .zero
        log("INFO heading placeholder \(placeholder), heading line \(headingLine), task line \(taskLine)")
        check(placeholder != .zero && placeholder.minY >= taskLine.maxY - 1 && placeholder.maxY <= headingLine.maxY + 3,
              "an empty heading's placeholder sits on the heading's line")
        if let caret = textView.caretRect() {
            check(caret.minY >= headingLine.minY - 1 && caret.maxY <= headingLine.maxY + 1, "the caret on an empty heading sits on its line")
        }
        await snap("08d-heading-placeholder")
        if let note = state.selectedNote {
            state.library.update(note, text: "# ")
            state.library.discardIfBlank(note)
        }
    }

    /// The way a person edits a table: clicking into cells, with real mouse events.
    private static func tableClicks(_ state: AppState) async {
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView as? EditorTextView, let window = textView.window,
              let layoutManager = textView.layoutManager else { return }
        let source = "# Stack\n\n| Layer | What we use |\n| --- | --- |\n| Runtime | Cloudflare Workers, Durable Objects (SQLite) |\n"
            + "| Agents | `agents` SDK, `@cloudflare/think`, `@cloudflare/computer` |\n| Browser | Browser Run: Chromium, Live View, Kite surf |\n"
            + "| Models | Workers AI, or any provider through AI Gateway |\n\nAfter.\n"
        textView.string = ""
        textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        await wait(0.5)
        let text = { textView.string as NSString }
        guard let found = textView.table(at: text().range(of: "| Layer").location) else { return check(false, "the Stack table is found") }

        // The blank line above keeps its own line; the table's line starts at the table.
        var tableLine = NSRange(), blankLine = NSRange()
        let tableFragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: found.range.location), effectiveRange: &tableLine)
        let blankFragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: found.range.location - 1), effectiveRange: &blankLine)
        check(tableLine.location == found.range.location && blankFragment.maxY <= tableFragment.minY + 0.5 && blankFragment.height > 0,
              "the blank line above a table keeps its own line")

        func click(_ point: NSPoint, count: Int = 1) {
            let location = textView.convert(point, to: nil)
            for number in 1...count {
                let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: 0)!
                let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: number, pressure: 1)!
                NSApp.postEvent(up, atStart: false)
                // As the window would: to the view under the point.
                let target = window.contentView?.superview?.hitTest(location) ?? textView
                target.mouseDown(with: down)
            }
        }
        func cellCenter(_ row: Int, _ column: Int) -> NSPoint {
            guard let current = textView.table(at: found.range.location) else { return .zero }
            let geometry = textView.tableGeometry(current.range, current.block)
            let cell = geometry.layout.contentRect(row: row, column: column)
            return NSPoint(x: geometry.origin.x - geometry.offset + cell.minX + 30, y: geometry.origin.y + cell.midY)
        }

        click(cellCenter(3, 1))
        check(textView.activeCell?.row == 3 && textView.activeCell?.column == 1 && window.firstResponder === textView.cellEditor
              && textView.cellEditor.string.hasPrefix("Browser Run"), "clicking a cell edits it")
        let caret = textView.cellEditor.selectedRange()
        check(caret.length == 0 && caret.location > 0 && caret.location < 12, "the caret lands where the cell was clicked")
        textView.cellEditor.insertText("X", replacementRange: textView.cellEditor.selectedRange())
        check(text().range(of: "| Browser | Br").location != NSNotFound && text().range(of: "X").location != NSNotFound, "typing after a click edits that cell")
        textView.cellEditor.deleteBackward(nil)

        click(cellCenter(4, 0))
        check(textView.activeCell?.row == 4 && textView.activeCell?.column == 0 && textView.cellEditor.string == "Models", "clicking another cell moves there")
        click(cellCenter(2, 1), count: 2)
        check(textView.activeCell?.row == 2 && textView.cellEditor.selectedRange().length > 0, "double-clicking a cell selects a word in it")

        let after = text().range(of: "After.")
        let afterGlyph = layoutManager.glyphIndexForCharacter(at: after.location + 2)
        let afterRect = layoutManager.boundingRect(forGlyphRange: NSRange(location: afterGlyph, length: 1), in: textView.textContainer!)
        click(NSPoint(x: afterRect.midX + textView.textContainerOrigin.x, y: afterRect.midY + textView.textContainerOrigin.y))
        check(textView.activeCell == nil && window.firstResponder === textView
              && abs(textView.selectedRange().location - (after.location + 2)) <= 1, "clicking text after a table leaves the table")

        // Beside the table (it's narrower than the page) isn't in it.
        click(cellCenter(2, 0))
        if let current = textView.table(at: found.range.location) {
            let grid = textView.tableGeometry(current.range, current.block).gridFrame
            if grid.maxX + 40 < textView.textContainerOrigin.x + textView.gutter + textView.tableColumnWidth {
                click(NSPoint(x: grid.maxX + 30, y: grid.minY + grid.height * 0.75))
                check(textView.activeCell == nil && window.firstResponder === textView, "clicking beside a table leaves it")
            }
        }
        // A click outside the note's text (here, the window's title area) ends cell editing too.
        click(cellCenter(1, 0))
        let outside = NSPoint(x: window.frame.width / 2, y: window.frame.height - 12)
        let outsideUp = NSEvent.mouseEvent(with: .leftMouseUp, location: outside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let outsideDown = NSEvent.mouseEvent(with: .leftMouseDown, location: outside, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(outsideUp, atStart: false)
        NSApp.sendEvent(outsideDown)
        await wait(0.3)
        check(textView.activeCell == nil, "clicking outside the note ends cell editing")

        // Selecting from the title down through the table and copying gives its Markdown.
        textView.setSelectedRange(NSRange(location: 0, length: NSMaxRange(found.range)))
        check(textView.activeCell == nil, "selecting across a table doesn't open a cell")
        textView.setSelectedRange(NSRange(location: after.location, length: 0))
        check(text().range(of: "| Layer | What we use |\n| --- | --- |\n| Runtime |").location != NSNotFound, "the table's Markdown is intact after editing")
        await snap("08c-table-clicks")
    }

    /// Long code blocks scroll in place instead of taking over the note.
    private static func codeBlocks(_ state: AppState) async {
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView as? EditorTextView, let window = textView.window,
              let layoutManager = textView.layoutManager, let page = textView.enclosingScrollView else { return }
        let code = (1...40).map { "let value\($0) = compute(\($0))" }.joined(separator: "\n")
        let filler = (1...60).map { "Paragraph \($0) after the code." }.joined(separator: "\n\n")
        let source = "# Code\n\nIntro.\n\n```swift\n\(code)\n```\n\nAfter.\n\n" + filler + "\n"
        textView.string = ""
        textView.insertText(source, replacementRange: NSRange(location: 0, length: 0))
        window.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        page.contentView.scroll(to: NSPoint(x: 0, y: -page.contentInsets.top))
        page.reflectScrolledClipView(page.contentView)
        await wait(0.5)
        textView.syncCodeViews()
        let text = { textView.string as NSString }
        guard let view = textView.codeViews.values.first, let block = textView.codeViewport(at: text().range(of: "let value1 ").location) else {
            return check(false, "a long code block gets a scrolling view")
        }
        check(view.code.string == code, "the code view holds the block's code")
        let pitch = block.viewport.lineHeight
        check(abs(view.frame.height - 15 * pitch) < 1, "a long code block shows 15 lines")
        let after = text().range(of: "After.").location
        let afterLine = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: after), effectiveRange: nil)
        check(afterLine.minY + textView.textContainerOrigin.y >= view.frame.maxY, "text after a scrolling block sits below it")

        func wheel(_ dy: Int32) -> NSEvent {
            let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: dy / 24, wheel2: 0, wheel3: 0)!
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            let screen = window.convertPoint(toScreen: center)
            event.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            return NSEvent(cgEvent: event)!
        }
        let pageTop = page.contentView.bounds.minY
        // A mouse wheel scrolls with a short animation; let it land.
        view.scrollWheel(with: wheel(-120))
        await wait(0.5)
        check(view.contentView.bounds.minY > 0 && abs(page.contentView.bounds.minY - pageTop) < 0.5, "scrolling over a long block scrolls its code, not the page")
        let bottom = (view.documentView?.frame.height ?? 0) - view.contentView.bounds.height
        view.contentView.scroll(to: NSPoint(x: 0, y: bottom))
        view.reflectScrolledClipView(view.contentView)
        view.scrollWheel(with: wheel(-120))
        await wait(0.5)
        check(page.contentView.bounds.minY > pageTop + 1, "at the end of its code, scrolling moves the page")
        page.contentView.scroll(to: NSPoint(x: 0, y: pageTop))
        page.reflectScrolledClipView(page.contentView)
        await wait(0.5)
        view.contentView.scroll(to: .zero)
        view.reflectScrolledClipView(view.contentView)
        await wait(0.3)

        // Click into the third line and type.
        let point = NSPoint(x: view.frame.minX + block.viewport.numberWidth + 60, y: view.frame.minY + pitch * 2.5)
        let location = textView.convert(point, to: nil)
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        NSApp.postEvent(up, atStart: false)
        // As the window does: hit-testing from the frame view, in window coordinates.
        let hit = window.contentView?.superview?.hitTest(location)
        (hit ?? textView).mouseDown(with: down)
        check(window.firstResponder === view.code, "clicking a long block's code edits it in place")
        let line3 = (code as NSString).range(of: "let value3 ")
        let caret = view.code.selectedRange().location
        check(caret >= line3.location && caret <= line3.location + 30, "the caret lands on the clicked line")
        view.code.insertText("X", replacementRange: view.code.selectedRange())
        let typed = text().range(of: "X")
        let typedLine = typed.location == NSNotFound ? "" : text().substring(with: text().lineRange(for: typed))
        check(typedLine.contains("3 = compute(3)"), "typing in a code view edits the note's Markdown")
        check(abs(view.frame.height - 15 * pitch) < 1 && textView.codeViews.values.first === view, "the block keeps its height and view while typing")
        view.code.insertTab(nil)
        check(view.code.string.contains("X    "), "Tab in code inserts spaces")
        check(textView.undoManager?.canUndo == true, "code edits are on the note's undo stack")

        // Out and back in by keyboard.
        view.code.setSelectedRange(NSRange(location: (view.code.string as NSString).length, length: 0))
        view.code.moveDown(nil)
        let close = text().range(of: "```\n\nAfter.").location
        check(window.firstResponder === textView && textView.selectedRange().location == close, "arrowing down out of the code lands on the closing fence")
        textView.moveUp(nil)
        check(window.firstResponder === textView.codeViews.values.first?.code, "arrowing up from the closing fence goes back into the code")
        textView.codeViews.values.first?.code.cancelOperation(nil)

        // The drag handle sets the viewport's height.
        let fence = text().range(of: "```swift").location
        textView.setCodeLines(8, fenceAt: fence)
        await wait(0.3)
        textView.syncCodeViews()
        check(abs((textView.codeViews.values.first?.frame.height ?? 0) - 8 * pitch) < 1, "resizing sets how many lines the viewport shows")
        await snap("08e-code-viewport")

        // Shorter than its height, a block is plain text again.
        let body = NSRange(location: text().range(of: "let value1 ").location, length: 0)
        let end = text().range(of: "\n```\n", range: NSRange(location: body.location, length: text().length - body.location)).location
        textView.replace(NSRange(location: body.location, length: end - body.location), with: "let a = 1\nlet b = 2", select: NSRange(location: body.location, length: 0))
        await wait(0.3)
        textView.syncCodeViews()
        check(textView.codeViews.isEmpty && textView.codeViewport(at: body.location) == nil, "a block shorter than its height is plain text again")
    }

    /// Scrolling and typing around big tables.
    private static func tablePerformance(_ state: AppState) async {
        var big = "# Table performance\n\n"
        for t in 0..<6 {
            big += "Some text before table \(t).\n\n| Key | Value | Notes |\n| --- | --- | --- |\n"
            for r in 0..<120 {
                big += "| `key\(r)` | **value** \(r) with a [link](https://example.com/\(r)) | Some longer note text that wraps across a few lines when the column is narrow, row \(r) |\n"
            }
            big += "\n"
        }
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView as? EditorTextView, let scrollView = textView.enclosingScrollView else { return }
        textView.string = ""
        var start = Date()
        textView.insertText(big, replacementRange: NSRange(location: 0, length: 0))
        textView.displayIfNeeded()
        log("INFO open a note with 6 tables of 120 rows: \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000)) ms")
        await wait(0.5)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            start = Date()
            layoutManager.ensureLayout(for: container)
            log("INFO   lay the whole note out: \(String(format: "%.1f", Date().timeIntervalSince(start) * 1000)) ms")
        }

        // Vertical scroll, a frame at a time, through the whole note.
        start = Date()
        var frames = 0
        var worst = 0.0
        var y: CGFloat = 0
        // The view grows as layout reaches further down.
        while y < textView.frame.height {
            let frameStart = Date()
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            scrollView.displayIfNeeded()
            worst = max(worst, Date().timeIntervalSince(frameStart) * 1000)
            frames += 1
            y += 40
        }
        let perFrame = Date().timeIntervalSince(start) / Double(frames) * 1000
        log("INFO scroll \(Int(textView.frame.height)) pt of tables: \(String(format: "%.2f", perFrame)) ms a frame, worst \(String(format: "%.1f", worst)) ms")
        check(perFrame < 8, "scrolling through big tables stays under 8 ms a frame")

        // Typing in a cell of a big table.
        let text = textView.string as NSString
        let target = text.range(of: "row 60 |")
        guard let found = textView.table(at: target.location) else { return }
        let cell = found.block.cell(at: target.location - found.range.location)
        textView.beginCellEditing(tableAt: found.range.location, row: cell.row, column: cell.column, caret: .end)
        textView.reveal(NSRange(location: target.location, length: 0))
        textView.cellEditor.window?.makeFirstResponder(textView.cellEditor)
        start = Date()
        let keys = 50
        for _ in 0..<keys {
            textView.cellEditor.insertText("a", replacementRange: textView.cellEditor.selectedRange())
            scrollView.displayIfNeeded()
        }
        let perKey = Date().timeIntervalSince(start) / Double(keys) * 1000
        log("INFO typing in a 120-row table: \(String(format: "%.2f", perKey)) ms per keystroke")
        check(perKey < 8, "typing in a big table stays under 8 ms a keystroke")
        textView.endCellEditing()
        await snap("09a-big-tables")
        if let note = state.selectedNote {
            state.library.update(note, text: "# ")
            state.library.discardIfBlank(note)
            state.selection = state.library.notes.first?.id
        }
    }

    /// Typing into a long note: the cost of one keystroke, restyle included.
    private static func performance(_ state: AppState) async {
        var big = "# Performance\n\n"
        for i in 0..<400 {
            big += "## Section \(i)\n\nSome **bold** and _italic_ text with `code` and a [link](https://example.com). Line \(i).\n\n- [ ] task \(i)\n- item\n\n"
            if i % 10 == 0 { big += "```swift\nlet value\(i) = [1, 2, 3].map { $0 * 2 }\nprint(value\(i))\n```\n\n" }
        }
        state.newNote(useSelection: false)
        await wait(0.5)
        guard let textView = state.editor.textView else { return }
        textView.string = ""
        textView.insertText(big, replacementRange: NSRange(location: 0, length: 0))
        await wait(1.5)
        let middle = (textView.string as NSString).length / 2
        textView.setSelectedRange(NSRange(location: middle, length: 0))
        let start = Date()
        for _ in 0..<100 {
            textView.insertText("a", replacementRange: textView.selectedRange())
            textView.displayIfNeeded()
        }
        let perKey = Date().timeIntervalSince(start) / 100 * 1000
        log("INFO typing in a \((textView.string as NSString).length / 1024) KB note: \(String(format: "%.2f", perKey)) ms per keystroke")
        check(perKey < 8, "typing in a long note stays under 8 ms a keystroke")
        let text = textView.string
        func measure(_ name: String, _ body: () -> Void) {
            let start = Date()
            for _ in 0..<50 { body() }
            log("INFO   \(name): \(String(format: "%.2f", Date().timeIntervalSince(start) / 50 * 1000)) ms")
        }
        measure("stats") { _ = NoteStats(text) }
        measure("outline") { _ = NoteOutline.headings(in: text) }
        if let storage = textView.textStorage {
            let styler = MarkdownStyler(style: EditorStyle(theme: .paper, isDark: true, noteFont: FontChoice.system, noteFontSize: 15,
                                                           lineSpacing: .comfortable, codeFont: FontChoice.mono, readableWidth: .medium, spellCheck: true))
            styler.restyle(storage, edited: nil)
            measure("restyle one line") { storage.beginEditing(); styler.restyle(storage, edited: NSRange(location: middle, length: 1)); storage.endEditing() }
            measure("restyle all") { storage.beginEditing(); styler.restyle(storage, edited: nil); storage.endEditing() }
            measure("load note") { textView.string = text; textView.displayIfNeeded() }
        }
        await snap("09-long-note")
        if let note = state.selectedNote {
            state.library.update(note, text: "# ")
            state.library.discardIfBlank(note)
            state.selection = state.library.notes.first?.id
        }
    }
}
#endif
