#if DEBUG
import AppKit
import Carbon.HIToolbox
import SafeCore

// The two languages, the German keyboard and the Settings window, for
// `Safe --app-tests` (suite i18n, version 0.3.0). Nothing is put on the screen,
// and the language choice is kept in a defaults suite of the tests' own, never
// in the app's real domain.

enum LocalizationTests {
    /// German words that are the same in English, and may be.
    static let sameInBothLanguages: Set<String> = ["OK", "Safe", "Name", "Name:", "Volume", "Volumes", "System",
                                                   "1 GB", "Text in %@."]

    static let cases: [AppTests.Case] = [
        AppTests.Case("every key of the code is in both tables, and no German text is empty or English") {
            let (keys, _) = try sourceKeys()
            AppTests.check(keys.count > 400, "only \(keys.count) keys found in the code")
            let english = try table(.english), german = try table(.german)
            for key in keys.sorted() {
                AppTests.check(english[key] != nil, "en.lproj lacks “\(key)”")
                AppTests.check(german[key] != nil, "de.lproj lacks “\(key)”")
            }
            for key in Set(english.keys).subtracting(keys).sorted() {
                AppTests.check(false, "en.lproj has “\(key)”, which the code does not use")
            }
            AppTests.equal(Set(german.keys), Set(english.keys), "de.lproj and en.lproj have other keys")
            for (key, text) in german {
                AppTests.check(!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "German “\(key)” is empty")
                if text == Localization.englishText(of: key) {
                    AppTests.check(sameInBothLanguages.contains(key), "German “\(key)” is still English")
                }
            }
            for (key, text) in english {
                AppTests.equal(text, Localization.englishText(of: key), "the English text of “\(key)”")
            }
        },

        AppTests.Case("format specifiers match between English and German") {
            let german = try table(.german)
            for (key, text) in german {
                guard let theirs = Localization.specifiers(of: text) else {
                    AppTests.check(false, "German “\(text)” mixes specifiers with and without positions")
                    continue
                }
                guard let ours = Localization.specifiers(of: key) else {
                    AppTests.check(false, "“\(key)” mixes specifiers with and without positions")
                    continue
                }
                AppTests.check(ours.map { "\($0.0)\($0.1)" } == theirs.map { "\($0.0)\($0.1)" },
                               "“\(key)”: \(ours) in English, \(theirs) in German")
                AppTests.check(ours.allSatisfy { ["@", "ld"].contains($0.1) }, "“\(key)” has \(ours)")
                if ours.isEmpty {
                    // used without format, so %% would show as two percent signs
                    AppTests.check(!text.contains("%%"), "German “\(key)” has %% but no arguments")
                }
            }
            // filling in works with positions in another order
            withLanguage(.german) {
                AppTests.equal(L("%@ has %ld bytes in %@ and %ld bytes in %@.", "a", 1, "b", 2, "c"),
                               "a hat 1 Byte in b und 2 Byte in c.")
            }
        },

        AppTests.Case("plural forms: one and several, in both languages") {
            let (_, plurals) = try sourceKeys()
            AppTests.check(plurals.count >= 3, "only \(plurals.count) plural pairs")
            let german = try table(.german)
            for (one, other) in plurals {
                AppTests.check(german[one] != nil && german[other] != nil, "no German for “\(one)” / “\(other)”")
            }
            AppTests.equal(Lp(1, "Encrypt %ld file", "Encrypt %ld files"), "Encrypt 1 file")
            AppTests.equal(Lp(3, "Encrypt %ld file", "Encrypt %ld files"), "Encrypt 3 files")
            AppTests.equal(Lp(0, "%ld match", "%ld matches"), "0 matches")
            withLanguage(.german) {
                AppTests.equal(Lp(1, "Encrypt %ld file", "Encrypt %ld files"), "1 Datei verschlüsseln")
                AppTests.equal(Lp(3, "Encrypt %ld file", "Encrypt %ld files"), "3 Dateien verschlüsseln")
                AppTests.equal(Lp(1, "this %ld file", "these %ld files"), "diese 1 Datei")
                AppTests.equal(Lp(2, "%ld match", "%ld matches"), "2 Treffer")
            }
        },

        AppTests.Case("the German menu bar has macOS's German titles, the same unique shortcuts and ⌘, for Settings") {
            let english = shortcuts(of: MainMenu.build(target: AppDelegate()))
            withLanguage(.german) {
                let menu = MainMenu.build(target: AppDelegate())
                AppTests.equal(menu.items.map(\.title), ["Safe", "Ablage", "Bearbeiten", "Darstellung", "Volume",
                                                         "Fenster", "Hilfe"])
                let edit = MainMenu.submenu(of: menu, key: "Edit")
                AppTests.equal(edit?.items.filter { !$0.isSeparatorItem }.map(\.title),
                               ["Widerrufen", "Wiederholen", "Ausschneiden", "Kopieren", "Einsetzen", "Löschen",
                                "Alles auswählen", "Suchen"])
                AppTests.equal(MainMenu.submenu(of: edit, key: "Find")?.items.map(\.title),
                               ["Suchen …", "Weitersuchen", "Weitersuchen (rückwärts)"])
                AppTests.equal(MainMenu.submenu(of: menu, key: "Window")?.items.filter { !$0.isSeparatorItem }.map(\.title),
                               ["Im Dock ablegen", "Zoomen", "Volumes", "Alle nach vorne bringen"])
                AppTests.equal(MainMenu.submenu(of: menu, key: "Safe")?.items.filter { !$0.isSeparatorItem }.map(\.title),
                               ["Über Safe", "Einstellungen …", "Jetzt sperren", "Safe ausblenden",
                                "Andere ausblenden", "Alle einblenden", "Safe beenden"])
                AppTests.equal(MainMenu.submenu(of: menu, key: "File")?.items.filter { !$0.isSeparatorItem }.map(\.title),
                               ["Öffnen …", "Datei verschlüsseln …", "Schließen", "Sichern", "Exportieren …"])
                AppTests.equal(MainMenu.submenu(of: menu, key: "View")?.items.filter { !$0.isSeparatorItem && !$0.isHidden }
                                .map(\.title),
                               ["Vergrößern", "Verkleinern", "Originalgröße", "Größe an Fenster anpassen",
                                "Nächste Seite", "Vorherige Seite"])
                AppTests.equal(MainMenu.submenu(of: menu, key: "Help")?.items.first?.title, "Safe-Hilfe")
                AppTests.equal(MainMenu.submenu(of: menu, key: "Help")?.items.filter { $0.representedObject != nil }
                                .map(\.title),
                               ["Die Idee hinter Safe", "Tastaturkurzbefehle", "Wenn etwas nicht klappt"])
                let german = shortcuts(of: menu)
                AppTests.equal(german.map(\.0), english.map(\.0), "the shortcuts differ between the languages")
                AppTests.equal(Set(german.map(\.0)).count, german.count, "a shortcut is used twice in German")
                let settings = MainMenu.item(in: menu, key: "Settings...")
                AppTests.equal(settings.flatMap(MainMenu.shortcut(of:)), "⌘,")
                AppTests.equal(settings?.action.map(NSStringFromSelector), "showSettings:")
                // AppKit may move a key that a layout lacks; none of Safe's needs it (next test)
                AppTests.check(HelpTests.allItems(menu).allSatisfy { $0.allowsAutomaticKeyEquivalentLocalization },
                               "an item does not allow AppKit's localization of its key")
            }
        },

        AppTests.Case("the Edit menu loses what the system adds in German too") {
            withLanguage(.german) {
                let menu = MainMenu.build(target: AppDelegate())
                guard let edit = MainMenu.submenu(of: menu, key: "Edit") else {
                    AppTests.check(false, "no Edit menu")
                    return
                }
                let before = edit.items.map(\.title)
                edit.addItem(.separator())
                edit.addItem(NSMenuItem(title: "Schreibtools", action: nil, keyEquivalent: ""))
                edit.addItem(NSMenuItem(title: "Automatisch ausfüllen", action: nil, keyEquivalent: ""))
                edit.addItem(.separator())
                edit.addItem(NSMenuItem(title: "Diktat starten …", action: nil, keyEquivalent: ""))
                edit.addItem(NSMenuItem(title: "Emoji & Symbole", action: nil, keyEquivalent: ""))
                // an item that the system gives a title of Safe's own is still not Safe's
                edit.addItem(NSMenuItem(title: "Kopieren", action: nil, keyEquivalent: ""))
                EditMenuGuard.shared.menuNeedsUpdate(edit)
                AppTests.equal(edit.items.map(\.title), before)
            }
        },

        AppTests.Case("every shortcut can be typed on a German keyboard without Option") {
            guard let german = keyboardLayout("com.apple.keylayout.German") else {
                try AppTests.skip("the German keyboard layout is not available")
            }
            let menu = MainMenu.build(target: AppDelegate())
            var notes: [String] = []
            for item in HelpTests.allItems(menu) where !item.keyEquivalent.isEmpty {
                let key = item.keyEquivalent
                if [MainMenu.Keys.down, MainMenu.Keys.up, MainMenu.Keys.returnKey].contains(key) {
                    continue
                }
                let found = keys(producing: key.lowercased(), in: german)
                AppTests.check(!found.isEmpty, "\(item.title): “\(key)” cannot be typed on a German keyboard")
                if found.allSatisfy(\.shift) {
                    notes.append(key)
                }
            }
            // the keys that need Shift on a German keyboard: ⌘? (ß) and ⌘= (0), as the help says
            AppTests.equal(Set(notes), ["?", "="])
            AppTests.check(keys(producing: "+", in: german).contains { !$0.shift }, "+ needs Shift on German")
            AppTests.check(keys(producing: ",", in: german).contains { !$0.shift }, ", needs Shift on German")
        },

        AppTests.Case("the help loads in German, with every section, and its table has the German menu") {
            let url = HelpBook.helpURL(for: .german)
            AppTests.check(HelpBook.isComplete(at: url), url.path)
            withLanguage(.german) {
                let book = HelpBook.load()
                AppTests.check(book.isComplete, "the German help was not read")
                for section in HelpSection.allCases {
                    guard let range = book.headings[section] else {
                        AppTests.check(false, "no heading for \(section) in German")
                        continue
                    }
                    AppTests.equal((book.text.string as NSString).substring(with: range), section.title)
                    AppTests.check((book.plainText(of: section)?.count ?? 0) > 400, "German \(section) is nearly empty")
                }
                AppTests.check(book.text.string.count > 20_000, "the German help is short")
                AppTests.check(!book.text.string.contains("!"), "an exclamation mark in the German help")
                AppTests.check(!book.text.string.contains("Kennwort"), "Kennwort instead of Passwort")
                let starts = HelpSection.allCases.compactMap { book.headings[$0]?.location }
                AppTests.equal(starts, starts.sorted())
                HelpTests.checkShortcutTable(in: url, or: "oder")
            }
            // the English one has the same sections
            AppTests.check(HelpBook.isComplete(at: HelpBook.helpURL(for: .english)))
        },

        AppTests.Case("switching the language re-titles the menu bar, the Volumes and help windows, not an editor") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let before = NSApp.mainMenu
            let (settings, suite) = testSettings()
            defer {
                settings.setLanguageChoice(.system)
                Localization.language = .english
                NSApp.mainMenu = before
                UserDefaults().removePersistentDomain(forName: suite)
            }
            settings.systemLanguages = { ["en-CA"] }
            let delegate = AppDelegate()
            MainMenu.install(target: delegate)
            let stage = VolumeStage()
            _ = stage.record("safetest-language")
            let volumes = VolumesWindowController(actions: stage.flows())
            defer { volumes.window?.close() }
            let help = HelpWindowController(book: HelpBook.load())
            defer { help.close() }
            help.go(to: .volumes)
            try EditorTests.withEditor { _, _, editor, _ in
                EditorTests.type("safetest changed\n", into: editor)
                let text = editor.textView.string
                let title = editor.window?.title
                let status = editor.statusLabel.stringValue
                AppTests.check(editor.hasUnsavedChanges)
                volumes.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                AppTests.equal(volumes.table.selectedRow, 0)

                settings.setLanguageChoice(.german)
                AppTests.equal(Localization.language, .german)
                AppTests.equal(NSApp.mainMenu?.items.map(\.title), ["Safe", "Ablage", "Bearbeiten", "Darstellung",
                                                                    "Volume", "Fenster", "Hilfe"])
                AppTests.equal(MainMenu.item(in: NSApp.mainMenu, key: "Settings...")?.title, "Einstellungen …")
                AppTests.equal(volumes.window?.title, "Safe-Volumes")
                AppTests.equal(volumes.buttons["Close"]?.title, "Schließen")
                AppTests.equal(volumes.buttons["New Empty..."]?.title, "Leeres Volume …")
                AppTests.equal(volumes.table.tableColumns.map(\.title), ["Name", "Ort", "Status"])
                AppTests.equal(volumes.table.selectedRow, 0, "the selection was lost")
                AppTests.equal(help.window?.title, "Safe-Hilfe")
                AppTests.equal(help.currentSection, .volumes)
                AppTests.check(help.textView.string.contains("Die Idee hinter Safe"), "the help is not German")

                // the editor keeps its text, its changes and its window
                AppTests.equal(editor.textView.string, text)
                AppTests.check(editor.hasUnsavedChanges, "the change is gone")
                AppTests.check(!editor.isClosed, "the editor was closed")
                AppTests.equal(editor.window?.title, title)
                AppTests.equal(editor.statusLabel.stringValue, status)

                settings.setLanguageChoice(.english)
                AppTests.equal(NSApp.mainMenu?.items.map(\.title), ["Safe", "File", "Edit", "View", "Volume",
                                                                    "Window", "Help"])
                AppTests.equal(volumes.buttons["Close"]?.title, "Close")
                AppTests.equal(editor.textView.string, text)
                AppTests.check(editor.hasUnsavedChanges)
            }
        },

