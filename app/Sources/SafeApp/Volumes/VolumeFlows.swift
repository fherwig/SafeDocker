import Foundation
import SafeCore

// WP4. What the buttons of the Volumes window do (R4, section 4.8), and the
// closing of the volumes the app opened when it locks (G4, section 4.9). Like
// RouterFlows, the flows get everything from outside through
// VolumeEnvironment, so that the tests can pass stand-ins; nothing here ever
// forces a volume closed, because other apps may have unsaved work on it.

/// The list of volumes; VolumeStore in the app, an array in the tests.
protocol VolumeList: AnyObject {
    var volumes: [VolumeRecord] { get }
    func add(_ v: VolumeRecord) throws
    func update(_ v: VolumeRecord) throws
    func remove(id: UUID) throws
}

extension VolumeStore: VolumeList {}

/// Whether a volume in the list is open.
enum VolumeState: Equatable {
    case missing, closed, open(URL)
}

/// What the Volumes window asks of the flows; VolumeFlows in the app and the tests.
protocol VolumeActions: AnyObject {
    var list: VolumeList { get }
    var onChange: (() -> Void)? { get set }
    func refresh()
    func state(of record: VolumeRecord) -> VolumeState
    func newEmpty() -> VolumeRecord?
    func newFromFolder() -> VolumeRecord?
    func addExisting() -> VolumeRecord?
    func remove(_ record: VolumeRecord)
    func open(_ record: VolumeRecord)
    func close(_ record: VolumeRecord)
    func changePassword(_ record: VolumeRecord)
    func setSyncApp(_ record: VolumeRecord, to name: String?)
}

extension VolumeFlows: VolumeActions {}

/// Everything the volume flows need from outside.
struct VolumeEnvironment<Password: AnyObject> {
    var askOnce: (_ title: String, _ message: String) -> Password?
    var askTwice: (_ title: String, _ message: String) -> Password?
    var wipe: (Password) -> Void
    var inform: (_ title: String, _ message: String) -> Void
    /// Returns the index of the button clicked.
    var choose: (_ title: String, _ message: String, _ buttons: [String]) -> Int
    /// Asks for lines of text; nil on Cancel.
    var form: (_ title: String, _ message: String, _ fields: [(label: String, value: String)]) -> [String]?
    var chooseFolder: () -> URL?
    /// Where a new image goes (a save panel).
    var chooseImageLocation: (_ suggestedName: String, _ directory: URL?) -> URL?
    var chooseExistingImage: () -> URL?
    /// Shows an open volume in the Finder.
    var reveal: (URL) -> Void

    var createEmpty: (_ image: URL, _ maxSizeMB: Int, _ volumeName: String, Password) throws -> Void
    var createFromFolder: (_ folder: URL, _ image: URL, _ volumeName: String, Password) throws -> Void
    var attach: (_ image: URL, Password, _ readOnly: Bool, _ mountPoint: URL?, _ hidden: Bool) throws -> URL
    var detach: (_ mountPoint: URL, _ force: Bool) throws -> Void
    var changePassword: (_ image: URL, _ old: Password, _ new: Password) throws -> Void
    var isEncrypted: (URL) throws -> Bool
    var attached: () throws -> [(image: URL, mountPoint: URL?)]
    var sameContents: (URL, URL) throws -> Bool
    var isRunning: (_ processName: String) -> Bool

    var fileState: (URL) -> FileState
    var isVolumeRoot: (URL) -> Bool
    /// True if a folder, or one above it, is uploaded by a sync service
    /// (SyncCheck.isInSyncedFolder), whose trash keeps what is deleted there.
    var isInSyncedFolder: (URL) -> Bool
    /// The files in a folder (relative paths) that have names outside it (hard
    /// links), which would keep them on the disk after the folder is deleted.
    var filesWithOtherNames: (URL) throws -> [String]
    /// Deletes the folder after the check (FileManager.removeItem in the app).
    var removeFolder: (URL) throws -> Void
    /// What a folder holds, one line per item (FolderSnapshot.list in the app), to
    /// notice a change between the check and the delete.
    var listFolder: (URL) throws -> [String]
    /// Renames a file or folder; fails if the new name exists.
    var moveItem: (_ from: URL, _ to: URL) throws -> Void
    /// The volumes this app opened, as saved by saveOpened, and saving them, so
    /// that the next start still closes them on lock (OpenedVolumesFile in the app).
    var loadOpened: () -> [UUID: URL]
    var saveOpened: ([UUID: URL]) -> Void
    /// The folders that New from Folder moved aside to delete and has not
    /// finished deleting, and saving them (PendingDeletesFile in the app), so that
    /// a start after a crash during the delete can offer to finish it.
    var loadPendingDeletes: () -> [URL]
    var savePendingDeletes: ([URL]) -> Void
    /// A new empty folder only this user can read (mode 0700), named with
    /// VolumeInput.privateFolderPrefix, for the mount point of the check and of
    /// an open volume: other accounts on the Mac cannot reach a volume mounted
    /// inside it, which ignores owners (review round 4).
    var makePrivateFolder: () throws -> URL
    /// Removes a folder only if it is empty (rmdir), never what is mounted in it.
    var removeEmptyFolder: (URL) -> Void
    /// Whether the user was told which copies of deleted files can remain (shared
    /// with Encrypt, CopiesNote), and telling it.
    var toldAboutDeletedFiles: () -> Bool
    var setToldAboutDeletedFiles: () -> Void
    var homeDirectory: String
    /// Waits before trying a detach again.
    var pause: (TimeInterval) -> Void
    /// Runs slow work, with a progress panel in the app.
    var runWork: (_ message: String, _ work: @escaping () throws -> Void) throws -> Void
    /// Runs work off the main thread, and code back on it.
    var background: (@escaping () -> Void) -> Void
    var main: (@escaping () -> Void) -> Void
}

