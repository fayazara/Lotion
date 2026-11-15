//
//  SettingsKit.swift
//  Lotion
//
//  The pieces every settings pane is built from, so they all read the same:
//  a page of sections, each a quiet rounded card of rows under a small
//  capitalised heading. A row is an icon in a little
//  square, a title with a line of detail, and its control on the right —
//  or, for a choice best seen, pictures under the words.
//

import AppKit
import SwiftUI

// MARK: - Page

/// One pane: its sections, in a column that stops growing in a wide
/// window. The pane's name is the window's title, as in System Settings.
struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                content()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

// MARK: - Section

/// A small capitalised heading with its icon, a card of rows under it, and
/// an optional note below. Rows are split by hairlines that start where the
/// text does.
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    init(_ title: String, icon: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(icon: icon)
                    .uiFont(.system(size: 11, weight: .semibold))
                    .frame(width: 14)
                Text(title.uppercased())
                    .uiFont(.system(size: 11, weight: .semibold))
                    .tracking(0.7)
            }
            .foregroundStyle(Palette.secondaryLabel)
            .padding(.leading, 4)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            VStack(alignment: .leading, spacing: 0) {
                Group(subviews: content()) { rows in
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            Rectangle()
                                .fill(SettingsStyle.hairline)
                                .frame(height: 0.5)
                                .padding(.leading, SettingsStyle.textInset)
                        }
                        row
                    }
                }
            }
            .background(SettingsStyle.cardFill, in: SettingsStyle.card)
            .overlay { SettingsStyle.card.strokeBorder(SettingsStyle.cardStroke, lineWidth: 0.5) }

            if let footer {
                Text(footer)
                    .uiFont(.system(size: 11.5))
                    .foregroundStyle(Palette.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
        }
    }
}

enum SettingsStyle {
    static let card = RoundedRectangle(cornerRadius: 12, style: .continuous)
    static let cardFill = Color.primary.opacity(0.03)
    static let cardStroke = Color.primary.opacity(0.09)
    static let hairline = Color.primary.opacity(0.08)
    static let rowPadding = EdgeInsets(top: 12, leading: 14, bottom: 12, trailing: 14)
    static let chip: CGFloat = 30
    static let chipGap: CGFloat = 12
    /// Where a row's text starts, for hairlines and anything set under it.
    static var textInset: CGFloat { rowPadding.leading + chip + chipGap }
}

// MARK: - Row

/// An icon in a square, a title with detail, and a control on the right.
/// Pictured choices go under the words, lined up with them.
struct SettingsRow<Accessory: View, Below: View>: View {
    let icon: String
    let title: String
    var detail: String?
    var info: String?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var below: () -> Below

    init(_ title: String, icon: String, detail: String? = nil, info: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder below: @escaping () -> Below = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.info = info
        self.accessory = accessory
        self.below = below
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsStyle.chipGap) {
            SettingsIcon(icon)
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(title)
                                .uiFont(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.label)
                            if let info {
                                Image(icon: "info.circle")
                                    .uiFont(.system(size: 11))
                                    .foregroundStyle(Palette.tertiaryLabel)
                                    .help(info)
                                    .accessibilityLabel(info)
                            }
                        }
                        if let detail {
                            Text(detail)
                                .uiFont(.system(size: 11.5))
                                .foregroundStyle(Palette.secondaryLabel)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(minHeight: SettingsStyle.chip, alignment: .leading)
                    Spacer(minLength: 0)
                    accessory()
                }
                below()
            }
        }
        .padding(SettingsStyle.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingsRow where Below == EmptyView {
    init(_ title: String, icon: String, detail: String? = nil, info: String? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory) {
        self.init(title, icon: icon, detail: detail, info: info, accessory: accessory, below: { EmptyView() })
    }
}

/// A row whose control is a switch.
struct SettingsToggle: View {
    let title: String
    let icon: String
    var detail: String?
    var info: String?
    @Binding var isOn: Bool

    init(_ title: String, icon: String, detail: String? = nil, info: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.icon = icon
        self.detail = detail
        self.info = info
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, icon: icon, detail: detail, info: info) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// A row's icon, in a small rounded square.
struct SettingsIcon: View {
    let name: String

    init(_ name: String) { self.name = name }

    var body: some View {
        Image(icon: name)
            .uiFont(.system(size: 14, weight: .regular))
            .foregroundStyle(Palette.label)
            .frame(width: SettingsStyle.chip, height: SettingsStyle.chip)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// A short warning or error under a row, lined up with its text.
struct SettingsNote: View {
    let text: String
    var color: Color = .orange
    var icon = "exclamationmark.triangle.fill"

    var body: some View {
        Label(text, icon: icon)
            .uiFont(.system(size: 11.5))
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, SettingsStyle.textInset)
            .padding(.trailing, SettingsStyle.rowPadding.trailing)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Pictured choices

/// A choice drawn as a miniature over its name. The picked one gets a ring
/// a hair outside it and its name in bold.
struct ChoiceTile<Picture: View>: View {
    let title: String
    let isSelected: Bool
    var width: CGFloat = 104
    var aspect: CGFloat = 16 / 10
    let action: () -> Void
    @ViewBuilder let picture: () -> Picture

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                picture()
                    .frame(width: width, height: (width / aspect).rounded())
                    .selectionRing(isSelected: isSelected, isHovering: isHovering, radius: 8)
                Text(title)
                    .uiFont(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Tiles in a row that wraps when the window is narrow.
struct ChoiceTiles<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: spacing) { content() }
            // Columns at least as wide as a tile and its ring, so they never overlap.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 124), spacing: spacing, alignment: .top)],
                      alignment: .leading, spacing: spacing) { content() }
        }
    }
}

extension View {
    /// Clips to a rounded shape with a hairline, and rings it when picked.
    func selectionRing(isSelected: Bool, isHovering: Bool, radius: CGFloat) -> some View {
        let gap: CGFloat = 2.5
        return clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering && !isSelected ? 0.22 : 0.1), lineWidth: 0.5)
            }
            .padding(gap)
            .overlay {
                RoundedRectangle(cornerRadius: radius + gap, style: .continuous)
                    .strokeBorder(Palette.label, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .animation(.smooth(duration: 0.15), value: isSelected)
            .animation(.smooth(duration: 0.12), value: isHovering)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

// MARK: - Fonts

/// System designs first, then every installed family.
struct FontPicker: View {
    @Binding var selection: String
    let families: [String]
    var designs: [String] = FontChoice.designs.map(\.id)

    var body: some View {
        Picker("Font", selection: $selection) {
            ForEach(designs, id: \.self) { Text(FontChoice.title(for: $0)).tag($0) }
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
            // Keep a saved family selectable even if it is no longer installed.
            if !designs.contains(selection), !families.contains(selection) {
                Text(selection).tag(selection)
            }
        }
        .labelsHidden()
        .frame(width: 170)
    }
}
