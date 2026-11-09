//
//  IconPicker.swift
//  Lotion
//
//  A small grid of SF Symbols that suit a note or folder, for its sidebar
//  row. Symbols this macOS doesn't have are left out.
//

import AppKit
import SwiftUI

enum NoteIcon {
    static let `default` = "doc.text"
}

struct IconPicker: View {
    let current: String
    let pick: (String) -> Void

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
    ].filter { NSImage(systemSymbolName: $0, accessibilityDescription: nil) != nil }

    private let columns = Array(repeating: GridItem(.fixed(30), spacing: Space.xs), count: 8)

    var body: some View {
        LazyVGrid(columns: columns, spacing: Space.xs) {
            ForEach(Self.symbols, id: \.self) { symbol in
                Button { pick(symbol) } label: {
                    Image(systemName: symbol)
                        .symbolVariant(.fill)
                        .font(.system(size: 14))
                        .frame(width: 30, height: 30)
                        .foregroundStyle(symbol == current ? Color.white : Palette.label)
                        .background(
                            symbol == current ? Color.accentColor : .clear,
                            in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(symbol)
            }
        }
        .padding(Space.l)
    }
}
