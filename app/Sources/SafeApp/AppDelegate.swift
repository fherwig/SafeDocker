import AppKit
import SafeCore
import UniformTypeIdentifiers

// WP4. Steps 3 and 4 of section 4.1, the main menu, and the self-test gate
// that every encrypt and save asks first (G5).

/// Starts the app when no command-line mode was asked for.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var openedDocuments = false
    /// The Volumes window once it was shown; the checks set one over stand-ins.
    var volumesWindow: VolumesWindowController?
    /// True if the Volumes window is the window in front, for the Volume menu's
    /// items that act on its selection; the checks replace it.
    var volumesWindowIsInFront: (VolumesWindowController) -> Bool = { controller in
        controller.window != nil && NSApp.keyWindow === controller.window
    }

    /// The result of the self-test at start; nil while it runs. If it failed,
    /// every encrypt and save is refused (G5). The editor and the viewer read it.
    var selfTestReport: SelfTestReport? {
        SelfTestGate.shared.report
    }

    /// Settings in the app's own defaults, which win over the global ones.
    static func setDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        defaults.set(true, forKey: "NSDisabledDictationMenuItem")
        defaults.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.setDefaults()
        MainMenu.install(target: self)
        NSApp.servicesProvider = ServicesProvider()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LockController.shared.hasOpenVolumes = { VolumeController.shared.hasAppOpenedVolumes }
        LockController.shared.start()
        VolumeController.shared.adoptOpenedVolumes()
        LockController.shared.addLockAction { VolumeController.shared.lock() }
        LockController.shared.onUserBack = { VolumeController.shared.userIsBack() }
        SelfTestGate.shared.start(fixturesDirectory: AppInfo.fixturesDirectory)
        NSUpdateDynamicServices()
        let isDefaultLaunch = notification.userInfo?[NSApplication.launchIsDefaultUserInfoKey] as? Bool ?? true
        if !openedDocuments && isDefaultLaunch {
            showVolumes()
        }
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(userCameBack(_:)),
                           name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        // a folder that New from Folder was deleting when Safe was stopped
        DispatchQueue.main.async {
            VolumeController.shared.offerToFinishDeletes()
        }
    }

    /// Double-click on a .crypt file in the Finder; comes before applicationDidFinishLaunching.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedDocuments = true
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            DocumentRouter.shared.open(urls)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showVolumes()
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        VolumeController.shared.reportBusyVolumes()
    }

    /// Unsaved text is offered for saving first (Save, Don't Save, Cancel; a
    /// locked editor asks for its password first); volumes the app opened are closed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard EditorWindowController.reviewUnsavedChangesBeforeQuit() else {
            return .terminateCancel
        }
        let busy = VolumeController.shared.closeForQuit()
        if !busy.isEmpty {
            let names = busy.map { L("“%@”", $0) }.joined(separator: ", ")
            let choice = Alerts.choose(L("Quit and leave %@ open?", names), L("""
                Files on it are in use, so Safe cannot close it. If you quit now, it stays \
                open until you eject it in the Finder.
                """), buttons: [L("Cancel"), L("Quit Anyway")])
            if choice == 0 {
                return .terminateCancel
            }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        ClipboardGuard.clearIfOurs()
    }

    /// com.apple.screenIsUnlocked: the user is back.
    @objc private func userCameBack(_ notification: Notification) {
        LockController.shared.userIsBack()
    }

    /// Step 4: the Volumes window, when there are no documents to open.
    @discardableResult
    private func showVolumes() -> VolumesWindowController {
        let controller = volumesWindow ?? VolumesWindowController()
        volumesWindow = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    // MARK: - Menu actions

    @objc func showVolumesWindow(_ sender: Any?) {
        showVolumes()
    }

    @objc func lockNow(_ sender: Any?) {
        LockController.shared.lockNow()
    }

    /// Safe > Settings... (Cmd-,): the Settings window.
    @objc func showSettings(_ sender: Any?) {
        SettingsWindowController.shared.show()
    }

    /// Help > Safe Help (Cmd-?) and the topics below it: the help window, at
    /// the section named by the item's representedObject, or at the top.
    @objc func showSafeHelp(_ sender: Any?) {
        let anchor = (sender as? NSMenuItem)?.representedObject as? String
        HelpWindowController.shared.show(anchor.flatMap { HelpSection(rawValue: $0) })
    }

    // MARK: - Volume menu

    /// The Volume menu's items do what the Volumes window's buttons do. New
    /// Empty, New from Folder and Add Existing work from any window and show the
    /// Volumes window first; the others act on its selection, only while it is
    /// in front, so that a shortcut typed in an editor never acts on a volume.
    @objc func newEmptyVolume(_ sender: Any?) { performVolume(.newEmpty) }
    @objc func newVolumeFromFolder(_ sender: Any?) { performVolume(.newFromFolder) }
    @objc func addExistingVolume(_ sender: Any?) { performVolume(.addExisting) }
    @objc func openSelectedVolume(_ sender: Any?) { performVolume(.open) }
    @objc func closeSelectedVolume(_ sender: Any?) { performVolume(.close) }
    @objc func changeSelectedVolumePassword(_ sender: Any?) { performVolume(.changePassword) }
    @objc func removeSelectedVolume(_ sender: Any?) { performVolume(.remove) }

    private func performVolume(_ action: VolumeMenuAction) {
        if action.needsSelection {
            guard let controller = volumesWindow, volumesWindowIsInFront(controller),
                  controller.canPerform(action) else { return }
            controller.perform(action)
        } else {
            showVolumes().perform(action)
        }
    }

    /// Whether a Volume menu item applies now; every other item of this target is enabled.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action.flatMap(VolumeMenuAction.init(selector:)) else {
            return true
        }
        guard action.needsSelection else { return true }
        guard let controller = volumesWindow, volumesWindowIsInFront(controller) else { return false }
        return controller.canPerform(action)
    }

    /// File > Open: .crypt files.
    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "crypt") {
            panel.allowedContentTypes = [type]
        }
        panel.message = L("Choose encrypted files to open.")
        if panel.runModal() == .OK {
            DocumentRouter.shared.open(panel.urls)
        }
    }

    /// File > Encrypt File: any files.
    @objc func encryptDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L("Choose files to encrypt. Each original is deleted after its encrypted copy is checked.")
        panel.prompt = L("Encrypt")
        if panel.runModal() == .OK {
            DocumentRouter.shared.encrypt(panel.urls)
        }
    }

    /// File > Export when no editor or viewer is in front to handle it (they
    /// export their own file): choose .crypt files.
    @objc func exportDecryptedCopy(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if let type = UTType(filenameExtension: "crypt") {
            panel.allowedContentTypes = [type]
        }
        panel.message = L("Choose encrypted files to export as unencrypted copies.")
        panel.prompt = L("Export")
        if panel.runModal() == .OK {
            DocumentRouter.shared.export(panel.urls)
        }
    }
}

