//
//  EditorTextView.swift
//  Lotion
//
//  The note canvas: a TextKit 1 NSTextView that keeps its text in a centered,
//  readable column, draws Markdown decorations through EditorLayoutManager,
//  and knows a few Markdown habits (continuing lists, closing fences,
//  toggling tasks, wrapping a selection in marks). Block marks are hidden, so
//  the caret skips over them and Delete at a line's start removes them whole.
//

import AppKit

final class EditorTextView: NSTextView {
    /// Matches the styler's gutter; heading marks hang into it.
    var gutter: CGFloat = 52 { didSet { updateInsets() } }
    var readableWidth: CGFloat = 700 { didSet { updateInsets() } }
    var palette: ThemePalette?
    var bottomInset: CGFloat = 160
    /// Room above the title: the cover, or space for the Add Cover button.
    var topInset: CGFloat { hasCover ? coverHeight + 44 : 64 }
    /// For the placeholders shown in an empty note and empty headings.
    var headingFonts: [NSFont] = []
    var bodyFont: NSFont?
    /// Called when the editor gains or loses focus; marks show only while it has it.
    var onFocusChange: (() -> Void)?
    /// Where placeholders were last drawn (for redrawing them, and the self-test).
    private(set) var placeholderRects: [NSRect] = []

    // Tables: the behavior is in TableCellEditing.swift.
    /// Builds cell text for the cell editor; set by the note's coordinator.
    weak var styler: MarkdownStyler?
    /// The cell being edited, while the cell editor has focus.
    var activeCell: ActiveCell?
    lazy var cellEditor: TableCellEditor = TableCellEditor.make(host: self)
    /// Clips the cell editor to the table's visible part.
    lazy var cellEditorClip: TableEditorClip = TableEditorClip()
    /// Sideways scroll of tables wider than the page, by where each starts.
    var tableScrollOffsets: [Int: CGFloat] = [:]
    /// Set while the cell editor writes into the note, so the write isn't
    /// mistaken for an outside change (an undo, say).
    var isWritingCell = false
    var scrollGesture: TableScrollGesture = .idle
    var needsCellEditorPosition = false
    var cellClickMonitor: Any?
    /// Scroll views over long code blocks, by where each block's code starts.
    var codeViews: [Int: CodeBlockView] = [:]
    var isWritingCode = false
    var needsCodeViewSync = false

    static func make() -> EditorTextView {
        let storage = NSTextStorage()
        let layoutManager = EditorLayoutManager()
        layoutManager.delegate = layoutManager
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        let view = EditorTextView(frame: .zero, textContainer: container)
        view.configure()
        return view
    }

    private func configure() {
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        usesFontPanel = false
        usesRuler = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        smartInsertDeleteEnabled = false
        isGrammarCheckingEnabled = false
        allowsCharacterPickerTouchBarItem = false
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        layoutManager?.allowsNonContiguousLayout = true
        drawsBackground = true
    }

