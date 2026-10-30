#if DEBUG
import AppKit
import SafeCore

// WP4. Tests of VolumeFlows (section 4.8) and of closing volumes on lock
// (section 4.9), with stand-ins for the dialogs, DiskImage and the list, run
// by Safe --app-tests. No disk image is made here; WP2 tests DiskImage itself.

/// The list of volumes in memory.
final class FakeVolumeList: VolumeList {
    var volumes: [VolumeRecord] = []
    var failAdd = false
    func add(_ v: VolumeRecord) throws {
        if failAdd { throw CryptError.io("cannot write the list") }
        volumes.append(v)
    }
    func update(_ v: VolumeRecord) throws {
        guard let i = volumes.firstIndex(where: { $0.id == v.id }) else { throw CryptError.io("no such volume") }
        volumes[i] = v
    }
    func remove(id: UUID) throws {
        volumes.removeAll { $0.id == id }
    }
}

/// Records what the volume flows did and answers from queues.
final class VolumeStage {
    let home = "/Users/safetest"
    var answers: [String?] = []
    var choices: [Int] = []
    var forms: [[String]?] = []
    var asked: [(twice: Bool, title: String, message: String)] = []
    var told: [(title: String, message: String)] = []
    var questions: [(title: String, buttons: [String])] = []
    var formMessages: [String] = []
    var folderChoice: URL?
    var imageChoice: URL?
    var imageChoiceAsked: [(name: String, directory: URL?)] = []
    var existingChoice: URL?
    var revealed: [URL] = []
    var states: [String: FileState] = [:]
    var volumeRoots: Set<String> = []
    /// Folders in a synced folder, and files with names outside their folder.
    var synced: Set<String> = []
    var otherNames: [String] = []
    var created: [(kind: String, image: String, size: Int, name: String, password: String)] = []
    var createError: Error?
    var attachCalls: [(image: String, readOnly: Bool, mountPoint: String?, hidden: Bool, password: String)] = []
    var rightPassword = "pw"
    var attachedNow: [(image: URL, mountPoint: URL?)] = []
    var detachCalls: [(mountPoint: String, force: Bool)] = []
    var busy: Set<String> = []
    var detachFailuresLeft = 0
    var same = true
    var sameError: Error?
    var compared: [(String, String)] = []
    var running: Set<String> = []
    var encrypted: Set<String> = []
    var changed: [(image: String, old: String, new: String)] = []
    var removedFolders: [String] = []
    /// Renames, and the listing of each folder (one entry if not set).
    var moves: [(from: String, to: String)] = []
    var listings: [String: [String]] = [:]
    var failMove = false
    /// Runs while the check compares, as a sync client writing into the folder would.
    var onCompare: (() -> Void)?
    /// The list of opened volumes as saved, and as the next start finds it.
    var savedOpened: [[UUID: URL]] = []
    var storedOpened: [UUID: URL] = [:]
    /// The folders being deleted, as saved (PendingDeletesFile in the app).
    var pendingDeletes: [URL] = []
    /// Background work on another thread and main-thread work on the main queue,
    /// as in the app, instead of at once.
    var realQueues = false
    var privateFolders: [String] = []
    var removedEmpty: [String] = []
    var told_ = false
    var passwords: [FakePassword] = []
    var events: [String] = []
    let list = FakeVolumeList()

    func flows() -> VolumeFlows<FakePassword> {
        VolumeFlows(environment: VolumeEnvironment(
            askOnce: { self.ask(false, $0, $1) },
            askTwice: { self.ask(true, $0, $1) },
            wipe: { $0.wipe() },
            inform: { self.told.append(($0, $1)) },
            choose: { title, _, buttons in
                self.questions.append((title, buttons))
                return self.choices.isEmpty ? buttons.count - 1 : self.choices.removeFirst()
            },
            form: { _, message, _ in
                self.formMessages.append(message)
                return self.forms.isEmpty ? nil : self.forms.removeFirst()
            },
            chooseFolder: { self.folderChoice },
            chooseImageLocation: { name, directory in
                self.imageChoiceAsked.append((name, directory))
                return self.imageChoice
            },
            chooseExistingImage: { self.existingChoice },
            reveal: { self.revealed.append($0) },
            createEmpty: { image, size, name, password in
                if let error = self.createError { throw error }
                self.created.append(("empty", image.path, size, name, password.text))
                self.states[image.path] = .folder
            },
            createFromFolder: { folder, image, name, password in
                if let error = self.createError { throw error }
                self.created.append(("folder:" + folder.path, image.path, 0, name, password.text))
                self.states[image.path] = .folder
                self.events.append("create")
            },
            attach: { image, password, readOnly, mountPoint, hidden in
                self.attachCalls.append((image.path, readOnly, mountPoint?.path, hidden, password.text))
                guard password.text == self.rightPassword else { throw CryptError.wrongPassword }
                let mounted = mountPoint ?? URL(fileURLWithPath: "/Volumes/" + image.deletingPathExtension().lastPathComponent)
                self.attachedNow.append((image, mounted))
                self.events.append("attach")
                return mounted
            },
            detach: { mountPoint, force in
                self.detachCalls.append((mountPoint.path, force))
                if self.busy.contains(mountPoint.path) { throw CryptError.io("resource busy") }
                if self.detachFailuresLeft > 0 {
                    self.detachFailuresLeft -= 1
                    throw CryptError.io("resource busy for a moment")
                }
                self.attachedNow.removeAll { $0.mountPoint?.path == mountPoint.path }
                self.events.append("detach")
            },
            changePassword: { image, old, new in
                guard old.text == self.rightPassword else { throw CryptError.wrongPassword }
                self.changed.append((image.path, old.text, new.text))
            },
            isEncrypted: { self.encrypted.contains($0.path) },
            attached: { self.attachedNow },
            sameContents: { a, b in
                self.compared.append((a.path, b.path))
                self.events.append("compare")
                self.onCompare?()
                if let error = self.sameError { throw error }
                return self.same
            },
            isRunning: { self.running.contains($0) },
            fileState: { self.states[$0.path] ?? .missing },
            isVolumeRoot: { self.volumeRoots.contains($0.path) },
            isInSyncedFolder: { self.synced.contains($0.path) },
            filesWithOtherNames: { _ in self.otherNames },
            removeFolder: {
                self.removedFolders.append($0.path)
                self.states[$0.path] = nil
                self.events.append("delete")
            },
            listFolder: { folder in
                guard self.states[folder.path] == .folder else { throw CryptError.io("no folder \(folder.path)") }
                self.events.append("list")
                return self.listings[folder.path] ?? ["safetest-entry"]
            },
            moveItem: { from, to in
                if self.failMove { throw CryptError.io("cannot rename") }
                guard self.states[to.path] == nil else { throw CryptError.alreadyExists(to.path) }
                self.moves.append((from.path, to.path))
                self.states[to.path] = self.states[from.path]
                self.states[from.path] = nil
                self.listings[to.path] = self.listings[from.path]
                self.listings[from.path] = nil
                self.events.append("move")
            },
            loadOpened: { self.storedOpened },
            saveOpened: { self.savedOpened.append($0) },
            loadPendingDeletes: { self.pendingDeletes },
            savePendingDeletes: {
                self.pendingDeletes = $0
                self.events.append("pending \($0.count)")
            },
            makePrivateFolder: {
                let path = "/private/tmp/\(VolumeInput.privateFolderPrefix)safetest-\(self.privateFolders.count)"
                self.privateFolders.append(path)
                return URL(fileURLWithPath: path, isDirectory: true)
            },
            removeEmptyFolder: { self.removedEmpty.append($0.path) },
            toldAboutDeletedFiles: { self.told_ },
            setToldAboutDeletedFiles: { self.told_ = true },
            homeDirectory: home,
            pause: { _ in },
            runWork: { _, work in try work() },
            background: { work in
                if self.realQueues { DispatchQueue.global().async(execute: work) } else { work() }
            },
            main: { work in
                if self.realQueues { DispatchQueue.main.async(execute: work) } else { work() }
            }
        ), list: list)
    }