        AppTests.Case("Settings keeps the choice in its defaults; System follows macOS's order of languages") {
            let (settings, suite) = testSettings()
            defer {
                Localization.language = .english
                UserDefaults().removePersistentDomain(forName: suite)
            }
            AppTests.equal(settings.languageChoice, .system)
            settings.systemLanguages = { ["fr-FR", "de-CH", "en-US"] }
            AppTests.equal(settings.language, .german)
            settings.setLanguageChoice(.english)
            AppTests.equal(Localization.language, .english)
            AppTests.equal(settings.defaults.string(forKey: Settings.languageKey), "en")
            settings.setLanguageChoice(.german)
            AppTests.equal(Localization.language, .german)
            // a new start reads the same choice
            let again = Settings(defaults: UserDefaults(suiteName: suite)!)
            AppTests.equal(again.languageChoice, .german)
            AppTests.check(again.defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil,
                           "the tests' settings wrote AppleLanguages")
            settings.setLanguageChoice(.system)
            AppTests.equal(settings.defaults.persistentDomain(forName: suite)?[Settings.languageKey] as? String, nil)
            AppTests.equal(Localization.language, .german)
            for (list, expected) in [(["de-DE", "en"], AppLanguage.german), (["en-CA", "de"], .english),
                                     (["fr", "it"], .english), ([], .english), (["de"], .german),
                                     (["en_GB"], .english)] {
                AppTests.equal(Settings.resolve(.system, preferred: list), expected, "\(list)")
            }
            AppTests.equal(Settings.resolve(.english, preferred: ["de"]), .english)
            AppTests.equal(Settings.resolve(.german, preferred: ["en"]), .german)
        },

