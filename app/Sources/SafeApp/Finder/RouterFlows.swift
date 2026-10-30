import Foundation
import SafeCore

// WP4. What DocumentRouter does with the files the Finder hands over
// (sections 4.3, 4.4, 4.7). The flows get everything from outside through
// RouterEnvironment: DocumentRouter passes the real dialogs, CryptFile and the
// windows of WP3, the tests pass stand-ins. They are generic over the password
// and the opened file, because the tests cannot make a SecureBytes or an
// OpenedFile of their own.

/// A window that the router keeps alive until it closes.
protocol RoutedWindow: AnyObject {
    var onClose: (() -> Void)? { get set }
    func bringToFront()
}

/// What opening a file gave.
struct OpenResult<Opened> {
    let opened: Opened
    let originalName: String
    let kind: FileKind
    let variant: CryptVariant
    let data: Data
    /// Whether Safe could confirm the password (CryptFile.decrypt).
    var check: PasswordCheck = .confirmed
}

/// The text for the editor: what it shows, how it is written back, and whether
/// it is shown read only because Safe could not confirm the password.
struct EditorText: Equatable {
    let text: String
    let coding: TextCoding
    /// The note above a read-only text, or nil for a normal editor.
    let readOnlyNote: String?
}

/// What the user decided about a result (section 4.4).
enum OpenDecision: Equatable {
    /// Safe confirmed the password.
    case confirmed
    /// An older variant of a type Safe cannot check, which the user accepted.
    case acceptedUnchecked
    /// Safe could not confirm the password; the user chose to see the text read only.
    case openReadOnly
    /// The same, and the user chose to look at the picture or PDF.
    case viewAnyway
    /// The same, and the user chose to export the result.
    case exportAnyway
}

/// What is at a path.
enum FileState: Equatable {
    case missing, file, folder
}

/// What happened to one file of an Encrypt request.
enum EncryptOutcome: Equatable {
    case encrypted(URL)
    case skipped(String)
    case failed(String)
}

/// Everything the flows need from outside.
struct RouterEnvironment<Password: AnyObject, Opened> {
    var askOnce: (_ title: String, _ message: String) -> Password?
    var askTwice: (_ title: String, _ message: String) -> Password?
    var wipe: (Password) -> Void
    var inform: (_ title: String, _ message: String) -> Void
    /// Returns the index of the button clicked.
    var choose: (_ title: String, _ message: String, _ buttons: [String]) -> Int
    /// nil if encrypting and saving are allowed, else why not (the self-test, G5).
    var writeRefusal: () -> String?
    var fileState: (URL) -> FileState
    /// The size of a file in bytes, nil if it cannot be read.
    var fileSize: (URL) -> Int?
    /// True for an encrypted disk image (DiskImage.isEncrypted), false for anything else.
    var isEncryptedImage: (URL) -> Bool
    /// The number of names (hard links) of a file; 1 for most.
    var linkCount: (URL) -> Int
    /// The mount points of the attached disk images, to warn about encrypting a
    /// file inside a volume, whose plain copy stays in the image (R4).
    var volumeMountPoints: () -> [URL]
    /// How often the app has locked so far (LockController.lockCount): a lock
    /// while a dialog was open means that nothing decrypted may be shown after it (G4).
    var lockCount: () -> Int
    var encryptFile: (URL, Password) throws -> URL
    var openFile: (URL, Password) throws -> OpenResult<Opened>
    /// What can be read of a file that openFile reported as damaged
    /// (CryptFile.readablePart): its original name and data. With `checked`
    /// false, whatever its start looks like, for a file that mayBeCutShort.
    var readablePart: (URL, Password, _ checked: Bool) throws -> (name: String, data: Data)
    /// True if a file that opened with no variant may be an old RC4 file that
    /// Safe cannot check (CryptFile.mayBeOldRC4).
    var mayBeOldRC4: (URL) -> Bool
    /// True if such a file may be a file in the current format cut short whose
    /// start Safe cannot recognise (CryptFile.mayBeCutShort).
    var mayBeCutShort: (URL) -> Bool
    /// True if a folder, or one above it, is uploaded by a sync service
    /// (SyncCheck.isInSyncedFolder), whose trash keeps a deleted original.
    var isInSyncedFolder: (URL) -> Bool
    /// Whether the user was told once which copies of a deleted original can
    /// remain (shared with New from Folder), and telling it.
    var toldAboutCopies: () -> Bool
    var setToldAboutCopies: () -> Void
    /// The file decrypted with an RC4 variant, whatever comes out (CryptFile.decryptOldRC4).
    var decryptOldRC4: (URL, Password, CryptVariant) throws -> (name: String, data: Data)
    /// A keyed digest of a password, to notice the same password typed twice
    /// without keeping it; compared in constant time.
    var passwordDigest: (Password) -> Data
    var saveCurrent: (Data, Opened, Password) throws -> Void
    /// The editor and the viewer take over the password and wipe it when they close.
    var showEditor: (Opened, EditorText, Password) -> RoutedWindow
    var showViewer: (Opened, Data, Password) -> RoutedWindow
    /// Export (section 4.7); `note`, if given, is added to the warning before it
    /// writes: for a result Safe could not check.
    var exportData: (_ data: Data, _ originalName: String, _ encryptedFile: URL, _ note: String?) -> Void
    /// Hands a window to the lock (G4).
    var register: (RoutedWindow) -> Void
    /// Runs slow work, with a progress panel in the app.
    var runWork: (_ message: String, _ work: @escaping () throws -> Void) throws -> Void
}

