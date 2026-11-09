//
//  MediaZoom.swift
//  Lotion
//
//  Clicking an image in a note lifts it out of the page: it grows from where
//  it sits to fill the window over a backdrop in the canvas color, and a
//  click anywhere, Escape or a scroll puts it back exactly where it came
//  from. Videos do the same from their expand button, still playing.
//

import AppKit
import AVKit

@MainActor
final class MediaZoom {
    static let shared = MediaZoom()

    /// What is zoomed: a still image, or a video's own player view on loan.
    enum Content {
        case image(NSImage)
        case video(AVPlayerView)
    }

    struct Request {
        let content: Content
        /// The media's rect in `source`, looked up again on the way back so a
        /// page that moved underneath still lands right.
        let rect: () -> NSRect?
        weak var source: NSView?
        let radius: CGFloat
        let backdrop: NSColor
        /// Before it lifts and after it lands: hide or show the original.
        let setOriginalHidden: (Bool) -> Void
        /// A double-click: the first click zoomed, the second lands here.
        var onDoubleClick: (() -> Void)?
    }

    private var overlay: MediaZoomOverlay?
    var isShowing: Bool { overlay != nil }

    static let openDuration: TimeInterval = 0.42
    static let closeDuration: TimeInterval = 0.32
    /// A strong ease-out: quick to leave, gentle to land.
    static let curve = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)

    func show(_ request: Request) {
        guard overlay == nil, let source = request.source, let window = source.window,
              let host = window.contentView?.superview ?? window.contentView,
              let rect = request.rect() else { return }
        let overlay = MediaZoomOverlay(request: request, frame: host.bounds)
        overlay.autoresizingMask = [.width, .height]
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        overlay.onClose = { [weak self] in self?.hide() }
        overlay.open(from: overlay.convert(rect, from: source))
    }

    func hide(animated: Bool = true) {
        guard let overlay else { return }
        self.overlay = nil
        overlay.close(animated: animated)
    }
}

// MARK: - Overlay

private final class MediaZoomOverlay: NSView {
    private let request: MediaZoom.Request
    private let backdrop = NSView()
    private let mediaView: NSView
    private weak var previousResponder: NSResponder?
    private var openedAt = Date.distantPast
    private var scrolled: CGFloat = 0
    private var isClosing = false
    /// The video's place in its block, to give it back.
    private var videoHome: (superview: NSView, frame: NSRect)?
    var onClose: (() -> Void)?