/// The flows of the Volumes window.
final class VolumeFlows<Password: AnyObject> {
    let env: VolumeEnvironment<Password>
    let list: VolumeList

    /// The volumes this app opened, by record id, with their mount points. These
    /// are the ones closed on lock. Saved at every change, so that a new start
    /// after a crash, a force quit or Quit Anyway can take them over.
    private(set) var appOpened: [UUID: URL] = [:] {
        didSet {
            if appOpened != oldValue {
                env.saveOpened(appOpened)
            }
        }
    }
    /// Names of volumes that could not be closed on lock because they are busy.
    private(set) var busyAfterLock: [String] = []
    /// The volumes this app closed on lock, with the mount points they had, so
    /// that an editor whose file was on one can open it again at the same place
    /// and save there (G4). Forgotten when the volume is opened again.
    private(set) var closedOnLock: [UUID: URL] = [:]
    /// Called after anything in the list or the open volumes changed.
    var onChange: (() -> Void)?

    private var attachedImages: [String: URL] = [:]

    init(environment: VolumeEnvironment<Password>, list: VolumeList) {
        env = environment
        self.list = list
    }

    // MARK: - Paths and state

    /// The image of a record, with "~/" expanded.
    func imageURL(for record: VolumeRecord) -> URL {
        URL(fileURLWithPath: VolumeInput.expandedPath(record.path, home: env.homeDirectory))
    }

    /// Asks hdiutil which images are attached now.
    func refresh() {
        attachedImages = [:]
        for item in (try? env.attached()) ?? [] {
            if let mountPoint = item.mountPoint {
                attachedImages[Self.canonical(item.image)] = mountPoint
            }
        }
    }

    /// Open, closed or missing, as of the last refresh().
    func state(of record: VolumeRecord) -> VolumeState {
        let image = imageURL(for: record)
        if let mountPoint = attachedImages[Self.canonical(image)] {
            return .open(mountPoint)
        }
        return env.fileState(image) == .missing ? .missing : .closed
    }

    static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// At start: takes over the volumes that an earlier run of the app opened and
    /// that are still open at the same place, so that they are closed on lock as
    /// before (G4). The others are forgotten.
    func adoptOpenedVolumes() {
        let stored = env.loadOpened()
        guard !stored.isEmpty else { return }
        refresh()
        var adopted: [UUID: URL] = [:]
        for record in list.volumes {
            guard let saved = stored[record.id],
                  let mountPoint = attachedImages[Self.canonical(imageURL(for: record))],
                  Self.canonical(mountPoint) == Self.canonical(saved)
            else { continue }
            adopted[record.id] = mountPoint
        }
        if adopted == appOpened {
            env.saveOpened(adopted)     // drops what is no longer open
        } else {
            appOpened = adopted
        }
        onChange?()
    }

    private func changed() {
        refresh()
        onChange?()
    }

    // MARK: - New Empty

    /// Name, size, place and password, then an empty encrypted sparse bundle.
    @discardableResult
    func newEmpty() -> VolumeRecord? {
        var name = L("Private"), size = L("1 GB")
        var message = L("The volume grows as files are added, up to the maximum size.")
        var sizeMB = 0
        while true {
            guard let values = env.form(L("New empty volume"), message,
                                        [(L("Name:"), name), (L("Maximum size:"), size)]),
                  values.count == 2
            else { return nil }
            name = values[0].trimmingCharacters(in: .whitespaces)
            size = values[1]
            if let problem = VolumeInput.nameProblem(name) {
                message = problem
            } else if let mb = VolumeInput.parseSizeMB(size) {
                sizeMB = mb
                break
            } else {
                message = L("Give the maximum size as a number with MB, GB or TB, for example 1 GB. The smallest is %ld MB.",
                            VolumeInput.minimumSizeMB)
            }
        }
        guard let image = chooseNewImage(suggestedName: name, directory: nil, inside: nil) else {
            return nil
        }
        guard let password = env.askTwice(L("New volume “%@”", name), L("""
            Type a password for the new volume twice. Without it the volume cannot be opened.
            """)) else { return nil }
        defer { env.wipe(password) }
        do {
            try env.runWork(L("Making the volume “%@” ...", name)) {
                try self.env.createEmpty(image, sizeMB, name, password)
            }
        } catch {
            env.inform(L("The volume was not made"), Wording.describe(error) + ".")
            return nil
        }
        return addToList(name: name, image: image)
    }