/// The flows of Encrypt, Open and Export.
final class RouterFlows<Password: AnyObject, Opened> {
    let env: RouterEnvironment<Password, Opened>

    /// The editor and viewer windows, by the path of their file, until they close.
    private(set) var windows: [String: RoutedWindow] = [:]

    init(environment: RouterEnvironment<Password, Opened>) {
        env = environment
    }

    // MARK: - Encrypt (R1, section 4.3)

    /// Encrypts each file with one password typed twice; returns what happened to
    /// each file, in the order given, and tells the user about any that failed.
    @discardableResult
    func encrypt(_ urls: [URL]) -> [EncryptOutcome] {
        guard !urls.isEmpty else { return [] }
        if let refusal = env.writeRefusal() {
            env.inform(L("Safe will not encrypt"), refusal)
            return urls.map { _ in .skipped("the self-test failed") }
        }

        var outcomes = urls.map { reasonNotToEncrypt($0).map(EncryptOutcome.skipped) }
        let todo = urls.indices.filter { outcomes[$0] == nil }
        if todo.isEmpty {
            report(urls, outcomes.map { $0! })
            return outcomes.map { $0! }
        }

        let names = todo.map { urls[$0].lastPathComponent }
        let title = names.count == 1 ? L("Encrypt “%@”", names[0]) : Lp(names.count, "Encrypt %ld file", "Encrypt %ld files")
        let what = names.count == 1 ? L("“%@”", names[0]) : Lp(names.count, "this %ld file", "these %ld files")
        var message = L("""
            Type a password for %@ twice. Safe writes an encrypted copy ending in .crypt \
            next to each file, checks it, and then deletes the original. \
            Without the password the files cannot be opened again.
            """, what)
        let mountPoints = env.volumeMountPoints()
        let inVolume = todo.filter {
            ExportController.isInside(urls[$0].deletingLastPathComponent(), anyOf: mountPoints)
        }
        if !inVolume.isEmpty {
            // the deleted original stays readable in the image (tested fact of the requirements)
            message += "\n\n" + (todo.count == 1 ? Wording.inVolumeNote : Wording.someInVolumeNote)
        }
        // a sync service keeps the plain original in its trash and version history
        // (finding of review round 4)
        let synced = todo.filter { env.isInSyncedFolder(urls[$0].deletingLastPathComponent()) }
        if !synced.isEmpty {
            message += "\n\n" + (todo.count == 1 ? Wording.syncedNote : Wording.someSyncedNote)
        }
        let tellCopies = !env.toldAboutCopies()
        if tellCopies {
            message += "\n\n" + Wording.copiesNote
        }
        guard let password = env.askTwice(title, message) else {
            return outcomes.map { $0 ?? .skipped("cancelled") }
        }
        defer { env.wipe(password) }
        if tellCopies {
            env.setToldAboutCopies()
        }

        for index in todo {
            let url = urls[index]
            do {
                var made = url
                try env.runWork(L("Encrypting “%@” ...", url.lastPathComponent)) {
                    made = try self.env.encryptFile(url, password)
                }
                outcomes[index] = .encrypted(made)
            } catch {
                outcomes[index] = .failed(Wording.describe(error))
            }
        }
        report(urls, outcomes.map { $0! })
        return outcomes.map { $0! }
    }


    /// Why a file is not encrypted, or nil if it can be. An encrypted disk image
    /// belongs in the Volumes window; an unencrypted single-file image (a .dmg made
    /// without encryption, a downloaded installer) is encrypted like any file.
    private func reasonNotToEncrypt(_ url: URL) -> String? {
        let state = env.fileState(url)
        if VolumeInput.imageEndings.contains(url.pathExtension.lowercased()) &&
            (state == .folder || (state == .file && env.isEncryptedImage(url))) {
            return L("It is an encrypted disk image. To use it as a volume, add it in Safe's Volumes window (Add Existing)")
        }
        switch state {
        case .missing:
            return L("It is not there any more")
        case .folder:
            return L("It is a folder. To encrypt a folder, make a volume from it in Safe's Volumes window (New from Folder)")
        case .file:
            break
        }
        if url.pathExtension.lowercased() == "crypt" {
            return L("It is encrypted already")
        }
        let target = URL(fileURLWithPath: url.path + ".crypt")
        if env.fileState(target) != .missing {
            return L("A file named %@ exists already", target.lastPathComponent)
        }
        if let size = env.fileSize(url), size > CryptFile.largestFileToEncrypt {
            return CryptFile.tooLargeMessage(nil)
        }
        if env.linkCount(url) > 1 {
            return L("It has other names (hard links), so deleting it would leave it unencrypted on the disk under those names")
        }
        return nil
    }

