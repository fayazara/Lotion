//
//  MediaViews.swift
//  Lotion
//
//  Images, videos and HTML blocks. Images and videos load off the main
//  thread; GitHub attachment links, which carry no extension, are asked what
//  they hold. HTML shows as a rendered preview and turns into its source
//  while you edit it.
//

import AppKit
import AVKit
import CryptoKit

// MARK: - Loading

enum MediaLoader {
    private static var images: [URL: NSImage] = [:]
    private static var kinds: [URL: MediaKind] = [:]
    private static var downloading: Set<URL> = []

    static func cachedImage(_ url: URL) -> NSImage? { images[url] }

    // MARK: The note's own copies

    /// Where a remote file is kept once fetched: a name from its address, any extension.
    private static func cacheBase(for url: URL, in directory: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    /// The saved copy of a remote file, if it was fetched before.
    static func savedCopy(of url: URL, in directory: URL?) -> URL? {
        guard !url.isFileURL, let directory else { return nil }
        let base = cacheBase(for: url, in: directory)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard let name = names.first(where: { $0.hasPrefix(base + ".") && !$0.hasSuffix(".part") }) else { return nil }
        return directory.appending(path: name)
    }

    private static func saveCopy(_ data: Data, of url: URL, response: URLResponse?, in directory: URL?) {
        guard let directory else { return }
        let ext = fileExtension(for: url, response: response)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appending(path: cacheBase(for: url, in: directory) + "." + ext), options: .atomic)
    }

    private static func fileExtension(for url: URL, response: URLResponse?) -> String {
        if let final = response?.url, MediaKind.of(final.path) != .unknown { return final.pathExtension.lowercased() }
        if MediaKind.of(url.path) != .unknown { return url.pathExtension.lowercased() }
        switch response?.mimeType ?? "" {
        case "image/png": return "png"
        case "image/jpeg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "video/mp4": return "mp4"
        case "video/quicktime": return "mov"
        case "video/webm": return "webm"
        default: return "bin"
        }
    }

    // MARK: Loading

    /// An image from disk, or fetched once and kept in `cache` (the note's folder).
    static func image(_ url: URL, cache: URL?) async -> NSImage? {
        if let cached = images[url] { return cached }
        var image: NSImage?
        let file = url.isFileURL ? url : savedCopy(of: url, in: cache)
        if let file {
            image = await withCheckedContinuation { continuation in
                CoverImages.load(file, maxPixels: 3200) { continuation.resume(returning: $0) }
            }
        } else if let (data, response) = try? await URLSession.shared.data(from: url) {
            image = NSImage(data: data)
            if image != nil { saveCopy(data, of: url, response: response, in: cache) }
        }
        if let image {
            if images.count > 80 { images.removeAll() }
            images[url] = image
        }
        return image
    }

    /// What a link holds: by its extension, its saved copy, or by asking the server.
    static func kind(of url: URL, cache: URL?) async -> MediaKind {
        let known = MediaKind.of(url.path)
        if known != .unknown { return known }
        if let copy = savedCopy(of: url, in: cache) { return MediaKind.of(copy.path) }
        if let cached = kinds[url] { return cached }
        // GitHub redirects to signed storage links that refuse HEAD; ask for one byte instead.
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        var kind = MediaKind.unknown
        if let response = try? await URLSession.shared.data(for: request).1 {
            if let type = response.mimeType {
                kind = type.hasPrefix("video/") ? .video : type.hasPrefix("image/") ? .image : .unknown
            }
            if kind == .unknown, let final = response.url { kind = MediaKind.of(final.path) }
        }
        kinds[url] = kind
        return kind
    }

    /// Where to play a video from: its saved copy if there is one. A remote
    /// video plays from the network the first time and is saved meanwhile.
    static func playableURL(_ url: URL, cache: URL?) -> URL {
        if url.isFileURL { return url }
        if let copy = savedCopy(of: url, in: cache) { return copy }
        // Videos can be large: they are kept only when Settings say so.
        guard UserDefaults.standard.bool(forKey: Prefs.saveVideos), let cache, !downloading.contains(url) else { return url }
        downloading.insert(url)
        Task.detached(priority: .utility) {
            let result = try? await URLSession.shared.download(from: url)
            await MainActor.run {
                downloading.remove(url)
                guard let (temporary, response) = result else { return }
                let ext = fileExtension(for: url, response: response)
                try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
                let destination = cache.appending(path: cacheBase(for: url, in: cache) + "." + ext)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.moveItem(at: temporary, to: destination)
            }
        }
        return url
    }