    /// The folders deleted, by the path they had before they were moved aside.
    var deletedFolders: [String] {
        removedFolders.map { path in moves.last(where: { $0.to == path })?.from ?? path }
    }

    private func ask(_ twice: Bool, _ title: String, _ message: String) -> FakePassword? {
        asked.append((twice, title, message))
        guard !answers.isEmpty, let text = answers.removeFirst() else { return nil }
        let password = FakePassword(text)
        passwords.append(password)
        return password
    }

    var leakedPasswords: Int { passwords.filter { !$0.wiped }.count }

    /// A folder with a sparse bundle location next to it, ready for New from Folder.
    func folderSetUp() -> (folder: URL, image: URL) {
        let folder = URL(fileURLWithPath: home + "/safetest-folder")
        states[folder.path] = .folder
        folderChoice = folder
        let image = URL(fileURLWithPath: home + "/Sync/safetest-folder.sparsebundle")
        imageChoice = image
        answers = ["pw"]
        choices = [0]
        return (folder, image)
    }

    /// Where the flows open a volume: in the n-th private folder made.
    func mount(_ name: String, _ n: Int = 0) -> String {
        "/private/tmp/\(VolumeInput.privateFolderPrefix)safetest-\(n)/\(name)"
    }

    /// A volume in the list whose image exists.
    func record(_ name: String, syncApp: String? = nil) -> VolumeRecord {
        let record = VolumeRecord(name: name, path: "~/Sync/\(name).sparsebundle", syncApp: syncApp)
        list.volumes.append(record)
        states[home + "/Sync/\(name).sparsebundle"] = .folder
        return record
    }
}

