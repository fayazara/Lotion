//
//  SharePopover.swift
//  Lotion
//
//  The toolbar's Share button: publish the note to the user's own Lotion
//  Share worker, then copy its link, update it, share it or take it down.
//  Before publishing, a little browser window shows the page as it will
//  look, in the note's own theme.
//

import AppKit
import SwiftUI

extension Notification.Name {
    /// Posted with a note ID when Settings unpublishes it, so the library forgets it.
    static let cloudDidUnpublish = Notification.Name("LotionCloudDidUnpublish")
}

struct ShareButton: View {
    let note: Note
    let library: Library
    let style: EditorStyle
    @State private var isPresented = false

    var body: some View {
        let isPublished = library.publication(for: note) != nil
        Button { isPresented.toggle() } label: {
            Label("Share", systemImage: isPublished ? "globe" : "square.and.arrow.up")
        }
        .help(isPublished ? "Published to the web" : "Publish to the web")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            SharePopover(note: note, library: library, style: style)
        }
    }
}

struct SharePopover: View {
    let note: Note
    let library: Library
    let style: EditorStyle

    /// What's running: the button it belongs to shows the spinner.
    enum Job: Equatable { case publishing, updating, unpublishing }

    @State private var running: Job?
    @State private var feedback: Feedback?
    @State private var didCopy = false

    struct Feedback: Equatable {
        let text: String
        let isError: Bool
    }

    #if DEBUG
    /// Self-tests draw each state without a worker.
    var forcedPublication: Publication?
    var forcesConfigured: Bool?
    #endif

    private var publication: Publication? {
        #if DEBUG
        if let forcedPublication { return forcedPublication }
        #endif
        return library.publication(for: note)
    }

    private var isConfigured: Bool {
        #if DEBUG
        if let forcesConfigured { return forcesConfigured }
        #endif
        return CloudSettings.isConfigured
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            header
            if let publication, isConfigured {
                published(publication)
            } else {
                unpublished
            }
            if let feedback {
                FeedbackBanner(feedback: feedback)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .padding(Space.xl)
        .frame(width: 344)
        .animation(.snappy(duration: 0.22), value: publication)
        .animation(.snappy(duration: 0.22), value: feedback)
        .animation(.snappy(duration: 0.22), value: running)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(publication == nil ? "Publish to the web" : "Published to the web")
                    .font(.dsTitle)
                Text(subtitle)
                    .font(.dsCallout)
                    .foregroundStyle(Palette.secondaryLabel)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if publication != nil {
                LiveChip()
            }
        }
    }

    private var subtitle: String {
        if let publication {
            return "“\(note.displayTitle)” · \(publication.published.formatted(.relative(presentation: .named)))"
        }
        return "“\(note.displayTitle)”"
    }

    // MARK: Not published yet

