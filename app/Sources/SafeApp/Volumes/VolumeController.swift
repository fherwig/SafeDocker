import AppKit
import SafeCore
import UniformTypeIdentifiers

// WP4. Gives VolumeFlows the real dialogs, DiskImage, FolderVerifier,
// SyncCheck and VolumeStore, and keeps them for the life of the app, so that
// the volumes the app opened are closed on lock even when the Volumes window
// is closed.

/// The volumes of the app: the list, the flows, and closing on lock (R4, G4).
final class VolumeController {
    /// The one volume controller of the app.
    static let shared = VolumeController()

    let flows: VolumeFlows<SecureBytes>
    private let glue: VolumeLockGlue<SecureBytes>

    private init() {
        flows = VolumeFlows(environment: Self.environment(), list: VolumeStore())
        glue = VolumeLockGlue(flows: flows)
    }

    /// The lock action that AppDelegate gives LockController: closes the volumes
    /// this app opened, never forced; busy ones are reported when the user is back.
    func lock() {
        glue.lock()
    }

    /// The name of the volume that Safe closed on lock and that held `file`, if any.
    func closedVolumeName(holding file: URL) -> String? {
        flows.closedVolume(holding: file)?.name
    }

    /// Opens that volume again at the same place, for an editor that saves the file.
    func reopenVolume(holding file: URL) -> Bool {
        flows.reopen(holding: file)
    }

    /// At start: offers to finish deleting a folder that New from Folder was
    /// deleting when Safe was stopped.
    func offerToFinishDeletes() {
        flows.offerToFinishDeletes()
    }

    /// Tells the user about volumes that stayed open on lock, once.
    func reportBusyVolumes() {
        glue.reportBusyVolumes()
    }

    /// The user is back after a lock: the report now if Safe is in front,
    /// else a bounce of its Dock icon and the report when it becomes active.
    func userIsBack() {
        glue.userIsBack()
    }

    /// At start: takes over the volumes an earlier run opened that are still open.
    func adoptOpenedVolumes() {
        flows.adoptOpenedVolumes()
    }

    /// True while a volume that Safe opened is open (LockController.hasOpenVolumes).
    var hasAppOpenedVolumes: Bool {
        !flows.appOpened.isEmpty
    }

    /// At Quit: closes the volumes this app opened and returns the names of those
    /// that stayed open because they are busy.
    func closeForQuit() -> [String] {
        flows.closeAppOpenedVolumesNow()
    }

