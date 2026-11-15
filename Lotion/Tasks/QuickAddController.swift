//
//  QuickAddController.swift
//  Lotion
//
//  Quick Add: a floating card, from any app (⌃⌥T), that turns a line of
//  plain words into a task — "Call mum tomorrow 6pm #home p1" — and writes
//  it to the inbox, or to a note you pick. What the words were read as shows
//  as pills under the title; the date and priority pills can be set by hand.
//  Return adds and puts the card away; ⌘Return adds and keeps it open.
//

import AppKit
import Observation
import SwiftUI

@MainActor
final class QuickAddController: NSObject, NSWindowDelegate {
    static let shared = QuickAddController()

    weak var state: AppState?
    private var panel: QuickAddPanel?
    let model = QuickAddModel()

    var isVisible: Bool { panel?.isVisible == true }

    func toggle() {
        if panel?.isKeyWindow == true { hide() } else { show() }
    }

    func show() {
        guard let state else { return }
        model.library = state.library
        if model.target.flatMap({ state.library.note(id: $0) }) == nil { model.target = nil }
        let panel = panel ?? makePanel(state: state)
        self.panel = panel
        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let frame = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height))
        }
        model.focusRequest += 1
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Adds the task typed; true when one was added.
    @discardableResult
    func add(keepOpen: Bool) -> Bool {
        guard let state else { return false }
        let draft = model.draft
        guard !draft.isEmpty else { NSSound.beep(); return false }
        let index = state.library.tasks
        let note = model.target.flatMap { state.library.note(id: $0) } ?? index.inbox(create: true)
        guard let note, index.add(draft, to: note) != nil else { NSSound.beep(); return false }
        model.reset()
        model.lastAdded = note.isScratchpad ? "Scratchpad" : note.displayTitle
        if !keepOpen { hide() }
        return true
    }

    private func makePanel(state: AppState) -> QuickAddPanel {
        let panel = QuickAddPanel(
            contentRect: NSRect(x: 0, y: 0, width: QuickAddView.width, height: 150),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        let view = NSHostingView(rootView: QuickAddView(model: model, controller: self))
        view.sizingOptions = [.preferredContentSize]
        panel.contentView = view
        panel.onEscape = { [weak self] in self?.hide() }
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        // Like Spotlight: clicking elsewhere puts it away, keeping what was typed.
        hide()
    }
}

@MainActor
@Observable
final class QuickAddModel {
    var text = ""
    /// The note tasks go to; the inbox when nil.
    var target: Note.ID?
    /// A date or priority picked from a pill, over what the words say.
    var pickedDay: Date??
    var pickedPriority: Int??
    var lastAdded: String?
    var focusRequest = 0
    @ObservationIgnored weak var library: Library?

    /// The task as it will be written: the words, then anything picked.
    var draft: TaskDraft {
        var draft = TaskDraft.parse(text)
        if let pickedDay {
            draft.due = pickedDay
            if pickedDay == nil { draft.minutes = nil }
        }
        if let pickedPriority { draft.priority = pickedPriority }
        return draft
    }

    func reset() {
        text = ""
        pickedDay = nil
        pickedPriority = nil
    }
}

final class QuickAddPanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

// MARK: - The card

/// Three rows on one 20 pt left edge: the title, the pills, and a footer
/// with where the task goes and how to add it.
struct QuickAddView: View {
    static let width: CGFloat = 640
    private static let inset: CGFloat = 20
    private static let radius: CGFloat = 18

    @Bindable var model: QuickAddModel
    let controller: QuickAddController
    @FocusState private var isFocused: Bool

    private var palette: ThemePalette { QuickNoteController.currentStyle().palette }

    var body: some View {
        let colors = TaskColors(palette: palette)
        let draft = model.draft
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                TextField("Call mum tomorrow 6pm #home p1", text: $model.text)
                    .textFieldStyle(.plain)
                    .uiFont(.system(size: 18, weight: .medium))
                    .foregroundStyle(colors.ink)
                    .focused($isFocused)
                    .onSubmit { controller.add(keepOpen: NSEvent.modifierFlags.contains(.command)) }
                pills(draft, colors)
            }
            .padding(.horizontal, Self.inset)
            .padding(.top, 20)
            .padding(.bottom, 18)