// MARK: - Self-test gate

/// The result of the self-test at start (section 4.1, step 3). If it failed,
/// every encrypt and save is refused (G5); opening and exporting still work.
/// DocumentRouter asks writeRefusal(); the editor and the viewer read the report
/// through AppDelegate.selfTestReport.
final class SelfTestGate {
    /// The gate of the app.
    static let shared = SelfTestGate()
    /// Posted on the main thread when the self-test has finished.
    static let didFinish = Notification.Name("SafeSelfTestDidFinish")

    enum State: Equatable {
        case notStarted, running, passed
        case failed([String])
    }

    private let lock = NSLock()
    private var current = State.notStarted
    private var finishedReport: SelfTestReport?
    private var waiting: [() -> Void] = []
    private let finished = DispatchGroup()

    var state: State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// The report of SelfTest.run once it has finished, else nil.
    var report: SelfTestReport? {
        lock.lock()
        defer { lock.unlock() }
        return current == .running ? nil : finishedReport
    }

    /// Runs the self-test over the fixtures in the background. The app's gate
    /// also holds back CryptFile itself until the self-test has passed.
    func start(fixturesDirectory: URL) {
        let guardsCore = self === Self.shared && state == .notStarted
        if guardsCore {
            CryptFile.writeRefusal = L("the self-test is still running")
        }
        start {
            let report = SelfTest.run(fixturesDirectory: fixturesDirectory)
            self.lock.lock()
            self.finishedReport = report
            self.lock.unlock()
            let failures = Self.outcome(of: report)
            if guardsCore {
                CryptFile.writeRefusal = failures.isEmpty ? nil : failures.joined(separator: "; ")
            }
            return failures
        }
    }

