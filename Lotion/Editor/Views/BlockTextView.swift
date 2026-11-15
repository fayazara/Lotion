//
//  BlockTextView.swift
//  Lotion
//
//  The text view inside every editable block and table cell. It edits only
//  its own text; anything that crosses blocks (Return, Delete at the start,
//  arrows at an edge, Tab) is handed to the editor through its delegate.
//

import AppKit

/// A table cell's place, for a text view that edits one.
struct CellPosition: Equatable {
    var row: Int
    var column: Int
}

final class BlockTextView: NSTextView {
    weak var editor: BlockEditorView?
    var blockID: UUID
    var cell: CellPosition?
    var placeholder: String?
    var placeholderOnlyWhenFocused = true
    var placeholderFont: NSFont?
    var placeholderColor: NSColor = .placeholderTextColor
    /// How far the line's text sits below its top, to line the placeholder up with it.
    var placeholderOffset: CGFloat = 0

    /// While the mouse is down in this view, between its mouseDown and mouseUp.
    private(set) var isTrackingMouse = false

    init(blockID: UUID, width: CGFloat) {
        self.blockID = blockID
        let storage = NSTextStorage()
        let layoutManager = BlockLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layoutManager.addTextContainer(container)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 20), textContainer: container)
        isRichText = true
        allowsUndo = false
        drawsBackground = false
        textContainerInset = .zero
        isVerticallyResizable = false
        isHorizontallyResizable = false
        autoresizingMask = []
        importsGraphics = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        smartInsertDeleteEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isGrammarCheckingEnabled = false
        displaysLinkToolTips = false
        linkTextAttributes = [:]
        focusRingType = .none
        layoutManager.allowsNonContiguousLayout = false
        setUpCaret()
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        blockID = UUID()
        super.init(frame: frameRect, textContainer: container)
    }

    override var acceptsFirstResponder: Bool { true }

    /// The editor keeps the note's history as whole-note steps; anything
    /// TextKit tries to record on its own is dropped here.
    private static let discardedUndo: UndoManager = {
        let manager = UndoManager()
        manager.disableUndoRegistration()
        return manager
    }()

    override var undoManager: UndoManager? { Self.discardedUndo }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { editor?.textViewDidFocus(self) }
        DispatchQueue.main.async { [weak self] in self?.updateCaret() }
        needsDisplay = true
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            // A table cell left behind (by Tab, say) would keep drawing its selection
            // as a gray inactive highlight, so drop it down to a caret.
            if cell != nil, selectedRange().length > 0 {
                setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            }
            editor?.textViewDidBlur(self)
        }
        needsDisplay = true
        return resigned
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if editor?.textViewMouseDown(self, event: event) == true { return }
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        editor?.textViewMouseUp(self)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        editor?.contextMenu(for: self, event: event) ?? super.menu(for: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        editor?.addCursorRects(for: self)
    }

    // MARK: Editing commands

    override func paste(_ sender: Any?) {
        if editor?.paste(into: self) != true { super.paste(sender) }
    }

    override func pasteAsPlainText(_ sender: Any?) {
        if editor?.paste(into: self, plain: true) != true { super.pasteAsPlainText(sender) }
    }

    override func copy(_ sender: Any?) {
        if editor?.copy(from: self) != true { super.copy(sender) }
    }

    override func cut(_ sender: Any?) {
        guard selectedRange().length > 0 else { return }
        copy(sender)
        insertText("", replacementRange: selectedRange())
    }

    override func selectAll(_ sender: Any?) {
        if editor?.selectAll(from: self) != true { super.selectAll(sender) }
    }

    @objc func undo(_ sender: Any?) { editor?.undo() }
    @objc func redo(_ sender: Any?) { editor?.redo() }

    @objc func toggleBold(_ sender: Any?) { editor?.toggleFormat(.lotionBold, in: self) }
    @objc func toggleItalic(_ sender: Any?) { editor?.toggleFormat(.lotionItalic, in: self) }
    @objc func toggleStrikethrough(_ sender: Any?) { editor?.toggleFormat(.lotionStrike, in: self) }
    @objc func toggleInlineCode(_ sender: Any?) { editor?.toggleFormat(.lotionCode, in: self) }
    @objc func insertLink(_ sender: Any?) { editor?.editLink(in: self) }
    @objc func makeHeading1(_ sender: Any?) { editor?.turnFocused(into: .heading(1)) }
    @objc func makeHeading2(_ sender: Any?) { editor?.turnFocused(into: .heading(2)) }
    @objc func makeHeading3(_ sender: Any?) { editor?.turnFocused(into: .heading(3)) }
    @objc func makeBodyText(_ sender: Any?) { editor?.turnFocused(into: .paragraph) }
    @objc func toggleBulletList(_ sender: Any?) { editor?.toggleFocused(.bullet) }
    @objc func toggleNumberedList(_ sender: Any?) { editor?.toggleFocused(.numbered) }
    @objc func toggleChecklist(_ sender: Any?) { editor?.toggleFocused(.todo) }
    @objc func toggleQuote(_ sender: Any?) { editor?.toggleFocused(.quote) }
    @objc func insertCodeBlock(_ sender: Any?) { editor?.turnFocused(into: .code) }
    @objc func insertTable(_ sender: Any?) { editor?.insertBlockAfterFocus(.table) }
    @objc func insertDivider(_ sender: Any?) { editor?.insertBlockAfterFocus(.divider) }
    @objc func moveBlockUp(_ sender: Any?) { editor?.moveFocusedBlocks(by: -1) }
    @objc func moveBlockDown(_ sender: Any?) { editor?.moveFocusedBlocks(by: 1) }
    @objc func duplicateBlock(_ sender: Any?) { editor?.duplicateFocusedBlocks() }
    @objc func insertMediaFromPanel(_ sender: Any?) { editor?.chooseMedia(video: false) }

    // MARK: Dropping images and videos

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if cell == nil, BlockEditorView.hasMedia(sender.draggingPasteboard), let editor { return editor.mediaDragUpdated(sender) }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if cell == nil, BlockEditorView.hasMedia(sender.draggingPasteboard), let editor { return editor.mediaDragUpdated(sender) }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        editor?.mediaDragEnded()
        super.draggingExited(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if cell == nil, BlockEditorView.hasMedia(sender.draggingPasteboard), let editor { return editor.performMediaDrop(sender) }
        return super.performDragOperation(sender)
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if let editor, let result = editor.validate(item, from: self) { return result }
        return super.validateUserInterfaceItem(item)
    }

    // MARK: Caret

    /// The caret is a layer of our own. AppKit's blinks by redrawing the
    /// text view, which shows as a stepped, low-frame-rate fade; a layer's
    /// opacity is animated by Core Animation at the display's full rate.
    private let caretLayer = CALayer()
    private var keyObservers: [NSObjectProtocol] = []

    var caretColor: NSColor = .textColor {
        didSet { caretLayer.backgroundColor = caretColor.cgColor }
    }

    private func setUpCaret() {
        // AppKit's own caret stays, invisible, so everything else about it works.
        super.insertionPointColor = .clear
        wantsLayer = true
        caretLayer.backgroundColor = caretColor.cgColor
        caretLayer.cornerRadius = 1
        caretLayer.isHidden = true
        caretLayer.zPosition = 10
        // Moves are instant; only the blink animates.
        caretLayer.actions = ["position": NSNull(), "bounds": NSNull(), "frame": NSNull(),
                              "hidden": NSNull(), "opacity": NSNull(), "backgroundColor": NSNull()]
        layer?.addSublayer(caretLayer)
    }

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        if caretLayer.superlayer == nil { layer.addSublayer(caretLayer) }
        return layer
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                keyObservers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.updateCaret() }
                })
            }
        }
        updateCaret()
    }

    /// Puts the caret where the selection is, solid, and starts it blinking
    /// after a moment, so it never blinks while you type or move it.
    func updateCaret() {
        guard window?.firstResponder === self, window?.isKeyWindow == true, selectedRange().length == 0,
              let layoutManager, let textContainer else {
            caretLayer.isHidden = true
            caretLayer.removeAllAnimations()
            return
        }
        layoutManager.ensureLayout(for: textContainer)
        var rect = caretRect
        guard rect.height > 0 else { caretLayer.isHidden = true; return }
        let scale = window?.backingScaleFactor ?? 2
        let width: CGFloat = scale >= 2 ? 2 : 1
        rect.origin.x = (round((rect.minX - width / 2) * scale) / scale)
        rect.size.width = width
        if let layer, caretLayer.superlayer !== layer { layer.addSublayer(caretLayer) }
        caretLayer.contentsScale = scale
        caretLayer.frame = rect
        caretLayer.isHidden = false
        caretLayer.opacity = 1
        caretLayer.removeAllAnimations()
        let blink = CAKeyframeAnimation(keyPath: "opacity")
        // Solid, an eased fade out, off, an eased fade back: about once a second, like macOS.
        blink.values = [1, 1, 0, 0, 1]
        blink.keyTimes = [0, 0.42, 0.58, 0.9, 1]
        blink.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut),
                                 CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .easeInEaseOut)]
        blink.duration = 1.1
        blink.repeatCount = .infinity
        blink.beginTime = CACurrentMediaTime() + 0.5
        blink.fillMode = .backwards
        caretLayer.add(blink, forKey: "blink")
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if stillSelecting && isTrackingMouse { editor?.textViewDragged(self) }
        updateCaret()
    }

    override func didChangeText() {
        super.didChangeText()
        updateCaret()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateCaret()
    }

    /// AppKit's caret is clear; keep it that way whatever asks to draw it.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {}

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholder()
    }

    private func drawPlaceholder() {
        guard let placeholder, textStorage?.length == 0 else { return }
        if placeholderOnlyWhenFocused && window?.firstResponder !== self { return }
        let font = placeholderFont ?? (typingAttributes[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 15)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: placeholderColor]
        let origin = NSPoint(x: textContainerOrigin.x, y: textContainerOrigin.y + placeholderOffset)
        (placeholder as NSString).draw(at: origin, withAttributes: attributes)
    }

    // MARK: Geometry

    /// The caret's rect in this view, or the selection's first line.
    var caretRect: NSRect {
        guard let layoutManager, let textContainer else { return .zero }
        let location = selectedRange().location
        let length = textStorage?.length ?? 0
        if length == 0 || (location == length && (string as NSString).character(at: length - 1) == 10) {
            let extra = layoutManager.extraLineFragmentRect
            if !extra.isEmpty { return extra.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y) }
            let height = (typingAttributes[.font] as? NSFont).map { BlockTheme.lineHeight($0) } ?? 18
            let y = length == 0 ? 0 : layoutManager.usedRect(for: textContainer).maxY
            return NSRect(x: textContainerOrigin.x, y: textContainerOrigin.y + y, width: 1, height: height)
        }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: min(location, length), length: 0), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyphRange.location, length: 0), in: textContainer)
        if location >= length {
            let last = layoutManager.lineFragmentUsedRect(forGlyphAt: max(0, layoutManager.numberOfGlyphs - 1), effectiveRange: nil)
            rect = NSRect(x: last.maxX, y: last.minY, width: 1, height: last.height)
        } else {
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
            rect.origin.y = fragment.minY
            rect.size.height = fragment.height
        }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// Whether the caret sits on the first or last visual line.
    func caretIsOnFirstLine() -> Bool {
        lineIndex(of: selectedRange().location) == 0
    }

    func caretIsOnLastLine() -> Bool {
        let location = NSMaxRange(selectedRange())
        return lineIndex(of: location) == lineCount() - 1
    }

    private func lineCount() -> Int {
        guard let layoutManager else { return 1 }
        var count = 0
        var index = 0
        let glyphs = layoutManager.numberOfGlyphs
        while index < glyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            count += 1
            index = NSMaxRange(range)
        }
        if !layoutManager.extraLineFragmentRect.isEmpty || count == 0 { count += 1 }
        return count
    }

    private func lineIndex(of location: Int) -> Int {
        guard let layoutManager else { return 0 }
        let length = textStorage?.length ?? 0
        if length == 0 { return 0 }
        if location >= length, (string as NSString).character(at: length - 1) == 10 { return lineCount() - 1 }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, length - 1))
        var count = 0
        var index = 0
        while index < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: index, effectiveRange: &range)
            if NSLocationInRange(glyph, range) { return count }
            count += 1
            index = NSMaxRange(range)
        }
        return max(0, count - 1)
    }

    /// The character nearest a point in this view's coordinates.
    func characterIndex(near point: NSPoint) -> Int {
        guard let layoutManager, let textContainer else { return 0 }
        let length = textStorage?.length ?? 0
        guard length > 0 else { return 0 }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let used = layoutManager.usedRect(for: textContainer)
        if local.y >= used.maxY, (string as NSString).character(at: length - 1) == 10 { return length }
        var fraction: CGFloat = 0
        let index = layoutManager.characterIndex(for: local, in: textContainer, fractionOfDistanceBetweenInsertionPoints: &fraction)
        if index >= length { return length }
        // Past the middle of a character puts the caret after it, except before a line's newline.
        if fraction > 0.5, (string as NSString).character(at: index) != 10 { return index + 1 }
        return index
    }

    /// Places the caret on the first or last line, nearest `x` (in this view).
    func placeCaret(onFirstLine first: Bool, x: CGFloat) {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let y = first ? 1 : max(1, used.maxY - 2)
        let index = caretIndex(onLineAt: y + textContainerOrigin.y, x: x)
        setSelectedRange(NSRange(location: index, length: 0))
    }

    /// The caret position nearest `x` on the visual line at `y` (both in this
    /// view). Past the end of a line that wraps, the caret stays on that line
    /// instead of slipping to the start of the next one.
    func caretIndex(onLineAt y: CGFloat, x: CGFloat) -> Int {
        var index = characterIndex(near: NSPoint(x: x, y: y))
        guard let layoutManager, let textContainer, layoutManager.numberOfGlyphs > 0 else { return index }
        let length = textStorage?.length ?? 0
        let local = NSPoint(x: 0, y: y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: local, in: textContainer)
        var lineGlyphs = NSRange()
        layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        let line = layoutManager.characterRange(forGlyphRange: lineGlyphs, actualGlyphRange: nil)
        if index == NSMaxRange(line), NSMaxRange(line) < length, line.length > 0 { index -= 1 }
        return index
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        // ⌘↩ checks off a to-do, or opens the link under the caret. (In the
        // scratchpad the menu takes it first, for a new entry.)
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, editor?.commandReturn(in: self) == true { return }
        super.keyDown(with: event)
    }

    @objc func showBlockActions(_ sender: Any?) { editor?.showBlockActions() }

    // MARK: Accessibility

    override func accessibilityRoleDescription() -> String? {
        editor?.accessibilityDescription(for: self) ?? super.accessibilityRoleDescription()
    }

    override func accessibilityPlaceholderValue() -> String? {
        textStorage?.length == 0 ? placeholder : nil
    }
}

