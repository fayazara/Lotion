//
//  DiagramBlockView.swift
//  Lotion
//
//  A ```mermaid fence, drawn by BeautifulMermaid in the note's own colors:
//  flowcharts, state, sequence, class and ER diagrams, and XY charts.
//  Double-click (or Edit) shows the source under the drawing, which follows
//  every keystroke; clicking away puts the source away again.
//

import AppKit
import BeautifulMermaid

final class DiagramBlockView: BlockView {
    private(set) var textView: BlockTextView?
    private(set) var isEditing = false
    private var content: DiagramContent?
    private var problem: DiagramProblem?
    private var renderedKey: String?
    private var isZoomed = false { didSet { canvas.isZoomedOut = isZoomed } }

    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let zoomButton = NSButton(title: "", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { updateButtons() } }

    private static let sourceGap: CGFloat = 10
    /// How far a wide chart may shrink to fit the column; past that it scrolls sideways.
    private static let minScale: CGFloat = 0.72
    /// A chart wider than the column scrolls sideways in a real scroll view,
    /// so swipes lock to an axis, carry momentum and rubber-band like the rest
    /// of the Mac. Vertical swipes pass through to the note.
    private let chartScroll = DiagramScrollView()
    private let canvas = DiagramCanvasView()
    private var scrollX: CGFloat { chartScroll.contentView.bounds.origin.x }
    /// For tests: how far the chart is scrolled, and how far it can go.
    var horizontalOffset: CGFloat { scrollX }
    var scrollableWidth: CGFloat {
        let preview = previewRect
        return max(0, (content?.size.width ?? 0) * scale(for: preview.width) - preview.width)
    }
    /// For tests: the drawn chart's size, in points.
    var chartSize: CGSize? { content?.size }

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        for button in [editButton, zoomButton] {
            button.bezelStyle = .glass
            button.controlSize = .small
            button.target = self
            button.isHidden = true
            addSubview(button)
        }
        chartScroll.drawsBackground = false
        chartScroll.borderType = .noBorder
        chartScroll.hasVerticalScroller = false
        chartScroll.hasHorizontalScroller = true
        chartScroll.autohidesScrollers = true
        chartScroll.scrollerStyle = .overlay
        chartScroll.verticalScrollElasticity = .none
        chartScroll.horizontalScrollElasticity = .allowed
        chartScroll.documentView = canvas
        chartScroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(chartDidScroll), name: NSView.boundsDidChangeNotification, object: chartScroll.contentView)
        addSubview(chartScroll, positioned: .below, relativeTo: editButton)
        editButton.action = #selector(toggleEditing)
        zoomButton.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: "Expand")
        zoomButton.action = #selector(zoom)
        render()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTextView: BlockTextView? {
        beginEditing()
        return textView
    }

    override var isMaterialized: Bool { true }

    /// Charts that can't be drawn keep their source on show.
    private var showsSource: Bool { isEditing || problem != nil }

    // MARK: Rendering

    private func render() {
        let source = textView?.string ?? block.text.string
        let style = DiagramStyle(palette: theme.palette, fontSize: theme.em)
        let key = style.key + "\u{0}" + source
        guard renderedKey != key else { return }
        renderedKey = key
        switch DiagramContent.make(source, style: style) {
        case .success(let made):
            content = made
            problem = nil
        case .failure(let failure):
            problem = failure
            content = nil
        }
        if problem != nil, textView == nil { makeTextView() }
        textView?.isHidden = !showsSource
        updateCanvas()
        updateButtons()
    }

    private func updateCanvas() {
        canvas.content = content
        canvas.palette = theme.palette
        canvas.needsDisplay = true
    }

    @objc private func chartDidScroll() {
        canvas.needsDisplay = true
    }

    override func update(_ block: Block) {
        super.update(block)
        if let textView, textView.string != block.text.string {
            textView.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
        }
        render()
        needsLayout = true
        needsDisplay = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        renderedKey = nil
        if let textView {
            configure(textView)
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: textView.string, attributes: theme.baseAttributes(for: .code)))
            textView.setSelectedRange(selection)
        }
        render()
        updateCanvas()
        needsLayout = true
        needsDisplay = true
    }

    /// The source changed while editing: the drawing follows it.
    func sourceDidChange() {
        render()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
    }

    // MARK: Editing

    private func makeTextView() {
        guard textView == nil, let editor else { return }
        let view = BlockTextView(blockID: block.id, width: 100)
        view.editor = editor
        view.delegate = editor
        view.isRichText = false
        configure(view)
        view.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
        view.isHidden = true
        addSubview(view, positioned: .below, relativeTo: editButton)
        textView = view
    }

    private func configure(_ view: BlockTextView) {
        view.typingAttributes = theme.baseAttributes(for: .code)
        view.insertionPointColor = theme.palette.text
        view.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.placeholder = "flowchart LR\n  A[Start] --> B[Finish]"
        view.placeholderColor = theme.palette.marker
        view.placeholderFont = theme.code
        view.placeholderOffset = theme.baselineOffset(for: .code)
    }

    func beginEditing() {
        guard !isEditing, let editor else { return }
        isEditing = true
        makeTextView()
        textView?.isHidden = false
        updateButtons()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor.blockHeightMayHaveChanged(block.id)
    }

    func endEditing() {
        guard isEditing else { return }
        isEditing = false
        textView?.isHidden = !showsSource
        render()
        updateButtons()
        invalidateHeight()
        needsLayout = true
        needsDisplay = true
        editor?.blockHeightMayHaveChanged(block.id)
    }

    @objc private func toggleEditing() {
        if isEditing {
            editor?.selectBlocks([block.id])
        } else {
            editor?.focus(block.id, .end)
        }
    }

    private func updateButtons() {
        editButton.title = isEditing ? "Done" : "Edit"
        editButton.isHidden = !(isEditing || isHovered) || (problem != nil && !isEditing)
        zoomButton.isHidden = !isHovered || content == nil
        needsLayout = true
    }

    // MARK: Layout

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }

    private func scale(for width: CGFloat) -> CGFloat {
        guard let size = content?.size, size.width > 0 else { return 1 }
        return max(Self.minScale, min(1, width / size.width))
    }

    private func previewHeight(width: CGFloat) -> CGFloat {
        if let problem {
            return problem == .empty && !isEditing ? 96 : (problem == .empty ? 0 : 40)
        }
        guard let content else { return 96 }
        return ceil(content.size.height * scale(for: width))
    }

    private func sourceHeight(width: CGFloat) -> CGFloat {
        let text = NSAttributedString(string: textView?.string ?? block.text.string, attributes: theme.baseAttributes(for: .code))
        return TextMeasurer.shared.height(of: text, width: max(20, width - 32), base: theme.baseAttributes(for: .code)) + 24
    }

    override func measure(width: CGFloat) -> CGFloat {
        let available = width - indent
        let preview = previewHeight(width: available)
        guard showsSource else { return preview }
        return (preview > 0 ? preview + Self.sourceGap : 0) + sourceHeight(width: available)
    }

    private var previewRect: NSRect {
        let available = bounds.width - indent
        return NSRect(x: indent, y: 0, width: available, height: previewHeight(width: available))
    }

    override var selectionShape: (rect: NSRect, radius: CGFloat) {
        let preview = previewRect
        let shape = showsSource ? (preview.height > 0 ? preview.union(sourceRect) : sourceRect) : preview
        return (shape, showsSource && preview.height == 0 ? 8 : DiagramCanvasView.radius)
    }

    private var sourceRect: NSRect {
        let preview = previewRect
        let top = preview.height > 0 ? preview.maxY + Self.sourceGap : 0
        return NSRect(x: indent, y: top, width: preview.width, height: max(0, bounds.height - top))
    }

    override func layoutContent() {
        if let textView, showsSource {
            textView.frame = sourceRect.insetBy(dx: 16, dy: 12)
        }
        let edit = editButton.fittingSize
        editButton.frame = NSRect(x: bounds.width - edit.width - 8, y: 8, width: edit.width, height: edit.height)
        let zoom = zoomButton.fittingSize
        zoomButton.frame = NSRect(x: editButton.frame.minX - zoom.width - 6, y: 8, width: zoom.width, height: zoom.height)
        layoutChart()
    }

    private func layoutChart() {
        let preview = previewRect
        let shows = problem == nil && content != nil && preview.height > 0
        chartScroll.isHidden = !shows
        guard shows else { return }
        let scale = scale(for: preview.width)
        let width = ceil((content?.size.width ?? 0) * scale)
        let x = scrollX
        chartScroll.frame = preview
        canvas.scale = scale
        canvas.frame = NSRect(x: 0, y: 0, width: max(preview.width, width), height: preview.height)
        chartScroll.horizontalScrollElasticity = width > preview.width + 0.5 ? .allowed : .none
        chartScroll.contentView.scroll(to: NSPoint(x: min(max(0, x), max(0, canvas.frame.width - preview.width)), y: 0))
        chartScroll.reflectScrolledClipView(chartScroll.contentView)
        canvas.needsDisplay = true
    }

    override var firstLineMidY: CGFloat { min(18, bounds.height / 2) }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        if showsSource {
            let box = sourceRect
            let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            palette.codeBackground.setFill()
            path.fill()
            palette.codeBorder.setStroke()
            path.stroke()
        }
        let preview = previewRect
        guard preview.height > 0 else { return }
        if let problem {
            drawNotice(problem, in: preview)
            return
        }
        if content == nil {
            MediaPlaceholder.draw(in: preview, symbol: "point.3.connected.trianglepath.dotted", palette: palette, caption: "Empty diagram")
        }
        // The chart itself is drawn by the canvas in the scroll view above.
    }

    private func drawNotice(_ problem: DiagramProblem, in rect: NSRect) {
        let palette = theme.palette
        let text: String
        switch problem {
        case .empty: text = "Write a diagram below to draw it."
        case .unreadable: text = "Lotion couldn’t draw this diagram, so it shows as its source. Check its syntax."
        }
        let symbol = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))?.tinted(palette.secondary)
        var x = rect.minX + 4
        if let symbol {
            CardRow.icon(symbol, x: x, centerY: rect.midY)
            x += symbol.size.width + 8
        }
        CardRow.text(text, font: .systemFont(ofSize: 12), color: palette.secondary, x: x, centerY: rect.midY, maxWidth: rect.maxX - x)
    }

    // MARK: Clicks

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        if event.clickCount == 2 {
            editor?.focus(block.id, .end)
        } else if showsSource, sourceRect.contains(point), let textView = primaryTextView {
            window?.makeFirstResponder(textView)
            let local = textView.convert(point, from: self)
            textView.setSelectedRange(NSRange(location: textView.characterIndex(near: local), length: 0))
        } else {
            editor?.selectBlocks([block.id])
        }
        return true
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

    /// The chart at full size, over the window.
    @objc private func zoom() {
        guard let content else { return }
        let palette = theme.palette
        let size = content.size
        MediaZoom.shared.show(MediaZoom.Request(
            content: .image(content.image(palette: palette)),
            rect: { [weak self] in
                guard let self, self.window != nil else { return nil }
                let area = self.previewRect
                let scale = self.scale(for: area.width)
                let width = size.width * scale
                return NSRect(x: area.minX + max(0, (area.width - width) / 2) - self.scrollX, y: area.minY,
                              width: width, height: size.height * scale)
            },
            source: self,
            radius: DiagramCanvasView.radius,
            backdrop: palette.background,
            setOriginalHidden: { [weak self] hidden in self?.isZoomed = hidden },
            onDoubleClick: { [weak self] in
                guard let self else { return }
                self.editor?.focus(self.block.id, .end)
            }
        ))
    }
}

