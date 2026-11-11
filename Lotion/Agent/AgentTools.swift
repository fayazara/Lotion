//
//  AgentTools.swift
//  Lotion
//
//  The tools the agent (MCP) server offers, and their dispatch. The
//  descriptions are written for the model on the other end: they are the
//  only documentation it gets, so they say how notes are named, where
//  changes land, and what leaves the Mac.
//

import Foundation

enum AgentToolError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): message
        }
    }
}

/// Typed access to a tool's arguments, with errors the model can act on.
struct AgentArguments {
    let raw: JSONValue

    func has(_ key: String) -> Bool { raw[key].map { !$0.isNull } ?? false }

    func string(_ key: String) throws -> String {
        guard let value = raw[key]?.stringValue, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AgentToolError.message("Missing required string argument \"\(key)\".")
        }
        return value
    }

    func optionalString(_ key: String) -> String? { raw[key]?.stringValue }

    func optionalDouble(_ key: String) -> Double? { raw[key]?.doubleValue }

    func int(_ key: String, default defaultValue: Int) -> Int { raw[key]?.intValue ?? defaultValue }

    func bool(_ key: String) throws -> Bool {
        guard let value = raw[key]?.boolValue else {
            throw AgentToolError.message("Missing required boolean argument \"\(key)\".")
        }
        return value
    }

    func bool(_ key: String, default defaultValue: Bool) -> Bool { raw[key]?.boolValue ?? defaultValue }

    func array(_ key: String) throws -> [JSONValue] {
        guard let value = raw[key]?.arrayValue, !value.isEmpty else {
            throw AgentToolError.message("Missing required array argument \"\(key)\".")
        }
        return value
    }
}

@MainActor
enum AgentTools {
    static let instructions = """
    Lotion is a native macOS notes app. Every note is a plain Markdown file in the user's library; \
    folders are one level deep. These tools read and change the library live: the Lotion window \
    updates as you work, and an open note shows your edits right away.

    Notes are named by the `note` argument, which takes a note's id (from any listing; ids last \
    while Lotion runs), its path relative to the library (e.g. "Work/Plan/Plan.md"), its exact \
    title when only one note has it, or "scratchpad". A note's title is its first line, and its \
    file is renamed to match whenever it is saved, so paths change with titles: use the id or \
    the path a tool returns.

    Start with get_library (folders, pinned notes, what's open) or search_notes. Read with \
    get_note before editing; prefer edit_note's find-and-replace for small changes over \
    rewriting the whole note with update_note. Lotion's Markdown supports headings, lists, \
    `- [ ]` checklists, quotes, tables, fenced code (```mermaid draws diagrams), images and \
    files beside the note (add them with add_attachment), a link alone on a line (shown as a \
    card or embed), `![[Other note]]` to embed another note, and `[TOC]`.

    Deleting moves notes and folders to the macOS Trash. Publishing (publish_note) puts a note \
    on the public web through the user's own Lotion Share worker on Cloudflare; only do it when \
    the user asks. Check cloud_status first: publishing needs a connected worker.
    """

