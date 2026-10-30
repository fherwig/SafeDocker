import AppKit
import SafeCore

// Version 0.3.0: Safe > Settings... (Cmd-,). A small window with the language
// popup, what changes when, and Restart Safe when a new start is needed for what
// AppKit draws. Room for more settings later.

/// The Settings window, one for the app.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    /// The window of the app, made the first time it is asked for.
    static var shared: SettingsWindowController {
        if let existing = instance {
            return existing
        }
        let made = SettingsWindowController(settings: .shared)
        instance = made
        return made
    }
    private static var instance: SettingsWindowController?

    /// Puts the window on the screen; the checks replace it, so that nothing is shown.
    static var present: (NSWindow) -> Void = { window in
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    let settings: Settings
    // not private, for the tests
    let languageLabel = NSTextField(labelWithString: "")
    let languagePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let explanation = NSTextField(wrappingLabelWithString: "")
    let restartNote = NSTextField(wrappingLabelWithString: "")
    let restartButton = NSButton(title: "", target: nil, action: nil)
    let helpButton = HelpButton.make(.settings, toolTip: L("Open Safe Help about settings and the language."))
    private var observers: [NSObjectProtocol] = []

    init(settings: Settings) {
        self.settings = settings
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
                              styleMask: [.titled, .closable, .miniaturizable],
                              backing: .buffered, defer: true)
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        build(in: window)
        window.center()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Settings.languageDidChange, object: nil, queue: .main) {
            [weak self] _ in self?.applyLanguage()
        })
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Puts the window on the screen, with the state of now.
    func show() {
        applyLanguage()
        if let window = window {
            Self.present(window)
        }
    }

    // MARK: - Layout

    private func build(in window: NSWindow) {
        languagePopup.target = self
        languagePopup.action = #selector(languageChosen(_:))
        explanation.textColor = .secondaryLabelColor
        explanation.isSelectable = false
        restartNote.isSelectable = false
        restartNote.identifier = ToolTipAudit.statusIdentifier
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restartNow(_:))

        let row = NSStackView(views: [languageLabel, languagePopup])
        row.orientation = .horizontal
        row.spacing = 8
        let restartRow = NSStackView(views: [restartButton])
        restartRow.orientation = .horizontal
        let bottom = NSStackView()
        bottom.orientation = .horizontal
        bottom.addView(restartRow, in: .leading)
        bottom.addView(helpButton, in: .trailing)

        let stack = NSStackView(views: [row, explanation, restartNote, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 16, right: 20)
        for view in [explanation, restartNote, bottom] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: 480).isActive = true
        window.contentView = stack
        applyLanguage()
    }

    /// Every text of the window in Safe's language, and the popup and the
    /// restart offer as they are now.
    func applyLanguage() {
        window?.title = L("Settings")
        languageLabel.stringValue = L("Language:")
        let choices = Settings.LanguageChoice.allCases
        languagePopup.removeAllItems()
        for choice in choices {
            languagePopup.addItem(withTitle: Self.title(of: choice))
            languagePopup.lastItem?.representedObject = choice.rawValue
        }
        languagePopup.selectItem(at: choices.firstIndex(of: settings.languageChoice) ?? 0)
        languagePopup.toolTip = L("""
            The language of Safe's menus, windows and messages. System follows the order of the \
            languages in System Settings: German if German comes before English, otherwise English.
            """)
        explanation.stringValue = L("""
            The menus, the Volumes window, the help and this window change at once. A text or a \
            viewer that is open keeps its language until you open the file again; nothing is \
            closed and no change is lost. The services in the Finder follow the language of macOS.
            """)
        helpButton.toolTip = L("Open Safe Help about settings and the language.")
        updateRestart()
        window?.contentView?.layoutSubtreeIfNeeded()
        if let window = window, let content = window.contentView {
            window.setContentSize(content.fittingSize)
        }
    }

    /// The name of a choice in the popup; the languages in their own names.
    static func title(of choice: Settings.LanguageChoice) -> String {
        switch choice {
        case .system: return L("System")
        case .english: return "English"
        case .german: return "Deutsch"
        }
    }

    /// Says whether what macOS draws for Safe needs a new start, and offers it
    /// only when nothing is open.
    private func updateRestart() {
        let needed = settings.needsRestart
        let possible = settings.nothingIsOpen()
        restartButton.title = L("Restart Safe")
        restartButton.isHidden = !needed
        restartButton.isEnabled = needed && possible
        restartButton.toolTip = L("""
            Quit Safe and start it again, so that the Open and Save dialogs and the About window \
            are in the new language too. Only while no text, viewer or volume is open.
            """)
        restartNote.isHidden = !needed
        if !needed {
            restartNote.stringValue = ""
        } else if possible {
            restartNote.stringValue = L("""
                The Open and Save dialogs, the About window and the search field of the Help menu \
                change when Safe starts again.
                """)
        } else {
            restartNote.stringValue = L("""
                The Open and Save dialogs, the About window and the search field of the Help menu \
                change the next time Safe starts. A text, a viewer or a volume is open, so Safe \
                does not offer to restart now.
                """)
        }
        restartNote.toolTip = restartNote.stringValue.isEmpty ? L("Notes about the language appear here.")
            : restartNote.stringValue
    }

    // MARK: - Actions

    @objc private func languageChosen(_ sender: Any?) {
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let choice = Settings.LanguageChoice(rawValue: raw) else { return }
        settings.setLanguageChoice(choice)
        // the notification re-titles the window if the language changed; the
        // restart offer may change without that (System to the same language)
        applyLanguage()
    }

    @objc private func restartNow(_ sender: Any?) {
        updateRestart()
        guard settings.needsRestart, settings.nothingIsOpen() else { return }
        settings.restart()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateRestart()
    }
}
