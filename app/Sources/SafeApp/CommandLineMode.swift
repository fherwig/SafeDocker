import AppKit
import SafeCore

// WP4. The modes without a window (section 4.1, step 2), for the install
// agent: --version, --self-test and --check. None of them starts the run loop
// or opens a window. A debug build also has --app-tests, which runs the tests
// of the app's own logic (the SafeTests runner cannot link the app); see the
// end of this file.

/// Facts about the running app.
enum AppInfo {
    /// "debug" or "release": how this program was compiled. build-app.sh makes
    /// both, and only a release build is to be installed.
    static var configuration: String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    /// CFBundleShortVersionString, which build-app.sh fills in from VERSION; a
    /// debug build adds " (debug build)", so that it cannot pass for a release.
    static var version: String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            #if DEBUG
            return version + " (debug build)"
            #else
            return version
            #endif
        }
        #if DEBUG
        if let text = try? String(contentsOf: sourceAppDirectory.appendingPathComponent("VERSION"), encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines) + " (development build)"
        }
        #endif
        return "unknown (not run from Safe.app)"
    }

    /// Resources/Fixtures inside the app bundle, the reference files of the self-test.
    /// A debug build run outside Safe.app uses app/Fixtures of its source tree.
    static var fixturesDirectory: URL {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" {
            return sourceAppDirectory.appendingPathComponent("Fixtures", isDirectory: true)
        }
        #endif
        return (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    /// Contents/Resources of the app bundle: the help files and the tables of
    /// en.lproj and de.lproj. A debug build run outside Safe.app uses
    /// app/Resources of its source tree.
    static var resourcesDirectory: URL {
        #if DEBUG
        if Bundle.main.bundleURL.pathExtension != "app" {
            return sourceAppDirectory.appendingPathComponent("Resources", isDirectory: true)
        }
        #endif
        return Bundle.main.resourceURL ?? Bundle.main.bundleURL
    }

    #if DEBUG
    /// The app/ folder of the source tree this debug build was made from.
    static let sourceAppDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SafeApp
        .deletingLastPathComponent()   // Sources
        .deletingLastPathComponent()   // app
    #endif
}

/// The modes without a window, for the install agent (section 4.1, step 2).
enum CommandLineMode {
    /// Printed by --help and after a wrong option.
    static let usage = """
        Usage: Safe [--version | --self-test | --check | --help]
          --version     print the version
          --self-test   run the self-test, print a JSON report, exit 0 if it passed
          --check       print a JSON report on this installation: version, build
                        configuration, reference files, network blocked, whether
                        the help files are complete, which languages' tables
                        were found, the volume list (and
                        volumeListError if it cannot be read), attached images,
                        and pendingDeletes, the number of unencrypted folders that New
                        from Folder did not finish deleting
        Without an option Safe starts as a normal app.
        """

    /// For tests: --check reads this volume list instead of the user's.
    static let volumeListVariable = "SAFE_VOLUME_LIST"

