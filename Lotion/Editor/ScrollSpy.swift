//
//  ScrollSpy.swift
//  Lotion
//
//  A quiet map of the note at the canvas's right edge: one short line per
//  heading, the one you are reading darker. Come near it and the lines open
//  into a card of the note's sections; click one to scroll there.
//

import AppKit
import Observation
import SwiftUI

/// The note's headings and which one is being read, fed by the editor.
@Observable
final class ScrollSpy {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let level: Int
        let title: String
    }

    private(set) var entries: [Entry] = []
    private(set) var activeID: UUID?
    @ObservationIgnored weak var editor: BlockEditorView?
    /// While a click's scroll is under way, the section clicked stays active
    /// rather than every heading the page passes on the way.
    @ObservationIgnored fileprivate var revealing: UUID?
    @ObservationIgnored fileprivate var revealGeneration = 0
    #if DEBUG
    /// Holds the card open, for screenshots.
    var debugOpen = false
    #endif

    func set(entries: [Entry]) {
        if entries != self.entries { self.entries = entries }
    }

    func set(activeID: UUID?) {
        if activeID != self.activeID { self.activeID = activeID }
    }

    func reveal(_ id: UUID) {
        revealGeneration += 1
        let generation = revealGeneration
        revealing = id
        set(activeID: id)
        editor?.scrollToBlock(id) { [weak self] in
            guard let self, self.revealGeneration == generation else { return }
            self.revealing = nil
            self.editor?.updateScrollSpyActive()
        }
    }
}

// MARK: - Feeding it

extension BlockEditorView {
    /// Headings worth a line: levels 1–3 with text, the note's title aside.
    func updateScrollSpyEntries() {
        guard let scrollSpy else { return }
        var entries: [ScrollSpy.Entry] = []
        if isScratchpad {
            // The scratchpad's map is its entries, named by their first line.
            for (index, block) in blocks.enumerated() where block.kind == .entry {
                entries.append(ScrollSpy.Entry(id: block.id, level: 1, title: entryTitle(at: index)))
            }
            scrollSpy.set(entries: entries)
            updateScrollSpyActive()
            return
        }
        for (index, block) in blocks.enumerated() {
            guard let level = block.kind.headingLevel, level <= 3, !(index == 0 && level == 1) else { continue }
            let title = block.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            entries.append(ScrollSpy.Entry(id: block.id, level: level, title: title))
        }
        scrollSpy.set(entries: entries)
        updateScrollSpyActive()
    }

    /// The section being read: the last heading above the top quarter of the page.
    func updateScrollSpyActive() {
        guard let scrollSpy, !scrollSpy.entries.isEmpty, scrollSpy.revealing == nil else { return }
        let insetTop = enclosingScrollView?.contentInsets.top ?? 0
        let readingLine = visibleRect.minY + insetTop + min(140, (visibleRect.height - insetTop) * 0.25)
        var active: UUID?
        for entry in scrollSpy.entries {
            guard let view = view(for: entry.id) else { continue }
            if view.frame.minY <= readingLine { active = entry.id } else { break }
        }
        // At the very bottom the last section is the one being read, however short.
        if visibleRect.maxY >= contentBottom, let last = scrollSpy.entries.last,
           let view = view(for: last.id), view.frame.minY < visibleRect.maxY {
            active = last.id
        }
        scrollSpy.set(activeID: active)
    }

    /// Scrolls a block to just under the toolbar, smoothly.
    func scrollToBlock(_ id: UUID, completion: (() -> Void)? = nil) {
        guard let view = view(for: id), let scrollView = enclosingScrollView else {
            completion?()
            return
        }
        let clip = scrollView.contentView
        let insetTop = scrollView.contentInsets.top
        let highest = max(-insetTop, frame.height - clip.bounds.height)
        let y = min(highest, max(-insetTop, view.frame.minY - insetTop - 28))
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.32, 0.72, 0, 1)
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: y))
        } completionHandler: { [weak scrollView] in
            MainActor.assumeIsolated {
                if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
                completion?()
            }
        }
    }
}

// MARK: - The view

struct ScrollSpyView: View {
    let spy: ScrollSpy
    let palette: ThemePalette

    @State private var isOpen = false
    @State private var isHovering = false
    @State private var pendingChange: Task<Void, Never>?