    // MARK: Column

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        updateInsets()
        layoutCover()
        if widthChanged {
            setNeedsCellEditorPosition()
            setNeedsCodeViewSync()
        }
    }

    private func updateInsets() {
        let width = bounds.width
        guard width > 0 else { return }
        let margin: CGFloat = 28
        let column = max(160, min(readableWidth, width - 2 * (gutter + margin)))
        let inset = max(0, floor((width - column) / 2 - gutter))
        let target = NSSize(width: inset, height: (topInset + bottomInset) / 2)
        if textContainerInset != target {
            textContainerInset = target
        }
    }

    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: topInset)
    }

    // MARK: Cover

    var onAddCover: (() -> Void)?
    var onChangeCover: ((NSRect) -> Void)?
    var onRemoveCover: (() -> Void)?
    var onMoveCover: ((Double) -> Void)?

    private(set) var hasCover = false
    private let coverView = CoverImageView()
    private lazy var coverControls: NSStackView = {
        let stack = NSStackView(views: [
            coverButton("Change Cover", #selector(changeCover)),
            repositionButton,
            coverButton("Remove", #selector(removeCover)),
        ])
        stack.spacing = 6
        return stack
    }()
    private lazy var repositionButton = coverButton("Reposition", #selector(toggleReposition))
    private lazy var creditButton = coverButton("", #selector(openCredit))
    private lazy var addCoverButton: NSButton = {
        let button = NSButton(title: "Add Cover", image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!,
                              target: self, action: #selector(addCover))
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        return button
    }()
    private var creditURL: URL?
    private var isRepositioning = false
    private var coverTracking: NSTrackingArea?

    /// Covers are a 4:1 band across the editor's width, capped for wide windows.
    private var coverHeight: CGFloat { round(min(300, bounds.width / 4)) }

    private func coverButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .glass
        button.controlSize = .small
        return button
    }

    func setCover(_ present: Bool, image: NSImage?, position: Double, credit: String?, creditURL: URL?) {
        if coverView.superview == nil {
            for view in [coverView, coverControls, creditButton, addCoverButton] as [NSView] {
                view.isHidden = true
                addSubview(view)
            }
        }
        let changed = present != hasCover
        hasCover = present
        coverView.image = image
        if !isRepositioning { coverView.position = position }
        creditButton.title = credit.map { "Photo by \($0) on Unsplash" } ?? ""
        self.creditURL = creditURL
        if changed {
            isRepositioning = false
            repositionButton.title = "Reposition"
            updateInsets()
            needsDisplay = true
        }
        layoutCover()
        updateCoverHover(at: window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) })
    }

    private func layoutCover() {
        guard coverView.superview != nil else { return }
        let height = coverHeight
        coverView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        coverView.isHidden = !hasCover
        let controls = coverControls.fittingSize
        let right = textContainerOrigin.x + (textContainer?.size.width ?? bounds.width) - gutter
        coverControls.frame = NSRect(x: right - controls.width, y: height - controls.height - 12,
                                     width: controls.width, height: controls.height)
        let left = textContainerOrigin.x + gutter
        let credit = creditButton.fittingSize
        creditButton.frame = NSRect(x: left, y: height - credit.height - 12, width: credit.width, height: credit.height)
        let add = addCoverButton.fittingSize
        addCoverButton.frame = NSRect(x: left - 4, y: 22, width: add.width, height: add.height)
        addCoverButton.contentTintColor = palette?.secondary
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let coverTracking { removeTrackingArea(coverTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        coverTracking = area
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        updateCoverHover(at: nil)
    }

    /// Cover buttons show while the pointer is over the cover, or for a note
    /// without one, over the space above its title.
    private func updateCoverHover(at point: NSPoint?) {
        guard coverView.superview != nil else { return }
        let inTop = point.map { bounds.contains($0) && $0.y < (hasCover ? coverHeight : topInset) } ?? false
        coverControls.isHidden = !(hasCover && (inTop || isRepositioning))
        creditButton.isHidden = coverControls.isHidden || creditButton.title.isEmpty
        addCoverButton.isHidden = hasCover || !inTop
    }

    @objc private func addCover() { onAddCover?() }
    @objc private func changeCover() { onChangeCover?(coverControls.frame) }
    @objc private func removeCover() { onRemoveCover?() }
    @objc private func openCredit() { if let creditURL { NSWorkspace.shared.open(creditURL) } }

    @objc private func toggleReposition() {
        if isRepositioning { onMoveCover?(coverView.position) }
        isRepositioning.toggle()
        repositionButton.title = isRepositioning ? "Save Position" : "Reposition"
        layoutCover()
    }

    /// Dragging a cover while repositioning slides the image under it.
    private func dragCover(from start: NSPoint) {
        var last = start
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(event.locationInWindow, from: nil)
            let overflow = coverView.overflow
            if overflow > 0 {
                coverView.position = min(1, max(0, coverView.position - (point.y - last.y) / overflow))
            }
            last = point
            if event.type == .leftMouseUp { break }
        }
    }

    // MARK: Code block height

    /// A code block's height while dragging (`done` false), then once more when it is let go.
    var onResizeCode: ((_ fenceLocation: Int, _ lines: Int, _ done: Bool) -> Void)?

    /// The code block whose bottom row, its resize handle, is under the point.
    private func codeHandle(at point: NSPoint) -> CodeHandle? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer)
        let row = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        guard row.minY <= containerPoint.y, containerPoint.y <= row.maxY else { return nil }
        let character = layoutManager.characterIndexForGlyph(at: glyph)
        guard character < storage.length else { return nil }
        return storage.attribute(.lotionCodeHandle, at: character, effectiveRange: nil) as? CodeHandle
    }

    private func dragCodeHandle(_ handle: CodeHandle, from start: NSPoint) {
        var lines = handle.visibleLines
        NSCursor.resizeUpDown.push()
        defer { NSCursor.pop() }
        while let event = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let point = convert(event.locationInWindow, from: nil)
            let steps = Int(((point.y - start.y) / max(1, handle.lineHeight)).rounded())
            let next = min(handle.lineCount, max(MarkdownStyler.minimumCodeLines, handle.visibleLines + steps))
            if event.type == .leftMouseUp {
                // Zero: nothing changed, just drop the preview.
                onResizeCode?(handle.fenceLocation, next != handle.visibleLines ? next : 0, true)
                break
            }
            if next != lines {
                lines = next
                onResizeCode?(handle.fenceLocation, next, false)
            }
        }
    }

    /// Saves a code block's height as `lines=N` on its opening fence, as one undoable edit.
    func setCodeLines(_ lines: Int, fenceAt location: Int) {
        let text = string as NSString
        guard location < text.length else { return }
        var line = text.lineRange(for: NSRange(location: location, length: 0))
        if line.length > 0, text.character(at: NSMaxRange(line) - 1) == 10 { line.length -= 1 }
        let fence = text.substring(with: line)
        let bare = MarkdownStyler.linesPattern.stringByReplacingMatches(
            in: fence, range: NSRange(location: 0, length: (fence as NSString).length), withTemplate: "")
        let replacement = bare + " lines=\(lines)"
        guard replacement != fence else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: line, replacementString: replacement) else { return }
        let selection = selectedRange()
        let delta = (replacement as NSString).length - line.length
        textStorage?.replaceCharacters(in: line, with: replacement)
        didChangeText()
        breakUndoCoalescing()
        undoManager?.setActionName("Resize Code Block")
        setSelectedRange(selection.location > location ? NSRange(location: selection.location + delta, length: selection.length) : selection)
    }

    // MARK: Placeholder

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawPlaceholder()
    }

    /// "Start writing" in an empty note; "Title" on an empty first heading,
    /// and "Heading N" on the empty heading the caret is in.
    private func drawPlaceholder() {
        placeholderRects = []
        guard let palette, let layoutManager else { return }
        let text = string as NSString
        let origin = textContainerOrigin
        if text.length == 0 {
            guard let font = bodyFont else { return }
            let fragment = layoutManager.extraLineFragmentRect
            let point = NSPoint(x: origin.x + gutter, y: origin.y + fragment.minY)
            draw("Start writing", at: point, font: font, color: palette.marker)
            return
        }
        var lines = [0]
        let caretLine = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0)).location
        if caretLine != 0 { lines.append(caretLine) }
        for start in lines {
            guard let level = emptyHeadingLevel(at: start, in: text), level <= headingFonts.count else { continue }
            let font = headingFonts[level - 1]
            guard let baseline = baseline(ofLineAt: start, font: font) else { continue }
            let point = NSPoint(x: origin.x + gutter, y: origin.y + baseline - font.ascender)
            draw(start == 0 ? "Title" : "Heading \(level)", at: point, font: font, color: palette.marker)
        }
    }

    /// The baseline of the line holding `character`, in container coordinates.
    /// Hidden marks are null glyphs with no real position, so it's read from
    /// a glyph that is laid out (the line's break, if nothing else), or, on a
    /// line of nothing but hidden marks, from the font and paragraph spacing.
    func baseline(ofLineAt character: Int, font: NSFont) -> CGFloat? {
        guard let layoutManager, let storage = textStorage, character < storage.length else { return nil }
        let glyph = layoutManager.glyphIndexForCharacter(at: character)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        var lineGlyphs = NSRange()
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &lineGlyphs)
        if layoutManager.propertyForGlyph(at: glyph) != .null {
            return fragment.minY + layoutManager.location(forGlyphAt: glyph).y
        }
        for candidate in lineGlyphs.location..<NSMaxRange(lineGlyphs) where layoutManager.propertyForGlyph(at: candidate) != .null {
            return fragment.minY + layoutManager.location(forGlyphAt: candidate).y
        }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: character, length: 0))
        let style = storage.attribute(.paragraphStyle, at: character, effectiveRange: nil) as? NSParagraphStyle
        let before = layoutManager.characterIndexForGlyph(at: lineGlyphs.location) == line.location ? style?.paragraphSpacingBefore ?? 0 : 0
        return fragment.minY + before + layoutManager.defaultBaselineOffset(for: font)
    }

    private func draw(_ placeholder: String, at point: NSPoint, font: NSFont, color: NSColor) {
        let string = placeholder as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        string.draw(at: point, withAttributes: attributes)
        placeholderRects.append(NSRect(origin: point, size: string.size(withAttributes: attributes)).insetBy(dx: -2, dy: -2))
    }

    /// The level of the heading on the line starting at `start`, when it has marks and nothing else.
    private func emptyHeadingLevel(at start: Int, in text: NSString) -> Int? {
        var index = start, hashes = 0
        while index < text.length, text.character(at: index) == 32, index - start < 3 { index += 1 }
        while index < text.length, text.character(at: index) == 35 { hashes += 1; index += 1 }
        guard (1...6).contains(hashes), index < text.length, text.character(at: index) == 32 || text.character(at: index) == 9 else { return nil }
        while index < text.length, text.character(at: index) == 32 || text.character(at: index) == 9 { index += 1 }
        guard index == text.length || text.character(at: index) == 10 else { return nil }
        return hashes
    }

    /// Redraws where a placeholder was, or may now be.
    func invalidatePlaceholders() {
        for rect in placeholderRects { setNeedsDisplay(rect) }
        let text = string as NSString
        let line = text.lineRange(for: NSRange(location: min(selectedRange().location, text.length), length: 0))
        if line.length <= 9, let layoutManager, let textContainer {
            let glyphs = layoutManager.glyphRange(forCharacterRange: line, actualCharacterRange: nil)
            var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
            rect.origin.x = textContainerOrigin.x
            rect.origin.y += textContainerOrigin.y
            rect.size.width = textContainer.size.width
            setNeedsDisplay(rect)
        }
    }

    // MARK: Caret

    /// The caret sized to the text it sits in: the font's ascender to
    /// descender on the baseline, not the whole line box with its spacing.
    func caretRect() -> NSRect? {
        guard let storage = textStorage, let layoutManager, selectedRange().length == 0 else { return nil }
        let text = storage.string as NSString
        let length = text.length
        let index = selectedRange().location
        let endsLine = length == 0 || (index == length && text.character(at: length - 1) == 10)
        let baseline: CGFloat
        let font: NSFont
        if endsLine {
            font = typingAttributes[.font] as? NSFont ?? bodyFont ?? .systemFont(ofSize: 15)
            let extra = layoutManager.extraLineFragmentRect
            guard extra.height > 0 else { return nil }
            baseline = extra.minY + layoutManager.defaultBaselineOffset(for: font)
        } else {
            let character = min(index, length - 1)
            font = storage.attribute(.font, at: character, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 15)
            guard let found = self.baseline(ofLineAt: character, font: font) else { return nil }
            baseline = found
        }
        let origin = textContainerOrigin
        let top = (origin.y + baseline - font.ascender - 1).rounded()
        let bottom = (origin.y + baseline - font.descender + 1).rounded()
        return NSRect(x: 0, y: top, width: 0, height: bottom - top)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        guard let rect = caretRect() else { return }
        for case let indicator as NSTextInsertionIndicator in subviews {
            var frame = indicator.frame
            frame.origin.y = rect.minY
            frame.size.height = rect.height
            if indicator.frame != frame { indicator.frame = frame }
        }
    }

    /// A caret taller than its line (a short blank line) must also be erased
    /// where it reaches past the line, so thin caret-sized redraws grow.
    override func setNeedsDisplay(_ invalidRect: NSRect, avoidAdditionalLayout flag: Bool) {
        var rect = invalidRect
        if rect.width <= 4 {
            if let caret = caretRect() { rect = rect.union(NSRect(x: rect.minX, y: caret.minY, width: rect.width, height: caret.height)) }
            if let drawnCaret, abs(drawnCaret.minX - rect.minX) < 3 { rect = rect.union(drawnCaret) }
        }
        super.setNeedsDisplay(rect, avoidAdditionalLayout: flag)
    }

    /// The last caret drawn, for the self-test.
    private(set) var drawnCaret: NSRect?

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var flag = flag
        // A table's Markdown is hidden; a caret there is on its way into a cell.
        if flag, selectedRange().length == 0,
           tableContaining(caret: selectedRange().location) != nil || codeViewport(at: selectedRange().location) != nil { flag = false }
        var adjusted = rect
        defer { drawnCaret = adjusted }
        if let caret = caretRect() {
            adjusted.origin.y = caret.minY
            adjusted.size.height = caret.height
        }
        // Moving the caret erases where the system thinks it was; ours may
        // have reached further, so wipe the last one we drew as well.
        if let old = drawnCaret, old != adjusted {
            super.setNeedsDisplay(old.insetBy(dx: -1, dy: -1), avoidAdditionalLayout: true)
        }
        super.drawInsertionPoint(in: adjusted, color: color, turnedOn: flag)
    }

    // MARK: Focus

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        onFocusChange?()
        // Focus coming back to a caret inside a table goes on into its cell.
        DispatchQueue.main.async { [weak self] in self?.activateCellIfCaretInTable() }
        return true
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        let old = selectedRanges
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // Tables draw their own selection; their hidden rows have no height to redraw.
        invalidateTables(touching: (old + ranges).map(\.rangeValue))
        if !stillSelecting, ranges.count == 1 { mirrorSelectionIntoCode(ranges[0].rangeValue) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Code views come and go as the page scrolls.
        guard let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageDidScroll), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func pageDidScroll() { setNeedsCodeViewSync() }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        onFocusChange?()
        return true
    }

    // MARK: Hidden marks

    /// Keeps a caret out of a line's hidden marks: it lands where the text
    /// starts, or, moving left from there, at the end of the line above.
    func snappedSelection(from old: NSRange, to new: NSRange) -> NSRange {
        scheduleCellActivation(from: old, to: new)
        guard new.length == 0, let storage = textStorage, new.location < storage.length else { return new }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: new.location, length: 0))
        var prefix = NSRange()
        guard storage.attribute(.lotionPrefix, at: new.location, longestEffectiveRange: &prefix, in: line) != nil,
              prefix.location == line.location else { return new }
        let contentStart = NSMaxRange(prefix)
        if old.length == 0, old.location == contentStart, new.location < contentStart, line.location > 0 {
            return NSRange(location: line.location - 1, length: 0)
        }
        return NSRange(location: contentStart, length: 0)
    }

    /// The hidden marks that end at `caret`, when the caret is where a line's text starts.
    private func prefix(endingAt caret: Int) -> NSRange? {
        guard let storage = textStorage, caret > 0, caret <= storage.length else { return nil }
        let line = (storage.string as NSString).lineRange(for: NSRange(location: caret - 1, length: 0))
        var prefix = NSRange()
        guard storage.attribute(.lotionPrefix, at: caret - 1, longestEffectiveRange: &prefix, in: line) != nil,
              NSMaxRange(prefix) == caret, prefix.location == line.location else { return nil }
        return prefix
    }

    /// Delete at the start of a heading, quote or list item removes its marks
    /// (a nested item steps out a level first) instead of one hidden character.
    override func deleteForward(_ sender: Any?) {
        if deleteForwardIntoTable() { return }
        super.deleteForward(sender)
    }

    override func deleteBackward(_ sender: Any?) {
        if deleteBackwardIntoTable() { return }
        let caret = selectedRange()
        guard caret.length == 0, let prefix = prefix(endingAt: caret.location) else { return super.deleteBackward(sender) }
        let text = string as NSString
        let lineStart = prefix.location
        let isNested = text.character(at: lineStart) == 32 || text.character(at: lineStart) == 9
        let line = text.substring(with: text.lineRange(for: NSRange(location: lineStart, length: 0)))
        if isNested, Self.listContinuation(for: line) != nil, adjustListIndent(outdent: true) { return }
        replace(prefix, with: "", select: NSRange(location: lineStart, length: 0))
        undoManager?.setActionName("Delete")
    }

    /// `[] ` or `[ ] ` at the start of a line becomes a checklist item.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        let caret = selectedRange()
        // A pipe typed in a table stays in its cell.
        if string as? String == "|", tableContaining(caret: caret.location) != nil {
            return super.insertText("\\|", replacementRange: replacementRange)
        }
        if string as? String == " ", caret.length == 0, replacementRange.location == NSNotFound || replacementRange == caret {
            let text = self.string as NSString
            let lineStart = text.lineRange(for: NSRange(location: caret.location, length: 0)).location
            let typed = text.substring(with: NSRange(location: lineStart, length: caret.location - lineStart))
            let indent = (typed.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
            let box = typed.dropFirst(indent)
            if box == "[]" || box == "[ ]" {
                let range = NSRange(location: lineStart + indent, length: (box as Substring).utf16.count)
                replace(range, with: "- [ ] ", select: NSRange(location: range.location + 6, length: 0))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hasCover, point.y < coverHeight {
            if isRepositioning { dragCover(from: point) }
            return
        }
        endCellEditing()
        if handleTableClick(event, at: point) { return }
        if let handle = codeHandle(at: point) {
            dragCodeHandle(handle, from: point)
            return
        }
        if let task = taskRange(at: point) {
            toggleTask(at: task)
            return
        }
        if event.modifierFlags.contains(.command), let url = link(at: point) {
            NSWorkspace.shared.open(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        updateCoverHover(at: point)
        if hasCover, point.y < coverHeight {
            (isRepositioning ? NSCursor.openHand : NSCursor.arrow).set()
            return
        }
        if codeHandle(at: point) != nil {
            NSCursor.resizeUpDown.set()
            return
        }
        if taskRange(at: point) != nil || (event.modifierFlags.contains(.command) && link(at: point) != nil) {
            NSCursor.pointingHand.set()
        }
    }

    private func characterIndex(at point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: &fraction)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -2, dy: -2).contains(containerPoint) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func taskRange(at point: NSPoint) -> NSRange? {
        guard let index = characterIndex(at: point), let storage = textStorage else { return nil }
        var range = NSRange()
        guard storage.attribute(.lotionTask, at: index, longestEffectiveRange: &range, in: NSRange(location: 0, length: storage.length)) != nil else { return nil }
        return range
    }

    private func link(at point: NSPoint) -> URL? {
        let target: String
        if let tableTarget = tableLink(at: point) {
            target = tableTarget
        } else {
            guard let index = characterIndex(at: point), let storage = textStorage,
                  let found = storage.attribute(.lotionURL, at: index, effectiveRange: nil) as? String else { return nil }
            target = found
        }
        if let url = URL(string: target), url.scheme != nil { return url }
        return URL(string: "https://" + target)
    }

    /// Flips `- [ ]` and `- [x]`, as one undoable edit.
    private func toggleTask(at range: NSRange) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let open = text.range(of: "[", options: [], range: range)
        guard open.location != NSNotFound, open.location + 1 < NSMaxRange(range) else { return }
        let box = NSRange(location: open.location + 1, length: 1)
        let replacement = text.substring(with: box) == " " ? "x" : " "
        let selection = selectedRanges
        if shouldChangeText(in: box, replacementString: replacement) {
            storage.replaceCharacters(in: box, with: replacement)
            didChangeText()
            undoManager?.setActionName("Toggle Task")
        }
        selectedRanges = selection
    }

    // MARK: Tables

    override func scrollWheel(with event: NSEvent) {
        if handleTableScroll(event) { return }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        if case .cell(let start, let row, let column)? = tableHit(at: point) {
            if let active = activeCell, active.tableStart == start, active.row == row, active.column == column {
                return tableMenu()
            }
            beginCellEditing(tableAt: start, row: row, column: column, caret: .end)
            return tableMenu()
        }
        return super.menu(for: event)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        validateTableItem(menuItem.action) ?? super.validateMenuItem(menuItem)
    }

    /// Line-level formatting doesn't apply while a cell or code view is being edited.
    private var isEditingCell: Bool { activeCell != nil || isEditingCode }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, performTableShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Markdown habits

    override func moveUp(_ sender: Any?) {
        if enterTableVertically(up: true) || enterCodeVertically(up: true) { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        if enterTableVertically(up: false) || enterCodeVertically(up: false) { return }
        super.moveDown(sender)
    }

    /// Return continues a list (or ends it on an empty item) and closes a
    /// freshly opened fence.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage, selectedRange().length == 0 else { return super.insertNewline(sender) }
        let text = storage.string as NSString
        let caret = selectedRange().location
        let lineRange = text.lineRange(for: NSRange(location: caret, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, lineEnd <= text.length, text.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let line = text.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        let beforeCaret = String(line.prefix(caret - lineRange.location))

        // Return before a heading's text opens a line above it, rather than
        // leaving the marks behind on an empty heading.
        if let prefix = prefix(endingAt: caret), caret < lineEnd, Self.listContinuation(for: line) == nil {
            insertText("\n", replacementRange: NSRange(location: prefix.location, length: 0))
            setSelectedRange(NSRange(location: caret + 1, length: 0))
            return
        }

        if let continuation = Self.listContinuation(for: line) {
            if continuation.isEmptyItem {
                // Return on an empty item ends the list.
                let range = NSRange(location: lineRange.location, length: lineEnd - lineRange.location)
                insertText("", replacementRange: range)
                return
            }
            if beforeCaret.count >= continuation.prefixLength {
                insertText("\n" + continuation.next, replacementRange: selectedRange())
                return
            }
        }

        if caret == lineEnd, Self.opensFence(line), !hasFence(after: lineEnd, in: text, matching: line) {
            let indent = String(line.prefix { $0 == " " })
            let fence = String(line.drop { $0 == " " }.prefix { $0 == "`" || $0 == "~" })
            insertText("\n" + indent + "\n" + indent + fence, replacementRange: selectedRange())
            setSelectedRange(NSRange(location: caret + 1 + (indent as NSString).length, length: 0))
            return
        }
        super.insertNewline(sender)
    }

    private struct ListContinuation {
        let next: String
        let prefixLength: Int
        let isEmptyItem: Bool
    }

    private static let listPattern = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|(\d{1,9})([.)]))(\s+)(\[[ xX]\]\s+)?"#)

    private static func listContinuation(for line: String) -> ListContinuation? {
        let ns = line as NSString
        guard let match = listPattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: match.range(at: 1))
        let spacing = ns.substring(with: match.range(at: 5))
        var marker = ns.substring(with: match.range(at: 2))
        if match.range(at: 3).location != NSNotFound, let number = Int(ns.substring(with: match.range(at: 3))) {
            marker = "\(number + 1)" + ns.substring(with: match.range(at: 4))
        }
        let task = match.range(at: 6).location != NSNotFound ? "[ ] " : ""
        let rest = ns.substring(from: NSMaxRange(match.range)).trimmingCharacters(in: .whitespaces)
        return ListContinuation(
            next: indent + marker + spacing + task,
            prefixLength: match.range.length,
            isEmptyItem: rest.isEmpty
        )
    }

    private static func opensFence(_ line: String) -> Bool {
        let trimmed = line.drop { $0 == " " }
        guard line.count - trimmed.count <= 3 else { return false }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// Whether the fence on this line is already closed further down, by
    /// counting the fences before it: an even count means this one opens.
    private func hasFence(after location: Int, in text: NSString, matching line: String) -> Bool {
        let before = text.substring(to: location)
        var fencesBefore = 0
        before.enumerateLines { line, _ in if Self.opensFence(line) { fencesBefore += 1 } }
        // This line is itself counted in `fencesBefore`.
        if fencesBefore % 2 == 0 { return true }
        var fencesAfter = 0
        text.substring(from: location).enumerateLines { line, _ in if Self.opensFence(line) { fencesAfter += 1 } }
        return fencesAfter > 0
    }

    /// Tab indents a list item; in code it inserts spaces.
    override func insertTab(_ sender: Any?) {
        if adjustListIndent(outdent: false) { return }
        if isInCode { insertText("    ", replacementRange: selectedRange()); return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if adjustListIndent(outdent: true) { return }
        super.insertBacktab(sender)
    }

    private var isInCode: Bool {
        guard let storage = textStorage, storage.length > 0 else { return false }
        let index = min(selectedRange().location, storage.length - 1)
        return (storage.attribute(.lotionBlock, at: index, effectiveRange: nil) as? BlockDecoration)?.kind == .code
    }

    private func adjustListIndent(outdent: Bool) -> Bool {
        guard let storage = textStorage else { return false }
        let text = storage.string as NSString
        let lines = text.lineRange(for: selectedRange())
        var edits: [(NSRange, String)] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, lineRange, _, _ in
            let line = text.substring(with: lineRange)
            guard Self.listContinuation(for: line) != nil else { return }
            if outdent {
                let leading = line.prefix { $0 == " " }.count
                let remove = line.hasPrefix("\t") ? 1 : min(2, leading)
                if remove > 0 { edits.append((NSRange(location: lineRange.location, length: remove), "")) }
            } else {
                edits.append((NSRange(location: lineRange.location, length: 0), "  "))
            }
        }
        guard !edits.isEmpty else { return false }
        let ranges = edits.map { NSValue(range: $0.0) }
        guard shouldChangeText(inRanges: ranges, replacementStrings: edits.map(\.1)) else { return true }
        let selection = selectedRange()
        var shift = 0
        var firstShift = 0
        for (index, (range, replacement)) in edits.enumerated() {
            let adjusted = NSRange(location: range.location + shift, length: range.length)
            storage.replaceCharacters(in: adjusted, with: replacement)
            let delta = (replacement as NSString).length - range.length
            if index == 0 { firstShift = delta }
            shift += delta
        }
        didChangeText()
        let location = max(lines.location, selection.location + firstShift)
        setSelectedRange(NSRange(location: location, length: max(0, selection.length + shift - firstShift)))
        return true
    }

    // MARK: Formatting

    @objc func toggleBold(_ sender: Any?) { wrapMarkdownSelection(with: "**") }
    @objc func toggleItalic(_ sender: Any?) { wrapMarkdownSelection(with: "_") }
    @objc func toggleStrikethrough(_ sender: Any?) { wrapMarkdownSelection(with: "~~") }
    @objc func toggleInlineCode(_ sender: Any?) { wrapMarkdownSelection(with: "`") }
    @objc func insertLink(_ sender: Any?) { insertMarkdownLink() }

    @objc func toggleChecklist(_ sender: Any?) {
        guard !isEditingCell else { return }
        toggleLinePrefix("- [ ] ", matching: #"^(\s*)[-*+]\s+\[[ xX]\]\s+"#)
    }
    @objc func toggleBulletList(_ sender: Any?) {
        guard !isEditingCell else { return }
        toggleLinePrefix("- ", matching: #"^(\s*)[-*+]\s+(?!\[[ xX]\])"#)
    }
    @objc func toggleQuote(_ sender: Any?) {
        guard !isEditingCell else { return }
        toggleLinePrefix("> ", matching: #"^(\s*)>\s?"#)
    }
    @objc func makeHeading1(_ sender: Any?) { setHeading(1) }
    @objc func makeHeading2(_ sender: Any?) { setHeading(2) }
    @objc func makeHeading3(_ sender: Any?) { setHeading(3) }
    @objc func makeBodyText(_ sender: Any?) { setHeading(0) }

    func replace(_ range: NSRange, with replacement: String, select selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }

    private func toggleLinePrefix(_ prefix: String, matching pattern: String) {
        guard let storage = textStorage, let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let text = storage.string as NSString
        let lines = text.lineRange(for: selectedRange())
        var lineRanges: [NSRange] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, _, _ in lineRanges.append(range) }
        if lineRanges.isEmpty { lineRanges = [NSRange(location: lines.location, length: 0)] }
        let allPrefixed = lineRanges.allSatisfy { regex.firstMatch(in: text as String, range: $0) != nil }

        var edits: [(NSRange, String)] = []
        for range in lineRanges {
            if allPrefixed, let match = regex.firstMatch(in: text as String, range: range) {
                let indent = match.range(at: 1)
                edits.append((NSRange(location: NSMaxRange(indent), length: NSMaxRange(match.range) - NSMaxRange(indent)), ""))
            } else if !allPrefixed {
                let line = text.substring(with: range)
                let indent = (line.prefix { $0 == " " || $0 == "\t" } as Substring).utf16.count
                edits.append((NSRange(location: range.location + indent, length: 0), prefix))
            }
        }
        apply(edits, keepingLinesSelected: lines)
    }

    private func setHeading(_ level: Int) {
        guard !isEditingCell, let storage = textStorage, let regex = try? NSRegularExpression(pattern: #"^\s{0,3}#{1,6}\s+"#) else { return }
        let text = storage.string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let existing = regex.firstMatch(in: text as String, range: line)?.range ?? NSRange(location: line.location, length: 0)
        let marks = level > 0 ? String(repeating: "#", count: level) + " " : ""
        apply([(existing, marks)], keepingLinesSelected: line)
    }

    private func apply(_ edits: [(NSRange, String)], keepingLinesSelected lines: NSRange) {
        guard let storage = textStorage, !edits.isEmpty else { return }
        guard shouldChangeText(inRanges: edits.map { NSValue(range: $0.0) }, replacementStrings: edits.map(\.1)) else { return }
        let selection = selectedRange()
        var shift = 0
        var shiftBeforeCaret = 0
        for (range, replacement) in edits {
            storage.replaceCharacters(in: NSRange(location: range.location + shift, length: range.length), with: replacement)
            let delta = (replacement as NSString).length - range.length
            if range.location <= selection.location { shiftBeforeCaret += delta }
            shift += delta
        }
        didChangeText()
        let location = max(lines.location, selection.location + shiftBeforeCaret)
        setSelectedRange(NSRange(location: location, length: max(0, selection.length + shift - shiftBeforeCaret)))
    }

    // MARK: Navigation

    /// Scrolls `range` near the top of the view and puts the caret there.
    func reveal(_ range: NSRange, select: Bool = false) {
        guard let layoutManager, let textContainer, let scrollView = enclosingScrollView else { return }
        let length = (string as NSString).length
        let target = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(target)))
        let glyphs = layoutManager.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        let y = max(0, rect.minY + textContainerOrigin.y - 80 - scrollView.contentInsets.top)
        let maxY = max(0, frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY) - scrollView.contentInsets.top))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        setSelectedRange(select ? target : NSRange(location: target.location, length: 0))
        // A match in a table shows as a highlight in its cell instead.
        if select, tableContaining(caret: target.location) == nil { showFindIndicator(for: target) }
    }
}