// MARK: - Content

/// Why a fence shows as its source instead of a drawing.
enum DiagramProblem: Error, Equatable {
    case empty
    /// BeautifulMermaid couldn't read it: a typo, or a kind it doesn't draw.
    case unreadable
}

/// The theme's colors, as BeautifulMermaid takes them. Diagrams draw on the
/// code-block ground, in the note's ink, with its accent for highlights.
struct DiagramStyle {
    let theme: DiagramTheme
    /// Identifies the look, so a chart is laid out again only when it changes.
    let key: String

    init(palette: ThemePalette, fontSize: CGFloat) {
        func resolved(_ color: NSColor) -> NSColor {
            var result = color
            NSAppearance(named: palette.isDark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
                result = color.usingColorSpace(.sRGB) ?? color
            }
            return result
        }
        let size = (fontSize * 0.87).rounded()
        let colors = [palette.codeBackground, palette.text, palette.secondary, palette.accent, palette.codeBorder].map(resolved)
        theme = DiagramTheme(
            background: colors[0],
            foreground: colors[1],
            accent: colors[3],
            muted: colors[2],
            border: colors[4],
            font: .systemFont(ofSize: size, weight: .medium),
            lineWidth: 1.25,
            cornerRadius: 8,
            transparent: true
        )
        key = colors.map { String(format: "%.3f,%.3f,%.3f", $0.redComponent, $0.greenComponent, $0.blueComponent) }.joined(separator: ";")
            + "|\(size)"
    }
}

