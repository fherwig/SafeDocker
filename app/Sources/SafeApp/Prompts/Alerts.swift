import AppKit
import SafeCore

// WP4. Plain alerts, a small form dialog and a progress panel for long work,
// all modal, so that the flows in DocumentRouter and the Volumes window read
// from top to bottom.

/// Messages and questions to the user.
enum Alerts {
    /// A message with an OK button.
    static func inform(_ title: String, _ message: String, warning: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = warning ? .warning : .informational
        alert.addButton(withTitle: L("OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A question with the given buttons, the first one the default; returns the
    /// index of the button clicked. The button named Cancel gets the Escape key.
    static func choose(_ title: String, _ message: String, buttons: [String]) -> Int {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        for name in buttons {
            alert.addButton(withTitle: name)
        }
        assignCancelEscape(alert)
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return max(0, min(buttons.count - 1, response))
    }

    /// Asks for a few lines of text; returns them, or nil on Cancel.
    static func form(_ title: String, _ message: String, fields: [(label: String, value: String)],
                     ok: String = L("OK")) -> [String]? {
        let (alert, inputs) = formAlert(title, message, fields: fields, ok: ok)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map(\.stringValue)
    }

    /// The alert of form, not shown yet. Its only use is New Empty, so its "?"
    /// opens the help about volumes.
    static func formAlert(_ title: String, _ message: String, fields: [(label: String, value: String)],
                          ok: String = L("OK")) -> (NSAlert, [NSTextField]) {
        let inputs = fields.map { field -> NSTextField in
            let input = NSTextField(string: field.value)
            input.cell?.isScrollable = true
            input.cell?.wraps = false
            input.toolTip = fieldToolTips[field.label] ?? L("Type the %@ here.", String(field.label.lowercased().dropLast()))
            return input
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: ok).toolTip = L("Go on with these values (Return).")
        alert.addButton(withTitle: L("Cancel")).toolTip = L("Close this dialog without doing anything (Escape).")
        assignCancelEscape(alert)
        alert.accessoryView = PasswordPrompt.form(zip(fields, inputs).map { ($0.label, $1) })
        alert.window.initialFirstResponder = inputs.first
        HelpButton.add(to: alert, .volumes, toolTip: L("Open Safe Help about volumes."))
        return (alert, inputs)
    }

    /// The tooltips of the form's fields, by label (the labels as shown, in Safe's language).
    static var fieldToolTips: [String: String] {
        [
            L("Name:"): L("The name of the new volume, which the Finder shows while it is open."),
            L("Maximum size:"): L("""
                The most the volume can grow to, for example 500 MB, 2 GB or 1 TB. It takes only as \
                much room as its files need.
                """),
        ]
    }

    /// Gives the button named Cancel the Escape key. NSAlert does that by itself
    /// only for a title in AppKit's own language, which follows macOS, not Safe's
    /// setting, so a German "Abbrechen" would lose it. Nothing changes if a
    /// button has the Escape key already.
    static func assignCancelEscape(_ alert: NSAlert) {
        guard !alert.buttons.contains(where: { $0.keyEquivalent == "\u{1b}" }),
              let cancel = alert.buttons.first(where: { $0.title == L("Cancel") }) else { return }
        cancel.keyEquivalent = "\u{1b}"
    }
}

/// Runs work off the main thread while a small panel says what is happening.
enum ModalProgress {
    /// Runs `work` in the background and returns its result. The main thread
    /// keeps handling events, but only for the panel, which shows after a
    /// moment so that quick work does not flicker.
    static func run<T>(_ message: String, _ work: @escaping () throws -> T) throws -> T {
        let box = ResultBox<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.result = Result { try work() }
            done.signal()
        }
        if done.wait(timeout: .now() + 0.4) == .timedOut {
            let panel = makePanel(message)
            panel.makeKeyAndOrderFront(nil)
            let session = NSApp.beginModalSession(for: panel)
            while done.wait(timeout: .now() + 0.05) == .timedOut {
                _ = NSApp.runModalSession(session)
            }
            NSApp.endModalSession(session)
            panel.orderOut(nil)
        }
        return try box.result!.get()
    }

    private final class ResultBox<T> {
        var result: Result<T, Error>?
    }

    /// The panel, not shown yet.
    static func makePanel(_ message: String) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 90),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Safe"
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .regular
        spinner.startAnimation(nil)
        let label = NSTextField(wrappingLabelWithString: message)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = stack
        label.widthAnchor.constraint(equalToConstant: 280).isActive = true
        panel.center()
        return panel
    }
}