    // MARK: - New from Folder

    /// Makes a volume from a folder, checks it against the folder, and only then
    /// deletes the folder (R4).
    @discardableResult
    func newFromFolder() -> VolumeRecord? {
        guard let folder = env.chooseFolder() else { return nil }
        let folderName = folder.lastPathComponent
        if let problem = folderProblem(folder) {
            env.inform(L("Safe cannot make a volume from “%@”", folderName), problem)
            return nil
        }
        let name = VolumeInput.volumeName(from: folderName)
        var question = L("""
            Safe makes an encrypted volume with a copy of everything in the folder, checks \
            the copy file by file against the folder, and only then deletes the folder. \
            If the check finds a difference, the folder is kept.
            """)
        if env.isInSyncedFolder(folder) {
            question += "\n\n" + L("""
                The folder is in a synced folder, so the sync service has plain copies of its \
                files, and keeps them in its trash and version history after the folder is \
                deleted here: delete them there too. Folders are best made into volumes before \
                they go into a synced folder.
                """)
        }
        let go = env.choose(L("Make a volume from “%@”?", folderName), question, [L("Continue"), L("Cancel")])
        guard go == 0 else { return nil }
        guard let image = chooseNewImage(suggestedName: name, directory: folder.deletingLastPathComponent(),
                                         inside: folder)
        else { return nil }
        guard let password = env.askTwice(L("New volume “%@”", name), L("""
            Type a password for the new volume twice. Without it the volume cannot be opened.
            """)) else { return nil }
        defer { env.wipe(password) }

        // 1. make the volume
        do {
            try env.runWork(L("Copying “%@” into a new encrypted volume ...", folderName)) {
                try self.env.createFromFolder(folder, image, name, password)
            }
        } catch {
            env.inform(L("The volume was not made"), Wording.describe(error) + ".\n\n" + L("The folder was not changed."))
            return nil
        }

        // 2. check it against the folder, after noting what the folder holds, so that
        // a change during the check is found before the delete
        let kept = L("The folder was not deleted. The new volume is at %@; you can delete it, or add it to the list with Add Existing.",
                     image.path)
        let before: [String]
        do {
            before = try env.listFolder(folder)
        } catch {
            env.inform(L("The folder was kept"),
                       L("Safe could not read the folder: %@.", Wording.describe(error)) + " " + kept)
            return nil
        }
        switch verify(folder: folder, image: image, password: password) {
        case .success(true):
            break
        case .success(false):
            env.inform(L("The folder was kept"),
                       L("The new volume does not hold exactly the files of “%@”.", folderName) + " " + kept)
            return nil
        case .failure(let error):
            env.inform(L("The folder was kept"),
                       L("Safe could not check the new volume: %@.", Wording.describe(error)) + " " + kept)
            return nil
        }

        // 3. delete the folder, unless something is mounted inside it or it changed
        // since the check began
        if let problem = mountedInside(folder) {
            let record = addToList(name: name, image: image)
            env.inform(L("The folder was kept"), problem)
            return record
        }
        switch removeCheckedFolder(folder, unchangedSince: before) {
        case .removed:
            break
        case .changed(let note):
            env.inform(L("The folder was kept"), L("""
                “%@” changed while Safe was checking the new volume: another app or a \
                sync service wrote to it. The volume may not hold the newest files, so the \
                folder was not deleted%@. The new volume is at %@; you can \
                delete it, or add it to the list with Add Existing.
                """, folderName, note, image.path))
            return nil
        case .notRemoved(let reason):
            let record = addToList(name: name, image: image)
            env.inform(L("The volume is ready, but the folder was not deleted completely"), reason)
            return record
        }
        let record = addToList(name: name, image: image)
        var message = L("""
            “%@” holds exactly the files of the folder “%@”, which was \
            deleted. Open the volume to use the files.
            """, name, folderName)
        if !env.toldAboutDeletedFiles() {
            message += "\n\n" + L("""
                Please note: deleted files cannot be wiped reliably on an SSD. The \
                unencrypted copies may stay on the disk until they are overwritten. Previews \
                that the Finder made (Quick Look thumbnails) and the Spotlight index can also \
                keep copies outside the volume. FileVault protects all of these if it is \
                switched on. If the folder was in a synced folder, the sync service has plain \
                copies and keeps them in its trash and version history; Time Machine backups \
                and local snapshots keep older copies too. Delete those as well, or make \
                volumes from folders before they go into a synced folder.
                """)
            env.setToldAboutDeletedFiles()
        }
        env.inform(L("The volume is ready"), message)
        return record
    }

    /// What removeCheckedFolder did.
    private enum Removal {
        case removed
        /// The folder changed; it is kept, and the note says where if it is not
        /// at its old place.
        case changed(String)
        /// The folder was not deleted, or not completely; the message says why.
        case notRemoved(String)
    }

