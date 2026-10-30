import Foundation

// Safe's own words in English and German (version 0.3.0). Every text that the
// user sees goes through L() or Lp(). The key is the English text itself, with
// %@ for a piece of text and %ld for a number, so that the code reads as before
// and English never depends on a file: without a table, or for a key that a table
// lacks, the key is the text. The German texts are in
// Resources/de.lproj/Localizable.strings, as "English" = "Deutsch"; pairs, and
// Resources/en.lproj/Localizable.strings lists every key once, for the checks.
// The tables are read directly rather than through Bundle's choice of language,
// because the language is Safe's own setting, not macOS's (architecture.md,
// section 12). Command-line output and log lines are not translated.

/// The languages of Safe's windows and messages.
public enum AppLanguage: String, CaseIterable {
    case english = "en", german = "de"
}

/// The tables and the language in use.
public enum Localization {
    private static let lock = NSLock()
    private static var currentLanguage = AppLanguage.english
    private static var directory: URL?
    private static var tables: [AppLanguage: [String: String]] = [:]
    private static var recording: Set<String>?

    /// The name of each language's table inside its .lproj folder.
    public static let tableName = "Localizable.strings"

    /// The language of Safe's own texts. English unless the app sets another;
    /// the command-line modes always use English.
    public static var language: AppLanguage {
        get {
            lock.lock()
            defer { lock.unlock() }
            return currentLanguage
        }
        set {
            lock.lock()
            currentLanguage = newValue
            lock.unlock()
        }
    }

    /// The folder that holds en.lproj and de.lproj: the app's Resources. Nil
    /// until the app sets it; then only the English keys are used.
    public static var resourceDirectory: URL? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return directory
        }
        set {
            lock.lock()
            directory = newValue
            tables = [:]
            lock.unlock()
        }
    }

    /// Where a language's table is, or would be.
    public static func tableURL(_ language: AppLanguage, in directory: URL) -> URL {
        directory.appendingPathComponent("\(language.rawValue).lproj/\(tableName)")
    }

    /// A .strings file as a dictionary; nil if it cannot be read.
    public static func loadTable(at url: URL) -> [String: String]? {
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return nil
        }
        return plist as? [String: String]
    }

    /// The table of a language, read once; empty if there is none.
    public static func table(_ language: AppLanguage) -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        if let table = tables[language] {
            return table
        }
        let table = directory.flatMap { loadTable(at: tableURL(language, in: $0)) } ?? [:]
        tables[language] = table
        return table
    }

    /// The text for a key in a language (the current one if nil), else in
    /// English, else the key itself.
    public static func string(_ key: String, in language: AppLanguage? = nil) -> String {
        let language = language ?? self.language
        record(key)
        if language != .english, let text = table(language)[key], !text.isEmpty {
            return text
        }
        if let text = table(.english)[key], !text.isEmpty {
            return text
        }
        return englishText(of: key)
    }

    /// The English text of a key: the key itself, without the context that
    /// tells apart two meanings of the same English words, as in "[state] Open"
    /// (German "Geöffnet") beside "Open" (German "Öffnen").
    public static func englishText(of key: String) -> String {
        guard key.hasPrefix("["), let close = key.range(of: "] ") else { return key }
        return String(key[close.upperBound...])
    }

    /// Fills in a format the way L does: positions (%1$@) allowed, numbers
    /// without a thousands separator.
    public static func format(_ format: String, _ args: [CVarArg]) -> String {
        args.isEmpty ? format : String(format: format, locale: nil, arguments: args)
    }

    // MARK: checks

    /// Starts noting every key looked up, for the app tests.
    public static func startRecording() {
        lock.lock()
        recording = []
        lock.unlock()
    }

    /// The keys looked up since startRecording, and stops noting them.
    public static func stopRecording() -> Set<String> {
        lock.lock()
        defer { lock.unlock() }
        let keys = recording ?? []
        recording = nil
        return keys
    }

    private static func record(_ key: String) {
        lock.lock()
        recording?.insert(key)
        lock.unlock()
    }

    /// The format specifiers of a text, as (position, kind) in order of position,
    /// for example [(1, "@"), (2, "ld")]; "%%" is not one. Nil if the text mixes
    /// specifiers with and without positions, which String(format:) cannot read.
    public static func specifiers(of text: String) -> [(Int, String)]? {
        var result: [(Int, String)] = []
        var positional: Bool?
        let chars = Array(text)
        var index = 0
        var next = 1
        while index < chars.count {
            guard chars[index] == "%" else {
                index += 1
                continue
            }
            index += 1
            guard index < chars.count else { break }
            if chars[index] == "%" {
                index += 1
                continue
            }
            var digits = ""
            var probe = index
            while probe < chars.count, chars[probe].isNumber {
                digits.append(chars[probe])
                probe += 1
            }
            var position: Int
            if !digits.isEmpty, probe < chars.count, chars[probe] == "$" {
                if positional == false { return nil }
                positional = true
                position = Int(digits) ?? 0
                index = probe + 1
            } else {
                if positional == true { return nil }
                positional = false
                position = next
                next += 1
            }
            var kind = ""
            while index < chars.count, "lhqjztL".contains(chars[index]) {
                kind.append(chars[index])
                index += 1
            }
            if index < chars.count {
                kind.append(chars[index])
                index += 1
            }
            result.append((position, kind))
        }
        return result.sorted { $0.0 < $1.0 }
    }
}

/// The text of `key` in Safe's language, with the arguments filled in. The key
/// is the English text; arguments are Strings for %@ and Ints for %ld.
public func L(_ key: String, _ args: CVarArg...) -> String {
    Localization.format(Localization.string(key), args)
}

/// A text with a number in it, in the singular when the number is 1 and in the
/// plural otherwise, which is the rule of both English and German: Lp(n,
/// "%ld file", "%ld files"). The number is the first argument of the format.
public func Lp(_ count: Int, _ one: String, _ other: String, _ args: CVarArg...) -> String {
    Localization.format(Localization.string(count == 1 ? one : other), [count] + args)
}

/// Marks a literal as a key whose text is looked up later with
/// Localization.string, for titles that must change with the language after
/// they were made (the menu bar); returns the key itself. The checks find the
/// keys of L, Lp and LKey in the source code.
public func LKey(_ key: String) -> String {
    key
}
