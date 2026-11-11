//
//  SidebarView.swift
//  Lotion
//
//  Pinned notes, folders (each a disclosure of its notes) and the notes at
//  the top of the library. While searching, a flat list of matches with a
//  line of context. Rows follow Screendrop's sidebar: a quiet, filled grey
//  glyph in a 20 pt column, 12 pt from the title, count on the right.
//

import SwiftUI
import UniformTypeIdentifiers

struct SidebarView: View {
    @Bindable var state: AppState

    private static let fade: CGFloat = 28
    private var library: Library { state.library }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $state.selection) {
                if state.isSearching {
                    searchResults
                } else {
                    sections
                }
            }
            .listStyle(.sidebar)
            // Rows bring their own menus; this one is for the empty space and headers.
            .contextMenu {
                Button("New Note") { state.newNote(useSelection: false) }
                Button("New Folder") { state.newFolder() }
            }
            // Search results and the library are different lists; sharing
            // one outline lets stale result rows linger after a search.
            .id(state.isSearching)
            // A long list fades out above the footer rather than ending at a
            // hard edge; the margin lets the last row scroll clear of it.
            .contentMargins(.bottom, Self.fade, for: .scrollContent)
            .mask {
                VStack(spacing: 0) {
                    Rectangle()
                    LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                        .frame(height: Self.fade)
                }
            }
            .onDeleteCommand {
                if let note = state.selectedNote, !note.isScratchpad { state.delete(note) }
            }
            SidebarFooter()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { state.newNote() } label: {
                    Label("New Note", systemImage: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
    }

    // MARK: Library

    @ViewBuilder private var sections: some View {
        if let scratchpad = library.scratchpad {
            Section {
                SidebarRow(title: "Scratchpad", count: scratchpad.entryCount) {
                    Image(systemName: "note.text")
                }
                .tag(scratchpad.id)
                .help("An endless page for quick notes. ⌘↩ starts a new entry.")
                .contextMenu {
                    Button("New Entry", systemImage: "plus") { state.newScratchpadEntry() }
                    Divider()
                    NoteMenuItems(note: scratchpad, state: state)
                }
            }
        }

        let pinned = library.pinnedNotes
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned) { note in
                    NoteRow(note: note, state: state, systemImage: "pin")
                }
            }
        }

        if !library.folders.isEmpty {
            Section("Folders") {
                ForEach(library.folders, id: \.self) { folder in
                    FolderRow(folder: folder, state: state)
                }
            }
        }

        Section {
            let notes = library.notes(in: nil)
            ForEach(notes) { note in
                NoteRow(note: note, state: state)
            }
        } header: {
            Text("Notes")
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { items, _ in
                    state.move(items: items, to: nil)
                }
        }
    }

    // MARK: Search

    @ViewBuilder private var searchResults: some View {
        let results = library.search(state.searchText)
        if results.isEmpty {
            Text("No notes match “\(state.searchText.trimmingCharacters(in: .whitespaces))”.")
                .font(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
                .padding(.vertical, Space.s)
                .selectionDisabled()
        } else {
            Section(results.count == 1 ? "1 Note" : "\(results.count) Notes") {
                ForEach(results) { result in
                    SearchResultRow(result: result)
                        .tag(result.note.id)
                        .noteContextMenu(result.note, state: state)
                }
            }
        }
    }
}

// MARK: - Rows

