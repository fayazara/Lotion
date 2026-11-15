//
//  Icons.swift
//  Lotion
//
//  The app's icons are Hugeicons (https://hugeicons.com), shipped as custom
//  symbols in Assets.xcassets/Hugeicons so they scale with the font, take
//  weights and tints, and animate like SF Symbols. Code still names icons by
//  their SF Symbol name — so do saved note and folder icons — and these
//  helpers draw the Hugeicon that stands in for it (see `Hugeicons.symbols`),
//  or the SF Symbol itself when there isn't one.
//

import AppKit
import SwiftUI

enum AppIcon {
    /// The custom symbol drawn for an SF Symbol name, if Hugeicons has one.
    static func hugeicon(for name: String) -> String? { Hugeicons.symbols[name] }
}

extension NSImage {
    /// The app's icon for an SF Symbol name: its Hugeicon, or the SF Symbol.
    /// A `hugeicon:` or `brand:` name, picked for a note or folder, draws
    /// from its catalog.
    convenience init?(icon name: String, accessibilityDescription: String? = nil) {
        if let (catalog, catalogName) = IconCatalog.resolve(name) {
            guard let image = catalog.image(catalogName) else { return nil }
            self.init(size: image.size, flipped: false) { image.draw(in: $0); return true }
            isTemplate = true
            self.accessibilityDescription = accessibilityDescription
        } else if let hugeicon = AppIcon.hugeicon(for: name) {
            self.init(symbolName: hugeicon, bundle: .main, variableValue: 0)
            self.accessibilityDescription = accessibilityDescription
        } else {
            self.init(systemSymbolName: name, accessibilityDescription: accessibilityDescription)
        }
    }
}

extension Image {
    /// The app's icon for an SF Symbol name: its Hugeicon, or the SF Symbol.
    init(icon name: String) {
        if let hugeicon = AppIcon.hugeicon(for: name) { self.init(hugeicon) } else { self.init(systemName: name) }
    }
}

// Built from Label's own image initializers rather than a custom icon view,
// so toolbars and menus can still lift the image out of the label.
extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, icon: String) {
        if let hugeicon = AppIcon.hugeicon(for: icon) {
            self.init(titleKey, image: hugeicon)
        } else {
            self.init(titleKey, systemImage: icon)
        }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: String) {
        if let hugeicon = AppIcon.hugeicon(for: icon) {
            self.init(title, image: hugeicon)
        } else {
            self.init(title, systemImage: icon)
        }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(titleKey, icon: icon) }
    }

    @_disfavoredOverload
    init<S: StringProtocol>(_ title: S, icon: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) { SwiftUI.Label(title, icon: icon) }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ titleKey: LocalizedStringKey, icon: String, @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(titleKey, icon: icon) }
    }
}
