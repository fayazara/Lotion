//
//  Theme.swift
//  Lotion
//
//  The note canvas themes. Each has a light and a dark variant; the window's
//  appearance picks one. A theme colors the canvas (ground, ink, markdown
//  marks, code surfaces) and names the Shiki theme for fenced code. Chrome
//  (sidebar, toolbar, inspector) stays native.
//

import AppKit
import SwiftUI

/// A page theme: a light side, a dark side, or both. Themes with both follow
/// the window's appearance; a theme with one side keeps it either way.
struct LotionTheme: Identifiable, Hashable, RawRepresentable, CaseIterable {
    let id: String
    let name: String
    let light: ThemeSpec?
    let dark: ThemeSpec?

    init(id: String, name: String, light: ThemeSpec?, dark: ThemeSpec?) {
        self.id = id
        self.name = name
        self.light = light
        self.dark = dark
    }

    var rawValue: String { id }

    init?(rawValue: String) {
        guard let theme = Self.allCases.first(where: { $0.id == rawValue }) else { return nil }
        self = theme
    }

    static func == (lhs: LotionTheme, rhs: LotionTheme) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Lotion's own four first, then those made from VS Code themes.
    static var allCases: [LotionTheme] { [paper, graphite, sepia, nord] + catalog }

    var hasLight: Bool { light != nil }
    var hasDark: Bool { dark != nil }

    func palette(dark isDark: Bool) -> ThemePalette {
        let spec = (isDark ? dark ?? light : light ?? dark)!
        return ThemePalette(spec)
    }

    static let paper = LotionTheme(id: "paper", name: "Paper",
        light: ThemeSpec(background: 0xFBFBFA, text: 0x1F1F1D, secondary: 0x6E6E6A, marker: 0xB3B3AD, accent: nil,
                         codeBackground: 0xF3F3F1, inlineCode: 0xEEEEEB, rule: 0xE3E3E0, shikiTheme: "github-light", isDark: false),
        dark: ThemeSpec(background: 0x1C1C1B, text: 0xE8E7E3, secondary: 0x9D9C97, marker: 0x5F5E5A, accent: nil,
                        codeBackground: 0x252524, inlineCode: 0x2B2B2A, rule: 0x343432, shikiTheme: "github-dark-dimmed", isDark: true))

    static let graphite = LotionTheme(id: "graphite", name: "Graphite",
        light: ThemeSpec(background: 0xFFFFFF, text: 0x1D1D1F, secondary: 0x6E6E73, marker: 0xAEAEB2, accent: nil,
                         codeBackground: 0xF5F5F7, inlineCode: 0xF0F0F2, rule: 0xE5E5EA, shikiTheme: "github-light-default", isDark: false),
        dark: ThemeSpec(background: 0x161618, text: 0xF2F2F7, secondary: 0x98989D, marker: 0x55555A, accent: nil,
                        codeBackground: 0x1F1F22, inlineCode: 0x26262A, rule: 0x2C2C30, shikiTheme: "github-dark-default", isDark: true))

    static let sepia = LotionTheme(id: "sepia", name: "Sepia",
        light: ThemeSpec(background: 0xF7F1E6, text: 0x3B3027, secondary: 0x86735F, marker: 0xC4B39D, accent: 0xA8552A,
                         codeBackground: 0xEFE6D5, inlineCode: 0xEBE1CE, rule: 0xE3D7C2, shikiTheme: "rose-pine-dawn", isDark: false),
        dark: ThemeSpec(background: 0x1E1915, text: 0xEADFCC, secondary: 0xA8987F, marker: 0x665848, accent: 0xE09A63,
                        codeBackground: 0x28211B, inlineCode: 0x2F2720, rule: 0x372E25, shikiTheme: "gruvbox-dark-soft", isDark: true))