    /// Moves the checked folder aside under a hidden name in the same place, so
    /// that nothing that writes by its path can add to it any more, compares it
    /// with what it held before the check, and deletes it only if nothing changed;
    /// otherwise moves it back (R4).
    ///
    /// The place it is moved to is recorded first (loadPendingDeletes) and
    /// forgotten only when the delete has finished, so that if Safe is stopped
    /// during a long delete (a crash, a forced quit, a power cut), the next start
    /// finds the unencrypted rest and offers to delete it (offerToFinishDeletes).
    private func removeCheckedFolder(_ folder: URL, unchangedSince before: [String]) -> Removal {
        let aside = folder.deletingLastPathComponent().appendingPathComponent(
            ".\(folder.lastPathComponent)\(Self.pendingMark)\(UUID().uuidString.prefix(8))", isDirectory: true)
        rememberPendingDelete(aside)
        do {
            try env.moveItem(folder, aside)
        } catch {
            forgetPendingDelete(aside)
            return .notRemoved(L("Safe could not move the folder aside to delete it: %@. The volume holds all of its files, so you can delete the folder yourself.",
                                 Wording.describe(error)))
        }
        guard (try? env.listFolder(aside)) == before else {
            // not to be deleted: it changed
            forgetPendingDelete(aside)
            do {
                try env.moveItem(aside, folder)
                return .changed("")
            } catch {
                return .changed(L(", and it is now at %@, because Safe could not move it back", aside.path))
            }
        }
        do {
            try env.runWork(L("Deleting the folder “%@” ...", folder.lastPathComponent)) {
                try self.env.removeFolder(aside)
            }
        } catch {
            // what is left stays recorded: the next start offers to delete it
            return .notRemoved(L("""
                %@. The volume holds all of its files, so you can \
                delete what is left of the folder yourself; it is at %@.
                """, Wording.describe(error), aside.path))
        }
        forgetPendingDelete(aside)
        return .removed
    }

    /// Part of the name of a folder moved aside to be deleted.
    static var pendingMark: String { ".safe-pending-" }

    private func rememberPendingDelete(_ folder: URL) {
        var pending = env.loadPendingDeletes()
        pending.append(folder)
        env.savePendingDeletes(pending)
    }

    private func forgetPendingDelete(_ folder: URL) {
        env.savePendingDeletes(env.loadPendingDeletes().filter { $0.path != folder.path })
    }

    /// At start: a folder that New from Folder was deleting when Safe was stopped
    /// (a crash, a forced quit, a power cut) is still partly there, unencrypted
    /// and hidden from the Finder. Says where, and deletes it only after the
    /// user's yes. Entries whose folder is gone are forgotten.
    func offerToFinishDeletes() {
        let pending = env.loadPendingDeletes()
        guard !pending.isEmpty else { return }
        var left: [URL] = []
        for folder in pending {
            // only what Safe itself moved aside, and only if it is still there
            guard folder.lastPathComponent.contains(Self.pendingMark), env.fileState(folder) == .folder else {
                continue
            }
            let choice = env.choose(L("Safe did not finish deleting a folder"), L("""
                When Safe made an encrypted volume from a folder, it was stopped (by a crash, a \
                forced quit or a power cut) while it deleted the folder's unencrypted copy. The \
                volume holds all of the files. What is left of the copy is at %@, \
                hidden from the Finder, and it is not encrypted.

                Delete removes it. To keep it, choose Show in Finder and rename it.
                """, folder.path), [L("Delete"), L("Show in Finder"), L("Not Now")])
            switch choice {
            case 0:
                do {
                    try env.runWork(L("Deleting “%@” ...", folder.lastPathComponent)) {
                        try self.env.removeFolder(folder)
                    }
                } catch {
                    env.inform(L("The folder was not deleted completely"), L("""
                        %@. What is left of it is at %@; you can \
                        delete it yourself.
                        """, Wording.describe(error), folder.path))
                    left.append(folder)
                }
            case 1:
                env.reveal(folder)
                left.append(folder)
            default:
                left.append(folder)
            }
        }
        env.savePendingDeletes(left)
    }

    /// Attaches the new image read only and hidden in a private folder, compares
    /// it with the folder, and detaches it again (never forced).
    func verify(folder: URL, image: URL, password: Password) -> Result<Bool, Error> {
        do {
            let parent = try env.makePrivateFolder()
            defer { env.removeEmptyFolder(parent) }
            let mountPoint = parent.appendingPathComponent("volume", isDirectory: true)
            var same = false
            try env.runWork(L("Checking the new volume against the folder ...")) {
                let mounted = try self.env.attach(image, password, true, mountPoint, true)
                var compareError: Error?
                do {
                    same = try self.env.sameContents(folder, mounted)
                } catch {
                    compareError = error
                }
                try self.detachSoon(mounted)
                if let error = compareError {
                    throw error
                }
            }
            return .success(same)
        } catch {
            return .failure(error)
        }
    }