    private var ink: Color { Color(nsColor: palette.text) }

    var body: some View {
        let entries = spy.entries
        if entries.count >= 2 {
            let minimum = entries.map(\.level).min() ?? 1
            ZStack(alignment: .trailing) {
                lines(entries, minimum: minimum)
                    .opacity(showsCard ? 0 : 1)
                if showsCard {
                    card(entries, minimum: minimum)
                        // One layer: surface, border, shadow and rows fade as a single piece.
                        .compositingGroup()
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .trailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .trailing))
                        ))
                }
            }
            .onHover(perform: hover)
            .onDisappear { pendingChange?.cancel() }
        }
    }

    private var showsCard: Bool {
        #if DEBUG
        if spy.debugOpen { return true }
        #endif
        return isOpen
    }

    /// A strong ease-out: most of the motion happens in the first few frames.
    private static let enter = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.18)
    private static let exit = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.12)

    /// Opens at once; closes a beat late so a pointer passing by doesn't flicker it.
    private func hover(_ hovering: Bool) {
        isHovering = hovering
        pendingChange?.cancel()
        if hovering {
            withAnimation(Self.enter) { isOpen = true }
            return
        }
        pendingChange = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, !isHovering else { return }
            withAnimation(Self.exit) { isOpen = false }
        }
    }

    // MARK: Lines

    private func lines(_ entries: [ScrollSpy.Entry], minimum: Int) -> some View {
        let spacing: CGFloat = entries.count > 28 ? 5 : entries.count > 16 ? 7 : 10
        return VStack(alignment: .trailing, spacing: spacing) {
            ForEach(entries) { entry in
                let isActive = entry.id == spy.activeID
                Capsule()
                    .fill(ink.opacity(isActive ? 0.8 : 0.18))
                    .frame(width: lineWidth(entry.level - minimum, isActive: isActive), height: 2)
                    .animation(.smooth(duration: 0.25), value: isActive)
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        // Reach a little past the lines, so coming near is enough.
        .padding(.leading, 28)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sections")
        .accessibilityValue(entries.first { $0.id == spy.activeID }?.title ?? "")
        .accessibilityAddTraits(.isButton)
    }

    private func lineWidth(_ depth: Int, isActive: Bool) -> CGFloat {
        let base: CGFloat = [18, 13, 9][min(2, max(0, depth))]
        return isActive ? base + 4 : base
    }

    // MARK: Card

    private func card(_ entries: [ScrollSpy.Entry], minimum: Int) -> some View {
        let rows = VStack(alignment: .leading, spacing: 1) {
            ForEach(entries) { entry in
                SpyRow(entry: entry, depth: entry.level - minimum, isActive: entry.id == spy.activeID, ink: ink) {
                    spy.reveal(entry.id)
                }
                .id(entry.id)
            }
        }
        .padding(6)

        return ScrollViewReader { proxy in
            ViewThatFits(in: .vertical) {
                rows
                ScrollView { rows }
                    .scrollIndicators(.never)
            }
            .onAppear { if let id = spy.activeID { proxy.scrollTo(id, anchor: .center) } }
        }
        .frame(width: 248)
        .frame(maxHeight: 440)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: palette.background))
                .shadow(color: .black.opacity(palette.isDark ? 0.4 : 0.1), radius: 18, y: 8)
                .shadow(color: .black.opacity(palette.isDark ? 0.25 : 0.05), radius: 2, y: 1)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(ink.opacity(palette.isDark ? 0.14 : 0.09), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .padding(.leading, 28)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

private struct SpyRow: View {
    let entry: ScrollSpy.Entry
    let depth: Int
    let isActive: Bool
    let ink: Color
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(entry.title)
                // Weight stays put: changing it reflows the text as it lights up.
                .font(.system(size: depth == 0 ? 13 : 12.5, weight: depth == 0 ? .medium : .regular))
                .foregroundStyle(ink.opacity(isActive ? 0.95 : depth == 0 ? 0.55 : 0.42))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.leading, 10 + CGFloat(depth) * 12)
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                .background(
                    ink.opacity(isHovering ? 0.07 : 0),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .animation(.easeOut(duration: 0.15), value: isActive)
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }
}
