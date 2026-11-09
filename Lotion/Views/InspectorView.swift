//
//  InspectorView.swift
//  Lotion
//
//  About the open note, in collapsible sections: when it was made and
//  edited and where it lives, an outline of its headings (click to jump),
//  the things you can do with it, and its counts.
//

import SwiftUI

struct InspectorView: View {
    let state: AppState

    var body: some View {
        if let note = state.selectedNote {
            NoteInspector(note: note, state: state)
        } else {
            Text("No Note Selected")
                .font(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NoteInspector: View {
    let note: Note
    let state: AppState

    var body: some View {
        // A scratchpad's entry lines are bookkeeping, not words.
        let stats = NoteStats(note.isScratchpad
            ? note.text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.hasPrefix(BlockMarkdown.entryPrefix) }.joined(separator: "\n")
            : note.text)
        let outline = NoteOutline.headings(in: note.text)
        let isPinned = state.library.isPinned(note)

        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                InspectorSection("Properties", key: "properties", isFirst: true) {
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        VStack(alignment: .leading, spacing: Space.l) {
                            PropertyRow(symbol: "calendar", label: "Created", value: note.created.relativeDescription,
                                        help: note.created.formatted(date: .complete, time: .shortened))
                            PropertyRow(symbol: "clock.arrow.circlepath", label: "Updated", value: note.modified.relativeDescription,
                                        help: note.modified.formatted(date: .complete, time: .shortened))
                            if note.isScratchpad {
                                PropertyRow(symbol: "square.stack", label: "Entries", value: note.entryCount.formatted(), help: "⌘↩ starts a new entry")
                            } else {
                                PropertyRow(symbol: "doc", label: "File", value: note.fileName, help: note.url.path)
                            }
                        }
                    }
                }

                if !outline.isEmpty {
                    InspectorSection("Outline", key: "outline") {
                        VStack(alignment: .leading, spacing: 0) {
                            let minimum = outline.map(\.level).min() ?? 1
                            ForEach(Array(outline.enumerated()), id: \.element.id) { index, heading in
                                OutlineRow(heading: heading, minimumLevel: minimum, showsRule: index < outline.count - 1) {
                                    state.editor.revealHeading(heading.id, in: note)
                                }
                            }
                        }
                    }
                }

                InspectorSection("Actions", key: "actions") {
                    VStack(spacing: Space.s) {
                        if note.isScratchpad {
                            ActionButton("New Entry", symbol: "plus") { state.newScratchpadEntry() }
                            ActionButton("Copy Markdown", symbol: "doc.on.doc") { state.copyMarkdown(note) }
                            ActionButton("Show in Finder", symbol: "folder") { state.showInFinder(note) }
                        } else {
                            ActionButton(isPinned ? "Unpin Note" : "Pin Note", symbol: isPinned ? "pin.slash" : "pin") {
                                state.togglePin(note)
                            }
                            Menu {
                                Button("Notes") { state.move(note, to: nil) }
                                    .disabled(note.folder == nil)
                                if !state.library.folders.isEmpty {
                                    Divider()
                                    ForEach(state.library.folders, id: \.self) { folder in
                                        Button(folder) { state.move(note, to: folder) }
                                            .disabled(note.folder == folder)
                                    }
                                }
                            } label: {
                                ActionLabel(title: "Move to…", symbol: "arrowshape.turn.up.right")
                            }
                            .menuStyle(.button)
                            .buttonStyle(ActionButtonStyle())
                            .menuIndicator(.hidden)
                            ActionButton("Copy Markdown", symbol: "doc.on.doc") { state.copyMarkdown(note) }
                            ActionButton("Show in Finder", symbol: "folder") { state.showInFinder(note) }
                            ActionButton("Move to Trash", symbol: "trash", role: .destructive) { state.delete(note) }
                        }
                    }
                }

                if !note.isScratchpad {
                    InspectorSection("Location", key: "location") {
                        Button { state.showInFinder(note) } label: {
                            HStack(spacing: Space.m) {
                                Image(systemName: note.folder.map { state.library.icon(for: $0) } ?? "tray")
                                    .font(.system(size: 14))
                                    .foregroundStyle(Palette.secondaryLabel)
                                    .frame(width: 20)
                                Text(note.folder ?? "Notes")
                                    .font(.dsBody)
                                    .foregroundStyle(Palette.label)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show in Finder")
                    }
                }

                InspectorSection("Stats", key: "stats", showsRule: false) {
                    VStack(spacing: 0) {
                        StatRow(label: "Words", value: stats.words.formatted())
                        StatRow(label: "Characters", value: stats.characters.formatted())
                        StatRow(label: "Reading Time", value: "\(stats.readingMinutes) min")
                        StatRow(label: "Headings", value: outline.count.formatted())
                        StatRow(label: "Media", value: stats.media.formatted(), showsRule: false)
                    }
                }
            }
            .padding(.horizontal, Space.xl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Sections

/// A titled group that folds away; whether it is open is remembered.
private struct InspectorSection<Content: View>: View {
    let title: String
    let isFirst: Bool
    let showsRule: Bool
    @ViewBuilder let content: () -> Content
    @AppStorage private var isCollapsed: Bool
    @State private var isHovering = false

    init(_ title: String, key: String, isFirst: Bool = false, showsRule: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.isFirst = isFirst
        self.showsRule = showsRule
        self.content = content
        _isCollapsed = AppStorage(wrappedValue: false, "inspector.collapsed.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.smooth(duration: 0.25)) { isCollapsed.toggle() }
            } label: {
                HStack {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Palette.tertiaryLabel)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isHovering ? Palette.secondaryLabel : Palette.tertiaryLabel)
                        .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                }
                .padding(.top, isFirst ? Space.l : Space.xl)
                .padding(.bottom, isCollapsed ? Space.xl : Space.l)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel(title)
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")

            if !isCollapsed {
                content()
                    .padding(.bottom, Space.xl)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }

            if showsRule {
                Rectangle().fill(Palette.hairline).frame(height: 0.5)
            }
        }
        .clipped()
    }
}

// MARK: - Rows

private struct PropertyRow: View {
    let symbol: String
    let label: String
    let value: String
    let help: String

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 20)
            (Text("\(label):  ").foregroundStyle(Palette.secondaryLabel) + Text(value).foregroundStyle(Palette.label))
                .font(.dsBody)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help)
    }
}

private struct OutlineRow: View {
    let heading: NoteOutline.Heading
    let minimumLevel: Int
    let showsRule: Bool
    let action: () -> Void
    @State private var isHovering = false

