import CommonCrypto
import Foundation
import SafeCore

// WP1: the format and the legacy variants (building plan 7.1): round trip,
// every fixture decrypts to the manifest's hash, files the app makes decrypt
// with /usr/bin/openssl and the Docker image, 2000 wrong passwords never pass,
// strict padding, empty file, 1 MB file, each legacy fixture opens with the
// right variant.

enum CryptoTests: TestSuite {
    static let name = "crypto"

    static let tests: [TestCase] = [
        // MARK: format

        TestCase("round trip at block boundaries") {
            for size in [0, 1, 15, 16, 17, 31, 32, 33, 1000, 4101] {
                let plain = CryptoTestKit.randomData(size)
                let password = SecureBytes(string: "pw-\(size)-ü")
                let a = try OpenSSLFormat.encrypt(plain, password: password)
                let b = try OpenSSLFormat.encrypt(plain, password: password)
                expectEqual(a.count, 16 + (size / 16 + 1) * 16, "size \(size)")
                expect(a.prefix(8) == Data("Salted__".utf8), "size \(size): header")
                expect(a != b, "size \(size): two encryptions should differ by their salt")
                expectEqual(try OpenSSLFormat.decryptCurrent(a, password: password), plain, "size \(size)")
                expectEqual(try OpenSSLFormat.decryptCurrent(b, password: password), plain, "size \(size)")
            }
        },

        TestCase("the layout matches an independent derivation") {
            // key and IV from PBKDF2 computed here, the cipher from CommonCrypto directly
            let password = Array("indépendant".utf8)
            let plain = Data("compare with a second implementation\n".utf8)
            let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(password))
            let salt = Array(encrypted[8 ..< 16])
            let keyIV = Reference.pbkdf2(password, salt)
            let decrypted = Reference.aes(CCOperation(kCCDecrypt), keyIV, Array(encrypted[16...]), padding: true)
            expectEqual(decrypted.map { Data($0) }, plain)

            let made = Data("Salted__".utf8) + salt +
                Reference.aes(CCOperation(kCCEncrypt), keyIV, Array(plain), padding: true)!
            expectEqual(made, encrypted, "the same salt must give the same bytes")
        },

        TestCase("the worked example of docs/format.md") {
            let file = Data([0x53, 0x61, 0x6c, 0x74, 0x65, 0x64, 0x5f, 0x5f, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
                             0x28, 0xae, 0x1a, 0x6a, 0xf8, 0x60, 0x20, 0x57, 0xb7, 0xf1, 0xef, 0x7d, 0x86, 0x38, 0x9a, 0x50])
            expectEqual(try OpenSSLFormat.decryptCurrent(file, password: SecureBytes(string: "safetest")),
                        Data("hello\n".utf8))
            let keyIV = Reference.pbkdf2(Array("safetest".utf8), [1, 2, 3, 4, 5, 6, 7, 8])
            expectEqual(keyIV.map { String(format: "%02x", $0) }.joined(),
                        "190d11c6016143d648000169550c96ed86ce07e03d5694b28c39651a60d7ef1f"
                            + "120b32f1ec3ca941f349f48006ae08b3")
        },

        TestCase("every reference file decrypts to the manifest's hash") {
            let entries = try ReferenceFiles.load()
            expect(entries.count >= 30, "only \(entries.count) reference files")
            for entry in entries {
                guard let variant = entry.cryptVariant else {
                    fail("\(entry.file): unknown variant \(entry.variant)")
                    continue
                }
                let data = try entry.data()
                expectEqual(data.prefix(8) == Data("Salted__".utf8), entry.salted, "\(entry.file): salted")
                expect(entry.file.hasPrefix(entry.file.split(separator: "-")[0] + "-\(entry.variant)-"),
                       "\(entry.file): name does not follow <generator>-<variant>-<n>.enc")
                let password = SecureBytes(string: entry.password)
                let plain = variant == .current
                    ? try OpenSSLFormat.decryptCurrent(data, password: password)
                    : try OpenSSLFormat.decryptLegacy(data, password: password, variant: variant)
                expectEqual(plain.count, entry.length, entry.file)
                expectEqual(CryptoTestKit.sha256Hex(plain), entry.sha256, entry.file)
            }
        },

