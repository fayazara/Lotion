//
//  TaskDates.swift
//  Lotion
//
//  Dates in plain words: "tomorrow", "next week", "fri 3pm", "nov 20",
//  "in 3 days". Relative words are only ever read; Lotion writes the day
//  they meant (`@2026-11-16`), so a file reads the same next week.
//

import Foundation

nonisolated enum TaskDates {
    static let weekdayNames = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let weekdayAliases: [String: Int] = [
        "sun": 1, "mon": 2, "tue": 3, "tues": 3, "wed": 4, "weds": 4, "thu": 5, "thur": 5, "thurs": 5, "fri": 6, "sat": 7,
    ]
    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]

    /// A weekday number (1 is Sunday) for a name or its short form.
    static func weekday(named word: String) -> Int? {
        let word = word.lowercased()
        if let index = weekdayNames.firstIndex(of: word) { return index + 1 }
        return weekdayAliases[word]
    }

    static func month(named word: String) -> Int? {
        let word = word.lowercased()
        guard word.count >= 3 else { return nil }
        if word == "sept" { return 9 }
        return months.firstIndex { $0 == word || ($0.hasPrefix(word) && word.count == 3) }.map { $0 + 1 }
    }

    /// The first `weekday` strictly after `day`.
    static func next(weekday: Int, after day: Date, calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: day)
        let current = calendar.component(.weekday, from: start)
        var ahead = (weekday - current + 7) % 7
        if ahead == 0 { ahead = 7 }
        return calendar.date(byAdding: .day, value: ahead, to: start) ?? start
    }

    // MARK: Reading

    private static let isoRegex = try! NSRegularExpression(pattern: #"^(\d{4})-(\d{2})-(\d{2})$"#)

    /// `2026-11-16`, as midnight that day.
    static func iso(_ word: String, calendar: Calendar = .current) -> Date? {
        let ns = word as NSString
        guard word.count == 10, let match = isoRegex.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var parts = DateComponents()
        parts.year = Int(ns.substring(with: match.range(at: 1)))
        parts.month = Int(ns.substring(with: match.range(at: 2)))
        parts.day = Int(ns.substring(with: match.range(at: 3)))
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, (1...31).contains(day) else { return nil }
        return calendar.date(from: parts)
    }

    private static let timeRegex = try! NSRegularExpression(pattern: #"^(\d{1,2})(?:[:.](\d{2}))?(am|pm|a|p)?$"#)

    /// `14:30`, `3pm`, `9:15am`, `noon`: minutes after midnight. A bare
    /// number isn't a time; one after "at" is (see `phrase`).
    static func time(_ word: String, bare: Bool = false) -> Int? {
        let word = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",."))
        if word == "noon" || word == "midday" { return 12 * 60 }
        if word == "midnight" { return 0 }
        let ns = word as NSString
        guard let match = timeRegex.firstMatch(in: word, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let hasMinutes = match.range(at: 2).location != NSNotFound
        let meridiem = match.range(at: 3).location == NSNotFound ? nil : ns.substring(with: match.range(at: 3))
        guard hasMinutes || meridiem != nil || bare else { return nil }
        guard var hour = Int(ns.substring(with: match.range(at: 1))) else { return nil }
        let minute = hasMinutes ? Int(ns.substring(with: match.range(at: 2))) ?? 0 : 0
        guard minute < 60 else { return nil }
        if let meridiem {
            guard (1...12).contains(hour) else { return nil }
            if meridiem.hasPrefix("p"), hour < 12 { hour += 12 }
            if meridiem.hasPrefix("a"), hour == 12 { hour = 0 }
        } else if bare, !hasMinutes, (1...7).contains(hour) {
            // "at 3" means the afternoon.
            hour += 12
        }
        guard hour < 24 else { return nil }
        return hour * 60 + minute
    }

    struct Found {
        var day: Date?
        var minutes: Int?
        var used: Int
    }

    /// The longest date and time phrase at the start of `words`, if any:
    /// "tomorrow", "fri at 3pm", "next week", "nov 20", "in 2 weeks", "15:00".
    static func phrase(_ words: [String], from now: Date, calendar: Calendar = .current) -> Found? {
        let words = words.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.;")) }
        guard let first = words.first, !first.isEmpty else { return nil }
        var found: Found?
        if let (day, used) = day(words, from: now, calendar: calendar) {
            found = Found(day: day, minutes: nil, used: used)
        }
        let at = found?.used ?? 0
        if at < words.count {
            if words[at] == "at", at + 1 < words.count, let (minutes, used) = time(in: words, from: at + 1, bare: true) {
                found = Found(day: found?.day, minutes: minutes, used: at + 1 + used)
            } else if let (minutes, used) = time(in: words, from: at, bare: false) {
                found = Found(day: found?.day, minutes: minutes, used: at + used)
            }
        }
        return found
    }

    /// "am" or "pm" in any of the ways it's written: "am", "a.m.", "AM".
    private static func meridiem(_ word: String) -> String? {
        let letters = word.lowercased().filter { $0 != "." }
        return letters == "am" || letters == "pm" ? letters : nil
    }

    /// A time at `index`, with "am" or "pm" as the next word when it's
    /// written apart ("3 am", "9:30 p.m."). Returns the minutes and the
    /// words used.
    private static func time(in words: [String], from index: Int, bare: Bool) -> (Int, Int)? {
        let word = words[index]
        if index + 1 < words.count, let half = meridiem(words[index + 1]), !word.lowercased().hasSuffix("m"),
           let minutes = time(word + half) {
            return (minutes, 2)
        }
        return time(word, bare: bare).map { ($0, 1) }
    }

    private static func day(_ words: [String], from now: Date, calendar: Calendar) -> (Date, Int)? {
        let today = calendar.startOfDay(for: now)
        func add(_ component: Calendar.Component, _ value: Int) -> Date {
            calendar.date(byAdding: component, value: value, to: today) ?? today
        }
        let first = words[0]
        let second = words.count > 1 ? words[1] : ""
        if let date = iso(first, calendar: calendar) { return (date, 1) }
        switch first {
        case "today", "tod", "tonight": return (today, 1)
        case "tomorrow", "tmr", "tmrw": return (add(.day, 1), 1)
        case "yesterday": return (add(.day, -1), 1)
        case "weekend": return (saturday(from: today, calendar: calendar), 1)
        default: break
        }
        if first == "this", second == "weekend" { return (saturday(from: today, calendar: calendar), 2) }
        if first == "next" {
            switch second {
            case "week": return (next(weekday: 2, after: today, calendar: calendar), 2)
            case "weekend": return (calendar.date(byAdding: .day, value: 7, to: saturday(from: today, calendar: calendar)) ?? today, 2)
            case "month":
                let month = calendar.date(byAdding: .month, value: 1, to: today) ?? today
                return (calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month, 2)
            case "year":
                let year = calendar.component(.year, from: today) + 1
                return (calendar.date(from: DateComponents(year: year, month: 1, day: 1)) ?? today, 2)
            default:
                if let weekday = weekday(named: second) { return (next(weekday: weekday, after: today, calendar: calendar), 2) }
            }
        }
        if first == "this" || first == "on", let weekday = weekday(named: second) {
            return (next(weekday: weekday, after: today, calendar: calendar), 2)
        }
        if let weekday = weekday(named: first) { return (next(weekday: weekday, after: today, calendar: calendar), 1) }
        if first == "in", words.count > 2 {
            let count = second == "a" || second == "an" ? 1 : Int(second)
            if let count, count > 0 {
                switch words[2] {
                case "day", "days": return (add(.day, count), 3)
                case "week", "weeks": return (add(.weekOfYear, count), 3)
                case "month", "months": return (add(.month, count), 3)
                case "year", "years": return (add(.year, count), 3)
                default: break
                }
            }
        }
        // "nov 20", "november 20th", "20 nov", with an optional year.
        if let month = month(named: first), let day = dayNumber(second) {
            return monthDay(month, day, year: words.count > 2 ? Int(words[2]) : nil, used: 2, from: today, calendar: calendar)
        }
        if let day = dayNumber(first), let month = month(named: second) {
            return monthDay(month, day, year: words.count > 2 ? Int(words[2]) : nil, used: 2, from: today, calendar: calendar)
        }
        return nil
    }

    private static func dayNumber(_ word: String) -> Int? {
        let digits = word.replacingOccurrences(of: #"(st|nd|rd|th)$"#, with: "", options: .regularExpression)
        guard let day = Int(digits), (1...31).contains(day) else { return nil }
        return day
    }

    /// A day in a month: this year, or next if it has passed.
    private static func monthDay(_ month: Int, _ day: Int, year: Int?, used: Int, from today: Date, calendar: Calendar) -> (Date, Int)? {
        if let year, (2000...2200).contains(year),
           let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) {
            return (date, used + 1)
        }
        let thisYear = calendar.component(.year, from: today)
        guard var date = calendar.date(from: DateComponents(year: thisYear, month: month, day: day)) else { return nil }
        if date < today { date = calendar.date(from: DateComponents(year: thisYear + 1, month: month, day: day)) ?? date }
        return (date, used)
    }

    private static func saturday(from today: Date, calendar: Calendar) -> Date {
        calendar.component(.weekday, from: today) == 7 ? today : next(weekday: 7, after: today, calendar: calendar)
    }

    // MARK: Writing

    static func isoString(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func timeString(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    static func durationString(_ minutes: Int) -> String {
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        if minutes > 60 { return "\(minutes / 60)h\(minutes % 60)m" }
        return "\(minutes)m"
    }

    // MARK: Showing

    /// "Today", "Tomorrow", "Friday", "Nov 20", "Nov 20, 2027".
    static func label(_ day: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let today = calendar.startOfDay(for: now)
        let offset = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: day)).day ?? 0
        switch offset {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case 2...6: return day.formatted(.dateTime.weekday(.wide))
        default:
            if calendar.component(.year, from: day) == calendar.component(.year, from: today) {
                return day.formatted(.dateTime.month(.abbreviated).day())
            }
            return day.formatted(.dateTime.month(.abbreviated).day().year())
        }
    }

    /// "3:30 PM", in the Mac's own clock style.
    static func timeLabel(_ minutes: Int, calendar: Calendar = .current) -> String {
        let date = calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    static func label(due: Date, minutes: Int?, now: Date = .now) -> String {
        guard let minutes else { return label(due, now: now) }
        return label(due, now: now) + " " + timeLabel(minutes)
    }
}

// MARK: - Quick add

/// A task typed in a line of plain words: "Call mum tomorrow 6pm #home p1".
/// The words that are dates, tags, priorities and repeats become metadata,
/// and the rest is the task.
nonisolated struct TaskDraft: Equatable {
    var title = ""
    var due: Date?
    var minutes: Int?
    var priority: Int?
    var tags: [String] = []
    var recurrence: Recurrence?
    var duration: Int?
    /// The words read as metadata, for showing what was understood.
    var matched: [String] = []

    var isEmpty: Bool { title.trimmingCharacters(in: .whitespaces).isEmpty }

    var line: String {
        TaskSyntax.newLine(title: title, tags: tags, priority: priority, due: due, minutes: minutes, recurrence: recurrence, duration: duration)
    }

    private static let ambiguous: Set<String> = ["sun", "mon", "tue", "wed", "weds", "thu", "thur", "fri", "sat", "tod", "may", "mar"]

    static func parse(_ text: String, now: Date = .now, calendar: Calendar = .current) -> TaskDraft {
        var draft = TaskDraft()
        let words = TaskSyntax.words(text.replacingOccurrences(of: "\n", with: " "))
        var keep: [String] = []
        var i = 0
        while i < words.count {
            let word = words[i]
            let lower = word.lowercased()
            let rest = Array(words[i...].prefix(5)).enumerated().map { $0.offset == 0 && $0.element.hasPrefix("@") ? String($0.element.dropFirst()) : $0.element }
            if let level = TaskSyntax.priority(word) {
                draft.priority = level
                draft.matched.append(word)
                i += 1
                continue
            }
            if let tag = TaskSyntax.tag(word) {
                draft.tags.append(tag)
                draft.matched.append(word)
                i += 1
                continue
            }
            if ["p1", "p2", "p3", "!1", "!2", "!3"].contains(lower) {
                draft.priority = Int(lower.dropFirst())
                draft.matched.append(word)
                i += 1
                continue
            }
            if let minutes = TaskSyntax.duration(word) {
                draft.duration = minutes
                draft.matched.append(word)
                i += 1
                continue
            }
            if lower == "for", i + 1 < words.count, let minutes = TaskSyntax.minutes(in: words[i + 1].lowercased()) {
                draft.duration = minutes
                draft.matched.append(words[i...i + 1].joined(separator: " "))
                i += 2
                continue
            }
            if draft.recurrence == nil, let (rule, used) = Recurrence.parse(rest) {
                draft.recurrence = rule
                draft.matched.append(words[i..<i + used].joined(separator: " "))
                i += used
                continue
            }
            // "on friday", "by tomorrow", "due nov 20": the lead-in goes with the date.
            let leadIn = ["on", "by", "due"].contains(lower) ? 1 : 0
            // Short forms that are also words ("sun", "sat") count only after "@" or a lead-in.
            let ambiguous = leadIn == 0 && !word.hasPrefix("@") && Self.ambiguous.contains(lower)
            if !ambiguous, draft.due == nil || draft.minutes == nil,
               let found = TaskDates.phrase(Array(rest.dropFirst(leadIn)), from: now, calendar: calendar),
               !(leadIn == 1 && found.day == nil) {
                if let day = found.day { draft.due = day }
                if let minutes = found.minutes { draft.minutes = minutes }
                let used = found.used + leadIn
                draft.matched.append(words[i..<i + used].joined(separator: " "))
                i += used
                continue
            }
            keep.append(word)
            i += 1
        }
        if let rule = draft.recurrence, draft.due == nil { draft.due = Self.firstDay(of: rule, from: now, calendar: calendar) }
        if draft.minutes != nil, draft.due == nil { draft.due = calendar.startOfDay(for: now) }
        draft.title = keep.joined(separator: " ")
        return draft
    }

    /// The first day a repeating task is due, from today on.
    static func firstDay(of rule: Recurrence, from now: Date, calendar: Calendar) -> Date {
        let today = calendar.startOfDay(for: now)
        switch rule {
        case .every: return today
        case .weekdays:
            return calendar.isDateInWeekend(today) ? TaskDates.next(weekday: 2, after: today, calendar: calendar) : today
        case .weekday(let day):
            return calendar.component(.weekday, from: today) == day ? today : TaskDates.next(weekday: day, after: today, calendar: calendar)
        }
    }
}

// MARK: - Relative dates in the editor

nonisolated extension TaskSyntax {
    /// When `segment` (from an `@` to the caret) is a whole date phrase not
    /// yet written as a date, what to write instead: `@tomorrow` becomes
    /// `@2026-11-16`, `@fri 3pm` becomes `@2026-11-20 15:00`, `@daily`
    /// becomes `@every day`.
    static func canonical(_ segment: String, now: Date = .now) -> String? {
        guard segment.hasPrefix("@"), segment.count > 1 else { return nil }
        let words = words(String(segment.dropFirst()))
        guard !words.isEmpty else { return nil }
        if let (rule, used) = Recurrence.parse(words), used == words.count {
            let text = "@" + rule.text
            return text == segment ? nil : text
        }
        guard let found = TaskDates.phrase(words, from: now), found.used == words.count else { return nil }
        let day = found.day ?? Calendar.current.startOfDay(for: now)
        var text = "@" + TaskDates.isoString(day)
        if let minutes = found.minutes { text += " " + TaskDates.timeString(minutes) }
        return text == segment ? nil : text
    }
}
