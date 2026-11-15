//
//  TasksSettings.swift
//  Lotion
//
//  Settings → Tasks: the Quick Add shortcut, and how to write a task.
//

import SwiftUI

struct TasksPane: View {
    @State private var shortcut = KeyShortcut.quickAdd

    var body: some View {
        SettingsPage {
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: $shortcut, slot: .quickAdd)
                } label: {
                    SettingsControlLabel("Quick Add shortcut",
                                         detail: "Opens a field from any app that turns plain words into a task: “Call mum tomorrow 6pm #home p1”.")
                }
                if shortcut != nil, !GlobalHotKey.quickAdd.isRegistered, !GlobalHotKey.quickAdd.isSuspended {
                    Label("Another app is using this shortcut. Pick a different one.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                LabeledContent {
                    Button("Show Quick Add") { QuickAddController.shared.show() }
                } label: {
                    SettingsControlLabel("Adds to your Inbox",
                                         detail: "A note called “Inbox”. Pick another note from the pane’s menu. ⌘↩ adds a task and keeps the pane open.")
                }
            }

            Section("Writing tasks") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("A task is any checklist line in any note. Add these after its words:")
                        .font(.callout)
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        syntax("@tomorrow, @fri 3pm, @nov 20", "When it's due. Becomes a date as you type.")
                        syntax("@every week, @every monday", "Repeats; checking it off makes the next one.")
                        syntax("!1  !2  !3", "Priority, 1 highest.")
                        syntax("#tag", "Tags, to filter by.")
                        syntax("~45m", "How long it takes.")
                        syntax("[tasks #work due:week]", "On its own line: a live list of matching tasks.")
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func syntax(_ code: String, _ meaning: String) -> some View {
        GridRow {
            Text(code)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
            Text(meaning)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
