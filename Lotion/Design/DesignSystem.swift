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

/// A size and weight for the app's chrome, set in the interface font.
/// Use with `.uiFont(_:)`; a plain `Font` can't follow an installed family.
struct InterfaceType {
    var size: CGFloat
    var weight: Font.Weight = .regular
    var digits = false

    static func system(size: CGFloat, weight: Font.Weight = .regular) -> InterfaceType {
        InterfaceType(size: size, weight: weight)
    }

    func weight(_ weight: Font.Weight) -> InterfaceType {
        var copy = self; copy.weight = weight; return copy
    }

    func monospacedDigit() -> InterfaceType {
        var copy = self; copy.digits = true; return copy
    }

    static let dsTitle = InterfaceType(size: 15, weight: .semibold)
    static let dsHeadline = InterfaceType(size: 13, weight: .semibold)
    static let dsBody = InterfaceType(size: 13)
    static let dsCallout = InterfaceType(size: 12)
    static let dsCaption = InterfaceType(size: 11)
    static let dsSectionHeader = InterfaceType(size: 11, weight: .semibold)
    static let dsNumeric = InterfaceType(size: 15, weight: .semibold, digits: true)
}

// MARK: - Interface font

extension EnvironmentValues {
    /// The installed family picked as the interface font; nil for a system design.
    @Entry var interfaceFamily: String?
}

extension View {
    /// Applies the interface font setting to chrome. A system design reaches
    /// every system font below through `fontDesign`; an installed family
    /// reaches the default font and every `.uiFont` below.
    @ViewBuilder func interfaceFont(_ choice: String) -> some View {
        if let design = FontChoice.design(choice) {
            fontDesign(design)
        } else {
            font(.custom(choice, size: 13))
                .environment(\.interfaceFamily, choice)
        }
    }

    /// Chrome text at a size and weight, in the interface font.
    func uiFont(_ type: InterfaceType) -> some View {
        modifier(InterfaceFontModifier(type: type))
    }
}

private struct InterfaceFontModifier: ViewModifier {
    let type: InterfaceType
    @Environment(\.interfaceFamily) private var family

    func body(content: Content) -> some View {
        var font: Font = if let family {
            .custom(family, fixedSize: type.size).weight(type.weight)
        } else {
            .system(size: type.size, weight: type.weight)
        }
        if type.digits { font = font.monospacedDigit() }
        return content.font(font)
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
            Image(icon: systemImage)
                .uiFont(.system(size: 22, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 56, height: 56)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.bottom, Space.xs)

            Text(title)
                .uiFont(.dsTitle)
                .foregroundStyle(Palette.label)

            Text(message)
                .uiFont(.dsCallout)
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
