//
//  BlockViews.swift
//  Lotion
//
//  One view per block. Text blocks make their text view only when they first
//  come near the screen; until then they are measured, not built.
//

import AppKit

enum CaretPlacement {
    case start
    case end
    case offset(Int)
    case range(NSRange)
    /// On the first or last line, nearest an x in the editor's coordinates.
    case line(first: Bool, x: CGFloat)
}

class BlockView: NSView {
    weak var editor: BlockEditorView?
    private(set) var block: Block
    var theme: BlockTheme
    /// The height this view wants at its current width.
    var measuredHeight: CGFloat = 0
    var measuredWidth: CGFloat = -1

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        self.block = block
        self.theme = theme
        self.editor = editor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    /// The text view that holds the caret when the block is focused.
    var primaryTextView: BlockTextView? { nil }
    var isMaterialized: Bool { true }
    func materialize() {}

    /// Takes a changed block. Returns whether its height may have changed.
    func update(_ block: Block) {
        self.block = block
        measuredWidth = -1
    }

    /// Records the model after the view edited it, without reloading the view.
    func adopt(_ block: Block) {
        self.block = block
    }

    func apply(theme: BlockTheme) {
        self.theme = theme
        measuredWidth = -1
    }

    func height(for width: CGFloat) -> CGFloat {
        if width != measuredWidth {
            measuredHeight = measure(width: width)
            measuredWidth = width
        }
        return measuredHeight
    }

    func invalidateHeight() { measuredWidth = -1 }

    func measure(width: CGFloat) -> CGFloat { 0 }

    /// The vertical middle of the first line, for the block handle.
    var firstLineMidY: CGFloat { min(bounds.height / 2, 14) }

    func focus(_ placement: CaretPlacement) {
        guard let textView = primaryTextView else { return }
        textView.window?.makeFirstResponder(textView)
        place(placement, in: textView)
    }

    func place(_ placement: CaretPlacement, in textView: BlockTextView) {
        let length = textView.textStorage?.length ?? 0
        switch placement {
        case .start:
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        case .end:
            textView.setSelectedRange(NSRange(location: length, length: 0))
        case .offset(let offset):
            textView.setSelectedRange(NSRange(location: max(0, min(length, offset)), length: 0))
        case .range(let range):
            let location = max(0, min(length, range.location))
            textView.setSelectedRange(NSRange(location: location, length: max(0, min(range.length, length - location))))
        case .line(let first, let x):
            let local = textView.convert(NSPoint(x: x, y: 0), from: editor)
            textView.placeCaret(onFirstLine: first, x: local.x)
        }
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    func layoutContent() {}

    /// Mouse down outside the block's text view, in this view's coordinates.
    /// Returns false to let the editor treat it as a click beside the text.
    func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool { false }

    /// The shape the block draws, in its own coordinates, with its corner radius.
    /// A selection wraps it at an even distance with a matching, larger radius.
    /// Text has no shape of its own, so it's selected edge to edge.
    var selectionShape: (rect: NSRect, radius: CGFloat) { (bounds, 0) }
}

// MARK: - Text blocks

/// Paragraphs, headings, list items, to-dos, quotes and raw Markdown.
final class TextBlockView: BlockView {
    private(set) var textView: BlockTextView?
    /// The text with display attributes, built once until the text view exists.
    private var displayed: NSAttributedString?
    /// A numbered item's number.
    var number: Int? { didSet { if number != oldValue { needsDisplay = true } } }

    override var primaryTextView: BlockTextView? {
        materialize()
        return textView
    }

    override var isMaterialized: Bool { textView != nil }

    var baseAttributes: [NSAttributedString.Key: Any] {
        theme.baseAttributes(for: block.kind, checked: block.checked)
    }

    private func displayText() -> NSAttributedString {
        if let displayed { return displayed }
        let text = theme.display(block.text, base: baseAttributes, code: block.kind == .raw)
        displayed = text
        return text
    }

    override func materialize() {
        guard textView == nil, let editor else { return }
        let view = BlockTextView(blockID: block.id, width: max(1, bounds.width - leadingInset))
        view.editor = editor
        view.delegate = editor
        view.textStorage?.setAttributedString(displayText())
        displayed = nil
        configure(view)
        addSubview(view)
        textView = view
        layoutContent()
    }