    /// Runs `check` in the background; it returns the failures, none if it passed.
    func start(_ check: @escaping () -> [String]) {
        lock.lock()
        guard current == .notStarted else {
            lock.unlock()
            return
        }
        current = .running
        finished.enter()
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let failures = check()
            self.lock.lock()
            self.current = failures.isEmpty ? .passed : .failed(failures)
            let toRun = self.waiting
            self.waiting = []
            self.lock.unlock()
            self.finished.leave()
            DispatchQueue.main.async {
                toRun.forEach { $0() }
                NotificationCenter.default.post(name: Self.didFinish, object: self)
            }
        }
    }

    /// Runs `body` on the main thread once the self-test has finished (at once if
    /// it has, or if it never started).
    func whenFinished(_ body: @escaping () -> Void) {
        lock.lock()
        if current == .running {
            waiting.append(body)
            lock.unlock()
        } else {
            lock.unlock()
            body()
        }
    }

    /// nil if encrypting and saving are allowed, else the message why not. Waits
    /// for the self-test if it still runs.
    func writeRefusal() -> String? {
        finished.wait()
        switch state {
        case .passed:
            return nil
        case .notStarted, .running:
            return L("Safe will not encrypt or save, because its self-test has not run.")
        case .failed(let failures):
            return Self.refusal(failures)
        }
    }

    static func refusal(_ failures: [String]) -> String {
        L("""
        Safe will not encrypt or save, because its self-test failed when it started, and it \
        must never write a file it cannot read back. Files that are encrypted already can \
        still be opened and exported. Ask whoever installed Safe to check it with \
        Safe --self-test.

        What failed: %@
        """, failures.joined(separator: "; "))
    }

    /// The failures of a report; the checks are those of SelfTestReport.ok.
    static func outcome(of report: SelfTestReport) -> [String] {
        if passed(report) {
            return []
        }
        return report.failures.isEmpty ? [L("a check failed without a message")] : report.failures
    }

    /// Every check passed and nothing failed.
    static func passed(_ report: SelfTestReport) -> Bool {
        report.ok
    }
}

// MARK: - Main menu

/// The main menu, built by hand: no Spelling, Substitutions, Transformations,
/// Speech, Writing Tools or AutoFill, no Print and no Share (section 4.5).
/// Each item of Safe's own carries its English title in its identifier, which
/// is also the key of its title in Safe's language: relocalize gives every item
/// its title again when the language changes, and the Edit menu's guard knows
/// Safe's items in any language.
enum MainMenu {
    /// The identifiers of Safe's own items start with this, followed by the English title.
    static let identifierPrefix = "safe.menu:"
    /// The identifiers of the Help menu's topics: this and the section's anchor.
    static let topicPrefix = "safe.help-topic:"

