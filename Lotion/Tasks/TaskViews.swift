//
//  TaskViews.swift
//  Lotion
//
//  The pieces every task list is made of: a row with its checkbox, date,
//  tags and note, the menu of things to do with a task, and the field that
//  adds one from a line of plain words. They sit on the note canvas, in the
//  theme's colors, like Home.
//

import SwiftUI
import UniformTypeIdentifiers

/// Colors for task lists, from the note theme.
struct TaskColors {
    let palette: ThemePalette

    var ink: Color { Color(nsColor: palette.text) }
    var heading: Color { Color(nsColor: palette.heading) }
    var secondary: Color { Color(nsColor: palette.secondary) }
    var accent: Color { Color(nsColor: palette.glyph ?? palette.accent) }
    var hairline: Color { ink.opacity(palette.isDark ? 0.12 : 0.08) }
    var fill: Color { ink.opacity(palette.isDark ? 0.05 : 0.03) }
    var overdue: Color { Color(nsColor: .systemRed) }

    func priority(_ level: Int?) -> Color? {
        switch level {
        case 1: Color(nsColor: .systemRed)
        case 2: Color(nsColor: .systemOrange)
        case 3: Color(nsColor: .systemBlue)
        default: nil
        }
    }

    func due(_ task: TaskItem, now: Date = .now) -> Color {
        guard let due = task.due, !task.checked else { return secondary }
        return self.due(for: due, now: now)
    }

    /// Overdue red, today green, tomorrow orange, later the theme's color.
    func due(for day: Date, now: Date = .now) -> Color {
        let calendar = Calendar.current
        if day < calendar.startOfDay(for: now) { return overdue }
        if calendar.isDateInToday(day) { return Color(nsColor: .systemGreen) }
        if calendar.isDateInTomorrow(day) { return Color(nsColor: .systemOrange) }
        return accent
    }
}

/// What a dragged task carries: its id, behind a prefix so a note dragged
/// from the sidebar isn't taken for one.
enum TaskDrag {
    static let prefix = "lotion-task:"
    static func payload(_ task: TaskItem) -> String { prefix + task.id }
    static func id(from payload: String) -> String? {
        payload.hasPrefix(prefix) ? String(payload.dropFirst(prefix.count)) : nil
    }
}

// MARK: - Checkbox

struct TaskCheckbox: View {
    let checked: Bool
    let priority: Int?
    let colors: TaskColors
    var size: CGFloat = 17
    let toggle: () -> Void
    @State private var isHovered = false

