//  The settings window: one hot key field and one login-item switch, opened
//  modally from the gear (or from the right-click menu).

import AppKit
import Carbon.HIToolbox
import ServiceManagement

/// A field that records a key combination: click it, press the keys, done.
/// Delete clears it, Escape cancels.
final class ShortcutRecorder: NSButton {
    var onCapture: ((HotKey) -> Void)?

    private var hotKey: HotKey = .none
    private var recording = false

    init() {
        super.init(frame: .zero)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        alignment = .center
        target = self
        action = #selector(startRecording)
        render()
    }

    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorder is created in code only")
    }

    override var acceptsFirstResponder: Bool { true }

    /// The recorder cannot resign while it is waiting for keys, otherwise a
    /// stray click would leave the field showing "press a combination".
    override func resignFirstResponder() -> Bool {
        endRecording()
        return super.resignFirstResponder()
    }

    func set(hotKey: HotKey) {
        self.hotKey = hotKey
        render()
    }

    @objc private func startRecording() {
        recording = true
        window?.makeFirstResponder(self)
        render()
    }

    private func endRecording() {
        guard recording else { return }
        recording = false
        render()
    }

    override func keyDown(with event: NSEvent) {
        guard recording else {
            super.keyDown(with: event)
            return
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            endRecording()
            return
        case kVK_Delete, kVK_ForwardDelete:
            hotKey = .none
            endRecording()
            onCapture?(.none)
            return
        default:
            break
        }

        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        // A bare key would shadow typing everywhere; insist on a modifier.
        guard modifiers != 0 else {
            NSSound.beep()
            return
        }
        var text = event.charactersIgnoringModifiers?.uppercased() ?? ""
        if text.isEmpty { text = Self.keyName(for: UInt32(event.keyCode)) }
        hotKey = HotKey(keyCode: UInt32(event.keyCode), modifiers: modifiers, display: text)
        endRecording()
        onCapture?(hotKey)
    }

    private func render() {
        let text: String
        let colour: NSColor
        if recording {
            text = L10n.recordingHotKey
            colour = .controlAccentColor
        } else if hotKey.isEmpty {
            text = L10n.noHotKey
            colour = .tertiaryLabelColor
        } else {
            text = hotKey.label
            colour = .labelColor
        }
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: colour,
        ])
        layer?.borderColor = (recording ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        render()
    }

    override func mouseDown(with event: NSEvent) {
        // Keep keyboard focus here for the whole recording, not just the click.
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }

    /// Names for the keys whose character is not printable.
    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6,
             kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12:
            return "F\(Int(keyCode) - Int(kVK_F1) + 1)"
        default: return "Key \(keyCode)"
        }
    }
}

final class SettingsWindow: NSObject {
    private let window: NSWindow
    private let recorder = ShortcutRecorder()
    private let appearanceControl = NSSegmentedControl()
    private let loginCheckbox = NSButton(checkboxWithTitle: L10n.launchAtLogin, target: nil, action: nil)
    private let noteLabel = NSTextField(labelWithString: "")
    var onHotKeyChange: ((HotKey) -> Void)?
    var onAppearanceChange: ((AppAppearance) -> Void)?
    var onClose: (() -> Void)?

    var windowNumber: Int { window.windowNumber }