        AppTests.Case("the Settings window: Language popup, live switch, restart offer only when nothing is open") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let (settings, suite) = testSettings()
            defer {
                Localization.language = .english
                UserDefaults().removePersistentDomain(forName: suite)
            }
            settings.systemLanguages = { ["en-US"] }
            settings.apply()
            var restarts = 0
            settings.restart = { restarts += 1 }
            settings.runsInsideApp = true
            settings.appKitLanguage = "en"
            var open = true
            settings.nothingIsOpen = { !open }
            let controller = SettingsWindowController(settings: settings)
            defer { controller.close() }
            let present = SettingsWindowController.present
            defer { SettingsWindowController.present = present }
            SettingsWindowController.present = { _ in }
            controller.show()
            AppTests.equal(controller.window?.title, "Settings")
            AppTests.equal(controller.languagePopup.itemTitles, ["System", "English", "Deutsch"])
            AppTests.equal(controller.languagePopup.indexOfSelectedItem, 0)
            AppTests.check(controller.restartButton.isHidden, "a restart offered without a change")
            let missing = ToolTipAudit.missing(in: controller.window?.contentView)
            AppTests.check(missing.isEmpty, "no tooltip on " + missing.map(ToolTipAudit.describe).joined(separator: ", "))
            AppTests.equal(HelpButton.section(of: controller.helpButton), .settings)

