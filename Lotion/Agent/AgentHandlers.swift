//
//  AgentHandlers.swift
//  Lotion
//
//  What each agent tool does. Everything goes through the window's
//  `AppState` and its `Library`, the same calls the menus and sidebar make,
//  so the window follows along and an open note reloads when an agent
//  changes it. Every change is saved to disk before the tool returns.
//

import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
struct AgentHandlers {
    let state: AppState
    var library: Library { state.library }

    init() throws {
        guard let state = AgentServer.shared.state else {
            throw AgentToolError.message("Lotion is still starting. Try again in a moment.")
        }
        self.state = state
    }

    // MARK: - Library

    func getLibrary() throws -> [JSONValue] {
        library.refreshFromDisk()
        let folders: [JSONValue] = library.folders.map { folder in
            [
                "name": .string(folder),
                "icon": .string(library.icon(for: folder)),
                "notes": .number(Double(library.notes.filter { $0.folder == folder }.count)),
            ]
        }
        return [AgentTools.json([
            "root": .string(library.root.path),
            "notes": .number(Double(library.notes.count)),
            "topLevelNotes": .number(Double(library.notes.filter { $0.folder == nil }.count)),
            "folders": .array(folders),
            "pinned": .array(library.pinnedNotes.map(summary)),
            "open": state.selectedNote.map(summary) ?? .null,
            "scratchpadEntries": .number(Double(library.scratchpad?.entryCount ?? 0)),
            "sort": .string(library.sort.rawValue),
            "cloudConnected": .bool(CloudSettings.isConfigured),
        ])]
    }

    func listNotes(_ args: AgentArguments) throws -> [JSONValue] {
        library.refreshFromDisk()
        var notes = library.notes
        if let raw = args.optionalString("folder") {
            let folder = try existingFolder(raw)
            notes = notes.filter { $0.folder == folder }
        }
        if args.bool("pinned_only", default: false) {
            notes = notes.filter(library.isPinned)
        }
        let sort = try args.optionalString("sort").map { raw in
            guard let sort = NoteSort(rawValue: raw) else {
                throw AgentToolError.message("\"sort\" must be created, modified or title.")
            }
            return sort
        } ?? library.sort
        notes = sorted(notes, by: sort)
        let limit = max(1, args.int("limit", default: 100))
        return [AgentTools.json([
            "total": .number(Double(notes.count)),
            "notes": .array(notes.prefix(limit).map(summary)),
        ])]
    }

    func searchNotes(_ args: AgentArguments) throws -> [JSONValue] {
        library.refreshFromDisk()
        let query = try args.string("query")
        let limit = max(1, args.int("limit", default: 25))
        let results = library.search(query)
        let matches: [JSONValue] = results.prefix(limit).map { result in
            var item = summary(result.note).objectValue ?? [:]
            item["snippet"] = .string(result.snippet)
            return .object(item)
        }
        return [AgentTools.json(["total": .number(Double(results.count)), "results": .array(matches)])]
    }

