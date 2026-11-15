//
//  TaskSyntax.swift
//  Lotion
//
//  A task is a checklist line in any note. What makes it more than a
//  checkbox is a little plain text after it, readable in any Markdown app:
//
//      - [ ] Send Sam the mockups #lotion !1 @2026-11-16 10:00 ~45m @every week
//
//  `@date` (with an optional time) is when it's due, `!1`–`!3` its priority,
//  `#tag` a tag, `~45m` how long it takes, `@every …` how it repeats. Lotion
//  writes these; it also reads the Obsidian Tasks emoji (📅 ⏳ 🔁 ⏫ 🔼 🔽),
//  so a library shared with Obsidian keeps its dates.
//

import Foundation

/// How a task repeats.
nonisolated enum Recurrence: Equatable, Hashable, Sendable {
    enum Unit: String, Sendable { case day, week, month, year }

    case every(Int, Unit)
    /// Monday to Friday.
    case weekdays
    /// One day of the week, as `Calendar` numbers them (1 is Sunday).
    case weekday(Int)

    /// "every week", "every 2 months", "every weekday", "every monday".
    var text: String {
        switch self {
        case .every(1, let unit): "every \(unit.rawValue)"
        case .every(let n, let unit): "every \(n) \(unit.rawValue)s"
        case .weekdays: "every weekday"
        case .weekday(let day): "every \(TaskDates.weekdayNames[day - 1])"
        }
    }

    /// The next due day after `day`.
    func next(after day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        switch self {
        case .every(let n, let unit):
            let component: Calendar.Component = switch unit {
            case .day: .day
            case .week: .weekOfYear
            case .month: .month
            case .year: .year
            }
            return calendar.date(byAdding: component, value: max(1, n), to: start) ?? start
        case .weekdays:
            var next = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            while calendar.isDateInWeekend(next) { next = calendar.date(byAdding: .day, value: 1, to: next) ?? next }
            return next
        case .weekday(let weekday):
            return TaskDates.next(weekday: weekday, after: start, calendar: calendar)
        }
    }

    /// Reads "every week", "every 2 weeks", "daily", "weekly", "every mon".
    static func parse(_ words: [String]) -> (Recurrence, Int)? {
        guard let first = words.first?.lowercased() else { return nil }
        switch first {
        case "daily": return (.every(1, .day), 1)
        case "weekly": return (.every(1, .week), 1)
        case "monthly": return (.every(1, .month), 1)
        case "yearly", "annually": return (.every(1, .year), 1)
        case "weekdays": return (.weekdays, 1)
        case "every": break
        default: return nil
        }
        guard words.count > 1 else { return nil }
        let second = words[1].lowercased()
        if let unit = unit(second) { return (.every(1, unit), 2) }
        if second == "weekday" || second == "weekdays" { return (.weekdays, 2) }
        if let day = TaskDates.weekday(named: second) { return (.weekday(day), 2) }
        if second == "other", words.count > 2, let unit = unit(words[2].lowercased()) { return (.every(2, unit), 3) }
        if let n = Int(second), n > 0, words.count > 2, let unit = unit(words[2].lowercased()) { return (.every(n, unit), 3) }
        return nil
    }

    private static func unit(_ word: String) -> Unit? {
        switch word {
        case "day", "days": .day
        case "week", "weeks": .week
        case "month", "months": .month
        case "year", "years": .year
        default: nil
        }
    }
}

/// One task, as read from its line.
nonisolated struct TaskItem: Identifiable, Hashable, Sendable {
    let noteID: UUID
    /// The line's index in the note, counting from 0.
    let line: Int
    /// The whole line as written, to find it again before changing it.
    let raw: String

    let checked: Bool
    /// The text without its marks or metadata, for lists.
    let title: String
    /// The day it's due, at midnight.
    let due: Date?
    /// Minutes after midnight, when it has a time.
    let minutes: Int?
    /// How long it takes, in minutes, when written.
    let duration: Int?
    /// 1 is the highest.
    let priority: Int?
    let tags: [String]
    let recurrence: Recurrence?
    /// The heading the task sits under, for context.
    let section: String?
    let indent: Int

    var id: String { "\(noteID.uuidString)#\(line)" }

    /// When it starts, for a task with a time.
    var start: Date? {
        guard let due, let minutes else { return nil }
        return due.addingTimeInterval(TimeInterval(minutes * 60))
    }

    func isOverdue(now: Date = .now, calendar: Calendar = .current) -> Bool {
        guard !checked, let due else { return false }
        return due < calendar.startOfDay(for: now)
    }

    static func == (lhs: TaskItem, rhs: TaskItem) -> Bool { lhs.id == rhs.id && lhs.raw == rhs.raw }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(raw)
    }
}

