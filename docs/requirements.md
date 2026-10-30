# SafeDocker: requirements

Status: draft, dictated by the owner on 2026-10-25. The owner's decisions are written into
each requirement. Points marked **proposed** are answers suggested to the owner and not
yet confirmed.

## Purpose

A Mac application that keeps files encrypted and lets their owner use them conveniently:
single encrypted files that can be edited or viewed without a decrypted copy on the disk,
and encrypted volumes in Apple's standard disk image format. It grows out of today's
SafeDocker, a terminal tool that edits one encrypted text file inside an encrypted disk
image, and replaces it for everyday use.

## General requirements

### G1. No terminal

The user never has to open a terminal or type a command. Everything the user does
happens in the Finder or in the app's own windows.

### G2. Installed by a system administration agent

The user may not be technical. An AI system administration agent installs the app for
them, following agent-facing install instructions kept in the Git repository.

- The install procedure checks the requirements first (for example the macOS version,
  and Docker if the chosen design needs it) and reports what is missing.
- The instructions say how to verify the installation, how to update it and how to remove
  it. Removing the app never deletes the user's encrypted files or volumes.
- The agent never sees, types or stores the user's passwords.

### G3. Compatible with today's safe

Single files use today's format: the openssl format of `crypt.sh` (AES-256-CBC, key and IV
from PBKDF2-HMAC-SHA512 with 100,000 iterations, an 8-byte salt, the `Salted__` header)
and the ending `.crypt`. So:

- files encrypted by today's `crypt.sh`, such as `safe.txt.crypt`, open in the app;
- files the app encrypts open with `crypt.sh`, and with plain `openssl` on any Mac:
  `openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt`.

### G4. Automatic closing

After 10 minutes without use, and when the Mac sleeps or the screen locks:

- the editor and the viewer hide the decrypted content;
- volumes opened by the app are closed.

**Proposed:** a file without unsaved changes is closed. A file with unsaved changes stays
open behind the lock, and its password is needed to show the text again; nothing is
discarded without asking.

### G5. Readable for the long term (proposed)

A file encrypted today must still open after any number of macOS and OpenSSL updates, and
old files that today's `openssl` rejects must open as well.

- Every parameter of the format is written down byte by byte in the repository, and the
  app never relies on a default: header, salt, PBKDF2-HMAC-SHA512 with 100,000 iterations,
  AES-256-CBC, padding.
- The app does not call the system's `openssl`. It contains its own implementation of the
  format, so an update of macOS's `openssl` cannot change what the app reads or writes.
- Test files with known passwords and contents, made by several implementations (the
  Docker image's OpenSSL 3, macOS's LibreSSL, the app itself), are kept in the
  repository. The app checks them when it is built, when it is installed and each time
  it starts. If one fails, the app refuses to encrypt and says so, so it can never write
  a file it cannot read back.
