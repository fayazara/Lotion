//
//  HomeView.swift
//  Lotion
//
//  Where Lotion opens: a greeting, the notes you were last in, what's
//  pinned, the scratchpad's latest entry and the folders, all on the note
//  canvas in the theme's colors. Everything on it is a button, so it works
//  from the keyboard as well as the pointer.
//

import SwiftUI

struct HomeView: View {
    let state: AppState
    let palette: ThemePalette

    private var library: Library { state.library }

    private var ink: Color { Color(nsColor: palette.text) }
    private var heading: Color { Color(nsColor: palette.heading) }
    private var secondary: Color { Color(nsColor: palette.secondary) }

    /// Recently edited notes, newest first, without the empty ones.
    private var recent: [Note] {
        library.notes
            .filter { !$0.isBlank }
            .sorted { $0.modified > $1.modified }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 52) {
                header
                HomeTodayTasks(state: state, palette: palette) { title, symbol, content in
                    section(title, systemImage: symbol, content: content)
                }
                if library.notes.isEmpty {
                    emptyLibrary
                } else {
                    if !recent.isEmpty {
                        section("Jump back in", systemImage: "clock") {
                            cardRow(recent)
                        }
                    }
                    let pinned = library.pinnedNotes
                    if !pinned.isEmpty {
                        section("Pinned", systemImage: "pin") {
                            cardRow(pinned)
                        }
                    }
                }
                if let scratchpad = library.scratchpad {
                    section("Scratchpad", systemImage: "note.text") {
                        ScratchpadCard(note: scratchpad, palette: palette,
                                       open: { state.openScratchpad() },
                                       newEntry: { state.newScratchpadEntry() })
                    }
                }
                if !library.folders.isEmpty {
                    section("Folders", systemImage: "folder") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: Space.l)], alignment: .leading, spacing: Space.l) {
                            ForEach(library.folders, id: \.self) { folder in
                                FolderTile(folder: folder, icon: library.icon(for: folder),
                                           count: library.notes(in: folder).count, palette: palette) {
                                    openFolder(folder)
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.horizontal, 48)
            .padding(.top, 64)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            Text(Date.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .uiFont(.system(size: 12, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(secondary.opacity(0.8))
            Text(Self.greeting(for: .now))
                .uiFont(.system(size: 34, weight: .semibold))
                .foregroundStyle(heading)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Space.m) {
                QuickAction(title: "New Note", shortcut: "⌘N", systemImage: "square.and.pencil", palette: palette, isProminent: true) {
                    state.newNote(useSelection: false)
                }
                if library.scratchpad != nil {
                    QuickAction(title: "Scratchpad", shortcut: "⌘0", systemImage: "note.text", palette: palette) {
                        state.openScratchpad()
                    }
                }
                QuickAction(title: "Search", shortcut: "⌥⌘F", systemImage: "magnifyingglass", palette: palette) {
                    state.focusSearch()
                }
            }
            .padding(.top, Space.s)
        }
    }

    static func greeting(for date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Hello, night owl"
        }
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text("Nothing here yet")
                .uiFont(.system(size: 15, weight: .semibold))
                .foregroundStyle(ink)
            Text("Notes are Markdown files, kept in a folder you can open in Finder. Start one, and it shows up here.")
                .uiFont(.system(size: 13))
                .foregroundStyle(secondary)
        }
    }

    // MARK: Sections

    private func section<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> AnyView {
        AnyView(sectionBody(title, systemImage: systemImage, content: content))
    }

    private func sectionBody<Content: View>(_ title: String, systemImage: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            Label {
                Text(title)
            } icon: {
                // Today shows the date, as it does in the sidebar.
                if systemImage == TodayGlyph.symbol { TodayGlyph() } else { Image(icon: systemImage) }
            }
            .uiFont(.system(size: 12, weight: .semibold))
            .foregroundStyle(secondary)
            .labelStyle(SectionLabelStyle())
            .accessibilityAddTraits(.isHeader)
            content()
        }
    }

    private func cardRow(_ notes: [Note]) -> some View {
        NoteCardRow(notes: notes) { note in
            NoteCard(note: note, cover: library.cover(for: note), icon: library.icon(for: note),
                     library: library, palette: palette) {
                state.selection = note.id
            }
        }
    }

    private func openFolder(_ folder: String) {
        state.expandedFolders.insert(folder)
        if let first = library.notes(in: folder).first { state.selection = first.id }
    }
}

