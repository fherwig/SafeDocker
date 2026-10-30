# Safe Help

Safe keeps files encrypted and lets you use them without leaving a readable copy on the disk. This help is also a file in Safe's source code, `app/Resources/SafeHelp.md`, which any text editor can open.

## The idea behind Safe {#idea}

### Two kinds of protection

Safe protects your files in two ways.

- **Encrypted files.** One file is encrypted on its own. `report.pdf` becomes `report.pdf.crypt`, and only its password opens it. This suits single documents: a list of passwords, a scanned passport, a contract.
- **Encrypted volumes.** A volume is an encrypted disk image: one item in the Finder that holds many files and folders. When you open it with its password, it appears in the Finder like a USB stick, and you use its files as usual. This suits a whole folder, a project or a collection of photos.

You can combine the two. A file encrypted on its own and kept inside a volume needs both passwords.

### Decrypted content stays in memory

When Safe opens an encrypted file, the text, the PDF or the picture exists only in Safe's memory, in its window. Opening, editing, saving and viewing never write a readable copy to the disk, not even for a moment. Saving writes only encrypted data. When you close the window, Safe forgets the content and the password.

The reason: a deleted file is not really gone. On the SSD of a modern Mac, the blocks of a deleted file can stay readable until they happen to be overwritten. Inside an encrypted disk image, a deleted file could still be found in the image (this was tested while Safe was built). A plain copy written "only for a moment" would therefore stay behind. Safe avoids making one.

The one exception is **Export**, which writes a normal, unencrypted copy where you choose, on purpose, after a warning.

### Standard formats that outlive Safe

Safe uses formats that are documented and that other programs read, so that your files stay readable for decades, with or without Safe.

- An encrypted file is in the format of `openssl`, a program that comes with every Mac: AES-256, with the password stretched by PBKDF2-HMAC-SHA512 over 100,000 rounds. The Terminal on any Mac can decrypt it. So can `tools/safe-decrypt.py` from Safe's source code, which needs only Python 3, the Docker image `fherwig/safe:22.0`, and the older terminal tool `crypt.sh`. Section "Old files and the long term" has the commands.
- A volume is an encrypted disk image in Apple's own format (AES-256). Any Mac opens it with a double-click and the password, without Safe.

### No network at all

The first thing Safe does when it starts is switch off its own network access. It cannot send anything anywhere: no update check, no statistics, no online help. This help is part of the app.

### Automatic locking

After 10 minutes without any input on the Mac, and when the Mac sleeps or the screen locks, Safe hides or closes what it shows and closes the volumes it opened. Section "Locking" says what happens to each kind of window.

### No password recovery

Nobody can recover a lost password: not Safe, not the person who installed it, not Apple. The encryption has no back door. **If you lose the password, the file or volume is lost.** Keep your passwords somewhere safe, for example written on paper in a safe place, or in a password manager you trust.

Installing, updating or removing Safe never needs your passwords: not the installer, and not the person or AI agent who installed it. Removing Safe never deletes your encrypted files or volumes.

### What Safe does not protect against

Safe protects files while they are encrypted. It cannot protect against everything. Be aware of these limits:

- **Malware, or someone using your logged-in account.** While a file is open in Safe, or a volume is open, a program running under your account, or a person at your unlocked Mac, can read it. Someone watching can also see the password you type. Lock the screen when you leave the Mac (Control-Command-Q).
- **Copies made before you encrypted.** Encrypting a file deletes the original, but older plain copies may exist elsewhere: in the trash and version history of a sync service such as Nextcloud, Dropbox or iCloud Drive, in Time Machine backups and local snapshots, in the Spotlight index, and in Quick Look previews (the thumbnails the Finder makes). On an SSD, the deleted original may stay readable for a while. FileVault, the Mac's own disk encryption, protects these copies on the Mac itself; switch it on in System Settings > Privacy & Security > FileVault.
- **Screenshots and cameras.** Safe keeps the windows that show decrypted content out of most screenshots and screen sharing, but this is a best effort, and it cannot stop a camera pointed at the screen.
- **Copies you export on purpose.** An exported copy is a normal file. Delete it when you no longer need it.
- **A volume while it is open.** An open volume is a normal folder for every app you run. Any of them can read its files, copy them elsewhere, or upload them. Close a volume when you are done with it.
- **The clipboard history.** Some versions of macOS keep a history of what you copy (Spotlight on macOS 26). Safe cannot empty it; section "Opening and editing a text file" explains what Safe does.