/// Screendrop's sidebar row: glyph, title, optional count.
struct SidebarRow<Icon: View>: View {
    let title: String
    var isPlaceholder = false
    var count: Int?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        // Not a Label: the sidebar tints Label icons with the system accent.
        // These take the theme's accent instead (or a quiet grey for themes
        // without one), with room between glyph and title.
        HStack(spacing: 12) {
            icon()
                .symbolVariant(.fill)
                .sidebarGlyphTint()
                .frame(width: 20, alignment: .center)
            Text(title)
                .lineLimit(1)
                .foregroundStyle(isPlaceholder ? .secondary : .primary)
            Spacer(minLength: 8)
            if let count {
                Text(count, format: .number)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}

private struct NoteRow: View {
    let note: Note
    let state: AppState
    /// Shown when the note has no icon of its own.
    var systemImage = NoteIcon.default
    @State private var isPickingIcon = false

    var body: some View {
        SidebarRow(title: note.displayTitle, isPlaceholder: note.title.isEmpty) {
            Image(systemName: state.library.icon(for: note) ?? systemImage)
        }
        .tag(note.id)
        .draggable(note.id.uuidString)
        .popover(isPresented: $isPickingIcon, arrowEdge: .trailing) {
            IconPicker(current: state.library.icon(for: note) ?? NoteIcon.default) { state.library.setIcon($0, for: note) }
        }
        .noteContextMenu(note, state: state) { isPickingIcon = true }
    }
}

private struct FolderRow: View {
    let folder: String
    @Bindable var state: AppState
    @State private var isPickingIcon = false

    private var isExpanded: Binding<Bool> {
        Binding(
            get: { state.expandedFolders.contains(folder) },
            set: { expanded in
                if expanded { state.expandedFolders.insert(folder) } else { state.expandedFolders.remove(folder) }
            }
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: isExpanded) {
            ForEach(state.library.notes(in: folder)) { note in
                // The sidebar indents a folder's rows a full level, which
                // reads as too far; keep half of it so the notes still sit
                // visibly inside the folder.
                NoteRow(note: note, state: state)
                    .padding(.leading, -6)
            }
        } label: {
            Group {
                if state.renamingFolder == folder {
                    FolderNameField(name: folder) { state.renameFolder(folder, to: $0) }
                } else {
                    SidebarRow(title: folder, count: state.library.count(in: folder)) {
                        Image(systemName: state.library.icon(for: folder))
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { isExpanded.wrappedValue.toggle() }
                    .popover(isPresented: $isPickingIcon, arrowEdge: .trailing) {
                        IconPicker(current: state.library.icon(for: folder)) { state.library.setIcon($0, for: folder) }
                    }
                }
            }
            .dropDestination(for: String.self) { items, _ in
                state.move(items: items, to: folder)
            }
            .contextMenu {
                Button("New Note") { state.newNote(inFolder: folder) }
                Divider()
                Button("Rename…") { state.renamingFolder = folder }
                Button("Change Icon…") { isPickingIcon = true }
                if state.library.icon(for: folder) != "folder" {
                    Button("Default Icon") { state.library.setIcon(nil, for: folder) }
                }
                Button("Show in Finder") { state.showInFinder(folder: folder) }
                Divider()
                Button("Delete Folder…", role: .destructive) { state.requestDelete(folder: folder) }
            }
        }
    }
}

/// Edits a folder's name in place: Return or clicking away commits, Escape keeps the old name.
private struct FolderNameField: View {
    let name: String
    let commit: (String) -> Void
    @State private var text = ""
    @State private var didFinish = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .sidebarGlyphTint()
                .frame(width: 20, alignment: .center)
            TextField("Folder Name", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { finish(text) }
                .onExitCommand { finish(name) }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .onAppear {
            text = name
            DispatchQueue.main.async { isFocused = true }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { finish(text) }
        }
    }

    private func finish(_ value: String) {
        guard !didFinish else { return }
        didFinish = true
        commit(value)
    }
}

private struct SearchResultRow: View {
    let result: SearchResult

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: "doc.text")
                .symbolVariant(.fill)
                .sidebarGlyphTint()
                .frame(width: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                Text(result.note.displayTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

// MARK: - Glyph Tint

/// Colors sidebar glyphs with the heading color of the theme picked in Settings,
/// on the side (light or dark) in use, so they match the note. Themes with
/// plain headings fall back to the accent; themes that leave the accent to the
/// system keep the sidebar's quiet grey rather than going system blue.
private struct SidebarGlyphTint: ViewModifier {
    @AppStorage(Prefs.theme) private var theme: LotionTheme = .paper
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let isDark = colorScheme == .dark
        let spec = isDark ? theme.dark ?? theme.light : theme.light ?? theme.dark
        if let spec, let heading = spec.heading, heading != spec.text {
            content.foregroundStyle(Color(nsColor: theme.palette(dark: isDark).heading))
        } else if spec?.accent != nil {
            content.foregroundStyle(Color(nsColor: theme.palette(dark: isDark).accent))
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

private extension View {
    func sidebarGlyphTint() -> some View { modifier(SidebarGlyphTint()) }
}

// MARK: - Footer

/// Settings, at the foot of the sidebar.
private struct SidebarFooter: View {
    @State private var isHovering = false

    var body: some View {
        Button { SettingsWindowController.show() } label: {
            HStack(spacing: 8) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 20)
                Text("Settings")
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Palette.label)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                isHovering ? Palette.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Settings (⌘,)")
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }
}

// MARK: - Menus

extension View {
    func noteContextMenu(_ note: Note, state: AppState, changeIcon: (() -> Void)? = nil) -> some View {
        contextMenu {
            NoteMenuItems(note: note, state: state, changeIcon: changeIcon)
        }
    }
}

/// The actions on a note, shared by the sidebar's context menu and the toolbar.
struct NoteMenuItems: View {
    let note: Note
    let state: AppState
    /// Offered where there is a row to show the picker beside.
    var changeIcon: (() -> Void)?

    var body: some View {
        if note.isScratchpad {
            Button("Copy Markdown", systemImage: "doc.on.doc") { state.copyMarkdown(note) }
            Button("Export as Markdown…", systemImage: "square.and.arrow.up") { state.exportMarkdown(note) }
            Button("Show in Finder", systemImage: "finder") { state.showInFinder(note) }
        } else {
            items
        }
    }

    @ViewBuilder private var items: some View {
        Button(state.library.isPinned(note) ? "Unpin" : "Pin", systemImage: state.library.isPinned(note) ? "pin.slash" : "pin") {
            state.togglePin(note)
        }
        Menu("Move To", systemImage: "folder") {
            Button("Notes") { state.move(note, to: nil) }
                .disabled(note.folder == nil)
            if !state.library.folders.isEmpty {
                Divider()
                ForEach(state.library.folders, id: \.self) { folder in
                    Button(folder) { state.move(note, to: folder) }
                        .disabled(note.folder == folder)
                }
            }
        }
        if let changeIcon {
            Button("Change Icon…", systemImage: "face.smiling") { changeIcon() }
            if state.library.icon(for: note) != nil {
                Button("Default Icon", systemImage: NoteIcon.default) { state.library.setIcon(nil, for: note) }
            }
        }
        if state.library.cover(for: note) == nil {
            Button("Add Cover", systemImage: "photo") { state.library.addRandomCover(for: note) }
        } else {
            Button("Remove Cover", systemImage: "photo.badge.minus") { state.library.setCover(nil, for: note) }
        }
        Divider()
        Button("Copy Markdown", systemImage: "doc.on.doc") { state.copyMarkdown(note) }
        Button("Export as Markdown…", systemImage: "square.and.arrow.up") { state.exportMarkdown(note) }
        Button("Show in Finder", systemImage: "finder") { state.showInFinder(note) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { state.delete(note) }
    }
}

extension AppState {
    /// Drops of note ids dragged from the sidebar.
    @discardableResult
    func move(items: [String], to folder: String?) -> Bool {
        let notes = items.compactMap { UUID(uuidString: $0) }.compactMap { library.note(id: $0) }
        guard !notes.isEmpty else { return false }
        for note in notes { move(note, to: folder) }
        return true
    }
}