// MARK: - Pieces

/// Home's look at today: what's due and overdue, the first few of it. Its
/// own view, so a note's typing redraws only this part of Home.
private struct HomeTodayTasks: View {
    let state: AppState
    let palette: ThemePalette
    let section: (String, String, () -> AnyView) -> AnyView

    var body: some View {
        let today = state.library.tasks.today()
        let open = today.overdue + today.today
        if !open.isEmpty {
            let colors = TaskColors(palette: palette)
            section("Today", TodayGlyph.symbol) {
                AnyView(VStack(alignment: .leading, spacing: 0) {
                    let shown = Array(open.prefix(5))
                    ForEach(shown) { task in
                        TaskCompactRow(task: task, state: state, colors: colors, isLast: task.id == shown.last?.id && open.count <= 5)
                    }
                    if open.count > 5 {
                        Button { state.show(.today) } label: {
                            Text("\(open.count - 5) more in Today")
                                .uiFont(.system(size: 13))
                                .foregroundStyle(colors.secondary)
                                .padding(.leading, TaskCompactRow.textInset)
                                .frame(height: 36)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("All of today’s tasks (⌘1)")
                    }
                }
                // The rows' hover room hangs outside, so checkboxes line up with the section's icon.
                .padding(.horizontal, -10))
            }
        }
    }
}

/// A row of cards that scrolls sideways. Each edge fades only while there
/// are cards past it, so neither end of the row is ever cut off hard.
private struct NoteCardRow<Card: View>: View {
    let notes: [Note]
    @ViewBuilder let card: (Note) -> Card
    @State private var hidden = (leading: false, trailing: false)

    private static var fade: CGFloat { 36 }

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.l) {
                ForEach(notes) { note in card(note) }
            }
            // Room for the hover shadow, which a scroll view would clip.
            .padding(.vertical, Space.m)
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.never)
        .padding(.vertical, -Space.m)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.x > 1
        } action: { _, value in
            hidden.leading = value
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.x + geometry.containerSize.width < geometry.contentSize.width - 1
        } action: { _, value in
            hidden.trailing = value
        }
        .mask {
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                    .frame(width: hidden.leading ? Self.fade : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: hidden.trailing ? Self.fade : 0)
            }
            .animation(.easeOut(duration: 0.2), value: hidden.leading)
            .animation(.easeOut(duration: 0.2), value: hidden.trailing)
        }
    }
}

private struct SectionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Hover and press feedback shared by everything clickable on Home.
private struct HomeButtonStyle: ButtonStyle {
    let palette: ThemePalette
    var radius: CGFloat = 14
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color(nsColor: palette.text).opacity(palette.isDark ? 0.05 : 0.025))
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color(nsColor: palette.text).opacity(isHovered ? 0.14 : 0.08), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(isHovered ? (palette.isDark ? 0.35 : 0.08) : 0), radius: 12, y: 6)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.2), value: isHovered)
            .animation(.spring(duration: 0.18), value: configuration.isPressed)
            .onHover { isHovered = $0 }
    }
}

private struct QuickAction: View {
    let title: String
    let shortcut: String
    let systemImage: String
    let palette: ThemePalette
    var isProminent = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(icon: systemImage)
                    .imageScale(.small)
                Text(title)
                Text(shortcut)
                    .foregroundStyle(isProminent ? Color.white.opacity(0.7) : Color(nsColor: palette.secondary).opacity(0.7))
            }
            .uiFont(.system(size: 12, weight: .medium))
            .foregroundStyle(isProminent ? Color.white : Color(nsColor: palette.text))
            .padding(.horizontal, Space.l)
            .padding(.vertical, 7)
            .background {
                Capsule().fill(isProminent
                    ? Color(nsColor: palette.tint).opacity(isHovered ? 1 : 0.92)
                    : Color(nsColor: palette.text).opacity(isHovered ? 0.09 : 0.055))
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .help("\(title) (\(shortcut))")
    }
}