            Rectangle().fill(colors.hairline).frame(height: 0.5)

            footer(draft, colors)
                .padding(.horizontal, Self.inset - 8)
                .frame(height: 44)
                .background(colors.ink.opacity(palette.isDark ? 0.04 : 0.025))
        }
        .frame(width: Self.width)
        .background(Color(nsColor: palette.background))
        .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(colors.ink.opacity(palette.isDark ? 0.16 : 0.1), lineWidth: 0.5)
        )
        .environment(\.colorScheme, palette.isDark ? .dark : .light)
        .onAppear { isFocused = true }
        .onChange(of: model.focusRequest) { isFocused = true }
    }

    // MARK: Pills

    /// Date and priority always show, as placeholders until set; repeat,
    /// length and tags show once typed.
    private func pills(_ draft: TaskDraft, _ colors: TaskColors) -> some View {
        HStack(spacing: 6) {
            PillMenu(title: draft.due.map { TaskDates.label(due: $0, minutes: draft.minutes) } ?? "Date",
                     symbol: "calendar", tint: draft.due.map { colors.due(for: $0) }, colors: colors,
                     choices: TaskQuickDate.allCases.map { choice in
                         PillChoice(title: choice.title, symbol: choice.symbol) { model.pickedDay = .some(choice.date) }
                     } + (draft.due == nil ? [] : [nil, PillChoice(title: "No Date", symbol: "calendar.badge.minus") { model.pickedDay = .some(nil) }]))
            PillMenu(title: draft.priority.map { "P\($0)" } ?? "Priority",
                     symbol: draft.priority == nil ? "flag" : "flag.fill", tint: colors.priority(draft.priority), colors: colors,
                     choices: (1...3).map { level in
                         PillChoice(title: "Priority \(level)", symbol: "flag.fill") { model.pickedPriority = .some(level) }
                     } + (draft.priority == nil ? [] : [nil, PillChoice(title: "No Priority", symbol: "flag.slash") { model.pickedPriority = .some(nil) }]))
            if let rule = draft.recurrence {
                QuickAddPill(title: rule.text.capitalizedFirst, symbol: "repeat", tint: colors.ink.opacity(0.75), colors: colors)
            }
            if let duration = draft.duration {
                QuickAddPill(title: TaskDates.durationString(duration), symbol: "hourglass", tint: colors.ink.opacity(0.75), colors: colors)
            }
            ForEach(draft.tags, id: \.self) { tag in
                QuickAddPill(title: tag, symbol: "tag", tint: colors.ink.opacity(0.75), colors: colors)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Footer

    private func footer(_ draft: TaskDraft, _ colors: TaskColors) -> some View {
        HStack(spacing: 0) {
            QuickAddTargetMenu(model: model, colors: colors)
            Spacer(minLength: 12)
            if let added = model.lastAdded, model.text.isEmpty {
                Label("Added to \(added)", icon: "checkmark")
                    .labelStyle(CompactLabelStyle())
                    .uiFont(.system(size: 12))
                    .foregroundStyle(colors.secondary)
                    .padding(.trailing, 16)
                    .transition(.opacity)
            }
            HStack(spacing: 16) {
                KeyHint(title: "Add another", keys: ["⌘", "↩"], colors: colors)
                KeyHint(title: "Add", keys: ["↩"], colors: colors)
            }
            .padding(.trailing, 8)
            .opacity(draft.isEmpty ? 0.45 : 1)
        }
        .animation(.easeOut(duration: 0.15), value: model.lastAdded)
    }
}

/// One choice in a pill's menu; nil is a divider.
struct PillChoice {
    let title: String
    let symbol: String
    let action: () -> Void
}

/// A property under the title that opens a menu: a quiet outline with its
/// icon, or, once set, its value in its color. A plain button that pops a
/// native menu where it was clicked, so the pill is drawn whole by SwiftUI.
private struct PillMenu: View {
    let title: String
    let symbol: String
    /// Nil while it's a placeholder.
    let tint: Color?
    let colors: TaskColors
    let choices: [PillChoice?]
    @State private var isHovered = false

    var body: some View {
        Button(action: showMenu) {
            QuickAddPillLabel(title: title, symbol: symbol)
                .foregroundStyle(tint ?? (isHovered ? colors.ink.opacity(0.8) : colors.secondary))
                .padding(.horizontal, 10)
                .frame(height: 26)
                .pillBackground(tint: tint, colors: colors, isHovered: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private func showMenu() {
        let menu = NSMenu()
        for choice in choices {
            guard let choice else { menu.addItem(.separator()); continue }
            let item = ClosureMenuItem(title: choice.title, action: choice.action)
            item.image = NSImage(icon: choice.symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        guard let window = NSApp.keyWindow, let view = window.contentView else { return }
        let point = view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        menu.popUp(positioning: nil, at: point, in: view)
    }
}

/// A property that's only shown, like a tag or a repeat.
private struct QuickAddPill: View {
    let title: String
    let symbol: String
    let tint: Color
    let colors: TaskColors

    var body: some View {
        QuickAddPillLabel(title: title, symbol: symbol)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .pillBackground(tint: tint, colors: colors, isHovered: false)
    }
}

private struct QuickAddPillLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: 5) {
            Image(icon: symbol)
                .uiFont(.system(size: 11, weight: .medium))
            Text(title)
                .uiFont(.system(size: 12.5, weight: .medium))
        }
    }
}

private extension View {
    func pillBackground(tint: Color?, colors: TaskColors, isHovered: Bool) -> some View {
        background(
            Capsule().fill(tint.map { $0.opacity(colors.palette.isDark ? 0.16 : 0.09) } ?? colors.ink.opacity(isHovered ? 0.05 : 0))
        )
        .overlay(
            Capsule().strokeBorder(tint == nil ? colors.ink.opacity(colors.palette.isDark ? 0.18 : 0.12) : .clear, lineWidth: 0.5)
        )
        .contentShape(Capsule())
    }
}

/// "Add ↩": a word and its keys, drawn as keycaps.
private struct KeyHint: View {
    let title: String
    let keys: [String]
    let colors: TaskColors

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .uiFont(.system(size: 12))
                .foregroundStyle(colors.secondary)
            HStack(spacing: 3) {
                ForEach(keys, id: \.self) { key in
                    Text(key)
                        .uiFont(.system(size: 11, weight: .medium))
                        .foregroundStyle(colors.secondary)
                        .frame(minWidth: 20, minHeight: 20)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(colors.ink.opacity(colors.palette.isDark ? 0.1 : 0.06))
                        )
                }
            }
        }
    }
}

/// Where the task goes: the inbox, or a recent note.
private struct QuickAddTargetMenu: View {
    @Bindable var model: QuickAddModel
    let colors: TaskColors
    @State private var isHovered = false

    private var notes: [Note] {
        guard let library = model.library else { return [] }
        return library.notes.filter { !$0.title.isEmpty && $0.title != TaskIndex.inboxTitle }
            .sorted { $0.modified > $1.modified }.prefix(20).map { $0 }
    }

    private var current: Note? { model.target.flatMap { model.library?.note(id: $0) } }

    var body: some View {
        Menu {
            Button(TaskIndex.inboxTitle, icon: "tray") { model.target = nil }
            Divider()
            ForEach(notes) { note in
                Button(note.displayTitle) { model.target = note.id }
            }
        } label: {
            HStack(spacing: 6) {
                Image(icon: current == nil ? "tray" : "doc.text")
                    .uiFont(.system(size: 11, weight: .medium))
                Text(current?.displayTitle ?? TaskIndex.inboxTitle)
                    .uiFont(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Image(icon: "chevron.down")
                    .uiFont(.system(size: 8, weight: .bold))
                    .opacity(0.6)
            }
            .foregroundStyle(isHovered ? colors.ink : colors.secondary)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(colors.ink.opacity(isHovered ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovered = $0 }
        .help("The note this task goes in")
    }
}