        TestCase("the reference files cover every generator and variant") {
            let entries = try ReferenceFiles.load()
            let generators = Set(entries.map { String($0.file.split(separator: "-")[0]) })
            expectEqual(generators, ["openssl3", "libressl", "cryptsh", "app"])
            expectEqual(Set(entries.map(\.variant)), Set(CryptVariant.allCases.map(\.rawValue)))
            for variant in CryptVariant.allCases where variant != .current {
                let some = entries.filter { $0.variant == variant.rawValue }
                expect(some.contains { $0.salted }, "no salted \(variant)")
                expect(some.contains { !$0.salted }, "no unsalted \(variant)")
            }
            for generator in ["openssl3", "libressl", "cryptsh", "app"] {
                let made = entries.filter { $0.file.hasPrefix(generator + "-") }
                expect(made.contains { $0.variant == "current" && $0.length == 0 }, "\(generator): no empty file")
                expect(made.contains { $0.password.unicodeScalars.contains { !$0.isASCII } },
                       "\(generator): no non-ASCII password")
            }
            expect(entries.contains { $0.length >= 1_048_576 }, "no 1 MB file")
            expect(entries.contains { $0.originalName.hasSuffix(".pdf") }, "no PDF")
            expect(entries.contains { $0.originalName.hasSuffix(".png") }, "no PNG")
            expect(entries.contains { !$0.originalName.contains(".") }, "no file without an ending")
            expect(entries.contains { $0.generator.hasPrefix("crypt.sh 1.5") }, "nothing from crypt.sh 1.5")
        },

