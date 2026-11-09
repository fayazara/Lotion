//
//  Library.swift
//  Lotion
//
//  Notes are plain Markdown files in one folder on disk; each subfolder is a
//  folder in the sidebar (one level deep). A note's title is its first line,
//  and its file is renamed to match whenever it is saved. Pins live in
//  UserDefaults and covers in `.lotion/covers.json`, both keyed by path
//  relative to the library, note icons in `.lotion/notes.json` and folder
//  icons in `.lotion/folders.json`, so
//  the Markdown stays untouched.
//

import AppKit
import Foundation
import Observation

@Observable
final class Note: Identifiable, Hashable {
    let id = UUID()
    var url: URL
    /// The folder's name, or nil for a note at the top of the library.
    var folder: String?
    private(set) var text: String
    private(set) var title: String
    var created: Date
    var modified: Date
    /// Bumped when the file changed on disk and `text` was reloaded, so an
    /// open editor knows to take the new text.
    private(set) var diskRevision = 0

    /// The text last read from or written to disk.
    @ObservationIgnored var savedText: String
    /// The library's one scratchpad: an endless page of entries, kept out of
    /// the list of notes, never renamed, moved or thrown away.
    let isScratchpad: Bool

    init(url: URL, folder: String?, text: String, created: Date, modified: Date, isScratchpad: Bool = false) {
        self.isScratchpad = isScratchpad
        self.url = url
        self.folder = folder
        self.text = text
        self.savedText = text
        self.title = Note.title(from: text)
        self.created = created
        self.modified = modified
    }

    var isDirty: Bool { text != savedText }

    /// A scratchpad's entries, counted by their breaks.
    var entryCount: Int {
        guard isScratchpad else { return 0 }
        return text.components(separatedBy: BlockMarkdown.entryPrefix).count - 1
    }
    var displayTitle: String { isScratchpad ? "Scratchpad" : title.isEmpty ? "Untitled" : title }
    var fileName: String { url.lastPathComponent }

    /// True when there is nothing worth keeping: no text beyond a bare `#`.
    var isBlank: Bool {
        text.allSatisfy { $0.isWhitespace || $0 == "#" }
    }

    /// Callers pass text that changed; comparing whole notes per keystroke costs more than it saves.
    func setText(_ newText: String) {
        text = newText
        let newTitle = Note.title(from: newText)
        if newTitle != title { title = newTitle }
    }

    func reload(text newText: String, modified date: Date) {
        savedText = newText
        modified = date
        guard newText != text else { return }
        setText(newText)
        diskRevision += 1
    }

    /// The first non-empty line, without heading marks or emphasis.
    static func title(from text: String) -> String {
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            var line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            while line.hasPrefix("#") { line.removeFirst() }
            line = line.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                line = line.replacingOccurrences(of: "**", with: "")
                    .replacingOccurrences(of: "__", with: "")
                    .replacingOccurrences(of: "`", with: "")
                return String(line.prefix(120))
            }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        return ""
    }

    nonisolated static func == (lhs: Note, rhs: Note) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

struct SearchResult: Identifiable {
    let note: Note
    let snippet: String
    /// The first match in the note's text, for the editor to reveal.
    let match: NSRange?
    var id: Note.ID { note.id }
}

