//
//  Preferences.swift
//  Lotion
//
//  UserDefaults-backed settings and the fonts they resolve to. Views read
//  them with @AppStorage; the editor gets them folded into an `EditorStyle`.
//

import AppKit
import SwiftUI

enum Prefs {
    static let theme = "theme"
    static let appearance = "appearance"
    static let interfaceFont = "interfaceFont"
    static let noteFont = "noteFont"
    static let noteFontSize = "noteFontSize"
    static let lineSpacing = "lineSpacing"
    static let codeFont = "codeFont"
    static let readableWidth = "readableWidth"
    static let spellCheck = "spellCheck"
    static let sort = "sort"
    static let inspectorVisible = "inspectorVisible"
    static let editorMode = "editorMode"
    static let tableWidth = "tableWidth"
    static let saveVideos = "saveVideos"
    static let linkPreviews = "linkPreviews"
}

// MARK: - Fonts

/// A font setting: one of the system's designs, or an installed family by name.
enum FontChoice {
    static let system = "system"
    static let serif = "serif"
    static let rounded = "rounded"
    static let mono = "mono"

    static let designs: [(id: String, title: String)] = [
        (system, "San Francisco"),
        (serif, "New York"),
        (rounded, "SF Rounded"),
        (mono, "SF Mono"),
    ]

    static func title(for choice: String) -> String {
        designs.first { $0.id == choice }?.title ?? choice
    }

    /// Resolves a choice to a regular-weight font, falling back to the system
    /// font when a family is no longer installed.
    static func font(_ choice: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let design: NSFontDescriptor.SystemDesign? = switch choice {
        case system: .default
        case serif: .serif
        case rounded: .rounded
        case mono: .monospaced
        default: nil
        }
        if let design {
            let base = choice == mono
                ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            guard design != .default, design != .monospaced,
                  let descriptor = base.fontDescriptor.withDesign(design) else { return base }
            return NSFont(descriptor: descriptor, size: size) ?? base
        }
        let manager = NSFontManager.shared
        let fontWeight = weight >= .bold ? 9 : weight >= .semibold ? 8 : weight >= .medium ? 6 : 5
        if let font = manager.font(withFamily: choice, traits: [], weight: fontWeight, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: weight)
    }

    /// The design for a system choice; nil for an installed family.
    static func design(_ choice: String) -> Font.Design? {
        switch choice {
        case system: .default
        case serif: .serif
        case rounded: .rounded
        case mono: .monospaced
        default: nil
        }
    }

    /// Installed families, for the font pickers. Computed once.
    static let installedFamilies: [String] = NSFontManager.shared.availableFontFamilies
        .filter { !$0.hasPrefix(".") }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

    /// Installed families whose regular face is fixed pitch.
    static let monospacedFamilies: [String] = installedFamilies.filter { family in
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 12)?.isFixedPitch == true
    }
}

// MARK: - Editor settings

enum LineSpacing: String, CaseIterable, Identifiable {
    case compact, comfortable, relaxed

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Line height as a multiple of the font size.
    var multiple: CGFloat {
        switch self {
        // Lines of one paragraph sit close; the room goes between paragraphs
        // and items instead, so each reads as one piece.
        case .compact: 1.35
        case .comfortable: 1.5
        case .relaxed: 1.7
        }
    }
}

enum ReadableWidth: String, CaseIterable, Identifiable {
    case narrow, medium, wide, full

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// The text column's widest extent, in points.
    var points: CGFloat {
        switch self {
        case .narrow: 580
        case .medium: 700
        case .wide: 840
        case .full: 10_000
        }
    }
}

/// How wide tables run: as wide as their content, or the whole text column.
enum TableWidth: String, CaseIterable, Identifiable {
    case fit, full

    var id: String { rawValue }
    var title: String { self == .fit ? "Fit Content" : "Full Width" }
}

enum NoteSort: String, CaseIterable, Identifiable {
    case created, modified, title

    var id: String { rawValue }

    var title: String {
        switch self {
        case .created: "Date Created"
        case .modified: "Date Edited"
        case .title: "Title"
        }
    }
}

/// Everything the editor's look depends on. Changing any of it restyles the note.
struct EditorStyle: Equatable {
    var theme: LotionTheme
    var isDark: Bool
    var noteFont: String
    var noteFontSize: CGFloat
    var lineSpacing: LineSpacing
    var codeFont: String
    var readableWidth: ReadableWidth
    var spellCheck: Bool
    var tableWidth: TableWidth = .fit

    var palette: ThemePalette { theme.palette(dark: isDark) }
}
