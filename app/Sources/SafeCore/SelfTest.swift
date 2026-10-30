import Foundation

/// The result of SelfTest.run, printed as JSON by Safe --self-test.
public struct SelfTestReport: Codable {
    public var knownAnswers: Bool, wrongPasswordRejected: Bool, networkBlocked: Bool
    public var failures: [String]

    public init(knownAnswers: Bool, wrongPasswordRejected: Bool, networkBlocked: Bool, failures: [String]) {
        self.knownAnswers = knownAnswers
        self.wrongPasswordRejected = wrongPasswordRejected
        self.networkBlocked = networkBlocked
        self.failures = failures
    }

    /// True if every check passed.
    public var ok: Bool {
        knownAnswers && wrongPasswordRejected && networkBlocked && failures.isEmpty
    }
}

/// The checks the app runs when built, installed and started (G5).
public enum SelfTest {
    /// Runs the known-answer tests over fixtures in `fixturesDirectory` (the app passes its
    /// Resources/Fixtures), plus a wrong-password test, plus the network probe.
    ///
    /// Known answers: the manifest covers every generator, every variant, salted
    /// and unsalted files, and every reference file in the folder; every
    /// reference file listed in manifest.json decrypts, through the same path as
    /// CryptFile.open, with the listed variant to the listed length and SHA-256;
    /// every file in the current format is reproduced byte by byte by encrypting
    /// its plaintext with its salt; and a fresh encryption decrypts again. Wrong
    /// passwords: a few near misses must not open a text reference file.
    public static func run(fixturesDirectory: URL) -> SelfTestReport {
        let failures = Failures()
        var knownAnswers = false
        var wrongPasswordRejected = false
        if let manifest = loadManifest(fixturesDirectory, failures) {
            let complete = checkCoverage(manifest, fixturesDirectory, failures)
            knownAnswers = checkKnownAnswers(manifest, fixturesDirectory, failures) && complete
            wrongPasswordRejected = checkWrongPasswords(manifest, fixturesDirectory, failures)
        }
        if !checkRoundTrip(failures) {
            knownAnswers = false
        }
        let networkBlocked = NoNetwork.probeBlocked()
        if !networkBlocked {
            failures.add("network access is not blocked")
        }
        return SelfTestReport(knownAnswers: knownAnswers, wrongPasswordRejected: wrongPasswordRejected,
                              networkBlocked: networkBlocked, failures: failures.list)
    }

    // MARK: - manifest.json (building plan 5.4, docs/format.md)

    struct Manifest: Decodable {
        let files: [Entry]
    }

    struct Entry: Decodable {
        let file: String
        let password: String
        let sha256: String
        let length: Int
        let variant: String
        let originalName: String
        let generator: String
        /// Whether the file has the Salted__ header; checked against the file.
        let salted: Bool?
    }

    /// The implementations whose files the reference set must hold (G5), by the
    /// start of their generator name in manifest.json.
    static let requiredGenerators = ["Debian OpenSSL", "crypt.sh", "macOS LibreSSL", "Safe.app"]

    final class Failures {
        private let lock = NSLock()
        private var items: [String] = []

        func add(_ message: String) {
            lock.lock()
            items.append(message)
            lock.unlock()
        }

        var list: [String] {
            lock.lock()
            defer { lock.unlock() }
            return items
        }
    }