/// A laid-out chart, ready to draw at any scale.
final class DiagramContent {
    private let prepared: PreparedDiagram
    var size: CGSize { prepared.bounds.size }

    private init(prepared: PreparedDiagram) {
        self.prepared = prepared
    }

    /// Laid-out charts, kept by look and source: notes redraw often, and
    /// layout is the slow part.
    private static let cache: NSCache<NSString, DiagramContent> = {
        let cache = NSCache<NSString, DiagramContent>()
        cache.countLimit = 64
        return cache
    }()

    static func make(_ source: String, style: DiagramStyle) -> Result<DiagramContent, DiagramProblem> {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure(.empty) }
        let key = (style.key + "\u{0}" + source) as NSString
        if let cached = cache.object(forKey: key) { return .success(cached) }
        guard let prepared = try? MermaidImageRenderer(theme: style.theme).prepare(from: source),
              prepared.bounds.width > 1, prepared.bounds.height > 1 else { return .failure(.unreadable) }
        let content = DiagramContent(prepared: prepared)
        cache.setObject(content, forKey: key)
        return .success(content)
    }

    /// Draws the chart with its top left at the origin, in a flipped context.
    func draw(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: -prepared.bounds.minX, y: -prepared.bounds.minY)
        // BeautifulMermaid unflips around each label itself, then draws it
        // with AppKit, which would flip it again in a flipped view's context.
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        prepared.render(context, prepared.bounds)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    /// The chart on its canvas, for zooming in.
    func image(palette: ThemePalette) -> NSImage {
        NSImage(size: size, flipped: true) { rect in
            palette.codeBackground.setFill()
            rect.fill()
            if let context = NSGraphicsContext.current?.cgContext { self.draw(in: context) }
            return true
        }
    }
}

