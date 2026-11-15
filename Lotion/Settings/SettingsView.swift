//
//  SettingsView.swift
//  Lotion
//
//  Settings, in panes down a sidebar. Each pane is a page of quiet cards
//  (see SettingsKit): an icon, a title and a line of detail on every row,
//  and choices drawn as what they look like — appearance as little
//  windows, themes as little pages, spacing as lines. Every change applies
//  live.
//

import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, editor, tasks, quickNote, media, cloud, agents, updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .tasks: "Tasks"
        case .quickNote: "Quick Note"
        case .media: "Media & Links"
        case .cloud: "Cloud"
        case .agents: "AI Agents"
        case .updates: "Updates"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "sun.min"
        case .editor: "character.cursor.ibeam"
        case .tasks: "checkmark.square"
        case .quickNote: "note.text"
        case .media: "photo"
        case .cloud: "cloud.fill"
        case .agents: "bubble.left.and.text.bubble.right"
        case .updates: "arrow.down.circle"
        }
    }
}

// MARK: - Window

/// Settings get a window of their own, laid out like Screendrop's: a fixed
/// sidebar, the pane's name as the title, and back and forward through the
/// panes visited.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static var shared: SettingsWindowController?

    static func show(pane: SettingsPane? = nil) {
        if let pane { UserDefaults.standard.set(pane.rawValue, forKey: "settingsTab") }
        if shared == nil { shared = SettingsWindowController() }
        shared?.showWindow(nil)
        shared?.window?.makeKeyAndOrderFront(nil)
    }

    /// Wide enough for the widest row (Text width's four pictures) beside the
    /// sidebar, so no pane ever has to squeeze or wrap its choices.
    static let minimum = NSSize(width: 800, height: 540)

    private init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: SettingsWindowController.minimum.width + 20, height: 620)),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.contentMinSize = Self.minimum
        window.setFrameAutosaveName("SettingsWindow")
        // A frame saved before the minimum grew can still be smaller than it.
        let content = window.contentRect(forFrameRect: window.frame).size
        if content.width < Self.minimum.width || content.height < Self.minimum.height {
            window.setContentSize(NSSize(width: max(content.width, Self.minimum.width),
                                         height: max(content.height, Self.minimum.height)))
        }
        window.contentViewController = NSHostingController(rootView: SettingsView())
        window.center()
        window.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    @AppStorage("settingsTab") private var tab = SettingsPane.appearance.rawValue
    @AppStorage(Prefs.interfaceFont) private var interfaceFont = FontChoice.system
    @State private var history: [SettingsPane] = []
    @State private var historyIndex = 0
    @State private var isHistoryNavigation = false

    private var active: SettingsPane { SettingsPane(rawValue: tab) ?? .appearance }

    private var selection: Binding<SettingsPane?> {
        Binding(get: { active }, set: { if let value = $0 { tab = value.rawValue } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: selection) {
                ForEach(SettingsPane.allCases) { pane in
                    Label {
                        Text(pane.title)
                    } icon: {
                        // Symbols differ in width; a fixed slot keeps the titles aligned.
                        Image(icon: pane.symbol).frame(width: 20, alignment: .center)
                    }
                    .listItemTint(.monochrome)
                    .tag(pane)
                }
            }
            .listStyle(.sidebar)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .frame(width: 200)
            .navigationSplitViewColumnWidth(min: 200, ideal: 200, max: 200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch active {
                case .appearance: AppearancePane()
                case .editor: EditorPane()
                case .tasks: TasksPane()
                case .quickNote: QuickNotePane()
                case .media: MediaPane()
                case .cloud: CloudPane()
                case .agents: AgentsPane()
                case .updates: UpdatesPane()
                }
            }
            .navigationTitle(active.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsWindowController.minimum.width, minHeight: SettingsWindowController.minimum.height)
        .interfaceFont(interfaceFont)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { go(by: -1) } label: { Image(icon: "chevron.left") }
                    .disabled(historyIndex <= 0)
                    .help("Go Back")
                    .accessibilityLabel("Go Back")
                Button { go(by: 1) } label: { Image(icon: "chevron.right") }
                    .disabled(historyIndex >= history.count - 1)
                    .help("Go Forward")
                    .accessibilityLabel("Go Forward")
            }
        }
        .onAppear {
            history = [active]
            historyIndex = 0
        }
        .onChange(of: tab) { _, _ in record() }
    }

    private func go(by step: Int) {
        let target = historyIndex + step
        guard history.indices.contains(target) else { return }
        isHistoryNavigation = true
        historyIndex = target
        tab = history[target].rawValue
        DispatchQueue.main.async { isHistoryNavigation = false }
    }

    private func record() {
        guard !isHistoryNavigation else { return }
        if history.isEmpty { history = [active]; historyIndex = 0; return }
        guard history[historyIndex] != active else { return }
        history = Array(history.prefix(historyIndex + 1)) + [active]
        historyIndex = history.count - 1
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @AppStorage(Prefs.appearance) private var appearance: AppearanceMode = .system
    @AppStorage(Prefs.theme) private var theme: LotionTheme = .paper
    @AppStorage(Prefs.interfaceFont) private var interfaceFont = FontChoice.system
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        SettingsPage {
            SettingsSection("Light and dark", icon: "circle.lefthalf.filled") {
                SettingsRow("Appearance", icon: "circle.lefthalf.filled",
                            detail: "Light, dark, or whatever the Mac is doing.") {
                    EmptyView()
                } below: {
                    ChoiceTiles {
                        ForEach([AppearanceMode.light, .dark, .system]) { mode in
                            ChoiceTile(title: mode.title, isSelected: appearance == mode, width: 112, aspect: 16 / 11,
                                       action: { appearance = mode }) {
                                AppearancePicture(mode: mode, isSelected: appearance == mode)
                            }
                        }
                    }
                }
            }

            SettingsSection("Theme", icon: "paintpalette",
                            footer: "A sun or a moon on a theme means it has only that side, and keeps it whatever the Mac is doing.") {
                SettingsRow("Page", icon: "doc.text", detail: "The page you write on, and the code on it.") {
                    // No name here: the picked swatch already says it, and a
                    // name that changes width would rewrap the detail.
                    EmptyView()
                } below: {
                    ThemeGrid(theme: $theme, isDark: colorScheme == .dark)
                }
            }

            SettingsSection("Window", icon: "macwindow") {
                SettingsRow("Interface font", icon: "textformat",
                            detail: "The sidebar, toolbar and inspector.") {
                    FontPicker(selection: $interfaceFont, families: FontChoice.installedFamilies)
                }
            }
        }
    }
}

