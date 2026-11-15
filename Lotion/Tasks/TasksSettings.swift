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
            SettingsSection("Quick Add", icon: "command") {
                SettingsRow("Shortcut", icon: "command",
                            detail: "Turns plain words into a task, from any app.",
                            info: "“Call mum tomorrow 6pm #home p1” becomes a task due tomorrow at 6pm, tagged home, priority 1.") {
                    ShortcutRecorder(shortcut: $shortcut, slot: .quickAdd)
                }
                if shortcut != nil, !GlobalHotKey.quickAdd.isRegistered, !GlobalHotKey.quickAdd.isSuspended {
                    SettingsNote(text: "Another app is using this shortcut. Pick a different one.")
                }
                SettingsRow("Adds to your Inbox", icon: "tray",
                            detail: "A note called “Inbox”, or another from the pane’s menu.",
                            info: "⌘↩ adds a task and keeps the pane open.") {
                    Button("Show Quick Add") { QuickAddController.shared.show() }
                }
            }

            SettingsSection("Writing tasks", icon: "checklist",
                            footer: "A task is any checklist line in any note. Add these after its words.") {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    syntax("@tomorrow, @fri 3pm", "When it's due. Becomes a date as you type.")
                    syntax("@every monday", "Repeats; checking it off makes the next one.")
                    syntax("!1  !2  !3", "Priority, 1 highest.")
                    syntax("#tag", "Tags, to filter by.")
                    syntax("~45m", "How long it takes.")
                    syntax("[tasks #work due:week]", "On its own line: a live list of matching tasks.")
                }
                .padding(SettingsStyle.rowPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func syntax(_ code: String, _ meaning: String) -> some View {
        GridRow {
            Text(code)
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Palette.label)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .textSelection(.enabled)
            Text(meaning)
                .font(.system(size: 12))
                .foregroundStyle(Palette.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
