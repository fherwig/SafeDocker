# Safe.app: building plan

This plan turns `docs/requirements.md` (G1 to G5, R1 to R4) into a native Mac app,
Safe.app. It is written so that several developers, human or AI, can build parts in
parallel: the module interfaces are fixed here, each work package owns its files, and
every package ends with tests that prove it works.

Background: a design study of 2026-10-25 compared five designs (wrapper around the
Docker tool, native front end with Docker as backend, editor in the container shown over
VNC, native app without Docker, security first). The native app without Docker won; its
reasoning and the reviewers' findings are summarised in `design-decisions.md` next to
this file.

## 1. Decisions

- **Native AppKit app, Swift, no Docker at run time.** Docker stays in the repository for
  the terminal tool and as the source of reference test files (G5).
- **No App Sandbox.** The App Sandbox lets an app write only the files the user picked,
  so it cannot write `NAME.crypt_new`, `NAME.crypt.bak` or `NAME.crypt` next to a file.
  Instead the app denies itself the network at start with
  `sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, &err)`. Tested on macOS 26.3: after
  the call, `connect()` fails with "Operation not permitted", while file access and
  `hdiutil attach/detach` from a child process still work. The API is deprecated but
  works; `--self-test` checks it on every machine.
- **Hardened runtime, ad hoc signature** for now. Developer ID signing and notarization
  come later (section 10).
- **Built with the Command Line Tools only** (no Xcode): Swift 6.2, macOS SDK 26.2,
  SwiftPM. XCTest and Swift Testing do not run without Xcode, so tests are an executable
  target, `SafeTests`, with a small assertion harness. The universal binary is built per
  architecture (`--triple arm64-apple-macosx13.0` and `x86_64-apple-macosx13.0`) and
  joined with `lipo`.
- **Disk images through `hdiutil`** with passwords on stdin. Tested on macOS 26.3 with a
  standard user: `create -srcfolder ... -format UDSB -fs APFS -encryption AES-256
  -stdinpass`, `create -size ... -type SPARSEBUNDLE ...`, `attach -stdinpass -nobrowse
  -mountpoint DIR`, `detach`, `chpass -oldstdinpass -newstdinpass` (the two passwords on
  stdin separated by NUL bytes).
- **Minimum macOS 13.** Newer text features are switched off behind `#available` checks.
- **Bundle identifier** `io.github.fherwig.safedocker`, app name `Safe`, file type
  `io.github.fherwig.safedocker.crypt` for the ending `.crypt`.

## 2. Repository layout

```
app/
  Package.swift
  VERSION                       one line, for example 0.1.0
  Sources/
    CSandbox/                   C shim: include/CSandbox.h declares safe_deny_network()
    SafeCore/                   no AppKit; everything testable lives here
      Crypto/                   OpenSSLFormat, Legacy, Plausibility, SecureBytes
      Files/                    FileKind, CryptFile (open, save, encrypt, export)
      Volumes/                  DiskImage (hdiutil), VolumeStore, FolderVerifier, SyncCheck
      SelfTest.swift            known-answer tests, network probe; used by app and tests
      NoNetwork.swift           calls safe_deny_network()
    SafeApp/                    the app (AppKit)
      main.swift, AppDelegate.swift, CommandLineMode.swift
      Finder/                   ServicesProvider, DocumentRouter
      Prompts/                  PasswordPrompt (once or twice), alerts
      Editor/                   SafeTextView, EditorWindowController, ClipboardGuard
      Viewer/                   ViewerWindowController, ExportController
      Volumes/                  VolumesWindowController and its sheets
      Lock/                     LockController (G4)
    SafeTests/                  test runner (executable) and its tests
  Resources/
    Info.plist                  document type, exported UTI, NSServices
    Safe.entitlements           empty dict (hardened runtime, no sandbox)
  Fixtures/                     reference encrypted files, named *.enc (see 5.4)
  scripts/
    build-app.sh                build, assemble, sign, zip
    make-fixtures.sh            regenerate the reference files
    agent-check.sh              read-only requirement checks for the install agent
    time-capsule.sh             save the Docker image as an archive file (G5)
tools/
  safe-decrypt.py               reference decryptor, Python standard library only (G5)
docs/
  format.md                     the file format, byte by byte (G5)
  safe-app/                     this plan, design decisions, architecture
INSTALL-AGENT.md                instructions for the install agent (G2)
```

Build products never go into the repository folder (it is synced): always build with
`--scratch-path "$HOME/Library/Caches/SafeDocker-build/<name>"`, and delete that folder
once the build's result is checked (section 11). `app/dist/` holds the assembled app and
zip and is ignored by git.

## 3. Module interfaces (the contract)