/// Every theme as a small swatch of its page. Lotion's own come first; the
/// rest wait behind "Show all" so the pane stays short.
private struct ThemeGrid: View {
    @Binding var theme: LotionTheme
    let isDark: Bool
    @State private var showsAll = false

    private static let collapsedCount = 12

    private var visible: [LotionTheme] {
        let all = LotionTheme.allCases
        guard !showsAll else { return all }
        var shown = Array(all.prefix(Self.collapsedCount))
        // The theme in use is always in view.
        if !shown.contains(theme) { shown[shown.count - 1] = theme }
        return shown
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70, maximum: 92), spacing: 10, alignment: .top)],
                      alignment: .leading, spacing: 12) {
                ForEach(visible) { option in
                    ThemeSwatch(theme: option, isDark: isDark, isSelected: theme == option) { theme = option }
                }
            }
            Button {
                withAnimation(.smooth(duration: 0.25)) { showsAll.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Text(showsAll ? "Show fewer" : "Show all \(LotionTheme.allCases.count) themes")
                    Image(icon: "chevron.down")
                        .uiFont(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(showsAll ? 180 : 0))
                }
                .uiFont(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.secondaryLabel)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A theme as a scrap of its page: "Aa" in its heading color over a line of
/// text and a dash of its accent.
private struct ThemeSwatch: View {
    let theme: LotionTheme
    let isDark: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let palette = theme.palette(dark: isDark)
        let text = Color(nsColor: palette.text)
        let heading = Color(nsColor: palette.colorsHeadings ? palette.heading : palette.text)
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topLeading) {
                    Color(nsColor: palette.background)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Aa")
                            .uiFont(.system(size: 15, weight: .semibold))
                            .foregroundStyle(heading)
                        HStack(spacing: 3) {
                            Capsule().fill(text.opacity(0.45)).frame(width: 20, height: 3)
                            Capsule().fill(Color(nsColor: palette.accent)).frame(width: 10, height: 3)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.top, 6)
                    if theme.hasLight != theme.hasDark {
                        Image(icon: theme.hasDark ? "moon.fill" : "sun.max.fill")
                            .uiFont(.system(size: 8, weight: .semibold))
                            .foregroundStyle(Color(nsColor: palette.secondary))
                            .frame(maxWidth: .infinity, alignment: .topTrailing)
                            .padding(6)
                    }
                }
                .frame(height: 48)
                .selectionRing(isSelected: isSelected, isHovering: isHovering, radius: 8)
                Text(theme.name)
                    .uiFont(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .truncationMode(.tail)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .onHover { isHovering = $0 }
        .help(theme.name)
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A Mac window with a sidebar, on a neutral stage: light, dark, or split
/// down the middle for Automatic.
private struct AppearancePicture: View {
    let mode: AppearanceMode
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                FauxWindow(isDark: mode == .dark)
                if mode == .system {
                    FauxWindow(isDark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: proxy.size.width / 2) }
                }
            }
        }
    }
}

