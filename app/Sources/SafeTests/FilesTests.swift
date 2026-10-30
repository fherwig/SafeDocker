import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import SafeCore

// WP1: CryptFile and FileKind (building plan 7.1 and 7.3): encryptFile deletes
// the original only after a successful check, save keeps .bak, refuses on
// conflict and leaves no .crypt_new, export writes identical bytes, the leak
// test.

enum FilesTests: TestSuite {
    static let name = "files"

    static let tests: [TestCase] = earlier + roundThree + roundFour

    private static let earlier: [TestCase] = [
        // MARK: Plausibility and FileKind

        TestCase("text endings need UTF-8 without NUL") {
            let good: [[UInt8]] = [
                [], Array("plain ASCII\n".utf8), Array("Grüße, 日本語, 🔐, tab\tand CR\r\n".utf8),
                [0xEF, 0xBB, 0xBF] + Array("with a BOM".utf8),
            ]
            let bad: [[UInt8]] = [
                Array("NUL\u{0}inside".utf8), [0x41, 0xFF, 0x42], [0xC0, 0xAF], [0xE0, 0x80, 0xAF],
                [0xED, 0xA0, 0x80], [0xF4, 0x90, 0x80, 0x80], [0xE6, 0x97], [0x80], [0xF8, 0x88, 0x80, 0x80, 0x80],
            ]
            for name in ["notes.txt", "a.md", "a.markdown", "a.csv", "a.json", "a.yaml", "a.yml", "a.xml",
                         "a.tex", "a.log", "safe", "NOTES.TXT", ".profile", "dir.d/README"] {
                for bytes in good {
                    expectEqual(Plausibility.check(Data(bytes), originalName: name), .plausible, "\(name) \(bytes.prefix(6))")
                }
                for bytes in bad {
                    expectEqual(Plausibility.check(Data(bytes), originalName: name), .implausible, "\(name) \(bytes)")
                }
            }
        },

        TestCase("known binary types need their magic bytes") {
            let samples: [String: [UInt8]] = [
                "pdf": Array("%PDF-1.4\n".utf8),
                "png": [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13],
                "jpg": [0xFF, 0xD8, 0xFF, 0xE0, 0, 16],
                "jpeg": [0xFF, 0xD8, 0xFF, 0xE1, 0, 16],
                "gif": Array("GIF89a".utf8) + [1, 0, 1, 0],
                "tif": [0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0],
                "tiff": [0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8],
                "heic": [0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0, 0, 0] + Array("mif1heic".utf8),
                "heif": [0, 0, 0, 24] + Array("ftypmif1".utf8) + [0, 0, 0, 0],
            ]
            for (ending, magic) in samples {
                let name = "file." + ending
                expectEqual(Plausibility.check(Data(magic + [1, 2, 3]), originalName: name), .plausible, name)
                expectEqual(Plausibility.check(Data(magic), originalName: name.uppercased()), .plausible, name)
                expectEqual(Plausibility.check(Data("not an image".utf8), originalName: name), .implausible, name)
                expectEqual(Plausibility.check(Data([0x01] + magic), originalName: name),
                            ending == "pdf" ? .plausible : .implausible, "\(name) with a byte in front")
                expectEqual(Plausibility.check(Data(), originalName: name), .implausible, name)
            }
            // a misnamed file still counts, a PNG saved as .jpg for example
            expectEqual(Plausibility.check(Data(samples["png"]!), originalName: "photo.jpg"), .plausible)
            // PDF readers accept the header within the first 1024 bytes
            expectEqual(Plausibility.check(Data(repeating: 0x20, count: 1000) + Data("%PDF-1.7".utf8),
                                           originalName: "a.pdf"), .plausible)
            expectEqual(Plausibility.check(Data(repeating: 0x20, count: 1024) + Data("%PDF-1.7".utf8),
                                           originalName: "a.pdf"), .implausible)
        },

        TestCase("other endings cannot be checked, unless the content is a known type or long text") {
            for name in ["data.bin", "x.crypt", "notes.bak", "photo.raw", "song.mp3", "film.mov"] {
                expectEqual(Plausibility.check(CryptoTestKit.randomData(100), originalName: name), .unknownType, name)
                expectEqual(Plausibility.check(Data("text".utf8), originalName: name), .unknownType, name)
                expectEqual(Plausibility.check(Data(repeating: 0x61, count: 31), originalName: name), .unknownType, name)
                expectEqual(Plausibility.check(Data(repeating: 0x61, count: 32), originalName: name), .plausible, name)
                expectEqual(Plausibility.check(Data("<?xml version=\"1.0\"?>\n<plist>Grüße</plist>\n".utf8),
                                               originalName: name), .plausible, name)
                expectEqual(Plausibility.check(Data([0x50, 0x4B, 3, 4, 20, 0]), originalName: name), .plausible, name)
                // three bytes of JPEG are too few to count for any name
                expectEqual(Plausibility.check(Data([0xFF, 0xD8, 0xFF, 0xE0]), originalName: name), .unknownType, name)
            }
        },

        TestCase("containers, documents and media need their magic bytes") {
            let zip: [UInt8] = [0x50, 0x4B, 0x03, 0x04, 20, 0, 0, 0]
            let riff = { (form: String) -> [UInt8] in Array("RIFF".utf8) + [36, 0, 0, 0] + Array(form.utf8) }
            let samples: [(String, [UInt8])] = [
                ("docx", zip), ("xlsx", zip), ("pptx", zip), ("zip", zip), ("odt", zip), ("epub", zip),
                ("pages", zip), ("numbers", zip), ("zip", [0x50, 0x4B, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)),
                ("doc", [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]), ("xls", [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]),
                ("gz", [0x1F, 0x8B, 0x08, 0]), ("tgz", [0x1F, 0x8B, 0x08, 8]), ("bz2", Array("BZh9".utf8)),
                ("xz", [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]), ("zst", [0x28, 0xB5, 0x2F, 0xFD]),
                ("7z", [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]), ("rar", Array("Rar!".utf8) + [0x1A, 0x07, 0x01]),
                ("wav", riff("WAVE")), ("avi", riff("AVI ")), ("webp", riff("WEBP")),
                ("mp4", [0, 0, 0, 32] + Array("ftypisom".utf8)), ("m4a", [0, 0, 0, 32] + Array("ftypM4A ".utf8)),
                ("avif", [0, 0, 0, 32] + Array("ftypavif".utf8)), ("bmp", Array("BM".utf8) + [70, 0, 0, 0, 0, 0, 0, 0]),
                ("flac", Array("fLaC".utf8)), ("ogg", Array("OggS".utf8)), ("rtf", Array("{\\rtf1\\ansi".utf8)),
                ("sqlite", Array("SQLite format 3".utf8) + [0]),
            ]
            for (ending, magic) in samples {
                let name = "file." + ending
                expectEqual(Plausibility.check(Data(magic + [1, 2, 3]), originalName: name), .plausible, name)
                expectEqual(Plausibility.check(CryptoTestKit.randomData(200), originalName: name), .implausible, name)
                expectEqual(Plausibility.check(Data("plain text, long enough to count as text elsewhere".utf8),
                                               originalName: name), .implausible, name)
            }
            // a misnamed file counts if its content is a known type: a PDF saved as .docx,
            // a WebP picture or a ZIP saved as .jpg, a PDF without an ending
            let pdf = Data("%PDF-1.7\n".utf8) + CryptoTestKit.randomData(100)
            expectEqual(Plausibility.check(pdf, originalName: "report.docx"), .plausible)
            expectEqual(Plausibility.check(Data(riff("WEBP")), originalName: "photo.jpg"), .plausible)
            expectEqual(Plausibility.check(Data(zip), originalName: "photo.jpg"), .plausible)
            expectEqual(Plausibility.check(pdf, originalName: "scan"), .plausible)
            // three bytes of gzip count for .gz only
            expectEqual(Plausibility.check(Data([0x1F, 0x8B, 0x08, 0]), originalName: "notes.txt"), .implausible)
        },

        TestCase("a .key file may be a Keynote document or a private key") {
            // finding of review round 2: a PEM key was always "could not confirm"
            let pem = Data("-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIFHDBOBgkqhkiG9w0BBQ0wQTApBgkqhkiG9w0BBQwwHAQI\n".utf8)
            expectEqual(Plausibility.check(pem, originalName: "server.key"), .plausible)
            expectEqual(Plausibility.check(Data([0x50, 0x4B, 3, 4, 20, 0]), originalName: "talk.key"), .plausible)
            // a DER key or other bytes: a type Safe cannot check, not a wrong password
            expectEqual(Plausibility.check(CryptoTestKit.randomData(200), originalName: "server.key"), .unknownType)
        },

        TestCase("text in another encoding is told apart from random bytes") {
            let latin1 = Data("Grüße aus Köln, und bis bald im Frühjahr!\n".unicodeScalars.map { UInt8($0.value) })
            let macRoman = "Café crème für Jürgen, 5 € Trinkgeld.".data(using: .macOSRoman)!
            let cp1252 = Data([0x93]) + Data("Quoted,".utf8) + Data([0x94]) + Data(" and a long dash ".utf8)
                + Data([0x97]) + Data(" in Windows-1252.\r\n".utf8)
            var utf16le = Data([0xFF, 0xFE]), utf16be = Data([0xFE, 0xFF])
            for unit in "Name;Wert\r\nÄpfel;3\r\n日本語;5\r\n".utf16 {
                utf16le.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
                utf16be.append(contentsOf: [UInt8(unit >> 8), UInt8(unit & 0xFF)])
            }
            for (name, data) in [("latin1", latin1), ("macRoman", macRoman), ("cp1252", cp1252),
                                 ("UTF-16 LE", utf16le), ("UTF-16 BE", utf16be)] {
                expect(Plausibility.looksLikeText(data), name)
                expectEqual(Plausibility.check(data, originalName: "notes.txt"), .implausible, name)
            }
            // too short, a NUL or another control byte, too little ASCII, no byte order mark
            expect(!Plausibility.looksLikeText(Data("Gr\u{FC}\u{DF}e\n".unicodeScalars.map { UInt8($0.value) })))
            expect(!Plausibility.looksLikeText(Data("text with a NUL\u{0} inside, long enough to count\n".utf8)))
            expect(!Plausibility.looksLikeText(Data("text with an escape \u{1B}[0m, long enough to count\n".utf8)))
            expect(!Plausibility.looksLikeText(Data((0 ..< 64).map { UInt8(0xC0 + $0 % 32) })))
            expect(!Plausibility.looksLikeText(utf16le.dropFirst(2)))
            // random bytes, as a wrong password gives them: never in 20,000 tries
            var passed = 0
            for _ in 0 ..< 20_000 where Plausibility.looksLikeText(CryptoTestKit.randomData(64)) {
                passed += 1
            }
            var withMark = 0
            for _ in 0 ..< 20_000 where Plausibility.looksLikeText(Data([0xFF, 0xFE]) + CryptoTestKit.randomData(126)) {
                withMark += 1
            }
            expectEqual(passed, 0, "random bytes looked like text")
            expectEqual(withMark, 0, "random bytes after a UTF-16 byte order mark looked like text")
        },

        TestCase("FileKind by name and content") {
            let pdf = Data("%PDF-1.4\n%".utf8) + Data([0xE2, 0xE3, 0xCF, 0xD3])
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0])
            let jpeg = Data([0xFF, 0xD8, 0xFF, 0xDB])
            let heic = Data([0, 0, 0, 24] + Array("ftypheic".utf8) + [0, 0, 0, 0])
            let text = Data("Grüße\n".utf8)
            let cases: [(String, Data, FileKind)] = [
                ("notes.txt", text, .text), ("safe", text, .text), ("a.md", text, .text),
                ("notes.txt", Data([0xFF, 0xFE, 0]), .other), ("sample.pdf", pdf, .pdf),
                ("photo.png", png, .image), ("photo.jpg", jpeg, .image), ("photo.heic", heic, .image),
                ("x.docx", Data([0x50, 0x4B, 3, 4]), .other), ("photo.png", text, .other),
                ("scan", pdf, .pdf), ("data.bin", text, .other), ("notes.txt", Data(), .text),
                ("photo.jpg", Data(Array("RIFF".utf8) + [36, 0, 0, 0] + Array("WEBP".utf8)), .image),
                ("photo.bmp", Data(Array("BM".utf8) + [70, 0, 0, 0, 0, 0, 0, 0]), .image),
                ("photo.avif", Data([0, 0, 0, 32] + Array("ftypavif".utf8)), .image),
            ]
            for (name, data, kind) in cases {
                expectEqual(FileKind.classify(originalName: name, plaintext: data), kind, name)
            }
            for name in ["notes.txt", "safe", "a.MD", "x.csv", ".profile"] {
                expect(FileKind.isTextName(name), name)
            }
            for name in ["a.pdf", "x.docx", "data.bin", "notes.txt.bak"] {
                expect(!FileKind.isTextName(name), name)
            }
        },

        // MARK: encryptFile (R1)

        TestCase("encryptFile replaces the original by NAME.crypt") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("report.pdf")
                let content = Data("%PDF-1.4\n".utf8) + CryptoTestKit.randomData(3000)
                try content.write(to: original)
                let pw = "Encrypt-Grüße"
                let result = try CryptFile.encryptFile(at: original, password: SecureBytes(string: pw))
                expectEqual(result.lastPathComponent, "report.pdf.crypt")
                expect(!FileManager.default.fileExists(atPath: original.path), "the original is still there")
                expect(!FileManager.default.fileExists(atPath: original.path + ".crypt_new"), ".crypt_new left")
                expectEqual(try FileManager.default.attributesOfItem(atPath: result.path)[.posixPermissions] as? Int, 0o600)
                let (opened, plain) = try CryptFile.open(at: result, password: SecureBytes(string: pw), allowLegacy: false)
                expect(plain == content, "the app decrypts it to the original")
                expectEqual(opened.kind, .pdf)
                expectEqual(opened.originalName, "report.pdf")
                expect(try CryptoTestKit.opensslDecrypt(Data(contentsOf: result), password: pw) == content,
                       "/usr/bin/openssl decrypts it to the original")
            }
        },

        TestCase("encryptFile keeps the original when the check fails") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("notes.txt")
                let content = Data("keep me\n".utf8)
                try content.write(to: original)
                CryptFile.testHookFailCheck = true
                defer { CryptFile.testHookFailCheck = false }
                expectThrows(CryptError.checkFailed) {
                    _ = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw"))
                }
                expectEqual(try Data(contentsOf: original), content, "the original is unchanged")
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.txt"],
                            "no .crypt or .crypt_new is left")
            }
        },

        TestCase("encryptFile refuses when NAME.crypt exists") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("notes.txt")
                let existing = dir.appendingPathComponent("notes.txt.crypt")
                try Data("new".utf8).write(to: original)
                try Data("old ciphertext".utf8).write(to: existing)
                expectThrows(CryptError.alreadyExists(existing.path)) {
                    _ = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw"))
                }
                expectEqual(try Data(contentsOf: original), Data("new".utf8))
                expectEqual(try Data(contentsOf: existing), Data("old ciphertext".utf8))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["notes.txt", "notes.txt.crypt"])
            }
        },

        TestCase("encryptFile replaces a stale NAME.crypt_new and handles an empty file") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("empty.txt")
                try Data().write(to: original)
                try Data("stale".utf8).write(to: dir.appendingPathComponent("empty.txt.crypt_new"))
                let result = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw"))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["empty.txt.crypt"])
                expectEqual(try CryptFile.open(at: result, password: SecureBytes(string: "pw"), allowLegacy: false).1, Data())
            }
        },

        TestCase("encryptFile refuses a file too large to hold in memory") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("big.bin")
                try CryptoTestKit.randomData(200).write(to: original)
                let saved = CryptFile.largestFileToEncrypt
                CryptFile.largestFileToEncrypt = 100
                defer { CryptFile.largestFileToEncrypt = saved }
                expectThrows(CryptError.io(CryptFile.tooLargeMessage("big.bin"))) {
                    _ = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw"))
                }
                expect(CryptFile.tooLargeMessage("big.bin").contains("volume"), CryptFile.tooLargeMessage("big.bin"))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["big.bin"])
                CryptFile.largestFileToEncrypt = 200
                _ = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw"))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["big.bin.crypt"])
            }
        },

        TestCase("encryptFile refuses folders and links") {
            try withTemporaryDirectory { dir in
                let folder = dir.appendingPathComponent("folder")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                expectThrows { _ = try CryptFile.encryptFile(at: folder, password: SecureBytes(string: "pw")) }
                let target = dir.appendingPathComponent("target.txt")
                try Data("target".utf8).write(to: target)
                let link = dir.appendingPathComponent("link.txt")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
                expectThrows { _ = try CryptFile.encryptFile(at: link, password: SecureBytes(string: "pw")) }
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["folder", "link.txt", "target.txt"])
            }
        },

        // MARK: open (R2, R3)

        TestCase("open gives the original name, kind, variant and hash") {
            let entry = try ReferenceFiles.text()
            try withTemporaryDirectory { dir in
                let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                let (opened, plain) = try CryptFile.open(at: url, password: SecureBytes(string: entry.password),
                                                         allowLegacy: true)
                expectEqual(opened.originalName, "notes.txt")
                expectEqual(opened.kind, .text)
                expectEqual(opened.variant, .current)
                expectEqual(opened.check, .confirmed)
                expectEqual(opened.url.resolvingSymlinksInPath().path, url.resolvingSymlinksInPath().path)
                expectEqual(opened.ciphertextSHA256.map { String(format: "%02x", $0) }.joined(),
                            CryptoTestKit.sha256Hex(try Data(contentsOf: url)))
                expectEqual(CryptoTestKit.sha256Hex(plain), entry.sha256)

                let backup = dir.appendingPathComponent("notes.txt.crypt.bak")
                try FileManager.default.copyItem(at: url, to: backup)
                expectEqual(try CryptFile.open(at: backup, password: SecureBytes(string: entry.password),
                                               allowLegacy: true).0.originalName, "notes.txt")
            }
        },

        TestCase("open reports a wrong password and never confirms garbage") {
            let entries = try ReferenceFiles.load().filter { $0.variant == "current" && $0.length > 0 }
            try withTemporaryDirectory { dir in
                for entry in entries where Plausibility.check(Data(), originalName: entry.originalName) != .unknownType {
                    let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                    for allowLegacy in [false, true] {
                        // about 1 in 256 wrong passwords passes the padding check; such a
                        // result comes back unconfirmed, for the user to judge
                        do {
                            let (opened, _) = try CryptFile.open(at: url, password: SecureBytes(string: entry.password + "!"),
                                                                 allowLegacy: allowLegacy)
                            expect(opened.check != .confirmed, "\(entry.file): a wrong password was confirmed")
                        } catch {
                            expectEqual(error as? CryptError, .wrongPassword, entry.file)
                        }
                    }
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("the right password always opens the file, even when Safe cannot confirm it") {
            // finding of the requirements review: these were refused as wrong passwords
            let latin1 = Data("Grüße aus Köln, ½ € fünf\n".unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            let cp1252 = Data([0x93, 0x51, 0x75, 0x6F, 0x74, 0x65, 0x94, 0x20, 0x80, 0x0A]) + latin1
            var utf16 = Data([0xFF, 0xFE])
            for unit in "Name;Wert\r\nÄpfel;3\r\n".utf16 {
                utf16.append(UInt8(unit & 0xFF))
                utf16.append(UInt8(unit >> 8))
            }
            let withNUL = Data("text with a NUL\u{0} inside\n".utf8)
            let binary = Data((0 ..< 999).map { UInt8(($0 * 37 + 11) & 0xFF) })
            let webp = Data(Array("RIFF".utf8) + [100, 0, 0, 0] + Array("WEBPVP8 ".utf8)) + CryptoTestKit.randomData(92)
            let cases: [(String, Data, [String], CryptVariant, PasswordCheck, FileKind)] = [
                ("notes.txt", latin1, CryptoTestKit.currentOptions, .current, .contentMismatch, .other),
                ("table.csv", utf16, CryptoTestKit.currentOptions, .current, .contentMismatch, .other),
                ("notes.txt", withNUL, CryptoTestKit.currentOptions, .current, .contentMismatch, .other),
                ("blob", binary, CryptoTestKit.currentOptions, .current, .contentMismatch, .other),
                ("photo.jpg", webp, CryptoTestKit.currentOptions, .current, .confirmed, .image),
                ("old.log", cp1252, ["-aes-256-cbc", "-md", "md5"], .legacyAESMD5, .contentMismatch, .other),
                ("old.txt", latin1, ["-aes-256-cbc", "-md", "md5", "-nosalt"], .legacyAESMD5, .contentMismatch, .other),
            ]
            let pw = "right-Paßwort"
            try withTemporaryDirectory { dir in
                for (name, plain, options, variant, check, kind) in cases {
                    let url = dir.appendingPathComponent(name + ".crypt")
                    try CryptoTestKit.opensslEncrypt(plain, password: pw, options: options).write(to: url)
                    defer { try? FileManager.default.removeItem(at: url) }
                    do {
                        // finding of review round 2: the old file was refused as a wrong password
                        let (opened, data) = try CryptFile.open(at: url, password: SecureBytes(string: pw), allowLegacy: true)
                        expectEqual(data, plain, name)
                        expectEqual(opened.kind, kind, name)
                        expectEqual(opened.variant, variant, name)
                        expectEqual(opened.check, check, name)
                    } catch {
                        fail("\(name): the right password was refused: \(error)")
                    }
                }
            }
        },

        TestCase("the right password opens old files in another encoding, and binary ones with padding") {
            // the probe of review round 2: 16 of 16 such files were refused as a wrong password
            let latin1 = Data("Grüße aus Köln, und bis bald im Frühjahr! Liebe Grüße\n".unicodeScalars.map {
                UInt8(truncatingIfNeeded: $0.value)
            })
            let macRoman = "Café crème für Jürgen, 5 € Trinkgeld, ohne Zeilenende.".data(using: .macOSRoman)!
            var utf16 = Data([0xFF, 0xFE])
            for unit in "Name;Wert\r\nÄpfel;3\r\nBirnen;5\r\n".utf16 {
                utf16.append(contentsOf: [UInt8(unit & 0xFF), UInt8(unit >> 8)])
            }
            // 998 bytes: 10 bytes of padding, which a wrong key nearly never leaves
            let binary = Data((0 ..< 998).map { UInt8(($0 * 37 + 11) & 0xFF) })
            let files: [(String, Data)] = [("notes.txt", latin1), ("safe", macRoman), ("table.csv", utf16),
                                           ("data", binary)]
            let variants: [(CryptVariant, [String])] = [
                (.legacyAESSHA256, ["-aes-256-cbc"]),        // today's openssl without -md and -pbkdf2
                (.legacyAESMD5, ["-aes-256-cbc", "-md", "md5"]),
                (.legacyAESMD5, ["-aes-256-cbc", "-md", "md5", "-nosalt"]),
                (.legacyRC4MD5, ["-rc4", "-md", "md5"]),
            ]
            let pw = "probe-pass-1"
            try withTemporaryDirectory { dir in
                for (variant, options) in variants {
                    for (name, plain) in files {
                        let label = "\(name), \(options.joined(separator: " "))"
                        let url = dir.appendingPathComponent(name + ".crypt")
                        try CryptoTestKit.opensslEncrypt(plain, password: pw, options: options).write(to: url)
                        defer { try? FileManager.default.removeItem(at: url) }
                        if variant == .legacyRC4MD5 && name == "data" {
                            // RC4 decrypts with any password; bytes that are not text cannot be
                            // told from garbage, so this opens only with openssl or safe-decrypt.py
                            let error = expectThrows(label) {
                                _ = try CryptFile.open(at: url, password: SecureBytes(string: pw), allowLegacy: true)
                            }
                            expectEqual(error as? CryptError, .wrongPasswordOrDamaged, label)
                            continue
                        }
                        do {
                            let (opened, data) = try CryptFile.open(at: url, password: SecureBytes(string: pw),
                                                                    allowLegacy: true)
                            expectEqual(data, plain, label)
                            expectEqual(opened.variant, variant, label)
                            expectEqual(opened.check, .contentMismatch, label)
                        } catch {
                            fail("\(label): the right password was refused: \(error)")
                        }
                    }
                }
            }
        },

        TestCase("a tiny unsalted old file opens; it is not taken for a plain file") {
            // finding of review round 2: "1234\n" encrypted without salt was "not encrypted"
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("pin.txt.crypt")
                let rc4 = try CryptoTestKit.opensslEncrypt(Data("1234\n".utf8), password: "pin-9",
                                                           options: ["-rc4", "-md", "md5", "-nosalt"])
                try rc4.write(to: url)
                let (o1, p1) = try CryptFile.open(at: url, password: SecureBytes(string: "pin-9"), allowLegacy: true)
                expectEqual(p1, Data("1234\n".utf8))
                expectEqual(o1.variant, .legacyRC4MD5)
                expectEqual(o1.check, .unchecked, "a short RC4 text needs the user's yes")
                let aes = try CryptoTestKit.opensslEncrypt(Data("1234\n".utf8), password: "pin-246",
                                                           options: ["-aes-256-cbc", "-md", "md5", "-nosalt"])
                try aes.write(to: url)
                let (o2, p2) = try CryptFile.open(at: url, password: SecureBytes(string: "pin-246"), allowLegacy: true)
                expectEqual(p2, Data("1234\n".utf8))
                expectEqual(o2.variant, .legacyAESMD5)
                expectEqual(o2.check, .confirmed)
            }
        },

        TestCase("a file whose type cannot be checked: one byte of padding needs the user's yes") {
            let pw = SecureBytes(string: "padding-rule")
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("data.bin.crypt")
                for (length, check) in [(31, PasswordCheck.unchecked), (30, .confirmed), (32, .confirmed), (4095, .unchecked)] {
                    let plain = Data((0 ..< length).map { UInt8(($0 * 13 + 200) & 0xFF) | 0x80 })
                    try OpenSSLFormat.encrypt(plain, password: pw).write(to: url)
                    let (opened, data) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                    expectEqual(data, plain, "\(length) bytes")
                    expectEqual(opened.check, check, "\(length) bytes: \(16 - length % 16) bytes of padding")
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("a short RC4 text needs the user's yes, a longer one opens") {
            let pw = "rc4-short"
            try withTemporaryDirectory { dir in
                for (text, check) in [("short note\n", PasswordCheck.unchecked),
                                      ("a longer note of more than thirty-two bytes\n", .confirmed)] {
                    let url = dir.appendingPathComponent("a.txt.crypt")
                    let data = try CryptoTestKit.opensslEncrypt(Data(text.utf8), password: pw,
                                                                options: ["-rc4", "-md", "md5", "-S", "0011223344556677"])
                    try data.write(to: url)
                    let (opened, plain) = try CryptFile.open(at: url, password: SecureBytes(string: pw), allowLegacy: true)
                    expectEqual(opened.variant, .legacyRC4MD5, text)
                    expectEqual(opened.check, check, text)
                    expectEqual(plain, Data(text.utf8))
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("open refuses a file that is not encrypted") {
            try withTemporaryDirectory { dir in
                let plain = dir.appendingPathComponent("notes.txt.crypt")
                let empty = dir.appendingPathComponent("empty.txt.crypt")
                let png = dir.appendingPathComponent("photo.png.crypt")
                try Data("just text, never encrypted\n".utf8).write(to: plain)
                try Data().write(to: empty)
                try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).write(to: png)
                for url in [plain, empty, png] {
                    for allowLegacy in [false, true] {
                        expectThrows(CryptError.notEncrypted, url.lastPathComponent) {
                            _ = try CryptFile.open(at: url, password: SecureBytes(string: "pw"), allowLegacy: allowLegacy)
                        }
                    }
                }
            }
        },

        TestCase("open reports a truncated file as corrupt") {
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("notes.txt.crypt")
                try Data("Salted__1234".utf8).write(to: url)
                for allowLegacy in [false, true] {
                    expectThrows(CryptError.corrupt, "no room for the salt") {
                        _ = try CryptFile.open(at: url, password: SecureBytes(string: "pw"), allowLegacy: allowLegacy)
                    }
                }
                let good = try OpenSSLFormat.encrypt(Data("some text, long enough to be cut short\n".utf8),
                                                     password: SecureBytes(string: "pw"))
                try good.prefix(good.count - 5).write(to: url)
                expectThrows(CryptError.corrupt, "not whole blocks") {
                    _ = try CryptFile.open(at: url, password: SecureBytes(string: "pw"), allowLegacy: false)
                }
                // as the app opens it: the right password is not called wrong, and the
                // message says that the file may be damaged (finding of review round 2)
                expectThrows(CryptError.wrongPasswordOrDamaged, "not whole blocks, older variants tried") {
                    _ = try CryptFile.open(at: url, password: SecureBytes(string: "pw"), allowLegacy: true)
                }
                // only the header: nothing can be right, not even an empty RC4 text
                try good.prefix(16).write(to: url)
                for allowLegacy in [false, true] {
                    expectThrows(CryptError.corrupt, "the header only") {
                        _ = try CryptFile.open(at: url, password: SecureBytes(string: "pw"), allowLegacy: allowLegacy)
                    }
                }
            }
        },

        // MARK: save (R2, building plan 5.3)

        TestCase("save keeps the previous version as .bak") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "save-Paßwort")
                let url = dir.appendingPathComponent("notes.txt.crypt")
                try OpenSSLFormat.encrypt(Data("version 1\n".utf8), password: pw).write(to: url)
                let v1 = try Data(contentsOf: url)
                var (opened, _) = try CryptFile.open(at: url, password: pw, allowLegacy: false)

                opened = try CryptFile.save(Data("version 2 äöü\n".utf8), over: opened, password: pw)
                let v2 = try Data(contentsOf: url)
                expectEqual(try Data(contentsOf: dir.appendingPathComponent("notes.txt.crypt.bak")), v1)
                expectEqual(try OpenSSLFormat.decryptCurrent(v2, password: pw), Data("version 2 äöü\n".utf8))
                expectEqual(opened.ciphertextSHA256.map { String(format: "%02x", $0) }.joined(), CryptoTestKit.sha256Hex(v2))
                expectEqual(opened.variant, .current)
                expectEqual(opened.originalName, "notes.txt")

                opened = try CryptFile.save(Data("version 3\n".utf8), over: opened, password: pw)
                expectEqual(try Data(contentsOf: dir.appendingPathComponent("notes.txt.crypt.bak")), v2)
                expectEqual(try CryptFile.open(at: url, password: pw, allowLegacy: false).1, Data("version 3\n".utf8))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["notes.txt.crypt", "notes.txt.crypt.bak"], "no .crypt_new is left")
                for name in ["notes.txt.crypt", "notes.txt.crypt.bak"] {
                    expectEqual(try FileManager.default.attributesOfItem(
                        atPath: dir.appendingPathComponent(name).path)[.posixPermissions] as? Int, 0o600, name)
                }
                expect(try CryptoTestKit.opensslDecrypt(Data(contentsOf: url), password: "save-Paßwort")
                       == Data("version 3\n".utf8), "/usr/bin/openssl reads the saved file")
            }
        },

        TestCase("save refuses when the file changed on disk") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "conflict")
                let url = dir.appendingPathComponent("notes.txt.crypt")
                try OpenSSLFormat.encrypt(Data("mine\n".utf8), password: pw).write(to: url)
                let (opened, _) = try CryptFile.open(at: url, password: pw, allowLegacy: false)
                let theirs = try OpenSSLFormat.encrypt(Data("theirs, from another Mac\n".utf8), password: pw)
                try theirs.write(to: url)
                expectThrows(CryptError.conflict) {
                    _ = try CryptFile.save(Data("my change\n".utf8), over: opened, password: pw)
                }
                expectEqual(try Data(contentsOf: url), theirs, "the other version is untouched")
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.txt.crypt"])

                try FileManager.default.removeItem(at: url)
                expectThrows(CryptError.conflict, "a file that is gone") {
                    _ = try CryptFile.save(Data("my change\n".utf8), over: opened, password: pw)
                }
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
            }
        },

        TestCase("save changes nothing when the check fails") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "check")
                let url = dir.appendingPathComponent("notes.txt.crypt")
                try OpenSSLFormat.encrypt(Data("before\n".utf8), password: pw).write(to: url)
                let before = try Data(contentsOf: url)
                let (opened, _) = try CryptFile.open(at: url, password: pw, allowLegacy: false)
                CryptFile.testHookFailCheck = true
                defer { CryptFile.testHookFailCheck = false }
                expectThrows(CryptError.checkFailed) {
                    _ = try CryptFile.save(Data("after\n".utf8), over: opened, password: pw)
                }
                expectEqual(try Data(contentsOf: url), before)
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["notes.txt.crypt"],
                            "no .bak and no .crypt_new")
            }
        },

        TestCase("save writes a legacy file in the current format") {
            let entry = try ReferenceFiles.first("an AES-MD5 text file") {
                $0.variant == "legacyAESMD5" && $0.originalName == "notes.txt" && $0.salted
            }
            try withTemporaryDirectory { dir in
                let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                let legacyBytes = try Data(contentsOf: url)
                let pw = SecureBytes(string: entry.password)
                let (opened, plain) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                expectEqual(opened.variant, .legacyAESMD5)
                // a stale .crypt_new from an interrupted save is replaced
                try Data("stale".utf8).write(to: URL(fileURLWithPath: url.path + "_new"))
                let saved = try CryptFile.save(plain, over: opened, password: pw)
                expectEqual(saved.variant, .current)
                expectEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".bak")), legacyBytes)
                expectEqual(try OpenSSLFormat.decryptCurrent(Data(contentsOf: url), password: pw), plain)
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["notes.txt.crypt", "notes.txt.crypt.bak"])
            }
        },

        TestCase("save writes an RC4 file in the current format") {
            let entry = try ReferenceFiles.first("an RC4-MD5 text file") {
                $0.variant == "legacyRC4MD5" && $0.originalName == "notes.txt" && $0.salted
            }
            try withTemporaryDirectory { dir in
                let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                let legacyBytes = try Data(contentsOf: url)
                let pw = SecureBytes(string: entry.password)
                let (opened, plain) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                expectEqual(opened.variant, .legacyRC4MD5)
                expectEqual(opened.check, .confirmed)
                let saved = try CryptFile.save(plain, over: opened, password: pw)
                expectEqual(saved.variant, .current)
                expectEqual(try Data(contentsOf: URL(fileURLWithPath: url.path + ".bak")), legacyBytes)
                let (again, data) = try CryptFile.open(at: url, password: pw, allowLegacy: false)
                expectEqual(again.variant, .current)
                expectEqual(again.check, .confirmed)
                expectEqual(data, plain)
                expect(try CryptoTestKit.opensslDecrypt(Data(contentsOf: url), password: entry.password) == plain,
                       "/usr/bin/openssl reads the saved file")
            }
        },

        TestCase("save can keep an existing .bak") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "keep-bak")
                let url = dir.appendingPathComponent("notes.txt.crypt")
                let backup = URL(fileURLWithPath: url.path + ".bak")
                try OpenSSLFormat.encrypt(Data("version 1\n".utf8), password: pw).write(to: url)
                let v1 = try Data(contentsOf: url)
                var (opened, _) = try CryptFile.open(at: url, password: pw, allowLegacy: false)
                opened = try CryptFile.save(Data("version 2\n".utf8), over: opened, password: pw, replacingBackup: false)
                expectEqual(try Data(contentsOf: backup), v1, "no .bak yet: it is written")
                opened = try CryptFile.save(Data("version 3\n".utf8), over: opened, password: pw, replacingBackup: false)
                expectEqual(try Data(contentsOf: backup), v1, "the .bak was replaced")
                expectEqual(try CryptFile.open(at: url, password: pw, allowLegacy: false).1, Data("version 3\n".utf8))
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["notes.txt.crypt", "notes.txt.crypt.bak"])
            }
        },

        TestCase("save through a link replaces the file, not the link") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "link")
                let real = dir.appendingPathComponent("real.txt.crypt")
                let link = dir.appendingPathComponent("notes.txt.crypt")
                try OpenSSLFormat.encrypt(Data("one\n".utf8), password: pw).write(to: real)
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
                let (opened, _) = try CryptFile.open(at: link, password: pw, allowLegacy: false)
                expectEqual(opened.originalName, "notes.txt")
                _ = try CryptFile.save(Data("two\n".utf8), over: opened, password: pw)
                expectEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), real.path)
                expectEqual(try CryptFile.open(at: link, password: pw, allowLegacy: false).1, Data("two\n".utf8))
            }
        },

        // MARK: export (R3)

        TestCase("export writes identical bytes") {
            try withTemporaryDirectory { dir in
                let data = CryptoTestKit.randomData(70_000)
                let target = dir.appendingPathComponent("exported.bin")
                try CryptFile.export(data, to: target)
                expectEqual(try Data(contentsOf: target), data)
                expectEqual(try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? Int, 0o600)
                let other = Data("replaced".utf8)
                try CryptFile.export(other, to: target)
                expectEqual(try Data(contentsOf: target), other, "an existing file is replaced")
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["exported.bin"],
                            "no temporary file is left")
                expectThrows("export into a missing folder") {
                    try CryptFile.export(data, to: dir.appendingPathComponent("missing/x.bin"))
                }
                // a copy left by a crash is visible and named after the target
                let temporary = CryptFile.exportTemporaryName(for: "notes.txt")
                expect(temporary.hasPrefix("notes.txt (exporting ") && temporary.hasSuffix(").tmp"), temporary)
                expect(CryptFile.exportTemporaryName(for: String(repeating: "é", count: 200)).utf8.count < 255)
            }
        },

        TestCase("encryptFile refuses a file with a resource fork, which it would lose") {
            try withTemporaryDirectory { dir in
                let original = dir.appendingPathComponent("old-mac-file")
                try Data("data fork\n".utf8).write(to: original)
                let fork = [UInt8]("resource fork".utf8)
                expectEqual(setxattr(original.path, XATTR_RESOURCEFORK_NAME, fork, fork.count, 0, 0), 0)
                let error = expectThrows { _ = try CryptFile.encryptFile(at: original, password: SecureBytes(string: "pw")) }
                if case CryptError.io(let message)? = error as? CryptError {
                    expect(message.contains("resource fork"), message)
                } else {
                    fail("\(String(describing: error))")
                }
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["old-mac-file"])
            }
        },

        // MARK: leak test (building plan 7.3)

        TestCase("no plaintext on disk after opening, viewing and editing") {
            let start = Date().addingTimeInterval(-2)
            var markers: [String] = []
            // a text in UTF-16 too, whose marker is searched for in UTF-16 as well
            let wanted: [(String, FileKind)] = [("notes.txt", .text), ("table.csv", .other), ("sample.pdf", .pdf),
                                                ("sample.png", .image), ("photo.jpg", .image), ("photo.heic", .image)]
            try withTemporaryDirectory { dir in
                for (name, kind) in wanted {
                    let entry = try ReferenceFiles.first(name) { $0.variant == "current" && $0.originalName == name }
                    let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                    let (opened, plain) = try CryptFile.open(at: url, password: SecureBytes(string: entry.password),
                                                             allowLegacy: true)
                    expectEqual(opened.kind, kind, name)
                    guard let marker = CryptoTestKit.marker(in: plain) else {
                        fail("\(name) holds no marker")
                        continue
                    }
                    markers.append(marker)
                    // what the viewer does: draw the PDF with PDFKit and the image with
                    // NSImage from memory, and also with CoreGraphics and ImageIO
                    switch kind {
                    case .pdf:
                        expect(LeakSearch.renderPDF(plain), "\(name) does not render")
                        expect(LeakSearch.renderWithPDFKit(plain), "\(name) does not render in PDFKit")
                    case .image:
                        expect(LeakSearch.renderImage(plain), "\(name) does not render")
                        expect(LeakSearch.renderWithNSImage(plain), "\(name) does not render as an NSImage")
                    default: break
                    }
                }
            }
            // the viewer itself, in the app: PDFView and NSImageView in windows that
            // are never shown, over the same reference files
            do {
                let viewer = try AppShellTests.runSafe(["--app-tests", "child:viewer-leak"])
                expectEqual(viewer.status, 0, viewer.output + viewer.errorOutput)
                if viewer.output.contains("no window server") {
                    print("     the viewer windows were not checked: no window server")
                } else {
                    expect(viewer.output.contains("viewed sample.pdf, sample.png, photo.jpg, photo.heic"),
                           viewer.output + viewer.errorOutput)
                }
            } catch let skipped as TestSkipped {
                print("     the viewer windows were not checked: \(skipped.reason)")
            }
            // the editor, in the app: typing a marker made at run time, searching for it,
            // copying it, saving, locking, unlocking and saving again
            do {
                let editor = try AppShellTests.runSafe(["--app-tests", "child:editor-leak"])
                expectEqual(editor.status, 0, editor.output + editor.errorOutput)
                if editor.output.contains("no window server") {
                    print("     the editor was not checked: no window server")
                } else if let line = editor.output.split(separator: "\n").first(where: { $0.hasPrefix("typed ") }) {
                    markers.append(String(line.dropFirst("typed ".count)))
                } else {
                    fail("the editor child named no marker: " + editor.output + editor.errorOutput)
                }
            } catch let skipped as TestSkipped {
                print("     the editor was not checked: \(skipped.reason)")
            }
            Thread.sleep(forTimeInterval: 1)
            // with a deadline: a search over all files once hung in open()
            // on some file, perhaps waiting for a permission dialog
            let search = LeakSearch.Run(markers, changedSince: start)
            guard let (hits, files) = search.wait(seconds: 240) else {
                fail("the search did not finish in 240 s; it hangs opening \(search.current)")
                return
            }
            expectEqual(hits, [], "a marker of a decrypted file was found on disk")
            print("     searched \(files) files changed during the test for \(markers.count) markers, "
                  + "in UTF-8 and UTF-16")
        },
    ]

    /// Findings of review round 3: damaged files, old RC4 files, short Latin-1
    /// texts, pictures under other names, hard links.
    private static let roundThree: [TestCase] = [
        TestCase("a file cut short at a block boundary is called damaged, not a wrong password") {
            // finding of review round 3: copies and downloads stop at 4 KiB or 64 KiB, which
            // are whole blocks, and the right password was then called wrong
            var text = Data()
            while text.count < 70_000 {
                text += Data("Grüße aus Köln — Zeile \(text.count)\n".utf8)
            }
            // every other byte boundary cuts a two-byte character
            let umlauts = Data(("a" + String(repeating: "ü", count: 40_000)).utf8)
            let pdf = Data("%PDF-1.4\n".utf8) + CryptoTestKit.randomData(70_000)
            let pw = SecureBytes(string: "safetest-cut")
            let wrong = SecureBytes(string: "safetest-wrong")
            try withTemporaryDirectory { dir in
                let files: [(String, Data)] = [("notes.txt", text), ("cut.txt", umlauts), ("report.pdf", pdf)]
                for (name, plain) in files {
                    let whole = try OpenSSLFormat.encrypt(plain, password: pw)
                    let url = dir.appendingPathComponent(name + ".crypt")
                    for cut in [4096, 65536] {
                        let label = "\(name) cut at \(cut)"
                        try whole.prefix(cut).write(to: url)
                        for allowLegacy in [true, false] {
                            expectThrows(CryptError.damaged, "\(label), allowLegacy \(allowLegacy)") {
                                _ = try CryptFile.open(at: url, password: pw, allowLegacy: allowLegacy)
                            }
                        }
                        // what can be read: everything but the last block of what is left
                        let part = try CryptFile.readablePart(at: url, password: pw)
                        expectEqual(part.originalName, name, label)
                        expect(part.data == plain.prefix(cut - 32), "\(label): not the start of the file")
                        // a wrong password is not told that the file is damaged
                        do {
                            let (opened, _) = try CryptFile.open(at: url, password: wrong, allowLegacy: true)
                            expect(opened.check != .confirmed, "\(label): a wrong password was confirmed")
                        } catch {
                            expectEqual(error as? CryptError, .wrongPassword, label)
                        }
                        expectThrows(CryptError.wrongPassword, "\(label): the readable part of a wrong password") {
                            _ = try CryptFile.readablePart(at: url, password: wrong)
                        }
                    }
                    // intact, it opens as before
                    try whole.write(to: url)
                    let (opened, data) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                    expectEqual(opened.check, .confirmed, name)
                    expect(data == plain, name)
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("an old RC4 file of a type Safe cannot check opens only for export, by its variant") {
            // finding of review round 3 (G5): RC4 files of such a type, whose length is whole
            // blocks or which have no salt, never opened, even with the right password
            let pw = "safetest-rc4"
            try withTemporaryDirectory { dir in
                let files: [(String, Int, [String])] = [
                    ("keys.bin", 4080, ["-rc4", "-md", "md5", "-S", "0011223344556677"]),
                    ("vault.kdbx", 8192, ["-rc4", "-md", "md5", "-nosalt"]),
                    ("notes.dat", 9000, ["-rc4", "-md", "sha256", "-S", "8899aabbccddeeff"]),
                ]
                for (name, length, options) in files {
                    let plain = Data((0 ..< length).map { UInt8(($0 * 7 + 3) & 0xFF) })
                    let url = dir.appendingPathComponent(name + ".crypt")
                    try CryptoTestKit.opensslEncrypt(plain, password: pw, options: options).write(to: url)
                    let variant: CryptVariant = options.contains("md5") ? .legacyRC4MD5 : .legacyRC4SHA256
                    if length % 16 == 0 {
                        expectThrows(CryptError.wrongPassword, name) {
                            _ = try CryptFile.open(at: url, password: SecureBytes(string: pw), allowLegacy: true)
                        }
                    }
                    expect(CryptFile.mayBeOldRC4(at: url), "\(name) is not offered as an old RC4 file")
                    let result = try CryptFile.decryptOldRC4(at: url, password: SecureBytes(string: pw), variant: variant)
                    expectEqual(result.originalName, name)
                    expect(result.data == plain, "\(name): not the original")
                    try FileManager.default.removeItem(at: url)
                }
                // a PDF starts with %PDF-, so RC4 would have opened it: not offered
                let pdf = dir.appendingPathComponent("r.pdf.crypt")
                try OpenSSLFormat.encrypt(Data("%PDF-1.4\n".utf8), password: SecureBytes(string: pw)).write(to: pdf)
                expect(!CryptFile.mayBeOldRC4(at: pdf), "a PDF is offered")
                // nothing after the header: nothing to decrypt
                let empty = dir.appendingPathComponent("e.bin.crypt")
                try Data("Salted__12345678".utf8).write(to: empty)
                expect(!CryptFile.mayBeOldRC4(at: empty), "a file with nothing after its header is offered")
                expect(CryptFile.mayBeOldRC4(at: dir.appendingPathComponent("plain.txt.crypt")) == false,
                       "a missing file is offered")
            }
        },

        TestCase("a short Latin-1 text opens as itself, never as RC4 bytes that happen to be UTF-8") {
            // finding of review round 3: found by trying salts, "Grüße" and a line feed in ISO
            // Latin-1, password safetest-right, whose RC4-MD5 reading is valid UTF-8. That
            // reading was kept as text and beat the right result of the current format
            let hex = "53616c7465645f5f6281c73ca07aaee64eaa26c1ed2f574051866d5c26e953af"
            let file = bytes(fromHex: hex)
            let latin1 = Data([0x47, 0x72, 0xFC, 0xDF, 0x65, 0x0A] as [UInt8])
            // the file still is such a case: RC4 with an MD5 key gives UTF-8 without NUL
            let rc4 = try CryptoTestKit.opensslDecrypt(file, password: "safetest-right", options: ["-rc4", "-md", "md5"])
            let reading = rc4 ?? Data([0])
            expect(String(data: reading, encoding: .utf8) != nil && !reading.contains(0),
                   "the file no longer reproduces the finding")
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("pin.txt.crypt")
                try file.write(to: url)
                let (opened, data) = try CryptFile.open(at: url, password: SecureBytes(string: "safetest-right"),
                                                        allowLegacy: true)
                expectEqual(opened.variant, .current)
                expectEqual(opened.check, .contentMismatch)
                expectEqual(data, latin1)
            }
        },

        TestCase("a picture or gzip under another name is confirmed in the current format") {
            // finding of review round 3: a JPEG saved without an ending got "The password is
            // probably not right" every time
            let jfif: [UInt8] = [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]
            let jpeg = Data(jfif) + CryptoTestKit.randomData(500)
            let gzip = Data([0x1F, 0x8B, 0x08, 0x00] as [UInt8]) + CryptoTestKit.randomData(300)
            let pw = SecureBytes(string: "safetest-picture")
            try withTemporaryDirectory { dir in
                let files: [(String, Data, FileKind)] = [("photo", jpeg, .image), ("scan.txt", jpeg, .image),
                                                         ("download", gzip, .other), ("data.bin", gzip, .other)]
                for (name, plain, kind) in files {
                    let url = dir.appendingPathComponent(name + ".crypt")
                    try OpenSSLFormat.encrypt(plain, password: pw).write(to: url)
                    let (opened, data) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                    expectEqual(opened.check, .confirmed, name)
                    expectEqual(opened.kind, kind, name)
                    expect(data == plain, name)
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("encryptFile refuses a file with other names, which would keep the plaintext") {
            // finding of review round 3: another hard link kept the plaintext on the disk
            try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("linked.txt")
                let other = dir.appendingPathComponent("other name.txt")
                try Data("safetest linked\n".utf8).write(to: file)
                try FileManager.default.linkItem(at: file, to: other)
                let error = expectThrows("a file with two names was encrypted") {
                    _ = try CryptFile.encryptFile(at: file, password: SecureBytes(string: "pw"))
                }
                if case CryptError.io(let message)? = error as? CryptError {
                    expect(message.contains("hard links"), message)
                } else {
                    fail("\(String(describing: error))")
                }
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["linked.txt", "other name.txt"])
            }
        },

    ]

    private static let roundFour: [TestCase] = [
        TestCase("a file cut inside a block is called damaged, and its readable part ends before the cut") {
            // finding of review round 4: a cut at any offset but a block boundary was
            // called a wrong password, so the readable part could not be recovered
            var text = Data()
            while text.count < 10_000 {
                text += Data("Grüße aus Köln — Zeile \(text.count)\n".utf8)
            }
            let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + CryptoTestKit.randomData(10_000)
            let pw = SecureBytes(string: "safetest-cut")
            let wrong = SecureBytes(string: "safetest-wrong")
            try withTemporaryDirectory { dir in
                for (name, plain) in [("notes.txt", text), ("photo.png", png)] {
                    let whole = try OpenSSLFormat.encrypt(plain, password: pw)
                    let url = dir.appendingPathComponent(name + ".crypt")
                    for cut in [7, 1000] {
                        let label = "\(name) cut by \(cut)"
                        try whole.prefix(whole.count - cut).write(to: url)
                        for allowLegacy in [true, false] {
                            expectThrows(CryptError.damaged, "\(label), allowLegacy \(allowLegacy)") {
                                _ = try CryptFile.open(at: url, password: pw, allowLegacy: allowLegacy)
                            }
                        }
                        // whole blocks only, and without the last of them
                        let body = whole.count - cut - 16
                        let part = try CryptFile.readablePart(at: url, password: pw)
                        expect(part.data == plain.prefix(body / 16 * 16 - 16), "\(label): not the start of the file")
                        // a wrong password is not told that the file is damaged
                        do {
                            let (opened, _) = try CryptFile.open(at: url, password: wrong, allowLegacy: true)
                            expect(opened.check != .confirmed, "\(label): a wrong password was confirmed")
                        } catch {
                            expectEqual(error as? CryptError, .wrongPasswordOrDamaged, label)
                        }
                        expectThrows(CryptError.wrongPassword, "\(label): the readable part of a wrong password") {
                            _ = try CryptFile.readablePart(at: url, password: wrong)
                        }
                    }
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("a cut file whose start Safe cannot recognise can be exported in part, unchecked") {
            // finding of review round 4: a .bin or .kdbx cut short was a wrong password, and
            // the second try offered only an RC4 export, garbage for such a file
            let plain = Data(Array("KeePass".utf8)) + CryptoTestKit.randomData(10_000)
            let pw = SecureBytes(string: "safetest-cut-bin")
            let wrong = SecureBytes(string: "safetest-wrong")
            try withTemporaryDirectory { dir in
                let whole = try OpenSSLFormat.encrypt(plain, password: pw)
                for name in ["data.bin", "vault.kdbx"] {
                    let url = dir.appendingPathComponent(name + ".crypt")
                    for length in [4096, 4096 - 7] {
                        let label = "\(name), \(length) bytes"
                        try whole.prefix(length).write(to: url)
                        // never confirmed: a wrong password, or an unconfirmed RC4 or AES result
                        do {
                            let (opened, _) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                            expect(opened.check != .confirmed, "\(label): garbage was confirmed")
                        } catch {
                            expect([CryptError.wrongPassword, .wrongPasswordOrDamaged].contains(error as? CryptError),
                                   "\(label): \(error)")
                        }
                        expect(CryptFile.mayBeCutShort(at: url), "\(label) is not offered as cut short")
                        expectThrows(CryptError.wrongPassword, "\(label): checked although the start is unknown") {
                            _ = try CryptFile.readablePart(at: url, password: pw)
                        }
                        let part = try CryptFile.readablePart(at: url, password: pw, checked: false)
                        expectEqual(part.originalName, name, label)
                        expect(part.data == plain.prefix((length - 16) / 16 * 16 - 16), "\(label): not the start")
                        expect(try CryptFile.readablePart(at: url, password: wrong, checked: false).data
                               != part.data, "\(label): the same part for a wrong password")
                    }
                    try FileManager.default.removeItem(at: url)
                }
                // not for a type whose start Safe recognises, a file without salt, or one too short
                let pdf = dir.appendingPathComponent("r.pdf.crypt")
                try whole.prefix(4096).write(to: pdf)
                expect(!CryptFile.mayBeCutShort(at: pdf), "a PDF is offered")
                let unsalted = dir.appendingPathComponent("u.bin.crypt")
                try CryptoTestKit.opensslEncrypt(plain, password: "pw", options: ["-aes-256-cbc", "-md", "md5", "-nosalt"])
                    .write(to: unsalted)
                expect(!CryptFile.mayBeCutShort(at: unsalted), "an unsalted file is offered")
                let short = dir.appendingPathComponent("s.bin.crypt")
                try whole.prefix(16 + 31).write(to: short)
                expect(!CryptFile.mayBeCutShort(at: short), "a file with one whole block is offered")
            }
        },

        TestCase("an RC4 file that an AES variant opens by chance is still offered as RC4") {
            // finding of review round 4: the reviewer's file, salt 0000000000000003; with the
            // right password AES with a SHA-256 key passes its padding check, the result is
            // kept unchecked, and the RC4 content was out of reach in the app
            let plain = Data((0 ..< 4096).map { UInt8(($0 * 7 + 3) & 0xFF) })
            let file = try CryptoTestKit.opensslEncrypt(plain, password: "unknown-type",
                                                        options: ["-rc4", "-md", "md5", "-S", "0000000000000003"])
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("data.bin.crypt")
                try file.write(to: url)
                let pw = SecureBytes(string: "unknown-type")
                let (opened, data) = try CryptFile.open(at: url, password: pw, allowLegacy: true)
                expectEqual(opened.variant, .legacyAESSHA256, "the file no longer reproduces the finding")
                expectEqual(opened.check, .unchecked)
                expectEqual(data.count, 4095)
                expect(CryptFile.mayBeOldRC4(at: url), "not offered as an old RC4 file")
                expect(try CryptFile.decryptOldRC4(at: url, password: pw, variant: .legacyRC4MD5).data == plain,
                       "the RC4 reading is not the original")
            }
        },

        TestCase("a short text is confirmed only where a wrong password could not give it") {
            // finding of review round 4: 15 random bytes are UTF-8 without NUL once in 6,600
            // tries, so with three AES attempts about 1 in 550,000 wrong passwords was
            // confirmed as the text of a short file
            for name in ["pin.txt", "safe", "a.json"] {
                expectEqual(Plausibility.check(Data([0x37, 0x7D, 0x1F, 0x46, 0x53, 0x52, 0x02]), originalName: name),
                            .implausible, name)
                expectEqual(Plausibility.check(Data("tab\tand CR\r\nform\u{0C}".utf8), originalName: name),
                            .plausible, name)
                // longer texts keep the plain rule: a log with escape codes
                expectEqual(Plausibility.check(Data("\u{1B}[31mred\u{1B}[0m and a long enough line\n".utf8),
                                               originalName: name), .plausible, name)
            }
            try withTemporaryDirectory { dir in
                let url = dir.appendingPathComponent("pin.txt.crypt")
                let cases: [(String, [String], CryptVariant, PasswordCheck)] = [
                    ("123456789012345", CryptoTestKit.currentOptions, .current, .unchecked),        // 15 bytes, padding 1
                    ("12345678901234", CryptoTestKit.currentOptions, .current, .confirmed),        // padding 2
                    ("1234567890123456789012345678901", CryptoTestKit.currentOptions, .current, .confirmed),
                    ("123456789012345", ["-aes-256-cbc", "-md", "md5"], .legacyAESMD5, .unchecked),
                    ("1234-5678", ["-aes-256-cbc", "-md", "md5", "-nosalt"], .legacyAESMD5, .confirmed),
                ]
                for (text, options, variant, check) in cases {
                    try CryptoTestKit.opensslEncrypt(Data(text.utf8), password: "safetest-pin", options: options)
                        .write(to: url)
                    let (opened, data) = try CryptFile.open(at: url, password: SecureBytes(string: "safetest-pin"),
                                                            allowLegacy: true)
                    expectEqual(data, Data(text.utf8), text)
                    expectEqual(opened.variant, variant, text)
                    expectEqual(opened.check, check, text)
                }
                // the reviewer's case: this wrong password gave 15 bytes with two control
                // bytes, confirmed as the text of a PIN in AES with an MD5 key
                try CryptoTestKit.opensslEncrypt(Data("1234-5678".utf8), password: "Pässwört-ñ-日本",
                                                 options: ["-aes-256-cbc", "-md", "md5", "-nosalt"]).write(to: url)
                let wrong = "f🔐 R@}Y$Qy%H9_,FAs}6f"
                do {
                    let (opened, _) = try CryptFile.open(at: url, password: SecureBytes(string: wrong), allowLegacy: true)
                    expect(opened.check != .confirmed, "a wrong password was confirmed as \(opened.variant)")
                } catch {
                    expectEqual(error as? CryptError, .wrongPassword)
                }
            }
        },
    ]

    static let children: [String: () -> Int32] = [
        // used by make-fixtures.sh: the picture SAFETEST_FIXTURE_IN as
        // SAFETEST_FIXTURE_TYPE (public.jpeg or public.heic) in SAFETEST_FIXTURE_OUT,
        // with SAFETEST_FIXTURE_MARKER in its EXIF description, where the leak test
        // finds it in the file's bytes
        "fixtures/picture": {
            let env = ProcessInfo.processInfo.environment
            guard let input = env["SAFETEST_FIXTURE_IN"], let output = env["SAFETEST_FIXTURE_OUT"],
                  let type = env["SAFETEST_FIXTURE_TYPE"], let marker = env["SAFETEST_FIXTURE_MARKER"] else {
                FileHandle.standardError.write(Data("set SAFETEST_FIXTURE_IN, _OUT, _TYPE and _MARKER\n".utf8))
                return 2
            }
            guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: input) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                FileHandle.standardError.write(Data("fixtures/picture: cannot read \(input)\n".utf8))
                return 1
            }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else {
                FileHandle.standardError.write(Data("fixtures/picture: this Mac cannot write \(type)\n".utf8))
                return 1
            }
            let properties: [CFString: Any] = [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFImageDescription: marker],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: marker],
            ]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination), (data as Data).range(of: Data(marker.utf8)) != nil else {
                FileHandle.standardError.write(Data("fixtures/picture: \(type) without the marker\n".utf8))
                return 1
            }
            do {
                try (data as Data).write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
                return 0
            } catch {
                FileHandle.standardError.write(Data("fixtures/picture: \(error)\n".utf8))
                return 1
            }
        },

        // used by make-fixtures.sh: encrypt SAFETEST_FIXTURE_IN to
        // SAFETEST_FIXTURE_OUT with the app's code; the password is the
        // first line of stdin
        "fixtures/encrypt": {
            let env = ProcessInfo.processInfo.environment
            guard let input = env["SAFETEST_FIXTURE_IN"], let output = env["SAFETEST_FIXTURE_OUT"] else {
                FileHandle.standardError.write(Data("set SAFETEST_FIXTURE_IN and SAFETEST_FIXTURE_OUT\n".utf8))
                return 2
            }
            var line = FileHandle.standardInput.readDataToEndOfFile()
            if line.last == 0x0A { line.removeLast() }
            do {
                let plain = try Data(contentsOf: URL(fileURLWithPath: input))
                let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(Array(line)))
                try encrypted.write(to: URL(fileURLWithPath: output), options: .withoutOverwriting)
                return 0
            } catch {
                FileHandle.standardError.write(Data("fixtures/encrypt: \(error)\n".utf8))
                return 1
            }
        },
    ]
}

