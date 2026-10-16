//  Status item, popover, refresh loop, and the three actions (terminate,
//  terminate all, copy URL). One rule runs through all of it: signals only
//  ever go to processes this user owns.

import AppKit
import Carbon.HIToolbox

enum AppInfo {
    /// The executable, as typed on a command line.
    static let name = "PortBuddy"
    /// What the Finder, the menus and every message call it.
    static let displayName = "PortBuddy"
    static let version = "1.0.0"
}

struct Flags {
    var show = false
    var appearance: NSAppearance.Name?
    var selftestPort: Int?
    var selftestFilter: String?
    var armPort: Int?
    var filter: String?
    var openSettings = false
    var setDefaultHotKey = false
    var debugFrame: String?

    static func parse(_ arguments: [String]) -> Flags {
        var flags = Flags()
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--show":
                flags.show = true
            case "--settings":
                flags.openSettings = true
            case "--hotkey":
                flags.setDefaultHotKey = true
            case "--arm" where index + 1 < arguments.count:
                flags.armPort = Int(arguments[index + 1])
                index += 1
            case "--filter" where index + 1 < arguments.count:
                let value = arguments[index + 1]
                flags.filter = value.lowercased() == "all" ? "" : value
                index += 1
            case "--debug-frame":
                // Optional path: when the app is started with `open`, stdout
                // goes nowhere useful.
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    flags.debugFrame = arguments[index + 1]
                    index += 1
                } else {
                    flags.debugFrame = ""
                }
            case "--appearance" where index + 1 < arguments.count:
                flags.appearance = arguments[index + 1].lowercased() == "dark" ? .darkAqua : .aqua
                index += 1
            case "--selftest-click" where index + 1 < arguments.count:
                flags.selftestPort = Int(arguments[index + 1])
                index += 1
            case "--selftest-filter" where index + 1 < arguments.count:
                flags.selftestFilter = arguments[index + 1]
                index += 1
            default:
                break
            }
            index += 1
        }
        return flags
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let flags: Flags
    private var statusItem: NSStatusItem?
    private let hotKeys = HotKeyManager()
    private var settingsWindow: SettingsWindow?
    private let popover = NSPopover()
    private let panel = PortPanel(frame: NSRect(x: 0, y: 0, width: PortPanel.contentWidth, height: 100))
    private var entries: [PortEntry] = []
    private var rendered: [PortEntry] = []
    private var scanTimer: Timer?
    private var scanning = false
    private var lastScan = Date.distantPast
    private var lastPopoverClose: Date?

    init(flags: Flags) {
        self.flags = flags
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let override = flags.appearance {
            NSApp.appearance = NSAppearance(named: override)
        } else {
            applySettingsAppearance()
        }
        installMainMenu()
        setUpStatusItem()
        setUpPopover()
        if flags.setDefaultHotKey {
            Settings.hotKey = HotKey(keyCode: 35, modifiers: UInt32(cmdKey | optionKey), display: "P")
        }
        hotKeys.onPress = { [weak self] in self?.togglePanel() }
        reloadHotKey(reportingToStdout: flags.setDefaultHotKey)
        refresh(minInterval: 0)

        scanTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refresh(minInterval: self.popover.isShown ? 1.8 : 5)
        }

        if flags.openSettings {
            openSettings()
        } else if let name = flags.selftestFilter {
            runFilterSelftest(name: name)
        } else if let port = flags.selftestPort {
            runSelftest(port: port)
        } else if flags.show {
            // Showing during didFinishLaunching races the menu bar window the
            // status item lives in; give it a beat.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.showPopover()
            }
            if let filter = flags.filter {
                // Applied after the first scan: earlier it looks like a group
                // that does not exist yet, and the panel drops it again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
                    guard let self else { return }
                    self.panel.applyFilter(filter.isEmpty ? nil : filter)
                    self.renderPanel(self.entries)
                }
            }
            if let armPort = flags.armPort {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                    self?.panel.terminateButton(port: armPort)?.arm(autoDisarmAfter: 120)
                }
            }
        }
        if flags.debugFrame != nil {
            printFrames()
        }
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = PortGlyph.statusImage()
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        button.image = PortGlyph.statusImage()
        let mine = entries.filter { !$0.isSystem }.count
        button.attributedTitle = NSAttributedString(string: mine > 0 ? "\(mine)" : "", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        button.toolTip = L10n.statusTip(mine: mine)
    }

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.modifierFlags.contains(.control) ?? false) {
            showContextMenu()
            return
        }
        togglePanel()
    }

    /// Same door for the status item click and the global hot key.
    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        // A transient popover closes on the mouse-down that lands outside it,
        // so this same click reaches the button afterwards. Reopening here
        // would make the item feel like it ignores the second click.
        if let closed = lastPopoverClose, Date().timeIntervalSince(closed) < 0.25 { return }
        showPopover()
    }

    // MARK: - Settings and the hot key

    private func applySettingsAppearance() {
        NSApp.appearance = Settings.appearance.appearanceName.flatMap(NSAppearance.init(named:))
    }

    private func reloadHotKey(reportingToStdout: Bool = false) {
        let hotKey = Settings.hotKey
        let error = hotKeys.register(hotKey)
        if reportingToStdout {
            if let error {
                print("hotkey: \(hotKey.label) — \(error)")
            } else {
                print("hotkey: \(hotKey.isEmpty ? "none" : hotKey.label) registered")
            }
            fflush(stdout)
        }
        if let error, !reportingToStdout {
            let alert = NSAlert()
            alert.messageText = L10n.hotKeyConflict
            alert.informativeText = error
            alert.addButton(withTitle: L10n.done)
            alert.runModal()
        }
    }

    /// Settings are modal, and while they are up the hot key is unregistered
    /// so the current combination can be recorded again.
    func openSettings() {
        hotKeys.unregister()
        let window = SettingsWindow()
        settingsWindow = window
        window.onHotKeyChange = { [weak self] hotKey in
            Settings.hotKey = hotKey
            self?.reloadHotKey()
        }
        window.onAppearanceChange = { [weak self] appearance in
            Settings.appearance = appearance
            self?.applySettingsAppearance()
        }
        window.onClose = { [weak self] in
            self?.reloadHotKey()
            self?.settingsWindow = nil
        }
        if let path = flags.debugFrame, !path.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                try? (existing + "settings: \(window.windowNumber)\n")
                    .write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        NSApp.activate(ignoringOtherApps: true)   // a settings window may take focus
        window.run()
    }

    private func showContextMenu() {
        guard let button = statusItem?.button else { return }
        let menu = NSMenu()
        let refreshItem = NSMenuItem(title: L10n.refreshTip, action: #selector(contextRefresh), keyEquivalent: "")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let settingsItem = NSMenuItem(title: L10n.settingsTitle, action: #selector(contextSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    @objc private func contextRefresh() {
        refresh(minInterval: 0)
    }

    @objc private func contextSettings() {
        openSettings()
    }

    /// An LSUIElement app has no menu bar of its own, but key equivalents
    /// still route through NSApp.mainMenu — without this, ⌘Q does nothing.
    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    // MARK: - Popover

    private func setUpPopover() {
        let controller = NSViewController()
        controller.view = panel
        popover.contentViewController = controller
        popover.behavior = .transient
        popover.delegate = self

        panel.onKill = { [weak self] entry, force in self?.terminate(entry, force: force) }
        panel.onKillAll = { [weak self] in self?.terminateAll() }
        panel.onRefresh = { [weak self] in self?.refresh(minInterval: 0) }
        panel.onFilterChange = { [weak self] in
            guard let self else { return }
            self.renderPanel(self.entries)
        }
        panel.onOpenSettings = { [weak self] in self?.openSettings() }
        panel.onCopy = { entry in
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString("http://localhost:\(entry.port)", forType: .string)
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        renderPanel(entries)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // The popover is a child of the menu bar window and would otherwise
        // inherit its appearance instead of the app-wide one. Its own backdrop
        // view caches its appearance, so walk the tree and tell every view.
        if let appearance = flags.appearance {
            let resolved = NSAppearance(named: appearance)
            popover.contentViewController?.view.window?.appearance = resolved
            if let root = popover.contentViewController?.view.window?.contentView {
                apply(appearance: resolved, to: root)
            }
        }
        // Deliberately no NSApp.activate: a status bar panel that pulls
        // keyboard focus out of whatever you were typing in is a rude panel.
        refresh(minInterval: 0)
    }

    func popoverDidClose(_ notification: Notification) {
        lastPopoverClose = Date()
        // Every terminate button forgets it was armed once the panel closes.
        panel.disarmAll()
    }

    private func apply(appearance: NSAppearance?, to view: NSView) {
        view.appearance = appearance
        for subview in view.subviews { apply(appearance: appearance, to: subview) }
    }

    // MARK: - Refresh

    private func refresh(minInterval: TimeInterval) {
        guard !scanning else { return }
        guard minInterval <= 0 || Date().timeIntervalSince(lastScan) >= minInterval else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let scanned = PortScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.scanning = false
                self.lastScan = Date()
                self.entries = scanned
                self.updateStatusItem()
                // Rebuild rows only when the socket list actually changed:
                // a rebuild would drop the armed state of a terminate button
                // that is waiting for its second click.
                if self.popover.isShown, scanned != self.rendered {
                    self.renderPanel(scanned)
                }
            }
        }
    }

    private func renderPanel(_ list: [PortEntry]) {
        rendered = list
        let height = panel.render(list)
        popover.contentSize = NSSize(width: PortPanel.contentWidth, height: height)
        reassertPanelFrame(height: height)
    }

    /// 把面板摆回 popover 该放的位置（内容四周 13pt 内缩，居中）。
    /// 用户 2026-10-16 早上的截图：整块内容往下掉了一个内缩、最后一行被切 —— 面板
    /// （popover 的内容视图）被落到了 (0,0)（NSPopoverFrame 是**非翻转**的，那是左下角），
    /// 而 AppKit 不是每次都把它摆回去。平时这一条是空操作；窗口尺寸与预期不符时不猜。
    private func reassertPanelFrame(height: CGFloat) {
        guard let sv = panel.superview else { return }
        let w = PortPanel.contentWidth
        let inset = max(0, (sv.bounds.width - w) / 2)
        guard inset > 0,
              abs(sv.bounds.height - (height + inset * 2)) < 1 else { return }
        let want = NSRect(x: inset, y: inset, width: w, height: height)
        if panel.frame != want || panel.bounds.origin != .zero {
            panel.bounds = NSRect(origin: .zero, size: panel.bounds.size)
            panel.frame = want
        }
    }

    // MARK: - Kill

    private func terminate(_ entry: PortEntry, force: Bool) {
        guard entry.canKill else { return }
        if Darwin.kill(entry.pid, force ? SIGKILL : SIGTERM) != 0 {
            NSLog("%@: kill(%d) failed: %s", AppInfo.name, entry.pid, strerror(errno))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refresh(minInterval: 0)
        }
    }

    /// Terminate-all carries the same two-step shape as a single row: the
    /// header button arms itself, and only the second click sends signals.
    /// Acts on the rows on screen: when the panel is filtered to one project,
    /// "terminate all" means that project.
    private func terminateAll() {
        let targets = panel.visible.filter { $0.canKill }
        guard !targets.isEmpty else { return }
        for target in targets {
            Darwin.kill(target.pid, SIGTERM)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.refresh(minInterval: 0)
        }
    }

    // MARK: - Debug / self-test entry points

    /// Opens the popover and clicks the real terminate button of one row —
    /// twice, since the first click only arms it — then checks the socket is
    /// gone. Used by the build check; needs no mouse and no permissions.
    private func runSelftest(port: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let button = self.panel.terminateButton(port: port) else {
                    print("selftest: no terminate button for :\(port) — FAIL")
                    fflush(stdout)
                    exit(3)
                }
                button.performClick(nil)                 // arm
                guard button.armed else {
                    print("selftest: first click did not arm :\(port) — FAIL")
                    fflush(stdout)
                    exit(4)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    button.performClick(nil)             // fire
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                    let alive = PortScanner.scan().contains { $0.port == port }
                    print(alive ? "selftest: :\(port) still listening — FAIL"
                                : "selftest: :\(port) terminated — OK")
                    fflush(stdout)
                    exit(alive ? 1 : 0)
                }
            }
        }
    }

    /// Opens the popover, clicks the real name button of a row carrying that
    /// name, and checks the panel narrowed to it.
    private func runFilterSelftest(name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.showPopover()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                guard let entry = self.entries.first(where: { $0.displayName == name }),
                      let button = self.panel.nameButton(port: entry.port) else {
                    print("selftest-filter: no name button for \(name) — FAIL")
                    fflush(stdout)
                    exit(3)
                }
                let before = self.panel.visible.count
                button.performClick(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let shown = self.panel.visible
                    let onlyThis = !shown.isEmpty && shown.allSatisfy { $0.displayName == name }
                    let pass = self.panel.activeFilter == name && onlyThis && shown.count < before
                    print("selftest-filter: rows \(before) → \(shown.count), only \"\(name)\": \(onlyThis) — \(pass ? "OK" : "FAIL")")
                    fflush(stdout)
                    exit(pass ? 0 : 1)
                }
            }
        }
    }

    /// Writes both window frames (screen coordinates, bottom-left origin) for
    /// the screenshot tooling, then keeps running.
    private func printFrames() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            var lines: [String] = []
            if let button = self.statusItem?.button, let window = button.window {
                let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
                lines.append("status: \(Int(rect.origin.x)),\(Int(rect.origin.y)),\(Int(rect.width)),\(Int(rect.height))")
            }
            if let frame = self.popover.contentViewController?.view.window?.frame {
                lines.append("popover: \(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))")
                lines.append("popoverWindow: \(self.popover.contentViewController?.view.window?.windowNumber ?? 0)")
            }
            let popoverWindow = self.popover.contentViewController?.view.window
            lines.append("shown: \(self.popover.isShown) appActive: \(NSApp.isActive) popoverKey: \(popoverWindow?.isKeyWindow ?? false) style: \(popoverWindow.map { String($0.styleMask.rawValue, radix: 16) } ?? "-")")
            if let armPort = self.flags.armPort {
                let button = self.panel.terminateButton(port: armPort)
                lines.append("arm \(armPort): button \(button != nil) armed \(button?.armed ?? false)")
            }
            lines.append("language: \(L10n.language)")
            lines.append("appearance: \(self.popover.contentViewController?.view.effectiveAppearance.name.rawValue ?? "?") (app: \(NSApp.appearance?.name.rawValue ?? "system"))")
            let text = lines.joined(separator: "\n") + "\n"
            if let path = self.flags.debugFrame, !path.isEmpty {
                try? text.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                print(text, terminator: "")
                fflush(stdout)
            }
        }
    }
}