## Passwords {#passwords}

### Choosing a new password

When you encrypt a file or make a volume, Safe asks for the new password twice. The two must be the same, so that a typing mistake cannot lock you out. A long password made of several words is easier to remember and harder to guess than a short one with symbols, for example `garden-violin-seven-harbour`.

Safe refuses a new password that:

- is empty;
- contains a line break or another control character such as a tab. These usually come from pasting. `openssl` reads a password only up to a line break, so a file with such a password would not open there;
- is longer than 511 bytes, the most that `openssl` accepts.

If the password has letters of a script other than Latin (Greek, Cyrillic, Chinese and others) or emoji, Safe warns you first. Password fields on the Mac accept only Latin keyboard layouts and no emoji, so you would have to paste such a password every time. To use it anyway, type or paste it twice again. Letters with accents, such as the German ä, ö, ü and ß, are Latin letters: they type as usual on a German or any other Latin keyboard layout.

Capital and small letters count: `Garden` and `garden` are different passwords.

### Typing a password to open something

Safe asks once. If the password is wrong, it says so and asks again. A line break at the end of a pasted password is ignored, because no password can end with one.

### Where passwords are kept

While a file is open, Safe keeps its password in memory, so that Command-S can save without asking again. It is kept in memory that is never written to the swap file, and wiped when you close the window. Safe never writes a password to the disk. For volumes, Safe hands the password straight to macOS's disk image tool and forgets it.

There is no password recovery. Section "The idea behind Safe" explains why.

## Encrypting a file {#encrypting}

### From the Finder

1. Select one or more files in the Finder.
2. Right-click (or Control-click) them and choose **Encrypt with Safe**. Depending on the version of macOS and the Finder's settings, it is under **Quick Actions** or under **Services**.
3. Type a new password twice and click OK.

You can also choose **File > Encrypt File...** (Shift-Command-E) in Safe and pick the files there.

### What happens to the original

Safe writes the encrypted copy next to the original, with `.crypt` added to the name: `report.pdf` becomes `report.pdf.crypt`. Then it reads the encrypted copy back, decrypts it and compares the result with the original. Only if they are the same does it delete the original. If anything goes wrong, the original stays where it was and Safe tells you.

Only the file's content is encrypted. Finder tags and comments are not kept.

The first time you encrypt, Safe reminds you once which older plain copies can remain (section "The idea behind Safe"). For a file in a synced folder, it says that the sync service keeps a plain copy in its trash and version history (Nextcloud keeps it for 30 days by default). For a file inside an open volume, it says that the deleted original stays readable inside the volume's image to anyone with the volume's password: encrypt files before you move them into a volume.

### Several files at once

Select several files and choose Encrypt with Safe once. Safe asks for one password, which it uses for all of them, and encrypts each file into its own `.crypt` file. At the end it lists any file it did not encrypt, with the reason; those originals are kept.

### What Safe refuses

- **Folders.** Make an encrypted volume from a folder instead (section "Volumes").
- **Encrypted disk images and sparse bundles.** Add them to the Volumes window with Add Existing. An unencrypted single-file disk image (`.dmg`) is encrypted like any other file.
- **Files that are already encrypted** (`.crypt`), and files whose `NAME.crypt` exists already.
- **Files larger than 1 GB.** Encrypting needs several copies in memory. Put large files in a volume.
- **Files with a second name** (a hard link). Deleting the original would not remove the content, which would stay readable under the other name.
- **Files with a resource fork**, an old Mac way of storing extra data that the `.crypt` file could not keep.

