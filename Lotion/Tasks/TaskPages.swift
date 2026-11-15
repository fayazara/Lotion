//
//  TaskPages.swift
//  Lotion
//
//  Today, Upcoming and Inbox: the tasks in every note, gathered by when
//  they're due. Each task still lives on its line in its note; ticking one
//  here ticks it there.
//

import SwiftUI

/// The page around a task list: a title, a count, then the sections.
private struct TaskPage<Content: View>: View {
    let title: String
    let count: Int
    var detail: String?
    let colors: TaskColors
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 34) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(title)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(colors.heading)
                        .accessibilityAddTraits(.isHeader)
                    HStack(spacing: 6) {
                        Image(icon: "checkmark.circle")
                        Text(count == 1 ? "1 task" : "\(count) tasks")
                        if let detail {
                            Text("·")
                            Text(detail)
                        }
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(colors.secondary)
                }
                content()
            }
            .frame(maxWidth: 760, alignment: .leading)
            // Room on the left for the sections' fold chevrons.
            .padding(.leading, 64)
            .padding(.trailing, 40)
            .padding(.top, 48)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Today

struct TodayView: View {
    let state: AppState
    let palette: ThemePalette

    private var colors: TaskColors { TaskColors(palette: palette) }

    var body: some View {
        // Redrawn each minute, so "today" turns over at midnight.
        TimelineView(.everyMinute) { context in
            list(now: context.date)
        }
    }

    private func list(now: Date) -> some View {
        let today = state.library.tasks.today(now: now)
        return TaskPage(
            title: "Today",
            count: today.overdue.count + today.today.count,
            detail: now.formatted(.dateTime.weekday(.wide).day().month(.wide)),
            colors: colors
        ) {
            if !today.overdue.isEmpty {
                TaskSection(title: "Overdue", tasks: today.overdue, state: state, colors: colors) {
                    RescheduleMenu(tasks: today.overdue, state: state)
                }
            }
            TaskSection(title: now.formatted(.dateTime.day().month(.abbreviated)), subtitle: "Today · " + now.formatted(.dateTime.weekday(.wide)),
                        tasks: today.today, state: state, colors: colors, showsDay: false,
                        empty: today.overdue.isEmpty && today.done.isEmpty
                            ? "Nothing due today. Write @today after a to-do in any note, or add one here."
                            : nil,
                        dropDay: now, addsTasks: true, addDay: now)
            if !today.done.isEmpty {
                TaskSection(title: "Completed", tasks: today.done, state: state, colors: colors, showsDay: false, startsCollapsed: true)
            }
        }
    }
}

// MARK: - Upcoming

struct UpcomingView: View {
    let state: AppState
    let palette: ThemePalette

    private var colors: TaskColors { TaskColors(palette: palette) }
    private static let days = 14

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let all = state.library.tasks.run(TaskQuery(), now: now).filter { $0.due != nil }
        let overdue = all.filter { $0.due! < today }
        let byDay = Dictionary(grouping: all.filter { $0.due! >= today }) { calendar.startOfDay(for: $0.due!) }
        let horizon = calendar.date(byAdding: .day, value: Self.days, to: today) ?? today
        let later = byDay.keys.filter { $0 >= horizon }.sorted()
        return TaskPage(title: "Upcoming", count: all.count, detail: "the next two weeks", colors: colors) {
            if !overdue.isEmpty {
                TaskSection(title: "Overdue", tasks: overdue, state: state, colors: colors) {
                    RescheduleMenu(tasks: overdue, state: state)
                }
            }
            ForEach(0..<Self.days, id: \.self) { offset in
                let day = calendar.date(byAdding: .day, value: offset, to: today) ?? today
                let name = offset == 0 ? "Today · " : offset == 1 ? "Tomorrow · " : ""
                TaskSection(
                    title: day.formatted(.dateTime.day().month(.abbreviated)),
                    subtitle: name + day.formatted(.dateTime.weekday(.wide)),
                    tasks: byDay[day] ?? [],
                    state: state, colors: colors, showsDay: false,
                    dropDay: day, addsTasks: true, addDay: day
                )
            }
            if !later.isEmpty {
                TaskSection(title: "Later", tasks: later.flatMap { byDay[$0] ?? [] }, state: state, colors: colors)
            }
        }
    }
}

// MARK: - Inbox

struct InboxView: View {
    let state: AppState
    let palette: ThemePalette

    private var colors: TaskColors { TaskColors(palette: palette) }

    var body: some View {
        let index = state.library.tasks
        let inbox = index.inbox(create: false)
        let tasks = index.inboxTasks()
        let undated = tasks.filter { $0.due == nil }
        let dated = tasks.filter { $0.due != nil }
        TaskPage(title: "Inbox", count: tasks.count, colors: colors) {
            TaskSection(title: "No date", tasks: undated, state: state, colors: colors, showsNote: false,
                        empty: "Tasks from Quick Add wait here until they get a date.",
                        addsTasks: true) {
                if let inbox {
                    Button("Open Inbox Note") { state.selection = inbox.id }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(colors.accent)
                        .help("The inbox is a note called “Inbox”. Its to-dos, and undated ones in the scratchpad, show here.")
                }
            }
            if !dated.isEmpty {
                TaskSection(title: "Scheduled", tasks: dated, state: state, colors: colors, showsNote: false)
            }
        }
    }
}
