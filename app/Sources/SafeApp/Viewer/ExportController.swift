import AppKit
import SafeCore

// WP3. The interface is fixed by the building plan, section 3.1.

/// Writes a decrypted original to a place the user chooses (R3, section 4.7).
enum ExportController {
    /// Asks where the copy goes: folder, proposed name, window, then the answer or nil.
    /// A save panel; the checks replace it.
    static var choosePlace: (URL, String, NSWindow?, @escaping (URL?) -> Void) -> Void = savePanel

    /// The mount points of the attached disk images; the checks replace it.
    static var volumeMountPoints: () -> [URL] = {
        ((try? DiskImage.attached()) ?? []).compactMap(\.mountPoint)
    }

    /// The lock count of the app (G4); the checks replace it.
    static var lockCount: () -> Int = { LockController.shared.lockCount }

    /// Save panel next to the encrypted file, the "not encrypted" warning, then
    /// CryptFile.export. For a file inside a volume the panel proposes the Desktop:
    /// a copy written into a volume stays readable in its image even after it is
    /// deleted. If Safe locks while a dialog is open, nothing is written (G4).
    static func export(_ data: Data, originalName: String, from encryptedFile: URL,
                       window: NSWindow?, note: String? = nil) {
        let mountPoints = volumeMountPoints()
        var folder = encryptedFile.deletingLastPathComponent()
        if isInside(folder, anyOf: mountPoints),
           let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first {
            folder = desktop
        }
        let asSheet = usesSheet(on: window)
        let locks = lockCount()
        choosePlace(folder, originalName, window) { url in
            guard let url = url else { return }
            let inVolume = isInside(url.deletingLastPathComponent(), anyOf: mountPoints)
            if asSheet {
                // a new sheet only after the save panel's sheet has gone
                DispatchQueue.main.async {
                    confirmAndWrite(data, to: url, encryptedFile: encryptedFile, window: window,
                                    inVolume: inVolume, locks: locks, note: note)
                }
            } else {
                // modal: finish this file before the caller goes on to the next
                confirmAndWrite(data, to: url, encryptedFile: encryptedFile, window: window,
                                inVolume: inVolume, locks: locks, note: note)
            }
        }
    }

    /// Sheets on a visible window without a sheet, else modal dialogs.
    static func usesSheet(on window: NSWindow?) -> Bool {
        guard let window = window else { return false }
        return window.isVisible && window.attachedSheet == nil
    }

    /// True if the place is the encrypted file, its .bak, or any encrypted file:
    /// the plaintext would replace it, and keep its .crypt name. On a disk that
    /// ignores case, or through another path, the names differ but the file is the
    /// same; so the file numbers are compared too.
    static func wouldReplaceEncryptedFile(_ url: URL, encryptedFile: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".crypt") || name.hasSuffix(".crypt.bak") {
            return true
        }
        if url.standardizedFileURL.path == encryptedFile.standardizedFileURL.path {
            return true
        }
        var target = stat()
        guard stat(url.path, &target) == 0 else { return false }
        for path in [encryptedFile.path, encryptedFile.path + ".bak"] {
            var other = stat()
            if stat(path, &other) == 0 && other.st_dev == target.st_dev && other.st_ino == target.st_ino {
                return true
            }
        }
        return false
    }

    /// True if the folder lies on one of the volumes mounted at `mountPoints`.
    static func isInside(_ folder: URL, anyOf mountPoints: [URL]) -> Bool {
        let path = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return mountPoints.contains { mountPoint in
            let root = mountPoint.standardizedFileURL.resolvingSymlinksInPath().path
            return path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }

    /// The warning, then the write. `note` is added to the warning, for a result
    /// Safe could not check or a damaged file.
    static func confirmAndWrite(_ data: Data, to url: URL, encryptedFile: URL, window: NSWindow?,
                                inVolume: Bool = false, locks: Int? = nil, note: String? = nil) {
        if wouldReplaceEncryptedFile(url, encryptedFile: encryptedFile) {
            DocumentAlerts.show(L("Not exported"),
                                L("That is the encrypted file itself, or another encrypted file. Choose another name."),
                                on: window)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("The exported copy is not encrypted.")
        var message = L("""
            %@ will be written to %@ as a normal file. Anyone who can read that folder can read \
            it, and a sync service may upload it. Delete it when you no longer need it.
            """, url.lastPathComponent, DocumentAlerts.folderName(of: url))
        if inVolume {
            message += " " + L("""
                That folder is in an encrypted volume: there, a deleted file stays readable in the \
                volume's image to anyone with the volume's password. Choose a place outside the \
                volume if you can, the Desktop for example.
                """)
        }
        if let note = note {
            message += "\n\n" + note
        }
        alert.informativeText = message
        alert.addButton(withTitle: L("Export"))
        alert.addButton(withTitle: L("Cancel"))
        DocumentAlerts.run(alert, on: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            if let locks = locks, lockCount() != locks {
                DocumentAlerts.show(L("Not exported"), L("""
                    Safe locked while the dialog was open, so nothing was written. Open or export \
                    the file again.
                    """), on: window)
                return
            }
            do {
                try CryptFile.export(data, to: url)
            } catch {
                DocumentAlerts.show(L("The file was not exported"), DocumentAlerts.describe(error), on: window)
            }
        }
    }

    /// NSSavePanel in the encrypted file's folder with the original name.
    private static func savePanel(_ folder: URL, _ name: String, _ window: NSWindow?,
                                  _ completion: @escaping (URL?) -> Void) {
        let panel = NSSavePanel()
        panel.title = L("Export")
        panel.prompt = L("Export")
        panel.message = L("The exported copy is not encrypted.")
        panel.directoryURL = folder
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.isExtensionHidden = false
        if let window = window, usesSheet(on: window) {
            panel.beginSheetModal(for: window) { response in
                completion(response == .OK ? panel.url : nil)
            }
        } else {
            completion(panel.runModal() == .OK ? panel.url : nil)
        }
    }
}