    private func configure(_ view: BlockTextView) {
        view.typingAttributes = baseAttributes
        view.insertionPointColor = theme.palette.text
        view.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        view.isContinuousSpellCheckingEnabled = theme.style.spellCheck && block.kind != .raw
        view.placeholderColor = theme.palette.marker
        view.placeholderFont = theme.font(for: block.kind)
        view.placeholderOffset = theme.baselineOffset(for: block.kind)
        updatePlaceholder()
    }

    func updatePlaceholder() {
        guard let textView else { return }
        let isTitle = editor?.isTitle(block.id) == true
        textView.placeholderOnlyWhenFocused = !isTitle && block.kind.headingLevel == nil
        // A scratchpad entry's first line says what the page is for.
        if let editor, editor.isScratchpad, block.kind == .paragraph, let index = editor.index(of: block.id),
           index > 0, editor.blocks[index - 1].kind == .entry {
            textView.placeholderOnlyWhenFocused = editor.blocks.count > 2
            textView.placeholder = "Jot something down. ⌘↩ starts a new entry."
            textView.needsDisplay = true
            return
        }
        textView.placeholder = switch block.kind {
        case .heading(let level): isTitle ? "Untitled" : "Heading \(level)"
        case .bullet, .numbered: "List"
        case .todo: "To-do"
        case .quote: "Quote"
        case .raw: "Markdown"
        default: "Type “/” for commands"
        }
        textView.needsDisplay = true
    }

    override func update(_ block: Block) {
        let old = self.block
        super.update(block)
        let formatChanged = old.kind != block.kind || old.checked != block.checked || old.alert != block.alert
        if let textView {
            if formatChanged || !(textView.textStorage?.isEqual(to: block.text) ?? false) {
                let selection = textView.selectedRange()
                textView.textStorage?.setAttributedString(theme.display(block.text, base: baseAttributes, code: block.kind == .raw))
                let length = textView.textStorage?.length ?? 0
                textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            }
            configure(textView)
        } else {
            displayed = nil
        }
        needsDisplay = true
        needsLayout = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        if let textView {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(theme.display(block.text, base: baseAttributes, code: block.kind == .raw))
            textView.setSelectedRange(selection)
            configure(textView)
        } else {
            displayed = nil
        }
        needsDisplay = true
    }

    var leadingInset: CGFloat {
        var inset = CGFloat(block.indent) * theme.indentWidth
        if block.kind.isList { inset += block.kind == .numbered ? max(theme.markerWidth, numberWidth + 6) : theme.markerWidth }
        if block.kind == .quote { inset += round(theme.em * 1.05) }
        return inset
    }

    private var numberWidth: CGFloat {
        let digits = String(max(1, number ?? 1)).count
        let sample = String(repeating: "8", count: digits) + "."
        return ceil((sample as NSString).size(withAttributes: [.font: theme.body]).width)
    }

    override func measure(width: CGFloat) -> CGFloat {
        let textWidth = max(20, width - leadingInset)
        let text = textView?.textStorage.map { NSAttributedString(attributedString: $0) } ?? displayText()
        return TextMeasurer.shared.height(of: text, width: textWidth, base: baseAttributes) + alertHeader
    }

    /// The title row of a GitHub alert ("Note", "Warning", …).
    private var alertHeader: CGFloat {
        block.kind == .quote && block.alert != nil ? theme.lineHeight(for: .paragraph) : 0
    }

    override func layoutContent() {
        textView?.frame = NSRect(x: leadingInset, y: alertHeader, width: max(20, bounds.width - leadingInset),
                                 height: max(1, bounds.height - alertHeader))
    }

    override var firstLineMidY: CGFloat {
        round(theme.lineHeight(for: block.kind == .quote && block.alert != nil ? .paragraph : block.kind) / 2)
    }

