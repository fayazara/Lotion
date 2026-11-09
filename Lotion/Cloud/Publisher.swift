//
//  Publisher.swift
//  Lotion
//
//  Publishes a note to the user's Lotion Share worker. The note's Markdown
//  goes as it is, except that images and files beside it are uploaded and
//  their links pointed at the worker. Files are named by their content's
//  hash, so a file that didn't change is never sent twice. The note's cover,
//  its icon (drawn as an image) and its theme's colors go along, so the page
//  looks like the note. Pages always use the system font.
//

import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Where a note is published.
struct Publication: Codable, Equatable {
    var id: String
    var url: URL
    var published: Date
}

/// What a publish did, for the share popover to report.
struct PublishResult {
    let publication: Publication
    /// Files the note links to that couldn't be found on disk.
    let skipped: [String]
}

enum Publisher {
    // MARK: Payload, as the worker reads it

    private struct Payload: Encodable {
        let title: String
        let markdown: String
        let files: [String]
        let cover: Cover?
        let icon: String?
        let style: Style
    }

    private struct Cover: Encodable {
        let source: String
        let position: Double
        let credit: String?
        let creditUrl: String?
    }

    /// The page always uses the system font, so only colors go.
    private struct Style: Encodable {
        let light: Palette?
        let dark: Palette?
    }

    private struct Palette: Encodable {
        let background, text, secondary, accent, codeBackground, inlineCode, rule: String
    }

    /// A file to send: one on disk, or bytes made here (the icon).
    private enum Upload {
        case file(URL)
        case data(Data)
    }

    // MARK: Publishing

    static func publish(_ note: Note, library: Library, style: EditorStyle) async throws -> PublishResult {
        let client = try CloudClient.configured()
        _ = try await client.checkCompatible()
        library.save(note)

        let id = library.publication(for: note)?.id ?? newID()
        var uploads: [String: Upload] = [:]
        var skipped: [String] = []

        // Images and files beside the note become the worker's.
        var blocks = BlockMarkdown.blocks(from: note.text)
        for index in blocks.indices {
            let block = blocks[index]
            let isMedia = block.kind == .image && !block.isBareLink
            let isFile = block.kind == .embed && block.info == "file"
            guard isMedia || isFile, isLocal(block.imageSource) else { continue }
            guard let url = localFile(block.imageSource, near: note.url), let name = try? hashedName(of: url) else {
                skipped.append(block.imageSource)
                continue
            }
            uploads[name] = .file(url)
            blocks[index].imageSource = "/files/\(id)/\(name)"
            blocks[index].source = nil
        }
        let markdown = BlockMarkdown.write(blocks, trailingNewlines: 1)

        var cover: Cover?
        if let noteCover = library.cover(for: note) {
            let url = noteCover.url(in: library)
            if FileManager.default.fileExists(atPath: url.path), let name = try? hashedName(of: url) {
                uploads[name] = .file(url)
                cover = Cover(source: name, position: noteCover.position, credit: noteCover.credit,
                              creditUrl: noteCover.creditURL?.absoluteString)
            }
        }

        let light = style.theme.light.map(ThemePalette.init)
        let dark = style.theme.dark.map(ThemePalette.init)
        var icon: String?
        if let symbol = library.icon(for: note), let tint = (light ?? dark)?.accent,
           let data = iconPNG(symbol: symbol, color: resolved(tint, dark: light == nil)) {
            let name = hashedName(of: data, ext: "png")
            uploads[name] = .data(data)
            icon = name
        }

        let payload = Payload(
            title: note.displayTitle,
            markdown: markdown,
            files: uploads.keys.sorted(),
            cover: cover,
            icon: icon,
            style: Style(light: light.map { palette($0, dark: false) },
                         dark: dark.map { palette($0, dark: true) })
        )
        let reply = try await client.publish(id: id, payload: payload)

        for name in reply.missing {
            guard let upload = uploads[name] else { continue }
            let type = contentType(for: name)
            switch upload {
            case .file(let url): try await client.upload(noteID: id, name: name, file: url, contentType: type)
            case .data(let data): try await client.upload(noteID: id, name: name, data: data, contentType: type)
            }
        }

        let publication = Publication(id: reply.id, url: reply.url, published: .now)
        library.setPublication(publication, for: note)
        return PublishResult(publication: publication, skipped: skipped)
    }

    static func unpublish(_ note: Note, library: Library) async throws {
        guard let publication = library.publication(for: note) else { return }
        do {
            try await CloudClient.configured().unpublish(id: publication.id)
        } catch CloudError.server(status: 404, _) {
            // Already gone on the worker.
        }
        library.setPublication(nil, for: note)
    }

    // MARK: Files

    /// Twelve letters and digits: hard to guess, short to share.
    private static func newID() -> String {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<12).map { _ in alphabet.randomElement()! })
    }

    private static func isLocal(_ source: String) -> Bool {
        guard !source.isEmpty, !source.hasPrefix("#") else { return false }
        if source.hasPrefix("file://") { return true }
        return !source.contains("://") && !source.hasPrefix("data:") && !source.hasPrefix("mailto:")
    }

    private static func localFile(_ source: String, near note: URL) -> URL? {
        let url: URL
        if source.hasPrefix("file://") {
            guard let fileURL = URL(string: source) else { return nil }
            url = fileURL
        } else {
            let path = source.removingPercentEncoding ?? source
            url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : note.deletingLastPathComponent().appending(path: path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
        return url.standardizedFileURL
    }

    /// The file's name on the worker: a hash of its bytes, and its extension.
    private static func hashedName(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return name(for: hasher.finalize(), ext: url.pathExtension)
    }

    private static func hashedName(of data: Data, ext: String) -> String {
        name(for: SHA256.hash(data: data), ext: ext)
    }

    private static func name(for digest: SHA256.Digest, ext: String) -> String {
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        let cleaned = ext.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(10)
        return cleaned.isEmpty ? hex : "\(hex).\(cleaned)"
    }

    private static func contentType(for name: String) -> String {
        let ext = (name as NSString).pathExtension
        return UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    // MARK: Look

    private static func palette(_ palette: ThemePalette, dark: Bool) -> Palette {
        func hex(_ color: NSColor) -> String { hexString(resolved(color, dark: dark)) }
        return Palette(background: hex(palette.background), text: hex(palette.text), secondary: hex(palette.secondary),
                       accent: hex(palette.accent), codeBackground: hex(palette.codeBackground),
                       inlineCode: hex(palette.inlineCode), rule: hex(palette.rule))
    }

    /// A color as it looks in light or dark: the system accent depends on both.
    private static func resolved(_ color: NSColor, dark: Bool) -> NSColor {
        var result = color
        NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.sRGB) ?? color
        }
        return result
    }

    private static func hexString(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? .black
        let channels = [srgb.redComponent, srgb.greenComponent, srgb.blueComponent]
            .map { Int(($0 * 255).rounded()).clamped(to: 0...255) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }

    /// The note's SF Symbol, drawn as a PNG for the page: web browsers can't
    /// draw SF Symbols themselves.
    private static func iconPNG(symbol: String, color: NSColor) -> Data? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 128, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        let side = 192
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let scale = min(CGFloat(side) / image.size.width, CGFloat(side) / image.size.height) * 0.9
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        image.draw(in: CGRect(x: (CGFloat(side) - size.width) / 2, y: (CGFloat(side) - size.height) / 2,
                              width: size.width, height: size.height))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
