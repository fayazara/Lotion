//
//  CodeHighlighter.swift
//  Lotion
//
//  Colors fenced code with Shiki. Small blocks in a language that is already
//  loaded highlight synchronously, so typing in a code block never flashes;
//  anything else highlights in the background and posts `didHighlight`, and
//  the editor restyles from the cache.
//

import AppKit
import Foundation
import Shiki

/// One colored stretch of a code block, in UTF-16 offsets from its start.
nonisolated struct CodeColorRun: Sendable {
    let location: Int
    let length: Int
    /// Nil leaves the block's own text color.
    let color: String?
    let italic: Bool
    let bold: Bool
}

final class CodeHighlighter {
    static let shared = CodeHighlighter()
    static let didHighlight = Notification.Name("LotionCodeDidHighlight")

    /// Above this, a block highlights in the background even when its grammar is loaded.
    private static let synchronousLimit = 4_000
    /// Above this, a block is not highlighted at all.
    private static let highlightLimit = 200_000
    private static let cacheLimit = 400

    private let engine: ShikiHighlighter?
    private var cache: [String: [CodeColorRun]] = [:]
    private var pending: Set<String> = []
    private var warmed: Set<String> = []
    private var inFlight = 0
    private var colors: [String: NSColor] = [:]

    /// Every language id and alias Shiki knows, lowercased.
    private lazy var languages: Set<String> = {
        var names: Set<String> = []
        for language in BundledShikiAssets.shared.languages {
            names.insert(language.id.lowercased())
            for alias in language.aliases { names.insert(alias.lowercased()) }
        }
        return names
    }()

    /// Themes Lotion ships beside Shiki's own (see Scripts/generate-themes.py).
    static let shippedThemes = ["pierre-light", "pierre-dark"]

    private init() {
        engine = try? ShikiHighlighter(defaultTheme: "github-light")
        for name in Self.shippedThemes {
            guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let theme = try? JSONDecoder().decode(ShikiTheme.self, from: data) else { continue }
            try? engine?.registerTheme(theme)
        }
    }

    /// Whether code can be colored in `theme` (for tests).
    func canHighlight(theme: String) -> Bool {
        guard let engine else { return false }
        return (try? engine.codeToTokens("let x = 1", language: "swift", theme: theme)) != nil
    }

    /// The fence's language if Shiki can highlight it.
    func supportedLanguage(_ name: String?) -> String? {
        guard let name, !name.isEmpty, !["text", "txt", "plaintext", "plain"].contains(name) else { return nil }
        return languages.contains(name) ? name : nil
    }

    /// Colors for `code`, or nil while they are being computed.
    func runs(for code: String, language: String, theme: String) -> [CodeColorRun]? {
        guard let engine else { return [] }
        let length = code.utf16.count
        guard length > 0, length <= Self.highlightLimit else { return [] }
        let key = "\(theme)\u{1}\(language)\u{1}\(code)"
        if let cached = cache[key] { return cached }
        let warmKey = "\(theme)\u{1}\(language)"

        if warmed.contains(warmKey), inFlight == 0, length <= Self.synchronousLimit {
            let runs = Self.tokenize(engine, code: code, language: language, theme: theme)
            store(runs, for: key)
            return runs
        }

        guard !pending.contains(key) else { return nil }
        pending.insert(key)
        inFlight += 1
        Task.detached(priority: .userInitiated) {
            let runs = Self.tokenize(engine, code: code, language: language, theme: theme)
            await MainActor.run {
                let highlighter = CodeHighlighter.shared
                highlighter.inFlight -= 1
                highlighter.pending.remove(key)
                highlighter.warmed.insert(warmKey)
                highlighter.store(runs, for: key)
                NotificationCenter.default.post(name: Self.didHighlight, object: nil)
            }
        }
        return nil
    }

    /// A theme color (`#rgb`, `#rrggbb` or `#rrggbbaa`) as an NSColor.
    func color(_ hex: String) -> NSColor? {
        if let color = colors[hex] { return color }
        var digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let rgb = hasAlpha ? value >> 8 : value
        let color = NSColor(hex: UInt32(rgb), alpha: hasAlpha ? CGFloat(value & 0xFF) / 255 : 1)
        colors[hex] = color
        return color
    }

    private func store(_ runs: [CodeColorRun], for key: String) {
        if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = runs
    }

    private nonisolated static func tokenize(_ engine: ShikiHighlighter, code: String, language: String, theme: String) -> [CodeColorRun] {
        guard let result = try? engine.codeToTokens(code, language: language, theme: theme) else { return [] }
        let foreground = result.fg?.uppercased()
        var runs: [CodeColorRun] = []
        for line in result.tokens {
            for token in line {
                let length = token.content.utf16.count
                guard length > 0 else { continue }
                let style = token.fontStyle ?? []
                let color = token.color.flatMap { $0.uppercased() == foreground ? nil : $0 }
                let italic = style != .notSet && style.contains(.italic)
                let bold = style != .notSet && style.contains(.bold)
                guard color != nil || italic || bold else { continue }
                runs.append(CodeColorRun(location: token.offset, length: length, color: color, italic: italic, bold: bold))
            }
        }
        return runs
    }
}