    /// Detaches without force, trying again twice, because the system may still
    /// look at a volume that was just read.
    private func detachSoon(_ mountPoint: URL) throws {
        var attempt = 1
        while true {
            do {
                try env.detach(mountPoint, false)
                return
            } catch {
                if attempt == 3 {
                    throw error
                }
                attempt += 1
                env.pause(1)
            }
        }
    }

    /// Why this folder must not become a volume (and then be deleted), or nil.
    func folderProblem(_ folder: URL) -> String? {
        guard env.fileState(folder) == .folder else {
            return L("It is not a folder.")
        }
        let path = Self.canonical(folder)
        let home = Self.canonical(URL(fileURLWithPath: env.homeDirectory))
        let parts = path.split(separator: "/")
        if parts.count < 2 || path == home || home.hasPrefix(path + "/") {
            return L("Safe does not make volumes from the home folder, a folder that contains it, or a top-level folder of the disk.")
        }
        if env.isVolumeRoot(folder) {
            return L("It is a whole disk or volume, not a folder on one.")
        }
        if let problem = mountedInside(folder) {
            return problem
        }
        // deleting the folder would leave these on the disk under their other names,
        // as Encrypt refuses such files (finding of review round 4)
        let linked: [String]
        do {
            linked = try env.filesWithOtherNames(folder)
        } catch {
            return L("Safe could not read the folder: %@.", Wording.describe(error))
        }
        if !linked.isEmpty {
            let shown = linked.prefix(5).map { L("“%@”", $0) }.joined(separator: ", ")
                + (linked.count > 5 ? L(" and %ld more", linked.count - 5) : "")
            return L("""
                Some of its files have other names (hard links) outside the folder: %@. \
                Deleting the folder would leave them unencrypted on the disk under those names. \
                Make the volume with New Empty and copy the files into it instead, or remove the \
                other names first.
                """, shown)
        }
        return nil
    }

    /// A message if an attached image is mounted inside the folder, else nil.
    private func mountedInside(_ folder: URL) -> String? {
        let path = Self.canonical(folder)
        for item in (try? env.attached()) ?? [] {
            if let mountPoint = item.mountPoint, Self.canonical(mountPoint).hasPrefix(path + "/") {
                return L("A volume is open inside the folder, at %@. Close it first.", mountPoint.path)
            }
        }
        return nil
    }

    /// Asks where the new image goes; refuses a place that exists already or lies
    /// inside `inside`, the folder that will be deleted.
    private func chooseNewImage(suggestedName: String, directory: URL?, inside folder: URL?) -> URL? {
        guard var image = env.chooseImageLocation(suggestedName + ".sparsebundle", directory) else {
            return nil
        }
        if image.pathExtension.lowercased() != "sparsebundle" {
            image = image.appendingPathExtension("sparsebundle")
        }
        if let folder = folder {
            let f = Self.canonical(folder), i = Self.canonical(image)
            if i == f || i.hasPrefix(f + "/") {
                env.inform(L("Choose another place"), L("""
                    The volume cannot be stored inside the folder it is made from, because \
                    the folder is deleted afterwards.
                    """))
                return nil
            }
        }
        if env.fileState(image) != .missing {
            env.inform(L("Choose another name"), L("""
                “%@” exists already there. Safe does not replace it.
                """, image.lastPathComponent))
            return nil
        }
        return image
    }

    private func addToList(name: String, image: URL) -> VolumeRecord {
        let record = VolumeRecord(name: name, path: VolumeInput.storedPath(image.path, home: env.homeDirectory))
        do {
            try list.add(record)
        } catch {
            env.inform(L("The volume was made but not added to the list"), L("""
                %@. It is at %@; add it with Add Existing.
                """, Wording.describe(error), image.path))
        }
        changed()
        return record
    }

    // MARK: - Add Existing, Remove, sync app

    /// Adds an encrypted image made elsewhere, for example today's safe.
    @discardableResult
    func addExisting() -> VolumeRecord? {
        guard let image = env.chooseExistingImage() else { return nil }
        let fileName = image.lastPathComponent
        if let known = list.volumes.first(where: { Self.canonical(imageURL(for: $0)) == Self.canonical(image) }) {
            env.inform(L("“%@” is in the list already", fileName), L("It is listed as “%@”.", known.name))
            return nil
        }
        do {
            guard try env.isEncrypted(image) else {
                env.inform(L("“%@” is not encrypted", fileName), L("Safe keeps only encrypted volumes in its list."))
                return nil
            }
        } catch {
            env.inform(L("Safe cannot read “%@”", fileName), Wording.describe(error) + ".")
            return nil
        }
        return addToList(name: image.deletingPathExtension().lastPathComponent, image: image)
    }