            controller.languagePopup.selectItem(at: 2)
            controller.languagePopup.sendAction(controller.languagePopup.action, to: controller.languagePopup.target)
            AppTests.equal(settings.languageChoice, .german)
            AppTests.equal(Localization.language, .german)
            AppTests.equal(controller.window?.title, "Einstellungen")
            AppTests.equal(controller.languageLabel.stringValue, "Sprache:")
            AppTests.equal(controller.languagePopup.indexOfSelectedItem, 2)
            // something is open: said, not offered
            AppTests.check(!controller.restartButton.isHidden && !controller.restartButton.isEnabled,
                           "a restart offered while something is open")
            AppTests.check(controller.restartNote.stringValue.contains("nächsten Start"), controller.restartNote.stringValue)
            controller.restartButton.performClick(nil)
            AppTests.equal(restarts, 0)
            open = false
            controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
            AppTests.check(controller.restartButton.isEnabled, "no restart offered with nothing open")
            AppTests.equal(controller.restartButton.title, "Safe neu starten")
            controller.restartButton.performClick(nil)
            AppTests.equal(restarts, 1)
            OffScreen.render(controller.window!, as: "settings-de")
            // back to the language AppKit has: no restart needed
            controller.languagePopup.selectItem(at: 1)
            controller.languagePopup.sendAction(controller.languagePopup.action, to: controller.languagePopup.target)
            AppTests.equal(Localization.language, .english)
            AppTests.check(controller.restartButton.isHidden)
            AppTests.equal(controller.window?.title, "Settings")
            AppTests.check(controller.window?.isVisible == false, "the Settings window is on the screen")
        },

        AppTests.Case("German buttons, labels and popups fit their controls") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try withLanguageThrowing(.german) {
                let stage = VolumeStage()
                _ = stage.record("safetest-fit")
                let volumes = VolumesWindowController(actions: stage.flows())
                defer { volumes.window?.close() }
                checkFit(volumes.window?.contentView, "the Volumes window")
                OffScreen.render(volumes.window!, as: "volumes-de")

                let (settings, suite) = testSettings()
                defer { UserDefaults().removePersistentDomain(forName: suite) }
                settings.runsInsideApp = true
                settings.appKitLanguage = "en"
                settings.nothingIsOpen = { true }
                let window = SettingsWindowController(settings: settings)
                defer { window.close() }
                window.applyLanguage()
                checkFit(window.window?.contentView, "the Settings window")

                let help = HelpWindowController(book: HelpBook.load())
                defer { help.close() }
                checkFit(help.window?.contentView, "the help window")

                let (once, _) = PasswordPrompt.onceAlert(title: "„safetest“ öffnen", message: "x")
                let (twice, _, _) = PasswordPrompt.twiceAlert(title: "Neues Passwort", message: "x")
                let (form, _) = Alerts.formAlert(L("New empty volume"), "x",
                                                 fields: [(L("Name:"), L("Private")), (L("Maximum size:"), "1 GB")])
                for alert in [once, twice, form] {
                    alert.layout()
                    checkFit(alert.window.contentView, alert.messageText)
                }
                OffScreen.render(twice.window, as: "password-de")

                try EditorTests.withEditor { _, _, editor, _ in
                    editor.showSearch()
                    editor.window?.contentView?.layoutSubtreeIfNeeded()
                    checkFit(editor.window?.contentView, "the editor")
                    OffScreen.render(editor.window!, as: "editor-de")
                }
                try EditorTests.withViewer(of: try HelpTests.twoPagePDF(), named: "safetest-fit.pdf", kind: .pdf) { viewer in
                    viewer.window?.contentView?.layoutSubtreeIfNeeded()
                    checkFit(viewer.window?.contentView, "the PDF viewer")
                    OffScreen.render(viewer.window!, as: "viewer-de")
                }
            }
        },

        AppTests.Case("Cancel keeps the Escape key in German dialogs") {
            withLanguage(.german) {
                let (once, _) = PasswordPrompt.onceAlert(title: "x", message: "x")
                let (form, _) = Alerts.formAlert("x", "x", fields: [(L("Name:"), "x")])
                for alert in [once, form] {
                    let cancel = alert.buttons.first { $0.title == "Abbrechen" }
                    AppTests.check(cancel != nil, "no Abbrechen in \(alert.buttons.map(\.title))")
                    AppTests.equal(cancel?.keyEquivalent, "\u{1b}")
                    AppTests.equal(alert.buttons.first?.title, "OK")
                }
                AppTests.equal(PasswordPrompt.newPasswordProblem("a", "b"),
                               "Die beiden Passwörter sind nicht gleich. Gib sie noch einmal ein.")
            }
        },

        AppTests.Case("a German password with umlauts and ß round-trips through the prompt's rules") {
            let typed = "Prüfung-ß"
            let password = PasswordPrompt.typedPassword(typed + "\n")
            AppTests.equal(password, typed)
            AppTests.equal(PasswordPrompt.newPasswordProblem(password, typed), nil)
            AppTests.check(!PasswordPrompt.needsPasting(password), "ä, ö, ü and ß would need pasting")
            for word in ["Äpfel", "Öl", "Übung", "Straße", "ẞ"] {
                AppTests.check(!PasswordPrompt.needsPasting(word), word)
            }
            // a German keyboard types the composed letters, which are the bytes openssl gets
            AppTests.equal(Array(password.utf8), [0x50, 0x72, 0xC3, 0xBC, 0x66, 0x75, 0x6E, 0x67, 0x2D, 0xC3, 0x9F])
            try AppTests.withTemporaryFolder { dir in
                let file = dir.appendingPathComponent("safetest-umlaut.txt")
                let content = Data("Prüfung bestanden, Grüße.\n".utf8)
                try content.write(to: file)
                let crypt = try CryptFile.encryptFile(at: file, password: SecureBytes(string: password))
                let (opened, plain) = try CryptFile.open(at: crypt, password: SecureBytes(string: typed),
                                                         allowLegacy: false)
                AppTests.equal(plain, content)
                AppTests.equal(opened.check, .confirmed)
                // without the umlauts it is another password. About 1 wrong password in 256
                // passes the padding check for the file's random salt; Safe then rightly
                // says it could not confirm the password, and never shows the text
                do {
                    let (wrong, garbage) = try CryptFile.open(at: crypt, password: SecureBytes(string: "Prufung-ss"),
                                                              allowLegacy: false)
                    AppTests.check(wrong.check != .confirmed, "confirmed without the umlauts")
                    AppTests.check(garbage != content, "opened without the umlauts")
                } catch CryptError.wrongPassword {
                } catch {
                    AppTests.check(false, "\(error)")
                }
            }
        },
    ]

    // MARK: helpers

    /// Runs `body` with Safe's texts in a language, and English again afterwards.
    static func withLanguage(_ language: AppLanguage, _ body: () -> Void) {
        let before = Localization.language
        Localization.language = language
        defer { Localization.language = before }
        body()
    }

    static func withLanguageThrowing(_ language: AppLanguage, _ body: () throws -> Void) throws {
        let before = Localization.language
        Localization.language = language
        defer { Localization.language = before }
        try body()
    }

    /// Settings over a defaults suite of the tests' own, emptied first.
    static func testSettings() -> (Settings, String) {
        let suite = "io.github.fherwig.safedocker.safetest-i18n-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let settings = Settings(defaults: defaults)
        settings.systemLanguages = { ["en"] }
        return (settings, suite)
    }

    /// A language's table in the source tree.
    static func table(_ language: AppLanguage) throws -> [String: String] {
        let url = Localization.tableURL(language, in: AppInfo.resourcesDirectory)
        guard let table = Localization.loadTable(at: url) else {
            throw CryptError.io("cannot read \(url.path)")
        }
        return table
    }

    /// The shortcuts of a menu, with the English title of each item.
    static func shortcuts(of menu: NSMenu) -> [(String, String)] {
        HelpTests.allItems(menu).compactMap { item in
            MainMenu.shortcut(of: item).map { ($0, MainMenu.key(of: item) ?? item.title) }
        }
    }

    // MARK: the keys in the code

    /// Every key of L, Lp and LKey in the app's and the core's code (not the
    /// tests), and the pairs of Lp, read from the source tree.
    static func sourceKeys() throws -> (Set<String>, [(String, String)]) {
        let sources = AppInfo.sourceAppDirectory.appendingPathComponent("Sources")
        var keys: Set<String> = []
        var plurals: [(String, String)] = []
        for target in ["SafeApp", "SafeCore"] {
            let root = sources.appendingPathComponent(target)
            guard let walker = FileManager.default.enumerator(atPath: root.path) else { continue }
            for case let path as String in walker where path.hasSuffix(".swift") {
                if path.hasSuffix("Tests.swift") || path.hasSuffix("Localization.swift") { continue }
                let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
                let found = try KeyScanner.scan(text, file: path)
                keys.formUnion(found.keys)
                plurals += found.plurals
            }
        }
        return (keys, plurals)
    }

    // MARK: the German keyboard

    /// The Unicode layout of a keyboard layout that macOS has, read only; the
    /// user's own input sources are not touched.
    static func keyboardLayout(_ id: String) -> Data? {
        let filter = [kTISPropertyInputSourceID as String: id] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first,
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
    }

    /// The keys of a layout's main block (not the numeric keypad, which only
    /// full-size keyboards have) that give `character`, alone or with Shift.
    static func keys(producing character: String, in layout: Data) -> [(code: UInt16, shift: Bool)] {
        var found: [(UInt16, Bool)] = []
        for code in UInt16(0) ..< 51 {
            for shift in [false, true] where self.character(of: code, shift: shift, in: layout) == character {
                found.append((code, shift))
            }
        }
        return found
    }

    private static func character(of code: UInt16, shift: Bool, in layout: Data) -> String {
        layout.withUnsafeBytes { raw -> String in
            guard let base = raw.baseAddress else { return "" }
            let keyboard = base.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeys: UInt32 = 0
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 4)
            let modifiers = shift ? UInt32(shiftKey >> 8) & 0xFF : 0
            let status = UCKeyTranslate(keyboard, code, UInt16(kUCKeyActionDown), modifiers, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &buffer)
            return status == noErr ? String(utf16CodeUnits: buffer, count: length) : ""
        }
    }

    // MARK: truncation

    /// Checks that no button, popup or one-line label in a view is narrower
    /// than its text needs.
    static func checkFit(_ view: NSView?, _ name: String) {
        guard let view = view else { return }
        view.layoutSubtreeIfNeeded()
        for control in allControls(in: view) where !control.isHidden {
            let needed = control.intrinsicContentSize.width
            guard needed > 0, needed != NSView.noIntrinsicMetric else { continue }
            var text = ""
            if let button = control as? NSButton, !(control is NSPopUpButton) {
                guard !button.title.isEmpty else { continue }
                text = button.title
            } else if let popup = control as? NSPopUpButton {
                text = popup.titleOfSelectedItem ?? ""
            } else if let field = control as? NSTextField, !field.isEditable,
                      field.cell?.wraps == false, field.cell?.lineBreakMode != .byTruncatingMiddle,
                      field.cell?.lineBreakMode != .byTruncatingTail {
                guard !field.stringValue.isEmpty else { continue }
                text = field.stringValue
            } else {
                continue
            }
            AppTests.check(control.frame.width + 1 >= needed,
                           "\(name): “\(text)” needs \(Int(needed)) points, has \(Int(control.frame.width))")
        }
    }

    private static func allControls(in view: NSView) -> [NSControl] {
        let own: [NSControl] = (view as? NSControl).map { [$0] } ?? []
        if view is NSTableView || view is NSSearchField { return own }
        return own + view.subviews.flatMap { allControls(in: $0) }
    }
}