enum VolumeTests {
    static let cases: [AppTests.Case] = [
        AppTests.Case("with real disk images: new from folder, a failed check, a new password") {
            try AppTests.runChild("volumes-real")
        },

        AppTests.Case("new from folder checks the volume before it deletes the folder") {
            let stage = VolumeStage()
            let (folder, image) = stage.folderSetUp()
            let record = stage.flows().newFromFolder()
            // the place it is moved to is recorded before the move and forgotten after the delete
            AppTests.equal(stage.events, ["create", "list", "attach", "compare", "detach", "pending 1", "move", "list",
                                          "delete", "pending 0"])
            AppTests.equal(stage.created.first?.image, image.path)
            AppTests.equal(stage.created.first?.name, "safetest-folder")
            AppTests.equal(stage.created.first?.password, "pw")
            AppTests.check(stage.asked.first?.twice == true, "the password was not asked twice")
            let attach = stage.attachCalls.first
            AppTests.check(attach?.readOnly == true && attach?.hidden == true, "check volume not read-only and hidden")
            AppTests.check(attach?.mountPoint?.hasPrefix("/private/tmp/safe-volume-safetest-") == true, "\(attach?.mountPoint ?? "nil")")
            AppTests.equal(stage.compared.first?.0, folder.path)
            AppTests.equal(stage.compared.first?.1, attach?.mountPoint)
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            AppTests.equal(stage.removedEmpty, stage.privateFolders)
            AppTests.equal(stage.deletedFolders, [folder.path])
            AppTests.check(stage.removedFolders.first?.hasPrefix(stage.home + "/.safetest-folder.safe-pending-") == true,
                           "not moved aside under a hidden name first: \(stage.removedFolders)")
            AppTests.equal(record?.path, "~/Sync/safetest-folder.sparsebundle")
            AppTests.equal(stage.list.volumes.map(\.name), ["safetest-folder"])
            AppTests.check(stage.told.last?.message.contains("SSD") == true, "not told about SSDs")
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("the note about deleted files on an SSD comes only once") {
            let stage = VolumeStage()
            _ = stage.folderSetUp()
            stage.flows().newFromFolder()
            let (folder, _) = stage.folderSetUp()
            stage.imageChoice = URL(fileURLWithPath: stage.home + "/Sync/second.sparsebundle")
            stage.flows().newFromFolder()
            AppTests.equal(stage.deletedFolders, [folder.path, folder.path])
            AppTests.equal(stage.told.filter { $0.message.contains("SSD") }.count, 1)
        },

        AppTests.Case("new from folder keeps the folder when the check finds a difference") {
            let stage = VolumeStage()
            _ = stage.folderSetUp()
            stage.same = false
            let record = stage.flows().newFromFolder()
            AppTests.equal(record, nil)
            AppTests.equal(stage.removedFolders, [])
            AppTests.equal(stage.told.last?.title, "The folder was kept")
            AppTests.equal(stage.detachCalls.count, 1, "the check volume was not detached")
            AppTests.equal(stage.list.volumes.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("new from folder keeps the folder when the check cannot run") {
            for failure in ["attach", "compare", "detach"] {
                let stage = VolumeStage()
                _ = stage.folderSetUp()
                switch failure {
                case "attach": stage.rightPassword = "other"
                case "compare": stage.sameError = CryptError.io("unreadable file")
                default: stage.busy = ["/private/tmp/safe-volume-safetest-0/volume"]
                }
                stage.flows().newFromFolder()
                AppTests.equal(stage.removedFolders, [], "folder deleted after a failed \(failure)")
                AppTests.equal(stage.told.last?.title, "The folder was kept", failure)
                AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            }
        },

        AppTests.Case("new from folder keeps the folder if something wrote to it during the check") {
            // finding of review round 2: a file a sync client wrote meanwhile was deleted
            let stage = VolumeStage()
            let (folder, image) = stage.folderSetUp()
            stage.onCompare = { stage.listings[folder.path] = ["safetest-entry", "new from the sync client"] }
            let record = stage.flows().newFromFolder()
            AppTests.equal(record, nil)
            AppTests.equal(stage.removedFolders, [], "deleted a folder that changed")
            AppTests.equal(stage.states[folder.path], .folder, "the folder is not back at its place")
            AppTests.equal(stage.told.last?.title, "The folder was kept")
            AppTests.check(stage.told.last?.message.contains(image.path) == true, stage.told.last?.message ?? "")
            AppTests.equal(stage.list.volumes.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)

            // a folder that cannot be moved aside is not deleted
            let stuck = VolumeStage()
            let (kept, _) = stuck.folderSetUp()
            stuck.failMove = true
            let made = stuck.flows().newFromFolder()
            AppTests.check(made != nil, "the volume is not in the list")
            AppTests.equal(stuck.removedFolders, [])
            AppTests.equal(stuck.states[kept.path], .folder)
            AppTests.equal(stuck.told.last?.title, "The volume is ready, but the folder was not deleted completely")
        },

        AppTests.Case("the check tries a detach again before it gives up") {
            let stage = VolumeStage()
            let (folder, _) = stage.folderSetUp()
            stage.detachFailuresLeft = 2
            stage.flows().newFromFolder()
            AppTests.equal(stage.detachCalls.count, 3)
            AppTests.equal(stage.deletedFolders, [folder.path])
        },

        AppTests.Case("new from folder keeps the folder when making the volume fails") {
            let stage = VolumeStage()
            _ = stage.folderSetUp()
            stage.createError = CryptError.io("hdiutil failed")
            stage.flows().newFromFolder()
            AppTests.equal(stage.removedFolders, [])
            AppTests.equal(stage.attachCalls.count, 0)
            AppTests.check(stage.told.last?.message.contains("not changed") == true)
        },

        AppTests.Case("new from folder refuses an image inside the folder, the home folder and volumes") {
            let stage = VolumeStage()
            let (folder, _) = stage.folderSetUp()
            stage.imageChoice = folder.appendingPathComponent("inside.sparsebundle")
            stage.flows().newFromFolder()
            AppTests.equal(stage.created.count, 0)
            AppTests.equal(stage.told.last?.title, "Choose another place")

            for path in [stage.home, "/Users", "/", "/Applications", "/Volumes/safetest-disk"] {
                let s = VolumeStage()
                s.states[path] = .folder
                s.volumeRoots = ["/Volumes/safetest-disk"]
                s.folderChoice = URL(fileURLWithPath: path)
                s.imageChoice = URL(fileURLWithPath: "/tmp/safetest.sparsebundle")
                s.answers = ["pw"]
                s.choices = [0]
                s.flows().newFromFolder()
                AppTests.equal(s.created.count, 0, "made a volume from \(path)")
                AppTests.check(s.told.first?.title.hasPrefix("Safe cannot make a volume") == true, path)
            }
        },

        AppTests.Case("new from folder refuses an image that exists already, and stops on Cancel") {
            let stage = VolumeStage()
            let (_, image) = stage.folderSetUp()
            stage.states[image.path] = .folder
            stage.flows().newFromFolder()
            AppTests.equal(stage.created.count, 0)
            AppTests.equal(stage.told.last?.title, "Choose another name")

            let cancel = VolumeStage()
            _ = cancel.folderSetUp()
            cancel.choices = [1]
            cancel.flows().newFromFolder()
            AppTests.equal(cancel.imageChoiceAsked.count, 0)
            AppTests.equal(cancel.created.count, 0)
        },

        AppTests.Case("new from folder refuses a folder with files that have names outside it") {
            // finding of review round 4: as Encrypt, a hard link outside the folder would keep
            // the plaintext on the disk after the folder is deleted
            let stage = VolumeStage()
            _ = stage.folderSetUp()
            stage.otherNames = ["a.txt", "sub/b.bin"]
            stage.flows().newFromFolder()
            AppTests.equal(stage.created.count, 0)
            AppTests.equal(stage.removedFolders, [])
            AppTests.equal(stage.told.first?.title, "Safe cannot make a volume from “safetest-folder”")
            let message = stage.told.first?.message ?? ""
            AppTests.check(message.contains("hard links") && message.contains("“sub/b.bin”"), message)
        },

        AppTests.Case("new from folder names the sync service's copies, and the note says once which copies remain") {
            // finding of review round 4: the copies in a sync service's trash and in backups
            // were not mentioned
            let stage = VolumeStage()
            let (folder, _) = stage.folderSetUp()
            stage.synced = [folder.path]
            var questions: [String] = []
            var env = stage.flows().env
            let choose = env.choose
            env.choose = { title, message, buttons in
                questions.append(message)
                return choose(title, message, buttons)
            }
            VolumeFlows(environment: env, list: stage.list).newFromFolder()
            AppTests.check(questions.first?.contains("trash and version history") == true, questions.first ?? "")
            let note = stage.told.last?.message ?? ""
            AppTests.check(note.contains("Time Machine") && note.contains("synced folder"), note)
            AppTests.equal(stage.deletedFolders, [folder.path])
        },

        AppTests.Case("new from folder keeps the folder if a volume is mounted inside it") {
            let stage = VolumeStage()
            let (folder, _) = stage.folderSetUp()
            stage.attachedNow = [(URL(fileURLWithPath: "/tmp/other.dmg"), folder.appendingPathComponent("mnt"))]
            stage.flows().newFromFolder()
            AppTests.equal(stage.created.count, 0)
            AppTests.equal(stage.removedFolders, [])
        },

        AppTests.Case("new empty asks name, size, place and password") {
            let stage = VolumeStage()
            stage.forms = [["safetest:bad", "1 GB"], ["safetest empty", "tiny"], ["safetest empty", "2 GB"]]
            stage.imageChoice = URL(fileURLWithPath: stage.home + "/Sync/safetest empty")
            stage.answers = ["pw"]
            let record = stage.flows().newEmpty()
            AppTests.equal(stage.formMessages.count, 3)
            AppTests.equal(stage.created.count, 1)
            AppTests.equal(stage.created.first?.kind, "empty")
            AppTests.equal(stage.created.first?.size, 2048)
            AppTests.equal(stage.created.first?.name, "safetest empty")
            AppTests.equal(stage.created.first?.image, stage.home + "/Sync/safetest empty.sparsebundle")
            AppTests.equal(record?.path, "~/Sync/safetest empty.sparsebundle")
            AppTests.equal(stage.imageChoiceAsked.first?.name, "safetest empty.sparsebundle")
            AppTests.check(stage.asked.first?.twice == true)
            AppTests.equal(stage.list.volumes.count, 1)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("open checks the sync app, asks the password and shows the volume") {
            let stage = VolumeStage()
            let record = stage.record("safetest-a", syncApp: "SafetestSync")
            stage.choices = [1]
            let flows = stage.flows()
            flows.open(record)
            AppTests.equal(stage.questions.first?.title, "SafetestSync is not running")
            AppTests.equal(stage.attachCalls.count, 0, "opened after Cancel")
            AppTests.equal(stage.asked.count, 0)

            stage.choices = [0]
            stage.answers = ["wrong", "pw"]
            flows.open(record)
            AppTests.equal(stage.attachCalls.count, 2)
            let attach = stage.attachCalls.last
            AppTests.check(attach?.readOnly == false && attach?.hidden == false, "not attached for the Finder")
            // finding of review round 4: at /Volumes, with owners ignored, every account
            // on the Mac could read it; in a private folder only this user can
            AppTests.equal(attach?.mountPoint, stage.mount("safetest-a", 1))
            AppTests.equal(stage.removedEmpty, [stage.privateFolders[0]], "the folder of the wrong try was kept")
            AppTests.check(stage.asked.last?.message.contains("not right") == true)
            AppTests.equal(stage.revealed.map(\.path), [stage.mount("safetest-a", 1)])
            AppTests.equal(flows.appOpened[record.id]?.path, stage.mount("safetest-a", 1))
            AppTests.equal(flows.state(of: record), .open(URL(fileURLWithPath: stage.mount("safetest-a", 1), isDirectory: true)))
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("open does not ask when the sync app runs, and only shows an open volume") {
            let stage = VolumeStage()
            let record = stage.record("safetest-b", syncApp: "SafetestSync")
            stage.running = ["SafetestSync"]
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(record)
            AppTests.equal(stage.questions.count, 0)
            flows.open(record)
            AppTests.equal(stage.attachCalls.count, 1, "attached twice")
            AppTests.equal(stage.revealed.count, 2)
        },

        AppTests.Case("close never forces, and says so when the volume is busy") {
            let stage = VolumeStage()
            let record = stage.record("safetest-c")
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(record)
            stage.busy = [stage.mount("safetest-c")]
            flows.close(record)
            AppTests.equal(stage.told.last?.title, "“safetest-c” is still open")
            AppTests.check(flows.appOpened[record.id] != nil)
            AppTests.equal(stage.removedEmpty, [], "the private folder of an open volume was removed")
            stage.busy = []
            flows.close(record)
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            AppTests.equal(stage.detachCalls.count, 2)
            AppTests.equal(flows.appOpened[record.id], nil)
            AppTests.equal(flows.state(of: record), .closed)
            AppTests.equal(stage.removedEmpty, [stage.privateFolders[0]], "the private folder was kept")
        },

        AppTests.Case("lock closes only the volumes the app opened, never forced") {
            let stage = VolumeStage()
            let mine = stage.record("safetest-mine"), busy = stage.record("safetest-busy")
            let other = stage.record("safetest-other")
            let flows = stage.flows()
            stage.answers = ["pw", "pw"]
            flows.open(mine)
            flows.open(busy)
            stage.attachedNow.append((flows.imageURL(for: other), URL(fileURLWithPath: "/Volumes/safetest-other")))
            stage.busy = [stage.mount("safetest-busy", 1)]
            var done = false
            flows.closeAppOpenedVolumes { done = true }
            AppTests.check(done)
            AppTests.equal(Set(stage.detachCalls.map(\.mountPoint)),
                           [stage.mount("safetest-mine", 0), stage.mount("safetest-busy", 1)])
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            AppTests.equal(Array(flows.appOpened.keys), [busy.id])
            AppTests.equal(flows.busyAfterLock, ["safetest-busy"])
            AppTests.equal(flows.state(of: mine), .closed)
            AppTests.equal(flows.state(of: other), .open(URL(fileURLWithPath: "/Volumes/safetest-other")))
            let report = flows.takeBusyReport()
            AppTests.check(report?.contains("safetest-busy") == true, report ?? "nil")
            AppTests.equal(flows.takeBusyReport(), nil)
        },

        AppTests.Case("lock closes a volume under unsaved changes too, and it opens again at the same place") {
            // finding of review round 3 (G4): a volume holding the file of an editor with
            // unsaved changes stayed open, readable to every process, while the user was away
            let stage = VolumeStage()
            let held = stage.record("safetest-held"), free = stage.record("safetest-free")
            let flows = stage.flows()
            stage.answers = ["pw", "pw"]
            flows.open(held)
            flows.open(free)
            var done = false
            flows.closeAppOpenedVolumes { done = true }
            AppTests.check(done)
            AppTests.equal(Set(stage.detachCalls.map(\.mountPoint)),
                           [stage.mount("safetest-held", 0), stage.mount("safetest-free", 1)])
            AppTests.equal(stage.removedEmpty, [], "a private folder was removed, which opening again needs")
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            AppTests.equal(flows.appOpened, [:])
            AppTests.equal(flows.busyAfterLock, [])
            let file = URL(fileURLWithPath: stage.mount("safetest-held") + "/notes/a.txt.crypt")
            AppTests.equal(flows.closedVolume(holding: file)?.name, "safetest-held")
            AppTests.equal(flows.closedVolume(holding: URL(fileURLWithPath: stage.mount("safetest-held-not") + "/b.txt.crypt")),
                           nil)

            // the editor asks for it again: the same mount point, so that the save goes to the same path
            stage.states[stage.mount("safetest-held") + "/notes"] = .folder
            stage.answers = ["safetest-wrong", "pw"]
            AppTests.check(flows.reopen(holding: file), "not opened again")
            AppTests.equal(stage.asked.suffix(2).map(\.title), ["Open “safetest-held” again", "Open “safetest-held” again"])
            AppTests.check(stage.asked.last?.message.contains("not right") == true, stage.asked.last?.message ?? "")
            let attach = stage.attachCalls.last
            AppTests.equal(attach?.mountPoint, stage.mount("safetest-held"))
            AppTests.check(attach?.readOnly == false && attach?.hidden == false, "not opened as the user opens it")
            AppTests.equal(flows.appOpened[held.id], URL(fileURLWithPath: stage.mount("safetest-held"), isDirectory: true))
            AppTests.equal(flows.closedVolume(holding: file), nil)
            AppTests.check(!flows.reopen(holding: file), "opened a volume that was not closed on lock")
            AppTests.equal(stage.leakedPasswords, 0)

            // opened in the Volumes window instead: forgotten too
            flows.closeAppOpenedVolumes()
            AppTests.equal(flows.closedVolume(holding: file)?.name, "safetest-held")
            stage.answers = ["pw"]
            flows.open(held)
            AppTests.equal(flows.closedVolume(holding: file), nil)
            AppTests.check(VolumeFlows<FakePassword>.isInside(URL(fileURLWithPath: "/Volumes/a/b"),
                                                              URL(fileURLWithPath: "/Volumes/a")))
            AppTests.check(!VolumeFlows<FakePassword>.isInside(URL(fileURLWithPath: "/Volumes/ab/c"),
                                                               URL(fileURLWithPath: "/Volumes/a")))
        },

        AppTests.Case("a folder whose delete was cut short is offered for deleting at the next start") {
            // finding of review round 3: after a crash during the delete its unencrypted
            // rest stayed under a hidden name, and nothing ever mentioned it
            let stage = VolumeStage()
            let (folder, _) = stage.folderSetUp()
            stage.flows().newFromFolder()
            AppTests.equal(stage.deletedFolders, [folder.path])
            AppTests.equal(stage.pendingDeletes, [], "a finished delete is still recorded")

            // the delete fails halfway: the rest stays recorded
            let broken = VolumeStage()
            _ = broken.folderSetUp()
            var failing = broken.flows().env
            failing.removeFolder = { _ in throw CryptError.io("safetest: stopped halfway") }
            let made = VolumeFlows(environment: failing, list: broken.list).newFromFolder()
            AppTests.check(made != nil)
            AppTests.equal(broken.pendingDeletes.count, 1)
            let rest = broken.pendingDeletes.first ?? URL(fileURLWithPath: "/")
            AppTests.check(rest.lastPathComponent.hasPrefix(".safetest-folder.safe-pending-"), rest.path)

            // the next start: Not Now keeps it, Delete deletes it after the yes
            let next = VolumeStage()
            next.pendingDeletes = [rest, URL(fileURLWithPath: next.home + "/.gone.safe-pending-12345678"),
                                   URL(fileURLWithPath: next.home + "/Documents")]
            next.states[rest.path] = .folder
            next.states[next.home + "/Documents"] = .folder
            next.choices = [2]
            next.flows().offerToFinishDeletes()
            AppTests.equal(next.questions.map(\.title), ["Safe did not finish deleting a folder"])
            AppTests.equal(next.questions.first?.buttons, ["Delete", "Show in Finder", "Not Now"])
            AppTests.equal(next.removedFolders, [], "deleted without a yes")
            AppTests.equal(next.pendingDeletes, [rest], "only what Safe moved aside, and is still there, is kept")
            next.choices = [0]
            next.flows().offerToFinishDeletes()
            AppTests.equal(next.removedFolders, [rest.path])
            AppTests.equal(next.pendingDeletes, [])
        },

        AppTests.Case("the volumes the app opened are saved, and taken over at the next start") {
            // finding of review round 2 (G4): after a crash or Quit Anyway they stayed open
            let stage = VolumeStage()
            let record = stage.record("safetest-kept")
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(record)
            let mountPoint = URL(fileURLWithPath: stage.mount("safetest-kept"), isDirectory: true)
            AppTests.equal(stage.savedOpened.last, [record.id: mountPoint])

            let next = VolumeStage()
            next.list.volumes = stage.list.volumes
            next.states = stage.states
            next.attachedNow = stage.attachedNow
            let gone = UUID()
            next.storedOpened = [record.id: mountPoint, gone: URL(fileURLWithPath: "/Volumes/safetest-gone")]
            let later = next.flows()
            later.adoptOpenedVolumes()
            AppTests.equal(later.appOpened, [record.id: mountPoint])
            AppTests.equal(next.savedOpened.last, [record.id: mountPoint], "the stale entry was kept")
            later.closeAppOpenedVolumes()
            AppTests.equal(next.detachCalls.map(\.mountPoint), [mountPoint.path])
            AppTests.equal(later.appOpened, [:])
            AppTests.equal(next.savedOpened.last, [:])

            // a volume open at another place now was not opened by the app
            let moved = VolumeStage()
            moved.list.volumes = stage.list.volumes
            moved.states = stage.states
            moved.attachedNow = [(flows.imageURL(for: record), URL(fileURLWithPath: "/Volumes/safetest-kept 1"))]
            moved.storedOpened = [record.id: mountPoint]
            let other = moved.flows()
            other.adoptOpenedVolumes()
            AppTests.equal(other.appOpened, [:])
            AppTests.equal(moved.savedOpened.last, [:])
        },

        AppTests.Case("before sleep the lock waits for the volumes to close") {
            let stage = VolumeStage()
            stage.realQueues = true
            let record = stage.record("safetest-sleep")
            stage.answers = ["pw", "pw"]
            let flows = stage.flows()
            flows.open(record)
            var done = false
            flows.closeAppOpenedVolumes(waitUpTo: 5) { done = true }
            AppTests.check(done, "returned before the volumes were closed")
            AppTests.equal(flows.appOpened, [:])

            flows.open(record)
            AppTests.check(flows.appOpened[record.id] != nil, "not opened again")
            var later = false
            flows.closeAppOpenedVolumes { later = true }
            AppTests.check(!later, "the idle lock waited")
            let deadline = Date().addingTimeInterval(5)
            while !later && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            AppTests.check(later, "never finished")
            AppTests.equal(flows.appOpened, [:])
        },

        AppTests.Case("a volume kept open on lock is reported when the user is back, never during the lock") {
            // finding of review round 2: the alert came inside the lock and held it up
            let stage = VolumeStage()
            let held = stage.record("safetest-held")
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(held)
            let glue = VolumeLockGlue(flows: flows)
            let lock = LockController()
            var informed: [String] = [], attention = 0, sleeping: [Bool] = []
            glue.lockController = lock
            stage.busy = [stage.mount("safetest-held")]
            glue.inform = { title, _ in informed.append(title) }
            glue.requestAttention = { attention += 1 }
            glue.appIsActive = { true }
            lock.addLockAction { glue.lock() }
            lock.addLockAction { sleeping.append(lock.isLockingForSleep) }
            lock.onUserBack = { glue.userIsBack() }
            lock.lockNow()
            AppTests.equal(informed, [], "a message during the lock")
            AppTests.equal(attention, 1)
            AppTests.check(flows.appOpened[held.id] != nil, "a busy volume was forgotten")
            lock.userIsBack()
            AppTests.equal(informed, ["A volume is still open"])
            lock.lockNow(beforeSleep: true)
            AppTests.equal(sleeping, [false, true])
            AppTests.check(!lock.isLockingForSleep)
        },

        AppTests.Case("lock forgets volumes that were ejected meanwhile") {
            let stage = VolumeStage()
            let record = stage.record("safetest-d")
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(record)
            stage.attachedNow = []
            flows.closeAppOpenedVolumes()
            AppTests.equal(stage.detachCalls.count, 0)
            AppTests.equal(flows.appOpened.count, 0)
            AppTests.equal(flows.busyAfterLock, [])
        },

        AppTests.Case("quit closes the volumes the app opened and names the busy ones") {
            let stage = VolumeStage()
            let record = stage.record("safetest-e")
            stage.answers = ["pw"]
            let flows = stage.flows()
            flows.open(record)
            stage.busy = [stage.mount("safetest-e")]
            AppTests.equal(flows.closeAppOpenedVolumesNow(), ["safetest-e"])
            AppTests.equal(stage.removedEmpty, [])
            stage.busy = []
            AppTests.equal(flows.closeAppOpenedVolumesNow(), [])
            AppTests.equal(flows.appOpened.count, 0)
            AppTests.equal(stage.removedEmpty, [stage.privateFolders[0]], "the private folder was kept after Quit")
        },

        AppTests.Case("add existing takes only encrypted images, once") {
            let stage = VolumeStage()
            let image = URL(fileURLWithPath: stage.home + "/Sync/safetest-old.dmg")
            stage.existingChoice = image
            let flows = stage.flows()
            flows.addExisting()
            AppTests.equal(stage.list.volumes.count, 0)
            AppTests.equal(stage.told.last?.title, "“safetest-old.dmg” is not encrypted")
            stage.encrypted = [image.path]
            let record = flows.addExisting()
            AppTests.equal(record?.name, "safetest-old")
            AppTests.equal(record?.path, "~/Sync/safetest-old.dmg")
            flows.addExisting()
            AppTests.equal(stage.list.volumes.count, 1)
            AppTests.equal(stage.told.last?.title, "“safetest-old.dmg” is in the list already")
        },

        AppTests.Case("remove forgets the volume after asking and deletes nothing") {
            let stage = VolumeStage()
            let record = stage.record("safetest-f")
            stage.choices = [1]
            let flows = stage.flows()
            flows.remove(record)
            AppTests.equal(stage.list.volumes.count, 1)
            stage.choices = [0]
            flows.remove(record)
            AppTests.equal(stage.list.volumes.count, 0)
            AppTests.equal(stage.removedFolders, [])
            AppTests.equal(stage.states[stage.home + "/Sync/safetest-f.sparsebundle"], .folder)
        },

        AppTests.Case("the sync app is set and cleared per volume") {
            let stage = VolumeStage()
            let record = stage.record("safetest-g")
            let flows = stage.flows()
            flows.setSyncApp(record, to: "  SafetestSync ")
            AppTests.equal(stage.list.volumes.first?.syncApp, "SafetestSync")
            flows.setSyncApp(stage.list.volumes[0], to: "")
            AppTests.equal(stage.list.volumes.first?.syncApp, nil)
        },

        AppTests.Case("change password asks the old one once and the new one twice") {
            let stage = VolumeStage()
            let record = stage.record("safetest-h")
            stage.answers = ["wrong", "new", "pw", "new"]
            stage.flows().changePassword(record)
            AppTests.equal(stage.asked.map(\.twice), [false, true, false, true])
            AppTests.equal(stage.changed.count, 1)
            AppTests.equal(stage.changed.first?.new, "new")
            AppTests.equal(stage.changed.first?.image, stage.home + "/Sync/safetest-h.sparsebundle")
            AppTests.equal(stage.leakedPasswords, 0)
            // finding of review round 4: hdiutil chpass keeps the key, so an old copy of the
            // volume still opens with the old password; the user is told so, not the opposite
            AppTests.check(stage.asked.first?.message.contains("still opens with the old password") == true,
                           stage.asked.first?.message ?? "")
            let message = stage.told.last?.message ?? ""
            AppTests.check(message.contains("still opens with the old password") && message.contains("New Empty"), message)
            AppTests.check(!message.contains("only with the new password"), message)
        },

        AppTests.Case("the volumes window shows the list, and its buttons follow the selection") {
            guard OffScreen.available else { return }
            let stage = VolumeStage()
            let open = stage.record("safetest-open"), closed = stage.record("safetest-closed", syncApp: "SafetestSync")
            stage.list.volumes.append(VolumeRecord(name: "safetest-gone", path: "/tmp/safetest-gone.sparsebundle"))
            let flows = stage.flows()
            stage.answers = ["pw"]
            flows.open(open)
            let controller = VolumesWindowController(actions: flows)
            let table = controller.table
            AppTests.equal(controller.records.map(\.name), ["safetest-open", "safetest-closed", "safetest-gone"])
            AppTests.equal(controller.numberOfRows(in: table), 3)
            func label(_ row: Int, _ column: Int) -> NSTextField? {
                controller.tableView(table, viewFor: table.tableColumns[column], row: row) as? NSTextField
            }
            func cell(_ row: Int, _ column: Int) -> String? { label(row, column)?.stringValue }
            AppTests.equal(cell(0, 0), "safetest-open")
            AppTests.equal(cell(0, 1), "~/Sync/safetest-open.sparsebundle")
            AppTests.equal(cell(0, 2), "Open")
            AppTests.equal(label(0, 2)?.toolTip, "Open at " + stage.mount("safetest-open"))
            AppTests.equal(cell(1, 2), "Closed")
            AppTests.equal(cell(2, 2), "Not found")
            let titles = ["New Empty...", "New from Folder...", "Add Existing...", "Remove from List",
                          "Open", "Close", "Change Password..."]
            AppTests.equal(Set(controller.buttons.keys), Set(titles))
            func enabled(_ title: String) -> Bool { controller.buttons[title]?.isEnabled ?? false }
            AppTests.check(!enabled("Open") && !enabled("Close") && !enabled("Remove from List"), "enabled without a selection")
            AppTests.check(enabled("New Empty...") && enabled("New from Folder...") && enabled("Add Existing..."))

            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            AppTests.check(enabled("Open") && enabled("Close") && !enabled("Change Password..."), "open volume")
            AppTests.equal(controller.syncCheckbox.state, .off)
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            AppTests.check(enabled("Open") && !enabled("Close") && enabled("Change Password..."), "closed volume")
            AppTests.equal(controller.syncCheckbox.state, .on)
            AppTests.equal(controller.syncField.stringValue, "SafetestSync")
            OffScreen.render(controller.window!, as: "volumes-window")
            table.selectRowIndexes(IndexSet(integer: 2), byExtendingSelection: false)
            AppTests.check(!enabled("Open") && !enabled("Change Password...") && enabled("Remove from List"), "missing volume")

            stage.choices = [0]
            controller.buttons["Remove from List"]?.performClick(nil)
            AppTests.equal(controller.records.map(\.name), ["safetest-open", "safetest-closed"])
            table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            controller.syncCheckbox.performClick(nil)
            AppTests.equal(stage.list.volumes.first { $0.id == closed.id }?.syncApp, nil)
            AppTests.equal(controller.selected?.id, closed.id, "the selection was lost")
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            controller.buttons["Close"]?.performClick(nil)
            AppTests.equal(stage.detachCalls.map(\.mountPoint), [stage.mount("safetest-open")])
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")
            AppTests.check(controller.window?.isVisible == false, "the window is on the screen")
        },

        AppTests.Case("a volume whose image is gone shows as missing and does not open") {
            let stage = VolumeStage()
            let record = VolumeRecord(name: "safetest-gone", path: "/tmp/safetest-gone.sparsebundle")
            stage.list.volumes.append(record)
            let flows = stage.flows()
            flows.refresh()
            AppTests.equal(flows.state(of: record), .missing)
            flows.open(record)
            AppTests.equal(stage.asked.count, 0)
            AppTests.equal(stage.told.last?.title, "“safetest-gone” cannot be found")
        },
    ]

    /// Run in a child process by the first test: the real DiskImage and
    /// FolderVerifier with stand-in dialogs, on throwaway folders and images in
    /// $TMPDIR, attached only hidden; nothing shows in the Finder.
    static let children: [String: () throws -> Void] = [
        "volumes-real": {
            try AppTests.withTemporaryFolder { dir in
                let fm = FileManager.default
                func makeFolder(_ name: String) throws -> URL {
                    let folder = dir.appendingPathComponent(name, isDirectory: true)
                    try fm.createDirectory(at: folder.appendingPathComponent("sub"), withIntermediateDirectories: true)
                    try Data("safetest a\n".utf8).write(to: folder.appendingPathComponent("a.txt"))
                    try Data((0..<5000).map { UInt8($0 % 251) }).write(to: folder.appendingPathComponent("sub/b.bin"))
                    return folder
                }
                func isAttached(_ image: URL) -> Bool {
                    let images = (try? DiskImage.attached()) ?? []
                    let wanted = VolumeFlows<SecureBytes>.canonical(image)
                    return images.contains { VolumeFlows<SecureBytes>.canonical($0.imagePath) == wanted }
                }
                var told: [String] = []
                var toldSSD = false
                // names of their own, so that two runs at once do not meet in /Volumes,
                // where create -srcfolder mounts the new volume (finding of review round 4)
                let run = UUID().uuidString.prefix(8)
                var folder = try makeFolder("safetest-folder-\(run)")
                var image = dir.appendingPathComponent("safetest-folder-\(run).sparsebundle")
                var env = VolumeController.environment()
                env.chooseFolder = { folder }
                env.chooseImageLocation = { _, _ in image }
                env.askTwice = { _, _ in SecureBytes(string: "safetest-pw") }
                env.choose = { _, _, _ in 0 }
                env.inform = { title, message in told.append(title + ": " + message) }
                env.toldAboutDeletedFiles = { toldSSD }
                env.setToldAboutDeletedFiles = { toldSSD = true }
                env.reveal = { _ in }
                env.runWork = { _, work in try work() }
                env.loadOpened = { [:] }
                env.saveOpened = { _ in }
                // never the real ~/Library/Application Support/SafeDocker (plan section 11)
                var pending: [URL] = []
                env.loadPendingDeletes = { pending }
                env.savePendingDeletes = { pending = $0 }

                // 1. made, checked, folder deleted
                let list = FakeVolumeList()
                let record = VolumeFlows(environment: env, list: list).newFromFolder()
                AppTests.check(record != nil, "no volume: \(told)")
                AppTests.check(told.last?.hasPrefix("The volume is ready") == true, "\(told)")
                AppTests.check(!fm.fileExists(atPath: folder.path), "the folder is still there")
                AppTests.check(!(try fm.contentsOfDirectory(atPath: dir.path)).contains { $0.contains("safe-pending") },
                               "the folder moved aside is still there")
                AppTests.check(fm.fileExists(atPath: image.path), "no image")
                AppTests.check(!isAttached(image), "the image is still attached")
                AppTests.equal(list.volumes.count, 1)
                AppTests.check(toldSSD)
                AppTests.equal(pending, [], "a finished delete is still recorded")

                // 2. a check that finds a difference keeps the folder
                let first = image
                folder = try makeFolder("safetest-kept-\(run)")
                image = dir.appendingPathComponent("safetest-kept-\(run).sparsebundle")
                var failing = env
                failing.sameContents = { _, _ in false }
                AppTests.equal(VolumeFlows(environment: failing, list: FakeVolumeList()).newFromFolder(), nil)
                AppTests.check(fm.fileExists(atPath: folder.appendingPathComponent("sub/b.bin").path), "the folder is gone")
                AppTests.check(told.last?.hasPrefix("The folder was kept") == true, "\(told)")
                AppTests.check(!isAttached(image), "the image is still attached")

                // 3. a new password for the first image, and it opens with it
                var answers = ["safetest-wrong", "safetest-pw"]
                env.askOnce = { _, _ in answers.isEmpty ? nil : SecureBytes(string: answers.removeFirst()) }
                env.askTwice = { _, _ in SecureBytes(string: "safetest-new") }
                let flows = VolumeFlows(environment: env, list: list)
                if let record = record {
                    flows.changePassword(record)
                }
                AppTests.equal(answers, [])
                AppTests.check(told.last?.hasPrefix("The password of") == true, "\(told)")
                let result = flows.verify(folder: folder, image: first, password: SecureBytes(string: "safetest-new"))
                if case .failure(let error) = result {
                    AppTests.check(false, "does not open with the new password: \(error)")
                }
                AppTests.check(!isAttached(first), "the image is still attached")
            }
        },
    ]
}
#endif