When Safe starts, it first checks its own encryption (the self-test, section "Old files and the long term"). Encrypting waits until that check has passed, which takes a few seconds.

## Opening and editing a text file {#editing}

### Opening

Double-click a `.crypt` file in the Finder, or right-click it and choose **Open with Safe**, or choose **File > Open...** (Command-O) in Safe. Type the password. What happens next depends on the file:

- **text** opens in Safe's editor;
- **PDFs and pictures** open in Safe's viewer (section "Viewing PDFs and pictures, and exporting");
- **other files**, such as a Word document or a zip archive, cannot be shown. Safe offers to export them.

A file counts as text if its name ends in `.txt`, `.md`, `.markdown`, `.csv`, `.json`, `.yaml`, `.yml`, `.xml`, `.tex` or `.log`, or has no ending at all, and its content is text. If the file is open already, Safe brings its window to the front.

The window's title is the file's original name, and below it the folder it is in. The line at the bottom starts with "Decrypted in memory only."

### Saving

Command-S saves without asking for the password again. Safe encrypts the text, writes it to a new file, reads that back and checks it, keeps the previous version as `NAME.crypt.bak`, and only then puts the new version in place. The line at the bottom then says, for example, "Saved 14:05, the previous version is kept as notes.txt.crypt.bak."

The `.bak` file is encrypted with the same password and opens like any other `.crypt` file. Each save replaces it with the version before.

### Closing

Close the window with Command-W. If you have unsaved changes, Safe asks whether to save them: Save, Don't Save (Command-D) or Cancel. Closing removes the text, the undo history and the password from memory.

### Searching

Command-F shows a search field above the text. Type to find the first match; Return finds the next one and Shift-Return the one before; Command-G and Shift-Command-G do the same from anywhere in the window. Escape or Done hides the field. The search ignores capital and small letters and goes on at the top after the end. What you search for stays in this window: Safe does not share it with the Find of other apps.

### When the file changed somewhere else

If another program or another Mac changed the file after you opened it, Command-S does not overwrite that version. Safe asks what to do:

- **Keep My Version as a Copy** saves your text as a separate encrypted file next to it, for example `notes (conflict 2026-10-25 14-05).txt.crypt`, with the same password.
- **Discard My Changes** loads the file as it is now.
- **Cancel** keeps your text in the window and changes nothing.

If the folder of the file has gone, usually because the volume holding it was closed, Safe says so. Open the volume again, then save. If Safe itself closed the volume when it locked, it offers **Open “NAME” Again**.

### "Safe could not confirm the password"

A wrong password sometimes produces something that looks like a file. Safe checks that what it decrypted looks like the kind of file its name says. Usually this check confirms the password. Some real files fail it, for example a text written on Windows in an older encoding (ISO Latin-1) or in UTF-16. Then Safe cannot tell a right password from a wrong one, and asks you:

- **Open Read-Only** shows the text without letting you change it. A yellow note at the top says that Safe could not confirm the password. If the text is what you expect, the password is right: click **Allow Editing**. If it is gibberish, close the window and open the file again with the right password.
- **Type Another Password** asks again.
- **Cancel** stops.

For such a file, the first save keeps the file as it was in `NAME.crypt.bak`, and later saves in the same window keep that `.bak`, so that two saves cannot replace both the file and its backup if the password was wrong after all.

If what came out is not text at all, Safe says that **the password is probably not right**, and offers Type It Again, Export Anyway and Cancel.

### Encodings

Most texts are UTF-8. Safe also reads UTF-8 with a byte order mark (as Windows Notepad writes it), UTF-16 and ISO Latin-1, shows the encoding in the line at the bottom, and writes the text back in the same encoding. If you add a character that ISO Latin-1 cannot hold, such as the euro sign, Safe offers to save the text in UTF-8 instead.