    override init() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 244),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.delegate = self
        build()
    }

    private func build() {
        window.title = L10n.settingsTitle
        window.isReleasedWhenClosed = false

        let content = window.contentView!

        let appearanceLabel = NSTextField(labelWithString: L10n.appearanceLabel)
        appearanceLabel.font = .systemFont(ofSize: 12, weight: .medium)
        appearanceLabel.frame = NSRect(x: 20, y: 208, width: 340, height: 16)

        appearanceControl.segmentCount = 3
        appearanceControl.segmentStyle = .rounded
        appearanceControl.trackingMode = .selectOne
        appearanceControl.controlSize = .regular
        appearanceControl.font = .systemFont(ofSize: 12)
        appearanceControl.setLabel(L10n.appearanceSystem, forSegment: 0)
        appearanceControl.setLabel(L10n.appearanceLight, forSegment: 1)
        appearanceControl.setLabel(L10n.appearanceDark, forSegment: 2)
        appearanceControl.setWidth(108, forSegment: 0)
        appearanceControl.setWidth(88, forSegment: 1)
        appearanceControl.setWidth(88, forSegment: 2)
        appearanceControl.selectedSegment = Self.segment(of: Settings.appearance)
        appearanceControl.target = self
        appearanceControl.action = #selector(appearanceChanged)
        appearanceControl.frame = NSRect(x: 20, y: 174, width: 284, height: 26)

        let appearanceRule = NSBox(frame: NSRect(x: 20, y: 160, width: 340, height: 1))
        appearanceRule.boxType = .separator

        let hotKeyLabel = NSTextField(labelWithString: L10n.hotKeyLabel)
        hotKeyLabel.font = .systemFont(ofSize: 12, weight: .medium)
        hotKeyLabel.frame = NSRect(x: 20, y: 132, width: 340, height: 16)

        recorder.frame = NSRect(x: 20, y: 98, width: 160, height: 26)
        recorder.set(hotKey: Settings.hotKey)
        recorder.onCapture = { [weak self] hotKey in
            guard let self else { return }
            self.onHotKeyChange?(hotKey)
            self.showNote(hotKey.isEmpty ? "" : L10n.hotKeySaved)
        }

        let clear = NSButton(title: L10n.clearHotKey, target: self, action: #selector(clearHotKey))
        clear.bezelStyle = .rounded
        clear.controlSize = .regular
        clear.frame = NSRect(x: 188, y: 98, width: 72, height: 26)

        let hint = NSTextField(labelWithString: L10n.hotKeyHint)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.lineBreakMode = .byTruncatingTail
        hint.frame = NSRect(x: 20, y: 74, width: 340, height: 16)

        let rule = NSBox(frame: NSRect(x: 20, y: 58, width: 340, height: 1))
        rule.boxType = .separator

        loginCheckbox.font = .systemFont(ofSize: 12)
        loginCheckbox.lineBreakMode = .byTruncatingTail
        loginCheckbox.frame = NSRect(x: 20, y: 28, width: 240, height: 20)
        loginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off
        loginCheckbox.target = self
        loginCheckbox.action = #selector(toggleLogin)

        noteLabel.font = .systemFont(ofSize: 11)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.lineBreakMode = .byTruncatingTail
        noteLabel.frame = NSRect(x: 20, y: 8, width: 240, height: 16)

        let done = NSButton(title: L10n.done, target: self, action: #selector(close))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 292, y: 6, width: 68, height: 26)

        // Escape closes too, without a visible second button.
        let cancel = NSButton(title: L10n.done, target: self, action: #selector(close))
        cancel.keyEquivalent = "\u{1b}"
        cancel.isHidden = true
        content.addSubview(cancel)

        for view in [appearanceLabel, appearanceControl, appearanceRule,
                     hotKeyLabel, recorder, clear, hint, rule,
                     loginCheckbox, noteLabel, done] {
            content.addSubview(view)
        }
    }

    func run() {
        window.center()
        NSApp.runModal(for: window)
    }

    deinit { window.delegate = nil }

    private static func segment(of appearance: AppAppearance) -> Int {
        switch appearance {
        case .system: return 0
        case .light: return 1
        case .dark: return 2
        }
    }

    @objc private func appearanceChanged() {
        let appearance: AppAppearance
        switch appearanceControl.selectedSegment {
        case 1: appearance = .light
        case 2: appearance = .dark
        default: appearance = .system
        }
        onAppearanceChange?(appearance)
    }

    @objc private func clearHotKey() {
        recorder.set(hotKey: .none)
        onHotKeyChange?(.none)
        showNote("")
    }

    @objc private func toggleLogin() {
        let wants = loginCheckbox.state == .on
        if let error = LaunchAtLogin.set(wants) {
            loginCheckbox.state = wants ? .off : .on
            showNote(error)
        } else {
            showNote("")
        }
    }

    @objc private func close() {
        onClose?()
        NSApp.stopModal()
        window.orderOut(nil)
    }

    private func showNote(_ text: String) {
        noteLabel.stringValue = text
    }
}

extension SettingsWindow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        close()
    }
}

/// Launch at login through SMAppService, which needs the app to live in a
/// stable place (a copy in /tmp or a build folder gets refused).
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) -> String? {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return L10n.launchAtLoginFailed
        }
    }
}
