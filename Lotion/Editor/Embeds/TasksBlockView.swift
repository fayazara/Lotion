//
//  TasksBlockView.swift
//  Lotion
//
//  `[tasks #work due:week]` on a line of its own: a live list of the tasks
//  in the library that match, drawn in the note. Ticking one here ticks it
//  in its own note. Other Markdown apps show the line as written.
//

import AppKit

final class TasksBlockView: HoverBlockView {
    private var tasks: [TaskItem] = []
    private var total = 0
    private static let header: CGFloat = 42
    private static let rowHeight: CGFloat = 32
    private static let maxRows = 12
    private static let radius: CGFloat = 12

    private var query: TaskQuery { TaskQuery(block.imageSource) }

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        NotificationCenter.default.addObserver(self, selector: #selector(tasksDidChange), name: .lotionTasksDidChange, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tasksDidChange() { refresh() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { refresh() }
    }

    override func update(_ block: Block) {
        super.update(block)
        refresh()
    }

    /// Runs the query again; called on every edit and whenever a task changes.
    func refresh() {
        guard let editor else { return }
        let all = editor.taskQuery?(block.imageSource) ?? []
        let shown = Array(all.prefix(Self.maxRows))
        let changed = shown.map(\.raw) != tasks.map(\.raw) || shown.map(\.id) != tasks.map(\.id) || all.count != total
        tasks = shown
        total = all.count
        if changed {
            invalidateHeight()
            editor.blockHeightMayHaveChanged(block.id)
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    private var hasMore: Bool { total > tasks.count }

    override func measure(width: CGFloat) -> CGFloat {
        Self.header + CGFloat(max(1, tasks.count) + (hasMore ? 1 : 0)) * Self.rowHeight + 10
    }

    private func rowRect(_ index: Int) -> NSRect {
        let rect = contentRect
        return NSRect(x: rect.minX + 6, y: Self.header + CGFloat(index) * Self.rowHeight, width: rect.width - 12, height: Self.rowHeight)
    }

    private func boxRect(_ index: Int) -> NSRect {
        let row = rowRect(index)
        return NSRect(x: row.minX + 10, y: row.midY - 8, width: 16, height: 16)
    }

    private var filterRect: NSRect {
        let rect = contentRect
        return NSRect(x: rect.maxX - 76, y: 8, width: 68, height: 26)
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))?.tinted(color)
    }