/// Finds the keys of L, Lp and LKey in Swift source: the string literal that is
/// the first argument (both of Lp's literals after the count), read as Swift
/// reads it, with escapes, multi-line literals, their indentation and `\` at
/// the end of a line.
enum KeyScanner {
    struct Found {
        var keys: [String] = []
        var plurals: [(String, String)] = []
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func scan(_ source: String, file: String) throws -> Found {
        let chars = Array(source)
        var found = Found()
        var index = 0
        func lineNumber(_ at: Int) -> Int { chars[..<at].filter { $0 == "\n" }.count + 1 }
        while index < chars.count {
            // skip comments and string literals outside the calls
            if chars[index] == "/" && index + 1 < chars.count && chars[index + 1] == "/" {
                while index < chars.count && chars[index] != "\n" { index += 1 }
                continue
            }
            var name = ""
            for candidate in ["LKey(", "Lp(", "L("] where matches(chars, index, candidate) {
                name = candidate
                break
            }
            let before: Character = index > 0 ? chars[index - 1] : " "
            if name.isEmpty || before.isLetter || before.isNumber || before == "_" || before == "." {
                index += 1
                continue
            }
            // not the definitions themselves
            let lineStart = (chars[..<index].lastIndex(of: "\n") ?? -1) + 1
            if String(chars[lineStart ..< index]).contains("func ") {
                index += 1
                continue
            }
            var at = index + name.count
            if name == "Lp(" {
                var depth = 0
                while at < chars.count {
                    let c = chars[at]
                    if c == "(" || c == "[" { depth += 1 }
                    if c == ")" || c == "]" { depth -= 1 }
                    if c == "," && depth == 0 { break }
                    at += 1
                }
                at = skipSpace(chars, at + 1)
                let (one, afterOne) = try literal(chars, at, file: file, line: lineNumber(at))
                at = skipSpace(chars, afterOne)
                guard at < chars.count, chars[at] == "," else {
                    throw Failure(description: "\(file):\(lineNumber(at)): Lp without a second literal")
                }
                at = skipSpace(chars, at + 1)
                let (other, afterOther) = try literal(chars, at, file: file, line: lineNumber(at))
                found.keys += [one, other]
                found.plurals.append((one, other))
                index = afterOther
            } else {
                at = skipSpace(chars, at)
                let (key, after) = try literal(chars, at, file: file, line: lineNumber(at))
                found.keys.append(key)
                index = after
            }
        }
        return found
    }

