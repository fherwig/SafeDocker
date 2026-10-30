import AppKit
import CryptoKit
import SafeCore

// WP4. The interface is fixed by the building plan, section 3.1. The flows
// themselves are in RouterFlows.swift; here they get the real dialogs,
// CryptFile, the windows of WP3 and the self-test gate.

/// Decides what happens with each file the Finder hands over (sections 4.3, 4.4).
final class DocumentRouter {
    /// The one router of the app.
    static let shared = DocumentRouter()

    private let flows: RouterFlows<SecureBytes, OpenedFile>

    private init() {
        flows = RouterFlows(environment: Self.environment())
    }

    /// True while an editor or a viewer that the router opened is open.
    var hasOpenWindows: Bool {
        !flows.windows.isEmpty
    }

    /// The real dialogs, CryptFile, windows and gate.
    static func environment() -> RouterEnvironment<SecureBytes, OpenedFile> {
        RouterEnvironment(
            askOnce: { PasswordPrompt.askOnce(title: $0, message: $1) },
            askTwice: { PasswordPrompt.askTwice(title: $0, message: $1) },
            wipe: { $0.wipe() },
            inform: { Alerts.inform($0, $1) },
            choose: { Alerts.choose($0, $1, buttons: $2) },
            writeRefusal: { SelfTestGate.shared.writeRefusal() },
            fileState: fileState(of:),
            fileSize: { url in
                (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue
            },
            isEncryptedImage: { (try? DiskImage.isEncrypted($0)) ?? false },
            linkCount: { url in
                var st = stat()
                return lstat(url.path, &st) == 0 ? Int(st.st_nlink) : 1
            },
            volumeMountPoints: { ExportController.volumeMountPoints() },
            lockCount: { LockController.shared.lockCount },
            encryptFile: { try CryptFile.encryptFile(at: $0, password: $1) },
            openFile: { url, password in
                let (opened, data) = try CryptFile.open(at: url, password: password, allowLegacy: true)
                return OpenResult(opened: opened, originalName: opened.originalName,
                                  kind: opened.kind, variant: opened.variant, data: data, check: opened.check)
            },
            readablePart: { url, password, checked in
                let part = try CryptFile.readablePart(at: url, password: password, checked: checked)
                return (part.originalName, part.data)
            },
            mayBeOldRC4: { CryptFile.mayBeOldRC4(at: $0) },
            mayBeCutShort: { CryptFile.mayBeCutShort(at: $0) },
            isInSyncedFolder: { folder in
                SyncCheck.isInSyncedFolder(folder.resolvingSymlinksInPath().path,
                                           home: FileManager.default.homeDirectoryForCurrentUser.path)
            },
            toldAboutCopies: { UserDefaults.standard.bool(forKey: CopiesNote.toldKey) },
            setToldAboutCopies: { UserDefaults.standard.set(true, forKey: CopiesNote.toldKey) },
            decryptOldRC4: { url, password, variant in
                let result = try CryptFile.decryptOldRC4(at: url, password: password, variant: variant)
                return (result.originalName, result.data)
            },
            passwordDigest: { password in
                password.withUnsafeBytes { Data(HMAC<SHA256>.authenticationCode(for: $0, using: digestKey)) }
            },
            saveCurrent: { data, opened, password in
                _ = try CryptFile.save(data, over: opened, password: password)
            },
            showEditor: { opened, text, password in
                let controller = EditorWindowController(opened: opened, text: text.text, password: password,
                                                        coding: text.coding, readOnlyNote: text.readOnlyNote)
                controller.showWindow(nil)
                return controller
            },
            showViewer: { opened, data, password in
                let controller = ViewerWindowController(opened: opened, data: data, password: password)
                controller.showWindow(nil)
                return controller
            },
            exportData: { data, originalName, encryptedFile, note in
                ExportController.export(data, originalName: originalName, from: encryptedFile, window: nil,
                                        note: note)
            },
            register: { window in
                if let item = window as? Lockable {
                    LockController.shared.register(item)
                }
            },
            runWork: { message, work in try ModalProgress.run(message, work) }
        )
    }

    /// Double-click, Open with Safe.
    func open(_ urls: [URL]) {
        flows.open(urls)
    }

    /// Encrypt with Safe. Waits for the self-test at start, which decides whether
    /// Safe may encrypt at all (G5).
    func encrypt(_ urls: [URL]) {
        SelfTestGate.shared.whenFinished { [flows] in
            flows.encrypt(urls)
        }
    }

    /// Export with Safe.
    func export(_ urls: [URL]) {
        flows.export(urls)
    }
}

/// The note about the copies a deleted original can leave (SSD, previews,
/// Spotlight, backups, sync services) is told once, by Encrypt or by New from
/// Folder, whichever comes first.
enum CopiesNote {
    /// A new key in review round 4, so that the note with backups and sync
    /// services is told once more to those who saw the shorter one.
    static let toldKey = "ToldWhichCopiesCanRemain"
}

/// The key of RouterEnvironment.passwordDigest: random, new at every start, and
/// only in memory, so that a digest says nothing outside this run of the app.
private let digestKey = SymmetricKey(size: .bits256)

extension EditorWindowController: RoutedWindow {}
extension ViewerWindowController: RoutedWindow {}

extension RoutedWindow where Self: NSWindowController {
    func bringToFront() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}