    /// An image's size in points, read from its file's header without decoding it.
    static func size(ofImageAt file: URL) -> NSSize? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat, width > 0, height > 0 else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? CGFloat).map { max(72, $0) } ?? 72
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let scale = 72 / dpi
        return orientation >= 5 ? NSSize(width: height * scale, height: width * scale) : NSSize(width: width * scale, height: height * scale)
    }

    /// A video's width over its height, or nil if it can't be read.
    static func aspect(of url: URL) async -> CGFloat? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let (size, transform) = try? await track.load(.naturalSize, .preferredTransform) else { return nil }
        let shown = size.applying(transform)
        guard abs(shown.height) > 0 else { return nil }
        return abs(shown.width) / abs(shown.height)
    }
}

/// The quiet stand-in for media that isn't on screen yet.
enum MediaPlaceholder {
    static func draw(in rect: NSRect, symbol: String, palette: ThemePalette, caption: String? = nil) {
        let path = NSBezierPath(roundedRect: rect, xRadius: MediaBlockView.radius, yRadius: MediaBlockView.radius)
        palette.codeBackground.setFill()
        path.fill()
        palette.codeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        let side = min(26, max(12, min(rect.width, rect.height) * 0.3))
        guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: side, weight: .light)) else { return }
        let icon = image.tinted(palette.marker)
        var iconRect = NSRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2, width: icon.size.width, height: icon.size.height)
        if let caption, rect.height > 70 {
            iconRect.origin.y -= 10
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: palette.secondary]
            let size = (caption as NSString).size(withAttributes: attributes)
            let width = min(size.width, rect.width - 24)
            (caption as NSString).draw(with: NSRect(x: rect.midX - width / 2, y: iconRect.maxY + 8, width: width, height: size.height),
                                       options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
        }
        icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

// MARK: - Image or video

final class MediaBlockView: BlockView {
    /// Corners of images and videos in a note.
    static let radius: CGFloat = 10

    private enum Content {
        /// Not loaded yet: what it probably is, and its size when the file says so.
        case pending(MediaKind, NSSize?)
        case image(NSImage)
        case video(AVPlayerView, CGFloat)
        case failed
    }

