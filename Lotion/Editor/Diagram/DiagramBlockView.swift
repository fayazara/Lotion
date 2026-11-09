//
//  DiagramBlockView.swift
//  Lotion
//
//  A ```mermaid fence, drawn. Cards sit on a dotted canvas with an icon,
//  a title and a line of detail; wires leave from ports and bend at right
//  angles. Double-click (or Edit) shows the source under the drawing, which
//  follows every keystroke; clicking away puts the source away again.
//

import AppKit

final class DiagramBlockView: BlockView {
    private(set) var textView: BlockTextView?
    private(set) var isEditing = false
    private var content: DiagramContent?
    private var problem: DiagramProblem?
    private var metrics = FlowMetrics(base: 15)
    private var renderedSource: String?
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
        guard renderedSource != source else { return }
        renderedSource = source
        metrics = FlowMetrics(base: theme.em)
        switch DiagramContent.make(source, metrics: metrics) {
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
        canvas.metrics = metrics
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
        renderedSource = nil
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
        zoomButton.isHidden = !isHovered || content?.isEmpty ?? true
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
        guard let content, !content.isEmpty else { return 96 }
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
        return (shape, showsSource && preview.height == 0 ? 8 : DiagramPainter.canvasRadius)
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
        let shows = problem == nil && content.map { !$0.isEmpty } == true && preview.height > 0
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
        guard let content, !content.isEmpty else {
            MediaPlaceholder.draw(in: preview, symbol: "point.3.connected.trianglepath.dotted", palette: palette, caption: "Empty diagram")
            return
        }
        _ = content
        // The chart itself is drawn by the canvas in the scroll view above.
    }