    static var definitions: [JSONValue] {
        [
            // MARK: Library
            tool(
                "get_library",
                title: "Get library",
                description: "An overview of the library: where it is on disk, its folders (with icons and note counts), pinned notes, the note open in the window, the scratchpad's entry count, how notes are sorted, and whether a cloud worker is connected.",
                properties: [:],
                readOnly: true
            ),
            tool(
                "list_notes",
                title: "List notes",
                description: "Lists notes with their ids, titles, paths, folders, pin state, icons, dates and published URLs, sorted like the sidebar. Does not include the scratchpad.",
                properties: [
                    "folder": ["type": "string", "description": "Only notes in this folder. Pass \"\" for notes at the top of the library, outside any folder. Omit for every note."],
                    "pinned_only": ["type": "boolean", "description": "Only pinned notes. Defaults to false."],
                    "sort": ["type": "string", "enum": ["created", "modified", "title"], "description": "Defaults to the sort the user chose in Lotion."],
                    "limit": ["type": "integer", "description": "Most to return. Defaults to 100."],
                ],
                readOnly: true
            ),
            tool(
                "search_notes",
                title: "Search notes",
                description: "Full-text search over every note's title and text, the scratchpad included (case- and diacritic-insensitive). Returns each match with a snippet around the first hit.",
                properties: [
                    "query": ["type": "string", "description": "Text to look for."],
                    "limit": ["type": "integer", "description": "Most to return. Defaults to 25."],
                ],
                required: ["query"],
                readOnly: true
            ),
            tool(
                "get_note",
                title: "Get note",
                description: "One note's full Markdown and its details: title, path, folder, pin state, icon, cover, where it's published, and the files beside it (attachments it can link to by name).",
                properties: ["note": noteProperty],
                required: ["note"],
                readOnly: true
            ),
            tool(
                "create_note",
                title: "Create note",
                description: "Creates a note from Markdown. Its first line becomes its title (start with `# Title`). Returns the new note.",
                properties: [
                    "markdown": ["type": "string", "description": "The note's text. Must not be empty."],
                    "folder": ["type": "string", "description": "Folder to put it in; created if it doesn't exist. Omit or pass \"\" for the top of the library."],
                    "open": ["type": "boolean", "description": "Show it in the Lotion window. Defaults to false."],
                ],
                required: ["markdown"]
            ),
            tool(
                "update_note",
                title: "Update note",
                description: "Replaces a note's whole Markdown, or appends to it. Changing the first line renames the note.",
                properties: [
                    "note": noteProperty,
                    "markdown": ["type": "string", "description": "The new text, or the text to add."],
                    "mode": ["type": "string", "enum": ["replace", "append"], "description": "\"replace\" (default) swaps the whole note; \"append\" adds a new paragraph at the end."],
                ],
                required: ["note", "markdown"],
                destructive: true
            ),
            tool(
                "edit_note",
                title: "Edit note",
                description: "Find-and-replace edits on a note's Markdown, applied in order, all or none. Each `find` must match exactly once unless `all` is true. Use an empty `replace` to delete text.",
                properties: [
                    "note": noteProperty,
                    "edits": [
                        "type": "array",
                        "items": [
                            "type": "object",
                            "properties": [
                                "find": ["type": "string", "description": "Exact text to find, copied from get_note."],
                                "replace": ["type": "string", "description": "What to put in its place."],
                                "all": ["type": "boolean", "description": "Replace every match. Defaults to false."],
                            ],
                            "required": ["find", "replace"],
                        ],
                    ],
                ],
                required: ["note", "edits"]
            ),
            tool(
                "delete_note",
                title: "Delete note",
                description: "Moves a note, and its folder of attachments, to the macOS Trash. A published page stays up until unpublished.",
                properties: ["note": noteProperty],
                required: ["note"],
                destructive: true
            ),
            tool(
                "move_note",
                title: "Move note",
                description: "Moves a note to another folder, with its attachments, pin, icon and cover. The folder is created if it doesn't exist.",
                properties: [
                    "note": noteProperty,
                    "folder": ["type": "string", "description": "Destination folder, or \"\" for the top of the library."],
                ],
                required: ["note", "folder"]
            ),
            tool(
                "set_note_pinned",
                title: "Pin or unpin note",
                description: "Pins a note to the top of the sidebar, or unpins it.",
                properties: [
                    "note": noteProperty,
                    "pinned": ["type": "boolean"],
                ],
                required: ["note", "pinned"],
                idempotent: true
            ),
            tool(
                "set_note_icon",
                title: "Set note icon",
                description: "Sets the icon shown beside a note's title and in the sidebar: any SF Symbol name, such as \"lightbulb\", \"book\", \"checklist\", \"briefcase\", \"star\", \"calendar\", \"terminal\" or \"leaf\". Pass null or \"\" for the default.",
                properties: [
                    "note": noteProperty,
                    "icon": ["type": ["string", "null"], "description": "SF Symbol name."],
                ],
                required: ["note"],
                idempotent: true
            ),
            tool(
                "set_note_cover",
                title: "Set note cover",
                description: "Sets the wide image at the top of a note. Give exactly one source, or only `position` to move the current cover. Wallpaper names are listed by get_settings.",
                properties: [
                    "note": noteProperty,
                    "remove": ["type": "boolean", "description": "Remove the cover."],
                    "random": ["type": "boolean", "description": "Use a random macOS wallpaper."],
                    "wallpaper": ["type": "string", "description": "A macOS wallpaper, by name."],
                    "image_url": ["type": "string", "description": "An https URL of an image to download."],
                    "image_base64": ["type": "string", "description": "Image bytes, base64-encoded. Give `extension` too."],
                    "extension": ["type": "string", "description": "File extension for image_base64, such as \"png\" or \"jpg\"."],
                    "position": ["type": "number", "description": "Which part of the image shows: 0 is its top edge, 1 its bottom. Defaults to 0.5."],
                    "credit": ["type": "string", "description": "Photographer or source, shown on the cover."],
                    "credit_url": ["type": "string", "description": "Link for the credit."],
                ],
                required: ["note"],
                openWorld: true
            ),
            tool(
                "add_attachment",
                title: "Add attachment",
                description: "Saves a file (image, video, audio, PDF or anything else) into the note's own folder, from base64 bytes or a URL, and by default adds it to the end of the note. Returns the relative link and the Markdown that shows it, so you can place it yourself with insert: false and edit_note.",
                properties: [
                    "note": noteProperty,
                    "file_name": ["type": "string", "description": "Name with extension, such as \"diagram.png\". Made safe and unique."],
                    "data_base64": ["type": "string", "description": "The file's bytes, base64-encoded."],
                    "url": ["type": "string", "description": "An http(s) URL to download instead."],
                    "insert": ["type": "boolean", "description": "Append the file to the note. Defaults to true."],
                    "alt": ["type": "string", "description": "Alt text or link text."],
                ],
                required: ["note", "file_name"],
                openWorld: true
            ),
            tool(
                "get_attachment",
                title: "Get attachment",
                description: "Reads a file beside a note, by the name get_note lists: images come back as images, text files as text, anything else as its size and type.",
                properties: [
                    "note": noteProperty,
                    "file": ["type": "string", "description": "File name, relative to the note."],
                ],
                required: ["note", "file"],
                readOnly: true
            ),
            tool(
                "open_note",
                title: "Open note",
                description: "Shows a note in the Lotion window, for the user to read or keep writing.",
                properties: [
                    "note": noteProperty,
                    "activate": ["type": "boolean", "description": "Bring Lotion to the front. Defaults to true."],
                ],
                required: ["note"],
                idempotent: true
            ),

            // MARK: Scratchpad
            tool(
                "get_scratchpad",
                title: "Get scratchpad",
                description: "The scratchpad: one endless page of dated entries at the top of the sidebar, for quick thoughts. Returns its entries in page order with their dates.",
                properties: [
                    "limit": ["type": "integer", "description": "Only the last this many entries. Defaults to all."],
                ],
                readOnly: true
            ),
            tool(
                "add_scratchpad_entry",
                title: "Add scratchpad entry",
                description: "Adds a dated entry to the end of the scratchpad.",
                properties: ["markdown": ["type": "string", "description": "The entry's text."]],
                required: ["markdown"]
            ),

            // MARK: Folders
            tool(
                "create_folder",
                title: "Create folder",
                description: "Creates a folder at the top of the library. Folders are one level deep. Returns the name it got (made unique and file-safe).",
                properties: [
                    "name": ["type": "string"],
                    "icon": ["type": "string", "description": "SF Symbol name for the folder. Defaults to \"folder\"."],
                ],
                required: ["name"]
            ),
            tool(
                "rename_folder",
                title: "Rename folder",
                description: "Renames a folder. Its notes keep their pins, icons, covers and publications.",
                properties: [
                    "folder": ["type": "string"],
                    "name": ["type": "string", "description": "The new name."],
                ],
                required: ["folder", "name"]
            ),
            tool(
                "delete_folder",
                title: "Delete folder",
                description: "Moves a folder and every note in it to the macOS Trash.",
                properties: ["folder": ["type": "string"]],
                required: ["folder"],
                destructive: true
            ),
            tool(
                "set_folder_icon",
                title: "Set folder icon",
                description: "Sets a folder's sidebar icon to any SF Symbol name. Pass null or \"\" for the plain folder.",
                properties: [
                    "folder": ["type": "string"],
                    "icon": ["type": ["string", "null"]],
                ],
                required: ["folder"],
                idempotent: true
            ),

            // MARK: Cloud
            tool(
                "cloud_status",
                title: "Cloud status",
                description: "Whether a Lotion Share worker (the user's own Cloudflare Worker for publishing notes) is connected, and if so its address, version, how many notes it serves, and whether it needs updating.",
                properties: [:],
                readOnly: true,
                openWorld: true
            ),
            tool(
                "connect_cloud",
                title: "Connect cloud",
                description: "Connects Lotion to a deployed Lotion Share worker: checks the URL and token against it, then saves the URL in Lotion's settings and the token in the Keychain. Use after deploying github.com/fayazara/lotion-share for the user.",
                properties: [
                    "url": ["type": "string", "description": "The worker's URL, such as https://lotion-share.you.workers.dev."],
                    "token": ["type": "string", "description": "The worker's shared token."],
                ],
                required: ["url", "token"],
                openWorld: true
            ),
            tool(
                "list_published",
                title: "List published notes",
                description: "Every page on the connected worker, with its public URL and last update, and which local note it came from (if that note still exists).",
                properties: [:],
                readOnly: true,
                openWorld: true
            ),
            tool(
                "publish_note",
                title: "Publish note",
                description: "Publishes a note as a public web page on the user's worker, or updates its page if it's already published (the URL stays the same). Its images and files are uploaded with it, and the page takes the note's cover, icon and theme colors. Returns the URL. Only when the user asks.",
                properties: ["note": noteProperty],
                required: ["note"],
                openWorld: true
            ),
            tool(
                "unpublish_note",
                title: "Unpublish note",
                description: "Takes a published page down from the worker. Give the note, or the publication id from list_published for a page whose note was deleted.",
                properties: [
                    "note": noteProperty,
                    "id": ["type": "string", "description": "Publication id from list_published."],
                ],
                destructive: true,
                openWorld: true
            ),

            // MARK: Settings
            tool(
                "get_settings",
                title: "Get settings",
                description: "Lotion's current settings (theme, appearance, fonts, layout, editor mode, sort and more) and the values each one accepts, plus the macOS wallpaper names set_note_cover takes.",
                properties: [:],
                readOnly: true
            ),
            tool(
                "update_settings",
                title: "Update settings",
                description: "Changes any of Lotion's settings; the window restyles live. Pass only the keys to change, with values from get_settings.",
                properties: [
                    "theme": ["type": "string"],
                    "appearance": ["type": "string", "enum": ["system", "light", "dark"]],
                    "note_font": ["type": "string"],
                    "code_font": ["type": "string"],
                    "interface_font": ["type": "string"],
                    "note_font_size": ["type": "number"],
                    "line_spacing": ["type": "string", "enum": .array(LineSpacing.allCases.map { .string($0.rawValue) })],
                    "readable_width": ["type": "string", "enum": .array(ReadableWidth.allCases.map { .string($0.rawValue) })],
                    "table_width": ["type": "string", "enum": .array(TableWidth.allCases.map { .string($0.rawValue) })],
                    "editor_mode": ["type": "string", "enum": ["blocks", "markdown"]],
                    "sort": ["type": "string", "enum": .array(NoteSort.allCases.map { .string($0.rawValue) })],
                    "spell_check": ["type": "boolean"],
                    "link_previews": ["type": "boolean"],
                    "save_videos": ["type": "boolean"],
                    "inspector_visible": ["type": "boolean"],
                ],
                idempotent: true
            ),
        ]
    }