These signatures are fixed. A package may add internal helpers, but changes to public
signatures go through the integrator.

```swift
// SafeCore/Crypto/SecureBytes.swift
/// A password or key in locked memory, wiped on deinit.
public final class SecureBytes {
    public init(_ bytes: [UInt8])
    public convenience init(string: String)        // the exact UTF-8 bytes
    public var count: Int { get }
    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
    public func wipe()
}

// SafeCore/Crypto/OpenSSLFormat.swift
public enum CryptVariant: String, Codable, CaseIterable {
    case current          // Salted__ + PBKDF2-HMAC-SHA512 100000 + AES-256-CBC (G3)
    case legacyAESMD5     // EVP_BytesToKey(MD5), AES-256-CBC, salted or not
    case legacyAESSHA256  // EVP_BytesToKey(SHA-256), AES-256-CBC, salted or not
    case legacyRC4MD5     // EVP_BytesToKey(MD5), RC4 128-bit, salted or not
    case legacyRC4SHA256
}
public enum CryptError: Error, Equatable {
    case notEncrypted, wrongPassword, corrupt, conflict, checkFailed,
         alreadyExists(String), io(String), selfTestFailed(String)
}
public enum OpenSSLFormat {
    /// Encrypts in the current format with a fresh random 8-byte salt.
    public static func encrypt(_ plaintext: Data, password: SecureBytes) throws -> Data
    /// Decrypts the current format only, with a strict PKCS#7 check.
    public static func decryptCurrent(_ ciphertext: Data, password: SecureBytes) throws -> Data
    /// Decrypts one legacy variant (never used for writing).
    public static func decryptLegacy(_ ciphertext: Data, password: SecureBytes,
                                     variant: CryptVariant) throws -> Data
}

// SafeCore/Crypto/Plausibility.swift
public enum Plausibility {
    /// Is this decrypted content believable for a file originally named `originalName`?
    /// Text endings need valid UTF-8 (no NUL); known binary types need their magic bytes.
    public static func check(_ plaintext: Data, originalName: String) -> Verdict
    public enum Verdict { case plausible, implausible, unknownType }
}

// SafeCore/Files/FileKind.swift
public enum FileKind: Equatable {
    case text, pdf, image, other
    public static func classify(originalName: String, plaintext: Data) -> FileKind
}

// SafeCore/Files/CryptFile.swift
public struct OpenedFile {
    public let url: URL                 // the .crypt file
    public let originalName: String     // file name without ".crypt"
    public let kind: FileKind
    public let variant: CryptVariant
    public let ciphertextSHA256: Data   // for the conflict check at save
}
public enum CryptFile {
    /// R1: NAME -> NAME.crypt, read back and compare, then delete NAME.
    public static func encryptFile(at url: URL, password: SecureBytes) throws -> URL
    /// R2, R3: read and decrypt; tries the current format, then legacy variants (G5).
    public static func open(at url: URL, password: SecureBytes,
                            allowLegacy: Bool) throws -> (OpenedFile, Data)
    /// R2: save in the current format (sequence in 5.3). Throws .conflict if the file
    /// changed on disk since it was opened.
    public static func save(_ plaintext: Data, over opened: OpenedFile,
                            password: SecureBytes) throws -> OpenedFile
    /// R3: write the decrypted original to a place the user chose.
    public static func export(_ plaintext: Data, to url: URL) throws
}

// SafeCore/Volumes/DiskImage.swift
public struct AttachedImage { public let imagePath: URL; public let mountPoint: URL? }
public enum DiskImage {
    public static func createEmpty(at image: URL, maxSizeMB: Int, volumeName: String,
                                   password: SecureBytes) throws
    public static func createFromFolder(_ folder: URL, at image: URL, volumeName: String,
                                        password: SecureBytes) throws
    public static func attach(_ image: URL, password: SecureBytes, readOnly: Bool,
                              mountPoint: URL?, hidden: Bool) throws -> URL
    public static func detach(_ mountPoint: URL, force: Bool) throws
    public static func changePassword(_ image: URL, old: SecureBytes, new: SecureBytes) throws
    public static func isEncrypted(_ image: URL) throws -> Bool
    public static func attached() throws -> [AttachedImage]       // hdiutil info -plist
}

// SafeCore/Volumes/FolderVerifier.swift
public enum FolderVerifier {
    /// Same relative paths, sizes and SHA-256 for every regular file (ignoring .DS_Store,
    /// .fseventsd, .Spotlight-V100, .Trashes and other volume metadata).
    public static func sameContents(_ a: URL, _ b: URL) throws -> Bool
}

// SafeCore/Volumes/VolumeStore.swift
public struct VolumeRecord: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var path: String           // stored with a leading "~/" when under the home folder
    public var syncApp: String?       // process name to check before opening, or nil
}
public final class VolumeStore {
    public init(file: URL = VolumeStore.defaultFile)   // ~/Library/Application Support/SafeDocker/volumes.json
    public static var defaultFile: URL { get }
    public private(set) var volumes: [VolumeRecord]
    public func add(_ v: VolumeRecord) throws
    public func update(_ v: VolumeRecord) throws
    public func remove(id: UUID) throws               // forgets it; never deletes the image
}

// SafeCore/Volumes/SyncCheck.swift
public enum SyncCheck { public static func isRunning(processName: String) -> Bool }

// SafeCore/SelfTest.swift
public struct SelfTestReport: Codable {
    public var knownAnswers: Bool, wrongPasswordRejected: Bool, networkBlocked: Bool
    public var failures: [String]
    public var ok: Bool { get }
}
public enum SelfTest {
    /// Runs the known-answer tests over fixtures in `fixturesDirectory` (the app passes its
    /// Resources/Fixtures), plus a wrong-password test, plus the network probe.
    public static func run(fixturesDirectory: URL) -> SelfTestReport
}

// SafeCore/NoNetwork.swift
public enum NoNetwork {
    public static func enforce() throws                 // calls safe_deny_network()
    public static func probeBlocked() -> Bool           // true if connect() fails with EPERM
}
```

