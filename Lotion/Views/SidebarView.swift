//
//  SidebarView.swift
//  Lotion
//
//  Pinned notes, folders (each a disclosure of its notes) and the notes at
//  the top of the library. While searching, a flat list of matches with a
//  line of context. Rows follow Screendrop's sidebar: a quiet, filled grey
//  glyph in a 20 pt column, 12 pt from the title, count on the right.
//

import Combine
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
            // Like Screendrop's, the list never holds keyboard focus, so the
            // selection stays the quiet grey rather than the focused accent.
            // ⌘1–3, ⇧⌘H and search still move around it.
            .focusable(false)
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
                    Label("New Note", icon: "square.and.pencil")
                }
                .help("New Note (⌘N)")
            }
        }
    }

    // MARK: Library

    @ViewBuilder private var sections: some View {
        // Home and the scratchpad sit together, as the places that aren't notes in a list.
        Section {
            SidebarRow(title: "Home") {
                Image(icon: "house")
            }
            .tag(AppState.homeID)
            .help("Recent notes, the scratchpad and folders (⇧⌘H)")
            TaskListRow(list: .today, state: state)
            TaskListRow(list: .upcoming, state: state)
            TaskListRow(list: .inbox, state: state)
            if let scratchpad = library.scratchpad {
                SidebarRow(title: "Scratchpad", count: scratchpad.entryCount) {
                    Image(icon: "note.text")
                }
                .tag(scratchpad.id)
                .help("An endless page for quick notes. ⌘↩ starts a new entry.")
                .contextMenu {
                    Button("New Entry", icon: "plus") { state.newScratchpadEntry() }
                    Divider()
                    NoteMenuItems(note: scratchpad, state: state)
                }
            }
        }

        let pinned = library.pinnedNotes
        if !pinned.isEmpty {
            Section {
                ForEach(pinned) { note in
                    NoteRow(note: note, state: state, systemImage: "pin")
                }
            } header: {
                SidebarHeader("Pinned")
            }
        }

        if !library.folders.isEmpty {
            Section {
                ForEach(library.folders, id: \.self) { folder in
                    FolderRow(folder: folder, state: state)
                }
            } header: {
                SidebarHeader("Folders")
            }
        }

        Section {
            let notes = library.notes(in: nil)
            ForEach(notes) { note in
                NoteRow(note: note, state: state)
            }
        } header: {
            SidebarHeader("Notes")
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
                .uiFont(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
                .padding(.vertical, Space.s)
                .selectionDisabled()
        } else {
            Section {
                ForEach(results) { result in
                    SearchResultRow(result: result)
                        .tag(result.note.id)
                        .noteContextMenu(result.note, state: state)
                }
            } header: {
                SidebarHeader(results.count == 1 ? "1 Note" : "\(results.count) Notes")
            }
        }
    }
}

// MARK: - Rows

/// One left edge for the whole sidebar: glyphs sit flush at the start of
/// their column, and section headers are indented to line up with them.
enum SidebarMetrics {
    static let glyphColumn: CGFloat = 20
    /// Hugeicons are outlines; at this size they carry the weight Screendrop's
    /// filled SF Symbols do at the sidebar's own.
    static let glyphSize: CGFloat = 16
    static let glyphSpacing: CGFloat = 12
    /// How far the list's own header inset sits left of a row's content.
    static let headerIndent: CGFloat = 11
}

/// A section header that starts where the rows' glyphs do.
struct SidebarHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).padding(.leading, SidebarMetrics.headerIndent)
    }
}