    static func alertStyle(_ alert: String) -> (title: String, symbol: String, color: NSColor) {
        switch alert {
        case "TIP": ("Tip", "lightbulb", NSColor(hex: 0x3FB950))
        case "IMPORTANT": ("Important", "exclamationmark.bubble", NSColor(hex: 0xA371F7))
        case "WARNING": ("Warning", "exclamationmark.triangle", NSColor(hex: 0xD29922))
        case "CAUTION": ("Caution", "exclamationmark.octagon", NSColor(hex: 0xF85149))
        default: ("Note", "info.circle", NSColor(hex: 0x4493F8))
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let palette = theme.palette
        let indent = CGFloat(block.indent) * theme.indentWidth
        let mid = firstLineMidY
        switch block.kind {
        case .bullet:
            let center = NSPoint(x: indent + theme.markerWidth / 2 - 2, y: mid)
            let size: CGFloat = round(theme.em * 0.36)
            let rect = NSRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
            palette.text.setFill()
            palette.text.setStroke()
            switch block.indent % 3 {
            case 0: NSBezierPath(ovalIn: rect).fill()
            case 1:
                let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.6, dy: 0.6))
                ring.lineWidth = 1.2
                ring.stroke()
            default: NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            }
        case .numbered:
            let label = "\(number ?? 1)." as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: theme.body, .foregroundColor: palette.text]
            let size = label.size(withAttributes: attributes)
            let column = max(theme.markerWidth, numberWidth + 6)
            label.draw(at: NSPoint(x: indent + column - size.width - 6, y: mid - size.height / 2), withAttributes: attributes)
        case .todo:
            let side = round(theme.em * 1.0)
            let rect = NSRect(x: indent + (theme.markerWidth - side) / 2 - 2, y: mid - side / 2, width: side, height: side)
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), xRadius: 3.5, yRadius: 3.5)
            if block.checked {
                palette.accent.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: rect.minX + side * 0.26, y: rect.minY + side * 0.52))
                check.line(to: NSPoint(x: rect.minX + side * 0.43, y: rect.minY + side * 0.69))
                check.line(to: NSPoint(x: rect.minX + side * 0.75, y: rect.minY + side * 0.33))
                check.lineWidth = 1.8
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                box.lineWidth = 1.5
                palette.secondary.withAlphaComponent(0.7).setStroke()
                box.stroke()
            }
        case .quote:
            if let alert = block.alert {
                let style = Self.alertStyle(alert)
                style.color.setFill()
                NSBezierPath(roundedRect: NSRect(x: indent + 1, y: 3, width: 3, height: max(0, bounds.height - 6)),
                             xRadius: 1.5, yRadius: 1.5).fill()
                let font = NSFont.systemFont(ofSize: theme.body.pointSize, weight: .semibold)
                let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.color]
                let titleSize = (style.title as NSString).size(withAttributes: attributes)
                var x = leadingInset
                if let symbol = NSImage(systemSymbolName: style.symbol, accessibilityDescription: style.title)?
                    .withSymbolConfiguration(.init(pointSize: theme.body.pointSize - 1, weight: .semibold)) {
                    let icon = symbol.tinted(style.color)
                    icon.draw(in: NSRect(x: x, y: mid - icon.size.height / 2, width: icon.size.width, height: icon.size.height),
                              from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    x += icon.size.width + 6
                }
                (style.title as NSString).draw(at: NSPoint(x: x, y: mid - titleSize.height / 2), withAttributes: attributes)
            } else {
                palette.marker.setFill()
                NSBezierPath(roundedRect: NSRect(x: indent + 1, y: 3, width: 3, height: max(0, bounds.height - 6)),
                             xRadius: 1.5, yRadius: 1.5).fill()
            }
        default:
            break
        }
    }

    /// The checkbox's hit area, in this view's coordinates.
    var checkboxRect: NSRect? {
        guard block.kind == .todo else { return nil }
        let indent = CGFloat(block.indent) * theme.indentWidth
        let side = round(theme.em * 1.0) + 8
        return NSRect(x: indent + (theme.markerWidth - side) / 2 - 2, y: firstLineMidY - side / 2, width: side, height: side)
    }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        if let checkboxRect, checkboxRect.contains(point) {
            editor?.toggleChecked(block.id)
            return true
        }
        return false
    }
}

// MARK: - Divider

final class DividerBlockView: BlockView {
    override func measure(width: CGFloat) -> CGFloat { round(theme.em * 1.4) }