private struct NoteCard: View {
    let note: Note
    let cover: NoteCover?
    let icon: String?
    let library: Library
    let palette: ThemePalette
    let action: () -> Void

    private static let width: CGFloat = 200
    private static let band: CGFloat = 72

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .bottomLeading) {
                    CoverBand(cover: cover, library: library, palette: palette, seed: note.displayTitle,
                              size: CGSize(width: Self.width, height: Self.band))
                    IconGlyph(icon ?? NoteIcon.default)
                        .uiFont(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: palette.glyph ?? palette.secondary))
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Color(nsColor: palette.background)))
                        .overlay(Circle().strokeBorder(Color(nsColor: palette.text).opacity(0.08), lineWidth: 0.5))
                        .offset(x: 14, y: 15)
                }
                .zIndex(1)
                VStack(alignment: .leading, spacing: 6) {
                    Text(note.displayTitle)
                        .uiFont(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(nsColor: palette.text).opacity(note.title.isEmpty ? 0.5 : 1))
                        .lineSpacing(2)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let preview = Self.preview(of: note.text) {
                        Text(preview)
                            .uiFont(.system(size: 12))
                            .foregroundStyle(Color(nsColor: palette.secondary))
                            .lineSpacing(3.5)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: Space.s)
                    HStack(spacing: Space.xs) {
                        Text(note.modified.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                        if let folder = note.folder {
                            Text("·")
                            Text(folder).lineLimit(1)
                        }
                    }
                    .uiFont(.system(size: 11))
                    .foregroundStyle(Color(nsColor: palette.secondary).opacity(0.75))
                }
                .padding(.horizontal, 16)
                .padding(.top, 28)
                .padding(.bottom, 16)
                .frame(width: Self.width, height: 158, alignment: .topLeading)
            }
        }
        .buttonStyle(HomeButtonStyle(palette: palette))
        .accessibilityLabel(note.displayTitle)
        .accessibilityHint("Opens the note")
    }

    /// The first few words after the title, without Markdown's marks.
    static func preview(of text: String) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = lines.first, first.hasPrefix("#") { lines.removeFirst() }
        var words: [String] = []
        var length = 0
        var inFence = false
        for line in lines {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || line.hasPrefix("<") || line.hasPrefix("|") || line.hasPrefix("![") || line.hasPrefix("---") { continue }
            var clean = line
            for prefix in ["- [ ] ", "- [x] ", "- ", "* ", "> ", "#### ", "### ", "## ", "# "] where clean.hasPrefix(prefix) {
                clean = String(clean.dropFirst(prefix.count))
                break
            }
            // A task reads as its words, without its date, priority or tags.
            if TaskSyntax.line(line) != nil { clean = TaskSyntax.metadata(in: clean).title }
            clean = clean.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
                .replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
            guard !clean.isEmpty else { continue }
            words.append(clean)
            length += clean.count
            if length > 120 { break }
        }
        let joined = words.joined(separator: " ")
        return joined.isEmpty ? nil : joined
    }
}

/// A card's top: the note's cover, or a soft wash in the theme's accent.
private struct CoverBand: View {
    let cover: NoteCover?
    let library: Library
    let palette: ThemePalette
    let seed: String
    let size: CGSize
    @State private var image: NSImage?

    var body: some View {
        // A fixed frame first, then the photo fills it: the photo's own size
        // never reaches the card's layout.
        Color.clear
            .frame(width: size.width, height: size.height)
            .overlay { fill }
            .clipped()
            .accessibilityHidden(true)
            .task(id: cover?.file) {
                guard let cover else { image = nil; return }
                let url = cover.url(in: library)
                if let cached = CoverImages.cached(url, maxPixels: 600) { image = cached; return }
                CoverImages.load(url, maxPixels: 600) { loaded in image = loaded }
            }
    }