/// Reading and writing task lines.
nonisolated enum TaskSyntax {
    /// `- [ ] `, `* [x] `, `1. [ ] ` and the like, with the indent before it.
    private static let lineRegex = try! NSRegularExpression(pattern: #"^([ \t]*)(?:[-*+]|\d{1,9}[.)])[ \t]+\[([ xX])\](?:[ \t]+(.*))?$"#)

    struct Line {
        let indent: String
        let checked: Bool
        /// Where the checkbox's character is, to flip it.
        let boxRange: NSRange
        /// The text after the checkbox.
        let body: String
        let bodyRange: NSRange
    }

    static func line(_ string: String) -> Line? {
        let ns = string as NSString
        guard let match = lineRegex.firstMatch(in: string, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: match.range(at: 1))
        let box = match.range(at: 2)
        let bodyRange = match.range(at: 3)
        let body = bodyRange.location == NSNotFound ? "" : ns.substring(with: bodyRange)
        return Line(indent: indent, checked: ns.substring(with: box) != " ", boxRange: box,
                    body: body, bodyRange: bodyRange.location == NSNotFound ? NSRange(location: ns.length, length: 0) : bodyRange)
    }

    /// Every task in a note's Markdown. Lines in code fences and quotes are
    /// left out. Relative dates (`@tomorrow`) count from `written`.
    static func tasks(in text: String, noteID: UUID, written: Date = .now) -> [TaskItem] {
        guard text.contains("[") else { return [] }
        var tasks: [TaskItem] = []
        var fence: String?
        var section: String?
        // Lines as `TaskIndex` counts them when it changes one: split on "\n" alone.
        for (index, part) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let raw = String(part)
            let content = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            let trimmed = content.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if trimmed.hasPrefix(open) { fence = nil }
                continue
            }
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                fence = String(trimmed.prefix(3))
                continue
            }
            if trimmed.hasPrefix("#") {
                let heading = trimmed.drop { $0 == "#" }
                if heading.first == " " { section = Self.plain(String(heading)).trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard trimmed.hasPrefix("-") || trimmed.hasPrefix("*") || trimmed.hasPrefix("+") || trimmed.first?.isNumber == true,
                  let line = line(content) else { continue }
            let meta = metadata(in: line.body, relativeTo: written)
            let indentWidth = line.indent.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            tasks.append(TaskItem(
                noteID: noteID, line: index, raw: raw, checked: line.checked, title: meta.title,
                due: meta.due, minutes: meta.minutes, duration: meta.duration, priority: meta.priority,
                tags: meta.tags, recurrence: meta.recurrence, section: index == 0 ? nil : section,
                indent: indentWidth / 2
            ))
        }
        return tasks
    }

    // MARK: Metadata

    struct Metadata {
        var title = ""
        var due: Date?
        var minutes: Int?
        var duration: Int?
        var priority: Int?
        var tags: [String] = []
        var recurrence: Recurrence?
        /// The body's word ranges that are metadata, to strip or replace.
        var tokenRanges: [Range<Int>] = []
    }

    private static let obsidianPriority: [String: Int] = ["🔺": 1, "⏫": 1, "🔼": 2, "🔽": 3, "⏬": 3]
    private static let obsidianSigns: Set<String> = ["📅", "⏳", "🛫", "✅", "➕", "❌", "🔁"]

    /// Words, split on spaces, so metadata can be found and taken out.
    static func words(_ body: String) -> [String] {
        body.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Reads the metadata from a task's text. `title` is what's left.
    static func metadata(in body: String, relativeTo now: Date = .now) -> Metadata {
        var meta = Metadata()
        let words = words(body)
        var keep: [String] = []
        var i = 0
        var calendar = Calendar.current
        calendar.timeZone = .current
        while i < words.count {
            let word = words[i]
            let lower = word.lowercased()
            // Obsidian Tasks: emoji then a value.
            if let level = obsidianPriority[word] {
                meta.priority = level
                meta.tokenRanges.append(i..<i + 1)
                i += 1
                continue
            }
            if obsidianSigns.contains(word) {
                if word == "🔁" {
                    let rest = Array(words[(i + 1)...].prefix(3))
                    if let (rule, used) = Recurrence.parse(rest) {
                        meta.recurrence = rule
                        meta.tokenRanges.append(i..<i + 1 + used)
                        i += 1 + used
                        continue
                    }
                } else if i + 1 < words.count, let day = TaskDates.iso(words[i + 1]) {
                    if word == "📅" || (word == "⏳" && meta.due == nil) || (word == "🛫" && meta.due == nil) { meta.due = day }
                    meta.tokenRanges.append(i..<i + 2)
                    i += 2
                    continue
                }
            }
            if word.hasPrefix("@"), word.count > 1 {
                // `@every week` repeats.
                var phrase = [String(word.dropFirst())] + Array(words[(i + 1)...].prefix(3))
                if let (rule, used) = Recurrence.parse(phrase) {
                    meta.recurrence = rule
                    meta.tokenRanges.append(i..<i + used)
                    i += used
                    continue
                }
                // `@2026-11-16`, `@2026-11-16 14:30`, `@tomorrow`, `@next week`, `@3pm`.
                phrase = [String(word.dropFirst())] + Array(words[(i + 1)...].prefix(3))
                if let found = TaskDates.phrase(phrase, from: now, calendar: calendar) {
                    var used = found.used
                    // A later date replaces an earlier one, time and all.
                    if let day = found.day { meta.due = day; meta.minutes = nil }
                    if let minutes = found.minutes { meta.minutes = minutes }
                    // A time written after the date: `@2026-11-16 14:30`.
                    if found.minutes == nil, i + used < words.count, let minutes = TaskDates.time(words[i + used]) {
                        meta.minutes = minutes
                        used += 1
                    }
                    if found.day == nil, meta.due == nil { meta.due = calendar.startOfDay(for: now) }
                    meta.tokenRanges.append(i..<i + used)
                    i += used
                    continue
                }
            }
            if let level = priority(word) {
                meta.priority = level
                meta.tokenRanges.append(i..<i + 1)
                i += 1
                continue
            }
            if let minutes = duration(word) {
                meta.duration = minutes
                meta.tokenRanges.append(i..<i + 1)
                i += 1
                continue
            }
            if let tag = tag(word) {
                meta.tags.append(tag)
                meta.tokenRanges.append(i..<i + 1)
                i += 1
                continue
            }
            keep.append(word)
            i += 1
        }
        meta.title = plain(keep.joined(separator: " "))
        return meta
    }

    /// `!1`–`!3`, or `#p1`–`#p3` as Todoist writes it: 1 is the highest.
    static func priority(_ word: String) -> Int? {
        let lower = word.lowercased()
        let digit: Substring
        if lower.count == 2, lower.hasPrefix("!") { digit = lower.dropFirst() }
        else if lower.count == 3, lower.hasPrefix("#p") { digit = lower.dropFirst(2) }
        else { return nil }
        guard let level = Int(digit), (1...3).contains(level) else { return nil }
        return level
    }

    /// `#tag`, without trailing punctuation. Not a heading mark or a URL fragment.
    static func tag(_ word: String) -> String? {
        guard word.hasPrefix("#"), word.count > 1 else { return nil }
        let name = word.dropFirst().trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?)"))
        guard let first = name.unicodeScalars.first, CharacterSet.letters.contains(first),
              name.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-_/".unicodeScalars.contains($0) })
        else { return nil }
        return name
    }

    /// `~30m`, `~1h`, `~1h30m`, `~90min`.
    static func duration(_ word: String) -> Int? {
        guard word.hasPrefix("~"), word.count > 2 else { return nil }
        return minutes(in: String(word.dropFirst()).lowercased())
    }

    static func minutes(in value: String) -> Int? {
        let regex = try! NSRegularExpression(pattern: #"^(?:(\d+)h)?(?:(\d+)m(?:in)?)?$"#)
        let ns = value as NSString
        guard let match = regex.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let hours = match.range(at: 1).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 1))) ?? 0
        let minutes = match.range(at: 2).location == NSNotFound ? 0 : Int(ns.substring(with: match.range(at: 2))) ?? 0
        let total = hours * 60 + minutes
        return total > 0 ? total : nil
    }

    /// Text without inline Markdown marks, for showing outside the editor.
    static func plain(_ text: String) -> String {
        var text = text
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[\[([^\]|]*)(\|[^\]]*)?\]\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "").replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespaces)
    }

    // MARK: Writing

    /// The metadata Lotion writes after a task's text.
    static func suffix(tags: [String], priority: Int?, due: Date?, minutes: Int?, recurrence: Recurrence?, duration: Int?) -> String {
        var parts: [String] = tags.map { "#\($0)" }
        if let priority { parts.append("!\(priority)") }
        if let due {
            var token = "@" + TaskDates.isoString(due)
            if let minutes { token += " " + TaskDates.timeString(minutes) }
            parts.append(token)
        }
        if let recurrence { parts.append("@" + recurrence.text) }
        if let duration { parts.append("~" + TaskDates.durationString(duration)) }
        return parts.joined(separator: " ")
    }

    /// A new task line, from text and metadata.
    static func newLine(title: String, tags: [String] = [], priority: Int? = nil, due: Date? = nil, minutes: Int? = nil,
                        recurrence: Recurrence? = nil, duration: Int? = nil, indent: String = "") -> String {
        let rest = suffix(tags: tags, priority: priority, due: due, minutes: minutes, recurrence: recurrence, duration: duration)
        return indent + "- [ ] " + [title.trimmingCharacters(in: .whitespaces), rest].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// The body with some metadata changed. Words that aren't metadata stay
    /// where they are; changed metadata is written where it was, or at the
    /// end when the task didn't have it.
    static func rewrite(body: String, relativeTo now: Date = .now, change: (inout Metadata) -> Void) -> String {
        var meta = metadata(in: body, relativeTo: now)
        let before = meta
        change(&meta)
        let words = words(body)

        enum Kind: CaseIterable { case date, priority, recurrence, duration, tags }
        func kind(of word: String) -> Kind? {
            let lower = word.lowercased()
            if word == "🔁" || lower.hasPrefix("@every") || ["@daily", "@weekly", "@monthly", "@yearly", "@weekdays"].contains(lower) { return .recurrence }
            if isDateWord(word) { return .date }
            if priority(word) != nil || obsidianPriority[word] != nil { return .priority }
            if word.hasPrefix("~") { return .duration }
            if word.hasPrefix("#") { return .tags }
            return nil
        }
        func token(_ kind: Kind) -> String {
            switch kind {
            case .date:
                guard let due = meta.due else { return "" }
                return "@" + TaskDates.isoString(due) + (meta.minutes.map { " " + TaskDates.timeString($0) } ?? "")
            case .priority: return meta.priority.map { "!\($0)" } ?? ""
            case .recurrence: return meta.recurrence.map { "@" + $0.text } ?? ""
            case .duration: return meta.duration.map { "~" + TaskDates.durationString($0) } ?? ""
            case .tags: return meta.tags.map { "#\($0)" }.joined(separator: " ")
            }
        }
        let changed: Set<Kind> = Set(Kind.allCases.filter { kind in
            switch kind {
            case .date: meta.due != before.due || meta.minutes != before.minutes
            case .priority: meta.priority != before.priority
            case .recurrence: meta.recurrence != before.recurrence
            case .duration: meta.duration != before.duration
            case .tags: meta.tags != before.tags
            }
        })
        // Each changed kind's first token takes the new value; any others go.
        var replace: [Int: String] = [:]
        var drop = Set<Int>()
        var placed = Set<Kind>()
        for range in before.tokenRanges {
            guard let kind = kind(of: words[range.lowerBound]), changed.contains(kind) else { continue }
            for index in range { drop.insert(index) }
            if !placed.contains(kind) {
                placed.insert(kind)
                replace[range.lowerBound] = token(kind)
            }
        }
        var out: [String] = []
        for (index, word) in words.enumerated() {
            if let text = replace[index] {
                if !text.isEmpty { out.append(text) }
            } else if !drop.contains(index) {
                out.append(word)
            }
        }
        for kind in Kind.allCases where changed.contains(kind) && !placed.contains(kind) {
            let text = token(kind)
            if !text.isEmpty { out.append(text) }
        }
        return out.joined(separator: " ")
    }

    private static func isDateWord(_ word: String) -> Bool {
        if ["📅", "⏳", "🛫"].contains(word) { return true }
        guard word.hasPrefix("@") else { return false }
        return !word.lowercased().hasPrefix("@every") && !["@daily", "@weekly", "@monthly", "@yearly", "@weekdays"].contains(word.lowercased())
    }

    /// The line with the task checked or not. A recurring task checked off
    /// gets its next one, unchecked, on the line above.
    static func toggled(_ raw: String, checked: Bool, now: Date = .now) -> [String] {
        guard let line = line(raw) else { return [raw] }
        let ns = raw as NSString
        let flipped = ns.replacingCharacters(in: line.boxRange, with: checked ? "x" : " ")
        guard checked, !line.checked else { return [flipped] }
        let meta = metadata(in: line.body, relativeTo: now)
        guard let rule = meta.recurrence else { return [flipped] }
        let from = meta.due ?? Calendar.current.startOfDay(for: now)
        var next = rule.next(after: from)
        // A task left overdue comes back on its next day from today, not in the past.
        while next < Calendar.current.startOfDay(for: now) { next = rule.next(after: next) }
        let body = rewrite(body: line.body, relativeTo: now) { $0.due = next }
        let marker = ns.substring(with: NSRange(location: 0, length: line.boxRange.location - 1))
        let open = marker + "[ ] " + body
        return [open, flipped]
    }
}
