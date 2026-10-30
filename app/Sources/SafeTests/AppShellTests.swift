import Foundation
import SafeCore

// WP4: the app's modes without a window (building plan 4.1 and 7.2), run on
// the Safe program that `swift build` put next to this test runner. Also runs
// `Safe --app-tests`, the tests of the app's own logic (routing, prompts,
// editor and viewer windows, volumes window, menu), which live in the app
// because this runner cannot link it. None of this opens a window. Build
// first: `swift run SafeTests` builds only the runner, so these tests skip
// when Safe is missing or older than its sources, and the run then fails as
// incomplete unless --allow-skips is given.

enum AppShellTests: TestSuite {
    static let name = "app"

    static let tests: [TestCase] = [
        TestCase("Safe --version prints the version") {
            let result = try runSafe(["--version"])
            expectEqual(result.status, 0, result.errorOutput)
            let version = String(decoding: try Data(contentsOf: TestPaths.appDirectory.appendingPathComponent("VERSION")),
                                 as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            expect(result.output.hasPrefix(version), "\(result.output) does not start with \(version)")
        },

        TestCase("Safe refuses unknown and extra options without starting") {
            let unknown = try runSafe(["--no-such-option"])
            expectEqual(unknown.status, 2)
            expect(unknown.errorOutput.contains("Usage"), unknown.errorOutput)
            let two = try runSafe(["--version", "--check"])
            expectEqual(two.status, 2)
            let help = try runSafe(["--help"])
            expectEqual(help.status, 0)
            expect(help.output.contains("--self-test") && help.output.contains("--check"), help.output)
            // what an agent may type out of habit gets the usage, never the app's window
            // (finding of review round 4; Safe --app-tests checks the rule without starting Safe)
            for word in ["-h", "-version", "help"] {
                let mistyped = try runSafe([word])
                expectEqual(mistyped.status, 2, word)
                expect(mistyped.errorOutput.contains("Usage"), mistyped.errorOutput)
            }
        },

        TestCase("Safe --self-test prints a JSON report and exits 0 only if it passed") {
            let result = try runSafe(["--self-test"])
            let json = try object(result)
            for key in ["knownAnswers", "wrongPasswordRejected", "networkBlocked", "failures", "ok", "version"] {
                expect(json[key] != nil, "no \(key) in \(result.output)")
            }
            let ok = json["ok"] as? Bool ?? false
            expectEqual(result.status, ok ? 0 : 1)
            let failures = json["failures"] as? [String] ?? []
            if failures.contains(where: { $0.contains("not implemented") }) {
                try skip("SelfTest is still a stub (WP1); the report itself is fine")
            }
            let manifest = TestPaths.fixtures.appendingPathComponent("manifest.json")
            if FileManager.default.fileExists(atPath: manifest.path) {
                expect(ok, "the self-test failed: \(failures)")
                expectEqual(json["networkBlocked"] as? Bool, true)
            }
        },

        TestCase("Safe --check prints a JSON report on the installation") {
            try withTemporaryDirectory { dir in
                let list = dir.appendingPathComponent("volumes.json")
                let result = try runSafe(["--check"], volumeList: list)
                if result.errorOutput.contains("not implemented") {
                    try skip("needs WP1 and WP2: \(result.errorOutput.split(separator: "\n").last ?? "")")
                }
                expectEqual(result.status, 0, result.errorOutput)
                let json = try object(result)
                for key in ["version", "fixturesDirectory", "fixturesFound", "networkBlocked", "helpFound",
                            "volumeList", "volumes", "attachedImages"] {
                    expect(json[key] != nil, "no \(key) in \(result.output)")
                }
                expectEqual(json["networkBlocked"] as? Bool, true)
                // the debug build finds the help in its source tree, Safe.app in its Resources
                expectEqual(json["helpFound"] as? Bool, true)
                // and the texts of both languages (version 0.3.0)
                expectEqual(json["languages"] as? [String], ["en", "de"])
                expectEqual(json["volumeList"] as? String, list.path)
                expectEqual((json["volumes"] as? [Any])?.count, 0)
                expect(json["attachedImages"] is [Any], "attachedImages is not a list")
                expectEqual(json["volumeListError"] as? String, nil)
                // the runner's Safe is a debug build, and says so
                expectEqual(json["configuration"] as? String, "debug")

                // a list it cannot read is reported, not passed off as an empty one
                // (finding of review round 3)
                try Data("{not json".utf8).write(to: list)
                let damaged = try runSafe(["--check"], volumeList: list)
                expectEqual(damaged.status, 0, damaged.errorOutput)
                let report = try object(damaged)
                expectEqual((report["volumes"] as? [Any])?.count, 0)
                expect((report["volumeListError"] as? String)?.contains(list.path) == true,
                       "no volumeListError in \(damaged.output)")
                expectEqual(try Data(contentsOf: list), Data("{not json".utf8), "--check changed the list")

                // unencrypted rests of New from Folder are counted, never named (review round 4)
                expectEqual(report["pendingDeletes"] as? Int, 0)
                let rest = dir.appendingPathComponent(".safetest-folder.safe-pending-12345678", isDirectory: true)
                try FileManager.default.createDirectory(at: rest, withIntermediateDirectories: false)
                let pending = ["version": 1, "pending": [rest.path, dir.appendingPathComponent("gone").path]] as [String: Any]
                try JSONSerialization.data(withJSONObject: pending).write(to: dir.appendingPathComponent("pending-deletes.json"))
                let withRest = try runSafe(["--check"], volumeList: list)
                expectEqual(try object(withRest)["pendingDeletes"] as? Int, 1)
                expect(!withRest.output.contains(rest.lastPathComponent), "--check names the folder")
            }
        },

        TestCase("Safe --app-tests: routing, prompts, editor, viewer, volumes window and menu") {
            let result = try runSafe(["--app-tests"])
            if result.errorOutput.contains("Unknown option --app-tests") {
                try skip("Safe is a release build, which has no --app-tests")
            }
            expectEqual(result.status, 0, "\n" + result.output + result.errorOutput)
            expect(result.output.contains(" passed, 0 failed"), result.output)
        },
    ]

    /// Runs the Safe program built next to this runner, with an empty volume list
    /// unless another is given, so that the user's own list is never read.
    static func runSafe(_ arguments: [String], volumeList: URL? = nil) throws -> ProcessResult {
        let me = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        let safe = me.deletingLastPathComponent().appendingPathComponent("Safe")
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: safe.path) else {
            TestLog.incomplete.append("the app suite did not run: no Safe program at \(safe.path)")
            try skip("no Safe program at \(safe.path); run swift build first")
        }
        let built = (try? fm.attributesOfItem(atPath: safe.path)[.modificationDate] as? Date) ?? .distantPast
        if let newest = newestSource(), newest > built {
            TestLog.incomplete.append("the app suite did not run: Safe is older than its sources")
            try skip("Safe is older than its sources; run swift build first")
        }
        var environment = ProcessInfo.processInfo.environment
        environment["SAFE_VOLUME_LIST"] = (volumeList
            ?? fm.temporaryDirectory.appendingPathComponent("safetest-no-list-\(UUID().uuidString).json")).path
        return try runProcess(safe.path, arguments, environment: environment)
    }

    /// The newest modification date of the app's and the core's sources.
    private static func newestSource() -> Date? {
        let fm = FileManager.default
        var newest: Date?
        for folder in ["SafeApp", "SafeCore"] {
            let dir = TestPaths.appDirectory.appendingPathComponent("Sources").appendingPathComponent(folder)
            guard let walker = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
            else { continue }
            for case let url as URL in walker where url.pathExtension == "swift" {
                if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                   date > (newest ?? .distantPast) {
                    newest = date
                }
            }
        }
        return newest
    }

    /// The JSON object Safe printed.
    private static func object(_ result: ProcessResult) throws -> [String: Any] {
        guard let json = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            throw CryptError.io("not a JSON object: \(result.output) \(result.errorOutput)")
        }
        return json
    }
}