/// A sidebar row: glyph, title, optional count.
struct SidebarRow<Icon: View>: View {
    let title: String
    var isPlaceholder = false
    var count: Int?
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        // Not a Label: the sidebar tints Label icons with the system accent.
        // These take the theme's accent instead (or a quiet grey for themes
        // without one), with room between glyph and title.
        HStack(spacing: SidebarMetrics.glyphSpacing) {
            icon()
                .sidebarGlyph()
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
        .padding(.trailing, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Today, Upcoming and Inbox. Each counts its own tasks, so typing in a
/// note redraws only these rows, not the whole sidebar.
private struct TaskListRow: View {
    let list: AppState.Page
    let state: AppState
    @State private var isTargeted = false

    var body: some View {
        let index = state.library.tasks
        let (title, symbol, tag, help, count): (String, String, UUID, String, Int?) = switch list {
        case .today: ("Today", TodayGlyph.symbol, AppState.todayID, "Tasks due today and overdue (⌘1)", index.todayCount)
        case .upcoming: ("Upcoming", "calendar", AppState.upcomingID, "Tasks with a date, by day (⌘2)", nil)
        default: ("Inbox", "tray", AppState.inboxID, "Tasks from Quick Add, waiting for a date (⌘3)", index.inboxTasks().count)
        }
        SidebarRow(title: title, count: count == 0 ? nil : count) {
            if list == .today { TodayGlyph() } else { Image(icon: symbol) }
        }
        .tag(tag)
        .help(help)
        .listRowBackground(isTargeted ? RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18)).padding(.horizontal, 10) : nil)
        // Drop a task here to give it today, or take its date away in the inbox.
        .dropDestination(for: String.self) { items, _ in
            let tasks = items.compactMap(TaskDrag.id(from:)).compactMap { index.task(id: $0) }
            for task in tasks {
                switch list {
                case .today: index.move(task, to: .now)
                case .inbox: index.setDue(task, nil)
                default: return false
                }
            }
            return !tasks.isEmpty
        } isTargeted: { isTargeted = $0 && list != .upcoming }
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
            IconGlyph(state.library.icon(for: note) ?? systemImage)
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
                        IconGlyph(state.library.icon(for: folder))
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
        HStack(spacing: SidebarMetrics.glyphSpacing) {
            Image(icon: "folder.fill")
                .sidebarGlyph()
            TextField("Folder Name", text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { finish(text) }
                .onExitCommand { finish(name) }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 2)
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
        HStack(alignment: .firstTextBaseline, spacing: SidebarMetrics.glyphSpacing) {
            Image(icon: "doc.text")
                .sidebarGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text(result.note.displayTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !result.snippet.isEmpty {
                    Text(result.snippet)
                        .uiFont(.dsCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.trailing, 2)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}

// MARK: - Today Glyph

/// Today's glyph: an empty calendar page with the day of the month written
/// on it, turned over at midnight.
/// Today's icon: a calendar page showing the date. Used by the sidebar and Home.
struct TodayGlyph: View {
    @State private var day = Self.today

    private static var today: String { String(format: "%02d", Calendar.current.component(.day, from: .now)) }

    /// Stands for this glyph wherever an icon is named, as on Home.
    static let symbol = "calendar.today"

    var body: some View {
        Image(icon: Self.symbol)
            .overlay {
                // The page below the calendar's header line, in the icon's
                // 24-unit grid: the shell runs 2–22, the header sits at 10.
                GeometryReader { geometry in
                    let unit = geometry.size.height / 21
                    Text(day)
                        .font(.system(size: unit * 7.2, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .tracking(-0.3)
                        .fixedSize()
                        .position(x: geometry.size.width / 2, y: unit * 14.25)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
                day = Self.today
            }
            .accessibilityLabel("Today, \(Date.now.formatted(date: .complete, time: .omitted))")
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
        if let glyph = theme.palette(dark: colorScheme == .dark).glyph {
            content.foregroundStyle(Color(nsColor: glyph))
        } else {
            content.foregroundStyle(.secondary)
        }
    }
}

private extension View {
    /// A row's glyph: tinted, sized and centred in the glyph column.
    func sidebarGlyph() -> some View {
        modifier(SidebarGlyphTint())
            .uiFont(.system(size: SidebarMetrics.glyphSize))
            .frame(width: SidebarMetrics.glyphColumn, alignment: .center)
    }
}

// MARK: - Footer

/// Settings, at the foot of the sidebar.
private struct SidebarFooter: View {
    @State private var isHovering = false

    var body: some View {
        Button { SettingsWindowController.show() } label: {
            HStack(spacing: 8) {
                Image(icon: "gearshape.fill")
                    .uiFont(.system(size: 15))
                    .frame(width: 20)
                Text("Settings")
                    .uiFont(.system(size: 13))
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
            Button("Copy Markdown", icon: "doc.on.doc") { state.copyMarkdown(note) }
            Button("Export as Markdown…", icon: "square.and.arrow.up") { state.exportMarkdown(note) }
            Button("Show in Finder", icon: "finder") { state.showInFinder(note) }
        } else {
            items
        }
    }

    @ViewBuilder private var items: some View {
        Button(state.library.isPinned(note) ? "Unpin" : "Pin", icon: state.library.isPinned(note) ? "pin.slash" : "pin") {
            state.togglePin(note)
        }
        Menu("Move To", icon: "folder") {
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
            Button("Change Icon…", icon: "face.smiling") { changeIcon() }
            if state.library.icon(for: note) != nil {
                Button("Default Icon", icon: NoteIcon.default) { state.library.setIcon(nil, for: note) }
            }
        }
        if state.library.cover(for: note) == nil {
            Button("Add Cover", icon: "photo") { state.library.addRandomCover(for: note) }
        } else {
            Button("Remove Cover", icon: "photo.badge.minus") { state.library.setCover(nil, for: note) }
        }
        Divider()
        Button("Copy Markdown", icon: "doc.on.doc") { state.copyMarkdown(note) }
        Button("Export as Markdown…", icon: "square.and.arrow.up") { state.exportMarkdown(note) }
        Button("Show in Finder", icon: "finder") { state.showInFinder(note) }
        Divider()
        Button("Move to Trash", icon: "trash", role: .destructive) { state.delete(note) }
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