    /// Tells the user which files were not encrypted, if any.
    private func report(_ urls: [URL], _ outcomes: [EncryptOutcome]) {
        var lines: [String] = []
        var anyEncrypted = false
        for (url, outcome) in zip(urls, outcomes) {
            switch outcome {
            case .encrypted:
                anyEncrypted = true
            case .skipped(let reason), .failed(let reason):
                lines.append(L("“%@”: %@.", url.lastPathComponent, reason))
            }
        }
        guard !lines.isEmpty else { return }
        let title: String
        if urls.count == 1 {
            title = L("“%@” was not encrypted", urls[0].lastPathComponent)
        } else {
            title = anyEncrypted ? L("Some files were not encrypted") : L("No file was encrypted")
        }
        env.inform(title, lines.joined(separator: "\n") + "\n\n" + L("The originals of these files were not deleted."))
    }

    // MARK: - Open (R2, R3, section 4.4)

    /// Opens each file: editor for text, viewer for PDF and images, else export.
    func open(_ urls: [URL]) {
        for url in urls {
            openOne(url)
        }
    }

    private func openOne(_ url: URL) {
        let key = url.standardizedFileURL.path
        if let window = windows[key] {
            window.bringToFront()
            return
        }
        var message: String?
        while let found = decrypt(url, verb: "Open", message: message) {
            if show(found, url: url, key: key) {
                return
            }
            // Safe locked while a message was open: nothing decrypted is shown
            // after that without the password (G4)
            message = lockedMessage(url.lastPathComponent)
        }
    }

    /// Shows what was decrypted, after the messages about it; false if Safe locked
    /// while one of them was open, in which case the data and the password are dropped.
    private func show(_ found: Found, url: URL, key: String) -> Bool {
        let (result, password, decision) = (found.result, found.password, found.decision)
        let name = url.lastPathComponent
        let legacy = result.variant != .current
        let unlocked = { self.env.lockCount() == found.locks }

        switch decision {
        case .exportAnyway:
            env.wipe(password)
            env.exportData(result.data, result.originalName, url, Wording.uncheckedNote)
            return true
        case .openReadOnly:
            showReadOnly(result, password: password, key: key)
            return true
        case .acceptedUnchecked where result.kind == .text:
            // accepted without a check: never saved again without the user's yes
            // (section 5.2), so read only until Allow Editing, as above
            showReadOnly(result, password: password, key: key)
            return true
        case .viewAnyway:
            keep(env.showViewer(result.opened, result.data, password), key)
            return true
        case .confirmed, .acceptedUnchecked:
            break
        }

        var kind = result.kind
        var decoded: (text: String, coding: TextCoding)?
        if kind == .text {
            decoded = TextCoding.decodeUTF8(result.data)
            if decoded == nil {
                kind = .other
            }
        }

        switch kind {
        case .text:
            if legacy {
                env.inform(L("“%@” is in an older format", name), L("""
                    It was written %@. Safe opened it and \
                    writes it in the current format the next time you save it (Cmd-S).
                    """, Wording.describe(result.variant)))
                guard unlocked() else {
                    env.wipe(password)
                    return false
                }
            }
            let text = EditorText(text: decoded!.text, coding: decoded!.coding, readOnlyNote: nil)
            keep(env.showEditor(result.opened, text, password), key)
        case .pdf, .image:
            if legacy && decision == .confirmed {
                env.inform(L("“%@” is in an older format", name), L("""
                    It was written %@. The viewer can save it \
                    again in the current format.
                    """, Wording.describe(result.variant)))
                guard unlocked() else {
                    env.wipe(password)
                    return false
                }
            }
            keep(env.showViewer(result.opened, result.data, password), key)
        case .other:
            return offerExport(found, from: url, canSave: decision == .confirmed)
        }
        return true
    }

    /// The editor, read only with a note until the user allows editing (section 4.4).
    private func showReadOnly(_ result: OpenResult<Opened>, password: Password, key: String) {
        let (text, coding) = TextCoding.decodeAnyway(result.data)
        let note = L("""
            Safe could not confirm the password, so this is shown read only, as text in \
            %@. If it is what you expect, the password is right.
            """, coding.name)
        keep(env.showEditor(result.opened, EditorText(text: text, coding: coding, readOnlyNote: note),
                            password), key)
    }

