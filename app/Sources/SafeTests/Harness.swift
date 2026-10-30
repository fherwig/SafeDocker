import Foundation

// A small test harness, because XCTest and Swift Testing do not run without
// Xcode. A suite file declares an enum that conforms to TestSuite and lists
// its tests; main.swift runs them. In a test, expect and expectEqual record a
// failure and go on; a thrown error ends the test as failed, skip(_:) ends it
// as skipped.

/// One test: a name and a body that records failures or throws.
struct TestCase {
    let name: String
    let body: () throws -> Void

    init(_ name: String, _ body: @escaping () throws -> Void) {
        self.name = name
        self.body = body
    }
}

/// A list of tests, one per package; main.swift collects them.
protocol TestSuite {
    /// The prefix of the test names, for example "crypto".
    static var name: String { get }
    /// The tests, run in this order.
    static var tests: [TestCase] { get }
    /// Actions that a test runs in a child process with runChild(_:), by name.
    static var children: [String: () -> Int32] { get }
}

extension TestSuite {
    static var children: [String: () -> Int32] { [:] }
}

/// Thrown by skip(_:): ends a test without failing it.
struct TestSkipped: Error {
    let reason: String
}

/// The failures recorded by the test that is running.
enum TestLog {
    static var failures: [String] = []
    /// Why parts of the run did not happen that must not be skipped silently,
    /// such as the app suite without a built Safe; the run then fails unless
    /// --allow-skips was given.
    static var incomplete: [String] = []

    static func record(_ message: String, _ file: StaticString, _ line: UInt) {
        failures.append("\(file):\(line): \(message)")
    }
}

/// Records a failure unless the condition holds.
func expect(_ condition: @autoclosure () throws -> Bool, _ message: @autoclosure () -> String = "",
            file: StaticString = #fileID, line: UInt = #line) {
    do {
        if try !condition() {
            let text = message()
            TestLog.record(text.isEmpty ? "expectation failed" : text, file, line)
        }
    } catch {
        TestLog.record("threw \(error)", file, line)
    }
}

/// Records a failure unless the two values are equal.
func expectEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T,
                               _ message: @autoclosure () -> String = "",
                               file: StaticString = #fileID, line: UInt = #line) {
    do {
        let x = try a(), y = try b()
        if x != y {
            let text = message()
            TestLog.record("\(x) is not equal to \(y)" + (text.isEmpty ? "" : ": \(text)"), file, line)
        }
    } catch {
        TestLog.record("threw \(error)", file, line)
    }
}

/// Records a failure unless the body throws; returns the error.
@discardableResult
func expectThrows(_ message: @autoclosure () -> String = "", file: StaticString = #fileID,
                  line: UInt = #line, _ body: () throws -> Void) -> Error? {
    do {
        try body()
    } catch {
        return error
    }
    let text = message()
    TestLog.record("no error thrown" + (text.isEmpty ? "" : ": \(text)"), file, line)
    return nil
}

/// Records a failure unless the body throws exactly `expected`.
func expectThrows<E: Error & Equatable>(_ expected: E, _ message: @autoclosure () -> String = "",
                                        file: StaticString = #fileID, line: UInt = #line,
                                        _ body: () throws -> Void) {
    let text = message()
    do {
        try body()
        TestLog.record("no error thrown, expected \(expected)" + (text.isEmpty ? "" : ": \(text)"), file, line)
    } catch let error as E where error == expected {
        return
    } catch {
        TestLog.record("threw \(error), expected \(expected)" + (text.isEmpty ? "" : ": \(text)"), file, line)
    }
}

/// Records a failure and goes on.
func fail(_ message: String, file: StaticString = #fileID, line: UInt = #line) {
    TestLog.record(message, file, line)
}

/// Ends the test without failing it, for example when Docker is not running.
func skip(_ reason: String) throws -> Never {
    throw TestSkipped(reason: reason)
}

/// Paths the tests need.
enum TestPaths {
    /// The app/ folder of the repository, found from this source file.
    static let appDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SafeTests
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // app

    /// app/Fixtures, the reference encrypted files.
    static var fixtures: URL {
        appDirectory.appendingPathComponent("Fixtures", isDirectory: true)
    }
}

