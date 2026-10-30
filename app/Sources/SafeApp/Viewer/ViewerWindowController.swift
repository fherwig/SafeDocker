import AppKit
import PDFKit
import SafeCore

// WP3. The interface is fixed by the building plan, section 3.1. The window is
// built in code; DocumentRouter calls showWindow(nil) after init. Nothing is
// written to disk: PDFDocument(data:) and NSImage(data:) work from memory.

/// Shows a decrypted PDF or image from memory, read only (R3, section 4.6).
final class ViewerWindowController: NSWindowController, Lockable, NSWindowDelegate,
                                    NSMenuItemValidation, PDFViewDelegate, ViewerCommands {
    /// The file as opened, or as saved again in the current format.
    private(set) var opened: OpenedFile
    private var data: Data
    /// Kept only for "Save in Current Format", for files opened from an old format.
    private var password: SecureBytes?

    private(set) var pdfView: SafePDFView?
    private(set) var imageView: NSImageView?
    /// The scroll view that zooms the picture.
    private(set) var imageScroll: NSScrollView?
    /// How the picture follows the window's size: shrunk to fit (at first),
    /// fitted (Zoom to Fit), or not at all once the user zoomed.
    enum ImageFit {
        case shrink, fit, none
    }
    private(set) var imageFit = ImageFit.shrink
    let helpButton = HelpButton.make(.viewing, toolTip: L("Open Safe Help about the viewer and exporting."))
    private let statusLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: L("Save in Current Format"), target: nil, action: nil)
    private let unlockPDFButton = NSButton(title: L("Unlock PDF…"), target: nil, action: nil)
    private(set) var isClosed = false

    /// Called when the window closed; DocumentRouter drops its reference.
    var onClose: (() -> Void)?

    /// Opens a viewer; the password is for "save in current format". A file whose
    /// password Safe could not confirm is never saved again: with a wrong password
    /// that would replace it with meaningless bytes.
    init(opened: OpenedFile, data: Data, password: SecureBytes) {
        self.opened = opened
        self.data = data
        self.password = opened.variant == .current || opened.check != .confirmed ? nil : password
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: true)
        window.isRestorable = false
        window.sharingType = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 360, height: 280)
        window.title = opened.originalName
        window.subtitle = DocumentAlerts.folderName(of: opened.url)
        super.init(window: window)
        window.delegate = self
        buildContent(in: window)
        window.center()
        window.layoutIfNeeded()
        fitImage()
        LockController.shared.register(self)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    // MARK: building the window

    private func buildContent(in window: NSWindow) {
        let content = makeContentView(window: window)
        content.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.identifier = ToolTipAudit.statusIdentifier

        saveButton.target = self
        saveButton.action = #selector(saveInCurrentFormat(_:))
        saveButton.bezelStyle = .rounded
        saveButton.isHidden = password == nil
        unlockPDFButton.target = self
        unlockPDFButton.action = #selector(unlockPDF(_:))
        unlockPDFButton.bezelStyle = .rounded
        unlockPDFButton.isHidden = pdfView?.document?.isLocked != true
        unlockPDFButton.toolTip = L("This PDF has a password of its own. Type it to show the pages.")
        let export = NSButton(title: L("Export…"), target: self, action: #selector(exportDecryptedCopy(_:)))
        export.bezelStyle = .rounded
        export.toolTip = L("Write an unencrypted copy of this file to a place you choose. Safe warns before it writes (⌥⌘E).")
        let close = NSButton(title: L("Close"), target: self, action: #selector(closeClicked(_:)))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\u{1b}"
        close.toolTip = L("Close the viewer. Safe forgets the content (Escape).")

        let bar = NSStackView()
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 8, right: 10)
        bar.addView(helpButton, in: .leading)
        bar.addView(statusLabel, in: .leading)
        for button in [unlockPDFButton, saveButton, export, close] {
            bar.addView(button, in: .trailing)
        }
        bar.translatesAutoresizingMaskIntoConstraints = false

        let column = NSStackView(views: [content, bar])
        column.orientation = .vertical
        column.spacing = 0
        column.alignment = .leading
        column.distribution = .fill
        for view in [content, bar] as [NSView] {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        // the content takes the room; a large image must not make the window grow
        content.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        content.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        content.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        bar.setHuggingPriority(.required, for: .vertical)
        window.contentView = column
        updateStatus()
    }

    /// A PDFView, an NSImageView, or a note if macOS cannot show the file.
    private func makeContentView(window: NSWindow) -> NSView {
        switch opened.kind {
        case .pdf:
            if let document = PDFDocument(data: data) {
                let view = SafePDFView()
                view.delegate = self
                view.acceptsDraggedFiles = false
                view.autoScales = true
                view.displayMode = .singlePageContinuous
                view.switchOffAnalysis()
                view.document = document
                // PDFKit turns data detection on again for a new document
                view.switchOffAnalysis()
                pdfView = view
                return view
            }
        case .image:
            if let image = NSImage(data: data) {
                let size = Self.pictureSize(image)
                let view = NSImageView(frame: NSRect(origin: .zero, size: size))
                view.image = image
                view.imageScaling = .scaleProportionallyUpOrDown
                view.isEditable = false
                view.allowsCutCopyPaste = false
                view.animates = true
                imageView = view
                // in a scroll view that zooms: View > Zoom In, Zoom Out, Actual Size, Zoom to Fit
                let scroll = NSScrollView()
                scroll.contentView = CenteringClipView()
                scroll.documentView = view
                scroll.hasVerticalScroller = true
                scroll.hasHorizontalScroller = true
                scroll.autohidesScrollers = true
                scroll.borderType = .noBorder
                scroll.backgroundColor = .windowBackgroundColor
                scroll.allowsMagnification = true
                scroll.minMagnification = 0.02
                scroll.maxMagnification = 32
                NotificationCenter.default.addObserver(self, selector: #selector(userMagnified(_:)),
                                                       name: NSScrollView.willStartLiveMagnifyNotification,
                                                       object: scroll)
                imageScroll = scroll
                window.setContentSize(Self.windowSize(for: size, on: NSScreen.main?.visibleFrame))
                return scroll
            }
        default:
            break
        }
        let note = NSTextField(wrappingLabelWithString:
            L("macOS cannot show %@ from memory. You can export the original with Export….", opened.originalName))
        note.alignment = .center
        note.isSelectable = false
        note.textColor = .secondaryLabelColor
        let holder = NSView()
        note.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(note)
        NSLayoutConstraint.activate([
            note.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        return holder
    }

    /// The picture's size in points; some pictures say zero, then that of their pixels.
    static func pictureSize(_ image: NSImage) -> NSSize {
        if image.size.width >= 1 && image.size.height >= 1 {
            return image.size
        }
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        }
        return NSSize(width: 100, height: 100)
    }

    /// The image at its size, but within the screen and not smaller than a small window.
    static func windowSize(for imageSize: NSSize, on screen: NSRect?) -> NSSize {
        let limit = screen.map { NSSize(width: $0.width * 0.9, height: $0.height * 0.85) }
            ?? NSSize(width: 1200, height: 900)
        let barHeight: CGFloat = 44
        return NSSize(width: min(max(imageSize.width, 360), limit.width),
                      height: min(max(imageSize.height + barHeight, 280), limit.height))
    }

    /// Short enough for a small window; the tooltip holds the whole line.
    private func updateStatus(savedAt: Date? = nil) {
        var line = L("Decrypted in memory only.")
        var tip = line
        let backup = EditorStatus.backupName(forEncryptedFileName: opened.url.lastPathComponent)
        if let savedAt = savedAt {
            line += " " + L("Saved in the current format %@.", EditorStatus.clock(savedAt))
            tip = line + " " + L("The previous version is kept as %@.", backup)
        } else if opened.check != .confirmed {
            line += " " + L("Safe could not confirm the password.")
            tip = line + " " + L("If this is what you expect, the password is right.")
        } else if opened.variant != .current {
            line += " " + L("Old format: %@.", DocumentAlerts.describe(opened.variant))
            tip = line + " " + L("""
                Save in Current Format writes the same content again in the current format and keeps \
                the previous version as %@.
                """, backup)
        }
        statusLabel.stringValue = line
        statusLabel.toolTip = tip
        saveButton.toolTip = password == nil
            ? L("Encrypt the same content again in today's format, with the same password, and keep the old file as %@.",
                backup)
            : tip
    }

    /// The status line as shown; for the checks.
    var statusText: String {
        statusLabel.stringValue
    }

    /// True while "Save in Current Format" is offered; for the checks.
    var offersSaveInCurrentFormat: Bool {
        !saveButton.isHidden
    }

    // MARK: commands

    @objc func exportDecryptedCopy(_ sender: Any?) {
        guard !isClosed else { return }
        ExportController.export(data, originalName: opened.originalName, from: opened.url, window: window)
    }

    @objc private func closeClicked(_ sender: Any?) {
        window?.close()
    }

    /// Encrypts the same bytes again in the current format (G5, 4.4).
    @objc func saveInCurrentFormat(_ sender: Any?) {
        guard !isClosed, let password = password else { return }
        if let refusal = DocumentAlerts.saveRefusal() {
            DocumentAlerts.show(L("%@ was not saved", opened.originalName), refusal, on: window)
            return
        }
        do {
            opened = try CryptFile.save(data, over: opened, password: password)
            password.wipe()
            self.password = nil
            saveButton.isHidden = true
            updateStatus(savedAt: Date())
        } catch CryptError.conflict {
            DocumentAlerts.show(L("%@ changed on disk", opened.url.lastPathComponent),
                                L("Another program or another Mac changed the file after it was opened. Close this window and open the file again."),
                                on: window)
        } catch {
            DocumentAlerts.show(L("%@ was not saved", opened.originalName), DocumentAlerts.describe(error), on: window)
        }
    }

    /// A PDF with its own password inside the encrypted file.
    @objc private func unlockPDF(_ sender: Any?) {
        guard let document = pdfView?.document, document.isLocked,
              let typed = DocumentAlerts.askPassword(L("Unlock %@", opened.originalName),
                                                     L("This PDF has a password of its own. Type it to show the pages."))
        else { return }
        defer { typed.wipe() }
        let text = typed.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
        if document.unlock(withPassword: text) {
            unlockPDFButton.isHidden = true
            pdfView?.layoutDocumentView()
        } else {
            DocumentAlerts.show(L("Wrong password"), L("The PDF stays locked."), on: window)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard !isClosed else { return false }
        switch menuItem.action {
        case #selector(viewerZoomIn(_:)):
            return pdfView.map(\.canZoomIn) ?? imageScroll.map { $0.magnification < $0.maxMagnification } ?? false
        case #selector(viewerZoomOut(_:)):
            return pdfView.map(\.canZoomOut) ?? imageScroll.map { $0.magnification > $0.minMagnification } ?? false
        case #selector(viewerActualSize(_:)), #selector(viewerZoomToFit(_:)):
            return pdfView != nil || imageScroll != nil
        case #selector(viewerNextPage(_:)):
            return pdfView?.canGoToNextPage ?? false
        case #selector(viewerPreviousPage(_:)):
            return pdfView?.canGoToPreviousPage ?? false
        default:
            return true
        }
    }

    // MARK: View menu

    /// One step of Zoom In or Zoom Out for a picture.
    static let zoomStep: CGFloat = 1.25

    @objc func viewerZoomIn(_ sender: Any?) {
        if let pdf = pdfView {
            pdf.zoomIn(nil)
        } else if let scroll = imageScroll {
            imageFit = .none
            scroll.magnification = min(scroll.magnification * Self.zoomStep, scroll.maxMagnification)
        }
    }

    @objc func viewerZoomOut(_ sender: Any?) {
        if let pdf = pdfView {
            pdf.zoomOut(nil)
        } else if let scroll = imageScroll {
            imageFit = .none
            scroll.magnification = max(scroll.magnification / Self.zoomStep, scroll.minMagnification)
        }
    }

    @objc func viewerActualSize(_ sender: Any?) {
        if let pdf = pdfView {
            pdf.autoScales = false
            pdf.scaleFactor = 1
        } else if let scroll = imageScroll {
            imageFit = .none
            scroll.magnification = 1
        }
    }

    @objc func viewerZoomToFit(_ sender: Any?) {
        if let pdf = pdfView {
            pdf.autoScales = true
        } else {
            imageFit = .fit
            fitImage()
        }
    }

    @objc func viewerNextPage(_ sender: Any?) {
        pdfView?.goToNextPage(nil)
    }

    @objc func viewerPreviousPage(_ sender: Any?) {
        pdfView?.goToPreviousPage(nil)
    }

    /// Fits the picture into the window, shrinking it only at first.
    private func fitImage() {
        guard let scroll = imageScroll, let view = imageView, imageFit != .none else { return }
        let size = view.frame.size, room = scroll.contentSize
        guard size.width > 0, size.height > 0, room.width > 0, room.height > 0 else { return }
        var scale = min(room.width / size.width, room.height / size.height)
        if imageFit == .shrink {
            scale = min(scale, 1)
        }
        scroll.magnification = max(scroll.minMagnification, min(scale, scroll.maxMagnification))
    }

    func windowDidResize(_ notification: Notification) {
        fitImage()
    }

    /// A pinch on the trackpad: the picture no longer follows the window.
    @objc private func userMagnified(_ notification: Notification) {
        imageFit = .none
    }

    // MARK: PDF links and actions: nothing leaves the app

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {}

    func pdfViewPerformPrint(_ sender: PDFView) {}

    func pdfViewPerformFind(_ sender: PDFView) {}

    // MARK: closing and locking

    func windowWillClose(_ notification: Notification) {
        guard !isClosed else { return }
        isClosed = true
        DocumentAlerts.endSheets(of: window)
        pdfView?.document = nil
        imageView?.image = nil
        data = Data()
        password?.wipe()
        password = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    /// Closes the window (G4).
    func lock() {
        guard !isClosed else { return }
        DocumentAlerts.endSheets(of: window)
        window?.close()
    }
}

/// A PDFView whose Copy goes through ClipboardGuard, without Services, Look Up,
/// the find bar or a context menu beyond Copy and zoom.
final class SafePDFView: PDFView {
    /// Switches off what PDFKit does with the decrypted pages besides drawing
    /// them, as the editor does (plan 4.5): data detectors, which scan the text
    /// for addresses, dates and telephone numbers, and document analysis, which
    /// runs Live Text (Vision) over pages that are only images (finding of review
    /// round 4). Both through key-value coding: enableDataDetectors is deprecated
    /// and documentAnalysisEnabled is not public, so each is set only if this
    /// macOS has it.
    func switchOffAnalysis() {
        for key in Self.analysisKeys where responds(to: NSSelectorFromString("set" + key.prefix(1).uppercased()
                                                                             + key.dropFirst() + ":")) {
            setValue(false, forKey: key)
        }
    }

    /// The keys of switchOffAnalysis.
    static let analysisKeys = ["enableDataDetectors", "documentAnalysisEnabled"]

    /// The value of such a key, nil if this macOS does not have it; for the checks.
    func analysisSetting(_ key: String) -> Bool? {
        guard responds(to: NSSelectorFromString(key)) || responds(to: NSSelectorFromString(
            "is" + key.prefix(1).uppercased() + key.dropFirst())) else { return nil }
        return value(forKey: key) as? Bool
    }

    override func copy(_ sender: Any?) {
        guard let text = currentSelection?.string, !text.isEmpty else {
            DocumentAlerts.beep()
            return
        }
        ClipboardGuard.copy(text)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu(title: "")
        menu.allowsContextMenuPlugIns = false
        if #available(macOS 15.2, *) {
            menu.automaticallyInsertsWritingToolsItems = false
        }
        menu.addItem(withTitle: L("Copy"), action: #selector(copy(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Zoom In"), action: #selector(zoomIn(_:)), keyEquivalent: "")
        menu.addItem(withTitle: L("Zoom Out"), action: #selector(zoomOut(_:)), keyEquivalent: "")
        return menu
    }

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?,
                                 returnType: NSPasteboard.PasteboardType?) -> Any? {
        nil
    }

    /// The Services way of handing out the selection (NSServicesMenuRequestor),
    /// which PDFView implements and a drag of the selection may use: it writes
    /// nothing, so that text leaves the viewer only through Copy and its
    /// clipboard rules. Whether PDFKit starts such a drag at all is left to the
    /// owner's checklist (acceptance.md, section 5).
    @objc(writeSelectionToPasteboard:types:)
    func writeSelection(to pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        false
    }

    override func quickLook(with event: NSEvent) {}

    override func quickLookPreviewItems(_ sender: Any?) {}

    override func performTextFinderAction(_ sender: Any?) {}

    override func showDefinition(for attrString: NSAttributedString?, at textBaselineOrigin: NSPoint) {}

    override func showDefinition(for attrString: NSAttributedString?, range targetRange: NSRange,
                                 options: [NSView.DefinitionOptionKey: Any]? = nil,
                                 baselineOriginProvider originProvider: ((NSRange) -> NSPoint)? = nil) {}
}

/// Keeps a picture smaller than the window in the middle of it.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if rect.width > document.frame.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if rect.height > document.frame.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}
