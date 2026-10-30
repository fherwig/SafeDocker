#if DEBUG
import Foundation
import SafeCore

// WP4. Tests of RouterFlows (sections 4.3, 4.4, 4.7) with stand-ins for the
// dialogs, CryptFile and the windows, run by Safe --app-tests.

/// A password that remembers whether it was wiped.
final class FakePassword {
    let text: String
    private(set) var wiped = false
    init(_ text: String) { self.text = text }
    func wipe() { wiped = true }
}

/// An opened file as the tests see it.
struct FakeOpened {
    let url: URL
}

/// An editor or viewer window.
final class FakeWindow: RoutedWindow {
    var onClose: (() -> Void)?
    let kind: String
    let password: FakePassword
    var text: String?
    var coding: TextCoding?
    var readOnlyNote: String?
    var fronted = 0
    init(kind: String, password: FakePassword) {
        self.kind = kind
        self.password = password
    }
    func bringToFront() { fronted += 1 }
}

/// Records what the flows did and answers their questions from queues.
final class RouterStage {
    var answers: [String?] = []          // passwords typed, nil for Cancel
    var choices: [Int] = []              // buttons clicked
    var asked: [(twice: Bool, title: String, message: String)] = []
    var told: [(title: String, message: String)] = []
    var questions: [(title: String, buttons: [String])] = []
    var refusal: String?
    var refusalAsked = 0
    var states: [String: FileState] = [:]
    var encrypted: [(path: String, password: String)] = []
    var encryptErrors: [String: Error] = [:]
    var contents: [String: (password: String, kind: FileKind, variant: CryptVariant, data: Data)] = [:]
    var openErrors: [String: Error] = [:]
    var checks: [String: PasswordCheck] = [:]
    var sizes: [String: Int] = [:]
    var windows: [FakeWindow] = []
    var registered: [FakeWindow] = []
    var exported: [(data: Data, name: String, from: String, note: String?)] = []
    /// Names (hard links) per file, 1 if not set; the mount points of open volumes.
    var links: [String: Int] = [:]
    var mountPoints: [URL] = []
    /// Damaged files: the password whose start looks right, and their readable part;
    /// whether each readable part asked for was checked; files that may be cut short
    /// with a start Safe cannot recognise.
    var readable: [String: (password: String, data: Data)] = [:]
    var readableChecked: [Bool] = []
    var cutShort: Set<String> = []
    /// Folders in a synced folder, and whether the note about copies was told.
    var synced: Set<String> = []
    var toldCopies = false
    /// Files that may be old RC4 files, and what RC4 gives, per variant.
    var rc4: [String: [CryptVariant: Data]] = [:]
    var rc4Asked: [CryptVariant] = []
    var saved: [(data: Data, path: String, password: String)] = []
    var passwords: [FakePassword] = []
    var usedAfterWipe = false
    var encryptedImages: Set<String> = []
    /// The app's lock count, and the titles of the dialogs during which it locks,
    /// as if the user had walked away from an open dialog; with useRealLock the
    /// real LockController.shared locks instead.
    var locks = 0
    var lockDuring: Set<String> = []
    var useRealLock = false

    private func dialog(_ title: String) {
        guard lockDuring.contains(title) else { return }
        lockDuring.remove(title)
        if useRealLock {
            LockController.shared.lockNow()
        } else {
            locks += 1
        }
    }

    func flows() -> RouterFlows<FakePassword, FakeOpened> {
        RouterFlows(environment: RouterEnvironment(
            askOnce: { self.ask(twice: false, $0, $1) },
            askTwice: { self.ask(twice: true, $0, $1) },
            wipe: { $0.wipe() },
            inform: { title, message in
                self.told.append((title, message))
                self.dialog(title)
            },
            choose: { title, _, buttons in
                self.questions.append((title, buttons))
                self.dialog(title)
                return self.choices.isEmpty ? buttons.count - 1 : self.choices.removeFirst()
            },
            writeRefusal: {
                self.refusalAsked += 1
                return self.refusal
            },
            fileState: { self.states[$0.path] ?? .missing },
            fileSize: { self.sizes[$0.path] ?? 10 },
            isEncryptedImage: { self.encryptedImages.contains($0.path) },
            linkCount: { self.links[$0.path] ?? 1 },
            volumeMountPoints: { self.mountPoints },
            lockCount: { self.useRealLock ? LockController.shared.lockCount : self.locks },
            encryptFile: { url, password in
                self.use(password)
                if let error = self.encryptErrors[url.path] {
                    throw error
                }
                self.encrypted.append((url.path, password.text))
                return URL(fileURLWithPath: url.path + ".crypt")
            },
            openFile: { url, password in
                self.use(password)
                if let error = self.openErrors[url.path] {
                    throw error
                }
                guard let c = self.contents[url.path] else { throw CryptError.notEncrypted }
                guard c.password == password.text else { throw CryptError.wrongPassword }
                return OpenResult(opened: FakeOpened(url: url), originalName: url.deletingPathExtension().lastPathComponent,
                                  kind: c.kind, variant: c.variant, data: c.data,
                                  check: self.checks[url.path] ?? .confirmed)
            },
            readablePart: { url, password, checked in
                self.use(password)
                self.readableChecked.append(checked)
                guard let part = self.readable[url.path], part.password == password.text else {
                    throw CryptError.wrongPassword
                }
                return (url.deletingPathExtension().lastPathComponent, part.data)
            },
            mayBeOldRC4: { self.rc4[$0.path] != nil },
            mayBeCutShort: { self.cutShort.contains($0.path) },
            isInSyncedFolder: { self.synced.contains($0.path) },
            toldAboutCopies: { self.toldCopies },
            setToldAboutCopies: { self.toldCopies = true },
            decryptOldRC4: { url, password, variant in
                self.use(password)
                self.rc4Asked.append(variant)
                guard let data = self.rc4[url.path]?[variant] else { throw CryptError.io("no RC4 stand-in") }
                return (url.deletingPathExtension().lastPathComponent, data)
            },
            passwordDigest: { Data(("digest:" + $0.text).utf8) },
            saveCurrent: { data, opened, password in
                self.use(password)
                self.saved.append((data, opened.url.path, password.text))
            },
            showEditor: { _, text, password in
                let window = FakeWindow(kind: "editor", password: password)
                window.text = text.text
                window.coding = text.coding
                window.readOnlyNote = text.readOnlyNote
                self.windows.append(window)
                return window
            },
            showViewer: { _, _, password in
                let window = FakeWindow(kind: "viewer", password: password)
                self.windows.append(window)
                return window
            },
            exportData: { self.exported.append(($0, $1, $2.path, $3)) },
            register: { self.registered.append($0 as! FakeWindow) },
            runWork: { _, work in try work() }
        ))
    }

    private func ask(twice: Bool, _ title: String, _ message: String) -> FakePassword? {
        asked.append((twice, title, message))
        guard !answers.isEmpty, let text = answers.removeFirst() else { return nil }
        let password = FakePassword(text)
        passwords.append(password)
        return password
    }

    private func use(_ password: FakePassword) {
        if password.wiped {
            usedAfterWipe = true
        }
    }

    /// Passwords not wiped, other than those the windows took over.
    var leakedPasswords: Int {
        passwords.filter { p in !p.wiped && !windows.contains { $0.password === p } }.count
    }

    func file(_ path: String) -> URL {
        states[path] = .file
        return URL(fileURLWithPath: path)
    }

    func crypt(_ path: String, password: String, kind: FileKind, variant: CryptVariant = .current,
               data: Data = Data("safetest text\n".utf8), check: PasswordCheck = .confirmed) -> URL {
        contents[path] = (password, kind, variant, data)
        checks[path] = check
        return file(path)
    }
}