### 3.1 Interfaces inside the app

Also fixed, so that WP3 and WP4 can be built in parallel. WP0 provides them as compiling
stubs.

```swift
// SafeApp/Lock/LockController.swift (WP3)
protocol Lockable: AnyObject { func lock() }
final class LockController {
    static let shared: LockController
    func start()                                  // called once by AppDelegate
    func register(_ item: Lockable)               // held weakly
    func addLockAction(_ action: @escaping () -> Void)   // WP4 adds "close volumes"
    func lockNow()
}

// SafeApp/Editor/EditorWindowController.swift (WP3)
final class EditorWindowController: NSWindowController, Lockable {
    init(opened: OpenedFile, text: String, password: SecureBytes)
    var hasUnsavedChanges: Bool { get }
    var onClose: (() -> Void)?                    // DocumentRouter drops its reference
}

// SafeApp/Viewer/ViewerWindowController.swift (WP3)
final class ViewerWindowController: NSWindowController, Lockable {
    init(opened: OpenedFile, data: Data, password: SecureBytes)   // password for "save in current format"
    var onClose: (() -> Void)?
}

// SafeApp/Viewer/ExportController.swift (WP3)
enum ExportController {
    /// Save panel next to the encrypted file, the "not encrypted" warning, then
    /// CryptFile.export.
    static func export(_ data: Data, originalName: String, from encryptedFile: URL,
                       window: NSWindow?)
}

// SafeApp/Editor/ClipboardGuard.swift (WP3)
enum ClipboardGuard {
    static func copy(_ string: String)
    static func clearIfOurs()
}

// SafeApp/Prompts/PasswordPrompt.swift (WP4)
enum PasswordPrompt {
    /// Modal; returns nil on Cancel. `fileName` is shown in the message.
    static func askOnce(title: String, message: String) -> SecureBytes?
    /// Two fields that must match and must not be empty.
    static func askTwice(title: String, message: String) -> SecureBytes?
}

// SafeApp/Finder/DocumentRouter.swift (WP4)
final class DocumentRouter {
    static let shared: DocumentRouter
    func open(_ urls: [URL])                      // double-click, Open with Safe
    func encrypt(_ urls: [URL])                   // Encrypt with Safe
    func export(_ urls: [URL])                    // Export with Safe
}
```

## 4. Behaviour of the app

### 4.1 Start

1. `NoNetwork.enforce()` first. If it fails, show an alert and quit.
2. Command-line modes, no window: `--version`, `--self-test` (JSON report, exit 0 if ok),
   `--check` (JSON: version, fixtures found, network blocked, list of volumes from the
   store and whether each image exists, attached images). These are for the install
   agent (G2).
3. Otherwise run `SelfTest` over the bundled fixtures, in the background. If it fails,
   every encrypt and save is refused with a clear message (G5); opening still works.
4. Without documents to open, show the Volumes window.

### 4.2 Finder integration (R1, R2, R3)

- `Info.plist` exports the UTI `io.github.fherwig.safedocker.crypt` (conforms to
  `public.data`, extension `crypt`) and declares it as a document type with the app as
  owner (`LSHandlerRank` Owner, role Editor), so a double-click opens `.crypt` files.
- `NSServices`, so the Finder's right-click menu offers (under Quick Actions or
  Services):
  - **Encrypt with Safe**: for any file (not folders, not `.crypt`).
  - **Open with Safe**, **Export with Safe**: for `.crypt` files.