    private var depth: Int { heading.level - minimumLevel }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.m) {
                Circle()
                    .strokeBorder(depth == 0 ? Palette.secondaryLabel : Palette.tertiaryLabel, lineWidth: 1)
                    .frame(width: depth == 0 ? 8 : 6, height: depth == 0 ? 8 : 6)
                    .frame(width: 20)
                Text(heading.title.isEmpty ? "Untitled" : heading.title)
                    .font(depth == 0 ? .system(size: 13, weight: .medium) : .dsBody)
                    .foregroundStyle(depth == 0 ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .overlay(alignment: .bottom) {
                if showsRule {
                    Rectangle().fill(Palette.hairline)
                        .frame(height: 0.5)
                        .padding(.leading, 28 + CGFloat(depth) * 14)
                }
            }
            .background(
                isHovering ? Palette.hoverFill : .clear,
                in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous).inset(by: -1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

private struct ActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 20)
            Text(title)
                .font(.dsBody)
            Spacer(minLength: 0)
        }
    }
}

private struct ActionButton: View {
    let title: String
    let symbol: String
    let role: ButtonRole?
    let action: () -> Void

    init(_ title: String, symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            ActionLabel(title: title, symbol: symbol)
        }
        .buttonStyle(ActionButtonStyle(isDestructive: role == .destructive))
    }
}

