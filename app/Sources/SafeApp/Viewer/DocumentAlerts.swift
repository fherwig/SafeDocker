import AppKit
import SafeCore

// WP3. Alerts and messages shared by the editor, the viewer and export. The
// hooks (presenter, askPassword, saveRefusal) let the checks answer without
// a dialog on the screen.

/// Messages and alerts for the editor, the viewer and export.
enum DocumentAlerts {
    /// Answers alerts instead of showing them; only the checks set it.
    static var presenter: ((NSAlert, NSWindow?, @escaping (NSApplication.ModalResponse) -> Void) -> Void)?

    /// The system beep; the checks replace it.
    static var beep: () -> Void = { NSSound.beep() }

    /// Asks for a password (PasswordPrompt.askOnce); the checks replace it.
    static var askPassword: (_ title: String, _ message: String) -> SecureBytes? = { title, message in
        PasswordPrompt.askOnce(title: title, message: message)
    }

    /// Nil if saving is allowed, else why not: while the self-test runs or after it
    /// failed, every encrypt and save is refused (G5, 4.1). The checks replace it.
    static var saveRefusal: () -> String? = {
        guard let delegate = NSApp?.delegate as? AppDelegate else { return nil }
        guard let report = delegate.selfTestReport else {
            return L("Safe is still checking that it can read back what it writes. Try again in a moment.")
        }
        if report.ok {
            return nil
        }
        return L("Safe's self-test failed, so it does not encrypt or save anything: %@",
                 report.failures.joined(separator: "; "))
    }

    /// Shows the alert as a sheet on a visible window, otherwise modal, and passes on the answer.
    static func run(_ alert: NSAlert, on window: NSWindow?,
                    completion: @escaping (NSApplication.ModalResponse) -> Void) {
        Alerts.assignCancelEscape(alert)
        if let presenter = presenter {
            presenter(alert, window, completion)
            return
        }
        if let window = window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// An alert with one OK button.
    static func show(_ title: String, _ message: String, on window: NSWindow?,
                     style: NSAlert.Style = .warning, completion: (() -> Void)? = nil) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        run(alert, on: window) { _ in completion?() }
    }

    /// A sentence for the user about an error from SafeCore.
    static func describe(_ error: Error) -> String {
        guard let error = error as? CryptError else {
            return error.localizedDescription
        }
        switch error {
        case .notEncrypted:
            return L("The file is not an encrypted file that Safe knows.")
        case .wrongPassword:
            return L("The password does not open the file.")
        case .corrupt:
            return L("The encrypted file is damaged.")
        case .wrongPasswordOrDamaged:
            return L("The password does not open the file, or the file is damaged.")
        case .damaged:
            return L("The file is damaged: its end is missing.")
        case .conflict:
            return L("The file changed on disk since it was opened.")
        case .checkFailed:
            return L("The encrypted file could not be read back correctly, so nothing was replaced.")
        case .alreadyExists(let name):
            return L("%@ exists already.", name)
        case .io(let message):
            return message
        case .selfTestFailed(let message):
            return L("Safe's self-test failed, so it does not encrypt or save anything: %@", message)
        }
    }

    /// The old format a file was opened from, in words (G5).
    static func describe(_ variant: CryptVariant) -> String {
        switch variant {
        case .current: return L("current format")
        case .legacyAESMD5: return L("AES-256-CBC, key from MD5")
        case .legacyAESSHA256: return L("AES-256-CBC, key from SHA-256 without PBKDF2")
        case .legacyRC4MD5: return L("RC4, key from MD5")
        case .legacyRC4SHA256: return L("RC4, key from SHA-256")
        }
    }

    /// ~/folder for a file's folder, for window subtitles and messages.
    static func folderName(of url: URL) -> String {
        (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    }

    /// Ends the sheets of a window before it is locked or closed; their completion
    /// handlers see a response that is not one of their buttons and do nothing.
    static func endSheets(of window: NSWindow?) {
        guard let window = window else { return }
        for sheet in window.sheets.reversed() {
            window.endSheet(sheet, returnCode: .abort)
        }
    }
}
