//
//  CodeBlockViews.swift
//  Lotion
//
//  A code block longer than its height scrolls inside a fixed viewport
//  instead of taking over the note. Its Markdown stays in the note, hidden,
//  with the block's first code line as tall as the viewport; a real scroll
//  view sits there, holding a text view with the same code, colors and line
//  numbers. Typing in it writes straight into the note's Markdown, so
//  saving, undo and highlighting all go through the note as usual.
//
//  A swipe that starts over the block scrolls the code while it can; one
//  that starts elsewhere, or when the code is already at that end, scrolls
//  the page, so the page never gets stuck under the pointer.
//

import AppKit

extension NSAttributedString.Key {
    /// A long code block's code, shown in a scrolling view (`CodeViewport`).
    static let lotionCodeViewport = NSAttributedString.Key("lotionCodeViewport")
}

/// How a scrolling code block is shown. One per restyle, so a view can tell
/// when its block was styled again.
final class CodeViewport: NSObject {
    let visibleLines: Int
    let lineHeight: CGFloat
    let numberWidth: CGFloat
    /// The note's code paragraph style, which the view adapts.
    let paragraph: NSParagraphStyle
    var height: CGFloat { CGFloat(visibleLines) * lineHeight }

    init(visibleLines: Int, lineHeight: CGFloat, numberWidth: CGFloat, paragraph: NSParagraphStyle) {
        self.visibleLines = visibleLines
        self.lineHeight = lineHeight
        self.numberWidth = numberWidth
        self.paragraph = paragraph
    }
}

// MARK: - The view

final class CodeBlockView: NSScrollView {
    let code: CodeTextView
    private let numbers: CodeLineNumbers
    weak var host: EditorTextView?
    /// Where the block's code starts in the note.
    var contentStart: Int
    /// The viewport it was last loaded from.
    private(set) weak var viewport: CodeViewport?
    /// Room on the right for the scroller, outside the code's column.
    static let scrollerRoom: CGFloat = 10

    private enum Gesture { case idle, inner, outer }
    private var gesture = Gesture.idle