    /// Forgets a volume after asking; the image itself stays.
    func remove(_ record: VolumeRecord) {
        let choice = env.choose(L("Remove “%@” from the list?", record.name), L("""
            The volume itself stays where it is, at %@, and is not \
            deleted. You can add it again with Add Existing.
            """, imageURL(for: record).path), [L("Remove"), L("Cancel")])
        guard choice == 0 else { return }
        do {
            try list.remove(id: record.id)
        } catch {
            env.inform(L("“%@” was not removed", record.name), Wording.describe(error) + ".")
        }
        changed()
    }

    /// Sets or clears the app that must be running before the volume opens.
    func setSyncApp(_ record: VolumeRecord, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = record
        updated.syncApp = (trimmed?.isEmpty ?? true) ? nil : trimmed
        guard updated != record else { return }
        do {
            try list.update(updated)
        } catch {
            env.inform(L("The setting was not saved"), Wording.describe(error) + ".")
        }
        changed()
    }

    // MARK: - Open, Close, Change Password

    /// Checks the sync app, asks the password and opens the volume in the Finder.
    func open(_ record: VolumeRecord) {
        let image = imageURL(for: record)
        refresh()
        switch state(of: record) {
        case .missing:
            env.inform(L("“%@” cannot be found", record.name), L("There is nothing at %@.", image.path))
            return
        case .open(let mountPoint):
            env.reveal(mountPoint)
            return
        case .closed:
            break
        }
        if let app = record.syncApp, !env.isRunning(app) {
            let choice = env.choose(L("%@ is not running", app), L("""
                %@ keeps the folder of “%@” in sync. As it is not running, \
                this copy of the volume may not be the latest one. Open it anyway?
                """, app, record.name), [L("Open Anyway"), L("Cancel")])
            guard choice == 0 else { return }
        }
        var message = L("Type the password of the volume “%@”.", record.name)
        while true {
            guard let password = env.askOnce(L("Open “%@”", record.name), message) else { return }
            defer { env.wipe(password) }
            // not at /Volumes: a disk image is mounted with owners ignored, so every
            // account on the Mac could read it there; a folder only this user can
            // enter keeps the others out, and the Finder shows the volume all the
            // same (finding of review round 4)
            var parent: URL?
            do {
                let folder = try env.makePrivateFolder()
                parent = folder
                let place = folder.appendingPathComponent(VolumeInput.volumeName(from: record.name), isDirectory: true)
                var mountPoint = place
                try env.runWork(L("Opening “%@” ...", record.name)) {
                    mountPoint = try self.env.attach(image, password, false, place, false)
                }
                appOpened[record.id] = mountPoint
                closedOnLock[record.id] = nil
                changed()
                env.reveal(mountPoint)
                return
            } catch CryptError.wrongPassword {
                parent.map(env.removeEmptyFolder)
                message = L("The password was not right. Type the password of “%@” again.", record.name)
            } catch {
                parent.map(env.removeEmptyFolder)
                env.inform(L("“%@” was not opened", record.name), Wording.describe(error) + ".")
                return
            }
        }
    }

    /// Removes the private folder that held a volume's mount point, once the
    /// volume is closed; only one Safe made, and only if it is empty.
    private func removeMountFolder(of mountPoint: URL) {
        let parent = mountPoint.deletingLastPathComponent()
        if parent.lastPathComponent.hasPrefix(VolumeInput.privateFolderPrefix) {
            env.removeEmptyFolder(parent)
        }
    }

    /// Closes the volume if nothing uses it; never forced.
    func close(_ record: VolumeRecord) {
        refresh()
        guard case .open(let mountPoint) = state(of: record) else {
            // ejected meanwhile, in the Finder for example
            if let old = appOpened[record.id] {
                removeMountFolder(of: old)
            }
            appOpened[record.id] = nil
            changed()
            return
        }
        do {
            try env.runWork(L("Closing “%@” ...", record.name)) {
                try self.env.detach(mountPoint, false)
            }
            appOpened[record.id] = nil
            removeMountFolder(of: mountPoint)
        } catch {
            env.inform(L("“%@” is still open", record.name), L("""
                Files on it are in use. Close them, or quit the apps that use them, and try \
                again. (%@)
                """, Wording.describe(error)))
        }
        changed()
    }

    /// Asks the current password and a new one twice.
    func changePassword(_ record: VolumeRecord) {
        let image = imageURL(for: record)
        guard env.fileState(image) != .missing else {
            env.inform(L("“%@” cannot be found", record.name), L("There is nothing at %@.", image.path))
            return
        }
        let keyNote = L("""
            Changing the password does not change the volume's key: a copy of the volume kept \
            from before (in a sync service's version history, a backup or on another Mac) still \
            opens with the old password.
            """)
        var message = L("Type the current password of “%@”.", record.name) + " " + keyNote
        while true {
            guard let old = env.askOnce(L("Change the password of “%@”", record.name), message) else { return }
            defer { env.wipe(old) }
            guard let new = env.askTwice(L("New password for “%@”", record.name),
                                         L("Type the new password twice.")) else { return }
            defer { env.wipe(new) }
            do {
                try env.runWork(L("Changing the password of “%@” ...", record.name)) {
                    try self.env.changePassword(image, old, new)
                }
                // hdiutil chpass wraps the same key anew (finding of review round 4)
                env.inform(L("The password of “%@” was changed", record.name), L("""
                    The volume now opens with the new password. Its key stays the same, so a copy \
                    of the volume kept from before (in a sync service's version history, a backup \
                    or another Mac) still opens with the old password. If the old password may be \
                    known to someone, make a new volume (New Empty) and move the files into it.
                    """))
                return
            } catch CryptError.wrongPassword {
                message = L("The current password was not right. Type the current password of “%@” again.",
                            record.name)
            } catch {
                env.inform(L("The password was not changed"), Wording.describe(error) + ".")
                return
            }
        }
    }