/// Lotion in miniature: a sidebar with a few rows, and a note with a
/// heading and lines.
private struct FauxWindow: View {
    let isDark: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width, size.height)
            let line = max(1.5, unit * 0.045)
            let sidebar = size.width * 0.3
            let ink = isDark ? Color.white : Color.black
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: line * 1.8) {
                    ForEach(0..<3, id: \.self) { index in
                        Capsule()
                            .fill(ink.opacity(isDark ? (index == 0 ? 0.45 : 0.22) : (index == 0 ? 0.35 : 0.16)))
                            .frame(width: sidebar * [0.55, 0.45, 0.5][index], height: line)
                    }
                }
                .padding(.top, unit * 0.2)
                .padding(.leading, unit * 0.1)
                .frame(width: sidebar, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(isDark ? Color(white: 0.2) : Color(white: 0.93))

                VStack(alignment: .leading, spacing: line * 1.4) {
                    Capsule().fill(ink.opacity(isDark ? 0.55 : 0.45)).frame(width: size.width * 0.3, height: line * 1.3)
                    Capsule().fill(ink.opacity(isDark ? 0.22 : 0.14)).frame(width: size.width * 0.42, height: line)
                    Capsule().fill(ink.opacity(isDark ? 0.22 : 0.14)).frame(width: size.width * 0.34, height: line)
                }
                .padding(.top, unit * 0.2)
                .padding(.leading, unit * 0.12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(isDark ? Color(white: 0.11) : Color.white)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 5, bottomLeadingRadius: 5, style: .continuous))
                .padding([.top, .bottom, .trailing], unit * 0.07)
            }
            .background(isDark ? Color(white: 0.2) : Color(white: 0.93))
            .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }
}

// MARK: - Editor