    private var content: Content = .pending(.unknown, nil)
    private var loadedSource: String?
    private var task: Task<Void, Never>?
    private var readyObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private let shimmer = Shimmer()
    var isShimmering: Bool { shimmer.isActive }
    /// While zoomed the media is lifted off the page; its place stays empty.
    private var isZoomed = false { didSet { needsDisplay = true } }
    private let expandButton = NSButton()
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateExpandButton() } }

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        expandButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand")
        expandButton.bezelStyle = .glass
        expandButton.controlSize = .small
        expandButton.isBordered = true
        expandButton.imagePosition = .imageOnly
        expandButton.toolTip = "Expand"
        expandButton.target = self
        expandButton.action = #selector(zoom)
        expandButton.isHidden = true
        expandButton.alphaValue = 0
        addSubview(expandButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shimmers while there is nothing to show yet.
    private func updateShimmer() {
        let loading: Bool = switch content {
        case .pending: true
        case .video(let player, _): player.isHidden
        default: false
        }
        shimmer.update(loading && window != nil ? [mediaRect] : [], radius: Self.radius, in: self, isDark: theme.palette.isDark)
    }

    override func update(_ block: Block) {
        super.update(block)
        if block.imageSource != loadedSource, window != nil { load() }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, loadedSource != block.imageSource { load() }
    }

    private func load() {
        loadedSource = block.imageSource
        task?.cancel()
        if case .video(let player, _) = content { player.player?.pause(); player.removeFromSuperview() }
        guard let url = editor?.resolveImageURL(block.imageSource),
              !url.isFileURL || FileManager.default.fileExists(atPath: url.path) else {
            content = .failed
            return
        }
        if let cached = MediaLoader.cachedImage(url) {
            content = .image(cached)
            return
        }
        let cache = editor?.mediaCacheURL
        // Its shape is known before anything loads when the file is on disk.
        let local = url.isFileURL ? url : MediaLoader.savedCopy(of: url, in: cache)
        var guess = MediaKind.of(url.path)
        if guess == .unknown, let local { guess = MediaKind.of(local.path) }
        content = .pending(guess, guess == .video ? nil : local.flatMap(MediaLoader.size(ofImageAt:)))
        task = Task { [weak self] in
            let kind = await MediaLoader.kind(of: url, cache: cache)
            guard let self, !Task.isCancelled else { return }
            if kind == .video {
                let player = AVPlayerView()
                player.controlsStyle = .inline
                let item = AVPlayerItem(url: MediaLoader.playableURL(url, cache: cache))
                player.player = AVPlayer(playerItem: item)
                player.wantsLayer = true
                player.layer?.cornerRadius = MediaBlockView.radius
                player.layer?.masksToBounds = true
                // The placeholder stays until there is a frame to show.
                player.isHidden = true
                self.addSubview(player, positioned: .below, relativeTo: self.expandButton)
                self.readyObservation = player.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self, weak player] view, _ in
                    let ready = view.isReadyForDisplay
                    DispatchQueue.main.async {
                        guard ready else { return }
                        player?.isHidden = false
                        self?.updateShimmer()
                        self?.needsDisplay = true
                    }
                }
                self.statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                    let failed = item.status == .failed
                    DispatchQueue.main.async {
                        guard failed, let self, case .video(let view, _) = self.content else { return }
                        view.removeFromSuperview()
                        self.content = .failed
                        self.contentDidChange()
                    }
                }
                self.content = .video(player, 16 / 9)
                self.contentDidChange()
                if let aspect = await MediaLoader.aspect(of: url), !Task.isCancelled, abs(aspect - 16 / 9) > 0.01 {
                    self.content = .video(player, aspect)
                    self.contentDidChange()
                }
                return
            }
            let image = await MediaLoader.image(url, cache: cache)
            guard !Task.isCancelled else { return }
            self.content = image.map { .image($0) } ?? .failed
            self.contentDidChange()
        }
    }

    private func contentDidChange() {
        window?.invalidateCursorRects(for: self)
        updateShimmer()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor?.blockHeightMayHaveChanged(block.id)
    }

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }

    /// The media's size in a column `available` wide.
    private func shownSize(available: CGFloat) -> NSSize {
        func fitted(_ size: NSSize) -> NSSize {
            guard size.width > 0, size.height > 0 else { return NSSize(width: available, height: round(available * 9 / 16)) }
            let width = min(available, size.width)
            return NSSize(width: width, height: round(width * size.height / size.width))
        }
        switch content {
        case .pending(_, let size?): return fitted(size)
        case .pending: return NSSize(width: available, height: round(available * 9 / 16))
        case .image(let image): return fitted(image.size)
        case .video(_, let aspect): return NSSize(width: available, height: round(available / max(0.2, aspect)))
        case .failed: return NSSize(width: available, height: 120)
        }
    }

    override func measure(width: CGFloat) -> CGFloat {
        shownSize(available: width - indent).height + 8
    }

    private var mediaRect: NSRect {
        let size = shownSize(available: bounds.width - indent)
        return NSRect(x: indent, y: 4, width: size.width, height: size.height)
    }

    override var selectionShape: (rect: NSRect, radius: CGFloat) { (mediaRect, Self.radius) }

    override func layoutContent() {
        if case .video(let player, _) = content, player.superview === self { player.frame = mediaRect }
        let size = expandButton.fittingSize
        let rect = mediaRect
        expandButton.frame = NSRect(x: rect.maxX - size.width - 8, y: rect.minY + 8, width: size.width, height: size.height)
        updateShimmer()
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let rect = mediaRect
        switch content {
        case .image where isZoomed:
            break
        case .image(let image):
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: Self.radius, yRadius: Self.radius).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        case .video(let player, _):
            if player.isHidden { MediaPlaceholder.draw(in: rect, symbol: "play.rectangle", palette: palette) }
        case .pending(let kind, _):
            MediaPlaceholder.draw(in: rect, symbol: kind == .image ? "photo" : "play.rectangle", palette: palette)
        case .failed:
            let name = block.imageAlt.isEmpty ? (block.imageSource as NSString).lastPathComponent : block.imageAlt
            MediaPlaceholder.draw(in: rect, symbol: "photo.badge.exclamationmark", palette: palette, caption: "Can’t show “\(name)”")
        }
    }

    override var firstLineMidY: CGFloat { 16 }

    /// A click zooms an image (⇧- or ⌘-click selects the block instead); a
    /// double-click opens it in its app.
    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        let selects = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if !selects, case .image = content, mediaRect.contains(point) {
            zoom()
            return true
        }
        if event.clickCount == 2 {
            openInApp()
            return true
        }
        editor?.selectBlocks([block.id])
        return true
    }

    private func openInApp() {
        guard let url = editor?.resolveImageURL(block.imageSource) else { return }
        NSWorkspace.shared.open(MediaLoader.savedCopy(of: url, in: editor?.mediaCacheURL) ?? url)
    }

    @objc func zoom() {
        let media: MediaZoom.Content
        switch content {
        case .image(let image): media = .image(image)
        case .video(let player, _) where !player.isHidden: media = .video(player)
        default: return
        }
        isHovered = false
        MediaZoom.shared.show(MediaZoom.Request(
            content: media,
            rect: { [weak self] in self?.window != nil ? self?.mediaRect : nil },
            source: self,
            radius: Self.radius,
            backdrop: theme.palette.background,
            setOriginalHidden: { [weak self] hidden in self?.isZoomed = hidden },
            onDoubleClick: { [weak self] in self?.openInApp() }
        ))
    }

    // MARK: Hover

    private func updateExpandButton() {
        let isVideo: Bool = if case .video(let player, _) = content { !player.isHidden && player.superview === self } else { false }
        let show = isHovered && isVideo && !isZoomed
        guard show != !expandButton.isHidden || expandButton.alphaValue != (show ? 1 : 0) else { return }
        if show { expandButton.isHidden = false }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = show ? 0.15 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            expandButton.animator().alphaValue = show ? 1 : 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !show, !self.isHovered else { return }
                self.expandButton.isHidden = true
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func resetCursorRects() {
        super.resetCursorRects()
        if case .image = content { addCursorRect(mediaRect, cursor: ZoomCursor.zoomIn) }
    }
}