    init(host: EditorTextView, contentStart: Int) {
        self.host = host
        self.contentStart = contentStart
        let storage = NSTextStorage()
        numbers = CodeLineNumbers()
        storage.addLayoutManager(numbers)
        let container = NSTextContainer(size: NSSize(width: 100, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        numbers.addTextContainer(container)
        code = CodeTextView(frame: .zero, textContainer: container)
        super.init(frame: .zero)
        code.block = self
        code.isRichText = false
        code.importsGraphics = false
        code.allowsUndo = false
        code.usesFindBar = false
        code.drawsBackground = false
        code.textContainerInset = .zero
        code.isVerticallyResizable = true
        code.isHorizontallyResizable = false
        code.autoresizingMask = [.width]
        code.minSize = .zero
        code.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        code.isAutomaticQuoteSubstitutionEnabled = false
        code.isAutomaticDashSubstitutionEnabled = false
        code.isAutomaticTextReplacementEnabled = false
        code.isAutomaticSpellingCorrectionEnabled = false
        code.isContinuousSpellCheckingEnabled = false
        code.isGrammarCheckingEnabled = false
        code.isAutomaticLinkDetectionEnabled = false
        code.isAutomaticDataDetectionEnabled = false
        code.smartInsertDeleteEnabled = false
        documentView = code
        drawsBackground = false
        contentView.drawsBackground = false
        borderType = .noBorder
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        scrollerStyle = .overlay
        horizontalScrollElasticity = .none
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows the block's code as the note has it styled.
    func load(_ source: NSAttributedString, viewport: CodeViewport, palette: ThemePalette) {
        self.viewport = viewport
        let paragraph = (viewport.paragraph.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        // The view starts where the note's text column does.
        let gutter = host?.gutter ?? 0
        paragraph.firstLineHeadIndent = viewport.numberWidth
        paragraph.headIndent = viewport.numberWidth
        paragraph.tailIndent = -Self.scrollerRoom
        _ = gutter
        let styled = NSMutableAttributedString(string: source.string)
        let whole = NSRange(location: 0, length: styled.length)
        styled.addAttribute(.paragraphStyle, value: paragraph, range: whole)
        source.enumerateAttributes(in: whole) { attributes, range, _ in
            var kept: [NSAttributedString.Key: Any] = [:]
            kept[.font] = attributes[.font]
            kept[.foregroundColor] = attributes[.foregroundColor]
            styled.addAttributes(kept, range: range)
        }
        let font = source.length > 0 ? source.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
        code.typingAttributes = [.font: font ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                                 .foregroundColor: palette.text, .paragraphStyle: paragraph]
        code.insertionPointColor = palette.text
        code.selectedTextAttributes = [.backgroundColor: palette.selection]
        numbers.numberWidth = viewport.numberWidth
        numbers.color = palette.marker
        numbers.codeFont = font ?? numbers.codeFont
        scrollerKnobStyle = palette.isDark ? .light : .dark

        guard let storage = code.textStorage else { return }
        if storage.string == styled.string {
            // Same code (typing here, or new colors): restyle in place, keeping the caret.
            storage.beginEditing()
            styled.enumerateAttributes(in: whole) { attributes, range, _ in storage.setAttributes(attributes, range: range) }
            storage.endEditing()
        } else {
            let selection = code.selectedRange()
            let scroll = contentView.bounds.origin
            code.isLoading = true
            storage.setAttributedString(styled)
            code.isLoading = false
            numbers.textChanged()
            code.setSelectedRange(NSRange(location: min(selection.location, styled.length), length: 0))
            contentView.scroll(to: scroll)
            reflectScrolledClipView(contentView)
        }
    }

    // MARK: Scrolling

    override func scrollWheel(with event: NSEvent) {
        let page = host?.enclosingScrollView
        if event.phase.isEmpty, event.momentumPhase.isEmpty {
            // A mouse wheel, notch by notch.
            if canScroll(event.scrollingDeltaY) || page == nil { super.scrollWheel(with: event) } else { page?.scrollWheel(with: event) }
            return
        }
        if event.phase.contains(.began) || event.phase.contains(.mayBegin) { gesture = .idle }
        if gesture == .idle {
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if !event.momentumPhase.isEmpty {
                // Momentum from a swipe that started elsewhere carries the page.
                gesture = .outer
            } else if dx == 0, dy == 0 {
                super.scrollWheel(with: event)
                page?.scrollWheel(with: event)
                return
            } else {
                gesture = abs(dy) >= abs(dx) && canScroll(dy) ? .inner : .outer
            }
        }
        if gesture == .inner || page == nil { super.scrollWheel(with: event) } else { page?.scrollWheel(with: event) }
    }

    /// Whether the code can move the way a delta asks.
    private func canScroll(_ deltaY: CGFloat) -> Bool {
        let bounds = contentView.bounds
        let height = documentView?.frame.height ?? 0
        if deltaY > 0 { return bounds.minY > 0.5 }
        if deltaY < 0 { return bounds.maxY < height - 0.5 }
        return false
    }
}

/// Draws a line number beside each line of code, as the note does.
final class CodeLineNumbers: NSLayoutManager {
    var numberWidth: CGFloat = 0
    var color: NSColor = .tertiaryLabelColor
    var codeFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
    private var lineStarts: [Int] = [0]

    /// Call when the text changes, so numbers can be found by line.
    func textChanged() {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        var starts = [0]
        var index = 0
        while index < text.length {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            index = NSMaxRange(line)
            if index < text.length || (index == text.length && text.length > 0 && text.character(at: text.length - 1) == 10) {
                if index <= text.length { starts.append(index) }
            }
        }
        lineStarts = starts
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let font = NSFont.monospacedDigitSystemFont(ofSize: codeFont.pointSize, weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let baseline = defaultBaselineOffset(for: codeFont)
        // The first line starting in view, by binary search.
        var low = 0, high = lineStarts.count
        while low < high {
            let mid = (low + high) / 2
            if lineStarts[mid] < characters.location { low = mid + 1 } else { high = mid }
        }
        if low > 0, lineStarts[low - 1] < characters.location {
            low -= 1 // the line the visible range starts inside
        }
        var line = low
        while line < lineStarts.count, lineStarts[line] <= NSMaxRange(characters) {
            let start = lineStarts[line]
            let rect: NSRect
            if start >= storage.length {
                rect = extraLineFragmentRect
                guard rect.height > 0 else { break }
            } else {
                rect = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: start), effectiveRange: nil)
            }
            let label = "\(line + 1)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: origin.x + numberWidth - 14 - size.width, y: origin.y + rect.minY + baseline - font.ascender),
                       withAttributes: attributes)
            line += 1
        }
    }
}

final class CodeTextView: NSTextView {
    weak var block: CodeBlockView?
    var isLoading = false
    private var host: EditorTextView? { block?.host }

    override func didChangeText() {
        super.didChangeText()
        (layoutManager as? CodeLineNumbers)?.textChanged()
        if !isLoading, let block { host?.codeViewDidChange(block) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        if let block { host?.codeViewDidFocus(block) }
        return true
    }

    /// A click always takes focus first, so the caret lands here and stays.
    override func mouseDown(with event: NSEvent) {
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        super.mouseDown(with: event)
    }

    override func insertTab(_ sender: Any?) { insertText("    ", replacementRange: selectedRange()) }
    override func cancelOperation(_ sender: Any?) { if let block { host?.leaveCode(block, downward: true) } }

    override func moveUp(_ sender: Any?) {
        guard isCaretOnEdgeLine(last: false), let block else { return super.moveUp(sender) }
        host?.leaveCode(block, downward: false)
    }

    override func moveDown(_ sender: Any?) {
        guard isCaretOnEdgeLine(last: true), let block else { return super.moveDown(sender) }
        host?.leaveCode(block, downward: true)
    }

    private func isCaretOnEdgeLine(last: Bool) -> Bool {
        guard selectedRange().length == 0, let layoutManager, let textContainer else { return true }
        let length = (string as NSString).length
        guard length > 0 else { return true }
        let caret = selectedRange().location
        let rect: NSRect
        if caret == length, (string as NSString).character(at: length - 1) == 10 {
            rect = layoutManager.extraLineFragmentRect
        } else {
            rect = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: min(caret, length - 1)), effectiveRange: nil)
        }
        var used = layoutManager.usedRect(for: textContainer)
        used = used.union(layoutManager.extraLineFragmentRect)
        return last ? rect.maxY >= used.maxY - 1 : rect.minY <= used.minY + 1
    }

    // Code isn't formatted: these stop here rather than reaching the note.
    @objc func toggleBold(_ sender: Any?) {}
    @objc func toggleItalic(_ sender: Any?) {}
    @objc func toggleStrikethrough(_ sender: Any?) {}
    @objc func toggleInlineCode(_ sender: Any?) {}
    @objc func insertLink(_ sender: Any?) {}

    /// Undo is the note's: code edits are on its stack.
    @objc func undo(_ sender: Any?) { host?.undoManager?.undo() }
    @objc func redo(_ sender: Any?) { host?.undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let manager = host?.undoManager
        switch item.action {
        case #selector(undo(_:)):
            (item as? NSMenuItem)?.title = manager?.undoMenuItemTitle ?? "Undo"
            return manager?.canUndo ?? false
        case #selector(redo(_:)):
            (item as? NSMenuItem)?.title = manager?.redoMenuItemTitle ?? "Redo"
            return manager?.canRedo ?? false
        case #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleStrikethrough(_:)),
             #selector(toggleInlineCode(_:)), #selector(insertLink(_:)):
            return false
        default:
            return super.validateUserInterfaceItem(item)
        }
    }
}

// MARK: - The note's side

extension EditorTextView {
    /// The scrolling code block whose code includes `index`.
    func codeViewport(at index: Int) -> (range: NSRange, viewport: CodeViewport)? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        var range = NSRange()
        guard let viewport = storage.attribute(.lotionCodeViewport, at: index, longestEffectiveRange: &range,
                                               in: NSRange(location: 0, length: storage.length)) as? CodeViewport else { return nil }
        return (range, viewport)
    }