private struct EditorPane: View {
    @AppStorage(Prefs.theme) private var theme: LotionTheme = .paper
    @AppStorage(Prefs.noteFont) private var noteFont = FontChoice.system
    @AppStorage(Prefs.noteFontSize) private var noteFontSize = 15.0
    @AppStorage(Prefs.lineSpacing) private var lineSpacing: LineSpacing = .comfortable
    @AppStorage(Prefs.codeFont) private var codeFont = FontChoice.mono
    @AppStorage(Prefs.readableWidth) private var readableWidth: ReadableWidth = .medium
    @AppStorage(Prefs.spellCheck) private var spellCheck = true
    @AppStorage(Prefs.tableWidth) private var tableWidth: TableWidth = .fit
    @AppStorage(Prefs.launchView) private var launchView: LaunchView = .home
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(dark: colorScheme == .dark)
        let isDark = colorScheme == .dark
        SettingsPage {
            SettingsSection("Type", icon: "textformat") {
                TypePreview(palette: palette, noteFont: noteFont, size: noteFontSize, lineSpacing: lineSpacing, codeFont: codeFont)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .padding(8)
                    .accessibilityHidden(true)
                SettingsRow("Note font", icon: "textformat", detail: "The sample above follows every change.") {
                    FontPicker(selection: $noteFont, families: FontChoice.installedFamilies)
                }
                SettingsRow("Size", icon: "plus.magnifyingglass") {
                    HStack(spacing: 10) {
                        Slider(value: $noteFontSize, in: 12...24, step: 1)
                            .frame(width: 140)
                            .accessibilityLabel("Size")
                            .accessibilityValue("\(Int(noteFontSize)) points")
                        Text("\(Int(noteFontSize)) pt")
                            .uiFont(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Palette.secondaryLabel)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
                SettingsRow("Code font", icon: "chevron.left.forwardslash.chevron.right", detail: "Code blocks and inline code.") {
                    FontPicker(selection: $codeFont, families: FontChoice.monospacedFamilies, designs: [FontChoice.mono])
                }
            }

            SettingsSection("Layout", icon: "square.grid.2x2") {
                SettingsRow("Line spacing", icon: "arrow.up.and.down.text.horizontal", detail: "Room between the lines of a paragraph.") {
                    EmptyView()
                } below: {
                    ChoiceTiles {
                        ForEach(LineSpacing.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: lineSpacing == option, action: { lineSpacing = option }) {
                                Miniature(isDark: isDark) { unit, width in
                                    TextLines(unit: unit, width: width, gap: option.pictureGap, count: 3)
                                }
                            }
                        }
                    }
                }
                SettingsRow("Text width", icon: "arrow.up.left.and.arrow.down.right",
                            detail: "How wide the text runs in a wide window.") {
                    EmptyView()
                } below: {
                    ChoiceTiles {
                        ForEach(ReadableWidth.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: readableWidth == option, action: { readableWidth = option }) {
                                Miniature(isDark: isDark) { unit, width in
                                    TextLines(unit: unit, width: width * option.fraction, count: 3)
                                        .frame(width: width, alignment: .center)
                                }
                            }
                        }
                    }
                }
                SettingsRow("Tables", icon: "tablecells.badge.ellipsis", detail: "As wide as what's in them, or across the whole column.") {
                    EmptyView()
                } below: {
                    ChoiceTiles {
                        ForEach(TableWidth.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: tableWidth == option, action: { tableWidth = option }) {
                                Miniature(isDark: isDark) { unit, width in
                                    TablePicture(unit: unit, width: option == .full ? width : width * 0.55)
                                }
                            }
                        }
                    }
                }
            }

            SettingsSection("Writing", icon: "pencil") {
                SettingsToggle("Check spelling while typing", icon: "checkmark.circle",
                               detail: "Underline words the dictionary doesn't know.", isOn: $spellCheck)
                SettingsRow("When Lotion opens", icon: "house", detail: "Start on Home, Today, or the note you were last in.") {
                    Picker("When Lotion opens", selection: $launchView) {
                        ForEach(LaunchView.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }
}

private extension LineSpacing {
    /// Points between lines in the picture: even steps, so the three read
    /// as tight, middle and loose.
    var pictureGap: CGFloat {
        switch self {
        case .compact: 2
        case .comfortable: 5
        case .relaxed: 8
        }
    }
}

private extension ReadableWidth {
    /// How much of a window the column takes, for the picture.
    var fraction: CGFloat {
        switch self {
        case .narrow: 0.42
        case .medium: 0.56
        case .wide: 0.7
        case .full: 0.88
        }
    }
}

/// A flat page for a picture to sit on, in light or dark. The picture sits
/// in the middle, top to bottom, so taller ones never touch an edge.
private struct Miniature<Content: View>: View {
    let isDark: Bool
    @ViewBuilder let content: (_ unit: CGFloat, _ width: CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width, size.height)
            let inset = (unit * 0.2).rounded()
            content(unit, size.width - inset * 2)
                .padding(.leading, inset)
                .frame(width: size.width, height: size.height, alignment: .leading)
                .background(isDark ? Color(white: 0.13) : Color.white)
                .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }
}

/// A heading and lines of text, the way a miniature shows a note. Sizes
/// are whole points so every gap renders the same; the heading keeps its
/// own gap, and only the gaps between body lines follow `gap`.
private struct TextLines: View {
    let unit: CGFloat
    let width: CGFloat
    /// Room between body lines, in points.
    var gap: CGFloat = 3
    var count = 2

    var body: some View {
        let line = max(2, (unit * 0.04).rounded())
        VStack(alignment: .leading, spacing: 0) {
            Capsule().fill(Color.primary.opacity(0.35))
                .frame(width: (width * 0.5).rounded(), height: line + 1)
                .padding(.bottom, line * 2 + 1)
            VStack(alignment: .leading, spacing: gap.rounded()) {
                ForEach(0..<count, id: \.self) { index in
                    Capsule().fill(Color.primary.opacity(0.14))
                        .frame(width: (width * (index == count - 1 ? 0.64 : 0.9)).rounded(), height: line)
                }
            }
        }
    }
}

/// A small table: a header row and two rows, two columns.
private struct TablePicture: View {
    let unit: CGFloat
    let width: CGFloat

    var body: some View {
        let row = max(6, unit * 0.15)
        let line = max(1.5, unit * 0.04)
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { column in
                        Capsule().fill(Color.primary.opacity(index == 0 ? 0.3 : 0.14))
                            .frame(width: width * (column == 0 ? 0.18 : 0.28), height: line)
                            .frame(width: width * (column == 0 ? 0.4 : 0.6), height: row, alignment: .leading)
                            .padding(.leading, line * 2)
                    }
                }
                .frame(width: width, alignment: .leading)
                .background(index == 0 ? Color.primary.opacity(0.06) : .clear)
                if index < 2 { Rectangle().fill(Color.primary.opacity(0.1)).frame(width: width, height: 0.5) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: line * 2, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: line * 2, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5) }
    }
}