    private func drawNotice(_ problem: DiagramProblem, in rect: NSRect) {
        let palette = theme.palette
        let text: String
        switch problem {
        case .empty: text = "Write a flowchart below to draw it."
        case .unsupported(let kind): text = "Lotion draws flowcharts and sequence diagrams. “\(kind)” diagrams show as their source."
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
        guard let content, !content.isEmpty else { return }
        let palette = theme.palette
        let size = content.size
        let metrics = self.metrics
        let image = NSImage(size: size, flipped: true) { rect in
            DiagramPainter.drawCanvas(in: rect, palette: palette, rounded: false)
            content.draw(metrics: metrics, palette: palette)
            return true
        }
        MediaZoom.shared.show(MediaZoom.Request(
            content: .image(image),
            rect: { [weak self] in
                guard let self, self.window != nil else { return nil }
                let area = self.previewRect
                let scale = self.scale(for: area.width)
                let width = size.width * scale
                return NSRect(x: area.minX + max(0, (area.width - width) / 2) - self.scrollX, y: area.minY,
                              width: width, height: size.height * scale)
            },
            source: self,
            radius: DiagramPainter.canvasRadius,
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

/// The colors every kind of chart shares.
struct DiagramInk {
    let palette: ThemePalette

    var cardFill: NSColor {
        palette.isDark
            ? palette.codeBackground.blended(withFraction: 0.07, of: .white) ?? palette.codeBackground
            : palette.background.blended(withFraction: 0.6, of: .white) ?? palette.background
    }
    var cardBorder: NSColor { palette.text.withAlphaComponent(palette.isDark ? 0.12 : 0.1) }
    var wire: NSColor { palette.text.withAlphaComponent(palette.isDark ? 0.32 : 0.26) }
}

/// A parsed, laid-out chart of any kind Lotion draws.
enum DiagramContent {
    case flow(Flowchart, FlowLayout)
    case sequence(SequenceChart, SequenceLayout)

    static func make(_ source: String, metrics: FlowMetrics) -> Result<DiagramContent, DiagramProblem> {
        if SequenceParser.isSequence(source) {
            return SequenceParser.parse(source).map { .sequence($0, SequenceLayout.make($0, metrics: metrics)) }
        }
        return FlowchartParser.parse(source).map { .flow($0, FlowLayout.make($0, metrics: metrics)) }
    }

    var size: CGSize {
        switch self {
        case .flow(_, let layout): layout.size
        case .sequence(_, let layout): layout.size
        }
    }

    var isEmpty: Bool {
        switch self {
        case .flow(_, let layout): layout.nodes.isEmpty
        case .sequence(_, let layout): layout.cards.isEmpty
        }
    }

    func draw(metrics: FlowMetrics, palette: ThemePalette) {
        switch self {
        case .flow(let chart, let layout): DiagramPainter(chart: chart, layout: layout, metrics: metrics, palette: palette).draw()
        case .sequence(_, let layout): SequencePainter(layout: layout, metrics: metrics, palette: palette).draw()
        }
    }
}

// MARK: - Scrolling canvas

/// The chart's scroll view. Clicks fall through to the block, which selects or edits it.
final class DiagramScrollView: NSScrollView {
    override var isFlipped: Bool { true }
}

/// Draws the dotted canvas and the chart, centered when it's narrower than the column.
final class DiagramCanvasView: NSView {
    var content: DiagramContent?
    var metrics = FlowMetrics(base: 15)
    var palette: ThemePalette?
    var scale: CGFloat = 1 { didSet { needsDisplay = true } }
    var isZoomedOut = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let palette else { return }
        // The rounded frame and the fades stay put while the chart moves under them.
        let visible = visibleRect
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: visible, xRadius: DiagramPainter.canvasRadius, yRadius: DiagramPainter.canvasRadius).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }
        DiagramPainter.drawCanvas(in: bounds, palette: palette, rounded: false)
        guard !isZoomedOut, let content else { return }
        let width = content.size.width * scale
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: max(0, (bounds.width - width) / 2).rounded(), yBy: 0)
        transform.scale(by: scale)
        transform.concat()
        content.draw(metrics: metrics, palette: palette)
        NSGraphicsContext.restoreGraphicsState()
        drawFades(in: visible, color: palette.codeBackground)
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

// MARK: - Painting

/// Draws a laid-out chart in its own coordinates (flipped, in points).
struct DiagramPainter {
    let chart: Flowchart
    let layout: FlowLayout
    let metrics: FlowMetrics
    let palette: ThemePalette

    static let canvasRadius: CGFloat = 12

    static func drawCanvas(in rect: NSRect, palette: ThemePalette, rounded: Bool = true) {
        let radius = rounded ? canvasRadius : 0
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        palette.codeBackground.setFill()
        path.fill()
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        let spacing: CGFloat = 16
        let dot = palette.marker.withAlphaComponent(palette.isDark ? 0.32 : 0.75)
        dot.setFill()
        var y = rect.minY + spacing / 2
        while y < rect.maxY {
            var x = rect.minX + spacing / 2
            while x < rect.maxX {
                NSBezierPath(ovalIn: NSRect(x: x - 0.8, y: y - 0.8, width: 1.6, height: 1.6)).fill()
                x += spacing
            }
            y += spacing
        }
        NSGraphicsContext.restoreGraphicsState()
        if rounded {
            palette.codeBorder.setStroke()
            let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
            border.lineWidth = 1
            border.stroke()
        }
    }

    // MARK: Colors

    private var cardFill: NSColor { DiagramInk(palette: palette).cardFill }
    private var cardBorder: NSColor { DiagramInk(palette: palette).cardBorder }
    private var wire: NSColor { DiagramInk(palette: palette).wire }

    /// A node's tint: from `style`, its classes, or nothing.
    private func tint(of node: FlowNode) -> NSColor? {
        if let stroke = node.stroke { return NSColor(hex: stroke) }
        for name in node.classes {
            if let colors = chart.classColors[name], let color = colors.stroke ?? colors.fill { return NSColor(hex: color) }
            switch name.lowercased() {
            case "accent", "active", "highlight", "primary", "selected", "current": return palette.accent
            case "done", "success", "complete", "completed", "ok": return NSColor(hex: 0x30A46C)
            case "error", "fail", "failed", "danger": return NSColor(hex: 0xE5484D)
            case "warn", "warning", "pending": return NSColor(hex: 0xE2A336)
            default: continue
            }
        }
        return nil
    }

    private func wireColor(_ edge: FlowEdge) -> NSColor {
        if let stroke = edge.stroke { return NSColor(hex: stroke) }
        if let from = chart.index(of: edge.from), let to = chart.index(of: edge.to),
           let a = tint(of: chart.nodes[from]), let b = tint(of: chart.nodes[to]), a == b { return a }
        return wire
    }

    // MARK: Draw

    func draw() {
        for group in layout.groups { drawGroup(group) }
        drawWires()
        for edge in layout.edges { drawWireLabel(edge) }
        for node in layout.nodes { drawCard(node) }
        drawPorts()
    }

    private func drawGroup(_ group: PlacedGroup) {
        let path = NSBezierPath(roundedRect: group.rect, xRadius: 16, yRadius: 16)
        palette.text.withAlphaComponent(palette.isDark ? 0.035 : 0.025).setFill()
        path.fill()
        palette.text.withAlphaComponent(0.1).setStroke()
        path.lineWidth = 1
        path.setLineDash([4, 3], count: 2, phase: 0)
        path.stroke()
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.label, .foregroundColor: palette.secondary]
        (group.title as NSString).draw(at: NSPoint(x: group.rect.minX + 14, y: group.rect.minY + 9), withAttributes: attributes)
    }

    /// Wires that share a trunk overlap; each style is stroked as one path so
    /// shared runs paint once instead of darkening, and shared arrows draw once.
    private func drawWires() {
        struct Style: Hashable { let color: NSColor; let line: FlowLine }
        var paths: [Style: CGMutablePath] = [:]
        var order: [Style] = []
        var heads: [(FlowHead, CGPoint, CGPoint, NSColor)] = []
        var seen: Set<String> = []
        for placed in layout.edges {
            let edge = chart.edges[placed.index]
            let points = placed.points
            guard points.count >= 2 else { continue }
            let color = wireColor(edge)
            let style = Style(color: color, line: edge.line)
            if paths[style] == nil { paths[style] = CGMutablePath(); order.append(style) }
            let path = paths[style]!
            path.move(to: points[0])
            for i in 1..<(points.count - 1) {
                let previous = points[i - 1], corner = points[i], next = points[i + 1]
                let radius = min(10, hypot(corner.x - previous.x, corner.y - previous.y) / 2, hypot(next.x - corner.x, next.y - corner.y) / 2)
                if radius < 0.5 { path.addLine(to: corner) } else { path.addArc(tangent1End: corner, tangent2End: next, radius: radius) }
            }
            // Stop short of an arrow's tip so the line doesn't poke through it.
            let end = points[points.count - 1]
            let direction = unit(from: points[points.count - 2], to: end)
            let inset: CGFloat = edge.head == .arrow ? 1 : edge.head == .circle ? 4 : 0
            path.addLine(to: CGPoint(x: end.x - direction.x * inset, y: end.y - direction.y * inset))
            func head(_ kind: FlowHead, _ tip: CGPoint, _ d: CGPoint) {
                guard kind != .none else { return }
                let id = "\(kind)@\(Int(tip.x.rounded())),\(Int(tip.y.rounded()))"
                guard seen.insert(id).inserted else { return }
                heads.append((kind, tip, d, color))
            }
            head(edge.head, end, direction)
            if edge.tail != .none { head(edge.tail, points[0], unit(from: points[1], to: points[0])) }
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        for style in order {
            guard let path = paths[style] else { continue }
            context.saveGState()
            context.addPath(path)
            context.setStrokeColor(style.color.cgColor)
            context.setLineWidth(style.line == .thick ? 2.25 : 1.25)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if style.line == .dotted { context.setLineDash(phase: 0, lengths: [3, 4]) }
            context.strokePath()
            context.restoreGState()
        }
        for (kind, tip, direction, color) in heads { drawHead(kind, at: tip, direction: direction, color: color) }
    }

    private func unit(from a: CGPoint, to b: CGPoint) -> CGPoint {
        let length = max(0.001, hypot(b.x - a.x, b.y - a.y))
        return CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
    }

    private func drawHead(_ head: FlowHead, at tip: CGPoint, direction d: CGPoint, color: NSColor) {
        let normal = CGPoint(x: -d.y, y: d.x)
        switch head {
        case .none:
            return
        case .arrow:
            let size: CGFloat = 6
            let path = NSBezierPath()
            path.move(to: NSPoint(x: tip.x - d.x * size + normal.x * size * 0.8, y: tip.y - d.y * size + normal.y * size * 0.8))
            path.line(to: tip)
            path.line(to: NSPoint(x: tip.x - d.x * size - normal.x * size * 0.8, y: tip.y - d.y * size - normal.y * size * 0.8))
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case .circle:
            let center = NSPoint(x: tip.x - d.x * 4, y: tip.y - d.y * 4)
            let path = NSBezierPath(ovalIn: NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7))
            cardFill.setFill()
            path.fill()
            path.lineWidth = 1.5
            color.setStroke()
            path.stroke()
        case .cross:
            let center = NSPoint(x: tip.x - d.x * 5, y: tip.y - d.y * 5)
            let path = NSBezierPath()
            for sign in [-1.0, 1.0] {
                path.move(to: NSPoint(x: center.x - 3.5, y: center.y - 3.5 * sign))
                path.line(to: NSPoint(x: center.x + 3.5, y: center.y + 3.5 * sign))
            }
            path.lineWidth = 1.5
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        }
    }

    private func drawWireLabel(_ placed: PlacedEdge) {
        guard let point = placed.labelPoint else { return }
        let text = chart.edges[placed.index].label
        let attributes: [NSAttributedString.Key: Any] = [.font: metrics.label, .foregroundColor: palette.secondary]
        let size = (text as NSString).size(withAttributes: attributes)
        let pill = NSRect(x: point.x - size.width / 2 - 8, y: point.y - size.height / 2 - 3, width: size.width + 16, height: size.height + 6)
        let path = NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2)
        cardFill.setFill()
        path.fill()
        cardBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        (text as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attributes)
    }

    /// A dot where each wire leaves its card, drawn once per port.
    private func drawPorts() {
        var drawn: [CGPoint] = []
        for placed in layout.edges {
            guard let start = placed.points.first else { continue }
            if drawn.contains(where: { hypot($0.x - start.x, $0.y - start.y) < 1 }) { continue }
            drawn.append(start)
            let color = wireColor(chart.edges[placed.index])
            let ring = NSBezierPath(ovalIn: NSRect(x: start.x - 4.5, y: start.y - 4.5, width: 9, height: 9))
            cardFill.setFill()
            ring.fill()
            let isTinted = color != wire
            let dot = NSBezierPath(ovalIn: NSRect(x: start.x - 3, y: start.y - 3, width: 6, height: 6))
            (isTinted ? color : palette.text.withAlphaComponent(palette.isDark ? 0.3 : 0.2)).setFill()
            dot.fill()
        }
    }

    private func drawCard(_ placed: PlacedNode) {
        let node = chart.nodes[placed.index]
        let rect = placed.rect
        let tint = tint(of: node)
        let p = FlowMetrics.padding
        let compact = node.detail.isEmpty && placed.portLabels.isEmpty
        let radius = (node.shape == .stadium || node.shape == .circle) && compact ? rect.height / 2 : FlowMetrics.radius

        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if !palette.isDark {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.05)
            shadow.shadowBlurRadius = 6
            shadow.shadowOffset = NSSize(width: 0, height: -1)
            shadow.set()
        }
        cardFill.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if let fill = node.fill {
            NSColor(hex: fill).withAlphaComponent(0.12).setFill()
            path.fill()
        }
        (tint ?? cardBorder).setStroke()
        path.lineWidth = tint == nil ? 1 : 1.5
        path.stroke()

        // Icon chip, title beside it, detail under both.
        let symbol = FlowIcons.symbol(for: node)
        let hue = tint ?? FlowIcons.hue(for: symbol, dark: palette.isDark)
        let chip = NSRect(x: rect.minX + p, y: rect.minY + p, width: FlowMetrics.chip, height: FlowMetrics.chip)
        let chipPath = NSBezierPath(roundedRect: chip, xRadius: 8, yRadius: 8)
        hue.withAlphaComponent(palette.isDark ? 0.2 : 0.12).setFill()
        chipPath.fill()
        hue.withAlphaComponent(0.18).setStroke()
        chipPath.lineWidth = 1
        chipPath.stroke()
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))?.tinted(hue) {
            let size = image.size
            image.draw(in: NSRect(x: chip.midX - size.width / 2, y: chip.midY - size.height / 2, width: size.width, height: size.height),
                       from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        let titleX = chip.maxX + FlowMetrics.chipGap
        let titleWidth = rect.maxX - p - titleX
        let titleAttributes: [NSAttributedString.Key: Any] = [.font: metrics.title, .foregroundColor: palette.text]
        let titleSize = metrics.size(of: node.title, font: metrics.title, width: titleWidth)
        // One line sits level with the chip's icon; wrapped titles start at its top.
        let oneLine = titleSize.height <= CardRow.lineHeight(metrics.title) + 1
        let titleY = oneLine ? CardRow.top(of: metrics.title, centeredOn: chip.midY)
            : titleSize.height <= FlowMetrics.chip ? (chip.midY - titleSize.height / 2).rounded() : chip.minY
        (node.title as NSString).draw(with: NSRect(x: titleX, y: titleY, width: titleWidth, height: titleSize.height + 2),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: titleAttributes)
        if !node.detail.isEmpty {
            let top = rect.minY + p + max(FlowMetrics.chip, titleSize.height) + FlowMetrics.detailGap
            let detailAttributes: [NSAttributedString.Key: Any] = [.font: metrics.detail, .foregroundColor: palette.secondary]
            let height = metrics.size(of: node.detail, font: metrics.detail, width: rect.width - p * 2).height
            (node.detail as NSString).draw(with: NSRect(x: rect.minX + p, y: top, width: rect.width - p * 2, height: height + 2),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: detailAttributes)
        }

        // Branch labels: beside their ports across a horizontal chart, above them in a vertical one.
        let labelAttributes: [NSAttributedString.Key: Any] = [.font: metrics.detail, .foregroundColor: palette.secondary]
        for label in placed.portLabels {
            let size = (label.text as NSString).size(withAttributes: labelAttributes)
            let origin = label.trailing
                ? NSPoint(x: label.point.x - 14 - size.width, y: label.point.y - size.height / 2)
                : NSPoint(x: label.point.x - size.width / 2, y: label.point.y - size.height - 8)
            (label.text as NSString).draw(at: origin, withAttributes: labelAttributes)
        }
    }
}

