//
//  IconPicker.swift
//  Lotion
//
//  Icons for a note or folder's sidebar row: a grid of ones that suit notes,
//  and a search by name through brand logos and the whole free Hugeicons set.
//

import AppKit
import SwiftUI

enum NoteIcon {
    static let `default` = "doc.text"
}

struct IconPicker: View {
    let current: String
    let pick: (String) -> Void

    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    /// Shown before anything's typed. App icon names; each draws a Hugeicon.
    static let symbols: [String] = [
        "folder", "tray", "archivebox", "doc.text", "book", "books.vertical", "bookmark", "tag",
        "star", "heart", "flag", "pin", "bell", "lightbulb", "brain.head.profile", "sparkles",
        "briefcase", "building.2", "house", "person", "person.2", "graduationcap", "pencil", "paintbrush",
        "paintpalette", "camera", "photo", "film", "music.note", "headphones", "gamecontroller", "gift",
        "cart", "bag", "creditcard", "banknote", "chart.bar", "chart.pie", "calendar", "clock",
        "checklist", "list.bullet", "square.grid.2x2", "terminal", "chevron.left.forwardslash.chevron.right", "hammer", "wrench.and.screwdriver", "gearshape",
        "cpu", "globe", "airplane", "car", "map", "mappin.and.ellipse", "leaf", "tree",
        "flame", "drop", "sun.max", "moon", "cloud", "pawprint", "fork.knife", "cup.and.saucer",
        "cross.case", "dumbbell", "figure.run", "envelope", "bubble.left.and.bubble.right", "phone", "lock", "key",
    ].filter { AppIcon.hugeicon(for: $0) != nil || NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    private static let cell: CGFloat = 30
    private static let perRow = 8
    private let columns = Array(repeating: GridItem(.fixed(cell), spacing: Space.xs), count: perRow)

    private func results(in catalog: IconCatalog) -> [String] {
        catalog.search(query).map(catalog.icon(named:))
    }

    var body: some View {
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        // Brands first: a search for "google" is after Google's logo more
        // often than an icon with google in its name.
        let brands = searching ? results(in: .brands) : []
        let icons = searching ? results(in: .hugeicons) : Self.symbols
        let count = brands.count + icons.count
        VStack(spacing: Space.m) {
            searchField
            ScrollView {
                if count == 0 {
                    Text("No icons named “\(query)”")
                        .font(.dsCallout)
                        .foregroundStyle(Palette.secondaryLabel)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Space.xs) {
                        if !brands.isEmpty {
                            section("Brands") {
                                ForEach(brands, id: \.self) { cell($0) }
                            }
                            if !icons.isEmpty {
                                section("Icons") {
                                    ForEach(icons, id: \.self) { cell($0) }
                                }
                            }
                        } else {
                            ForEach(icons, id: \.self) { cell($0) }
                        }
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(width: gridWidth, height: Self.cell * 9 + Space.xs * 8)
            if searching, count > 0 {
                Text(count == 1 ? "1 icon" : "\(count) icons")
                    .font(.dsCaption)
                    .foregroundStyle(Palette.tertiaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.l)
        .onAppear { isSearchFocused = true }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Section {
            content()
        } header: {
            Text(title)
                .font(.dsSectionHeader)
                .foregroundStyle(Palette.secondaryLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Space.xs)
        }
    }

    private var gridWidth: CGFloat {
        Self.cell * CGFloat(Self.perRow) + Space.xs * CGFloat(Self.perRow - 1)
    }

    private var searchField: some View {
        HStack(spacing: Space.s) {
            Image(icon: "magnifyingglass")
                .foregroundStyle(Palette.secondaryLabel)
            TextField("Search icons and brands", text: $query)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onSubmit {
                    if let first = results(in: .brands).first ?? results(in: .hugeicons).first { pick(first) }
                }
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(icon: "xmark.circle.fill").foregroundStyle(Palette.tertiaryLabel)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .font(.dsBody)
        .padding(.horizontal, Space.m)
        .frame(width: gridWidth, height: 28)
        .background(Palette.fill, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
    }

    private func cell(_ icon: String) -> some View {
        let isCurrent = icon == current
        return Button { pick(icon) } label: {
            IconGlyph(icon)
                .font(.system(size: 14))
                .frame(width: Self.cell, height: Self.cell)
                .foregroundStyle(isCurrent ? Color.white : Palette.label)
                .background(
                    isCurrent ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(IconCatalog.resolve(icon)?.name ?? AppIcon.hugeicon(for: icon).map { String($0.dropFirst("huge.".count)) } ?? icon)
    }
}