/// Makes a new empty folder $TMPDIR/safetest-..., passes it to `body` and
/// removes it afterwards. Detach any disk image attached inside it first.
func withTemporaryDirectory<R>(_ body: (URL) throws -> R) throws -> R {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("safetest-" + UUID().uuidString,
                                                            isDirectory: true)
    try fm.createDirectory(at: dir, withIntermediateDirectories: false,
                           attributes: [.posixPermissions: 0o700])
    defer { try? fm.removeItem(at: dir) }
    return try body(dir)
}

/// What a child process did.
struct ProcessResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var output: String { String(decoding: stdout, as: UTF8.self) }
    var errorOutput: String { String(decoding: stderr, as: UTF8.self) }
}

/// Runs a program, feeds it `input` on stdin, waits, and returns its status and output.
func runProcess(_ path: String, _ arguments: [String], input: Data? = nil,
                environment: [String: String]? = nil) throws -> ProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let environment = environment {
        process.environment = environment
    }
    let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    process.standardInput = inPipe
    process.standardOutput = outPipe
    process.standardError = errPipe
    try process.run()

    // read both outputs while writing the input, so that no pipe fills up
    final class Box { var data = Data() }
    let out = Box(), err = Box()
    let group = DispatchGroup()
    DispatchQueue.global().async(group: group) {
        out.data = outPipe.fileHandleForReading.readDataToEndOfFile()
    }
    DispatchQueue.global().async(group: group) {
        err.data = errPipe.fileHandleForReading.readDataToEndOfFile()
    }
    if let input = input {
        try? inPipe.fileHandleForWriting.write(contentsOf: input)
    }
    try? inPipe.fileHandleForWriting.close()
    process.waitUntilExit()
    group.wait()
    return ProcessResult(status: process.terminationStatus, stdout: out.data, stderr: err.data)
}

/// Runs this test program again as `SafeTests --child NAME`; the child runs the
/// action registered under NAME in a suite's `children` and exits with its result.
/// For things that cannot be undone in the test process, such as NoNetwork.enforce().
func runChild(_ name: String) throws -> ProcessResult {
    let me = Bundle.main.executablePath ?? CommandLine.arguments[0]
    return try runProcess(me, ["--child", name])
}

/// Runs the tests whose full name ("suite/test") contains one of the filters,
/// prints a line per test and a summary, and returns the exit code: 1 if a test
/// failed, or if a part that must not be skipped silently did not run
/// (TestLog.incomplete) and `allowSkips` is false.
func runTests(_ suites: [TestSuite.Type], filters: [String], allowSkips: Bool = false) -> Int32 {
    var passed = 0, failed = 0, skipped = 0
    var failedNames: [String] = []
    let wanted = filters.map { $0.lowercased() }
    for suite in suites {
        for test in suite.tests {
            let name = "\(suite.name)/\(test.name)"
            if !wanted.isEmpty && !wanted.contains(where: { name.lowercased().contains($0) }) {
                continue
            }
            TestLog.failures = []
            let start = Date()
            var skipReason: String?
            do {
                try test.body()
            } catch let s as TestSkipped {
                skipReason = s.reason
            } catch {
                TestLog.failures.append("threw \(error)")
            }
            let seconds = String(format: "%.2f s", Date().timeIntervalSince(start))
            if !TestLog.failures.isEmpty {
                failed += 1
                failedNames.append(name)
                print("FAIL \(name) (\(seconds))")
                for f in TestLog.failures {
                    print("     \(f)")
                }
            } else if let reason = skipReason {
                skipped += 1
                print("skip \(name): \(reason)")
            } else {
                passed += 1
                print("ok   \(name) (\(seconds))")
            }
        }
    }
    if passed + failed + skipped == 0 {
        print("No test matches \(filters.joined(separator: " ")).")
        return 1
    }
    print("\(passed) passed, \(failed) failed, \(skipped) skipped")
    for name in failedNames {
        print("failed: \(name)")
    }
    let incomplete = Array(Set(TestLog.incomplete)).sorted()
    if !incomplete.isEmpty {
        print("INCOMPLETE: " + incomplete.joined(separator: "; "))
        if allowSkips {
            print("(allowed with --allow-skips)")
        } else {
            print("Build first: swift build --scratch-path PATH && swift run --scratch-path PATH SafeTests"
                  + " (or give --allow-skips).")
            return 1
        }
    }
    return failed == 0 ? 0 : 1
}
