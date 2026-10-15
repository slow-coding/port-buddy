//  A global hot key, registered with Carbon's RegisterEventHotKey.
//
//  Carbon because it is the only way to get a system-wide hot key without
//  asking for Accessibility permission, and this app has no business asking
//  for that.

import AppKit
import Carbon.HIToolbox
import Foundation

struct HotKey: Equatable {
    var keyCode: UInt32
    var modifiers: UInt32        // Carbon mask: cmdKey, optionKey, shiftKey, controlKey
    var display: String          // what the recorder saw, e.g. "⌥⌘P"

    static let none = HotKey(keyCode: 0, modifiers: 0, display: "")

    var isEmpty: Bool { modifiers == 0 && keyCode == 0 }

    /// "⌃⌥⇧⌘" in the order macOS prints them.
    var modifierSymbols: String {
        var text = ""
        if modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        return text
    }

    var label: String { isEmpty ? "" : modifierSymbols + display }
}

final class HotKeyManager {
    /// Called on the main thread when the hot key fires.
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: HotKey = .none

    /// Returns an error string when the system refuses the combination —
    /// usually because another app already owns it.
    @discardableResult
    func register(_ hotKey: HotKey) -> String? {
        unregister()
        guard !hotKey.isEmpty else { return nil }

        var hotKeyID = EventHotKeyID(signature: OSType(0x50_53_42_52), id: 1)  // 'PSBR'
        let status = RegisterEventHotKey(hotKey.keyCode, hotKey.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onPress?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        guard status == noErr else {
            hotKeyRef = nil
            return status == eventHotKeyExistsErr ? L10n.hotKeyConflict
                                                  : L10n.hotKeyFailed
        }
        registered = hotKey
        return nil
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        if let handlerRef { RemoveEventHandler(handlerRef) }
        handlerRef = nil
        registered = .none
    }

    deinit { unregister() }
}

/// What the panel looks like: follow the system, or force one appearance.
enum AppAppearance: String {
    case system
    case light
    case dark

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

// MARK: - Persistence

/// Settings live in UserDefaults (unlike the panel filter, which is session
/// state on purpose).
enum Settings {
    private static let keyCodeKey = "hotKeyCode"
    private static let modifiersKey = "hotKeyModifiers"
    private static let displayKey = "hotKeyDisplay"

    private static let appearanceKey = "appearance"

    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: appearanceKey) }
    }

    static var hotKey: HotKey {
        get {
            let defaults = UserDefaults.standard
            guard defaults.object(forKey: modifiersKey) != nil else { return .none }
            return HotKey(keyCode: UInt32(defaults.integer(forKey: keyCodeKey)),
                          modifiers: UInt32(defaults.integer(forKey: modifiersKey)),
                          display: defaults.string(forKey: displayKey) ?? "")
        }
        set {
            let defaults = UserDefaults.standard
            if newValue.isEmpty {
                defaults.removeObject(forKey: keyCodeKey)
                defaults.removeObject(forKey: modifiersKey)
                defaults.removeObject(forKey: displayKey)
            } else {
                defaults.set(Int(newValue.keyCode), forKey: keyCodeKey)
                defaults.set(Int(newValue.modifiers), forKey: modifiersKey)
                defaults.set(newValue.display, forKey: displayKey)
            }
        }
    }
}