    @ViewBuilder private var fill: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size.width, height: size.height)
            } else {
                let accent = Color(nsColor: palette.tint)
                // Each note gets its own angle, so a row of plain cards isn't uniform.
                let turn = Double(abs(seed.hashValue % 360))
                LinearGradient(colors: [accent.opacity(palette.isDark ? 0.22 : 0.14), accent.opacity(0.03)],
                               startPoint: UnitPoint(x: 0.5 + cos(turn) * 0.5, y: 0.5 + sin(turn) * 0.5),
                               endPoint: UnitPoint(x: 0.5 - cos(turn) * 0.5, y: 0.5 - sin(turn) * 0.5))
            }
        }
    }
}

private struct ScratchpadCard: View {
    let note: Note
    let palette: ThemePalette
    let open: () -> Void
    let newEntry: () -> Void

    /// The latest entry: when it started and its first lines.
    private var latest: (label: String, text: String)? {
        guard let range = note.text.range(of: BlockMarkdown.entryPrefix, options: .backwards) else { return nil }
        let rest = note.text[range.upperBound...]
        let marker = rest.prefix { $0 != "\n" }
        let iso = marker.replacingOccurrences(of: "-->", with: "").trimmingCharacters(in: .whitespaces)
        let body = rest.dropFirst(marker.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return (EntryBreakView.label(for: iso), NoteCard.preview(of: body) ?? "")
    }

    var body: some View {
        HStack(alignment: .top, spacing: Space.xl) {
            Button(action: open) {
                VStack(alignment: .leading, spacing: 10) {
                    if let latest {
                        Text(latest.label)
                            .uiFont(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(nsColor: palette.secondary).opacity(0.8))
                        Text(latest.text.isEmpty ? "An empty page, waiting." : latest.text)
                            .uiFont(.system(size: 13))
                            .foregroundStyle(Color(nsColor: palette.text).opacity(latest.text.isEmpty ? 0.5 : 0.9))
                            .lineSpacing(5)
                            .lineLimit(3)
                            .multilineTextAlignment(.leading)
                    }
                    Text(note.entryCount == 1 ? "1 entry" : "\(note.entryCount) entries")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(Color(nsColor: palette.secondary).opacity(0.75))
                        .padding(.top, Space.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
            }
            .buttonStyle(HomeButtonStyle(palette: palette))
            .accessibilityLabel("Scratchpad")
            .accessibilityHint("Opens the scratchpad")

            Button(action: newEntry) {
                VStack(spacing: Space.s) {
                    Image(icon: "plus")
                        .uiFont(.system(size: 16, weight: .medium))
                    Text("New Entry")
                        .uiFont(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color(nsColor: palette.tint))
                .frame(width: 112)
                .frame(maxHeight: .infinity)
            }
            .buttonStyle(HomeButtonStyle(palette: palette))
            .help("Start a new scratchpad entry")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct FolderTile: View {
    let folder: String
    let icon: String
    let count: Int
    let palette: ThemePalette
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.l) {
                IconGlyph(icon)
                    .uiFont(.system(size: 15))
                    .foregroundStyle(Color(nsColor: palette.tint).opacity(0.85))
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 3) {
                    Text(folder)
                        .uiFont(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color(nsColor: palette.text))
                        .lineLimit(1)
                    Text(count == 1 ? "1 note" : "\(count) notes")
                        .uiFont(.system(size: 11))
                        .foregroundStyle(Color(nsColor: palette.secondary))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 15)
        }
        .buttonStyle(HomeButtonStyle(palette: palette, radius: 12))
        .accessibilityLabel("\(folder), \(count == 1 ? "1 note" : "\(count) notes")")
    }
}

private extension ThemePalette {
    /// Home's color: the same as the sidebar's glyphs, or the accent for a
    /// theme without a color of its own.
    var tint: NSColor { glyph ?? accent }
}