- Every encrypted file is decrypted again and compared before it replaces anything (as
  R1 and today's `crypt.sh` do).
- Old variants are recognised: if the current format does not open a file, the app tries
  the variants older tools wrote (key derived with MD5 or SHA-256 by default, RC4) and,
  if one opens it, offers to save it again in the current format. It never writes the old
  variants.
- Ways out that do not depend on macOS or on this app: the Docker image `fherwig/safe:22.0`,
  pinned by its digest and also kept as a saved archive file, and a small reference
  decryptor in the repository that needs nothing but a standard language runtime.

Done when:

- the test files from all implementations open in the app, in the Docker image and with
  the reference decryptor;
- a file made with the old MD5 default and a file made with RC4 open in the app and can be
  saved again in the current format;
- a deliberately broken check makes the app refuse to encrypt.

## R1. Encrypt a file from the Finder

The user encrypts a file from the Finder with a click.

- In the Finder, the user selects a file, right-clicks it and chooses "Encrypt" from the
  context menu.
- The user types a password twice; the two must match, so a typing mistake cannot lock
  the user out.
- The encrypted file is written next to the original, with `.crypt` added to its name:
  `report.pdf` becomes `report.pdf.crypt`.
- The app then checks the encrypted file by decrypting it and comparing the result with
  the original. Only if they match is the original deleted, as `crypt.sh -r` does today.
  If the check fails, the original stays and the user is told.

Done when:

- "Encrypt" appears in the Finder's context menu for a selected file;
- choosing it and typing the password twice produces `NAME.crypt` next to where the
  original was, and the original is gone;
- `NAME.crypt` decrypts to the original with the app, with `crypt.sh` and with plain
  `openssl`;
- if the check is made to fail (in a test), the original is kept.

**Proposed:**

- Several files selected at once are encrypted one by one, each into its own `.crypt`
  file, all with the one password typed.
- Files only. A whole folder is turned into an encrypted volume instead (R4).

## R2. Edit an encrypted text file without decrypting it on disk

Many encrypted files are plain text, Markdown or TXT for example. The user edits such a
file in a small, lean text editor, and the decrypted text never touches the disk.

- The user opens the file by double-clicking it in the Finder, or with "Open" from its
  right-click menu, and types its password.
- The decrypted text exists only in memory, while the editor is open.
- Saving (Cmd-S) encrypts the text with the password that opened the file, without asking
  for it again, and replaces the encrypted file. The password is kept in memory only
  while the file is open. The previous version is kept as `NAME.crypt.bak`, as today.
- No decrypted copy is written anywhere, not even temporarily.
- Closing the editor discards the text and the password from memory.
- G4 applies: after 10 minutes without use or when the Mac sleeps, the text is hidden.

Done when:

- the user can open an encrypted text file by double-clicking it, change it, save it
  without retyping the password, and close it;
- afterwards, the encrypted file holds the changes, the previous version is in
  `NAME.crypt.bak`, and no decrypted copy of the text can be found on the disk (checked by
  searching the disk for a marker typed into the file);
- a wrong password is reported as wrong, and never shows garbage as if it were the text.

**Proposed:**

- A file counts as text if its original ending is a text ending (`.txt`, `.md`,
  `.markdown`, `.csv`, `.json`, `.yaml`, `.xml`, `.tex`, `.log`, and files without an
  ending, such as today's `safe.txt`) and its content is valid UTF-8 text. Other files
  go to the viewer or to export (R3).
- Markdown is edited as plain text; a formatted preview can come later.

## R3. View an encrypted file, or export the original

When the encrypted file is not plain text, a PDF, PNG or JPEG for example, decrypting
means one of two things, chosen by the user in the file's right-click menu:

- **View:** the decrypted file is shown in a viewer, from memory only. Nothing decrypted
  is written to the disk. A double-click on such a file also opens the viewer.
- **Export:** the decrypted original is written to the disk as a normal file, on purpose,
  because the user wants to use it elsewhere. A save dialog asks where it goes, and the
  user is told that the exported copy is not encrypted. Text files can be exported too.

Done when:

- the user can view an encrypted PDF, PNG or JPEG, and no decrypted copy can be found on
  the disk afterwards;
- the user can export a file to a place chosen in the save dialog, sees the warning, and
  the exported file is identical to the original.

**Proposed:** the viewer shows what macOS can display from memory: PDF, PNG, JPEG, HEIC,
GIF and TIFF. Files it cannot show, a Word document or a zip file for example, can only be
exported.

## R4. Encrypted volumes

Besides single files, the app manages one or more small encrypted volumes: encrypted Mac
disk images in Apple's standard format. Because the format is standard, a volume can be
copied to another Mac and opened there with the password, without this app.

- The app makes volumes as **sparse bundles**: they grow as needed and are stored as many
  small pieces, so a sync service such as Nextcloud uploads only the changed pieces.
  Encryption is AES-256.
- When opened, a volume shows up in the Finder like a normal folder, and its files can be
  used as usual.
- Inside an open volume, particularly sensitive documents can additionally be encrypted
  one by one (R1 to R3). They are then protected twice: by the volume's password and by
  their own.
- A new volume is created in one of two ways:
  - **empty**, with a size the user gives (the most it can grow to);
  - **from an existing folder**: the volume is made with the folder's contents, then its
    contents are checked against the folder, and only if they match is the folder
    deleted. Deleted files on an SSD cannot be reliably wiped, so the plain copies may
    linger on the disk until they are overwritten; the user is told this once.
- G4 applies: volumes opened by the app close after 10 minutes without use and when the
  Mac sleeps.

Done when:

- the user can create a volume both ways, open it with its password, use its files in the
  Finder, and close it again;
- after creating a volume from a folder, the volume holds exactly the folder's files and
  the folder is gone; if the check is made to fail (in a test), the folder is kept;
- a volume made by the app opens on another Mac by double-clicking it in the Finder and
  typing its password;
- a file encrypted inside a volume (R1) opens only with both passwords.

**Proposed:**

- Volumes live wherever the user puts them, in a synced folder for example. The app keeps
  a list of them, each with a name, and opens and closes them from that list. A
  double-click in the Finder still opens a volume the way macOS does.
- Existing encrypted disk images that the app did not make, such as today's safe with
  `safe.txt.crypt` inside, can be added to the list.
- The app can change a volume's password.
- Today's check stays, as an option per volume: before opening, the app checks that the
  sync app keeping the volume's folder in sync is running, and warns if it is not.

## Tested facts that bear on these requirements

Tested on macOS 26 with throwaway files, 2026-10-25:

- **Deleted files stay inside an APFS disk image.** A file written into an APFS disk
  image and then deleted could still be found in the image file. Anything written in
  plain text into a volume, even briefly, therefore stays protected by the volume's
  password alone. This is why R2 and R3 allow no decrypted copy on the disk. In the same
  test with HFS+, the deleted text was not found.
- **macOS's own `openssl` reads today's files.** The `openssl` that ships with macOS
  (LibreSSL 3.3.6) decrypts files made by today's tool and makes files that today's tool
  decrypts, also with non-ASCII passwords. G3 needs no Docker.
- **OpenSSL's defaults have changed; the algorithms have not.** Encrypted without naming
  the digest (`-md`), a file from today's `openssl`, both macOS's LibreSSL 3.3.6 and
  Debian's OpenSSL 3.0.22, opens with `-md sha256` and fails with `-md md5`. Older
  versions, including those macOS shipped for years, used MD5 by default, so their files
  fail with today's defaults. RC4, which `crypt.sh` used by default before version 1.4,
  is missing from OpenSSL 3 and still present in macOS's LibreSSL. Since January 2023
  `crypt.sh` names every parameter, which removes the dependence on defaults (G5).
- **A wrong password can look right.** Without an extra check, about 1 in 256 wrong
  passwords decrypts without an error and yields garbage. The app must check that the
  result is plausible, so that a mistyped password is reported as wrong (R2).
- **Docker Desktop needs an administrator** to install and to update; its automatic
  update fails for a standard user. A design without Docker makes G2 much simpler. The
  design study of 2026-10-25 found that a native Mac app can meet these requirements
  without Docker.
