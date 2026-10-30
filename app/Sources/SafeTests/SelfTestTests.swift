import Foundation
import SafeCore

// WP1: SelfTest, and NoNetwork.probeBlocked() after enforce() (building plan
// 7.1). enforce() cannot be undone, so run it in a child process: register an
// action in `children` and call runChild(_:) from a test.

enum SelfTestTests: TestSuite {
    static let name = "selftest"

    static let tests: [TestCase] = [
        TestCase("the network is open in this process") {
            expect(!NoNetwork.probeBlocked(), "probeBlocked() is true without enforce()")
        },

        TestCase("enforce blocks the network; files and child processes still work") {
            let result = try runChild("selftest/enforce")
            expectEqual(result.status, 0, result.errorOutput)
            let report = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Bool] ?? [:]
            expectEqual(report["blockedBefore"], false)
            expectEqual(report["blockedAfter"], true)
            expectEqual(report["filesWork"], true)
            expectEqual(report["childProcessWorks"], true)
        },

        TestCase("the self-test passes over the reference files") {
            let report = SelfTest.run(fixturesDirectory: TestPaths.fixtures)
            expect(report.knownAnswers, "knownAnswers: \(report.failures)")
            expect(report.wrongPasswordRejected, "wrongPasswordRejected: \(report.failures)")
            // not blocked in this process, so the report is not ok
            expect(!report.networkBlocked)
            expectEqual(report.failures, ["network access is not blocked"])
            expect(!report.ok)
        },

        TestCase("the self-test passes with the network denied, as in the app") {
            let result = try runChild("selftest/run-enforced")
            expectEqual(result.status, 0, result.output + result.errorOutput)
            let report = try JSONDecoder().decode(SelfTestReport.self, from: result.stdout)
            expect(report.ok, "\(report.failures)")
            expect(report.knownAnswers && report.wrongPasswordRejected && report.networkBlocked)
        },

        TestCase("a damaged reference file fails the self-test") {
            let entry = try ReferenceFiles.text()
            try withFixtureCopy { dir in
                let url = dir.appendingPathComponent(entry.file)
                var data = try Data(contentsOf: url)
                data[data.count - 20] ^= 0x01
                try data.write(to: url)
                let report = SelfTest.run(fixturesDirectory: dir)
                expect(!report.knownAnswers)
                expect(!report.ok)
                expect(report.failures.contains { $0.hasPrefix(entry.file + ":") }, "\(report.failures)")
            }
        },

        TestCase("a wrong hash in the manifest fails the self-test") {
            try withFixtureCopy { dir in
                let url = dir.appendingPathComponent("manifest.json")
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var files = json["files"] as! [[String: Any]]
                let legacy = files.firstIndex { ($0["variant"] as? String) == "legacyRC4MD5" }!
                files[legacy]["sha256"] = String(repeating: "0", count: 64)
                json["files"] = files
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                let report = SelfTest.run(fixturesDirectory: dir)
                expect(!report.knownAnswers)
                expect(report.failures.contains { $0.hasPrefix("\(files[legacy]["file"]!):") }, "\(report.failures)")
            }
        },

        TestCase("a manifest that lost entries fails the self-test") {
            // finding of review round 4: one file in the current format was enough
            func run(keeping keep: ([String: Any]) -> Bool, in dir: URL) throws -> SelfTestReport {
                let url = dir.appendingPathComponent("manifest.json")
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                let files = (json["files"] as! [[String: Any]]).filter(keep)
                json["files"] = files
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                return SelfTest.run(fixturesDirectory: dir)
            }
            try withFixtureCopy { dir in
                let report = try run(keeping: { !(($0["generator"] as? String) ?? "").hasPrefix("macOS LibreSSL") }, in: dir)
                expect(!report.knownAnswers, "knownAnswers without the LibreSSL files")
                expect(report.failures.contains { $0.contains("made by macOS LibreSSL") }, "\(report.failures)")
                expect(report.failures.contains { $0.contains("libressl-") && $0.contains("not in") }, "\(report.failures)")
            }
            try withFixtureCopy { dir in
                let report = try run(keeping: { ($0["file"] as? String) == "app-current-1.enc" }, in: dir)
                expect(!report.knownAnswers)
                for missing in ["made by Debian OpenSSL", "made by crypt.sh", "legacyRC4SHA256", "unsalted"] {
                    expect(report.failures.contains { $0.contains(missing) }, "\(missing): \(report.failures)")
                }
            }
            // a manifest whose salted flag does not fit the file
            try withFixtureCopy { dir in
                let url = dir.appendingPathComponent("manifest.json")
                var json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                var files = json["files"] as! [[String: Any]]
                let index = files.firstIndex { ($0["salted"] as? Bool) == true }!
                files[index]["salted"] = false
                json["files"] = files
                try JSONSerialization.data(withJSONObject: json).write(to: url)
                let report = SelfTest.run(fixturesDirectory: dir)
                expect(!report.knownAnswers)
                expect(report.failures.contains { $0.hasPrefix("\(files[index]["file"]!):") && $0.contains("salted") },
                       "\(report.failures)")
            }
        },