    var body: some View {
        let tint = colors.priority(priority) ?? colors.secondary.opacity(0.75)
        Button(action: toggle) {
            ZStack {
                Circle()
                    .fill(checked ? tint : tint.opacity(priority == nil ? 0 : 0.12))
                Circle()
                    .strokeBorder(tint, lineWidth: priority == nil ? 1.2 : 1.6)
                if checked || isHovered {
                    Image(icon: "checkmark")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(checked ? Color(nsColor: colors.palette.background) : tint)
                }
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(checked ? "Mark as not done" : "Mark as done")
    }
}

// MARK: - Row

struct TaskRow: View {
    let task: TaskItem
    let state: AppState
    let colors: TaskColors
    /// Show which note the task is in.
    var showsNote = true
    /// Leave the day out, for lists already grouped by day.
    var showsDay = true
    @State private var isHovered = false
    @State private var isLeaving = false

    private var index: TaskIndex { state.library.tasks }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            TaskCheckbox(checked: task.checked || isLeaving, priority: task.priority, colors: colors, size: 18) { toggle() }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                    Text(task.title.isEmpty ? "Untitled task" : task.title)
                        .font(.system(size: 14))
                        .foregroundStyle(colors.ink.opacity(task.checked || isLeaving ? 0.45 : task.title.isEmpty ? 0.5 : 1))
                        .strikethrough(task.checked || isLeaving, color: colors.secondary.opacity(0.6))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    TaskMenuButton(task: task, state: state, colors: colors)
                        .opacity(isHovered ? 1 : 0)
                }
                meta
            }
        }
        .padding(.top, 11)
        .padding(.bottom, 12)
        // Every row ends on a hairline, as in a list, from the checkbox to the edge.
        .overlay(alignment: .bottom) {
            Rectangle().fill(colors.hairline).frame(height: 0.5)
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .onTapGesture(count: 2) { state.open(task) }
        .contextMenu { TaskMenuItems(task: task, state: state) }
        .draggable(TaskDrag.payload(task)) {
            Text(task.title)
                .font(.system(size: 13))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
        }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: task.checked ? "Mark as not done" : "Mark as done") { toggle() }
        .accessibilityAction(named: "Open note") { state.open(task) }
    }

    /// Where the task lives, as "Note / Section".
    private func place(_ note: Note) -> String {
        let name = note.isScratchpad ? "Scratchpad" : note.displayTitle
        guard let section = task.section, section != note.displayTitle else { return name }
        return name + " / " + section
    }

    /// One line under the title: when, how often, how long and tags on the
    /// left; the note it's in on the right.
    @ViewBuilder private var meta: some View {
        let note = showsNote ? index.note(of: task) : nil
        let hasLeft = (showsDay && task.due != nil) || task.minutes != nil || task.priority != nil || task.recurrence != nil || task.duration != nil || !task.tags.isEmpty
        if hasLeft || note != nil {
            HStack(spacing: 14) {
                if let due = task.due, showsDay {
                    Label(TaskDates.label(due: due, minutes: task.minutes), icon: "calendar")
                        .foregroundStyle(colors.due(task))
                } else if let minutes = task.minutes {
                    Label(TaskDates.timeLabel(minutes), icon: "clock")
                        .foregroundStyle(colors.due(task))
                }
                if let priority = task.priority, let color = colors.priority(priority) {
                    Label("P\(priority)", icon: "flag.fill")
                        .foregroundStyle(color)
                }
                if let rule = task.recurrence {
                    Label(rule.text.capitalizedFirst, icon: "repeat")
                }
                if let duration = task.duration {
                    Label(TaskDates.durationString(duration), icon: "hourglass")
                }
                ForEach(task.tags, id: \.self) { tag in
                    Label(tag, icon: "tag")
                }
                Spacer(minLength: Space.l)
                if let note {
                    Button { state.open(task) } label: {
                        HStack(spacing: 5) {
                            Text(place(note))
                            Image(icon: note.isScratchpad ? "note.text" : "doc.text")
                                .imageScale(.small)
                        }
                        .foregroundStyle(isHovered ? colors.ink.opacity(0.75) : colors.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open the note")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(colors.secondary)
            .labelStyle(CompactLabelStyle())
            .lineLimit(1)
        }
    }

    private func toggle() {
        if task.checked {
            index.setChecked(task, false)
            return
        }
        // A beat to see it ticked before it leaves the list.
        withAnimation(.easeOut(duration: 0.15)) { isLeaving = true }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            withAnimation(.easeInOut(duration: 0.25)) { _ = index.setChecked(task, true) }
            isLeaving = false
        }
    }
}

/// A task on one line, for Home: checkbox, title, and on the right its time,
/// or its day in red when it's overdue. Nothing else; the section says
/// it's today. Clicking the row opens its note.
struct TaskCompactRow: View {
    let task: TaskItem
    let state: AppState
    let colors: TaskColors
    /// The last row draws no divider under it.
    var isLast = false
    @State private var isHovered = false

    /// Where the title starts, for lining up text under the rows.
    static let textInset: CGFloat = 10 + 16 + 12

    var body: some View {
        HStack(spacing: 12) {
            TaskCheckbox(checked: task.checked, priority: task.priority, colors: colors, size: 16) {
                withAnimation(.easeInOut(duration: 0.25)) { _ = state.library.tasks.setChecked(task, !task.checked) }
            }
            Text(task.title.isEmpty ? "Untitled task" : task.title)
                .font(.system(size: 13.5))
                .foregroundStyle(colors.ink.opacity(task.title.isEmpty ? 0.5 : 1))
                .lineLimit(1)
            Spacer(minLength: Space.l)
            trailing
                .font(.system(size: 13).monospacedDigit())
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovered ? colors.ink.opacity(colors.palette.isDark ? 0.07 : 0.045) : .clear)
        )
        // Dividers run under the text, not the checkbox, and give way to the hover.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(colors.hairline)
                .frame(height: 0.5)
                .padding(.leading, Self.textInset)
                .padding(.trailing, 10)
                .opacity(isLast || isHovered ? 0 : 1)
        }
        .contentShape(Rectangle())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering } }
        .onTapGesture { state.open(task) }
        .contextMenu { TaskMenuItems(task: task, state: state) }
        .draggable(TaskDrag.payload(task))
        .help("Open “\(state.library.tasks.note(of: task)?.displayTitle ?? "the note")”")
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Mark as done") { state.library.tasks.setChecked(task, true) }
    }

    @ViewBuilder private var trailing: some View {
        if task.isOverdue(), let due = task.due {
            Text(TaskDates.label(due))
                .foregroundStyle(colors.overdue)
        } else if let minutes = task.minutes {
            Text(TaskDates.timeLabel(minutes))
                .foregroundStyle(colors.accent)
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Menus

/// Dates offered in a task's menus.
enum TaskQuickDate: CaseIterable {
    case today, tomorrow, weekend, nextWeek

    var title: String {
        switch self {
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .weekend: "This Weekend"
        case .nextWeek: "Next Week"
        }
    }

    var symbol: String {
        switch self {
        case .today: "sun.max"
        case .tomorrow: "sunrise"
        case .weekend: "sofa"
        case .nextWeek: "arrow.right.circle"
        }
    }

    var date: Date {
        let words: [String] = switch self {
        case .today: ["today"]
        case .tomorrow: ["tomorrow"]
        case .weekend: ["this", "weekend"]
        case .nextWeek: ["next", "week"]
        }
        return TaskDates.phrase(words, from: .now)?.day ?? .now
    }
}

struct TaskMenuItems: View {
    let task: TaskItem
    let state: AppState

    private var index: TaskIndex { state.library.tasks }

    var body: some View {
        Button(task.checked ? "Mark as Not Done" : "Mark as Done", icon: task.checked ? "circle" : "checkmark.circle") {
            index.setChecked(task, !task.checked)
        }
        Button("Open Note", icon: "arrow.up.right.square") { state.open(task) }
        Divider()
        Section("Due") {
            ForEach(TaskQuickDate.allCases, id: \.self) { choice in
                Button(choice.title, icon: choice.symbol) { index.move(task, to: choice.date) }
            }
            if task.minutes != nil {
                Button("Remove Time", icon: "clock.badge.xmark") { index.setDue(task, task.due, minutes: nil) }
            }
            if task.due != nil {
                Button("No Date", icon: "calendar.badge.minus") { index.setDue(task, nil) }
            }
        }
        Menu("Priority", icon: "flag") {
            ForEach(1...3, id: \.self) { level in
                Button("Priority \(level)") { index.setPriority(task, level) }
                    .disabled(task.priority == level)
            }
            Button("None") { index.setPriority(task, nil) }
                .disabled(task.priority == nil)
        }
    }
}

/// The "…" that shows on a hovered row, with the same choices as its context menu.
private struct TaskMenuButton: View {
    let task: TaskItem
    let state: AppState
    let colors: TaskColors

    var body: some View {
        Menu {
            TaskMenuItems(task: task, state: state)
        } label: {
            Image(icon: "ellipsis")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(colors.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Date, priority and more")
    }
}

// MARK: - Sections

/// A titled group of tasks, which a task can be dropped on to move it there.
/// The chevron in the margin folds it away.
struct TaskSection<Accessory: View>: View {
    let title: String
    var subtitle: String?
    var titleColor: Color?
    let tasks: [TaskItem]
    let state: AppState
    let colors: TaskColors
    var showsDay = true
    var showsNote = true
    var empty: String?
    /// The day a task dropped here moves to.
    var dropDay: Date?
    var startsCollapsed = false
    /// An "Add task" at the end of the list, for tasks due on this day
    /// (nil for none), into the inbox.
    var addsTasks = false
    var addDay: Date?
    @ViewBuilder var accessory: () -> Accessory
    @State private var isTargeted = false
    @State private var isCollapsed: Bool?

    private var collapsed: Bool { isCollapsed ?? startsCollapsed }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: Space.m) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(titleColor ?? colors.heading)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.secondary)
                }
                if !tasks.isEmpty {
                    Text(tasks.count, format: .number)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(colors.secondary.opacity(0.7))
                }
                Spacer()
                accessory()
            }
            .padding(.bottom, 10)
            .overlay(alignment: .topLeading) {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { isCollapsed = !collapsed }
                } label: {
                    Image(icon: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(colors.secondary)
                        .rotationEffect(.degrees(collapsed ? -90 : 0))
                        .frame(width: 22, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .offset(x: -30, y: -1)
                .help(collapsed ? "Show" : "Hide")
                .accessibilityLabel(collapsed ? "Show \(title)" : "Hide \(title)")
            }
            .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(isTargeted ? colors.accent : colors.hairline)
                .frame(height: isTargeted ? 2 : 0.5)

            if !collapsed {
                if tasks.isEmpty, let empty {
                    Text(empty)
                        .font(.system(size: 13))
                        .foregroundStyle(colors.secondary.opacity(0.8))
                        .padding(.vertical, 12)
                }
                ForEach(tasks) { task in
                    TaskRow(task: task, state: state, colors: colors, showsNote: showsNote, showsDay: showsDay)
                }
                if addsTasks {
                    TaskQuickAddField(state: state, colors: colors, defaultDay: addDay)
                        .padding(.top, 6)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let dropDay else { return false }
            let moved = items.compactMap(TaskDrag.id(from:)).compactMap { state.library.tasks.task(id: $0) }
            for task in moved { state.library.tasks.move(task, to: dropDay) }
            return !moved.isEmpty
        } isTargeted: { isTargeted = dropDay != nil && $0 }
    }
}

extension TaskSection where Accessory == EmptyView {
    init(title: String, subtitle: String? = nil, titleColor: Color? = nil, tasks: [TaskItem], state: AppState, colors: TaskColors,
         showsDay: Bool = true, showsNote: Bool = true, empty: String? = nil, dropDay: Date? = nil,
         startsCollapsed: Bool = false, addsTasks: Bool = false, addDay: Date? = nil) {
        self.init(title: title, subtitle: subtitle, titleColor: titleColor, tasks: tasks, state: state, colors: colors,
                  showsDay: showsDay, showsNote: showsNote, empty: empty, dropDay: dropDay,
                  startsCollapsed: startsCollapsed, addsTasks: addsTasks, addDay: addDay) { EmptyView() }
    }
}

/// "Reschedule": moves every task in a list to a day.
struct RescheduleMenu: View {
    let tasks: [TaskItem]
    let state: AppState

    var body: some View {
        Menu {
            ForEach(TaskQuickDate.allCases, id: \.self) { choice in
                Button(choice.title, icon: choice.symbol) {
                    for task in tasks { state.library.tasks.move(task, to: choice.date) }
                }
            }
        } label: {
            Text("Reschedule")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color(nsColor: .systemRed))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Quick add

/// "+ Add task" at the end of a list. Clicked, it's a field that turns plain
/// words into a task, showing what it understood. Return adds and stays
/// open for the next one; Escape puts it away.
struct TaskQuickAddField: View {
    let state: AppState
    let colors: TaskColors
    /// The day a task without one gets, in Today and Upcoming.
    var defaultDay: Date?
    var placeholder = "Call Sam tomorrow 3pm #work p1"
    /// Where it goes; the inbox when nil.
    var target: Note?
    @State private var text = ""
    @State private var isEditing = false
    @State private var isHovered = false
    @State private var added: String?
    /// A note picked in the editor, over `target`.
    @State private var choice: Note.ID?
    @FocusState private var isFocused: Bool

    private var draft: TaskDraft {
        var draft = TaskDraft.parse(text)
        if draft.due == nil, let defaultDay { draft.due = Calendar.current.startOfDay(for: defaultDay) }
        return draft
    }

    #if DEBUG
    /// Opens the next field shown with this text, for the self-test's screenshots.
    static var openForTesting: String?
    #endif

    var body: some View {
        Group {
            if isEditing { editor } else { button }
        }
        #if DEBUG
        .onAppear {
            if let text = Self.openForTesting {
                Self.openForTesting = nil
                self.text = text
                isEditing = true
            }
        }
        #endif
    }

    private var button: some View {
        Button {
            isEditing = true
        } label: {
            HStack(spacing: 12) {
                Image(icon: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(colors.accent)
                    .frame(width: 18)
                Text(added.map { "Added to \($0)" } ?? "Add task")
                    .font(.system(size: 14))
                    .foregroundStyle(isHovered ? colors.accent : colors.secondary)
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var editor: some View {
        let draft = draft
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .focused($isFocused)
                    .onSubmit(add)
                    .onExitCommand(perform: close)
                // What the words were read as; a quiet hint until there are some.
                if draft.due != nil || draft.priority != nil || draft.recurrence != nil || draft.duration != nil || !draft.tags.isEmpty {
                    TaskDraftChips(draft: draft, colors: colors)
                } else {
                    Text("Type a date, a time, “every week”, #tags or p1–p3")
                        .font(.system(size: 12))
                        .foregroundStyle(colors.secondary.opacity(0.75))
                        .frame(height: 22)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 12)

            Rectangle().fill(colors.hairline).frame(height: 0.5)

            HStack(spacing: Space.m) {
                TaskTargetMenu(state: state, colors: colors, target: target, choice: $choice)
                Spacer()
                Button("Cancel", action: close)
                    .buttonStyle(CapsuleButtonStyle(palette: colors.palette))
                    .keyboardShortcut(.cancelAction)
                Button("Add task", action: add)
                    .buttonStyle(CapsuleButtonStyle(palette: colors.palette, isProminent: true))
                    .disabled(draft.isEmpty)
            }
            // The menu's own 10pt padding puts its icon under the title's first letter.
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .padding(.vertical, 8)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: colors.palette.background)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(colors.ink.opacity(colors.palette.isDark ? 0.2 : 0.13), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(colors.palette.isDark ? 0.3 : 0.05), radius: 8, y: 2)
        .padding(.vertical, 8)
        .onAppear { isFocused = true }
    }

    private func close() {
        text = ""
        isEditing = false
    }

    private func add() {
        let draft = draft
        guard !draft.isEmpty else { return }
        let target = choice.flatMap { state.library.note(id: $0) } ?? target ?? state.library.tasks.inbox(create: true)
        guard let target, state.library.tasks.add(draft, to: target) != nil else { return }
        text = ""
        added = target.displayTitle
        isFocused = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            added = nil
        }
    }
}

/// What a typed task will be, in the same words and colors as a task row:
/// its date, repeat, length, priority and tags.
struct TaskDraftChips: View {
    let draft: TaskDraft
    let colors: TaskColors

    var body: some View {
        HStack(spacing: Space.s) {
            if let due = draft.due {
                chip(TaskDates.label(due: due, minutes: draft.minutes), "calendar", colors.due(for: due))
            }
            if let rule = draft.recurrence { chip(rule.text.capitalizedFirst, "repeat", colors.secondary) }
            if let duration = draft.duration { chip(TaskDates.durationString(duration), "hourglass", colors.secondary) }
            if let priority = draft.priority { chip("P\(priority)", "flag.fill", colors.priority(priority) ?? colors.secondary) }
            ForEach(draft.tags, id: \.self) { chip($0, "tag", colors.secondary) }
        }
    }

    private func chip(_ title: String, _ symbol: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(icon: symbol).imageScale(.small)
            Text(title)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(colors.palette.isDark ? 0.18 : 0.1)))
    }
}

/// Which note a new task goes in: the inbox, or one picked from the
/// notes edited most recently.
struct TaskTargetMenu: View {
    let state: AppState
    let colors: TaskColors
    let target: Note?
    @Binding var choice: Note.ID?
    @State private var isHovered = false

    private var current: Note? { choice.flatMap { state.library.note(id: $0) } ?? target }

    var body: some View {
        Menu {
            Button(TaskIndex.inboxTitle, icon: "tray") { choice = state.library.tasks.inbox(create: true)?.id }
            Divider()
            ForEach(state.library.notes.filter { !$0.title.isEmpty && $0.title != TaskIndex.inboxTitle }
                        .sorted { $0.modified > $1.modified }.prefix(20)) { note in
                Button(note.displayTitle) { choice = note.id }
            }
        } label: {
            HStack(spacing: 5) {
                Image(icon: current == nil ? "tray" : "doc.text").imageScale(.small)
                Text(current?.displayTitle ?? TaskIndex.inboxTitle)
                Image(icon: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isHovered ? colors.ink : colors.secondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Capsule().fill(colors.ink.opacity(isHovered ? 0.06 : 0)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("The note this task goes in")
    }
}

/// Lotion's button: a capsule, as on Home. The prominent one is filled with
/// the theme's color; the other is a quiet grey.
struct CapsuleButtonStyle: ButtonStyle {
    let palette: ThemePalette
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        CapsuleButton(configuration: configuration, palette: palette, isProminent: isProminent)
    }

    private struct CapsuleButton: View {
        let configuration: ButtonStyleConfiguration
        let palette: ThemePalette
        let isProminent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            let ink = Color(nsColor: palette.text)
            let tint = Color(nsColor: palette.glyph ?? palette.accent)
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isProminent ? Color.white : ink)
                .padding(.horizontal, Space.l)
                .frame(height: 28)
                .background {
                    Capsule().fill(isProminent
                        ? tint.opacity(isHovered && isEnabled ? 1 : 0.92)
                        : ink.opacity(isHovered && isEnabled ? 0.09 : 0.055))
                }
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
                .contentShape(Capsule())
                .onHover { isHovered = $0 }
                .animation(.easeOut(duration: 0.15), value: isHovered)
        }
    }
}
