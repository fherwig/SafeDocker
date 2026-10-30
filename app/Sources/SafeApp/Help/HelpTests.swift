#if DEBUG
import AppKit
import PDFKit
import SafeCore

// The help menu and window, the "?" buttons, the tooltips and the keyboard
// shortcuts, for `Safe --app-tests`. Nothing is put on the screen: the help
// window's present hook is replaced, and the other windows are never ordered in.

enum HelpTests {
    static let cases: [AppTests.Case] = [
        AppTests.Case("the Help menu is the last menu, the app's help menu, with Safe Help on Cmd-?") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let before = NSApp.mainMenu
            defer { NSApp.mainMenu = before }
            let delegate = AppDelegate()
            MainMenu.install(target: delegate)
            guard let main = NSApp.mainMenu, let help = main.items.last?.submenu else {
                AppTests.check(false, "no main menu")
                return
            }
            AppTests.equal(main.items.last?.title, "Help")
            AppTests.check(NSApp.helpMenu === help, "the Help menu is not NSApp.helpMenu")
            let safeHelp = help.item(withTitle: "Safe Help")
            AppTests.equal(safeHelp?.keyEquivalent, "?")
            AppTests.equal(safeHelp?.keyEquivalentModifierMask, .command)
            AppTests.equal(safeHelp?.action.map(NSStringFromSelector), "showSafeHelp:")
            AppTests.check(safeHelp?.target === delegate, "Safe Help does not go to the app")
            let topics = help.items.filter { $0.representedObject != nil }
            AppTests.equal(topics.map(\.title), ["The Idea Behind Safe", "Keyboard Shortcuts", "When Something Goes Wrong"])
            AppTests.equal(topics.compactMap { ($0.representedObject as? String).flatMap(HelpSection.init(rawValue:)) },
                           MainMenu.helpTopics)
            try withHelpWindow { window in
                delegate.showSafeHelp(topics[1])
                AppTests.equal(window.currentSection, .shortcuts)
                delegate.showSafeHelp(safeHelp)
                AppTests.equal(window.currentSection, nil)
            }
        },

        AppTests.Case("no shortcut is used twice in the main menu, and none takes a text-editing key") {
            let menu = MainMenu.build(target: AppDelegate())
            var seen: [String: String] = [:]
            for item in allItems(menu) {
                guard let shortcut = MainMenu.shortcut(of: item) else { continue }
                if let other = seen[shortcut] {
                    AppTests.check(false, "\(shortcut) is used by \(other) and \(item.title)")
                }
                seen[shortcut] = item.title
                // a menu item takes its key even while it is disabled, so these
                // would stop moving and deleting in the editor's text
                for editing in ["⌘↓", "⌘↑", "⌘←", "⌘→", "⌘\u{8}", "⌘\u{7f}", "⌘⌫"] {
                    AppTests.check(shortcut != editing, "\(item.title) takes \(editing) from the text")
                }
            }
            for expected in ["⌘O", "⇧⌘E", "⌥⌘E", "⌘S", "⌘W", "⌘0", "⌃⌘L", "⌘F", "⌘G", "⇧⌘G", "⌘?",
                             "⌘N", "⇧⌘N", "⇧⌘A", "⌘↩", "⌘E", "⌘+", "⌘=", "⌘-", "⌥⌘0", "⌘9", "⌥⌘↓", "⌥⌘↑", "⌘,"] {
                AppTests.check(seen[expected] != nil, "no menu item has \(expected)")
            }
        },

        AppTests.Case("every shortcut of the menu is in the help's table, with its item") {
            checkShortcutTable(in: HelpBook.helpURL(for: .english), or: "or")
        },