    init(request: MediaZoom.Request, frame: NSRect) {
        self.request = request
        switch request.content {
        case .image(let image):
            let view = ZoomImageView(image: image)
            mediaView = view
        case .video(let player):
            mediaView = player
            if let superview = player.superview { videoHome = (superview, player.frame) }
        }
        super.init(frame: frame)
        wantsLayer = true
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = request.backdrop.cgColor
        backdrop.frame = bounds
        backdrop.autoresizingMask = [.width, .height]
        backdrop.alphaValue = 0
        addSubview(backdrop)
        mediaView.wantsLayer = true
        mediaView.layer?.masksToBounds = true
        mediaView.layer?.cornerCurve = .continuous
        mediaView.layer?.cornerRadius = request.radius
        setAccessibilityRole(.image)
        setAccessibilityLabel("Zoomed media")
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    /// The media's natural size, the most it grows to: past that an image only blurs.
    private var naturalSize: NSSize? {
        guard case .image(let image) = request.content else { return nil }
        let pixels = image.representations.map { NSSize(width: $0.pixelsWide, height: $0.pixelsHigh) }.max { $0.width < $1.width }
        let scale = window?.backingScaleFactor ?? 2
        guard let pixels, pixels.width > 0 else { return image.size }
        // Screenshots and photos taken at 2x read at their point size.
        return NSSize(width: max(image.size.width, pixels.width / scale), height: max(image.size.height, pixels.height / scale))
    }

    /// Where the media sits zoomed: as big as fits, centered, with room to breathe.
    private func zoomedRect(from origin: NSRect) -> NSRect {
        let margin: CGFloat = bounds.width > 900 ? 56 : 32
        let available = bounds.insetBy(dx: margin, dy: margin)
        guard origin.width > 0, origin.height > 0, available.width > 0, available.height > 0 else { return origin }
        var scale = min(available.width / origin.width, available.height / origin.height)
        if let natural = naturalSize, natural.width > 0 {
            // Never smaller than on the page, never larger than the file.
            scale = min(scale, max(1, natural.width / origin.width))
        }
        let size = NSSize(width: round(origin.width * scale), height: round(origin.height * scale))
        return NSRect(x: round(bounds.midX - size.width / 2), y: round(bounds.midY - size.height / 2),
                      width: size.width, height: size.height)
    }

    func open(from origin: NSRect) {
        mediaView.frame = origin
        addSubview(mediaView)
        request.setOriginalHidden(true)
        previousResponder = window?.firstResponder
        window?.makeFirstResponder(self)
        openedAt = Date()
        layoutSubtreeIfNeeded()
        let target = zoomedRect(from: origin)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MediaZoom.openDuration
            context.timingFunction = MediaZoom.curve
            context.allowsImplicitAnimation = true
            mediaView.animator().frame = target
            backdrop.animator().alphaValue = 0.97
            mediaView.layer?.cornerRadius = min(request.radius, 6)
        }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    func close(animated: Bool) {
        guard !isClosing else { return }
        isClosing = true
        let destination = request.source.flatMap { source in request.rect().map { convert($0, from: source) } }
        let finish = { [weak self] in
            guard let self else { return }
            if let home = self.videoHome {
                home.superview.addSubview(self.mediaView)
                self.mediaView.frame = home.frame
                self.mediaView.layer?.cornerRadius = self.request.radius
                home.superview.needsLayout = true
            }
            self.request.setOriginalHidden(false)
            self.removeFromSuperview()
            if let responder = self.previousResponder, self.window?.firstResponder === self || self.window?.firstResponder == nil {
                self.window?.makeFirstResponder(responder)
            }
        }
        guard animated, let destination else {
            finish()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = MediaZoom.closeDuration
            context.timingFunction = MediaZoom.curve
            context.allowsImplicitAnimation = true
            mediaView.animator().frame = destination
            backdrop.animator().alphaValue = 0
            mediaView.layer?.cornerRadius = request.radius
        } completionHandler: {
            MainActor.assumeIsolated { finish() }
        }
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        // The window changed size while zoomed: stay centered and fitted.
        guard !isClosing, mediaView.superview === self, let rect = request.rect(), let source = request.source else { return }
        mediaView.frame = zoomedRect(from: convert(rect, from: source))
    }

    // MARK: Dismissing

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isClosing else { return nil }
        let local = convert(point, from: superview)
        // A zoomed video keeps its own controls.
        if case .video = request.content, mediaView.frame.contains(local) { return super.hitTest(point) }
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, Date().timeIntervalSince(openedAt) < NSEvent.doubleClickInterval, let action = request.onDoubleClick {
            MediaZoom.shared.hide(animated: false)
            action()
            return
        }
        onClose?()
    }

    override func scrollWheel(with event: NSEvent) {
        // A deliberate scroll puts it back, as reading on does.
        scrolled += abs(event.scrollingDeltaY) + abs(event.scrollingDeltaX)
        if scrolled > 24 { onClose?() }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53, 49, 36: onClose?() // Escape, space, return
        default: super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: ZoomCursor.zoomOut)
    }
}

/// An image drawn by its layer, so resizing it is only a transform.
private final class ZoomImageView: NSView {
    init(image: NSImage) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contents = image
        layer?.contentsGravity = .resizeAspectFill
        layer?.minificationFilter = .trilinear
        layer?.magnificationFilter = .linear
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Cursors

enum ZoomCursor {
    static let zoomIn = make("plus.magnifyingglass")
    static let zoomOut = make("minus.magnifyingglass")

    /// A magnifier drawn in black over a white halo, so it reads on any page.
    private static func make(_ symbol: String) -> NSCursor {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else {
            return .pointingHand
        }
        let size = NSSize(width: glyph.size.width + 4, height: glyph.size.height + 4)
        func tinted(_ color: NSColor) -> NSImage {
            NSImage(size: glyph.size, flipped: false) { rect in
                glyph.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
        }
        let white = tinted(.white)
        let black = tinted(.black)
        let image = NSImage(size: size, flipped: false) { _ in
            for dx in [-1.0, 0, 1] {
                for dy in [-1.0, 0, 1] where dx != 0 || dy != 0 {
                    white.draw(at: NSPoint(x: 2 + dx * 1.5, y: 2 + dy * 1.5), from: .zero, operation: .sourceOver, fraction: 1)
                }
            }
            black.draw(at: NSPoint(x: 2, y: 2), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // The hotspot is the lens's middle, toward the top left.
        return NSCursor(image: image, hotSpot: NSPoint(x: size.width * 0.42, y: size.height * 0.42))
    }
}
