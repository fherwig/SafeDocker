import AppKit
import SafeCore

// WP4. The password dialogs of section 3.1: modal alerts with secure fields.
// The typed text goes into a SecureBytes and the fields are emptied at once.

/// The password dialogs.
enum PasswordPrompt {
    /// Modal; returns nil on Cancel. The message names the file.
    static func askOnce(title: String, message: String) -> SecureBytes? {
        let (alert, field) = onceAlert(title: title, message: message)
        let ok = run(alert)
        defer { field.stringValue = "" }
        return ok ? SecureBytes(string: typedPassword(field.stringValue)) : nil
    }

    /// The password as typed, without line breaks at its end. They come from
    /// pasting a line copied with its line break; no password can end in one,
    /// because openssl and crypt.sh read a password only up to the line break, and
    /// Safe refuses new passwords with one (newPasswordProblem).
    static func typedPassword(_ text: String) -> String {
        var password = text
        while let last = password.unicodeScalars.last, last == "\n" || last == "\r" {
            password.unicodeScalars.removeLast()
        }
        return password
    }

    /// The most bytes a password can have: openssl's password prompt reads at
    /// most 511, so a longer one could not be typed there (G3).
    static let longestPassword = 511

    /// Two fields that must match and must not be empty. A password that the
    /// fields cannot take from the keyboard (needsPasting) is taken only the
    /// second time, after a note that it will have to be pasted.
    static func askTwice(title: String, message: String) -> SecureBytes? {
        var problem: String?
        var warnedAboutPasting = false
        while true {
            let text = problem.map { message + "\n\n" + $0 } ?? message
            let (alert, first, second) = twiceAlert(title: title, message: text)
            let ok = run(alert)
            defer {
                first.stringValue = ""
                second.stringValue = ""
            }
            guard ok else { return nil }
            problem = newPasswordProblem(first.stringValue, second.stringValue)
            if problem == nil && !warnedAboutPasting && needsPasting(first.stringValue) {
                problem = pastingNote
                warnedAboutPasting = true
            } else if problem == nil {
                return SecureBytes(string: first.stringValue)
            }
        }
    }

    /// Said once when a new password needs pasting (finding of review round 4).
    static var pastingNote: String {
        L("""
        This password has letters of a script other than Latin, or emoji. Password fields on \
        the Mac, Safe's included, take only Latin keyboard layouts and no emoji, so to open the \
        file later you would have to paste the password, and should clear the clipboard \
        afterwards. To use it anyway, type or paste it twice again and click OK.
        """)
    }

    /// True if the password has characters that a secure text field does not
    /// take from the keyboard: macOS allows such fields only Roman input sources
    /// (allowedInputSourceLocales) and switches off the emoji palette, so letters
    /// of other scripts (Greek, Cyrillic, Hebrew, Arabic, Chinese, Japanese,
    /// Korean and others) and emoji can only be pasted. Latin letters with
    /// accents, digits, punctuation and the symbols of Roman layouts are fine.
    static func needsPasting(_ password: String) -> Bool {
        password.unicodeScalars.contains { scalar in
            let v = scalar.value
            if scalar.properties.isEmojiPresentation || v == 0xFE0F || v >= 0x1F000 {
                return true
            }
            // CJK, Hangul, kana and what follows them; not the Latin ligatures and
            // not the Apple logo, which Option-Shift-K gives
            if v >= 0x2E80 && !(0xFB00 ... 0xFB06).contains(v) && v != 0xF8FF {
                return true
            }
            guard scalar.properties.isAlphabetic, v >= 0x0370 else { return false }
            // Latin beyond Latin-1 and Extended-B: Extended Additional, C, D and E
            let latin: [ClosedRange<UInt32>] = [0x1E00 ... 0x1EFF, 0x2C60 ... 0x2C7F, 0xA720 ... 0xA7FF,
                                                0xAB30 ... 0xAB6F, 0x2070 ... 0x209F, 0x2100 ... 0x214F]
            // Greek letters that Option gives on Roman layouts: π, Ω, µ
            let typeable: Set<UInt32> = [0x03C0, 0x03A9, 0x03BC]
            return !latin.contains { $0.contains(v) } && !typeable.contains(v)
        }
    }

    /// Why a new password typed twice cannot be used, or nil if it can.
    static func newPasswordProblem(_ first: String, _ second: String) -> String? {
        if first.isEmpty && second.isEmpty {
            return L("The password must not be empty.")
        }
        // compare the bytes, so that two different ways of writing an accented
        // letter do not count as the same password
        if Array(first.utf8) != Array(second.utf8) {
            return L("The two passwords are not the same. Type them again.")
        }
        // openssl and crypt.sh read a password up to the line break, so a file
        // encrypted with one would open with neither (G3, G5)
        if first.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            return L("""
                The password contains a line break, probably from pasting. openssl and crypt.sh \
                cannot use such a password; type or paste it again without it.
                """)
        }
        if first.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            return L("""
                The password contains a control character, such as a tab, probably from pasting. \
                Type it again without it.
                """)
        }
        if first.utf8.count > longestPassword {
            return L("""
                The password is longer than %ld bytes, more than openssl's password prompt can \
                take. Choose a shorter one.
                """, longestPassword)
        }
        return nil
    }

    // MARK: - Building the alert

    /// The alert of askOnce, not shown yet.
    static func onceAlert(title: String, message: String) -> (NSAlert, NSSecureTextField) {
        let field = secureField()
        field.toolTip = L("Type the password. Safe does not show it, and forgets it after use.")
        let alert = makeAlert(title: title, message: message)
        alert.accessoryView = form([(L("Password:"), field)])
        alert.window.initialFirstResponder = field
        addHelp(to: alert)
        return (alert, field)
    }

    /// The alert of askTwice, not shown yet.
    static func twiceAlert(title: String, message: String) -> (NSAlert, NSSecureTextField, NSSecureTextField) {
        let first = secureField(), second = secureField()
        first.nextKeyView = second
        first.toolTip = L("Type the new password. It cannot be recovered if it is lost, so keep it somewhere safe.")
        second.toolTip = L("Type the same password again, so that a typing mistake cannot lock you out.")
        let alert = makeAlert(title: title, message: message)
        alert.accessoryView = form([(L("Password:"), first), (L("Again:"), second)])
        alert.window.initialFirstResponder = first
        addHelp(to: alert)
        return (alert, first, second)
    }

    /// The "?" button, which opens the help about passwords, and the buttons' tooltips.
    private static func addHelp(to alert: NSAlert) {
        alert.buttons.first?.toolTip = L("Use this password (Return).")
        alert.buttons.last?.toolTip = L("Close this dialog without doing anything (Escape).")
        HelpButton.add(to: alert, .passwords, toolTip: L("Open Safe Help about passwords."))
    }

    private static func makeAlert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: L("OK"))
        alert.addButton(withTitle: L("Cancel"))
        Alerts.assignCancelEscape(alert)
        alert.window.sharingType = .none
        return alert
    }

    /// Shows the alert in front of everything; true if OK was clicked.
    private static func run(_ alert: NSAlert) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func secureField() -> NSSecureTextField {
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 22))
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        return field
    }

    /// Labels and fields in a grid, sized for an alert's accessory view.
    static func form(_ rows: [(String, NSView)]) -> NSView {
        let grid = NSGridView(views: rows.map { label, view in
            [NSTextField(labelWithString: label), view]
        })
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        for (_, view) in rows {
            view.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        grid.frame = NSRect(origin: .zero, size: grid.fittingSize)
        return grid
    }
}
