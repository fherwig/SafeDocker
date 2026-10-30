import Foundation
import SafeCore

// WP0: checks that the harness itself works.

enum HarnessTests: TestSuite {
    static let name = "harness"

    static let tests: [TestCase] = [
        TestCase("expect and expectEqual record failures") {
            let saved = TestLog.failures
            expect(1 + 1 == 3, "deliberate")
            expectEqual("a", "b")
            expectThrows { }
            let recorded = TestLog.failures.count - saved.count
            TestLog.failures = saved
            expectEqual(recorded, 3)
            expect(true)
            expectEqual(2, 2)
        },

        TestCase("expectThrows checks the error") {
            expectThrows(CryptError.wrongPassword) { throw CryptError.wrongPassword }
            let saved = TestLog.failures
            expectThrows(CryptError.wrongPassword) { throw CryptError.corrupt }
            expectThrows(CryptError.wrongPassword) { }
            let recorded = TestLog.failures.count - saved.count
            TestLog.failures = saved
            expectEqual(recorded, 2)
            let error = expectThrows { throw CryptError.io("x") }
            expectEqual(error as? CryptError, CryptError.io("x"))
        },

        TestCase("the app folder is found") {
            let package = TestPaths.appDirectory.appendingPathComponent("Package.swift")
            expect(FileManager.default.fileExists(atPath: package.path), package.path)
        },

        TestCase("temporary folders are made and removed") {
            let dir: URL = try withTemporaryDirectory { dir in
                let file = dir.appendingPathComponent("a.txt")
                try Data("test".utf8).write(to: file)
                expect(FileManager.default.fileExists(atPath: file.path))
                expect(dir.lastPathComponent.hasPrefix("safetest-"))
                return dir
            }
            expect(!FileManager.default.fileExists(atPath: dir.path), "\(dir.path) is still there")
        },

        TestCase("a child process runs and reports its status") {
            let result = try runChild("harness/exit 3")
            expectEqual(result.status, 3)
            expectEqual(result.output, "child ok\n")
        },
    ]

    static let children: [String: () -> Int32] = [
        "harness/exit 3": {
            print("child ok")
            return 3
        },
    ]
}
