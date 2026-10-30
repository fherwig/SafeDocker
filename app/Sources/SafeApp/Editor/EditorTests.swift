#if DEBUG
import AppKit
import PDFKit
import SafeCore

// The editor and viewer windows of WP3, built off the screen over real files
// in a throwaway folder: saving with the kept password, the choices on a
// conflict, locking and unlocking, closing. Alerts, beeps and password dialogs
// go through the hooks of DocumentAlerts, so no window or dialog is ever put
// on the screen.

/// Tests of the editor and the viewer windows, for `Safe --app-tests`.
/// Something to lock that does nothing, for the test of the idle check.
final class SafetestLockItem: Lockable {
    func lock() {}
}

enum EditorTests {
    static let cases: [AppTests.Case] = [
        AppTests.Case("the editor saves with the password that opened the file and keeps .bak") {
            try withEditor { dir, crypt, editor, log in
                let before = try Data(contentsOf: crypt)
                type("safetest second\n", into: editor)
                AppTests.check(editor.hasUnsavedChanges, "typing did not mark the text as changed")
                AppTests.check(editor.save(), "not saved: \(log.titles)")
                AppTests.check(!editor.hasUnsavedChanges)
                AppTests.equal(try decrypt(crypt), "safetest first.\nsafetest second\n")
                AppTests.equal(try Data(contentsOf: URL(fileURLWithPath: crypt.path + ".bak")), before)
                AppTests.check(editor.statusText.contains("Saved"), editor.statusText)
                AppTests.check(editor.statusText.contains(crypt.lastPathComponent + ".bak"), editor.statusText)
                AppTests.equal(try names(in: dir), [crypt.lastPathComponent, crypt.lastPathComponent + ".bak"])
                AppTests.equal(log.titles, [])
            }
        },

        AppTests.Case("a conflict keeps my version as a separate encrypted copy") {
            try withEditor { dir, crypt, editor, log in
                try changeOnDisk(crypt, to: "safetest other.\n")
                type("safetest mine\n", into: editor)
                log.answers = [.alertFirstButtonReturn]
                AppTests.check(!editor.save(), "saved over a file that changed on disk")
                AppTests.equal(log.titles, ["\(crypt.lastPathComponent) changed on disk"])
                AppTests.equal(try decrypt(crypt), "safetest other.\n")
                let copies = try names(in: dir).filter { $0.contains("(conflict ") }
                AppTests.equal(copies.count, 1)
                if let copy = copies.first {
                    AppTests.check(copy.hasPrefix("safetest-note (conflict ") && copy.hasSuffix(").txt.crypt"), copy)
                    AppTests.equal(try decrypt(dir.appendingPathComponent(copy)), "safetest first.\nsafetest mine\n")
                }
                AppTests.check(!editor.hasUnsavedChanges)
            }
        },

        AppTests.Case("a conflict can discard my changes and load the file as it is now") {
            try withEditor { dir, crypt, editor, log in
                try changeOnDisk(crypt, to: "safetest other.\n")
                type("safetest mine\n", into: editor)
                log.answers = [.alertSecondButtonReturn]
                AppTests.check(!editor.save(), "saved over a file that changed on disk")
                AppTests.equal(editor.textView.string, "safetest other.\n")
                AppTests.check(!editor.hasUnsavedChanges)
                type("safetest third\n", into: editor)
                AppTests.check(editor.save(), "not saved: \(log.titles)")
                AppTests.equal(try decrypt(crypt), "safetest other.\nsafetest third\n")
                AppTests.equal(try names(in: dir).filter { $0.contains("conflict") }, [])
            }
        },

        AppTests.Case("a changed editor is covered on lock and shows its text only with its password") {
            try withEditor { _, crypt, editor, log in
                type("safetest unsaved\n", into: editor)
                editor.lock()
                AppTests.check(editor.isLocked, "not locked")
                AppTests.check(!editor.isClosed, "closed although it has unsaved changes")
                AppTests.check(!editor.textView.isEditable && !editor.textView.isSelectable)
                AppTests.check(editor.textView.enclosingScrollView?.isHidden == true, "the text is still shown")
                AppTests.check(editor.statusText.hasPrefix("Locked."), editor.statusText)
                type("safetest typed while locked\n", into: editor)
                AppTests.check(!editor.textView.string.contains("while locked"), "typing changed a locked editor")
                AppTests.check(!editor.save(), "saved while locked")
                AppTests.equal(try decrypt(crypt), "safetest first.\n")

                log.passwords = ["safetest-wrong"]
                AppTests.check(!editor.unlock(), "a wrong password showed the text")
                AppTests.check(editor.isLocked)
                AppTests.equal(log.titles, ["Wrong password"])
                log.passwords = [password]
                AppTests.check(editor.unlock(), "the right password did not show the text")
                AppTests.check(!editor.isLocked && editor.textView.isEditable)
                AppTests.check(editor.textView.enclosingScrollView?.isHidden == false)
                AppTests.check(editor.hasUnsavedChanges, "the changes were lost")
                AppTests.equal(editor.textView.string, "safetest first.\nsafetest unsaved\n")
            }
        },

        AppTests.Case("an unchanged editor closes on lock and forgets its text") {
            try withEditor { _, _, editor, _ in
                var closed = false
                editor.onClose = { closed = true }
                editor.lock()
                AppTests.check(editor.isClosed, "not closed on lock")
                AppTests.check(closed, "onClose was not called")
                AppTests.equal(editor.textView.string, "")
            }
        },

        AppTests.Case("the viewer shows a picture from memory and closes on lock") {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                       colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            guard let png = rep?.representation(using: .png, properties: [:]) else {
                AppTests.check(false, "cannot make a PNG")
                return
            }
            try withViewer(of: png, named: "safetest-picture.png", kind: .image) { viewer in
                AppTests.check(viewer.imageView?.image != nil, "no image")
                AppTests.check(viewer.pdfView == nil)
            }
        },

        AppTests.Case("the viewer shows a PDF from memory and closes on lock") {
            let image = NSImage(size: NSSize(width: 72, height: 72))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 8, y: 8, width: 56, height: 56).fill()
            image.unlockFocus()
            let document = PDFDocument()
            guard let page = PDFPage(image: image) else {
                AppTests.check(false, "cannot make a PDF page")
                return
            }
            document.insert(page, at: 0)
            guard let pdf = document.dataRepresentation() else {
                AppTests.check(false, "cannot make a PDF")
                return
            }
            try withViewer(of: pdf, named: "safetest-document.pdf", kind: .pdf) { viewer in
                AppTests.equal(viewer.pdfView?.document?.pageCount, 1)
                AppTests.check(viewer.imageView == nil)
                // finding of review round 4: no data detectors, no Live Text over the pages
                AppTests.equal(viewer.pdfView?.analysisSetting("enableDataDetectors"), false)
                if let analysis = viewer.pdfView?.analysisSetting("documentAnalysisEnabled") {
                    AppTests.equal(analysis, false, "document analysis is on")
                }
                // the selection is handed out only by Copy, never through the Services way
                let pasteboard = NSPasteboard.withUniqueName()
                defer { pasteboard.releaseGlobally() }
                viewer.pdfView?.selectAll(nil)
                AppTests.check(viewer.pdfView?.writeSelection(to: pasteboard, types: [.string]) == false,
                               "the selection was written out")
                AppTests.equal(pasteboard.string(forType: .string), nil)
            }
        },