// MARK: - HTML

/// A rendered piece of an HTML block.
struct HTMLRow {
    enum Kind {
        case text(NSAttributedString)
        case images([HTMLImage])
        case video(String)
        case space(CGFloat)
    }

    var kind: Kind
    var alignment: NSTextAlignment
}

struct HTMLImage {
    var source: String
    var alt: String
    var width: CGFloat?
    var height: CGFloat?
    var link: String?
}

/// Just enough HTML for READMEs and notes: text with links and emphasis,
/// images (linked or not), videos, line breaks and centered paragraphs.
enum MiniHTML {
    /// Markdown images (and linked images) as the HTML they stand for, so a
    /// row of README badges renders like any other images.
    static func expandMarkdownImages(_ text: String) -> String {
        guard text.contains("![") else { return text }
        var result = text
        let linked = try! NSRegularExpression(pattern: #"\[!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)\]\(([^)\s]+)\)"#)
        result = linked.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                                 withTemplate: "<a href=\"$3\"><img src=\"$2\" alt=\"$1\"></a>")
        let plain = try! NSRegularExpression(pattern: #"!\[([^\]]*)\]\(([^)\s]+)(?:\s+"[^"]*")?\)"#)
        return plain.stringByReplacingMatches(in: result, range: NSRange(location: 0, length: (result as NSString).length),
                                              withTemplate: "<img src=\"$2\" alt=\"$1\">")
    }

    static func render(_ source: String, theme: BlockTheme) -> [HTMLRow] {
        let html = expandMarkdownImages(source)
        var rows: [HTMLRow] = []
        var text = NSMutableAttributedString()
        var images: [HTMLImage] = []
        var alignments: [NSTextAlignment] = [.natural]
        var links: [String] = []
        var bold = 0, italic = 0, code = 0, heading = 0
        var listDepth = 0

        func alignment() -> NSTextAlignment { alignments.last ?? .natural }

        func flushText() {
            let trimmed = text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                // Drop the whitespace at the edges, keeping attributes.
                let string = text.string as NSString
                var start = 0, end = string.length
                while start < end, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: start)) ?? " ") { start += 1 }
                while end > start, CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(string.character(at: end - 1)) ?? " ") { end -= 1 }
                let piece = NSMutableAttributedString(attributedString: text.attributedSubstring(from: NSRange(location: start, length: end - start)))
                let style = NSMutableParagraphStyle()
                style.alignment = alignment()
                style.lineHeightMultiple = 1.15
                piece.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: piece.length))
                rows.append(HTMLRow(kind: .text(piece), alignment: alignment()))
            }
            text = NSMutableAttributedString()
        }

        func flushImages() {
            if !images.isEmpty { rows.append(HTMLRow(kind: .images(images), alignment: alignment())) }
            images = []
        }

        func flush() {
            flushText()
            flushImages()
        }

        func attributes() -> [NSAttributedString.Key: Any] {
            var font = heading > 0 ? theme.headings[min(5, heading - 1)] : theme.body
            if code > 0 { font = theme.inlineCode }
            if bold > 0 || italic > 0 { font = theme.styled(font, bold: bold > 0, italic: italic > 0) }
            var result: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: theme.palette.text]
            if let link = links.last, !link.isEmpty {
                result[.foregroundColor] = theme.palette.accent
                result[.lotionLink] = link
            }
            return result
        }

        let blockTags: Set<String> = ["p", "div", "center", "section", "ul", "ol", "li", "blockquote", "table", "tr", "details", "summary", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "figure", "header", "footer"]
        let scanner = html as NSString
        var index = 0
        let length = scanner.length
        while index < length {
            let open = scanner.range(of: "<", options: [], range: NSRange(location: index, length: length - index))
            let textEnd = open.location == NSNotFound ? length : open.location
            if textEnd > index {
                let raw = scanner.substring(with: NSRange(location: index, length: textEnd - index))
                let collapsed = decodeEntities(raw.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression))
                if !collapsed.trimmingCharacters(in: .whitespaces).isEmpty || text.length > 0 {
                    if !collapsed.trimmingCharacters(in: .whitespaces).isEmpty { flushImages() }
                    text.append(NSAttributedString(string: collapsed, attributes: attributes()))
                }
            }
            guard open.location != NSNotFound else { break }
            if scanner.substring(from: open.location).hasPrefix("<!--") {
                let close = scanner.range(of: "-->", options: [], range: NSRange(location: open.location, length: length - open.location))
                index = close.location == NSNotFound ? length : NSMaxRange(close)
                continue
            }
            let close = scanner.range(of: ">", options: [], range: NSRange(location: open.location, length: length - open.location))
            guard close.location != NSNotFound else { break }
            let tagText = scanner.substring(with: NSRange(location: open.location + 1, length: close.location - open.location - 1))
            index = NSMaxRange(close)
            let closing = tagText.hasPrefix("/")
            let body = closing ? String(tagText.dropFirst()) : tagText
            let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()
            let attrs = attributesOf(body)

            switch name {
            case "br":
                if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && images.isEmpty {
                    rows.append(HTMLRow(kind: .space(round(theme.em * 0.6)), alignment: alignment()))
                }
                flush()
            case "img":
                if !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { flushText() } else { text = NSMutableAttributedString() }
                if let source = attrs["src"] {
                    images.append(HTMLImage(source: source, alt: attrs["alt"] ?? "", width: attrs["width"].flatMap(dimension),
                                            height: attrs["height"].flatMap(dimension), link: links.last))
                }
            case "video", "source":
                if let source = attrs["src"] {
                    flush()
                    rows.append(HTMLRow(kind: .video(source), alignment: alignment()))
                }
            case "a":
                if closing { _ = links.popLast() } else { links.append(attrs["href"] ?? "") }
            case "b", "strong":
                bold += closing ? -1 : 1
            case "i", "em":
                italic += closing ? -1 : 1
            case "code", "kbd":
                code += closing ? -1 : 1
            case "hr":
                flush()
                rows.append(HTMLRow(kind: .space(round(theme.em * 0.8)), alignment: alignment()))
            default:
                guard blockTags.contains(name) else { break }
                flush()
                if name.first == "h", let level = Int(name.dropFirst()) { heading = closing ? 0 : level }
                if name == "ul" || name == "ol" { listDepth += closing ? -1 : 1 }
                if name == "li", !closing { text.append(NSAttributedString(string: String(repeating: "   ", count: max(0, listDepth - 1)) + "•  ", attributes: attributes())) }
                if closing {
                    if alignments.count > 1, ["p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "section", "figure"].contains(name) {
                        alignments.removeLast()
                    }
                } else if ["p", "div", "center", "h1", "h2", "h3", "h4", "h5", "h6", "section", "figure"].contains(name) {
                    let align = (attrs["align"] ?? "").lowercased()
                    let style = (attrs["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
                    if name == "center" || align == "center" || style.contains("text-align:center") {
                        alignments.append(.center)
                    } else if align == "right" || style.contains("text-align:right") {
                        alignments.append(.right)
                    } else {
                        alignments.append(alignment())
                    }
                }
            }
        }
        flush()
        // Leading and trailing gaps add nothing.
        while let first = rows.first, case .space = first.kind { rows.removeFirst() }
        while let last = rows.last, case .space = last.kind { rows.removeLast() }
        return rows
    }

    private static func dimension(_ value: String) -> CGFloat? {
        let digits = value.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "px", with: "")
        guard let number = Double(digits), number > 0 else { return nil }
        return CGFloat(number)
    }

    static func attributesOf(_ tag: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Za-z_:][-A-Za-z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>/]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = tag as NSString
        for match in regex.matches(in: tag, range: NSRange(location: 0, length: ns.length)) {
            let key = ns.substring(with: match.range(at: 1)).lowercased()
            for group in 2...4 where match.range(at: group).location != NSNotFound {
                result[key] = decodeEntities(ns.substring(with: match.range(at: group)))
                break
            }
        }
        return result
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        let named = ["&nbsp;": "\u{00A0}", "&middot;": "·", "&copy;": "©", "&reg;": "®", "&mdash;": "—", "&ndash;": "–",
                     "&hellip;": "…", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&bull;": "•"]
        for (entity, value) in named { result = result.replacingOccurrences(of: entity, with: value) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9A-Fa-f]+);"#) {
            let ns = result as NSString
            var output = ""
            var last = 0
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)) {
                output += ns.substring(with: NSRange(location: last, length: match.range.location - last))
                let hex = ns.substring(with: match.range(at: 1)) == "x"
                if let value = UInt32(ns.substring(with: match.range(at: 2)), radix: hex ? 16 : 10), let scalar = UnicodeScalar(value) {
                    output.unicodeScalars.append(scalar)
                }
                last = NSMaxRange(match.range)
            }
            output += ns.substring(from: last)
            result = output
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// An HTML block: a preview, or its source while the caret is in it.
final class HTMLBlockView: BlockView {
    private(set) var textView: BlockTextView?
    private(set) var isEditing = false
    private var rows: [HTMLRow] = []
    private var rowFrames: [NSRect] = []
    private var imageFrames: [(NSRect, HTMLImage)] = []
    private var images: [String: NSImage] = [:]
    /// Sizes read from files on disk before the images themselves load.
    private var knownSizes: [String: NSSize] = [:]
    private var failedImages: Set<String> = []
    private var players: [String: AVPlayerView] = [:]
    private var aspects: [String: CGFloat] = [:]
    private var renderedSource: String?
    /// Images in the preview, and how many have loaded (for tests).
    var imageCounts: (shown: Int, loaded: Int) {
        let sources = rows.flatMap { row -> [String] in if case .images(let list) = row.kind { return list.map(\.source) }; return [] }
        return (sources.count, sources.filter { images[$0] != nil }.count)
    }
    private let editButton = NSButton(title: "Edit HTML", target: nil, action: nil)
    private let shimmer = Shimmer()
    private var tracking: NSTrackingArea?

