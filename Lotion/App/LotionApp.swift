//
//  LotionApp.swift
//  Lotion
//

import AppKit
import SwiftUI

/// `Lotion --mcp` is the agent relay and must never start the UI, so the
/// choice is made before SwiftUI gets the process.
@main
enum LotionMain {
    static func main() {
        if AgentRelay.isRequested {
            AgentRelay.run()
        }
        LotionApp.main()
    }
}

struct LotionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(Prefs.appearance) private var appearance: AppearanceMode = .system

    private var state: AppState { appDelegate.state }

    var body: some Scene {
        // One window: every note lives in one library, edited in one place.
        Window("Lotion", id: "main") {
            ContentView(state: state)
                .onAppear {
                    NSApp.appearance = appearance.nsAppearance
                    #if DEBUG
                    SelfTest.runIfRequested(state)
                    #endif
                }
                .onChange(of: appearance) { _, mode in NSApp.appearance = mode.nsAppearance }
        }
        .defaultSize(width: 1220, height: 780)
        .commands { LotionCommands(state: state) }

    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by the window, so the agent server can reach
    /// the library from launch.
    let state = AppState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdaterManager.shared.start()
        AgentServer.shared.state = state
        AgentServer.shared.updateForPreference()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Removes the socket, so a relay sees Lotion is gone and reopens it.
        AgentServer.shared.stop()
        if let note = state.selectedNote, note.isBlank {
            state.library.discardIfBlank(note)
        }
        state.library.saveAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LotionCommands: Commands {
    let state: AppState
    @AppStorage(Prefs.inspectorVisible) private var inspectorVisible = true
    @AppStorage(Prefs.editorMode) private var editorMode: EditorMode = .blocks

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton()
        }
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { SettingsWindowController.show() }
                .keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            Button("New Note") { state.newNote() }
                .keyboardShortcut("n")
            Button("New Folder") { state.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Scratchpad") { state.openScratchpad() }
                .keyboardShortcut("0")
            // Only while the scratchpad shows, so ⌘↩ stays free elsewhere.
            Button("New Scratchpad Entry") { state.newScratchpadEntry() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.isScratchpadOpen)
        }
        CommandGroup(after: .saveItem) {
            Button("Show in Finder") {
                if let note = state.selectedNote { state.showInFinder(note) }
            }
            .keyboardShortcut("r", modifiers: [.command, .option])
            .disabled(state.selectedNote == nil)
            Button("Export as Markdown…") {
                if let note = state.selectedNote { state.exportMarkdown(note) }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(state.selectedNote == nil)
            Button(state.selectedNote.map { state.library.isPinned($0) } == true ? "Unpin Note" : "Pin Note") {
                if let note = state.selectedNote { state.togglePin(note) }
            }
            .disabled(state.selectedNote == nil || state.isScratchpadOpen)
            Divider()
            Button("Move to Trash") {
                if let note = state.selectedNote { state.delete(note) }
            }
            .disabled(state.selectedNote == nil || state.isScratchpadOpen)
        }
        CommandGroup(after: .textEditing) {
            Button("Search All Notes") { state.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }
        CommandMenu("Format") {
            FormatButton("Bold", #selector(BlockTextView.toggleBold(_:)), key: "b")
            FormatButton("Italic", #selector(BlockTextView.toggleItalic(_:)), key: "i")
            FormatButton("Strikethrough", #selector(BlockTextView.toggleStrikethrough(_:)), key: "x", modifiers: [.command, .shift])
            FormatButton("Inline Code", #selector(BlockTextView.toggleInlineCode(_:)), key: "e")
            FormatButton("Link", #selector(BlockTextView.insertLink(_:)), key: "k")
            Divider()
            FormatButton("Text", #selector(BlockTextView.makeBodyText(_:)), key: "0", modifiers: [.command, .option])
            FormatButton("Heading 1", #selector(BlockTextView.makeHeading1(_:)), key: "1", modifiers: [.command, .option])
            FormatButton("Heading 2", #selector(BlockTextView.makeHeading2(_:)), key: "2", modifiers: [.command, .option])
            FormatButton("Heading 3", #selector(BlockTextView.makeHeading3(_:)), key: "3", modifiers: [.command, .option])
            Divider()
            FormatButton("Bulleted List", #selector(BlockTextView.toggleBulletList(_:)), key: "8", modifiers: [.command, .shift])
            FormatButton("Numbered List", #selector(BlockTextView.toggleNumberedList(_:)), key: "7", modifiers: [.command, .shift])
            FormatButton("To-do List", #selector(BlockTextView.toggleChecklist(_:)), key: "l", modifiers: [.command, .shift])
            FormatButton("Quote", #selector(BlockTextView.toggleQuote(_:)), key: "'", modifiers: [.command])
            FormatButton("Code Block", #selector(BlockTextView.insertCodeBlock(_:)), key: "c", modifiers: [.command, .option])
            Divider()
            FormatButton("Image or Video…", #selector(BlockTextView.insertMediaFromPanel(_:)), key: "i", modifiers: [.command, .shift])
            FormatButton("Table", #selector(BlockTextView.insertTable(_:)), key: "t", modifiers: [.command, .option])
            FormatButton("Divider", #selector(BlockTextView.insertDivider(_:)), key: "-", modifiers: [.command, .option])
            Divider()
            FormatButton("Move Block Up", #selector(BlockTextView.moveBlockUp(_:)), key: .upArrow, modifiers: [.command, .shift])
            FormatButton("Move Block Down", #selector(BlockTextView.moveBlockDown(_:)), key: .downArrow, modifiers: [.command, .shift])
            FormatButton("Duplicate Block", #selector(BlockTextView.duplicateBlock(_:)), key: "d")
        }
        CommandGroup(before: .sidebar) {
            Button(editorMode == .markdown ? "Edit as Blocks" : "Edit as Markdown") {
                editorMode = editorMode == .markdown ? .blocks : .markdown
            }
            .keyboardShortcut("m", modifiers: [.command, .control])
            Button(inspectorVisible ? "Hide Inspector" : "Show Inspector") { inspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Picker("Sort Notes By", selection: Binding(get: { state.library.sort }, set: { state.library.sort = $0 })) {
                ForEach(NoteSort.allCases) { Text($0.title).tag($0) }
            }
            Divider()
        }
    }
}

/// A Format menu item, sent to whichever editor has focus.
private struct FormatButton: View {
    let title: String
    let action: Selector
    let key: KeyEquivalent
    let modifiers: EventModifiers

    init(_ title: String, _ action: Selector, key: KeyEquivalent, modifiers: EventModifiers = .command) {
        self.title = title
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }

    var body: some View {
        Button(title) { NSApp.sendAction(action, to: nil, from: nil) }
            .keyboardShortcut(key, modifiers: modifiers)
    }
}