        AppTests.Case("closing a changed editor asks Save, Don't Save or Cancel, and wipes the password") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let crypt = try encrypt("safetest first.\n", as: "safetest-close.txt", in: dir)
                let log = AlertLog()
                try withHooks(log) {
                    for (answer, saved) in [(NSApplication.ModalResponse.alertThirdButtonReturn, false),
                                            (.alertSecondButtonReturn, false), (.alertFirstButtonReturn, true)] {
                        let kept = SecureBytes(string: password)
                        let (opened, plain) = try CryptFile.open(at: crypt, password: kept, allowLegacy: false)
                        let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                            password: kept)
                        defer { editor.window?.close() }
                        type("safetest change\n", into: editor)
                        log.titles = []
                        log.answers = [answer]
                        AppTests.check(editor.window.map { editor.windowShouldClose($0) } == false,
                                       "closed without asking")
                        AppTests.equal(log.titles, ["Do you want to save the changes to safetest-close.txt?"])
                        let cancelled = answer == .alertThirdButtonReturn
                        AppTests.equal(editor.isClosed, !cancelled, "answer \(answer.rawValue)")
                        AppTests.equal(kept.count == 0, !cancelled, "the password after answer \(answer.rawValue)")
                        if !cancelled {
                            AppTests.equal(editor.textView.string, "", "the text is still in the closed editor")
                        }
                        AppTests.equal(try decrypt(crypt).hasSuffix("safetest change\n"), saved)
                    }
                }
            }
        },

        AppTests.Case("saving is refused while the self-test has not passed") {
            try withEditor { _, crypt, editor, log in
                DocumentAlerts.saveRefusal = { "safetest refusal" }
                type("safetest refused\n", into: editor)
                AppTests.check(!editor.save(), "saved although the self-test failed")
                AppTests.equal(log.titles, ["safetest-note.txt was not saved"])
                AppTests.equal(log.messages, ["safetest refusal"])
                AppTests.equal(try decrypt(crypt), "safetest first.\n")
                AppTests.check(editor.hasUnsavedChanges)
            }
        },

        AppTests.Case("export warns that the copy is not encrypted before it writes") {
            try withEditor { dir, crypt, editor, log in
                let target = dir.appendingPathComponent("exported.txt")
                var proposed: (URL, String)?
                let choose = ExportController.choosePlace
                defer { ExportController.choosePlace = choose }
                ExportController.choosePlace = { folder, name, _, done in
                    proposed = (folder, name)
                    done(target)
                }
                log.answers = [.alertSecondButtonReturn]       // Cancel at the warning
                editor.exportDecryptedCopy(nil)
                AppTests.equal(proposed?.0.standardizedFileURL.path, dir.standardizedFileURL.path)
                AppTests.equal(proposed?.1, "safetest-note.txt")
                AppTests.equal(log.titles, ["The exported copy is not encrypted."])
                AppTests.check(!FileManager.default.fileExists(atPath: target.path), "written although cancelled")
                editor.exportDecryptedCopy(nil)                // Export at the warning
                AppTests.equal(try Data(contentsOf: target), Data("safetest first.\n".utf8))
                ExportController.choosePlace = { _, _, _, done in done(crypt) }
                log.titles = []
                editor.exportDecryptedCopy(nil)
                AppTests.equal(log.titles, ["Not exported"], "the encrypted file itself was offered")
            }
        },

        AppTests.Case("the clipboard holds copies for this Mac only, marked, and is cleared only if still ours") {
            let pasteboard = NSPasteboard.withUniqueName()
            let general = ClipboardGuard.pasteboard, delay = ClipboardGuard.clearDelay
            defer {
                ClipboardGuard.clearIfOurs()
                ClipboardGuard.pasteboard = general
                ClipboardGuard.clearDelay = delay
                pasteboard.releaseGlobally()
            }
            ClipboardGuard.pasteboard = pasteboard
            ClipboardGuard.copy("safetest secret")
            AppTests.equal(pasteboard.string(forType: .string), "safetest secret")
            let types = pasteboard.types?.map(\.rawValue) ?? []
            AppTests.check(types.contains(ClipboardPolicy.concealedType) && types.contains(ClipboardPolicy.transientType),
                           "\(types)")
            ClipboardGuard.clearIfOurs()
            AppTests.equal(pasteboard.string(forType: .string), nil)

            ClipboardGuard.copy("safetest secret")
            pasteboard.clearContents()
            pasteboard.setString("someone else's", forType: .string)
            ClipboardGuard.clearIfOurs()
            AppTests.equal(pasteboard.string(forType: .string), "someone else's", "cleared another app's text")

            ClipboardGuard.clearDelay = 0.05
            ClipboardGuard.copy("safetest secret")
            let deadline = Date().addingTimeInterval(3)
            while pasteboard.string(forType: .string) != nil && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            AppTests.equal(pasteboard.string(forType: .string), nil, "not cleared after the delay")
        },

        AppTests.Case("the first copy asks first when macOS may keep a clipboard history") {
            // finding of review round 4: macOS 26 keeps a clipboard history in Spotlight,
            // which ClipboardGuard cannot clear
            let pasteboard = NSPasteboard.withUniqueName()
            let general = ClipboardGuard.pasteboard, watched = ClipboardGuard.watchedByHistory
            let historyOn = ClipboardGuard.historyMayBeOn, confirm = ClipboardGuard.confirmDespiteHistory
            defer {
                ClipboardGuard.clearIfOurs()
                ClipboardGuard.pasteboard = general
                ClipboardGuard.watchedByHistory = watched
                ClipboardGuard.historyMayBeOn = historyOn
                ClipboardGuard.confirmDespiteHistory = confirm
                ClipboardGuard.resetHistoryAnswer()
                pasteboard.releaseGlobally()
            }
            ClipboardGuard.pasteboard = pasteboard
            var asked = 0, answer = false
            ClipboardGuard.watchedByHistory = { true }
            ClipboardGuard.historyMayBeOn = { true }
            ClipboardGuard.confirmDespiteHistory = {
                asked += 1
                return answer
            }
            ClipboardGuard.resetHistoryAnswer()
            AppTests.check(!ClipboardGuard.copy("safetest secret"), "copied after Cancel")
            AppTests.equal(pasteboard.string(forType: .string), nil)
            answer = true
            AppTests.check(ClipboardGuard.copy("safetest secret"))
            AppTests.equal(pasteboard.string(forType: .string), "safetest secret")
            AppTests.check(ClipboardGuard.copy("safetest again"))
            AppTests.equal(asked, 2, "asked again after the user agreed")
            // not asked when the history is off, nor for a pasteboard it does not watch
            ClipboardGuard.resetHistoryAnswer()
            ClipboardGuard.historyMayBeOn = { false }
            AppTests.check(ClipboardGuard.copy("safetest secret"))
            ClipboardGuard.historyMayBeOn = { true }
            ClipboardGuard.watchedByHistory = watched
            AppTests.check(ClipboardGuard.copy("safetest secret"))
            AppTests.equal(asked, 2)
        },

        AppTests.Case("the idle check is not held back while something decrypted or a volume is open") {
            // finding of review round 4: App Nap could delay the 30 s timer, and a stretch
            // that ended between two checks never locked
            let lock = LockController()
            var begun = 0, ended = 0, volumes = false
            lock.beginActivity = {
                begun += 1
                return NSObject()
            }
            lock.endActivity = { _ in ended += 1 }
            lock.hasOpenVolumes = { volumes }
            lock.idleSeconds = { 1 }
            lock.checkIdle()
            AppTests.equal(begun, 0, "held with nothing open")
            volumes = true
            lock.checkIdle()
            lock.checkIdle()
            AppTests.equal(begun, 1)
            AppTests.check(lock.isKeepingChecking)
            volumes = false
            lock.checkIdle()
            AppTests.equal(ended, 1)
            var item: SafetestLockItem? = SafetestLockItem()
            lock.register(item!)
            AppTests.equal(begun, 2, "not held for an editor or viewer")
            item = nil
            lock.checkIdle()
            AppTests.equal(ended, 2)
            AppTests.check(!lock.isKeepingChecking)
            // input that came back between two checks still locks
            var clock: TimeInterval = 100
            var idle: TimeInterval = 595
            lock.now = { clock }
            lock.idleSeconds = { idle }
            let before = lock.lockCount
            lock.checkIdle()
            clock += 10
            idle = 2
            lock.checkIdle()
            AppTests.equal(lock.lockCount, before + 1, "a stretch of 603 s did not lock")
        },

        AppTests.Case("the lock covers editors, closes viewers, runs its actions, clears the clipboard, and hears the user come back") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let pasteboard = NSPasteboard.withUniqueName()
            let general = ClipboardGuard.pasteboard
            defer {
                ClipboardGuard.pasteboard = general
                pasteboard.releaseGlobally()
            }
            ClipboardGuard.pasteboard = pasteboard
            try withEditor { dir, _, editor, _ in
                let png = try makePNG()
                let crypt = try encrypt(png, as: "safetest-lock.png", in: dir)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: false)
                let viewer = ViewerWindowController(opened: opened, data: plain, password: SecureBytes(string: password))
                defer { viewer.window?.close() }
                let lock = LockController()
                var actions = 0, back = 0
                lock.register(editor)
                lock.register(viewer)
                lock.addLockAction { actions += 1 }
                lock.onUserBack = { back += 1 }
                type("safetest unsaved\n", into: editor)
                ClipboardGuard.copy("safetest copied")

                var idle: TimeInterval = 5
                lock.idleSeconds = { idle }
                lock.checkIdle()
                AppTests.equal(actions, 0, "locked while the user was there")
                idle = LockPolicy.idleLimit + 1
                lock.checkIdle()
                AppTests.check(editor.isLocked && !editor.isClosed, "the changed editor is not covered")
                AppTests.check(viewer.isClosed, "the viewer is still open")
                AppTests.equal(actions, 1)
                AppTests.equal(pasteboard.string(forType: .string), nil, "the clipboard was not cleared")
                lock.checkIdle()
                AppTests.equal(actions, 1, "locked twice in one stretch without input")
                AppTests.equal(back, 0)
                idle = 3
                lock.checkIdle()
                AppTests.equal(back, 1, "the user's return after an idle lock went unnoticed")
                lock.checkIdle()
                AppTests.equal(back, 1, "the return was reported twice")
                lock.lockNow()
                lock.userIsBack()       // com.apple.screenIsUnlocked
                AppTests.equal(back, 2)
                AppTests.equal(actions, 2)
            }
        },

        AppTests.Case("text Safe could not confirm is read only until editing is allowed, and keeps its encoding") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let latin1 = Data("Gr\u{FC}\u{DF}e\n".unicodeScalars.map { UInt8($0.value) })
                let crypt = try encrypt(latin1, as: "safetest-latin1.txt", in: dir)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: true)
                AppTests.equal(opened.check, .contentMismatch)
                let (text, coding) = TextCoding.decodeAnyway(plain)
                AppTests.equal(text, "Grüße\n")
                let log = AlertLog()
                try withHooks(log) {
                    let editor = EditorWindowController(opened: opened, text: text, password: SecureBytes(string: password),
                                                        coding: coding, readOnlyNote: "safetest note")
                    defer { editor.window?.close() }
                    AppTests.check(editor.isReadOnly)
                    AppTests.equal(editor.readOnlyNote, "safetest note")
                    AppTests.check(!editor.textView.isEditable)
                    type("typed while read only\n", into: editor)
                    AppTests.equal(editor.textView.string, "Grüße\n")
                    let before = try Data(contentsOf: crypt)
                    AppTests.check(!editor.save(), "saved a read-only text")
                    AppTests.equal(try Data(contentsOf: crypt), before, "the file changed")
                    AppTests.check(editor.statusText.contains("ISO Latin-1"), editor.statusText)

                    editor.allowEditing()
                    AppTests.check(!editor.isReadOnly && editor.textView.isEditable)
                    AppTests.equal(editor.readOnlyNote, nil)
                    type("K\u{F6}ln\n", into: editor)
                    AppTests.check(editor.save(), "not saved: \(log.titles)")
                    AppTests.equal(try decryptData(crypt), latin1 + Data([0x4B, 0xF6, 0x6C, 0x6E, 0x0A]),
                                   "not written in ISO Latin-1")
                    AppTests.check(FileManager.default.fileExists(atPath: crypt.path + ".bak"))

                    type("5 €\n", into: editor)
                    log.titles = []
                    log.answers = [.alertFirstButtonReturn]     // Save as UTF-8
                    _ = editor.save()
                    AppTests.equal(log.titles, ["safetest-latin1.txt cannot be saved in ISO Latin-1"])
                    AppTests.equal(editor.textCoding, .utf8)
                    AppTests.equal(try decrypt(crypt), "Grüße\nKöln\n5 €\n")
                    AppTests.check(!editor.hasUnsavedChanges)
                }
            }
        },

        AppTests.Case("a UTF-8 byte order mark survives saving, conflict copies and export") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let bom = Data([0xEF, 0xBB, 0xBF])
                let crypt = try encrypt(bom + Data("safetest bom\n".utf8), as: "safetest-bom.txt", in: dir)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: false)
                AppTests.equal(opened.kind, .text)
                guard let (text, coding) = TextCoding.decodeUTF8(plain) else {
                    AppTests.check(false, "not UTF-8")
                    return
                }
                let log = AlertLog()
                try withHooks(log) {
                    let editor = EditorWindowController(opened: opened, text: text, password: SecureBytes(string: password),
                                                        coding: coding, readOnlyNote: nil)
                    defer { editor.window?.close() }
                    AppTests.equal(editor.textView.string, "safetest bom\n")
                    type("more\n", into: editor)
                    AppTests.check(editor.save())
                    AppTests.equal(try decryptData(crypt), bom + Data("safetest bom\nmore\n".utf8))

                    let target = dir.appendingPathComponent("exported.txt")
                    let choose = ExportController.choosePlace
                    defer { ExportController.choosePlace = choose }
                    ExportController.choosePlace = { _, _, _, done in done(target) }
                    editor.exportDecryptedCopy(nil)
                    AppTests.equal(try Data(contentsOf: target), bom + Data("safetest bom\nmore\n".utf8))

                    try changeOnDisk(crypt, to: "safetest other.\n")
                    type("mine\n", into: editor)
                    log.answers = [.alertFirstButtonReturn]     // Keep My Version as a Copy
                    AppTests.check(!editor.save())
                    let copies = try names(in: dir).filter { $0.contains("(conflict ") }
                    AppTests.equal(copies.count, 1)
                    if let copy = copies.first {
                        AppTests.equal(try decryptData(dir.appendingPathComponent(copy)),
                                       bom + Data("safetest bom\nmore\nmine\n".utf8))
                    }
                }
            }
        },

        AppTests.Case("saving after the file's volume was closed says so, not that the file changed") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let volume = dir.appendingPathComponent("safetest-volume")
                try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
                let crypt = try encrypt("safetest first.\n", as: "safetest-on-volume.txt", in: volume)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: false)
                let log = AlertLog()
                try withHooks(log) {
                    let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                        password: SecureBytes(string: password))
                    defer { editor.window?.close() }
                    type("safetest unsaved\n", into: editor)
                    // the volume closes: its folder is gone
                    try FileManager.default.moveItem(at: volume, to: dir.appendingPathComponent("safetest-elsewhere"))
                    AppTests.check(!editor.save())
                    AppTests.equal(log.titles, ["safetest-on-volume.txt was not saved"])
                    AppTests.check(log.messages.first?.contains("volume") == true, log.messages.first ?? "")
                    AppTests.check(editor.hasUnsavedChanges, "the changes were dropped")
                    try FileManager.default.moveItem(at: dir.appendingPathComponent("safetest-elsewhere"), to: volume)
                    log.titles = []
                    AppTests.check(editor.save(), "not saved after the volume came back: \(log.titles)")
                    AppTests.equal(try decrypt(crypt), "safetest first.\nsafetest unsaved\n")
                }
            }
        },

        AppTests.Case("a text Safe could not confirm is never saved without Allow Editing, and its first .bak stays") {
            // findings of review round 2: a short RC4 text accepted with Continue opened
            // editable, and two saves of garbage could replace the original and its .bak
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let crypt = dir.appendingPathComponent("safetest-short.txt.crypt")
                let original = try openssl(Data("pin 1234\n".utf8), options: ["-rc4", "-md", "md5", "-S", "0123456789abcdef"])
                try original.write(to: crypt)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: true)
                AppTests.equal(opened.variant, .legacyRC4MD5)
                AppTests.equal(opened.check, .unchecked)
                let backup = URL(fileURLWithPath: crypt.path + ".bak")
                let log = AlertLog()
                try withHooks(log) {
                    // as if a caller forgot the read-only note: the editor itself insists
                    let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                        password: SecureBytes(string: password))
                    defer { editor.window?.close() }
                    AppTests.check(editor.isReadOnly, "editable without Allow Editing")
                    AppTests.check(editor.readOnlyNote?.contains("could not confirm") == true, editor.readOnlyNote ?? "")
                    type("typed while read only\n", into: editor)
                    AppTests.check(!editor.save(), "Cmd-S saved a text whose password Safe could not confirm")
                    AppTests.equal(try Data(contentsOf: crypt), original, "the file changed")
                    AppTests.check(!FileManager.default.fileExists(atPath: backup.path))

                    editor.allowEditing()
                    type("5678\n", into: editor)
                    AppTests.check(editor.save(), "not saved after Allow Editing: \(log.titles)")
                    AppTests.equal(try Data(contentsOf: backup), original)
                    type("more\n", into: editor)
                    AppTests.check(editor.save())
                    AppTests.equal(try Data(contentsOf: backup), original, "the second save replaced the .bak")
                    AppTests.equal(try decrypt(crypt), "pin 1234\n5678\nmore\n")
                }
            }
        },

        AppTests.Case("export never replaces an encrypted file, and writes nothing after a lock") {
            // findings of review round 2
            try withEditor { dir, crypt, editor, log in
                let choose = ExportController.choosePlace, mounts = ExportController.volumeMountPoints
                let lockCount = ExportController.lockCount, presenter = DocumentAlerts.presenter
                var locks = 0
                defer {
                    ExportController.choosePlace = choose
                    ExportController.volumeMountPoints = mounts
                    ExportController.lockCount = lockCount
                    DocumentAlerts.presenter = presenter
                }
                ExportController.volumeMountPoints = { [] }
                ExportController.lockCount = { locks }
                let backup = URL(fileURLWithPath: crypt.path + ".bak")
                try FileManager.default.copyItem(at: crypt, to: backup)
                let link = dir.appendingPathComponent("safetest-same-file.txt")
                try FileManager.default.linkItem(at: crypt, to: link)
                let upper = dir.appendingPathComponent(crypt.lastPathComponent.uppercased())
                for target in [upper, backup, dir.appendingPathComponent("other.crypt"), link] {
                    log.titles = []
                    ExportController.choosePlace = { _, _, _, done in done(target) }
                    editor.exportDecryptedCopy(nil)
                    AppTests.equal(log.titles, ["Not exported"], target.lastPathComponent)
                }
                AppTests.equal(try decrypt(crypt), "safetest first.\n", "the encrypted file was replaced")
                try FileManager.default.removeItem(at: link)

                // Safe locks while the warning is open
                let target = dir.appendingPathComponent("exported.txt")
                ExportController.choosePlace = { _, _, _, done in done(target) }
                DocumentAlerts.presenter = { alert, window, done in
                    if alert.messageText == "The exported copy is not encrypted." {
                        locks += 1
                    }
                    presenter?(alert, window, done)
                }
                log.titles = []
                editor.exportDecryptedCopy(nil)
                AppTests.equal(log.titles, ["The exported copy is not encrypted.", "Not exported"])
                AppTests.check(!FileManager.default.fileExists(atPath: target.path), "written after a lock")
                DocumentAlerts.presenter = presenter

                // inside a volume: the Desktop is proposed, and the warning says why
                ExportController.volumeMountPoints = { [dir] }
                var proposed: URL?
                ExportController.choosePlace = { folder, _, _, done in
                    proposed = folder
                    done(target)
                }
                log.messages = []
                editor.exportDecryptedCopy(nil)
                AppTests.equal(proposed?.lastPathComponent, "Desktop")
                AppTests.check(log.messages.first?.contains("encrypted volume") == true, log.messages.first ?? "")
                AppTests.equal(try Data(contentsOf: target), Data("safetest first.\n".utf8))
            }
        },

        AppTests.Case("the viewer offers Save in Current Format only when Safe confirmed the password") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                // a PNG is checked by its first bytes; three bytes of JPEG are too few
                // for a name whose type Safe does not know
                for (name, picture, check, offers) in [("safetest-old.png", try makePNG(), PasswordCheck.confirmed, true),
                                                       ("safetest-old.raw", try makePNG(.jpeg), .unchecked, false)] {
                    let crypt = dir.appendingPathComponent(name + ".crypt")
                    try oldFormat(picture, password: password).write(to: crypt)
                    let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                             allowLegacy: true)
                    AppTests.equal(opened.variant, .legacyAESMD5, name)
                    AppTests.equal(opened.check, check, name)
                    AppTests.equal(opened.kind, .image, name)
                    withHooks(AlertLog()) {
                        let viewer = ViewerWindowController(opened: opened, data: plain,
                                                            password: SecureBytes(string: password))
                        defer { viewer.window?.close() }
                        AppTests.equal(viewer.offersSaveInCurrentFormat, offers, name)
                        if !offers {
                            AppTests.check(viewer.statusText.contains("could not confirm"), viewer.statusText)
                        }
                    }
                }
            }
        },

        AppTests.Case("Ctrl-K and the other delete-to commands keep nothing that Ctrl-Y could paste elsewhere") {
            // finding of review round 3: they put decrypted text into AppKit's kill ring,
            // which outlives the editor and the lock, and Ctrl-Y pasted it into any field
            guard OffScreen.available else { try AppTests.skip("no window server") }
            func killRing() -> String {
                let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
                view.doCommand(by: #selector(NSResponder.yank(_:)))
                return view.string
            }
            // a plain text view fills the kill ring, so the test can see it
            let plain = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
            plain.string = "safetest-plain-probe\nmore\n"
            plain.setSelectedRange(NSRange(location: 0, length: 0))
            plain.doCommand(by: #selector(NSResponder.deleteToEndOfParagraph(_:)))
            let ringWorks = killRing().contains("safetest-plain-probe")
            let deletes: [Selector] = [#selector(NSResponder.deleteToEndOfParagraph(_:)),
                                       #selector(NSResponder.deleteToEndOfLine(_:)),
                                       #selector(NSResponder.deleteToBeginningOfLine(_:)),
                                       #selector(NSResponder.deleteToBeginningOfParagraph(_:))]
            try withEditor { _, crypt, editor, log in
                let view = editor.textView
                for (n, command) in deletes.enumerated() {
                    let secret = "safetest-killring-SECRET-\(n)"
                    type(secret + "\n", into: editor)
                    let range = (view.string as NSString).range(of: secret)
                    let forward = n < 2
                    view.setSelectedRange(NSRange(location: forward ? range.location : NSMaxRange(range), length: 0))
                    view.doCommand(by: command)
                    AppTests.check(!view.string.contains(secret), "\(NSStringFromSelector(command)) did not delete")
                }
                // at the end of a line Ctrl-K takes the line break, as before
                AppTests.equal(view.string, "safetest first.\n\n\n\n\n")
                view.setSelectedRange(NSRange(location: (view.string as NSString).length - 1, length: 0))
                view.doCommand(by: #selector(NSResponder.deleteToEndOfParagraph(_:)))
                AppTests.equal(view.string, "safetest first.\n\n\n\n")
                // the mark
                type("safetest-killring-SECRET-mark", into: editor)
                let mark = (view.string as NSString).range(of: "safetest-killring-SECRET-mark")
                view.setSelectedRange(NSRange(location: mark.location, length: 0))
                view.setMark(nil)
                view.setSelectedRange(NSRange(location: NSMaxRange(mark), length: 0))
                view.doCommand(by: #selector(NSResponder.deleteToMark(_:)))
                AppTests.check(!view.string.contains("SECRET-mark"), "deleteToMark did not delete")
                // Edit > Delete and Cut, which delete through delete(_:) in AppKit
                let pasteboard = NSPasteboard.withUniqueName()
                let general = ClipboardGuard.pasteboard
                defer {
                    ClipboardGuard.pasteboard = general
                    pasteboard.releaseGlobally()
                }
                ClipboardGuard.pasteboard = pasteboard
                for (command, secret) in [(#selector(NSText.delete(_:)), "safetest-killring-SECRET-delete"),
                                          (#selector(NSText.cut(_:)), "safetest-killring-SECRET-cut")] {
                    type(secret, into: editor)
                    view.setSelectedRange((view.string as NSString).range(of: secret))
                    view.doCommand(by: command)
                    AppTests.check(!view.string.contains(secret), "\(NSStringFromSelector(command)) did not delete")
                }
                AppTests.equal(pasteboard.string(forType: .string), "safetest-killring-SECRET-cut")
                ClipboardGuard.clearIfOurs()
                AppTests.check(editor.textView.undoManager?.canUndo == true, "the deletes cannot be undone")
                // Ctrl-Y in the editor pastes nothing
                let before = view.string
                view.doCommand(by: #selector(NSResponder.yank(_:)))
                AppTests.equal(view.string, before, "Ctrl-Y changed the text")
                AppTests.check(editor.save(), "not saved: \(log.titles)")
                AppTests.equal(try decrypt(crypt), before)
                editor.lock()
                AppTests.check(editor.isClosed, "not closed on lock")
            }
            let after = killRing()
            AppTests.check(!after.contains("SECRET"), "Ctrl-Y in another field after the lock gives: \(after)")
            if ringWorks {
                AppTests.check(after.contains("safetest-plain-probe"), "the kill ring changed: \(after)")
            } else {
                print("     note: this process has no kill ring, so the check above proves less")
            }
        },

        AppTests.Case("Discard My Changes never loads garbage, and loads text Safe could not confirm read only") {
            // finding of review round 3: after another Mac re-encrypted the file with another
            // password, garbage that passed the padding check was loaded into an editable editor
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let latin1 = Data("Gr\u{FC}\u{DF}e aus K\u{F6}ln, und bis bald!\n".unicodeScalars.map { UInt8($0.value) })
                let crypt = try encrypt(latin1, as: "safetest-latin1.txt", in: dir)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: true)
                AppTests.equal(opened.check, .contentMismatch)
                let log = AlertLog()
                try withHooks(log) {
                    let (text, coding) = TextCoding.decodeAnyway(plain)
                    let editor = EditorWindowController(opened: opened, text: text,
                                                        password: SecureBytes(string: password),
                                                        coding: coding, readOnlyNote: nil)
                    defer { editor.window?.close() }
                    editor.allowEditing()
                    type("mine\n", into: editor)
                    AppTests.check(editor.save(), "not saved: \(log.titles)")
                    // another Mac encrypted the file with another password; Safe's password
                    // passes the padding check of this one (found by trying salts)
                    try bytes(fromHex: otherPasswordFile).write(to: crypt)
                    type("more\n", into: editor)
                    log.titles = []
                    log.answers = [.alertSecondButtonReturn]     // Discard My Changes
                    AppTests.check(!editor.save())
                    AppTests.equal(log.titles, ["safetest-latin1.txt.crypt changed on disk",
                                                "The file on disk could not be loaded"])
                    AppTests.check(editor.textView.string.hasSuffix("mine\nmore\n"), "garbage was loaded")
                    AppTests.check(editor.hasUnsavedChanges && !editor.isReadOnly)
                }
            }
            try withEditor { dir, crypt, editor, log in
                // the file as another Mac saved it: a Latin-1 text with the same password
                type("safetest mine\n", into: editor)
                AppTests.check(editor.save())
                let latin1Text = "Gr\u{FC}\u{DF}e vom anderen Mac, mit demselben Passwort!\n"
                let latin1 = Data(latin1Text.unicodeScalars.map { UInt8($0.value) })
                let other = try OpenSSLFormat.encrypt(latin1, password: SecureBytes(string: password))
                try other.write(to: crypt)
                type("safetest more\n", into: editor)
                log.answers = [.alertSecondButtonReturn]     // Discard My Changes
                AppTests.check(!editor.save())
                AppTests.equal(editor.textView.string, latin1Text)
                AppTests.check(editor.isReadOnly && !editor.textView.isEditable, "not read only")
                AppTests.equal(editor.readOnlyNote, EditorWindowController.unconfirmedNote)
                AppTests.check(!editor.save(), "saved without Allow Editing")
                editor.allowEditing()
                type("x\n", into: editor)
                AppTests.check(editor.save(), "not saved: \(log.titles)")
                // the .bak holds the other Mac's version, not the one before it
                AppTests.equal(try Data(contentsOf: URL(fileURLWithPath: crypt.path + ".bak")), other)
                _ = dir
            }
        },

        AppTests.Case("an answer given after a lock is not taken: Don't Save and Discard My Changes need the password") {
            // finding of review round 3 (G4): the Quit question and the conflict question were
            // answered after a lock without the password
            try withEditor { _, crypt, editor, log in
                type("safetest unsaved\n", into: editor)
                let presenter = DocumentAlerts.presenter
                defer { DocumentAlerts.presenter = presenter }
                var lockedOnce = false
                DocumentAlerts.presenter = { alert, window, done in
                    if !lockedOnce && alert.messageText.hasPrefix("Do you want to save") {
                        lockedOnce = true
                        editor.lock()         // Safe locks while the question is open
                    }
                    presenter?(alert, window, done)
                }
                log.answers = [.alertSecondButtonReturn]        // Don't Save, after the lock
                AppTests.check(!editor.confirmCloseModally(), "Don't Save was taken without the password")
                AppTests.check(editor.isLocked && editor.hasUnsavedChanges, "the changes were dropped")
                log.passwords = [password]
                log.answers = [.alertSecondButtonReturn]
                AppTests.check(editor.confirmCloseModally(), "not asked again after the password")
                AppTests.check(!editor.hasUnsavedChanges)

                // the conflict question
                type("safetest mine\n", into: editor)
                try changeOnDisk(crypt, to: "safetest other.\n")
                lockedOnce = false
                DocumentAlerts.presenter = { alert, window, done in
                    if !lockedOnce && alert.messageText.hasSuffix("changed on disk") {
                        lockedOnce = true
                        editor.lock()
                    }
                    presenter?(alert, window, done)
                }
                log.answers = [.alertSecondButtonReturn]        // Discard My Changes, after the lock
                AppTests.check(!editor.save())
                AppTests.check(editor.isLocked, "not locked")
                AppTests.check(editor.textView.string.hasSuffix("safetest mine\n"), "the covered text was replaced")
                AppTests.check(!editor.resolveConflict(.discardMine, data: Data()), "discarded while locked")
                AppTests.check(editor.textView.string.hasSuffix("safetest mine\n"))
            }
        },

        AppTests.Case("a volume Safe closed on lock can be opened again from the editor, and the save goes there") {
            // finding of review round 3 (G4): volumes now close on lock under unsaved changes too
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try AppTests.withTemporaryFolder { dir in
                let volume = dir.appendingPathComponent("safetest-volume")
                let away = dir.appendingPathComponent("safetest-away")
                try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: false)
                let crypt = try encrypt("safetest first.\n", as: "safetest-on-volume.txt", in: volume)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: false)
                var reopened: [String] = []
                let log = AlertLog()
                try withHooks(log) {
                    EditorWindowController.closedVolumeName = { url in
                        url.path.hasPrefix(volume.path + "/") && !FileManager.default.fileExists(atPath: volume.path)
                            ? "safetest-vol" : nil
                    }
                    EditorWindowController.reopenVolume = { url in
                        reopened.append(url.lastPathComponent)
                        return (try? FileManager.default.moveItem(at: away, to: volume)) != nil
                    }
                    let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                        password: SecureBytes(string: password))
                    defer { editor.window?.close() }
                    type("safetest unsaved\n", into: editor)
                    editor.lock()
                    try FileManager.default.moveItem(at: volume, to: away)      // the lock closed the volume
                    log.passwords = [password]
                    AppTests.check(editor.unlock())
                    log.answers = [.alertSecondButtonReturn]                     // Not Now
                    editor.offerToReopenVolume()
                    AppTests.equal(log.titles, ["The volume “safetest-vol” was closed"])
                    AppTests.equal(reopened, [])
                    // Cmd-S: the same offer, and the save after it
                    log.titles = []
                    log.answers = [.alertFirstButtonReturn]                      // Open “safetest-vol” Again
                    AppTests.check(!editor.save())
                    AppTests.equal(log.titles, ["safetest-on-volume.txt was not saved"])
                    AppTests.equal(reopened, ["safetest-on-volume.txt.crypt"])
                    AppTests.check(!editor.hasUnsavedChanges, "not saved after the volume was opened again")
                    AppTests.equal(try decrypt(crypt), "safetest first.\nsafetest unsaved\n")
                }
            }
        },
    ]

    /// Run in a child process by the leak test of SafeTests: the reference PDF and
    /// PNG in viewer windows that are never shown, drawn as on the screen.
    static let children: [String: () throws -> Void] = [
        "viewer-leak": {
            guard OffScreen.available else {
                print("no window server")
                return
            }
            let fixtures = AppInfo.fixturesDirectory
            let manifest = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixtures.appendingPathComponent("manifest.json"))) as? [String: Any]
            let files = manifest?["files"] as? [[String: Any]] ?? []
            var viewed: [String] = []
            try AppTests.withTemporaryFolder { dir in
                for name in ["sample.pdf", "sample.png", "photo.jpg", "photo.heic"] {
                    guard let entry = files.first(where: {
                        $0["variant"] as? String == "current" && $0["originalName"] as? String == name
                    }), let file = entry["file"] as? String, let secret = entry["password"] as? String else {
                        AppTests.check(false, "no reference file \(name)")
                        continue
                    }
                    let crypt = dir.appendingPathComponent(name + ".crypt")
                    try Data(contentsOf: fixtures.appendingPathComponent(file)).write(to: crypt)
                    let (opened, data) = try CryptFile.open(at: crypt, password: SecureBytes(string: secret),
                                                            allowLegacy: true)
                    withHooks(AlertLog()) {
                        let viewer = ViewerWindowController(opened: opened, data: data, password: SecureBytes(string: secret))
                        if let window = viewer.window, let view = window.contentView {
                            window.layoutIfNeeded()
                            view.layoutSubtreeIfNeeded()
                            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                                view.cacheDisplay(in: view.bounds, to: rep)
                            }
                        }
                        AppTests.check(viewer.pdfView?.document != nil || viewer.imageView?.image != nil,
                                       "\(name) is not shown")
                        AppTests.check(viewer.window?.isVisible == false, "the viewer is on the screen")
                        viewer.window?.close()
                    }
                    viewed.append(name)
                }
            }
            print("viewed " + viewed.joined(separator: ", "))
        },

        // Run by the leak test of SafeTests: an editor that is never shown, over a
        // throwaway file; a marker made here is typed, searched for, copied (to a
        // private pasteboard), saved, typed again, locked, unlocked and saved again.
        // The leak test then searches the disk for it.
        "editor-leak": {
            guard OffScreen.available else {
                print("no window server")
                return
            }
            let marker = "safetest-marker-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            let pasteboard = NSPasteboard.withUniqueName()
            let general = ClipboardGuard.pasteboard
            defer {
                ClipboardGuard.clearIfOurs()
                ClipboardGuard.pasteboard = general
                pasteboard.releaseGlobally()
            }
            ClipboardGuard.pasteboard = pasteboard
            try AppTests.withTemporaryFolder { dir in
                let crypt = try encrypt("safetest leak\n", as: "safetest-leak.txt", in: dir)
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                         allowLegacy: false)
                let log = AlertLog()
                withHooks(log) {
                    let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                        password: SecureBytes(string: password))
                    defer { editor.window?.close() }
                    type(marker + "\n", into: editor)
                    editor.showSearch()
                    editor.searchString = marker
                    AppTests.check(editor.search(.next) != nil, "the marker was not found")
                    editor.textView.copy(nil)
                    AppTests.equal(pasteboard.string(forType: .string), marker)
                    AppTests.check(editor.save(), "not saved: \(log.titles)")
                    type("again " + marker + "\n", into: editor)
                    editor.lock()
                    AppTests.check(editor.isLocked, "not locked")
                    log.passwords = [password]
                    AppTests.check(editor.unlock(), "not unlocked")
                    AppTests.check(editor.save(), "not saved after unlocking: \(log.titles)")
                    if let window = editor.window, let view = window.contentView {
                        view.layoutSubtreeIfNeeded()
                        if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                            view.cacheDisplay(in: view.bounds, to: rep)
                        }
                    }
                    AppTests.check(editor.window?.isVisible == false, "the editor is on the screen")
                }
                AppTests.check(try decrypt(crypt).contains("again " + marker), "the second save is not in the file")
            }
            print("typed " + marker)
        },
    ]

    // MARK: helpers

    static let password = "safetest-pw"

    /// A text encrypted with the password safetest-other, which safetest-pw decrypts
    /// with valid padding into bytes that are not text: found by trying salts.
    static let otherPasswordFile = """
        53616c7465645f5f9b959088807bde83d23f2a59b4de1716ba75ed90fafe45e15cdafff44a364fdb\
        0c0aaf3e28ed3e7279dd4dc9c49120e97284da7f3c71028423cd5e0cb3088c06feedc6668a0fad36\
        41ed55946a038d9e5d46758f9d0c2facb542f4eaefbbf3ccfef759d194dbcf3e2cb4e2a41249803be\
        57355a1ff20f6ab26dfea5723108784e696e1b4ba89fa62
        """

    /// The bytes of a string of hex digits.
    static func bytes(fromHex hex: String) -> Data {
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            data.append(UInt8(hex[index ..< next], radix: 16)!)
            index = next
        }
        return data
    }

    /// What the hooks saw and how they answer.
    final class AlertLog {
        /// The titles of the alerts, in order.
        var titles: [String] = []
        /// Their messages.
        var messages: [String] = []
        /// The buttons to press; the first button when it is empty.
        var answers: [NSApplication.ModalResponse] = []
        /// The passwords to type; Cancel when it is empty.
        var passwords: [String] = []
    }

    /// Encrypts a text file in a throwaway folder, opens it in an editor that is
    /// never shown, runs `body` with the folder, the .crypt file, the editor and the
    /// log, and closes the editor again.
    static func withEditor(_ body: (URL, URL, EditorWindowController, AlertLog) throws -> Void) throws {
        guard OffScreen.available else {
            try AppTests.skip("no window server")
        }
        try AppTests.withTemporaryFolder { dir in
            let file = dir.appendingPathComponent("safetest-note.txt")
            // 16 bytes: a text of 15 would be too short to confirm, and open read only
            try Data("safetest first.\n".utf8).write(to: file)
            let crypt = try CryptFile.encryptFile(at: file, password: SecureBytes(string: password))
            let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                     allowLegacy: false)
            AppTests.equal(opened.kind, .text)
            let log = AlertLog()
            try withHooks(log) {
                let editor = EditorWindowController(opened: opened, text: String(decoding: plain, as: UTF8.self),
                                                    password: SecureBytes(string: password))
                defer { editor.window?.close() }
                AppTests.check(editor.window?.isVisible == false, "the editor is on the screen")
                try body(dir, crypt, editor, log)
                AppTests.check(editor.window?.isVisible != true, "the editor is on the screen")
            }
        }
    }

    /// Encrypts `data` as `name` in a throwaway folder, opens it in a viewer that is
    /// never shown, runs `body`, then locks the viewer, which must close it and drop
    /// what it showed; no other file may appear in the folder.
    static func withViewer(of data: Data, named name: String, kind: FileKind,
                           _ body: (ViewerWindowController) throws -> Void) throws {
        guard OffScreen.available else {
            try AppTests.skip("no window server")
        }
        try AppTests.withTemporaryFolder { dir in
            let file = dir.appendingPathComponent(name)
            try data.write(to: file)
            let crypt = try CryptFile.encryptFile(at: file, password: SecureBytes(string: password))
            let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: password),
                                                     allowLegacy: false)
            AppTests.equal(opened.kind, kind)
            try withHooks(AlertLog()) {
                let viewer = ViewerWindowController(opened: opened, data: plain, password: SecureBytes(string: password))
                defer { viewer.window?.close() }
                AppTests.check(viewer.window?.isVisible == false, "the viewer is on the screen")
                AppTests.check(!viewer.offersSaveInCurrentFormat, "offers to save a file in the current format")
                try body(viewer)
                viewer.lock()
                AppTests.check(viewer.isClosed, "not closed on lock")
                AppTests.check(viewer.imageView?.image == nil && viewer.pdfView?.document == nil,
                               "still holds what it showed")
            }
            AppTests.equal(try names(in: dir), [crypt.lastPathComponent])
        }
    }

    /// Answers alerts and password dialogs from the log while `body` runs, then
    /// puts the hooks back.
    static func withHooks(_ log: AlertLog, _ body: () throws -> Void) rethrows {
        let presenter = DocumentAlerts.presenter, beep = DocumentAlerts.beep
        let askPassword = DocumentAlerts.askPassword, saveRefusal = DocumentAlerts.saveRefusal
        let closedVolumeName = EditorWindowController.closedVolumeName
        let reopenVolume = EditorWindowController.reopenVolume
        defer {
            DocumentAlerts.presenter = presenter
            DocumentAlerts.beep = beep
            DocumentAlerts.askPassword = askPassword
            DocumentAlerts.saveRefusal = saveRefusal
            EditorWindowController.closedVolumeName = closedVolumeName
            EditorWindowController.reopenVolume = reopenVolume
        }
        // never the app's own volume list, which is the user's
        EditorWindowController.closedVolumeName = { _ in nil }
        EditorWindowController.reopenVolume = { _ in false }
        DocumentAlerts.presenter = { alert, _, done in
            log.titles.append(alert.messageText)
            log.messages.append(alert.informativeText)
            done(log.answers.isEmpty ? .alertFirstButtonReturn : log.answers.removeFirst())
        }
        DocumentAlerts.beep = {}
        DocumentAlerts.askPassword = { _, _ in
            log.passwords.isEmpty ? nil : SecureBytes(string: log.passwords.removeFirst())
        }
        DocumentAlerts.saveRefusal = { nil }
        try body()
    }

    /// Types at the end of the text, as the keyboard would.
    static func type(_ text: String, into editor: EditorWindowController) {
        let view = editor.textView
        let end = NSRange(location: (view.string as NSString).length, length: 0)
        view.setSelectedRange(end)
        view.insertText(text, replacementRange: end)
    }

    /// Another program changes the file: new content, same password.
    static func changeOnDisk(_ crypt: URL, to text: String) throws {
        let data = try OpenSSLFormat.encrypt(Data(text.utf8), password: SecureBytes(string: password))
        try data.write(to: crypt)
    }

    static func decrypt(_ crypt: URL) throws -> String {
        String(decoding: try decryptData(crypt), as: UTF8.self)
    }

    static func decryptData(_ crypt: URL) throws -> Data {
        try OpenSSLFormat.decryptCurrent(Data(contentsOf: crypt), password: SecureBytes(string: password))
    }

    /// Encrypts text or bytes as NAME.crypt in the folder, as Encrypt with Safe does.
    static func encrypt(_ text: String, as name: String, in dir: URL) throws -> URL {
        try encrypt(Data(text.utf8), as: name, in: dir)
    }

    static func encrypt(_ data: Data, as name: String, in dir: URL) throws -> URL {
        let file = dir.appendingPathComponent(name)
        try data.write(to: file)
        return try CryptFile.encryptFile(at: file, password: SecureBytes(string: password))
    }

    /// An 8 by 8 picture, PNG unless asked otherwise.
    static func makePNG(_ type: NSBitmapImageRep.FileType = .png) throws -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let picture = rep?.representation(using: type, properties: [:]) else {
            throw CryptError.io("cannot make a picture")
        }
        return picture
    }

    /// `data` in the old format of openssl with an MD5 key (EVP_BytesToKey, AES-256-CBC),
    /// made with /usr/bin/openssl and a fixed salt.
    static func oldFormat(_ data: Data, password: String) throws -> Data {
        try openssl(data, options: ["-aes-256-cbc", "-md", "md5", "-S", "0123456789abcdef"], password: password)
    }

    /// `data` encrypted by /usr/bin/openssl enc with these options.
    static func openssl(_ data: Data, options: [String], password: String = password) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = ["enc", "-e"] + options + ["-pass", "stdin"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data((password + "\n").utf8) + data)
        try input.fileHandleForWriting.close()
        let result = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CryptError.io("openssl failed") }
        return result
    }

    static func names(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }
}
#endif
