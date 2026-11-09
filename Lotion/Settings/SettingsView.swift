//
//  SettingsView.swift
//  Lotion
//
//  Settings, in panes down a sidebar, built like Screendrop's: native grouped
//  forms, a title and a line of detail on every row, and choices drawn as
//  what they look like — appearance as little windows, themes as little
//  notes, spacing as lines. Every change applies live.
//

import AppKit
import SwiftUI

enum SettingsPane: String, CaseIterable, Identifiable {
    case appearance, editor, media

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appearance: "Appearance"
        case .editor: "Editor"
        case .media: "Media & Links"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "paintpalette.fill"
        case .editor: "textformat"
        case .media: "photo.fill.on.rectangle.fill"
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

    private init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: CGSize(width: 720, height: 560)),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Settings"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .automatic
        window.animationBehavior = .none
        window.isMovableByWindowBackground = false
        window.setFrameAutosaveName("SettingsWindow")
        window.minSize = NSSize(width: 640, height: 460)
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
                        Image(systemName: pane.symbol).frame(width: 20, alignment: .center)
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
                case .media: MediaPane()
                }
            }
            .navigationTitle(active.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 640, minHeight: 460)
        .interfaceFont(interfaceFont)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { go(by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(historyIndex <= 0)
                    .help("Go Back")
                    .accessibilityLabel("Go Back")
                Button { go(by: 1) } label: { Image(systemName: "chevron.right") }
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

// MARK: - Building blocks

/// One pane: a native grouped form, as a Mac settings window should be.
private struct SettingsPage<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        Form { content() }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, 8, for: .scrollContent)
            .scrollEdgeEffectStyle(.soft, for: .all)
    }
}

/// A row's title with a line of detail under it, free to wrap.
private struct SettingsControlLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row of pictured choices under its label.
private struct ChoiceRow<Tiles: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let tiles: () -> Tiles

    init(_ title: String, detail: String? = nil, @ViewBuilder tiles: @escaping () -> Tiles) {
        self.title = title
        self.detail = detail
        self.tiles = tiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsControlLabel(title, detail: detail)
            tiles()
        }
        .padding(.vertical, 2)
    }
}

/// A choice drawn as a miniature over its name, like Screendrop's layout
/// tiles: a hairline that firms up on hover, and an accent ring that sits a
/// hair outside the picked one.
private struct ChoiceTile<Picture: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @ViewBuilder let picture: () -> Picture

    @State private var isHovering = false

    private static var radius: CGFloat { 7 }
    private static var ringGap: CGFloat { 2 }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                picture()
                    .clipShape(RoundedRectangle(cornerRadius: Self.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isHovering && !isSelected ? 0.16 : 0.07), lineWidth: 0.5)
                    }
                    .padding(Self.ringGap)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.radius + Self.ringGap, style: .continuous)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                            .opacity(isSelected ? 1 : 0)
                    }
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Palette.label : Palette.secondaryLabel)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

/// Screendrop's miniature: a flat stage with one window on it — traffic
/// lights (lit on the picked tile), then whatever the window shows.
private struct Miniature<Content: View>: View {
    let isDark: Bool
    let isSelected: Bool
    var window: Color?
    @ViewBuilder let content: (_ unit: CGFloat, _ width: CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width, size.height)
            let padding = min(max((unit * 0.13).rounded(), 4), 9)
            let stage = CGRect(origin: .zero, size: size).insetBy(dx: padding, dy: padding)
            let radius = max(2, Radius.thumbnail - padding + 4)
            let dot = max(2.5, unit * 0.062)
            let inset = max(dot * 1.1, (unit * 0.085).rounded())
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            ZStack(alignment: .topLeading) {
                isDark ? Color(white: 0.15) : Color(white: 0.935)
                ZStack(alignment: .topLeading) {
                    shape.fill(window ?? (isDark ? Color(white: 0.25) : Color.white))
                    TrafficLights(dot: dot, isLit: isSelected, isDark: isDark)
                        .offset(x: inset, y: inset)
                    content(unit, stage.width - inset * 2)
                        .offset(x: inset, y: inset + dot + unit * 0.1)
                }
                .frame(width: stage.width, height: stage.height, alignment: .topLeading)
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.primary.opacity(isDark ? 0.1 : 0.06), lineWidth: 0.5) }
                .shadow(color: .black.opacity(isDark ? 0.22 : 0.05), radius: 1, y: 0.5)
                .offset(x: stage.minX, y: stage.minY)
            }
            .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }
}