        TestCase("missing reference files fail the self-test") {
            try withTemporaryDirectory { dir in
                let report = SelfTest.run(fixturesDirectory: dir)
                expect(!report.knownAnswers)
                expect(!report.wrongPasswordRejected)
                expect(!report.ok)
                expect(report.failures.contains { $0.contains("manifest.json") }, "\(report.failures)")
            }
        },

        TestCase("a failed self-test stops encrypt and save") {
            try withTemporaryDirectory { dir in
                let pw = SecureBytes(string: "gate")
                let original = dir.appendingPathComponent("notes.txt")
                try Data("stays plain\n".utf8).write(to: original)
                let existing = dir.appendingPathComponent("other.txt.crypt")
                try OpenSSLFormat.encrypt(Data("old\n".utf8), password: pw).write(to: existing)
                let (opened, _) = try CryptFile.open(at: existing, password: pw, allowLegacy: false)
                let before = try Data(contentsOf: existing)

                CryptFile.writeRefusal = "the self-test failed"
                defer { CryptFile.writeRefusal = nil }
                expectThrows(CryptError.selfTestFailed("the self-test failed")) {
                    _ = try CryptFile.encryptFile(at: original, password: pw)
                }
                expectThrows(CryptError.selfTestFailed("the self-test failed")) {
                    _ = try CryptFile.save(Data("new\n".utf8), over: opened, password: pw)
                }
                // opening still works
                expectEqual(try CryptFile.open(at: existing, password: pw, allowLegacy: false).1, Data("old\n".utf8))
                expectEqual(try Data(contentsOf: original), Data("stays plain\n".utf8))
                expectEqual(try Data(contentsOf: existing), before)
                expectEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(),
                            ["notes.txt", "other.txt.crypt"])

                CryptFile.writeRefusal = nil
                _ = try CryptFile.encryptFile(at: original, password: pw)
            }
        },

        TestCase("the report is JSON with the keys of the plan") {
            let report = SelfTestReport(knownAnswers: true, wrongPasswordRejected: true, networkBlocked: true,
                                        failures: [])
            expect(report.ok)
            let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
            expectEqual(Set(object?.keys.map { $0 } ?? []),
                        ["knownAnswers", "wrongPasswordRejected", "networkBlocked", "failures"])
            var failed = report
            failed.failures = ["x"]
            expect(!failed.ok)
            failed = report
            failed.networkBlocked = false
            expect(!failed.ok)
        },
    ]

    static let children: [String: () -> Int32] = [
        "selftest/enforce": {
            let before = NoNetwork.probeBlocked()
            do {
                try NoNetwork.enforce()
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                return 1
            }
            let after = NoNetwork.probeBlocked()
            var filesWork = false
            _ = try? withTemporaryDirectory { dir -> Void in
                let url = dir.appendingPathComponent("probe.txt")
                try Data("probe".utf8).write(to: url)
                filesWork = try Data(contentsOf: url) == Data("probe".utf8)
            }
            let child = try? runProcess("/usr/bin/true", [])
            let report = ["blockedBefore": before, "blockedAfter": after, "filesWork": filesWork,
                          "childProcessWorks": child?.status == 0]
            print(String(decoding: try! JSONSerialization.data(withJSONObject: report), as: UTF8.self))
            return 0
        },

        // the self-test as Safe --self-test runs it; make-fixtures.sh points
        // it at new files with SAFETEST_FIXTURES
        "selftest/run-enforced": {
            do {
                try NoNetwork.enforce()
            } catch {
                FileHandle.standardError.write(Data("\(error)\n".utf8))
                return 1
            }
            let directory = ProcessInfo.processInfo.environment["SAFETEST_FIXTURES"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? TestPaths.fixtures
            let report = SelfTest.run(fixturesDirectory: directory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try! encoder.encode(report), as: UTF8.self))
            return report.ok ? 0 : 1
        },
    ]

    /// Copies app/Fixtures into a temporary folder for tests that damage it.
    static func withFixtureCopy(_ body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { dir in
            for name in try FileManager.default.contentsOfDirectory(atPath: TestPaths.fixtures.path)
                where name.hasSuffix(".enc") || name == "manifest.json" {
                try FileManager.default.copyItem(at: TestPaths.fixtures.appendingPathComponent(name),
                                                 to: dir.appendingPathComponent(name))
            }
            try body(dir)
        }
    }
}
