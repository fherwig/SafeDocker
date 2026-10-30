import AppKit
import SafeCore

// WP3. The interface is fixed by the building plan, section 3.1. The window is
// built in code. DocumentRouter calls showWindow(nil) after init; init itself
// shows nothing.

/// The window of the text editor; the text exists only in memory (R2, section 4.5).
final class EditorWindowController: NSWindowController, Lockable, NSWindowDelegate,
                                    NSTextViewDelegate, NSSearchFieldDelegate,
                                    NSMenuItemValidation, SafeTextViewOwner {
    /// The file as opened or last saved; its hash is the conflict check of the next save.
    private(set) var opened: OpenedFile
    /// The password that opened the file, until the window closes.
    private var password: SecureBytes?

    let textView = SafeTextView.makeEditor()
    private let scrollView = NSScrollView()
    private let readOnlyBar = ReadOnlyBar()
    private let searchBar = SearchBar()
    private let lockView: LockCoverView
    let statusLabel = NSTextField(labelWithString: "")
    let helpButton = HelpButton.make(.editing, toolTip: L("Open Safe Help about the editor."))
    private let editorUndo = UndoManager()
    private lazy var fieldEditor: SafeTextView = {
        let editor = SafeTextView.makeFieldEditor()
        editor.owner = self
        return editor
    }()

    private var dirty = false
    private var savedAt: Date?
    private var savedWithBackup = true
    private(set) var isLocked = false
    private(set) var isClosed = false
    /// How the text is written back: the encoding it was read in (TextCoding).
    private(set) var textCoding: TextCoding
    /// True while the text is shown read only because Safe could not confirm
    /// the password (section 4.4), until the user allows editing.
    private(set) var isReadOnly: Bool
    /// True once a save has written NAME.crypt.bak. For a file whose password
    /// Safe could not confirm, later saves keep that .bak: if the password was
    /// wrong after all, it still holds the file as it was before.
    private var wroteBackup = false

    /// The note above the text of a file whose password Safe could not confirm,
    /// when the caller gave none: such a text is never editable without Allow Editing.
    static var unconfirmedNote: String {
        L("""
            Safe could not confirm the password, so this is shown read only. If it is what you \
            expect, the password is right.
            """)
    }

    /// Called when the window closed; DocumentRouter drops its reference.
    var onClose: (() -> Void)?

    /// The name of the volume that Safe closed on lock and that held this file,
    /// if any (G4: the volumes close on lock, also under unsaved changes); the
    /// checks replace it.
    static var closedVolumeName: (URL) -> String? = { VolumeController.shared.closedVolumeName(holding: $0) }
    /// Opens that volume again at the same place, after asking its password;
    /// true if the file's folder is there again. The checks replace it.
    static var reopenVolume: (URL) -> Bool = { VolumeController.shared.reopenVolume(holding: $0) }

    /// Opens an editor on decrypted text; keeps the password until the window closes.
    convenience init(opened: OpenedFile, text: String, password: SecureBytes) {
        self.init(opened: opened, text: text, password: password, coding: .utf8, readOnlyNote: nil)
    }

    /// The same, for text in another encoding, and read only with a note when Safe
    /// could not confirm the password.
    init(opened: OpenedFile, text: String, password: SecureBytes, coding: TextCoding, readOnlyNote: String?) {
        // a text whose password Safe could not confirm is read only until the user allows editing
        let readOnlyNote = readOnlyNote ?? (opened.check == .confirmed ? nil : Self.unconfirmedNote)
        self.opened = opened
        self.password = password
        self.textCoding = coding
        self.isReadOnly = readOnlyNote != nil
        self.lockView = LockCoverView(fileName: opened.originalName)
        let window = EditorWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                  backing: .buffered, defer: true)
        window.isRestorable = false
        window.sharingType = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 240)
        super.init(window: window)

        window.delegate = self
        window.commandHandler = { [weak self] command in self?.handle(command) ?? false }
        buildContent(in: window)
        textView.string = text
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if let note = readOnlyNote {
            readOnlyBar.note = note
            readOnlyBar.isHidden = false
            textView.isEditable = false
        }
        updateTitle()
        updateStatus()
        window.center()
        Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)

        LockController.shared.register(self)
        Self.track(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// True if the text changed since it was opened or saved.
    var hasUnsavedChanges: Bool {
        dirty
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if !isLocked {
            window?.makeFirstResponder(textView)
        }
    }

    // MARK: building the window

    private func buildContent(in window: NSWindow) {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.owner = self
        scrollView.documentView = textView

        let middle = NSView()
        for view in [scrollView, lockView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            middle.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: middle.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: middle.trailingAnchor),
                view.topAnchor.constraint(equalTo: middle.topAnchor),
                view.bottomAnchor.constraint(equalTo: middle.bottomAnchor),
            ])
        }
        lockView.isHidden = true
        lockView.onUnlock = { [weak self] in
            if self?.unlock() == true {
                self?.offerToReopenVolume()
            }
        }

        readOnlyBar.isHidden = true
        readOnlyBar.onAllow = { [weak self] in self?.allowEditing() }

        searchBar.isHidden = true
        searchBar.field.delegate = self
        searchBar.onNext = { [weak self] in self?.search(.next) }
        searchBar.onPrevious = { [weak self] in self?.search(.previous) }
        searchBar.onDone = { [weak self] in self?.hideSearch() }

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.identifier = ToolTipAudit.statusIdentifier
        helpButton.controlSize = .small
        helpButton.translatesAutoresizingMaskIntoConstraints = false
        let statusBar = NSView()
        statusBar.addSubview(statusLabel)
        statusBar.addSubview(helpButton)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: statusBar.leadingAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: helpButton.leadingAnchor, constant: -8),
            statusLabel.topAnchor.constraint(equalTo: statusBar.topAnchor, constant: 4),
            statusLabel.bottomAnchor.constraint(equalTo: statusBar.bottomAnchor, constant: -5),
            helpButton.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor, constant: -8),
            helpButton.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
            statusBar.heightAnchor.constraint(greaterThanOrEqualTo: helpButton.heightAnchor, constant: 6),
        ])

        let column = NSStackView(views: [readOnlyBar, searchBar, middle, statusBar])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.distribution = .fill
        for view in [readOnlyBar, searchBar, middle, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        // the text takes the room left by the search bar and the status line
        middle.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        middle.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        window.contentView = column
    }

    private func updateTitle() {
        window?.title = opened.originalName
        window?.subtitle = DocumentAlerts.folderName(of: opened.url)
    }

    private func updateStatus() {
        if isLocked {
            statusLabel.stringValue = EditorStatus.locked
        } else {
            let backup = savedWithBackup
                ? EditorStatus.backupName(forEncryptedFileName: opened.url.lastPathComponent) : nil
            let legacy = opened.variant == .current ? nil : DocumentAlerts.describe(opened.variant)
            let coding = textCoding == .utf8 ? nil : textCoding.name
            statusLabel.stringValue = EditorStatus.line(savedAt: savedAt, backupName: backup, legacyName: legacy,
                                                        codingName: coding)
        }
        // the whole line, if a narrow window cuts it
        statusLabel.toolTip = statusLabel.stringValue
    }

    /// The status line as shown; for the checks.
    var statusText: String {
        statusLabel.stringValue
    }

    // MARK: keyboard shortcuts and menu commands

    /// The window's own shortcuts; true if handled.
    func handle(_ command: EditorCommand) -> Bool {
        if isLocked {
            if command == .close {
                window?.performClose(nil)
            } else {
                DocumentAlerts.beep()
            }
            return true
        }
        switch command {
        case .save:
            save()
        case .close:
            window?.performClose(nil)
        case .find, .findNext, .findPrevious:
            perform(command)
        case .cut:
            return NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: self)
        case .copy:
            return NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: self)
        case .paste:
            return NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: self)
        case .selectAll:
            return NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case .undo:
            if editorUndo.canUndo {
                editorUndo.undo()
            } else {
                DocumentAlerts.beep()
            }
        case .redo:
            if editorUndo.canRedo {
                editorUndo.redo()
            } else {
                DocumentAlerts.beep()
            }
        }
        return true
    }

    /// Find, Find Next and Find Previous, from the text view, the menu or the window.
    func perform(_ command: EditorCommand) {
        guard !isLocked else { return }
        switch command {
        case .find:
            showSearch()
        case .findNext, .findPrevious:
            if searchBar.field.stringValue.isEmpty {
                showSearch()
            } else {
                search(command == .findNext ? .next : .previous)
            }
        default:
            break
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        save()
    }

    @objc func exportDecryptedCopy(_ sender: Any?) {
        guard !isLocked, !isClosed else { return }
        // in the file's own encoding, so an unchanged text exports the original bytes
        let text = textView.string
        ExportController.export(textCoding.encode(text) ?? Data(text.utf8), originalName: opened.originalName,
                                from: opened.url, window: window)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(saveDocument(_:)):
            return !isLocked && !isClosed && !isReadOnly
        case #selector(exportDecryptedCopy(_:)):
            return !isLocked && !isClosed
        default:
            return true
        }
    }

    // MARK: search

    enum SearchStep {
        case incremental, next, previous
    }

    func showSearch() {
        searchBar.isHidden = false
        window?.makeFirstResponder(searchBar.field)
        searchBar.field.currentEditor()?.selectAll(nil)
    }

    func hideSearch() {
        searchBar.isHidden = true
        searchBar.matchLabel.stringValue = ""
        if !isLocked {
            window?.makeFirstResponder(textView)
        }
    }

    /// Searches the text for the search field's string and selects the match.
    @discardableResult
    func search(_ step: SearchStep) -> NSRange? {
        let needle = searchBar.field.stringValue
        guard !needle.isEmpty else {
            searchBar.matchLabel.stringValue = ""
            return nil
        }
        let text = textView.string
        let selection = textView.selectedRange()
        let found: NSRange?
        switch step {
        case .incremental:
            found = TextSearch.find(needle, in: text, from: selection.location, backwards: false)
        case .next:
            found = TextSearch.find(needle, in: text, from: NSMaxRange(selection), backwards: false)
        case .previous:
            found = TextSearch.find(needle, in: text, from: selection.location, backwards: true)
        }
        guard let range = found else {
            searchBar.matchLabel.stringValue = L("Not found")
            if step != .incremental {
                DocumentAlerts.beep()
            }
            return nil
        }
        let count = TextSearch.count(needle, in: text)
        searchBar.matchLabel.stringValue = Lp(count, "%ld match", "%ld matches")
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        if window?.isVisible == true {
            textView.showFindIndicator(for: range)
        }
        return range
    }

    /// The search string; for the checks.
    var searchString: String {
        get { searchBar.field.stringValue }
        set { searchBar.field.stringValue = newValue }
    }

    var isSearchVisible: Bool {
        !searchBar.isHidden
    }

    var searchField: NSSearchField {
        searchBar.field
    }

    func controlTextDidChange(_ obj: Notification) {
        search(.incremental)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === searchBar.field else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            search(shift ? .previous : .next)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hideSearch()
            return true
        default:
            return false
        }
    }

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        // the search field gets an editor with the same switches off as the text
        (client as AnyObject?) === searchBar.field ? fieldEditor : nil
    }

    // MARK: editing

    func textDidChange(_ notification: Notification) {
        markDirty()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool {
        !isLocked && !isClosed && !isReadOnly
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        isLocked ? nil : editorUndo
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        isLocked ? nil : editorUndo
    }

    private func markDirty() {
        dirty = true
        window?.isDocumentEdited = true
    }

    private func markClean() {
        dirty = false
        window?.isDocumentEdited = false
    }

    // MARK: saving (R2, 5.3)

    /// Cmd-S: encrypts the text with the password that opened the file and replaces
    /// the file through CryptFile.save. On a conflict it offers the three choices of 4.5.
    @discardableResult
    func save() -> Bool {
        guard !isLocked, !isClosed, !isReadOnly, let password = password else {
            DocumentAlerts.beep()
            return false
        }
        if let refusal = DocumentAlerts.saveRefusal() {
            DocumentAlerts.show(L("%@ was not saved", opened.originalName), refusal, on: window)
            return false
        }
        guard let data = textCoding.encode(textView.string) else {
            askToSaveAsUTF8()
            return false
        }
        do {
            // the first save writes the .bak; while the password is not confirmed,
            // later saves keep it, so that two saves cannot lose the original
            let replaceBackup = opened.check == .confirmed || !wroteBackup
            let saved = try CryptFile.save(data, over: opened, password: password, replacingBackup: replaceBackup)
            wroteBackup = true
            didSave(saved, withBackup: true)
            return true
        } catch CryptError.conflict {
            let folder = opened.url.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: folder.path) {
                if let volume = Self.closedVolumeName(opened.url) {
                    // Safe closed its volume on lock: open it again at the same place
                    askToReopen(volume, thenSave: true)
                    return false
                }
                // the volume it is on was closed, for example; this is no conflict
                DocumentAlerts.show(L("%@ was not saved", opened.originalName), L("""
                    The folder that holds it, %@, is not there any more. If it is on \
                    a volume, the volume was closed: open the volume again, then save. Your \
                    changes are still in the window.
                    """, folder.path), on: window)
                return false
            }
            askAboutConflict(data)
            return false
        } catch {
            DocumentAlerts.show(L("%@ was not saved", opened.originalName), DocumentAlerts.describe(error), on: window)
            return false
        }
    }

    /// The text holds characters that the file's encoding (ISO Latin-1) cannot
    /// hold: offers to save it in UTF-8 instead.
    private func askToSaveAsUTF8() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("%@ cannot be saved in %@", opened.originalName, textCoding.name)
        alert.informativeText = L("""
            Some characters in the text do not exist in %@, the encoding of this file. Safe can \
            save it in UTF-8 instead; programs that expect %@ may then show some characters wrongly.
            """, textCoding.name, textCoding.name)
        alert.addButton(withTitle: L("Save as UTF-8"))
        alert.addButton(withTitle: L("Cancel"))
        DocumentAlerts.run(alert, on: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn, !self.isClosed, !self.isLocked else {
                return
            }
            self.textCoding = .utf8
            self.updateStatus()
            self.save()
        }
    }

    /// After the user unlocked the editor: if Safe closed the volume holding the
    /// file when it locked, offers to open it again, so that the changes can be saved.
    func offerToReopenVolume() {
        guard !isLocked, !isClosed, dirty,
              !FileManager.default.fileExists(atPath: opened.url.deletingLastPathComponent().path),
              let volume = Self.closedVolumeName(opened.url)
        else { return }
        askToReopen(volume, thenSave: false)
    }

    /// The question of offerToReopenVolume, and of a save that found the folder gone.
    private func askToReopen(_ volume: String, thenSave: Bool) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = thenSave ? L("%@ was not saved", opened.originalName)
            : L("The volume “%@” was closed", volume)
        alert.informativeText = L("""
            Safe closed the volume “%@”, which holds %@, when it locked. \
            Open it again at the same place to save your changes; they are still in the window.
            """, volume, opened.originalName)
        alert.addButton(withTitle: L("Open “%@” Again", volume))
        alert.addButton(withTitle: thenSave ? L("Cancel") : L("Not Now"))
        DocumentAlerts.run(alert, on: window) { [weak self] response in
            guard let self = self, response == .alertFirstButtonReturn, !self.isClosed, !self.isLocked else {
                return
            }
            if Self.reopenVolume(self.opened.url) && thenSave {
                self.save()
            }
        }
    }

    /// Ends the read-only view of a text whose password Safe could not confirm:
    /// the user has looked at it and takes it as right (section 4.4).
    func allowEditing() {
        guard isReadOnly, !isClosed else { return }
        isReadOnly = false
        readOnlyBar.isHidden = true
        if !isLocked {
            textView.isEditable = true
            window?.makeFirstResponder(textView)
        }
        updateStatus()
    }

    /// The note above a read-only text; for the checks.
    var readOnlyNote: String? {
        isReadOnly ? readOnlyBar.label.stringValue : nil
    }

    private func didSave(_ saved: OpenedFile, withBackup: Bool) {
        opened = saved
        savedAt = Date()
        savedWithBackup = withBackup
        markClean()
        updateTitle()
        updateStatus()
    }

    /// What the user chose when the file changed on disk.
    enum ConflictChoice {
        case keepCopy, discardMine, cancel
    }

    private func askAboutConflict(_ data: Data) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("%@ changed on disk", opened.url.lastPathComponent)
        alert.informativeText = L("""
            Another program or another Mac changed the file after you opened it. You can keep your \
            version as a separate encrypted copy next to it, or discard your changes and load the \
            file as it is now.
            """)
        alert.addButton(withTitle: L("Keep My Version as a Copy"))
        alert.addButton(withTitle: L("Discard My Changes"))
        alert.addButton(withTitle: L("Cancel"))
        DocumentAlerts.run(alert, on: window) { [weak self] response in
            // an answer given after a lock is not taken: the text is covered (G4)
            guard let self = self, !self.isClosed, !self.isLocked else { return }
            switch response {
            case .alertFirstButtonReturn: self.resolveConflict(.keepCopy, data: data)
            case .alertSecondButtonReturn: self.resolveConflict(.discardMine, data: data)
            default: break
            }
        }
    }

    /// Carries out the choice; true if the editor now matches a file on disk.
    @discardableResult
    func resolveConflict(_ choice: ConflictChoice, data: Data) -> Bool {
        guard !isClosed, !isLocked, let password = password else { return false }
        switch choice {
        case .cancel:
            return false
        case .keepCopy:
            if let refusal = DocumentAlerts.saveRefusal() {
                DocumentAlerts.show(L("Your version was not saved"), refusal, on: window)
                return false
            }
            do {
                let copy = try ConflictCopy.write(data, originalName: opened.originalName,
                                                  nextTo: opened.url, password: password)
                didSave(copy, withBackup: false)
                return true
            } catch {
                DocumentAlerts.show(L("Your version was not saved"), DocumentAlerts.describe(error), on: window)
                return false
            }
        case .discardMine:
            do {
                let (current, plaintext) = try CryptFile.open(at: opened.url, password: password, allowLegacy: true)
                let utf8 = TextCoding.decodeUTF8(plaintext)
                // a file that another Mac encrypted with another password can pass
                // the format's own check: as when opening (section 4.4), garbage is
                // never loaded, and text Safe could not confirm is shown read only
                if current.check != .confirmed && utf8 == nil && !Plausibility.looksLikeText(plaintext) {
                    throw CryptError.io(L("Safe could not confirm the password for the file as it is now."))
                }
                let (text, coding) = utf8 ?? TextCoding.decodeAnyway(plaintext)
                opened = current
                textCoding = coding
                textView.string = text
                textView.setSelectedRange(NSRange(location: 0, length: 0))
                editorUndo.removeAllActions()
                savedAt = nil
                // the next save backs up the file as it is now, and a text Safe
                // could not confirm keeps that .bak on later saves
                wroteBackup = false
                if current.check != .confirmed {
                    isReadOnly = true
                    readOnlyBar.note = Self.unconfirmedNote
                    readOnlyBar.isHidden = false
                    textView.isEditable = false
                }
                markClean()
                updateTitle()
                updateStatus()
                return true
            } catch {
                DocumentAlerts.show(L("The file on disk could not be loaded"),
                                    DocumentAlerts.describe(error) + " " + L("Your version is still in the window."),
                                    on: window)
                return false
            }
        }
    }

    // MARK: closing

    private func makeSaveAlert() -> NSAlert {
        let alert = NSAlert()
        alert.messageText = L("Do you want to save the changes to %@?", opened.originalName)
        alert.informativeText = L("Your changes are lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))
        let dontSave = alert.addButton(withTitle: L("Don't Save"))
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        alert.addButton(withTitle: L("Cancel"))
        return alert
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isLocked {
            // the password first, so that nobody else can discard the changes
            DispatchQueue.main.async { [weak self] in
                if self?.unlock() == true {
                    self?.window?.performClose(nil)
                }
            }
            return false
        }
        guard dirty else { return true }
        DocumentAlerts.run(makeSaveAlert(), on: window) { [weak self] response in
            guard let self = self, !self.isClosed, !self.isLocked else { return }
            switch response {
            case .alertFirstButtonReturn:
                if self.save() {
                    self.window?.close()
                }
            case .alertSecondButtonReturn:
                self.markClean()
                self.window?.close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        DocumentAlerts.endSheets(of: window)
        // drop the text, the search string, the undo steps and the password
        searchBar.field.stringValue = ""
        fieldEditor.string = ""
        textView.string = ""
        editorUndo.removeAllActions()
        password?.wipe()
        password = nil
        Self.untrack(self)
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// Asks about unsaved changes in one editor, modally; false cancels.
    func confirmCloseModally() -> Bool {
        guard !isClosed else { return true }
        if isLocked && dirty && !unlock() {
            return false
        }
        guard dirty else { return true }
        if let window = window, window.isVisible || window.isMiniaturized {
            window.makeKeyAndOrderFront(nil)
        }
        var answer = NSApplication.ModalResponse.cancel
        let locks = LockController.shared.lockCount
        DocumentAlerts.run(makeSaveAlert(), on: nil) { answer = $0 }
        if isLocked || LockController.shared.lockCount != locks {
            // Safe locked while the question was open: the answer is not taken. The
            // question comes again, after the password (above), so that nobody else
            // can discard the changes
            return confirmCloseModally()
        }
        switch answer {
        case .alertFirstButtonReturn:
            return save()
        case .alertSecondButtonReturn:
            markClean()
            return true
        default:
            return false
        }
    }

    // MARK: locking (G4, 4.9)

    /// Closes the window, or covers the text if it has unsaved changes (G4).
    func lock() {
        guard !isClosed else { return }
        DocumentAlerts.endSheets(of: window)
        switch LockPolicy.editorResponse(hasUnsavedChanges: dirty) {
        case .close:
            window?.close()
        case .cover:
            cover()
        }
    }

    private func cover() {
        guard !isLocked else { return }
        isLocked = true
        searchBar.isHidden = true
        searchBar.matchLabel.stringValue = ""
        textView.isEditable = false
        textView.isSelectable = false
        scrollView.isHidden = true
        lockView.isHidden = false
        HelpButton.point(helpButton, at: .locking, toolTip: L("Open Safe Help about locking."))
        window?.makeFirstResponder(lockView.unlockButton)
        if window?.isMiniaturized == true {
            // the Dock's picture of the window would still show the text
            window?.miniwindowImage = NSApp.applicationIconImage
        }
        updateStatus()
    }

    private func uncover() {
        isLocked = false
        lockView.isHidden = true
        HelpButton.point(helpButton, at: .editing, toolTip: L("Open Safe Help about the editor."))
        scrollView.isHidden = false
        textView.isEditable = !isReadOnly
        textView.isSelectable = true
        window?.miniwindowImage = nil
        window?.makeFirstResponder(textView)
        updateStatus()
    }

    /// Asks for the file's password and shows the text again if it matches.
    @discardableResult
    func unlock() -> Bool {
        guard isLocked else { return true }
        guard let password = password,
              let typed = DocumentAlerts.askPassword(L("Unlock %@", opened.originalName),
                                                     L("Type the password of %@ to show the text again.", opened.originalName))
        else { return false }
        defer { typed.wipe() }
        let same = password.withUnsafeBytes { kept in
            typed.withUnsafeBytes { given in LockPolicy.sameBytes(kept, given) }
        }
        guard same else {
            DocumentAlerts.show(L("Wrong password"), L("The text stays hidden."), on: window)
            return false
        }
        uncover()
        return true
    }

    // MARK: all editors, for quitting

    private struct WeakEditor {
        weak var editor: EditorWindowController?
    }

    private static var live: [WeakEditor] = []
    private static var cascadePoint = NSPoint.zero

    private static func track(_ editor: EditorWindowController) {
        live.removeAll { $0.editor == nil }
        live.append(WeakEditor(editor: editor))
    }

    private static func untrack(_ editor: EditorWindowController) {
        live.removeAll { $0.editor == nil || $0.editor === editor }
    }

    /// The editors whose windows are open.
    static var openEditors: [EditorWindowController] {
        live.compactMap { $0.editor }.filter { !$0.isClosed }
    }

    /// For applicationShouldTerminate: asks about unsaved changes in every editor
    /// (a locked one needs its password first); false cancels the quit.
    static func reviewUnsavedChangesBeforeQuit() -> Bool {
        for editor in openEditors where !editor.confirmCloseModally() {
            return false
        }
        return true
    }
}

/// Writes the user's version next to a file that changed on disk (4.5): the current
/// format, a new file that must not exist, read back and compared like every save.
enum ConflictCopy {
    static func write(_ plaintext: Data, originalName: String, nextTo file: URL,
                      password: SecureBytes, date: Date = Date()) throws -> OpenedFile {
        // the core's own refusal after a failed self-test (G5), as in CryptFile.save
        if let reason = CryptFile.writeRefusal {
            throw CryptError.selfTestFailed(reason)
        }
        let folder = file.deletingLastPathComponent()
        let name = ConflictName.make(originalName: originalName, date: date) { candidate in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path)
        }
        let url = folder.appendingPathComponent(name)
        let ciphertext = try OpenSSLFormat.encrypt(plaintext, password: password)
        try writeNew(ciphertext, to: url)
        do {
            let (copy, check) = try CryptFile.open(at: url, password: password, allowLegacy: false)
            guard check == plaintext else {
                throw CryptError.checkFailed
            }
            return copy
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error is CryptError ? error : CryptError.checkFailed
        }
    }

    /// O_CREAT | O_EXCL, mode 0600, then F_FULLFSYNC.
    static func writeNew(_ data: Data, to url: URL) throws {
        let fd = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else {
            if errno == EEXIST {
                throw CryptError.alreadyExists(url.lastPathComponent)
            }
            throw CryptError.io(L("cannot create %@: %@", url.lastPathComponent, String(cString: strerror(errno))))
        }
        var failure: String?
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    failure = String(cString: strerror(errno))
                    return
                }
                offset += n
            }
        }
        if failure == nil && fcntl(fd, F_FULLFSYNC) != 0 && fsync(fd) != 0 {
            failure = String(cString: strerror(errno))
        }
        Darwin.close(fd)
        if let failure = failure {
            try? FileManager.default.removeItem(at: url)
            throw CryptError.io(L("cannot write %@: %@", url.lastPathComponent, failure))
        }
    }
}
