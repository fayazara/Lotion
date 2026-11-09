//
//  Block.swift
//  Lotion
//
//  A note is a list of blocks. Markdown is how a note is saved, not how it
//  is edited: the file is parsed into blocks when a note opens, and the blocks
//  are written back as Markdown whenever they change.
//

import AppKit

nonisolated enum BlockKind: Equatable, Hashable {
    case paragraph
    case heading(Int)
    case bullet
    case numbered
    case todo
    case quote
    case code
    case divider
    case table
    /// An image or a video.
    case image
    /// An HTML block: previewed, and edited as its source.
    case html
    /// Markdown Lotion does not model (front matter, math, link definitions), kept as typed.
    case raw
    /// A rich block made from a line of its own: a link shown as a card or a
    /// player (`imageSource`), a file chip (`info` "file"), another note
    /// (`info` "note", `![[Name]]`) or the note's contents (`info` "toc", `[TOC]`).
    case embed
    /// Where a scratchpad entry starts; `info` holds when, as ISO 8601.
    /// Saved as an HTML comment, so other Markdown apps show nothing.
    case entry

    /// Blocks whose content is one run of rich text.
    var isText: Bool {
        switch self {
        case .paragraph, .heading, .bullet, .numbered, .todo, .quote: true
        default: false
        }
    }

    var isList: Bool { self == .bullet || self == .numbered || self == .todo }

    /// Holds editable text in a text view (code and raw text included).
    var isEditable: Bool { isText || self == .code || self == .raw || self == .html }

    /// What a new block made by pressing Return after this one is.
    var continuation: BlockKind {
        switch self {
        case .bullet, .numbered, .todo: self
        default: .paragraph
        }
    }

    var headingLevel: Int? {
        if case .heading(let level) = self { return level }
        return nil
    }
}

/// Inline formatting, kept on the text as attributes. Display attributes
/// (fonts, colors) are derived from these and never written to Markdown.
extension NSAttributedString.Key {
    nonisolated static let lotionBold = NSAttributedString.Key("lotionBold")
    nonisolated static let lotionItalic = NSAttributedString.Key("lotionItalic")
    nonisolated static let lotionStrike = NSAttributedString.Key("lotionStrike")
    nonisolated static let lotionCode = NSAttributedString.Key("lotionCode")
    /// The link's target, as written.
    nonisolated static let lotionLink = NSAttributedString.Key("lotionLink")
    /// Inline Markdown Lotion does not model (HTML, images, footnotes), written back unchanged.
    nonisolated static let lotionRaw = NSAttributedString.Key("lotionRaw")

    nonisolated static let semanticKeys: [NSAttributedString.Key] = [.lotionBold, .lotionItalic, .lotionStrike, .lotionCode, .lotionLink, .lotionRaw]
}

nonisolated enum ColumnAlignment: Equatable {
    case none, left, center, right
}

nonisolated struct TableData: Equatable {
    /// The first row is the header.
    var rows: [[NSAttributedString]]
    var alignments: [ColumnAlignment]

    var columnCount: Int { alignments.count }

    static func empty(rows: Int = 3, columns: Int = 3) -> TableData {
        TableData(rows: Array(repeating: Array(repeating: NSAttributedString(), count: columns), count: rows),
                  alignments: Array(repeating: .none, count: columns))
    }

    /// Pads or trims every row to the column count.
    mutating func normalize() {
        let count = max(1, alignments.count)
        if alignments.isEmpty { alignments = [.none] }
        for index in rows.indices {
            if rows[index].count < count {
                rows[index] += Array(repeating: NSAttributedString(), count: count - rows[index].count)
            } else if rows[index].count > count {
                rows[index] = Array(rows[index].prefix(count))
            }
        }
        if rows.isEmpty { rows = [Array(repeating: NSAttributedString(), count: count)] }
    }
}

nonisolated struct Block: Identifiable {
    let id: UUID
    var kind: BlockKind
    /// Rich text for text blocks; the code or raw Markdown for code and raw blocks.
    var text: NSAttributedString
    /// List nesting depth.
    var indent = 0
    var checked = false
    /// The first number of a numbered list, when it does not start at 1.
    var start: Int?
    /// A code fence's info string; its first word is the language.
    var info = ""
    var table: TableData?
    var imageSource = ""
    var imageAlt = ""
    /// A media link written alone on its line, the way GitHub embeds attachments.
    var isBareLink = false
    /// A quote's GitHub alert type (NOTE, TIP, IMPORTANT, WARNING, CAUTION).
    var alert: String?

    /// The Markdown this block was parsed from. Written back unchanged while
    /// the block is, so opening and saving a note never rewrites it.
    var source: String?
    /// Newlines before the block in the file, and the block that preceded it,
    /// to keep the file's spacing while the neighbours are the same.
    var gapBefore: Int?
    var sourcePrevious: UUID?

    init(id: UUID = UUID(), kind: BlockKind, text: NSAttributedString = NSAttributedString()) {
        self.id = id
        self.kind = kind
        self.text = text
    }

    var language: String {
        String(info.split(separator: " ", maxSplits: 1).first ?? "")
    }

    /// A ```mermaid fence, drawn as a diagram.
    var isDiagram: Bool { kind == .code && language.lowercased() == "mermaid" }

    /// Call on every change, so the block is written from its content.
    mutating func touch() {
        source = nil
    }

    /// A copy with a new identity, for duplicating.
    func duplicate() -> Block {
        var copy = Block(kind: kind, text: text)
        copy.indent = indent
        copy.checked = checked
        copy.start = start
        copy.info = info
        copy.table = table
        copy.imageSource = imageSource
        copy.imageAlt = imageAlt
        copy.isBareLink = isBareLink
        copy.alert = alert
        return copy
    }

    /// The text without formatting, for search and the outline.
    var plainText: String {
        if kind == .table, let table {
            return table.rows.map { $0.map(\.string).joined(separator: " ") }.joined(separator: "\n")
        }
        return text.string
    }
}

/// What a media source holds, judged from its address.
nonisolated enum MediaKind {
    case image, video, audio, pdf, unknown

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "avif"]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "aac", "aiff", "aif", "flac", "ogg", "caf", "opus"]

    static func of(_ source: String) -> MediaKind {
        let path = source.split(separator: "?").first.map(String.init) ?? source
        let ext = (path as NSString).pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if ext == "pdf" { return .pdf }
        return .unknown
    }

    /// Played or paged rather than shown: audio and PDFs.
    var isDocument: Bool { self == .audio || self == .pdf }

    /// A link that GitHub shows as media when it stands alone on a line.
    static func isEmbeddable(_ url: String) -> Bool {
        guard url.hasPrefix("http://") || url.hasPrefix("https://"), !url.contains(" ") else { return false }
        if of(url) != .unknown { return true }
        return url.contains("github.com/user-attachments/assets/") || url.contains("user-images.githubusercontent.com")
    }
}