    /// For files Safe cannot show: export, or for an older format also save again.
    /// A result the user accepted without a check is never saved again: with a
    /// wrong password that would replace the file with meaningless bytes. False if
    /// Safe locked while the question was open.
    private func offerExport(_ found: Found, from url: URL, canSave: Bool) -> Bool {
        let (result, password) = (found.result, found.password)
        defer { env.wipe(password) }
        var message = L("""
            Safe cannot show “%@”. It can export it: the decrypted \
            original is then written to a place you choose, and that copy is not encrypted.
            """, result.originalName)
        let export = L("Export..."), save = L("Save in Current Format")
        let saveAfterQuestion = L("Save in Current Format..."), cancel = L("Cancel")
        var buttons = [export, cancel]
        if result.variant != .current && canSave {
            message += "\n\n" + L("""
                The file was written %@. \
                Save in Current Format writes it again in the current format.
                """, Wording.describe(result.variant))
            buttons = [export, save, cancel]
        } else if result.variant != .current {
            // accepted without a check (G5 against plan 4.4, review round 4): saved
            // only after a question that names the risk; the old file becomes the .bak
            message += "\n\n" + L("""
                The file was written %@. Safe could not \
                confirm the password, so check an exported copy before you save it in the \
                current format.
                """, Wording.describe(result.variant))
            buttons = [export, saveAfterQuestion, cancel]
        }
        let choice = env.choose(L("“%@”", url.lastPathComponent), message, buttons)
        guard env.lockCount() == found.locks else {
            return false
        }
        switch buttons[choice] {
        case export:
            env.exportData(result.data, result.originalName, url, canSave ? nil : Wording.uncheckedNote)
        case save:
            saveInCurrentFormat(result, password: password, url: url)
        case saveAfterQuestion:
            let name = url.lastPathComponent
            let sure = env.choose(L("Save “%@” in the current format?", name), L("""
                Safe could not confirm the password of “%1$@”. If it is wrong, the content \
                is meaningless bytes, and saving would replace the file with them, encrypted \
                with that password. The file as it is now is kept as “%1$@.bak” either way, \
                replacing an older “%1$@.bak”. Save only if an exported copy was right.
                """, name), [save, cancel])
            guard env.lockCount() == found.locks else {
                return false
            }
            if sure == 0 {
                saveInCurrentFormat(result, password: password, url: url)
            }
        default:
            break
        }
        return true
    }

    private func saveInCurrentFormat(_ result: OpenResult<Opened>, password: Password, url: URL) {
        let name = url.lastPathComponent
        if let refusal = env.writeRefusal() {
            env.inform(L("Safe will not save"), refusal)
            return
        }
        do {
            try env.runWork(L("Saving “%@” ...", name)) {
                try self.env.saveCurrent(result.data, result.opened, password)
            }
            env.inform(L("“%@” is now in the current format", name),
                       L("The previous version is kept as “%@.bak”.", name))
        } catch {
            env.inform(L("“%@” was not saved", name), Wording.describe(error) + ".")
        }
    }

    /// Keeps the window until it closes, and hands it to the lock.
    private func keep(_ window: RoutedWindow, _ key: String) {
        windows[key] = window
        env.register(window)
        window.onClose = { [weak self, weak window] in
            guard let self = self, let window = window else { return }
            if self.windows[key] === window {
                self.windows[key] = nil
            }
        }
    }

    // MARK: - Export (R3, section 4.7)

    /// Decrypts each file and hands it to the export dialog.
    func export(_ urls: [URL]) {
        for url in urls {
            guard let found = decrypt(url, verb: "Export") else { continue }
            env.wipe(found.password)
            env.exportData(found.result.data, found.result.originalName, url,
                           found.decision == .confirmed ? nil : Wording.uncheckedNote)
        }
    }

    // MARK: - Asking for the password

    /// A file that was decrypted, the password that did it, what the user decided,
    /// and the lock count when the file was decrypted.
    private struct Found {
        let result: OpenResult<Opened>
        let password: Password
        let decision: OpenDecision
        let locks: Int
    }

    /// What the user answered to a question about a result Safe could not confirm.
    private enum Answer {
        case accept(OpenDecision), again, cancel
        /// Export the file read in another way (otherReadings).
        case otherReading
    }

    /// Other ways a file may have been written than the one that gave a result,
    /// none of which Safe can check (G5, R2: the right password must not be
    /// refused). Offered for export only.
    private enum Reading: Equatable {
        /// The current format with the end missing (CryptFile.readablePart, unchecked).
        case readablePart
        /// An old RC4 file (CryptFile.decryptOldRC4).
        case rc4(CryptVariant)
    }

    /// The readings of a file that gave a result Safe could not confirm, other
    /// than the result's own: an old RC4 file for a text name or a type Safe
    /// cannot check (an AES variant passes its padding check with about 1 in 256
    /// passwords, the right one of an RC4 file included, finding of review round
    /// 4), and the readable part of a file in the current format cut short whose
    /// start Safe cannot recognise, unless the current format gave the result.
    private func otherReadings(_ url: URL, besides variant: CryptVariant?) -> [Reading] {
        var readings: [Reading] = []
        if variant != .current && env.mayBeCutShort(url) {
            readings.append(.readablePart)
        }
        if env.mayBeOldRC4(url) {
            for rc4 in [CryptVariant.legacyRC4MD5, .legacyRC4SHA256] where rc4 != variant {
                readings.append(.rc4(rc4))
            }
        }
        return readings
    }


    /// "“NAME.bak” next to it holds the previous version", if there is one.
    private func backupSentence(_ url: URL) -> String? {
        let backup = URL(fileURLWithPath: url.path + ".bak")
        guard env.fileState(backup) == .file else { return nil }
        return L("“%@” next to it holds the previous version.", backup.lastPathComponent)
    }