    private static func matches(_ chars: [Character], _ at: Int, _ text: String) -> Bool {
        let wanted = Array(text)
        return at + wanted.count <= chars.count && Array(chars[at ..< at + wanted.count]) == wanted
    }

    private static func skipSpace(_ chars: [Character], _ start: Int) -> Int {
        var at = start
        while at < chars.count, chars[at] == " " || chars[at] == "\n" || chars[at] == "\t" { at += 1 }
        return at
    }

    /// The literal starting at `start`, and the index after it.
    private static func literal(_ chars: [Character], _ start: Int, file: String, line: Int) throws -> (String, Int) {
        guard start < chars.count, chars[start] == "\"" else {
            throw Failure(description: "\(file):\(line): the key is not a string literal")
        }
        if matches(chars, start, "\"\"\"") {
            guard let newline = chars[start...].firstIndex(of: "\n") else {
                throw Failure(description: "\(file):\(line): a multi-line literal without a line break")
            }
            var end = newline + 1
            while end < chars.count && !matches(chars, end, "\"\"\"") { end += 1 }
            let closingLineStart = (chars[..<end].lastIndex(of: "\n") ?? newline) + 1
            let indent = String(chars[closingLineStart ..< end])
            let body = String(chars[(newline + 1) ..< closingLineStart])
            var lines = body.components(separatedBy: "\n")
            lines.removeLast()
            var raw = ""
            for (number, original) in lines.enumerated() {
                var text = original
                if text.hasPrefix(indent) {
                    text = String(text.dropFirst(indent.count))
                } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw Failure(description: "\(file):\(line): a line of a literal is less indented than its end")
                } else {
                    text = ""
                }
                let continues = text.hasSuffix("\\") && !text.hasSuffix("\\\\")
                if continues { text.removeLast() }
                raw += text
                if !continues && number < lines.count - 1 { raw += "\n" }
            }
            return (try unescape(raw, file: file, line: line), end + 3)
        }
        var at = start + 1
        var raw = ""
        while at < chars.count && chars[at] != "\"" {
            if chars[at] == "\\" && at + 1 < chars.count {
                raw.append(chars[at])
                raw.append(chars[at + 1])
                at += 2
            } else {
                raw.append(chars[at])
                at += 1
            }
        }
        return (try unescape(raw, file: file, line: line), at + 1)
    }

    private static func unescape(_ raw: String, file: String, line: Int) throws -> String {
        var out = ""
        var chars = Array(raw)[...]
        while let c = chars.popFirst() {
            guard c == "\\", let next = chars.popFirst() else {
                out.append(c)
                continue
            }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"", "\\", "'": out.append(next)
            case "u":
                guard chars.popFirst() == "{", let close = chars.firstIndex(of: "}"),
                      let value = UInt32(String(chars[chars.startIndex ..< close]), radix: 16),
                      let scalar = UnicodeScalar(value) else {
                    throw Failure(description: "\(file):\(line): a bad \\u escape")
                }
                out.unicodeScalars.append(scalar)
                chars = chars[(close + 1)...]
            case "(":
                throw Failure(description: "\(file):\(line): a key with \\( ), which must be %@ or %ld")
            default:
                throw Failure(description: "\(file):\(line): an unknown escape \\\(next)")
            }
        }
        return out
    }
}
#endif
