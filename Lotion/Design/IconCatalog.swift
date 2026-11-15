//
//  IconCatalog.swift
//  Lotion
//
//  Icons to give a note or folder, found by name in the icon picker: the
//  whole free Hugeicons set (Design/Hugeicons.txt, from Scripts/hugeicons.swift)
//  and brand marks made one-colour from gilbarbara/logos (Design/Brands.txt,
//  from Scripts/brands.swift). Each holds icons' shapes on a 24-unit grid,
//  drawn here at the same stroke as the app's own icons. A picked icon is
//  saved as `hugeicon:<name>` or `brand:<name>`, beside the SF Symbol names
//  the app's built-in icons go by.
//

import AppKit
import SwiftUI
import os

final class IconCatalog: @unchecked Sendable {
    static let hugeicons = IconCatalog(resource: "Hugeicons", prefix: "hugeicon:")
    static let brands = IconCatalog(resource: "Brands", prefix: "brand:")

    /// The catalog a saved icon draws from, and its name there.
    static func resolve(_ icon: String) -> (catalog: IconCatalog, name: String)? {
        for catalog in [hugeicons, brands] {
            if let name = catalog.name(of: icon) { return (catalog, name) }
        }
        return nil
    }

    let resource: String
    let prefix: String

    private init(resource: String, prefix: String) {
        self.resource = resource
        self.prefix = prefix
    }

    /// The stroke the app's icons use on the 24-unit grid (Hugeicons draw 1.5).
    private static let strokeBoost: CGFloat = 1.75 / 1.5

    /// The name in a saved icon, if it's one of this catalog's.
    func name(of icon: String) -> String? {
        icon.hasPrefix(prefix) ? String(icon.dropFirst(prefix.count)) : nil
    }

    /// The saved form of one of this catalog's icons.
    func icon(named name: String) -> String { prefix + name }

    private struct Element {
        let path: CGPath
        let stroke: CGFloat?
        let fill: Bool
        let evenOdd: Bool
    }

    private struct Store {
        var names: [String] = []
        var raw: [String: Substring] = [:]
        /// Brands' own names ("CloudFlare"), lowercased, for search.
        var titles: [String: String] = [:]
        var shapes: [String: CGPath] = [:]
    }

    private let store: OSAllocatedUnfairLock<Store?> = OSAllocatedUnfairLock(uncheckedState: nil)

    /// Loads the catalog the first time anything asks for it.
    private func withStore<T>(_ body: (inout Store) -> T) -> T {
        store.withLockUnchecked { store in
            if store == nil { store = Self.load(resource) }
            return body(&store!)
        }
    }

