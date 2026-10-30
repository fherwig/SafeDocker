import AppKit
import SafeCore

// WP3. The interface is fixed by the building plan, section 3.1.

/// Copies text marked as concealed and transient, and clears it again (section 4.5).
enum ClipboardGuard {
    /// The general pasteboard; the checks use a private one instead.
    static var pasteboard: NSPasteboard = .general
    /// Seconds until the text is cleared.
    static var clearDelay: TimeInterval = ClipboardPolicy.clearAfter

    private static var ourChangeCount: Int?
    private static var pendingClear: DispatchWorkItem?

    /// True if the pasteboard copied to is the one macOS's clipboard history
    /// watches, the general one; the checks copy to a private one.
    static var watchedByHistory: () -> Bool = { pasteboard == NSPasteboard.general }
    /// True if macOS may keep a clipboard history (Spotlight on macOS 26), which
    /// Safe cannot clear; the checks replace it.
    static var historyMayBeOn: () -> Bool = {
        ClipboardPolicy.historyMayBeOn(
            preference: CFPreferencesCopyAppValue(ClipboardPolicy.historyPreferenceKey as CFString,
                                                  ClipboardPolicy.historyPreferenceDomain as CFString),
            macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
    }
    /// Asks whether to copy although the history may keep the text; true to copy.
    /// The checks replace it.
    static var confirmDespiteHistory: () -> Bool = {
        Alerts.choose(L("macOS may keep what you copy"), L("""
            macOS keeps a clipboard history (Spotlight). Safe marks what it copies as concealed \
            and empties the clipboard after a minute, but it cannot empty that history, which \
            may keep the copied text for hours, outside Safe's encryption. You can switch the \
            history off in System Settings > Spotlight. Safe asks this once each time it starts.
            """), buttons: [L("Copy"), L("Cancel")]) == 0
    }
    /// True once the user agreed to copy despite the history, until Safe quits.
    private static var historyAccepted = false

    /// Puts the string on the clipboard for this Mac only and clears it after 60 s.
    /// The first time in a run, if macOS may keep a clipboard history, the user is
    /// asked first (finding of review round 4). Returns false if nothing was copied.
    @discardableResult
    static func copy(_ string: String) -> Bool {
        if !historyAccepted && watchedByHistory() && historyMayBeOn() {
            guard confirmDespiteHistory() else { return false }
            historyAccepted = true
        }
        let pb = pasteboard
        // currentHostOnly keeps it off Universal Clipboard
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.setString(string, forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPolicy.concealedType))
        pb.setData(Data(), forType: NSPasteboard.PasteboardType(ClipboardPolicy.transientType))
        ourChangeCount = pb.changeCount

        pendingClear?.cancel()
        let work = DispatchWorkItem { clearIfOurs() }
        pendingClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + clearDelay, execute: work)
        return true
    }

    /// For the checks: forget that the user agreed to copy despite the history.
    static func resetHistoryAnswer() {
        historyAccepted = false
    }

    /// Clears the clipboard if it still holds what the app put there.
    static func clearIfOurs() {
        pendingClear?.cancel()
        pendingClear = nil
        let pb = pasteboard
        if ClipboardPolicy.shouldClear(currentChangeCount: pb.changeCount, ourChangeCount: ourChangeCount) {
            pb.clearContents()
        }
        ourChangeCount = nil
    }
}