    static func loadManifest(_ directory: URL, _ failures: Failures) -> Manifest? {
        let url = directory.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url) else {
            failures.add("no reference files: cannot read \(url.path)")
            return nil
        }
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            failures.add("cannot parse \(url.path)")
            return nil
        }
        if manifest.files.isEmpty {
            failures.add("\(url.path) lists no reference files")
            return nil
        }
        if !manifest.files.contains(where: { $0.variant == CryptVariant.current.rawValue }) {
            failures.add("\(url.path) lists no file in the current format")
            return nil
        }
        return manifest
    }

    /// True if the manifest covers what G5 asks for: files from every generator
    /// of requiredGenerators, every variant, salted and unsalted files, and every
    /// reference file (*.enc) in the folder. A manifest that lost entries (a bad
    /// merge, a partial regeneration, an edited bundle) fails here, even if every
    /// entry left decrypts (finding of review round 4).
    static func checkCoverage(_ manifest: Manifest, _ directory: URL, _ failures: Failures) -> Bool {
        let before = failures.list.count
        let file = directory.appendingPathComponent("manifest.json").path
        for generator in requiredGenerators where !manifest.files.contains(where: { $0.generator.hasPrefix(generator) }) {
            failures.add("\(file) lists no reference file made by \(generator)")
        }
        for variant in CryptVariant.allCases where !manifest.files.contains(where: { $0.variant == variant.rawValue }) {
            failures.add("\(file) lists no reference file of the variant \(variant.rawValue)")
        }
        for salted in [true, false] where !manifest.files.contains(where: { $0.salted == salted }) {
            failures.add("\(file) lists no \(salted ? "salted" : "unsalted") reference file")
        }
        let listed = Set(manifest.files.map(\.file))
        let present = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".enc") }
        for name in present.sorted() where !listed.contains(name) {
            failures.add("\(name) is in the folder of the reference files but not in \(file)")
        }
        return failures.list.count == before
    }

    static func checkKnownAnswers(_ manifest: Manifest, _ directory: URL, _ failures: Failures) -> Bool {
        let before = failures.list.count
        DispatchQueue.concurrentPerform(iterations: manifest.files.count) { i in
            let entry = manifest.files[i]
            if let problem = checkEntry(entry, directory) {
                failures.add("\(entry.file): \(problem)")
            }
        }
        return failures.list.count == before
    }

    /// nil if the reference file is right, else what is wrong.
    static func checkEntry(_ entry: Entry, _ directory: URL) -> String? {
        guard let variant = CryptVariant(rawValue: entry.variant) else {
            return "unknown variant \(entry.variant)"
        }
        guard !entry.file.contains("/"),
              let data = try? FileIO.read(directory.appendingPathComponent(entry.file).path)
        else {
            return "cannot read the file"
        }
        if let salted = entry.salted, salted != OpenSSLFormat.hasSaltedHeader(data) {
            return salted ? "has no Salted__ header, but the manifest says salted"
                : "has a Salted__ header, but the manifest says unsalted"
        }
        let password = SecureBytes(string: entry.password)
        defer { password.wipe() }
        let found: CryptVariant
        let plaintext: Data
        do {
            let result = try CryptFile.decrypt(data, originalName: entry.originalName,
                                               password: password, allowLegacy: true)
            (found, plaintext) = (result.variant, result.plaintext)
        } catch {
            return "does not decrypt: \(error)"
        }
        if found != variant {
            return "opened as \(found.rawValue), expected \(variant.rawValue)"
        }
        if plaintext.count != entry.length {
            return "decrypts to \(plaintext.count) bytes, expected \(entry.length)"
        }
        if hex(FileIO.sha256(plaintext)) != entry.sha256.lowercased() {
            return "decrypts to the wrong content (SHA-256 differs)"
        }
        if variant == .current {
            do {
                let salt = [UInt8](data[data.startIndex + 8 ..< data.startIndex + 16])
                let again = try OpenSSLFormat.encrypt(plaintext, password: password, salt: salt)
                if again != data {
                    return "encrypting the plaintext with the same salt gives different bytes"
                }
            } catch {
                return "cannot encrypt the plaintext again: \(error)"
            }
        }
        return nil
    }

    /// Near misses of the password of a text reference file in the current
    /// format must fail; they are fixed, so the test gives the same answer
    /// every time. A result that could not be confirmed counts as a failure to
    /// open, because the app shows it only after asking the user.
    static func checkWrongPasswords(_ manifest: Manifest, _ directory: URL, _ failures: Failures) -> Bool {
        guard let entry = manifest.files.first(where: {
            $0.variant == CryptVariant.current.rawValue &&
                FileEnding.text.contains(FileEnding.of($0.originalName)) &&
                $0.length > 0
        }), let data = try? FileIO.read(directory.appendingPathComponent(entry.file).path) else {
            failures.add("no text reference file in the current format for the wrong-password test")
            return false
        }
        let right = entry.password
        var candidates = [right + "x", "x" + right, String(right.dropLast()), right.uppercased(),
                          right + " ", "password"]
        candidates.removeAll { $0 == right || $0.isEmpty }
        let before = failures.list.count
        for wrong in candidates {
            let password = SecureBytes(string: wrong)
            defer { password.wipe() }
            do {
                let result = try CryptFile.decrypt(data, originalName: entry.originalName,
                                                   password: password, allowLegacy: true)
                if result.check == .confirmed {
                    failures.add("a wrong password opened \(entry.file) as \(result.variant.rawValue)")
                }
            } catch CryptError.wrongPassword {
                continue
            } catch {
                failures.add("a wrong password for \(entry.file) gave \(error), expected wrongPassword")
            }
        }
        return failures.list.count == before
    }

    /// A fresh encryption has the right layout and decrypts again.
    static func checkRoundTrip(_ failures: Failures) -> Bool {
        var sample = Data("Safe self-test: äöü ß € 日本 🔐\n".utf8)
        sample.append(contentsOf: 0 ... 255)
        let password = SecureBytes(string: "self-test Paßwort")
        defer { password.wipe() }
        do {
            let encrypted = try OpenSSLFormat.encrypt(sample, password: password)
            let expected = 16 + (sample.count / 16 + 1) * 16
            guard OpenSSLFormat.hasSaltedHeader(encrypted), encrypted.count == expected else {
                failures.add("a fresh encryption has the wrong layout")
                return false
            }
            guard try OpenSSLFormat.decryptCurrent(encrypted, password: password) == sample else {
                failures.add("a fresh encryption does not decrypt to the plaintext")
                return false
            }
        } catch {
            failures.add("a fresh encryption failed: \(error)")
            return false
        }
        return true
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