// MARK: - Inline formatting

extension NSTextView {
    /// Wraps the selection in `mark`, or unwraps it when it already is.
    func wrapMarkdownSelection(with mark: String) {
        guard let storage = textStorage else { return }
        let text = storage.string as NSString
        let range = selectedRange()
        let length = (mark as NSString).length
        let selected = text.substring(with: range)

        // Already wrapped, inside or just outside the selection: unwrap.
        if selected.count >= length * 2, selected.hasPrefix(mark), selected.hasSuffix(mark) {
            let inner = String(selected.dropFirst(mark.count).dropLast(mark.count))
            replaceMarkdown(range, with: inner, select: NSRange(location: range.location, length: (inner as NSString).length))
            return
        }
        if range.location >= length, NSMaxRange(range) + length <= text.length,
           text.substring(with: NSRange(location: range.location - length, length: length)) == mark,
           text.substring(with: NSRange(location: NSMaxRange(range), length: length)) == mark {
            let outer = NSRange(location: range.location - length, length: range.length + length * 2)
            replaceMarkdown(outer, with: selected, select: NSRange(location: outer.location, length: range.length))
            return
        }
        replaceMarkdown(range, with: mark + selected + mark, select: NSRange(location: range.location + length, length: range.length))
    }

    func insertMarkdownLink() {
        let range = selectedRange()
        let selected = (string as NSString).substring(with: range)
        let isURL = selected.hasPrefix("http://") || selected.hasPrefix("https://")
        let label = isURL ? "" : selected
        let target = isURL ? selected : "https://"
        let replacement = "[\(label)](\(target))"
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName("Insert Link")
        if label.isEmpty {
            setSelectedRange(NSRange(location: range.location + 1, length: 0))
        } else {
            let start = range.location + (label as NSString).length + 3
            setSelectedRange(NSRange(location: start, length: (target as NSString).length))
        }
    }