    /// True if the arguments ask for a mode without a window, or look like a
    /// mistyped option (isMistyped). Options of the system (one dash, such as
    /// -NSDocumentRevisionsDebugMode or -psn_0_12345) do not count.
    static func isRequested(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("--") || isMistyped($0) }
    }

    /// True for what an agent may type out of habit instead of --help or
    /// --version: "help", "version", "-h", "-v", "-?", and any other word of
    /// lower-case letters after one dash. They get the usage and exit status 2
    /// instead of starting the app, which would show a window (finding of review
    /// round 4). The system's own forms have capitals, digits, dots or
    /// underscores (-NSDocumentRevisionsDebugMode, -AppleLanguages, -psn_0_123).
    static func isMistyped(_ argument: String) -> Bool {
        if ["help", "version", "-?"].contains(argument) {
            return true
        }
        guard argument.hasPrefix("-"), !argument.hasPrefix("--"), argument.count > 1 else { return false }
        return argument.dropFirst().allSatisfy { ("a" ... "z").contains($0) || $0 == "-" }
    }

    /// Runs the mode the arguments ask for and returns the exit code, or nil to start the app.
    static func run(_ arguments: [String]) -> Int32? {
        let options = arguments.dropFirst().filter { $0.hasPrefix("--") }
        guard let option = options.first else {
            if let mistyped = arguments.dropFirst().first(where: isMistyped) {
                printError("Unknown option \(mistyped); options have two dashes.\n" + usage)
                return 2
            }
            return nil
        }
        guard options.count == 1 else {
            printError("Give only one option.\n" + usage)
            return 2
        }
        switch option {
        case "--version":
            print(AppInfo.version)
            return 0
        case "--self-test":
            return selfTest()
        case "--check":
            return check()
        case "--help":
            print(usage)
            return 0
        #if DEBUG
        case "--app-tests":
            // English, as the tests expect, but with the tables, for the tests of German
            Localization.resourceDirectory = AppInfo.resourcesDirectory
            Localization.language = .english
            return AppTests.run(filters: arguments.dropFirst().filter { !$0.hasPrefix("-") })
        #endif
        default:
            printError("Unknown option \(option).\n" + usage)
            return 2
        }
    }

    /// --self-test: SelfTest over the bundled reference files; exit 0 if it passed.
    private static func selfTest() -> Int32 {
        let fixtures = AppInfo.fixturesDirectory
        let report = SelfTest.run(fixturesDirectory: fixtures)
        let ok = SelfTestGate.passed(report)
        let printed = printJSON([
            "version": AppInfo.version,
            "configuration": AppInfo.configuration,
            "fixturesDirectory": fixtures.path,
            "knownAnswers": report.knownAnswers,
            "wrongPasswordRejected": report.wrongPasswordRejected,
            "networkBlocked": report.networkBlocked,
            "failures": report.failures,
            "ok": ok,
        ])
        return printed && ok ? 0 : 1
    }

    /// --check: what the install agent needs to know, read only.
    private static func check() -> Int32 {
        let fixtures = AppInfo.fixturesDirectory
        let listFile = ProcessInfo.processInfo.environment[volumeListVariable]
            .map { URL(fileURLWithPath: $0) } ?? VolumeStore.defaultFile
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let store = VolumeStore(file: listFile)
        let volumes: [[String: Any]] = store.volumes.map { record in
            let path = VolumeInput.expandedPath(record.path, home: home)
            var entry: [String: Any] = [
                "name": record.name,
                "path": record.path,
                "imageExists": FileManager.default.fileExists(atPath: path),
            ]
            if let app = record.syncApp {
                entry["syncApp"] = app
            }
            return entry
        }
        var report: [String: Any] = [
            "version": AppInfo.version,
            "configuration": AppInfo.configuration,
            "app": Bundle.main.bundlePath,
            "fixturesDirectory": fixtures.path,
            "fixturesFound": fixtureCount(fixtures),
            "manifestFound": FileManager.default.fileExists(
                atPath: fixtures.appendingPathComponent("manifest.json").path),
            "networkBlocked": NoNetwork.probeBlocked(),
            "helpFound": AppLanguage.allCases.allSatisfy {
                HelpBook.isComplete(at: HelpBook.helpURL(for: $0))
            },
            "languages": AppLanguage.allCases.filter {
                Localization.loadTable(at: Localization.tableURL($0, in: AppInfo.resourcesDirectory)) != nil
            }.map(\.rawValue),
            "volumeList": listFile.path,
            "volumes": volumes,
        ]
        if let error = store.loadError {
            // the Volumes window would be empty; the file is kept as volumes.json.broken-DATE
            report["volumeListError"] = error
        }
        // unencrypted rests of folders whose delete New from Folder did not finish,
        // counted, never named: only Safe's next start finds and offers them, so an
        // uninstall must not remove the record first (finding of review round 4)
        let pendingFile = listFile.deletingLastPathComponent().appendingPathComponent(
            PendingDeletesFile.defaultFile.lastPathComponent)
        report["pendingDeletes"] = PendingDeletesFile.load(pendingFile).filter {
            fileState(of: $0) == .folder
        }.count
        do {
            report["attachedImages"] = try DiskImage.attached().map { image -> [String: Any] in
                var entry: [String: Any] = ["image": image.imagePath.path]
                if let mountPoint = image.mountPoint {
                    entry["mountPoint"] = mountPoint.path
                }
                return entry
            }
        } catch {
            report["attachedImages"] = [Any]()
            report["attachedImagesError"] = "\(error)"
        }
        return printJSON(report) ? 0 : 1
    }

    /// The number of reference files (*.enc) in the fixtures folder.
    static func fixtureCount(_ directory: URL) -> Int {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasSuffix(".enc") }.count
    }

    /// Prints one JSON object on stdout; false if it cannot be encoded.
    static func printJSON(_ object: [String: Any]) -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.prettyPrinted, .sortedKeys,
                                                               .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8)
        else {
            printError("Cannot encode the report as JSON.")
            return false
        }
        print(text)
        return true
    }

    /// Prints a message on stderr.
    static func printError(_ message: String) {
        FileHandle.standardError.write(Data(("Safe: " + message + "\n").utf8))
    }
}

