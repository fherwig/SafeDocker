import AppKit
import SafeCore

// WP4. The selectors match NSMessage in Resources/Info.plist (encryptFiles,
// openFiles, exportFiles); keep them in step. The file names are read from the
// pasteboard at once, while it is valid; the dialogs come afterwards, so that
// the Finder does not wait for the user.

/// Receives the Finder's Services requests and hands the files to DocumentRouter (section 4.2).
final class ServicesProvider: NSObject {
    /// Encrypt with Safe.
    @objc(encryptFiles:userData:error:)
    func encryptFiles(_ pboard: NSPasteboard, userData: String?,
                      error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        hand(pboard, error) { DocumentRouter.shared.encrypt($0) }
    }

    /// Open with Safe.
    @objc(openFiles:userData:error:)
    func openFiles(_ pboard: NSPasteboard, userData: String?,
                   error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        hand(pboard, error) { DocumentRouter.shared.open($0) }
    }

    /// Export with Safe.
    @objc(exportFiles:userData:error:)
    func exportFiles(_ pboard: NSPasteboard, userData: String?,
                     error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        hand(pboard, error) { DocumentRouter.shared.export($0) }
    }

    private func hand(_ pboard: NSPasteboard, _ error: AutoreleasingUnsafeMutablePointer<NSString?>,
                      to action: @escaping ([URL]) -> Void) {
        let urls = Self.fileURLs(on: pboard)
        guard !urls.isEmpty else {
            error.pointee = L("Safe received no files.") as NSString
            return
        }
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            action(urls)
        }
    }

    /// The file URLs on a Services pasteboard.
    static func fileURLs(on pboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           !urls.isEmpty {
            return urls
        }
        // older senders put a list of paths
        let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let paths = pboard.propertyList(forType: filenames) as? [String] ?? []
        return paths.map { URL(fileURLWithPath: $0) }
    }
}