// MARK: - Icons

/// The icon on a card: named in the chart, or guessed from its words and shape.
enum FlowIcons {
    private static let keywords: [(words: [String], symbol: String)] = [
        (["start", "begin", "trigger", "triggered", "kickoff", "launch", "run"], "play"),
        (["end", "finish", "finished", "done", "complete", "completed", "success", "succeeded", "ok", "resolved"], "checkmark.circle"),
        (["stop", "cancel", "cancelled", "abort", "halt"], "stop.circle"),
        (["error", "fail", "failed", "failure", "reject", "rejected", "denied", "invalid", "exception", "crash"], "xmark.octagon"),
        (["warn", "warning", "alert", "risk"], "exclamationmark.triangle"),
        (["if", "decide", "decision", "route", "router", "branch", "condition", "switch", "choose", "valid?", "approved?"], "arrow.triangle.branch"),
        (["user", "users", "customer", "person", "client", "account", "member", "lead", "visitor", "profile", "contact", "you", "me", "human", "actor"], "person"),
        (["tool", "tools", "toolkit", "plugin", "plugins", "integration", "integrations"], "wrench.and.screwdriver"),
        (["team", "group", "people", "org", "organization"], "person.2"),
        (["login", "logout", "auth", "authenticate", "signin", "sign", "password", "secure", "security", "permission", "lock"], "lock"),
        (["key", "token", "secret", "credential", "credentials"], "key"),
        (["email", "mail", "inbox", "newsletter"], "envelope"),
        (["message", "chat", "slack", "sms", "reply", "comment", "discord"], "bubble.left"),
        (["send", "enroll", "sequence", "dispatch", "publish", "outreach", "submit"], "paperplane"),
        (["notify", "notification", "notifications", "remind", "reminder", "ping"], "bell"),
        (["database", "db", "store", "save", "persist", "record", "records", "table", "sql", "postgres", "mysql", "storage"], "cylinder.split.1x2"),
        (["cache", "redis", "memcache", "kv"], "bolt.horizontal"),
        (["queue", "job", "jobs", "worker", "workers", "batch", "task", "tasks"], "tray.full"),
        (["server", "backend", "host", "api", "endpoint", "service", "services", "worker", "lambda", "function"], "server.rack"),
        (["cloud", "aws", "gcp", "azure", "cloudflare"], "cloud"),
        (["folder", "folders", "directory", "disk", "drive", "filesystem"], "folder"),
        (["deploy", "deployment", "release", "ship", "upload"], "arrow.up.circle"),
        (["download", "fetch", "pull", "import"], "arrow.down.circle"),
        (["web", "website", "site", "browser", "http", "https", "url", "page", "internet", "online", "frontend"], "globe"),
        (["search", "find", "lookup", "research", "query", "explore", "scan"], "magnifyingglass"),
        (["agent", "bot", "bots", "assistant", "ai", "llm", "model", "gpt", "claude", "score", "classify", "predict", "summarize", "generate", "enrich"], "sparkles"),
        (["code", "build", "compile", "script", "commit", "git", "pr", "merge", "repo"], "chevron.left.forwardslash.chevron.right"),
        (["test", "tests", "check", "verify", "validate", "validation", "review", "approve", "approval", "qa"], "checkmark.seal"),
        (["wait", "delay", "timer", "schedule", "scheduled", "cron", "time", "timeout", "later"], "clock"),
        (["calendar", "date", "meeting", "event", "book", "booking"], "calendar"),
        (["pay", "payment", "payments", "invoice", "billing", "charge", "checkout", "order", "purchase", "buy", "refund", "subscription"], "creditcard"),
        (["cart", "shop", "store", "product", "products"], "cart"),
        (["file", "files", "document", "doc", "docs", "report", "pdf", "note", "notes", "draft"], "doc.text"),
        (["image", "photo", "picture", "media", "video"], "photo"),
        (["config", "configure", "setting", "settings", "setup", "prepare", "install", "init", "initialize"], "gearshape"),
        (["data", "analytics", "metric", "metrics", "chart", "stats", "dashboard", "insight", "insights"], "chart.bar"),
        (["transform", "process", "processing", "convert", "parse", "map", "normalize", "clean", "format"], "arrow.triangle.2.circlepath"),
        (["loop", "retry", "repeat", "again", "iterate", "sync", "refresh"], "arrow.clockwise"),
        (["input", "form", "enter", "create", "created", "new", "add", "signup", "register", "onboard"], "plus.square"),
        (["delete", "remove", "removed", "archive", "purge", "trash"], "trash"),
        (["update", "edit", "modify", "change", "write"], "pencil"),
        (["log", "logs", "history", "audit", "track", "tracking"], "list.bullet.rectangle"),
        (["phone", "call", "mobile", "app", "ios", "android"], "iphone"),
        (["location", "map", "address", "geo", "place"], "mappin"),
        (["deliver", "delivery", "shipping", "package", "fulfil", "fulfill", "fulfillment"], "shippingbox"),
        (["idea", "think", "plan", "brainstorm"], "lightbulb"),
        (["read", "learn", "study"], "book"),
        (["home", "landing", "index"], "house"),
    ]