        AppTests.Case("the Volume menu has the buttons' actions and shortcuts, on only when they apply") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let stage = VolumeStage()
            let open = stage.record("safetest-open"), closed = stage.record("safetest-closed")
            let flows = stage.flows()
            stage.answers = ["pw"]
            flows.open(open)
            let controller = VolumesWindowController(actions: flows)
            defer { controller.window?.close() }
            let delegate = AppDelegate()
            delegate.volumesWindow = controller
            var inFront = false
            delegate.volumesWindowIsInFront = { _ in inFront }
            let menu = MainMenu.build(target: delegate)
            guard let volume = menu.item(withTitle: "Volume")?.submenu else {
                AppTests.check(false, "no Volume menu")
                return
            }
            let items = volume.items.filter { !$0.isSeparatorItem }
            AppTests.equal(items.map(\.title), ["New Empty Volume...", "New Volume from Folder...", "Add Existing Volume...",
                                                "Open Volume", "Close Volume", "Change Password...", "Remove from List"])
            AppTests.equal(items.map { MainMenu.shortcut(of: $0) ?? "" }, ["⌘N", "⇧⌘N", "⇧⌘A", "⌘↩", "⌘E", "", ""])
            AppTests.check(items.allSatisfy { $0.target === delegate }, "an item does not go to the app")
            AppTests.equal(menu.items.map(\.title).firstIndex(of: "Volume"), menu.items.map(\.title).firstIndex(of: "Edit")! + 2)
            func enabled(_ title: String) -> Bool {
                volume.item(withTitle: title).map { delegate.validateMenuItem($0) } ?? false
            }
            let onSelection = ["Open Volume", "Close Volume", "Change Password...", "Remove from List"]
            for title in ["New Empty Volume...", "New Volume from Folder...", "Add Existing Volume..."] {
                AppTests.check(enabled(title), "\(title) is off")
            }
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            AppTests.check(onSelection.allSatisfy { !enabled($0) }, "on while the Volumes window is not in front")
            inFront = true
            controller.table.deselectAll(nil)
            AppTests.check(onSelection.allSatisfy { !enabled($0) }, "on without a selection")
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            AppTests.check(enabled("Open Volume") && enabled("Close Volume") && !enabled("Change Password...")
                           && enabled("Remove from List"), "an open volume")
            controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            AppTests.check(enabled("Open Volume") && !enabled("Close Volume") && enabled("Change Password..."),
                           "a closed volume")
            // the buttons follow the same rule
            AppTests.equal(controller.buttons["Close"]?.isEnabled, false)
            AppTests.equal(controller.buttons["Change Password..."]?.isEnabled, true)

            // the menu does what the button does
            controller.table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            delegate.closeSelectedVolume(volume.item(withTitle: "Close Volume"))
            AppTests.equal(stage.detachCalls.map(\.mountPoint), [stage.mount("safetest-open")])
            AppTests.check(stage.detachCalls.allSatisfy { !$0.force }, "a detach was forced")