    private func replaceMarkdown(_ range: NSRange, with replacement: String, select selection: NSRange) {
        guard shouldChangeText(in: range, replacementString: replacement) else { return }
        replaceCharacters(in: range, with: replacement)
        didChangeText()
        setSelectedRange(selection)
    }
}

// MARK: - Cover

/// A cover image filling its frame, cropped to show `position` of its height.
final class CoverImageView: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var position: CGFloat = 0.5 { didSet { if position != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // Views stopped clipping their drawing by default in macOS 14; an
        // aspect-filled image would spill over the note.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    /// How much taller the scaled image is than the frame.
    var overflow: CGFloat {
        guard let image, image.size.width > 0, image.size.height > 0 else { return 0 }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        return image.size.height * scale - bounds.height
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image, image.size.width > 0, image.size.height > 0 else {
            NSColor.quaternaryLabelColor.setFill()
            bounds.fill()
            return
        }
        let scale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let rect = NSRect(x: (bounds.width - size.width) / 2, y: -(size.height - bounds.height) * position,
                          width: size.width, height: size.height)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])
    }
}

// MARK: - Layout manager

/// Paints what the styler marks: code block grounds, quote bars, rules,
/// inline code chips, bullets and checkboxes. Hidden marks become null glyphs.
final class EditorLayoutManager: NSLayoutManager, NSLayoutManagerDelegate {
    private var editor: EditorTextView? { firstTextView as? EditorTextView }
    /// Where a code line's baseline sits in its line box, for empty lines' numbers.
    private var codeBaselineOffset: CGFloat?