    private func lockedMessage(_ name: String) -> String {
        L("Safe locked while a message about “%1$@” was open. Type the password of “%1$@” again.", name)
    }

    /// Asks for the password until the file opens or the user gives up. A wrong
    /// password is said to be wrong; garbage is never shown as if it were the file;
    /// and the right password is never refused. A result Safe could not confirm
    /// goes to the user (sections 4.4 and 5.2). A file whose end is missing is
    /// said to be damaged, and its readable part can be exported. The same
    /// password refused twice in a row may be right for an old RC4 file that Safe
    /// cannot check: the user can export it as such (G5). If Safe locks while a
    /// question is open, the result is dropped and the password asked again (G4).
    private func decrypt(_ url: URL, verb: String, message first: String? = nil) -> Found? {
        let name = url.lastPathComponent
        switch env.fileState(url) {
        case .missing:
            env.inform(L("“%@” cannot be opened", name), L("It is not there any more."))
            return nil
        case .folder:
            env.inform(L("“%@” cannot be opened", name), L("It is a folder, not an encrypted file."))
            return nil
        case .file:
            break
        }
        let title = verb == "Open" ? L("Open “%@”", name) : L("Export “%@”", name)
        var message = first ?? L("Type the password of “%@”.", name)
        // a keyed digest of the last password that opened nothing, kept only while
        // this loop asks, to notice the same password typed again
        var lastRefused: Data?
        while true {
            guard let password = env.askOnce(title, message) else { return nil }
            do {
                let result = try env.openFile(url, password)
                let locks = env.lockCount()
                if result.check == .confirmed {
                    return Found(result: result, password: password, decision: .confirmed, locks: locks)
                }
                // an older variant whose type cannot be checked gets its own question;
                // content that does not fit the name, from any variant, gets this one
                let readings = otherReadings(url, besides: result.variant)
                let answer = result.check == .unchecked && result.variant != .current
                    ? askAboutUnchecked(result, name: name, readings: readings)
                    : askAboutUnconfirmed(result, name: name, verb: verb, readings: readings)
                guard env.lockCount() == locks else {
                    env.wipe(password)
                    message = lockedMessage(name)
                    continue
                }
                switch answer {
                case .accept(let decision):
                    return Found(result: result, password: password, decision: decision, locks: locks)
                case .again:
                    env.wipe(password)
                    message = L("Type the password of “%@” again.", name)
                case .cancel:
                    env.wipe(password)
                    return nil
                case .otherReading:
                    defer { env.wipe(password) }
                    switch exportReading(of: url, password: password, choosingFrom: readings, locks: locks) {
                    case .again:
                        message = L("Type the password of “%@” again.", name)
                    case .locked:
                        message = lockedMessage(name)
                    case .done:
                        return nil
                    }
                }
            } catch let error as CryptError where error == .wrongPassword || error == .wrongPasswordOrDamaged {
                let digest = env.passwordDigest(password)
                let repeated = lastRefused.map { Self.sameDigest($0, digest) } ?? false
                lastRefused = digest
                if repeated && env.mayBeOldRC4(url) {
                    switch exportAsOldRC4(url, password: password) {
                    case .again:
                        lastRefused = nil
                        message = L("Type the password of “%@” again.", name)
                        continue
                    case .locked:
                        lastRefused = nil
                        message = lockedMessage(name)
                        continue
                    case .done:
                        return nil
                    }
                }
                env.wipe(password)
                if repeated, let backup = backupSentence(url) {
                    message = L("""
                        The password was not right, again. If you are sure that it is, the file may be \
                        damaged: %@ Type the password of “%@” again.
                        """, backup, name)
                } else if repeated {
                    message = L("""
                        The password was not right, again. If you are sure that it is, the file may be \
                        damaged. Type the password of “%@” again.
                        """, name)
                } else if error == .wrongPasswordOrDamaged {
                    message = L("""
                        The password was not right. If you are sure that it is, the file may be \
                        damaged: its length does not fit the current format, as when a copy or a \
                        sync was interrupted. Type the password of “%@” again.
                        """, name)
                } else {
                    message = L("The password was not right. Type the password of “%@” again.", name)
                }
            } catch CryptError.damaged {
                switch exportReadablePart(url, password: password, verb: verb) {
                case .again:
                    message = L("Type the password of “%@” again.", name)
                case .locked:
                    message = lockedMessage(name)
                case .done:
                    return nil
                }
            } catch {
                env.wipe(password)
                env.inform(L("“%@” cannot be opened", name), Wording.describe(error) + ".")
                return nil
            }
        }
    }

    /// What became of a question asked from the password loop.
    private enum LoopStep {
        case again, locked, done
    }

