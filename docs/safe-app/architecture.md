# Safe.app: architecture as built

This describes Safe.app version 0.3.0 as it is in the repository: its parts, files and
flows, where decrypted data lives, and how it is tested. `building-plan.md` is the plan
it was built from; section 9 lists every place where the code differs from it, section
10 sums up the four rounds of review and fixes that followed the first build, section
11 describes what version 0.2.0 added: the help, the tooltips and the keyboard shortcuts,
and section 12 what version 0.3.0 added: English and German, and the Settings window.
`design-decisions.md` says why it is built this way, `../format.md` describes the file
format byte by byte, and `acceptance.md` is the owner's checklist.

## 1. Overview

Safe.app is one AppKit process, written in Swift (SwiftPM, Swift 5 language mode,
macOS 13 or later, a universal binary for Apple silicon and Intel). It has no helper
processes of its own and no network: the first thing it does is deny itself the network
with `sandbox_init`. The only programs it starts are `/usr/bin/hdiutil`, for volumes,
and, in tests, itself.

```
Finder: double-click, Services menu        Safe's own windows and menus
        |                                          |
   AppDelegate, ServicesProvider  ------>  DocumentRouter (RouterFlows)
                                             |  password dialogs
                                             v
                    EditorWindowController, ViewerWindowController, ExportController
                                             |
   SafeCore:  CryptFile -> OpenSSLFormat, Legacy, Plausibility, FileKind
              (reads and writes only ciphertext, except Export)

   Volumes window -> VolumeController (VolumeFlows) -> DiskImage -> /usr/bin/hdiutil
                                                    -> FolderVerifier, VolumeStore, SyncCheck

   LockController: idle time, sleep, screen lock -> editors, viewers, volumes, clipboard
```

## 2. Targets and files

`app/Package.swift` defines four targets. Line counts are rounded.

| Target | Kind | Lines | What it holds |
|---|---|---|---|
| `CSandbox` | C library | 35 | `safe_deny_network()`, a wrapper around the deprecated `sandbox_init(kSBXProfileNoNetwork, ...)`, which Swift cannot call directly |
| `SafeCore` | library, no AppKit | 3,400 | everything that can be tested without a window |
| `SafeApp` | executable, product `Safe` | 12,000 | the app; about 4,400 of these lines are the tests run by `Safe --app-tests` and their harness |
| `SafeTests` | executable | 3,800 | the test runner and its suites |

`SafeCore`:

| File | Purpose |
|---|---|
| `Crypto/SecureBytes.swift` | passwords and keys in their own `mmap` pages, locked with `mlock`, wiped with `memset_s` |
| `Crypto/OpenSSLFormat.swift` | the current format: `Salted__`, PBKDF2-HMAC-SHA512 with 100,000 iterations, AES-256-CBC through CommonCrypto's `CCCryptorCreateWithMode` with the mode named (`kCCModeCBC`) and no padding, PKCS#7 padding added and checked in code, the last block decrypted first; the first blocks of a file whose padding fails, for the damage check; `CryptVariant`, `CryptError` |
| `Crypto/Legacy.swift` | the older variants, read only: `EVP_BytesToKey` with MD5 or SHA-256 (CryptoKit), AES-256-CBC or RC4 (in Swift), salted or not |
| `Crypto/Plausibility.swift` | is decrypted content believable: the first bytes of a known type (PDF, pictures, ZIP and Office documents, archives, media) for any name, strict UTF-8 without NUL for text endings (below 32 bytes also without control bytes), the type's own first bytes for the endings of known binary types, and UTF-8 of at least 32 bytes for other endings; `looksLikeText`, text in an 8-bit encoding or UTF-16, told apart from random bytes; `needsMagicBytes`; the start of a file cut short (`looksLikeStartOfFile`) and the RC4 check of a file's first 4 KB |
| `Files/FileKind.swift` | text, pdf, image or other, from the original name and the content; `isTextName` |
| `Files/CryptFile.swift` | encrypt, open, save and export single files; `OpenedFile`, `PasswordCheck`; the readable part of a damaged file (also unchecked, for a file that `mayBeCutShort`), old RC4 files for export |
| `Files/FileIO.swift` | POSIX helpers: new files with `O_CREAT|O_EXCL` and mode 0600, `F_FULLFSYNC`, renames, messages naming the file |
| `Volumes/DiskImage.swift` | create, attach, detach, change the password, `isEncrypted`, `attached()` |
| `Volumes/Hdiutil.swift` | runs `hdiutil`; passwords go to its stdin from the `SecureBytes`, each followed by a NUL byte |
| `Volumes/FolderVerifier.swift` | compares a folder with the volume made from it |
| `Volumes/VolumeStore.swift` | the list of volumes, `~/Library/Application Support/SafeDocker/volumes.json` |
| `Volumes/SyncCheck.swift` | is the sync app running, like `pgrep -x`, without a child process; `isInSyncedFolder`, whether a sync service uploads a folder |
| `SelfTest.swift` | the known-answer tests over the reference files and the manifest's coverage of every generator, variant and file, the wrong-password test, the network probe |
| `NoNetwork.swift` | `enforce()` and `probeBlocked()` |
| `AppLogic/EditorLogic.swift` | the editor's decisions without a window: search, status line, conflict copy names, clipboard rule and macOS's clipboard history, shortcuts |
| `AppLogic/LockPolicy.swift` | the lock's decisions without a window: 10 minutes, every 10 s, a stretch that ended between two checks, close or cover, password comparison in constant time |
| `AppLogic/TextCoding.swift` | the editor's text encodings: UTF-8 with or without a byte order mark, UTF-16, ISO Latin-1; reading and writing back the same bytes |
| `Localization.swift` | `L`, `Lp`, `LKey`, `AppLanguage` and the tables of `en.lproj` and `de.lproj` (section 12) |

`SafeApp`:

| File | Purpose |
|---|---|
| `main.swift` | the start sequence (section 3) |
| `AppDelegate.swift` | app life cycle, `SelfTestGate`, the main menu built by hand, File menu actions |
| `CommandLineMode.swift` | `--version`, `--self-test`, `--check`, `--help`; in debug builds `--app-tests` and its small harness |
| `Finder/ServicesProvider.swift` | receives "Encrypt with Safe", "Open with Safe", "Export with Safe" |
| `Finder/DocumentRouter.swift` | the fixed interface; gives `RouterFlows` the real dialogs, `CryptFile` and windows |
| `Finder/RouterFlows.swift` | what happens to each file on Encrypt, Open and Export, testable with stand-ins |
| `Prompts/PasswordPrompt.swift` | password dialogs: once, or twice with a check that both match and are not empty; the rules for new passwords (no line break or other control character, at most 511 bytes, the note for one that must be pasted) |
| `Prompts/Alerts.swift` | messages, questions, a small form, `ModalProgress` (work off the main thread with a panel after 0.4 s) |
| `Editor/SafeTextView.swift` | the hardened text view (section 4.3) |
| `Editor/EditorWindowController.swift` | the editor window: save, conflict, close, lock and unlock; `ConflictCopy` |
| `Editor/EditorViews.swift` | `EditorWindow` (its own shortcuts), `SearchBar`, `LockCoverView`, `ReadOnlyBar` |
| `Editor/ClipboardGuard.swift` | copy for this Mac only, concealed, cleared after 60 s; asks first if macOS keeps a clipboard history |
| `Viewer/ViewerWindowController.swift` | PDF and image viewer from memory; `SafePDFView` |
| `Viewer/ExportController.swift` | save panel, the "not encrypted" warning, `CryptFile.export` |
| `Viewer/DocumentAlerts.swift` | alerts for the editor, viewer and export, with hooks for tests |
| `Lock/LockController.swift` | watches idle time, sleep and screen lock (G4) |
| `Volumes/VolumesWindowController.swift` | the Volumes window |
| `Volumes/VolumeFlows.swift` | what its buttons do, and closing on lock, testable with stand-ins |
| `Volumes/VolumeController.swift` | gives `VolumeFlows` the real dialogs, `DiskImage` and `VolumeStore`; `VolumeLockGlue` (closing on lock, the report when the user is back), `FolderSnapshot` (and the files with names outside a folder), `OpenedVolumesFile`, `PendingDeletesFile` |
| `Help/HelpBook.swift` | `HelpSection`, finding and reading `SafeHelp.md` (a short note if it is missing), and `HelpRenderer`, which draws its Markdown into an attributed string with AppKit only |
| `Settings/Settings.swift`, `Settings/SettingsWindowController.swift` | the language choice in the defaults, what System means, the restart offer; the Settings window (section 12) |
| `Help/HelpWindowController.swift` | the help window (sections, search), `HelpTextView`, `HelpButton` (the "?" buttons and the "?" of alerts), `ToolTipAudit` (the rule the tooltip test checks) |
| `*/PromptTests.swift`, `RouterTests.swift`, `EditorTests.swift`, `VolumeTests.swift`, `HelpTests.swift`, `LocalizationTests.swift` | tests run by `Safe --app-tests` |

Other parts:

| Path | Purpose |
|---|---|
| `app/Resources/Info.plist` | bundle id `io.github.fherwig.safedocker`, the exported type `io.github.fherwig.safedocker.crypt` (ending `.crypt`, conforms to `public.data`), the document type (role Editor, rank Owner), three services |
| `app/Resources/Safe.entitlements` | an empty dictionary: hardened runtime, no App Sandbox |
| `app/Resources/SafeHelp.md`, `SafeHelp.de.md` | the owner's manual in English and German, shown by Help > Safe Help; copied into `Safe.app/Contents/Resources` |
| `app/Resources/en.lproj`, `de.lproj` | `Localizable.strings` (Safe's texts), `InfoPlist.strings` and `ServicesMenu.strings` (what the Finder shows, in macOS's language); copied into `Contents/Resources` |
| `app/Fixtures/` | 59 reference files (`*.enc`) and `manifest.json`; copied into `Safe.app/Contents/Resources/Fixtures` |
| `app/scripts/build-app.sh` | builds, assembles, signs and zips the app (section 8) |
| `app/scripts/make-fixtures.sh` | regenerates the reference files |
| `app/scripts/gen-icon.swift`, `make-icon.sh` | draw Safe's icon (a porthole with a keyhole, in the design language of Marina's icon) and pack it into `app/Resources/Safe.icns`, plus `docs/images/safe-icon.png` for the README; `build-app.sh` copies the icon into the bundle, and `.crypt` files get a document icon that macOS makes from it (`CFBundleTypeIconSystemGenerated`) |
| `app/scripts/agent-check.sh` | read-only checks for the install agent, one JSON object |
| `app/scripts/time-capsule.sh` | saves the Docker image `fherwig/safe:22.0` as an archive outside any repository |
| `tools/safe-decrypt.py` | reference decryptor, Python 3 standard library only, every variant, never encrypts |
| `tools/test_safe_decrypt.py`, `tools/test_scripts.py` | tests of the decryptor and of the two scripts |
| `tools/docker-image.txt` | the image's digest |
| `INSTALL-AGENT.md` | instructions for the install agent |

## 3. Start and command-line modes

`main.swift`:

1. `NoNetwork.enforce()`. If it fails, an alert says so (or, for a command-line mode,
   stderr, with the message itself rather than the error's debug form) and the app exits
   with status 1.
2. `CommandLineMode.run`: an argument starting with `--` selects a mode without a window,
   which prints and exits. Arguments with one dash and capitals, digits, dots or underscores
   (those macOS adds, such as `-psn_0_123` or `-NSDocumentRevisionsDebugMode`) start the app;
   what an agent may type out of habit (`help`, `version`, `-?`, and one dash with lower-case
   letters, such as `-h` or `-version`) gets the usage and exit status 2 instead.
   - `--version`: the version from `Info.plist`, which `build-app.sh` fills in from
     `app/VERSION`; a debug build adds ` (debug build)`.
   - `--self-test`: `SelfTest.run` over `Contents/Resources/Fixtures`; JSON with
     `version`, `configuration` (`debug` or `release`), `fixturesDirectory`, `knownAnswers`,
     `wrongPasswordRejected`, `networkBlocked`, `failures` and `ok`; exit status 0 only if
     everything passed.
   - `--check`: JSON with `version`, `configuration`, `app`, `fixturesDirectory`,
     `fixturesFound`, `manifestFound`, `networkBlocked`, `helpFound` (the help files of both
     languages are there and have every section), `languages` (the tables found, `["en", "de"]`), `volumeList`, `volumes` (name,
     path, whether the image exists, sync app), `volumeListError` if the list cannot be
     read, `attachedImages` (image and mount point; `attachedImagesError` if `hdiutil`
     cannot list them), and `pendingDeletes`, the number of folders recorded in
     `pending-deletes.json` that are still there (counted, never named). Read only. The
     environment variable `SAFE_VOLUME_LIST` points it at another list, and the
     `pending-deletes.json` next to it, for tests.
   - `--help`; a wrong or second option gives the usage and exit status 2.
   - `--app-tests [filter ...]`, debug builds only (section 7).
3. Otherwise `NSApplication` with `AppDelegate`. Before launch: the app's own defaults
   (`NSQuitAlwaysKeepsWindows` false, the Dictation and Emoji menu items off), the main
   menu, the services provider. After launch: `LockController.start()`, the volumes an
   earlier run opened and that are still open taken over (`OpenedVolumesFile`), closing
   volumes added as a lock action, the self-test started in the background through
   `SelfTestGate`, `NSUpdateDynamicServices()`, the Volumes window if the app was
   not started to open documents, and the offer to finish deleting a folder that New from
   Folder was deleting when Safe was stopped (section 4.6).

`SelfTestGate` holds the result of the self-test. While it runs and if it fails,
`CryptFile.writeRefusal` is set, so `encryptFile` and `save` throw `.selfTestFailed`
whoever calls them; the dialogs say why. Encrypt waits for the self-test to finish;
saving in the editor while it still runs says to try again in a moment. Opening and
exporting always work.

The main menu is built by hand: Safe (About, Settings Cmd-comma, Lock Now Ctrl-Cmd-L, Hide, Quit), File
(Open, Encrypt File, Close, Save, Export), Edit (Undo, Redo, Cut, Copy, Paste, Delete,
Select All, Find), View (the viewer's zoom and pages), Volume (the Volumes window's
buttons), Window (Minimize, Zoom, Volumes Cmd-0) and Help (Safe Help Cmd-?, three topics),
which is `NSApp.helpMenu`. Section 11 lists every shortcut. A delegate strips anything
macOS adds to the Edit menu (Writing Tools, AutoFill, Dictation, Emoji) before it opens.
There is no Print, Share, Services, Spelling, Substitutions, Transformations or Speech.

## 4. Flows

### 4.1 Encrypt (R1)

From "Encrypt with Safe" in the Finder or File > Encrypt File. `RouterFlows.encrypt`
waits for the self-test, skips (and reports) missing files, folders, encrypted disk images
(a `.sparsebundle`, or a `.dmg` or `.sparseimage` that `DiskImage.isEncrypted` reports as
encrypted: to be added in the Volumes window; an unencrypted single-file image is
encrypted like any file), `.crypt` files, files whose `NAME.crypt` exists, files larger
than 1 GB (`CryptFile.largestFileToEncrypt`: encrypting holds about four copies in memory;
such files belong in a volume) and files with other names (hard links, which would keep the
plaintext after the delete), asks for one password twice, and encrypts each file with
`CryptFile.encryptFile` behind a progress panel. A summary lists the files that were not
encrypted; their originals are kept. For a file inside an open volume (a mount point of
`DiskImage.attached()`), the password dialog says that the deleted plain copy stays readable
in the volume's image to anyone with the volume's password, and that files are best
encrypted before they are moved into a volume (R4: protected twice). For a file in a synced
folder (`SyncCheck.isInSyncedFolder`: under `~/Library/CloudStorage` or `~/Library/Mobile
Documents`, or a folder named after Nextcloud, ownCloud, Dropbox, OneDrive, Google Drive,
Seafile or Syncthing) it says that the sync service keeps a plain copy in its trash and version
history. The first Encrypt dialog also says once (`CopiesNote`, shared with New from Folder)
which copies of a deleted original can remain: on an SSD, in Quick Look previews and the
Spotlight index, in Time Machine backups and local snapshots.

A new password must be typed the same twice, must not be empty, must not contain a line
break or another control character (`openssl` and `crypt.sh` read a password only up to the
line break, so a pasted one would make the file unreadable for them), and must be at most
511 bytes, the most `openssl`'s prompt takes. A password typed to open a file or a volume
loses line breaks at its end, which pasting a whole line adds. A new password with letters of
a script other than Latin or with emoji (`PasswordPrompt.needsPasting`) is taken only when it
is given twice again after a note: macOS lets secure text fields use only Roman input sources
and no emoji palette, so it would have to be pasted every time.

`CryptFile.encryptFile`: refuse a file above the size limit, a file with other names (hard
links, `st_nlink` above 1), and a file with a resource fork, which the `.crypt` file could not keep (only the data fork is encrypted; extended
attributes such as Finder tags and comments are not kept either); read `NAME`; encrypt with a
fresh salt; remove a stale
`NAME.crypt_new`; write it with `O_CREAT|O_EXCL`, mode 0600 and `F_FULLFSYNC`; read it
back, decrypt and compare (on a mismatch delete it and throw `.checkFailed`); rename it
to `NAME.crypt` only if that does not exist (`RENAME_EXCL`); flush the folder; read
`NAME` again and delete it only if it is still what was encrypted; flush the folder.

### 4.2 Open (R2, R3)

From a double-click, "Open with Safe" or File > Open. A file that is open already is
brought to the front. Otherwise the password is asked once, and
`CryptFile.open(allowLegacy: true)`:

1. follows a symbolic link, so a later save replaces the file and not the link;
2. with the `Salted__` header, decrypts the current format with the strict padding
   check, the last block first, so that a wrong key costs one block. A plausible result is
   `confirmed`; so is one of a type that cannot be checked that removed more than one byte
   of padding, and a picture (JPEG included) or gzip whatever the name. If the padding is
   wrong, the first blocks (up to 4 KB, never the last) are decrypted anyway, for the damage
   check of step 4. Any other result with valid padding is kept: `contentMismatch` (the content does not look like its name) or `unchecked` (a
   type that cannot be checked, one byte of padding). It is never thrown away as a wrong
   password. A plausible text of exactly 15 bytes, with one byte of padding, is kept
   `unchecked` instead of confirmed: a wrong key gives one about once in 27 million tries. A
   body that is not whole blocks gives its first whole blocks for the damage check too. A file without the header that already looks like its type is not encrypted,
   if it is at least 32 bytes long or starts with the first bytes of a known type; shorter
   content goes on to the older variants first, because a few random bytes are UTF-8 often;
3. if that gave no confirmed result, tries the older variants in the order AES-SHA256,
   AES-MD5, RC4-MD5, RC4-SHA256 and returns the first plausible one (an AES text of exactly
   15 bytes is kept `unchecked`, as above; RC4 is skipped once the damage check found a cut
   file). Other results are
   kept, so that the right password is never refused: an AES result whose padding is right
   (`contentMismatch`, or `unchecked` for a type that cannot be checked); an RC4 result
   only if it is text in another encoding for a text name (`Plausibility.looksLikeText`,
   `contentMismatch`), a plausible text shorter than 32 bytes (`unchecked`, never ranked as
   text), or, for a type that cannot be checked, if the file cannot be AES, being salted
   with a length that is not whole blocks (`unchecked`). RC4 of an empty body is never
   taken; for a body larger than 4 KB, RC4 decrypts the first 4 KB and goes on only if the
   whole result could still be kept (`Plausibility.rc4StartCouldBeKept`);
4. otherwise returns the best kept result (`CryptFile.Candidate`: for a text name, text
   first; then the current format, unless an older AES result removed more than one byte
   of padding and the current one only one; then more padding; otherwise the earlier
   attempt). Before that, if no result was confirmed and the current format's padding was
   wrong, or its body not whole blocks, while the start of what its key gave looks like the start of a file of this name
   (`Plausibility.looksLikeStartOfFile`: the first bytes of a known type, JPEG and gzip with
   one byte more; or for a text name or a type that cannot be checked UTF-8 of at least 32
   bytes, the last character possibly cut; or for a text name text in another encoding of at
   least 64 bytes), it throws `.damaged`: the file was cut short, at a block boundary or inside
   a block, and the password is very likely right. Without a result it throws `.corrupt` for a salted file
   with nothing after the salt, `.wrongPasswordOrDamaged` for a salted file that is not
   whole blocks (an RC4 file with a wrong password, or a file cut short), `.notEncrypted`
   for a short file without the header that looks like its type, else `.wrongPassword`;
5. returns the `OpenedFile` (URL, original name, kind, variant, SHA-256 of the
   ciphertext, `check`) and the plaintext.

A wrong password is said to be wrong and asked again; for `.wrongPasswordOrDamaged` the
message adds that, if the user is sure of the password, the file may be damaged. The router
keeps a keyed digest of the last refused password (HMAC-SHA256 with a key made at start, only
in memory, compared in constant time) while it asks. When the same password is refused twice
in a row for a text name or a type that cannot be checked (`CryptFile.mayBeOldRC4`), it asks
"The password was not right" with Type It Again, Export as an Old RC4 File... and Cancel, and
then "How was “NAME” written?": by crypt.sh before 1.4 (RC4 with an MD5 key) or by another
tool (RC4 with a SHA-256 key). `CryptFile.decryptOldRC4` goes straight to Export with the
warning that Safe could not check the result, never to a window or a save. For a salted file
of at least two whole blocks (`CryptFile.mayBeCutShort`) the question also offers Export
Readable Part... (`CryptFile.readablePart(checked: false)`), for a file in the current format
cut short whose start Safe cannot recognise, exported with the note that Safe could not check
it. For other names the repeat says that the file may be damaged and names `NAME.crypt.bak`,
if there is one. For `.damaged` the question is "“NAME” is damaged": the password seems right
but the end is missing, `NAME.crypt.bak` if there is one, and Export Readable Part...
(`CryptFile.readablePart`, every whole block but the last, exported with a note that it is
incomplete), Type Another Password or Cancel. A result that is `contentMismatch`, from any
variant, or `unchecked` from the current format, goes to the question "Safe could not
confirm the password": the content does not look like its type (or Safe cannot check the
type), and with a wrong password it would be meaningless. The user chooses Open Read-Only (a
text name: the editor shows the text as UTF-8, as UTF-16 after a byte order mark, or as ISO
Latin-1, read only, until Allow Editing), Open (a PDF or picture: the viewer), Export...
(anything else, and always from "Export with Safe"), Type Another Password or Cancel. For a
text name whose result is neither UTF-8 nor text in another encoding, nearly always a wrong
password, the question is "The password is probably not right" instead, with Type It Again,
Export Anyway... and Cancel; so is a result for a name whose type always starts with the
same bytes (`Plausibility.needsMagicBytes`: PDF, ZIP-based documents, the Office compound
file, archives, media, RTF, SQLite; not pictures) that matches no known type. An export of
any result Safe could not confirm carries a note in the export warning that the copy may be
meaningless. An `unchecked` result from an older variant asks "Is this the
right password?" (Continue, Type It Again, Cancel); after Continue a text opens read only
until Allow Editing. A text of 15 bytes from the current format gets the question above,
saying that it is too short to confirm. For a text name or a type Safe cannot check, these
questions also offer Other Readings..., which asks "How was “NAME” written?" and exports the
file read in another way, with the warning that Safe could not check it: as an old RC4 file
(MD5 or SHA-256 key) unless the result is that, and, unless the current format gave the result,
as a damaged file in the current format (`mayBeCutShort`); an AES variant gives a result with
valid padding for about 1 in 85 passwords, the right one of an old RC4 file included, and Type
It Again gives the same every time. A file in an older format is
named as such; text is written in the current format at the next save, other files offer
"Save in Current Format", and a result accepted without a check "Save in Current Format...",
which saves only after a second question that names the risk (the file as it was becomes
`NAME.crypt.bak`). Then by kind: text goes
to the editor, PDF and images to the viewer, other files to Export (or Save in Current
Format) or Cancel.

The router reads `LockController.lockCount` when a file has been decrypted and again after
each question and message that follows: if the app locked meanwhile, the result and the
password are dropped and the password is asked again, so that nothing decrypted is shown
after a lock without it (G4). Export checks the same before it writes.

### 4.3 Editor (R2)

`SafeTextView` is a plain-text `NSTextView`, monospaced system font 13 pt, with undo in
memory. Off: rich text, the font panel, the ruler, the find bar and find panel,
incremental search, spelling, grammar, autocorrection, completion, quote, dash and text
substitution, data and link detection, smart insert and delete, inline predictions
(macOS 14), Writing Tools and math completion (macOS 15), the Touch Bar picker. It
refuses Services (`validRequestor`), Quick Look, Look Up (`showDefinition`), sharing,
speech, every spelling command and every drag of the selection. It has no kill ring:
AppKit's `delete(_:)` and the delete-to commands (Ctrl-K, `deleteToEndOfLine`,
`deleteToBeginningOfLine`, `deleteToBeginningOfParagraph`, `deleteToMark`) put what they
delete into a buffer that lives as long as the process and that Ctrl-Y pastes into any
other text field, after the editor closed and after a lock; `SafeTextView` extends the
selection as AppKit does and deletes it with `deleteBackward(_:)`, which keeps undo and does
not kill (tested), Edit > Delete and Cut too, and `yank` does nothing. Its context menu holds
Cut, Copy, Paste and Select All. Cut and Copy go through `ClipboardGuard`; if macOS may keep a
clipboard history (Spotlight's on macOS 26: `PasteboardHistoryEnabled` of `com.apple.Spotlight`
on, or not set on macOS 26 or later), the first Copy or Cut after each start asks first, because
Safe cannot clear that history, and Cancel copies and cuts nothing. The search
field above the text uses a `SafeTextView` as its field editor, with the same settings.