    private static let lookup: [String: String] = {
        var table: [String: String] = [:]
        for (words, symbol) in keywords { for word in words where table[word] == nil { table[word] = symbol } }
        return table
    }()

    static func symbol(for node: FlowNode) -> String {
        if let icon = node.icon, NSImage(systemSymbolName: icon, accessibilityDescription: nil) != nil { return icon }
        if let icon = node.icon, let mapped = aliases[icon.lowercased().replacingOccurrences(of: "fa-", with: "")] { return mapped }
        switch node.shape {
        case .decision: return "arrow.triangle.branch"
        case .cylinder: return "cylinder.split.1x2"
        default: break
        }
        // "BotAgent" reads as "bot agent".
        let words = (node.title + " " + node.detail)
            .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        for word in words.prefix(12) {
            if let symbol = lookup[word] { return symbol }
        }
        for word in words.prefix(12) where word.count >= 5 {
            if let match = keywords.first(where: { $0.words.contains { word.hasPrefix($0) && $0.count >= 4 } }) { return match.symbol }
        }
        switch node.shape {
        case .circle, .stadium: return "circle.circle"
        case .hexagon: return "gearshape"
        case .subroutine: return "square.stack"
        case .document: return "doc.text"
        case .parallelogram: return "arrow.left.arrow.right"
        default: return "square.grid.2x2"
        }
    }