### The clipboard

What you copy or cut in Safe is meant for this Mac only:

- it is not sent to your iPhone or iPad (Universal Clipboard);
- it is marked as concealed, which clipboard managers that respect the mark leave out;
- Safe empties the clipboard after one minute, when it locks and when it quits, if the clipboard still holds what Safe put there.

If macOS keeps a clipboard history (Spotlight on macOS 26), Safe cannot empty that history. It asks before the first copy each time it starts. You can switch the history off in System Settings > Spotlight.

### What the editor leaves out, and why

Safe's editor is plain on purpose. It has no spell checking, grammar check, autocorrection, text completion, smart quotes, Writing Tools, Look Up, Services, Share, Print, dragging of selected text into other apps, and no automatic saving of versions. Each of these hands your text to another part of macOS or to another app, which may keep it, write it to the disk or send it over the network. The menu bar therefore has no Spelling, Substitutions, Speech or Writing Tools items.

For the same reason, Control-K deletes to the end of the line but does not keep what it deleted, and Control-Y pastes nothing: macOS would otherwise keep the deleted text in a buffer that any text field can paste.

Markdown is edited as plain text.

## Viewing PDFs and pictures, and exporting {#viewing}

### The viewer

PDFs and pictures (PNG, JPEG, HEIC, GIF, TIFF, WebP, BMP, AVIF) open in Safe's viewer, from memory only. The viewer is read only.

- **Zoom In** (Command-+), **Zoom Out** (Command-minus), **Actual Size** (Option-Command-0) and **Zoom to Fit** (Command-9) are in the View menu.
- For a PDF, **Next Page** (Option-Command-Down Arrow) and **Previous Page** (Option-Command-Up Arrow) are there too; scrolling works as usual.
- You can select and copy text in a PDF. The clipboard rules of the editor apply.
- Links in a PDF do nothing, and printing is not offered: both would hand the content to other programs.
- A PDF with a password of its own shows **Unlock PDF...**; type that PDF's password.
- **Close**, or Escape, closes the viewer and forgets the content.

### Exporting

**Export...** (Option-Command-E) writes a normal, **unencrypted** copy of the file, for use in another app or to send to someone. You find it in the viewer, in the editor's File menu, and in the Finder: right-click a `.crypt` file and choose **Export with Safe**.

1. A save dialog proposes the original name, in the folder of the encrypted file. For a file inside an open volume, it proposes the Desktop instead, because a copy deleted inside a volume stays readable in the volume's image.
2. Safe warns that the exported copy is not encrypted, and says where it goes. Anyone who can read that folder can read it, and a sync service may upload it.
3. Click Export to write the copy, or Cancel to write nothing.

Delete an exported copy when you no longer need it, and empty the Trash. Remember that the app you open it with may keep its own copies (recent files, automatic versions, previews).

Safe refuses to export over the encrypted file itself, or to any name ending in `.crypt` or `.crypt.bak`. While it writes, the copy is called `NAME (exporting XXXXXXXX).tmp`; if the Mac lost power during an export, that file is an unencrypted copy to delete.

### Saving an old file in the current format

For a file in an older format (section "Old files and the long term"), the viewer offers **Save in Current Format**. It encrypts the same content again in today's format, with the same password, and keeps the old file as `NAME.crypt.bak`.

## Volumes {#volumes}

### What a volume is

A volume is an encrypted disk image in Apple's standard format, encrypted with AES-256. Safe makes them as **sparse bundles**: they grow as you add files, up to a maximum size you choose, and are stored as many small pieces, so that a sync service uploads only the pieces that changed. Open, a volume appears in the Finder like a disk, and you use its files as usual. Closed, it is one item in the Finder (`Private.sparsebundle`, for example) that nobody can read without the password.

### The Volumes window