    /// True if two digests are equal; the time taken depends only on their length.
    static func sameDigest(_ a: Data, _ b: Data) -> Bool {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in LockPolicy.sameBytes(x, y) } }
    }

    /// The password seems right, but the end of the file is missing (CryptFile
    /// .damaged): says so, and offers to export what can be read. Wipes the password.
    private func exportReadablePart(_ url: URL, password: Password, verb: String) -> LoopStep {
        defer { env.wipe(password) }
        let name = url.lastPathComponent
        let locks = env.lockCount()
        var message = verb == "Open" ? L("""
            The password seems right, but the end of “%@” is missing, as when a copy, a \
            download or a sync was interrupted, so Safe cannot open \
            it as it is.
            """, name) : L("""
            The password seems right, but the end of “%@” is missing, as when a copy, a \
            download or a sync was interrupted, so Safe cannot export \
            it as it is.
            """, name)
        if let backup = backupSentence(url) {
            message += " " + backup
        }
        message += "\n\n" + L("""
            Export Readable Part writes what can be read, without the missing end, to a place \
            you choose, not encrypted.
            """)
        let choice = env.choose(L("“%@” is damaged", name), message,
                                [L("Export Readable Part..."), L("Type Another Password"), L("Cancel")])
        guard env.lockCount() == locks else {
            return .locked
        }
        switch choice {
        case 0:
            do {
                let part = try env.readablePart(url, password, true)
                env.exportData(part.data, part.name, url, Wording.damagedNote)
            } catch {
                env.inform(L("“%@” was not exported", name), Wording.describe(error) + ".")
            }
            return .done
        case 1:
            return .again
        default:
            return .done
        }
    }

    /// The same password was refused twice for a file that may be an old RC4 file
    /// of a type Safe cannot check (G5: old files must open as well), or, if it is
    /// salted, a file in the current format cut short whose start Safe cannot
    /// recognise (finding of review round 4): offers to export it as such, never
    /// to show or save it. Wipes the password.
    private func exportAsOldRC4(_ url: URL, password: Password) -> LoopStep {
        defer { env.wipe(password) }
        let name = url.lastPathComponent
        let locks = env.lockCount()
        let cutShort = env.mayBeCutShort(url)
        var message = L("""
            Safe tried every format it knows. If you are sure that the password is right, \
            “%@” may be damaged, or an old file encrypted with RC4 (crypt.sh before \
            version 1.4 wrote such files). Safe cannot check its content, so it cannot open it.
            """, name)
        if let backup = backupSentence(url) {
            message += " " + backup
        }
        if cutShort {
            message += "\n\n" + L("""
                Export Readable Part writes what this password gives for the start of the \
                file in the current format, as for a file whose end is missing (an interrupted \
                copy or sync).
                """)
        }
        message += "\n\n" + L("""
            Export as an Old RC4 File writes the file decrypted with RC4, which gives a \
            result with any password. Either is written to a place you choose, not encrypted, \
            for you to check: with a wrong password it is meaningless bytes.
            """)
        let typeAgain = L("Type It Again"), readablePart = L("Export Readable Part...")
        let oldRC4 = L("Export as an Old RC4 File...")
        let buttons = [typeAgain] + (cutShort ? [readablePart] : []) + [oldRC4, L("Cancel")]
        let choice = env.choose(L("The password was not right"), message, buttons)
        guard env.lockCount() == locks else {
            return .locked
        }
        switch buttons[choice] {
        case typeAgain:
            return .again
        case readablePart:
            export(.readablePart, of: url, password: password)
            return .done
        case oldRC4:
            return exportReading(of: url, password: password,
                                 choosingFrom: [.rc4(.legacyRC4MD5), .rc4(.legacyRC4SHA256)], locks: locks)
        default:
            return .done
        }
    }

    /// Asks which of the readings to export, and exports it, with the warning that
    /// Safe could not check it; never shows or saves it. The caller wipes the password.
    private func exportReading(of url: URL, password: Password, choosingFrom readings: [Reading],
                               locks: Int) -> LoopStep {
        let name = url.lastPathComponent
        var lines: [String] = []
        var buttons: [String] = []
        for reading in readings {
            switch reading {
            case .readablePart:
                lines.append(L("A damaged file in the current format, whose end is missing (an interrupted copy or sync): Safe writes the part that can be read."))
                buttons.append(L("Damaged File (Readable Part)"))
            case .rc4(.legacyRC4MD5):
                lines.append(L("An old file from crypt.sh before version 1.4: RC4 with a key from MD5."))
                buttons.append(L("crypt.sh Before 1.4 (MD5 Key)"))
            case .rc4:
                lines.append(L("An old file from another tool: RC4 with a key from SHA-256."))
                buttons.append(L("Another Tool (SHA-256 Key)"))
            }
        }
        let choice = env.choose(L("How was “%@” written?", name), L("""
            Safe can export what the password gives for “%@” read in one of these ways, \
            not encrypted, to a place you choose. It cannot check the result, which is \
            meaningless bytes with a wrong password, so it never shows or saves it. If you do \
            not know, choose the first; if the copy is not usable, export it again another way.
            """, name) + "\n" + lines.map { "• " + $0 }.joined(separator: "\n"), buttons + [L("Cancel")])
        guard env.lockCount() == locks else {
            return .locked
        }
        if choice < readings.count {
            export(readings[choice], of: url, password: password)
        }
        return .done
    }

    /// Exports one reading of the file, with the note that Safe could not check it.
    private func export(_ reading: Reading, of url: URL, password: Password) {
        do {
            switch reading {
            case .readablePart:
                let part = try env.readablePart(url, password, false)
                env.exportData(part.data, part.name, url, Wording.uncheckedPartNote)
            case .rc4(let variant):
                let result = try env.decryptOldRC4(url, password, variant)
                env.exportData(result.data, result.name, url, Wording.uncheckedNote)
            }
        } catch {
            env.inform(L("“%@” was not exported", url.lastPathComponent), Wording.describe(error) + ".")
        }
    }

    /// A sentence for the questions below about the other readings, or "".
    private func readingsSentence(_ readings: [Reading]) -> String {
        guard !readings.isEmpty else { return "" }
        let damaged = readings.contains(.readablePart)
        let rc4 = readings.contains { if case .rc4 = $0 { return true } else { return false } }
        let sentence: String
        if damaged && rc4 {
            sentence = L("""
                If the password is right but the result is not usable, Other Readings exports the \
                file read as a damaged file whose end is missing, or an old RC4 file, for you to check.
                """)
        } else if damaged {
            sentence = L("""
                If the password is right but the result is not usable, Other Readings exports the \
                file read as a damaged file whose end is missing, for you to check.
                """)
        } else {
            sentence = L("""
                If the password is right but the result is not usable, Other Readings exports the \
                file read as an old RC4 file, for you to check.
                """)
        }
        return "\n\n" + sentence
    }

    /// The file opened with valid padding, but the content does not look like the
    /// file's type, or the current format opened a type that cannot be checked:
    /// the password may be wrong, or the file is unusual. The user decides.
    private func askAboutUnconfirmed(_ result: OpenResult<Opened>, name: String, verb: String,
                                     readings: [Reading]) -> Answer {
        let textName = FileKind.isTextName(result.originalName)
        let picture = result.kind == .pdf || result.kind == .image
        let notText = textName && !Plausibility.looksLikeText(result.data)
        let noMagic = Plausibility.needsMagicBytes(result.originalName)
        if !picture && result.check == .contentMismatch && (notText || noMagic) {
            // not text in any encoding Safe knows, or not the first bytes that every
            // file of this type has: nearly always a wrong password. The right one
            // is still never refused: Export Anyway
            let content = notText
                ? L("""
                    The content of “%@” does not look like text in any encoding, so Safe could not \
                    confirm the password. With a wrong password the content is meaningless bytes, as \
                    it most likely is here.
                    """, name)
                : L("""
                    The content of “%@” does not start as %@ always does, so Safe could not confirm \
                    the password. With a wrong password the content is meaningless bytes, as it most \
                    likely is here.
                    """, name, Wording.typeName(result.originalName))
            let typeAgain = L("Type It Again"), other = L("Other Readings...")
            let exportAnyway = L("Export Anyway...")
            let buttons = [typeAgain] + (readings.isEmpty ? [] : [other]) + [exportAnyway, L("Cancel")]
            let choice = env.choose(L("The password is probably not right"), content + "\n\n" + L("""
                If you are sure that the password is right, Export Anyway writes the result to \
                a place you choose, not encrypted.
                """) + readingsSentence(readings), buttons)
            switch buttons[choice] {
            case typeAgain: return .again
            case other: return .otherReading
            case exportAnyway: return .accept(.exportAnyway)
            default: return .cancel
            }
        }
        var message: String
        if result.check == .contentMismatch {
            message = L("The content of “%@” does not look like %@, so Safe could not confirm the password.",
                        name, Wording.typeName(result.originalName))
        } else if textName {
            // a text of 15 bytes with one byte of padding (CryptFile.decrypt)
            message = L("“%@” is so short that Safe cannot tell its text from what a wrong password gives, so it could not confirm the password.",
                        name)
        } else {
            message = L("Safe cannot check the content of a file like “%@”, so it could not confirm the password.",
                        result.originalName)
        }
        message += " " + L("With a wrong password the content is meaningless bytes; with the right one the file is simply unusual.")
            + "\n\n"
        let first: String
        let decision: OpenDecision
        if verb == "Open" && picture {
            message += L("Open shows it in the viewer, without changing anything.")
            first = L("Open")
            decision = .viewAnyway
        } else if verb == "Open" && textName {
            message += L("Open Read-Only shows it as text without changing anything; you can allow editing once you have checked that it is right.")
            first = L("Open Read-Only")
            decision = .openReadOnly
        } else {
            message += L("Export writes the result to a place you choose, not encrypted.")
            first = L("Export...")
            decision = .exportAnyway
        }
        let other = L("Other Readings..."), typeAnother = L("Type Another Password")
        let buttons = [first] + (readings.isEmpty ? [] : [other]) + [typeAnother, L("Cancel")]
        let choice = env.choose(L("Safe could not confirm the password"), message + readingsSentence(readings), buttons)
        switch buttons[choice] {
        case first: return .accept(decision)
        case other: return .otherReading
        case typeAnother: return .again
        default: return .cancel
        }
    }

    /// An older variant opened a file whose type Safe cannot check, or gave a
    /// short text (section 5.2). If the file may also be an old RC4 file or a
    /// damaged one, Other Readings exports it read so (finding of review round
    /// 4: an AES result that passed its padding check by chance hid the RC4
    /// content for good).
    private func askAboutUnchecked(_ result: OpenResult<Opened>, name: String, readings: [Reading]) -> Answer {
        let goOn = L("Continue"), other = L("Other Readings..."), typeAgain = L("Type It Again")
        let buttons = [goOn] + (readings.isEmpty ? [] : [other]) + [typeAgain, L("Cancel")]
        let choice = env.choose(L("Is this the right password?"), L("""
            “%@” opened only as a file written %@, \
            and Safe cannot tell whether the result is right. With a wrong password, or if \
            the file is damaged, it would be meaningless bytes.
            """, name, Wording.describe(result.variant)) + readingsSentence(readings), buttons)
        switch buttons[choice] {
        case goOn: return .accept(.acceptedUnchecked)
        case other: return .otherReading
        case typeAgain: return .again
        default: return .cancel
        }
    }
}