/// A full-width tinted row that darkens under the pointer and sinks when pressed.
private struct ActionButtonStyle: ButtonStyle {
    var isDestructive = false

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, isDestructive: isDestructive)
    }

    private struct ActionButtonBody: View {
        let configuration: Configuration
        let isDestructive: Bool
        @State private var isHovering = false

        var body: some View {
            let tint = isDestructive ? Color.red : Color.primary
            configuration.label
                .foregroundStyle(isDestructive ? Color.red.opacity(0.9) : Palette.label)
                .padding(.horizontal, Space.m)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(
                    tint.opacity(isDestructive ? (isHovering ? 0.13 : 0.08) : (isHovering ? 0.08 : 0.045)),
                    in: RoundedRectangle(cornerRadius: Radius.field + 2, style: .continuous)
                )
                .contentShape(Rectangle())
                .scaleEffect(configuration.isPressed ? 0.98 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.15), value: isHovering)
                .onHover { isHovering = $0 }
        }
    }
}

private struct StatRow: View {
    let label: String
    let value: String
    var showsRule = true

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(Palette.secondaryLabel)
            Spacer()
            Text(value)
                .foregroundStyle(Palette.label)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .font(.dsBody)
        .padding(.horizontal, Space.xs)
        .frame(minHeight: 32)
        .overlay(alignment: .bottom) {
            if showsRule { Rectangle().fill(Palette.hairline).frame(height: 0.5) }
        }
    }
}

private extension Date {
    /// "5 years ago", "20 hours ago", "Just now".
    var relativeDescription: String {
        if abs(timeIntervalSinceNow) < 60 { return "Just now" }
        return formatted(.relative(presentation: .named, unitsStyle: .wide))
    }
}

// MARK: - Analysis

struct NoteStats {
    let words: Int
    let characters: Int
    let readingMinutes: Int
    /// Images and videos.
    let media: Int

    init(_ text: String) {
        var words = 0
        var characters = 0
        var inWord = false
        var wordHasLetters = false
        for scalar in text.unicodeScalars {
            let value = scalar.value
            // ASCII is nearly all of a note; Unicode properties are slow.
            let isSpace: Bool
            let isLetter: Bool
            if value < 128 {
                isSpace = value == 32 || (value >= 9 && value <= 13)
                isLetter = (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
            } else {
                isSpace = scalar.properties.isWhitespace
                isLetter = !isSpace && (scalar.properties.isAlphabetic || scalar.properties.numericType != nil)
            }
            if isSpace {
                if inWord && wordHasLetters { words += 1 }
                inWord = false
                wordHasLetters = false
            } else {
                characters += 1
                inWord = true
                if isLetter { wordHasLetters = true }
            }
        }
        if inWord && wordHasLetters { words += 1 }
        self.words = words
        self.characters = characters
        readingMinutes = max(1, Int((Double(words) / 230).rounded(.up)))
        media = text.contains("![") || text.contains("<img") || text.contains("<video")
            ? text.components(separatedBy: "![").count - 1 + text.components(separatedBy: "<img").count - 1
                + text.components(separatedBy: "<video").count - 1
            : 0
    }
}

enum NoteOutline {
    struct Heading: Identifiable {
        /// The heading's place among the note's outline headings.
        let id: Int
        let level: Int
        let title: String
    }

    static func headings(in text: String) -> [Heading] {
        // Only lines that can be ATX headings; skips parsing notes without any.
        guard text.contains("#") || text.contains("\n===") || text.contains("\n---") else { return [] }
        var result: [Heading] = []
        for block in BlockMarkdown.parse(text).blocks {
            guard let level = block.kind.headingLevel, level <= 3 else { continue }
            let title = block.text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            result.append(Heading(id: result.count, level: level, title: title))
        }
        return result
    }
}