/// Searches the places where a decrypted file could leak to disk.
enum LeakSearch {
    /// ~/Library is searched where this process or the system could write
    /// for it: not ~/Library/Containers and the other places of other apps,
    /// whose reading can bring up a permission dialog, nor cloud folders,
    /// whose reading downloads files.
    static func roots() -> [String] {
        let library = NSHomeDirectory() + "/Library/"
        var roots = ["Caches", "Preferences", "Logs", "Saved Application State", "Autosave Information",
                     "HTTPStorages", "WebKit", "Application Support/SafeDocker"].map { library + $0 }
        roots.append(NSTemporaryDirectory())
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            roots.append(String(cString: buffer))
        }
        roots.append("/private/tmp")
        return roots.map { ($0 as NSString).standardizingPath }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// Compiler output of the builds, large and of no interest here.
    static var skipped: Set<String> {
        [NSHomeDirectory() + "/Library/Caches/SafeDocker-build"]
    }

    /// A search on a thread of its own, so that the test can give up if it hangs.
    final class Run {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var path = ""
        private var result: ([String], Int)?

        init(_ needles: [String], changedSince: Date) {
            Thread.detachNewThread { [self] in
                let found = LeakSearch.find(needles, changedSince: changedSince) { path in
                    self.lock.lock()
                    self.path = path
                    self.lock.unlock()
                }
                lock.lock()
                result = found
                lock.unlock()
                done.signal()
            }
        }

