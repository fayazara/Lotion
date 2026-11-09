//
//  DesignSystem.swift
//  Lotion
//
//  The tokens the chrome is built from, shared with Screendrop: neutral label
//  ink for text and glyphs, the system accent for selection and the one
//  prominent action, whitespace rather than rules between groups. The note
//  canvas takes its colors from the active theme (Theme.swift) instead.
//

import AppKit
import SwiftUI

// MARK: - Ink

extension Color {
    /// Pure black in light mode, pure white in dark.
    static let ink = Color(nsColor: NSColor(name: "lotion.ink") { $0.isDarkAppearance ? .white : .black })
}

extension NSAppearance {
    var isDarkAppearance: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Semantic colors for chrome. Views ask for a role, never a literal color.
enum Palette {
    static let label = Color.ink.opacity(0.88)
    static let secondaryLabel = Color.ink.opacity(0.55)
    static let tertiaryLabel = Color.ink.opacity(0.32)

    static let fill = Color.primary.opacity(0.055)
    static let hoverFill = Color.primary.opacity(0.07)
    static let selectedFill = Color.primary.opacity(0.10)
    static let hairline = Color.primary.opacity(0.10)
}

// MARK: - Geometry

/// Corner radii. Nested shapes follow `outer = inner + padding`.
enum Radius {
    static let tile: CGFloat = 6
    static let field: CGFloat = 8
    static let thumbnail: CGFloat = 10
    static let card: CGFloat = 16
}

/// The spacing rhythm. Surfaces separate groups with whitespace, not rules.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 6
    static let m: CGFloat = 8
    static let l: CGFloat = 12
    static let xl: CGFloat = 16
    static let xxl: CGFloat = 20
    static let xxxl: CGFloat = 28
}

// MARK: - Typography

extension Font {
    static let dsTitle = Font.system(size: 15, weight: .semibold)
    static let dsHeadline = Font.system(size: 13, weight: .semibold)
    static let dsBody = Font.system(size: 13)
    static let dsCallout = Font.system(size: 12)
    static let dsCaption = Font.system(size: 11)
    static let dsSectionHeader = Font.system(size: 11, weight: .semibold)
    static let dsNumeric = Font.system(size: 15, weight: .semibold).monospacedDigit()
}

// MARK: - Interface font

extension View {
    /// Applies the interface font setting to chrome. A system design reaches
    /// every system font below, sized or not; an installed family can only
    /// replace the default font.
    @ViewBuilder func interfaceFont(_ choice: String) -> some View {
        if let design = FontChoice.design(choice) {
            fontDesign(design)
        } else {
            font(.custom(choice, size: 13))
        }
    }
}

// MARK: - Surfaces

extension View {
    /// A quiet rounded surface for grouped content inside a panel.
    func surface(radius: CGFloat = Radius.card) -> some View {
        background(Palette.fill, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// A hairline edge, drawn inside the shape so it never changes layout.
    func hairline(radius: CGFloat, opacity: Double = 0.10) -> some View {
        overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.primary.opacity(opacity), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

/// A centered placeholder for an empty pane: a glyph on glass, a title, a
/// line of copy and optional actions.
struct EmptyStateView<Actions: View>: View {
    let systemImage: String
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: Space.l) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, Space.xs)

            Text(title)
                .font(.dsTitle)
                .foregroundStyle(Palette.label)

            Text(message)
                .font(.dsCallout)
                .foregroundStyle(Palette.secondaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            if Actions.self != EmptyView.self {
                HStack(spacing: Space.m) { actions() }
                    .padding(.top, Space.s)
            }
        }
        .padding(Space.xxxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(systemImage: String, title: String, message: String) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}