    static func call(_ name: String, arguments: AgentArguments) async throws -> [JSONValue] {
        let handlers = try AgentHandlers()
        switch name {
        case "get_library": return try handlers.getLibrary()
        case "list_notes": return try handlers.listNotes(arguments)
        case "search_notes": return try handlers.searchNotes(arguments)
        case "get_note": return try handlers.getNote(arguments)
        case "create_note": return try handlers.createNote(arguments)
        case "update_note": return try handlers.updateNote(arguments)
        case "edit_note": return try handlers.editNote(arguments)
        case "delete_note": return try handlers.deleteNote(arguments)
        case "move_note": return try handlers.moveNote(arguments)
        case "set_note_pinned": return try handlers.setPinned(arguments)
        case "set_note_icon": return try handlers.setNoteIcon(arguments)
        case "set_note_cover": return try await handlers.setCover(arguments)
        case "add_attachment": return try await handlers.addAttachment(arguments)
        case "get_attachment": return try handlers.getAttachment(arguments)
        case "open_note": return try handlers.openNote(arguments)
        case "get_scratchpad": return try handlers.getScratchpad(arguments)
        case "add_scratchpad_entry": return try handlers.addScratchpadEntry(arguments)
        case "create_folder": return try handlers.createFolder(arguments)
        case "rename_folder": return try handlers.renameFolder(arguments)
        case "delete_folder": return try handlers.deleteFolder(arguments)
        case "set_folder_icon": return try handlers.setFolderIcon(arguments)
        case "cloud_status": return try await handlers.cloudStatus()
        case "connect_cloud": return try await handlers.connectCloud(arguments)
        case "list_published": return try await handlers.listPublished()
        case "publish_note": return try await handlers.publish(arguments)
        case "unpublish_note": return try await handlers.unpublish(arguments)
        case "get_settings": return handlers.getSettings()
        case "update_settings": return try handlers.updateSettings(arguments)
        default: throw AgentToolError.message("Unknown tool \"\(name)\".")
        }
    }

