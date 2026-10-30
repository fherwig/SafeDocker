import AppKit
import SafeCore

// The help window: the manual of HelpBook in a read-only text view, a list of
// its sections on the left and a search field. One window for the whole app,
// opened by Help > Safe Help (Cmd-?) and by the "?" buttons, each at its section.

/// The one help window.
final class HelpWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource,
                                  NSTableViewDelegate, NSSearchFieldDelegate {
    /// The window of the app, made the first time it is asked for.
    static var shared: HelpWindowController {
        if let existing = instance {
            return existing
        }
        let made = HelpWindowController(book: HelpBook.load())
        instance = made
        return made
    }
    private static var instance: HelpWindowController?

    /// Puts the window on the screen; the checks replace it, so that nothing is shown.
    static var present: (NSWindow) -> Void = { window in
        if NSApp.modalWindow != nil {
            // from the "?" of a dialog: beside it, which keeps the keyboard
            window.orderFront(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private(set) var book: HelpBook
    let textView = HelpTextView()
    let sidebar = NSTableView()
    let searchField = NSSearchField()
    let matchLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    /// The sections in the sidebar: those with a heading in the text.
    private(set) var sections: [HelpSection]
    private var observer: NSObjectProtocol?
    /// The section last shown or chosen; nil at the top of the text.
    private(set) var currentSection: HelpSection?
    private var followingScroll = true

    init(book: HelpBook) {
        self.book = book
        sections = HelpSection.allCases.filter { book.headings[$0] != nil }
        // a panel that works while a dialog is open, so that the "?" of a
        // password dialog shows help that can be read and scrolled at once
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: true)
        window.title = L("Safe Help")
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.worksWhenModal = true
        window.isExcludedFromWindowsMenu = false
        window.tabbingMode = .disallowed
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        observer = NotificationCenter.default.addObserver(forName: Settings.languageDidChange, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.applyLanguage()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        if let observer = observer {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// The texts of the window in Safe's language, and the manual in it, read
    /// again; the same section stays in view.
    func applyLanguage() {
        window?.title = L("Safe Help")
        searchField.placeholderString = L("Search Help")
        searchField.toolTip = L("Search the help text. Return finds the next place, Shift-Return the one before (⌘F).")
        matchLabel.toolTip = L("How often the search text occurs in the help.")
        sidebar.tableColumns.first?.title = L("Contents")
        sidebar.tableColumns.first?.headerToolTip = L("The sections of the help.")
        sidebar.toolTip = L("The sections of the help. Click one to go to it.")
        let section = currentSection
        book = HelpBook.load()
        sections = HelpSection.allCases.filter { book.headings[$0] != nil }
        textView.textStorage?.setAttributedString(book.text)
        sidebar.reloadData()
        matchLabel.stringValue = ""
        go(to: section)
    }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        searchField.recentsAutosaveName = nil
        searchField.sendsWholeSearchString = false
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        matchLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.identifier = ToolTipAudit.statusIdentifier

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("section"))
        sidebar.addTableColumn(column)
        sidebar.headerView = nil
        sidebar.style = .sourceList
        sidebar.dataSource = self
        sidebar.delegate = self
        sidebar.allowsEmptySelection = true
        let sidebarScroll = NSScrollView()
        sidebarScroll.documentView = sidebar
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        sidebarScroll.autohidesScrollers = true

        // Safe's icon under the contents, the porthole of scripts/gen-icon.swift
        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.toolTip = L("Safe, version %@", AppInfo.version)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let left = NSStackView(views: [searchField, matchLabel, sidebarScroll, icon])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 6
        left.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 10, right: 6)
        for view in [searchField, sidebarScroll] as [NSView] {
            view.widthAnchor.constraint(equalTo: left.widthAnchor, constant: -16).isActive = true
        }
        sidebarScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        icon.centerXAnchor.constraint(equalTo: left.centerXAnchor).isActive = true
        left.widthAnchor.constraint(equalToConstant: 290).isActive = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 28, height: 22)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
        }
        textView.owner = self
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(textScrolled(_:)),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        let split = NSStackView(views: [left, scrollView])
        split.orientation = .horizontal
        split.spacing = 0
        split.alignment = .top
        split.distribution = .fill
        for view in [left, scrollView] as [NSView] {
            view.heightAnchor.constraint(equalTo: split.heightAnchor).isActive = true
        }
        scrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        window.contentView = split
        window.initialFirstResponder = textView
        applyLanguage()
    }

    // MARK: - Showing a section

    /// Puts the window on the screen at the section, or at the top for nil.
    func show(_ section: HelpSection?) {
        go(to: section)
        if let window = window {
            Self.present(window)
        }
    }

    /// Scrolls the text so that the section's heading is at the top.
    func go(to section: HelpSection?) {
        currentSection = section
        followingScroll = false
        defer { followingScroll = true }
        if let section = section, let row = sections.firstIndex(of: section) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        } else {
            sidebar.deselectAll(nil)
        }
        window?.layoutIfNeeded()
        let y = section.flatMap { book.headings[$0] }.map { headingTop($0) } ?? 0
        let clip = scrollView.contentView
        let highest = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), highest)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where a heading starts in the text view, less a little space above it.
    private func headingTop(_ range: NSRange) -> CGFloat {
        guard let layout = textView.layoutManager, let container = textView.textContainer else { return 0 }
        layout.ensureLayout(for: container)
        let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let rect = layout.boundingRect(forGlyphRange: glyphs, in: container)
        return rect.minY + textView.textContainerOrigin.y - 12
    }

    /// The section whose heading is at the top of the visible text.
    func sectionAtTop() -> HelpSection? {
        let top = scrollView.contentView.bounds.minY + 40
        var found: HelpSection?
        for section in sections {
            guard let range = book.headings[section] else { continue }
            if headingTop(range) <= top {
                found = section
            }
        }
        return found
    }

    @objc private func textScrolled(_ notification: Notification) {
        guard followingScroll, window?.isVisible == true else { return }
        let section = sectionAtTop()
        guard section != currentSection else { return }
        currentSection = section
        followingScroll = false
        if let section = section, let row = sections.firstIndex(of: section) {
            sidebar.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            sidebar.scrollRowToVisible(row)
        } else {
            sidebar.deselectAll(nil)
        }
        followingScroll = true
    }

    // MARK: - The sidebar

    func numberOfRows(in tableView: NSTableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // a cell view with its text field, so that a selected row draws its text in white
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: sections[row].shortTitle)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = sections[row].title
        label.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard followingScroll, sections.indices.contains(sidebar.selectedRow) else { return }
        go(to: sections[sidebar.selectedRow])
    }

    // MARK: - Search

    @objc private func searchChanged(_ sender: Any?) {
        find(.incremental)
    }

    enum Step {
        case incremental, next, previous
    }

    /// Finds the search text in the manual, selects and shows it; the range found.
    @discardableResult
    func find(_ step: Step) -> NSRange? {
        let needle = searchField.stringValue
        guard !needle.isEmpty else {
            matchLabel.stringValue = ""
            return nil
        }
        let text = textView.string
        let selection = textView.selectedRange()
        let found: NSRange?
        switch step {
        case .incremental:
            found = TextSearch.find(needle, in: text, from: selection.location, backwards: false)
        case .next:
            found = TextSearch.find(needle, in: text, from: NSMaxRange(selection), backwards: false)
        case .previous:
            found = TextSearch.find(needle, in: text, from: selection.location, backwards: true)
        }
        guard let range = found else {
            matchLabel.stringValue = L("Not found")
            return nil
        }
        let count = TextSearch.count(needle, in: text)
        matchLabel.stringValue = Lp(count, "%ld match", "%ld matches")
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if window?.isVisible == true {
            textView.showFindIndicator(for: range)
        }
        return range
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            find(shift ? .previous : .next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            searchField.stringValue = ""
            matchLabel.stringValue = ""
            window?.makeFirstResponder(self.textView)
            return true
        default:
            return false
        }
    }

    /// Edit > Find, Find Next and Find Previous in the help window.
    func performFind(_ action: NSFindPanelAction) {
        switch action {
        case .next where !searchField.stringValue.isEmpty:
            find(.next)
        case .previous where !searchField.stringValue.isEmpty:
            find(.previous)
        default:
            window?.makeFirstResponder(searchField)
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    @objc func performFindPanelAction(_ sender: Any?) {
        let tag = (sender as? NSMenuItem)?.tag ?? Int(NSFindPanelAction.showFindPanel.rawValue)
        performFind(NSFindPanelAction(rawValue: UInt(tag)) ?? .showFindPanel)
    }
}

/// The help text: read only, with a context menu of Copy and Select All only, as
/// the rest of the app, and Find going to the window's own search field.
final class HelpTextView: NSTextView {
    weak var owner: HelpWindowController?

    override func performFindPanelAction(_ sender: Any?) {
        owner?.performFindPanelAction(sender)
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(performFindPanelAction(_:)) {
            return owner != nil
        }
        return super.validateMenuItem(menuItem)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }
        menu.addItem(withTitle: L("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Select All"), action: #selector(selectAll(_:)), keyEquivalent: "")
        return menu
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        nil
    }
}

// MARK: - The "?" buttons

/// The small round "?" buttons of the windows and dialogs, each for a section.
enum HelpButton {
    /// A "?" button that opens the help window at the section.
    static func make(_ section: HelpSection, toolTip: String) -> NSButton {
        let button = NSButton(title: "", target: Opener.shared, action: #selector(Opener.open(_:)))
        button.bezelStyle = .helpButton
        button.identifier = NSUserInterfaceItemIdentifier(prefix + section.rawValue)
        button.toolTip = toolTip
        button.setAccessibilityLabel(L("Help"))
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// Makes a button made by make open another section.
    static func point(_ button: NSButton, at section: HelpSection, toolTip: String) {
        button.identifier = NSUserInterfaceItemIdentifier(prefix + section.rawValue)
        button.toolTip = toolTip
    }

    /// The section a button made by make opens; for the checks.
    static func section(of button: NSButton) -> HelpSection? {
        guard let id = button.identifier?.rawValue, id.hasPrefix(prefix) else { return nil }
        return HelpSection(rawValue: String(id.dropFirst(prefix.count)))
    }

    private static let prefix = "help:"

    /// Gives an alert the standard "?" button, which opens the section.
    static func add(to alert: NSAlert, _ section: HelpSection, toolTip: String) {
        alert.showsHelp = true
        alert.helpAnchor = section.rawValue
        alert.delegate = AlertHelp.shared
        alert.layout()
        for button in buttons(in: alert.window.contentView) where button.bezelStyle == .helpButton {
            button.toolTip = toolTip
        }
    }

    /// Every button in a view and the views inside it.
    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view = view else { return [] }
        let own: [NSButton] = (view as? NSButton).map { [$0] } ?? []
        return own + view.subviews.flatMap { buttons(in: $0) }
    }

    /// The target of the buttons; a button holds its target weakly.
    final class Opener: NSObject {
        static let shared = Opener()

        @objc func open(_ sender: NSButton) {
            HelpWindowController.shared.show(HelpButton.section(of: sender))
        }
    }

    /// The delegate of alerts with a "?" button; the alert holds it weakly.
    final class AlertHelp: NSObject, NSAlertDelegate {
        static let shared = AlertHelp()

        func alertShowHelp(_ alert: NSAlert) -> Bool {
            HelpWindowController.shared.show(alert.helpAnchor.flatMap { HelpSection(rawValue: $0) })
            return true
        }
    }
}

// MARK: - Tooltips

/// Which controls lack a tooltip; for the checks, and the rule they follow.
enum ToolTipAudit {
    /// Marks a label that shows a status, which needs a tooltip like a control.
    static let statusIdentifier = NSUserInterfaceItemIdentifier("status")

    /// The controls in the view and the views inside it that have no tooltip.
    /// Fixed labels (text fields that cannot be edited or selected and are not a
    /// status), scroll bars and pictures do not count, nor the parts that AppKit
    /// puts inside a search field, whose tooltip is the field's.
    static func missing(in view: NSView?) -> [NSControl] {
        guard let view = view else { return [] }
        var found: [NSControl] = []
        if let control = view as? NSControl, needsToolTip(control), (control.toolTip ?? "").isEmpty {
            found.append(control)
        }
        if view is NSSearchField {
            return found
        }
        for subview in view.subviews {
            found += missing(in: subview)
        }
        return found
    }

    static func needsToolTip(_ control: NSControl) -> Bool {
        if control is NSScroller || control is NSImageView {
            return false
        }
        if let field = control as? NSTextField, !field.isEditable, !field.isSelectable,
           field.identifier != statusIdentifier {
            return false
        }
        return true
    }

    /// A short description of a control, for messages.
    static func describe(_ control: NSControl) -> String {
        let field = control as? NSTextField
        let title = (control as? NSButton)?.title ?? field?.placeholderString ?? String(control.stringValue.prefix(40))
        return "\(type(of: control)) “\(title)”"
    }
}