    private static let padding: CGFloat = 4
    /// Space between the preview and the source under it while editing.
    private static let sourceGap: CGFloat = 10

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        editButton.bezelStyle = .glass
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(toggleEditing)
        editButton.isHidden = true
        addSubview(editButton)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTextView: BlockTextView? {
        beginEditing()
        return textView
    }

    override var isMaterialized: Bool { true }

    private func render() {
        guard renderedSource != block.text.string else { return }
        renderedSource = block.text.string
        rows = MiniHTML.render(block.text.string, theme: theme)
        for (source, player) in players where !rows.contains(where: { if case .video(source) = $0.kind { return true }; return false }) {
            player.removeFromSuperview()
            players[source] = nil
        }
        loadMedia()
    }

    private func loadMedia() {
        guard let editor else { return }
        for row in rows {
            switch row.kind {
            case .images(let list):
                for image in list where images[image.source] == nil && !failedImages.contains(image.source) {
                    guard let url = editor.resolveImageURL(image.source) else { failedImages.insert(image.source); continue }
                    let cache = editor.mediaCacheURL
                    if let local = url.isFileURL ? url : MediaLoader.savedCopy(of: url, in: cache),
                       let size = MediaLoader.size(ofImageAt: local) { knownSizes[image.source] = size }
                    Task { [weak self] in
                        let loaded = await MediaLoader.image(url, cache: cache)
                        guard let self else { return }
                        if let loaded { self.images[image.source] = loaded } else { self.failedImages.insert(image.source) }
                        self.mediaDidLoad()
                    }
                }
            case .video(let source):
                guard players[source] == nil, let url = editor.resolveImageURL(source) else { continue }
                let player = AVPlayerView()
                player.controlsStyle = .inline
                player.player = AVPlayer(url: MediaLoader.playableURL(url, cache: editor.mediaCacheURL))
                player.wantsLayer = true
                player.layer?.cornerRadius = MediaBlockView.radius
                player.layer?.masksToBounds = true
                addSubview(player, positioned: .below, relativeTo: editButton)
                players[source] = player
                Task { [weak self] in
                    let aspect = await MediaLoader.aspect(of: url)
                    guard let self, let aspect else { return }
                    self.aspects[source] = aspect
                    self.mediaDidLoad()
                }
            default:
                break
            }
        }
    }

