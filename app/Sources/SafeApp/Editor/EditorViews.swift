import AppKit
import SafeCore

// WP3. The pieces of the editor window: the window itself (its own keyboard
// shortcuts), the search bar and the view that covers the text when locked.

/// The editor's window; handles the editor's shortcuts itself, so that they work
/// whatever the main menu holds.
final class EditorWindow: NSWindow {
    /// Returns true if it handled the command.
    var commandHandler: ((EditorCommand) -> Bool)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // AppKit may offer key equivalents to windows that are not key; only the
        // key editor acts on them
        let isKey = NSApp.keyWindow == nil || NSApp.keyWindow === self
        if isKey, event.type == .keyDown, let key = event.charactersIgnoringModifiers {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if let command = EditorShortcuts.command(key: key, command: flags.contains(.command),
                                                     shift: flags.contains(.shift),
                                                     option: flags.contains(.option),
                                                     control: flags.contains(.control)),
               let handler = commandHandler, handler(command) {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The search field above the text, with Previous, Next and Done. Search strings stay
/// in this window: no recent searches, no find pasteboard.
final class SearchBar: NSView {
    let field = NSSearchField()
    let matchLabel = NSTextField(labelWithString: "")
    var onPrevious: (() -> Void)?
    var onNext: (() -> Void)?
    var onDone: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 32))
        field.placeholderString = L("Search")
        field.toolTip = L("Search this text. Return finds the next match, Shift-Return the one before. What you search for stays in this window (⌘F).")
        field.recentsAutosaveName = nil
        field.searchMenuTemplate = nil
        (field.cell as? NSSearchFieldCell)?.maximumRecents = 0
        field.sendsWholeSearchString = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let preferred = field.widthAnchor.constraint(equalToConstant: 300)
        preferred.priority = NSLayoutConstraint.Priority(260)
        preferred.isActive = true

        let previous = Self.button(symbol: "chevron.up", title: L("Previous"), action: #selector(previousClicked))
        previous.toolTip = L("Find the previous match (⇧⌘G).")
        let next = Self.button(symbol: "chevron.down", title: L("Next"), action: #selector(nextClicked))
        next.toolTip = L("Find the next match (⌘G).")
        previous.target = self
        next.target = self
        let done = NSButton(title: L("Done"), target: self, action: #selector(doneClicked))
        done.bezelStyle = .rounded
        done.controlSize = .small
        done.toolTip = L("Hide the search field (Escape).")
        matchLabel.identifier = ToolTipAudit.statusIdentifier
        matchLabel.toolTip = L("How often the search text occurs in the text.")
        matchLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        matchLabel.textColor = .secondaryLabelColor
        matchLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        matchLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView()
        for view in [field, previous, next, matchLabel] as [NSView] {
            row.addView(view, in: .leading)
        }
        row.addView(done, in: .trailing)
        row.orientation = .horizontal
        row.spacing = 6
        row.setHuggingPriority(.defaultHigh, for: .vertical)
        row.edgeInsets = NSEdgeInsets(top: 5, left: 8, bottom: 5, right: 8)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    private static func button(symbol: String, title: String, action: Selector) -> NSButton {
        let button: NSButton
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button = NSButton(image: image, target: nil, action: action)
        } else {
            button = NSButton(title: title, target: nil, action: action)
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = title
        return button
    }

    @objc private func previousClicked() { onPrevious?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func doneClicked() { onDone?() }
}

/// Covers the text of a locked editor that has unsaved changes (G4).
final class LockCoverView: NSView {
    let unlockButton = NSButton(title: L("Show Text…"), target: nil, action: nil)
    var onUnlock: (() -> Void)?

    init(fileName: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: L("Locked")) {
            icon.image = image
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .regular)
        }
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: L("Locked"))
        title.font = NSFont.boldSystemFont(ofSize: 17)
        title.alignment = .center
        let text = NSTextField(wrappingLabelWithString:
            L("%@ has unsaved changes. They are kept, hidden, until you type the file's password.", fileName))
        text.alignment = .center
        text.isSelectable = false
        text.textColor = .secondaryLabelColor
        text.preferredMaxLayoutWidth = 360
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: 360).isActive = true
        unlockButton.bezelStyle = .rounded
        unlockButton.keyEquivalent = "\r"
        unlockButton.toolTip = L("Type the file's password to show the text and your unsaved changes again (Return).")
        unlockButton.setContentHuggingPriority(.required, for: .horizontal)
        unlockButton.target = self
        unlockButton.action = #selector(unlockClicked)

        let column = NSStackView(views: [icon, title, text, unlockButton])
        column.orientation = .vertical
        column.alignment = .centerX
        column.spacing = 12
        column.setHuggingPriority(.required, for: .vertical)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func unlockClicked() { onUnlock?() }
}

/// The note above a text shown read only because Safe could not confirm the
/// password (section 4.4), with the button that allows editing.
final class ReadOnlyBar: NSView {
    let label = NSTextField(wrappingLabelWithString: "")
    let allowButton = NSButton(title: L("Allow Editing"), target: nil, action: nil)
    var onAllow: (() -> Void)?

    /// The note, also as the label's tooltip.
    var note: String {
        get { label.stringValue }
        set {
            label.stringValue = newValue
            label.toolTip = newValue
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 600, height: 44))
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor
        let icon = NSImageView()
        if let image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L("Warning")) {
            icon.image = image
        }
        icon.contentTintColor = .systemOrange
        icon.setContentHuggingPriority(.required, for: .horizontal)
        label.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.identifier = ToolTipAudit.statusIdentifier
        label.toolTip = L("Why the text is shown read only.")
        allowButton.toolTip = L("Allow changes to the text. Do this only if the text is what you expect: then the password is right.")
        allowButton.bezelStyle = .rounded
        allowButton.controlSize = .small
        allowButton.setContentHuggingPriority(.required, for: .horizontal)
        allowButton.target = self
        allowButton.action = #selector(allowClicked)

        let row = NSStackView(views: [icon, label, allowButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc private func allowClicked() { onAllow?() }
}
