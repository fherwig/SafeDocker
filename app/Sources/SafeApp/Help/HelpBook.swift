import AppKit
import SafeCore

// The owner's manual: Resources/SafeHelp.md, a small Markdown file that
// build-app.sh copies into Safe.app/Contents/Resources. It is drawn into a
// read-only text view by the small renderer below, with AppKit only: no web
// view, nothing that could load content from elsewhere (the app has no network,
// section 4.1 of the plan), and not Apple's Help Viewer, which needs a help book.

/// The sections of the manual, in order; the raw value is the anchor written
/// after the heading in SafeHelp.md, as in "## Volumes {#volumes}".
enum HelpSection: String, CaseIterable {
    case idea, passwords, encrypting, editing, viewing, volumes, locking, longterm, settings, shortcuts, problems

    /// The heading in the help file of Safe's language (SafeHelp.md, SafeHelp.de.md).
    var title: String {
        switch self {
        case .idea: return L("The idea behind Safe")
        case .passwords: return L("Passwords")
        case .encrypting: return L("Encrypting a file")
        case .editing: return L("Opening and editing a text file")
        case .viewing: return L("Viewing PDFs and pictures, and exporting")
        case .volumes: return L("Volumes")
        case .locking: return L("Locking")
        case .longterm: return L("Old files and the long term")
        case .settings: return L("Settings and language")
        case .shortcuts: return L("Keyboard shortcuts")
        case .problems: return L("When something goes wrong")
        }
    }

    /// The title in the help window's list of sections, short enough for it.
    var shortTitle: String {
        self == .viewing ? L("Viewing and exporting") : title
    }
}

/// The manual, found, read and drawn.
struct HelpBook {
    /// The name of the English file in Resources.
    static let fileName = "SafeHelp.md"

    /// The name of a language's file in Resources: SafeHelp.md, SafeHelp.de.md.
    static func helpFileName(for language: AppLanguage) -> String {
        language == .english ? fileName : "SafeHelp.\(language.rawValue).md"
    }

    /// The text as drawn.
    let text: NSAttributedString
    /// Where each section's heading is in `text`.
    let headings: [HelpSection: NSRange]
    /// False if the file was missing or unreadable and `text` is the short note.
    let isComplete: Bool

    /// The help file of Safe's language in the app bundle's Resources; a debug
    /// build run outside Safe.app (swift run, the tests) uses app/Resources of
    /// its source tree.
    static var resourceURL: URL {
        helpURL(for: Localization.language)
    }

    /// The help file of a language.
    static func helpURL(for language: AppLanguage) -> URL {
        AppInfo.resourcesDirectory.appendingPathComponent(helpFileName(for: language))
    }

    /// Reads and draws the manual in Safe's language; the English one if that
    /// file cannot be read, and a short note if neither can.
    static func load() -> HelpBook {
        let own = load(from: resourceURL)
        if own.isComplete || Localization.language == .english {
            return own
        }
        let english = load(from: helpURL(for: .english))
        return english.isComplete ? english : own
    }

    /// Reads and draws the manual from a file; a short note if it is missing.
    static func load(from url: URL) -> HelpBook {
        if let data = try? Data(contentsOf: url), let markdown = String(data: data, encoding: .utf8),
           markdown.contains("## ") {
            let rendered = HelpRenderer.render(markdown)
            return HelpBook(text: rendered.text, headings: rendered.headings, isComplete: true)
        }
        let rendered = HelpRenderer.render(fallback)
        return HelpBook(text: rendered.text, headings: rendered.headings, isComplete: false)
    }

    /// True if the file can be read and has a heading for every section; for --check.
    static func isComplete(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let markdown = String(data: data, encoding: .utf8) else {
            return false
        }
        return HelpSection.allCases.allSatisfy { markdown.contains("{#\($0.rawValue)}") }
    }

    /// Shown when the help file cannot be read, so that the window is never empty.
    static var fallback: String {
        L("""
        # Safe Help

        The help text is missing from this copy of Safe (Contents/Resources/%@). \
        Safe itself works as usual. Ask whoever installed Safe to build it again with \
        app/scripts/build-app.sh. The same text is in the source code, in app/Resources/%@.

        In short:

        - Encrypt a file: right-click it in the Finder and choose Encrypt with Safe.
        - Open an encrypted file: double-click it. Command-S saves it encrypted again.
        - Volumes: Window > Volumes (Command-0).
        - Safe locks after 10 minutes without input, and when the Mac sleeps or locks.
        - A lost password cannot be recovered.
        """, helpFileName(for: Localization.language), helpFileName(for: Localization.language))
    }

