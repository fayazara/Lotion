//
//  TaskIndex.swift
//  Lotion
//
//  Every task in the library, read from the notes Lotion already holds.
//  Nothing is stored apart from the Markdown: the index is rebuilt from the
//  notes' text as it changes, and every change to a task is a change to its
//  line in its note, saved like any other edit.
//

import Foundation

extension Notification.Name {
    /// Posted after a task changed outside the editor, or a note was saved,
    /// so views that list tasks from other notes look again.
    static let lotionTasksDidChange = Notification.Name("LotionTasksDidChange")
}

/// Which tasks to list, as written in a `[tasks …]` block or asked by an agent.
nonisolated struct TaskQuery: Equatable {
    enum When: String, CaseIterable {
        /// Overdue and due today.
        case today
        case overdue
        /// Due in the next seven days, today and overdue included.
        case week
        /// Due after today.
        case upcoming
        /// With any date.
        case dated
        /// Without a date.
        case undated
        case any
    }

    var tags: [String] = []
    /// A folder's name; "" for notes outside any folder.
    var folder: String?
    /// Only tasks in the note the block is in.
    var here = false
    var when: When = .any
    var includeDone = false
    /// Only tasks this important or more (1 is the highest).
    var priority: Int?
    var text: String?

    /// Reads `#tag folder:Work due:week !2 done here`. Words it doesn't know are searched for.
    init(_ source: String = "") {
        var words: [String] = []
        var rest = source[...]
        // Quoted values keep their spaces: folder:"Side projects".
        while let first = rest.first {
            if first == " " { rest = rest.dropFirst(); continue }
            var word = ""
            var quoted = false
            while let c = rest.first, quoted || c != " " {
                rest = rest.dropFirst()
                if c == "\"" { quoted.toggle(); continue }
                word.append(c)
            }
            words.append(word)
        }
        var search: [String] = []
        for word in words {
            let lower = word.lowercased()
            if let tag = TaskSyntax.tag(word) {
                tags.append(tag)
            } else if lower.hasPrefix("folder:") {
                folder = String(word.dropFirst(7))
            } else if lower.hasPrefix("due:"), let when = When(rawValue: String(lower.dropFirst(4))) {
                self.when = when
            } else if let when = When(rawValue: lower), when != .any {
                self.when = when
            } else if lower == "done" || lower == "all" {
                includeDone = true
            } else if lower == "here" || lower == "this" {
                here = true
            } else if lower.count == 2, lower.hasPrefix("!"), let level = Int(lower.dropFirst()), (1...3).contains(level) {
                priority = level
            } else if !word.isEmpty {
                search.append(word)
            }
        }
        if !search.isEmpty { text = search.joined(separator: " ") }
    }

    /// The query written back, as it reads in the block.
    var source: String {
        var parts: [String] = tags.map { "#\($0)" }
        if let folder { parts.append(folder.contains(" ") ? "folder:\"\(folder)\"" : "folder:\(folder)") }
        if here { parts.append("here") }
        if when != .any { parts.append("due:\(when.rawValue)") }
        if let priority { parts.append("!\(priority)") }
        if includeDone { parts.append("done") }
        if let text { parts.append(text) }
        return parts.joined(separator: " ")
    }

    /// What the query shows, in words, for a block's header.
    var summary: String {
        var parts: [String] = []
        switch when {
        case .today: parts.append("Due today")
        case .overdue: parts.append("Overdue")
        case .week: parts.append("Due this week")
        case .upcoming: parts.append("Upcoming")
        case .dated: parts.append("With a date")
        case .undated: parts.append("No date")
        case .any: break
        }
        if here { parts.append("in this note") } else if let folder { parts.append(folder.isEmpty ? "in Notes" : "in \(folder)") }
        if !tags.isEmpty { parts.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        if let priority { parts.append(priority == 1 ? "priority 1" : "priority 1–\(priority)") }
        if let text { parts.append("“\(text)”") }
        return parts.isEmpty ? "All open tasks" : parts.joined(separator: " · ")
    }
}

@MainActor
final class TaskIndex {
    unowned let library: Library
    private var cache: [UUID: (text: String, tasks: [TaskItem])] = [:]

    init(library: Library) {
        self.library = library
    }

    // MARK: Reading

    /// The note's tasks. Reading a note's text here lets a SwiftUI view that
    /// lists them follow its changes.
    func tasks(in note: Note) -> [TaskItem] {
        let text = note.text
        if let cached = cache[note.id], cached.text == text { return cached.tasks }
        let tasks = TaskSyntax.tasks(in: text, noteID: note.id, written: note.modified)
        cache[note.id] = (text, tasks)
        return tasks
    }

    private var notes: [Note] { library.notes + (library.scratchpad.map { [$0] } ?? []) }

    var all: [TaskItem] { notes.flatMap(tasks(in:)) }

    func task(id: String) -> TaskItem? {
        let parts = id.split(separator: "#", maxSplits: 1)
        guard parts.count == 2, let noteID = UUID(uuidString: String(parts[0])), let line = Int(parts[1]),
              let note = library.note(id: noteID) else { return nil }
        return tasks(in: note).first { $0.line == line }
    }

    func note(of task: TaskItem) -> Note? { library.note(id: task.noteID) }

    /// The tasks a query asks for: open before done, then by date, time and priority.
    func run(_ query: TaskQuery, here: Note? = nil, now: Date = .now) -> [TaskItem] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today
        let weekEnd = calendar.date(byAdding: .day, value: 7, to: today) ?? today
        var source: [Note] = notes
        if query.here { source = here.map { [$0] } ?? [] }
        if let folder = query.folder {
            source = source.filter { ($0.folder ?? "").caseInsensitiveCompare(folder) == .orderedSame && !$0.isScratchpad }
        }
        let text = query.text?.lowercased()
        let tags = query.tags.map { $0.lowercased() }
        let list = source.flatMap(tasks(in:)).filter { task in
            if !query.includeDone && task.checked { return false }
            if !tags.isEmpty, !tags.allSatisfy({ tag in task.tags.contains { $0.lowercased() == tag } }) { return false }
            if let priority = query.priority, (task.priority ?? 4) > priority { return false }
            if let text, !task.title.lowercased().contains(text) { return false }
            switch query.when {
            case .any: return true
            case .dated: return task.due != nil
            case .undated: return task.due == nil
            case .overdue: return task.due.map { $0 < today } ?? false
            case .today: return task.due.map { $0 < tomorrow } ?? false
            case .week: return task.due.map { $0 < weekEnd } ?? false
            case .upcoming: return task.due.map { $0 >= tomorrow } ?? false
            }
        }
        return sorted(list)
    }

    func sorted(_ list: [TaskItem]) -> [TaskItem] {
        list.sorted { a, b in
            if a.checked != b.checked { return !a.checked }
            switch (a.due, b.due) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            switch (a.minutes, b.minutes) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: break
            }
            if (a.priority ?? 4) != (b.priority ?? 4) { return (a.priority ?? 4) < (b.priority ?? 4) }
            if a.noteID != b.noteID { return a.noteID.uuidString < b.noteID.uuidString }
            return a.line < b.line
        }
    }

    /// Open tasks due before today, today's, and today's that are done.
    func today(now: Date = .now) -> (overdue: [TaskItem], today: [TaskItem], done: [TaskItem]) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let all = self.all.filter { $0.due != nil }
        let overdue = sorted(all.filter { !$0.checked && $0.due! < start })
        let today = sorted(all.filter { !$0.checked && calendar.isDate($0.due!, inSameDayAs: start) })
        let done = sorted(all.filter { $0.checked && calendar.isDate($0.due!, inSameDayAs: start) })
        return (overdue, today, done)
    }

    /// How many tasks need doing today, for the sidebar.
    var todayCount: Int {
        let t = today()
        return t.overdue.count + t.today.count
    }

    // MARK: The inbox

    static let inboxTitle = "Inbox"

    /// The note quick add writes to: a note titled “Inbox” outside any folder.
    func inbox(create: Bool) -> Note? {
        if let note = library.notes.first(where: { $0.folder == nil && $0.title.caseInsensitiveCompare(Self.inboxTitle) == .orderedSame }) {
            return note
        }
        guard create, let note = library.createNote(in: nil) else { return nil }
        library.updateFromOtherEditor(note, text: "# \(Self.inboxTitle)\n\nTasks you add with Quick Add land here. Give them a date to see them in Today.\n")
        library.save(note)
        return note
    }

    /// Open tasks in the inbox, and undated ones in the scratchpad.
    func inboxTasks() -> [TaskItem] {
        var list = inbox(create: false).map { tasks(in: $0).filter { !$0.checked } } ?? []
        if let scratchpad = library.scratchpad {
            list += tasks(in: scratchpad).filter { !$0.checked && $0.due == nil }
        }
        return sorted(list)
    }

    // MARK: Changing

    /// Replaces the task's line with `lines`. False when the line can't be
    /// found any more (the note changed since the task was read).
    @discardableResult
    func change(_ task: TaskItem, _ transform: (String) -> [String]) -> Bool {
        guard let note = note(of: task) else { return false }
        var lines = note.text.components(separatedBy: "\n")
        let index: Int
        if lines.indices.contains(task.line), lines[task.line] == task.raw {
            index = task.line
        } else if let found = lines.firstIndex(of: task.raw) {
            index = found
        } else {
            return false
        }
        lines.replaceSubrange(index...index, with: transform(lines[index]))
        commit(note, text: lines.joined(separator: "\n"))
        return true
    }

    private func commit(_ note: Note, text: String) {
        library.updateFromOtherEditor(note, text: text)
        library.save(note)
        NotificationCenter.default.post(name: .lotionTasksDidChange, object: nil)
    }

    @discardableResult
    func setChecked(_ task: TaskItem, _ checked: Bool) -> Bool {
        change(task) { raw in TaskSyntax.toggled(raw, checked: checked) }
    }

    /// Changes the task's metadata, keeping its words where they are.
    @discardableResult
    func edit(_ task: TaskItem, _ change: @escaping (inout TaskSyntax.Metadata) -> Void) -> Bool {
        let written = note(of: task)?.modified ?? .now
        return self.change(task) { raw in
            let content = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            guard let line = TaskSyntax.line(content) else { return [raw] }
            let body = TaskSyntax.rewrite(body: line.body, relativeTo: written, change: change)
            // Everything up to and including the checkbox's "]".
            let head = (content as NSString).substring(to: NSMaxRange(line.boxRange) + 1)
            return [body.isEmpty ? head : head + " " + body]
        }
    }

    @discardableResult
    func setDue(_ task: TaskItem, _ day: Date?, minutes: Int? = nil) -> Bool {
        edit(task) {
            $0.due = day.map { Calendar.current.startOfDay(for: $0) }
            $0.minutes = day == nil ? nil : minutes
        }
    }

    /// Moves the task to a day, keeping its time.
    @discardableResult
    func move(_ task: TaskItem, to day: Date?) -> Bool {
        setDue(task, day, minutes: task.minutes)
    }

    @discardableResult
    func setPriority(_ task: TaskItem, _ priority: Int?) -> Bool {
        edit(task) { $0.priority = priority }
    }

    /// Adds a task line to a note: after the last task in it, or at its end.
    /// Returns the task as the index reads it back.
    @discardableResult
    func add(_ line: String, to note: Note) -> TaskItem? {
        var lines = note.text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        let lastIsTask = lines.last.map { TaskSyntax.line($0) != nil } ?? false
        if !lastIsTask, !(lines.last ?? "").isEmpty { lines.append("") }
        if lines.count == 1, lines[0].isEmpty { lines = [] }
        lines.append(line)
        let index = lines.count - 1
        commit(note, text: lines.joined(separator: "\n") + "\n")
        return tasks(in: note).first { $0.line == index }
    }

    /// Adds a task typed in plain words to the inbox, or to `note`.
    @discardableResult
    func add(_ draft: TaskDraft, to note: Note? = nil) -> TaskItem? {
        guard !draft.isEmpty, let target = note ?? inbox(create: true) else { return nil }
        return add(draft.line, to: target)
    }
}