    private static func priorityColor(_ level: Int?) -> NSColor? {
        switch level {
        case 1: .systemRed
        case 2: .systemOrange
        case 3: .systemBlue
        default: nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = contentRect
        let card = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        let fill = palette.isDark ? palette.codeBackground : palette.background.blended(withFraction: 0.5, of: .white) ?? palette.background
        fill.setFill()
        card.fill()
        palette.text.withAlphaComponent(palette.isDark ? 0.12 : 0.1).setStroke()
        card.lineWidth = 1
        card.stroke()

        let headerMid: CGFloat = 21
        CardRow.icon(symbol("checklist", size: 12, color: palette.accent, weight: .medium), centerX: rect.minX + 24, centerY: headerMid)
        let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        CardRow.text("Tasks", font: titleFont, color: palette.text, x: rect.minX + 38, centerY: headerMid)
        let titleEnd = rect.minX + 38 + CardRow.width("Tasks", font: titleFont)
        CardRow.text(query.summary + (total > 0 ? " · \(total)" : ""), font: .systemFont(ofSize: 12), color: palette.secondary,
                     x: titleEnd + 8, centerY: headerMid, maxWidth: filterRect.minX - titleEnd - 16)
        let filterHovered = hoverPoint.map { filterRect.contains($0) } ?? false
        let filterColor = filterHovered ? palette.accent : palette.secondary
        CardRow.icon(symbol("line.3.horizontal.decrease", size: 10, color: filterColor, weight: .medium), centerX: filterRect.minX + 12, centerY: headerMid)
        CardRow.text("Filter", font: .systemFont(ofSize: 12, weight: .medium), color: filterColor, x: filterRect.minX + 22, centerY: headerMid)

        palette.text.withAlphaComponent(palette.isDark ? 0.1 : 0.07).setFill()
        NSRect(x: rect.minX + 1, y: Self.header - 2, width: rect.width - 2, height: 1).fill()

        guard !tasks.isEmpty else {
            let row = rowRect(0)
            let message = editor?.taskQuery == nil ? "Task lists show in the main window." : "No tasks match. Add `@today`, `#tags` or `!1` after a to-do and they gather here."
            CardRow.text(message, font: .systemFont(ofSize: 13), color: palette.marker, x: row.minX + 12, centerY: row.midY, maxWidth: row.width - 24)
            return
        }
        let calendar = Calendar.current
        for (index, task) in tasks.enumerated() {
            let row = rowRect(index)
            let hovered = hoverPoint.map { row.contains($0) } ?? false
            if hovered {
                palette.text.withAlphaComponent(0.05).setFill()
                NSBezierPath(roundedRect: row, xRadius: 7, yRadius: 7).fill()
            }
            // The checkbox: a ring in the priority's color, filled once done.
            let box = boxRect(index)
            let tint = Self.priorityColor(task.priority) ?? palette.secondary.withAlphaComponent(0.8)
            let ring = NSBezierPath(ovalIn: box.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = task.priority == nil ? 1.2 : 1.6
            if task.checked {
                tint.setFill()
                ring.fill()
                CardRow.icon(symbol("checkmark", size: 8, color: palette.background, weight: .bold), centerX: box.midX, centerY: box.midY)
            } else {
                if task.priority != nil {
                    tint.withAlphaComponent(0.12).setFill()
                    ring.fill()
                }
                tint.setStroke()
                ring.stroke()
                if hovered, (hoverPoint.map { box.insetBy(dx: -4, dy: -4).contains($0) } ?? false) {
                    CardRow.icon(symbol("checkmark", size: 8, color: tint, weight: .bold), centerX: box.midX, centerY: box.midY)
                }
            }

            // Right side: the date, then the note it's in.
            var right = row.maxX - 12
            let metaFont = NSFont.systemFont(ofSize: 11.5)
            if !query.here, let title = editor?.taskNoteTitle?(task) {
                let width = min(160, CardRow.width(title, font: metaFont))
                CardRow.text(title, font: metaFont, color: palette.secondary.withAlphaComponent(0.85), x: right - width, centerY: row.midY, maxWidth: width)
                right -= width + 12
            }
            if let due = task.due {
                let label = TaskDates.label(due: due, minutes: task.minutes)
                let color: NSColor = task.checked ? palette.secondary
                    : task.isOverdue() ? .systemRed
                    : calendar.isDateInToday(due) ? .systemGreen
                    : calendar.isDateInTomorrow(due) ? .systemOrange : palette.accent
                let width = CardRow.width(label, font: metaFont)
                CardRow.text(label, font: metaFont, color: color, x: right - width, centerY: row.midY)
                right -= width + 12
            }
            for tag in task.tags.reversed() where right - row.minX > 240 {
                let text = "#" + tag
                let width = CardRow.width(text, font: metaFont)
                CardRow.text(text, font: metaFont, color: palette.accent, x: right - width, centerY: row.midY)
                right -= width + 8
            }
            let x = box.maxX + 10
            let title = task.title.isEmpty ? "Untitled task" : task.title
            let titleColor = task.checked ? palette.secondary : palette.text
            let titleFont = NSFont.systemFont(ofSize: 13.5)
            CardRow.text(title, font: titleFont, color: titleColor, x: x, centerY: row.midY, maxWidth: right - x - 8)
            let end = x + min(right - x - 8, CardRow.width(title, font: titleFont))
            if task.checked {
                titleColor.withAlphaComponent(0.6).setFill()
                NSRect(x: x, y: row.midY, width: end - x, height: 1).fill()
            }
        }
        if hasMore {
            let row = rowRect(tasks.count)
            CardRow.text("and \(total - tasks.count) more", font: .systemFont(ofSize: 12), color: palette.secondary,
                         x: boxRect(tasks.count).maxX + 10, centerY: row.midY)
        }
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        guard let editor else { return false }
        if event.modifierFlags.intersection([.shift, .command]).isEmpty {
            if filterRect.contains(point) {
                editFilter()
                return true
            }
            if let index = tasks.indices.first(where: { boxRect($0).insetBy(dx: -6, dy: -6).contains(point) }) {
                editor.taskToggle?(tasks[index])
                return true
            }
            if let index = tasks.indices.first(where: { rowRect($0).contains(point) }) {
                editor.openTask?(tasks[index])
                return true
            }
        }
        editor.selectBlocks([block.id])
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(filterRect, cursor: .pointingHand)
        for index in tasks.indices { addCursorRect(rowRect(index), cursor: .pointingHand) }
    }

    /// Asks for the filter, as it's written in the note.
    func editFilter() {
        guard let editor, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Which tasks?"
        alert.informativeText = "Words to match, #tags, a priority (!1), when they're due (due:today, due:week, due:overdue, due:upcoming, due:undated), folder:Name, here (this note only) and done (finished ones too)."
        let field = NSTextField(string: block.imageSource)
        field.placeholderString = "#work due:week"
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Show")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self, weak editor] response in
            guard response == .alertFirstButtonReturn, let self, let editor, let index = editor.index(of: self.block.id) else { return }
            let source = TaskQuery(field.stringValue).source
            editor.mutate("Filter Tasks", focus: .blocks([self.block.id])) { blocks in
                blocks[index].imageSource = source
                blocks[index].touch()
            }
        }
    }
}

extension BlockEditorView {
    /// Lets `[tasks]` blocks in this editor list, tick and open the library's tasks.
    /// `note` is the note being edited, for `here`.
    func connectTasks(to library: Library, note: @escaping () -> Note?, open: @escaping (TaskItem) -> Void) {
        let index = library.tasks
        taskQuery = { source in index.run(TaskQuery(source), here: note()) }
        taskNoteTitle = { task in
            index.note(of: task).map { $0.isScratchpad ? "Scratchpad" : $0.displayTitle }
        }
        taskToggle = { task in index.setChecked(task, !task.checked) }
        openTask = open
    }
}