        TestCase("files the app makes decrypt with /usr/bin/openssl") {
            let cases: [(Data, String)] = [
                (Data("Grüße aus dem Safe, 日本語 🔐\nzweite Zeile\n".utf8), "Paßwort-ü-🔐"),
                (Data(), "empty-file-pw"),
                (CryptoTestKit.randomData(1_048_576), "one MiB"),
                (CryptoTestKit.randomData(4097), "a b $HOME !x %s `q`"),
            ]
            for (plain, pw) in cases {
                let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(string: pw))
                let decrypted = try CryptoTestKit.opensslDecrypt(encrypted, password: pw)
                expect(decrypted == plain, "\(plain.count) bytes with password \(pw)")
                expect(try CryptoTestKit.opensslDecrypt(encrypted, password: pw + "x") != plain,
                       "openssl accepted a wrong password")
            }
        },

        TestCase("files the app makes decrypt in the Docker image with openssl and crypt.sh") {
            let plain = Data("Docker check: Grüße, 日本語, 🔐\nline two\n".utf8)
            let pw = "Paßwort-日本-🔐 x"
            let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(string: pw))
            let openssl = try CryptoTestKit.inDocker(
                "openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -pass env:SAFETEST_PW",
                input: encrypted, password: pw)
            expectEqual(openssl.status, 0, openssl.errorOutput)
            expectEqual(openssl.stdout, plain, "OpenSSL 3 in the image")

            let cryptsh = try CryptoTestKit.inDocker(
                "cd /tmp && cat > t.crypt && printf '%s\\n' \"$SAFETEST_PW\" | crypt.sh -d t.crypt >/dev/null 2>&1 && cat t",
                input: encrypted, password: pw)
            expectEqual(cryptsh.status, 0, cryptsh.errorOutput)
            expectEqual(cryptsh.stdout, plain, "crypt.sh in the image")

            let big = CryptoTestKit.randomData(1_048_576)
            let bigEncrypted = try OpenSSLFormat.encrypt(big, password: SecureBytes(string: pw))
            let bigResult = try CryptoTestKit.inDocker(
                "openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -pass env:SAFETEST_PW",
                input: bigEncrypted, password: pw)
            expect(bigResult.stdout == big, "1 MiB through OpenSSL 3 in the image")
        },

        TestCase("every reference file decrypts in the Docker image") {
            // G5: the test files of all implementations open in the image too. One
            // container gets the files and their passwords as a tar on stdin; only
            // the SHA-256 of each plaintext comes back.
            guard let docker = CryptoTestKit.docker else {
                try skip("Docker is not running or the image \(CryptoTestKit.dockerImage) is missing")
            }
            let entries = try ReferenceFiles.load()
            try withTemporaryDirectory { dir in
                let folder = dir.appendingPathComponent("refs")
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                var script = "cd /tmp && mkdir refs && cd refs && tar xf - && "
                for (i, entry) in entries.enumerated() {
                    try entry.data().write(to: folder.appendingPathComponent("f\(i)"))
                    try Data((entry.password + "\n").utf8).write(to: folder.appendingPathComponent("p\(i)"))
                    let legacy = entry.options.contains("-rc4") ? " -provider legacy -provider default" : ""
                    script += "printf 'f\(i) '; { openssl enc -d \(entry.options)\(legacy) -pass file:p\(i) -in f\(i) "
                        + "|| echo failed >&2; } | sha256sum; "
                }
                var environment = ProcessInfo.processInfo.environment
                environment["COPYFILE_DISABLE"] = "1"
                let tar = try runProcess("/usr/bin/tar", ["--format", "ustar", "--no-xattrs", "--no-mac-metadata",
                                                          "-c", "-f", "-", "-C", folder.path, "."],
                                         environment: environment)
                expectEqual(tar.status, 0, tar.errorOutput)
                let result = try runProcess(docker, ["run", "--rm", "-i", "--pull", "never", "--network", "none",
                                                     "--name", "safetest-refs-\(UUID().uuidString.prefix(8).lowercased())",
                                                     CryptoTestKit.dockerImage, "sh", "-c", script + "true"],
                                            input: tar.stdout)
                expectEqual(result.status, 0, result.errorOutput)
                var hashes: [String: String] = [:]
                for line in result.output.split(separator: "\n") {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 {
                        hashes[String(parts[0])] = String(parts[1])
                    }
                }
                var opened = 0
                for (i, entry) in entries.enumerated() {
                    if hashes["f\(i)"] == entry.sha256 {
                        opened += 1
                    } else {
                        fail("\(entry.file) (\(entry.generator), \(entry.variant)) does not decrypt in the image")
                    }
                }
                print("     \(opened) of \(entries.count) reference files decrypt in \(CryptoTestKit.dockerImage)")
            }
        },

        TestCase("2000 wrong passwords are rejected") {
            let entry = try ReferenceFiles.text()
            try withTemporaryDirectory { dir in
                let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                let tally = WrongPasswords.run(url, count: 2000, except: entry.password)
                expectEqual(tally.confirmed, [], "wrong passwords were accepted")
                expectEqual(tally.otherErrors, [], "errors other than wrongPassword")
                // what decides whether garbage is offered read only: it must not look like text
                expectEqual(tally.textLike, 0, "wrong passwords gave text that would be offered read only")
                expectEqual(tally.damaged, 0, "wrong passwords were told that the file is damaged")
                // about 1 in 256 passes the padding check; Plausibility must catch them,
                // and the app asks the user about those instead of showing them
                print("     \(tally.tried) wrong passwords: \(tally.paddingPassed) passed the padding check, "
                      + "0 accepted, \(tally.unconfirmed) left to the user")
            }
        },

        TestCase("1000 wrong passwords each: unusual files are never confirmed") {
            // the files of the right-password test in FilesTests, plus a Word document;
            // 1000 each keeps the run short, the 2000 of plan 7.1 are the test above
            let latin1 = Data("Grüße aus Köln, ½ fünf\n".unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
            var utf16 = Data([0xFF, 0xFE])
            for unit in "Name;Wert\r\nÄpfel;3\r\n".utf16 {
                utf16.append(UInt8(unit & 0xFF))
                utf16.append(UInt8(unit >> 8))
            }
            let files: [(String, Data)] = [
                ("notes.txt", latin1), ("table.csv", utf16), ("blob", CryptoTestKit.randomData(999)),
                ("photo.jpg", Data(Array("RIFF".utf8) + [100, 0, 0, 0] + Array("WEBPVP8 ".utf8)) + CryptoTestKit.randomData(92)),
                ("report.docx", Data([0x50, 0x4B, 3, 4]) + CryptoTestKit.randomData(4000)),
            ]
            let pw = "the right one"
            try withTemporaryDirectory { dir in
                for (name, plain) in files {
                    let url = dir.appendingPathComponent(name + ".crypt")
                    try OpenSSLFormat.encrypt(plain, password: SecureBytes(string: pw)).write(to: url)
                    let tally = WrongPasswords.run(url, count: 1000, except: pw)
                    expectEqual(tally.confirmed, [], "\(name): wrong passwords were accepted")
                    expectEqual(tally.otherErrors, [], name)
                    expectEqual(tally.textLike, 0, "\(name): wrong passwords gave text")
                    expectEqual(tally.damaged, 0, "\(name): wrong passwords were told that the file is damaged")
                    print("     \(name): \(tally.paddingPassed) of \(tally.tried) passed the padding check, "
                          + "0 accepted, \(tally.unconfirmed) left to the user")
                }
            }
        },

        TestCase("strict padding") {
            let password = Array("padding".utf8)
            let salt: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
            let keyIV = Reference.pbkdf2(password, salt)
            func file(_ blocks: [UInt8]) -> Data {
                Data("Salted__".utf8) + salt + Reference.aes(CCOperation(kCCEncrypt), keyIV, blocks, padding: false)!
            }
            let text = Array("0123456789abcdef".utf8)
            let bad: [[UInt8]] = [
                Array(text[0 ..< 15]) + [0x00],
                Array(text[0 ..< 15]) + [0x11],
                Array(text[0 ..< 14]) + [0x03, 0x02],
                Array(text[0 ..< 13]) + [0x03, 0x02, 0x03],
                [0x0F] + [UInt8](repeating: 0x10, count: 15),
            ]
            for blocks in bad {
                expectThrows(CryptError.wrongPassword, "padding \(blocks.suffix(3))") {
                    _ = try OpenSSLFormat.decryptCurrent(file(blocks), password: SecureBytes(password))
                }
            }
            let good: [([UInt8], [UInt8])] = [
                ([UInt8](repeating: 0x10, count: 16), []),
                (Array("abc".utf8) + [UInt8](repeating: 0x0D, count: 13), Array("abc".utf8)),
                (Array(text[0 ..< 15]) + [0x01], Array(text[0 ..< 15])),
                (text + [UInt8](repeating: 0x10, count: 16), text),
            ]
            for (blocks, plain) in good {
                expectEqual(try OpenSSLFormat.decryptCurrent(file(blocks), password: SecureBytes(password)),
                            Data(plain))
            }
        },

        TestCase("files that are not in the format") {
            let password = SecureBytes(string: "x")
            let salt = Data([1, 2, 3, 4, 5, 6, 7, 8])
            expectThrows(CryptError.notEncrypted) { _ = try OpenSSLFormat.decryptCurrent(Data(), password: password) }
            expectThrows(CryptError.notEncrypted) {
                _ = try OpenSSLFormat.decryptCurrent(Data("hello, plain text".utf8), password: password)
            }
            expectThrows(CryptError.corrupt) {
                _ = try OpenSSLFormat.decryptCurrent(Data("Salted__".utf8) + Data([1, 2, 3]), password: password)
            }
            for bodyLength in [0, 15, 17, 31] {
                let data = Data("Salted__".utf8) + salt + CryptoTestKit.randomData(bodyLength)
                expectThrows(CryptError.corrupt, "body of \(bodyLength) bytes") {
                    _ = try OpenSSLFormat.decryptCurrent(data, password: password)
                }
                expectThrows(CryptError.corrupt, "AES legacy, body of \(bodyLength) bytes") {
                    _ = try OpenSSLFormat.decryptLegacy(data, password: password, variant: .legacyAESMD5)
                }
            }
        },

        TestCase("empty file") {
            let password = SecureBytes(string: "empty")
            let encrypted = try OpenSSLFormat.encrypt(Data(), password: password)
            expectEqual(encrypted.count, 32, "header, salt and one block of padding")
            expectEqual(try OpenSSLFormat.decryptCurrent(encrypted, password: password), Data())
        },

        TestCase("1 MB file") {
            let plain = CryptoTestKit.randomData(1_048_576)
            let password = SecureBytes(string: "one MiB")
            let encrypted = try OpenSSLFormat.encrypt(plain, password: password)
            expectEqual(encrypted.count, 16 + 1_048_576 + 16)
            expect(try OpenSSLFormat.decryptCurrent(encrypted, password: password) == plain)
        },

        TestCase("a password is its exact UTF-8 bytes") {
            let composed = "Gr\u{00FC}\u{00DF}e"       // ü as one code point
            let decomposed = "Gru\u{0308}\u{00DF}e"    // u and a combining diaeresis
            let plain = Data("normalisation".utf8)
            let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(string: composed))
            expectEqual(try OpenSSLFormat.decryptCurrent(encrypted, password: SecureBytes(Array(composed.utf8))), plain)
            expectEqual(try CryptoTestKit.opensslDecrypt(encrypted, password: composed), plain)
            expect((try? OpenSSLFormat.decryptCurrent(encrypted, password: SecureBytes(string: decomposed))) != plain,
                   "another normal form is another password")
        },

        TestCase("an empty password works as in openssl") {
            // the app never asks for one, but a file made with one should open
            let plain = Data("empty password\n".utf8)
            let made = try CryptoTestKit.opensslEncrypt(plain, password: "", options: CryptoTestKit.currentOptions)
            expectEqual(try OpenSSLFormat.decryptCurrent(made, password: SecureBytes([])), plain)
            let encrypted = try OpenSSLFormat.encrypt(plain, password: SecureBytes(string: ""))
            expectEqual(try CryptoTestKit.opensslDecrypt(encrypted, password: ""), plain)
        },

        TestCase("SecureBytes keeps and wipes its bytes") {
            let bytes: [UInt8] = Array("secret Paßwort".utf8)
            let secure = SecureBytes(bytes)
            expectEqual(secure.count, bytes.count)
            expectEqual(secure.withUnsafeBytes { Array($0) }, bytes)
            expectEqual(SecureBytes(string: "Paßwort").withUnsafeBytes { Array($0) }, Array("Paßwort".utf8))
            let address = secure.withUnsafeBytes { $0.baseAddress! }
            secure.wipe()
            expectEqual(secure.count, 0)
            expectEqual(secure.withUnsafeBytes { $0.count }, 0)
            let after = Array(UnsafeRawBufferPointer(start: address, count: bytes.count))
            expectEqual(after, [UInt8](repeating: 0, count: bytes.count), "the memory is zero after wipe")
            expectEqual(SecureBytes([]).count, 0)
        },

        // MARK: legacy

        TestCase("each legacy reference file opens with its variant") {
            let legacy = try ReferenceFiles.load().filter { $0.variant != "current" }
            expect(legacy.count >= 15, "only \(legacy.count) legacy reference files")
            try withTemporaryDirectory { dir in
                for entry in legacy {
                    // under its original name, whose ending decides what counts as plausible
                    let folder = dir.appendingPathComponent(entry.file, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let url = try ReferenceFiles.copyAsCrypt(entry, to: folder)
                    let (opened, plain) = try CryptFile.open(at: url, password: SecureBytes(string: entry.password),
                                                             allowLegacy: true)
                    expectEqual(opened.variant.rawValue, entry.variant, entry.file)
                    expectEqual(opened.originalName, entry.originalName)
                    expectEqual(CryptoTestKit.sha256Hex(plain), entry.sha256, entry.file)
                    do {
                        let (current, _) = try CryptFile.open(at: url, password: SecureBytes(string: entry.password),
                                                              allowLegacy: false)
                        // the current format's padding check can pass on an old file; never confirmed
                        expect(current.variant == .current && current.check != .confirmed,
                               "\(entry.file) opened without allowLegacy as \(current.variant), \(current.check)")
                    } catch {}
                    try FileManager.default.removeItem(at: folder)
                }
            }
        },

        TestCase("a wrong password opens no legacy file") {
            let legacy = try ReferenceFiles.load().filter { $0.variant != "current" }
            try withTemporaryDirectory { dir in
                for entry in legacy {
                    // a type that cannot be checked may open with garbage; the app asks the user then
                    if Plausibility.check(Data(), originalName: entry.originalName) == .unknownType {
                        continue
                    }
                    let url = try ReferenceFiles.copyAsCrypt(entry, to: dir)
                    for wrong in [entry.password + "x", String(entry.password.dropLast()), "password"] {
                        do {
                            let (opened, _) = try CryptFile.open(at: url, password: SecureBytes(string: wrong),
                                                                 allowLegacy: true)
                            expect(opened.check != .confirmed, "\(entry.file) opened with \(wrong) as \(opened.variant)")
                        } catch {
                            let e = error as? CryptError
                            expect(e == .wrongPassword || e == .wrongPasswordOrDamaged || e == .notEncrypted,
                                   "\(entry.file): \(error)")
                        }
                    }
                    try FileManager.default.removeItem(at: url)
                }
            }
        },

        TestCase("legacy files of a type that cannot be checked") {
            // made here with LibreSSL and a fixed salt, so the outcome is the same every time
            let plain = Data((0 ..< 4096).map { UInt8(($0 * 7 + 3) & 0xFF) })
            let odd = plain + plain.prefix(3)          // 4099 bytes, not whole blocks
            let pw = "unknown-type"
            let salt = ["-S", "0011223344556677"]
            try withTemporaryDirectory { dir in
                func open(_ data: Data) throws -> (OpenedFile, Data) {
                    let url = dir.appendingPathComponent("data.bin.crypt")
                    try data.write(to: url)
                    defer { try? FileManager.default.removeItem(at: url) }
                    return try CryptFile.open(at: url, password: SecureBytes(string: pw), allowLegacy: true)
                }
                let aes = try CryptoTestKit.opensslEncrypt(plain, password: pw,
                                                           options: ["-aes-256-cbc", "-md", "md5"] + salt)
                let (o1, p1) = try open(aes)
                expectEqual(o1.variant, .legacyAESMD5)
                expectEqual(o1.check, .unchecked, "the app asks the user")
                expect(p1 == plain, "AES-MD5 content")
                expectEqual(Plausibility.check(p1, originalName: o1.originalName), .unknownType)

                let rc4 = try CryptoTestKit.opensslEncrypt(odd, password: pw, options: ["-rc4", "-md", "md5"] + salt)
                let (o2, p2) = try open(rc4)
                expectEqual(o2.variant, .legacyRC4MD5)
                expectEqual(o2.check, .unchecked, "the app asks the user")
                expect(p2 == odd, "RC4-MD5 content")

                // RC4 with whole blocks could be AES with a wrong password: not opened. RC4
                // decrypts with any password, so taking its result here would turn every
                // wrong password for a .bin file in the current format into a question;
                // docs/format.md names openssl and safe-decrypt.py --variant for these
                let rc4Blocks = try CryptoTestKit.opensslEncrypt(plain, password: pw, options: ["-rc4", "-md", "md5"] + salt)
                expectThrows(CryptError.wrongPassword) { _ = try open(rc4Blocks) }
            }
        },

        TestCase("decryptLegacy reads every variant made by LibreSSL here") {
            let plain = Data("legacy variants, made at test time: Grüße\n".utf8)
            let pw = "Paßwort"
            let variants: [(CryptVariant, [String])] = [
                (.legacyAESMD5, ["-aes-256-cbc", "-md", "md5"]),
                (.legacyAESSHA256, ["-aes-256-cbc", "-md", "sha256"]),
                (.legacyAESSHA256, ["-aes-256-cbc"]),
                (.legacyRC4MD5, ["-rc4", "-md", "md5"]),
                (.legacyRC4SHA256, ["-rc4", "-md", "sha256"]),
                (.current, CryptoTestKit.currentOptions),
            ]
            for (variant, options) in variants {
                for salt in [["-salt"], ["-nosalt"]] where !(variant == .current && salt == ["-nosalt"]) {
                    let data = try CryptoTestKit.opensslEncrypt(plain, password: pw, options: options + salt)
                    expectEqual(try OpenSSLFormat.decryptLegacy(data, password: SecureBytes(string: pw), variant: variant),
                                plain, "\(options) \(salt)")
                }
            }
        },
    ]
}

