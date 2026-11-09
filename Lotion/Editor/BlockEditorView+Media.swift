//
//  BlockEditorView+Media.swift
//  Lotion
//
//  Adding images and videos: pasted, dropped, or picked from a panel. The
//  files are copied into the note's own folder and linked from there.
//

import AppKit
import UniformTypeIdentifiers

enum AttachmentInput {
    case file(URL)
    case data(Data, name: String, ext: String)

    var name: String {
        switch self {
        case .file(let url): url.deletingPathExtension().lastPathComponent
        case .data(_, let name, _): name
        }
    }
}

extension BlockEditorView {
    // MARK: Reading the pasteboard

    /// Images and videos on a pasteboard: files first, then image data.
    static func media(on board: NSPasteboard) -> [AttachmentInput] {
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter { !$0.hasDirectoryPath && $0.pathExtension.lowercased() != "md" }
        if !files.isEmpty { return files.map { .file($0) } }
        let string = board.string(forType: .string)
        guard string == nil || isURL(string ?? "") else { return [] }
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                                timeZone: .current, calendar: .current))
        if let png = board.data(forType: .png) {
            return [.data(png, name: "Image-\(stamp)", ext: "png")]
        }
        if let tiff = board.data(forType: .tiff), let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return [.data(png, name: "Image-\(stamp)", ext: "png")]
        }
        return []
    }

    static func hasMedia(_ board: NSPasteboard) -> Bool {
        let files = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
        if files.contains(where: { !$0.hasDirectoryPath && $0.pathExtension.lowercased() != "md" }) { return true }
        return board.availableType(from: [.png, .tiff]) != nil && board.availableType(from: [.fileURL]) == nil
    }

    // MARK: Inserting

    /// Copies media into the note and adds a block for each, before `position`
    /// (an index into the blocks), or after the focused block.
    func insertMedia(_ inputs: [AttachmentInput], at position: Int? = nil) {
        guard let attach = attachmentHandler, !inputs.isEmpty else { return }
        var made: [Block] = []
        for input in inputs {
            guard let link = attach(input) else { continue }
            // Images, video, audio and PDFs show as themselves; other files as a chip.
            var block = Block(kind: MediaKind.of(link) == .unknown ? .embed : .image)
            if block.kind == .embed {
                block.info = "file"
                block.imageAlt = (link.removingPercentEncoding ?? link).components(separatedBy: "/").last ?? input.name
            } else {
                block.imageAlt = input.name
            }
            block.imageSource = link
            made.append(block)
        }
        guard !made.isEmpty else { return }
        var at = position ?? ((blockSelection?.upperBound ?? focusedIndex ?? (blocks.count - 1)) + 1)
        at = max(0, min(blocks.count, at))
        // An empty paragraph where the media goes gives up its place.
        let replace = position == nil && at > 0 && blocks[at - 1].kind == .paragraph && blocks[at - 1].text.length == 0
        let start = replace ? at - 1 : at
        let after = replace ? at : at
        let needsParagraph = !(blocks.indices.contains(after) && blocks[after].kind.isText)
        let paragraph = Block(kind: .paragraph)
        let focus: FocusTarget = needsParagraph ? .text(paragraph.id, nil, NSRange(location: 0, length: 0)) : .blocks(made.map(\.id))
        let name: String = switch made.count == 1 ? MediaKind.of(made[0].imageSource) : nil {
        case .video: "Add Video"
        case .image: "Add Image"
        case .audio: "Add Audio"
        case .pdf: "Add PDF"
        case .unknown: "Add File"
        case nil: "Add Media"
        }
        mutate(name, focus: focus) { blocks in
            if replace { blocks.remove(at: start) }
            blocks.insert(contentsOf: made, at: start)
            if needsParagraph { blocks.insert(paragraph, at: start + made.count) }
        }
    }

    /// Picks images or videos from disk.
    func chooseMedia(video: Bool) { chooseFiles(video ? [.movie] : [.image]) }

    /// Picks files of these types (any file when empty) to add to the note.
    func chooseFiles(_ types: [UTType]) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if !types.isEmpty { panel.allowedContentTypes = types }
        panel.prompt = "Add"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let self else { return }
            self.insertMedia(panel.urls.map { .file($0) })
        }
    }

    @objc func insertMediaFromPanel(_ sender: Any?) { chooseMedia(video: false) }

    // MARK: Dropping

    func registerForMediaDrops() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    func mediaDragUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard Self.hasMedia(sender.draggingPasteboard) else {
            dropIndicator = nil
            return []
        }
        let point = convert(sender.draggingLocation, from: nil)
        dropIndicator = gapY(before: mediaDropIndex(atY: point.y))
        autoscroll(with: NSApp.currentEvent ?? NSEvent())
        return .copy
    }

    func mediaDragEnded() { dropIndicator = nil }

    func performMediaDrop(_ sender: NSDraggingInfo) -> Bool {
        dropIndicator = nil
        let inputs = Self.media(on: sender.draggingPasteboard)
        guard !inputs.isEmpty else { return false }
        let point = convert(sender.draggingLocation, from: nil)
        insertMedia(inputs, at: mediaDropIndex(atY: point.y))
        return true
    }

    func mediaDropIndex(atY y: CGFloat) -> Int {
        for (index, view) in views.enumerated() where y < view.frame.midY { return index }
        return views.count
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { mediaDragUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { mediaDragUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { mediaDragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { performMediaDrop(sender) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { mediaDragEnded() }
}