    /// The plain text of one section, from its heading to the next; for the checks.
    func plainText(of section: HelpSection) -> String? {
        guard let start = headings[section] else { return nil }
        let following = headings.values.map(\.location).filter { $0 > start.location }.min() ?? text.length
        return (text.string as NSString).substring(with: NSRange(location: start.location,
                                                                 length: following - start.location))
    }
}

/// Draws the Markdown of SafeHelp.md: headings (#, ## with an {#anchor}, ###),
/// paragraphs, lists (- and 1.), tables with |, code indented by four spaces,
/// and inline `code` and **bold**. Nothing else is needed, and nothing else is read.
enum HelpRenderer {
    struct Result {
        let text: NSAttributedString
        let headings: [HelpSection: NSRange]
    }

    static let bodySize: CGFloat = 13

    static func render(_ markdown: String) -> Result {
        let out = NSMutableAttributedString()
        var headings: [HelpSection: NSRange] = [:]
        var paragraph: [String] = []
        var table: [String] = []
        var code: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            append(inline(paragraph.joined(separator: " "), font: body), style: bodyStyle(), to: out)
            paragraph = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            appendTable(table, to: out)
            table = []
        }
        func flushCode() {
            guard !code.isEmpty else { return }
            let style = bodyStyle()
            style.headIndent = 22
            style.firstLineHeadIndent = 22
            style.paragraphSpacing = 2
            for (index, line) in code.enumerated() {
                if index == code.count - 1 {
                    style.paragraphSpacing = 10
                }
                append(NSAttributedString(string: line, attributes: [.font: monospaced(bodySize - 1),
                                                                     .foregroundColor: NSColor.labelColor]),
                       style: style.copy() as! NSParagraphStyle, to: out)
            }
            code = []
        }
        func flushAll() {
            flushParagraph()
            flushTable()
            flushCode()
        }