    // MARK: - Lock (G4)

    /// Closes the volumes this app opened, without force, off the main thread (G4).
    /// Busy ones stay open and are remembered in busyAfterLock. Those closed are
    /// remembered in closedOnLock with their mount points: an editor with unsaved
    /// changes to a file on one keeps its text behind the lock cover, and can open
    /// the volume again at the same place to save it (reopen(holding:)).
    ///
    /// With `wait` above zero, as before the Mac sleeps, it waits up to that many
    /// seconds for the detaches to finish, so that the system does not sleep
    /// with the volumes open; what takes longer finishes in the background.
    func closeAppOpenedVolumes(waitUpTo wait: TimeInterval = 0, completion: (() -> Void)? = nil) {
        let targets = appOpened
        let names = volumeNames()
        guard !targets.isEmpty, !closing else {
            completion?()
            return
        }
        closing = true
        // finish runs once, on the main thread: after the wait, or when the detaches are done
        var finished = false
        let finish = { (closed: [UUID], busy: [String]) in
            guard !finished else { return }
            finished = true
            self.closing = false
            for id in closed {
                if let mountPoint = targets[id] {
                    self.closedOnLock[id] = mountPoint
                }
                self.appOpened[id] = nil
            }
            for name in busy where !self.busyAfterLock.contains(name) {
                self.busyAfterLock.append(name)
            }
            self.changed()
            completion?()
        }
        let done = DispatchSemaphore(value: 0)
        let outcome = DetachOutcome()
        env.background {
            let result = self.detachAll(targets, names: names)
            outcome.set(result)
            done.signal()
            self.env.main { finish(result.closed, result.busy) }
        }
        if wait > 0, done.wait(timeout: .now() + wait) == .success, let result = outcome.get() {
            finish(result.closed, result.busy)
        }
    }

    /// The volume in the list that Safe closed on lock and that held `file`, if any.
    func closedVolume(holding file: URL) -> VolumeRecord? {
        // the innermost mount point first, should one volume be mounted inside another
        for (id, mountPoint) in closedOnLock.sorted(by: { $0.value.path.count > $1.value.path.count })
            where Self.isInside(file, mountPoint) {
            if let record = list.volumes.first(where: { $0.id == id }) {
                return record
            }
        }
        return nil
    }

    /// Opens the volume that Safe closed on lock under `file` again, at the mount
    /// point it had, so that the file is back at its path and an editor can save
    /// it (G4). Asks the password, again after a wrong one. True if the file's
    /// folder is there afterwards.
    @discardableResult
    func reopen(holding file: URL) -> Bool {
        guard let record = closedVolume(holding: file), let mountPoint = closedOnLock[record.id] else {
            return false
        }
        let image = imageURL(for: record)
        refresh()
        switch state(of: record) {
        case .missing:
            env.inform(L("“%@” cannot be found", record.name), L("There is nothing at %@.", image.path))
            return false
        case .open(let now):
            closedOnLock[record.id] = nil
            if Self.canonical(now) == Self.canonical(mountPoint) {
                return env.fileState(file.deletingLastPathComponent()) == .folder
            }
            env.inform(L("“%@” is open at another place", record.name), L("""
                It is open at %@, not at %@, where the file in the editor \
                was. Close it in the Volumes window, then try again.
                """, now.path, mountPoint.path))
            return false
        case .closed:
            break
        }
        var message = L("""
            Type the password of the volume “%@”. Safe opens it at the same place as \
            before, so that %@ can be saved there.
            """, record.name, file.lastPathComponent)
        while true {
            guard let password = env.askOnce(L("Open “%@” again", record.name), message) else { return false }
            defer { env.wipe(password) }
            do {
                var mounted = mountPoint
                try env.runWork(L("Opening “%@” ...", record.name)) {
                    mounted = try self.env.attach(image, password, false, mountPoint, false)
                }
                appOpened[record.id] = mounted
                closedOnLock[record.id] = nil
                changed()
                return env.fileState(file.deletingLastPathComponent()) == .folder
            } catch CryptError.wrongPassword {
                message = L("The password was not right. Type the password of “%@” again.", record.name)
            } catch {
                env.inform(L("“%@” was not opened", record.name), Wording.describe(error) + ".")
                return false
            }
        }
    }

