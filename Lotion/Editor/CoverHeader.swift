//
//  CoverHeader.swift
//  Lotion
//
//  The note's cover: a band of image above the title, with buttons to
//  change, reposition or remove it on hover, and "Add Cover" over the space
//  above the title of a note without one.
//

import AppKit

final class CoverHeader: NSObject {
    var onAdd: (() -> Void)?
    var onChange: ((NSRect) -> Void)?
    var onRemove: (() -> Void)?
    var onMove: ((Double) -> Void)?

    private(set) var hasCover = false
    private let imageView = CoverImageView()
    private lazy var controls: NSStackView = {
        let stack = NSStackView(views: [
            button("Change Cover", #selector(change)),
            repositionButton,
            button("Remove", #selector(remove)),
        ])
        stack.spacing = 6
        return stack
    }()
    private lazy var repositionButton = button("Reposition", #selector(toggleReposition))
    private lazy var creditButton = button("", #selector(openCredit))
    private lazy var addButton: NSButton = {
        let button = NSButton(title: "Add Cover", image: NSImage(systemSymbolName: "photo", accessibilityDescription: nil)!,
                              target: self, action: #selector(add))
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.imagePosition = .imageLeading
        return button
    }()
    private var creditURL: URL?
    private var isRepositioning = false
    private var width: CGFloat = 800
    private var secondary: NSColor = .secondaryLabelColor

    var height: CGFloat { round(min(300, width / 4)) }
    var topInset: CGFloat { hasCover ? height + 44 : 64 }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .glass
        button.controlSize = .small
        return button
    }

    func install(in view: NSView) {
        for subview in [imageView, controls, creditButton, addButton] as [NSView] {
            subview.isHidden = true
            view.addSubview(subview)
        }
    }

    func applyTheme(_ theme: BlockTheme) {
        secondary = theme.palette.secondary
        addButton.contentTintColor = secondary
    }

    func set(_ present: Bool, image: NSImage?, position: Double, credit: String?, creditURL: URL?, in editor: BlockEditorView) {
        let changed = present != hasCover
        hasCover = present
        imageView.image = image
        if !isRepositioning { imageView.position = position }
        creditButton.title = credit.map { "Photo by \($0) on Unsplash" } ?? ""
        self.creditURL = creditURL
        if changed {
            isRepositioning = false
            repositionButton.title = "Reposition"
            editor.relayout()
        } else {
            layout(in: editor)
        }
        updateHover(at: editor.window.map { editor.convert($0.mouseLocationOutsideOfEventStream, from: nil) }, in: editor)
    }

    func layout(in editor: BlockEditorView) {
        width = editor.bounds.width
        imageView.frame = NSRect(x: 0, y: 0, width: editor.bounds.width, height: height)
        imageView.isHidden = !hasCover
        let size = controls.fittingSize
        let right = editor.columnX + editor.columnWidth
        controls.frame = NSRect(x: right - size.width, y: height - size.height - 12, width: size.width, height: size.height)
        let credit = creditButton.fittingSize
        creditButton.frame = NSRect(x: editor.columnX, y: height - credit.height - 12, width: credit.width, height: credit.height)
        let add = addButton.fittingSize
        addButton.frame = NSRect(x: editor.columnX - 4, y: 22, width: add.width, height: add.height)
        addButton.contentTintColor = secondary
    }

    /// Buttons show while the pointer is over the cover, or for a note
    /// without one, over the space above its title.
    func updateHover(at point: NSPoint?, in editor: BlockEditorView) {
        let inTop = point.map { editor.bounds.contains($0) && $0.y < (hasCover ? height : topInset) } ?? false
        controls.isHidden = !(hasCover && (inTop || isRepositioning))
        creditButton.isHidden = controls.isHidden || creditButton.title.isEmpty
        addButton.isHidden = hasCover || !inTop || editor.isScratchpad
    }

    /// Dragging a cover while repositioning slides the image under it.
    func mouseDown(at point: NSPoint, in editor: BlockEditorView) -> Bool {
        guard hasCover, point.y < height else { return false }
        guard isRepositioning else { return true }
        var last = point
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        while let event = editor.window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let current = editor.convert(event.locationInWindow, from: nil)
            let overflow = imageView.overflow
            if overflow > 0 {
                imageView.position = min(1, max(0, imageView.position - (current.y - last.y) / overflow))
            }
            last = current
            if event.type == .leftMouseUp { break }
        }
        return true
    }

    @objc private func add() { onAdd?() }
    @objc private func change() { onChange?(controls.frame) }
    @objc private func remove() { onRemove?() }
    @objc private func openCredit() { if let creditURL { NSWorkspace.shared.open(creditURL) } }

    @objc private func toggleReposition() {
        if isRepositioning { onMove?(imageView.position) }
        isRepositioning.toggle()
        repositionButton.title = isRepositioning ? "Save Position" : "Reposition"
    }
}

final class CoverImageView: NSView {
    var image: NSImage? { didSet { if image !== oldValue { needsDisplay = true } } }
    var position: CGFloat = 0.5 { didSet { if position != oldValue { needsDisplay = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        // The image is scaled to the whole width, so a resize changes every
        // pixel: redraw all of it, not just the strip a sidebar uncovers.
        layerContentsRedrawPolicy = .duringViewResize
        // Views stopped clipping their drawing by default in macOS 14; an
        // aspect-filled image would spill over the note.
        clipsToBounds = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { setNeedsDisplay(bounds) }
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

/// A small popover for a link's address.
final class LinkPopover: NSViewController, NSTextFieldDelegate {
    private let field = NSTextField()
    private var completion: ((String) -> Void)?
    private var popover: NSPopover?
    private static var current: LinkPopover?

    static func show(relativeTo rect: NSRect, of view: NSView, url: String, completion: @escaping (String) -> Void) {
        let controller = LinkPopover()
        controller.completion = completion
        controller.field.stringValue = url
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        controller.popover = popover
        current = controller
        popover.show(relativeTo: rect.isEmpty ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: max(1, rect.height)) : rect,
                     of: view, preferredEdge: .maxY)
        popover.contentViewController?.view.window?.makeFirstResponder(controller.field)
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 44))
        field.frame = NSRect(x: 10, y: 10, width: 300, height: 24)
        field.placeholderString = "Paste or type a link"
        field.delegate = self
        field.bezelStyle = .roundedBezel
        field.target = self
        field.action = #selector(commit)
        container.addSubview(field)
        view = container
    }

    @objc private func commit() {
        let value = field.stringValue
        let completion = self.completion
        self.completion = nil
        popover?.close()
        LinkPopover.current = nil
        completion?(value)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            completion = nil
            popover?.close()
            LinkPopover.current = nil
            return true
        }
        return false
    }
}