    override func draw(_ dirtyRect: NSRect) {
        theme.palette.rule.setFill()
        let indent = CGFloat(block.indent) * theme.indentWidth
        NSRect(x: indent, y: round(bounds.midY), width: bounds.width - indent, height: 1).fill()
    }

    override var firstLineMidY: CGFloat { round(bounds.midY) }

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        editor?.selectBlocks([block.id])
        return true
    }
}

// MARK: - Code

final class CodeBlockView: BlockView {
    private(set) var textView: BlockTextView?
    private let languageButton = NSButton(title: "", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private var tracking: NSTrackingArea?
    private var isHovered = false { didSet { copyButton.isHidden = !isHovered } }

    static let padding: CGFloat = 16
    static let header: CGFloat = 30

    required init(block: Block, theme: BlockTheme, editor: BlockEditorView) {
        super.init(block: block, theme: theme, editor: editor)
        for button in [languageButton, copyButton] {
            button.isBordered = false
            button.controlSize = .small
            button.font = .systemFont(ofSize: 11, weight: .medium)
            button.target = self
            addSubview(button)
        }
        languageButton.action = #selector(chooseLanguage)
        copyButton.action = #selector(copyCode)
        copyButton.isHidden = true
        updateLabels()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var primaryTextView: BlockTextView? {
        materialize()
        return textView
    }

    override var isMaterialized: Bool { textView != nil }

    override func materialize() {
        guard textView == nil, let editor else { return }
        let view = BlockTextView(blockID: block.id, width: 100)
        view.editor = editor
        view.delegate = editor
        view.isRichText = false
        configure(view)
        view.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
        addSubview(view)
        textView = view
        layoutContent()
        highlight()
    }

    private func configure(_ view: BlockTextView) {
        view.typingAttributes = theme.baseAttributes(for: .code)
        view.insertionPointColor = theme.palette.text
        view.selectedTextAttributes = [.backgroundColor: theme.palette.selection]
        view.isContinuousSpellCheckingEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.placeholder = "Code"
        view.placeholderColor = theme.palette.marker
        view.placeholderFont = theme.code
        view.placeholderOffset = theme.baselineOffset(for: .code)
    }

    private func updateLabels() {
        let language = block.language
        let title = language.isEmpty ? "Plain Text" : CodeLanguages.title(for: language)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: theme.palette.secondary,
        ]
        languageButton.attributedTitle = NSAttributedString(string: title + " ▾", attributes: attributes)
        copyButton.attributedTitle = NSAttributedString(string: "Copy", attributes: attributes)
    }

    override func update(_ block: Block) {
        let old = self.block
        super.update(block)
        if let textView, textView.string != block.text.string {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
            let length = textView.textStorage?.length ?? 0
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
        }
        if old.info != block.info || old.text.string != block.text.string { highlight() }
        updateLabels()
        needsLayout = true
    }

    override func apply(theme: BlockTheme) {
        super.apply(theme: theme)
        if let textView {
            configure(textView)
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(NSAttributedString(string: block.text.string, attributes: theme.baseAttributes(for: .code)))
            textView.setSelectedRange(selection)
        }
        updateLabels()
        highlight()
        needsDisplay = true
    }

    /// Colors the code with Shiki, as temporary attributes so layout is untouched.
    func highlight() {
        guard let textView, let layoutManager = textView.layoutManager else { return }
        let code = textView.string
        let full = NSRange(location: 0, length: (code as NSString).length)
        guard let language = CodeHighlighter.shared.supportedLanguage(block.language.lowercased()) else {
            layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
            return
        }
        guard let runs = CodeHighlighter.shared.runs(for: code, language: language, theme: theme.palette.shikiTheme) else { return }
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        for run in runs {
            guard let hex = run.color, let color = CodeHighlighter.shared.color(hex) else { continue }
            let range = NSIntersectionRange(NSRange(location: run.location, length: run.length), full)
            if range.length > 0 { layoutManager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range) }
        }
    }

    override func measure(width: CGFloat) -> CGFloat {
        let textWidth = max(20, width - indent - Self.padding * 2)
        let text = NSAttributedString(string: textView?.string ?? block.text.string, attributes: theme.baseAttributes(for: .code))
        return TextMeasurer.shared.height(of: text, width: textWidth, base: theme.baseAttributes(for: .code)) + Self.header + Self.padding - 2
    }

