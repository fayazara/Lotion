//
//  EmbedBlockView.swift
//  Lotion
//
//  A link alone on its line, shown as what it points at: a bookmark card
//  with the page's picture, title and description; a video that plays in
//  place; a live player (Spotify, Apple Music, Figma, CodePen, an iframe);
//  a GitHub repository or issue; a post from X; or a map. The note keeps
//  only the link, so it reads the same in any other Markdown app.
//

import AppKit
import MapKit
import WebKit

final class EmbedBlockView: BlockView, WKUIDelegate, WKNavigationDelegate {
    private var target: EmbedTarget?
    private(set) var webView: EmbedWebView?
    /// What the block shows, for tests.
    var shownTarget: EmbedTarget? { target }
    var reportedPostHeight: CGFloat? { postHeight }
    private var isPlaying = false
    /// A post's height, as its page reports it.
    private var postHeight: CGFloat?
    private var mapImage: NSImage?
    private var mapKey: String?
    private var loadObserver: NSObjectProtocol?
    private let menuButton = NSButton()
    private let field = NSTextField()
    private let shimmer = Shimmer()
    private var tracking: NSTrackingArea?
    private var isHovered = false {
        didSet {
            menuButton.isHidden = !isHovered || source.isEmpty
            if !isHovered { webView?.isEngaged = false }
            needsDisplay = true
        }
    }