// MARK: - Scrolling canvas

/// The chart's scroll view. Clicks fall through to the block, which selects or edits it.
final class DiagramScrollView: NSScrollView {
    override var isFlipped: Bool { true }
}

/// Draws the canvas and the chart, centered when it's narrower than the column.
final class DiagramCanvasView: NSView {
    static let radius: CGFloat = 12

    var content: DiagramContent?
    var palette: ThemePalette?
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    var isZoomedOut = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette, let context = NSGraphicsContext.current?.cgContext else { return }
        // The rounded frame and the fades stay put while the chart moves under them.
        let visible = visibleRect
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let frame = NSBezierPath(roundedRect: visible, xRadius: Self.radius, yRadius: Self.radius)
        frame.addClip()
        palette.codeBackground.setFill()
        bounds.fill()
        if !isZoomedOut, let content {
            let width = content.size.width * scale
            context.saveGState()
            context.translateBy(x: max(0, (bounds.width - width) / 2).rounded(), y: 0)
            context.scaleBy(x: scale, y: scale)
            content.draw(in: context)
            context.restoreGState()
            drawFades(in: visible, color: palette.codeBackground)
        }
        palette.codeBorder.setStroke()
        let border = NSBezierPath(roundedRect: visible.insetBy(dx: 0.5, dy: 0.5), xRadius: Self.radius, yRadius: Self.radius)
        border.lineWidth = 1
        border.stroke()
    }

    /// Soft edges where a wide chart runs on past the column, fading in with
    /// the distance left so they don't pop.
    private func drawFades(in visible: NSRect, color: NSColor) {
        let overflow = bounds.width - visible.width
        guard overflow > 0.5 else { return }
        let fade: CGFloat = 32
        let left = min(1, max(0, visible.minX / fade))
        let right = min(1, max(0, (bounds.width - visible.maxX) / fade))
        if left > 0 {
            NSGradient(starting: color.withAlphaComponent(left), ending: color.withAlphaComponent(0))?
                .draw(in: NSRect(x: visible.minX, y: visible.minY, width: fade, height: visible.height), angle: 0)
        }
        if right > 0 {
            NSGradient(starting: color.withAlphaComponent(0), ending: color.withAlphaComponent(right))?
                .draw(in: NSRect(x: visible.maxX - fade, y: visible.minY, width: fade, height: visible.height), angle: 0)
        }
    }

    // Clicks belong to the block, not the scroll view.
    override func mouseDown(with event: NSEvent) { nextResponderForClicks?.mouseDown(with: event) }
    override func rightMouseDown(with event: NSEvent) { nextResponderForClicks?.rightMouseDown(with: event) }
    private var nextResponderForClicks: NSView? { enclosingScrollView?.superview }
}