    func getNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        var details = summary(note).objectValue ?? [:]
        details["file"] = .string(note.url.path)
        details["markdown"] = .string(note.text)
        if let cover = library.cover(for: note) {
            details["cover"] = [
                "image": .string(cover.file.hasPrefix("/") ? (cover.file as NSString).lastPathComponent : cover.file),
                "position": .number(cover.position),
                "credit": .optional(cover.credit),
            ]
        }
        if let publication = library.publication(for: note) {
            details["publication"] = [
                "id": .string(publication.id),
                "url": .string(publication.url.absoluteString),
                "published": .date(publication.published),
            ]
        }
        details["attachments"] = .array(attachments(of: note))
        return [AgentTools.json(.object(details))]
    }

    // MARK: - Writing notes

    func createNote(_ args: AgentArguments) throws -> [JSONValue] {
        let markdown = try args.string("markdown")
        let folder = try destinationFolder(args.optionalString("folder"))
        let note = try checked { library.createNote(in: folder) }
        try write(note, text: markdown)
        if args.bool("open", default: false) { show(note, activate: false) }
        return [AgentTools.json(summary(note))]
    }

    func updateNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        guard let markdown = args.optionalString("markdown") else {
            throw AgentToolError.message("Missing required string argument \"markdown\".")
        }
        let mode = args.optionalString("mode") ?? "replace"
        let text: String
        switch mode {
        case "replace":
            guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw AgentToolError.message("Refusing to empty the note. To remove it, use delete_note.")
            }
            text = markdown
        case "append":
            text = Self.trimmingTrailingNewlines(note.text) + "\n\n" + markdown
        default:
            throw AgentToolError.message("\"mode\" must be \"replace\" or \"append\".")
        }
        try write(note, text: text)
        return [AgentTools.json(summary(note))]
    }

    func editNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        var text = note.text
        var replacements = 0
        for (index, edit) in try args.array("edits").enumerated() {
            guard let find = edit["find"]?.stringValue, !find.isEmpty else {
                throw AgentToolError.message("Edit \(index + 1) needs a non-empty \"find\".")
            }
            guard let replace = edit["replace"]?.stringValue else {
                throw AgentToolError.message("Edit \(index + 1) needs \"replace\" (use \"\" to delete).")
            }
            let count = text.components(separatedBy: find).count - 1
            if count == 0 {
                throw AgentToolError.message("Edit \(index + 1): \"\(find.prefix(80))\" isn't in the note. No edits were made; read it again with get_note.")
            }
            if count > 1, edit["all"]?.boolValue != true {
                throw AgentToolError.message("Edit \(index + 1): the text appears \(count) times. Include more around it, or set \"all\": true. No edits were made.")
            }
            text = text.replacingOccurrences(of: find, with: replace)
            replacements += count
        }
        try write(note, text: text)
        var result = summary(note).objectValue ?? [:]
        result["replacements"] = .number(Double(replacements))
        return [AgentTools.json(.object(result))]
    }

    func deleteNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        try refuseScratchpad(note, "deleted")
        let title = note.displayTitle
        try checked { state.delete(note) }
        guard !library.notes.contains(where: { $0 === note }) else {
            throw AgentToolError.message("“\(title)” could not be moved to the Trash.")
        }
        return [AgentTools.text("Moved “\(title)” to the Trash.")]
    }

    func moveNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        try refuseScratchpad(note, "moved")
        guard let raw = args.optionalString("folder") else {
            throw AgentToolError.message("Missing \"folder\". Pass \"\" for the top of the library.")
        }
        let folder = try destinationFolder(raw)
        try checked { state.move(note, to: folder) }
        return [AgentTools.json(summary(note))]
    }

    func setPinned(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        try refuseScratchpad(note, "pinned")
        if library.isPinned(note) != (try args.bool("pinned")) { state.togglePin(note) }
        return [AgentTools.json(summary(note))]
    }

    func setNoteIcon(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        library.setIcon(try symbol(args.optionalString("icon")), for: note)
        return [AgentTools.json(summary(note))]
    }

    func setCover(_ args: AgentArguments) async throws -> [JSONValue] {
        let note = try resolveNote(args)
        let position = args.optionalDouble("position").map { min(max($0, 0), 1) }
        let credit = args.optionalString("credit")
        let creditURL = args.optionalString("credit_url").flatMap(URL.init(string:))
        let sources = ["remove", "random", "wallpaper", "image_url", "image_base64"].filter(args.has)
        guard sources.count <= 1 else {
            throw AgentToolError.message("Give one cover source, not \(sources.joined(separator: " and ")).")
        }

        switch sources.first {
        case "remove":
            library.setCover(nil, for: note)
            return [AgentTools.text("Removed the cover.")]
        case "random":
            library.addRandomCover(for: note)
        case "wallpaper":
            let name = try args.string("wallpaper")
            guard let wallpaper = SystemWallpapers.all.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw AgentToolError.message("No wallpaper is called “\(name)”. get_settings lists them.")
            }
            library.setCover(NoteCover(file: wallpaper.url.path, credit: credit, creditURL: creditURL), for: note)
        case "image_url":
            let (data, response) = try await download(try args.string("image_url"), maxBytes: 40 << 20)
            let ext = imageExtension(url: response.url, mimeType: response.mimeType)
            try saveCover(data, ext: ext, credit: credit, creditURL: creditURL, for: note)
        case "image_base64":
            guard let data = Data(base64Encoded: try args.string("image_base64"), options: .ignoreUnknownCharacters) else {
                throw AgentToolError.message("\"image_base64\" isn't valid base64.")
            }
            let ext = args.optionalString("extension")?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) ?? "png"
            try saveCover(data, ext: ext, credit: credit, creditURL: creditURL, for: note)
        default:
            guard position != nil else {
                throw AgentToolError.message("Give a cover source (remove, random, wallpaper, image_url or image_base64), or a position.")
            }
            guard library.cover(for: note) != nil else {
                throw AgentToolError.message("The note has no cover to move.")
            }
        }
        if let position, var cover = library.cover(for: note) {
            cover.position = position
            library.setCover(cover, for: note)
        }
        guard let cover = library.cover(for: note) else {
            throw AgentToolError.message("The cover could not be set.")
        }
        return [AgentTools.json([
            "note": summary(note),
            "cover": ["image": .string((cover.file as NSString).lastPathComponent), "position": .number(cover.position)],
        ])]
    }

    // MARK: - Attachments

    func addAttachment(_ args: AgentArguments) async throws -> [JSONValue] {
        let note = try resolveNote(args)
        let fileName = try args.string("file_name")
        let ext = (fileName as NSString).pathExtension.lowercased()
        let base = (fileName as NSString).deletingPathExtension
        guard !ext.isEmpty else {
            throw AgentToolError.message("\"file_name\" needs an extension, such as \"photo.png\".")
        }
        let data: Data
        if args.has("data_base64") {
            guard let decoded = Data(base64Encoded: try args.string("data_base64"), options: .ignoreUnknownCharacters) else {
                throw AgentToolError.message("\"data_base64\" isn't valid base64.")
            }
            data = decoded
        } else if args.has("url") {
            data = try await download(try args.string("url"), maxBytes: 200 << 20).0
        } else {
            throw AgentToolError.message("Give the file as \"data_base64\" or \"url\".")
        }
        let link = try checked { library.addAttachment(data: data, name: base, ext: ext, to: note) }
        let markdown = Self.markdown(forAttachment: link, alt: args.optionalString("alt"))
        if args.bool("insert", default: true) {
            try write(note, text: Self.trimmingTrailingNewlines(note.text) + "\n\n" + markdown + "\n")
        }
        return [AgentTools.json([
            "note": summary(note),
            "link": .string(link),
            "markdown": .string(markdown),
            "bytes": .number(Double(data.count)),
        ])]
    }

    func getAttachment(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        let name = try args.string("file")
        let directory = note.url.deletingLastPathComponent().standardizedFileURL
        let url = directory.appending(path: name.removingPercentEncoding ?? name).standardizedFileURL
        guard url.path.hasPrefix(directory.path + "/") else {
            throw AgentToolError.message("\"file\" must be a file beside the note.")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw AgentToolError.message("There's no file called “\(name)” beside the note. get_note lists its attachments.")
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let type = UTType(filenameExtension: url.pathExtension) ?? .data
        let info: JSONValue = [
            "name": .string(url.lastPathComponent),
            "bytes": .number(Double(size)),
            "type": .string(type.preferredMIMEType ?? type.identifier),
            "file": .string(url.path),
        ]

        if type.conforms(to: .image) {
            // Large photos are scaled down: the model sees them just as well.
            if size <= 3 << 20, let data = try? Data(contentsOf: url), let mime = type.preferredMIMEType,
               ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(mime) {
                return [AgentTools.json(info), AgentTools.image(data, mimeType: mime)]
            }
            if let image = CoverImages.downsample(url, maxPixels: 1600),
               let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
               let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
                return [AgentTools.json(info), AgentTools.image(jpeg, mimeType: "image/jpeg")]
            }
        }
        if type.conforms(to: .text) || type.conforms(to: .sourceCode) || type.conforms(to: .json),
           size <= 1 << 20, let text = try? String(contentsOf: url, encoding: .utf8) {
            return [AgentTools.json(info), AgentTools.text(text)]
        }
        return [AgentTools.json(info)]
    }

    func openNote(_ args: AgentArguments) throws -> [JSONValue] {
        let note = try resolveNote(args)
        show(note, activate: args.bool("activate", default: true))
        return [AgentTools.json(summary(note))]
    }

    // MARK: - Scratchpad

    func getScratchpad(_ args: AgentArguments) throws -> [JSONValue] {
        let scratchpad = try self.scratchpad()
        var entries = Self.entries(in: scratchpad.text)
        if args.has("limit") { entries = Array(entries.suffix(max(1, args.int("limit", default: entries.count)))) }
        return [AgentTools.json([
            "id": .string(scratchpad.id.uuidString),
            "entries": .array(entries.map { ["date": .optional($0.date), "markdown": .string($0.body)] }),
        ])]
    }

    func addScratchpadEntry(_ args: AgentArguments) throws -> [JSONValue] {
        let scratchpad = try self.scratchpad()
        let markdown = try args.string("markdown").trimmingCharacters(in: .newlines)
        var text = Self.trimmingTrailingNewlines(scratchpad.text)
        // An empty last entry (a new scratchpad starts with one) is filled
        // rather than left blank above the new one.
        if let last = text.range(of: BlockMarkdown.entryPrefix, options: .backwards),
           text[last.lowerBound...].split(separator: "\n", maxSplits: 1).count == 1 {
            text = Self.trimmingTrailingNewlines(String(text[..<last.lowerBound]))
        }
        let entry = Library.entryMarker() + "\n\n" + markdown + "\n"
        try write(scratchpad, text: text.isEmpty ? entry : text + "\n\n" + entry)
        return [AgentTools.text("Added an entry to the scratchpad.")]
    }

    // MARK: - Folders

    func createFolder(_ args: AgentArguments) throws -> [JSONValue] {
        let name = try args.string("name")
        if let existing = library.folders.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw AgentToolError.message("There's already a folder called “\(existing)”.")
        }
        let folder = try destinationFolder(name) ?? name
        if args.has("icon") { library.setIcon(try symbol(args.optionalString("icon")), for: folder) }
        return [AgentTools.json(["name": .string(folder), "icon": .string(library.icon(for: folder))])]
    }

    func renameFolder(_ args: AgentArguments) throws -> [JSONValue] {
        let folder = try existingFolder(try args.string("folder"))
        guard let folder else { throw AgentToolError.message("The top of the library can't be renamed.") }
        let proposed = try args.string("name")
        guard !proposed.contains("/") else { throw AgentToolError.message("Folder names can't contain “/”.") }
        let newName = try checked { () -> String? in
            let newName = library.renameFolder(folder, to: proposed)
            if newName != folder, state.expandedFolders.remove(folder) != nil { state.expandedFolders.insert(newName) }
            return newName
        }
        return [AgentTools.json(["name": .string(newName)])]
    }

    func deleteFolder(_ args: AgentArguments) throws -> [JSONValue] {
        let folder = try existingFolder(try args.string("folder"))
        guard let folder else { throw AgentToolError.message("The top of the library can't be deleted.") }
        let count = library.notes.filter { $0.folder == folder }.count
        try checked { state.deleteFolder(folder) }
        guard !library.folders.contains(folder) else {
            throw AgentToolError.message("“\(folder)” could not be moved to the Trash.")
        }
        return [AgentTools.text("Moved “\(folder)” and its \(count == 1 ? "note" : "\(count) notes") to the Trash.")]
    }

    func setFolderIcon(_ args: AgentArguments) throws -> [JSONValue] {
        let folder = try existingFolder(try args.string("folder"))
        guard let folder else { throw AgentToolError.message("Name a folder.") }
        library.setIcon(try symbol(args.optionalString("icon")) ?? "folder", for: folder)
        return [AgentTools.json(["name": .string(folder), "icon": .string(library.icon(for: folder))])]
    }

    // MARK: - Cloud

    func cloudStatus() async throws -> [JSONValue] {
        guard CloudSettings.isConfigured, let url = CloudSettings.workerURL else {
            return [AgentTools.json([
                "connected": false,
                "message": "No Lotion Share worker is connected. The user can set one up from Lotion → Settings → Cloud (Copy Setup Prompt), or you can deploy github.com/fayazara/lotion-share by following its DEPLOY.md and then call connect_cloud with its URL and token.",
            ])]
        }
        let client = try CloudClient.configured()
        async let latest = CloudClient.latestTemplateVersion()
        do {
            let info = try await client.info()
            let latestVersion = await latest
            return [AgentTools.json([
                "connected": true,
                "url": .string(url.absoluteString),
                "version": .string(info.version),
                "apiVersion": .number(Double(info.apiVersion)),
                "publishedNotes": .number(Double(info.notes)),
                "pendingMigrations": .number(Double(info.migrations.pending)),
                "compatible": .bool(info.apiVersion >= CloudSettings.requiredAPIVersion && info.migrations.pending == 0),
                "latestVersion": .optional(latestVersion),
                "updateAvailable": .bool(latestVersion.map { info.version.isOlderVersion(than: $0) } ?? false),
            ])]
        } catch {
            return [AgentTools.json([
                "connected": true,
                "url": .string(url.absoluteString),
                "reachable": false,
                "error": .string(error.localizedDescription),
            ])]
        }
    }

    func connectCloud(_ args: AgentArguments) async throws -> [JSONValue] {
        let raw = try args.string("url")
        guard let url = CloudSettings.normalizedURL(raw) else {
            throw AgentToolError.message("“\(raw)” isn't a web address.")
        }
        let token = try args.string("token").trimmingCharacters(in: .whitespacesAndNewlines)
        let info = try await CloudClient(baseURL: url, token: token).checkCompatible()
        guard Keychain.save(token) else {
            throw AgentToolError.message("The worker answered, but the token couldn't be saved to the Keychain.")
        }
        UserDefaults.standard.set(url.absoluteString, forKey: Prefs.cloudURL)
        return [AgentTools.json([
            "connected": true,
            "url": .string(url.absoluteString),
            "version": .string(info.version),
            "publishedNotes": .number(Double(info.notes)),
        ])]
    }

    func listPublished() async throws -> [JSONValue] {
        let remote = try await CloudClient.configured().notes()
        let local = Dictionary(library.publications.map { ($0.value.id, $0.key) }, uniquingKeysWith: { first, _ in first })
        let items: [JSONValue] = remote.map { page in
            var item: [String: JSONValue] = [
                "id": .string(page.id),
                "title": .string(page.title),
                "url": .string(page.url.absoluteString),
                "updated": .date(page.updatedAt),
            ]
            if let path = local[page.id], let note = library.notes.first(where: { library.relativePath(of: $0.url) == path }) {
                item["note"] = summary(note)
            }
            return .object(item)
        }
        return [AgentTools.json(["pages": .array(items)])]
    }

    func publish(_ args: AgentArguments) async throws -> [JSONValue] {
        let note = try resolveNote(args)
        let wasPublished = library.publication(for: note) != nil
        let theme = LotionTheme(rawValue: UserDefaults.standard.string(forKey: Prefs.theme) ?? "") ?? .paper
        let style = EditorStyle(theme: theme, isDark: false, noteFont: FontChoice.system, noteFontSize: 15,
                                lineSpacing: .comfortable, codeFont: FontChoice.mono, readableWidth: .medium, spellCheck: true)
        let result = try await Publisher.publish(note, library: library, style: style)
        return [AgentTools.json([
            "url": .string(result.publication.url.absoluteString),
            "id": .string(result.publication.id),
            "updated": .bool(wasPublished),
            "missingFiles": .array(result.skipped.map { .string($0) }),
        ])]
    }

    func unpublish(_ args: AgentArguments) async throws -> [JSONValue] {
        if args.has("note") {
            let note = try resolveNote(args)
            guard library.publication(for: note) != nil else {
                throw AgentToolError.message("“\(note.displayTitle)” isn't published.")
            }
            try await Publisher.unpublish(note, library: library)
            return [AgentTools.text("Unpublished “\(note.displayTitle)”.")]
        }
        let id = try args.string("id")
        do {
            try await CloudClient.configured().unpublish(id: id)
        } catch CloudError.server(status: 404, _) {
            // Already gone on the worker.
        }
        library.forgetPublication(id: id)
        return [AgentTools.text("Unpublished \(id).")]
    }

    // MARK: - Settings

    func getSettings() -> [JSONValue] {
        [AgentTools.json([
            "settings": currentSettings(),
            "options": [
                "theme": .array(LotionTheme.allCases.map { theme in
                    ["id": .string(theme.id), "name": .string(theme.name),
                     "modes": .string(theme.light != nil && theme.dark != nil ? "light+dark" : theme.dark != nil ? "dark" : "light")]
                }),
                "appearance": .array(AppearanceMode.allCases.map { .string($0.rawValue) }),
                "fonts": .string("note_font, code_font and interface_font take \(FontChoice.designs.map { "\"\($0.id)\" (\($0.title))" }.joined(separator: ", ")), or the name of any installed font family."),
                "monospacedFamilies": .array(FontChoice.monospacedFamilies.map { .string($0) }),
                "note_font_size": "12 to 24 points",
                "line_spacing": .array(LineSpacing.allCases.map { .string($0.rawValue) }),
                "readable_width": .array(ReadableWidth.allCases.map { .string($0.rawValue) }),
                "table_width": .array(TableWidth.allCases.map { .string($0.rawValue) }),
                "editor_mode": ["blocks", "markdown"],
                "sort": .array(NoteSort.allCases.map { .string($0.rawValue) }),
                "wallpapers": .array(SystemWallpapers.all.map { .string($0.name) }),
            ],
        ])]
    }

    func updateSettings(_ args: AgentArguments) throws -> [JSONValue] {
        guard let changes = args.raw.objectValue, !changes.isEmpty else {
            throw AgentToolError.message("Pass the settings to change, such as {\"theme\": \"nord\"}.")
        }
        let defaults = UserDefaults.standard
        // Checked first, so a bad value changes nothing.
        var apply: [() -> Void] = []
        for (key, value) in changes.sorted(by: { $0.key < $1.key }) {
            func string<T: RawRepresentable<String>>(_ type: T.Type, _ allowed: [String]) throws -> T {
                guard let raw = value.stringValue, let parsed = T(rawValue: raw) else {
                    throw AgentToolError.message("\"\(key)\" must be one of \(allowed.joined(separator: ", ")).")
                }
                return parsed
            }
            func bool() throws -> Bool {
                guard let flag = value.boolValue else { throw AgentToolError.message("\"\(key)\" must be true or false.") }
                return flag
            }
            switch key {
            case "theme":
                let theme = try string(LotionTheme.self, LotionTheme.allCases.map(\.id))
                apply.append { defaults.set(theme.rawValue, forKey: Prefs.theme) }
            case "appearance":
                let mode = try string(AppearanceMode.self, AppearanceMode.allCases.map(\.rawValue))
                apply.append { defaults.set(mode.rawValue, forKey: Prefs.appearance) }
            case "note_font", "code_font", "interface_font":
                let font = try fontChoice(value.stringValue, key: key)
                let pref = key == "note_font" ? Prefs.noteFont : key == "code_font" ? Prefs.codeFont : Prefs.interfaceFont
                apply.append { defaults.set(font, forKey: pref) }
            case "note_font_size":
                guard let size = value.doubleValue, (12...24).contains(size) else {
                    throw AgentToolError.message("\"note_font_size\" must be a number from 12 to 24.")
                }
                apply.append { defaults.set(size.rounded(), forKey: Prefs.noteFontSize) }
            case "line_spacing":
                let spacing = try string(LineSpacing.self, LineSpacing.allCases.map(\.rawValue))
                apply.append { defaults.set(spacing.rawValue, forKey: Prefs.lineSpacing) }
            case "readable_width":
                let width = try string(ReadableWidth.self, ReadableWidth.allCases.map(\.rawValue))
                apply.append { defaults.set(width.rawValue, forKey: Prefs.readableWidth) }
            case "table_width":
                let width = try string(TableWidth.self, TableWidth.allCases.map(\.rawValue))
                apply.append { defaults.set(width.rawValue, forKey: Prefs.tableWidth) }
            case "editor_mode":
                let mode = try string(EditorMode.self, ["blocks", "markdown"])
                apply.append { defaults.set(mode.rawValue, forKey: Prefs.editorMode) }
            case "sort":
                let sort = try string(NoteSort.self, NoteSort.allCases.map(\.rawValue))
                apply.append { library.sort = sort }
            case "spell_check":
                let flag = try bool()
                apply.append { defaults.set(flag, forKey: Prefs.spellCheck) }
            case "link_previews":
                let flag = try bool()
                apply.append { defaults.set(flag, forKey: Prefs.linkPreviews) }
            case "save_videos":
                let flag = try bool()
                apply.append { defaults.set(flag, forKey: Prefs.saveVideos) }
            case "inspector_visible":
                let flag = try bool()
                apply.append { defaults.set(flag, forKey: Prefs.inspectorVisible) }
            default:
                throw AgentToolError.message("Unknown setting \"\(key)\". get_settings lists them.")
            }
        }
        apply.forEach { $0() }
        return [AgentTools.json(currentSettings())]
    }

    private func currentSettings() -> JSONValue {
        let defaults = UserDefaults.standard
        func string(_ key: String, _ fallback: String) -> JSONValue { .string(defaults.string(forKey: key) ?? fallback) }
        func bool(_ key: String, _ fallback: Bool) -> JSONValue { .bool(defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)) }
        return [
            "theme": string(Prefs.theme, LotionTheme.paper.id),
            "appearance": string(Prefs.appearance, AppearanceMode.system.rawValue),
            "note_font": string(Prefs.noteFont, FontChoice.system),
            "code_font": string(Prefs.codeFont, FontChoice.mono),
            "interface_font": string(Prefs.interfaceFont, FontChoice.system),
            "note_font_size": .number(defaults.object(forKey: Prefs.noteFontSize) == nil ? 15 : defaults.double(forKey: Prefs.noteFontSize)),
            "line_spacing": string(Prefs.lineSpacing, LineSpacing.comfortable.rawValue),
            "readable_width": string(Prefs.readableWidth, ReadableWidth.medium.rawValue),
            "table_width": string(Prefs.tableWidth, TableWidth.fit.rawValue),
            "editor_mode": string(Prefs.editorMode, EditorMode.blocks.rawValue),
            "sort": .string(library.sort.rawValue),
            "spell_check": bool(Prefs.spellCheck, true),
            "link_previews": bool(Prefs.linkPreviews, true),
            "save_videos": bool(Prefs.saveVideos, false),
            "inspector_visible": bool(Prefs.inspectorVisible, true),
        ]
    }

    private func fontChoice(_ raw: String?, key: String) throws -> String {
        let name = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if let design = FontChoice.designs.first(where: {
            $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.title.caseInsensitiveCompare(name) == .orderedSame
        }) {
            return design.id
        }
        if let family = FontChoice.installedFamilies.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return family
        }
        throw AgentToolError.message("“\(name)” isn't a font on this Mac. \"\(key)\" takes \(FontChoice.designs.map(\.id).joined(separator: ", ")), or an installed family name.")
    }

    // MARK: - Finding things

    /// A note by id, path, title or "scratchpad". Looks at the disk again
    /// before giving up, in case the note was just written there.
    func resolveNote(_ args: AgentArguments) throws -> Note {
        let raw = try args.string("note").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.caseInsensitiveCompare("scratchpad") == .orderedSame { return try scratchpad() }
        if let note = try findNote(raw) { return note }
        library.refreshFromDisk()
        if let note = try findNote(raw) { return note }
        throw AgentToolError.message("No note matches “\(raw)”. Use an id or path from list_notes or search_notes.")
    }

    private func findNote(_ raw: String) throws -> Note? {
        if let id = UUID(uuidString: raw), let note = library.note(id: id) { return note }
        let path = raw.hasPrefix("/") ? library.relativePath(of: URL(fileURLWithPath: raw)) : raw
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        if let note = library.notes.first(where: {
            let notePath = library.relativePath(of: $0.url)
            // A note's own folder names it too: "Work/Plan" for "Work/Plan/Plan.md".
            return notePath == trimmed || (library.isBundle($0) && (notePath as NSString).deletingLastPathComponent == trimmed)
        }) {
            return note
        }
        let titled = library.notes.filter { $0.displayTitle.caseInsensitiveCompare(raw) == .orderedSame }
        if titled.count > 1 {
            let options = titled.map { "\($0.id.uuidString) (\(library.relativePath(of: $0.url)))" }
            throw AgentToolError.message("\(titled.count) notes are titled “\(raw)”. Pick one by id: \(options.joined(separator: ", ")).")
        }
        return titled.first
    }

    private func scratchpad() throws -> Note {
        guard let scratchpad = library.scratchpad else { throw AgentToolError.message("The scratchpad isn't available.") }
        return scratchpad
    }

    private func refuseScratchpad(_ note: Note, _ verb: String) throws {
        if note.isScratchpad { throw AgentToolError.message("The scratchpad can't be \(verb).") }
    }

    /// An existing folder's name, nil for the top of the library ("").
    private func existingFolder(_ raw: String) throws -> String? {
        let name = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        guard !name.isEmpty else { return nil }
        if let folder = library.folders.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return folder }
        let list = library.folders.isEmpty ? "There are no folders yet." : "Folders: \(library.folders.joined(separator: ", "))."
        throw AgentToolError.message("No folder is called “\(name)”. \(list)")
    }

    /// Where a note should go: nil for the top of the library, otherwise a
    /// folder, made if it doesn't exist.
    private func destinationFolder(_ raw: String?) throws -> String? {
        let name = (raw ?? "").trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "/")))
        guard !name.isEmpty else { return nil }
        if let folder = library.folders.first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { return folder }
        guard !name.contains("/") else {
            throw AgentToolError.message("Folders are one level deep; “\(name)” can't contain “/”.")
        }
        let created = try checked { library.createFolder() }
        return try checked { library.renameFolder(created, to: name) }
    }

    private func symbol(_ raw: String?) throws -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return nil }
        guard NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil else {
            throw AgentToolError.message("“\(name)” isn't an SF Symbol. Try names like \"lightbulb\", \"book\", \"star\" or \"folder\".")
        }
        return name
    }

    // MARK: - Helpers

    func summary(_ note: Note) -> JSONValue {
        var item: [String: JSONValue] = [
            "id": .string(note.id.uuidString),
            "title": .string(note.displayTitle),
            "path": .string(library.relativePath(of: note.url)),
            "folder": .optional(note.folder),
            "pinned": .bool(library.isPinned(note)),
            "created": .date(note.created),
            "modified": .date(note.modified),
        ]
        if note.isScratchpad { item["scratchpad"] = true }
        if let icon = library.icon(for: note) { item["icon"] = .string(icon) }
        if let publication = library.publication(for: note) { item["publishedURL"] = .string(publication.url.absoluteString) }
        return .object(item)
    }

    private func sorted(_ notes: [Note], by sort: NoteSort) -> [Note] {
        switch sort {
        case .created: notes.sorted { $0.created > $1.created }
        case .modified: notes.sorted { $0.modified > $1.modified }
        case .title: notes.sorted { $0.displayTitle.localizedStandardCompare($1.displayTitle) == .orderedAscending }
        }
    }

    /// The files in a note's own folder, which it can link to by name.
    private func attachments(of note: Note) -> [JSONValue] {
        guard library.isBundle(note) else { return [] }
        let directory = note.url.deletingLastPathComponent()
        let items = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { $0.lastPathComponent != note.url.lastPathComponent }
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                [
                    "name": .string(url.lastPathComponent),
                    "bytes": .number(Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)),
                ]
            }
    }

    /// Puts agent-written text in the note and saves it, renaming the file
    /// if the title changed. An editor showing the note reloads it.
    private func write(_ note: Note, text: String) throws {
        note.replaceText(text)
        try checked { library.save(note) }
    }

    /// Runs a library call and turns the alert it would raise into an error
    /// for the agent, without showing the user an alert they didn't cause.
    private func checked<T>(_ body: () -> T?) throws -> T {
        let previous = library.errorMessage
        library.errorMessage = nil
        let result = body()
        let failure = library.errorMessage
        library.errorMessage = previous
        if let failure { throw AgentToolError.message(failure) }
        guard let result else { throw AgentToolError.message("That didn't work, and Lotion gave no reason.") }
        return result
    }

    private func checked(_ body: () -> Void) throws {
        _ = try checked { () -> Bool? in
            body()
            return true
        }
    }

    private func show(_ note: Note, activate: Bool) {
        state.searchText = ""
        if let folder = note.folder { state.expandedFolders.insert(folder) }
        state.selection = note.id
        guard activate else { return }
        NSApp.activate()
        NSApp.windows.first { $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
    }

    private func saveCover(_ data: Data, ext: String, credit: String?, creditURL: URL?, for note: Note) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
            throw AgentToolError.message("That isn't an image Lotion can read.")
        }
        let name = "\(UUID().uuidString).\(ext.isEmpty ? "jpg" : ext)"
        do {
            try FileManager.default.createDirectory(at: library.coversDirectory, withIntermediateDirectories: true)
            try data.write(to: library.coversDirectory.appending(path: name), options: .atomic)
        } catch {
            throw AgentToolError.message("The cover could not be saved. \(error.localizedDescription)")
        }
        library.setCover(NoteCover(file: name, credit: credit, creditURL: creditURL), for: note)
    }

    private func download(_ raw: String, maxBytes: Int) async throws -> (Data, URLResponse) {
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw AgentToolError.message("“\(raw)” isn't an http(s) URL.")
        }
        var request = URLRequest(url: url)
        request.setValue("Lotion", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AgentToolError.message("Downloading \(url.absoluteString) failed with status \(http.statusCode).")
        }
        guard data.count <= maxBytes else {
            throw AgentToolError.message("That file is larger than \(maxBytes >> 20) MB.")
        }
        return (data, response)
    }

    private func imageExtension(url: URL?, mimeType: String?) -> String {
        if let ext = url?.pathExtension.lowercased(), MediaKind.imageExtensions.contains(ext) { return ext }
        if let mimeType, let ext = UTType(mimeType: mimeType)?.preferredFilenameExtension { return ext }
        return "jpg"
    }

    static func markdown(forAttachment link: String, alt: String?) -> String {
        let target = link.contains(" ") ? "<\(link)>" : link
        if MediaKind.of(link) == .unknown {
            let text = (alt?.isEmpty == false ? alt! : link).replacingOccurrences(of: "]", with: "\\]")
            return "[\(text)](\(target))"
        }
        return "![\((alt ?? "").replacingOccurrences(of: "]", with: "\\]"))](\(target))"
    }

    static func trimmingTrailingNewlines(_ text: String) -> String {
        var text = text
        while text.last?.isNewline == true { text.removeLast() }
        return text
    }

    /// The scratchpad's entries: each starts at an entry line with its date.
    static func entries(in text: String) -> [(date: String?, body: String)] {
        var entries: [(date: String?, body: String)] = []
        var date: String?
        var lines: [Substring] = []
        func flush() {
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if date != nil || !body.isEmpty { entries.append((date, body)) }
            lines = []
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(BlockMarkdown.entryPrefix), trimmed.hasSuffix(" -->") {
                flush()
                date = trimmed.dropFirst(BlockMarkdown.entryPrefix.count).dropLast(4).trimmingCharacters(in: .whitespaces)
            } else {
                lines.append(line)
            }
        }
        flush()
        return entries
    }
}