    private var unpublished: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            PagePreview(note: note, library: library, style: style,
                        address: CloudSettings.workerURL?.host() ?? "your-worker.workers.dev")
            if isConfigured {
                Button { run(.publishing) { try await publish() } } label: {
                    ButtonLabel(title: "Publish", busyTitle: "Publishing…", isBusy: running == .publishing)
                }
                .buttonStyle(PopoverButtonStyle(isPrimary: true))
                .disabled(running != nil || note.isBlank)
                Footnote(systemImage: "info.circle",
                         text: "Anyone with the link can read this note. You can update it or take it down at any time.")
            } else {
                Button { SettingsWindowController.show(pane: .cloud) } label: {
                    ButtonLabel(title: "Set Up Publishing…", busyTitle: "", isBusy: false)
                }
                .buttonStyle(PopoverButtonStyle(isPrimary: true))
                Footnote(systemImage: "cloud",
                         text: "Notes publish to a worker on your own Cloudflare account, free. Settings has a prompt your coding agent can use to set it up.")
            }
        }
    }

    // MARK: Published

    private func published(_ publication: Publication) -> some View {
        let isStale = note.modified > publication.published
        return VStack(alignment: .leading, spacing: Space.l) {
            LinkField(url: publication.url, didCopy: didCopy) { copy(publication.url) }

            VStack(spacing: 0) {
                Button { run(.updating) { try await publish() } } label: {
                    ActionRow(systemImage: "arrow.clockwise", title: "Update page") {
                        if running == .updating {
                            ProgressView().controlSize(.small)
                        } else if isStale {
                            HStack(spacing: Space.xs) {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                                Text("Edited since publishing")
                            }
                            .foregroundStyle(Palette.secondaryLabel)
                        } else {
                            Text("Up to date").foregroundStyle(Palette.tertiaryLabel)
                        }
                    }
                }
                .disabled(running != nil)

                ShareLink(item: publication.url, subject: Text(note.displayTitle)) {
                    ActionRow(systemImage: "square.and.arrow.up", title: "Share…") { EmptyView() }
                }

                Button { SettingsWindowController.show(pane: .cloud) } label: {
                    ActionRow(systemImage: "gearshape", title: "Manage published notes") {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.tertiaryLabel)
                    }
                }
            }
            .buttonStyle(RowButtonStyle())
            .padding(.horizontal, -Space.m)

            HStack(spacing: Space.m) {
                Button {
                    run(.unpublishing) {
                        try await Publisher.unpublish(note, library: library)
                        return "The page is no longer on the web."
                    }
                } label: {
                    ButtonLabel(title: "Unpublish", busyTitle: "Unpublishing…", isBusy: running == .unpublishing)
                }
                .buttonStyle(PopoverButtonStyle(isPrimary: false))
                .disabled(running != nil)

                Button { NSWorkspace.shared.open(publication.url) } label: {
                    ButtonLabel(title: "View Page", busyTitle: "", isBusy: false)
                }
                .buttonStyle(PopoverButtonStyle(isPrimary: true))
            }
        }
    }

    // MARK: Actions

    private func copy(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            didCopy = false
        }
    }

    private func publish() async throws -> String {
        let wasPublished = publication != nil
        let result = try await Publisher.publish(note, library: library, style: style)
        copy(result.publication.url)
        if !result.skipped.isEmpty {
            let count = result.skipped.count
            return "\(count == 1 ? "One file wasn’t" : "\(count) files weren’t") found next to the note, so \(count == 1 ? "it’s" : "they’re") missing from the page."
        }
        return wasPublished ? "Page updated. The link is copied." : "Published. The link is copied."
    }

    private func run(_ job: Job, _ action: @escaping () async throws -> String) {
        running = job
        feedback = nil
        Task {
            do {
                let text = try await action()
                feedback = Feedback(text: text, isError: text.contains("missing"))
            } catch {
                feedback = Feedback(text: error.localizedDescription, isError: true)
            }
            running = nil
        }
    }
}

// MARK: - Pieces

/// The popover's buttons: one solid accent action, and quiet ones beside it.
/// Drawn here rather than by the system, so they look the same whether or
/// not the window is active.
private struct PopoverButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, isPrimary: isPrimary)
    }

    private struct StyledButton: View {
        let configuration: ButtonStyleConfiguration
        let isPrimary: Bool
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.dsBody.weight(isPrimary ? .semibold : .medium))
                .foregroundStyle(isPrimary ? AnyShapeStyle(.white) : AnyShapeStyle(Palette.label))
                .frame(maxWidth: .infinity)
                .frame(height: 32)
                .background {
                    RoundedRectangle(cornerRadius: Radius.field)
                        .fill(isPrimary ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(isHovering ? Palette.selectedFill : Palette.fill))
                        .overlay {
                            if isPrimary {
                                RoundedRectangle(cornerRadius: Radius.field)
                                    .fill(.white.opacity(isHovering ? 0.08 : 0))
                            } else {
                                RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline)
                            }
                        }
                }
                .contentShape(.rect(cornerRadius: Radius.field))
                .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.5)
                .scaleEffect(configuration.isPressed ? 0.985 : 1)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
        }
    }
}

/// A button's title, or a spinner and what's happening, filling the button.
private struct ButtonLabel: View {
    let title: String
    let busyTitle: String
    let isBusy: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            if isBusy {
                ProgressView().controlSize(.mini)
                Text(busyTitle)
            } else {
                Text(title)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct LiveChip: View {
    var body: some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(.green)
                .frame(width: 6, height: 6)
            Text("Live")
                .font(.dsCaption.weight(.semibold))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xxs + 1)
        .background(.green.opacity(0.12), in: .capsule)
    }
}

