//
//  Covers.swift
//  Lotion
//
//  A note's cover: an image across the top of the editor, Notion style. It
//  is a macOS wallpaper, an Unsplash photo or an image the user picked; the
//  last two are copied into the library's `.lotion/covers`, so a cover never
//  depends on the network or on a file elsewhere staying put.
//

import AppKit
import ImageIO

struct NoteCover: Codable, Equatable {
    /// An absolute path for a system wallpaper, otherwise a file name in the
    /// library's covers folder.
    var file: String
    /// The photographer, for Unsplash photos.
    var credit: String?
    var creditURL: URL?
    /// Which part of the image shows: 0 is its top edge, 1 its bottom.
    var position: Double = 0.5

    func url(in library: Library) -> URL {
        file.hasPrefix("/") ? URL(fileURLWithPath: file) : library.coversDirectory.appending(path: file)
    }
}

// MARK: - Sources

/// The wallpapers macOS ships at full size. Most others in the folder are
/// downloaded on demand, and only their small thumbnails are on disk.
enum SystemWallpapers {
    struct Wallpaper: Identifiable, Hashable {
        let name: String
        let url: URL
        let thumbnail: URL
        var id: URL { url }
    }

    static let all: [Wallpaper] = {
        let folder = URL(fileURLWithPath: "/System/Library/Desktop Pictures", isDirectory: true)
        let thumbnails = folder.appending(path: ".thumbnails", directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { ["heic", "jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                let thumbnail = thumbnails.appending(path: url.lastPathComponent)
                let hasThumbnail = FileManager.default.fileExists(atPath: thumbnail.path)
                return Wallpaper(name: url.deletingPathExtension().lastPathComponent, url: url,
                                 thumbnail: hasThumbnail ? thumbnail : url)
            }
    }()
}

extension Library {
    /// A wallpaper picked at random, as Notion does, to change from there.
    func addRandomCover(for note: Note) {
        guard let wallpaper = SystemWallpapers.all.randomElement() else { return }
        setCover(NoteCover(file: wallpaper.url.path), for: note)
    }

    /// Copies a picked image into the covers folder and makes it the note's cover.
    func importCover(from source: URL, for note: Note) {
        let ext = source.pathExtension.isEmpty ? "jpg" : source.pathExtension.lowercased()
        let name = "\(UUID().uuidString).\(ext)"
        do {
            try FileManager.default.createDirectory(at: coversDirectory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: coversDirectory.appending(path: name))
        } catch {
            errorMessage = "The image could not be added as a cover. \(error.localizedDescription)"
            return
        }
        setCover(NoteCover(file: name), for: note)
    }

    /// Downloads an Unsplash photo into the covers folder and makes it the note's cover.
    func setUnsplashCover(_ photo: UnsplashPhoto, for note: Note) async {
        do {
            let file = try await UnsplashClient.download(photo, to: coversDirectory)
            setCover(NoteCover(file: file.lastPathComponent, credit: photo.user.name, creditURL: photo.photographerURL), for: note)
        } catch {
            errorMessage = "The photo could not be downloaded. \(error.localizedDescription)"
        }
    }
}

// MARK: - Loading

/// Decodes cover images off the main thread, scaled down to what a cover
/// needs: a 6K wallpaper would otherwise cost hundreds of megabytes.
@MainActor
enum CoverImages {
    private struct Key: Hashable { let url: URL; let maxPixels: Int }
    private static var cache: [Key: NSImage] = [:]
    private static var pending: [Key: [(NSImage?) -> Void]] = [:]

    static func cached(_ url: URL, maxPixels: Int = 2800) -> NSImage? { cache[Key(url: url, maxPixels: maxPixels)] }

    static func load(_ url: URL, maxPixels: Int = 2800, completion: @escaping (NSImage?) -> Void) {
        let key = Key(url: url, maxPixels: maxPixels)
        if let image = cache[key] { return completion(image) }
        if pending[key] != nil { pending[key]?.append(completion); return }
        pending[key] = [completion]
        Task.detached(priority: .userInitiated) {
            let image = downsample(url, maxPixels: maxPixels)
            await MainActor.run {
                if let image {
                    if cache.count > 24 { cache.removeAll() }
                    cache[key] = image
                }
                for callback in pending.removeValue(forKey: key) ?? [] { callback(image) }
            }
        }
    }

    nonisolated static func downsample(_ url: URL, maxPixels: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }
}
