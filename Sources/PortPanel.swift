//  Everything inside the popover: header (filter, refresh, terminate-all) and
//  one row per listening socket that belongs to this user.
//
//  System daemons are not listed at all. Processes of the same project repeat
//  (one dev server per port), so the header carries a filter that narrows the
//  list to a single project or app.
//
//  Laid out with manual frames against a fixed 300pt width: the panel is a
//  short fixed-size list and manual frames make the popover height exact,
//  which Auto Layout inside NSScrollView does not give for free.

import AppKit

class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

final class PortPanel: FlippedView {
    static let contentWidth: CGFloat = 300

    private let headerHeight: CGFloat = 32
    private let rowHeight: CGFloat = 26
    private let listTopPadding: CGFloat = 4
    private let maxListHeight: CGFloat = 420
    private let bottomPadding: CGFloat = 10

    var onKill: ((PortEntry, Bool) -> Void)?
    var onKillAll: (() -> Void)?
    var onRefresh: (() -> Void)?
    var onCopy: ((PortEntry) -> Void)?
    /// Called after the user picks another group; the owner re-renders.
    var onFilterChange: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    /// nil means every group is shown.
    private(set) var activeFilter: String?
    /// The rows currently on screen, in order — what "terminate all" acts on.
    private(set) var visible: [PortEntry] = []

    private let refreshButton = NSButton()
    private let settingsButton = NSButton()
    private let filterButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scrollView = NSScrollView()
    private let listView = FlippedView()
    private var rowButtons: [Int: TerminateButton] = [:]
    private var nameButtons: [Int: NSButton] = [:]
    /// Which row (pid:port) is waiting for its second click. Held here rather
    /// than only inside the button so a row rebuild does not lose it.
    private var armedKey: String?

    private lazy var killAllButton: TerminateButton = {
        let button = TerminateButton(idle: L10n.killAll, armed: L10n.killAllConfirm,
                                     frame: NSRect(x: 0, y: 0, width: 96, height: 22))
        button.toolTip = L10n.terminateAllTip
        button.onFire = { [weak self] _ in self?.onKillAll?() }
        button.onArmChange = { [weak self, weak button] armed in
            guard let self, let button, armed else { return }
            self.disarm(except: button)
        }
        return button
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildChrome()
    }

    required init?(coder: NSCoder) {
        fatalError("PortPanel is created in code only")
    }

    // MARK: - Chrome