    static let radius: CGFloat = 12
    /// The web address wrapper pages are given, so players see a referrer.
    private static let frameBase = URL(string: "https://com.fayazahmed.lotion/")!

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        menuButton.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "Options")
        menuButton.bezelStyle = .glass
        menuButton.controlSize = .small
        menuButton.imagePosition = .imageOnly
        menuButton.target = self
        menuButton.action = #selector(showMenu)
        menuButton.isHidden = true
        addSubview(menuButton)

        field.placeholderString = "Paste a link — a page, YouTube, Spotify, GitHub, X, Figma, a map…"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.target = self
        field.action = #selector(commitField)
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        addSubview(field)

        loadObserver = NotificationCenter.default.addObserver(forName: EmbedCache.didLoad, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.factsDidLoad() }
        }
        resolve()
    }

    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        if let loadObserver { NotificationCenter.default.removeObserver(loadObserver) }
    }

    // MARK: Source

    /// The link: the block's source, or an iframe's `src`.
    private var source: String {
        if block.kind == .html { return IframeHTML.parse(block.text.string)?.source ?? "" }
        return block.imageSource
    }

    private func resolve() {
        let old = target
        if block.kind == .html, let frame = IframeHTML.parse(block.text.string), let url = URL(string: frame.source) {
            target = .frame(url, height: frame.height, name: url.host ?? "Embed")
        } else {
            target = EmbedTarget.classify(block.imageSource)
        }
        if old != target {
            tearDownWeb()
            isPlaying = false
            postHeight = nil
            mapImage = nil
            mapKey = nil
        }
        field.isHidden = !source.isEmpty
        if case .frame = target, window != nil { startWeb() }
        if case .post = target, window != nil { startWeb() }
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
    }

    override func update(_ block: Block) {
        super.update(block)
        resolve()
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        mapImage = nil
        mapKey = nil
        // A post's colors come from its page; draw it again in the new theme.
        if case .post = target, webView != nil { tearDownWeb(); startWeb() }
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        switch target {
        case .frame, .post: startWeb()
        case nil where source.isEmpty:
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.source.isEmpty else { return }
                self.window?.makeFirstResponder(self.field)
            }
        default: break
        }
    }

    private func factsDidLoad() {
        guard window != nil else { return }
        invalidateHeight()
        editor?.blockHeightMayHaveChanged(block.id)
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Facts

    private var bookmarkFacts: [String: String]? {
        guard case .bookmark(let url) = target else { return nil }
        return EmbedCache.facts(url.absoluteString) { await EmbedCache.pageFacts(url) }
    }

    private func videoFacts(_ site: VideoSite, page: URL) -> [String: String]? {
        let endpoint = switch site {
        case .youtube: "https://www.youtube.com/oembed?format=json"
        case .vimeo: "https://vimeo.com/api/oembed.json?width=1280"
        case .loom: "https://www.loom.com/v1/oembed?format=json"
        }
        return EmbedCache.facts("oembed:" + page.absoluteString) { await EmbedCache.oEmbed(endpoint, for: page) }
    }

    private func githubFacts(_ ref: GitHubRef) -> [String: String]? {
        let id = "github:\(ref.slug)#\(ref.number.map(String.init) ?? "")"
        return EmbedCache.facts(id, maxAge: 60 * 60 * 12) {
            let headers = ["Accept": "application/vnd.github+json"]
            if let number = ref.number {
                guard let issue = await EmbedCache.json("https://api.github.com/repos/\(ref.slug)/issues/\(number)", headers: headers) else { return nil }
                var facts: [String: String] = [
                    "title": issue["title"] as? String ?? "",
                    "state": issue["state"] as? String ?? "open",
                    "author": (issue["user"] as? [String: Any])?["login"] as? String ?? "",
                    "avatar": (issue["user"] as? [String: Any])?["avatar_url"] as? String ?? "",
                    "comments": "\(issue["comments"] as? Int ?? 0)",
                    "pull": issue["pull_request"] != nil ? "1" : "0",
                    "reason": issue["state_reason"] as? String ?? "",
                ]
                if issue["pull_request"] != nil,
                   let pull = await EmbedCache.json("https://api.github.com/repos/\(ref.slug)/pulls/\(number)", headers: headers) {
                    if pull["merged"] as? Bool == true { facts["state"] = "merged" }
                    if pull["draft"] as? Bool == true, facts["state"] == "open" { facts["state"] = "draft" }
                }
                return facts
            }
            guard let repo = await EmbedCache.json("https://api.github.com/repos/\(ref.slug)", headers: headers) else { return nil }
            return [
                "title": repo["full_name"] as? String ?? ref.slug,
                "description": repo["description"] as? String ?? "",
                "stars": "\(repo["stargazers_count"] as? Int ?? 0)",
                "forks": "\(repo["forks_count"] as? Int ?? 0)",
                "language": repo["language"] as? String ?? "",
                "avatar": (repo["owner"] as? [String: Any])?["avatar_url"] as? String ?? "",
            ]
        }
    }

    private func postFacts(_ url: URL) -> [String: String]? {
        EmbedCache.facts("post:" + url.absoluteString) {
            await EmbedCache.oEmbed("https://publish.twitter.com/oembed?omit_script=1&dnt=true", for: url)
        }
    }

    // MARK: Layout

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }
    private var columnWidth: CGFloat { max(100, bounds.width - indent) }

    override func measure(width: CGFloat) -> CGFloat {
        let available = max(100, width - indent)
        guard !source.isEmpty, let target else { return 48 }
        switch target {
        case .bookmark:
            let facts = bookmarkFacts
            return facts?["description"] == nil && facts?["image"] == nil && facts != nil ? 84 : 112
        case .video:
            return round(min(available, 900) * 9 / 16)
        case .frame(_, let height, _):
            return height
        case .github(let ref, _):
            return ref.number == nil ? 116 : 112
        case .post:
            return postHeight ?? 240
        case .map:
            return round(min(320, max(180, available * 0.42))) + 52
        }
    }

    private var contentRect: NSRect {
        var rect = NSRect(x: indent, y: 0, width: columnWidth, height: bounds.height)
        switch target {
        case .video: rect.size.width = min(rect.width, 900)
        case .post: rect.size.width = min(rect.width, 550)
        default: break
        }
        return rect
    }

    override var selectionShape: (rect: NSRect, radius: CGFloat) {
        if case .video = target { return (contentRect, MediaBlockView.radius) }
        return (contentRect, Self.radius)
    }

    override func layoutContent() {
        let rect = contentRect
        let size = menuButton.fittingSize
        menuButton.frame = NSRect(x: rect.maxX - size.width - 8, y: 8, width: size.width, height: size.height)
        let fieldHeight = ceil(field.fittingSize.height)
        field.frame = NSRect(x: rect.minX + 40, y: (rect.midY - fieldHeight / 2).rounded(), width: rect.width - 56, height: fieldHeight)
        webView?.frame = rect
        updateShimmer()
        if case .map = target { loadMapIfNeeded() }
    }

    private func updateShimmer() {
        var loading: [NSRect] = []
        if window != nil {
            switch target {
            case .bookmark where bookmarkFacts == nil && !EmbedCache.hasFailed(source):
                loading = [contentRect]
            case .frame, .post:
                if webView == nil || webView?.isLoading == true || (webView?.alphaValue ?? 0) < 1 { loading = [contentRect] }
            case .map where mapImage == nil:
                loading = [contentRect]
            default: break
            }
        }
        shimmer.update(loading, radius: Self.radius, in: self, isDark: theme.palette.isDark)
    }

    override var firstLineMidY: CGFloat { min(24, bounds.height / 2) }

    // MARK: Drawing

    private var cardFill: NSColor {
        let palette = theme.palette
        return palette.isDark ? palette.codeBackground : palette.background.blended(withFraction: 0.5, of: .white) ?? palette.background
    }

    private var cardBorder: NSColor { theme.palette.text.withAlphaComponent(theme.palette.isDark ? 0.12 : 0.1) }

    private func drawCard(_ rect: NSRect) {
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        (isHovered ? cardFill.blended(withFraction: 0.035, of: theme.palette.text) ?? cardFill : cardFill).setFill()
        path.fill()
        cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func text(_ string: String, font: NSFont, color: NSColor, in rect: NSRect, lines: Int = 1) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let box = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: min(rect.height, lineHeight * CGFloat(lines)))
        (string as NSString).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    private func textHeight(_ string: String, font: NSFont, width: CGFloat, lines: Int) -> CGFloat {
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let full = (string as NSString).boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                                     options: [.usesLineFragmentOrigin], attributes: [.font: font]).height
        return min(ceil(full), lineHeight * CGFloat(lines))
    }

    private func drawImage(_ image: NSImage, in rect: NSRect, corners radius: CGFloat, roundedRight: Bool = false, fill: Bool = true) {
        NSGraphicsContext.saveGraphicsState()
        let clip: NSBezierPath
        if roundedRight {
            clip = NSBezierPath()
            clip.move(to: NSPoint(x: rect.minX, y: rect.minY))
            clip.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
            clip.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius, startAngle: 270, endAngle: 360)
            clip.line(to: NSPoint(x: rect.maxX, y: rect.maxY - radius))
            clip.appendArc(withCenter: NSPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius, startAngle: 0, endAngle: 90)
            clip.line(to: NSPoint(x: rect.minX, y: rect.maxY))
            clip.close()
        } else {
            clip = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        clip.addClip()
        let size = image.size
        let scale = fill ? max(rect.width / max(1, size.width), rect.height / max(1, size.height))
                         : min(rect.width / max(1, size.width), rect.height / max(1, size.height))
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        image.draw(in: NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func symbol(_ name: String, size: CGFloat, color: NSColor, weight: NSFont.Weight = .regular) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: weight))?.tinted(color)
    }

    private func draw(_ image: NSImage?, at point: NSPoint) {
        guard let image else { return }
        image.draw(in: NSRect(origin: point, size: image.size), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = contentRect
        guard !source.isEmpty, let target else {
            drawCard(rect)
            CardRow.icon(symbol("link", size: 13, color: theme.palette.secondary, weight: .medium), centerX: rect.minX + 24, centerY: rect.midY)
            return
        }
        switch target {
        case .bookmark(let url): drawBookmark(url, in: rect)
        case .video(let site, let id, let page, _): if !isPlaying { drawVideo(site, id: id, page: page, in: rect) }
        case .frame(_, _, let name): if webView == nil { drawCard(rect); drawCaption(name, in: rect) }
        case .github(let ref, _): drawGitHub(ref, in: rect)
        case .post: if webView == nil || postHeight == nil { drawCard(rect) }
        case .map(let place, _): drawMap(place, in: rect)
        }
    }

    private func drawCaption(_ name: String, in rect: NSRect) {
        text(name, font: .systemFont(ofSize: 12, weight: .medium), color: theme.palette.secondary,
             in: NSRect(x: rect.minX + 16, y: rect.minY + 14, width: rect.width - 32, height: 18))
    }

    // MARK: Bookmark

    private func drawBookmark(_ url: URL, in rect: NSRect) {
        let palette = theme.palette
        drawCard(rect)
        let facts = bookmarkFacts
        let imageAddress = facts?["image"]
        let image = EmbedCache.image(imageAddress)
        let showsImage = imageAddress != nil && (image != nil || EmbedCache.imageIsLoading(imageAddress))
        let imageWidth = showsImage ? min(240, round(rect.width * 0.32)) : 0
        if showsImage {
            let imageRect = NSRect(x: rect.maxX - imageWidth, y: rect.minY, width: imageWidth, height: rect.height).insetBy(dx: 0.5, dy: 0.5)
            if let image {
                drawImage(image, in: imageRect, corners: Self.radius, roundedRight: true)
            } else {
                palette.text.withAlphaComponent(0.04).setFill()
                imageRect.fill()
            }
        }
        let p: CGFloat = 16
        let textWidth = rect.width - imageWidth - p * 2
        let host = Favicons.host(of: url.absoluteString) ?? url.host ?? ""
        let title = facts?["title"] ?? (facts == nil && !EmbedCache.hasFailed(source) ? "" : host)
        let description = facts?["description"] ?? (facts == nil ? "" : url.absoluteString)
        let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12.5)
        var y = rect.minY + p - 1
        let titleHeight = textHeight(title, font: titleFont, width: textWidth, lines: 2)
        let roomForDetail = rect.height - p * 2 - 22 - titleHeight
        text(title, font: titleFont, color: palette.text, in: NSRect(x: rect.minX + p, y: y, width: textWidth, height: titleHeight), lines: 2)
        y += titleHeight + 3
        if !description.isEmpty, roomForDetail > 12 {
            let lines = roomForDetail > 32 ? 2 : 1
            text(description, font: detailFont, color: palette.secondary,
                 in: NSRect(x: rect.minX + p, y: y, width: textWidth, height: 40), lines: lines)
        }
        // Footer: the site's icon and name.
        let footerY = rect.maxY - p - 15
        let footerMid = footerY + 7.5
        var x = rect.minX + p
        if let icon = Favicons.icon(for: url.absoluteString) {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: NSRect(x: x, y: footerY, width: 15, height: 15), xRadius: 3, yRadius: 3).addClip()
            icon.draw(in: NSRect(x: x, y: footerY, width: 15, height: 15), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            x += 21
        }
        let site = facts?["site"].map { $0.lowercased() == host ? host : "\($0) · \(host)" } ?? host
        CardRow.text(site, font: .systemFont(ofSize: 12), color: palette.secondary, x: x, centerY: footerMid, maxWidth: rect.minX + p + textWidth - x)
    }

    // MARK: Video

    private func thumbnail(_ site: VideoSite, id: String, page: URL) -> NSImage? {
        switch site {
        case .youtube:
            return EmbedCache.image("https://i.ytimg.com/vi/\(id)/maxresdefault.jpg") ?? EmbedCache.image("https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
        case .vimeo, .loom:
            return EmbedCache.image(videoFacts(site, page: page)?["thumbnail_url"])
        }
    }

    private func drawVideo(_ site: VideoSite, id: String, page: URL, in rect: NSRect) {
        let palette = theme.palette
        let facts = videoFacts(site, page: page)
        if let image = thumbnail(site, id: id, page: page) {
            drawImage(image, in: rect, corners: MediaBlockView.radius)
        } else {
            let path = NSBezierPath(roundedRect: rect, xRadius: MediaBlockView.radius, yRadius: MediaBlockView.radius)
            NSColor.black.withAlphaComponent(palette.isDark ? 0.5 : 0.85).setFill()
            path.fill()
        }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: MediaBlockView.radius, yRadius: MediaBlockView.radius).addClip()
        // A shade under the title.
        let shade = NSRect(x: rect.minX, y: rect.maxY - 96, width: rect.width, height: 96)
        NSGradient(starting: NSColor.black.withAlphaComponent(0), ending: NSColor.black.withAlphaComponent(0.62))?.draw(in: shade, angle: 90)
        let top = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 64)
        NSGradient(starting: NSColor.black.withAlphaComponent(0.28), ending: NSColor.black.withAlphaComponent(0))?.draw(in: top, angle: 90)
        NSGraphicsContext.restoreGraphicsState()

        // The play button.
        let side: CGFloat = isHovered ? 68 : 62
        let circle = NSRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
        let disc = NSBezierPath(ovalIn: circle)
        NSColor.black.withAlphaComponent(0.42).setFill()
        disc.fill()
        NSColor.white.withAlphaComponent(0.35).setStroke()
        disc.lineWidth = 1
        disc.stroke()
        if let play = symbol("play.fill", size: side * 0.36, color: .white, weight: .semibold) {
            CardRow.icon(play, centerX: circle.midX + side * 0.03, centerY: circle.midY)
        }

        let p: CGFloat = 16
        let title = facts?["title"] ?? ""
        let author = facts?["author_name"]
        let byline = [author == site.name ? nil : author, site.name].compactMap { $0 }.joined(separator: " · ")
        text(title, font: .systemFont(ofSize: 15, weight: .semibold), color: .white,
             in: NSRect(x: rect.minX + p, y: rect.maxY - p - 40, width: rect.width - p * 2, height: 22))
        text(byline, font: .systemFont(ofSize: 12, weight: .medium), color: NSColor.white.withAlphaComponent(0.78),
             in: NSRect(x: rect.minX + p, y: rect.maxY - p - 17, width: rect.width - p * 2, height: 17))
    }

    // MARK: GitHub

    private func drawGitHub(_ ref: GitHubRef, in rect: NSRect) {
        let palette = theme.palette
        drawCard(rect)
        let facts = githubFacts(ref)
        let p: CGFloat = 16
        var x = rect.minX + p
        let y = rect.minY + p
        // Header: an avatar and the repository's name.
        if let avatar = EmbedCache.image(facts?["avatar"]) {
            drawImage(avatar, in: NSRect(x: x, y: y, width: 20, height: 20), corners: 10)
        } else {
            palette.text.withAlphaComponent(0.08).setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 20, height: 20)).fill()
        }
        x += 28
        let headerFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let header = ref.number.map { "\(ref.slug)  #\($0)" } ?? ref.slug
        CardRow.text(ref.number == nil ? "github.com" : header, font: headerFont, color: palette.secondary,
                     x: x, centerY: y + 10, maxWidth: rect.maxX - p - x - 40)

        let titleFont = NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        let detailFont = NSFont.systemFont(ofSize: 12.5)
        if let number = ref.number {
            let state = facts?["state"] ?? "open"
            let pull = facts?["pull"] == "1" || ref.isPull
            let (label, color, icon): (String, NSColor, String) = switch state {
            case "merged": ("Merged", NSColor(hex: 0x8250DF), "arrow.triangle.merge")
            case "draft": ("Draft", NSColor(hex: 0x6E7781), pull ? "arrow.triangle.pull" : "circle.dotted")
            case "closed" where pull: ("Closed", NSColor(hex: 0xCF222E), "xmark.circle")
            case "closed" where facts?["reason"] == "not_planned": ("Not planned", NSColor(hex: 0x6E7781), "slash.circle")
            case "closed": ("Closed", NSColor(hex: 0x8250DF), "checkmark.circle")
            default: ("Open", NSColor(hex: 0x1A7F37), pull ? "arrow.triangle.pull" : "smallcircle.filled.circle")
            }
            let title = facts?["title"] ?? (pull ? "Pull request #\(number)" : "Issue #\(number)")
            text(title, font: titleFont, color: palette.text, in: NSRect(x: rect.minX + p, y: y + 30, width: rect.width - p * 2, height: 20))
            // State pill and byline.
            let pillFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
            let pillText = (label as NSString).size(withAttributes: [.font: pillFont])
            let pill = NSRect(x: rect.minX + p, y: rect.maxY - p - 20, width: ceil(pillText.width) + 32, height: 20)
            let pillPath = NSBezierPath(roundedRect: pill, xRadius: 10, yRadius: 10)
            color.setFill()
            pillPath.fill()
            CardRow.icon(symbol(icon, size: 10, color: .white, weight: .bold), centerX: pill.minX + 14, centerY: pill.midY)
            CardRow.text(label, font: pillFont, color: .white, x: pill.minX + 24, centerY: pill.midY)
            var byline: [String] = []
            if let author = facts?["author"], !author.isEmpty { byline.append("by \(author)") }
            if let comments = facts?["comments"], let count = Int(comments), count > 0 { byline.append(count == 1 ? "1 comment" : "\(count) comments") }
            CardRow.text(byline.joined(separator: " · "), font: detailFont, color: palette.secondary,
                         x: pill.maxX + 10, centerY: pill.midY, maxWidth: rect.maxX - p - pill.maxX - 10)
        } else {
            text(facts?["title"] ?? ref.slug, font: titleFont, color: palette.text,
                 in: NSRect(x: rect.minX + p, y: y + 28, width: rect.width - p * 2, height: 20))
            if let description = facts?["description"], !description.isEmpty {
                text(description, font: detailFont, color: palette.secondary,
                     in: NSRect(x: rect.minX + p, y: y + 49, width: rect.width - p * 2, height: 17))
            }
            // Footer: language, stars, forks.
            var fx = rect.minX + p
            let fy = rect.maxY - p - 15
            let fmid = fy + 7.5
            let footerFont = NSFont.systemFont(ofSize: 12)
            if let language = facts?["language"], !language.isEmpty {
                GitHubColors.color(for: language).setFill()
                NSBezierPath(ovalIn: NSRect(x: fx, y: fmid - 5, width: 10, height: 10)).fill()
                fx += 15 + CardRow.text(language, font: footerFont, color: palette.secondary, x: fx + 15, centerY: fmid) + 16
            }
            for (icon, key) in [("star", "stars"), ("arrow.branch", "forks")] {
                guard let value = facts?[key].flatMap(Int.init) else { continue }
                CardRow.icon(symbol(icon, size: 11, color: palette.secondary), centerX: fx + 6, centerY: fmid)
                let count = value.formatted(.number.notation(.compactName))
                fx += 17 + CardRow.text(count, font: footerFont, color: palette.secondary, x: fx + 17, centerY: fmid) + 16
            }
        }
    }

    // MARK: Map

    private func mapCaption(_ place: MapPlace) -> String {
        if let name = place.name, !name.isEmpty { return name }
        if let query = place.query { return query }
        if let lat = place.latitude, let lng = place.longitude { return String(format: "%.4f, %.4f", lat, lng) }
        return "Map"
    }

    private func drawMap(_ place: MapPlace, in rect: NSRect) {
        let palette = theme.palette
        drawCard(rect)
        let mapRect = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - 52).insetBy(dx: 0.5, dy: 0.5)
        if let mapImage {
            NSGraphicsContext.saveGraphicsState()
            let clip = NSBezierPath()
            let r = Self.radius
            clip.move(to: NSPoint(x: mapRect.minX, y: mapRect.maxY))
            clip.line(to: NSPoint(x: mapRect.minX, y: mapRect.minY + r))
            clip.appendArc(withCenter: NSPoint(x: mapRect.minX + r, y: mapRect.minY + r), radius: r, startAngle: 180, endAngle: 270)
            clip.line(to: NSPoint(x: mapRect.maxX - r, y: mapRect.minY))
            clip.appendArc(withCenter: NSPoint(x: mapRect.maxX - r, y: mapRect.minY + r), radius: r, startAngle: 270, endAngle: 360)
            clip.line(to: NSPoint(x: mapRect.maxX, y: mapRect.maxY))
            clip.close()
            clip.addClip()
            mapImage.draw(in: mapRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            // The pin.
            if let pin = symbol("mappin.circle.fill", size: 26, color: NSColor(hex: 0xE5484D), weight: .semibold) {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
                shadow.shadowBlurRadius = 4
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: mapRect.midX - 11, y: mapRect.midY - 11, width: 22, height: 22)).fill()
                NSGraphicsContext.restoreGraphicsState()
                draw(pin, at: NSPoint(x: mapRect.midX - pin.size.width / 2, y: mapRect.midY - pin.size.height / 2))
            }
        }
        cardBorder.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: rect.minX, y: mapRect.maxY + 0.5))
        line.line(to: NSPoint(x: rect.maxX, y: mapRect.maxY + 0.5))
        line.stroke()
        let p: CGFloat = 16
        let mid = (mapRect.maxY + rect.maxY) / 2
        CardRow.icon(symbol("map", size: 13, color: palette.secondary), centerX: rect.minX + p + 8, centerY: mid)
        CardRow.text(mapCaption(place), font: .systemFont(ofSize: 13.5, weight: .semibold), color: palette.text,
                     x: rect.minX + p + 24, centerY: mid, maxWidth: rect.width - p * 2 - 140)
        let service = place.service
        let serviceFont = NSFont.systemFont(ofSize: 12)
        let arrowX = rect.maxX - p - 5
        CardRow.icon(symbol("arrow.up.right", size: 10, color: palette.secondary, weight: .medium), centerX: arrowX, centerY: mid)
        CardRow.text(service, font: serviceFont, color: palette.secondary, x: arrowX - 11 - CardRow.width(service, font: serviceFont), centerY: mid)
    }

    private func loadMapIfNeeded() {
        guard case .map(let place, let page) = target, window != nil else { return }
        let rect = contentRect
        let size = NSSize(width: round(rect.width), height: round(rect.height - 52))
        guard size.width > 20, size.height > 20 else { return }
        let key = "\(page.absoluteString)|\(Int(size.width))x\(Int(size.height))|\(theme.palette.isDark)"
        guard mapKey != key else { return }
        mapKey = key
        let dark = theme.palette.isDark
        Task { [weak self] in
            guard let coordinate = await Self.coordinate(for: place, page: page) else { return }
            let options = MKMapSnapshotter.Options()
            options.region = MKCoordinateRegion(center: coordinate, latitudinalMeters: place.span, longitudinalMeters: place.span * Double(size.width / size.height))
            options.size = size
            options.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            options.pointOfInterestFilter = .includingAll
            let snapshot = try? await MKMapSnapshotter(options: options).start()
            guard let self, self.mapKey == key, let snapshot else { return }
            self.mapImage = snapshot.image
            self.updateShimmer()
            self.needsDisplay = true
        }
    }

    private static func coordinate(for place: MapPlace, page: URL) async -> CLLocationCoordinate2D? {
        if let lat = place.latitude, let lng = place.longitude { return CLLocationCoordinate2D(latitude: lat, longitude: lng) }
        guard let query = place.query else { return nil }
        let id = "map:" + query
        if let facts = EmbedCache.facts(id, load: { nil }), let lat = facts["lat"].flatMap(Double.init), let lng = facts["lng"].flatMap(Double.init) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lng)
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else { return nil }
        let coordinate = item.location.coordinate
        EmbedCache.forget(id)
        _ = EmbedCache.facts(id) { ["lat": "\(coordinate.latitude)", "lng": "\(coordinate.longitude)"] }
        return coordinate
    }

    // MARK: Web players

    private func startWeb() {
        guard webView == nil, let target, window != nil else { return }
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        let view = EmbedWebView(frame: contentRect, configuration: configuration)
        view.uiDelegate = self
        view.navigationDelegate = self
        view.setValue(false, forKey: "drawsBackground")
        view.underPageBackgroundColor = .clear
        view.wantsLayer = true
        view.layer?.cornerRadius = Self.radius
        view.layer?.masksToBounds = true
        view.alphaValue = 0
        addSubview(view, positioned: .below, relativeTo: menuButton)
        webView = view

        switch target {
        case .video(_, _, _, let player):
            view.alphaValue = 1
            view.layer?.cornerRadius = MediaBlockView.radius
            view.loadHTMLString(Self.framePage(player), baseURL: Self.frameBase)
        case .frame(let url, _, _):
            view.loadHTMLString(Self.framePage(url), baseURL: Self.frameBase)
        case .post(let url):
            let handler = EmbedHeightHandler { [weak self] height in self?.postHeightChanged(height) }
            view.configuration.userContentController.add(handler, name: "height")
            if let facts = postFacts(url), let html = facts["html"] {
                view.loadHTMLString(Self.postPage(html, dark: theme.palette.isDark), baseURL: URL(string: "https://platform.twitter.com/")!)
            } else {
                // Wait for the post's HTML; the cache tells us when it lands.
                tearDownWeb()
                if !EmbedCache.hasFailed("post:" + url.absoluteString) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.startWeb() }
                } else {
                    self.target = .bookmark(url)
                    invalidateHeight()
                    editor?.blockHeightMayHaveChanged(block.id)
                }
                return
            }
        default:
            break
        }
        updateShimmer()
    }

    private func tearDownWeb() {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "height")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
    }

    private func postHeightChanged(_ height: CGFloat) {
        let rounded = ceil(max(120, height))
        guard abs((postHeight ?? 0) - rounded) > 1 else { return }
        postHeight = rounded
        invalidateHeight()
        editor?.blockHeightMayHaveChanged(block.id)
        needsLayout = true
        needsDisplay = true
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            webView.animator().alphaValue = 1
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.updateShimmer() }
    }

    /// Links that open new windows go to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        // A post's links leave Lotion; the frame itself stays.
        if case .post = target, navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func framePage(_ url: URL) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;height:100%;background:transparent;overflow:hidden}iframe{border:0;width:100%;height:100%;display:block}</style>
        </head><body><iframe src="\(escape(url.absoluteString))" allow="autoplay; encrypted-media; fullscreen; picture-in-picture; clipboard-write"
        allowfullscreen referrerpolicy="strict-origin-when-cross-origin"></iframe></body></html>
        """
    }

    static func postPage(_ html: String, dark: Bool) -> String {
        let themed = html.replacingOccurrences(of: "<blockquote class=\"twitter-tweet\"",
                                               with: "<blockquote class=\"twitter-tweet\" data-dnt=\"true\" data-theme=\"\(dark ? "dark" : "light")\"")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>html,body{margin:0;background:transparent;overflow:hidden}.twitter-tweet{margin:0 auto!important}</style>
        </head><body>\(themed)
        <script async src="https://platform.twitter.com/widgets.js"></script>
        <script>
        const report = () => window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
        new ResizeObserver(report).observe(document.body); window.addEventListener('load', report); setInterval(report, 800);
        </script></body></html>
        """
    }

    // MARK: Clicks and menu

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        let selects = !event.modifierFlags.intersection([.shift, .command]).isEmpty
        if selects || source.isEmpty {
            editor?.selectBlocks([block.id])
            return true
        }
        switch target {
        case .video:
            if !isPlaying, contentRect.contains(point) {
                isPlaying = true
                startWeb()
                needsDisplay = true
            }
        case .bookmark(let url), .github(_, let url), .map(_, let url):
            if contentRect.contains(point) { NSWorkspace.shared.open(url) } else { editor?.selectBlocks([block.id]) }
        default:
            editor?.selectBlocks([block.id])
        }
        return true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch target {
        case .bookmark, .github, .map: addCursorRect(contentRect, cursor: .pointingHand)
        case .video where !isPlaying: addCursorRect(contentRect, cursor: .pointingHand)
        default: break
        }
    }

    @objc private func commitField() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let editor, let index = editor.index(of: block.id) else { return }
        guard !text.isEmpty else { return }
        let link = text.hasPrefix("http") ? text : "https://" + text
        editor.mutate("Embed", focus: .blocks([block.id])) { blocks in
            blocks[index].imageSource = link
            blocks[index].touch()
        }
    }

    @objc private func showMenu() {
        let menu = NSMenu()
        let link = target?.page?.absoluteString ?? source
        menu.addItem(ClosureMenuItem(title: "Open Link") { NSWorkspace.shared.open(URL(string: link)!) })
        menu.addItem(ClosureMenuItem(title: "Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        })
        if block.kind == .embed {
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Show as Link") { [weak self] in self?.showAsLink() })
            menu.addItem(ClosureMenuItem(title: "Refresh Preview") { [weak self] in self?.refresh() })
        }
        if isPlaying {
            menu.addItem(ClosureMenuItem(title: "Stop Video") { [weak self] in
                guard let self else { return }
                self.isPlaying = false
                self.tearDownWeb()
                self.needsDisplay = true
            })
        }
        menu.popUp(positioning: nil, at: NSPoint(x: menuButton.frame.minX, y: menuButton.frame.maxY + 4), in: self)
    }

    /// Back to a plain link in the text.
    private func showAsLink() {
        guard let editor, let index = editor.index(of: block.id) else { return }
        let link = block.imageSource
        let text = NSAttributedString(string: link, attributes: [.lotionLink: link])
        editor.mutate("Show as Link", focus: .text(block.id, nil, NSRange(location: text.length, length: 0))) { blocks in
            var paragraph = Block(id: blocks[index].id, kind: .paragraph, text: text)
            paragraph.indent = blocks[index].indent
            blocks[index] = paragraph
        }
    }

    private func refresh() {
        let link = source
        EmbedCache.forget(link)
        if let target {
            switch target {
            case .video(_, _, let page, _): EmbedCache.forget("oembed:" + page.absoluteString)
            case .github(let ref, _): EmbedCache.forget("github:\(ref.slug)#\(ref.number.map(String.init) ?? "")")
            case .post(let url): EmbedCache.forget("post:" + url.absoluteString)
            default: break
            }
        }
        tearDownWeb()
        mapKey = nil
        resolve()
        if case .frame = target { startWeb() }
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
}

// MARK: - Web view

/// A web view that lets the page scroll past it until it is clicked.
final class EmbedWebView: WKWebView {
    var isEngaged = false

    override func scrollWheel(with event: NSEvent) {
        if isEngaged { super.scrollWheel(with: event) } else { nextResponder?.scrollWheel(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        isEngaged = true
        super.mouseDown(with: event)
    }
}

/// Passes a page's height on without the page holding on to its view.
final class EmbedHeightHandler: NSObject, WKScriptMessageHandler {
    private let onHeight: (CGFloat) -> Void

    init(_ onHeight: @escaping (CGFloat) -> Void) {
        self.onHeight = onHeight
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = message.body as? Double { onHeight(CGFloat(value)) } else if let value = message.body as? Int { onHeight(CGFloat(value)) }
    }
}

// MARK: - Iframes

/// An HTML block that is a single `<iframe>`.
enum IframeHTML {
    static func parse(_ html: String) -> (source: String, height: CGFloat)? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("<iframe"), let close = trimmed.firstIndex(of: ">") else { return nil }
        let rest = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard rest.isEmpty || rest == "</iframe>" else { return nil }
        let attributes = PageHead.attributes(String(trimmed[...close]))
        guard var source = attributes["src"], !source.isEmpty else { return nil }
        if source.hasPrefix("//") { source = "https:" + source }
        guard source.hasPrefix("https://") || source.hasPrefix("http://") else { return nil }
        let height = attributes["height"].flatMap { Double($0.replacingOccurrences(of: "px", with: "")) }.map { CGFloat($0) } ?? 400
        return (PageHead.decode(source), min(1200, max(80, height)))
    }
}

/// GitHub's colors for the languages people use most.
enum GitHubColors {
    private static let colors: [String: UInt32] = [
        "swift": 0xF05138, "javascript": 0xF1E05A, "typescript": 0x3178C6, "python": 0x3572A5, "go": 0x00ADD8,
        "rust": 0xDEA584, "ruby": 0x701516, "java": 0xB07219, "kotlin": 0xA97BFF, "c": 0x555555, "c++": 0xF34B7D,
        "c#": 0x178600, "php": 0x4F5D95, "html": 0xE34C26, "css": 0x563D7C, "shell": 0x89E051, "vue": 0x41B883,
        "dart": 0x00B4AB, "objective-c": 0x438EFF, "scala": 0xC22D40, "elixir": 0x6E4A7E, "lua": 0x000080,
        "zig": 0xEC915C, "astro": 0xFF5A03, "svelte": 0xFF3E00, "mdx": 0xFCB32C, "jupyter notebook": 0xDA5B0B,
    ]

    static func color(for language: String) -> NSColor {
        NSColor(hex: colors[language.lowercased()] ?? 0x8B949E)
    }
}