    func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                       properties: UnsafePointer<NSLayoutManager.GlyphProperty>, characterIndexes: UnsafePointer<Int>,
                       font: NSFont, forGlyphRange glyphRange: NSRange) -> Int {
        guard let storage = textStorage, glyphRange.length > 0 else { return 0 }
        let first = characterIndexes[0]
        let span = NSRange(location: first, length: characterIndexes[glyphRange.length - 1] - first + 1)
        // Hidden characters become control glyphs that advance by nothing
        // (see shouldUse:forControlCharacterAt:). They keep a real place on
        // their own line; null glyphs would be pulled onto the line above,
        // taking an empty heading's marks, or a table's first line, with them.
        var hiddenRuns: [NSRange] = []
        for key in [NSAttributedString.Key.lotionHidden, .lotionCollapsed, .lotionTableText, .lotionCodeViewport] {
            storage.enumerateAttribute(key, in: span) { value, range, _ in
                if value != nil { hiddenRuns.append(range) }
            }
        }
        guard !hiddenRuns.isEmpty else { return 0 }
        hiddenRuns.sort { $0.location < $1.location }
        // Character indexes only grow, so one pass over the runs does.
        var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var run = 0
        for i in 0..<glyphRange.length {
            let index = characterIndexes[i]
            while run < hiddenRuns.count, NSMaxRange(hiddenRuns[run]) <= index { run += 1 }
            guard run < hiddenRuns.count else { break }
            guard index >= hiddenRuns[run].location else { continue }
            newProperties[i] = .controlCharacter
        }
        layoutManager.setGlyphs(glyphs, properties: newProperties, characterIndexes: characterIndexes, font: font, forGlyphRange: glyphRange)
        return glyphRange.length
    }

    /// Hidden characters take no room; real line breaks still break lines.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
        guard let storage = textStorage, charIndex < storage.length else { return action }
        let c = (storage.string as NSString).character(at: charIndex)
        if c == 10 || c == 13 || c == 0x2028 || c == 0x2029 { return action }
        for key in [NSAttributedString.Key.lotionTableText, .lotionCodeViewport, .lotionHidden, .lotionCollapsed]
        where storage.attribute(key, at: charIndex, effectiveRange: nil) != nil {
            return .zeroAdvancement
        }
        return action
    }

    /// Folded code lines take no height. A table's first line is as tall as
    /// the table drawn over it; its other lines take none.
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let character = characterIndexForGlyph(at: glyphRange.location)
        guard character < storage.length else { return false }
        // TextKit folds a lone line break just before a table into the
        // table's first line, so that line is the one holding the table's
        // first character, wherever it starts.
        let characters = characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let last = min(storage.length - 1, NSMaxRange(characters) - 1)
        let probe = storage.attribute(.lotionTableText, at: last, effectiveRange: nil) != nil ? last
            : storage.attribute(.lotionTableText, at: character, effectiveRange: nil) != nil ? character : nil
        if let probe {
            var full = NSRange()
            if let table = (storage.attribute(.lotionBlock, at: probe, longestEffectiveRange: &full,
                                              in: NSRange(location: 0, length: storage.length)) as? BlockDecoration)?.table,
               NSLocationInRange(full.location, characters), let editor {
                let layout = table.layout(available: textContainer.size.width - editor.gutter * 2,
                                          override: editor.cellOverride(forTableAt: full.location))
                lineFragmentRect.pointee.size.height = layout.blockHeight
                lineFragmentUsedRect.pointee.size.height = layout.blockHeight
            } else {
                lineFragmentRect.pointee.size.height = 0
                lineFragmentUsedRect.pointee.size.height = 0
            }
            baselineOffset.pointee = 0
            return true
        }
        // A scrolling code block: its first line holds the viewport the code
        // view sits in; its other lines take no room.
        let codeProbe = storage.attribute(.lotionCodeViewport, at: last, effectiveRange: nil) != nil ? last
            : storage.attribute(.lotionCodeViewport, at: character, effectiveRange: nil) != nil ? character : nil
        if let codeProbe {
            var full = NSRange()
            let viewport = storage.attribute(.lotionCodeViewport, at: codeProbe, longestEffectiveRange: &full,
                                             in: NSRange(location: 0, length: storage.length)) as? CodeViewport
            let height = viewport.map { NSLocationInRange(full.location, characters) ? $0.height : 0 } ?? 0
            lineFragmentRect.pointee.size.height = height
            lineFragmentUsedRect.pointee.size.height = height
            baselineOffset.pointee = 0
            return true
        }
        if storage.attribute(.lotionCollapsed, at: character, effectiveRange: nil) != nil {
            lineFragmentRect.pointee.size.height = 0
            lineFragmentUsedRect.pointee.size.height = 0
            baselineOffset.pointee = 0
            return true
        }
        return false
    }

    /// Layout settling (a resize, text above changing) can move a table; the cell editor follows.
    func layoutManager(_ layoutManager: NSLayoutManager, didCompleteLayoutFor textContainer: NSTextContainer?, atEnd layoutFinishedFlag: Bool) {
        editor?.setNeedsCellEditorPosition()
        editor?.setNeedsCodeViewSync()
    }

    /// Selection behind a table's hidden rows is left to the table, which draws its own.
    override func fillBackgroundRectArray(_ rectArray: UnsafePointer<NSRect>, count rectCount: Int,
                                          forCharacterRange charRange: NSRange, color: NSColor) {
        guard let storage = textStorage, let editor, charRange.length > 0, NSMaxRange(charRange) <= storage.length else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        var tables: [NSRect] = []
        storage.enumerateAttribute(.lotionBlock, in: charRange) { value, range, _ in
            guard let table = (value as? BlockDecoration)?.table,
                  let found = editor.table(at: range.location) else { return }
            tables.append(editor.tableGeometry(found.range, table).blockRect)
        }
        // A scrolling code block's hidden code: its view shows its own selection.
        storage.enumerateAttribute(.lotionCodeViewport, in: charRange) { value, range, _ in
            guard let viewport = value as? CodeViewport, let block = editor.codeViewport(at: range.location) else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyphIndexForCharacter(at: block.range.location), effectiveRange: nil)
            tables.append(NSRect(x: 0, y: fragment.minY + editor.textContainerOrigin.y, width: editor.bounds.width, height: viewport.height))
        }
        guard !tables.isEmpty else {
            return super.fillBackgroundRectArray(rectArray, count: rectCount, forCharacterRange: charRange, color: color)
        }
        let kept = (0..<rectCount).map { rectArray[$0] }.filter { rect in
            rect.height > 0 && !tables.contains { $0.intersects(rect.insetBy(dx: 0, dy: 0.5)) }
        }
        guard !kept.isEmpty else { return }
        kept.withUnsafeBufferPointer { buffer in
            super.fillBackgroundRectArray(buffer.baseAddress!, count: kept.count, forCharacterRange: charRange, color: color)
        }
    }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let storage = textStorage, let editor, let palette = editor.palette, let container = textContainers.first {
            let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
            let whole = NSRange(location: 0, length: storage.length)
            let columnLeft = origin.x + editor.gutter
            let columnWidth = container.size.width - editor.gutter * 2

            storage.enumerateAttribute(.lotionBlock, in: chars) { value, range, _ in
                guard let decoration = value as? BlockDecoration else { return }
                var full = NSRange()
                storage.attribute(.lotionBlock, at: range.location, longestEffectiveRange: &full, in: whole)
                let glyphs = glyphRange(forCharacterRange: full, actualCharacterRange: nil)
                guard glyphs.length > 0 else { return }
                let first = lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
                let last = lineFragmentRect(forGlyphAt: NSMaxRange(glyphs) - 1, effectiveRange: nil)

                switch decoration.kind {
                case .code:
                    // Padding measured from the text, not the line boxes: the
                    // last line of a note gets no paragraph spacing.
                    let bleed: CGFloat = 14
                    let inset = MarkdownStyler.codeInset
                    let font = storage.attribute(.font, at: full.location, effectiveRange: nil) as? NSFont
                    let ascender = font?.ascender ?? 11, descender = font?.descender ?? -3
                    let lastGlyph = NSMaxRange(glyphs) - 1
                    let endsWithBreak = (storage.string as NSString).character(at: NSMaxRange(full) - 1) == 10
                    let bottomGlyph = endsWithBreak && glyphs.length > 1 ? lastGlyph - 1 : lastGlyph
                    let top = baselineY(ofGlyphAt: glyphs.location, origin: origin) - ascender - inset
                    let bottom: CGFloat
                    if let code = decoration.code, code.showsHeader, code.isClosed {
                        // The hidden closing fence's row is exactly the bottom inset, or the handle.
                        let row = lineFragmentRect(forGlyphAt: bottomGlyph, effectiveRange: nil)
                        bottom = row.minY + origin.y + (code.isResizable ? MarkdownStyler.codeHandleHeight : inset)
                    } else {
                        bottom = baselineY(ofGlyphAt: bottomGlyph, origin: origin) - descender + inset
                    }
                    let rect = NSRect(x: columnLeft - bleed, y: top,
                                      width: columnWidth + bleed * 2, height: bottom - top)
                    let path = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
                    palette.codeBackground.setFill()
                    path.fill()
                    palette.codeBorder.setStroke()
                    let border = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
                    border.lineWidth = 0.5
                    border.stroke()
                    if let code = decoration.code, let font {
                        drawCodeChrome(code, in: rect, firstGlyph: glyphs.location, lastGlyph: bottomGlyph,
                                       columnLeft: columnLeft, font: font, origin: origin, palette: palette)
                    }

                case .quote:
                    let spacing = (storage.attribute(.paragraphStyle, at: NSMaxRange(full) - 1, effectiveRange: nil) as? NSParagraphStyle)?.lineSpacing ?? 0
                    let rect = NSRect(x: columnLeft - 13, y: first.minY + origin.y + 2,
                                      width: 3, height: last.maxY - first.minY - spacing - 4)
                    palette.marker.withAlphaComponent(0.7).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 1.5, yRadius: 1.5).fill()

                case .table:
                    guard let table = decoration.table else { return }
                    let geometry = editor.tableGeometry(full, table)
                    let clip = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath ?? .infinite
                    table.draw(geometry.layout, at: geometry.origin, offset: geometry.offset,
                               editing: editor.editingCell(inTableAt: full.location),
                               highlight: editor.tableHighlight(full, table), clip: clip)

                case .rule:
                    let y = midline(ofGlyphAt: glyphs.location, origin: origin, font: storage.attribute(.font, at: full.location, effectiveRange: nil) as? NSFont)
                    palette.rule.setFill()
                    NSRect(x: columnLeft, y: round(y), width: columnWidth, height: 1).fill()
                }
            }

            storage.enumerateAttribute(.lotionInlineCode, in: chars) { value, range, _ in
                guard value != nil else { return }
                drawInlineCode(range, origin: origin, container: container, color: palette.inlineCode)
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let palette = editor?.palette else { return }
        let chars = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        storage.enumerateAttribute(.lotionLineNumber, in: chars) { value, range, _ in
            guard let number = value as? Int, storage.attribute(.lotionCollapsed, at: range.location, effectiveRange: nil) == nil,
                  let code = (storage.attribute(.lotionBlock, at: range.location, effectiveRange: nil) as? BlockDecoration)?.code,
                  let editor = self.editor else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? .monospacedSystemFont(ofSize: 13, weight: .regular)
            let glyph = glyphIndexForCharacter(at: range.location)
            let label = "\(number)" as NSString
            let numberFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular)
            let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: palette.marker]
            let size = label.size(withAttributes: attributes)
            let right = origin.x + editor.gutter + code.numberWidth - 14
            // The line's own baseline. An empty line's break character has no
            // useful position, so it borrows the offset of a line with text:
            // every line of a block shares its font and spacing.
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let isEmpty = (storage.string as NSString).character(at: range.location) == 10
            if !isEmpty { codeBaselineOffset = location(forGlyphAt: glyph).y }
            let baseline = fragment.minY + origin.y + (isEmpty ? codeBaselineOffset ?? font.ascender : location(forGlyphAt: glyph).y)
            label.draw(at: NSPoint(x: right - size.width, y: baseline - numberFont.ascender), withAttributes: attributes)
        }

        storage.enumerateAttribute(.lotionBullet, in: chars) { value, range, _ in
            guard value != nil else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let glyph = glyphIndexForCharacter(at: range.location)
            let x = location(forGlyphAt: glyph).x + lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + origin.x
            let em = font?.pointSize ?? 15
            let size = round(em * 0.32 * 2) / 2
            let y = midline(ofGlyphAt: glyph, origin: origin, font: font)
            palette.accent.setFill()
            NSBezierPath(ovalIn: NSRect(x: x + em * 0.18, y: y - size / 2, width: size, height: size)).fill()
        }

        storage.enumerateAttribute(.lotionTask, in: chars) { value, range, _ in
            guard let checked = value as? Bool else { return }
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let glyph = glyphIndexForCharacter(at: range.location)
            let x = location(forGlyphAt: glyph).x + lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + origin.x
            let em = font?.pointSize ?? 15
            let size = round(em * 1.1)
            let baseline = baselineY(ofGlyphAt: glyph, origin: origin)
            let capHeight = font?.capHeight ?? em * 0.7
            let box = NSRect(x: x + 1, y: round(baseline - capHeight / 2 - size / 2), width: size, height: size)
            let path = NSBezierPath(roundedRect: box, xRadius: size * 0.28, yRadius: size * 0.28)
            if checked {
                palette.accent.setFill()
                path.fill()
                let check = NSBezierPath()
                check.move(to: NSPoint(x: box.minX + size * 0.27, y: box.midY + size * 0.02))
                check.line(to: NSPoint(x: box.minX + size * 0.44, y: box.minY + size * 0.70))
                check.line(to: NSPoint(x: box.minX + size * 0.74, y: box.minY + size * 0.31))
                check.lineWidth = max(1.5, size * 0.12)
                check.lineCapStyle = .round
                check.lineJoinStyle = .round
                NSColor.white.setStroke()
                check.stroke()
            } else {
                let inset = NSBezierPath(roundedRect: box.insetBy(dx: 0.75, dy: 0.75), xRadius: size * 0.26, yRadius: size * 0.26)
                inset.lineWidth = 1.5
                palette.accent.withAlphaComponent(0.85).setStroke()
                inset.stroke()
            }
        }
    }

    /// A code block's header, fold fade and resize handle.
    private func drawCodeChrome(_ code: CodeHeader, in rect: NSRect, firstGlyph: Int, lastGlyph: Int,
                                columnLeft: CGFloat, font: NSFont, origin: NSPoint, palette: ThemePalette) {
        let size = round(font.pointSize * 0.95)
        if code.showsHeader {
            let mid = baselineY(ofGlyphAt: firstGlyph, origin: origin) - font.xHeight / 2
            let title = code.title ?? code.language.map(Self.languageName) ?? "Code"
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: palette.text,
            ]
            var x = columnLeft
            if let symbol = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size, weight: .regular).applying(.init(hierarchicalColor: palette.secondary))) {
                symbol.draw(in: NSRect(x: x, y: mid - symbol.size.height / 2, width: symbol.size.width, height: symbol.size.height),
                            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                x += symbol.size.width + 8
            }
            let titleSize = (title as NSString).size(withAttributes: titleAttributes)
            (title as NSString).draw(at: NSPoint(x: x, y: mid - titleSize.height / 2), withAttributes: titleAttributes)
            if let language = code.language, code.title != nil || Self.languageName(language) != language.uppercased() {
                let label = language.uppercased() as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: size - 1, weight: .medium), .foregroundColor: palette.secondary,
                ]
                let labelSize = label.size(withAttributes: attributes)
                label.draw(at: NSPoint(x: rect.maxX - labelSize.width - 14, y: mid - labelSize.height / 2), withAttributes: attributes)
            }
        }
        guard code.isResizable, code.showsHeader else { return }
        let row = lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
        let handleTop = row.minY + origin.y
        let handleMid = handleTop + MarkdownStyler.codeHandleHeight / 2 - 2
        if code.hiddenLines > 0 {
            // The last visible lines fade into the block, hinting at more.
            let fade = NSRect(x: rect.minX + 1, y: handleTop - 30, width: rect.width - 2, height: 30)
            NSGradient(starting: palette.codeBackground.withAlphaComponent(0), ending: palette.codeBackground)?.draw(in: fade, angle: 90)
            let more = "\(code.hiddenLines) more \(code.hiddenLines == 1 ? "line" : "lines")" as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size - 1.5), .foregroundColor: palette.secondary]
            let moreSize = more.size(withAttributes: attributes)
            more.draw(at: NSPoint(x: columnLeft, y: handleMid - moreSize.height / 2), withAttributes: attributes)
        }
        let pill = NSRect(x: rect.midX - 18, y: rect.maxY - 8, width: 36, height: 4)
        palette.marker.setFill()
        NSBezierPath(roundedRect: pill, xRadius: 2, yRadius: 2).fill()
    }

    private static func languageName(_ language: String) -> String {
        let names = ["js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
                     "tsx": "TSX", "jsx": "JSX", "py": "Python", "python": "Python", "rb": "Ruby", "ruby": "Ruby",
                     "swift": "Swift", "go": "Go", "rs": "Rust", "rust": "Rust", "sh": "Shell", "bash": "Bash", "zsh": "Zsh",
                     "json": "JSON", "yaml": "YAML", "yml": "YAML", "html": "HTML", "css": "CSS", "sql": "SQL",
                     "md": "Markdown", "markdown": "Markdown", "kotlin": "Kotlin", "java": "Java", "c": "C", "cpp": "C++",
                     "objc": "Objective-C", "php": "PHP", "toml": "TOML", "diff": "Diff"]
        return names[language] ?? language.capitalized
    }

    private func baselineY(ofGlyphAt glyph: Int, origin: NSPoint) -> CGFloat {
        let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return fragment.minY + location(forGlyphAt: glyph).y + origin.y
    }

    /// The middle of the lowercase letters on a glyph's line.
    private func midline(ofGlyphAt glyph: Int, origin: NSPoint, font: NSFont?) -> CGFloat {
        baselineY(ofGlyphAt: glyph, origin: origin) - (font?.xHeight ?? 7) / 2
    }

    private func drawInlineCode(_ range: NSRange, origin: NSPoint, container: NSTextContainer, color: NSColor) {
        guard let storage = textStorage else { return }
        // The chip hugs the visible code: hidden backticks have no width but
        // still carry a position, which can sit well left of the text.
        var range = range
        while range.length > 0, storage.attribute(.lotionHidden, at: range.location, effectiveRange: nil) != nil {
            range = NSRange(location: range.location + 1, length: range.length - 1)
        }
        while range.length > 0, storage.attribute(.lotionHidden, at: NSMaxRange(range) - 1, effectiveRange: nil) != nil {
            range.length -= 1
        }
        guard range.length > 0 else { return }
        let glyphs = glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
        let ascender = font?.ascender ?? 11
        let descender = font?.descender ?? -3
        enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, lineGlyphs, _ in
            let piece = NSIntersectionRange(glyphs, lineGlyphs)
            guard piece.length > 0 else { return }
            let bounds = self.boundingRect(forGlyphRange: piece, in: container)
            let baseline = fragment.minY + self.location(forGlyphAt: piece.location).y
            let rect = NSRect(
                x: bounds.minX + origin.x - 3,
                y: baseline - ascender - 2 + origin.y,
                width: bounds.width + 6,
                height: ascender - descender + 4
            )
            color.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
        }
    }
}