The Volumes window lists your volumes with their name, location and state: Open, Closed, or Not found (nothing is at that location any more). It appears when Safe starts, and Window > Volumes (Command-0) brings it back. The buttons are also in the **Volume** menu, which has the keyboard shortcuts.

Select a volume in the list for Open, Close, Change Password and Remove from List. Double-click a volume, or press Return, to open it.

### New Empty (Command-N)

Safe asks for a name and a maximum size (1 GB unless you change it; write for example `500 MB`, `2 GB` or `1 TB`), then where to save the volume, then a new password twice. The new volume is added to the list.

### New from Folder (Shift-Command-N)

This turns an existing folder into a volume.

1. Choose the folder.
2. Choose where to save the new volume (not inside the folder).
3. Type a new password twice.

Safe copies the folder into the new volume, then compares every file in the volume with the folder. **Only if they match does it delete the folder.** If the check fails, or something changed the folder in the meantime, the folder is kept and Safe tells you where the new volume is.

Safe refuses your home folder and the folders that contain it, top-level folders, whole disks, folders with a disk mounted inside, and folders with a file that has a second name (a hard link) outside the folder.

Remnants of the deleted folder can stay behind, and Safe tells you so once: on an SSD the deleted files may stay readable for a while; Quick Look previews and the Spotlight index can keep copies outside the volume, which FileVault protects; a sync service keeps plain copies of a synced folder in its trash and version history; Time Machine keeps older copies.

Deleting a large folder can take a while. If Safe is stopped during the delete, it asks at its next start whether to finish deleting the rest: Delete, Show in Finder, or Not Now.

### Open (Command-Return)

Safe asks for the volume's password, opens the volume and shows it in a Finder window. It opens it in a private folder that only your account can enter, not in the usual place for disks, so that other accounts on the same Mac cannot read it. The volume appears in the Finder's sidebar as usual. If the volume is open already, Open shows it in the Finder.

### Close (Command-E)

Close ejects the volume, as Command-E ejects a disk in the Finder. Safe never forces a volume closed, because another app may have unsaved work on it. If a file on the volume is still in use, the volume stays open and Safe says so: close that file, or quit the app that uses it, and try again.

When you quit Safe, it closes the volumes it opened. If one is in use, you choose between Cancel and Quit Anyway, which leaves it open until you eject it in the Finder.

### Change Password

Select a closed volume and choose Change Password. Type the current password once and the new one twice.

What it does not do: the volume's key stays the same, so **a copy of the volume kept from before** (in a sync service's version history, a backup, or on another Mac) **still opens with the old password**. If the old password may be known to someone, make a new empty volume and move the files into it instead.

### Add Existing (Shift-Command-A)

Adds an encrypted disk image that Safe did not make, for example one made with Disk Utility: a `.dmg`, `.sparsebundle` or `.sparseimage`. Safe accepts only encrypted images.

### Remove from List

Removes the selected volume from Safe's list, after asking. **The volume itself stays on the disk** and is not deleted. You can add it again with Add Existing. In the list, the Delete key does the same.

### Checking that the sync app runs

If a volume lives in a folder that a sync app keeps up to date, select it, tick **Check that this app is running before opening**, and type the app's name, for example `Nextcloud`. If that app is not running when you open the volume, Safe warns you, because this copy of the volume may not be the latest one, and asks whether to open it anyway.

### On another Mac

A volume needs no Safe. Copy the sparse bundle to another Mac, or let a sync service carry it there. Double-click it in the Finder and type its password. A volume opened this way is mounted by macOS in the usual place for disks, where other accounts on that Mac can read it while it is open.

### Files that need extra protection

Inside an open volume, you can encrypt single files with Encrypt with Safe. They then need both passwords. Encrypt them before you move them into the volume: a plain file deleted inside a volume stays readable in the volume's image to anyone with the volume's password.

### A tip for the Finder

A volume's Finder window opens without its toolbar; the Finder does this for every disk image. To change it in the window:

- Command-1, Command-2, Command-3 and Command-4 switch between icon, list, column and gallery view;
- Option-Command-T shows the toolbar (and hides it again).

The Finder remembers this for each volume.

## Locking {#locking}

### When Safe locks

- after **10 minutes without any input on the Mac**: no key pressed, no mouse or trackpad movement, in any app, not only in Safe;
- when the Mac goes to **sleep**, or its display sleeps;
- when the **screen locks**, or you switch to another user;
- when you choose **Safe > Lock Now** (Control-Command-L).

### What happens when Safe locks

- **A text without unsaved changes** closes.
- **A text with unsaved changes** stays open, but a lock covers the text. Click **Show Text...** (or press Return) and type the file's password to see it again, with your changes. Nothing is discarded without asking.
- **Viewers** close.
- **The clipboard** is emptied, if it still holds what Safe put there.
- **Volumes that Safe opened** are closed. Safe never forces one: if a file on a volume is in use, that volume stays open, and Safe tells you when you are back. Volumes you opened yourself with a double-click in the Finder are not closed by Safe.

A volume is closed even when it holds a text with unsaved changes. When you show that text again, Safe offers **Open “NAME” Again**, which opens the volume at the same place, so that Command-S saves where the file was.

If a question was open when Safe locked, for example "Safe could not confirm the password", your answer after the lock is not taken: Safe asks for the password again first. Nothing decrypted is shown after a lock without the password.

## Old files and the long term {#longterm}

### Old formats

Over the years, `openssl` and the terminal tool `crypt.sh` wrote files in slightly different ways: with a key made by MD5 or by SHA-256 instead of today's PBKDF2, or with the old cipher RC4 (`crypt.sh` before version 1.4), with or without a random salt. When today's format does not open a file, Safe tries these older ways too.

If an older way opens the file, Safe names it. A text is saved in today's format at the next Command-S. For other files, the viewer and the export question offer **Save in Current Format**, which keeps the old file as `NAME.crypt.bak`. If Safe could not check the result (an old file of a type it cannot recognise), it asks a second time before it saves. Safe never writes the old formats.

### Old RC4 files

RC4 gives some result with any password, so for an old RC4 file Safe cannot always tell whether the password is right. If you type the same password twice in a row for a text or for a file of a type Safe cannot check, and Safe still says it is not right, it offers **Export as an Old RC4 File...**, then asks how the file was written: by `crypt.sh` before 1.4, or by another tool. The exported copy is not checked: look at it. **Other Readings...** in the questions about a password Safe could not confirm offers the same, and the readable part of a damaged file.

### The self-test at every start