/// Close, minimize and zoom: macOS's colors on the picked tile, grey on the rest.
private struct TrafficLights: View {
    let dot: CGFloat
    let isLit: Bool
    let isDark: Bool

    private static let colors = [
        Color(red: 1, green: 0.373, blue: 0.341),
        Color(red: 0.996, green: 0.737, blue: 0.18),
        Color(red: 0.157, green: 0.784, blue: 0.251),
    ]

    var body: some View {
        HStack(spacing: dot * 0.62) {
            ForEach(Self.colors.indices, id: \.self) { index in
                Circle()
                    .fill(isLit ? Self.colors[index] : Color.primary.opacity(isDark ? 0.22 : 0.15))
                    .frame(width: dot, height: dot)
            }
        }
    }
}

/// A heading and lines of text, the way a miniature window shows a note.
private struct TextLines: View {
    let unit: CGFloat
    let width: CGFloat
    var heading: Color?
    var line: Color?
    var spacing: CGFloat = 1.2
    var count = 2

    var body: some View {
        let height = max(1.5, unit * 0.042)
        VStack(alignment: .leading, spacing: height * spacing) {
            Capsule().fill(heading ?? Color.primary.opacity(0.25)).frame(width: width * 0.5, height: height * 1.4)
            ForEach(0..<count, id: \.self) { index in
                Capsule().fill(line ?? Color.primary.opacity(0.12))
                    .frame(width: width * (index == count - 1 ? 0.64 : 0.9), height: height)
            }
        }
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
            Section("Appearance") {
                ChoiceRow("Mode", detail: "Light, dark, or following your Mac.") {
                    HStack(spacing: 12) {
                        ForEach(AppearanceMode.allCases) { mode in
                            ChoiceTile(title: mode.title, isSelected: appearance == mode, action: { appearance = mode }) {
                                AppearancePicture(mode: mode, isSelected: appearance == mode)
                                    .aspectRatio(16 / 11, contentMode: .fit)
                            }
                        }
                    }
                }
                FontPicker(selection: $interfaceFont, families: FontChoice.installedFamilies) {
                    SettingsControlLabel("Interface font", detail: "The sidebar, toolbar and inspector.")
                }
            }

            Section {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(LotionTheme.allCases) { option in
                        ThemeCard(theme: option, isDark: colorScheme == .dark, isSelected: theme == option) {
                            theme = option
                        }
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Theme")
            } footer: {
                Text("The page you write on. A sun and a moon mean the theme follows light and dark; one alone means it keeps that side.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
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
                FauxWindow(isDark: mode == .dark, isSelected: isSelected)
                if mode == .system {
                    FauxWindow(isDark: true, isSelected: isSelected)
                        .mask(alignment: .trailing) { Rectangle().frame(width: proxy.size.width / 2) }
                }
            }
        }
    }
}

/// Screendrop's stage with Lotion on it: the sidebar with its rows, and a
/// note with a heading, lines and a checklist.
private struct FauxWindow: View {
    let isDark: Bool
    let isSelected: Bool

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let unit = min(size.width, size.height)
            let padding = min(max((unit * 0.12).rounded(), 4), 10)
            let window = CGSize(width: size.width - padding * 2, height: size.height - padding)
            let line = max(1.5, unit * 0.04)
            let dot = max(2.5, unit * 0.055)
            let sidebar = window.width * 0.28
            let shape = UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 7, style: .continuous)
            let ink = isDark ? Color.white : Color.black
            ZStack(alignment: .topLeading) {
                isDark ? Color(white: 0.15) : Color(white: 0.935)
                HStack(spacing: 0) {
                    // Sidebar: the lights, then a few rows, one picked.
                    VStack(alignment: .leading, spacing: line * 1.9) {
                        TrafficLights(dot: dot, isLit: isSelected, isDark: isDark)
                            .padding(.bottom, line)
                        ForEach(0..<5, id: \.self) { index in
                            Capsule()
                                .fill(index == 1 ? Color.accentColor.opacity(0.9) : ink.opacity(isDark ? 0.2 : 0.14))
                                .frame(width: sidebar * (index == 1 ? 0.62 : [0.5, 0, 0.56, 0.42, 0.48][index]), height: line)
                        }
                    }
                    .padding(.top, dot * 1.6)
                    .padding(.leading, dot * 1.6)
                    .frame(width: sidebar, alignment: .topLeading)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(isDark ? Color(white: 0.21) : Color(white: 0.965))
                    // The note
                    VStack(alignment: .leading, spacing: line * 1.25) {
                        Capsule().fill(ink.opacity(isDark ? 0.75 : 0.7)).frame(width: window.width * 0.24, height: line * 1.5)
                        Capsule().fill(ink.opacity(isDark ? 0.22 : 0.13)).frame(width: window.width * 0.5, height: line)
                        Capsule().fill(ink.opacity(isDark ? 0.22 : 0.13)).frame(width: window.width * 0.38, height: line)
                        ForEach(0..<3, id: \.self) { index in
                            HStack(spacing: line * 1.4) {
                                RoundedRectangle(cornerRadius: line * 0.6, style: .continuous)
                                    .fill(index < 2 ? Color.accentColor : .clear)
                                    .overlay {
                                        if index == 2 {
                                            RoundedRectangle(cornerRadius: line * 0.6, style: .continuous)
                                                .strokeBorder(ink.opacity(0.3), lineWidth: 0.75)
                                        }
                                    }
                                    .frame(width: line * 2.4, height: line * 2.4)
                                Capsule().fill(ink.opacity(isDark ? 0.22 : 0.13)).frame(width: window.width * 0.2, height: line)
                            }
                        }
                    }
                    .padding(.top, dot * 2.2)
                    .padding(.leading, dot * 2.2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(isDark ? Color(white: 0.12) : Color.white)
                }
                .frame(width: window.width, height: window.height)
                .clipShape(shape)
                .overlay { shape.strokeBorder(ink.opacity(isDark ? 0.12 : 0.08), lineWidth: 0.5) }
                .shadow(color: .black.opacity(isDark ? 0.3 : 0.08), radius: 2, y: 1)
                .offset(x: padding, y: padding)
            }
            .environment(\.colorScheme, isDark ? .dark : .light)
        }
    }
}