- `ServicesProvider` receives the file URLs from the pasteboard; `DocumentRouter` decides
  what to do with each file.

### 4.3 Encrypt (R1)

Ask the password twice (`PasswordPrompt`, both fields secure, must match, not empty).
For several selected files, one password for all; each file goes through
`CryptFile.encryptFile` on its own; a summary lists failures. Refuse if `NAME.crypt`
exists already.

### 4.4 Open (R2, R3)

Ask the password once. `CryptFile.open(allowLegacy: true)`. Wrong password: say so and
ask again; garbage is never shown as if it were the file, and the right password is never
refused. A result whose padding is right but whose content does not look like its name (a
text in ISO Latin-1, for example, from the current format or an older one, 5.2), or a
current-format result whose type cannot be checked and which removed one byte of padding
(5.1), is not called a wrong password: say that the password could not be confirmed because
the content does not look like such a file, and let the user choose: for text, open it read
only (UTF-8, UTF-16 after a byte order mark, else ISO Latin-1) until they allow editing; for
a PDF or picture, view it; otherwise export it; or type another password. For a text name
whose result is neither UTF-8 nor text in another encoding (`Plausibility.looksLikeText`),
and for a name whose type always starts with the same bytes (PDF, ZIP-based documents, the
Office compound file, archives, media, RTF, SQLite: `Plausibility.needsMagicBytes`; not
pictures, which may be in a format Safe does not know) whose result matches no known type,
both nearly always a wrong password, say that the password is probably not right and offer
Type It Again, Export Anyway and Cancel. A current-format file whose padding check fails, or
whose length is not whole blocks, while the start of what the key gives looks like the start of
such a file (`CryptError.damaged`: cut short, at a block boundary as interrupted copies mostly
are, or inside a block) is not called a wrong password: say that the password seems right but
the end is missing, name `NAME.crypt.bak` if there is one, and offer Export Readable Part
(every whole block but the last), Type Another Password and Cancel. When the same password is
refused twice in a row for a text name or a type that cannot be checked (compared by a keyed
digest kept only while the password is asked), the file may be an old RC4 file whose content
Safe cannot check, or, if it is salted, a file in the current format cut short whose start Safe
cannot recognise: offer Export as an Old RC4 File (RC4 with an MD5 key as crypt.sh before 1.4
wrote, or with a SHA-256 key) and for a salted file Export Readable Part, never a window or a
save; with the warning that Safe could not check the result. Otherwise the repeat names the
`.bak`. For such a file a result that an AES variant gave by chance with valid padding (about 1
in 85 passwords, the right one of an RC4 file included) must not hide those readings: the
questions about a result Safe could not confirm offer Other Readings, which exports the file
read as an old RC4 file or as a damaged one. If a legacy variant opened it, say which one
and offer to save it in the current format (for text, the next save does that; for other
files, "Save in current format" re-encrypts the same bytes); for a result the user
accepted without a check (5.2) a text opens read only until Allow Editing, like one
whose password could not be confirmed, and other files are saved only after a second question
that names the risk (the file as it was becomes `NAME.crypt.bak`). If the app
locks while one of these questions is open, nothing decrypted is shown afterwards: the
password is asked again (G4). Then by kind:

- **text**: editor window (4.5);
- **pdf, image**: viewer window (4.6);
- **other**: offer Export (4.7) or Cancel.

### 4.5 Editor (R2)

- `SafeTextView`, a subclass of `NSTextView`, plain text, monospaced system font 13 pt,
  undo in memory.
- Off: continuous spell checking, grammar, automatic spelling correction, text
  completion, smart quotes, smart dashes, text replacement, data detection, link
  detection, smart insert/delete; `inlinePredictionType = .no` (macOS 14+);
  `writingToolsBehavior = .none` (macOS 15+); math expression completion off (macOS 15+);
  `validRequestor(forSendType:returnType:)` returns nil (no Services on the text);
  `quickLook(with:)` and `showDefinition(for:at:)` do nothing (no Look Up); the context
  menu holds only Cut, Copy, Paste, Select All; dragging the selection out is disabled; no
  kill ring: `delete(_:)` and the delete-to commands (Ctrl-K and its kin, `deleteToMark`)
  put what they delete into a buffer that AppKit keeps for the whole process and that Ctrl-Y
  pastes into any other text field, after a lock too, so they all delete with
  `deleteBackward(_:)` (which keeps undo and does not kill), Cut too, and `yank(_:)` does
  nothing.
- Search with an own search field (Cmd-F, Cmd-G, Cmd-Shift-G) over the text storage. Do
  not use `NSTextFinder` or the find bar: they write the search string to the system-wide
  find pasteboard.