            // Return in the list opens the selected volume, Delete asks to remove it
            controller.table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
            stage.asked = []
            stage.answers = [nil]
            controller.table.keyDown(with: key("\r"))
            AppTests.equal(stage.asked.map(\.title), ["Open “safetest-closed”"])
            stage.choices = [1]
            controller.table.keyDown(with: key("\u{7f}"))
            AppTests.equal(stage.questions.last?.title, "Remove “safetest-closed” from the list?")
            AppTests.check(stage.list.volumes.contains { $0.id == closed.id }, "removed after Cancel")
            AppTests.check(controller.window?.isVisible == false, "the window is on the screen")
        },

        AppTests.Case("the help file is found, every section is in it, and a missing file gives a note") {
            AppTests.check(HelpBook.isComplete(at: HelpBook.resourceURL), HelpBook.resourceURL.path)
            let book = HelpBook.load()
            AppTests.check(book.isComplete, "the help was not read from \(HelpBook.resourceURL.path)")
            for section in HelpSection.allCases {
                guard let range = book.headings[section] else {
                    AppTests.check(false, "no heading for \(section)")
                    continue
                }
                AppTests.equal((book.text.string as NSString).substring(with: range), section.title)
                AppTests.check((book.plainText(of: section)?.count ?? 0) > 400, "section \(section) is nearly empty")
            }
            // the rules of plain English: no exclamation marks
            AppTests.check(!book.text.string.contains("!"), "an exclamation mark in the help")
            // headings come in the order of the sections
            let starts = HelpSection.allCases.compactMap { book.headings[$0]?.location }
            AppTests.equal(starts, starts.sorted())
            let missing = HelpBook.load(from: URL(fileURLWithPath: "/nonexistent/safetest-help.md"))
            AppTests.check(!missing.isComplete)
            AppTests.check(missing.text.string.contains("help text is missing"), missing.text.string)
            AppTests.check(!HelpBook.isComplete(at: URL(fileURLWithPath: "/nonexistent/safetest-help.md")))
        },

        AppTests.Case("the help renders headings, lists, tables and code from its Markdown") {
            let result = HelpRenderer.render("""
                # Title

                Intro with `code` and **bold** words
                on two lines.

                ## First {#idea}

                - one
                - two

                | Key | What |
                |---|---|
                | ⌘S | Save |

                    openssl enc -d

                1. step
                """)
            let text = result.text.string
            AppTests.check(text.hasPrefix("Title\nIntro with code and bold words on two lines.\nFirst\n"), text)
            AppTests.check(text.contains("•\tone\n•\ttwo\n"), text)
            AppTests.check(text.contains("Key\tWhat\n⌘S\tSave\n"), text)
            AppTests.check(text.contains("openssl enc -d\n1.\tstep"), text)
            AppTests.check(!text.contains("|") && !text.contains("**") && !text.contains("`") && !text.contains("{#"), text)
            AppTests.equal(result.headings[.idea].map { (text as NSString).substring(with: $0) }, "First")
            let codeFont = result.text.attribute(.font, at: (text as NSString).range(of: "openssl").location,
                                                 effectiveRange: nil) as? NSFont
            AppTests.check(codeFont?.isFixedPitch == true, "code is not in a fixed-width font")
        },

        AppTests.Case("the help window lists the sections, goes to each, and searches") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            let window = HelpWindowController(book: HelpBook.load())
            let present = HelpWindowController.present
            defer {
                HelpWindowController.present = present
                window.close()
            }
            var presented = 0
            HelpWindowController.present = { _ in presented += 1 }
            AppTests.equal(window.sections, HelpSection.allCases)
            AppTests.equal(window.numberOfRows(in: window.sidebar), HelpSection.allCases.count)
            AppTests.check(window.textView.string.count > 20_000, "the text is short: \(window.textView.string.count)")
            AppTests.check(!window.textView.isEditable, "the help can be edited")
            for section in HelpSection.allCases {
                AppTests.check(window.textView.string.contains(section.title + "\n"), "no heading \(section.title)")
            }
            for section in [HelpSection.volumes, .locking, .passwords] {
                window.show(section)
                AppTests.equal(window.currentSection, section)
                AppTests.equal(window.sidebar.selectedRow, HelpSection.allCases.firstIndex(of: section))
                AppTests.equal(window.sectionAtTop(), section, "the text did not scroll to \(section)")
            }
            AppTests.equal(presented, 3)
            // choosing in the sidebar goes there too
            window.sidebar.selectRowIndexes(IndexSet(integer: HelpSection.allCases.firstIndex(of: .encrypting)!),
                                            byExtendingSelection: false)
            AppTests.equal(window.currentSection, .encrypting)
            AppTests.equal(window.sectionAtTop(), .encrypting)
            window.searchField.stringValue = "sparse bundle"
            let first = window.find(.next)
            AppTests.check(first != nil, "the search found nothing")
            AppTests.check(window.matchLabel.stringValue.hasSuffix("matches"), window.matchLabel.stringValue)
            let second = window.find(.next)
            AppTests.check(second != nil && second != first, "Find Next stayed")
            window.searchField.stringValue = "safetest-nowhere"
            AppTests.equal(window.find(.next), nil)
            AppTests.equal(window.matchLabel.stringValue, "Not found")
            AppTests.check(window.window?.isVisible == false, "the help window is on the screen")
            AppTests.check((window.window as? NSPanel)?.worksWhenModal == true, "the help cannot be used beside a dialog")
            OffScreen.render(window.window!, as: "help-window")
            window.go(to: .shortcuts)
            OffScreen.render(window.window!, as: "help-shortcuts")
        },

        AppTests.Case("each “?” button opens the help at its section") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            try withHelpWindow { help in
                let stage = VolumeStage()
                _ = stage.record("safetest-help")
                let volumes = VolumesWindowController(actions: stage.flows())
                defer { volumes.window?.close() }
                AppTests.equal(volumes.helpButton.bezelStyle, .helpButton)
                volumes.helpButton.performClick(nil)
                AppTests.equal(help.currentSection, .volumes)

                try EditorTests.withEditor { _, _, editor, _ in
                    AppTests.equal(editor.helpButton.bezelStyle, .helpButton)
                    editor.helpButton.performClick(nil)
                    AppTests.equal(help.currentSection, .editing)
                    // while the text is covered, the "?" is about locking
                    EditorTests.type("safetest changed\n", into: editor)
                    editor.lock()
                    editor.helpButton.performClick(nil)
                    AppTests.equal(help.currentSection, .locking)
                    AppTests.equal(editor.helpButton.toolTip, "Open Safe Help about locking.")
                }

                try EditorTests.withViewer(of: try EditorTests.makePNG(), named: "safetest-help.png", kind: .image) { viewer in
                    AppTests.equal(viewer.helpButton.bezelStyle, .helpButton)
                    viewer.helpButton.performClick(nil)
                    AppTests.equal(help.currentSection, .viewing)
                }

                for (alert, section) in [(PasswordPrompt.onceAlert(title: "Open “safetest”", message: "x").0, HelpSection.passwords),
                                         (PasswordPrompt.twiceAlert(title: "New “safetest”", message: "x").0, .passwords),
                                         (Alerts.formAlert("New empty volume", "x", fields: [("Name:", "Private")]).0, .volumes)] {
                    help.go(to: nil)
                    AppTests.check(alert.showsHelp, "\(alert.messageText) has no “?”")
                    let button = HelpButton.buttons(in: alert.window.contentView).first { $0.bezelStyle == .helpButton }
                    AppTests.check(button != nil, "no “?” button in \(alert.messageText)")
                    button?.performClick(nil)
                    AppTests.equal(help.currentSection, section, alert.messageText)
                    AppTests.check(!alert.window.isVisible, "the dialog is on the screen")
                }
            }
        },

        AppTests.Case("every control in the windows and dialogs has a tooltip") {
            guard OffScreen.available else { try AppTests.skip("no window server") }
            func audit(_ view: NSView?, _ name: String) {
                let missing = ToolTipAudit.missing(in: view)
                AppTests.check(missing.isEmpty, "\(name): no tooltip on " + missing.map(ToolTipAudit.describe).joined(separator: ", "))
            }
            let stage = VolumeStage()
            _ = stage.record("safetest-tips")
            let volumes = VolumesWindowController(actions: stage.flows())
            defer { volumes.window?.close() }
            audit(volumes.window?.contentView, "the Volumes window")
            AppTests.check(volumes.table.tableColumns.allSatisfy { !($0.headerToolTip ?? "").isEmpty }, "a column without a tooltip")
            AppTests.check(ToolTipAudit.needsToolTip(volumes.statusLabel), "the status line does not count")
            AppTests.check(!(volumes.statusLabel.toolTip ?? "").isEmpty)
            // controls with a shortcut say it at the end
            for action in VolumeMenuAction.allCases where !action.key.isEmpty {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: action.key)
                item.keyEquivalentModifierMask = action.modifiers
                let shortcut = MainMenu.shortcut(of: item) ?? "?"
                AppTests.check(action.toolTip.hasSuffix("(\(shortcut)).") , "\(action) does not end with (\(shortcut))")
            }

            try EditorTests.withEditor { _, _, editor, _ in
                audit(editor.window?.contentView, "the editor")
                editor.showSearch()
                audit(editor.window?.contentView, "the editor with its search bar")
                OffScreen.render(editor.window!, as: "editor")
                AppTests.check(editor.searchField.toolTip?.hasSuffix("(⌘F).") == true, editor.searchField.toolTip ?? "")
                EditorTests.type("safetest changed\n", into: editor)
                editor.lock()
                AppTests.check(editor.isLocked)
                audit(editor.window?.contentView, "the locked editor")
                OffScreen.render(editor.window!, as: "editor-locked")
            }

            try EditorTests.withViewer(of: try EditorTests.makePNG(), named: "safetest-tips.png", kind: .image) { viewer in
                audit(viewer.window?.contentView, "the picture viewer")
            }
            try EditorTests.withViewer(of: try twoPagePDF(), named: "safetest-tips.pdf", kind: .pdf) { viewer in
                audit(viewer.window?.contentView, "the PDF viewer")
                OffScreen.render(viewer.window!, as: "viewer-pdf")
            }

            let (once, field) = PasswordPrompt.onceAlert(title: "Open “safetest”", message: "x")
            audit(once.accessoryView, "the password dialog")
            AppTests.check(!(field.toolTip ?? "").isEmpty)
            let (twice, _, _) = PasswordPrompt.twiceAlert(title: "New “safetest”", message: "x")
            audit(twice.accessoryView, "the new-password dialog")
            let (form, _) = Alerts.formAlert("New empty volume", "x", fields: [("Name:", "Private"), ("Maximum size:", "1 GB")])
            audit(form.accessoryView, "the new-volume form")
            OffScreen.render(form.window, as: "new-volume-form")
            for alert in [once, twice, form] {
                let buttons = HelpButton.buttons(in: alert.window.contentView)
                AppTests.check(buttons.count >= 3, "\(alert.messageText): \(buttons.count) buttons")
                for button in buttons {
                    AppTests.check(!(button.toolTip ?? "").isEmpty, "\(alert.messageText): no tooltip on “\(button.title)”")
                }
            }

            let help = HelpWindowController(book: HelpBook.load())
            defer { help.close() }
            audit(help.window?.contentView, "the help window")
        },

        AppTests.Case("the View menu zooms the viewer and turns the pages of a PDF") {
            func item(_ action: Selector) -> NSMenuItem {
                NSMenuItem(title: "", action: action, keyEquivalent: "")
            }
            let next = item(#selector(ViewerWindowController.viewerNextPage(_:)))
            let previous = item(#selector(ViewerWindowController.viewerPreviousPage(_:)))
            let zoomIn = item(#selector(ViewerWindowController.viewerZoomIn(_:)))
            try EditorTests.withViewer(of: try twoPagePDF(), named: "safetest-pages.pdf", kind: .pdf) { viewer in
                guard let pdf = viewer.pdfView else {
                    AppTests.check(false, "no PDF view")
                    return
                }
                AppTests.check(viewer.validateMenuItem(next) && !viewer.validateMenuItem(previous), "on the first page")
                viewer.viewerNextPage(nil)
                AppTests.equal(pdf.currentPage.flatMap { pdf.document?.index(for: $0) }, 1)
                AppTests.check(!viewer.validateMenuItem(next) && viewer.validateMenuItem(previous), "on the last page")
                AppTests.check(viewer.validateMenuItem(zoomIn))
                viewer.viewerActualSize(nil)
                AppTests.check(!pdf.autoScales && abs(pdf.scaleFactor - 1) < 0.001, "not at actual size")
                viewer.viewerZoomIn(nil)
                AppTests.check(pdf.scaleFactor > 1.01, "did not zoom in: \(pdf.scaleFactor)")
                viewer.viewerZoomToFit(nil)
                AppTests.check(pdf.autoScales, "Zoom to Fit is off")
            }
            try EditorTests.withViewer(of: try EditorTests.makePNG(), named: "safetest-zoom.png", kind: .image) { viewer in
                guard let scroll = viewer.imageScroll else {
                    AppTests.check(false, "the picture cannot zoom")
                    return
                }
                AppTests.check(!viewer.validateMenuItem(next), "Next Page for a picture")
                // an 8-point picture is not enlarged at first, but fitted by Zoom to Fit
                AppTests.check(abs(scroll.magnification - 1) < 0.001, "first magnification \(scroll.magnification)")
                viewer.viewerZoomIn(nil)
                AppTests.check(abs(scroll.magnification - ViewerWindowController.zoomStep) < 0.001,
                               "Zoom In gave \(scroll.magnification)")
                viewer.viewerZoomOut(nil)
                viewer.viewerZoomOut(nil)
                AppTests.check(scroll.magnification < 1, "Zoom Out gave \(scroll.magnification)")
                viewer.viewerActualSize(nil)
                AppTests.check(abs(scroll.magnification - 1) < 0.001, "Actual Size gave \(scroll.magnification)")
                viewer.viewerZoomToFit(nil)
                AppTests.check(scroll.magnification > 10, "Zoom to Fit gave \(scroll.magnification)")
            }
        },
    ]

    // MARK: helpers

    /// Every shortcut of the menu, in Safe's language, is in the table of the
    /// help file's section of shortcuts with its item's title, and the table
    /// names no shortcut that the menu lacks. `or` is the word of "⌘+ (or ⌘=)".
    static func checkShortcutTable(in url: URL, or: String) {
        guard let markdown = try? String(contentsOf: url, encoding: .utf8),
              let start = markdown.range(of: "{#shortcuts}"),
              let end = markdown.range(of: "{#problems}") else {
            AppTests.check(false, "no section of shortcuts in \(url.path)")
            return
        }
        let rows = markdown[start.upperBound ..< end.lowerBound].split(separator: "\n")
            .filter { $0.hasPrefix("| ") }
        let menu = MainMenu.build(target: AppDelegate())
        var menuShortcuts: Set<String> = []
        for item in allItems(menu) {
            guard let shortcut = MainMenu.shortcut(of: item) else { continue }
            menuShortcuts.insert(shortcut)
            let title = item.title.replacingOccurrences(of: "...", with: "")
                .replacingOccurrences(of: " …", with: "").replacingOccurrences(of: "…", with: "")
            let row = rows.first { row in
                row.split(separator: "|").first.map { cell in
                    cell.split(separator: " ").contains { $0 == shortcut }
                        || cell.contains("(\(or) \(shortcut))")
                } ?? false
            }
            AppTests.check(row?.contains(title) == true, "\(url.lastPathComponent) has no row “\(shortcut) \(title)”")
        }
        for row in rows {
            guard let first = row.split(separator: "|").first?.trimmingCharacters(in: .whitespaces),
                  first.hasPrefix("⌘") || first.hasPrefix("⇧") || first.hasPrefix("⌥") || first.hasPrefix("⌃")
            else { continue }
            let keys = first.replacingOccurrences(of: "(\(or) ", with: "").replacingOccurrences(of: ")", with: "")
                .split(separator: " ").map(String.init)
            for key in keys where !(key.hasPrefix("⇧") && key.count == 2) {
                AppTests.check(menuShortcuts.contains(key) || key == "⌘D",
                               "\(url.lastPathComponent) names \(key), which the menu lacks")
            }
        }
    }

    /// Every item of a menu and its submenus.
    static func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(allItems) ?? []) }
    }

    /// A key press of `characters` without modifiers.
    static func key(_ characters: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: false, keyCode: characters == "\r" ? 36 : 51)!
    }

    /// The app's help window with its present hook replaced, so that it stays
    /// off the screen while `body` runs.
    static func withHelpWindow(_ body: (HelpWindowController) throws -> Void) throws {
        let present = HelpWindowController.present
        defer { HelpWindowController.present = present }
        HelpWindowController.present = { _ in }
        let help = HelpWindowController.shared
        try body(help)
        AppTests.check(help.window?.isVisible == false, "the help window is on the screen")
    }

    /// A PDF of two pages.
    static func twoPagePDF() throws -> Data {
        let document = PDFDocument()
        for index in 0 ..< 2 {
            let image = NSImage(size: NSSize(width: 200, height: 260))
            image.lockFocus()
            NSColor.black.setFill()
            NSRect(x: 20 + CGFloat(index) * 40, y: 20, width: 60, height: 60).fill()
            image.unlockFocus()
            guard let page = PDFPage(image: image) else { throw CryptError.io("cannot make a PDF page") }
            document.insert(page, at: index)
        }
        guard let data = document.dataRepresentation() else { throw CryptError.io("cannot make a PDF") }
        return data
    }
}
#endif