/// A theme as a card of its page: its name in its heading color, and a
/// sentence with bold and a link. Sun and moon say which sides it has.
private struct ThemeCard: View {
    let theme: LotionTheme
    let isDark: Bool
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        let palette = theme.palette(dark: isDark)
        let text = Color(nsColor: palette.text)
        let link = Color(nsColor: palette.accent)
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.s) {
                HStack(alignment: .firstTextBaseline) {
                    Text(theme.name)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color(nsColor: palette.heading == palette.text ? palette.text : palette.heading))
                    Spacer(minLength: Space.s)
                    HStack(spacing: 5) {
                        if theme.hasLight { sideMark("sun.max.fill", inUse: !palette.isDark, palette: palette) }
                        if theme.hasDark { sideMark("moon.fill", inUse: palette.isDark, palette: palette) }
                    }
                }
                Text("Lorem ipsum \(Text("dolor sit amet").bold()), consectetur adipiscing elit. Mauris iaculis \(Text("semper").foregroundStyle(link)) pharetra.")
                    .font(.system(size: 11.5))
                    .lineSpacing(2)
                    .foregroundStyle(text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(nsColor: palette.background), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovering && !isSelected ? 0.2 : 0.1), lineWidth: 0.5)
            }
            .padding(2)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovering = $0 }
        .accessibilityLabel(theme.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The side in use is in the theme's accent; the other is dim.
    private func sideMark(_ symbol: String, inUse: Bool, palette: ThemePalette) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(inUse ? Color(nsColor: palette.accent) : Color(nsColor: palette.marker))
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = theme.palette(dark: colorScheme == .dark)
        let isDark = colorScheme == .dark
        SettingsPage {
            Section("Type") {
                TypePreview(palette: palette, noteFont: noteFont, size: noteFontSize, lineSpacing: lineSpacing, codeFont: codeFont)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                    }
                    .padding(.vertical, 4)
                    .accessibilityHidden(true)
                FontPicker(selection: $noteFont, families: FontChoice.installedFamilies) {
                    SettingsControlLabel("Note font", detail: "The sample above follows every change.")
                }
                LabeledContent {
                    HStack(spacing: 10) {
                        Slider(value: $noteFontSize, in: 12...24, step: 1)
                            .frame(width: 160)
                            .accessibilityLabel("Size")
                            .accessibilityValue("\(Int(noteFontSize)) points")
                        Text("\(Int(noteFontSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                } label: {
                    Text("Size")
                }
                FontPicker(selection: $codeFont, families: FontChoice.monospacedFamilies, designs: [FontChoice.mono]) {
                    SettingsControlLabel("Code font", detail: "Code blocks and inline code.")
                }
            }

            Section("Layout") {
                ChoiceRow("Line spacing", detail: "Room between the lines of a paragraph.") {
                    HStack(spacing: 12) {
                        ForEach(LineSpacing.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: lineSpacing == option, action: { lineSpacing = option }) {
                                Miniature(isDark: isDark, isSelected: lineSpacing == option) { unit, width in
                                    TextLines(unit: unit, width: width, spacing: 1.2 + (option.multiple - 1.4) * 9, count: 3)
                                }
                                .aspectRatio(16 / 10, contentMode: .fit)
                            }
                        }
                    }
                }
                ChoiceRow("Text width", detail: "How wide the column of text runs in a wide window.") {
                    HStack(spacing: 12) {
                        ForEach(ReadableWidth.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: readableWidth == option, action: { readableWidth = option }) {
                                Miniature(isDark: isDark, isSelected: readableWidth == option) { unit, width in
                                    TextLines(unit: unit, width: width * option.fraction, count: 3)
                                        .frame(width: width, alignment: .center)
                                }
                                .aspectRatio(16 / 10, contentMode: .fit)
                            }
                        }
                    }
                }
                ChoiceRow("Tables", detail: "As wide as what's in them, or across the whole column.") {
                    HStack(spacing: 12) {
                        ForEach(TableWidth.allCases) { option in
                            ChoiceTile(title: option.title, isSelected: tableWidth == option, action: { tableWidth = option }) {
                                Miniature(isDark: isDark, isSelected: tableWidth == option) { unit, width in
                                    TablePicture(unit: unit, width: option == .full ? width : width * 0.55)
                                }
                                .aspectRatio(16 / 10, contentMode: .fit)
                            }
                        }
                    }
                }
            }

            Section("Writing") {
                Toggle(isOn: $spellCheck) {
                    SettingsControlLabel("Check spelling while typing", detail: "Underline words the system dictionary doesn't know.")
                }
            }
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



/// A small table: a header row and two rows, two columns.
private struct TablePicture: View {
    let unit: CGFloat
    let width: CGFloat

    var body: some View {
        let row = max(6, unit * 0.13)
        let line = max(1.5, unit * 0.035)
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
                .foregroundStyle(Color(nsColor: palette.text))
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
            Section {
                LabeledContent {
                    Label("Always on", systemImage: "checkmark")
                        .foregroundStyle(.secondary)
                } label: {
                    SettingsControlLabel("Keep images from the web",
                                         detail: "An image linked from the web is saved in the note’s folder the first time it shows, and opens from there after.")
                }
                Toggle(isOn: $saveVideos) {
                    SettingsControlLabel("Save videos for offline viewing",
                                         detail: "Videos from the web play from the web. When this is on, each one is also saved in the note’s folder after it first plays. Videos can be large.")
                }
            } header: {
                Text("Images and Videos")
            } footer: {
                Text("Images and videos you add are copied into the note’s own folder, next to its Markdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Links") {
                Toggle(isOn: $linkPreviews) {
                    SettingsControlLabel("Preview pages on hover",
                                         detail: "Rest the pointer on a link to see the page. Each preview is kept for a week.")
                }
            }
        }
    }
}

// MARK: - Fonts

/// System designs first, then every installed family.
private struct FontPicker<Label: View>: View {
    @Binding var selection: String
    let families: [String]
    var designs: [String] = FontChoice.designs.map(\.id)
    @ViewBuilder var label: () -> Label

    var body: some View {
        Picker(selection: $selection, label: label()) {
            ForEach(designs, id: \.self) { Text(FontChoice.title(for: $0)).tag($0) }
            Divider()
            ForEach(families, id: \.self) { Text($0).tag($0) }
            // Keep a saved family selectable even if it is no longer installed.
            if !designs.contains(selection), !families.contains(selection) {
                Text(selection).tag(selection)
            }
        }
    }
}

private extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}