#if DEBUG
// MARK: - Tests of the app's logic (debug builds only)

/// A small test runner inside the app, for `Safe --app-tests [filter ...]`.
/// The suites are AppTests.suites; each test records failures with check and
/// equal, or ends with skip. No test puts a window on the screen: the flows run
/// with stand-ins. Tests with the real core run in a child process
/// (`Safe --app-tests child:NAME`), so that they can skip while it is a stub.
enum AppTests {
    struct Case {
        let name: String
        let body: () throws -> Void
        init(_ name: String, _ body: @escaping () throws -> Void) {
            self.name = name
            self.body = body
        }
    }

    static var suites: [(String, [Case])] {
        [("prompts", PromptTests.cases), ("router", RouterTests.cases), ("editor", EditorTests.cases),
         ("volumes", VolumeTests.cases), ("shell", ShellTests.cases), ("help", HelpTests.cases),
         ("i18n", LocalizationTests.cases)]
    }

    /// Bodies run in a child process, by name.
    static var children: [String: () throws -> Void] {
        RouterTests.children.merging(VolumeTests.children) { first, _ in first }
            .merging(ShellTests.children) { first, _ in first }
            .merging(EditorTests.children) { first, _ in first }
    }

    /// Ends a test without failing it.
    struct Skipped: Error {
        let reason: String
    }

    static func skip(_ reason: String) throws -> Never {
        throw Skipped(reason: reason)
    }

    private static var failures: [String] = []

    static func check(_ condition: Bool, _ message: @autoclosure () -> String = "",
                      file: StaticString = #fileID, line: UInt = #line) {
        if !condition {
            let text = message()
            failures.append("\(file):\(line): " + (text.isEmpty ? "check failed" : text))
        }
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ message: @autoclosure () -> String = "",
                                    file: StaticString = #fileID, line: UInt = #line) {
        if a != b {
            let text = message()
            failures.append("\(file):\(line): \(a) is not equal to \(b)" + (text.isEmpty ? "" : ": \(text)"))
        }
    }

    static func run(filters: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        if filters.count == 1, filters[0].hasPrefix("child:") {
            return runAsChild(String(filters[0].dropFirst("child:".count)))
        }
        var passed = 0, failed = 0, skipped = 0
        for (suite, cases) in suites {
            for test in cases {
                let name = "\(suite)/\(test.name)"
                if !filters.isEmpty && !filters.contains(where: { name.lowercased().contains($0.lowercased()) }) {
                    continue
                }
                failures = []
                var skipReason: String?
                do {
                    try test.body()
                } catch let s as Skipped {
                    skipReason = s.reason
                } catch {
                    failures.append("threw \(error)")
                }
                if !failures.isEmpty {
                    failed += 1
                    print("FAIL \(name)")
                    failures.forEach { print("     \($0)") }
                } else if let reason = skipReason {
                    skipped += 1
                    print("skip \(name): \(reason)")
                } else {
                    passed += 1
                    print("ok   \(name)")
                }
            }
        }
        print("\(passed) passed, \(failed) failed, \(skipped) skipped")
        return failed == 0 && passed > 0 ? 0 : 1
    }