/// An editor or viewer for the tests with the real core; wipes the password on close.
final class StandInWindow: RoutedWindow {
    var onClose: (() -> Void)?
    let password: SecureBytes
    init(password: SecureBytes) { self.password = password }
    func bringToFront() {}
    func close() {
        password.wipe()
        onClose?()
    }
}

enum RouterTests {
    /// A text in ISO Latin-1, long enough to be told apart from random bytes.
    static let latin1Text = "Gr\u{FC}\u{DF}e aus K\u{F6}ln, und bis bald im Fr\u{FC}hjahr!\n"

    static let cases: [AppTests.Case] = [
        AppTests.Case("with the real CryptFile: encrypt, open after a wrong password, export") {
            try AppTests.runChild("router-real-files")
        },

        AppTests.Case("with the real CryptFile: nothing is written when the self-test failed") {
            try AppTests.runChild("router-real-refused")
        },

        AppTests.Case("with the real CryptFile: an old Latin-1 file opens read only with the right password") {
            try AppTests.runChild("router-real-legacy")
        },

        AppTests.Case("encrypt asks the password twice, once for all files") {
            let stage = RouterStage()
            let a = stage.file("/tmp/safetest/a.txt"), b = stage.file("/tmp/safetest/b.pdf")
            stage.answers = ["pw"]
            let outcomes = stage.flows().encrypt([a, b])
            AppTests.equal(stage.asked.count, 1)
            AppTests.check(stage.asked.first?.twice == true, "not asked twice")
            AppTests.equal(stage.encrypted.map(\.path), [a.path, b.path])
            AppTests.equal(stage.encrypted.map(\.password), ["pw", "pw"])
            AppTests.equal(outcomes, [.encrypted(URL(fileURLWithPath: a.path + ".crypt")),
                                      .encrypted(URL(fileURLWithPath: b.path + ".crypt"))])
            AppTests.equal(stage.told.count, 0, "a message after full success")
            AppTests.equal(stage.leakedPasswords, 0)
            AppTests.check(!stage.usedAfterWipe)
        },

        AppTests.Case("encrypt reports each file that failed and goes on") {
            let stage = RouterStage()
            let a = stage.file("/tmp/safetest/a.txt"), b = stage.file("/tmp/safetest/b.txt")
            let c = stage.file("/tmp/safetest/c.txt")
            stage.encryptErrors[b.path] = CryptError.checkFailed
            stage.answers = ["pw"]
            let outcomes = stage.flows().encrypt([a, b, c])
            AppTests.equal(outcomes.count, 3)
            AppTests.equal(outcomes[0], .encrypted(URL(fileURLWithPath: a.path + ".crypt")))
            AppTests.equal(outcomes[1], .failed(Wording.describe(CryptError.checkFailed)))
            AppTests.equal(outcomes[2], .encrypted(URL(fileURLWithPath: c.path + ".crypt")))
            AppTests.equal(stage.told.count, 1)
            AppTests.check(stage.told.first?.message.contains("b.txt") == true)
            AppTests.check(stage.told.first?.message.contains("a.txt") == false)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("encrypt is refused when the self-test failed") {
            let stage = RouterStage()
            let a = stage.file("/tmp/safetest/a.txt")
            stage.refusal = "self-test failed"
            stage.answers = ["pw"]
            let outcomes = stage.flows().encrypt([a])
            AppTests.equal(stage.asked.count, 0, "asked for a password anyway")
            AppTests.equal(stage.encrypted.count, 0)
            AppTests.equal(stage.told.first?.message, "self-test failed")
            AppTests.equal(outcomes, [.skipped("the self-test failed")])
        },

        AppTests.Case("encrypt skips folders, .crypt files and existing NAME.crypt") {
            let stage = RouterStage()
            let folder = URL(fileURLWithPath: "/tmp/safetest/folder")
            stage.states[folder.path] = .folder
            let crypt = stage.file("/tmp/safetest/x.crypt")
            let taken = stage.file("/tmp/safetest/taken.txt")
            _ = stage.file("/tmp/safetest/taken.txt.crypt")
            let gone = URL(fileURLWithPath: "/tmp/safetest/gone.txt")
            let outcomes = stage.flows().encrypt([folder, crypt, taken, gone])
            AppTests.equal(stage.asked.count, 0, "asked for a password with nothing to encrypt")
            AppTests.equal(stage.encrypted.count, 0)
            AppTests.equal(outcomes.count, 4)
            for outcome in outcomes {
                if case .skipped = outcome {} else { AppTests.check(false, "\(outcome) is not skipped") }
            }
            AppTests.equal(stage.told.count, 1)
            let message = stage.told.first?.message ?? ""
            AppTests.check(message.contains("folder") && message.contains("Volumes"), message)
            AppTests.check(message.contains("taken.txt.crypt exists already"), message)
            AppTests.check(message.contains("encrypted already"), message)
        },

        AppTests.Case("encrypt does nothing on Cancel") {
            let stage = RouterStage()
            let a = stage.file("/tmp/safetest/a.txt")
            stage.answers = [nil]
            let outcomes = stage.flows().encrypt([a])
            AppTests.equal(stage.encrypted.count, 0)
            AppTests.equal(stage.told.count, 0)
            AppTests.equal(outcomes, [.skipped("cancelled")])
        },

        AppTests.Case("open asks again after a wrong password and never shows garbage") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/notes.txt.crypt", password: "right", kind: .text)
            stage.answers = ["wrong", "right"]
            stage.flows().open([url])
            AppTests.equal(stage.asked.count, 2)
            AppTests.check(stage.asked.allSatisfy { !$0.twice }, "open asked twice")
            AppTests.check(stage.asked.last?.message.contains("not right") == true)
            AppTests.equal(stage.windows.count, 1)
            AppTests.equal(stage.windows.first?.kind, "editor")
            AppTests.equal(stage.windows.first?.text, "safetest text\n")
            AppTests.equal(stage.windows.first?.password.text, "right")
            AppTests.check(stage.passwords.first?.wiped == true, "the wrong password was not wiped")
            AppTests.check(stage.windows.first?.password.wiped == false, "the editor's password was wiped")
        },

        AppTests.Case("open shows nothing after a wrong password and Cancel") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/notes.txt.crypt", password: "right", kind: .text)
            stage.answers = ["wrong", nil]
            stage.flows().open([url])
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.exported.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("open sends text to the editor, PDF and images to the viewer") {
            let stage = RouterStage()
            let text = stage.crypt("/tmp/safetest/a.md.crypt", password: "p", kind: .text)
            let pdf = stage.crypt("/tmp/safetest/b.pdf.crypt", password: "p", kind: .pdf, data: Data("%PDF-".utf8))
            let png = stage.crypt("/tmp/safetest/c.png.crypt", password: "p", kind: .image, data: Data([0x89, 0x50]))
            stage.answers = ["p", "p", "p"]
            let flows = stage.flows()
            flows.open([text, pdf, png])
            AppTests.equal(stage.windows.map(\.kind), ["editor", "viewer", "viewer"])
            AppTests.equal(stage.registered.count, 3, "windows not handed to the lock")
            AppTests.equal(flows.windows.count, 3)
            AppTests.equal(stage.told.count, 0)
        },

        AppTests.Case("open offers export for other files, and Cancel") {
            let stage = RouterStage()
            let zip = stage.crypt("/tmp/safetest/d.zip.crypt", password: "p", kind: .other, data: Data([1, 2, 3]))
            stage.answers = ["p", "p"]
            stage.choices = [0, 1]
            let flows = stage.flows()
            flows.open([zip])
            AppTests.equal(stage.questions.first?.buttons, ["Export...", "Cancel"])
            AppTests.equal(stage.exported.count, 1)
            AppTests.equal(stage.exported.first?.data, Data([1, 2, 3]))
            AppTests.equal(stage.exported.first?.name, "d.zip")
            AppTests.equal(stage.exported.first?.from, zip.path)
            flows.open([zip])
            AppTests.equal(stage.exported.count, 1, "exported after Cancel")
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("text that is not UTF-8 is not put into the editor") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/e.txt.crypt", password: "p", kind: .text, data: Data([0xff, 0xfe, 0x00]))
            stage.answers = ["p"]
            stage.flows().open([url])
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.questions.count, 1)
        },