Search (Cmd-F, Cmd-G, Cmd-Shift-G and the Find menu) goes to the window's own search bar,
which searches the text storage with `TextSearch`, case-insensitive and wrapping. The
find pasteboard is never written.

The window: not restorable, `sharingType = .none`, no tabs. The title is the original
name; the status line says "Decrypted in memory only.", "Text in ISO Latin-1." (or UTF-16,
or UTF-8 with a byte order mark) for text that is not plain UTF-8, and, after a save,
"Saved 14:05, the previous version is kept as NAME.crypt.bak.".

The text keeps its encoding (`TextCoding`): a UTF-8 byte order mark, as Windows Notepad
writes it, is not shown and is written back on save, in conflict copies and on export;
UTF-16 and ISO Latin-1 are written back as they were read, so an unchanged text gives the
same bytes. If the text gains a character that ISO Latin-1 cannot hold, saving offers
"Save as UTF-8" or Cancel. A text opened read only (4.2) shows a note with Allow Editing
above it; until then typing changes nothing and Save is refused. The editor itself insists:
a file whose password Safe could not confirm (`OpenedFile.check` not `confirmed`) is read
only until Allow Editing, whatever the caller asked for. For such a file the first save
writes `NAME.crypt.bak` as usual, and later saves in the same window keep that `.bak`, so
that saving twice cannot replace both the file and its `.bak` if the password was wrong
after all.

Cmd-S calls `CryptFile.save` with the password kept since opening:

1. read `NAME.crypt`; if it is gone or its SHA-256 differs from the one at opening,
   throw `.conflict` (if its folder is gone, the editor says that the volume holding it
   was probably closed and should be opened again, instead of offering the conflict
   choices; if Safe itself closed that volume on lock, it offers "Open “NAME” Again", which
   attaches it at the same mount point, and then saves);
2. encrypt; remove a stale `NAME.crypt_new`; write it (`O_EXCL`, 0600, `F_FULLFSYNC`);
3. read it back, decrypt and compare; on a mismatch delete it and throw `.checkFailed`;
4. remove the old `NAME.crypt.bak` and write the bytes read in step 1 as the new one
   (`O_EXCL`, 0600, `F_FULLFSYNC`);
5. rename `NAME.crypt_new` to `NAME.crypt` and flush the folder;
6. return a new `OpenedFile` with the new hash and the current variant.

On a conflict the user chooses: keep my version as a separate encrypted copy
(`NAME (conflict 2026-10-25 14-05).md.crypt`, written new, read back and compared), load
the file as it is now and discard my changes, or cancel. Loading follows the rules of
opening: a result Safe cannot confirm that is neither UTF-8 nor text in another encoding is
refused ("Safe could not confirm the password for the file as it is now"), other text it
cannot confirm is shown read only until Allow Editing; either way the next save writes
`NAME.crypt.bak` from the file as it is now.

Closing with unsaved changes asks Save, Don't Save or Cancel. An answer given after Safe
locked while one of the editor's questions was open is not taken: the close and conflict
questions check the lock when they are answered, and the question at Quit is asked again
after the password. After the user unlocks an editor whose file was on a volume that Safe
closed on lock, it offers "Open “NAME” Again" (section 4.7). Closing empties the text
view, the search field and its field editor, removes the undo steps and wipes the
password.

### 4.4 Viewer (R3)

PDFs in a `SafePDFView` (`PDFDocument(data:)`), images in an `NSImageView`
(`NSImage(data:)`), both from memory. `SafePDFView` copies through `ClipboardGuard` and
has no Services, Look Up, find bar or extra menu items; links and print requests do
nothing; its data detectors and its document analysis (Live Text over pages that are only
pictures) are off, set through key-value coding where this macOS has them. A PDF with a password of its own gets an "Unlock PDF" button. Buttons: Export,
Close, and for a file in an older format "Save in Current Format", which saves the same
bytes with `CryptFile.save`; not for a file whose password Safe could not confirm, whose
status line says so instead. The password is kept only for "Save in Current Format". Closing drops the
document, the image and the data and wipes the password. The View menu zooms (Zoom In, Zoom
Out, Actual Size, Zoom to Fit: `PDFView`'s own scaling, and for a picture an `NSScrollView`
with magnification around the image view, which first shrinks a large picture to fit and
never enlarges a small one until Zoom to Fit) and turns the pages of a PDF.

### 4.5 Export (R3)

`ExportController.export`: a save panel in the encrypted file's folder, proposing the
original name, or on the Desktop for a file inside an open disk image, where a copy stays
readable in the image even after it is deleted; any name ending in `.crypt` or `.crypt.bak`
is refused, and so is any other name for the encrypted file itself or its `.bak` (same device
and file number, so a name in other case or a hard link cannot replace it); an alert says
"The exported copy is not encrypted." and where it goes, with a sentence about volumes when
the place is in one, and a note for a result Safe could not confirm (it may be meaningless)
or the readable part of a damaged file (it is incomplete); if the app locked while a dialog was open, nothing is written; then
`CryptFile.export` writes a visible temporary file in the chosen folder,
`NAME (exporting XXXXXXXX).tmp` (`O_EXCL`, 0600, `F_FULLFSYNC`), and renames it over the target.
"Export with Safe" in the Finder and File > Export ask for each file's password (again
after a wrong one) and export one file at a time.

### 4.6 Volumes (R4)

The Volumes window lists the volumes in `VolumeStore` with name, location and state
(open, closed, missing), and has the buttons New Empty, New from Folder, Add Existing,
Remove from List, Open, Close and Change Password, and per volume "Check that this app is
running before opening" with the app's process name. The dialogs are modal alerts.

- **New Empty**: name and maximum size (default 1 GB) in a form, the place in a save
  panel, the password twice; `DiskImage.createEmpty` makes an AES-256 APFS sparse
  bundle; the volume is added to the list.
