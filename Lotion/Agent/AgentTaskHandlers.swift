//
//  AgentTaskHandlers.swift
//  Lotion
//
//  The task tools. A task is a checklist line in a note, so these read and
//  change notes' lines through the library's task index, the same calls the
//  Today and Upcoming lists make. Changes are saved before the tool returns.
//

import Foundation

extension AgentHandlers {
    func listTasks(_ args: AgentArguments) throws -> [JSONValue] {
        library.refreshFromDisk()
        var query = TaskQuery(args.optionalString("filter") ?? "")
        if let raw = args.optionalString("due") {
            guard let when = TaskQuery.When(rawValue: raw) else {
                throw AgentToolError.message("\"due\" must be one of \(TaskQuery.When.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            query.when = when
        }
        if let tag = args.optionalString("tag") { query.tags.append(tag.hasPrefix("#") ? String(tag.dropFirst()) : tag) }
        if let folder = args.optionalString("folder") { query.folder = folder }
        if args.bool("include_done", default: false) { query.includeDone = true }
        var here: Note?
        if args.has("note") {
            here = try resolveNote(args)
            query.here = true
        }
        let tasks = library.tasks.run(query, here: here)
        let limit = max(1, args.int("limit", default: 100))
        return [AgentTools.json([
            "total": .number(Double(tasks.count)),
            "tasks": .array(tasks.prefix(limit).map(taskJSON)),
        ])]
    }

    func addTask(_ args: AgentArguments) throws -> [JSONValue] {
        library.refreshFromDisk()
        var draft = TaskDraft.parse(try args.string("text"))
        guard !draft.isEmpty else { throw AgentToolError.message("The task needs some words besides its date, tags and priority.") }
        if let due = args.optionalString("due") { (draft.due, draft.minutes) = try day(due, keeping: draft.minutes) }
        if args.has("priority") { draft.priority = try priority(args) }
        let note = args.has("note") ? try resolveNote(args) : library.tasks.inbox(create: true)
        guard let note else { throw AgentToolError.message("The inbox note couldn't be made.") }
        guard let task = library.tasks.add(draft, to: note) else { throw AgentToolError.message("The task couldn't be added.") }
        return [AgentTools.json(taskJSON(task))]
    }

    func updateTask(_ args: AgentArguments) throws -> [JSONValue] {
        library.refreshFromDisk()
        let index = library.tasks
        let id = try args.string("id")
        guard var task = index.task(id: id) else {
            throw AgentToolError.message("No task has the id “\(id)”. Ids change when lines above a task are added or removed; get fresh ones from list_tasks.")
        }
        let noteID = task.noteID
        func reread(_ title: String, near line: Int) throws {
            guard let note = library.note(id: noteID),
                  let found = index.tasks(in: note).filter({ $0.title == title }).min(by: { abs($0.line - line) < abs($1.line - line) })
            else { throw AgentToolError.message("The task changed while it was being edited. Read it again with list_tasks.") }
            task = found
        }
        if args.has("due") || args.has("time") {
            var due = task.due
            var minutes = task.minutes
            if let raw = args.optionalString("due") { (due, minutes) = try day(raw, keeping: minutes) }
            if let raw = args.optionalString("time") {
                if raw.trimmingCharacters(in: .whitespaces).isEmpty {
                    minutes = nil
                } else {
                    guard let parsed = TaskDates.time(raw, bare: true) else { throw AgentToolError.message("\"time\" takes 24-hour HH:MM, like \"14:30\".") }
                    minutes = parsed
                    if due == nil { due = Calendar.current.startOfDay(for: .now) }
                }
            }
            guard index.setDue(task, due, minutes: minutes) else { throw AgentToolError.message("The task's line changed; read it again with list_tasks.") }
            try reread(task.title, near: task.line)
        }
        if args.has("priority") {
            let level = try priority(args)
            guard index.setPriority(task, level) else { throw AgentToolError.message("The task's line changed; read it again with list_tasks.") }
            try reread(task.title, near: task.line)
        }
        if args.has("done") {
            let done = try args.bool("done")
            let wasRecurring = task.recurrence != nil && done && !task.checked
            guard index.setChecked(task, done) else { throw AgentToolError.message("The task's line changed; read it again with list_tasks.") }
            // A repeating task's next one is written above the one checked off.
            try reread(task.title, near: task.line + (wasRecurring ? 1 : 0))
            if wasRecurring, let note = library.note(id: noteID), let next = index.tasks(in: note).first(where: { $0.line == task.line - 1 }) {
                return [AgentTools.json(["done": taskJSON(task), "next": taskJSON(next)])]
            }
        }
        return [AgentTools.json(taskJSON(task))]
    }

    // MARK: Helpers

    /// "2026-11-20", words like "tomorrow" or "next friday 3pm", or "" for no date.
    private func day(_ raw: String, keeping minutes: Int?) throws -> (Date?, Int?) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.lowercased() == "none" { return (nil, nil) }
        let words = TaskSyntax.words(trimmed)
        guard let found = TaskDates.phrase(words, from: .now), found.used == words.count else {
            throw AgentToolError.message("“\(raw)” isn't a date Lotion understands. Use YYYY-MM-DD, or words like \"tomorrow\", \"next friday\", \"nov 20 3pm\".")
        }
        return (found.day ?? Calendar.current.startOfDay(for: .now), found.minutes ?? minutes)
    }

    private func priority(_ args: AgentArguments) throws -> Int? {
        let level = args.int("priority", default: 0)
        guard (0...3).contains(level) else { throw AgentToolError.message("\"priority\" is 1 (highest) to 3, or 0 for none.") }
        return level == 0 ? nil : level
    }

    func taskJSON(_ task: TaskItem) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(task.id),
            "title": .string(task.title),
            "done": .bool(task.checked),
            "markdown": .string(task.raw.trimmingCharacters(in: .whitespaces)),
        ]
        if let due = task.due { item["due"] = .string(TaskDates.isoString(due)) }
        if let minutes = task.minutes { item["time"] = .string(TaskDates.timeString(minutes)) }
        if let priority = task.priority { item["priority"] = .number(Double(priority)) }
        if !task.tags.isEmpty { item["tags"] = .array(task.tags.map { .string($0) }) }
        if let rule = task.recurrence { item["repeats"] = .string(rule.text) }
        if let duration = task.duration { item["minutes"] = .number(Double(duration)) }
        if task.isOverdue() { item["overdue"] = true }
        if let section = task.section { item["section"] = .string(section) }
        if let note = library.tasks.note(of: task) {
            item["note"] = ["id": .string(note.id.uuidString), "title": .string(note.displayTitle), "path": .string(library.relativePath(of: note.url))]
        }
        return .object(item)
    }
}
