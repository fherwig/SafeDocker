import Foundation
import SafeCore

// WP3: the parts of the editor and the lock that need no window (building plan
// 4.5 and 4.9): idle decision, lock policy, password comparison, search,
// selection, status line, conflict names, clipboard rule and shortcuts.
// The code is in LockPolicy.swift and EditorLogic.swift.

enum AppLogicTests: TestSuite {
    static let name = "applogic"

    static let utc = TimeZone(identifier: "UTC")!

    /// 2026-10-25 14:05 UTC
    static let fivepast2 = Date(timeIntervalSince1970: 1_792_937_100)

    static func same(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        a.withUnsafeBytes { x in b.withUnsafeBytes { y in LockPolicy.sameBytes(x, y) } }
    }

    static let tests: [TestCase] = [
        TestCase("lock after 10 minutes, checked every 10 s") {
            expectEqual(LockPolicy.idleLimit, 600)
            expectEqual(LockPolicy.checkInterval, 10)
        },

        TestCase("an editor closes when clean and covers its text when changed") {
            expectEqual(LockPolicy.editorResponse(hasUnsavedChanges: false), .close)
            expectEqual(LockPolicy.editorResponse(hasUnsavedChanges: true), .cover)
        },

        TestCase("idle time locks once per stretch without input") {
            var decider = IdleLockDecider()
            expect(!decider.shouldLock(idleSeconds: 0))
            expect(!decider.shouldLock(idleSeconds: 599.9))
            expect(decider.shouldLock(idleSeconds: 600))
            expect(!decider.shouldLock(idleSeconds: 630))
            expect(!decider.shouldLock(idleSeconds: 5000))
            expect(!decider.shouldLock(idleSeconds: 3), "input resets the stretch")
            expect(decider.shouldLock(idleSeconds: 601))
            var short = IdleLockDecider(limit: 10)
            expect(short.shouldLock(idleSeconds: 10))
        },

        TestCase("idle time locks for a stretch that ended between two checks") {
            // finding of review round 4: input between 600 s and the next check, or a
            // check that App Nap held back, meant that the stretch never locked
            var decider = IdleLockDecider()
            expect(!decider.shouldLock(idleSeconds: 595, at: 1000))
            expect(decider.shouldLock(idleSeconds: 2, at: 1010), "595 s, then input 8 s later: 603 s without input")
            expect(!decider.shouldLock(idleSeconds: 12, at: 1020), "locked twice")
            // a check held back for minutes
            var late = IdleLockDecider()
            expect(!late.shouldLock(idleSeconds: 400, at: 0))
            expect(late.shouldLock(idleSeconds: 1, at: 300))
            // short stretches with checks on time do not lock
            var busy = IdleLockDecider()
            expect(!busy.shouldLock(idleSeconds: 500, at: 0))
            expect(!busy.shouldLock(idleSeconds: 3, at: 10), "503 s at most")
            expect(!busy.shouldLock(idleSeconds: 590, at: 597))
            expect(!busy.shouldLock(idleSeconds: 595, at: 602), "no input since the last check")
            // a stretch locked already does not lock again when the user is back
            var back = IdleLockDecider()
            expect(back.shouldLock(idleSeconds: 605, at: 0))
            expect(!back.shouldLock(idleSeconds: 615, at: 10))
            expect(!back.shouldLock(idleSeconds: 1, at: 20))
            // without a clock, as before
            var plain = IdleLockDecider()
            expect(!plain.shouldLock(idleSeconds: 595))
            expect(!plain.shouldLock(idleSeconds: 2))
        },

        TestCase("password comparison") {
            expect(same(Array("päss wörd".utf8), Array("päss wörd".utf8)))
            expect(!same(Array("password".utf8), Array("passwore".utf8)))
            expect(!same(Array("password".utf8), Array("password1".utf8)))
            expect(!same([], [0]))
            expect(same([], []))
        },

        TestCase("search finds forwards and backwards, wraps, ignores case") {
            let text = "Alpha beta ALPHA gamma alpha"
            expectEqual(TextSearch.find("alpha", in: text, from: 0, backwards: false), NSRange(location: 0, length: 5))
            expectEqual(TextSearch.find("alpha", in: text, from: 1, backwards: false), NSRange(location: 11, length: 5))
            expectEqual(TextSearch.find("alpha", in: text, from: 16, backwards: false), NSRange(location: 23, length: 5))
            expectEqual(TextSearch.find("alpha", in: text, from: 24, backwards: false), NSRange(location: 0, length: 5),
                        "wraps to the start")
            expectEqual(TextSearch.find("alpha", in: text, from: 23, backwards: true), NSRange(location: 11, length: 5))
            expectEqual(TextSearch.find("alpha", in: text, from: 0, backwards: true), NSRange(location: 23, length: 5),
                        "wraps to the end")
            expectEqual(TextSearch.find("alpha", in: text, from: 999, backwards: false), NSRange(location: 0, length: 5))
            expect(TextSearch.find("delta", in: text, from: 0, backwards: false) == nil)
            expect(TextSearch.find("", in: text, from: 0, backwards: false) == nil)
            expect(TextSearch.find("a", in: "", from: 0, backwards: true) == nil)
            expectEqual(TextSearch.count("alpha", in: text), 3)
            expectEqual(TextSearch.count("aa", in: "aaaa"), 2)
            expectEqual(TextSearch.count("", in: text), 0)
        },

        TestCase("search works in UTF-16 ranges like NSTextView") {
            let text = "ä😀b😀"
            expectEqual(TextSearch.find("😀", in: text, from: 0, backwards: false), NSRange(location: 1, length: 2))
            expectEqual(TextSearch.find("😀", in: text, from: 3, backwards: false), NSRange(location: 4, length: 2))
            expectEqual(TextSearch.find("B", in: text, from: 0, backwards: false), NSRange(location: 3, length: 1))
        },

        TestCase("a selection of several ranges is joined in text order") {
            let text = "hello world"
            expectEqual(TextSelection.joined(text, ranges: [NSRange(location: 6, length: 5), NSRange(location: 0, length: 5)]),
                        "hello\nworld")
            expectEqual(TextSelection.joined(text, ranges: [NSRange(location: 0, length: 0)]), "")
            expectEqual(TextSelection.joined(text, ranges: [NSRange(location: 8, length: 10)]), "", "outside the text")
            expectEqual(TextSelection.joined(text, ranges: [NSRange(location: 0, length: 11)]), text)
        },

        TestCase("status line") {
            expectEqual(EditorStatus.line(savedAt: nil, backupName: "notes.md.crypt.bak", legacyName: nil, timeZone: utc),
                        "Decrypted in memory only.")
            expectEqual(EditorStatus.line(savedAt: fivepast2, backupName: "notes.md.crypt.bak", legacyName: nil, timeZone: utc),
                        "Decrypted in memory only. Saved 14:05, the previous version is kept as notes.md.crypt.bak.")
            expectEqual(EditorStatus.line(savedAt: fivepast2, backupName: nil, legacyName: nil, timeZone: utc),
                        "Decrypted in memory only. Saved 14:05.")
            expectEqual(EditorStatus.line(savedAt: nil, backupName: "x", legacyName: "RC4, key from MD5", timeZone: utc),
                        "Decrypted in memory only. Opened from an old format (RC4, key from MD5); saving writes the current format.")
            expect(!EditorStatus.line(savedAt: fivepast2, backupName: "x", legacyName: "RC4", timeZone: utc).contains("old format"))
            expectEqual(EditorStatus.line(savedAt: nil, backupName: "x", legacyName: nil, codingName: "ISO Latin-1",
                                          timeZone: utc), "Decrypted in memory only. Text in ISO Latin-1.")
            expectEqual(EditorStatus.backupName(forEncryptedFileName: "safe.txt.crypt"), "safe.txt.crypt.bak")
            expectEqual(EditorStatus.clock(Date(timeIntervalSince1970: 9 * 3600 + 3 * 60), timeZone: utc), "09:03")
            expect(EditorStatus.locked.hasPrefix("Locked."))
        },

        TestCase("text keeps its encoding: UTF-8 with a byte order mark, UTF-16, ISO Latin-1") {
            let plain = Data("Grüße\r\nline two\n".utf8)
            expectEqual(TextCoding.decodeUTF8(plain)?.coding, .utf8)
            let bom = Data([0xEF, 0xBB, 0xBF]) + Data("hi\n".utf8)
            let decodedBOM = TextCoding.decodeUTF8(bom)
            expectEqual(decodedBOM?.text, "hi\n", "the mark is not part of the text")
            expectEqual(decodedBOM?.coding, .utf8WithBOM)
            expectEqual(decodedBOM.flatMap { $0.coding.encode($0.text) }, bom, "saving puts the mark back")
            expect(TextCoding.decodeUTF8(Data([0x41, 0xFF])) == nil)
            expect(TextCoding.decodeUTF8(Data([0x41, 0x00])) == nil)

            var utf16 = Data([0xFF, 0xFE])
            for unit in "Äpfel;3\r\n🔐".utf16 {
                utf16.append(UInt8(unit & 0xFF))
                utf16.append(UInt8(unit >> 8))
            }
            let (text16, coding16) = TextCoding.decodeAnyway(utf16)
            expectEqual(text16, "Äpfel;3\r\n🔐")
            expectEqual(coding16, .utf16LittleEndian)
            expectEqual(coding16.encode(text16), utf16)
            let bigEndian = Data([0xFE, 0xFF, 0x00, 0x41, 0x00, 0xE4])
            expectEqual(TextCoding.decodeAnyway(bigEndian).text, "Aä")
            expectEqual(TextCoding.decodeAnyway(bigEndian).coding.encode("Aä"), bigEndian)

            let every = Data((0 ... 255).map { UInt8($0) })
            let (text1, coding1) = TextCoding.decodeAnyway(every)
            expectEqual(coding1, .latin1)
            expectEqual(text1.unicodeScalars.count, 256)
            expectEqual(coding1.encode(text1), every, "an unchanged text gives the same bytes")
            expect(TextCoding.latin1.encode("5 €") == nil, "€ is not in ISO Latin-1")
            // a lone surrogate is no UTF-16: ISO Latin-1, which loses nothing
            expectEqual(TextCoding.decodeAnyway(Data([0xFF, 0xFE, 0x00, 0xD8])).coding, .latin1)
            // UTF-8 with a NUL byte is still UTF-8
            expectEqual(TextCoding.decodeAnyway(Data([0x41, 0x00, 0xC3, 0xBC])).text, "A\u{0}ü")
            expectEqual(TextCoding.latin1.name, "ISO Latin-1")
        },

        TestCase("conflict copies keep the ending last and never overwrite") {
            let none: (String) -> Bool = { _ in false }
            expectEqual(ConflictName.make(originalName: "notes.md", date: fivepast2, timeZone: utc, exists: none),
                        "notes (conflict 2026-10-25 14-05).md.crypt")
            expectEqual(ConflictName.make(originalName: "safe", date: fivepast2, timeZone: utc, exists: none),
                        "safe (conflict 2026-10-25 14-05).crypt")
            expectEqual(ConflictName.make(originalName: ".env", date: fivepast2, timeZone: utc, exists: none),
                        ".env (conflict 2026-10-25 14-05).crypt")
            expectEqual(ConflictName.make(originalName: "archive.tar.gz", date: fivepast2, timeZone: utc, exists: none),
                        "archive.tar (conflict 2026-10-25 14-05).gz.crypt")
            expectEqual(ConflictName.make(originalName: "v1. draft", date: fivepast2, timeZone: utc, exists: none),
                        "v1. draft (conflict 2026-10-25 14-05).crypt")
            let taken: Set = ["notes (conflict 2026-10-25 14-05).md.crypt", "notes (conflict 2026-10-25 14-05 2).md.crypt"]
            expectEqual(ConflictName.make(originalName: "notes.md", date: fivepast2, timeZone: utc, exists: { taken.contains($0) }),
                        "notes (conflict 2026-10-25 14-05 3).md.crypt")
            let name = ConflictName.make(originalName: "a.txt", date: Date(), exists: none)
            expect(!name.contains(":") && !name.contains("/"), name)
            expectEqual(((name as NSString).deletingPathExtension as NSString).pathExtension, "txt")
        },

        TestCase("the clipboard is cleared only if it still holds the app's text") {
            expectEqual(ClipboardPolicy.clearAfter, 60)
            expect(ClipboardPolicy.shouldClear(currentChangeCount: 5, ourChangeCount: 5))
            expect(!ClipboardPolicy.shouldClear(currentChangeCount: 6, ourChangeCount: 5))
            expect(!ClipboardPolicy.shouldClear(currentChangeCount: 5, ourChangeCount: nil))
            expectEqual(ClipboardPolicy.concealedType, "org.nspasteboard.ConcealedType")
            expectEqual(ClipboardPolicy.transientType, "org.nspasteboard.TransientType")
        },

        TestCase("macOS's clipboard history is taken as on unless it is known to be off") {
            // finding of review round 4: Spotlight's clipboard history on macOS 26
            expect(ClipboardPolicy.historyMayBeOn(preference: true, macOSMajor: 26))
            expect(ClipboardPolicy.historyMayBeOn(preference: NSNumber(value: 1), macOSMajor: 26))
            expect(!ClipboardPolicy.historyMayBeOn(preference: false, macOSMajor: 26))
            expect(!ClipboardPolicy.historyMayBeOn(preference: NSNumber(value: 0), macOSMajor: 27))
            expect(ClipboardPolicy.historyMayBeOn(preference: nil, macOSMajor: 26), "not set on macOS 26")
            expect(!ClipboardPolicy.historyMayBeOn(preference: nil, macOSMajor: 15), "macOS 15 has none")
            expectEqual(ClipboardPolicy.historyPreferenceDomain, "com.apple.Spotlight")
            expectEqual(ClipboardPolicy.historyPreferenceKey, "PasteboardHistoryEnabled")
        },

        TestCase("editor shortcuts") {
            func cmd(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false,
                     command: Bool = true) -> EditorCommand? {
                EditorShortcuts.command(key: key, command: command, shift: shift, option: option, control: control)
            }
            expectEqual(cmd("s"), .save)
            expectEqual(cmd("w"), .close)
            expectEqual(cmd("f"), .find)
            expectEqual(cmd("g"), .findNext)
            expectEqual(cmd("g", shift: true), .findPrevious)
            expectEqual(cmd("G", shift: true), .findPrevious)
            expectEqual(cmd("x"), .cut)
            expectEqual(cmd("c"), .copy)
            expectEqual(cmd("v"), .paste)
            expectEqual(cmd("a"), .selectAll)
            expectEqual(cmd("z"), .undo)
            expectEqual(cmd("Z", shift: true), .redo)
            expect(cmd("s", shift: true) == nil, "Save As does not exist")
            expect(cmd("f", option: true) == nil)
            expect(cmd("s", control: true) == nil)
            expect(cmd("s", command: false) == nil)
            expect(cmd("q") == nil, "Quit belongs to the app")
            expect(cmd("p") == nil, "no Print")
        },
    ]
}
