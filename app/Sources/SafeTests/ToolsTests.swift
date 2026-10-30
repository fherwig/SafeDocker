import Foundation
import SafeCore

// WP5: the long-term tools and the install scripts. Their own tests are in
// Python (tools/test_safe_decrypt.py, tools/test_scripts.py), so that they need
// nothing but Python 3; these cases run them, without Docker, and check that
// agent-check.sh prints JSON.

enum ToolsTests: TestSuite {
    static let name = "tools"

    static let tests: [TestCase] = [
        TestCase("safe-decrypt.py passes its self-test") {
            try expectPythonPasses(["tools/safe-decrypt.py", "--self-test"])
        },
        TestCase("safe-decrypt.py opens every variant and the fixtures, without Docker") {
            try expectPythonPasses(["tools/test_safe_decrypt.py", "--quick"])
        },
        TestCase("agent-check.sh, time-capsule.sh and install-safe.sh pass their tests") {
            try expectPythonPasses(["tools/test_scripts.py"])
        },
        TestCase("agent-check.sh prints one JSON object") {
            let script = repository.appendingPathComponent("app/scripts/agent-check.sh").path
            let result = try runProcess("/bin/bash", [script])
            expectEqual(result.status, 0, result.errorOutput)
            let object = try JSONSerialization.jsonObject(with: result.stdout) as? [String: Any]
            expect(object?["ready_to_install"] is Bool, "no ready_to_install in \(result.output)")
            expect(object?["checks"] is [String: Any], "no checks in \(result.output)")
        },
    ]

    /// The root of the repository, above app/.
    static let repository = TestPaths.appDirectory.deletingLastPathComponent()

    /// Runs python3 from the PATH on a script of the repository and expects exit
    /// status 0; skips if there is no python3.
    static func expectPythonPasses(_ arguments: [String], file: StaticString = #fileID,
                                   line: UInt = #line) throws {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
            .split(separator: ":")
            .map { "\($0)/python3" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let python = path else {
            try skip("no python3 on the PATH")
        }
        let script = repository.appendingPathComponent(arguments[0]).path
        let result = try runProcess(python, ["-I", "-B", script] + arguments.dropFirst())
        expectEqual(result.status, 0, String(result.errorOutput.suffix(3000)), file: file, line: line)
    }
}