@Observable
final class Library {
    let root: URL
    private(set) var notes: [Note] = []
    /// The endless page at the top of the sidebar, in `.lotion/Scratchpad/`.
    private(set) var scratchpad: Note?
    private(set) var folders: [String] = []
    private(set) var pinnedPaths: Set<String>
    private(set) var covers: [String: NoteCover] = [:]
    /// SF Symbol names chosen for notes, keyed by relative path.
    private(set) var noteIcons: [String: String] = [:]
    /// SF Symbol names chosen for folders, keyed by folder name.
    private(set) var folderIcons: [String: String] = [:]
    var sort: NoteSort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: Prefs.sort) }
    }
    /// The last file operation that failed, for an alert.
    var errorMessage: String?

    @ObservationIgnored private var saveTasks: [Note.ID: Task<Void, Never>] = [:]
    /// The demo library keeps its own pins, apart from the real ones.
    private static var pinsKey: String { DemoLibrary.isEnabled ? DemoLibrary.pinsKey : "pinnedNotes" }
    private static let extensions: Set<String> = ["md", "markdown"]

    init(root: URL = Library.defaultRoot()) {
        self.root = root
        Self.migrateMetadataFolder(in: root)
        if DemoLibrary.isEnabled { DemoLibrary.seedIfNeeded() }
        pinnedPaths = Set(UserDefaults.standard.stringArray(forKey: Self.pinsKey) ?? [])
        covers = Self.readMetadata("covers.json", in: root) ?? [:]
        folderIcons = Self.readMetadata("folders.json", in: root) ?? [:]
        noteIcons = Self.readMetadata("notes.json", in: root) ?? [:]
        sort = NoteSort(rawValue: UserDefaults.standard.string(forKey: Prefs.sort) ?? "") ?? .created
    }

    static func defaultRoot() -> URL {
        if DemoLibrary.isEnabled { return DemoLibrary.root }
        #if DEBUG
        // Test runs point the app at a scratch library.
        if let path = UserDefaults.standard.string(forKey: "LotionLibrary") {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return URL.documentsDirectory.appending(path: "Notes", directoryHint: .isDirectory)
    }

    // MARK: Reading

    /// Scans the library. The first launch seeds it with a welcome note.
    func load() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        if !DemoLibrary.isEnabled, !UserDefaults.standard.bool(forKey: "didSeedLibrary") {
            UserDefaults.standard.set(true, forKey: "didSeedLibrary")
            let url = root.appending(path: "Welcome to Lotion.md")
            if !fm.fileExists(atPath: url.path) {
                try? WelcomeNote.text.write(to: url, atomically: true, encoding: .utf8)
            }
        }
        refreshFromDisk()
        loadScratchpad()
    }

    private var scratchpadURL: URL {
        root.appending(path: ".lotion/Scratchpad/Scratchpad.md")
    }

    /// Reads the scratchpad, starting one with a first entry the first time.
    private func loadScratchpad() {
        let fm = FileManager.default
        let url = scratchpadURL
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? (Self.entryMarker() + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let modified = values?.contentModificationDate ?? .now
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        scratchpad = Note(url: url, folder: nil, text: text, created: values?.creationDate ?? modified, modified: modified, isScratchpad: true)
    }

    /// The line that starts a scratchpad entry made now.
    static func entryMarker(at date: Date = .now) -> String {
        BlockMarkdown.entryPrefix + date.formatted(.iso8601) + " -->"
    }

    /// Re-reads the folder: picks up notes added, removed or changed by other
    /// apps. Notes with unsaved edits keep them.
    func refreshFromDisk() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .creationDateKey, .contentModificationDateKey]
        let existing = Dictionary(notes.map { ($0.url.standardizedFileURL.path, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [Note] = []
        var foundFolders: [String] = []

        func scan(_ directory: URL, folder: String?) {
            guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            for item in items {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if let file = Self.noteFile(inBundle: item) {
                        // A note's own folder: its Markdown and the files it shows.
                        addNote(at: file, folder: folder)
                    } else if folder == nil {
                        foundFolders.append(item.lastPathComponent)
                        scan(item, folder: item.lastPathComponent)
                    }
                    continue
                }
                guard Self.extensions.contains(item.pathExtension.lowercased()) else { continue }
                addNote(at: item, folder: folder)
            }
        }

        func addNote(at item: URL, folder: String?) {
            do {
                let values = try? item.resourceValues(forKeys: Set(keys))
                let modified = values?.contentModificationDate ?? .now
                let created = values?.creationDate ?? modified
                if let note = existing[item.standardizedFileURL.path] {
                    if !note.isDirty, modified > note.modified, let text = try? String(contentsOf: item, encoding: .utf8) {
                        note.reload(text: text, modified: modified)
                    }
                    found.append(note)
                } else if let text = try? String(contentsOf: item, encoding: .utf8) {
                    found.append(Note(url: item, folder: folder, text: text, created: created, modified: modified))
                }
            }
        }
        scan(root, folder: nil)

        // A note being edited whose file vanished stays; its next save writes it back.
        let foundIDs = Set(found.map(\.id))
        found += notes.filter { $0.isDirty && !foundIDs.contains($0.id) }

        notes = found
        folders = foundFolders.sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        if let scratchpad, !scratchpad.isDirty,
           let modified = try? scratchpad.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           modified > scratchpad.modified, let text = try? String(contentsOf: scratchpad.url, encoding: .utf8) {
            scratchpad.reload(text: text, modified: modified)
        }
    }

    func note(id: Note.ID?) -> Note? {
        guard let id else { return nil }
        if let scratchpad, scratchpad.id == id { return scratchpad }
        return notes.first { $0.id == id }
    }

    /// The notes listed under a folder (nil for the top level), pinned notes excluded.
    func notes(in folder: String?) -> [Note] {
        sorted(notes.filter { $0.folder == folder && !isPinned($0) })
    }

    var pinnedNotes: [Note] {
        sorted(notes.filter(isPinned))
    }

    private func sorted(_ list: [Note]) -> [Note] {
        switch sort {
        case .created: list.sorted { $0.created > $1.created }
        case .modified: list.sorted { $0.modified > $1.modified }
        case .title: list.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }

    func search(_ query: String) -> [SearchResult] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return ((scratchpad.map { [$0] } ?? []) + sorted(notes)).compactMap { note in
            let text = note.text as NSString
            let match = text.range(of: query, options: options)
            let titleMatches = note.title.range(of: query, options: options) != nil
            guard titleMatches || match.location != NSNotFound else { return nil }
            return SearchResult(
                note: note,
                snippet: match.location == NSNotFound ? Self.firstBodyLine(of: note) : Self.snippet(in: text, around: match),
                match: match.location == NSNotFound ? nil : match
            )
        }
    }

    private static func snippet(in text: NSString, around match: NSRange) -> String {
        let line = text.lineRange(for: match)
        var snippet = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        snippet = Self.withoutListMarks(snippet)
        let offset = match.location - line.location
        if offset > 40, let start = snippet.index(snippet.startIndex, offsetBy: offset - 30, limitedBy: snippet.endIndex) {
            snippet = "…" + snippet[start...]
        }
        return snippet
    }

    private static func firstBodyLine(of note: Note) -> String {
        let lines = note.text.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        return lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { withoutListMarks(String($0)) } ?? ""
    }

    /// A line without its heading, quote, bullet or task marks.
    private static func withoutListMarks(_ line: String) -> String {
        var line = line.trimmingCharacters(in: .whitespaces)
        while let first = line.first, "#>-*+ ".contains(first) { line.removeFirst() }
        for box in ["[ ] ", "[x] ", "[X] "] where line.hasPrefix(box) { line.removeFirst(box.count) }
        return line
    }

    // MARK: Pins

    func isPinned(_ note: Note) -> Bool { pinnedPaths.contains(relativePath(of: note.url)) }

    func togglePin(_ note: Note) {
        guard !note.isScratchpad else { return }
        let path = relativePath(of: note.url)
        if pinnedPaths.contains(path) { pinnedPaths.remove(path) } else { pinnedPaths.insert(path) }
        savePins()
    }

    /// Carries a note's pin, cover and icon to its new path.
    private func moveMetadata(from old: URL, to new: URL) {
        let oldPath = relativePath(of: old), newPath = relativePath(of: new)
        if let cover = covers.removeValue(forKey: oldPath) {
            covers[newPath] = cover
            saveCovers()
        }
        if let icon = noteIcons.removeValue(forKey: oldPath) {
            noteIcons[newPath] = icon
            writeMetadata(noteIcons, to: "notes.json")
        }
        guard pinnedPaths.remove(oldPath) != nil else { return }
        pinnedPaths.insert(newPath)
        savePins()
    }

    private func forgetMetadata(of url: URL) {
        let path = relativePath(of: url)
        pinnedPaths.remove(path)
        if covers.removeValue(forKey: path) != nil { saveCovers() }
        if noteIcons.removeValue(forKey: path) != nil { writeMetadata(noteIcons, to: "notes.json") }
    }

    private func savePins() {
        UserDefaults.standard.set(Array(pinnedPaths).sorted(), forKey: Self.pinsKey)
    }

    private func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    // MARK: Covers

    /// Where imported and downloaded cover images are kept.
    var coversDirectory: URL { root.appending(path: ".lotion/covers", directoryHint: .isDirectory) }

    func cover(for note: Note) -> NoteCover? { covers[relativePath(of: note.url)] }

    func setCover(_ cover: NoteCover?, for note: Note) {
        covers[relativePath(of: note.url)] = cover
        saveCovers()
    }

    private func saveCovers() { writeMetadata(covers, to: "covers.json") }

    // MARK: Folder icons

    func icon(for folder: String) -> String { folderIcons[folder] ?? "folder" }

    /// Nil goes back to the plain folder.
    func setIcon(_ symbol: String?, for folder: String) {
        folderIcons[folder] = symbol == "folder" ? nil : symbol
        writeMetadata(folderIcons, to: "folders.json")
    }

    /// The note's chosen symbol, or nil for the default.
    func icon(for note: Note) -> String? { noteIcons[relativePath(of: note.url)] }

    /// Nil goes back to the default.
    func setIcon(_ symbol: String?, for note: Note) {
        noteIcons[relativePath(of: note.url)] = symbol == NoteIcon.default ? nil : symbol
        writeMetadata(noteIcons, to: "notes.json")
    }

    // MARK: Metadata files

    /// The app was called Paper, and kept its metadata in `.paper`; move it
    /// to `.lotion` so covers, icons and the scratchpad come along.
    private static func migrateMetadataFolder(in root: URL) {
        let fm = FileManager.default
        let old = root.appending(path: ".paper", directoryHint: .isDirectory)
        let new = root.appending(path: ".lotion", directoryHint: .isDirectory)
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }

    private static func readMetadata<T: Decodable>(_ name: String, in root: URL) -> T? {
        guard let data = try? Data(contentsOf: root.appending(path: ".lotion/\(name)")) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func writeMetadata<T: Encodable>(_ value: T, to name: String) {
        let directory = root.appending(path: ".lotion", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(value).write(to: directory.appending(path: name), options: .atomic)
    }

    // MARK: Notes

    func directory(for folder: String?) -> URL {
        folder.map { root.appending(path: $0, directoryHint: .isDirectory) } ?? root
    }

    /// The Markdown file of a note folder: the one named after the folder.
    static func noteFile(inBundle directory: URL) -> URL? {
        let name = directory.lastPathComponent
        let fm = FileManager.default
        for ext in ["md", "markdown"] {
            let file = directory.appending(path: name).appendingPathExtension(ext)
            if fm.fileExists(atPath: file.path) { return file }
        }
        return nil
    }

    /// Whether the note lives in a folder of its own, with its attachments.
    func isBundle(_ note: Note) -> Bool {
        note.url.deletingLastPathComponent().standardizedFileURL != directory(for: note.folder).standardizedFileURL
    }

    /// What moves, renames and goes to the Trash for a note: its folder, or its lone file.
    private func item(of note: Note) -> URL {
        isBundle(note) ? note.url.deletingLastPathComponent() : note.url
    }

    /// Creates a note — a folder holding its Markdown — whose first line is an empty title.
    func createNote(in folder: String?) -> Note? {
        let text = "# "
        let parent = directory(for: folder)
        let bundle = uniqueURL(in: parent, base: "Untitled", ext: nil)
        let url = bundle.appending(path: bundle.lastPathComponent).appendingPathExtension("md")
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "The note could not be created. \(error.localizedDescription)"
            return nil
        }
        let note = Note(url: url, folder: folder, text: text, created: .now, modified: .now)
        notes.append(note)
        return note
    }

    func update(_ note: Note, text: String) {
        note.setText(text)
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = Task { [weak self, weak note] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, let self, let note else { return }
            self.save(note)
        }
    }

    /// Writes the note if it changed, then renames its file after its title.
    func save(_ note: Note) {
        saveTasks[note.id] = nil
        guard note.isDirty || !FileManager.default.fileExists(atPath: note.url.path) else { return }
        let text = note.text
        do {
            try text.write(to: note.url, atomically: true, encoding: .utf8)
            // An atomic write replaces the file; keep its original creation date.
            try? FileManager.default.setAttributes([.creationDate: note.created], ofItemAtPath: note.url.path)
            note.savedText = text
            note.modified = .now
        } catch {
            errorMessage = "“\(note.displayTitle)” could not be saved. \(error.localizedDescription)"
            return
        }
        if !note.isScratchpad { renameToMatchTitle(note) }
    }

    func saveAll() {
        for note in notes where note.isDirty { save(note) }
        if let scratchpad, scratchpad.isDirty { save(scratchpad) }
    }

    private func renameToMatchTitle(_ note: Note) {
        let base = Self.fileBaseName(for: note.title)
        let current = note.url.deletingPathExtension().lastPathComponent
        if current == base { return }
        // "Ideas 2" already belongs to a note titled "Ideas".
        if current.hasPrefix(base + " "), Int(current.dropFirst(base.count + 1)) != nil { return }
        let ext = note.url.pathExtension.isEmpty ? "md" : note.url.pathExtension
        if isBundle(note) {
            let bundle = note.url.deletingLastPathComponent()
            let newBundle = uniqueURL(in: bundle.deletingLastPathComponent(), base: base, ext: nil, ignoring: bundle)
            relocate(note, bundleTo: newBundle, ext: ext)
        } else {
            let destination = uniqueURL(in: note.url.deletingLastPathComponent(), base: base, ext: ext, ignoring: note.url)
            relocate(note, fileTo: destination)
        }
    }

    /// Moves a file or folder, tolerating a change of case only.
    private func moveItem(at source: URL, to destination: URL) throws {
        let fm = FileManager.default
        if source.path.lowercased() == destination.path.lowercased() {
            let temporary = source.deletingLastPathComponent().appending(path: ".lotion-\(UUID().uuidString)")
            try fm.moveItem(at: source, to: temporary)
            try fm.moveItem(at: temporary, to: destination)
        } else {
            try fm.moveItem(at: source, to: destination)
        }
    }

    private func relocate(_ note: Note, fileTo destination: URL) {
        do {
            try moveItem(at: note.url, to: destination)
        } catch {
            errorMessage = "“\(note.displayTitle)” could not be renamed. \(error.localizedDescription)"
            return
        }
        moveMetadata(from: note.url, to: destination)
        note.url = destination
    }

    /// Moves a note's folder to `newBundle`, and names its Markdown after it.
    private func relocate(_ note: Note, bundleTo newBundle: URL, ext: String) {
        let bundle = note.url.deletingLastPathComponent()
        let finalFile = newBundle.appending(path: newBundle.lastPathComponent).appendingPathExtension(ext)
        do {
            try moveItem(at: bundle, to: newBundle)
            let moved = newBundle.appending(path: note.url.lastPathComponent)
            if moved.lastPathComponent != finalFile.lastPathComponent { try moveItem(at: moved, to: finalFile) }
        } catch {
            errorMessage = "“\(note.displayTitle)” could not be renamed. \(error.localizedDescription)"
            return
        }
        moveMetadata(from: note.url, to: finalFile)
        note.url = finalFile
    }

    func move(_ note: Note, toFolder folder: String?) {
        guard note.folder != folder, !note.isScratchpad else { return }
        if note.isDirty { save(note) }
        let ext = note.url.pathExtension.isEmpty ? "md" : note.url.pathExtension
        let base = note.url.deletingPathExtension().lastPathComponent
        if isBundle(note) {
            let destination = uniqueURL(in: directory(for: folder), base: base, ext: nil)
            let old = note.url
            relocate(note, bundleTo: destination, ext: ext)
            if note.url != old { note.folder = folder }
        } else {
            let destination = uniqueURL(in: directory(for: folder), base: base, ext: ext)
            relocate(note, fileTo: destination)
            if note.url == destination { note.folder = folder }
        }
    }

    // MARK: Attachments

    /// The folder a note's files go in. A note that is a lone file becomes
    /// a folder holding it first. Nil if that fails.
    func attachmentDirectory(for note: Note) -> URL? {
        if isBundle(note) { return note.url.deletingLastPathComponent() }
        if note.isDirty { save(note) }
        let base = note.url.deletingPathExtension().lastPathComponent
        let ext = note.url.pathExtension.isEmpty ? "md" : note.url.pathExtension
        let bundle = uniqueURL(in: note.url.deletingLastPathComponent(), base: base, ext: nil)
        let file = bundle.appending(path: bundle.lastPathComponent).appendingPathExtension(ext)
        do {
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: false)
            try FileManager.default.moveItem(at: note.url, to: file)
        } catch {
            errorMessage = "“\(note.displayTitle)” could not get a folder for its files. \(error.localizedDescription)"
            return nil
        }
        moveMetadata(from: note.url, to: file)
        note.url = file
        return bundle
    }

    /// Where remote images and videos a note shows are kept once fetched: a hidden
    /// folder inside the note's folder, or the library's own for a note that is a lone file.
    func mediaCache(for note: Note) -> URL {
        isBundle(note)
            ? note.url.deletingLastPathComponent().appending(path: ".cache", directoryHint: .isDirectory)
            : root.appending(path: ".lotion/cache", directoryHint: .isDirectory)
    }

    /// Copies a file into the note's folder. Returns its link, relative to the note.
    func addAttachment(copying source: URL, to note: Note) -> String? {
        guard let directory = attachmentDirectory(for: note) else { return nil }
        let ext = source.pathExtension.lowercased()
        let base = Self.attachmentName(source.deletingPathExtension().lastPathComponent)
        let destination = uniqueAttachmentURL(in: directory, base: base, ext: ext)
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            errorMessage = "“\(source.lastPathComponent)” could not be added. \(error.localizedDescription)"
            return nil
        }
        return destination.lastPathComponent
    }

    /// Writes data (a pasted image) into the note's folder. Returns its link.
    func addAttachment(data: Data, name: String, ext: String, to note: Note) -> String? {
        guard let directory = attachmentDirectory(for: note) else { return nil }
        let destination = uniqueAttachmentURL(in: directory, base: Self.attachmentName(name), ext: ext)
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            errorMessage = "The image could not be saved. \(error.localizedDescription)"
            return nil
        }
        return destination.lastPathComponent
    }

    /// A file name that reads well in a Markdown link: no spaces or brackets.
    static func attachmentName(_ name: String) -> String {
        let cleaned = name.map { "/\\:()[]<> ".contains($0) ? "-" : $0 }
        var result = String(cleaned)
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return result.isEmpty ? "file" : String(result.prefix(80))
    }

    private func uniqueAttachmentURL(in directory: URL, base: String, ext: String) -> URL {
        var index = 1
        while true {
            let name = index == 1 ? base : "\(base)-\(index)"
            let url = directory.appending(path: name).appendingPathExtension(ext)
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }

    /// Moves a note to the Trash.
    func delete(_ note: Note) {
        guard !note.isScratchpad else { return }
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = nil
        do {
            try FileManager.default.trashItem(at: item(of: note), resultingItemURL: nil)
        } catch {
            errorMessage = "“\(note.displayTitle)” could not be moved to the Trash. \(error.localizedDescription)"
            return
        }
        forgetMetadata(of: note.url)
        savePins()
        notes.removeAll { $0 === note }
    }

    /// Removes a note that was never written to, without a trip to the Trash.
    func discardIfBlank(_ note: Note) {
        guard note.isBlank, notes.contains(where: { $0 === note }) else { return }
        saveTasks[note.id]?.cancel()
        saveTasks[note.id] = nil
        try? FileManager.default.removeItem(at: item(of: note))
        forgetMetadata(of: note.url)
        savePins()
        notes.removeAll { $0 === note }
    }

    // MARK: Folders

    func count(in folder: String) -> Int {
        notes.reduce(0) { $0 + ($1.folder == folder && !isPinned($1) ? 1 : 0) }
    }

    func createFolder() -> String? {
        let url = uniqueURL(in: root, base: "New Folder", ext: nil)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        } catch {
            errorMessage = "The folder could not be created. \(error.localizedDescription)"
            return nil
        }
        let name = url.lastPathComponent
        folders.append(name)
        folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return name
    }

    /// Renames a folder; returns the name it ended up with.
    @discardableResult
    func renameFolder(_ name: String, to proposed: String) -> String {
        let newName = Self.fileBaseName(for: proposed, fallback: name)
        guard newName != name else { return name }
        let source = directory(for: name)
        let destination = uniqueURL(in: root, base: newName, ext: nil, ignoring: source)
        let fm = FileManager.default
        do {
            if source.path.lowercased() == destination.path.lowercased() {
                let temporary = root.appending(path: ".lotion-\(UUID().uuidString)")
                try fm.moveItem(at: source, to: temporary)
                try fm.moveItem(at: temporary, to: destination)
            } else {
                try fm.moveItem(at: source, to: destination)
            }
        } catch {
            errorMessage = "The folder could not be renamed. \(error.localizedDescription)"
            return name
        }
        let finalName = destination.lastPathComponent
        if let icon = folderIcons.removeValue(forKey: name) {
            folderIcons[finalName] = icon
            writeMetadata(folderIcons, to: "folders.json")
        }
        let oldPrefix = source.standardizedFileURL.path + "/"
        for note in notes where note.folder == name {
            let inside = String(note.url.standardizedFileURL.path.dropFirst(oldPrefix.count))
            let newURL = destination.appending(path: inside)
            moveMetadata(from: note.url, to: newURL)
            note.url = newURL
            note.folder = finalName
        }
        folders = (folders.filter { $0 != name } + [finalName])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return finalName
    }

    /// Moves a folder and every note in it to the Trash.
    func deleteFolder(_ name: String) {
        for note in notes where note.folder == name {
            saveTasks[note.id]?.cancel()
            saveTasks[note.id] = nil
        }
        do {
            try FileManager.default.trashItem(at: directory(for: name), resultingItemURL: nil)
        } catch {
            errorMessage = "The folder could not be moved to the Trash. \(error.localizedDescription)"
            return
        }
        for note in notes where note.folder == name {
            forgetMetadata(of: note.url)
        }
        savePins()
        notes.removeAll { $0.folder == name }
        folders.removeAll { $0 == name }
        if folderIcons.removeValue(forKey: name) != nil { writeMetadata(folderIcons, to: "folders.json") }
    }

    // MARK: Names

    /// A file name for a title: no path separators, no leading dot, not too long.
    static func fileBaseName(for title: String, fallback: String = "Untitled") -> String {
        var name = title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        name = String(name.prefix(80)).trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? fallback : name
    }

    private func uniqueURL(in directory: URL, base: String, ext: String?, ignoring: URL? = nil) -> URL {
        let fm = FileManager.default
        func candidate(_ index: Int) -> URL {
            let name = index == 1 ? base : "\(base) \(index)"
            let url = directory.appending(path: name, directoryHint: ext == nil ? .isDirectory : .notDirectory)
            return ext.map { url.appendingPathExtension($0) } ?? url
        }
        var index = 1
        while true {
            let url = candidate(index)
            let isSelf = ignoring.map { $0.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased() } ?? false
            if isSelf || !fm.fileExists(atPath: url.path) { return url }
            index += 1
        }
    }
}