    private static func runAsChild(_ name: String) -> Int32 {
        guard let body = children[name] else {
            print("no child \(name)")
            return 99
        }
        failures = []
        do {
            try body()
        } catch {
            failures.append("threw \(error)")
        }
        failures.forEach { print($0) }
        return failures.isEmpty ? 0 : 1
    }

    /// The child's temporary folder, made and removed by the parent, so that it
    /// goes even when the child crashes.
    private static let folderVariable = "SAFE_APP_TEST_FOLDER"

    /// Runs a child body in a new process of this program. It fails if the child
    /// fails, and skips if the core it needs is still a stub of WP0.
    static func runChild(_ name: String, file: StaticString = #fileID, line: UInt = #line) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("safetest-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        process.arguments = ["--app-tests", "child:" + name]
        var environment = ProcessInfo.processInfo.environment
        environment[folderVariable] = dir.path
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        final class Box { var data = Data() }
        let errors = Box()
        let reader = DispatchGroup()
        DispatchQueue.global().async(group: reader) {
            errors.data = err.fileHandleForReading.readDataToEndOfFile()
        }
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        reader.wait()
        let errorOutput = String(decoding: errors.data, as: UTF8.self)
        let lines = (errorOutput + "\n" + output).split(separator: "\n")
        if let line = lines.first(where: { $0.contains("not implemented") }) {
            try skip("the core is still a stub: \(line.split(separator: ":").suffix(2).joined(separator: ":"))")
        }
        if process.terminationReason != .exit || process.terminationStatus != 0 {
            failures.append("\(file):\(line): child \(name) failed (\(process.terminationStatus))\n"
                            + output + errorOutput)
        }
    }

    /// A wrong password that Safe refuses outright for the encrypted file at `url`:
    /// `base`, or else `base-2`, `base-3` and so on. A file encrypted with a fresh
    /// random salt lets about 1 wrong password in 256 pass the padding check of a
    /// format; Safe then rightly says that it "could not confirm the password"
    /// instead of "wrong password", and a test that needs the second answer would
    /// fail about once in a hundred runs. Tests of the "wrong password" path pick
    /// their wrong password here, for the salt actually used; Safe's checks are
    /// not changed.
    static func refusedPassword(for url: URL, near base: String,
                                file: StaticString = #fileID, line: UInt = #line) -> String {
        for n in 1 ... 100 {
            let candidate = n == 1 ? base : "\(base)-\(n)"
            let refused = [false, true].allSatisfy { allowLegacy in
                do {
                    _ = try CryptFile.open(at: url, password: SecureBytes(string: candidate), allowLegacy: allowLegacy)
                    return false
                } catch CryptError.wrongPassword {
                    return true
                } catch {
                    return false
                }
            }
            if refused {
                return candidate
            }
        }
        check(false, "Safe refused none of 100 wrong passwords for \(url.lastPathComponent)", file: file, line: line)
        return base
    }

    /// Makes a new empty folder $TMPDIR/safetest-..., passes it to `body` and
    /// removes it afterwards; in a child, the folder the parent made. Detach any
    /// disk image attached inside it first.
    static func withTemporaryFolder(_ body: (URL) throws -> Void) throws {
        if let path = ProcessInfo.processInfo.environment[folderVariable] {
            try body(URL(fileURLWithPath: path, isDirectory: true))
            return
        }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("safetest-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        try body(dir)
    }
}

/// Windows and dialogs built for a test but never put on the screen.
enum OffScreen {
    /// True if windows can be made at all (a login session with a window
    /// server). Makes the application object with no Dock icon and no menu bar.
    static let available: Bool = {
        guard CGSessionCopyCurrentDictionary() != nil else { return false }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        return true
    }()

