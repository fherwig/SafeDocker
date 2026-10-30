import Foundation

// The test runner. Build the app first, because the app suite runs the Safe
// program next to this runner:
//   S="$HOME/Library/Caches/SafeDocker-build/dev"
//   swift build --scratch-path "$S" && swift run --scratch-path "$S" SafeTests
//   ... SafeTests crypto files      only tests whose name contains one of these
//   ... SafeTests --list            print the test names
//   ... SafeTests --allow-skips     do not fail when the app suite cannot run
// Exits with 1 if a test failed, or if the app suite could not run (no Safe, or
// one older than its sources) without --allow-skips. Each package adds its tests
// to its own suite file; only new suites need a line here.

let suites: [TestSuite.Type] = [
    HarnessTests.self,
    CryptoTests.self,     // WP1
    FilesTests.self,      // WP1
    SelfTestTests.self,   // WP1
    VolumesTests.self,    // WP2
    ToolsTests.self,      // WP5
    AppLogicTests.self,   // WP3
    AppShellTests.self,   // WP4
]

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.first == "--child" {
    var children: [String: () -> Int32] = [:]
    for suite in suites {
        children.merge(suite.children) { first, _ in first }
    }
    guard arguments.count == 2, let action = children[arguments[1]] else {
        FileHandle.standardError.write(Data("SafeTests: no child action \(arguments.dropFirst())\n".utf8))
        exit(99)
    }
    exit(action())
}

if arguments.first == "--list" {
    for suite in suites {
        for test in suite.tests {
            print("\(suite.name)/\(test.name)")
        }
    }
    exit(0)
}

let allowSkips = arguments.contains("--allow-skips")
exit(runTests(suites, filters: arguments.filter { $0 != "--allow-skips" }, allowSkips: allowSkips))