/// Draws inline code with rounded grounds instead of TextKit's square ones,
/// and favicons in the space left before external links.
final class BlockLayoutManager: NSLayoutManager {
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        let string = storage.string as NSString
        storage.enumerateAttribute(.lotionLink, in: characters) { value, range, _ in
            guard let link = value as? String, Favicons.host(of: link) != nil else { return }
            let start = range.location
            if start > 0 {
                if storage.attribute(.lotionLink, at: start - 1, effectiveRange: nil) as? String == link { return }
                if string.character(at: start - 1) == 10 { return }
            }
            guard let font = storage.attribute(.font, at: start, effectiveRange: nil) as? NSFont else { return }
            let glyph = glyphIndexForCharacter(at: start)
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let location = location(forGlyphAt: glyph)
            let side = BlockTheme.linkIconSize(font)
            let baseline = origin.y + fragment.minY + location.y
            let rect = NSRect(x: origin.x + fragment.minX + location.x - side - 3,
                              y: round(baseline - font.xHeight / 2 - side / 2), width: side, height: side)
            if let icon = Favicons.icon(for: link) {
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).addClip()
                icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high])
                NSGraphicsContext.restoreGraphicsState()
            } else if let globe = NSImage(icon: "globe", accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: side * 0.8, weight: .regular)) {
                let color = (storage.attribute(.foregroundColor, at: start, effectiveRange: nil) as? NSColor ?? .secondaryLabelColor)
                    .withAlphaComponent(0.6)
                let icon = globe.tinted(color)
                icon.draw(in: NSRect(x: rect.midX - icon.size.width / 2, y: rect.midY - icon.size.height / 2,
                                     width: icon.size.width, height: icon.size.height),
                          from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }

    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, charRange.location < storage.length,
              storage.attribute(.lotionCode, at: charRange.location, effectiveRange: nil) != nil,
              let font = storage.attribute(.font, at: charRange.location, effectiveRange: nil) as? NSFont else {
            super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
            return
        }
        color.setFill()
        let height = ceil(font.ascender - font.descender) + 3
        for index in 0..<rectCount {
            var rect = rectArray[index]
            // The fragment's top holds the text; line spacing sits below it.
            let glyph = glyphIndexForCharacter(at: charRange.location)
            let baseline = location(forGlyphAt: glyph).y
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let top = fragment.minY + baseline - ceil(font.ascender) - 1.5
            rect.origin.y = max(rect.minY, top)
            rect.size.height = height
            rect = rect.insetBy(dx: -2, dy: 0)
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        }
    }
}
