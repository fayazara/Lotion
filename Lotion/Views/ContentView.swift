//
//  ContentView.swift
//  Lotion
//
//  The window: sidebar, the note on its themed canvas, and the inspector.
//

import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState

    @AppStorage(Prefs.inspectorVisible) private var inspectorVisible = true
    @AppStorage(Prefs.theme) private var theme: LotionTheme = .paper
    @AppStorage(Prefs.interfaceFont) private var interfaceFont = FontChoice.system
    @AppStorage(Prefs.noteFont) private var noteFont = FontChoice.system
    @AppStorage(Prefs.noteFontSize) private var noteFontSize = 15.0
    @AppStorage(Prefs.lineSpacing) private var lineSpacing: LineSpacing = .comfortable
    @AppStorage(Prefs.codeFont) private var codeFont = FontChoice.mono
    @AppStorage(Prefs.readableWidth) private var readableWidth: ReadableWidth = .medium
    @AppStorage(Prefs.spellCheck) private var spellCheck = true
    @AppStorage(Prefs.editorMode) private var editorMode: EditorMode = .blocks
    @AppStorage(Prefs.tableWidth) private var tableWidth: TableWidth = .fit
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isSearchFocused: Bool

    private var editorStyle: EditorStyle {
        EditorStyle(
            theme: theme,
            isDark: colorScheme == .dark,
            noteFont: noteFont,
            noteFontSize: noteFontSize,
            lineSpacing: lineSpacing,
            codeFont: codeFont,
            readableWidth: readableWidth,
            spellCheck: spellCheck,
            tableWidth: tableWidth
        )
    }

    private var canvas: Color { Color(nsColor: editorStyle.palette.background) }

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 340)
        } detail: {
            detail
                .navigationTitle(state.selectedNote?.displayTitle ?? "Lotion")
                .navigationSubtitle(state.selectedNote.map { note in
                    note.isScratchpad ? (note.entryCount == 1 ? "1 entry" : "\(note.entryCount) entries") : note.folder ?? "Notes"
                } ?? "")
        }
        .searchable(text: $state.searchText, placement: .sidebar, prompt: "Search")
        .searchFocused($isSearchFocused)
        .onChange(of: state.searchFocusRequest) { isSearchFocused = true }
        .inspector(isPresented: $inspectorVisible) {
            // Keep the inspector's ideal size out of the split view's
            // constraint pass; its width belongs to the split view.
            GeometryReader { _ in
                InspectorView(state: state)
            }
            .inspectorColumnWidth(min: 240, ideal: 270, max: 360)
        }
        .toolbar { toolbar }
        .interfaceFont(interfaceFont)
        .frame(minWidth: 900, minHeight: 560)
        .alert(
            "Delete “\(state.folderPendingDelete ?? "")”?",
            isPresented: Binding(
                get: { state.folderPendingDelete != nil },
                set: { if !$0 { state.folderPendingDelete = nil } }
            )
        ) {
            Button("Move to Trash", role: .destructive) {
                if let folder = state.folderPendingDelete { state.deleteFolder(folder) }
            }
            Button("Cancel", role: .cancel) { state.folderPendingDelete = nil }
        } message: {
            let count = state.library.notes.filter { $0.folder == state.folderPendingDelete }.count
            Text("The folder and its \(count == 1 ? "note" : "\(count) notes") will move to the Trash.")
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { state.library.errorMessage != nil },
                set: { if !$0 { state.library.errorMessage = nil } }
            )
        ) {
            Button("OK") { state.library.errorMessage = nil }
        } message: {
            Text(state.library.errorMessage ?? "")
        }
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: SelfTest.openSettings)) { _ in SettingsWindowController.show() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.library.refreshFromDisk()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willResignActiveNotification)) { _ in
            state.library.saveAll()
        }
    }

    @ViewBuilder private var detail: some View {
        Group {
            if let note = state.selectedNote {
                if editorMode == .markdown {
                    MarkdownSourceEditor(note: note, style: editorStyle, library: state.library, controller: state.editor)
                } else {
                    NoteEditor(note: note, cover: state.library.cover(for: note), style: editorStyle,
                               library: state.library, controller: state.editor)
                        .overlay(alignment: .trailing) {
                            ScrollSpyView(spy: state.editor.scrollSpy, palette: editorStyle.palette)
                                .padding(.trailing, Space.s)
                        }
                }
            } else {
                EmptyStateView(
                    systemImage: "square.and.pencil",
                    title: state.library.notes.isEmpty ? "No Notes" : "No Note Selected",
                    message: state.library.notes.isEmpty
                        ? "Notes are Markdown files, kept in a folder you can open in Finder."
                        : "Choose a note in the sidebar, or start a new one."
                ) {
                    Button("New Note") { state.newNote() }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                }
                // No scroll view here, so keep the toolbar from drawing its own ground.
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            }
        }
        .background(canvas.ignoresSafeArea())
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Editor", selection: $editorMode) {
                Label("Blocks", systemImage: "text.document").tag(EditorMode.blocks)
                Label("Markdown", systemImage: "chevron.left.forwardslash.chevron.right").tag(EditorMode.markdown)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .disabled(state.selectedNote == nil)
            .help("Edit as blocks or as Markdown (⌃⌘M)")
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if let note = state.selectedNote {
                    NoteMenuItems(note: note, state: state)
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .disabled(state.selectedNote == nil)
            .help("More")
        }
        ToolbarItem(placement: .primaryAction) {
            Button { inspectorVisible.toggle() } label: {
                Label(inspectorVisible ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(inspectorVisible ? "Hide Inspector (⌥⌘I)" : "Show Inspector (⌥⌘I)")
        }
    }
}