    /// One icon per line: `name<TAB>shapes`, and for brands `<TAB>title`.
    private static func load(_ resource: String) -> Store {
        var store = Store()
        guard let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return store }
        for line in text.split(separator: "\n") {
            let columns = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count >= 2 else { continue }
            let name = String(columns[0])
            store.names.append(name)
            store.raw[name] = columns[1]
            if columns.count > 2 { store.titles[name] = columns[2].lowercased() }
        }
        return store
    }

    var names: [String] { withStore { $0.names } }

    func contains(_ name: String) -> Bool { withStore { $0.raw[name] != nil } }

    /// Icons whose names hold every word of the query, best matches first:
    /// a name that is the query, then names that start with it, then ones
    /// with it as a word, then ones with it inside a word (`facebook`), and
    /// shorter names first within each.
    func search(_ query: String, limit: Int = 400) -> [String] {
        let words = query.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        guard !words.isEmpty else { return [] }
        let joined = words.joined(separator: "-")
        let (names, titles) = withStore { ($0.names, $0.titles) }
        let matches = names.filter { name in
            words.allSatisfy { name.contains($0) || titles[name]?.contains($0) == true }
        }
        func rank(_ name: String) -> Int {
            if name == joined || name.hasPrefix(joined + "-0") && name.count <= joined.count + 3 { return 0 }
            if name.hasPrefix(joined) { return 1 }
            let segments = name.split(separator: "-")
            if segments.contains(where: { $0 == words[0] }) { return 2 }
            // A word starting a segment (book in notebook-01 doesn't; it
            // does in book-open-01) before one in the middle of one.
            if words.allSatisfy({ word in segments.contains { $0.hasPrefix(word) } }) { return 3 }
            return 4
        }
        return matches
            .sorted { (rank($0), $0.count, $0) < (rank($1), $1.count, $1) }
            .prefix(limit)
            .map { $0 }
    }

    /// The icon as one filled outline on its 24-unit grid, strokes included.
    func shape(_ name: String) -> CGPath? {
        withStore { store in
            if let shape = store.shapes[name] { return shape }
            guard let raw = store.raw[name] else { return nil }
            let shape = Self.outline(raw.split(separator: ";").compactMap(Self.element))
            store.shapes[name] = shape
            return shape
        }
    }

    /// The icon's outline scaled so its 24-unit grid is as tall as `rect`,
    /// centred in it.
    func shape(_ name: String, in rect: CGRect) -> CGPath? {
        guard let shape = shape(name) else { return nil }
        let scale = rect.height / 24
        var transform = CGAffineTransform(translationX: rect.midX - 12 * scale, y: rect.midY - 12 * scale)
            .scaledBy(x: scale, y: scale)
        return shape.copy(using: &transform)
    }

    /// The icon as an image for AppKit, drawn in `color`, or as a template
    /// that takes its tint from where it's drawn when there's no color.
    /// `size` is the grid's height; the image is as wide too, unless the icon
    /// runs past the grid's sides, as wide brand marks do.
    func image(_ name: String, size: CGFloat = 16, color: NSColor? = nil) -> NSImage? {
        guard let shape = shape(name) else { return nil }
        let box = shape.boundingBoxOfPath
        let units = max(24, 2 * max(12 - box.minX, box.maxX - 12))
        let image = NSImage(size: NSSize(width: size * units / 24, height: size), flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext,
                  let path = self.shape(name, in: rect) else { return false }
            context.addPath(path)
            context.setFillColor((color ?? .black).cgColor)
            context.fillPath()
            return true
        }
        image.isTemplate = color == nil
        return image
    }

    // MARK: Parsing

    /// `flags[width]:path`, as Scripts/hugeicons.swift writes it.
    private static func element(_ text: Substring) -> Element? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let head = text[..<colon]
        let flags = head.prefix { $0.isLetter }
        let width = Double(head.dropFirst(flags.count)).map { CGFloat($0) } ?? 1.5
        return Element(path: path(text[text.index(after: colon)...]),
                       stroke: flags.contains("s") ? width : nil,
                       fill: flags.contains("f"), evenOdd: flags.contains("e"))
    }

    /// Absolute M, L, Q, C and Z only.
    private static func path(_ data: Substring) -> CGPath {
        let path = CGMutablePath()
        var command: Character = "M"
        var numbers: [CGFloat] = []
        func flush() {
            var n = numbers[...]
            func point() -> CGPoint? {
                guard n.count >= 2 else { return nil }
                defer { n = n.dropFirst(2) }
                return CGPoint(x: n[n.startIndex], y: n[n.startIndex + 1])
            }
            switch command {
            case "M": if let p = point() { path.move(to: p) }
            case "L": if let p = point() { path.addLine(to: p) }
            case "Q": if let c = point(), let p = point() { path.addQuadCurve(to: p, control: c) }
            case "C": if let c1 = point(), let c2 = point(), let p = point() { path.addCurve(to: p, control1: c1, control2: c2) }
            case "Z": path.closeSubpath()
            default: break
            }
            numbers.removeAll(keepingCapacity: true)
        }
        var token = ""
        for character in data {
            if character.isLetter {
                if !token.isEmpty { numbers.append(CGFloat(Double(token) ?? 0)); token = "" }
                flush()
                command = character
            } else if character == " " {
                if !token.isEmpty { numbers.append(CGFloat(Double(token) ?? 0)); token = "" }
            } else {
                token.append(character)
            }
        }
        if !token.isEmpty { numbers.append(CGFloat(Double(token) ?? 0)) }
        flush()
        return path
    }

    private static func outline(_ elements: [Element]) -> CGPath {
        var shape: CGPath?
        for element in elements {
            var piece = element.path
            if let width = element.stroke {
                piece = element.path.copy(strokingWithWidth: width * strokeBoost, lineCap: .round, lineJoin: .round, miterLimit: 10)
                if element.fill { piece = piece.union(element.path, using: element.evenOdd ? .evenOdd : .winding) }
            } else {
                piece = piece.union(piece, using: element.evenOdd ? .evenOdd : .winding)
            }
            shape = shape.map { $0.union(piece) } ?? piece
        }
        return shape ?? CGMutablePath()
    }
}

// MARK: - SwiftUI

/// A note or folder icon: a Hugeicon or brand picked from a catalog, or one
/// of the app's named icons.
struct IconGlyph: View {
    let icon: String
    init(_ icon: String) { self.icon = icon }

    var body: some View {
        if let (catalog, name) = IconCatalog.resolve(icon) {
            CatalogGlyph(catalog: catalog, name: name)
        } else {
            Image(icon: icon)
        }
    }
}

/// A catalog icon, sized from the current font like a symbol image: its
/// 24-unit grid spans 1.104 em, as the app's custom symbols do.
struct CatalogGlyph: View {
    let catalog: IconCatalog
    let name: String

    var body: some View {
        // An em space is as wide as the font is big.
        Text("\u{2003}")
            .hidden()
            .overlay {
                GeometryReader { geometry in
                    let side = geometry.size.width * 1.104
                    // A template image, not a shape: the sidebar draws images
                    // in .secondary with vibrancy, as it does symbols, but a
                    // shape gets the flat, fainter grey.
                    let image = catalog.image(name, size: side) ?? NSImage()
                    // Wide brand marks spill a little past the em, centred.
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .frame(width: image.size.height > 0 ? side * image.size.width / image.size.height : side,
                               height: side)
                        .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
                }
            }
            .accessibilityLabel(name.replacingOccurrences(of: "-", with: " "))
    }
}