        AppTests.Case("an older format is named, and text is saved in the current format on the next save") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/old.txt.crypt", password: "p", kind: .text, variant: .legacyAESMD5)
            stage.answers = ["p"]
            stage.flows().open([url])
            AppTests.equal(stage.told.count, 1)
            AppTests.check(stage.told.first?.message.contains("MD5") == true, stage.told.first?.message ?? "")
            AppTests.check(stage.told.first?.message.contains("next time you save") == true)
            AppTests.equal(stage.windows.map(\.kind), ["editor"])
        },

        AppTests.Case("an other file in an older format can be saved in the current format") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/old.zip.crypt", password: "p", kind: .other, variant: .legacyRC4MD5,
                                  data: Data([9, 9]))
            stage.answers = ["p"]
            stage.choices = [1]
            stage.flows().open([url])
            AppTests.equal(stage.questions.first?.buttons, ["Export...", "Save in Current Format", "Cancel"])
            AppTests.equal(stage.saved.count, 1)
            AppTests.equal(stage.saved.first?.data, Data([9, 9]))
            AppTests.equal(stage.saved.first?.password, "p")
            AppTests.equal(stage.refusalAsked, 1, "saved without asking the self-test gate")
            AppTests.equal(stage.leakedPasswords, 0)
            AppTests.check(!stage.usedAfterWipe)
        },

        AppTests.Case("saving in the current format is refused when the self-test failed") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/old.zip.crypt", password: "p", kind: .other, variant: .legacyRC4MD5)
            stage.answers = ["p"]
            stage.choices = [1]
            stage.refusal = "self-test failed"
            stage.flows().open([url])
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.told.last?.message, "self-test failed")
        },

        AppTests.Case("an unchecked result from an older format needs the user's yes") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/old.bin.crypt", password: "p", kind: .other, variant: .legacyAESSHA256,
                                  check: .unchecked)
            stage.answers = ["p"]
            stage.choices = [2]        // Cancel at "Is this the right password?"
            stage.flows().open([url])
            AppTests.equal(stage.questions.first?.title, "Is this the right password?")
            AppTests.equal(stage.questions.count, 1)
            AppTests.equal(stage.exported.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)

            stage.questions = []
            stage.answers = ["p", "p"]
            stage.choices = [1, 0, 0]  // Type It Again, then Continue, then Export
            stage.flows().open([url])
            AppTests.equal(stage.asked.count, 3)
            AppTests.equal(stage.questions.map(\.title).first, "Is this the right password?")
            // accepted without a check: saved again in the current format only after a
            // question that names the risk (review round 4)
            AppTests.equal(stage.questions.last?.buttons, ["Export...", "Save in Current Format...", "Cancel"])
            AppTests.equal(stage.exported.count, 1)
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("an old file accepted without a check is saved in the current format only after a second yes") {
            // finding of review round 4 (G5): such a file could only be exported
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/old.bin.crypt", password: "p", kind: .other, variant: .legacyAESMD5,
                                  data: Data([7, 7]), check: .unchecked)
            stage.answers = ["p", "p"]
            stage.choices = [0, 1, 1]  // Continue, Save in Current Format..., Cancel
            let flows = stage.flows()
            flows.open([url])
            AppTests.equal(stage.questions.map(\.title), ["Is this the right password?", "“old.bin.crypt”",
                                                          "Save “old.bin.crypt” in the current format?"])
            AppTests.equal(stage.saved.count, 0, "saved after Cancel")
            stage.questions = []
            stage.choices = [0, 1, 0]  // Continue, Save in Current Format..., Save in Current Format
            flows.open([url])
            AppTests.equal(stage.questions.last?.buttons, ["Save in Current Format", "Cancel"])
            AppTests.equal(stage.saved.map(\.data), [Data([7, 7])])
            AppTests.check(stage.told.last?.message.contains("old.bin.crypt.bak") == true, stage.told.last?.message ?? "")
            // a lock during the second question saves nothing
            let locked = RouterStage()
            let other = locked.crypt("/tmp/safetest/old.bin.crypt", password: "p", kind: .other,
                                     variant: .legacyAESMD5, data: Data([7]), check: .unchecked)
            locked.answers = ["p", nil]
            locked.choices = [0, 1, 0]
            locked.lockDuring = ["Save “old.bin.crypt” in the current format?"]
            locked.flows().open([other])
            AppTests.equal(locked.saved.count, 0, "saved after a lock")
            AppTests.equal(locked.leakedPasswords, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("a text whose password Safe could not confirm opens read only, on the user's choice") {
            let stage = RouterStage()
            let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
            let url = stage.crypt("/tmp/safetest/latin1.txt.crypt", password: "p", kind: .other, data: latin1,
                                  check: .contentMismatch)
            stage.answers = ["p"]
            stage.choices = [0]        // Open Read-Only
            stage.flows().open([url])
            AppTests.equal(stage.questions.first?.title, "Safe could not confirm the password")
            AppTests.equal(stage.questions.first?.buttons, ["Open Read-Only", "Type Another Password", "Cancel"])
            AppTests.equal(stage.windows.map(\.kind), ["editor"])
            AppTests.equal(stage.windows.first?.text, RouterTests.latin1Text)
            AppTests.equal(stage.windows.first?.coding, .latin1)
            AppTests.check(stage.windows.first?.readOnlyNote?.contains("read only") == true,
                           stage.windows.first?.readOnlyNote ?? "no note")
            AppTests.equal(stage.told.count, 0, "told the right password was wrong")
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("a result Safe could not confirm can be refused: type another password, or cancel") {
            let stage = RouterStage()
            let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
            let url = stage.crypt("/tmp/safetest/notes.txt.crypt", password: "p", kind: .other,
                                  data: latin1, check: .contentMismatch)
            stage.answers = ["p", "p"]
            stage.choices = [1, 2]     // Type Another Password, then Cancel
            stage.flows().open([url])
            AppTests.equal(stage.asked.count, 2)
            AppTests.check(stage.asked.last?.message.contains("again") == true, stage.asked.last?.message ?? "")
            AppTests.equal(stage.questions.count, 2)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.exported.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("content that is not text in any encoding is called a wrong password, with Export Anyway") {
            // finding of review round 2: about 1 in 256 wrong passwords gave a read-only
            // editor full of garbage
            let stage = RouterStage()
            let noise = Data((0 ..< 200).map { UInt8(($0 * 151 + 7) & 0xFF) })
            let url = stage.crypt("/tmp/safetest/notes.txt.crypt", password: "p", kind: .other,
                                  data: noise, check: .contentMismatch)
            stage.answers = ["p", "p", "p"]
            stage.choices = [0, 2]     // Type It Again, then Cancel
            let flows = stage.flows()
            flows.open([url])
            AppTests.equal(stage.questions.first?.title, "The password is probably not right")
            AppTests.equal(stage.questions.first?.buttons, ["Type It Again", "Export Anyway...", "Cancel"])
            AppTests.equal(stage.asked.count, 2)
            AppTests.check(stage.asked.last?.message.contains("again") == true, stage.asked.last?.message ?? "")
            AppTests.equal(stage.windows.count, 0, "garbage was shown")
            AppTests.equal(stage.exported.count, 0)
            // the right password is never refused: Export Anyway
            stage.choices = [1]
            flows.open([url])
            AppTests.equal(stage.exported.map(\.data), [noise])
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("an older format whose text does not fit its name opens read only, without a save offer") {
            // finding of review round 2: old Latin-1 files were refused as a wrong password
            let stage = RouterStage()
            let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
            let url = stage.crypt("/tmp/safetest/old.txt.crypt", password: "p", kind: .other,
                                  variant: .legacyAESMD5, data: latin1, check: .contentMismatch)
            stage.answers = ["p"]
            stage.choices = [0]        // Open Read-Only
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["Safe could not confirm the password"])
            AppTests.equal(stage.questions.first?.buttons, ["Open Read-Only", "Type Another Password", "Cancel"])
            AppTests.equal(stage.windows.map(\.kind), ["editor"])
            AppTests.equal(stage.windows.first?.coding, .latin1)
            AppTests.check(stage.windows.first?.readOnlyNote != nil, "not read only")
            AppTests.equal(stage.told.count, 0, "told something before the read-only view")
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("a short text from an older format accepted without a check opens read only") {
            // findings of review round 2: it went into an editable editor and was saved
            // in the current format at the next Cmd-S
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/short.txt.crypt", password: "p", kind: .text,
                                  variant: .legacyRC4MD5, data: Data("pin 1234\n".utf8), check: .unchecked)
            stage.answers = ["p"]
            stage.choices = [0]        // Continue at "Is this the right password?"
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["Is this the right password?"])
            AppTests.equal(stage.windows.map(\.kind), ["editor"])
            AppTests.equal(stage.windows.first?.text, "pin 1234\n")
            AppTests.check(stage.windows.first?.readOnlyNote?.contains("read only") == true,
                           stage.windows.first?.readOnlyNote ?? "no note: editable")
            AppTests.equal(stage.told.count, 0, "promised to save it in the current format")
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("nothing decrypted is shown after Safe locked while a question was open") {
            // finding of review round 2 (G4): a click after the lock showed the text
            let stage = RouterStage()
            let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
            let url = stage.crypt("/tmp/safetest/latin1.txt.crypt", password: "p", kind: .other, data: latin1,
                                  check: .contentMismatch)
            stage.answers = ["p", "p"]
            stage.choices = [0, 0]     // Open Read-Only both times
            stage.lockDuring = ["Safe could not confirm the password"]
            stage.flows().open([url])
            AppTests.equal(stage.asked.count, 2, "not asked again after the lock")
            AppTests.check(stage.asked.last?.message.contains("locked") == true, stage.asked.last?.message ?? "")
            AppTests.check(stage.passwords.first?.wiped == true, "the password was kept over the lock")
            AppTests.equal(stage.windows.count, 1)
            AppTests.check(stage.windows.first?.password === stage.passwords.last, "shown with the first password")

            // the same during the message about an older format, and before an export
            let old = RouterStage()
            let text = old.crypt("/tmp/safetest/old.md.crypt", password: "p", kind: .text, variant: .legacyAESMD5)
            old.answers = ["p", nil]
            old.lockDuring = ["“old.md.crypt” is in an older format"]
            old.flows().open([text])
            AppTests.equal(old.windows.count, 0, "shown after a lock")
            AppTests.equal(old.asked.count, 2)
            AppTests.equal(old.leakedPasswords, 0)

            let other = RouterStage()
            let zip = other.crypt("/tmp/safetest/d.zip.crypt", password: "p", kind: .other, data: Data([1, 2]))
            other.answers = ["p", nil]
            other.choices = [0]        // Export...
            other.lockDuring = ["“d.zip.crypt”"]
            other.flows().open([zip])
            AppTests.equal(other.exported.count, 0, "exported after a lock")
            AppTests.equal(other.asked.count, 2)
            AppTests.equal(other.leakedPasswords, 0)
        },

        AppTests.Case("with the real lock: LockController.lockNow during a question shows no window") {
            let stage = RouterStage()
            stage.useRealLock = true
            let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
            let url = stage.crypt("/tmp/safetest/latin1.txt.crypt", password: "p", kind: .other, data: latin1,
                                  check: .contentMismatch)
            stage.answers = ["p", nil]
            stage.choices = [0]
            stage.lockDuring = ["Safe could not confirm the password"]
            let before = LockController.shared.lockCount
            stage.flows().open([url])
            AppTests.equal(LockController.shared.lockCount, before + 1)
            AppTests.equal(stage.windows.count, 0, "a window was shown after the lock")
            AppTests.equal(stage.exported.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("a file that may be damaged is said so, and the password asked again") {
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/cut.txt.crypt")
            stage.openErrors[url.path] = CryptError.wrongPasswordOrDamaged
            stage.answers = ["p", nil]
            stage.flows().open([url])
            AppTests.equal(stage.asked.count, 2)
            AppTests.check(stage.asked.last?.message.contains("damaged") == true, stage.asked.last?.message ?? "")
            AppTests.equal(stage.told.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("a damaged file is said to be damaged, and its readable part can be exported") {
            // finding of review round 3: a file cut at a block boundary was a wrong password
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/cut.txt.crypt")
            stage.openErrors[url.path] = CryptError.damaged
            stage.readable[url.path] = ("p", Data("safetest readable start\n".utf8))
            _ = stage.file(url.path + ".bak")
            stage.answers = ["p"]
            stage.choices = [0]        // Export Readable Part...
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["“cut.txt.crypt” is damaged"])
            AppTests.equal(stage.questions.first?.buttons, ["Export Readable Part...", "Type Another Password", "Cancel"])
            AppTests.equal(stage.exported.map(\.data), [Data("safetest readable start\n".utf8)])
            AppTests.equal(stage.exported.first?.name, "cut.txt")
            AppTests.equal(stage.exported.first?.note, Wording.damagedNote)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
            AppTests.check(!stage.usedAfterWipe)

            // the message names the .bak; Type Another Password asks again; a lock during
            // the question drops the password
            let other = RouterStage()
            let cut = other.file("/tmp/safetest/cut.txt.crypt")
            other.openErrors[cut.path] = CryptError.damaged
            _ = other.file(cut.path + ".bak")
            other.answers = ["p", "p", nil]
            other.choices = [0, 1]     // Export (after a lock: not taken), then Type Another Password
            other.lockDuring = ["“cut.txt.crypt” is damaged"]
            var messages: [String] = []
            let flows = other.flows()
            var env = flows.env
            let choose = env.choose
            env.choose = { title, message, buttons in
                messages.append(message)
                return choose(title, message, buttons)
            }
            RouterFlows(environment: env).open([cut])
            AppTests.check(messages.first?.contains("“cut.txt.crypt.bak” next to it holds the previous version") == true,
                           messages.first ?? "")
            AppTests.equal(other.asked.count, 3)
            AppTests.check(other.asked[1].message.contains("locked"), other.asked[1].message)
            AppTests.equal(other.exported.count, 0, "exported after a lock")
            AppTests.equal(other.leakedPasswords, 0)
        },

        AppTests.Case("the same password refused twice can export an old RC4 file, never show it") {
            // finding of review round 3 (G5): such files never opened in the app
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/keys.bin.crypt")
            stage.openErrors[url.path] = CryptError.wrongPassword
            stage.rc4[url.path] = [.legacyRC4MD5: Data([1, 2, 3]), .legacyRC4SHA256: Data([4, 5, 6])]
            stage.answers = ["p", "other", "p", "p"]
            stage.choices = [1, 0]     // Export as an Old RC4 File..., crypt.sh before 1.4
            stage.flows().open([url])
            // different passwords are not asked about; the same one twice is
            AppTests.equal(stage.asked.count, 4)
            AppTests.equal(stage.questions.map(\.title), ["The password was not right", "How was “keys.bin.crypt” written?"])
            AppTests.equal(stage.questions.first?.buttons, ["Type It Again", "Export as an Old RC4 File...", "Cancel"])
            AppTests.equal(stage.rc4Asked, [.legacyRC4MD5])
            AppTests.equal(stage.exported.map(\.data), [Data([1, 2, 3])])
            AppTests.equal(stage.exported.first?.note, Wording.uncheckedNote)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
            AppTests.check(!stage.usedAfterWipe)

            // a file that cannot be such a file: the repeat only names the .bak
            let pdf = RouterStage()
            let report = pdf.file("/tmp/safetest/report.pdf.crypt")
            _ = pdf.file(report.path + ".bak")
            pdf.openErrors[report.path] = CryptError.wrongPassword
            pdf.answers = ["p", "p", nil]
            pdf.flows().open([report])
            AppTests.equal(pdf.questions.count, 0)
            AppTests.equal(pdf.asked.count, 3)
            AppTests.check(pdf.asked[2].message.contains("“report.pdf.crypt.bak”"), pdf.asked[2].message)
            AppTests.equal(pdf.leakedPasswords, 0)

            // a lock during the question: nothing is exported, the password is asked again
            let locked = RouterStage()
            let bin = locked.file("/tmp/safetest/data.bin.crypt")
            locked.openErrors[bin.path] = CryptError.wrongPasswordOrDamaged
            locked.rc4[bin.path] = [.legacyRC4MD5: Data([7])]
            locked.answers = ["p", "p", nil]
            locked.choices = [1, 0]
            locked.lockDuring = ["How was “data.bin.crypt” written?"]
            locked.flows().open([bin])
            AppTests.equal(locked.exported.count, 0, "exported after a lock")
            AppTests.check(locked.asked.last?.message.contains("locked") == true, locked.asked.last?.message ?? "")
            AppTests.equal(locked.leakedPasswords, 0)
        },

        AppTests.Case("a cut file refused twice can export its readable part, unchecked") {
            // finding of review round 4: a .bin or .kdbx cut short could not be recovered,
            // and only Export as an Old RC4 File was offered
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/vault.kdbx.crypt")
            stage.openErrors[url.path] = CryptError.wrongPassword
            stage.rc4[url.path] = [.legacyRC4MD5: Data([1])]
            stage.cutShort = [url.path]
            stage.readable[url.path] = ("p", Data("safetest start".utf8))
            stage.answers = ["p", "p"]
            stage.choices = [1]        // Export Readable Part...
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["The password was not right"])
            AppTests.equal(stage.questions.first?.buttons,
                           ["Type It Again", "Export Readable Part...", "Export as an Old RC4 File...", "Cancel"])
            AppTests.equal(stage.readableChecked, [false])
            AppTests.equal(stage.exported.map(\.data), [Data("safetest start".utf8)])
            AppTests.equal(stage.exported.first?.note, Wording.uncheckedPartNote)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
            AppTests.check(!stage.usedAfterWipe)
        },

        AppTests.Case("a result Safe could not confirm offers the other readings of the file") {
            // finding of review round 4 (G5): with about 1 in 256 passwords, the right one
            // of an old RC4 file included, an AES variant passes its padding check; Type It
            // Again gave the same garbage every time, and the RC4 content was out of reach
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/keys.bin.crypt", password: "p", kind: .other,
                                  variant: .legacyAESSHA256, data: Data([9, 9, 9]), check: .unchecked)
            stage.rc4[url.path] = [.legacyRC4MD5: Data([1, 2, 3]), .legacyRC4SHA256: Data([4])]
            stage.cutShort = [url.path]
            stage.answers = ["p"]
            stage.choices = [1, 1]     // Other Readings..., crypt.sh before 1.4
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["Is this the right password?", "How was “keys.bin.crypt” written?"])
            AppTests.equal(stage.questions.first?.buttons, ["Continue", "Other Readings...", "Type It Again", "Cancel"])
            AppTests.equal(stage.questions.last?.buttons, ["Damaged File (Readable Part)", "crypt.sh Before 1.4 (MD5 Key)",
                                                          "Another Tool (SHA-256 Key)", "Cancel"])
            AppTests.equal(stage.rc4Asked, [.legacyRC4MD5])
            AppTests.equal(stage.exported.map(\.data), [Data([1, 2, 3])])
            AppTests.equal(stage.exported.first?.note, Wording.uncheckedNote)
            AppTests.equal(stage.leakedPasswords, 0)

            // the current format's unchecked result: RC4 only, no readable part
            let current = RouterStage()
            let bin = current.crypt("/tmp/safetest/data.bin.crypt", password: "p", kind: .other,
                                    data: Data([5]), check: .unchecked)
            current.rc4[bin.path] = [.legacyRC4MD5: Data([6]), .legacyRC4SHA256: Data([7])]
            current.cutShort = [bin.path]
            current.answers = ["p"]
            current.choices = [1, 1]   // Other Readings..., SHA-256
            current.flows().open([bin])
            AppTests.equal(current.questions.first?.buttons, ["Export...", "Other Readings...", "Type Another Password",
                                                            "Cancel"])
            AppTests.equal(current.questions.last?.buttons, ["crypt.sh Before 1.4 (MD5 Key)", "Another Tool (SHA-256 Key)",
                                                            "Cancel"])
            AppTests.equal(current.exported.map(\.data), [Data([7])])

            // a text name whose content is not text: "probably not right", with the readings
            let text = RouterStage()
            let noise = Data((0 ..< 200).map { UInt8(($0 * 151 + 7) & 0xFF) })
            let keys = text.crypt("/tmp/safetest/keys.crypt", password: "p", kind: .other, variant: .legacyAESMD5,
                                  data: noise, check: .contentMismatch)
            text.rc4[keys.path] = [.legacyRC4MD5: Data("safetest keys\n".utf8)]
            text.answers = ["p"]
            text.choices = [1, 0]      // Other Readings..., crypt.sh before 1.4
            text.lockDuring = []
            text.flows().open([keys])
            AppTests.equal(text.questions.first?.title, "The password is probably not right")
            AppTests.equal(text.questions.first?.buttons, ["Type It Again", "Other Readings...", "Export Anyway...", "Cancel"])
            AppTests.equal(text.exported.map(\.data), [Data("safetest keys\n".utf8)])
            AppTests.equal(text.windows.count, 0)

            // a lock during the choice exports nothing and asks the password again
            let locked = RouterStage()
            let other = locked.crypt("/tmp/safetest/keys.bin.crypt", password: "p", kind: .other,
                                     variant: .legacyAESMD5, data: Data([1]), check: .unchecked)
            locked.rc4[other.path] = [.legacyRC4MD5: Data([2])]
            locked.answers = ["p", nil]
            locked.choices = [1, 0]
            locked.lockDuring = ["How was “keys.bin.crypt” written?"]
            locked.flows().open([other])
            AppTests.equal(locked.exported.count, 0, "exported after a lock")
            AppTests.check(locked.asked.last?.message.contains("locked") == true, locked.asked.last?.message ?? "")
            AppTests.equal(locked.leakedPasswords, 0)
        },

        AppTests.Case("a text too short to confirm opens read only, on the user's choice") {
            // finding of review round 4: 15 random bytes were confirmed as a text too often
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/pin.txt.crypt", password: "p", kind: .text,
                                  data: Data("123456789012345".utf8), check: .unchecked)
            stage.answers = ["p"]
            stage.choices = [0]        // Open Read-Only
            var messages: [String] = []
            var env = stage.flows().env
            let choose = env.choose
            env.choose = { title, message, buttons in
                messages.append(message)
                return choose(title, message, buttons)
            }
            RouterFlows(environment: env).open([url])
            AppTests.equal(stage.questions.map(\.title), ["Safe could not confirm the password"])
            AppTests.check(messages.first?.contains("so short") == true, messages.first ?? "")
            AppTests.equal(stage.windows.map(\.kind), ["editor"])
            AppTests.check(stage.windows.first?.readOnlyNote != nil, "not read only")
        },

        AppTests.Case("encrypt names the sync service's copies, and the other copies once") {
            // finding of review round 4: Encrypt told nothing of the plain copies that
            // outlive the delete
            let stage = RouterStage()
            stage.synced = ["/tmp/safetest-sync"]
            let synced = stage.file("/tmp/safetest-sync/notes.txt")
            let plain = stage.file("/tmp/safetest/other.txt")
            stage.answers = ["pw", "pw"]
            stage.flows().encrypt([synced])
            AppTests.check(stage.asked.first?.message.contains(Wording.syncedNote) == true, stage.asked.first?.message ?? "")
            AppTests.check(stage.asked.first?.message.contains(Wording.copiesNote) == true, "the note about copies is missing")
            AppTests.check(stage.toldCopies)
            stage.flows().encrypt([plain])
            AppTests.check(stage.asked.last?.message.contains("synced") == false, stage.asked.last?.message ?? "")
            AppTests.check(stage.asked.last?.message.contains("SSD") == false, "the note about copies came twice")
            AppTests.equal(stage.encrypted.map(\.path), [synced.path, plain.path])
            // told only when the user went on
            let cancelled = RouterStage()
            cancelled.answers = [nil]
            cancelled.flows().encrypt([cancelled.file("/tmp/safetest/a.txt")])
            AppTests.check(!cancelled.toldCopies, "told after Cancel")
        },

        AppTests.Case("a wrong password for a type with fixed first bytes is called probably wrong") {
            // finding of review round 3: a PDF that does not start with %PDF- got the softer
            // question with Export... first, about 1 in 70 mistypes
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/report.pdf.crypt", password: "p", kind: .other,
                                  data: Data((0 ..< 300).map { UInt8(($0 * 151 + 7) & 0xFF) }), check: .contentMismatch)
            stage.answers = ["p", nil]
            stage.choices = [0]        // Type It Again
            stage.flows().open([url])
            AppTests.equal(stage.questions.map(\.title), ["The password is probably not right"])
            AppTests.equal(stage.questions.first?.buttons, ["Type It Again", "Export Anyway...", "Cancel"])
            AppTests.equal(stage.asked.count, 2)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.exported.count, 0)
            // a picture may be in a format Safe does not know: the softer question stays
            let picture = RouterStage()
            let png = picture.crypt("/tmp/safetest/odd.png.crypt", password: "p", kind: .other,
                                    data: Data([1, 2, 3]), check: .contentMismatch)
            picture.answers = ["p"]
            picture.flows().open([png])
            AppTests.equal(picture.questions.map(\.title), ["Safe could not confirm the password"])
        },

        AppTests.Case("encrypt warns that a file in a volume keeps its plain copy in the image") {
            // finding of review round 3 (R4): the deleted original stays readable in the image
            let stage = RouterStage()
            stage.mountPoints = [URL(fileURLWithPath: "/tmp/safetest-volume")]
            let inside = stage.file("/tmp/safetest-volume/notes/secret.txt")
            let outside = stage.file("/tmp/safetest/other.txt")
            stage.answers = ["pw", nil]
            stage.flows().encrypt([inside])
            AppTests.check(stage.asked.first?.message.contains(Wording.inVolumeNote) == true,
                           stage.asked.first?.message ?? "")
            stage.flows().encrypt([outside])
            AppTests.check(stage.asked.last?.message.contains("volume") == false, stage.asked.last?.message ?? "")
            AppTests.equal(stage.encrypted.map(\.path), [inside.path])
        },

        AppTests.Case("encrypt refuses a file with other names (hard links)") {
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/linked.txt")
            stage.links[url.path] = 2
            let outcomes = stage.flows().encrypt([url])
            AppTests.equal(stage.asked.count, 0)
            AppTests.equal(stage.encrypted.count, 0)
            if case .skipped(let reason)? = outcomes.first {
                AppTests.check(reason.contains("hard links"), reason)
            } else {
                AppTests.check(false, "\(outcomes)")
            }
        },

        AppTests.Case("with the real CryptFile: a damaged file and an old RC4 file are exported, not shown") {
            try AppTests.runChild("router-real-damaged")
        },

        AppTests.Case("with the real CryptFile: cut files and an RC4 file that AES opens by chance are exported") {
            try AppTests.runChild("router-real-round4")
        },

        AppTests.Case("an unencrypted disk image is encrypted like any file") {
            let stage = RouterStage()
            let dmg = stage.file("/tmp/safetest/installer.dmg")
            stage.answers = ["pw"]
            let outcomes = stage.flows().encrypt([dmg])
            AppTests.equal(outcomes, [.encrypted(URL(fileURLWithPath: dmg.path + ".crypt"))])
            AppTests.equal(stage.told.count, 0)
        },

        AppTests.Case("other files whose password Safe could not confirm can be exported anyway") {
            let stage = RouterStage()
            let docx = stage.crypt("/tmp/safetest/report.docx.crypt", password: "p", kind: .other,
                                   data: Data([1, 2, 3]), check: .contentMismatch)
            let bin = stage.crypt("/tmp/safetest/data.bin.crypt", password: "p", kind: .other,
                                  data: Data([4, 5]), check: .unchecked)
            stage.answers = ["p", "p"]
            stage.choices = [1, 0]     // Export Anyway..., then Export...
            let flows = stage.flows()
            flows.open([docx])
            flows.export([bin])
            // finding of review round 3: a Word document always starts as a ZIP does, so
            // anything else is nearly always a wrong password
            AppTests.equal(stage.questions.map(\.title), ["The password is probably not right",
                                                          "Safe could not confirm the password"])
            AppTests.equal(stage.questions.map(\.buttons), [["Type It Again", "Export Anyway...", "Cancel"],
                                                           ["Export...", "Type Another Password", "Cancel"]])
            AppTests.equal(stage.exported.map(\.data), [Data([1, 2, 3]), Data([4, 5])])
            AppTests.equal(stage.exported.map(\.note), [Wording.uncheckedNote, Wording.uncheckedNote])
            AppTests.equal(stage.saved.count, 0)
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("Export with Safe offers export, not the read-only editor, for an unconfirmed text") {
            let stage = RouterStage()
            var utf16 = Data([0xFF, 0xFE])
            for unit in "Name;Wert\r\nÄpfel;3\r\nBirnen;5\r\n".utf16 {
                utf16.append(UInt8(unit & 0xFF))
                utf16.append(UInt8(unit >> 8))
            }
            let url = stage.crypt("/tmp/safetest/table.csv.crypt", password: "p", kind: .other,
                                  data: utf16, check: .contentMismatch)
            stage.answers = ["p"]
            stage.choices = [0]
            stage.flows().export([url])
            AppTests.equal(stage.questions.first?.buttons, ["Export...", "Type Another Password", "Cancel"])
            AppTests.equal(stage.exported.first?.data, utf16)
            AppTests.equal(stage.windows.count, 0)
        },

        AppTests.Case("a picture whose password Safe could not confirm can be viewed anyway") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/scan.crypt", password: "p", kind: .image,
                                  data: Data([0xFF, 0xD8, 0xFF, 0xE0]), check: .unchecked)
            stage.answers = ["p"]
            stage.choices = [0]
            stage.flows().open([url])
            AppTests.equal(stage.questions.first?.buttons, ["Open", "Type Another Password", "Cancel"])
            AppTests.equal(stage.windows.map(\.kind), ["viewer"])
        },

        AppTests.Case("a UTF-8 text with a byte order mark keeps it for saving") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/bom.txt.crypt", password: "p", kind: .text,
                                  data: Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8))
            stage.answers = ["p"]
            stage.flows().open([url])
            AppTests.equal(stage.windows.first?.text, "hi\n")
            AppTests.equal(stage.windows.first?.coding, .utf8WithBOM)
            AppTests.equal(stage.windows.first?.readOnlyNote, nil)
        },

        AppTests.Case("encrypt refuses encrypted disk images and files too large for memory") {
            let stage = RouterStage()
            let dmg = stage.file("/tmp/safetest/old.dmg")
            stage.encryptedImages = [dmg.path]
            let bundle = URL(fileURLWithPath: "/tmp/safetest/vol.sparsebundle")
            stage.states[bundle.path] = .folder
            let big = stage.file("/tmp/safetest/movie.mov")
            stage.sizes[big.path] = CryptFile.largestFileToEncrypt + 1
            let outcomes = stage.flows().encrypt([dmg, bundle, big])
            AppTests.equal(stage.asked.count, 0, "asked for a password with nothing to encrypt")
            AppTests.equal(stage.encrypted.count, 0)
            AppTests.equal(outcomes.count, 3)
            let message = stage.told.first?.message ?? ""
            AppTests.check(message.contains("“old.dmg”: It is an encrypted disk image") && message.contains("Add Existing"),
                           message)
            AppTests.check(message.contains("“vol.sparsebundle”: It is an encrypted disk image"), message)
            AppTests.check(message.contains("“movie.mov”: It is larger than") && message.contains("volume"), message)
        },

        AppTests.Case("open keeps a window until it closes, and brings it forward when opened again") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/a.txt.crypt", password: "p", kind: .text)
            stage.answers = ["p", "p"]
            let flows = stage.flows()
            flows.open([url])
            weak var window = stage.windows.first
            AppTests.equal(flows.windows.count, 1)
            flows.open([URL(fileURLWithPath: "/tmp/safetest/./a.txt.crypt")])
            AppTests.equal(stage.windows.count, 1, "opened twice")
            AppTests.equal(stage.asked.count, 1, "asked the password again")
            AppTests.equal(window?.fronted, 1)
            window?.onClose?()
            AppTests.equal(flows.windows.count, 0)
            stage.windows = []
            stage.registered = []
            AppTests.check(window == nil, "the window is still kept after onClose")
        },

        AppTests.Case("open reports errors other than a wrong password without asking again") {
            let stage = RouterStage()
            let url = stage.file("/tmp/safetest/plain.txt.crypt")
            stage.openErrors[url.path] = CryptError.notEncrypted
            stage.answers = ["p", "p"]
            stage.flows().open([url, URL(fileURLWithPath: "/tmp/safetest/missing.crypt")])
            AppTests.equal(stage.asked.count, 1)
            AppTests.equal(stage.told.count, 2)
            AppTests.check(stage.told.last?.message.contains("not there") == true)
            AppTests.equal(stage.leakedPasswords, 0)
        },

        AppTests.Case("export decrypts and hands the original to the export dialog") {
            let stage = RouterStage()
            let url = stage.crypt("/tmp/safetest/r.pdf.crypt", password: "p", kind: .pdf, data: Data("%PDF-1".utf8))
            stage.answers = ["x", "p"]
            stage.flows().export([url])
            AppTests.equal(stage.asked.map(\.title), ["Export “r.pdf.crypt”", "Export “r.pdf.crypt”"])
            AppTests.equal(stage.exported.count, 1)
            AppTests.equal(stage.exported.first?.data, Data("%PDF-1".utf8))
            AppTests.equal(stage.exported.first?.name, "r.pdf")
            AppTests.equal(stage.windows.count, 0)
            AppTests.equal(stage.leakedPasswords, 0)
        },
    ]

    /// Run in a child process by the first two tests: the real CryptFile with
    /// stand-in dialogs and windows, on throwaway files.
    static let children: [String: () throws -> Void] = [
        "router-real-files": {
            try AppTests.withTemporaryFolder { dir in
                let fm = FileManager.default
                let file = dir.appendingPathComponent("safetest-note.txt")
                let text = "safetest marker \(UUID().uuidString)\n"
                try Data(text.utf8).write(to: file)
                var answers = ["safetest-pw", "safetest-wrong", "safetest-pw", "safetest-pw"]
                var told: [String] = []
                var shown: [String] = []
                var windows: [StandInWindow] = []
                var env = DocumentRouter.environment()
                env.askOnce = { _, _ in answers.isEmpty ? nil : SecureBytes(string: answers.removeFirst()) }
                env.askTwice = env.askOnce
                env.inform = { title, message in told.append(title + ": " + message) }
                env.choose = { _, _, buttons in buttons.count - 1 }
                env.writeRefusal = { nil }
                env.showEditor = { _, text, password in
                    shown.append(text.text)
                    windows.append(StandInWindow(password: password))
                    return windows.last!
                }
                env.showViewer = { _, _, password in
                    windows.append(StandInWindow(password: password))
                    return windows.last!
                }
                env.exportData = { data, name, _, _ in
                    try? CryptFile.export(data, to: dir.appendingPathComponent("exported-" + name))
                }
                env.register = { _ in }
                env.runWork = { _, work in try work() }
                let flows = RouterFlows(environment: env)

                let crypt = URL(fileURLWithPath: file.path + ".crypt")
                AppTests.equal(flows.encrypt([file]), [.encrypted(crypt)])
                AppTests.check(!fm.fileExists(atPath: file.path), "the original is still there")
                AppTests.check(fm.fileExists(atPath: crypt.path), "no .crypt file")
                AppTests.equal(told, [])
                // a wrong password that Safe refuses for this file's random salt (about 1
                // in 256 would be "could not confirm" instead, rightly, and ask otherwise)
                AppTests.equal(answers.first, "safetest-wrong")
                answers[0] = AppTests.refusedPassword(for: crypt, near: "safetest-wrong")
                flows.open([crypt])
                AppTests.equal(shown, [text], "told: \(told)")
                AppTests.equal(windows.count, 1)
                windows.forEach { $0.close() }
                AppTests.equal(flows.windows.count, 0)
                flows.export([crypt])
                let exported = dir.appendingPathComponent("exported-safetest-note.txt")
                AppTests.equal(try? Data(contentsOf: exported), Data(text.utf8))
                AppTests.equal(answers, [])
                let names = try fm.contentsOfDirectory(atPath: dir.path).sorted()
                AppTests.equal(names, ["exported-safetest-note.txt", "safetest-note.txt.crypt"])
            }
        },

        "router-real-legacy": {
            try AppTests.withTemporaryFolder { dir in
                // finding of review round 2: "The password was not right" for the right one
                let latin1 = Data(RouterTests.latin1Text.unicodeScalars.map { UInt8($0.value) })
                let crypt = dir.appendingPathComponent("safetest-old.txt.crypt")
                try EditorTests.openssl(latin1, options: ["-aes-256-cbc", "-md", "md5"], password: "safetest-pw")
                    .write(to: crypt)
                var answers = ["safetest-pw"]
                var questions: [String] = []
                var notes: [String?] = []
                var shown: [String] = []
                var windows: [StandInWindow] = []
                var env = DocumentRouter.environment()
                env.askOnce = { _, _ in answers.isEmpty ? nil : SecureBytes(string: answers.removeFirst()) }
                env.inform = { title, _ in questions.append(title) }
                env.choose = { title, _, _ in
                    questions.append(title)
                    return 0
                }
                env.writeRefusal = { nil }
                env.showEditor = { _, text, password in
                    shown.append(text.text)
                    notes.append(text.readOnlyNote)
                    windows.append(StandInWindow(password: password))
                    return windows.last!
                }
                env.register = { _ in }
                env.runWork = { _, work in try work() }
                RouterFlows(environment: env).open([crypt])
                AppTests.equal(questions, ["Safe could not confirm the password"])
                AppTests.equal(shown, [RouterTests.latin1Text])
                AppTests.check(notes.first??.contains("ISO Latin-1") == true, "\(notes)")
                windows.forEach { $0.close() }
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                AppTests.equal(names, ["safetest-old.txt.crypt"])
            }
        },

        "router-real-damaged": {
            try AppTests.withTemporaryFolder { dir in
                var text = "safetest damaged start\n"
                while text.utf8.count < 9000 {
                    text += "Grüße, Zeile \(text.utf8.count)\n"
                }
                let password = SecureBytes(string: "safetest-pw")
                let whole = try OpenSSLFormat.encrypt(Data(text.utf8), password: password)
                let cut = dir.appendingPathComponent("safetest-cut.txt.crypt")
                try whole.prefix(4096).write(to: cut)
                // an RC4 file of a type Safe cannot check, whole blocks
                let bin = dir.appendingPathComponent("safetest-keys.bin.crypt")
                let binary = Data((0 ..< 4080).map { UInt8(($0 * 7 + 3) & 0xFF) })
                try EditorTests.openssl(binary, options: ["-rc4", "-md", "md5", "-S", "0011223344556677"],
                                        password: "safetest-pw").write(to: bin)

                var answers = ["safetest-pw", "safetest-pw", "safetest-pw"]
                var choices = [0, 2, 0]   // Export Readable Part; Export as an Old RC4 File; MD5
                var questions: [String] = []
                var exported: [(name: String, data: Data, note: String?)] = []
                var env = DocumentRouter.environment()
                env.askOnce = { _, _ in answers.isEmpty ? nil : SecureBytes(string: answers.removeFirst()) }
                env.inform = { title, message in questions.append(title + ": " + message) }
                env.choose = { title, _, _ in
                    questions.append(title)
                    return choices.isEmpty ? 2 : choices.removeFirst()
                }
                env.showEditor = { _, _, _ in
                    AppTests.check(false, "an editor was shown")
                    return StandInWindow(password: SecureBytes(string: ""))
                }
                env.showViewer = { _, _, _ in
                    AppTests.check(false, "a viewer was shown")
                    return StandInWindow(password: SecureBytes(string: ""))
                }
                env.exportData = { data, name, _, note in exported.append((name, data, note)) }
                env.register = { _ in }
                env.runWork = { _, work in try work() }
                let flows = RouterFlows(environment: env)
                flows.open([cut])
                flows.open([bin])
                AppTests.equal(questions, ["“safetest-cut.txt.crypt” is damaged", "The password was not right",
                                           "How was “safetest-keys.bin.crypt” written?"])
                AppTests.equal(exported.map(\.name), ["safetest-cut.txt", "safetest-keys.bin"])
                AppTests.equal(exported.first?.data, Data(text.utf8).prefix(4096 - 32))
                AppTests.equal(exported.last?.data, binary)
                AppTests.equal(exported.map(\.note), [Wording.damagedNote, Wording.uncheckedNote])
                AppTests.equal(answers, [])
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                AppTests.equal(names, ["safetest-cut.txt.crypt", "safetest-keys.bin.crypt"])
            }
        },

        "router-real-round4": {
            // findings of review round 4, with fixed salts so that the outcome is the same
            // every time
            try AppTests.withTemporaryFolder { dir in
                let current = ["-aes-256-cbc", "-md", "sha512", "-pbkdf2", "-iter", "100000", "-S", "0011223344556677"]
                // 1. a cut .kdbx, whose start Safe cannot recognise: refused twice, then
                // Export Readable Part, unchecked
                let vault = Data(Array("KeePass".utf8)) + Data((0 ..< 10_000).map { UInt8(($0 * 13 + 5) & 0xFF) })
                let kdbx = dir.appendingPathComponent("safetest-vault.kdbx.crypt")
                try EditorTests.openssl(vault, options: current, password: "safetest-pw").prefix(4096).write(to: kdbx)
                // 2. the reviewer's RC4 file: AES with a SHA-256 key passes its padding check
                let pattern = Data((0 ..< 4096).map { UInt8(($0 * 7 + 3) & 0xFF) })
                let bin = dir.appendingPathComponent("safetest-data.bin.crypt")
                try EditorTests.openssl(pattern, options: ["-rc4", "-md", "md5", "-S", "0000000000000003"],
                                        password: "unknown-type").write(to: bin)
                // 3. a text cut inside a block: damaged, not a wrong password
                var text = "safetest cut text\n"
                while text.utf8.count < 6000 {
                    text += "Grüße, Zeile \(text.utf8.count)\n"
                }
                let notes = dir.appendingPathComponent("safetest-notes.txt.crypt")
                let whole = try EditorTests.openssl(Data(text.utf8), options: current, password: "safetest-pw")
                try whole.prefix(whole.count - 7).write(to: notes)

                var answers = ["safetest-pw", "safetest-pw", "unknown-type", "safetest-pw"]
                // Export Readable Part; Other Readings, crypt.sh before 1.4; Export Readable Part
                var choices = [1, 1, 1, 0]
                var questions: [String] = []
                var exported: [(name: String, data: Data, note: String?)] = []
                var env = DocumentRouter.environment()
                env.askOnce = { _, _ in answers.isEmpty ? nil : SecureBytes(string: answers.removeFirst()) }
                env.inform = { title, message in questions.append(title + ": " + message) }
                env.choose = { title, _, _ in
                    questions.append(title)
                    return choices.isEmpty ? 3 : choices.removeFirst()
                }
                env.showEditor = { _, _, _ in
                    AppTests.check(false, "an editor was shown")
                    return StandInWindow(password: SecureBytes(string: ""))
                }
                env.showViewer = { _, _, _ in
                    AppTests.check(false, "a viewer was shown")
                    return StandInWindow(password: SecureBytes(string: ""))
                }
                env.exportData = { data, name, _, note in exported.append((name, data, note)) }
                env.register = { _ in }
                env.runWork = { _, work in try work() }
                let flows = RouterFlows(environment: env)
                flows.open([kdbx, bin, notes])
                AppTests.equal(questions, ["The password was not right", "Is this the right password?",
                                           "How was “safetest-data.bin.crypt” written?",
                                           "“safetest-notes.txt.crypt” is damaged"])
                AppTests.equal(exported.map(\.name), ["safetest-vault.kdbx", "safetest-data.bin", "safetest-notes.txt"])
                AppTests.check(exported.first?.data == vault.prefix(4096 - 32), "not the start of the .kdbx")
                AppTests.check(exported.count > 1 && exported[1].data == pattern, "not the RC4 content")
                let body = whole.count - 7 - 16
                AppTests.check(exported.last?.data == Data(text.utf8).prefix(body / 16 * 16 - 16), "not the start of the text")
                AppTests.equal(exported.map(\.note), [Wording.uncheckedPartNote, Wording.uncheckedNote, Wording.damagedNote])
                AppTests.equal(answers, [])
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                AppTests.equal(names, ["safetest-data.bin.crypt", "safetest-notes.txt.crypt", "safetest-vault.kdbx.crypt"])
            }
        },

        "router-real-refused": {
            try AppTests.withTemporaryFolder { dir in
                let file = dir.appendingPathComponent("safetest-note.txt")
                try Data("safetest\n".utf8).write(to: file)
                var env = DocumentRouter.environment()
                env.askTwice = { _, _ in SecureBytes(string: "safetest-pw") }
                env.inform = { _, _ in }
                env.writeRefusal = { SelfTestGate.refusal(["safetest failure"]) }
                env.runWork = { _, work in try work() }
                _ = RouterFlows(environment: env).encrypt([file])
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
                AppTests.equal(names, ["safetest-note.txt"])
            }
        },
    ]
}
#endif
