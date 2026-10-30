import Foundation

// WP3. The parts of the editor (building plan 4.5) that need no window: search,
// the status line, the name of a conflict copy, the clipboard check and the
// keyboard shortcuts. Only Foundation, so that the file can move to SafeCore
// and be tested there. Ranges are UTF-16 NSRanges, as NSTextView uses them.

/// Case-insensitive search over the text; never touches the system's find pasteboard.
public enum TextSearch {
    /// The first match at or after `location`, or with `backwards` the last match that
    /// ends before `location`; wraps around the end. Nil if there is none.
    public static func find(_ needle: String, in text: String, from location: Int,
                            backwards: Bool) -> NSRange? {
        guard !needle.isEmpty else { return nil }
        let ns = text as NSString
        let length = ns.length
        let start = min(max(location, 0), length)
        var options: NSString.CompareOptions = [.caseInsensitive]
        let firstTry: NSRange
        if backwards {
            options.insert(.backwards)
            firstTry = NSRange(location: 0, length: start)
        } else {
            firstTry = NSRange(location: start, length: length - start)
        }
        let found = ns.range(of: needle, options: options, range: firstTry)
        if found.location != NSNotFound {
            return found
        }
        let wrapped = ns.range(of: needle, options: options, range: NSRange(location: 0, length: length))
        return wrapped.location == NSNotFound ? nil : wrapped
    }

    /// The number of matches that do not overlap.
    public static func count(_ needle: String, in text: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        let ns = text as NSString
        var count = 0
        var rest = NSRange(location: 0, length: ns.length)
        while true {
            let found = ns.range(of: needle, options: .caseInsensitive, range: rest)
            if found.location == NSNotFound || found.length == 0 {
                break
            }
            count += 1
            let next = NSMaxRange(found)
            rest = NSRange(location: next, length: ns.length - next)
        }
        return count
    }
}

/// The text of a selection that may have several ranges.
public enum TextSelection {
    /// The selected pieces in text order, joined by line breaks; ranges outside the text are dropped.
    public static func joined(_ text: String, ranges: [NSRange]) -> String {
        let ns = text as NSString
        return ranges
            .filter { $0.location != NSNotFound && $0.length > 0 && NSMaxRange($0) <= ns.length }
            .sorted { $0.location < $1.location }
            .map { ns.substring(with: $0) }
            .joined(separator: "\n")
    }
}

/// The status line under the text.
public enum EditorStatus {
    /// Shown while the window is locked.
    public static var locked: String {
        L("Locked. The unsaved changes are kept; type the file's password to show them again.")
    }

    /// "Decrypted in memory only. Saved 14:05, the previous version is kept as NAME.crypt.bak."
    /// `legacyName` names the old format the file was opened from, until it is saved;
    /// `codingName` the text's encoding when it is not plain UTF-8.
    public static func line(savedAt: Date?, backupName: String?, legacyName: String?,
                            codingName: String? = nil, timeZone: TimeZone = .current) -> String {
        var line = L("Decrypted in memory only.")
        if let codingName = codingName {
            line += " " + L("Text in %@.", codingName)
        }
        if let savedAt = savedAt {
            let time = clock(savedAt, timeZone: timeZone)
            if let backupName = backupName {
                line += " " + L("Saved %@, the previous version is kept as %@.", time, backupName)
            } else {
                line += " " + L("Saved %@.", time)
            }
        } else if let legacyName = legacyName {
            line += " " + L("Opened from an old format (%@); saving writes the current format.", legacyName)
        }
        return line
    }

    /// NAME.crypt.bak for NAME.crypt, as CryptFile.save keeps it.
    public static func backupName(forEncryptedFileName name: String) -> String {
        name + ".bak"
    }

    /// Hours and minutes, 24-hour clock.
    public static func clock(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

/// The name of the separate copy written when the file changed on disk (4.5).
public enum ConflictName {
    /// "notes (conflict 2026-10-25 14-05).md.crypt" for "notes.md". The ending stays
    /// last, so the copy opens as the same kind of file; no colon or dot in the time.
    /// `exists` tells whether a name is taken in the folder; then " 2", " 3" and so on.
    public static func make(originalName: String, date: Date, timeZone: TimeZone = .current,
                            exists: (String) -> Bool) -> String {
        let (stem, ending) = split(originalName)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let p = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let stamp = String(format: "%04d-%02d-%02d %02d-%02d",
                           p.year ?? 0, p.month ?? 0, p.day ?? 0, p.hour ?? 0, p.minute ?? 0)
        for n in 1...999 {
            let label = n == 1 ? "conflict \(stamp)" : "conflict \(stamp) \(n)"
            let name = "\(stem) (\(label))" + (ending.isEmpty ? "" : "." + ending) + ".crypt"
            if !exists(name) {
                return name
            }
        }
        return "\(stem) (conflict \(UUID().uuidString))" + (ending.isEmpty ? "" : "." + ending) + ".crypt"
    }

    /// Splits "notes.md" into ("notes", "md"); names without a real ending keep it empty.
    static func split(_ name: String) -> (String, String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ending = String(name[name.index(after: dot)...])
        if ending.isEmpty || ending.contains(" ") {
            return (name, "")
        }
        return (String(name[..<dot]), ending)
    }
}

/// The clipboard rule of 4.5: clear only what the app itself put there.
public enum ClipboardPolicy {
    /// Seconds until copied text is cleared.
    public static let clearAfter: TimeInterval = 60
    /// Markers that clipboard managers honour (nspasteboard.org).
    public static let concealedType = "org.nspasteboard.ConcealedType"
    public static let transientType = "org.nspasteboard.TransientType"

    /// True if the clipboard still holds what the app put there.
    public static func shouldClear(currentChangeCount: Int, ourChangeCount: Int?) -> Bool {
        guard let ours = ourChangeCount else { return false }
        return ours == currentChangeCount
    }

    /// The preference of macOS 26's Spotlight clipboard history
    /// (com.apple.Spotlight), which may keep copied text for hours after the
    /// clipboard is cleared. Whether it honours the concealed and transient
    /// markers is not known, so Safe asks before the first copy (review round 4).
    public static let historyPreferenceDomain = "com.apple.Spotlight"
    public static let historyPreferenceKey = "PasteboardHistoryEnabled"

    /// True if macOS may keep a clipboard history: the preference is on, or, on
    /// macOS 26 or later, not set (its default is not known).
    public static func historyMayBeOn(preference: Any?, macOSMajor: Int) -> Bool {
        if let on = preference as? Bool {
            return on
        }
        if let number = preference as? NSNumber {
            return number.intValue != 0
        }
        return preference == nil && macOSMajor >= 26
    }
}

/// What a keyboard shortcut in the editor window asks for.
public enum EditorCommand: Equatable {
    case save, close, find, findNext, findPrevious, cut, copy, paste, selectAll, undo, redo
}

/// The editor's own shortcuts, so that it works whatever the main menu holds.
public enum EditorShortcuts {
    /// The command for a key (charactersIgnoringModifiers) and the modifier keys, or nil.
    public static func command(key: String, command: Bool, shift: Bool, option: Bool,
                               control: Bool) -> EditorCommand? {
        guard command, !option, !control else { return nil }
        switch (key.lowercased(), shift) {
        case ("s", false): return .save
        case ("w", false): return .close
        case ("f", false): return .find
        case ("g", false): return .findNext
        case ("g", true): return .findPrevious
        case ("x", false): return .cut
        case ("c", false): return .copy
        case ("v", false): return .paste
        case ("a", false): return .selectAll
        case ("z", false): return .undo
        case ("z", true): return .redo
        default: return nil
        }
    }
}