/// How errors and formats are named in messages.
enum Wording {
    /// The note in the password dialog for a file inside an open volume (R4).
    static var inVolumeNote: String {
        L("""
            This file is in an encrypted volume. Its deleted plain copy stays readable in the \
            volume's image to anyone with the volume's password; for protection by both \
            passwords, encrypt files before you move them into the volume.
            """)
    }
    static var someInVolumeNote: String {
        L("""
            Some of these files are in an encrypted volume. Their deleted plain copies stay \
            readable in the volume's image to anyone with the volume's password; for protection \
            by both passwords, encrypt files before you move them into the volume.
            """)
    }
    /// Added to the export warning for a result Safe could not check.
    static var uncheckedNote: String {
        L("""
            Safe could not confirm the password for this file, so it cannot tell whether the copy \
            is right: with a wrong password it is meaningless bytes. Check the copy before you use it.
            """)
    }
    /// The same for the readable part of a damaged file.
    static var damagedNote: String {
        L("""
            The file is damaged: its end is missing, so this copy is incomplete.
            """)
    }
    /// The same for the readable part of a file whose start Safe cannot recognise.
    static var uncheckedPartNote: String {
        L("""
            This is the start of the file as the password gives it in the current format, without \
            the missing end. Safe could not confirm the password: with a wrong one it is meaningless \
            bytes. Check the copy before you use it.
            """)
    }
    /// The note in the password dialog for a file in a synced folder (review round 4).
    static var syncedNote: String {
        L("""
            This file is in a synced folder, so the sync service has a plain copy of it, and keeps \
            it in its trash and version history after the original is deleted here: delete it \
            there too. Files are best encrypted before they go into a synced folder.
            """)
    }
    static var someSyncedNote: String {
        L("""
            Some of these files are in a synced folder, so the sync service has plain copies of \
            them, and keeps them in its trash and version history after the originals are deleted \
            here: delete them there too. Files are best encrypted before they go into a synced folder.
            """)
    }
    /// Told once, in the first Encrypt dialog: the copies a deleted original can leave.
    static var copiesNote: String {
        L("""
            Please note (Safe says this once): a deleted file cannot be wiped reliably on an SSD, so \
            the plain original may stay on the disk until it is overwritten, and Quick Look previews \
            and the Spotlight index may keep copies of it; FileVault protects all of these if it is \
            on. Time Machine backups and local snapshots keep older copies too.
            """)
    }

