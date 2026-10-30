import AppKit
import SafeCore

// WP4. The window of section 4.8: the list of volumes and its buttons. What
// the buttons do is in VolumeFlows.swift; the window only shows the list and
// passes on the selected volume.

/// The list of volumes with New, Add, Open, Close, Change Password and Remove (R4, section 4.8).
final class VolumesWindowController: NSWindowController, NSWindowDelegate,
                                     NSTableViewDataSource, NSTableViewDelegate {
    private let flows: VolumeActions
    private(set) var records: [VolumeRecord] = []
    /// Called when the window becomes key: reports volumes left open on lock.
    var onBecomeKey: (() -> Void)?

    // not private, for the tests
    let table = VolumeTableView()
    let syncCheckbox = NSButton(checkboxWithTitle: L("Check that this app is running before opening:"),
                                target: nil, action: nil)
    let syncField = NSTextField(string: "")
    let statusLabel = NSTextField(wrappingLabelWithString: "")
    let helpButton = HelpButton.make(.volumes, toolTip: L("Open Safe Help about volumes."))
    /// The buttons, by their English titles, which stay the same in every language.
    private(set) var buttons: [String: NSButton] = [:]
    private var buttonActions: [String: VolumeMenuAction] = [:]
    private let intro = NSTextField(wrappingLabelWithString: "")
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// Makes the window over the app's VolumeStore.
    convenience init() {
        self.init(actions: VolumeController.shared.flows)
        onBecomeKey = { VolumeController.shared.reportBusyVolumes() }
    }

    /// Makes the window over the given flows.
    init(actions: VolumeActions) {
        flows = actions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 440),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L("Safe Volumes")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 620, height: 340)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        flows.onChange = { [weak self] in self?.reload() }
        watch(NotificationCenter.default, SelfTestGate.didFinish) { [weak self] in self?.showSelfTest() }
        let workspace = NSWorkspace.shared.notificationCenter
        watch(workspace, NSWorkspace.didMountNotification) { [weak self] in self?.reload() }
        watch(workspace, NSWorkspace.didUnmountNotification) { [weak self] in self?.reload() }
        watch(NotificationCenter.default, Settings.languageDidChange) { [weak self] in self?.applyLanguage() }
        reload()
        showSelfTest()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        for (center, observer) in observers {
            center.removeObserver(observer)
        }
    }

    private func watch(_ center: NotificationCenter, _ name: Notification.Name, _ body: @escaping () -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { _ in body() }))
    }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        intro.textColor = .secondaryLabelColor
        intro.isSelectable = false

        for (id, width) in [("name", 160.0), ("location", 330.0), ("state", 150.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = 60
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.target = self
        table.doubleAction = #selector(openVolume(_:))
        table.onReturn = { [weak self] in self?.perform(.open) }
        table.onDelete = { [weak self] in self?.perform(.remove) }
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true

        syncCheckbox.target = self
        syncCheckbox.action = #selector(syncCheckboxChanged(_:))
        syncField.target = self
        syncField.action = #selector(syncFieldChanged(_:))
        syncField.cell?.sendsActionOnEndEditing = true
        syncField.widthAnchor.constraint(equalToConstant: 200).isActive = true
        let syncRow = NSStackView(views: [syncCheckbox, syncField])
        syncRow.orientation = .horizontal

        let listRow = NSStackView(views: [
            button(LKey("New Empty..."), #selector(newEmpty(_:)), .newEmpty),
            button(LKey("New from Folder..."), #selector(newFromFolder(_:)), .newFromFolder),
            button(LKey("Add Existing..."), #selector(addExisting(_:)), .addExisting),
            button(LKey("Remove from List"), #selector(removeVolume(_:)), .remove),
        ])
        let volumeRow = NSStackView(views: [
            button(LKey("Open"), #selector(openVolume(_:)), .open),
            button(LKey("Close"), #selector(closeVolume(_:)), .close),
            button(LKey("Change Password..."), #selector(changePassword(_:)), .changePassword),
        ])
        for row in [listRow, volumeRow] {
            row.orientation = .horizontal
        }

        statusLabel.textColor = .secondaryLabelColor
        statusLabel.identifier = ToolTipAudit.statusIdentifier
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let bottomRow = NSStackView()
        bottomRow.addView(statusLabel, in: .leading)
        bottomRow.addView(helpButton, in: .trailing)
        bottomRow.orientation = .horizontal
        bottomRow.alignment = .top
        bottomRow.spacing = 12

        let stack = NSStackView(views: [intro, scroll, syncRow, volumeRow, listRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        for view in [intro, scroll, bottomRow] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        window.contentView = stack
        applyLanguage()
    }

    /// A button; `key` is its English title, marked with LKey.
    private func button(_ key: String, _ action: Selector, _ menu: VolumeMenuAction) -> NSButton {
        let button = NSButton(title: Localization.string(key), target: self, action: action)
        button.bezelStyle = .rounded
        buttons[key] = button
        buttonActions[key] = menu
        return button
    }

    /// Every text of the window in Safe's language; again when the language
    /// changes, without touching the list, its selection or what is typed.
    func applyLanguage() {
        window?.title = L("Safe Volumes")
        intro.stringValue = L("""
            Encrypted volumes are disk images in Apple's standard format. Open one to use its \
            files in the Finder. Safe closes the volumes it opened after 10 minutes without use \
            and when the Mac sleeps. To encrypt a single file, right-click it in the Finder and \
            choose Encrypt with Safe (under Quick Actions or Services); double-click a .crypt \
            file to open it.
            """)
        let columns = [
            ("name", L("Name"), L("The name Safe shows for the volume.")),
            ("location", L("Location"), L("Where the volume's disk image is stored.")),
            ("state", L("State"), L("Open, Closed, or Not found if nothing is at the location any more.")),
        ]
        for (id, title, tip) in columns {
            let column = table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(id))
            column?.title = title
            column?.headerToolTip = tip
        }
        table.headerView?.needsDisplay = true
        table.toolTip = L("Your encrypted volumes. Double-click a volume, or select it and press Return, to open it.")
        syncCheckbox.title = L("Check that this app is running before opening:")
        syncCheckbox.toolTip = L("""
            Before opening this volume, check that the app keeping its folder in sync is running, \
            and warn if it is not.
            """)
        syncField.placeholderString = L("for example Nextcloud")
        syncField.toolTip = L("""
            The name of the sync app, for example Nextcloud. Safe warns before opening the volume \
            if no app of this name is running.
            """)
        for (key, button) in buttons {
            button.title = Localization.string(key)
            button.toolTip = buttonActions[key]?.toolTip
        }
        helpButton.toolTip = L("Open Safe Help about volumes.")
        let selection = table.selectedRowIndexes
        table.reloadData()
        table.selectRowIndexes(selection, byExtendingSelection: false)
        showSelfTest()
    }

    // MARK: - The list

    /// Asks which images are attached and shows the list again, keeping the selection.
    func reload() {
        let selectedID = selected?.id
        flows.refresh()
        records = flows.list.volumes
        table.reloadData()
        if let id = selectedID, let row = records.firstIndex(where: { $0.id == id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        updateControls()
    }

    var selected: VolumeRecord? {
        let row = table.selectedRow
        return records.indices.contains(row) ? records[row] : nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        records.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, records.indices.contains(row) else { return nil }
        let record = records[row]
        let text: String
        var tip: String?
        switch column.identifier.rawValue {
        case "name":
            text = record.name
        case "location":
            text = record.path
        default:
            switch flows.state(of: record) {
            case .open(let mountPoint):
                text = L("[state] Open")
                tip = L("Open at %@", mountPoint.path)
            case .closed:
                text = L("[state] Closed")
            case .missing:
                text = L("[state] Not found")
                tip = L("There is nothing at this location.")
            }
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = tip ?? text
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateControls()
    }

    private func updateControls() {
        let record = selected
        buttons["Open"]?.isEnabled = canPerform(.open)
        buttons["Close"]?.isEnabled = canPerform(.close)
        buttons["Change Password..."]?.isEnabled = canPerform(.changePassword)
        buttons["Remove from List"]?.isEnabled = canPerform(.remove)
        syncCheckbox.isEnabled = record != nil
        syncCheckbox.state = record?.syncApp != nil ? .on : .off
        syncField.stringValue = record?.syncApp ?? ""
        syncField.isEnabled = record?.syncApp != nil
    }

    private func showSelfTest() {
        switch SelfTestGate.shared.state {
        case .notStarted, .passed:
            statusLabel.stringValue = ""
        case .running:
            statusLabel.stringValue = L("Safe is checking its encryption (self-test) ...")
            statusLabel.textColor = .secondaryLabelColor
        case .failed(let failures):
            statusLabel.stringValue = L("The self-test failed, so Safe will not encrypt or save files: %@",
                                        failures.joined(separator: "; "))
            statusLabel.textColor = .systemRed
        }
        statusLabel.toolTip = statusLabel.stringValue.isEmpty
            ? L("Messages about Safe's self-test, which checks its encryption at every start, appear here.")
            : statusLabel.stringValue
    }

    // MARK: - The Volume menu

    /// True if the action applies to the selection now, as its button is enabled.
    func canPerform(_ action: VolumeMenuAction) -> Bool {
        guard action.needsSelection else { return true }
        let record = selected
        let state = record.map { flows.state(of: $0) }
        let isOpen: Bool
        if case .open = state { isOpen = true } else { isOpen = false }
        switch action {
        case .open:
            return record != nil && state != .missing
        case .close:
            return isOpen
        case .changePassword:
            return record != nil && state != .missing && !isOpen
        case .remove:
            return record != nil
        case .newEmpty, .newFromFolder, .addExisting:
            return true
        }
    }

    /// Does what the action's button does, if it applies.
    func perform(_ action: VolumeMenuAction) {
        guard canPerform(action) else {
            NSSound.beep()
            return
        }
        switch action {
        case .newEmpty: newEmpty(nil)
        case .newFromFolder: newFromFolder(nil)
        case .addExisting: addExisting(nil)
        case .open: openVolume(nil)
        case .close: closeVolume(nil)
        case .changePassword: changePassword(nil)
        case .remove: removeVolume(nil)
        }
    }

    // MARK: - Buttons

    @objc private func newEmpty(_ sender: Any?) {
        select(flows.newEmpty())
    }

    @objc private func newFromFolder(_ sender: Any?) {
        select(flows.newFromFolder())
    }

    @objc private func addExisting(_ sender: Any?) {
        select(flows.addExisting())
    }

    @objc private func removeVolume(_ sender: Any?) {
        if let record = selected {
            flows.remove(record)
        }
    }

    @objc private func openVolume(_ sender: Any?) {
        if let record = selected {
            flows.open(record)
        }
    }

    @objc private func closeVolume(_ sender: Any?) {
        if let record = selected {
            flows.close(record)
        }
    }

    @objc private func changePassword(_ sender: Any?) {
        if let record = selected {
            flows.changePassword(record)
        }
    }

    @objc private func syncCheckboxChanged(_ sender: Any?) {
        guard let record = selected else { return }
        if syncCheckbox.state == .on {
            syncField.isEnabled = true
            window?.makeFirstResponder(syncField)
            if !syncField.stringValue.isEmpty {
                flows.setSyncApp(record, to: syncField.stringValue)
            }
        } else {
            flows.setSyncApp(record, to: nil)
        }
    }

    @objc private func syncFieldChanged(_ sender: Any?) {
        guard let record = selected, syncCheckbox.state == .on else { return }
        flows.setSyncApp(record, to: syncField.stringValue)
    }

    private func select(_ record: VolumeRecord?) {
        reload()
        if let record = record, let row = records.firstIndex(where: { $0.id == record.id }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    // MARK: - Window

    func windowDidBecomeKey(_ notification: Notification) {
        reload()
        onBecomeKey?()
    }
}

/// The Volume menu: the same actions as the Volumes window's buttons, with
/// their shortcuts (architecture.md, section 3, says why these).
enum VolumeMenuAction: CaseIterable {
    case newEmpty, newFromFolder, addExisting, open, close, changePassword, remove

    var menuTitle: String {
        switch self {
        case .newEmpty: return LKey("New Empty Volume...")
        case .newFromFolder: return LKey("New Volume from Folder...")
        case .addExisting: return LKey("Add Existing Volume...")
        case .open: return LKey("Open Volume")
        case .close: return LKey("Close Volume")
        case .changePassword: return LKey("Change Password...")
        case .remove: return LKey("Remove from List")
        }
    }

    var selector: Selector {
        switch self {
        case .newEmpty: return #selector(AppDelegate.newEmptyVolume(_:))
        case .newFromFolder: return #selector(AppDelegate.newVolumeFromFolder(_:))
        case .addExisting: return #selector(AppDelegate.addExistingVolume(_:))
        case .open: return #selector(AppDelegate.openSelectedVolume(_:))
        case .close: return #selector(AppDelegate.closeSelectedVolume(_:))
        case .changePassword: return #selector(AppDelegate.changeSelectedVolumePassword(_:))
        case .remove: return #selector(AppDelegate.removeSelectedVolume(_:))
        }
    }

    init?(selector: Selector) {
        guard let action = Self.allCases.first(where: { $0.selector == selector }) else { return nil }
        self = action
    }

    /// The key; Change Password and Remove from List have none, so that a slip
    /// of the finger cannot start them (Remove from List has Delete in the list).
    var key: String {
        switch self {
        case .newEmpty, .newFromFolder: return "n"
        case .addExisting: return "a"
        case .open: return MainMenu.Keys.returnKey
        case .close: return "e"
        case .changePassword, .remove: return ""
        }
    }

    var modifiers: NSEvent.ModifierFlags {
        switch self {
        case .newFromFolder, .addExisting: return [.command, .shift]
        default: return .command
        }
    }

    /// True for the actions on the selected volume.
    var needsSelection: Bool {
        switch self {
        case .newEmpty, .newFromFolder, .addExisting: return false
        case .open, .close, .changePassword, .remove: return true
        }
    }

    /// The tooltip of the button, ending with the shortcut.
    var toolTip: String {
        switch self {
        case .newEmpty:
            return L("Make a new, empty encrypted volume. You choose its name, maximum size, place and password (⌘N).")
        case .newFromFolder:
            return L("Make an encrypted volume from a folder. Safe checks the copy, then deletes the folder (⇧⌘N).")
        case .addExisting:
            return L("Add an encrypted disk image that is on the disk already, such as one made with Disk Utility (⇧⌘A).")
        case .open:
            return L("Open the selected volume with its password and show it in the Finder (⌘↩).")
        case .close:
            return L("Close the selected volume. If a file on it is still in use, it stays open and Safe says so (⌘E).")
        case .changePassword:
            return L("""
                Change the password of the selected volume while it is closed. A copy of the volume \
                kept from before still opens with the old password.
                """)
        case .remove:
            return L("""
                Remove the selected volume from this list. The volume itself stays on the disk and is \
                not deleted (or press Delete in the list).
                """)
        }
    }
}

/// The list of volumes: Return opens the selected volume, Delete removes it from
/// the list (after asking), as the Finder's lists do.
final class VolumeTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onDelete: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if flags.isEmpty, let key = event.charactersIgnoringModifiers?.unicodeScalars.first {
            switch Int(key.value) {
            case 0x0D, 0x03:   // Return, Enter
                if let onReturn = onReturn {
                    onReturn()
                    return
                }
            case 0x7F, NSDeleteFunctionKey:   // Delete, Forward Delete
                if let onDelete = onDelete {
                    onDelete()
                    return
                }
            default:
                break
            }
        }
        super.keyDown(with: event)
    }
}