- **New from Folder**: the folder (refused: the home folder, folders that contain it,
  top-level folders, whole volumes, folders with a volume mounted inside, and folders with a
  file that has a name outside them, a hard link, `FolderSnapshot.filesWithOtherNames`, as
  Encrypt refuses such files; for a folder in a synced folder the question before says that
  the sync service keeps plain copies in its trash and version history); the place
  of the new sparse bundle, not inside the folder; the password twice.
  `DiskImage.createFromFolder` (room for twice the folder's size, at least 1 GB). Then
  the check: a listing of the folder (`FolderSnapshot`: paths, kinds, sizes, modification
  times, file numbers, numbers of names), attach read-only and hidden at `$TMPDIR/safe-volume-UUID/volume`
  (the outer folder made with mode 0700), `FolderVerifier.sameContents`, detach without
  force, trying up to three times. Only if they match is the folder deleted: it is renamed
  to a hidden `.NAME.safe-pending-XXXXXXXX` next to it, so that nothing writing by its path
  can add to it any more, listed again, and deleted (`FileManager.removeItem`) only if the
  listing is the one from before the check; otherwise it is renamed back and kept, because
  a sync service or another app wrote to it meanwhile. The hidden path is recorded in
  `~/Library/Application Support/SafeDocker/pending-deletes.json` (paths only, mode 0600,
  replaced atomically) before the rename and forgotten after the delete; a start that finds
  one still there (Safe was stopped during a long delete) says where the unencrypted rest is
  and offers Delete, Show in Finder and Not Now, and deletes only after Delete. Then the
  volume is added to the list; the first time (`CopiesNote`), the user is told that deleted files cannot be
  wiped reliably on an SSD, that previews (Quick Look thumbnails) and the Spotlight index
  can keep copies outside the volume, which FileVault protects, and that a sync service keeps
  plain copies of a synced folder in its trash and version history and Time Machine older
  ones. If the check fails or cannot run, the folder is kept and the user is told where the
  new volume is.
- **Add Existing**: a `.dmg`, `.sparsebundle` or `.sparseimage`, accepted only if
  `DiskImage.isEncrypted`.
- **Open**: if a sync app is set and not running, a warning with "Open Anyway"; the
  password, asked again after a wrong one; `DiskImage.attach` read-write, visible, at
  `$TMPDIR/safe-volume-UUID/NAME`, in a new folder with mode 0700, not at `/Volumes`: a disk
  image is mounted with owners ignored, so at `/Volumes` every account on the Mac could read
  its files, while the private folder keeps the others out (tested: the volume is browsable
  and listed like any other, so the Finder shows it); a Finder window shows it. The folder is
  removed when the volume is closed, or at Quit for one closed on lock. The app remembers that it opened it, also in
  `~/Library/Application Support/SafeDocker/opened-volumes.json` (record id and mount
  point, mode 0600), so that after a crash, a force quit or Quit Anyway the next start
  takes over the volumes still open at the same place and closes them on lock.
- **Close**: `DiskImage.detach` without force; if files are in use, the user is told.
- **Change Password**: the old password once and the new one twice; refused while the
  volume is open (`hdiutil chpass`). `chpass` wraps the same key again, so a copy of the volume
  kept from before (in a sync service's version history, a backup, another Mac) still opens
  with the old password; both dialogs say so, and suggest a new volume if the old password may
  be known to someone.
- **Remove from List**: after asking; the image is never deleted.

The Volume menu has the same actions (section 11). In the list, Return opens the selected
volume and Delete removes it from the list after asking (`VolumeTableView`).

`DiskImage` runs `hdiutil` with passwords on stdin and `-plist` output where there is
any: `create -size N -type SPARSEBUNDLE` or `create -srcfolder -format UDSB -anyowners
-skipunreadable`, always `-fs APFS -encryption AES-256 -stdinpass`; `attach -stdinpass
-plist -noautoopen` with `-readonly`, `-nobrowse` and `-mountpoint` as asked; `detach`
of the image's disk, tried again for a moment while busy, with `-force` only if asked
(the app never asks); `chpass -oldstdinpass -newstdinpass`; `isencrypted -plist`;
`info -plist`. "Authentication error" becomes `.wrongPassword`, anything else `.io` with
`hdiutil`'s message.

`VolumeStore` keeps `{"version": 1, "volumes": [{"id", "name", "path", "syncApp"}]}`,
paths under the home folder as `~/...`, replaced atomically with mode 0600 in a folder
with mode 0700. A file it cannot read is renamed to `volumes.json.broken-DATE` before the
next write, never overwritten.

### 4.7 Locking (G4)

`LockController` reads the time since the last keyboard, mouse or tablet input on the
Mac every 10 s (`CGEventSource.secondsSinceLastEventType(.combinedSessionState,
kCGAnyInputEventType)`) and locks once per stretch of 10 minutes without input; a stretch that
passed 10 minutes and ended between two checks (input came back, or the check came late) locks
at the next check, from the idle time and the time of the check before (`IdleLockDecider`), up
to one interval early if input in between is no longer visible. While an editor, a viewer or a
volume Safe opened exists, it holds a `ProcessInfo` activity (`userInitiatedAllowingIdleSystemSleep`),
so that App Nap does not hold back the check of a Safe in the background. It also
locks on `NSWorkspace.willSleepNotification`, `screensDidSleepNotification`,
`sessionDidResignActiveNotification` and the distributed notification
`com.apple.screenIsLocked` (delivered even while the app is in the background), and on
Safe > Lock Now. Each lock counts up `lockCount`, which flows that wait in dialogs with
decrypted data read (4.2). Locking:

- closes editors without unsaved changes; an editor with unsaved changes hides its text
  behind a cover (also in the Dock's picture of a minimised window), and shows it again
  only after its password is typed and matches the one kept;
- closes viewers;
- clears the clipboard if it still holds what the app put there, and counts the user as
  away, before the lock actions run, so that an action that finishes at once never shows a
  message during the lock;
- closes the volumes the app opened, without force, off the main thread, also one that
  holds the file of an editor with unsaved changes: the text stays behind the editor's
  cover, and `VolumeFlows.closedOnLock` remembers the mount point. After the user unlocks
  the editor, or at Cmd-S, it offers "Open “NAME” Again", which asks the volume's password
  and attaches it at the same mount point (`DiskImage.attach(..., mountPoint:)`, tested to
  work without an administrator at `/Volumes/NAME` and in the private folder, which is kept
  until then), so the save goes to the same path.
  Before sleep (`willSleepNotification`, `screensDidSleepNotification`) the lock waits up to
  10 s for the detaches, so that the Mac does not sleep with the volumes open. A busy volume
  stays open, and the user is told when they are back: at the first idle check
  after the lock that finds input again (an app in front when it locks never becomes
  active again), on `com.apple.screenIsUnlocked`, or when the app becomes active; when
  Safe is not in front, its Dock icon bounces and the message comes on activation.

### 4.8 Quit

Each editor with unsaved changes asks Save, Don't Save or Cancel (a locked one asks for
its password first). The volumes the app opened are detached without force; if one is
busy, the user chooses between Cancel and Quit Anyway. Then the clipboard is cleared if
it still holds the app's text.

## 5. The format

`../format.md` describes it byte by byte, with a worked example. In short: `Salted__`,
an 8-byte random salt, then AES-256-CBC with PKCS#7 padding; key and IV are the 48 bytes
of PBKDF2-HMAC-SHA512 over the password's exact UTF-8 bytes and the salt with 100,000
iterations. This is `openssl enc -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -salt`, as
`crypt.sh` 1.5 writes it. A wrong password passes the current format's padding check about
once in 256 tries; with the two older AES derivations, which open also tries on every salted
file, about 3 in 256 wrong passwords (14 to 31 of 2000 in the test runs) reach the user as
results Safe could not confirm. `Plausibility` never confirms those, and the app asks the
user about them instead of showing them. The older variants are in section 4.2.

The reference files in `app/Fixtures` come from four generators: OpenSSL 3.0.22 in the
Docker image (current format and every older variant, RC4 through its legacy
provider), `crypt.sh` 1.5 in the same image, macOS's LibreSSL 3.3.6 (current and older
variants), and the app itself. They include non-ASCII passwords, a password full of
shell characters, an empty file, a 1 MB file, a PDF, a PNG, a JPEG, a HEIC picture, files
without an ending, binary files, and texts in ISO Latin-1, MacRoman and UTF-16 in the
current format and older variants. Each text and picture holds a random marker for the
leak test.

## 6. Where decrypted data lives

- **In the app's memory only**, while a window is open: the decrypted `Data`, the text
  in the text view and its undo steps, the PDF document or image, layout caches. Swift
  and AppKit copy these freely, and such copies cannot be wiped; closing the window drops
  them, and the process quitting ends them. macOS encrypts swap.
- **Passwords and keys** are in `SecureBytes`: locked pages, wiped on close and after
  use. Typed passwords also pass through the secure text field's string, which is
  emptied right after the dialog but cannot be wiped. `hdiutil` gets them through a
  pipe, never on a command line or in a message.
- **The clipboard** holds only what the user copies: for this Mac only (not Universal
  Clipboard), marked `org.nspasteboard.ConcealedType` and `TransientType`, cleared after
  60 s, on lock and on quit, if it still holds what the app put there. macOS 26's Spotlight
  clipboard history may keep copied text for hours, and whether it honours those markers is
  not known (testing it would overwrite the owner's clipboard; `acceptance.md` has the step):
  Safe asks before the first copy of each run when the history may be on.
- **On the screen** while a window shows it; `sharingType = .none` keeps it out of most
  screenshots and screen sharing, as a best effort.
- **Never on the disk** when a file is opened, edited, saved or viewed: only ciphertext
  is written (`NAME.crypt_new`, `NAME.crypt.bak`, `NAME.crypt`, conflict copies). The
  exceptions are deliberate:
  - Export writes the plaintext where the user chose, after the warning, through a
    temporary file `NAME (exporting XXXXXXXX).tmp` next to the target; if the app is killed
    or the power fails in between, that visible file is a plaintext copy to delete.
  - New from Folder deletes the checked folder under a hidden name,
    `.NAME.safe-pending-XXXXXXXX`; if the app is stopped during a long delete, the rest of
    the folder stays there, recorded in `pending-deletes.json`, and the next start offers to
    delete it (section 4.6).
  - Encrypt reads an original that is a plain file on the disk; it is deleted after the
    check, but on an SSD its blocks may stay until they are overwritten.
  - New from Folder deletes the plain folder after the check, with the same caveat,
    which the user is told once.
  - Files in an open volume are plain to every process of the user, as on any disk; the
    app closes the volumes it opened on lock and on quit. A disk image is mounted with owners
    ignored, so every account on the Mac counts as the owner of its files: Safe mounts the
    volumes it opens in a folder with mode 0700 in the user's temporary folder, which other
    accounts cannot enter. A volume opened by a double-click in the Finder is mounted by
    macOS at `/Volumes`, where other accounts on the Mac (fast user switching, SSH, a guest)
    can read it while it is open, and so is the new volume while `hdiutil create -srcfolder`
    copies a folder into it. A file encrypted inside a volume
    needs both passwords; its deleted plain original stays readable in the image to anyone
    with the volume's password, which the Encrypt dialog says.
  - macOS keeps copies made from files used in the Finder outside any encryption of the
    app: previews (the Quick Look thumbnail cache in the user's cache folder) of files in an
    open volume and of originals viewed before Encrypt or New from Folder, and the
    Spotlight index of the folder a volume was made from. They outlive the delete and the
    closing of the volume, and only FileVault protects them; the one-time note of the first
    Encrypt or New from Folder says so, and `agent-check.sh` warns when FileVault is off.
  - A sync service has a plain copy of a file or folder that was in a synced folder before
    Encrypt or New from Folder, and keeps it in its trash and version history (Nextcloud 30
    days by default), off the Mac; Time Machine backups and local snapshots keep older copies.
    The Encrypt dialog says so for a file in a synced folder, New from Folder's question for
    such a folder, and the one-time note always.
  - The viewer's PDFKit would run data detectors and Live Text (Vision) over the pages; both
    are switched off.

The leak test (section 7) and the marker search of `acceptance.md` check the first rule.

## 7. Tests

    S=~/Library/Caches/SafeDocker-build/NAME
    swift build --scratch-path $S && swift run --scratch-path $S SafeTests [filter ...]

runs 127 tests in eight suites and exits with 1 if one fails (`--list` names them). It takes
about 4 minutes on an idle Mac, of which the wrong-password tests take one and a half and the
leak test half a minute, and up to 15 on a busy one, where the leak test alone can take several
minutes; so run it in the background, or with a time limit of 20 minutes, and wait for its
summary line. A test skips with a note when something it needs is missing (Docker, Python). The app suite needs
the `Safe` that `swift build` puts next to the runner, which `swift run` alone does not build:
if it is missing or older than its sources, the run ends with "INCOMPLETE" and exits with 1,
unless `--allow-skips` is given.

| Suite | Tests | What it covers |
|---|---|---|
| harness | 5 | the harness itself |
| crypto | 21 | round trips at block boundaries, an independent derivation, the worked example of `format.md`, every reference file, every reference file again with OpenSSL 3 in the Docker image, files made by the app opened by `/usr/bin/openssl` and by OpenSSL 3 and `crypt.sh` in the Docker image, 2000 random wrong passwords against a text (none confirmed, none text that would be offered read only, none called damaged) and 1000 each against a Latin-1 text, a UTF-16 table, a file without an ending, a WebP named `.jpg` and a Word document, strict padding, empty and 1 MB files, UTF-8 and empty passwords, `SecureBytes`, every older variant, wrong passwords against them |
| files | 41 | `Plausibility` (text, pictures, documents, archives, media, other endings, `.key`, text in other encodings against random bytes, short texts with control bytes), `FileKind`, `encryptFile` (original deleted only after the check, kept when the check is made to fail through `CryptFile.testHookFailCheck`, refusals, the size limit, resource forks, hard links), `open` (the right password always opens unusual files, unconfirmed, in the current format and in old AES and RC4 variants: Latin-1, MacRoman, UTF-16, binary; the padding rule for types that cannot be checked; short RC4 text; texts of 15 bytes, unchecked, and the reviewer's wrong password for a PIN; tiny unsalted files; damaged files, cut at 4 KB and 64 KB and inside a block, and their readable part; cut files whose start Safe cannot recognise, exported in part unchecked; old RC4 files of a type Safe cannot check, for export, also the one an AES variant opens by chance with salt 0000000000000003; a short Latin-1 text whose RC4 reading is UTF-8; JPEG and gzip under other names), `save` (`.bak`, a kept `.bak`, conflict, failed check, AES-MD5 and RC4, through a link), `export`, and the leak test |
| selftest | 10 | the self-test with and without network, damaged files, a wrong hash, missing files, a manifest that lost entries or whose salted flag is wrong, a failed self-test stopping encrypt and save, the JSON report; `NoNetwork.enforce` in a child process |
| volumes | 27 | `VolumeStore`, `SyncCheck` (also synced folders), `FolderVerifier`, and `DiskImage` on throwaway images in `$TMPDIR`: create both ways, attach hidden, busy volumes, wrong passwords, change the password, unreadable files, refusals, nothing left attached |
| tools | 4 | `safe-decrypt.py --self-test`, `test_safe_decrypt.py --quick`, `test_scripts.py`, the JSON of `agent-check.sh` |
| applogic | 14 | the window-free logic of the editor and the lock (also a stretch without input that ended between two checks, and macOS's clipboard history), and the text encodings |
| app | 5 | `Safe --version`, `--help` and wrong options, `--self-test`, `--check` (with an empty throwaway volume list), and `Safe --app-tests` |

`Safe --app-tests` (debug builds) runs 147 tests of the app's own logic (since version
0.2.0 also the suite `help`, section 11, and since 0.3.0 the suite `i18n`, section 12): the password
dialogs and the progress panel built but never shown, the password rules (line breaks,
control characters, 511 bytes), the Encrypt, Open and Export flows and the Volumes flows
with stand-in dialogs (including the choices when Safe could not confirm a password, the
wrong-password question for random bytes, read-only text after Continue, nothing shown
after a lock during a question, also with the real `LockController`, unencrypted disk
images, a folder that changes during the check of New from Folder, the list of opened
volumes taken over at the next start, the wait before sleep, and no message during a
lock; since review round 3 also damaged files and Export Readable Part, Export as an Old
RC4 File after the same password twice, "probably not right" for a PDF name, the volume
warning and the hard-link refusal of Encrypt, volumes closed on lock under unsaved changes
and opened again at the same mount point, and the folder whose delete was cut short; since
review round 4 the unchecked readable part after the same password twice, Other Readings from
every question about an unconfirmed result, a text too short to confirm, the notes about
synced folders and copies in Encrypt, the second question before saving an old file accepted
without a check, the paste note for non-Latin passwords, volumes opened in a private folder,
the hard-link refusal and the sync note of New from Folder, the words after Change Password,
and mistyped options), the
same flows with the real core on throwaway files in a child process (an old Latin-1 file,
a file cut at 4 KB, an RC4 `.bin` file, a `.kdbx` cut short, a text cut inside a block and the
RC4 file that AES opens by chance among them, and the real self-test gate over a
damaged reference file), the editor and viewer windows over real files (saving with the kept password and
the `.bak`, all three answers to a conflict and to closing with unsaved changes, the
password wiped on close, the self-test's refusal, the export warning before writing, the
read-only view and the encodings, the byte order mark, a save after the file's volume
closed, the cover on lock and unlocking only with the password, closing on lock, a picture
and a PDF shown from memory, Save in Current Format only when confirmed, a text Safe could
not confirm read only and its first `.bak` kept, export refusing encrypted files and
writing nothing after a lock, no kill ring for Ctrl-K, the other delete-to commands, Edit >
Delete and Cut, Discard My Changes refusing garbage and loading unconfirmed text read only,
answers given after a lock not taken, opening a volume closed on lock again from the
editor, and the viewer's data detectors and document analysis off), the clipboard on a private
pasteboard and the question about macOS's clipboard history, `LockController` (idle lock, items,
actions, clipboard, the user's return, the stretch that ended between two checks, the activity
against App Nap), the Volumes window, the self-test gate, the main
menu and the Services pasteboard. The app creates no window on the screen in this mode: its activation policy
is set to prohibited, windows are never ordered in, and alerts and password dialogs are
answered through the hooks of `DocumentAlerts`. `SAFE_RENDER_DIR` draws the dialogs into
PNG files to check their layout.

The leak test opens a text, a UTF-16 table, a PDF, a PNG, a JPEG and a HEIC reference
file through `CryptFile.open`, draws the PDF with CoreGraphics and with PDFKit (a page and
its thumbnail) and the pictures with ImageIO and with `NSImage`, runs
`Safe --app-tests child:viewer-leak`, which shows the same PDF and pictures in
`ViewerWindowController`s (`PDFView` with `autoScales`, `NSImageView`) that are never put on
the screen, and `child:editor-leak`, which types a marker made at run time into an editor
that is never shown, searches for it, copies it to a private pasteboard, saves, types
again, locks, unlocks and saves again. Then it searches the files changed during the test,
in `~/Library/Caches`, `Preferences`, `Logs`, `Saved Application State`,
`Autosave Information`, `HTTPStorages`, `WebKit`, `Application Support/SafeDocker`,
`$TMPDIR`, the user's cache folder and `/private/tmp`, for the markers in UTF-8 and in
UTF-16 of both byte orders. None may be found.

The Python tests need only Python 3: `python3 tools/test_safe_decrypt.py` (53 tests,
with test files from macOS's LibreSSL and, if Docker runs, from OpenSSL 3 in the image; under
a minute on an idle Mac, up to three on a busy one) and `python3 tools/test_scripts.py` (26
tests, under a minute).

What is not tested automatically: the Finder integration (Services, double-click),
real keyboard and mouse input (whether PDFKit lets a selection be dragged out of the viewer,
for example), the timer and the system notifications that start a lock (the lock itself is
tested), export through the save panel, and anything else that needs a person at the screen. The owner's checklist, `acceptance.md`, covers these, including
the marker search after typing into the editor.

## 8. Build and packaging

`app/scripts/build-app.sh [--release]` (debug without the option):

1. `swift build --triple arm64-apple-macosx13.0` and `--triple x86_64-apple-macosx13.0`
   in `~/Library/Caches/SafeDocker-build/build-app-HASH` (`SAFE_SCRATCH_PATH` to change
   it), one folder per checkout; `lipo -create`.
2. `app/dist/Safe.app`: `Contents/MacOS/Safe`, `Contents/Info.plist` with the version
   from `app/VERSION`, `PkgInfo`, `Contents/Resources/Fixtures`,
   `Contents/Resources/SafeHelp.md` and `SafeHelp.de.md` (a note if one is missing),
   `Contents/Resources/en.lproj` and `de.lproj` (each `.strings` file checked with `plutil -lint`); extended attributes
   removed, because files from a synced folder may carry some that `codesign` refuses.
3. `codesign --force --options runtime --entitlements Resources/Safe.entitlements
   --sign -`, then `codesign --verify --strict`.
4. `Safe --self-test` of the new app, and of its other half under Rosetta (`arch -x86_64`
   on Apple silicon) if Rosetta is installed; a failure stops the build before the zip and
   renames the bundle to `Safe-SELF-TEST-FAILED.app`, so that it cannot be installed by
   mistake (G5).
5. `ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent` into
   `app/dist/Safe-VERSION.zip`, so that the zip holds no AppleDouble (`._`) files, which
   `unzip` would add to the bundle and so break its signature (checked with `unzip -Z1`),
   and its SHA-256 into `app/dist/SHA256SUMS`.

Before it compiles, the script finds a missing `HOME` through the directory service, as
`agent-check.sh` does; it looks for `swift` and `lipo` in the developer folder
(`xcode-select -p`) and stops with "Install the Command Line Tools" without running them if
they are not there, because `/usr/bin/swift` and `/usr/bin/lipo` are stubs that open an install
dialog; and it notes when it runs inside another sandbox (an agent's
command sandbox, for example), where `swift build` cannot sandbox its manifests and Safe
cannot deny itself the network: it tests whether `sandbox-exec -n no-network` can apply the
profile Safe uses, by its exit status (`build-app.sh --check-sandbox` runs only this test).
If the self-test then fails only because Safe cannot deny itself the network inside another
sandbox, the script says so and exits with status 3, without calling the app failed, but the
bundle is renamed to `Safe-NOT-SELF-TESTED.app`. A build
whose self-test fails is renamed to `Safe-SELF-TEST-FAILED.app`; both lose `CFBundleDocumentTypes`, `UTExportedTypeDeclarations`
and `NSServices` (then signed again), so that nothing registers them as the handler of `.crypt`
files. A debug build's zip is `Safe-VERSION-debug.zip`. A first build takes a few minutes; a release build here
took about two, and up to ten on a heavily loaded Mac. Nothing is
written into the repository but `app/dist`, which git ignores. Install, update and removal are in
`INSTALL-AGENT.md`; the agent runs `agent-check.sh` first (Swift 6.0 and the macOS SDK
15.2 or later, which `NSMenu.automaticallyInsertsWritingToolsItems` needs; for an Xcode.app
also its accepted licence, `xcodebuild -license check`) and
`Safe --self-test` and `Safe --check` after building.

Since version 0.3.2 the app also carries its licence (`Contents/Resources/LICENSE`, GPL-3.0-or-later,
copied from the repository's root) and shows its copyright in Safe > About Safe
(`NSHumanReadableCopyright`). A release is made by `app/scripts/make-release.sh`: it runs
`build-app.sh --release`, then `app/scripts/make-pkg.sh`, which makes the installer
`Safe-VERSION.pkg` with `pkgbuild` and `productbuild` and `app/Resources/distribution.xml` (a
per-user install into `~/Applications`, `enable_currentUserHome` only, bundle relocation off,
no scripts, unsigned, as Marina's), copies both files to the names without a version
(`Safe.zip`, `Safe.pkg`, so that `.../releases/latest/download/Safe.zip` always works), writes
`SHA256SUMS` over all four, and unpacks `Safe.zip` once to check its signature and version.
`install-safe.sh` at the repository's root installs from the latest release (or, with
`--from-source`, from a build) and uninstalls; `tools/test_scripts.py` tests it against a
stand-in release in a throwaway folder (`SAFE_RELEASE_DIR`, `SAFE_APPS_DIR`). Publishing is
`publishing.md`.

## 9. Deviations from building-plan.md

Every signature of sections 3 and 3.1 is there, and code written against the plan still
compiles: the changes to them are additions, `OpenedFile.check` and two more `CryptError`
cases (deviations 4, 23 and 30), and parameters or results that callers may leave out,
`ExportController.export(..., note:)` with a default of nil, `LockController.lockNow(beforeSleep:)`
with a default of false, and `ClipboardGuard.copy` returning whether it copied, a discardable
result (deviations 25, 36 and 47). The differences:

1. **Idle time** (4.9): `.null` as event type reports the time since start-up on
   macOS 26.3, not since the last input, so `LockController` uses `kCGAnyInputEventType`
   (`CGEventType(rawValue: ~0)`). The plan now says so too.
2. **Layout** (2): the editor's and the lock's window-free logic is in
   `SafeCore/AppLogic/` (`EditorLogic.swift`, `LockPolicy.swift`), so that `SafeTests`
   can test it. Helper files the plan did not name: `Files/FileIO.swift`,
   `Volumes/Hdiutil.swift`, `Finder/RouterFlows.swift`, `Prompts/Alerts.swift`,
   `Editor/EditorViews.swift`, `Viewer/DocumentAlerts.swift`,
   `Volumes/VolumeController.swift`, `Volumes/VolumeFlows.swift`. `Crypto/Legacy.swift`
   is internal.
3. **Tests of the app** (7): `SafeTests` cannot link the app, an executable, so the
   app's own tests live in the app and run with `Safe --app-tests` in debug builds;
   `SafeTests` runs that as one of its tests. The flows are generic over the password
   and the opened file and take their dialogs from an environment, so they run with
   stand-ins.
4. **Additions to the public interface** of `SafeCore`: `CryptFile.writeRefusal` (the
   app's self-test gate, so that the core itself refuses to write) and
   `CryptFile.testHookFailCheck` (the test hook of 7.1); `OpenedFile.check` and
   `PasswordCheck` (whether the password was confirmed, section 4.2);
   `CryptFile.largestFileToEncrypt` and `tooLargeMessage`; `CryptFile.exportTemporaryName(for:)`;
   `FileKind.isTextName`; `Plausibility.shortestUncheckedText` and `looksLikeText`;
   `TextCoding`;
   `FolderVerifier.firstDifference`; `DiskImage.attachment(of:)` and
   `DiskImage.privateMountPoint()`; `VolumeRecord.init` and `.url`; `VolumeStore.file`,
   `.loadError`, `abbreviatingHome` and `expandingHome`; `SelfTestReport.init`; the
   types of `AppLogic`. `VolumeStore.add` and `update` refuse a second entry with the
   same id or path (`.alreadyExists`).
5. **Saving** (5.3, step 4): the new `.bak` is written from the bytes read in step 1
   (whose hash was just checked) as a new file, instead of copying `NAME.crypt`; same
   content, mode 0600, flushed.
6. **Encrypting** (5.3, R1): the rename to `NAME.crypt` refuses an existing file
   (`RENAME_EXCL`), and the original is deleted only if it has not changed during the
   encryption.
7. **Opening** follows a symbolic link, and a name ending in `.crypt.bak` is opened
   with the original name without `.crypt.bak`. **Export** writes through a temporary
   file next to the target.
8. **Disk images** (4.8): `createFromFolder` adds `-size` (twice the folder, at least
   1 GB, so the volume has room to grow) and `-anyowners -skipunreadable` (so `hdiutil`
   never asks for an administrator; a file left out is then found missing by the check,
   and the folder is kept). `attach` adds `-plist -noautoopen`. `detach` resolves the
   image's disk first and detaches that, so a second try still works after a try that
   unmounted the volume but could not eject the disk. The check's mount point is in
   `$TMPDIR` inside a folder with mode 0700. Add Existing also takes `.sparseimage`.
9. **Command line** (4.1): also `--help`, and `--app-tests` in debug builds;
   `SAFE_VOLUME_LIST` for tests. `--self-test` also prints the version and the fixtures
   folder; `--check` also `app`, `manifestFound` and `volumeList`.
10. **Self-test** (3, G5): besides decrypting every reference file to its length and
    hash, it encrypts the plaintext of every reference file in the current format again
    with its salt and requires the same bytes, and checks a fresh round trip. Its
    wrong-password check uses six fixed near misses, so that it gives the same answer
    every time; the 2000 random passwords are in `SafeTests`. While the self-test runs,
    writing is refused too, not only after it failed.
11. **Viewer** (4.6): also "Unlock PDF" for PDFs with a password of their own, and
    "Save in Current Format" in the window. The password is kept only for files in an
    older format.
12. **Volumes window** (2, 4.8): its dialogs are modal alerts and forms, not sheets.
    "Open" shows the volume in a Finder window (`NSWorkspace.open`).
13. **Services** (4.2): `NSServices` cannot exclude `.crypt` files from "Encrypt with
    Safe" (it is offered for `public.data`); the router refuses them with a message.
14. **Reference files** (5.4): RC4 files also come from OpenSSL 3 in the Docker image,
    through its legacy provider, besides LibreSSL.
15. **Leak test** (7.3): it does not read all of `~/Library`: the folders of other apps
    can bring up permission dialogs and cloud folders download their files. It searches
    the folders listed in section 7, only files changed during the test, with a time
    limit.
16. **Build** (6): `build-app.sh` builds debug without `--release`.
17. **Extras not in the plan**: Safe > Lock Now (Ctrl-Cmd-L); the Dictation and Emoji
    menu items off; the editor's shortcuts handled by its window, so they work whatever
    the menu holds; at Quit, a choice to leave a busy volume open.
18. **Plausibility** (3, 5.1, after the requirements review): the plan's comment "known
    binary types need their magic bytes" covered PDF and pictures only. Now the first bytes
    of a known type count for any name (PDF, pictures, ZIP-based documents, the Office
    compound file, archives, media, RTF, SQLite); ZIP, Office, archive and media endings
    are checked like pictures; other endings count with UTF-8 text of at least 32 bytes.
    The viewer also shows WebP, BMP and AVIF, which macOS draws from memory.
19. **The editor's text** (3.1, 4.5): besides the fixed
    `init(opened:text:password:)`, `init(opened:text:password:coding:readOnlyNote:)` for
    text in another encoding and for the read-only view of 4.4; the router hands the
    editor an `EditorText`. `EditorWindowController.allowEditing()` ends the read-only view.
20. **Encrypt** (4.3): also refuses disk images and files larger than 1 GB.
21. **Tests** (7.3): the leak test also draws the PDF with PDFKit (`PDFDocument`, a page
    and its thumbnail) and the pictures with `NSImage`, so `SafeTests` links AppKit and
    PDFKit, and it runs `Safe --app-tests child:viewer-leak`, which shows the reference PDF,
    PNG, JPEG and HEIC in viewer windows that are never put on the screen, and
    `child:editor-leak` (typing, search, copy, save, lock, unlock), before the search. It
    searches for the markers in UTF-16 too. The runner fails when the app suite cannot run
    (section 6 of the plan named only `swift run SafeTests`, which skipped it).
22. **Older variants** (5.2, after review round 2): the plan accepted only plausible
    results from older variants, so an old file whose content does not fit its name (a
    Latin-1 text, a binary file without an ending) was refused with the right password,
    against G5 and 4.4. Now such AES results, and RC4 results that are text in another
    encoding, go to the user unconfirmed, and `CryptFile.Candidate` chooses between several
    (section 4.2). The plan now says so. RC4 files of a type Safe cannot check whose length is
    whole blocks or that have no salt still do not open in a window: RC4 gives a result
    with any password. Since review round 3 they can be exported (deviation 31).
23. **Wrong passwords** (4.4): for a text name, a result that is neither UTF-8 nor text in
    another encoding is reported as probably a wrong password, with Export Anyway, instead
    of being offered read only (since review round 3 also a result for a name whose type has
    fixed first bytes that matches no known type, deviation 32); a salted file that is not whole blocks gives
    `CryptError.wrongPasswordOrDamaged` (a new case) and a message that names damage.
24. **Saving** (5.3, step 4): for a file whose password Safe could not confirm, the editor
    keeps the `.bak` of its first save on later saves (`CryptFile.save(_:over:password:
    replacingBackup:)`, an addition to the interface), and refuses to save until Allow
    Editing whatever note it was given.
25. **Locking** (4.9): `LockController.lockCount`, read by the router and Export around
    their dialogs; `lockNow(beforeSleep:)`, before sleep the volumes are closed within up to
    10 s before the handler returns; the clipboard is cleared and the user counted as away
    before the lock actions run. The list of volumes the app opened is kept in
    `opened-volumes.json` and taken over at the next start
    (`VolumeController.adoptOpenedVolumes`). Since review round 1, `LockController.onUserBack`
    and `userIsBack()` tell the volumes when the user is back, for the report of a busy
    volume; for tests it has `idleSeconds`, `checkIdle()`, `registeredItems`,
    `isAwaitingReturn` and `isLockingForSleep`.
26. **New from Folder** (4.8): the folder is listed before the check and moved aside under
    a hidden name before it is deleted, and kept if it changed; the volume is added to the
    list after the delete.
27. **Passwords** (4.3): new passwords with a line break or another control character, or
    longer than 511 bytes, are refused; line breaks at the end of a password typed to open
    a file are dropped.
28. **Export** (4.7): refuses names ending in `.crypt` or `.crypt.bak` and the encrypted file
    under any name; proposes the Desktop for a file in an open volume; writes nothing after a
    lock; its temporary file is visible. **Encrypt** (4.3) refuses files with a resource fork
    and encrypts unencrypted single-file disk images. `.key` is no longer checked as a ZIP
    document. The viewer's `SafePDFView` writes nothing through the Services way of handing
    out a selection.
29. **Build** (6): `build-app.sh` also self-tests the Intel half under Rosetta, renames a
    build that fails its self-test, zips without extended attributes, and notes a nested
    sandbox; `agent-check.sh` also checks macOS 14.5 for building (`macos_for_build`) and
    finds the system's tools with a minimal `PATH`. `NoNetwork.enforce` says when Safe runs
    inside another sandbox.
30. **Damaged files** (4.4, 5.1, after review round 3): a current-format file cut short at a
    block boundary failed the padding check and was called a wrong password. Now
    `OpenSSLFormat.attemptCurrent` also returns the first blocks when the padding is wrong,
    `CryptFile.decrypt` throws `CryptError.damaged` (a new case) when they look like the start
    of such a file, and `CryptFile.readablePart` (an addition to the interface) gives
    everything but the last block for Export Readable Part. Older variants are not checked
    this way. `tools/safe-decrypt.py` gives the same diagnosis and has `--salvage`.
31. **Old RC4 files Safe cannot check** (G5, 5.2): after the same password is refused twice in
    a row, the router offers Export as an Old RC4 File, with `CryptFile.mayBeOldRC4` and
    `CryptFile.decryptOldRC4` (additions to the interface); the result is never shown or
    saved. The router keeps a keyed digest of the last refused password while it asks.
32. **Plausibility** (5.1, 5.2, 4.4): the current format confirms a picture (JPEG included)
    or gzip whatever the name; `Plausibility.needsMagicBytes` (an addition) makes a result
    that matches no known type for a PDF, ZIP-based, Office, archive, media, RTF or SQLite name
    "probably not right"; a short RC4 text no longer counts as text when kept results are
    compared, so it cannot beat the right current result of a short Latin-1 text; for a body
    above 4 KB, RC4 first decrypts 4 KB and goes on only if the result could be kept.
33. **Editor** (4.5): no kill ring (`delete(_:)`, the delete-to commands and Cut delete with
    `deleteBackward(_:)`; `yank` does nothing); Discard My Changes applies the rules of
    opening to a result Safe cannot confirm and resets the kept `.bak`; an answer given after
    a lock is not taken; `offerToReopenVolume()` and the hooks `closedVolumeName` and
    `reopenVolume` for a volume closed on lock.
34. **Locking** (4.9): the plan kept a volume open under an editor with unsaved changes; G4
    has no such exception, so it is closed like the others, and `VolumeFlows.closedOnLock`,
    `closedVolume(holding:)` and `reopen(holding:)` open it again at the same mount point.
    `closeAppOpenedVolumes` lost its `keeping:` parameter, and `VolumeLockGlue.unsavedFiles`
    is gone. The plan now says so.
35. **New from Folder** (4.8): the folder being deleted is recorded in `pending-deletes.json`
    (`PendingDeletesFile`), and a start that finds it offers to finish the delete
    (`VolumeFlows.offerToFinishDeletes`, two more functions in `VolumeEnvironment`). The
    one-time note also names previews and the Spotlight index.
36. **Encrypt** (4.3, R4): refuses files with other names (hard links), in the core
    (`CryptFile.hardLinksMessage`, an addition) and in the router, and warns in the password
    dialog when a file is inside an open volume. `RouterEnvironment` has `linkCount`,
    `volumeMountPoints`, `readablePart`, `mayBeOldRC4`, `decryptOldRC4` and
    `passwordDigest`, and `exportData` a note for the export warning
    (`ExportController.export(..., note:)`).
37. **The format's code** (5.1, G5): CBC is named (`CCCryptorCreateWithMode` with
    `kCCModeCBC`) instead of CCCrypt's default, and the last block is decrypted first.
38. **Command line** (4.1): `configuration` in `--self-test` and `--check`,
    `volumeListError` in `--check`, ` (debug build)` after the version of a debug bundle;
    the message of a failed start is printed as text.
39. **Build and checks** (6, 8): the sandbox note tests the exit status of
    `sandbox-exec -n no-network` (`--check-sandbox`), a self-test that cannot run inside
    another sandbox ends with status 3, a failed build loses its document type and services,
    a debug zip is named `Safe-VERSION-debug.zip`; `agent-check.sh` finds a missing `HOME`
    through the directory service and reports a copy in `/Applications` as `other_copy`.
40. **Damaged files** (4.4, 5.1, after review round 4): a file cut inside a block was called a
    wrong password, and one whose start Safe cannot recognise (a `.bin`, a `.kdbx`) could not be
    recovered. `OpenSSLFormat.attemptCurrent` also gives the start of a body that is not whole
    blocks, so such a file is `.damaged` when its start looks right; the readable part drops a
    partial block together with the last whole one. `CryptFile.mayBeCutShort` and
    `CryptFile.readablePart(at:password:checked:)` (additions) export the readable part of a cut
    file whose start Safe cannot recognise, unchecked, from the question after the same password
    twice and from Other Readings. `RouterEnvironment.readablePart` takes `checked`, and
    `RouterEnvironment.mayBeCutShort` is new. `tools/safe-decrypt.py` gives the same diagnosis
    and `--salvage --force`.
41. **Other readings** (4.4, G5, after review round 4): with about 1 in 85 passwords, the right
    one of an old RC4 file included, an AES variant passes its padding check, and the result went
    to "Is this the right password?" every time, so that Export as an Old RC4 File was never
    reached. The questions about a result Safe could not confirm now offer Other Readings for a
    text name or a type Safe cannot check: the file read as an old RC4 file or as a damaged one,
    for export only. The plan now says so.
42. **Short texts** (5.1, 5.2, after review round 4): a text shorter than 32 bytes must also be
    free of control bytes but tab, line feed, form feed and carriage return, and a text of 15
    bytes from an AES variant with one byte of padding is `unchecked`, not confirmed: before, about
    1 in 550,000 wrong passwords opened such a file as text. The plan now says so.
43. **Saving an old file accepted without a check** (4.4, G5, after review round 4): G5 asks to
    offer saving an old file in the current format, plan 4.4 forbade it for results accepted
    without a check. Files that can only be exported now offer "Save in Current Format...", which
    saves only after a second question that names the risk; the file as it was becomes
    `NAME.crypt.bak`. A picture viewed after "Safe could not confirm the password" and a file
    exported as an old RC4 file still cannot be saved in the current format: that is left to the
    owner. The plan now says so for the first.
44. **Copies that outlive the delete** (R1, R4, after review round 4): the Encrypt dialog names
    the sync service's trash and version history for a file in a synced folder, and its first
    time the copies on an SSD, in previews, Spotlight, Time Machine and snapshots; New from
    Folder's question names the sync service for a synced folder, and its one-time note names
    sync services and Time Machine too. The note is told once by whichever comes first
    (`CopiesNote`, a new defaults key). Additions: `SyncCheck.isInSyncedFolder`,
    `RouterEnvironment.isInSyncedFolder`, `toldAboutCopies` and `setToldAboutCopies`,
    `VolumeEnvironment.isInSyncedFolder` and `filesWithOtherNames`.
45. **Volumes** (4.8, after review round 4): Open mounts a volume at
    `$TMPDIR/safe-volume-UUID/NAME` (a folder with mode 0700) instead of `/Volumes`, where every
    account on the Mac could read it, because disk images are mounted with owners ignored. The
    other way, `-owners on` with a volume root of mode 0700, was not chosen: it can lock a user
    out of a volume made on a Mac where their user number differs. New from Folder refuses a
    folder with a file that has a name outside it (a hard link), and `FolderSnapshot` lists the
    number of names. After Change Password the user is told that an old copy of the volume still
    opens with the old password, instead of "only with the new password".
46. **Locking** (4.9, after review round 4): the idle time is read every 10 s, not 30 s; a
    stretch that ended between two checks locks at the next one
    (`IdleLockDecider.shouldLock(idleSeconds:at:)`, an addition); while an editor, a viewer or a
    volume opened by Safe exists, `LockController` holds an activity against App Nap
    (`keepChecking`, `hasOpenVolumes`, `now`, `beginActivity` and `endActivity`, additions, and
    `isKeepingChecking` for tests).
47. **Clipboard** (4.5, after review round 4): if macOS may keep a clipboard history, the first
    copy of each run asks first (`ClipboardGuard.copy` returns whether it copied;
    `ClipboardPolicy.historyMayBeOn`, an addition).
48. **Passwords** (4.3, G3, after review round 4): a new password with letters of a non-Latin
    script or emoji is taken only when given again after a note that it would have to be pasted
    (`PasswordPrompt.needsPasting`); secure text fields take only Roman input sources.
49. **Viewer** (4.6, after review round 4): data detectors and document analysis (Live Text) of
    `PDFView` are off.
50. **Self-test** (G5, after review round 4): the manifest must cover every generator, every
    variant, salted and unsalted files, and every reference file in the folder, and its
    `salted` flag must fit the file; a cut-down manifest passed before.
51. **Command line and scripts** (4.1, 6, 8, after review round 4): `--check` reports
    `pendingDeletes`; mistyped options get the usage instead of starting the app;
    `agent-check.sh` reports `pending_deletes`, checks the licence of an Xcode.app and no longer
    tells a release install to use a checkout; `build-app.sh` finds a missing `HOME`, checks the
    developer folder without running Apple's stubs, and renames a build whose self-test could not
    run to `Safe-NOT-SELF-TESTED.app`. The app test with real disk images keeps its list of
    pending deletes in memory and gives its volumes names of their own.
52. **Help, tooltips and shortcuts** (version 0.2.0, not in the plan): a Help menu and help
    window (section 11), "?" buttons, tooltips on every control, the View and Volume menus,
    Return and Delete in the volume list, zooming pictures in a scroll view, and
    `helpFound` in `--check`. The plan's lean main menu (4.5) stays: no Spelling,
    Substitutions, Writing Tools, Services, Print or Share, and no Use Selection for Find.

53. **Two languages and Settings** (version 0.3.0, not in the plan): every text through
    `L`/`Lp`/`LKey` with the tables of `en.lproj` and `de.lproj`, `SafeHelp.de.md`, Safe >
    Settings with the language, `HelpSection.settings` (a new section of the help, so the help
    has eleven), `languages` in `--check` and `helpFound` for both languages, `CryptError.io`
    messages of the core in the chosen language, `FileIO.message` replaced by whole sentences
    and `FileIO.reason`, `CryptFile.tooLargeMessage` taking an optional name, the Edit menu's
    guard by identifier rather than English title, Escape given to Cancel explicitly, and
    `AppleLanguages` written into Safe's own defaults for what AppKit draws (section 12). The
    count texts "Encrypt %ld files" and "%ld bytes" have singular forms now ("1 byte").

## 10. Review

After the integrated build (WP6), the app went through four rounds of review, each followed by
a round of fixes (WP7), and then this final pass. The reviewers worked on clones of the branch,
with throwaway files, images and passwords, never with the owner's files. Round 1 checked the
build against the requirements. Rounds 2 to 4 each had four reviewers, one per lens:

- **requirements**: G1 to G5 and R1 to R4 with every Done-when and the accepted proposed
  points, sections 4 and 5 of the plan, and the earlier findings again;
- **security and plaintext leaks**: the disk, logs, the clipboard, crash reports, window
  restoration, Spotlight, temporary files, command lines, child processes, the passwords given
  to `hdiutil`, wrong passwords, the deletes after Encrypt and New from Folder, saving, locking;
- **build and install as an agent would**: a clean clone, `INSTALL-AGENT.md` followed step by
  step into a throwaway Applications folder, nested sandboxes, failed self-tests, the zip;
- **crypto and long-term compatibility** (G3, G5): the format, the older variants, wrong
  passwords, damaged files, `tools/safe-decrypt.py` and `../format.md`.

| Round | Findings | High | Medium | Low | Fixes |
|---|---|---|---|---|---|
| 1 | 16 | 1 | 4 | 11 | commit `fb3abc1` |
| 2 | 38 | 2 | 9 | 27 | commit `b9f790f` |
| 3 | 33 | 1 | 12 | 20 | commit `4e3b78d` |
| 4 | 31 | 0 | 13 | 18 | commit `0cfa5b9` |

What was found and fixed, by theme (deviations 18 to 51 name the changes one by one):

- **The right password refused.** The high finding of round 1, and one of round 2 for the older
  variants: a text in ISO Latin-1, a UTF-16 table or a binary file without an ending was called
  a wrong password, because its content did not look like its name. Now every result whose
  padding is right, and that could be right, goes to the user unconfirmed (`PasswordCheck`,
  section 4.2). Later rounds added files cut short (`CryptError.damaged`, Export Readable Part),
  old RC4 files Safe cannot check (Export as an Old RC4 File, Other Readings) and short texts.
- **A wrong password shown as if it were right.** More known types; for a type Safe cannot
  check, more than one byte of padding; "The password is probably not right" for content that is
  not text, or lacks the first bytes of its type; read only, with the first `.bak` kept, for
  anything unconfirmed; short RC4 results and texts of 15 bytes never confirmed. In the tests no
  wrong password of 2000 against a text is confirmed, offered read only or called damaged, and
  none of 1000 against each of five unusual files is confirmed.
- **Passwords.** The other high finding of round 2: a pasted line break, or more than 511 bytes,
  would have made a file unreadable for `openssl` and `crypt.sh`; both are refused for new
  passwords. A password that needs pasting (another script, emoji) gets a note.
- **Plaintext leaks.** The high finding of round 3: Ctrl-K and its kin put deleted text into
  AppKit's kill ring, which Ctrl-Y pasted anywhere in the process, also after a lock. Also
  macOS 26's clipboard history, PDFKit's data detectors and Live Text, a hidden temporary file of
  Export, volumes at `/Volumes` readable by other accounts, hard links and resource forks, the
  plain copies that sync services, previews, Spotlight and Time Machine keep (now named to the
  user), and a folder that New from Folder stopped deleting (`pending-deletes.json`).
- **Locking** (G4). Dialogs open across a lock (`lockCount`); a volume left open under an editor
  with unsaved changes (now closed, and opened again at the same place); the wait before sleep;
  the idle check every 10 s, with a stretch that ended between two checks; App Nap; the report
  of a busy volume; the volumes the app opened, kept across a crash.
- **Build and install.** Agents whose commands run in a sandbox; a test command that skipped the
  app suite; the branch `safe-app` in `INSTALL-AGENT.md`; a Mac without `git` or `HOME`;
  AppleDouble files in the zip; the Intel half under Rosetta; builds that failed or skipped their
  self-test, now disabled; the Xcode licence; mistyped options that would have opened a window;
  `--check` fields for the agent.
- **The format's code and the tools.** CBC named, not left to CCCrypt's default; the last block
  first; the self-test's coverage of the manifest; `tools/safe-decrypt.py` giving the answers
  the app gives.

Left to the owner, or not done (each is recorded where it applies):

1. Whether "10 minutes without use" (G4) means input anywhere on the Mac, as now, or use of Safe
   itself (round 3). Reading it as use of Safe would also close a clean text that the user reads
   beside another app.
2. Whether Safe, when `sandbox_init` fails, quits, as the plan says and the app does, or starts
   without its network block (round 1): a change of security policy.
3. Saving in the current format a picture viewed after "Safe could not confirm the password",
   and a file exported as an old RC4 file (deviation 43, round 4).
4. Not built, with a way out in `../format.md`: a choice in the app for an old AES file of a type
   Safe cannot check whose result ties with the current format (about 1 in 4,000 such files;
   `safe-decrypt.py --variant`), and the damage check for the older AES variants
   (`safe-decrypt.py --salvage`). `--check` still lists every attached disk image;
   `INSTALL-AGENT.md` tells the agent not to repeat their paths.
5. Checked only by hand (`acceptance.md`): the Finder integration, the system notifications that
   start a lock, a real sleep, Open “NAME” Again after a lock with a real volume, the private
   mount point in the Finder's sidebar, dragging selected text out of the PDF viewer, Live Text on
   a PDF that is only pictures, and whether Spotlight's clipboard history honours the concealed
   marker. The check of the Xcode licence in `agent-check.sh` has not run, for want of an
   Xcode.app whose licence is not accepted.
6. Known gaps: a text in ISO Latin-1 or UTF-16 asks "Safe could not confirm the password" at
   every opening, because saving keeps its encoding; a text that is not UTF-8 and shorter than
   32 bytes gets "probably not right" and Export Anyway, not Open Read-Only; a volume opened by a
   double-click in the Finder, and a new volume while `hdiutil create -srcfolder` fills it, are
   at `/Volumes`, where other accounts can read them while they are open; one app test failed
   once in round 3 while another job loaded the Mac, and has passed in every run since (the tests
   with deadlines of 3 to 5 s are the likely cause); `INSTALL-AGENT.md` can be followed only after
   the owner pushes `safe-app` to GitHub, and until then the agent stops at step 4.2.

The final pass found the code as this document describes it, apart from corrections to this
document (line counts, the CBC call, the RC4 choices, the rate of wrong passwords that reach the
user, run times, deviations 4, 8, 25 and 46), to `../format.md`, `acceptance.md` and
`tools/README.md`. All tests passed: 127 of `SafeTests` (Docker included), 124 of
`Safe --app-tests`, 53 of `tools/test_safe_decrypt.py` and 26 of `tools/test_scripts.py`; the
universal release build passed its self-test in both halves.

## 11. Help, tooltips and keyboard shortcuts (version 0.2.0)

The owner asked for a good help function, much hover help, and keyboard shortcuts for the
common functions. Version 0.2.0 adds them without changing what the app does with files.

### 11.1 The help

`app/Resources/SafeHelp.md` is the owner's manual, in plain English, in ten sections: the
idea behind Safe (two kinds of protection, decrypted content only in memory and why,
standard formats and the ways out, no network, locking, no password recovery, what Safe does
not protect against), passwords, encrypting a file, opening and editing a text file, viewing
and exporting, volumes (with the Finder's view shortcuts for a volume's window), locking, old
files and the long term, keyboard shortcuts (with how to give the Finder's services a
shortcut in System Settings), and when something goes wrong. Each section heading carries an
anchor (`## Volumes {#volumes}`), the raw value of `HelpSection`.

- **Bundled and found:** `build-app.sh` copies it to `Safe.app/Contents/Resources/SafeHelp.md`.
  `HelpBook.resourceURL` is that file inside an app bundle, and in a debug build run outside
  one (`swift run`, the tests) `app/Resources/SafeHelp.md` of its source tree, as
  `AppInfo.fixturesDirectory` does for the reference files. If the file is missing or
  unreadable, the window shows a short note with the essentials instead (`HelpBook.fallback`).
  `Safe --check` reports `helpFound`.
- **Drawn natively:** `HelpRenderer` reads the small Markdown subset the file uses (headings,
  paragraphs, lists, tables with tab stops, indented code, inline code and bold) into an
  `NSAttributedString` for a read-only `NSTextView`. No `WKWebView` or anything else that
  could load remote content (Safe denies itself the network at start), and no Apple Help
  Book: `hiutil` and Help Viewer are not needed. `NSAttributedString(markdown:)` was not used,
  because AppKit text views do not lay out its block structure.
- **The window** (`HelpWindowController.shared`, one for the app): a list of sections on the
  left that follows the scrolling, the text on the right, and a search field (`TextSearch`,
  as in the editor; Edit > Find and Cmd-F/G go to it). It is an `NSPanel` with
  `worksWhenModal`, so that help opened from the "?" of a password dialog can be read and
  scrolled while the dialog waits. Its text view has a context menu of Copy and Select All
  only and offers no Services.
- **The "?" buttons** (`HelpButton`, `bezelStyle = .helpButton`): the Volumes window
  (Volumes), the editor's status line (Opening and editing; Locking while the text is
  covered), the viewer's bar (Viewing and exporting), and through `NSAlert.showsHelp` with
  `helpAnchor` and a shared delegate the password dialogs (Passwords) and the New Empty form
  (Volumes).
- **Help menu:** Safe Help (Cmd-?) opens the window at the top; The Idea Behind Safe,
  Keyboard Shortcuts and When Something Goes Wrong open it at those sections. macOS adds its
  menu search field at the top of the Help menu, as for every app; it searches the menus.

### 11.2 Tooltips

Every button, checkbox, text field, search field, table, column header and status line of
the Volumes window, the editor (search bar, read-only note, lock cover), the viewer, the
password dialogs, the New Empty form and the help window has a tooltip of one or two
sentences that says what it does and what may surprise (Close on a busy volume, Remove from
List keeps the image, Change Password's old copies, Export writes an unencrypted copy).
Controls with a shortcut end with it, for example "(⌘↩)". Tooltips with changing content (the
status lines, the cells of the volume list with the mount point) keep it. `ToolTipAudit`
states the rule the test checks: every `NSControl` but fixed labels, scroll bars and pictures;
status labels are marked with the identifier `status`. Fixed explanatory labels (the Volumes
window's introduction, the lock cover's sentence) are no longer selectable, which they never
needed to be.

### 11.3 Keyboard shortcuts

Every shortcut is unique across the menu bar (tested). The new ones:

| Shortcut | Item | Why this one |
|---|---|---|
| ⌘N | Volume > New Empty Volume... | the file side has no New: files are made in other apps and encrypted afterwards |
| ⇧⌘N | Volume > New Volume from Folder... | the other kind of new volume, next to ⌘N |
| ⇧⌘A | Volume > Add Existing Volume... | A for Add; free in this app (the Finder's Go to Applications does not apply here) |
| ⌘↩ | Volume > Open Volume | ⌘O is File > Open; ⌘↓, the Finder's Open, was not used (see below) |
| ⌘E | Volume > Close Volume | ⌘E ejects a disk in the Finder, and closing a volume ejects it; free here, because Use Selection for Find is left out on purpose (it writes the system-wide find pasteboard) |
| none | Volume > Change Password... | rare, and a slip of the finger should not start it |
| none (Delete in the list) | Volume > Remove from List | ⌘⌫ was not used (see below); it asks first in any case |
| ⌘+ and ⌘= | View > Zoom In | as in Preview and every app; ⌘= through a hidden item with `allowsKeyEquivalentWhenHidden` |
| ⌘- | View > Zoom Out | the same |
| ⌥⌘0 | View > Actual Size | ⌘0, Preview's Actual Size, has been Window > Volumes since 0.1.0 |
| ⌘9 | View > Zoom to Fit | as in Preview |
| ⌥⌘↓, ⌥⌘↑ | View > Next Page, Previous Page | arrows for pages, with Option-Command, which text fields and `PDFView` do not use themselves; for PDFs only |
| ⌘? | Help > Safe Help | the standard key of an app's help (Shift-Command-/) |

Unchanged: ⌘O Open, ⇧⌘E Encrypt File, ⌘W Close, ⌘S Save, ⌥⌘E Export, the Edit menu (⌘Z,
⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A, ⌘F, ⌘G, ⇧⌘G), ⌘M Minimize, ⌘0 Volumes, ⌃⌘L Lock Now, ⌘H, ⌥⌘H, ⌘Q.

- **No text-editing keys.** A menu item takes its key equivalent even while it is disabled
  (tested with AppKit: `NSMenu.performKeyEquivalent` returns true and does nothing), so a
  Volume item on ⌘↓ or ⌘⌫ would have stopped Command-Down Arrow (to the end of the text) and
  Command-Delete (delete to the start of the line) in the editor and in every text field. A
  test refuses such shortcuts.
- **The Volume menu** is between View and Window. New Empty, New from Folder and Add Existing
  work from any window and bring the Volumes window to the front first. Open, Close, Change
  Password and Remove from List act on the selected volume, and are enabled only while the
  Volumes window is the key window and the action applies, by the same rule as its buttons
  (`VolumesWindowController.canPerform`), so that a shortcut typed in an editor never acts on
  a volume.
- **The View menu** goes to the first responder; only `ViewerWindowController` answers its
  actions (`ViewerCommands`), so it is off in every other window. Next and Previous Page are
  on only for a PDF with a page in that direction.
- **Keys inside windows:** Return and Delete in the volume list; in the editor's search field
  Return and Shift-Return (next, previous) and Escape; Escape closes the viewer; Return on the
  lock cover is Show Text; ⌘D is Don't Save in the question before closing.
- **The Finder's services** get no default shortcut in `Info.plist`: service shortcuts are
  global and would collide with other apps. The help explains how to set one in System
  Settings > Keyboard > Keyboard Shortcuts > Services.

### 11.4 Tests

The suite `help` of `Safe --app-tests` (10 tests): the Help menu is the last menu and
`NSApp.helpMenu`, Safe Help is Cmd-?, its topics open their sections; no shortcut twice and
none on a text-editing key; every menu shortcut is in the help's table with its item, and the
table names none the menu lacks; the Volume menu's items, shortcuts and enabling (not in
front, no selection, open, closed), an item doing what its button does, Return and Delete in
the list; the help file found with every section, and the note when it is missing; the
renderer; the help window's sections, scrolling to a section and searching; each "?" button
and alert "?" opening its section; a tooltip on every control of the Volumes window, an
editor (with its search bar, and locked), a picture and a PDF viewer, the password dialogs,
the New Empty form and the help window, and the shortcuts at the end of the Volumes buttons'
tooltips; the View menu zooming a picture and a PDF and turning PDF pages. The main-menu test
of the suite `shell` now expects the menus Safe, File, Edit, View, Volume, Window and Help.
`SafeTests` checks `helpFound` in `--check`.

What only the owner can check (`acceptance.md`, section 10): how the help window, the "?"
buttons and the tooltips look and read on the screen, the shortcuts with a real keyboard, and
the help opened from a password dialog. The tests draw the windows off the screen; with
`SAFE_RENDER_DIR` set they write PNG files of the help window and the other windows.

## 12. Two languages and the Settings window (version 0.3.0)

The owner asked for German beside English, "and a German keyboard to go along with it", with
the language chosen in Settings. Version 0.3.0 adds that without changing what the app does
with files.

### 12.1 How texts are looked up

Every text that the user sees goes through one of three functions in
`SafeCore/Localization.swift`:

- `L("English text", args...)`: the key is the English text itself, with `%@` for a piece of
  text and `%ld` for a number. German may put the pieces in another order with positions
  (`%1$@`, `%2$ld`).
- `Lp(count, "one form %ld", "other form %ld", args...)`: the singular when the number is 1,
  the plural otherwise, which is the rule of both languages ("1 Datei", "3 Dateien").
- `LKey("English text")`: marks a key whose text is looked up later with
  `Localization.string`, for titles that change with the language after they were made (the
  menu bar, the Volumes window's buttons).

A key may start with a context, `"[state] Open"`, when the same English words need two German
ones (the state "Geöffnet" beside the button "Öffnen"); English shows the text after it.

The tables are `app/Resources/en.lproj/Localizable.strings` and `de.lproj/Localizable.strings`,
ordinary `.strings` files (`"English" = "Deutsch";`), about 500 keys, grouped by source file.
`Localization` reads them itself with `PropertyListSerialization`, from
`AppInfo.resourcesDirectory` (`Contents/Resources` in Safe.app, `app/Resources` for a debug
build run outside it), and looks a key up in the chosen language, then in English, then takes
the key. So English never depends on a file: the command-line modes, `SafeTests` and a bundle
without tables all speak English. Why `.strings` files read directly rather than a Swift table
or `NSLocalizedString`:

- `NSLocalizedString` and `Bundle.localizedString` choose the language from macOS's settings
  when the process starts, but Safe's language is its own setting and changes while it runs.
- A Swift table would be checked by the compiler, but the owner can read and correct a
  `.strings` file without Swift, with the English and the German side by side, and the Finder
  needs `.strings` files anyway (below).
- With the English text as key, the code reads as before, and the English that the app
  tests compare stayed byte for byte the same.

Not translated: the JSON and the text of `--version`, `--self-test`, `--check` and `--help`
(for agents; `main.swift` sets the language only after the command-line modes), log lines, the
details of a failed self-test (they are the same text as in `--self-test`), file names that
Safe writes (`NAME (conflict ...)`, `NAME (exporting ...).tmp`, `.bak`, `.safe-pending-`), and
messages that come from `hdiutil` or from the system (`strerror`), which follow macOS.

`build-app.sh` copies `en.lproj` and `de.lproj` (also `InfoPlist.strings` and
`ServicesMenu.strings`) and both help files into `Contents/Resources`, and stops if a
`.strings` file cannot be read. `Info.plist` has `CFBundleDevelopmentRegion` en and
`CFBundleLocalizations` en and de. `Safe --check` reports `languages`, the tables it found
(`["en", "de"]`), and `helpFound` is true only if the help of both languages is complete.

### 12.2 What follows macOS, not Safe's setting

The Finder reads the names of Safe's services (`de.lproj/ServicesMenu.strings`: Mit Safe
verschlüsseln, Mit Safe öffnen, Mit Safe exportieren) and of the `.crypt` file type
(`InfoPlist.strings`: Verschlüsselte Datei) in macOS's language, so they follow macOS, whatever
Safe's setting. The help says so.

What AppKit draws for Safe (the Open and Save dialogs, the About window, the search field of
the Help menu, the context menus of text fields) follows the language AppKit picked when Safe
started. Choosing English or Deutsch therefore also writes `AppleLanguages` into Safe's own
defaults (System removes it), the key that System Settings > General > Language & Region >
Applications writes for one app; these parts follow at the next start (12.4).

NSAlert gives the Escape key to a button named Cancel only in AppKit's language, so a German
"Abbrechen" would lose it while AppKit is English. `Alerts.assignCancelEscape` gives it back in
every alert of Safe (`Alerts`, `PasswordPrompt`, `DocumentAlerts.run`); Don't Save already had
⌘D set explicitly.

### 12.3 German style

German follows current macOS German, checked in the German tables that macOS itself ships
(read only, with `plutil -p` and Python's `plistlib` on `.loctable` files): AppKit's
`MenuCommands`, `Common`, `FunctionKeyNames`, the Finder's `MenuBar.strings`, and the main
menus of Preview and TextEdit.

- **Form of address: du**, as macOS uses since macOS 13 ("Du darfst aus diesem PDF kopieren"
  in Preview), with plain imperatives (Wähle, Gib ... ein, Klicke).
- **Menus as in macOS:** Ablage, Bearbeiten (Widerrufen, Wiederholen, Ausschneiden, Kopieren,
  Einsetzen, Löschen, Alles auswählen, Suchen with Suchen ..., Weitersuchen, Weitersuchen
  (rückwärts)), Darstellung (Vergrößern, Verkleinern, Originalgröße, Größe an Fenster anpassen,
  Nächste Seite, Vorherige Seite), Fenster (Im Dock ablegen, Zoomen, Alle nach vorne bringen),
  Hilfe (Safe-Hilfe), and Safe (Über Safe, Einstellungen ..., Safe ausblenden, Andere
  ausblenden, Alle einblenden, Safe beenden). Sichern for Save, Nicht sichern, Abbrechen.
  Ellipses as macOS writes them in German, after a space ("Öffnen …").
- **Words:** Passwort (not Kennwort), das Volume, Disk-Image, Ordner, Schreibtisch, Papierkorb,
  auswerfen, sperren, Ruhezustand, Arbeitsspeicher, Zwischenablage, Festplattendienstprogramm,
  Übersicht (Quick Look), Schnellaktionen, Dienste, Systemeinstellungen with macOS's German
  pane names.
- **Keys** as Apple's German help names them: Befehlstaste, Umschalttaste, Wahltaste,
  Control-Taste, Zeilenschalter, Rückschritttaste, esc-Taste; in prose "Befehl-S",
  "Umschalt-Befehl-E"; tooltips keep the symbols ("(⌘N)").
- The help is `app/Resources/SafeHelp.de.md`, the whole manual in German with the same section
  anchors, so every "?" button and Help menu topic opens the same section in both languages.
  `HelpBook.load` reads the file of Safe's language and falls back to the English one if it
  is missing. Help menu topics keep the capitals of the German headings.

### 12.4 Settings and switching the language

**Safe > Settings...** (⌘,; "Einstellungen …") opens `SettingsWindowController`, a small
window with **Language** (System, English, Deutsch), a sentence that says what changes when, the
restart offer, a "?" (help section Settings and language) and tooltips on every control.
`Settings` keeps the choice under `SafeLanguage` in the app's own defaults
(`io.github.fherwig.safedocker`); the no-network sandbox does not touch the preferences daemon,
which `setDefaults` already used. The app tests use a defaults suite of their own and remove it.
System means German if German comes before English in macOS's preferred languages (the
`AppleLanguages` list System Settings keeps, globally or for Safe alone), and English
otherwise, also when neither is in it.

A change applies at once (`Settings.languageDidChange`):

- the menu bar: `MainMenu.relocalize` gives every item that carries Safe's identifier
  (`safe.menu:` and the English title) its title again; items macOS added keep theirs;
- the Volumes window (`applyLanguage`: title, introduction, column headers, buttons, tooltips,
  states; the selection and the typed sync app stay), the help window (the manual of the new
  language, at the same section) and the Settings window.

Editors, viewers and open dialogs are not touched: they keep their texts until the file is
opened again, and a language change never closes a window, reloads a text or loses a change.
No restart is needed for Safe's own texts. Only what AppKit draws (12.2) needs one; when it
differs from Safe's language, the Settings window says so, and offers **Restart Safe** only
when no editor, viewer or volume opened by Safe is open (so no unsaved text), which starts a new
Safe through `NSWorkspace` and quits this one. Otherwise it says that those parts change at the
next start.

The Edit menu's guard (`EditMenuGuard`, `MainMenu.strip`) now knows Safe's items by their
identifiers instead of their English titles, so it strips Writing Tools, AutoFill, Dictation
and Emoji in German too ("Schreibtools", "Automatisch ausfüllen", "Diktat starten …",
"Emoji & Symbole").

### 12.5 The German keyboard

Interpretation: with German chosen, every shortcut works and is shown correctly on a German
(QWERTZ) keyboard, and the help and tooltips name the keys the German way. The shortcuts are the
same in both languages; macOS matches a menu's key equivalent by the character the keys type,
not by their place, which is what is wanted. Checked offline with the German layout's
`kTISPropertyUnicodeKeyLayoutData` and `UCKeyTranslate` (read only; no input source changed):

| Shortcut | English keyboard | German keyboard | Note |
|---|---|---|---|
| ⌘? Safe Help | Shift-Command-/ | Shift-Command-ß | the menu shows ⌘? in both |
| ⌘+ Zoom In | Shift-Command-= | Command and the + key, no Shift | |
| ⌘= Zoom In (hidden) | Command-= | Shift-Command-0 | no other item on ⇧⌘0 |
| ⌘- Zoom Out | Command and the - key | Command and the - key (right of the period) | |
| ⌘, Settings | Command-comma | Command-comma | |
| ⌥⌘0 Actual Size | Option-Command-0 | Option-Command-0 | Option-0 types "}" on German; AppKit matches Option shortcuts by the key without Option |
| ⌘Z, ⇧⌘Z | Z | Z, where English keyboards have Y | by character, so Undo stays on the key marked Z |

Every other shortcut is a letter, a digit, an arrow or Return, the same on both. Safe uses none
of ⌘[ ⌘] ⌘\ ⌘@, which need Option on a German keyboard. AppKit's automatic localization of key
equivalents (`allowsAutomaticKeyEquivalentLocalization`, on by default for apps built with the
macOS 12 SDK or later) moves only a shortcut whose character a layout cannot type; on German it
leaves all of Safe's alone, so it stays on (on a French keyboard, where digits need Shift, it
may move some, and the menu then shows the moved key). Mirroring
(`allowsAutomaticKeyEquivalentMirroring`) applies only to right-to-left languages. The uniqueness
rule holds per language, and no shortcut takes a text-editing key.

Passwords: umlauts and ß are Latin letters, which secure text fields take from the German
keyboard (they allow Roman input sources only); the keyboard types the composed letters, so
`Prüfung-ß` is the same UTF-8 bytes for Safe, `openssl` and `crypt.sh`. The rule about
non-Latin scripts (a note that such a password must be pasted) is unchanged, and the help says
that ä, ö, ü and ß are fine.

### 12.6 Tests

The suite `i18n` of `Safe --app-tests` (13 tests): every key that the code uses (found by
`KeyScanner`, which reads the literals of `L`, `Lp` and `LKey` in the app's and the core's
sources as Swift reads them) is in both tables, the tables have the same keys, and no German
text is empty or still English (except a short list: OK, Safe, Name, Name:, Volume, Volumes,
System, 1 GB, "Text in %@."); format specifiers match in number, position and type, and none
mixes positions with plain ones; the plural forms in both languages; the German menu bar has
macOS's German titles, the same unique shortcuts as the English one and ⌘, for Settings; the
Edit menu's guard in German; every shortcut can be typed on the German layout without Option
(only ⌘? and ⌘= need Shift); the German help with every section and the German menu titles in
its table; switching the language live re-titles the menu bar, the Volumes window and the help
window, keeps the Volumes selection, and leaves an open editor's text, changed state, title and
status line alone; Settings keeps the choice in its defaults suite, and System follows the order
of languages; the Settings window's popup, live switch and restart offer (only with nothing
open); German buttons, labels and popups fit their controls (intrinsic width against frame) in
the Volumes, Settings and help windows, the password dialogs, the New Empty form, the editor
with its search bar and the viewer; Cancel keeps Escape in German dialogs; and the password
`Prüfung-ß` passes the prompt's rules, needs no pasting, is the composed UTF-8 bytes and opens
what it encrypted. The help test of the shortcut table runs for both files, and `SafeTests`
checks `languages` in `--check`.

What only the owner can check (`acceptance.md`, section 11): how the German reads on the screen,
a real German keyboard, the restart, System with macOS's language order, and the Finder's
services under a German macOS.