    static func describe(_ error: Error) -> String {
        guard let error = error as? CryptError else {
            return error.localizedDescription
        }
        switch error {
        case .notEncrypted: return L("It is not a file encrypted by Safe or crypt.sh")
        case .wrongPassword: return L("The password is not right")
        case .corrupt: return L("The file is damaged")
        case .wrongPasswordOrDamaged: return L("The password is not right, or the file is damaged")
        case .damaged: return L("The file is damaged: its end is missing")
        case .conflict: return L("The file changed on the disk in the meantime")
        case .checkFailed: return L("The check of the encrypted copy failed, so the original was kept")
        case .alreadyExists(let name): return L("%@ exists already", name)
        case .io(let message): return message
        case .selfTestFailed(let message): return L("Safe's self-test failed: %@", message)
        }
    }

    /// "a .txt file", or "text" for a name without an ending.
    static func typeName(_ originalName: String) -> String {
        let ending = (originalName as NSString).pathExtension.lowercased()
        if ending.isEmpty {
            return L("text")
        }
        return L("a .%@ file", ending)
    }

    static func describe(_ variant: CryptVariant) -> String {
        switch variant {
        case .current: return L("in the current format")
        case .legacyAESMD5: return L("with AES-256 and an MD5 key, as old versions of openssl did")
        case .legacyAESSHA256: return L("with AES-256 and a SHA-256 key, without PBKDF2")
        case .legacyRC4MD5: return L("with RC4 and an MD5 key, as crypt.sh did before version 1.4")
        case .legacyRC4SHA256: return L("with RC4 and a SHA-256 key")
        }
    }
}

/// What is at the URL's path, following symbolic links.
func fileState(of url: URL) -> FileState {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
        return .missing
    }
    return isDirectory.boolValue ? .folder : .file
}
