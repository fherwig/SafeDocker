import Foundation
import SafeCore

// WP2: DiskImage, FolderVerifier, VolumeStore, SyncCheck (building plan 7.1),
// with throwaway images under $TMPDIR (withTemporaryDirectory), test passwords
// and volume names starting with "safetest". Every test that attaches an image
// detaches it again, also when it fails. Tests that need a password are
// skipped while SecureBytes is still the stub from WP0.

enum VolumesTests: TestSuite {
    static let name = "volumes"

    static let tests: [TestCase] = storeTests + syncTests + verifierTests + imageTests

    static let children: [String: () -> Int32] = [
        "volumes/secure bytes": {
            let bytes = SecureBytes(string: "safetest")
            let same = bytes.withUnsafeBytes { Array($0) } == Array("safetest".utf8)
            return bytes.count == 8 && same ? 0 : 1
        },
    ]

    // MARK: VolumeStore

    static let storeTests: [TestCase] = [
        TestCase("store: add, update, remove, and the list survives a reload") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("Support/volumes.json")
                let image = dir.appendingPathComponent("a.sparsebundle")
                try FileManager.default.createDirectory(at: image, withIntermediateDirectories: false)
                let store = VolumeStore(file: file)
                expectEqual(store.volumes, [])
                expect(store.loadError == nil)
                expect(!FileManager.default.fileExists(atPath: file.path), "reading made the file")

                let a = VolumeRecord(name: "safetest A", path: image.path, syncApp: "Nextcloud")
                let b = VolumeRecord(name: "safetest B", path: dir.appendingPathComponent("b.sparsebundle").path)
                try store.add(a)
                try store.add(b)
                expectEqual(store.volumes, [a, b])
                expectEqual(VolumeStore(file: file).volumes, [a, b])

                var changed = a
                changed.name = "safetest A2"
                changed.syncApp = nil
                try store.update(changed)
                expectEqual(store.volumes, [changed, b])
                expectEqual(VolumeStore(file: file).volumes, [changed, b])

                try store.remove(id: a.id)
                expectEqual(VolumeStore(file: file).volumes, [b])
                expect(FileManager.default.fileExists(atPath: image.path), "remove deleted the image")
                try store.remove(id: UUID())
                expectEqual(VolumeStore(file: file).volumes, [b])
                try store.remove(id: b.id)
                expectEqual(store.volumes, [])
                expectEqual(VolumeStore(file: file).volumes, [])
            }
        },

        TestCase("store: paths under the home folder are kept with ~/") {
            let home = NSHomeDirectory()
            expectEqual(VolumeStore.abbreviatingHome(home + "/Documents/safetest.sparsebundle"),
                        "~/Documents/safetest.sparsebundle")
            expectEqual(VolumeStore.abbreviatingHome(home + "2/safetest.sparsebundle"),
                        home + "2/safetest.sparsebundle")
            expectEqual(VolumeStore.abbreviatingHome("/tmp/safetest.sparsebundle"), "/tmp/safetest.sparsebundle")
            expectEqual(VolumeStore.expandingHome("~/x/safetest.sparsebundle"), home + "/x/safetest.sparsebundle")
            expectEqual(VolumeStore.expandingHome("/tmp/safetest.sparsebundle"), "/tmp/safetest.sparsebundle")

            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("volumes.json")
                let store = VolumeStore(file: file)
                try store.add(VolumeRecord(name: "safetest home",
                                           path: home + "/Sync/../Sync/safetest.sparsebundle/"))
                expectEqual(store.volumes.first?.path, "~/Sync/safetest.sparsebundle")
                expectEqual(store.volumes.first?.url.path, home + "/Sync/safetest.sparsebundle")
                let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
                expect(text.contains("\"path\" : \"~/Sync/safetest.sparsebundle\""), text)
                expect(!text.contains(home), "the home folder is written out in the file")
                expectEqual(VolumeStore(file: file).volumes.first?.path, "~/Sync/safetest.sparsebundle")
                expectEqual(VolumeStore(file: file).volumes.first?.url.path, home + "/Sync/safetest.sparsebundle")
            }
        },

        TestCase("store: a second entry with the same id or path is refused") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("volumes.json")
                let store = VolumeStore(file: file)
                let a = VolumeRecord(name: "safetest A", path: dir.path + "/a.sparsebundle")
                let b = VolumeRecord(name: "safetest B", path: dir.path + "/b.sparsebundle")
                try store.add(a)
                try store.add(b)
                expectThrows(CryptError.alreadyExists("safetest A")) { try store.add(a) }
                expectThrows(CryptError.alreadyExists(a.path)) {
                    try store.add(VolumeRecord(name: "safetest C", path: dir.path + "/./a.sparsebundle"))
                }
                var moved = b
                moved.path = a.path
                expectThrows(CryptError.alreadyExists(a.path)) { try store.update(moved) }
                expectThrows("update of a volume not in the list") {
                    try store.update(VolumeRecord(name: "safetest D", path: dir.path + "/d.sparsebundle"))
                }
                expectEqual(store.volumes, [a, b])
                expectEqual(VolumeStore(file: file).volumes, [a, b])
            }
        },

        TestCase("store: the file is private and replaced atomically") {
            try withTemporaryDirectory { dir in
                let folder = dir.appendingPathComponent("SafeDocker")
                let file = folder.appendingPathComponent("volumes.json")
                let store = VolumeStore(file: file)
                try store.add(VolumeRecord(name: "safetest 1", path: "/tmp/safetest1.sparsebundle"))
                try store.add(VolumeRecord(name: "safetest 2", path: "/tmp/safetest2.sparsebundle",
                                           syncApp: "Nextcloud"))
                let fm = FileManager.default
                let mode = try fm.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
                expectEqual(mode?.intValue, 0o600)
                let folderMode = try fm.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber
                expectEqual(folderMode?.intValue, 0o700)
                expectEqual(try fm.contentsOfDirectory(atPath: folder.path), ["volumes.json"])
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
                expectEqual(json?["version"] as? Int, 1)
                let list = json?["volumes"] as? [[String: Any]]
                expectEqual(list?.count, 2)
                expectEqual(list?.first?["syncApp"] == nil, true)
                expectEqual(list?.last?["syncApp"] as? String, "Nextcloud")
            }
        },

        TestCase("store: an unreadable file is kept, not overwritten") {
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("volumes.json")
                let broken = Data("not json".utf8)
                try broken.write(to: file)
                let store = VolumeStore(file: file)
                expectEqual(store.volumes, [])
                expect(store.loadError != nil, "no load error")
                expectEqual(try Data(contentsOf: file), broken)

                try store.add(VolumeRecord(name: "safetest", path: "/tmp/safetest.sparsebundle"))
                expect(store.loadError == nil)
                let kept = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                    .filter { $0.hasPrefix("volumes.json.broken-") }
                expectEqual(kept.count, 1)
                if let name = kept.first {
                    expectEqual(try Data(contentsOf: dir.appendingPathComponent(name)), broken)
                }
                expectEqual(VolumeStore(file: file).volumes.count, 1)
            }
        },

        TestCase("store: the default file is in Application Support") {
            // only the path; the owner's real list is not read here
            let path = VolumeStore.defaultFile.path
            expect(path.hasSuffix("/Library/Application Support/SafeDocker/volumes.json"), path)
            expect(path.hasPrefix(NSHomeDirectory() + "/"), path)
        },
    ]

    // MARK: SyncCheck

    static let syncTests: [TestCase] = [
        TestCase("sync check: finds running programs by exact name") {
            expect(SyncCheck.isRunning(processName: ProcessInfo.processInfo.processName),
                   "this test program")
            expect(SyncCheck.isRunning(processName: "launchd"), "launchd, a process of root")
            expect(!SyncCheck.isRunning(processName: "safetest-no-such-process"))
            expect(!SyncCheck.isRunning(processName: "SafeTest"), "a part of a name matched")
            expect(!SyncCheck.isRunning(processName: ""))
        },

        TestCase("sync check: folders that a sync service uploads") {
            // finding of review round 4: Encrypt and New from Folder name the sync
            // service's trash and version history for these
            let home = "/Users/safetest"
            for folder in ["/Users/safetest/Library/CloudStorage/Dropbox/notes",
                           "/Users/safetest/Library/Mobile Documents/com~apple~CloudDocs",
                           "/Users/safetest/Nextcloud/Documents", "/Users/safetest/Dropbox",
                           "/Volumes/Data/OneDrive - Uni/x", "/Users/safetest/Google Drive/My Drive",
                           "/Users/safetest/ownCloud"] {
                expect(SyncCheck.isInSyncedFolder(folder, home: home), folder)
                expect(SyncCheck.isInSyncedFolder(folder + "/", home: home + "/"), folder + "/")
            }
            for folder in ["/Users/safetest/Documents", "/Users/safetest/Library/Caches", "/tmp/safetest",
                           "/Users/safetest/Library/CloudStorageNot", "/Users/other/Library/CloudStorage/x"] {
                expect(!SyncCheck.isInSyncedFolder(folder, home: home), folder)
            }
        },
    ]

    // MARK: FolderVerifier

    static let verifierTests: [TestCase] = [
        TestCase("verifier: a copy of a folder has the same contents") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                expect(try FolderVerifier.sameContents(a, b))
                expectEqual(try FolderVerifier.firstDifference(a, b), nil)
                expect(try FolderVerifier.sameContents(b, a))
            }
        },

        TestCase("verifier: notices a changed file of the same size") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                try Data("bravO".utf8).write(to: b.appendingPathComponent("sub/b.txt"))
                expect(try !FolderVerifier.sameContents(a, b))
                expect(try FolderVerifier.firstDifference(a, b)?.contains("sub/b.txt") == true)
            }
        },

        TestCase("verifier: notices a file of another size") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                try Data("bravo!".utf8).write(to: b.appendingPathComponent("sub/b.txt"))
                expect(try !FolderVerifier.sameContents(a, b))
            }
        },

        TestCase("verifier: notices a missing file") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                try FileManager.default.removeItem(at: b.appendingPathComponent("sub/deeper/c.bin"))
                expect(try !FolderVerifier.sameContents(a, b))
                expect(try FolderVerifier.firstDifference(a, b)?.contains("sub/deeper/c.bin") == true)
                expect(try !FolderVerifier.sameContents(b, a))
            }
        },

        TestCase("verifier: notices an extra file and an extra folder") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                let extra = b.appendingPathComponent("sub/extra.txt")
                try Data("extra".utf8).write(to: extra)
                expect(try !FolderVerifier.sameContents(a, b))
                try FileManager.default.removeItem(at: extra)
                expect(try FolderVerifier.sameContents(a, b))
                try FileManager.default.createDirectory(at: b.appendingPathComponent("new folder"),
                                                        withIntermediateDirectories: false)
                expect(try !FolderVerifier.sameContents(a, b))
            }
        },

        TestCase("verifier: notices a missing empty folder and a changed link") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                try FileManager.default.removeItem(at: b.appendingPathComponent("empty"))
                expect(try !FolderVerifier.sameContents(a, b))
            }
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                let link = b.appendingPathComponent("link")
                try FileManager.default.removeItem(at: link)
                try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "sub/b.txt")
                expect(try !FolderVerifier.sameContents(a, b))
            }
        },

        TestCase("verifier: ignores .DS_Store and volume metadata at the top") {
            try withTemporaryDirectory { dir in
                let (a, b) = try twoTrees(in: dir)
                let fm = FileManager.default
                try Data("x".utf8).write(to: b.appendingPathComponent(".DS_Store"))
                try Data("x".utf8).write(to: b.appendingPathComponent("sub/.DS_Store"))
                for name in [".fseventsd", ".Spotlight-V100", ".Trashes", ".TemporaryItems"] {
                    try fm.createDirectory(at: b.appendingPathComponent(name), withIntermediateDirectories: false)
                }
                try Data("x".utf8).write(to: b.appendingPathComponent(".fseventsd/0000"))
                expect(try FolderVerifier.sameContents(a, b))
                // deeper down they are ordinary folders
                try fm.createDirectory(at: b.appendingPathComponent("sub/.Trashes"), withIntermediateDirectories: false)
                expect(try !FolderVerifier.sameContents(a, b))
            }
        },

        TestCase("verifier: a missing folder or a file throws") {
            try withTemporaryDirectory { dir in
                let (a, _) = try twoTrees(in: dir)
                expectThrows { _ = try FolderVerifier.sameContents(a, dir.appendingPathComponent("missing")) }
                expectThrows { _ = try FolderVerifier.sameContents(a.appendingPathComponent("a.txt"), a) }
            }
        },
    ]

    // MARK: DiskImage

    static let imageTests: [TestCase] = [
        TestCase("image: isEncrypted is false for a plain image and a plain file") {
            try withImageFolder { dir in
                let image = try makePlainImage(in: dir)
                expectEqual(try DiskImage.isEncrypted(image), false)
                let file = dir.appendingPathComponent("plain.txt")
                try Data("safetest".utf8).write(to: file)
                expectEqual(try DiskImage.isEncrypted(file), false)
                expectThrows { _ = try DiskImage.isEncrypted(dir.appendingPathComponent("missing.sparsebundle")) }
            }
        },

        TestCase("image: attached() lists an image and its mount point; detach") {
            try withImageFolder { dir in
                let image = try makePlainImage(in: dir)
                let mountPoint = dir.appendingPathComponent("mnt")
                expectEqual(try DiskImage.attachment(of: image) == nil, true)
                try attachPlain(image, at: mountPoint)
                defer { forceDetach(mountPoint) }
                expect(isMounted(mountPoint))

                let found = try DiskImage.attached().filter { canonical($0.imagePath) == canonical(image) }
                expectEqual(found.count, 1)
                expectEqual(found.first?.mountPoint.map(canonical), canonical(mountPoint))
                expectEqual(try DiskImage.attachment(of: image)?.mountPoint.map(canonical), canonical(mountPoint))

                try DiskImage.detach(mountPoint, force: false)
                expect(!isMounted(mountPoint), "still mounted")
                expectEqual(try DiskImage.attachment(of: image) == nil, true)
                expect(!FileManager.default.fileExists(atPath: mountPoint.path), "the mount point is left")
                expectThrows("detach of something not mounted") { try DiskImage.detach(mountPoint, force: false) }
            }
        },

        TestCase("image: a busy volume is detached only with force") {
            try withImageFolder { dir in
                let image = try makePlainImage(in: dir)
                let mountPoint = dir.appendingPathComponent("mnt")
                try attachPlain(image, at: mountPoint)
                defer { forceDetach(mountPoint) }
                let file = mountPoint.appendingPathComponent("open.txt")
                try Data("safetest".utf8).write(to: file)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }

                let error = expectThrows("detach of a busy volume") { try DiskImage.detach(mountPoint, force: false) }
                if case .io(let message)? = error as? CryptError {
                    expect(message.contains("busy"), message)
                } else {
                    fail("expected CryptError.io, got \(String(describing: error))")
                }
                expect(isMounted(mountPoint), "detached without force")
                try DiskImage.detach(mountPoint, force: true)
                expect(!isMounted(mountPoint), "still mounted after force")
            }
        },

        TestCase("image: create empty, attach hidden, write, detach, read back") {
            let password = try Self.password("safetest pw 1 äö")
            try withImageFolder { dir in
                let image = dir.appendingPathComponent("empty.sparsebundle")
                let volume = volumeName()
                try DiskImage.createEmpty(at: image, maxSizeMB: 50, volumeName: volume, password: password)
                expect(FileManager.default.fileExists(atPath: image.appendingPathComponent("Info.plist").path),
                       "not a sparse bundle")
                expectEqual(try DiskImage.isEncrypted(image), true)

                let mountPoint = dir.appendingPathComponent("mnt")
                let mounted = try DiskImage.attach(image, password: password, readOnly: false,
                                                   mountPoint: mountPoint, hidden: true)
                defer { forceDetach(mounted) }
                expectEqual(canonical(mounted), canonical(mountPoint))
                expect(isMounted(mountPoint), "not mounted")
                let values = try URL(fileURLWithPath: mounted.path).resourceValues(
                    forKeys: [.volumeNameKey, .volumeTotalCapacityKey])
                expectEqual(values.volumeName, volume)
                let capacity = values.volumeTotalCapacity ?? 0
                expect(capacity > 30_000_000 && capacity <= 53_000_000, "capacity \(capacity)")
                try Data("safetest marker".utf8).write(to: mounted.appendingPathComponent("note.txt"))

                let again = expectThrows("attach while attached") {
                    _ = try DiskImage.attach(image, password: password, readOnly: false,
                                             mountPoint: dir.appendingPathComponent("mnt2"), hidden: true)
                }
                expect("\(String(describing: again))".contains("already open"), "\(String(describing: again))")

                try DiskImage.detach(mounted, force: false)
                expect(!isMounted(mountPoint), "still mounted")
                expect(!FileManager.default.fileExists(atPath: mountPoint.path), "the mount point is left")

                let readOnly = try DiskImage.attach(image, password: password, readOnly: true,
                                                    mountPoint: mountPoint, hidden: true)
                defer { forceDetach(readOnly) }
                expectEqual(try Data(contentsOf: readOnly.appendingPathComponent("note.txt")),
                            Data("safetest marker".utf8))
                expectThrows("write to a read-only volume") {
                    try Data("x".utf8).write(to: readOnly.appendingPathComponent("other.txt"))
                }
                try DiskImage.detach(readOnly, force: false)
                expect(!isMounted(mountPoint), "still mounted")
            }
        },

        TestCase("image: create from a folder and verify it") {
            let password = try Self.password("safetest pw 2 ß€")
            try withImageFolder { dir in
                let source = dir.appendingPathComponent("source")
                try makeTree(at: source)
                let image = dir.appendingPathComponent("folder.sparsebundle")
                try DiskImage.createFromFolder(source, at: image, volumeName: volumeName(), password: password)
                expectEqual(try DiskImage.isEncrypted(image), true)
                expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.txt").path),
                       "the folder was changed")

                let mountPoint = DiskImage.privateMountPoint()
                expect(!FileManager.default.fileExists(atPath: mountPoint.path), "the private mount point exists")
                expect(canonical(mountPoint.deletingLastPathComponent())
                       == canonical(FileManager.default.temporaryDirectory))
                let mounted = try DiskImage.attach(image, password: password, readOnly: true,
                                                   mountPoint: mountPoint, hidden: true)
                defer { forceDetach(mounted) }
                expectEqual(canonical(mounted), canonical(mountPoint))
                expect(try FolderVerifier.sameContents(source, mounted),
                       (try? FolderVerifier.firstDifference(source, mounted)).flatMap { $0 } ?? "")
                let capacity = try URL(fileURLWithPath: mounted.path)
                    .resourceValues(forKeys: [.volumeTotalCapacityKey]).volumeTotalCapacity ?? 0
                expect(capacity > 900_000_000, "room to grow: capacity \(capacity)")

                try Data("alphA".utf8).write(to: source.appendingPathComponent("a.txt"))
                expect(try !FolderVerifier.sameContents(source, mounted), "a changed file was not noticed")

                try DiskImage.detach(mounted, force: false)
                expect(!isMounted(mountPoint), "still mounted")
                expect(!FileManager.default.fileExists(atPath: mountPoint.path), "the mount point is left")
            }
        },

        TestCase("image: an unreadable file is left out, and the check notices") {
            let password = try Self.password("safetest pw 10")
            try withImageFolder { dir in
                let fm = FileManager.default
                let source = dir.appendingPathComponent("source")
                try makeTree(at: source)
                let locked = source.appendingPathComponent("sub/locked.txt")
                try Data("safetest locked".utf8).write(to: locked)
                try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
                defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: locked.path) }

                let image = dir.appendingPathComponent("locked.sparsebundle")
                try DiskImage.createFromFolder(source, at: image, volumeName: volumeName(), password: password)
                let mounted = try DiskImage.attach(image, password: password, readOnly: true,
                                                   mountPoint: dir.appendingPathComponent("mnt"), hidden: true)
                defer { forceDetach(mounted) }
                expect(fm.fileExists(atPath: mounted.appendingPathComponent("sub/b.txt").path))
                expect(!fm.fileExists(atPath: mounted.appendingPathComponent("sub/locked.txt").path))
                expect(try !FolderVerifier.sameContents(source, mounted), "the left-out file was not noticed")
                try DiskImage.detach(mounted, force: false)
            }
        },

        TestCase("image: a wrong password is reported as wrong") {
            let password = try Self.password("safetest pw 3")
            try withImageFolder { dir in
                let image = dir.appendingPathComponent("wrong.sparsebundle")
                try DiskImage.createEmpty(at: image, maxSizeMB: 50, volumeName: volumeName(), password: password)
                let mountPoint = dir.appendingPathComponent("mnt")
                for wrong in ["safetest pw 4", "safetest pw 3 ", "", "safetest pw 3\n"] {
                    expectThrows(CryptError.wrongPassword, "password \(wrong.debugDescription)") {
                        let mounted = try DiskImage.attach(image, password: SecureBytes(string: wrong),
                                                           readOnly: true, mountPoint: mountPoint, hidden: true)
                        forceDetach(mounted)
                    }
                }
                expect(!isMounted(mountPoint))
                expectEqual(try DiskImage.attachment(of: image) == nil, true)

                // the right one opens it, also on an empty folder that exists already
                try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: false)
                let mounted = try DiskImage.attach(image, password: password, readOnly: true,
                                                   mountPoint: mountPoint, hidden: true)
                defer { forceDetach(mounted) }
                expect(isMounted(mountPoint))
                try DiskImage.detach(mounted, force: false)
                expect(!isMounted(mountPoint))
            }
        },

        TestCase("image: change the password") {
            let first = try Self.password("safetest pw 5 äö")
            let second = SecureBytes(string: "safetest pw 6\nwith a new line")
            let wrong = SecureBytes(string: "safetest pw 7")
            try withImageFolder { dir in
                let image = dir.appendingPathComponent("chpass.sparsebundle")
                let mountPoint = dir.appendingPathComponent("mnt")
                try DiskImage.createEmpty(at: image, maxSizeMB: 50, volumeName: volumeName(), password: first)
                try DiskImage.changePassword(image, old: first, new: second)

                expectThrows(CryptError.wrongPassword, "the old password still opens it") {
                    let mounted = try DiskImage.attach(image, password: first, readOnly: true,
                                                       mountPoint: mountPoint, hidden: true)
                    forceDetach(mounted)
                }
                let mounted = try DiskImage.attach(image, password: second, readOnly: true,
                                                   mountPoint: mountPoint, hidden: true)
                defer { forceDetach(mounted) }
                expect(isMounted(mountPoint))
                expectThrows("change while attached") {
                    try DiskImage.changePassword(image, old: second, new: first)
                }
                try DiskImage.detach(mounted, force: false)

                expectThrows(CryptError.wrongPassword) { try DiskImage.changePassword(image, old: wrong, new: first) }
                try DiskImage.changePassword(image, old: second, new: first)
                let back = try DiskImage.attach(image, password: first, readOnly: true,
                                                mountPoint: mountPoint, hidden: true)
                defer { forceDetach(back) }
                try DiskImage.detach(back, force: false)
            }
        },

        TestCase("image: attach hidden without a mount point goes to /Volumes") {
            let password = try Self.password("safetest pw 8")
            try withImageFolder { dir in
                let image = dir.appendingPathComponent("volumes.sparsebundle")
                let volume = volumeName()
                try DiskImage.createEmpty(at: image, maxSizeMB: 50, volumeName: volume, password: password)
                let mounted = try DiskImage.attach(image, password: password, readOnly: true,
                                                   mountPoint: nil, hidden: true)
                defer { forceDetach(mounted) }
                expect(mounted.path.hasPrefix("/Volumes/" + volume), mounted.path)
                expect(isMounted(mounted))
                try DiskImage.detach(mounted, force: false)
                expect(!isMounted(mounted), "still mounted")
            }
        },

        TestCase("image: refuses what it must not make") {
            let password = try Self.password("safetest pw 9")
            try withImageFolder { dir in
                let fm = FileManager.default
                let existing = dir.appendingPathComponent("existing.sparsebundle")
                try fm.createDirectory(at: existing, withIntermediateDirectories: false)
                expectThrows(CryptError.alreadyExists(existing.path)) {
                    try DiskImage.createEmpty(at: existing, maxSizeMB: 50, volumeName: volumeName(), password: password)
                }
                let dmg = dir.appendingPathComponent("other.dmg")
                expectThrows("a name not ending in .sparsebundle") {
                    try DiskImage.createEmpty(at: dmg, maxSizeMB: 50, volumeName: volumeName(), password: password)
                }
                let fresh = dir.appendingPathComponent("fresh.sparsebundle")
                expectThrows("an empty password") {
                    try DiskImage.createEmpty(at: fresh, maxSizeMB: 50, volumeName: volumeName(),
                                              password: SecureBytes(string: ""))
                }
                expectThrows("a password with a NUL byte") {
                    try DiskImage.createEmpty(at: fresh, maxSizeMB: 50, volumeName: volumeName(),
                                              password: SecureBytes(Array("safetest\u{0}pw".utf8)))
                }
                expectThrows("size 0") {
                    try DiskImage.createEmpty(at: fresh, maxSizeMB: 0, volumeName: volumeName(), password: password)
                }
                expectThrows("an empty volume name") {
                    try DiskImage.createEmpty(at: fresh, maxSizeMB: 50, volumeName: " ", password: password)
                }
                expectThrows("a missing folder") {
                    try DiskImage.createEmpty(at: dir.appendingPathComponent("missing/fresh.sparsebundle"),
                                              maxSizeMB: 50, volumeName: volumeName(), password: password)
                }
                expect(!fm.fileExists(atPath: fresh.path) && !fm.fileExists(atPath: dmg.path))

                let source = dir.appendingPathComponent("source")
                try makeTree(at: source)
                let inside = source.appendingPathComponent("sub/inside.sparsebundle")
                expectThrows("an image inside its own folder") {
                    try DiskImage.createFromFolder(source, at: inside, volumeName: volumeName(), password: password)
                }
                expect(!fm.fileExists(atPath: inside.path))
                expectThrows("a file instead of a folder") {
                    try DiskImage.createFromFolder(source.appendingPathComponent("a.txt"), at: fresh,
                                                   volumeName: volumeName(), password: password)
                }
                expectThrows("attach of a missing image") {
                    _ = try DiskImage.attach(dir.appendingPathComponent("missing.sparsebundle"), password: password,
                                             readOnly: true, mountPoint: dir.appendingPathComponent("mnt"),
                                             hidden: true)
                }
                expect(!fm.fileExists(atPath: fresh.path))

                // a mount point that holds files, or is a file, would be hidden
                let plain = try makePlainImage(in: dir)
                for occupied in [source, source.appendingPathComponent("a.txt")] {
                    expectThrows("attach on \(occupied.lastPathComponent)") {
                        let mounted = try DiskImage.attach(plain, password: password, readOnly: true,
                                                           mountPoint: occupied, hidden: true)
                        forceDetach(mounted)
                    }
                    expect(!isMounted(occupied))
                }
                expectEqual(try DiskImage.attachment(of: plain) == nil, true)
            }
        },

        TestCase("image: no test image is left attached") {
            for image in try DiskImage.attached() {
                let path = canonical(image.imagePath)
                guard imageFolders.contains(where: { path.hasPrefix($0) }) else {
                    continue
                }
                fail("\(image.imagePath.path) is still attached")
                if let mountPoint = image.mountPoint {
                    forceDetach(mountPoint)
                }
                detachDevice(of: image.imagePath)
            }
        },
    ]

    // MARK: helpers

    /// A test password, or a skip while SecureBytes is the WP0 stub.
    static func password(_ text: String) throws -> SecureBytes {
        guard secureBytesWorks else {
            try skip("SecureBytes is still the WP0 stub; this runs once WP1 is merged")
        }
        return SecureBytes(string: text)
    }

    /// The stub stops the program, so it is tried in a child process, once.
    static let secureBytesWorks: Bool = {
        guard let result = try? runChild("volumes/secure bytes") else {
            return false
        }
        return result.status == 0
    }()

    static func volumeName() -> String {
        "safetest-" + UUID().uuidString.prefix(8).lowercased()
    }

    /// The path with symbolic links resolved, as hdiutil reports paths. A path
    /// that is gone keeps its /private, so that an image whose folder was
    /// removed still matches the folders of this run.
    static func canonical(_ url: URL) -> String {
        guard let resolved = realpath(url.path, nil) else {
            let path = url.standardizedFileURL.path
            if path.hasPrefix("/var/") || path.hasPrefix("/tmp/") {
                return "/private" + path
            }
            return path
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// True if a file system is mounted exactly at `url`.
    static func isMounted(_ url: URL) -> Bool {
        guard let resolved = realpath(url.path, nil) else {
            return false
        }
        defer { free(resolved) }
        var fs = statfs()
        guard statfs(resolved, &fs) == 0 else {
            return false
        }
        let mountedOn = withUnsafeBytes(of: fs.f_mntonname) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return mountedOn == String(cString: resolved)
    }

    /// Detaches whatever is mounted at `url`, without asking; for cleaning up.
    static func forceDetach(_ url: URL) {
        guard isMounted(url) else {
            return
        }
        if (try? DiskImage.detach(url, force: true)) == nil || isMounted(url) {
            _ = try? runProcess("/usr/bin/hdiutil", ["detach", url.path, "-force"])
        }
    }

    /// Detaches an image by its device, without asking; for cleaning up. A
    /// detach that unmounted the volume but could not eject the disk leaves an
    /// image attached with no mount point, which forceDetach cannot reach.
    static func detachDevice(of image: URL) {
        guard let result = try? runProcess("/usr/bin/hdiutil", ["info", "-plist"]), result.status == 0,
              let info = (try? PropertyListSerialization.propertyList(from: result.stdout, format: nil))
                as? [String: Any]
        else {
            return
        }
        let wanted = canonical(image)
        for entry in info["images"] as? [[String: Any]] ?? [] {
            guard let path = entry["image-path"] as? String, canonical(URL(fileURLWithPath: path)) == wanted else {
                continue
            }
            let devices = (entry["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }
            // hdiutil lists the image's own disk first, /dev/disk4 before /dev/disk4s1
            if let disk = devices.first {
                _ = try? runProcess("/usr/bin/hdiutil", ["detach", disk, "-force"])
            }
        }
    }

    /// The folders withImageFolder made in this run, each ending in "/".
    static var imageFolders: [String] = []

    /// A temporary folder for images; whatever image in it is still attached
    /// at the end is detached before the folder is removed.
    static func withImageFolder(_ body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { dir in
            let prefix = canonical(dir) + "/"
            imageFolders.append(prefix)
            defer {
                for image in (try? DiskImage.attached()) ?? []
                where canonical(image.imagePath).hasPrefix(prefix) {
                    if let mountPoint = image.mountPoint {
                        forceDetach(mountPoint)
                    }
                    detachDevice(of: image.imagePath)
                }
            }
            try body(dir)
        }
    }

    /// An unencrypted sparse bundle, made with hdiutil directly; needs no password.
    static func makePlainImage(in dir: URL) throws -> URL {
        let image = dir.appendingPathComponent("plain.sparsebundle")
        let result = try runProcess("/usr/bin/hdiutil", ["create", "-size", "20m", "-type", "SPARSEBUNDLE",
                                                         "-fs", "APFS", "-volname", volumeName(), image.path])
        guard result.status == 0 else {
            throw CryptError.io("hdiutil create: " + result.errorOutput)
        }
        return image
    }

    static func attachPlain(_ image: URL, at mountPoint: URL) throws {
        let result = try runProcess("/usr/bin/hdiutil", ["attach", "-nobrowse", "-mountpoint", mountPoint.path,
                                                         image.path])
        guard result.status == 0 else {
            throw CryptError.io("hdiutil attach: " + result.errorOutput)
        }
    }

    /// A small tree with text, a 1 MB file, a hidden file, an empty folder, a
    /// symbolic link and a name with an accent.
    static func makeTree(at root: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("sub/deeper"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: false)
        try Data("alpha".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("bravo".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))
        try Data("accent".utf8).write(to: root.appendingPathComponent("caf\u{e9}.txt"))
        var big = Data(count: 1 << 20)
        big.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
        try big.write(to: root.appendingPathComponent("sub/deeper/c.bin"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "a.txt")
    }

    /// dir/a, a tree, and dir/b, a copy of it.
    static func twoTrees(in dir: URL) throws -> (URL, URL) {
        let a = dir.appendingPathComponent("a"), b = dir.appendingPathComponent("b")
        try makeTree(at: a)
        try FileManager.default.copyItem(at: a, to: b)
        return (a, b)
    }
}