/// Random wrong passwords against one file, in parallel.
enum WrongPasswords {
    final class Tally {
        let lock = NSLock()
        var tried = 0
        var confirmed: [String] = []
        var unconfirmed = 0
        var paddingPassed = 0
        var otherErrors: [String] = []
        /// Unconfirmed results for a text name that would be offered read only: an
        /// unchecked one, or text in another encoding (Plausibility.looksLikeText).
        var textLike = 0
        /// Wrong passwords told that the file is damaged (CryptError.damaged).
        var damaged = 0
    }

    /// Opens `url` with `count` random passwords other than `except`, as the app
    /// does (allowLegacy true), and counts what came back.
    static func run(_ url: URL, count: Int, except right: String) -> Tally {
        let data = (try? Data(contentsOf: url)) ?? Data()
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 -_.!$%&äöüß€日本🔐")
        var g = SystemRandomNumberGenerator()
        let passwords: [String] = (0 ..< count).map { _ in
            String((0 ..< Int.random(in: 1 ... 24, using: &g)).map { _ in alphabet.randomElement(using: &g)! })
        }.filter { $0 != right }
        let tally = Tally()
        tally.tried = passwords.count
        let name = url.deletingPathExtension().lastPathComponent
        DispatchQueue.concurrentPerform(iterations: passwords.count) { i in
            let password = SecureBytes(string: passwords[i])
            let padding = (try? OpenSSLFormat.decryptCurrent(data, password: password)) != nil
            var result: Result<(OpenedFile, Data), Error>
            do {
                result = .success(try CryptFile.open(at: url, password: password, allowLegacy: true))
            } catch {
                result = .failure(error)
            }
            tally.lock.lock()
            if padding { tally.paddingPassed += 1 }
            switch result {
            case .success(let (opened, _)) where opened.check == .confirmed:
                tally.confirmed.append("\(passwords[i]) as \(opened.variant)")
            case .success(let (opened, data)):
                tally.unconfirmed += 1
                if FileKind.isTextName(name) && (opened.check == .unchecked || Plausibility.looksLikeText(data)) {
                    tally.textLike += 1
                }
            case .failure(CryptError.damaged):
                tally.damaged += 1
            case .failure(CryptError.wrongPassword), .failure(CryptError.wrongPasswordOrDamaged): break
            case .failure(let error): tally.otherErrors.append("\(error)")
            }
            tally.lock.unlock()
        }
        return tally
    }
}

/// A second implementation of key derivation and cipher, straight from
/// CommonCrypto, to check the app's layout against.
enum Reference {
    static func pbkdf2(_ password: [UInt8], _ salt: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 48)
        let status = password.withUnsafeBytes { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.baseAddress?.assumingMemoryBound(to: CChar.self),
                                 pw.count, salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512),
                                 100_000, &out, out.count)
        }
        precondition(status == kCCSuccess)
        return out
    }

    static func aes(_ operation: CCOperation, _ keyIV: [UInt8], _ input: [UInt8], padding: Bool) -> [UInt8]? {
        var out = [UInt8](repeating: 0, count: input.count + 16)
        var moved = 0
        let status = CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(padding ? kCCOptionPKCS7Padding : 0),
                             Array(keyIV[0 ..< 32]), 32, Array(keyIV[32 ..< 48]),
                             input, input.count, &out, out.count, &moved)
        return status == kCCSuccess ? Array(out[0 ..< moved]) : nil
    }
}