    /// With SAFE_RENDER_DIR set, draws the window's content into NAME.png there,
    /// to look at the layout without showing the window.
    static func render(_ window: NSWindow, as name: String) {
        guard let dir = ProcessInfo.processInfo.environment["SAFE_RENDER_DIR"],
              let view = window.contentView?.superview ?? window.contentView
        else { return }
        window.appearance = NSAppearance(named: .aqua)
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let file = URL(fileURLWithPath: dir).appendingPathComponent(name + ".png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
    }
}

/// The self-test gate, the main menu and the Services pasteboard.
enum ShellTests {
    static let cases: [AppTests.Case] = [
        AppTests.Case("the gate allows writing after a passed self-test") {
            let gate = SelfTestGate()
            AppTests.equal(gate.state, .notStarted)
            AppTests.check(gate.writeRefusal() != nil, "writing allowed before the self-test ran")
            gate.start { [] }
            AppTests.check(gate.writeRefusal() == nil)
            AppTests.equal(gate.state, .passed)
        },

        AppTests.Case("the gate keeps the report of SelfTest.run for the editor and viewer") {
            let gate = SelfTestGate()
            AppTests.check(gate.report == nil)
            gate.start(fixturesDirectory: URL(fileURLWithPath: "/nonexistent/safetest-fixtures"))
            _ = gate.writeRefusal()
            AppTests.check(gate.report != nil, "no report after the self-test")
            if let report = gate.report {
                AppTests.equal(gate.state == .passed, SelfTestGate.passed(report))
            }
        },

        AppTests.Case("the gate refuses writing after a failed self-test") {
            let gate = SelfTestGate()
            gate.start { ["known answer test x failed"] }
            let refusal = gate.writeRefusal()
            AppTests.check(refusal?.contains("will not encrypt or save") == true, "\(refusal ?? "nil")")
            AppTests.check(refusal?.contains("known answer test x failed") == true)
            AppTests.equal(gate.state, .failed(["known answer test x failed"]))
        },

        AppTests.Case("the gate waits for a self-test that still runs") {
            let gate = SelfTestGate()
            let release = DispatchSemaphore(value: 0)
            gate.start {
                release.wait()
                return []
            }
            AppTests.equal(gate.state, .running)
            var ran = false
            gate.whenFinished { ran = true }
            AppTests.check(!ran, "ran before the self-test finished")
            release.signal()
            AppTests.check(gate.writeRefusal() == nil)
            // the waiting block runs on the main queue
            let deadline = Date().addingTimeInterval(5)
            while !ran && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            AppTests.check(ran, "whenFinished did not run")
        },

        AppTests.Case("a self-test report passes only if every check passed") {
            func report(_ json: String) throws -> SelfTestReport {
                try JSONDecoder().decode(SelfTestReport.self, from: Data(json.utf8))
            }
            let good = try report(#"{"knownAnswers":true,"wrongPasswordRejected":true,"networkBlocked":true,"failures":[]}"#)
            AppTests.check(SelfTestGate.passed(good))
            AppTests.equal(SelfTestGate.outcome(of: good), [])
            let noNet = try report(#"{"knownAnswers":true,"wrongPasswordRejected":true,"networkBlocked":false,"failures":[]}"#)
            AppTests.check(!SelfTestGate.passed(noNet))
            AppTests.equal(SelfTestGate.outcome(of: noNet).count, 1)
            let failed = try report(#"{"knownAnswers":true,"wrongPasswordRejected":true,"networkBlocked":true,"failures":["x"]}"#)
            AppTests.check(!SelfTestGate.passed(failed))
            AppTests.equal(SelfTestGate.outcome(of: failed), ["x"])
        },

        AppTests.Case("the main menu has no writing aids, print or share") {
            let menu = MainMenu.build(target: AppDelegate())
            AppTests.equal(menu.items.map(\.title), ["Safe", "File", "Edit", "View", "Volume", "Window", "Help"])
            var titles: [String] = []
            func collect(_ menu: NSMenu) {
                for item in menu.items {
                    titles.append(item.title)
                    if let sub = item.submenu {
                        collect(sub)
                    }
                }
            }
            collect(menu)
            for banned in ["Spelling", "Substitutions", "Transformations", "Speech", "Writing Tools",
                           "AutoFill", "Print", "Share", "Services", "Use Selection for Find"] {
                AppTests.check(!titles.contains(where: { $0.hasPrefix(banned) }), "menu has \(banned)")
            }
            let edit = menu.item(withTitle: "Edit")?.submenu
            let editTitles = edit?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
            AppTests.equal(editTitles, ["Undo", "Redo", "Cut", "Copy", "Paste", "Delete", "Select All", "Find"])
            let file = menu.item(withTitle: "File")?.submenu
            AppTests.equal(file?.item(withTitle: "Save")?.keyEquivalent, "s")
            AppTests.equal(file?.item(withTitle: "Save")?.action.map(NSStringFromSelector), "saveDocument:")
            AppTests.equal(file?.item(withTitle: "Export...")?.action.map(NSStringFromSelector), "exportDecryptedCopy:")
            AppTests.check(file?.item(withTitle: "Export...")?.target == nil, "Export does not go to the window in front")
            let find = edit?.item(withTitle: "Find")?.submenu
            AppTests.equal(find?.items.map(\.tag), [1, 2, 3])
            AppTests.equal(find?.items.compactMap { $0.action.map(NSStringFromSelector) },
                           Array(repeating: "performFindPanelAction:", count: 3))
            AppTests.equal(menu.item(withTitle: "Safe")?.submenu?.item(withTitle: "Quit Safe")?.keyEquivalent, "q")
            AppTests.check(menu.item(withTitle: "Window")?.submenu?.item(withTitle: "Volumes") != nil)
        },

        AppTests.Case("the Edit menu loses what the system adds") {
            let menu = MainMenu.build(target: AppDelegate())
            guard let edit = menu.item(withTitle: "Edit")?.submenu else {
                AppTests.check(false, "no Edit menu")
                return
            }
            let before = edit.items.map(\.title)
            edit.addItem(.separator())
            edit.addItem(NSMenuItem(title: "Writing Tools", action: nil, keyEquivalent: ""))
            edit.addItem(NSMenuItem(title: "AutoFill", action: nil, keyEquivalent: ""))
            edit.addItem(.separator())
            edit.addItem(NSMenuItem(title: "Start Dictation...", action: nil, keyEquivalent: ""))
            edit.addItem(NSMenuItem(title: "Emoji & Symbols", action: nil, keyEquivalent: ""))
            EditMenuGuard.shared.menuNeedsUpdate(edit)
            AppTests.equal(edit.items.map(\.title), before)
        },

        AppTests.Case("Services hand over the file URLs on the pasteboard") {
            let pboard = NSPasteboard.withUniqueName()
            defer { pboard.releaseGlobally() }
            let urls = [URL(fileURLWithPath: "/tmp/safetest-a.txt"), URL(fileURLWithPath: "/tmp/safetest b.pdf")]
            pboard.clearContents()
            pboard.writeObjects(urls as [NSURL])
            AppTests.equal(ServicesProvider.fileURLs(on: pboard).map(\.path), urls.map(\.path))

            pboard.clearContents()
            let filenames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            pboard.declareTypes([filenames], owner: nil)
            pboard.setPropertyList(["/tmp/safetest-c.txt"], forType: filenames)
            AppTests.equal(ServicesProvider.fileURLs(on: pboard).map(\.path), ["/tmp/safetest-c.txt"])

            pboard.clearContents()
            pboard.setString("not a file", forType: .string)
            AppTests.equal(ServicesProvider.fileURLs(on: pboard), [])
        },

        AppTests.Case("only options with two dashes ask for a mode without a window") {
            AppTests.check(!CommandLineMode.isRequested(["Safe"]))
            AppTests.check(!CommandLineMode.isRequested(["Safe", "-NSDocumentRevisionsDebugMode", "YES"]))
            AppTests.check(!CommandLineMode.isRequested(["Safe", "-psn_0_12345"]))
            AppTests.check(CommandLineMode.isRequested(["Safe", "--check"]))
            AppTests.equal(CommandLineMode.run(["Safe"]), nil)
            AppTests.equal(CommandLineMode.run(["Safe", "-psn_0_12345"]), nil)
        },

        AppTests.Case("mistyped options get the usage, never the app") {
            // finding of review round 4: "Safe -h" or "Safe version" started the app
            for argument in ["-h", "-help", "-v", "-version", "help", "version", "-?", "-check"] {
                AppTests.check(CommandLineMode.isRequested(["Safe", argument]), argument)
                AppTests.equal(CommandLineMode.run(["Safe", argument]), 2, argument)
            }
            for argument in ["-psn_0_12345", "-NSDocumentRevisionsDebugMode", "-AppleLanguages", "-ApplePersistenceIgnoreState",
                             "YES", "(en)", "-com.apple.CoreData.SQLDebug", "-_NSTrace", "-NO"] {
                AppTests.check(!CommandLineMode.isMistyped(argument), argument)
            }
            AppTests.equal(CommandLineMode.run(["Safe", "-NSDocumentRevisionsDebugMode", "YES"]), nil)
        },

        AppTests.Case("the app's gate holds back CryptFile until the self-test has passed") {
            try AppTests.runChild("shell-core-gate")
        },

        AppTests.Case("a damaged reference file makes the real gate refuse every write") {
            // finding of review round 2: only stubs had tested the failing path
            try AppTests.runChild("shell-core-gate-failed")
        },
    ]

    /// Run in a child process, because the app's gate starts only once.
    static let children: [String: () throws -> Void] = [
        "shell-core-gate": {
            try AppTests.withTemporaryFolder { dir in
                let gate = SelfTestGate.shared
                AppTests.equal(gate.state, .notStarted)
                AppTests.check(CryptFile.writeRefusal == nil)
                gate.start(fixturesDirectory: AppInfo.fixturesDirectory)
                AppTests.check(CryptFile.writeRefusal != nil, "CryptFile may write while the self-test runs")
                AppTests.equal(gate.writeRefusal(), nil)
                AppTests.equal(gate.state, .passed)
                AppTests.equal(CryptFile.writeRefusal, nil)
                let file = dir.appendingPathComponent("safetest-gate.txt")
                try Data("safetest gate\n".utf8).write(to: file)
                let password = SecureBytes(string: "safetest-pw")
                defer { password.wipe() }
                let encrypted = try CryptFile.encryptFile(at: file, password: password)
                AppTests.check(FileManager.default.fileExists(atPath: encrypted.path))
            }
        },

        "shell-core-gate-failed": {
            try AppTests.withTemporaryFolder { dir in
                // a copy of the reference files with one byte flipped in an RC4 file
                let fixtures = dir.appendingPathComponent("fixtures", isDirectory: true)
                try FileManager.default.copyItem(at: AppInfo.fixturesDirectory, to: fixtures)
                let damaged = fixtures.appendingPathComponent("libressl-legacyRC4MD5-1.enc")
                var bytes = try Data(contentsOf: damaged)
                bytes[bytes.count - 3] ^= 0x01
                try bytes.write(to: damaged)

                let gate = SelfTestGate.shared
                gate.start(fixturesDirectory: fixtures)
                let refusal = gate.writeRefusal()
                AppTests.check(refusal?.contains("libressl-legacyRC4MD5-1.enc") == true, refusal ?? "writing allowed")
                AppTests.check(CryptFile.writeRefusal?.contains("libressl-legacyRC4MD5-1.enc") == true,
                               CryptFile.writeRefusal ?? "the core may write")

                let password = SecureBytes(string: "safetest-pw")
                defer { password.wipe() }
                let file = dir.appendingPathComponent("safetest-gate.txt")
                try Data("safetest gate\n".utf8).write(to: file)
                do {
                    _ = try CryptFile.encryptFile(at: file, password: password)
                    AppTests.check(false, "encrypted after a failed self-test")
                } catch CryptError.selfTestFailed {
                } catch {
                    AppTests.check(false, "\(error)")
                }
                AppTests.check(FileManager.default.fileExists(atPath: file.path), "the original is gone")
                AppTests.check(!FileManager.default.fileExists(atPath: file.path + ".crypt"), "a .crypt was written")

                // the conflict copy of the editor honours the same refusal
                let crypt = dir.appendingPathComponent("safetest-other.txt.crypt")
                do {
                    _ = try ConflictCopy.write(Data("mine\n".utf8), originalName: "safetest-other.txt",
                                               nextTo: crypt, password: password)
                    AppTests.check(false, "a conflict copy was written after a failed self-test")
                } catch CryptError.selfTestFailed {
                } catch {
                    AppTests.check(false, "\(error)")
                }
                let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
                AppTests.equal(names, ["fixtures", "safetest-gate.txt"])
            }
        },
    ]
}
#endif