/// A heading, a sentence and a line of code, in the chosen fonts and theme.
private struct TypePreview: View {
    let palette: ThemePalette
    let noteFont: String
    let size: Double
    let lineSpacing: LineSpacing
    let codeFont: String

    var body: some View {
        let body = FontChoice.font(noteFont, size: size)
        let heading = FontChoice.font(noteFont, size: round(size * 1.6), weight: .bold)
        let code = FontChoice.font(codeFont, size: round(size * 0.87 * 2) / 2)
        VStack(alignment: .leading, spacing: Space.l) {
            Text("The quiet page")
                .font(Font(heading))
                .foregroundStyle(Color(nsColor: palette.colorsHeadings ? palette.heading : palette.text))
            Text("Plain Markdown, kept in files you own. Write in blocks, \(Text("link to anything").foregroundStyle(Color(nsColor: palette.accent)).underline()), and drop in images.")
                .font(Font(body))
                .lineSpacing(max(0, size * lineSpacing.multiple - size * 1.2))
                .foregroundStyle(Color(nsColor: palette.text))
                .fixedSize(horizontal: false, vertical: true)
            Text("\(Text("let ").foregroundStyle(Color(nsColor: palette.accent)))\(Text("note = ").foregroundStyle(Color(nsColor: palette.text)))\(Text("\"Hello\"").foregroundStyle(Color(nsColor: palette.secondary)))")
                .font(Font(code))
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: palette.codeBackground), in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: palette.background))
    }
}

// MARK: - Media & Links

private struct MediaPane: View {
    @AppStorage(Prefs.saveVideos) private var saveVideos = false
    @AppStorage(Prefs.linkPreviews) private var linkPreviews = true

    var body: some View {
        SettingsPage {
            SettingsSection("Images and videos", icon: "photo",
                            footer: "Images and videos you add are copied into the note’s own folder, next to its Markdown.") {
                SettingsRow("Keep images from the web", icon: "photo",
                            detail: "Saved beside the note the first time they show.",
                            info: "An image linked from the web is saved in the note’s folder the first time it shows, and opens from there after.") {
                    Text("Always on")
                        .uiFont(.system(size: 12))
                        .foregroundStyle(Palette.secondaryLabel)
                }
                SettingsToggle("Save videos for offline viewing", icon: "play.rectangle",
                               detail: "Each one is saved beside the note after it first plays.",
                               info: "Videos from the web play from the web. When this is on, each one is also saved in the note’s folder after it first plays. Videos can be large.",
                               isOn: $saveVideos)
            }

            SettingsSection("Links", icon: "link") {
                SettingsToggle("Preview pages on hover", icon: "globe",
                               detail: "Rest the pointer on a link to see the page.",
                               info: "Each preview is kept for a week.",
                               isOn: $linkPreviews)
            }
        }
    }
}

// MARK: - Updates

private struct UpdatesPane: View {
    @ObservedObject private var updater = UpdaterManager.shared

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage {
            SettingsSection("Version", icon: "info.circle") {
                SettingsRow("Lotion \(version)", icon: "sparkles", detail: "New versions are published on GitHub.") {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                }
                SettingsToggle("Check automatically", icon: "arrow.clockwise",
                               detail: "Once a day. Lotion asks before installing.",
                               isOn: Binding(get: { updater.automaticallyChecksForUpdates },
                                             set: { updater.automaticallyChecksForUpdates = $0 }))
            }
        }
    }
}