        /// The file being opened.
        var current: String {
            lock.lock()
            defer { lock.unlock() }
            return path
        }

        /// The hits and the number of files read, or nil after the deadline.
        func wait(seconds: Double) -> ([String], Int)? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return result
        }
    }

    /// Files under the roots that contain one of the needles, and the number
    /// of files read. Only files of this user written or changed since
    /// `changedSince` are read, which is what a leak from this process
    /// would be; `willOpen` hears of each.
    static func find(_ needles: [String], changedSince: Date, willOpen: (String) -> Void) -> ([String], Int) {
        // each needle in UTF-8 and in UTF-16 of both byte orders, as text in memory
        // and in many files is stored
        let patterns = needles.flatMap { needle -> [[UInt8]] in
            let units = Array(needle.utf16)
            return [Array(needle.utf8), units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] },
                    units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }]
        }
        guard let longest = patterns.map(\.count).max(), longest > 0 else { return ([], 0) }
        let cutoff = Int(changedSince.timeIntervalSince1970)
        let me = getuid()
        var paths: [UnsafeMutablePointer<CChar>?] = roots().map { strdup($0) } + [nil]
        defer { paths.forEach { free($0) } }
        guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return ([], 0) }
        defer { fts_close(fts) }
        let skip = skipped
        var hits: [String] = []
        var count = 0
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while let entry = fts_read(fts) {
            let info = Int32(entry.pointee.fts_info)
            if info == FTS_D {
                if skip.contains(String(cString: entry.pointee.fts_path)) {
                    fts_set(fts, entry, FTS_SKIP)
                }
                continue
            }
            guard info == FTS_F, let st = entry.pointee.fts_statp?.pointee, st.st_uid == me,
                  max(st.st_mtimespec.tv_sec, st.st_ctimespec.tv_sec) >= cutoff, st.st_size <= 1 << 30
            else { continue }
            let path = String(cString: entry.pointee.fts_path)
            willOpen(path)
            count += 1
            if contains(path, patterns, longest, &buffer) {
                hits.append(path)
            }
        }
        return (hits, count)
    }

    /// Reads the file in pieces that overlap by the length of the longest needle.
    static func contains(_ path: String, _ patterns: [[UInt8]], _ longest: Int, _ buffer: inout [UInt8]) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var kept = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + kept, $0.count - kept) }
            if n <= 0 { return false }
            let filled = kept + n
            let found = buffer.withUnsafeBytes { b in
                patterns.contains { p in
                    p.withUnsafeBytes { memmem(b.baseAddress, filled, $0.baseAddress, p.count) != nil }
                }
            }
            if found { return true }
            kept = min(longest - 1, filled)
            _ = buffer.withUnsafeMutableBytes { b in
                memmove(b.baseAddress, b.baseAddress! + filled - kept, kept)
            }
        }
    }

    /// Draws page 1 of a PDF into a bitmap in memory, as the viewer would.
    static func renderPDF(_ data: Data) -> Bool {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1), let context = bitmap(200, 100) else { return false }
        context.drawPDFPage(page)
        return true
    }

    /// Decodes an image with ImageIO, as NSImage does, and draws it into a bitmap.
    static func renderImage(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = bitmap(image.width, image.height) else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }

    /// Draws page 1 of a PDF with PDFKit, as PDFView does, and makes its thumbnail.
    static func renderWithPDFKit(_ data: Data) -> Bool {
        guard let document = PDFDocument(data: data), let page = document.page(at: 0),
              let context = bitmap(200, 260) else { return false }
        page.draw(with: .mediaBox, to: context)
        let thumbnail = page.thumbnail(of: NSSize(width: 120, height: 160), for: .mediaBox)
        return thumbnail.size.width > 0
    }

    /// Decodes an image with NSImage, as the viewer's NSImageView does, and draws it.
    static func renderWithNSImage(_ data: Data) -> Bool {
        guard let image = NSImage(data: data), image.size.width > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return false }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return true
    }

    static func bitmap(_ width: Int, _ height: Int) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}

/// The bytes of a string of hex digits, two per byte.
func bytes(fromHex hex: String) -> Data {
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index ..< next], radix: 16)!)
        index = next
    }
    return data
}
