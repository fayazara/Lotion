//
//  QuickNoteViews.swift
//  Lotion
//
//  The quick note pane's controls: the round "/" button in its corner,
//  which opens the slash menu out of itself, and the list of entries to
//  jump between.
//

import AppKit
import Observation
import SwiftUI

@Observable
final class QuickNoteModel {
    @ObservationIgnored weak var controller: QuickNoteController?
    var title = "Quick Note"
    var keepOnTop = true
    /// While the slash menu is open, it stands where the button was.
    var isSlashMenuOpen = false
    /// Newest first, for the browser.
    var entries: [ScratchpadEntries.Entry] = []
    var currentID: String?
}

// MARK: - Slash button

struct SlashButton: View {
    let model: QuickNoteModel

    var body: some View {
        Button {
            model.controller?.toggleSlashMenu()
        } label: {
            Text("/")
                .font(.system(size: 17, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 36, height: 36)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .help("Commands (/)")
        .accessibilityLabel("Commands")
        // The menu's surface takes the button's place and morphs from it,
        // so the button steps out at once and back once it has closed.
        .opacity(model.isSlashMenuOpen ? 0 : 1)
        .allowsHitTesting(!model.isSlashMenuOpen)
        .transaction { $0.animation = nil }
    }
}

// MARK: - Entry browser

struct EntryBrowser: View {
    let model: QuickNoteModel
    @State private var query = ""
    @State private var highlighted: String?
    @FocusState private var isSearchFocused: Bool

    private var results: [ScratchpadEntries.Entry] {
        let words = query.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return model.entries }
        return model.entries.filter { entry in
            words.allSatisfy { entry.preview.localizedStandardContains($0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search Entries", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) { move(by: 1); return .handled }
                .onKeyPress(.upArrow) { move(by: -1); return .handled }
                .onSubmit { if let id = highlighted ?? results.first?.id { model.controller?.select(id) } }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(results) { entry in
                            row(entry).id(entry.id)
                        }
                        if results.isEmpty {
                            Text(query.isEmpty ? "No entries yet" : "No matches")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 24)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: highlighted) { _, id in
                    if let id { withAnimation(.smooth(duration: 0.15)) { proxy.scrollTo(id) } }
                }
            }
        }
        .frame(width: 300, height: 340)
        .onAppear {
            highlighted = model.currentID ?? results.first?.id
            isSearchFocused = true
        }
        .onChange(of: query) { highlighted = results.first?.id }
    }

    private func row(_ entry: ScratchpadEntries.Entry) -> some View {
        let isHighlighted = entry.id == highlighted
        return Button {
            model.controller?.select(entry.id)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(entry.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(entry.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if entry.id == model.currentID {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(subtitle(entry))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHighlighted ? AnyShapeStyle(.selection.opacity(0.5)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { highlighted = entry.id } }
    }

    private func subtitle(_ entry: ScratchpadEntries.Entry) -> String {
        let when = entry.date.map { $0.formatted(.relative(presentation: .named)) } ?? "Entry"
        let rest = entry.preview.dropFirst(entry.title.count).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? when : when + " · " + rest
    }

    private func move(by step: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? (step > 0 ? -1 : list.count)
        highlighted = list[max(0, min(list.count - 1, index + step))].id
    }
}