    private func buildChrome() {
        // Opaque panel. The popover's own backdrop is a translucent material:
        // over a dark wallpaper the light appearance turns grey and the text
        // stops carrying. Filling the panel keeps both appearances clean.
        wantsLayer = true
        layer?.cornerRadius = 11
        layer?.masksToBounds = false
        applyBackground()

        refreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: L10n.refreshTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        refreshButton.isBordered = false
        refreshButton.contentTintColor = .secondaryLabelColor
        refreshButton.toolTip = L10n.refreshTip
        refreshButton.target = self
        refreshButton.action = #selector(refreshClicked)

        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: L10n.settingsTip)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
        settingsButton.isBordered = false
        settingsButton.contentTintColor = .secondaryLabelColor
        settingsButton.toolTip = L10n.settingsTip
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked)

        filterButton.controlSize = .small
        filterButton.font = .systemFont(ofSize: 11)
        filterButton.bezelStyle = .rounded
        filterButton.target = self
        filterButton.action = #selector(filterChanged)

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = listView

        for view in [filterButton, refreshButton, settingsButton, killAllButton] { addSubview(view) }
        addSubview(scrollView)
    }

    // MARK: - Render

    /// Dynamic colours must be resolved against this view's own appearance:
    /// resolving them at init (no window yet) can bake in the light variant
    /// and then never change, because an already-dark view gets no
    /// appearance notification.
    private func applyBackground() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyBackground()
    }

    /// Rebuilds every row and returns the height the popover needs.
    @discardableResult
    func render(_ entries: [PortEntry]) -> CGFloat {
        rowButtons.removeAll()
        nameButtons.removeAll()
        for view in listView.subviews { view.removeFromSuperview() }

        let mine = entries.filter { !$0.isSystem }
        let groups = Self.groups(of: mine)
        if let active = activeFilter, !groups.contains(where: { $0.name == active }) {
            activeFilter = nil   // the group left the table, fall back to all
        }
        rebuildFilterMenu(groups, total: mine.count)

        visible = activeFilter.map { name in mine.filter { $0.displayName == name } } ?? mine

        var y: CGFloat = listTopPadding
        for entry in visible {
            y = addRow(entry, at: y)
        }
        if visible.isEmpty {
            y = addEmptyState(at: 0)
        }

        if let armedKey, let entry = entries.first(where: { key($0) == armedKey }),
           let button = rowButtons[entry.port] {
            button.arm(autoDisarmAfter: 2.5)
        }

        let listHeight = min(max(y, 44), maxListHeight)
        listView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: y)
        scrollView.frame = NSRect(x: 0, y: headerHeight + 1, width: Self.contentWidth, height: listHeight)

        killAllButton.frame = NSRect(x: Self.contentWidth - 12 - 88, y: 5, width: 88, height: 22)
        settingsButton.frame = NSRect(x: killAllButton.frame.minX - 8 - 20, y: 5, width: 20, height: 22)
        refreshButton.frame = NSRect(x: settingsButton.frame.minX - 6 - 20, y: 5, width: 20, height: 22)
        filterButton.frame = NSRect(x: 12, y: 5, width: refreshButton.frame.minX - 8 - 12, height: 22)

        let height = headerHeight + 1 + listHeight + bottomPadding
        frame = NSRect(origin: .zero, size: NSSize(width: Self.contentWidth, height: height))
        return height
    }

    /// The groups a filter can pick: one per project or app name, in list
    /// order, which is port order.
    private static func groups(of entries: [PortEntry]) -> [(name: String, count: Int)] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for entry in entries {
            let name = entry.displayName
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { (name: $0, count: counts[$0] ?? 0) }
    }

    private func rebuildFilterMenu(_ groups: [(name: String, count: Int)], total: Int) {
        let menu = NSMenu()
        let all = NSMenuItem(title: "\(L10n.filterAll) · \(total)", action: nil, keyEquivalent: "")
        all.representedObject = nil
        menu.addItem(all)
        for group in groups {
            let item = NSMenuItem(title: "\(group.name) · \(group.count)", action: nil, keyEquivalent: "")
            item.representedObject = group.name
            menu.addItem(item)
        }
        menu.addItem(.separator())
        for item in menu.items where item.representedObject as? String == activeFilter {
            item.state = .on
        }
        if activeFilter == nil, let first = menu.items.first {
            first.state = .on
        }
        filterButton.menu = menu
        // Never disable it: with a filter on, the popup is the way back to
        // "all", and greying it out reads as a broken control.
        filterButton.isEnabled = true
        filterButton.toolTip = L10n.filterTip
    }

    func terminateButton(port: Int) -> TerminateButton? { rowButtons[port] }

    func nameButton(port: Int) -> NSButton? { nameButtons[port] }

    /// Sets the filter without going through the menu (debug entry point).
    func applyFilter(_ name: String?) {
        activeFilter = name
    }

    func disarmAll() {
        killAllButton.disarm()
        for button in rowButtons.values { button.disarm() }
    }

    private func key(_ entry: PortEntry) -> String { "\(entry.pid):\(entry.port)" }

    private func disarm(except keep: TerminateButton) {
        if killAllButton !== keep { killAllButton.disarm() }
        for button in rowButtons.values where button !== keep { button.disarm() }
    }

    private func addRow(_ entry: PortEntry, at y: CGFloat) -> CGFloat {
        let row = PortRow(entry: entry)
        row.frame = NSRect(x: 0, y: y, width: Self.contentWidth, height: rowHeight)
        row.onKill = { [weak self] entry, force in self?.onKill?(entry, force) }
        row.onCopy = { [weak self] entry in self?.onCopy?(entry) }
        // Clicking a name filters to it; clicking the same name again clears
        // the filter, so the way out is always under the pointer.
        row.onFilter = { [weak self] name in
            guard let self else { return }
            self.activeFilter = self.activeFilter == name ? nil : name
            self.disarmAll()
            self.armedKey = nil
            self.onFilterChange?()
        }
        listView.addSubview(row)
        if let button = row.nameButton { nameButtons[entry.port] = button }
        if let button = row.terminateButton {
            button.identifier = NSUserInterfaceItemIdentifier("terminate-\(entry.port)")
            let entryKey = key(entry)
            button.onArmChange = { [weak self, weak button] armed in
                guard let self, let button else { return }
                if armed {
                    self.disarm(except: button)
                    self.armedKey = entryKey
                } else if self.armedKey == entryKey {
                    self.armedKey = nil
                }
            }
            rowButtons[entry.port] = button
        }
        return y + rowHeight
    }

    private func addEmptyState(at y: CGFloat) -> CGFloat {
        let label = NSTextField(labelWithString: L10n.empty)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.frame = NSRect(x: 0, y: y + 14, width: Self.contentWidth, height: 16)
        listView.addSubview(label)
        return y + 44
    }

    // MARK: - Actions

    @objc private func refreshClicked() { onRefresh?() }

    @objc private func settingsClicked() { onOpenSettings?() }

    @objc private func filterChanged() {
        activeFilter = filterButton.selectedItem?.representedObject as? String
        disarmAll()
        armedKey = nil
        onFilterChange?()
    }
}