    static let nord = LotionTheme(id: "nord", name: "Nord",
        light: ThemeSpec(background: 0xF3F5F9, text: 0x2E3440, secondary: 0x5B6579, marker: 0xA7AFBE, accent: 0x5E81AC,
                         codeBackground: 0xE9EDF3, inlineCode: 0xE4E9F0, rule: 0xDCE1EA, shikiTheme: "catppuccin-latte", isDark: false),
        dark: ThemeSpec(background: 0x2E3440, text: 0xD8DEE9, secondary: 0x9AA3B5, marker: 0x616E88, accent: 0x88C0D0,
                        codeBackground: 0x353C4A, inlineCode: 0x3B4252, rule: 0x434C5E, shikiTheme: "nord", isDark: true))
}

/// One side of a theme, as hex colors.
struct ThemeSpec: Hashable {
    let background: UInt32
    let text: UInt32
    let secondary: UInt32
    let marker: UInt32
    /// Nil follows the accent picked in System Settings.
    let accent: UInt32?
    let codeBackground: UInt32
    let inlineCode: UInt32
    let rule: UInt32
    /// Headings, when the theme colors them.
    var heading: UInt32?
    let shikiTheme: String
    let isDark: Bool

    init(background: UInt32, text: UInt32, secondary: UInt32, marker: UInt32, accent: UInt32?, codeBackground: UInt32,
         inlineCode: UInt32, rule: UInt32, heading: UInt32? = nil, shikiTheme: String, isDark: Bool) {
        self.background = background
        self.text = text
        self.secondary = secondary
        self.marker = marker
        self.accent = accent
        self.codeBackground = codeBackground
        self.inlineCode = inlineCode
        self.rule = rule
        self.heading = heading
        self.shikiTheme = shikiTheme
        self.isDark = isDark
    }
}

/// One variant of a theme, resolved to concrete colors.
struct ThemePalette: Equatable {
    let background: NSColor
    let text: NSColor
    let secondary: NSColor
    /// Markdown syntax: `#`, `**`, backticks, fences, link targets.
    let marker: NSColor
    let accent: NSColor
    /// Heading ink; the text color unless the theme colors headings.
    let heading: NSColor
    let codeBackground: NSColor
    let inlineCode: NSColor
    let rule: NSColor
    let shikiTheme: String
    let isDark: Bool

    init(_ spec: ThemeSpec) {
        self.init(background: spec.background, text: spec.text, secondary: spec.secondary, marker: spec.marker, accent: spec.accent,
                  codeBackground: spec.codeBackground, inlineCode: spec.inlineCode, rule: spec.rule, heading: spec.heading,
                  shikiTheme: spec.shikiTheme, isDark: spec.isDark)
    }

    /// `accent: nil` follows the accent color picked in System Settings.
    init(background: UInt32, text: UInt32, secondary: UInt32, marker: UInt32, accent: UInt32?,
         codeBackground: UInt32, inlineCode: UInt32, rule: UInt32, heading: UInt32? = nil, shikiTheme: String, isDark: Bool) {
        self.background = NSColor(hex: background)
        self.heading = NSColor(hex: heading ?? text)
        self.text = NSColor(hex: text)
        self.secondary = NSColor(hex: secondary)
        self.marker = NSColor(hex: marker)
        self.accent = accent.map { NSColor(hex: $0) } ?? Self.systemAccent(isDark: isDark)
        self.codeBackground = NSColor(hex: codeBackground)
        self.inlineCode = NSColor(hex: inlineCode)
        self.rule = NSColor(hex: rule)
        self.shikiTheme = shikiTheme
        self.isDark = isDark
    }

    var selection: NSColor { accent.withAlphaComponent(isDark ? 0.34 : 0.22) }

    /// The hairline around a code block.
    var codeBorder: NSColor { (isDark ? NSColor.white : NSColor.black).withAlphaComponent(isDark ? 0.06 : 0.05) }

    /// The accent resolved for this variant, so it stays fixed while drawn.
    private static func systemAccent(isDark: Bool) -> NSColor {
        var color = NSColor.controlAccentColor
        NSAppearance(named: isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            color = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        }
        return color
    }
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

/// How the window follows light and dark.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "Automatic"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}