    /// The real dialogs, DiskImage, FolderVerifier and SyncCheck.
    static func environment() -> VolumeEnvironment<SecureBytes> {
        VolumeEnvironment(
            askOnce: { PasswordPrompt.askOnce(title: $0, message: $1) },
            askTwice: { PasswordPrompt.askTwice(title: $0, message: $1) },
            wipe: { $0.wipe() },
            inform: { Alerts.inform($0, $1) },
            choose: { Alerts.choose($0, $1, buttons: $2) },
            form: { Alerts.form($0, $1, fields: $2) },
            chooseFolder: {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.message = L("Choose the folder to turn into an encrypted volume.")
                panel.prompt = L("Choose")
                NSApp.activate(ignoringOtherApps: true)
                return panel.runModal() == .OK ? panel.url : nil
            },
            chooseImageLocation: { name, directory in
                let panel = NSSavePanel()
                panel.nameFieldStringValue = name
                if let directory = directory {
                    panel.directoryURL = directory
                }
                panel.canCreateDirectories = true
                panel.message = L("Where should the encrypted volume be kept? A synced folder is a good place.")
                panel.prompt = L("Create")
                NSApp.activate(ignoringOtherApps: true)
                return panel.runModal() == .OK ? panel.url : nil
            },
            chooseExistingImage: {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                panel.allowsMultipleSelection = false
                panel.treatsFilePackagesAsDirectories = false
                panel.allowedContentTypes = VolumeInput.imageEndings
                    .compactMap { UTType(filenameExtension: $0) }
                panel.message = L("Choose an encrypted disk image (.dmg or .sparsebundle).")
                panel.prompt = L("Add")
                NSApp.activate(ignoringOtherApps: true)
                return panel.runModal() == .OK ? panel.url : nil
            },
            reveal: { NSWorkspace.shared.open($0) },
            createEmpty: { image, sizeMB, name, password in
                try DiskImage.createEmpty(at: image, maxSizeMB: sizeMB, volumeName: name, password: password)
            },
            createFromFolder: { folder, image, name, password in
                try DiskImage.createFromFolder(folder, at: image, volumeName: name, password: password)
            },
            attach: { image, password, readOnly, mountPoint, hidden in
                try DiskImage.attach(image, password: password, readOnly: readOnly,
                                     mountPoint: mountPoint, hidden: hidden)
            },
            detach: { try DiskImage.detach($0, force: $1) },
            changePassword: { try DiskImage.changePassword($0, old: $1, new: $2) },
            isEncrypted: { try DiskImage.isEncrypted($0) },
            attached: { try DiskImage.attached().map { ($0.imagePath, $0.mountPoint) } },
            sameContents: { try FolderVerifier.sameContents($0, $1) },
            isRunning: { SyncCheck.isRunning(processName: $0) },
            fileState: fileState(of:),
            isVolumeRoot: { url in
                (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
            },
            isInSyncedFolder: { folder in
                SyncCheck.isInSyncedFolder(folder.resolvingSymlinksInPath().path,
                                           home: FileManager.default.homeDirectoryForCurrentUser.path)
            },
            filesWithOtherNames: { try FolderSnapshot.filesWithOtherNames($0) },
            removeFolder: { try FileManager.default.removeItem(at: $0) },
            listFolder: { try FolderSnapshot.list($0) },
            moveItem: { try FileManager.default.moveItem(at: $0, to: $1) },
            loadOpened: { OpenedVolumesFile.load(OpenedVolumesFile.defaultFile) },
            saveOpened: { opened in
                OpenedVolumesFile.save(opened, to: OpenedVolumesFile.defaultFile)
                // the idle check must not be held back while a volume is open (G4)
                DispatchQueue.main.async { LockController.shared.keepChecking() }
            },
            loadPendingDeletes: { PendingDeletesFile.load(PendingDeletesFile.defaultFile) },
            savePendingDeletes: { PendingDeletesFile.save($0, to: PendingDeletesFile.defaultFile) },
            makePrivateFolder: {
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent(VolumeInput.privateFolderPrefix + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                return folder
            },
            removeEmptyFolder: { _ = rmdir($0.path) },
            toldAboutDeletedFiles: { UserDefaults.standard.bool(forKey: CopiesNote.toldKey) },
            setToldAboutDeletedFiles: { UserDefaults.standard.set(true, forKey: CopiesNote.toldKey) },
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
            pause: { Thread.sleep(forTimeInterval: $0) },
            runWork: { message, work in try ModalProgress.run(message, work) },
            background: { DispatchQueue.global(qos: .userInitiated).async(execute: $0) },
            main: { DispatchQueue.main.async(execute: $0) }
        )
    }
}

/// What VolumeController does when the app locks and when the user is back,
/// for any flows, so that the tests can run it with stand-ins (G4, section 4.9).
final class VolumeLockGlue<Password: AnyObject> {
    let flows: VolumeFlows<Password>
    /// The lock controller whose state the glue reads.
    var lockController = LockController.shared
    var appIsActive: () -> Bool = { NSApp.isActive }
    var requestAttention: () -> Void = { NSApp.requestUserAttention(.informationalRequest) }
    var inform: (_ title: String, _ message: String) -> Void = { Alerts.inform($0, $1, warning: true) }
    /// How long a lock before sleep waits for the volumes to close.
    static var sleepWait: TimeInterval { 10 }

    init(flows: VolumeFlows<Password>) {
        self.flows = flows
    }

    /// Closes the volumes this app opened. Before sleep it waits for them (up to
    /// sleepWait), so that the Mac does not sleep with them open. Volumes that
    /// stay open are reported when the user is back, never during the lock.
    func lock() {
        let wait = lockController.isLockingForSleep ? Self.sleepWait : 0
        flows.closeAppOpenedVolumes(waitUpTo: wait) { [weak self] in
            guard let self = self, !self.flows.busyAfterLock.isEmpty else { return }
            if self.lockController.isAwaitingReturn {
                self.requestAttention()
            } else {
                // the user came back while the volumes were being closed
                self.userIsBack()
            }
        }
    }

    /// Tells the user about volumes that stayed open on lock, once.
    func reportBusyVolumes() {
        if let message = flows.takeBusyReport() {
            inform(L("A volume is still open"), message)
        }
    }

    /// The report now if Safe is in front, else a bounce of its Dock icon and the
    /// report when it becomes active.
    func userIsBack() {
        guard !flows.busyAfterLock.isEmpty else { return }
        if appIsActive() {
            reportBusyVolumes()
        } else {
            requestAttention()
        }
    }
}

/// What a folder holds, to notice a change between the check of a new volume and
/// the delete of the folder (R4): one line per item below it, with its relative
/// path, kind, size, modification time, file number and number of names, sorted.
/// .DS_Store files, which the Finder writes and FolderVerifier ignores, are left out.
enum FolderSnapshot {
    /// The regular files in the folder (relative paths, sorted) that have more
    /// names than the folder holds: hard links from outside it, which would keep
    /// the plaintext on the disk after the folder is deleted (R4, as Encrypt).
    static func filesWithOtherNames(_ folder: URL) throws -> [String] {
        let root = folder.path
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            throw CryptError.io(L("cannot read %@", root))
        }
        var names: [String: (first: String, links: Int, seen: Int)] = [:]
        while let relative = walker.nextObject() as? String {
            var st = stat()
            guard lstat(root + "/" + relative, &st) == 0 else {
                throw CryptError.io(L("cannot read %@: %@", root + "/" + relative, String(cString: strerror(errno))))
            }
            guard st.st_mode & S_IFMT == S_IFREG, st.st_nlink > 1 else { continue }
            let key = "\(st.st_dev):\(st.st_ino)"
            let entry = names[key] ?? (relative, Int(st.st_nlink), 0)
            names[key] = (entry.first, entry.links, entry.seen + 1)
        }
        return names.values.filter { $0.seen < $0.links }.map(\.first).sorted()
    }

    static func list(_ folder: URL) throws -> [String] {
        let root = folder.path
        guard let walker = FileManager.default.enumerator(atPath: root) else {
            throw CryptError.io(L("cannot read %@", root))
        }
        var lines: [String] = []
        while let relative = walker.nextObject() as? String {
            if (relative as NSString).lastPathComponent == ".DS_Store" {
                continue
            }
            var st = stat()
            guard lstat(root + "/" + relative, &st) == 0 else {
                throw CryptError.io(L("cannot read %@: %@", root + "/" + relative, String(cString: strerror(errno))))
            }
            lines.append("\(relative)\t\(st.st_mode)\t\(st.st_size)\t"
                         + "\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)\t\(st.st_ino)\t\(st.st_nlink)")
        }
        return lines.sorted()
    }
}

/// The folders that New from Folder moved aside to delete and has not finished
/// deleting, in ~/Library/Application Support/SafeDocker/pending-deletes.json
/// (paths only, mode 0600, replaced atomically), so that a start after a crash
/// during the delete can offer to finish it (R4).
enum PendingDeletesFile {
    static var defaultFile: URL {
        VolumeStore.defaultFile.deletingLastPathComponent().appendingPathComponent("pending-deletes.json")
    }