/// The page's address, split the way people read it: the site, then the
/// note. Clicking anywhere copies it.
private struct LinkField: View {
    let url: URL
    let didCopy: Bool
    let copy: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: Space.s) {
                Image(systemName: "globe")
                    .foregroundStyle(Palette.secondaryLabel)
                (Text(url.host() ?? url.absoluteString).foregroundStyle(Palette.label)
                    + Text(url.path()).foregroundStyle(Palette.secondaryLabel))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Space.m)
                Image(systemName: didCopy ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(didCopy ? AnyShapeStyle(.green) : AnyShapeStyle(Palette.secondaryLabel))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 16)
            }
            .font(.dsBody)
            .padding(.horizontal, Space.l - 2)
            .frame(height: 32)
            .background(isHovering ? Palette.selectedFill : Palette.fill, in: .rect(cornerRadius: Radius.field))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.field).strokeBorder(Palette.hairline)
            }
            .contentShape(.rect(cornerRadius: Radius.field))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(didCopy ? "Copied" : "Copy link")
        .accessibilityLabel("Copy link, \(url.absoluteString)")
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// One line in the list of actions: a glyph, a title, and something on the right.
private struct ActionRow<Trailing: View>: View {
    let systemImage: String
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(Palette.secondaryLabel)
                .frame(width: 18)
            Text(title)
                .foregroundStyle(Palette.label)
            Spacer(minLength: Space.m)
            trailing()
                .font(.dsCallout)
        }
        .font(.dsBody)
        .padding(.horizontal, Space.m)
        .frame(height: 30)
        .contentShape(.rect)
    }
}

/// Rows highlight under the pointer, like a menu.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .background(
                    (configuration.isPressed ? Palette.selectedFill : isHovering && isEnabled ? Palette.hoverFill : .clear),
                    in: .rect(cornerRadius: Radius.tile)
                )
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.1), value: isHovering)
        }
    }
}

private struct Footnote: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: systemImage)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.dsCallout)
        .foregroundStyle(Palette.secondaryLabel)
    }
}

private struct FeedbackBanner: View {
    let feedback: SharePopover.Feedback

    var body: some View {
        let tint: Color = feedback.isError ? .orange : .green
        HStack(alignment: .firstTextBaseline, spacing: Space.s) {
            Image(systemName: feedback.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(feedback.text)
                .foregroundStyle(Palette.label)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.dsCallout)
        .padding(Space.m + 2)
        .background(tint.opacity(0.1), in: .rect(cornerRadius: Radius.field))
    }
}

// MARK: - Preview of the page

/// A little browser window with the note's page in it, drawn in the note's
/// own theme: its cover, icon and title, and lines standing in for the text.
private struct PagePreview: View {
    let note: Note
    let library: Library
    let style: EditorStyle
    let address: String
    @State private var cover: NSImage?

    var body: some View {
        let palette = style.palette
        VStack(spacing: 0) {
            // The window's bar.
            HStack(spacing: Space.s) {
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().fill(Palette.tertiaryLabel.opacity(0.6)).frame(width: 7, height: 7)
                    }
                }
                Spacer(minLength: Space.s)
                HStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 7))
                    Text(address).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 10))
                .foregroundStyle(Palette.secondaryLabel)
                .padding(.horizontal, Space.m)
                .frame(height: 16)
                .background(Palette.fill, in: .capsule)
                Spacer(minLength: Space.s)
                Color.clear.frame(width: 29, height: 1)
            }
            .padding(.horizontal, Space.m)
            .frame(height: 26)
            .background(.background.secondary)

            // The page.
            VStack(alignment: .leading, spacing: 0) {
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(height: 40)
                        .frame(maxWidth: .infinity)
                        .clipped()
                }
                VStack(alignment: .leading, spacing: 6) {
                    if let symbol = library.icon(for: note) {
                        Image(systemName: symbol)
                            .font(.system(size: 22))
                            .foregroundStyle(Color(nsColor: palette.accent))
                            .padding(.top, cover == nil ? 0 : -22)
                    }
                    Text(note.displayTitle)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(nsColor: palette.text))
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 5) {
                        bar(1.0, palette)
                        bar(0.92, palette)
                        bar(0.97, palette)
                        bar(0.58, palette)
                    }
                    .padding(.top, 2)
                }
                .padding(.horizontal, 26)
                .padding(.top, cover == nil ? 18 : 10)
                .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: palette.background))
        }
        .clipShape(.rect(cornerRadius: Radius.thumbnail))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.thumbnail).strokeBorder(Palette.hairline)
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of the published page")
        .task(id: note.url) { cover = loadCover() }
    }

    private func bar(_ fraction: CGFloat, _ palette: ThemePalette) -> some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Color(nsColor: palette.text).opacity(0.09))
                .frame(width: proxy.size.width * fraction)
        }
        .frame(height: 5)
    }

    private func loadCover() -> NSImage? {
        guard let cover = library.cover(for: note) else { return nil }
        return NSImage(contentsOf: cover.url(in: library))
    }
}