    var isEditingCode: Bool { window?.firstResponder is CodeTextView }

    func setNeedsCodeViewSync() {
        guard !needsCodeViewSync else { return }
        needsCodeViewSync = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.needsCodeViewSync = false
            self.syncCodeViews()
        }
    }

    /// Puts a scroll view over each scrolling code block on screen (and a
    /// screen above and below), and takes away the ones no longer needed.
    func syncCodeViews() {
        guard let layoutManager, let textContainer, let storage = textStorage, let palette else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let origin = textContainerOrigin
        var seen = Set<Int>()
        if storage.length > 0 {
            let visible = visibleRect
            let area = NSRect(x: 0, y: visible.minY - origin.y - max(400, visible.height),
                              width: textContainer.size.width, height: visible.height + 2 * max(400, visible.height))
            let glyphs = layoutManager.glyphRange(forBoundingRect: area, in: textContainer)
            let characters = NSIntersectionRange(layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil), whole)
            var found: [(NSRange, CodeViewport)] = []
            storage.enumerateAttribute(.lotionCodeViewport, in: characters) { value, run, _ in
                guard value is CodeViewport, let block = codeViewport(at: run.location), !seen.contains(block.range.location) else { return }
                seen.insert(block.range.location)
                found.append((block.range, block.viewport))
            }
            // A block being edited stays, even scrolled far away.
            for (key, view) in codeViews where !seen.contains(key) && window?.firstResponder === view.code {
                if let block = codeViewport(at: key), block.range.location == key {
                    seen.insert(key)
                    found.append((block.range, block.viewport))
                }
            }
            for (range, viewport) in found {
                let view = codeViews[range.location] ?? makeCodeView(at: range.location)
                let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
                let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                let frame = NSRect(x: origin.x + gutter, y: origin.y + fragment.minY,
                                   width: tableColumnWidth + CodeBlockView.scrollerRoom, height: viewport.height)
                if view.frame != frame { view.frame = frame }
                if view.viewport !== viewport {
                    var code = range
                    if code.length > 0, (storage.string as NSString).character(at: NSMaxRange(code) - 1) == 10 { code.length -= 1 }
                    view.load(storage.attributedSubstring(from: code), viewport: viewport, palette: palette)
                }
            }
        }
        for (key, view) in codeViews where !seen.contains(key) {
            if window?.firstResponder === view.code {
                // The block no longer scrolls (it got short): the caret carries on in the note.
                let caret = min(key + view.code.selectedRange().location, storage.length)
                window?.makeFirstResponder(self)
                setSelectedRange(NSRange(location: caret, length: 0))
            }
            view.removeFromSuperview()
            codeViews[key] = nil
        }
    }

    private func makeCodeView(at location: Int) -> CodeBlockView {
        let view = CodeBlockView(host: self, contentStart: location)
        addSubview(view)
        codeViews[location] = view
        return view
    }

    /// For another note: no views carry over.
    func removeCodeViews() {
        for view in codeViews.values { view.removeFromSuperview() }
        codeViews = [:]
    }

    /// Keeps views keyed by where their code starts as text before it changes.
    func shiftCodeViews(after location: Int, by delta: Int) {
        guard delta != 0, !codeViews.isEmpty else { return }
        var shifted: [Int: CodeBlockView] = [:]
        for (key, view) in codeViews {
            let moved = key > location ? max(0, key + delta) : key
            view.contentStart = moved
            shifted[moved] = shifted[moved] ?? view
        }
        codeViews = shifted
    }

    /// Typing in a code view: the change goes into the note's Markdown.
    func codeViewDidChange(_ view: CodeBlockView) {
        guard let storage = textStorage, let block = codeViewport(at: view.contentStart), block.range.location == view.contentStart else { return }
        let markdown = view.code.string + "\n"
        let old = (storage.string as NSString).substring(with: block.range)
        guard old != markdown else { return }
        let change = Self.difference(old, markdown)
        let target = NSRange(location: block.range.location + change.range.location, length: change.range.length)
        isWritingCode = true
        if shouldChangeText(in: target, replacementString: change.replacement) {
            storage.replaceCharacters(in: target, with: change.replacement)
            didChangeText()
        }
        isWritingCode = false
        // New colors, or the block no longer scrolling, show right away.
        syncCodeViews()
    }

    /// The note's selection waits at the block while its code is edited; the
    /// note lays itself out only as far as its selection after each edit.
    func codeViewDidFocus(_ view: CodeBlockView) {
        endCellEditing(focusingNote: false)
        let start = view.contentStart
        if selectedRange() != NSRange(location: start, length: 0), start <= (string as NSString).length {
            setSelectedRange(NSRange(location: start, length: 0))
        }
    }

    /// The caret steps out of the code: onto the opening fence above, or the closing one below.
    func leaveCode(_ view: CodeBlockView, downward: Bool) {
        guard let block = codeViewport(at: view.contentStart) else { return }
        let target = downward ? NSMaxRange(block.range) : max(0, block.range.location - 1)
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: target, length: 0))
        scrollRangeToVisible(selectedRange())
    }

    /// Edits a scrolling block's code with the caret at `offset` into it.
    func focusCode(at location: Int, selecting length: Int = 0) {
        guard let block = codeViewport(at: location) else { return }
        if codeViews[block.range.location] == nil {
            scrollRangeToVisible(NSRange(location: block.range.location, length: 0))
            syncCodeViews()
        }
        guard let view = codeViews[block.range.location] else { return }
        let codeLength = (view.code.string as NSString).length
        let offset = min(max(0, location - block.range.location), codeLength)
        window?.makeFirstResponder(view.code)
        view.code.setSelectedRange(NSRange(location: offset, length: min(length, codeLength - offset)))
        view.code.scrollRangeToVisible(view.code.selectedRange())
    }

    /// Up from a block's closing fence, or down from its opening one, goes
    /// into the code; TextKit's own line moves would skip its one tall line.
    func enterCodeVertically(up: Bool) -> Bool {
        let caret = selectedRange()
        guard caret.length == 0, let storage = textStorage else { return false }
        let text = storage.string as NSString
        let line = text.lineRange(for: NSRange(location: min(caret.location, text.length), length: 0))
        if up {
            guard line.location > 0, let block = codeViewport(at: line.location - 1), NSMaxRange(block.range) == line.location else { return false }
            let lastLine = text.lineRange(for: NSRange(location: NSMaxRange(block.range) - 1, length: 0))
            focusCode(at: lastLine.location)
        } else {
            guard let block = codeViewport(at: NSMaxRange(line)), block.range.location == NSMaxRange(line) else { return false }
            focusCode(at: block.range.location)
        }
        return true
    }

    /// A find result or search match in a scrolling block shows in its view.
    func mirrorSelectionIntoCode(_ selection: NSRange) {
        guard selection.length > 0, let block = codeViewport(at: selection.location),
              NSMaxRange(selection) <= NSMaxRange(block.range) else { return }
        if codeViews[block.range.location] == nil { syncCodeViews() }
        guard let view = codeViews[block.range.location] else { return }
        let local = NSRange(location: selection.location - block.range.location, length: selection.length)
        guard NSMaxRange(local) <= (view.code.string as NSString).length else { return }
        view.code.setSelectedRange(local)
        view.code.scrollRangeToVisible(local)
    }
}
