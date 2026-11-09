//
//  Links.swift
//  Lotion
//
//  External links get the site's favicon in front of them, and a preview of
//  the page while the pointer rests on them. Favicons come from Google's
//  favicon service once per site; page previews are rendered once. Both are
//  kept in the library's `.lotion` folder and read from disk after that.
//

import AppKit
import CryptoKit
import WebKit

enum Favicons {
    /// Where icons are kept: the library's `.lotion/favicons`.
    static var directory: URL?
    static let didLoad = Notification.Name("LotionFaviconDidLoad")

    private static var memory: [String: NSImage] = [:]
    private static var missing: Set<String> = []
    private static var pending: Set<String> = []

    /// The site a link points at, for links that leave the note.
    static func host(of link: String) -> String? {
        var string = link
        if string.hasPrefix("www.") { string = "https://" + string }
        guard string.hasPrefix("http://") || string.hasPrefix("https://"),
              let host = URL(string: string)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The icon for a link's site, or nil while it loads (a fetch starts).
    static func icon(for link: String) -> NSImage? {
        guard let host = host(of: link) else { return nil }
        if let image = memory[host] { return image }
        if missing.contains(host) || pending.contains(host) { return nil }
        if let directory, let image = NSImage(contentsOf: directory.appending(path: "\(host).png")) {
            memory[host] = image
            return image
        }
        fetch(host)
        return nil
    }

    private static func fetch(_ host: String) {
        pending.insert(host)
        var components = URLComponents(string: "https://www.google.com/s2/favicons")!
        components.queryItems = [URLQueryItem(name: "domain", value: host), URLQueryItem(name: "sz", value: "64")]
        guard let url = components.url else { return }
        Task {
            // Google answers unknown sites with a generic globe and a 404; that is still an icon.
            let data = try? await URLSession.shared.data(from: url).0
            pending.remove(host)
            guard let data, let image = NSImage(data: data) else {
                missing.insert(host)
                return
            }
            memory[host] = image
            if let directory {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try? data.write(to: directory.appending(path: "\(host).png"), options: .atomic)
            }
            NotificationCenter.default.post(name: didLoad, object: nil)
        }
    }
}

// MARK: - Hover preview

/// A small glass panel under a hovered link with a picture of the page. It
/// follows the pointer sideways and stays on the link's line.
final class LinkPreview: NSObject, WKNavigationDelegate {
    static let shared = LinkPreview()
    /// Where page snapshots are kept: the library's `.lotion/previews`.
    static var directory: URL?

    private var panel: NSPanel?
    private let glass = NSGlassEffectView()
    private let content = FlippedView()
    private let snapshotView = NSImageView()
    private let placeholder = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let hostLabel = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private var webView: WKWebView?
    /// Holds the web view at desktop size and draws it scaled into the card.
    private var webContainer: NSView?

    private let shimmer = Shimmer()
    private let border = NSView()
    /// Bumped on every show and hide, so a late fade-out can't hide a newer preview.
    private var generation = 0
    private(set) var link: String?
    var isShowing: Bool { panel?.isVisible ?? false }
    var panelContent: NSView? { panel?.contentView }
    private var anchor: (line: NSRect, window: NSWindow)?
    private var pointerX: CGFloat = 0
    private var showTimer: Timer?

    /// The card. The window is larger by `margin` all round, so the glass's soft
    /// edge never meets the window's edge and gets cut off at the corners.
    static let size = NSSize(width: 340, height: 270)
    private static let margin: CGFloat = 16
    /// Outer radius = inner radius + padding.
    private static let padding: CGFloat = 10
    private static let innerRadius: CGFloat = 7
    private static var outerRadius: CGFloat { innerRadius + padding }
    private static let page = NSSize(width: 1280, height: 800)

    // MARK: Hovering