    private func mediaDidLoad() {
        window?.invalidateCursorRects(for: self)
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor?.blockHeightMayHaveChanged(block.id)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { render() }
    }

    override func update(_ block: Block) {
        super.update(block)
        if let textView, textView.string != block.text.string {
            textView.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
        }
        if !isEditing { render() }
        needsDisplay = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        renderedSource = nil
        if window != nil { render() }
        if let textView { configure(textView) }
        needsDisplay = true
    }

    // MARK: Editing the source

    func beginEditing() {
        guard !isEditing, let editor else { return }
        isEditing = true
        if textView == nil {
            let view = BlockTextView(blockID: block.id, width: 100)
            view.editor = editor
            view.delegate = editor
            view.isRichText = false
            configure(view)
            view.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
            addSubview(view)
            textView = view
        }
        textView?.isHidden = false
        highlightSource()
        updateButton()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor.blockHeightMayHaveChanged(block.id)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView?.isHidden = true
        updateButton()
        render()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor?.blockHeightMayHaveChanged(block.id)
    }

    private func configure(_ view: BlockTextView) {
        view.typingAttributes = theme.baseAttributes(for: .code)
        view.insertionPointColor = theme.palette.text
        view.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.placeholder = "HTML"
        view.placeholderColor = theme.palette.marker
        view.placeholderFont = theme.code
        view.placeholderOffset = theme.baselineOffset(for: .raw)
    }