    /// Font Awesome and Material names people write in Mermaid, to SF Symbols.
    private static let aliases: [String: String] = [
        "user": "person", "users": "person.2", "database": "cylinder.split.1x2", "server": "server.rack", "cloud": "cloud",
        "envelope": "envelope", "bell": "bell", "lock": "lock", "key": "key", "cog": "gearshape", "gear": "gearshape",
        "check": "checkmark", "times": "xmark", "globe": "globe", "search": "magnifyingglass", "file": "doc", "code": "chevron.left.forwardslash.chevron.right",
        "robot": "sparkles", "bolt": "bolt", "clock": "clock", "calendar": "calendar", "credit-card": "creditcard", "shopping-cart": "cart",
        "account": "person", "email": "envelope", "home": "house", "phone": "phone", "mobile": "iphone", "car": "car", "heart": "heart",
        "star": "star", "flag": "flag", "play": "play", "stop": "stop", "trash": "trash", "pencil": "pencil", "edit": "pencil",
    ]

    private static let hues: [UInt32] = [0x3B82F6, 0xC026D3, 0x22A06B, 0x8B5CF6, 0xEA7A2E, 0x0EA5A4, 0xE11D74]

    private static let fixed: [String: UInt32] = [
        "xmark.octagon": 0xE5484D, "checkmark.circle": 0x22A06B, "arrow.triangle.branch": 0x8B5CF6,
        "paperplane": 0xEA7A2E, "sparkles": 0xC026D3, "exclamationmark.triangle": 0xE2A336, "play": 0x3B82F6,
    ]

    /// A steady color for an icon, the same in every chart.
    static func hue(for symbol: String, dark: Bool) -> NSColor {
        let value: UInt32
        if let fixed = fixed[symbol] {
            value = fixed
        } else {
            var hash: UInt32 = 5381
            for byte in symbol.utf8 { hash = (hash &* 33) &+ UInt32(byte) }
            value = hues[Int(hash % UInt32(hues.count))]
        }
        let color = NSColor(hex: value)
        return dark ? color.blended(withFraction: 0.25, of: .white) ?? color : color
    }
}