        for rawLine in markdown.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("    ") && paragraph.isEmpty && table.isEmpty && !trimmed.isEmpty {
                code.append(String(line.dropFirst(4)))
                continue
            }
            if trimmed.isEmpty {
                flushAll()
                continue
            }
            flushCode()
            if trimmed.hasPrefix("|") {
                flushParagraph()
                table.append(trimmed)
                continue
            }
            flushTable()
            if let (level, title) = heading(trimmed) {
                flushParagraph()
                var text = title
                var anchor: String?
                if let open = text.range(of: " {#"), text.hasSuffix("}") {
                    anchor = String(text[open.upperBound ..< text.index(before: text.endIndex)])
                    text = String(text[..<open.lowerBound])
                }
                let start = out.length
                append(inline(text, font: headingFont(level)), style: headingStyle(level), to: out)
                if let anchor = anchor, let section = HelpSection(rawValue: anchor) {
                    headings[section] = NSRange(location: start, length: (text as NSString).length)
                }
                continue
            }
            if let (marker, item) = listItem(trimmed) {
                flushParagraph()
                let content = NSMutableAttributedString(string: marker + "\t",
                                                        attributes: [.font: body, .foregroundColor: NSColor.labelColor])
                content.append(inline(item, font: body))
                append(content, style: listStyle(), to: out)
                continue
            }
            paragraph.append(trimmed)
        }
        flushAll()
        // no empty line after the last paragraph
        if out.string.hasSuffix("\n") {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
        return Result(text: out, headings: headings)
    }

    // MARK: blocks

    private static func heading(_ line: String) -> (Int, String)? {
        for level in 1 ... 3 {
            let prefix = String(repeating: "#", count: level) + " "
            if line.hasPrefix(prefix) {
                return (level, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func listItem(_ line: String) -> (String, String)? {
        if line.hasPrefix("- ") {
            return ("•", String(line.dropFirst(2)))
        }
        let digits = line.prefix { $0.isNumber }
        if !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") {
            return (digits + ".", String(line.dropFirst(digits.count + 2)))
        }
        return nil
    }

    /// A table as rows with tab stops; the first row bold, the |---| row left out.
    private static func appendTable(_ rows: [String], to out: NSMutableAttributedString) {
        let cells: [[String]] = rows.compactMap { row in
            var parts = row.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.first == "" { parts.removeFirst() }
            if parts.last == "" { parts.removeLast() }
            if parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0 == "-" || $0 == ":" } }) {
                return nil
            }
            return parts
        }
        guard let columns = cells.map(\.count).max(), columns > 0 else { return }
        // each column as wide as its widest cell, but the last, which wraps
        var stops: [CGFloat] = []
        var x: CGFloat = 8
        for column in 0 ..< columns - 1 {
            let widest = cells.map { row -> CGFloat in
                guard column < row.count else { return 0 }
                return inline(row[column], font: bold).size().width
            }.max() ?? 0
            x += min(widest, 260) + 18
            stops.append(x)
        }
        for (index, row) in cells.enumerated() {
            let style = NSMutableParagraphStyle()
            style.tabStops = stops.map { NSTextTab(textAlignment: .left, location: $0) }
            style.defaultTabInterval = 40
            style.firstLineHeadIndent = 8
            style.headIndent = stops.last ?? 8
            style.paragraphSpacing = index == cells.count - 1 ? 12 : 3
            style.lineBreakMode = .byWordWrapping
            let line = NSMutableAttributedString()
            for (column, cell) in row.enumerated() {
                if column > 0 {
                    line.append(NSAttributedString(string: "\t", attributes: [.font: body]))
                }
                line.append(inline(cell, font: index == 0 ? bold : body))
            }
            append(line, style: style, to: out)
        }
    }

    private static func append(_ content: NSAttributedString, style: NSParagraphStyle,
                               to out: NSMutableAttributedString) {
        let line = NSMutableAttributedString(attributedString: content)
        line.append(NSAttributedString(string: "\n", attributes: [.font: body]))
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        out.append(line)
    }

    // MARK: inline

    /// `code` in a fixed-width font, **bold** in bold; everything else as written.
    static func inline(_ text: String, font: NSFont) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var isBold = false
        var buffer = ""
        var index = text.startIndex
        func flush() {
            guard !buffer.isEmpty else { return }
            let face = isBold ? NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) : font
            out.append(NSAttributedString(string: buffer, attributes: [.font: face, .foregroundColor: NSColor.labelColor]))
            buffer = ""
        }
        while index < text.endIndex {
            let rest = text[index...]
            if rest.hasPrefix("**") {
                flush()
                isBold.toggle()
                index = text.index(index, offsetBy: 2)
                continue
            }
            if rest.hasPrefix("`"), let close = rest.dropFirst().firstIndex(of: "`") {
                flush()
                let codeText = String(text[text.index(after: index) ..< close])
                out.append(NSAttributedString(string: codeText, attributes: [
                    .font: monospaced(font.pointSize - 1), .foregroundColor: NSColor.labelColor,
                ]))
                index = text.index(after: close)
                continue
            }
            buffer.append(text[index])
            index = text.index(after: index)
        }
        flush()
        return out
    }

    // MARK: fonts and paragraph styles

    static var body: NSFont { NSFont.systemFont(ofSize: bodySize) }
    static var bold: NSFont { NSFont.boldSystemFont(ofSize: bodySize) }

    static func monospaced(_ size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func headingFont(_ level: Int) -> NSFont {
        switch level {
        case 1: return NSFont.systemFont(ofSize: 24, weight: .bold)
        case 2: return NSFont.systemFont(ofSize: 19, weight: .bold)
        default: return NSFont.systemFont(ofSize: 14.5, weight: .semibold)
        }
    }

    private static func headingStyle(_ level: Int) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = level == 1 ? 0 : (level == 2 ? 22 : 10)
        style.paragraphSpacing = level == 3 ? 4 : 8
        return style
    }

    private static func bodyStyle() -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        style.lineHeightMultiple = 1.12
        return style
    }

    private static func listStyle() -> NSParagraphStyle {
        let style = bodyStyle()
        style.tabStops = [NSTextTab(textAlignment: .left, location: 24)]
        style.firstLineHeadIndent = 6
        style.headIndent = 24
        style.paragraphSpacing = 4
        return style
    }
}
