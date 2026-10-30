import AppKit
import SafeCore

// WP3. The editor's text view (building plan 4.5). Everything that could send
// the text elsewhere is off: spelling and grammar (spell server), completion,
// substitutions, data and link detection, inline predictions, Writing Tools,
// Services, Look Up, Quick Look, sharing, the find bar (it writes the find
// pasteboard), dragging the selection out, and the Emacs-style kill ring: Ctrl-K,
// the other "delete to" commands and delete(_:) itself (Edit > Delete, and Cut,
// which deletes with it) put what they delete into a buffer that AppKit keeps for
// the whole process and that Ctrl-Y pastes into any other text field, after a
// lock too. Here they all delete with deleteBackward(_:), which does not (tested
// on macOS 26), and Ctrl-Y does nothing.
// Copy and Cut go through ClipboardGuard. The same class serves as field editor
// of the search field.

/// Receives what the text view cannot do itself: the search commands.
protocol SafeTextViewOwner: AnyObject {
    func perform(_ command: EditorCommand)
}

/// The editor's text view, with spelling, completion, Services, Look Up and the rest off (section 4.5).
final class SafeTextView: NSTextView {
    /// The editor window's controller, for Find, Find Next and Find Previous.
    weak var owner: SafeTextViewOwner?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        switchOff()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        switchOff()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// A text view for the editor: plain text, monospaced system font 13 pt, undo in memory.
    static func makeEditor() -> SafeTextView {
        let view = SafeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        view.allowsUndo = true
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textContainerInset = NSSize(width: 4, height: 6)
        return view
    }

    /// A field editor for the search field, with the same switches off.
    static func makeFieldEditor() -> SafeTextView {
        let view = SafeTextView(frame: .zero)
        view.isFieldEditor = true
        view.allowsUndo = false
        return view
    }