    static func load(_ file: URL) -> [URL] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let paths = object["pending"] as? [String]
        else { return [] }
        return paths.map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Replaces the file atomically, mode 0600; removes it when nothing is pending.
    static func save(_ folders: [URL], to file: URL) {
        let fm = FileManager.default
        if folders.isEmpty {
            try? fm.removeItem(at: file)
            return
        }
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "pending": folders.map(\.path)]
                                                         as [String: Any], options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if (try? data.write(to: file, options: .atomic)) != nil {
            chmod(file.path, 0o600)
        }
    }
}

/// The volumes this app opened, with their mount points, in
/// ~/Library/Application Support/SafeDocker/opened-volumes.json, so that a new
/// start after a crash, a force quit or Quit Anyway still closes them on lock (G4).
enum OpenedVolumesFile {
    static var defaultFile: URL {
        VolumeStore.defaultFile.deletingLastPathComponent().appendingPathComponent("opened-volumes.json")
    }

    static func load(_ file: URL) -> [UUID: URL] {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["opened"] as? [[String: String]]
        else { return [:] }
        var opened: [UUID: URL] = [:]
        for entry in entries {
            if let id = entry["id"].flatMap(UUID.init(uuidString:)), let path = entry["mountPoint"] {
                opened[id] = URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return opened
    }

    /// Replaces the file atomically, mode 0600; removes it when nothing is open.
    static func save(_ opened: [UUID: URL], to file: URL) {
        let fm = FileManager.default
        if opened.isEmpty {
            try? fm.removeItem(at: file)
            return
        }
        let entries = opened.sorted { $0.key.uuidString < $1.key.uuidString }
            .map { ["id": $0.key.uuidString, "mountPoint": $0.value.path] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["version": 1, "opened": entries] as [String: Any],
                                                     options: [.prettyPrinted, .sortedKeys]) else { return }
        try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if (try? data.write(to: file, options: .atomic)) != nil {
            chmod(file.path, 0o600)
        }
    }
}
