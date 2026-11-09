//
//  AppState.swift
//  Lotion
//
//  The window's state: which note is open, the sidebar's search and folders,
//  and the actions menus, toolbar and sidebar share.
//

import AppKit
import UniformTypeIdentifiers
import Observation
import SwiftUI

@Observable
final class AppState {
    let library = Library()
    let editor = EditorController()

    var selection: Note.ID? {
        didSet { if oldValue != selection { selectionDidChange(from: oldValue) } }
    }
    var searchText = ""
    /// Bumped to move focus to the sidebar's search field.
    private(set) var searchFocusRequest = 0
    /// The folder whose name is being edited in the sidebar.
    var renamingFolder: String?
    var folderPendingDelete: String?
    var expandedFolders: Set<String> {
        didSet { UserDefaults.standard.set(Array(expandedFolders).sorted(), forKey: Self.expandedKey) }
    }

    private static let expandedKey = "expandedFolders"

    init() {
        expandedFolders = Set(UserDefaults.standard.stringArray(forKey: Self.expandedKey) ?? [])
        library.load()
        if DemoLibrary.isEnabled { Task { [library] in await DemoLibrary.fetchCovers(into: library) } }
        selection = library.pinnedNotes.first?.id ?? library.notes(in: nil).first?.id
        editor.openNote = { [weak self] id in self?.selection = id }
    }

    var selectedNote: Note? { library.note(id: selection) }
    var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespaces).isEmpty }

    private func selectionDidChange(from old: Note.ID?) {
        if let old, let previous = library.note(id: old) {
            if previous.isBlank {
                library.discardIfBlank(previous)
            } else if previous.isDirty {
                library.save(previous)
            }
        }
        // Opening a search result shows the first match.
        if isSearching, let note = selectedNote {
            editor.revealMatch(searchText.trimmingCharacters(in: .whitespaces), in: note)
        }
    }

    func focusSearch() { searchFocusRequest += 1 }

    // MARK: Scratchpad

    var isScratchpadOpen: Bool { selectedNote?.isScratchpad == true }

    func openScratchpad() {
        guard let scratchpad = library.scratchpad else { return }
        searchText = ""
        selection = scratchpad.id
        editor.focus(scratchpad)
    }

    /// Starts a new scratchpad entry after the one being written in,
    /// opening the scratchpad first if another note is showing.
    func newScratchpadEntry() {
        guard let scratchpad = library.scratchpad else { return }
        if selection != scratchpad.id {
            searchText = ""
            selection = scratchpad.id
        }
        editor.newEntry(in: scratchpad)
    }

    // MARK: Notes

    /// New notes go where the open note lives, or into `folder` when given.
    func newNote(inFolder folder: String? = nil, useSelection: Bool = true) {
        let target = folder ?? (useSelection ? selectedNote?.folder : nil)
        guard let note = library.createNote(in: target) else { return }
        if let target { expandedFolders.insert(target) }
        searchText = ""
        selection = note.id
        editor.focus(note)
    }

    func delete(_ note: Note) {
        let order = visibleNotes
        var next: Note.ID?
        if selection == note.id, let index = order.firstIndex(of: note) {
            next = order.indices.contains(index + 1) ? order[index + 1].id : index > 0 ? order[index - 1].id : nil
        }
        let wasSelected = selection == note.id
        library.delete(note)
        if wasSelected { selection = next }
    }

    func togglePin(_ note: Note) { library.togglePin(note) }

    func move(_ note: Note, to folder: String?) {
        library.move(note, toFolder: folder)
        if let folder { expandedFolders.insert(folder) }
    }

    func showInFinder(_ note: Note) {
        NSWorkspace.shared.activateFileViewerSelecting([note.url])
    }

    func copyMarkdown(_ note: Note) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
    }

    /// Saves a copy of the note's Markdown where the user picks.
    func exportMarkdown(_ note: Note) {
        library.save(note)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = note.url.lastPathComponent
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try note.text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            library.errorMessage = "The note could not be exported. \(error.localizedDescription)"
        }
    }

    /// Notes in the order the sidebar shows them, for picking a neighbour.
    var visibleNotes: [Note] {
        if isSearching { return library.search(searchText).map(\.note) }
        var list = library.pinnedNotes
        for folder in library.folders where expandedFolders.contains(folder) {
            list += library.notes(in: folder)
        }
        return list + library.notes(in: nil)
    }

    // MARK: Folders

    func newFolder() {
        guard let name = library.createFolder() else { return }
        searchText = ""
        renamingFolder = name
    }

    func renameFolder(_ name: String, to proposed: String) {
        renamingFolder = nil
        let newName = library.renameFolder(name, to: proposed)
        if newName != name, expandedFolders.remove(name) != nil { expandedFolders.insert(newName) }
    }

    func requestDelete(folder: String) {
        if library.count(in: folder) == 0 && !library.notes.contains(where: { $0.folder == folder }) {
            deleteFolder(folder)
        } else {
            folderPendingDelete = folder
        }
    }

    func deleteFolder(_ name: String) {
        folderPendingDelete = nil
        let selectedWasInside = selectedNote?.folder == name
        library.deleteFolder(name)
        expandedFolders.remove(name)
        if selectedWasInside { selection = visibleNotes.first?.id }
    }

    func showInFinder(folder: String) {
        NSWorkspace.shared.activateFileViewerSelecting([library.directory(for: folder)])
    }
}
