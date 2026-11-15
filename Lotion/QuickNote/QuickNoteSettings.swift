//
//  QuickNoteSettings.swift
//  Lotion
//
//  Settings → Quick Note: the shortcut that opens the pane from any app,
//  whether it stays above other windows, and opening Lotion at login so
//  the shortcut is always there.
//

import AppKit
import SwiftUI

struct QuickNotePane: View {
    @State private var shortcut = KeyShortcut.quickNote
    @State private var keepOnTop = QuickNoteController.shared.model.keepOnTop
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        SettingsPage {
            Section {
                LabeledContent {
                    ShortcutRecorder(shortcut: $shortcut)
                } label: {
                    SettingsControlLabel("Shortcut",
                                         detail: "Opens the quick note pane from any app. Press it again while typing in the pane to put it away.")
                }
                if shortcut != nil, !GlobalHotKey.quickNote.isRegistered, !GlobalHotKey.quickNote.isSuspended {
                    Label("Another app is using this shortcut. Pick a different one.", icon: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle(isOn: $keepOnTop) {
                    SettingsControlLabel("Keep on top",
                                         detail: "The pane floats above other windows, on every desktop and over full-screen apps.")
                }
                .onChange(of: keepOnTop) { _, value in QuickNoteController.shared.setKeepOnTop(value) }
                LabeledContent {
                    Button("Show Quick Note") { QuickNoteController.shared.show() }
                } label: {
                    SettingsControlLabel("Writes to your scratchpad",
                                         detail: "Each entry in the pane is an entry in the scratchpad. ⌘N starts a new one, ⌘P finds an older one, and Esc puts the pane away.")
                }
            }

            Section {
                Toggle(isOn: $openAtLogin) {
                    SettingsControlLabel("Open Lotion at login",
                                         detail: "Lotion keeps running when its window is closed, so the shortcut works until you quit with ⌘Q.")
                }
                .onChange(of: openAtLogin) { _, value in
                    guard value != LoginItem.isEnabled else { return }
                    do {
                        try LoginItem.set(value)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                        openAtLogin = LoginItem.isEnabled
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .onAppear { openAtLogin = LoginItem.isEnabled }
    }
}

/// Click, then press the new shortcut. Esc cancels; Delete clears it.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    var slot: HotKeySlot = .quickNote
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Type Shortcut…" : shortcut?.display ?? "Record Shortcut")
                    .font(.system(size: 12, weight: .medium, design: shortcut == nil || isRecording ? .default : .rounded))
                    .frame(minWidth: 110)
            }
            .buttonStyle(.bordered)
            .tint(isRecording ? .accentColor : nil)
            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                    slot.shortcut = nil
                } label: {
                    Image(icon: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear Shortcut")
            }
            if shortcut != slot.defaultShortcut, !isRecording {
                Button("Reset") {
                    shortcut = slot.defaultShortcut
                    slot.shortcut = shortcut
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        slot.hotKey.isSuspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let bare = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            let keyCode = event.keyCode
            let recorded = KeyShortcut(event: event)
            MainActor.assumeIsolated { record(bare: bare, keyCode: keyCode, recorded) }
            return nil
        }
    }

    private func record(bare: Bool, keyCode: UInt16, _ recorded: KeyShortcut?) {
        if bare, keyCode == 53 { stop(); return }
        if bare, keyCode == 51 || keyCode == 117 {
            shortcut = nil
            slot.shortcut = nil
            stop()
            return
        }
        guard let recorded else {
            NSSound.beep()
            return
        }
        shortcut = recorded
        slot.shortcut = recorded
        stop()
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        slot.hotKey.isSuspended = false
    }
}