    // MARK: Schema helpers

    static let noteProperty: JSONValue = [
        "type": "string",
        "description": "The note's id, its path relative to the library, its exact title, or \"scratchpad\".",
    ]

    private static func tool(
        _ name: String,
        title: String,
        description: String,
        properties: [String: JSONValue],
        required: [String] = [],
        readOnly: Bool = false,
        destructive: Bool = false,
        idempotent: Bool = false,
        openWorld: Bool = false
    ) -> JSONValue {
        var schema: [String: JSONValue] = ["type": "object", "properties": .object(properties)]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return [
            "name": .string(name),
            "title": .string(title),
            "description": .string(description),
            "inputSchema": .object(schema),
            "annotations": [
                "title": .string(title),
                "readOnlyHint": .bool(readOnly),
                "destructiveHint": .bool(destructive),
                "idempotentHint": .bool(readOnly || idempotent),
                "openWorldHint": .bool(openWorld),
            ],
        ]
    }

    // MARK: Content helpers

    static func text(_ string: String) -> JSONValue {
        ["type": "text", "text": .string(string)]
    }

    static func json(_ value: JSONValue) -> JSONValue {
        text(value.compactString)
    }

    static func image(_ data: Data, mimeType: String) -> JSONValue {
        ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": .string(mimeType)]
    }
}