// MARK: - Terminate button

/// Two-step terminate control: the first click arms it (capsule turns red),
/// the second click fires, and it falls back to idle on its own after three
/// seconds. Nothing modal, nothing to dismiss.
final class TerminateButton: NSButton {
    var onArmChange: ((Bool) -> Void)?
    var onFire: ((Bool) -> Void)?

    private let idleTitle: String
    private let armedTitle: String
    private var disarmTimer: Timer?
    private var trackingArea: NSTrackingArea?
    private var hovered = false
    private(set) var armed = false

    init(idle: String, armed: String, frame: NSRect) {
        self.idleTitle = idle
        self.armedTitle = armed
        super.init(frame: frame)
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = frame.height / 2
        alignment = .center
        target = self
        action = #selector(clicked)
        applyStyle()
    }

    required init?(coder: NSCoder) {
        fatalError("TerminateButton is created in code only")
    }

    func disarm() {
        disarmTimer?.invalidate()
        disarmTimer = nil
        guard armed else { return }
        armed = false
        applyStyle()
        onArmChange?(false)
    }

    /// Arms without a click, so screenshots (and later a keyboard path) can
    /// show the confirmation state.
    func arm(autoDisarmAfter seconds: TimeInterval = 3) {
        guard !armed else { return }
        armed = true
        applyStyle()
        disarmTimer?.invalidate()
        disarmTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            self?.disarm()
        }
        onArmChange?(true)
    }

    @objc private func clicked() {
        let force = NSApp.currentEvent?.modifierFlags.contains(.option) ?? false
        if armed {
            disarm()
            onFire?(force)
        } else {
            arm()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyStyle()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    /// Layer colours are CGColors, so they never update on their own; resolve
    /// them against this button's own appearance every time.
    private func applyStyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance { resolveStyle() }
    }

    private func resolveStyle() {
        // One capsule, three surfaces. Red shows up only when the click is
        // actually pending: idle is neutral, hover warms up, armed is a
        // solid red capsule with white type.
        attributedTitle = NSAttributedString(string: armed ? armedTitle : idleTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: armed ? .semibold : .medium),
            .foregroundColor: armed ? NSColor.white
                                   : (hovered ? NSColor.labelColor : NSColor.secondaryLabelColor),
        ])
        if armed {
            layer?.backgroundColor = NSColor.systemRed.cgColor
            layer?.borderWidth = 0
        } else {
            layer?.backgroundColor = hovered
                ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
                : NSColor.clear.cgColor
            layer?.borderColor = (hovered
                ? NSColor.labelColor.withAlphaComponent(0.22)
                : NSColor.labelColor.withAlphaComponent(0.12)).cgColor
            layer?.borderWidth = 1
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        applyStyle()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        applyStyle()
    }
}