    private var indent: CGFloat { CGFloat(block.indent) * theme.indentWidth }

    override func layoutContent() {
        let box = NSRect(x: indent, y: 0, width: bounds.width - indent, height: bounds.height)
        textView?.frame = NSRect(x: box.minX + Self.padding, y: Self.header, width: max(20, box.width - Self.padding * 2),
                                 height: max(10, bounds.height - Self.header - Self.padding + 2))
        let language = languageButton.fittingSize
        languageButton.frame = NSRect(x: box.minX + Self.padding - 6, y: 6, width: language.width, height: language.height)
        let copy = copyButton.fittingSize
        copyButton.frame = NSRect(x: box.maxX - Self.padding - copy.width + 6, y: 6, width: copy.width, height: copy.height)
    }

    override var firstLineMidY: CGFloat { Self.header / 2 + 2 }

    override var selectionShape: (rect: NSRect, radius: CGFloat) {
        (NSRect(x: indent, y: 0, width: bounds.width - indent, height: bounds.height), 8)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSRect(x: indent, y: 0, width: bounds.width - indent, height: bounds.height)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        theme.palette.codeBackground.setFill()
        path.fill()
        theme.palette.codeBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
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

    override func mouseDownOutsideText(at point: NSPoint, event: NSEvent) -> Bool {
        // The padding around the code places the caret at its nearest end.
        guard let textView = primaryTextView else { return false }
        window?.makeFirstResponder(textView)
        let local = textView.convert(point, from: self)
        textView.setSelectedRange(NSRange(location: textView.characterIndex(near: local), length: 0))
        return true
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView?.string ?? block.text.string, forType: .string)
        copyButton.attributedTitle = NSAttributedString(string: "Copied", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: theme.palette.secondary,
        ])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.updateLabels() }
    }

    @objc private func chooseLanguage() {
        let menu = NSMenu()
        let current = block.language.lowercased()
        let plain = NSMenuItem(title: "Plain Text", action: #selector(pickLanguage(_:)), keyEquivalent: "")
        plain.representedObject = ""
        plain.target = self
        plain.state = current.isEmpty ? .on : .off
        menu.addItem(plain)
        menu.addItem(.separator())
        for (id, title) in CodeLanguages.common {
            let item = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            item.state = CodeLanguages.normalized(current) == id ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: languageButton.frame.minX, y: languageButton.frame.maxY + 4), in: self)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let language = sender.representedObject as? String else { return }
        editor?.setCodeLanguage(language, for: block.id)
    }
}

enum CodeLanguages {
    static let common: [(String, String)] = [
        ("bash", "Bash"), ("c", "C"), ("cpp", "C++"), ("csharp", "C#"), ("css", "CSS"), ("diff", "Diff"),
        ("dockerfile", "Dockerfile"), ("go", "Go"), ("graphql", "GraphQL"), ("html", "HTML"), ("java", "Java"),
        ("javascript", "JavaScript"), ("json", "JSON"), ("jsx", "JSX"), ("kotlin", "Kotlin"), ("lua", "Lua"),
        ("markdown", "Markdown"), ("objective-c", "Objective-C"), ("php", "PHP"), ("python", "Python"),
        ("ruby", "Ruby"), ("rust", "Rust"), ("scss", "SCSS"), ("shellscript", "Shell"), ("sql", "SQL"),
        ("swift", "Swift"), ("toml", "TOML"), ("tsx", "TSX"), ("typescript", "TypeScript"), ("vue", "Vue"),
        ("xml", "XML"), ("yaml", "YAML"),
    ]

    private static let aliases: [String: String] = [
        "sh": "bash", "zsh": "bash", "shell": "shellscript", "js": "javascript", "ts": "typescript",
        "py": "python", "rb": "ruby", "rs": "rust", "yml": "yaml", "c++": "cpp", "cs": "csharp",
        "objc": "objective-c", "md": "markdown", "golang": "go", "kt": "kotlin", "docker": "dockerfile",
    ]

    static func normalized(_ id: String) -> String { aliases[id] ?? id }

    static func title(for language: String) -> String {
        let id = normalized(language.lowercased())
        return common.first { $0.0 == id }?.1 ?? language
    }
}