    /// Every switch-off of section 4.5; the newer ones only where macOS has them.
    func switchOff() {
        isRichText = false
        importsGraphics = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        usesInspectorBar = false
        allowsDocumentBackgroundColorChange = false
        usesFindBar = false
        usesFindPanel = false
        isIncrementalSearchingEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        smartInsertDeleteEnabled = false
        enabledTextCheckingTypes = 0
        allowsCharacterPickerTouchBarItem = false
        if #available(macOS 14.0, *) {
            inlinePredictionType = .no
        }
        if #available(macOS 15.0, *) {
            writingToolsBehavior = NSWritingToolsBehavior.none
            mathExpressionCompletionType = .no
        }
    }

    // MARK: no Services, Look Up, Quick Look, sharing, completion, speech

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        nil
    }

    override func quickLook(with event: NSEvent) {}

    override func quickLookPreviewItems(_ sender: Any?) {}

    override func toggleQuickLookPreviewPanel(_ sender: Any?) {}

    override func showDefinition(for attrString: NSAttributedString?, at textBaselineOrigin: NSPoint) {}

    override func showDefinition(for attrString: NSAttributedString?, range targetRange: NSRange,
                                 options: [NSView.DefinitionOptionKey: Any]? = nil,
                                 baselineOriginProvider originProvider: ((NSRange) -> NSPoint)? = nil) {}

    override func orderFrontSharingServicePicker(_ sender: Any?) {}

    override func complete(_ sender: Any?) {}

    override func startSpeaking(_ sender: Any?) {}

    override func checkSpelling(_ sender: Any?) {}

    override func showGuessPanel(_ sender: Any?) {}

    override func checkTextInSelection(_ sender: Any?) {}

    override func checkTextInDocument(_ sender: Any?) {}

    override func orderFrontSubstitutionsPanel(_ sender: Any?) {}

    override func toggleContinuousSpellChecking(_ sender: Any?) {}

    override func toggleGrammarChecking(_ sender: Any?) {}

    override func toggleAutomaticSpellingCorrection(_ sender: Any?) {}

    override func toggleAutomaticTextCompletion(_ sender: Any?) {}

    override func toggleAutomaticQuoteSubstitution(_ sender: Any?) {}

    override func toggleAutomaticDashSubstitution(_ sender: Any?) {}

    override func toggleAutomaticTextReplacement(_ sender: Any?) {}

    override func toggleAutomaticDataDetection(_ sender: Any?) {}

    override func toggleAutomaticLinkDetection(_ sender: Any?) {}

    override func toggleSmartInsertDelete(_ sender: Any?) {}

    override func makeTouchBar() -> NSTouchBar? {
        nil
    }

    // MARK: no dragging out

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
        false
    }

    override func draggingSession(_ session: NSDraggingSession,
                                  sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        []
    }

    // MARK: the context menu: Cut, Copy, Paste, Select All

    override func menu(for event: NSEvent) -> NSMenu? {
        Self.minimalMenu()
    }

    override class var defaultMenu: NSMenu? {
        minimalMenu()
    }

    /// Cut, Copy, Paste, Select All, and nothing that AppKit may add on its own.
    static func minimalMenu() -> NSMenu {
        let menu = NSMenu(title: "")
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }
        menu.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "")
        return menu
    }

    // MARK: Copy and Cut through ClipboardGuard

    /// The selected text; several ranges are joined by line breaks.
    var selectedText: String {
        TextSelection.joined(string, ranges: selectedRanges.map { $0.rangeValue })
    }

    override func copy(_ sender: Any?) {
        let text = selectedText
        guard !text.isEmpty else {
            DocumentAlerts.beep()
            return
        }
        ClipboardGuard.copy(text)
    }

    override func cut(_ sender: Any?) {
        let text = selectedText
        guard isEditable, !text.isEmpty else {
            DocumentAlerts.beep()
            return
        }
        // not cut if the user declined to copy (macOS's clipboard history)
        guard ClipboardGuard.copy(text) else { return }
        deleteSelectionWithoutKilling()
        undoManager?.setActionName(L("Cut"))
    }

    // MARK: no kill ring: delete without keeping what was deleted

    /// Edit > Delete.
    override func delete(_ sender: Any?) {
        guard isEditable, hasSelection else {
            DocumentAlerts.beep()
            return
        }
        deleteSelectionWithoutKilling()
    }

    override func deleteToEndOfParagraph(_ sender: Any?) {
        deleteWithoutKilling { $0.moveToEndOfParagraphAndModifySelection(nil) } ifEmpty: {
            $0.moveForwardAndModifySelection(nil)       // at the end, the line break, as Ctrl-K does
        }
    }

    override func deleteToEndOfLine(_ sender: Any?) {
        deleteWithoutKilling { $0.moveToEndOfLineAndModifySelection(nil) } ifEmpty: {
            $0.moveForwardAndModifySelection(nil)
        }
    }

    override func deleteToBeginningOfLine(_ sender: Any?) {
        deleteWithoutKilling { $0.moveToBeginningOfLineAndModifySelection(nil) } ifEmpty: {
            $0.moveBackwardAndModifySelection(nil)
        }
    }

    override func deleteToBeginningOfParagraph(_ sender: Any?) {
        deleteWithoutKilling { $0.moveToBeginningOfParagraphAndModifySelection(nil) } ifEmpty: {
            $0.moveBackwardAndModifySelection(nil)
        }
    }

    override func deleteToMark(_ sender: Any?) {
        deleteWithoutKilling { $0.selectToMark(nil) } ifEmpty: { _ in }
    }

    override func yank(_ sender: Any?) {
        DocumentAlerts.beep()
    }

    /// Not in the SDK's headers, but an action of NSTextView all the same.
    @objc(yankAndSelect:) func yankAndSelect(_ sender: Any?) {
        DocumentAlerts.beep()
    }

    /// Extends an empty selection with `extend` (and `ifEmpty` if it is still
    /// empty), then deletes the selection without the kill ring.
    private func deleteWithoutKilling(_ extend: (SafeTextView) -> Void, ifEmpty: (SafeTextView) -> Void) {
        guard isEditable else {
            DocumentAlerts.beep()
            return
        }
        if !hasSelection {
            extend(self)
            if !hasSelection {
                ifEmpty(self)
            }
        }
        guard hasSelection else {
            DocumentAlerts.beep()
            return
        }
        deleteSelectionWithoutKilling()
    }

    /// True if some text is selected.
    private var hasSelection: Bool {
        selectedRanges.contains { $0.rangeValue.length > 0 }
    }

    /// Deletes the selected text with deleteBackward(_:), which keeps undo and asks
    /// the delegate as typing does, but, unlike delete(_:), puts nothing into the
    /// kill ring. Only with a selection: without one it would delete a character.
    private func deleteSelectionWithoutKilling() {
        guard hasSelection else { return }
        deleteBackward(nil)
    }

    // MARK: search through the editor's own search field, never NSTextFinder

    override func performTextFinderAction(_ sender: Any?) {
        forwardFind(sender)
    }

    override func performFindPanelAction(_ sender: Any?) {
        forwardFind(sender)
    }

    /// Tags 1, 2, 3 are the same in NSTextFinder.Action and NSFindPanelAction.
    private func findCommand(for sender: Any?) -> EditorCommand? {
        let tag = (sender as? NSValidatedUserInterfaceItem)?.tag ?? 0
        switch NSTextFinder.Action(rawValue: tag) {
        case .showFindInterface?: return .find
        case .nextMatch?: return .findNext
        case .previousMatch?: return .findPrevious
        default: return nil
        }
    }

    private func forwardFind(_ sender: Any?) {
        if let command = findCommand(for: sender), let owner = owner {
            owner.perform(command)
        } else {
            DocumentAlerts.beep()
        }
    }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:))
            || item.action == #selector(performFindPanelAction(_:)) {
            return owner != nil && findCommand(for: item) != nil
        }
        return super.validateUserInterfaceItem(item)
    }
}