    /// The English titles of the Edit menu's items; anything else that the system adds is removed.
    static let editItems = ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "Find"]

    /// Makes the main menu the app's, with its Window and Help menus.
    static func install(target: AnyObject) {
        NSApp.mainMenu = build(target: target)
        NSApp.windowsMenu = submenu(of: NSApp.mainMenu, key: "Window")
        NSApp.helpMenu = submenu(of: NSApp.mainMenu, key: "Help")
        // the menu bar follows a change of language at once
        if languageObserver == nil {
            languageObserver = NotificationCenter.default.addObserver(forName: Settings.languageDidChange,
                                                                      object: nil, queue: .main) { _ in
                if let menu = NSApp.mainMenu {
                    relocalize(menu)
                }
            }
        }
    }
    private static var languageObserver: NSObjectProtocol?

    static func build(target: AnyObject) -> NSMenu {
        let main = NSMenu(title: "Main Menu")

        let app = submenu(of: main, LKey("Safe"))
        app.addItem(item(LKey("About Safe"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        app.addItem(.separator())
        app.addItem(item(LKey("Settings..."), #selector(AppDelegate.showSettings(_:)), ",", target: target))
        app.addItem(.separator())
        app.addItem(item(LKey("Lock Now"), #selector(AppDelegate.lockNow(_:)), "l", [.command, .control],
                         target: target))
        app.addItem(.separator())
        app.addItem(item(LKey("Hide Safe"), #selector(NSApplication.hide(_:)), "h"))
        app.addItem(item(LKey("Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h",
                         [.command, .option]))
        app.addItem(item(LKey("Show All"), #selector(NSApplication.unhideAllApplications(_:))))
        app.addItem(.separator())
        app.addItem(item(LKey("Quit Safe"), #selector(NSApplication.terminate(_:)), "q"))

        let file = submenu(of: main, LKey("File"))
        file.addItem(item(LKey("Open..."), #selector(AppDelegate.openDocument(_:)), "o", target: target))
        file.addItem(item(LKey("Encrypt File..."), #selector(AppDelegate.encryptDocument(_:)), "e",
                          [.command, .shift], target: target))
        file.addItem(.separator())
        file.addItem(item(LKey("Close"), #selector(NSWindow.performClose(_:)), "w"))
        file.addItem(item(LKey("Save"), #selector(ResponderActions.saveDocument(_:)), "s"))
        file.addItem(item(LKey("Export..."), #selector(AppDelegate.exportDecryptedCopy(_:)), "e", [.command, .option]))

        let edit = submenu(of: main, LKey("Edit"))
        edit.addItem(item(LKey("Undo"), #selector(ResponderActions.undo(_:)), "z"))
        edit.addItem(item(LKey("Redo"), #selector(ResponderActions.redo(_:)), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item(LKey("Cut"), #selector(NSText.cut(_:)), "x"))
        edit.addItem(item(LKey("Copy"), #selector(NSText.copy(_:)), "c"))
        edit.addItem(item(LKey("Paste"), #selector(NSText.paste(_:)), "v"))
        edit.addItem(item(LKey("Delete"), #selector(NSText.delete(_:))))
        edit.addItem(item(LKey("Select All"), #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = submenu(of: edit, LKey("Find"))
        let findAction = #selector(NSTextView.performFindPanelAction(_:))
        find.addItem(item(LKey("Find..."), findAction, "f", tag: Int(NSFindPanelAction.showFindPanel.rawValue)))
        find.addItem(item(LKey("Find Next"), findAction, "g", tag: Int(NSFindPanelAction.next.rawValue)))
        find.addItem(item(LKey("Find Previous"), findAction, "g", [.command, .shift],
                          tag: Int(NSFindPanelAction.previous.rawValue)))
        if #available(macOS 15.2, *) {
            edit.automaticallyInsertsWritingToolsItems = false
        }
        EditMenuGuard.shared.watch(edit)

        // the viewer's commands; they go to the window in front, and only the
        // viewer answers them, so they are off in every other window
        let view = submenu(of: main, LKey("View"))
        view.addItem(item(LKey("Zoom In"), #selector(ViewerCommands.viewerZoomIn(_:)), "+"))
        // Cmd-= too, as in other apps, without a second line in the menu
        let zoomInEqual = item(LKey("Zoom In"), #selector(ViewerCommands.viewerZoomIn(_:)), "=")
        zoomInEqual.isHidden = true
        zoomInEqual.allowsKeyEquivalentWhenHidden = true
        view.addItem(zoomInEqual)
        view.addItem(item(LKey("Zoom Out"), #selector(ViewerCommands.viewerZoomOut(_:)), "-"))
        view.addItem(item(LKey("Actual Size"), #selector(ViewerCommands.viewerActualSize(_:)), "0",
                          [.command, .option]))
        view.addItem(item(LKey("Zoom to Fit"), #selector(ViewerCommands.viewerZoomToFit(_:)), "9"))
        view.addItem(.separator())
        view.addItem(item(LKey("Next Page"), #selector(ViewerCommands.viewerNextPage(_:)), Keys.down,
                          [.command, .option]))
        view.addItem(item(LKey("Previous Page"), #selector(ViewerCommands.viewerPreviousPage(_:)), Keys.up,
                          [.command, .option]))

        // the Volumes window's buttons, with shortcuts (architecture.md, section 3)
        let volume = submenu(of: main, LKey("Volume"))
        for action in VolumeMenuAction.allCases {
            if action == .open || action == .remove {
                volume.addItem(.separator())
            }
            volume.addItem(item(action.menuTitle, action.selector, action.key, action.modifiers, target: target))
        }

        let window = submenu(of: main, LKey("Window"))
        window.addItem(item(LKey("Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(item(LKey("Zoom"), #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item(LKey("Volumes"), #selector(AppDelegate.showVolumesWindow(_:)), "0", target: target))
        window.addItem(.separator())
        window.addItem(item(LKey("Bring All to Front"), #selector(NSApplication.arrangeInFront(_:))))

        // the last menu, NSApp.helpMenu; macOS adds its search field at the top
        let help = submenu(of: main, LKey("Help"))
        help.addItem(item(LKey("Safe Help"), #selector(AppDelegate.showSafeHelp(_:)), "?", target: target))
        help.addItem(.separator())
        for section in helpTopics {
            let topic = NSMenuItem(title: helpTopicTitle(section), action: #selector(AppDelegate.showSafeHelp(_:)),
                                   keyEquivalent: "")
            topic.target = target
            topic.representedObject = section.rawValue
            topic.identifier = NSUserInterfaceItemIdentifier(topicPrefix + section.rawValue)
            help.addItem(topic)
        }

        return main
    }

    /// Gives every item of Safe's own, and its submenus, the title in Safe's
    /// language again; items the system added keep theirs. Used when the
    /// language changes, so that the menu bar follows at once.
    static func relocalize(_ menu: NSMenu) {
        for item in menu.items {
            if let key = key(of: item) {
                item.title = Localization.string(key)
                item.submenu?.title = item.title
            } else if let anchor = item.identifier?.rawValue, anchor.hasPrefix(topicPrefix),
                      let section = HelpSection(rawValue: String(anchor.dropFirst(topicPrefix.count))) {
                item.title = helpTopicTitle(section)
            }
            if let submenu = item.submenu {
                relocalize(submenu)
            }
        }
    }

    /// The English title of one of Safe's own items, nil for an item the system added.
    static func key(of item: NSMenuItem) -> String? {
        guard let id = item.identifier?.rawValue, id.hasPrefix(identifierPrefix) else { return nil }
        return String(id.dropFirst(identifierPrefix.count))
    }

    /// The submenu of the item whose English title is `key`, in any language.
    static func submenu(of menu: NSMenu?, key: String) -> NSMenu? {
        menu?.items.first { self.key(of: $0) == key }?.submenu
    }

    /// The first item, in a menu or its submenus, whose English title is `key`.
    static func item(in menu: NSMenu?, key: String) -> NSMenuItem? {
        for item in menu?.items ?? [] {
            if self.key(of: item) == key {
                return item
            }
            if let found = self.item(in: item.submenu, key: key) {
                return found
            }
        }
        return nil
    }

    /// The sections that the Help menu names directly, below Safe Help.
    static let helpTopics: [HelpSection] = [.idea, .shortcuts, .problems]

    /// "The Idea Behind Safe": a section's title in the capitals of an English
    /// menu item; German menu items keep the capitals of the heading.
    static func helpTopicTitle(_ section: HelpSection) -> String {
        guard Localization.language == .english else { return section.title }
        let small: Set<String> = ["a", "and", "the", "of", "with"]
        return section.title.split(separator: " ").enumerated().map { index, word in
            index > 0 && small.contains(String(word)) ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    /// Key equivalents that are not characters on the keyboard.
    enum Keys {
        static let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        static let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        static let returnKey = "\r"
    }

    /// A shortcut as the menus show it, for example "⇧⌘N"; nil without one.
    static func shortcut(of item: NSMenuItem) -> String? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var modifiers = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        // a capital letter means Shift
        if key.count == 1, let c = key.first, c.isLetter, c.isUppercase {
            modifiers.insert(.shift)
            key = key.lowercased()
        }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key {
        case Keys.down: text += "↓"
        case Keys.up: text += "↑"
        case Keys.returnKey: text += "↩"
        default: text += key.uppercased()
        }
        return text
    }

    /// A submenu whose holder item has the English title `key` (marked with LKey).
    private static func submenu(of parent: NSMenu, _ key: String) -> NSMenu {
        let title = Localization.string(key)
        let menu = NSMenu(title: title)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.identifier = NSUserInterfaceItemIdentifier(identifierPrefix + key)
        holder.submenu = menu
        parent.addItem(holder)
        return menu
    }

    /// An item of Safe's own; `key` is its English title, marked with LKey.
    private static func item(_ key: String, _ action: Selector, _ keyEquivalent: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command,
                             target: AnyObject? = nil, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: Localization.string(key), action: action, keyEquivalent: keyEquivalent)
        item.identifier = NSUserInterfaceItemIdentifier(identifierPrefix + key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        return item
    }

    /// Removes from the Edit menu whatever the system added (Writing Tools,
    /// AutoFill, Dictation, Emoji), each time before it opens. Safe's own items
    /// are known by their identifiers, so this works in every language.
    static func strip(_ menu: NSMenu) {
        for item in menu.items.reversed() where !item.isSeparatorItem {
            if let key = key(of: item), editItems.contains(key) {
                continue
            }
            menu.removeItem(item)
        }
        // no separator at the end or twice in a row
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator {
                menu.removeItem(item)
            } else {
                previousWasSeparator = item.isSeparatorItem
            }
        }
        while let last = menu.items.last, last.isSeparatorItem {
            menu.removeItem(last)
        }
    }
}

/// The View menu's actions, which only the viewer answers (ViewerWindowController).
@objc protocol ViewerCommands {
    func viewerZoomIn(_ sender: Any?)
    func viewerZoomOut(_ sender: Any?)
    func viewerActualSize(_ sender: Any?)
    func viewerZoomToFit(_ sender: Any?)
    func viewerNextPage(_ sender: Any?)
    func viewerPreviousPage(_ sender: Any?)
}

/// Actions that the menu sends to the first responder: the window handles undo
/// and redo, the editor (WP3) saving; the editor and the viewer handle
/// exportDecryptedCopy and the text view performFindPanelAction.
@objc private protocol ResponderActions {
    func undo(_ sender: Any?)
    func redo(_ sender: Any?)
    func saveDocument(_ sender: Any?)
}

/// The Edit menu's delegate; the menu holds it weakly, hence the shared instance.
/// Strips the menu before it opens and soon after the system adds an item.
final class EditMenuGuard: NSObject, NSMenuDelegate {
    static let shared = EditMenuGuard()

    func watch(_ menu: NSMenu) {
        menu.delegate = self
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: menu,
                                               queue: .main) { [weak menu] _ in
            DispatchQueue.main.async {
                if let menu = menu {
                    MainMenu.strip(menu)
                }
            }
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        MainMenu.strip(menu)
    }
}
