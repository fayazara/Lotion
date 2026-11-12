//
//  GlobalHotKey.swift
//  Lotion
//
//  The shortcut that shows the quick note pane from any app. Carbon's hot
//  keys need no Accessibility permission and work in the sandbox; the key
//  is taken before the frontmost app sees it.
//

import AppKit
import Carbon.HIToolbox

/// A key with modifiers, as recorded in Settings.
nonisolated struct KeyShortcut: Codable, Equatable, Sendable {
    var keyCode: UInt32
    /// `NSEvent.ModifierFlags`, device-independent bits only.
    var modifiers: UInt
    /// The key's character as typed, for showing the shortcut.
    var key: String

    static let quickNoteDefault = KeyShortcut(keyCode: UInt32(kVK_ANSI_N), modifiers: NSEvent.ModifierFlags([.control, .option]).rawValue, key: "N")

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var carbonModifiers: UInt32 {
        var flags: UInt32 = 0
        if modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        return flags
    }

    /// "⌃⌥N", in the order the menus use.
    var display: String {
        var out = ""
        if modifierFlags.contains(.control) { out += "⌃" }
        if modifierFlags.contains(.option) { out += "⌥" }
        if modifierFlags.contains(.shift) { out += "⇧" }
        if modifierFlags.contains(.command) { out += "⌘" }
        return out + key
    }

    /// A shortcut from a key press, or nil when it has no ⌘, ⌃ or ⌥: a
    /// shortcut taken from every app must not be plain typing.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        self.keyCode = UInt32(event.keyCode)
        self.modifiers = flags.rawValue
        self.key = Self.name(for: event)
    }

    init(keyCode: UInt32, modifiers: UInt, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    private static func name(for event: NSEvent) -> String {
        if let function = fKeys[Int(event.keyCode)] { return function }
        switch Int(event.keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        default: break
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        return characters.isEmpty ? "Key \(event.keyCode)" : characters.uppercased()
    }

    private static let fKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]
}

@MainActor extension KeyShortcut {
    private static let defaultsKey = "quickNoteShortcut"

    /// The quick note shortcut: the default until one is recorded, nil once
    /// it has been cleared.
    static var quickNote: KeyShortcut? {
        get {
            guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return quickNoteDefault }
            return (try? JSONDecoder().decode(Stored.self, from: data))?.shortcut ?? nil
        }
        set {
            if let data = try? JSONEncoder().encode(Stored(shortcut: newValue)) {
                UserDefaults.standard.set(data, forKey: defaultsKey)
            }
            GlobalHotKey.quickNote.register(newValue)
        }
    }

    private struct Stored: Codable { var shortcut: KeyShortcut? }
}

/// One system-wide hot key.
final class GlobalHotKey {
    static let quickNote = GlobalHotKey(id: 1)

    var onPress: (() -> Void)?
    private(set) var shortcut: KeyShortcut?
    private let id: UInt32
    private var reference: EventHotKeyRef?
    /// While Settings records a new shortcut, the old one must not fire.
    var isSuspended = false {
        didSet { if isSuspended != oldValue { isSuspended ? unregister() : register(shortcut) } }
    }

    private static var handlerInstalled = false
    private static var byID: [UInt32: GlobalHotKey] = [:]
    private nonisolated static let signature: OSType = 0x4C4F544E // "LOTN"

    private init(id: UInt32) {
        self.id = id
        Self.byID[id] = self
    }

    func register(_ shortcut: KeyShortcut?) {
        unregister()
        self.shortcut = shortcut
        guard let shortcut, !isSuspended else { return }
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        if status != noErr { reference = nil }
    }

    /// False when another app already holds the shortcut.
    var isRegistered: Bool { reference != nil }

    private func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == GlobalHotKey.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotKey.byID[id]?.onPress?() }
            }
            return noErr
        }, 1, &type, nil, nil)
    }
}