// MARK: - Row

final class PortRow: FlippedView {
    let entry: PortEntry
    var onKill: ((PortEntry, Bool) -> Void)?
    var onCopy: ((PortEntry) -> Void)?
    var onFilter: ((String) -> Void)?
    private(set) var terminateButton: TerminateButton?
    private(set) var nameButton: NSButton?

    private let dot = NSView()
    private let uptimeLabel = NSTextField(labelWithString: "")
    private let portButton = NSButton()
    private var trackingArea: NSTrackingArea?

    init(entry: PortEntry) {
        self.entry = entry
        super.init(frame: .zero)
        build()
        toolTip = L10n.rowTip(entry)
    }

    required init?(coder: NSCoder) {
        fatalError("PortRow is created in code only")
    }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 5

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3.5
        dot.layer?.backgroundColor = NSColor.systemGreen.cgColor
        dot.frame = NSRect(x: 12, y: 9.5, width: 7, height: 7)
        addSubview(dot)

        portButton.isBordered = false
        portButton.alignment = .left
        portButton.target = self
        portButton.action = #selector(copyClicked)
        portButton.toolTip = L10n.copyTip(entry.port)
        portButton.frame = NSRect(x: 26, y: 3, width: 42, height: 20)
        setPortTitle(String(entry.port), color: .labelColor)

        let name = NSButton()
        name.isBordered = false
        name.alignment = .left
        name.lineBreakMode = .byTruncatingTail
        name.target = self
        name.action = #selector(filterClicked)
        name.toolTip = L10n.filterByNameTip(entry.displayName)
        name.frame = NSRect(x: 82, y: 5.5, width: PortPanel.contentWidth - 82 - 12 - 58 - 8, height: 16)
        name.attributedTitle = NSAttributedString(string: entry.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ])
        // How long the process has been up, right-aligned before the button.
        uptimeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)
        uptimeLabel.textColor = .tertiaryLabelColor
        uptimeLabel.alignment = .right
        uptimeLabel.stringValue = entry.uptime.map(L10n.uptime) ?? ""
        uptimeLabel.frame = NSRect(x: 168, y: 6, width: 46, height: 14)

        addSubview(portButton)
        addSubview(name)
        addSubview(uptimeLabel)
        nameButton = name

        let button = TerminateButton(idle: L10n.terminate, armed: L10n.terminateConfirm,
                                     frame: NSRect(x: PortPanel.contentWidth - 12 - 66, y: 3, width: 66, height: 20))
        button.toolTip = L10n.terminateTip
        button.onFire = { [weak self] force in
            guard let self else { return }
            self.onKill?(self.entry, force)
        }
        addSubview(button)
        terminateButton = button
    }

    private func setPortTitle(_ title: String, color: NSColor) {
        portButton.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: color,
        ])
    }

    @objc private func filterClicked() {
        onFilter?(entry.displayName)
    }

    @objc private func copyClicked() {
        onCopy?(entry)
        // The check mark is the only feedback: the popover stays open and
        // there is no room for a toast.
        setPortTitle("✓", color: .systemGreen)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self else { return }
            self.setPortTitle(String(self.entry.port), color: .labelColor)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if let nameButton { addCursorRect(nameButton.frame, cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { highlight(true) }
    override func mouseExited(with event: NSEvent) { highlight(false) }

    private func highlight(_ on: Bool) {
        layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.06).cgColor
            : NSColor.clear.cgColor
    }
}