    // MARK: Layout

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }

    override func measure(width: CGFloat) -> CGFloat {
        let available = width - indent
        let preview = previewHeight(width: available)
        guard isEditing else { return preview }
        return (preview > 0 ? preview + Self.sourceGap : 0) + sourceHeight(width: available)
    }

    /// The rendered part's height; zero when the HTML renders to nothing.
    private func previewHeight(width: CGFloat) -> CGFloat {
        if rows.isEmpty {
            let source = block.text.string.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return isEditing ? 0 : 44 }
            // Only line breaks or comments: just the space they make.
            let breaks = source.components(separatedBy: "<br").count - 1
            return isEditing && breaks == 0 ? 0 : max(8, round(theme.em * 0.6) * CGFloat(breaks))
        }
        return layoutRows(width: width, apply: false)
    }

    private func sourceHeight(width: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: textView?.string ?? block.text.string, attributes: theme.baseAttributes(for: .code))
        return TextMeasurer.shared.height(of: text, width: max(20, width - 32), base: theme.baseAttributes(for: .code)) + 24
    }

    private var sourceRect: NSRect {
        let available = bounds.width - indent
        let preview = previewHeight(width: available)
        let top = preview > 0 ? preview + Self.sourceGap : 0
        return NSRect(x: indent, y: top, width: available, height: max(0, bounds.height - top))
    }

    /// Stacks the rows; returns the height. With `apply`, records their frames.
    @discardableResult
    private func layoutRows(width: CGFloat, apply: Bool) -> CGFloat {
        var y = Self.padding
        var frames: [NSRect] = []
        var imageFrames: [(NSRect, HTMLImage)] = []
        for row in rows {
            var rect: NSRect
            switch row.kind {
            case .text(let text):
                let size = text.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin, .usesFontLeading])
                rect = NSRect(x: indent, y: y, width: width, height: ceil(size.height) + 2)
            case .images(let list):
                var sizes = list.map { image -> NSSize in
                    let natural = images[image.source]?.size ?? knownSizes[image.source]
                    // Unknown sizes wait in a 16:9 frame.
                    var w = image.width ?? natural?.width ?? width
                    var h = image.height ?? natural.map { $0.height * (w / max(1, $0.width)) } ?? round(w * 9 / 16)
                    if image.width != nil, image.height == nil, let natural, natural.width > 0 { h = natural.height * w / natural.width }
                    if image.height != nil, image.width == nil, let natural, natural.height > 0 { w = natural.width * h / natural.height }
                    return NSSize(width: w, height: h)
                }
                let gap: CGFloat = 6
                let total = sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, sizes.count - 1))
                if total > width {
                    let scale = (width - gap * CGFloat(max(0, sizes.count - 1))) / max(1, total - gap * CGFloat(max(0, sizes.count - 1)))
                    sizes = sizes.map { NSSize(width: floor($0.width * scale), height: floor($0.height * scale)) }
                }
                let rowWidth = min(width, sizes.reduce(0) { $0 + $1.width } + gap * CGFloat(max(0, sizes.count - 1)))
                let height = sizes.map(\.height).max() ?? 0
                var x = indent + offset(for: row.alignment, content: rowWidth, width: width)
                for (index, size) in sizes.enumerated() {
                    imageFrames.append((NSRect(x: x, y: y + (height - size.height) / 2, width: size.width, height: size.height), list[index]))
                    x += size.width + gap
                }
                rect = NSRect(x: indent, y: y, width: width, height: height)
            case .video(let source):
                let aspect = aspects[source] ?? 16 / 9
                rect = NSRect(x: indent, y: y, width: width, height: round(width / aspect))
            case .space(let height):
                rect = NSRect(x: indent, y: y, width: width, height: height)
            }
            frames.append(rect)
            y = rect.maxY + 6
        }
        if apply {
            rowFrames = frames
            self.imageFrames = imageFrames
        }
        return max(28, y - 6 + Self.padding)
    }

    private func offset(for alignment: NSTextAlignment, content: CGFloat, width: CGFloat) -> CGFloat {
        switch alignment {
        case .center: round((width - content) / 2)
        case .right: width - content
        default: 0
        }
    }

    override func layoutContent() {
        let available = bounds.width - indent
        if let textView, isEditing {
            textView.frame = sourceRect.insetBy(dx: 16, dy: 12)
        }
        let size = editButton.fittingSize
        editButton.frame = NSRect(x: bounds.width - size.width - 6, y: 6, width: size.width, height: size.height)
        layoutRows(width: available, apply: true)
        for (index, row) in rows.enumerated() where index < rowFrames.count {
            if case .video(let source) = row.kind { players[source]?.frame = rowFrames[index] }
        }
        let loading = imageFrames.filter { images[$0.1.source] == nil && !failedImages.contains($0.1.source) }.map(\.0)
        shimmer.update(window != nil ? loading : [], radius: 8, in: self, isDark: theme.palette.isDark)
    }

    override var firstLineMidY: CGFloat { min(14, bounds.height / 2) }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        if isEditing {
            let box = sourceRect
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            palette.codeBackground.setFill()
            path.fill()
            palette.codeBorder.setStroke()
            path.stroke()
        } else if rows.isEmpty, block.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            MediaPlaceholder.draw(in: NSRect(x: indent, y: 0, width: bounds.width - indent, height: bounds.height),
                                  symbol: "chevron.left.forwardslash.chevron.right", palette: palette)
        }
        for (index, row) in rows.enumerated() where index < rowFrames.count {
            if case .text(let text) = row.kind {
                text.draw(with: rowFrames[index], options: [.usesLineFragmentOrigin, .usesFontLeading])
            }
        }
        for (rect, image) in imageFrames where !zoomedImages.contains(image.source) {
            if let loaded = images[image.source] {
                NSGraphicsContext.saveGraphicsState()
                let corner = min(MediaBlockView.radius, rect.height / 4, rect.width / 4)
                NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner).addClip()
                loaded.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                            hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            } else if failedImages.contains(image.source) {
                MediaPlaceholder.draw(in: rect, symbol: "photo.badge.exclamationmark", palette: palette,
                                      caption: image.alt.isEmpty ? nil : image.alt)
            } else {
                MediaPlaceholder.draw(in: rect, symbol: "photo", palette: palette)
            }
        }
    }

    // MARK: Clicks

    /// The link under a point of the preview.
    private func link(at point: NSPoint) -> String? {
        for (rect, image) in imageFrames where rect.contains(point) { return image.link ?? image.source }
        for (index, row) in rows.enumerated() where index < rowFrames.count && rowFrames[index].contains(point) {
            guard case .text(let text) = row.kind else { continue }
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: rowFrames[index].width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layout)
            layout.addTextContainer(container)
            let local = NSPoint(x: point.x - rowFrames[index].minX, y: point.y - rowFrames[index].minY)
            let glyph = layout.glyphIndex(for: local, in: container)
            guard layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container).contains(local) else { return nil }
            let character = layout.characterIndexForGlyph(at: glyph)
            return text.attribute(.lotionLink, at: character, effectiveRange: nil) as? String
        }
        return nil
    }

    /// A click selects the block, or zooms an image that isn't a link
    /// (⌘-click opens a link); a double-click edits its source.
    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), let link = link(at: point) {
            editor?.open(link: link)
            return true
        }
        if event.modifierFlags.intersection([.shift, .command]).isEmpty, !isEditing,
           let (rect, image) = imageFrames.first(where: { $0.0.contains(point) && $0.1.link == nil }),
           let loaded = images[image.source] {
            zoom(loaded, source: image.source, rect: rect)
            return true
        }
        if event.clickCount == 2 {
            editor?.focus(block.id, .start)
        } else {
            editor?.selectBlocks([block.id])
        }
        return true
    }

    /// Sources of images lifted off the page by a zoom.
    private var zoomedImages: Set<String> = [] { didSet { needsDisplay = true } }

    private func zoom(_ image: NSImage, source: String, rect: NSRect) {
        let corner = min(MediaBlockView.radius, rect.height / 4, rect.width / 4)
        MediaZoom.shared.show(MediaZoom.Request(
            content: .image(image),
            rect: { [weak self] in
                guard let self, self.window != nil else { return nil }
                return self.imageFrames.first { $0.1.source == source }?.0 ?? rect
            },
            source: self,
            radius: corner,
            backdrop: theme.palette.background,
            setOriginalHidden: { [weak self] hidden in
                if hidden { self?.zoomedImages.insert(source) } else { self?.zoomedImages.remove(source) }
            },
            onDoubleClick: { [weak self] in
                guard let self else { return }
                self.editor?.focus(self.block.id, .start)
            }
        ))
    }

    @objc private func toggleEditing() {
        if isEditing {
            editor?.selectBlocks([block.id])
        } else {
            editor?.focus(block.id, .end)
        }
    }

    private func updateButton() {
        editButton.title = isEditing ? "Done" : "Edit HTML"
        editButton.isHidden = !(isEditing || isHovered)
        needsLayout = true
    }

    private var isHovered = false { didSet { updateButton() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// The source changed while editing: the preview follows it.
    func sourceDidChange() {
        render()
        highlightSource()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
    }

    /// Colors the source as HTML, without touching its layout.
    private func highlightSource() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let code = textView.string
        let full = NSRange(location: 0, length: (code as NSString).length)
        guard let runs = CodeHighlighter.shared.runs(for: code, language: "html", theme: theme.palette.shikiTheme) else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for run in runs {
            guard let hex = run.color, let color = CodeHighlighter.shared.color(hex) else { continue }
            let range = NSIntersectionRange(NSRange(location: run.location, length: run.length), full)
            if range.length > 0 { layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range) }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard !isEditing else { return }
        for (rect, image) in imageFrames {
            if image.link != nil {
                addCursorRect(rect, cursor: .pointingHand)
            } else if images[image.source] != nil {
                addCursorRect(rect, cursor: ZoomCursor.zoomIn)
            }
        }
    }
}