- The app's Edit menu is built by hand: no Spelling, Substitutions, Transformations,
  Speech, Writing Tools or AutoFill. No Print, no Share.
- The window: `isRestorable = false`, `sharingType = .none`; the app sets
  `NSQuitAlwaysKeepsWindows = false` in its own defaults.
- Cmd-S saves through `CryptFile.save` with the password kept in a `SecureBytes` while
  the file is open (R2). Status line: "Decrypted in memory only. Saved 14:05, the
  previous version is kept as NAME.crypt.bak." On `.conflict`, offer: keep my version as
  a separate copy (`NAME (conflict DATE).crypt`), discard my changes, or cancel.
- Closing with unsaved changes asks Save / Don't Save / Cancel. Closing wipes the
  password and drops the text.
- `ClipboardGuard` for Copy and Cut: `prepareForNewContents(with: .currentHostOnly)`,
  the markers `org.nspasteboard.ConcealedType` and `org.nspasteboard.TransientType`, and
  clearing the clipboard after 60 s, on lock and on quit, but only if the clipboard still
  holds what the app put there (`changeCount`). If macOS may keep a clipboard history
  (Spotlight's on macOS 26, `PasteboardHistoryEnabled` of `com.apple.Spotlight`), which Safe
  cannot clear, the first Copy or Cut after each start asks first.

### 4.6 Viewer (R3)

PDF in a `PDFView` (`PDFDocument(data:)`), with data detectors and document analysis (Live
Text) off, images in an `NSImageView`
(`NSImage(data:)`): PDF, PNG, JPEG, HEIC, GIF, TIFF. Read only. Buttons: Export...,
Close. Nothing is written to disk; check that PDFKit and ImageIO create no cache files
(leak test, 7.3).

### 4.7 Export (R3)

`NSSavePanel` proposing the original name next to the encrypted file; before writing, an
alert: "The exported copy is not encrypted." Text files can be exported too (menu item in
the editor and the right-click "Export with Safe").

### 4.8 Volumes (R4)

The Volumes window lists the `VolumeStore` entries: name, location, open or closed, and
buttons New Empty..., New from Folder..., Add Existing..., Open, Close, Change Password...,
Remove from List, and a per-volume setting "Check that this app is running first" (the
sync app's process name, G2 and R4).

- **New Empty:** name, location (save panel), maximum size (default 1 GB), password
  twice; `DiskImage.createEmpty` as a sparse bundle.
- **New from Folder:** choose the folder, then the location for the sparse bundle, a
  password twice; `DiskImage.createFromFolder`; then attach read-only and hidden at a
  private folder, `FolderVerifier.sameContents(folder, mountPoint)`, detach; only if
  they match, delete the folder (`FileManager.removeItem`), and tell the user once that
  deleted files can linger on an SSD and that previews (Quick Look thumbnails) and the
  Spotlight index can keep copies outside the volume, protected only by FileVault, and that a
  sync service keeps plain copies of a synced folder in its trash and version history, and
  Time Machine older ones. If the check fails, keep the folder and say so. A folder with a
  file that has a name outside it (a hard link) is refused, as Encrypt refuses such files. The place the folder is moved to for the delete
  is recorded first in `pending-deletes.json` and forgotten only after the delete; a start
  that finds one still there (Safe was stopped during the delete) says where the unencrypted
  rest is and deletes it only after the user's yes.
- **Open:** if a sync app is set and not running, warn and ask; then password once,
  `DiskImage.attach(readOnly: false, mountPoint: PRIVATE/NAME, hidden: false)`, where PRIVATE
  is a new folder with mode 0700 in the user's temporary folder: a disk image is mounted with
  owners ignored, so at `/Volumes` every account on the Mac could read it, while a folder only
  this user can enter keeps the others out. It appears in the Finder all the same; reveal it.
- **Close:** `DiskImage.detach(force: false)`. If files are in use, say so; never force
  in the background, because other apps may have unsaved work on the volume.
- **Change Password:** `hdiutil chpass` wraps the same key again, so a copy of the volume
  kept from before still opens with the old password; say so before and after.
- **Add Existing:** any encrypted `.dmg` or `.sparsebundle`, checked with
  `DiskImage.isEncrypted`.

### 4.9 Locking (G4)

`LockController` watches: 10 minutes without user input (system-wide idle time from
`CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: kCGAnyInputEventType)`,
that is `CGEventType(rawValue: ~0)`, checked every 10 s; `.null`, planned first, reports the
time since start-up on macOS 26.3; a stretch without input that passed 10 minutes and ended
between two checks locks at the second, and while an editor, a viewer or a volume opened by Safe
exists an activity keeps App Nap from holding back the check), `NSWorkspace.willSleepNotification`, `screensDidSleepNotification`,
`sessionDidResignActiveNotification`, and the distributed notification
`com.apple.screenIsLocked`. On lock:

- editor windows without unsaved changes close; with unsaved changes the text view is
  replaced by a lock view, and the file's password is needed to show it again; nothing is
  discarded without asking;
- viewer windows close;
- volumes opened by the app are closed with `force: false`, also one that holds the file of
  an editor with unsaved changes: the text stays behind the editor's cover, and the volume's
  mount point is remembered, so that after unlocking (or at Cmd-S) the editor offers
  "Open “NAME” Again", which attaches it at the same mount point and the save goes to the same
  path. If one is busy, the user is told when they come back: at the first idle check with
  input again, on `com.apple.screenIsUnlocked`, or when the app becomes active;
- the clipboard is cleared (ClipboardGuard).

## 5. Formats and sequences

### 5.1 The current format (G3)

`"Salted__"` (8 bytes) + salt (8 random bytes) + ciphertext. Key and IV: PBKDF2-HMAC-SHA512
over the password's UTF-8 bytes and the salt, 100,000 iterations, 48 bytes output: key =
bytes 0 to 31, IV = bytes 32 to 47. Cipher: AES-256-CBC with PKCS#7 padding. Matches
`openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt`.

Decrypt with CommonCrypto **without** `kCCOptionPKCS7Padding` and check the padding
yourself: tested, CCCrypt with that option reports success for wrong keys (2000 of 2000).
Name the mode (`CCCryptorCreateWithMode` with `kCCModeCBC`) rather than relying on CCCrypt's
default. Decrypt the last block first (its IV is the block before it) and check its padding,
so that a wrong key costs one block, not a pass over the whole file.
A strict check still lets about 1 in 256 wrong keys through, so `Plausibility` confirms the
result. It cannot refuse one: a real file may not look like its name (text that is not
UTF-8, a picture in an unknown format). A plausible result is confirmed; for a type that
cannot be checked, so is a result that removed more than one byte of padding (a wrong key
that passes the check nearly always leaves one byte, a real file once in 16), and a picture
(JPEG included) or gzip whatever the name (with the padding check, a wrong key gets that far
once in about 4 billion tries). Any other result whose padding is right goes to the user
(4.4), never straight to a window. For a text name, a result shorter than 32 bytes must also be
free of control bytes but tab, line feed, form feed and carriage return, and one of exactly 15
bytes (one byte of padding) is not confirmed at all (`unchecked`): a wrong key gives one about
once in 27 million tries.

### 5.2 Legacy variants (G5, read only)

`openssl enc` without `-pbkdf2` derives key and IV with `EVP_BytesToKey(digest, salt,
password, count 1)`: repeated hashes of previous-hash + password + salt until enough bytes.
The digest was MD5 by default in old versions and SHA-256 from OpenSSL 1.1.0 (tested:
today's LibreSSL 3.3.6 and OpenSSL 3.0 both use SHA-256 when `-md` is not given). Files
may be salted (`Salted__` header) or not (`-nosalt`). RC4 (`crypt.sh` before 1.4) uses a
16-byte key and no IV. Order of attempts when the current format fails or is not confirmed: AES-SHA256,
AES-MD5, RC4-MD5, RC4-SHA256; only a plausible result is confirmed, because several attempts
raise the chance that a wrong password passes. A plausible legacy result wins over a current
one that was not confirmed. So that the right password is never refused (G5: old files must
open as well), other results that could be right go to the user unconfirmed (4.4): an AES
result whose padding is right (`contentMismatch` if its content does not fit the name,
`unchecked` for a type that cannot be checked), and an RC4 result, which comes with any
password, only if it is text in another encoding for a text name, if it is a plausible text
shorter than 32 bytes (`unchecked`, and not counted as text: random bytes that short are
UTF-8 too often), or, for a type that cannot be checked, if the file is salted and not whole
blocks (`unchecked`). An older AES text of exactly 15 bytes is kept `unchecked` as in 5.1. For a file larger than 4 KB, RC4 first decrypts the first 4 KB and goes
on only if the whole result could still be kept. Between several such results, text wins for a
text name, then the current format unless an older AES result removed more padding, then
more padding. An `unchecked` legacy result accepted without a check is never saved again in
the current format without the user's yes.

### 5.3 Saving (R2), same order as `crypt.sh`

1. Read `NAME.crypt`; if its SHA-256 differs from `opened.ciphertextSHA256`, throw
   `.conflict`.
2. Encrypt; remove a stale `NAME.crypt_new`; write it with `O_CREAT | O_EXCL`, mode 0600,
   then `F_FULLFSYNC`.
3. Read it back, decrypt, compare with the plaintext; on mismatch delete it and throw
   `.checkFailed`.
4. Copy `NAME.crypt` to `NAME.crypt.bak` (replacing the old .bak).
5. Rename `NAME.crypt_new` to `NAME.crypt` (atomic), `fsync` the directory.
6. Return a new `OpenedFile` with the new hash.

No step writes plaintext to disk. Encrypting a new file (R1) is the same from step 2,
writing `NAME.crypt_new` next to `NAME`, then rename to `NAME.crypt`, then delete `NAME`.

### 5.4 Reference files (G5)

`app/Fixtures/` holds files named `<generator>-<variant>-<n>.enc` and `manifest.json`
with, per file: password, the plaintext's SHA-256 and length, the variant, the original
name, the generator (for example `Debian OpenSSL 3.0.22`, `macOS LibreSSL 3.3.6`,
`crypt.sh 1.5`). The ending is `.enc` because `.gitignore` excludes `*.crypt*`.
`make-fixtures.sh` regenerates them with the Docker image `fherwig/safe:22.0` (run with
`--rm --network none`) and with `/usr/bin/openssl`; RC4 files come from LibreSSL, which
still has RC4. Include non-ASCII passwords, an empty file, a 1 MB file, a PDF and a PNG.
The app bundle carries a copy in `Resources/Fixtures`.

## 6. Build and packaging

`app/scripts/build-app.sh [--release]`:
1. `swift build -c release --triple arm64-apple-macosx13.0 --scratch-path ...` and the
   same for `x86_64-apple-macosx13.0`; `lipo -create`.
2. Assemble `app/dist/Safe.app`: `Contents/MacOS/Safe`, `Contents/Info.plist` (version
   from `VERSION`), `Contents/Resources/Fixtures/`.
3. `codesign --force --options runtime --entitlements Resources/Safe.entitlements --sign - Safe.app`,
   then `codesign --verify --strict`.
4. `Safe.app/Contents/MacOS/Safe --self-test`; stop if it fails (G5: the app checks the
   reference files when it is built).
5. `ditto -c -k --keepParent Safe.app dist/Safe-VERSION.zip` and `shasum -a 256` into
   `dist/SHA256SUMS`.

`swift build --scratch-path S && swift run --scratch-path S SafeTests` builds the app and
runs all tests; it exits non-zero on failure. `swift run` alone builds only the test runner,
and the app suite then cannot run: the runner says so and fails, unless `--allow-skips` is
given.

## 7. Tests

### 7.1 Unit tests (`SafeTests`)

- Format: round trip; every fixture decrypts to the manifest's hash; files the app makes
  decrypt with `/usr/bin/openssl` and with the Docker image (skip with a note if Docker
  is not running); wrong passwords never pass (2000 random passwords against a text
  fixture: zero accepted); strict padding; empty file; 1 MB file.
- Legacy: each legacy fixture opens with the right variant; a wrong password opens none.
- Files: `encryptFile` deletes the original only after a successful check (a failure is
  injected through a test hook and the original stays); `save` keeps `.bak`, refuses on
  conflict, leaves no `.crypt_new`; `export` writes identical bytes.
- Volumes (with throwaway images under `$TMPDIR`): create empty, create from folder,
  attach hidden at a private folder, verify, detach, change password, `isEncrypted`,
  `attached()`; `FolderVerifier` notices a changed, missing or extra file.
- `VolumeStore`: add, update, remove, `~/` paths, survives a reload.
- `SelfTest` and `NoNetwork.probeBlocked()` after `enforce()` (run in a child process,
  because the restriction cannot be lifted).

### 7.2 App checks without a window

`Safe.app/Contents/MacOS/Safe --version`, `--self-test`, `--check` all exit 0 and print
valid JSON.

### 7.3 Leak test

Open a text fixture through the core API, then search `~/Library`, `$TMPDIR`
(`/private/var/folders`) and `/tmp` for a unique marker contained in its plaintext; also
after viewing a PDF and an image fixture. Nothing may be found. (The full leak test with
typing into the editor is in the owner's acceptance checklist, 7.4.)

### 7.4 Owner's acceptance checklist

Written to `docs/safe-app/acceptance.md`: install with the agent, encrypt a test file
from the Finder, double-click to edit, save, check the `.bak`, view a PDF, export, create
a volume both ways, open it on another Mac, lock behaviour, the marker search after
typing a marker into the editor.

## 8. Install for agents (G2)

`INSTALL-AGENT.md` at the repository root, written for an AI system administration agent:

- **Ground rules:** never ask for, type, store or log the user's passwords; never open or
  mount the user's encrypted files or volumes; never delete them; ask the user before
  anything that changes their system.
- **Checks** (`app/scripts/agent-check.sh`, read only, prints one JSON object): macOS 13
  or later, `uname -m`, FileVault status (warn only), encrypted swap, free space, tools
  needed (`swift` for building from source, `hdiutil`, `codesign`, `ditto`, `shasum`).
  Docker is not required; mention it only for the terminal tool and the time capsule.
- **Install from source** (until releases exist): clone or download the repository, run
  `app/scripts/build-app.sh --release`, run `Safe --self-test`, copy `Safe.app` to
  `~/Applications` (no admin needed), run `Safe --check`, register it with Launch
  Services by opening it once, tell the user where "Encrypt with Safe" appears.
- **Install from a release** (later): download the zip and `SHA256SUMS` with `curl`
  (which sets no quarantine attribute), check the checksum and the signature, then as
  above.
- **Verify, update, uninstall.** Uninstalling removes the app and
  `~/Library/Application Support/SafeDocker`, never `.crypt` files or volumes.

## 9. Work packages

Each package lists its files (only the owner edits them), what it gets, what it delivers
and how it is accepted. Shared files (`Package.swift`, `Info.plist`, `.gitignore`) belong
to WP0 and the integrator; other packages ask for changes in their report.

| WP | Name | Files | Depends on |
|---|---|---|---|
| WP0 | Foundation | `app/Package.swift`, `VERSION`, `Resources/*`, `CSandbox`, all public signatures as compiling stubs, test harness, `build-app.sh`, `.gitignore` entries | this plan |
| WP1 | Crypto and files | `SafeCore/Crypto/*`, `SafeCore/Files/*`, `SafeCore/SelfTest.swift`, `SafeCore/NoNetwork.swift`, `app/Fixtures/*`, `make-fixtures.sh`, `docs/format.md`, their tests | WP0 |
| WP2 | Volumes | `SafeCore/Volumes/*`, their tests | WP0 |
| WP3 | Editor, viewer, export, lock | `SafeApp/Editor/*`, `SafeApp/Viewer/*`, `SafeApp/Lock/*` | WP0 |
| WP4 | App shell, Finder, prompts, volumes window | `SafeApp/main.swift`, `AppDelegate.swift`, `CommandLineMode.swift`, `SafeApp/Finder/*`, `SafeApp/Prompts/*`, `SafeApp/Volumes/*` | WP0 |
| WP5 | Install and long-term tools | `INSTALL-AGENT.md`, `agent-check.sh`, `time-capsule.sh`, `tools/safe-decrypt.py` and its test, `docs/safe-app/acceptance.md` | WP0 |
| WP6 | Integration | merges WP1 to WP5, shared files, universal build, all tests, fixes | WP1 to WP5 |
| WP7 | Review and fixes | requirements, security and leaks, build from a clean clone, crypto compatibility | WP6 |

Acceptance for every package: `swift build --scratch-path S && swift run --scratch-path S
SafeTests` passes in its own scratch path `S`; its tests cover the behaviour in sections 4
and 5 that it owns; it leaves no plaintext, temporary image or test file in the repository.

## 10. Later, not in this build

Developer ID signing and notarization (needs the Apple Developer Program), Team ID
pinning in `INSTALL-AGENT.md`, GitHub release builds, an update check, the App Sandbox
with a separate disk-image helper, Touch ID for passwords, encrypted autosave, a formatted
Markdown view.

## 11. Rules for builders

- Never touch the owner's real files: no safe disk image, nothing under `/Volumes/safe`,
  not the Docker container named `safe`, not `docker_stop.sh`, not `safe.conf`. Test with
  throwaway files under `$TMPDIR` or `/tmp`, test passwords, volume names starting with
  `safetest`.
- No windows or dialogs on the owner's screen: do not launch the app without a
  command-line flag, no `osascript` dialogs, no `open` of test files. Do not install the
  app into `~/Applications`, and do not change Launch Services or the Services menu
  (`lsregister`, `pbs`).
- Docker: only the local image `fherwig/safe:22.0`, with `--rm --network none` and
  container names starting with `safetest`; never pull, build, remove or restart.
- Build only with `--scratch-path` outside the repository. Each scratch folder takes
  about 700 MB: delete yours (`/bin/rm -rf` with its explicit path) as soon as its result
  is checked, and keep at most the one or two the next build starts from. Fifty of them
  filled the disk once. Do not delete with
  `rm -rf "$VARIABLE"` (a safety check blocks it); `rm` is aliased to `rm -i` in the
  owner's shell, so use `/bin/rm` with explicit paths, and leave scratch files in
  `/tmp` if in doubt. The shell is zsh.
- Commit only on your own branch; never push. The repository is public: no personal
  details (where the owner's safe lives, machine names, private email addresses).
- Code comments and documents in plain English, in the style of the existing scripts.