Each time Safe starts, it decrypts a set of reference files made by several programs (OpenSSL 3, macOS's own LibreSSL, `crypt.sh`, and Safe itself), checks that a wrong password is refused, and checks that its network access is switched off. This takes a few seconds in the background.

If the self-test fails, something is wrong with this copy of Safe or with this Mac. Safe then refuses to encrypt and to save, so that it can never write a file it cannot read back, and says so in red in the Volumes window. Files that are encrypted already still open and export. Ask whoever installed Safe to check it; they can run `Safe --self-test` for the details.

### Ways out that do not need Safe

Your files do not depend on Safe. In the Terminal of any Mac with macOS 13 or later:

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt

decrypts `FILE.crypt` and shows the content in the Terminal, after asking for the password. To write it to a file instead (the file `FILE` must not exist yet; delete it when you are done):

    openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt -out FILE

Without `openssl`, the small program `tools/safe-decrypt.py` in Safe's source code reads every format Safe knows, old ones included, and needs nothing but Python 3:

    python3 safe-decrypt.py -o report.pdf report.pdf.crypt

The Docker image `fherwig/safe:22.0`, which has OpenSSL 3, is a third way. Volumes open on any Mac with a double-click.

### Licence and source code

Safe is free software, under the GNU General Public License, version 3 or later (GPL-3.0-or-later). You may use it, pass it on and change it; whoever passes on a changed version must pass on its source code too. It comes without any warranty. The full text is the file `LICENSE`, inside the app (in `Safe.app/Contents/Resources`) and in Safe's source code, which is at github.com/fherwig/Safe. Safe > About Safe shows the version.

## Settings and language {#settings}

### The Settings window

**Safe > Settings...** (Command-comma) opens the Settings window. For now it has one setting: the language. Safe keeps it for your account, and it applies to every window of Safe.

### Choosing the language

Safe speaks English and German. Choose in **Language**:

- **System** follows the list of languages in System Settings > General > Language & Region: German if German comes before English in that list, otherwise English.
- **English** or **Deutsch** uses that language, whatever macOS uses.

### What changes when

The menu bar, the Volumes window, this help and the Settings window change at once. A text or a viewer that is open keeps its language until you open the file again: changing the language never closes a window, and never touches a text with unsaved changes. The same holds for a dialog that is open.

A few things that macOS draws for Safe follow the new language only after Safe starts again: the Open and Save dialogs, the About window, and the search field at the top of the Help menu. The Settings window says when this is the case. If nothing is open in Safe (no text, viewer or volume), it offers **Restart Safe**; otherwise the change takes effect the next time Safe starts.

### The Finder follows macOS

The services in the Finder (Encrypt with Safe, Open with Safe, Export with Safe) and the name of the `.crypt` file type, which the Finder shows as "Encrypted file", follow the language of macOS, not Safe's setting, because the Finder shows them. With macOS in German they are called Mit Safe verschlüsseln, Mit Safe öffnen, Mit Safe exportieren and "Verschlüsselte Datei".

## Keyboard shortcuts {#shortcuts}

These shortcuts are also shown next to each item in the menus.

| Shortcut | What it does |
|---|---|
| ⌘O | File > Open: open encrypted files |
| ⇧⌘E | File > Encrypt File: encrypt files |
| ⌘W | File > Close: close the window |
| ⌘S | File > Save: save the text, encrypted |
| ⌥⌘E | File > Export: write an unencrypted copy |
| ⌘Z | Edit > Undo |
| ⇧⌘Z | Edit > Redo |
| ⌘X | Edit > Cut |
| ⌘C | Edit > Copy |
| ⌘V | Edit > Paste |
| ⌘A | Edit > Select All |
| ⌘F | Edit > Find: show the search field |
| ⌘G | Edit > Find Next |
| ⇧⌘G | Edit > Find Previous |
| ⌘+ (or ⌘=) | View > Zoom In (viewer) |
| ⌘- | View > Zoom Out (viewer) |
| ⌥⌘0 | View > Actual Size (viewer) |
| ⌘9 | View > Zoom to Fit (viewer) |
| ⌥⌘↓ | View > Next Page (PDF) |
| ⌥⌘↑ | View > Previous Page (PDF) |
| ⌘N | Volume > New Empty Volume |
| ⇧⌘N | Volume > New Volume from Folder |
| ⇧⌘A | Volume > Add Existing Volume |
| ⌘↩ | Volume > Open Volume |
| ⌘E | Volume > Close Volume |
| ⌘0 | Window > Volumes: show the Volumes window |
| ⌘M | Window > Minimize |
| ⌃⌘L | Safe > Lock Now |
| ⌘H | Safe > Hide Safe |
| ⌥⌘H | Safe > Hide Others |
| ⌘Q | Safe > Quit Safe |
| ⌘? | Help > Safe Help |
| ⌘, | Safe > Settings: choose the language |

The symbols: ⌘ is the Command key, ⇧ Shift, ⌥ Option, ⌃ Control, ↩ Return, ↓ and ↑ the arrow keys. ⌘? is Shift-Command-/ on an English keyboard, and ⌘+ is Shift-Command-=. On a German keyboard, ⌘? is Shift-Command-ß, ⌘+ is Command with the + key (without Shift), and ⌘= is Shift-Command-0. The shortcuts are the same in both languages of Safe.

Keys inside windows:

| Key | Where | What it does |
|---|---|---|
| Return | Volumes list | open the selected volume |
| Delete | Volumes list | remove the selected volume from the list (asks first) |
| Return, ⇧Return | search field | find the next or the previous match |
| Escape | search field | hide the search field |
| Escape | viewer | close the viewer |
| Return | locked text | Show Text: type the password to see the text again |
| ⌘D | "Do you want to save" question | Don't Save |

Change Password and Remove from List have no shortcut in the menu, so that a slip of the finger cannot start them.

### Shortcuts for the Finder's services

Encrypt with Safe, Open with Safe and Export with Safe in the Finder have no shortcut, because a service shortcut works in every app and would collide with the shortcuts of other apps. You can give them one yourself:

1. Open System Settings > Keyboard, and click **Keyboard Shortcuts...**.
2. Choose **Services** on the left, and open **Files and Folders**.
3. Double-click **none** next to Encrypt with Safe, and press the keys you want, for example Control-Option-Command-E. Choose keys that no other app uses.
4. Click Done. The shortcut works when files are selected in the Finder.

## When something goes wrong {#problems}

### Wrong password, damaged file, or "could not confirm"

- **"The password was not right."** Check Caps Lock and the keyboard layout (the flag or letters in the menu bar), and type it again. Remember that capital and small letters count.
- **"The password does not open the file, or the file is damaged."** Usually a wrong password. If you are sure of the password, the file may have been cut short.
- **"“NAME” is damaged."** The password seems right, but the end of the file is missing, usually because a copy or a sync was interrupted. If there is a `NAME.crypt.bak`, open that: it is the version before the last save. Otherwise **Export Readable Part...** saves everything that can still be read.
- **"Safe could not confirm the password."** The content does not look like the kind of file its name says, so Safe cannot tell whether the password is right. Open it read only and look (section "Opening and editing a text file").
- **"The password is probably not right."** What came out is not what the file should contain. Type the password again. Export Anyway exists for the rare file that really looks like this.

### A volume will not close

A file on it is still in use: open in an app, for example, or a Terminal window is in one of its folders. Close the file or quit the app, then click Close again. Safe never forces a volume closed, because the app using it may have unsaved work. When Safe locks or quits, a busy volume stays open and Safe tells you.

### A save that does not work

- **"The folder that holds it is not there any more."** The volume holding the file was closed. Open it again, then save; your changes are still in the window.
- **"... changed on disk."** Another program or another Mac changed the file (section "Opening and editing a text file").
- **"Safe is still checking..."** The self-test is still running. Try again in a moment.
- **"Safe will not encrypt or save, because its self-test failed."** See section "Old files and the long term".

### Files you may find next to an encrypted file

- **`NAME.crypt.bak`**: the previous version, kept by every save. It is encrypted, with the password the file had then, and opens with a double-click like any `.crypt` file.
- **`NAME.crypt_new`**: exists only while Safe saves or encrypts. If you find one, saving or encrypting was interrupted. It is encrypted, and `NAME.crypt` is still the last good version. Safe removes it at the next save; you may also delete it.
- **`NAME (conflict 2026-10-25 14-05).txt.crypt`**: your version, saved as a copy because the file changed somewhere else while you edited it. Open both, keep what you need, and delete the other.
- **`NAME (exporting XXXXXXXX).tmp`**: an export that was interrupted. It is **not encrypted**: delete it.
- **A hidden folder `.NAME.safe-pending-XXXXXXXX`**: a folder that New from Folder was deleting. Safe offers to finish the delete at its next start.

### Safe does not start

If Safe says "Safe cannot start" because it could not switch off its own network access, it quits rather than run without that protection. Ask whoever installed Safe to look at it.