    /// The result of detachAll, handed from the background to the main thread.
    private final class DetachOutcome {
        private let lock = NSLock()
        private var value: (closed: [UUID], busy: [String])?
        func set(_ result: (closed: [UUID], busy: [String])) {
            lock.lock()
            value = result
            lock.unlock()
        }
        func get() -> (closed: [UUID], busy: [String])? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    /// The same at Quit, on this thread; returns the names of the busy volumes.
    func closeAppOpenedVolumesNow() -> [String] {
        let targets = appOpened
        let (closed, busy) = detachAll(targets, names: volumeNames())
        for id in closed {
            appOpened[id] = nil
            targets[id].map(removeMountFolder)
        }
        // nothing reopens a volume closed on lock after Quit
        for (_, mountPoint) in closedOnLock {
            removeMountFolder(of: mountPoint)
        }
        closedOnLock = [:]
        return busy
    }

    private var closing = false

    /// True if the file lies on the volume mounted at `mountPoint`.
    static func isInside(_ file: URL, _ mountPoint: URL) -> Bool {
        let root = canonical(mountPoint)
        return canonical(file).hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private func volumeNames() -> [UUID: String] {
        Dictionary(list.volumes.map { ($0.id, $0.name) }) { first, _ in first }
    }

    /// Detaches each volume without force; returns the ids closed and the names
    /// of those still open.
    private func detachAll(_ targets: [UUID: URL], names: [UUID: String]) -> (closed: [UUID], busy: [String]) {
        let attachedNow = Set(((try? env.attached()) ?? []).compactMap {
            $0.mountPoint.map(Self.canonical)
        })
        var closed: [UUID] = [], busy: [String] = []
        for (id, mountPoint) in targets.sorted(by: { $0.value.path < $1.value.path }) {
            if !attachedNow.contains(Self.canonical(mountPoint)) {
                closed.append(id)    // ejected meanwhile, in the Finder for example
                continue
            }
            do {
                try env.detach(mountPoint, false)
                closed.append(id)
            } catch {
                busy.append(names[id] ?? mountPoint.lastPathComponent)
            }
        }
        return (closed, busy)
    }

    /// The message about volumes that stayed open on lock, once; nil if none.
    func takeBusyReport() -> String? {
        guard !busyAfterLock.isEmpty else { return nil }
        let names = busyAfterLock.map { L("“%@”", $0) }.joined(separator: ", ")
        busyAfterLock = []
        return L("""
            When Safe locked, it could not close %@, because files on it were in use in \
            another app. It is still open. Save and close the files, then close the volume in \
            the Volumes window.
            """, names)
    }
}

/// Checks and conversions of what the user types in the Volumes window.
enum VolumeInput {
    static let minimumSizeMB = 20
    /// The start of the name of the private folders that hold mount points
    /// (VolumeEnvironment.makePrivateFolder).
    static let privateFolderPrefix = "safe-volume-"
    /// Endings of the disk images Add Existing takes; Encrypt refuses them (R1, R4).
    static let imageEndings: [String] = ["dmg", "sparsebundle", "sparseimage"]

    /// "1 GB", "500 MB", "0.5 TB" or a plain number of GB, in MB; nil if not a size.
    static func parseSizeMB(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        let units: [(String, Double)] = [("TB", 1024 * 1024), ("GB", 1024), ("MB", 1),
                                         ("T", 1024 * 1024), ("G", 1024), ("M", 1)]
        var number = trimmed, factor = 1024.0
        for (unit, f) in units where trimmed.hasSuffix(unit) {
            number = String(trimmed.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
            factor = f
            break
        }
        number = number.replacingOccurrences(of: ",", with: ".")
        guard !number.isEmpty, number.allSatisfy({ $0.isNumber || $0 == "." }),
              let value = Double(number), value.isFinite
        else { return nil }
        let mb = (value * factor).rounded()
        guard mb >= Double(minimumSizeMB), mb <= 64 * 1024 * 1024 else { return nil }
        return Int(mb)
    }

    /// Why this cannot be a volume name, or nil.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty {
            return L("Give the volume a name.")
        }
        if name.contains("/") || name.contains(":") || name.hasPrefix(".") {
            return L("The name must not contain / or : and must not start with a dot.")
        }
        if name.utf8.count > 60 {
            return L("The name is too long.")
        }
        return nil
    }

    /// A volume name made from a folder name.
    static func volumeName(from folderName: String) -> String {
        var name = String(folderName.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        while name.hasPrefix(".") {
            name.removeFirst()
        }
        while name.utf8.count > 60 {
            name.removeLast()
        }
        return name.isEmpty ? L("Private") : name
    }

    /// The path as stored in the list: "~/..." when under the home folder.
    static func storedPath(_ path: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }

    /// The full path of a stored path.
    static func expandedPath(_ stored: String, home: String) -> String {
        let home = home.hasSuffix("/") ? String(home.dropLast()) : home
        if stored == "~" {
            return home
        }
        if stored.hasPrefix("~/") {
            return home + "/" + stored.dropFirst(2)
        }
        return stored
    }
}