    /// The pointer is over `link`, on a line at `line` (screen coordinates).
    func hover(_ link: String, line: NSRect, pointerX: CGFloat, in window: NSWindow) {
        self.pointerX = pointerX
        anchor = (line, window)
        if link == self.link {
            position()
            return
        }
        hide()
        self.link = link
        anchor = (line, window)
        self.pointerX = pointerX
        showTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.show() }
        }
    }

    func hide() {
        showTimer?.invalidate()
        showTimer = nil
        guard link != nil else { return }
        link = nil
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        guard let panel, panel.isVisible else {
            removeWebView()
            return
        }
        generation += 1
        let current = generation
        let finish = { [weak self, weak panel] in
            guard let self, let panel, self.generation == current else { return }
            self.removeWebView()
            self.shimmer.stop()
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { MainActor.assumeIsolated { finish() } })
    }

    private func removeWebView() {
        webContainer?.removeFromSuperview()
        webContainer = nil
        webView = nil
    }

    private func show() {
        guard let link, let anchor, let host = Favicons.host(of: link) else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        titleLabel.stringValue = Self.cachedTitle(for: link) ?? host
        hostLabel.stringValue = host
        iconView.image = Favicons.icon(for: link) ?? NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        if let snapshot = Self.cachedSnapshot(for: link) {
            snapshotView.image = snapshot
            snapshotView.isHidden = false
            placeholder.isHidden = true
            shimmer.stop()
        } else {
            snapshotView.isHidden = true
            placeholder.isHidden = false
            shimmer.update([placeholder.frame], radius: Self.innerRadius, in: content, isDark: anchor.window.effectiveAppearance.isDarkAppearance)
            load(link)
        }
        // A faint hairline: the glass already draws its own soft rim.
        let dark = anchor.window.effectiveAppearance.isDarkAppearance
        // A solid ground in light mode: through a thin tint the glass shows
        // the blurred page behind it, and the sweep turns that into grain.
        placeholder.layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06) : NSColor(white: 0.94, alpha: 1)).cgColor
        placeholder.contentTintColor = dark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.2)
        border.layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.07)).cgColor
        position()
        generation += 1
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        if panel.parent == nil { anchor.window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        if !wasVisible { appear(panel) }
        // Start the sweep now the panel is on screen.
        if !placeholder.isHidden {
            shimmer.update([placeholder.frame], radius: Self.innerRadius, in: content,
                           isDark: anchor.window.effectiveAppearance.isDarkAppearance, restart: true)
        }
    }

    var shimmerLocation: Double? { shimmer.currentLocation }

    /// Fades in while settling up from a touch smaller and lower.
    private func appear(_ panel: NSPanel) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        guard let layer = panel.contentView?.layer, let size = panel.contentView?.bounds.size else { return }
        var from = CATransform3DMakeTranslation(size.width / 2, size.height / 2, 0)
        from = CATransform3DScale(from, 0.97, 0.97, 1)
        from = CATransform3DTranslate(from, -size.width / 2, -size.height / 2 + 4, 0)
        let settle = CABasicAnimation(keyPath: "transform")
        settle.fromValue = NSValue(caTransform3D: from)
        settle.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        settle.duration = 0.22
        settle.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1)
        layer.add(settle, forKey: "settle")
    }

    private func position() {
        guard let panel, let anchor, let screen = anchor.window.screen ?? NSScreen.main else { return }
        let size = Self.size
        let bounds = anchor.window.frame.intersection(screen.visibleFrame)
        var x = pointerX - size.width / 2
        x = max(bounds.minX + 8, min(bounds.maxX - size.width - 8, x))
        // Under the line, or above it when there is no room below.
        var y = anchor.line.minY - 8 - size.height
        if y < bounds.minY + 8 { y = anchor.line.maxY + 8 }
        let margin = Self.margin
        let frame = NSRect(x: round(x) - margin, y: round(y) - margin, width: size.width + margin * 2, height: size.height + margin * 2)
        // Only move it: redrawing on every pointer move froze the loading shimmer.
        if panel.frame != frame { panel.setFrame(frame, display: false) }
    }

    private func makePanel() -> NSPanel {
        let margin = Self.margin
        let window = NSSize(width: Self.size.width + margin * 2, height: Self.size.height + margin * 2)
        let card = NSRect(origin: NSPoint(x: margin, y: margin), size: Self.size)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: window), styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The glass draws its own soft edge and shadow; a window shadow on top made a hard outline.
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        glass.cornerRadius = Self.outerRadius
        glass.wantsLayer = true
        glass.frame = card
        content.frame = card
        content.wantsLayer = true
        // The glass is only the ground; content sits above it, not inside it.
        // A plain hairline border rings the card.
        border.frame = card
        border.wantsLayer = true
        border.layer?.cornerRadius = Self.outerRadius
        border.layer?.cornerCurve = .continuous
        border.layer?.borderWidth = 0.5
        let root = FlippedView(frame: NSRect(origin: .zero, size: window))
        root.wantsLayer = true
        root.addSubview(glass)
        root.addSubview(content)
        root.addSubview(border)
        panel.contentView = root

        let inset = Self.padding
        let pictureWidth = Self.size.width - inset * 2
        let picture = NSRect(x: inset, y: inset, width: pictureWidth, height: round(pictureWidth * Self.page.height / Self.page.width))
        for view in [snapshotView, placeholder] {
            view.frame = picture
            view.imageScaling = .scaleProportionallyUpOrDown
            view.wantsLayer = true
            view.layer?.cornerRadius = Self.innerRadius
            view.layer?.masksToBounds = true
            content.addSubview(view)
        }
        placeholder.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 28, weight: .light))
        placeholder.imageScaling = .scaleNone

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: inset + 2, y: picture.maxY + 8, width: pictureWidth - 4, height: 18)
        iconView.frame = NSRect(x: inset + 2, y: picture.maxY + 29, width: 14, height: 14)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        hostLabel.font = .systemFont(ofSize: 11)
        hostLabel.textColor = .secondaryLabelColor
        hostLabel.lineBreakMode = .byTruncatingTail
        hostLabel.frame = NSRect(x: inset + 22, y: picture.maxY + 28, width: pictureWidth - 24, height: 16)
        for view in [titleLabel, iconView, hostLabel] { content.addSubview(view) }
        return panel
    }

    // MARK: Rendering the page

    /// Loads the page in a small web view that sits where the snapshot will go.
    private func load(_ link: String) {
        removeWebView()
        var string = link
        if string.hasPrefix("www.") { string = "https://" + string }
        guard let url = URL(string: string) else { return }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        // The page gets a real desktop window to lay out in (1280 × 800); the
        // container's bounds scale it down into the card. Zooming the page
        // instead left it a narrow viewport, and sites laid out for a tablet.
        let container = NSView(frame: snapshotView.frame)
        container.setBoundsSize(Self.page)
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.innerRadius
        container.layer?.masksToBounds = true
        container.alphaValue = 0
        let view = WKWebView(frame: NSRect(origin: .zero, size: Self.page), configuration: configuration)
        view.navigationDelegate = self
        container.addSubview(view)
        content.addSubview(container, positioned: .below, relativeTo: titleLabel)
        webContainer = container
        webView = view
        view.load(URLRequest(url: url, timeoutInterval: 15))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, let link else { return }
        // Give the page a moment to draw what it loads after the document.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak webView] in
            guard let self, let webView, webView === self.webView, self.link == link else { return }
            if let title = webView.title, !title.isEmpty { self.titleLabel.stringValue = title }
            // Show a full-resolution picture of the page rather than the live view scaled down.
            let configuration = WKSnapshotConfiguration()
            configuration.afterScreenUpdates = true
            webView.takeSnapshot(with: configuration) { [weak self] image, _ in
                guard let image else { return }
                Self.save(image, title: webView.title, for: link)
                MainActor.assumeIsolated {
                    guard let self, self.link == link else { return }
                    self.snapshotView.image = image
                    self.snapshotView.isHidden = false
                    self.placeholder.isHidden = true
                    self.shimmer.stop()
                }
            }
        }
    }

    // MARK: Saved previews

    /// Bumped when previews change how they are taken, so old ones are retaken.
    private static let version = "2"

    private static func key(_ link: String) -> String {
        SHA256.hash(data: Data((version + ":" + link).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    /// Saved previews older than a week are taken again.
    private static func freshFile(_ name: String) -> URL? {
        guard let directory else { return nil }
        let url = directory.appending(path: name)
        guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
              Date().timeIntervalSince(modified) < 7 * 24 * 3600 else { return nil }
        return url
    }

    static func cachedSnapshot(for link: String) -> NSImage? {
        freshFile(key(link) + ".png").flatMap { NSImage(contentsOf: $0) }
    }

    static func cachedTitle(for link: String) -> String? {
        freshFile(key(link) + ".txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func save(_ image: NSImage, title: String?, for link: String) {
        guard let directory, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appending(path: key(link) + ".png"), options: .atomic)
        if let title { try? title.write(to: directory.appending(path: key(link) + ".txt"), atomically: true, encoding: .utf8) }
    }
}
