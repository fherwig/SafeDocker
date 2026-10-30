# Safe.app: the owner's acceptance checklist

This is the owner's last check of a build, by hand, in the Finder, as a user would
work (section 7.4 of `building-plan.md`). The automated tests have passed before:
`swift build --scratch-path S && swift run --scratch-path S SafeTests` in `app/` (with
`S` a folder under `~/Library/Caches/SafeDocker-build`; it fails as incomplete if the app
suite could not run; about 4 to 15 minutes, so run it in the background and wait for its
summary line), `tools/test_safe_decrypt.py` (up to three minutes) and
`tools/test_scripts.py`. This list covers what they cannot: the Finder, the windows, the
agent, locking, another Mac.

Use throwaway files and test passwords only, never the real safe or real documents.
Tick each box; the requirement it proves is in brackets. A few checks use Terminal;
the user of the app never needs it.

Build under test: version ______ from commit ______, on macOS ______, ______ (Mac).

## 0. Preparation

- [ ] A test folder that no sync service watches, with copies of the originals to
      compare with later:

          mkdir -p ~/safetest-acceptance/originals
          cd ~/safetest-acceptance

- [ ] In it, test files: `notes.txt` (a few lines of text), `report.pdf`,
      `photo.jpg` or `photo.png`, a Word document or zip file `other.docx`, and a
      folder `project` with a few files and a subfolder. Copy all of them into
      `originals/` (`cp -R notes.txt report.pdf photo.jpg other.docx project originals/`).
- [ ] Two test passwords, one of them with non-ASCII letters, such as `test-one` and
      `Grüße-zwei`.
- [ ] A marker for the leak search: a word that exists nowhere else, for example
      `QX7-PLUM-4410`. Type it only into Safe's editor, never into another app, a
      chat, or a Terminal command. The commands below write it in two pieces
      (`'QX7-PLUM''-4410'`), so that the shell history never holds it whole.

## 1. Install with the agent [G2]

- [ ] Give an AI system administration agent `INSTALL-AGENT.md` and ask it to install
      Safe. It runs `app/scripts/agent-check.sh` and reports what it found, including
      warnings such as FileVault.
- [ ] It asks before it installs, needs no administrator password, and never asks for,
      types or sees a password.
- [ ] Afterwards `~/Applications/Safe.app` exists, and the agent shows that
      `Safe --version`, `--self-test` and `--check` exit with status 0.
- [ ] Right-click any file in the Finder: "Encrypt with Safe" appears under Quick
      Actions or Services. A `.crypt` file shows "Open with Safe" and "Export with
      Safe", and Safe is its default app.

## 2. Encrypt from the Finder [R1, G3]

- [ ] Right-click `notes.txt` > Encrypt with Safe. Safe asks for the password twice;
      two different passwords are refused, and so is an empty one, and one pasted with a
      line break at its end (copy a whole line from TextEdit with a triple-click): Safe
      says that the password contains a line break.
- [ ] With `test-one` twice: `notes.txt.crypt` appears next to where `notes.txt` was,
      and `notes.txt` is gone.
- [ ] It decrypts to the original with macOS's own `openssl` (asks for the password):

          openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in notes.txt.crypt | cmp - originals/notes.txt && echo same

- [ ] It decrypts with the reference decryptor, which needs only Python 3:

          python3 PATH-TO-REPO/tools/safe-decrypt.py notes.txt.crypt | cmp - originals/notes.txt && echo same

- [ ] It decrypts with `crypt.sh` (on a copy, in a throwaway folder, which is then
      removed):

          mkdir /tmp/safetest-cryptsh && cp notes.txt.crypt /tmp/safetest-cryptsh/
          (cd /tmp/safetest-cryptsh && PATH-TO-REPO/safe_tools/crypt.sh -d notes.txt.crypt)
          cmp /tmp/safetest-cryptsh/notes.txt originals/notes.txt && echo same
          /bin/rm /tmp/safetest-cryptsh/notes.txt /tmp/safetest-cryptsh/notes.txt.crypt
          /bin/rmdir /tmp/safetest-cryptsh

- [ ] The first Encrypt dialog says once which copies of a deleted original can remain (SSD,
      previews, Spotlight, Time Machine); later ones do not. A file in a synced folder (copy a
      throwaway file into the sync service's folder) gets a sentence in the dialog that the
      sync service keeps a plain copy in its trash and version history. Delete that copy there
      afterwards.
- [ ] A password with letters of another script or an emoji (paste `Пароль-🔐` twice): Safe
      says that such a password could only be pasted later, and takes it when it is given
      twice again. Type a Latin password with accents (`Grüße-zwei`): no such note.
- [ ] Select two files at once and encrypt them with one password: each gets its own
      `.crypt` file.
- [ ] Encrypting a file whose `NAME.crypt` exists already is refused, and nothing
      changes.
- [ ] A file with a second name is refused, because the plaintext would stay under that
      name: `ln notes2.txt notes2-link.txt` (with a throwaway `notes2.txt`), then Encrypt
      with Safe on `notes2.txt` says that it has other names (hard links); both names are
      still there. Remove them afterwards.
- [ ] A folder is not encrypted as a file (it becomes a volume instead, section 6), and
      neither is an encrypted disk image: Encrypt with Safe on an encrypted `.dmg` or on a
      `.sparsebundle` says to add it in the Volumes window. An unencrypted `.dmg`
      (`hdiutil create -size 5m -fs APFS -volname safetest-plain safetest-plain.dmg`) is
      encrypted like any file.

## 3. Edit a text file [R2, G4]

- [ ] Double-click `notes.txt.crypt` and type a wrong password: Safe says it is wrong
      and asks again; it never shows garbage. (About three wrong passwords in 256 pass the
      padding check of the current format or of an older one; Safe then says that the
      password is probably not right, because the content does not look like text, and
      offers Type It Again, Export Anyway and Cancel. Choose Type It Again.)
- [ ] With `test-one` the text opens in Safe's editor; the status line says it is
      decrypted in memory only.
- [ ] Type the marker on a new line and press Cmd-S. Safe saves without asking for the
      password again, and the status line names `notes.txt.crypt.bak`.
- [ ] `notes.txt.crypt.bak` holds the version before the change and
      `notes.txt.crypt` the new one (the count is 0, then 1):

          openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in notes.txt.crypt.bak | grep -c 'QX7-PLUM''-4410'
          openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in notes.txt.crypt | grep -c 'QX7-PLUM''-4410'

- [ ] The editor offers no spelling or grammar checks, no autocorrection, no Writing
      Tools, no Look Up, no Services, no Share and no Print, neither in the menus nor
      in the right-click menu of the text. Search (Cmd-F) works inside the window.
- [ ] Copy a line and paste it into another app: it works. A minute later the
      clipboard is empty, if nothing else was copied in the meantime.
- [ ] With Spotlight's clipboard history on (macOS 26, System Settings > Spotlight), the first
      Copy after Safe starts asks first, because Safe cannot clear that history. Copy a
      throwaway marker (not the one of section 4), wait a minute, then look for it in
      Spotlight's clipboard history: note here whether the history kept it (Safe marks the
      copy as concealed and transient; whether the history honours that is not known).
      Kept: ______. Then run the marker search of section 4 for this marker too.
- [ ] The kill ring keeps nothing: put the cursor at the start of the marker's line and
      press Control-K (the line's text goes), then Control-Y (nothing comes back). Press
      Cmd-Z to undo. Then close the editor without saving, lock Safe (Safe > Lock Now),
      open the Volumes window (Cmd-0), click into the field of "Check that this app is
      running before opening" of any volume and press Control-Y: nothing is pasted.
      Press Escape.
- [ ] Change the text and close the window: Safe asks Save, Don't Save or Cancel.
- [ ] A text that is not UTF-8 opens with the right password. Make one in ISO Latin-1 and
      encrypt it with Encrypt with Safe:

          printf 'Gr\374\337e aus K\366ln, und bis bald im Fr\374hjahr!\n' > latin1.txt

      Double-click `latin1.txt.crypt` and type its password: Safe says it could not confirm
      the password, because the content does not look like a .txt file. Open Read-Only shows
      "Grüße aus Köln, ..." with a note above it, and typing changes nothing. Allow Editing,
      add a line with "Köln" and save: the status line says "Text in ISO Latin-1", and the
      file is still in ISO Latin-1:
      `openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in latin1.txt.crypt | file -`.
- [ ] A text of exactly 15 bytes (`printf '123456789012345' > pin.txt`, then Encrypt with
      Safe) opens with "Safe could not confirm the password", because a wrong password gives
      such a short text too often, and Open Read-Only shows it. A text of 14 or 16 bytes opens
      normally.
- [ ] A text file with a byte order mark (`printf '\357\273\277bom\n' > bom.txt`, then
      Encrypt with Safe) opens in the editor without a visible mark, and after a change and
      Cmd-S the decrypted file still starts with `ef bb bf`
      (`openssl enc -d ... -in bom.txt.crypt | xxd | head -1`).
- [ ] Close the editor and quit Safe.

## 4. Search the disk for the marker [R2, R3]

- [ ] With the editor closed, search the places where macOS and apps keep files. This
      takes a few minutes, and macOS may ask whether Terminal may read some folders
      (allow it, or those folders are not searched). It must print nothing:

          grep -rlF --binary-files=text 'QX7-PLUM''-4410' ~/Library /private/var/folders /private/tmp ~/safetest-acceptance 2>/dev/null
          mdfind 'QX7-PLUM''-4410'

## 5. View and export [R3]

- [ ] Encrypt `report.pdf` and `photo.jpg` with Encrypt with Safe. Note the time
      first: `touch ~/safetest-acceptance/stamp`.
- [ ] Double-click `report.pdf.crypt`: the PDF shows in Safe's viewer, read only,
      with Export... and Close. The same for `photo.jpg.crypt`.
- [ ] After closing the viewers, there is no decrypted copy of either file anywhere
      (each search prints nothing):

          for f in report.pdf photo.jpg; do
              want=$(shasum -a 256 < originals/$f)
              find ~/Library /private/var/folders /private/tmp -type f -size "$(stat -f %z originals/$f)c" 2>/dev/null |
                  while read -r g; do [ "$(shasum -a 256 < "$g")" = "$want" ] && echo "$g"; done
          done

- [ ] Select text in the PDF and try to drag it into TextEdit: nothing is dropped. (Copy
      goes through Safe's clipboard rules; a drag must not get around them.)
- [ ] Encrypt `other.docx` and double-click it: Safe offers only Export or Cancel.
- [ ] A damaged file is called damaged, not a wrong password. Make a copy cut short at
      4096 bytes, as an interrupted copy leaves it: `head -c 4096 report.pdf.crypt >
      cut.pdf.crypt` (the PDF must be larger than 4 KB). Double-click `cut.pdf.crypt` and
      type the password: Safe says that the password seems right but the end of the file
      is missing, and offers Export Readable Part. With a wrong password it says only that
      the password was not right. The same with a cut inside a block:
      `head -c 4000 report.pdf.crypt > cut.pdf.crypt`. Delete `cut.pdf.crypt`.
- [ ] A damaged file whose start Safe cannot recognise: `head -c 30000 /dev/urandom >
      blob.bin`, Encrypt with Safe, then `head -c 4096 blob.bin.crypt > cut.bin.crypt`.
      Double-click `cut.bin.crypt` and type the password twice: Safe offers Export Readable
      Part, and the export equals the start of the original:
      `cmp -n 4064 EXPORTED blob.bin && echo same`. Delete the copies.
- [ ] A scanned PDF (a page that is only a picture of text, from Preview's File > Import
      from iPhone or a scanner, or a screenshot saved as PDF) shows in the viewer; no
      addresses or dates in it are underlined as links, and text cannot be selected in the
      picture (Live Text is off). Encrypt it, view it, and run the marker search for a word
      on the page.
- [ ] Right-click `report.pdf.crypt` > Export with Safe: the save dialog proposes
      `report.pdf` next to it, Safe warns that the copy is not encrypted, and the
      exported file is identical: `cmp report.pdf originals/report.pdf && echo same`.
      Delete the exported copy.
- [ ] A text file can be exported too, from the editor's menu and with Export with
      Safe.
- [ ] Export with Safe on `report.pdf.crypt`, and type `REPORT.PDF.CRYPT` as the name in
      the save dialog: Safe refuses ("Not exported"), and `report.pdf.crypt` is still
      encrypted.
- [ ] For a `.crypt` file inside an open volume, Export proposes the Desktop, and the
      warning says that a copy deleted inside a volume stays readable in its image.

## 6. Volumes [R4]

- [ ] Open Safe from the Applications folder: the Volumes window appears.
- [ ] New Empty...: name `safetest-empty`, in `~/safetest-acceptance`, 100 MB, the
      password twice. `safetest-empty.sparsebundle` appears (a package of many small
      files), and `hdiutil isencrypted safetest-empty.sparsebundle` says it is
      encrypted.
- [ ] Open: Safe asks for the password, and the volume appears in the Finder's sidebar and a
      Finder window. Safe mounts it in a folder of its own, not in `/Volumes`, so that other
      accounts on the Mac cannot read it (`hdiutil info | grep safe-volume` shows where).
      Copy a few files onto it. Close: it disappears from the Finder.
- [ ] A wrong password does not open it.
- [ ] New from Folder...: choose `project`, save the sparse bundle in
      `~/safetest-acceptance`. Safe checks the copy, deletes `project`, and says once
      that deleted files may linger on an SSD, and that previews (Quick Look thumbnails)
      and the Spotlight index can keep copies outside the volume, so FileVault should be
      on, that a sync service keeps plain copies in its trash and version history, and that
      Time Machine keeps older copies. Open the new volume: it holds exactly
      the folder's files: `diff -r originals/project "$(hdiutil info | awk -F'\t' '/safe-volume.*project$/ {print $NF}')" && echo same`.
- [ ] New from Folder on a folder with a file that has a second name outside it
      (`mkdir linked && echo x > linked/a.txt && ln linked/a.txt outside.txt`): Safe refuses,
      names `a.txt` and says why. Remove `linked` and `outside.txt`.
- [ ] Change Password...: afterwards the new password works, and Safe says that a copy of
      the volume kept from before still opens with the old password. Check that: copy the
      sparse bundle before the change (`ditto safetest-empty.sparsebundle old-copy.sparsebundle`),
      change the password, then double-click `old-copy.sparsebundle`: the old password opens
      it. Delete the copy.
- [ ] Add Existing...: an encrypted disk image made for the test
      (`hdiutil create -size 20m -fs APFS -encryption AES-256 -volname safetest-old safetest-old.dmg`)
      is added; an unencrypted one is refused.
- [ ] Remove from List: the entry goes, the image stays on the disk.
- [ ] "Check that this app is running before opening" with a name that is not running,
      such as `NoSuchSyncApp`: Safe warns before opening and asks whether to go on.
- [ ] Inside an open volume, encrypt a file with Encrypt with Safe: the password dialog
      says that the deleted plain copy stays readable in the volume's image, and that files
      are best encrypted before they are moved into a volume. Close the volume. Opening
      that file needs both passwords: the volume's, then the file's.
- [ ] Optional, with a large folder (a few GB): New from Folder, and force quit Safe
      (Option-Command-Escape) while it says "Deleting the folder". Start Safe again: it
      says that it did not finish deleting a folder, names where the unencrypted rest is,
      and deletes it only after Delete.
- [ ] Copy a sparse bundle to another Mac (or let a sync service carry it). There,
      without Safe, a double-click in the Finder and the password open it, with the
      files on it.

## 7. Locking [G4]

- [ ] Open a text file without changes, a second text file with unsaved changes, a
      PDF and a volume, and copy a line of text.
- [ ] Lock the screen (Control-Command-Q) and unlock: the unchanged text file and the
      PDF are closed; the changed text file shows a lock, and its password shows the
      text again with the changes; the volume is closed; the clipboard is empty.
- [ ] The same after sleep (Apple menu > Sleep).
- [ ] The same after 10 minutes without touching the Mac (with the screen lock set to
      start later than that).
- [ ] With a file on the volume open in another app, lock and unlock: the volume
      stays open, nothing is forced, and Safe says so when you come back.
- [ ] Encrypt a text file on an open volume, open it in Safe, change it without saving,
      and lock: the volume is closed too, and the editor keeps the changes behind its lock.
      After unlocking the editor with the file's password, Safe offers Open “NAME” Again;
      with the volume's password the volume opens at the same place as before, and
      Cmd-S saves normally. With Not Now, Cmd-S offers the same again.
- [ ] With Safe in front and a busy volume, wait 10 minutes without touching the Mac (with
      the screen lock set later): when you move the mouse again, Safe says that the volume
      is still open, without first switching to another app. No message appears while Safe
      locks.
- [ ] Double-click `latin1.txt.crypt` (section 3), type its password, and lock the screen
      while "Safe could not confirm the password" is open. After unlocking, click Open
      Read-Only: Safe asks for the password again instead of showing the text.
- [ ] Open a volume and keep a file on it open in another app; quit Safe with Quit Anyway,
      start Safe again, close that file and lock: the volume is closed.

## 8. Old formats and the long term [G5]

- [ ] Make files in two old formats with macOS's `openssl` (it asks for a password):

          cp originals/notes.txt old.txt
          /usr/bin/openssl enc -e -aes-256-cbc -md md5 -in old.txt -out old-md5.txt.crypt
          /usr/bin/openssl enc -e -rc4 -md md5 -in old.txt -out old-rc4.txt.crypt
          /bin/rm old.txt

- [ ] Double-click each: Safe opens it, names the old format and offers to save it in
      the current one. After saving, it opens with the current command:
      `openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in old-md5.txt.crypt | cmp - originals/notes.txt && echo same`.
- [ ] An old RC4 file of a type Safe cannot check opens for export: with a throwaway binary
      file, `head -c 4080 /dev/urandom > keys.bin`, then
      `/usr/bin/openssl enc -e -rc4 -md md5 -nosalt -in keys.bin -out keys.bin.crypt`.
      Double-click `keys.bin.crypt` and type its password: Safe says it was not right. Type
      the same password again: Safe offers Export as an Old RC4 File, then asks which kind
      (crypt.sh before 1.4); the exported copy is identical: `cmp keys.bin EXPORTED && echo same`.
      About once in 128 tries an AES variant gives a result with this password instead, and
      Safe asks "Is this the right password?": choose Other Readings, then crypt.sh before
      1.4; the export is identical as well. Delete the copies.
- [ ] An old file in another encoding opens too: make `latin1.txt` again with the
      `printf` of section 3, then
      `/usr/bin/openssl enc -e -aes-256-cbc -md md5 -in latin1.txt -out old-latin1.txt.crypt`
      and `/bin/rm latin1.txt`. Double-click `old-latin1.txt.crypt`: Safe says it could not
      confirm the password, and Open Read-Only shows the text.
- [ ] `~/Applications/Safe.app/Contents/MacOS/Safe --self-test` exits with status 0,
      and so does `python3 PATH-TO-REPO/tools/safe-decrypt.py --self-test`.
- [ ] If Docker runs, the Docker image opens a file Safe made. Copy
      `originals/notes.txt` to `fresh.txt`, encrypt it with Encrypt with Safe, then
      compare the checksum printed in the container with
      `shasum -a 256 originals/notes.txt`:

          docker run --rm -it --network none -v ~/safetest-acceptance:/home/user fherwig/safe:22.0 \
              sh -c 'openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in fresh.txt.crypt | sha256sum'

- [ ] `app/scripts/time-capsule.sh DIR`, with a folder outside the repository (a
      backup disk, for example), writes the image archive and its record, and the
      record says the digest matches `tools/docker-image.txt`.
- [ ] The developer tests pass on this build, including the check that a deliberately
      broken self-test makes Safe refuse to encrypt, and that failed checks keep the
      original file (R1) and the folder (R4).

## 9. Verify, update and uninstall with the agent [G2]

- [ ] Ask the agent to verify the installation: it runs the checks of section 6 of
      `INSTALL-AGENT.md`, and all pass.
- [ ] Ask it to update (after a new commit or version): it asks you to quit Safe
      first, rebuilds, replaces the app, and the list of volumes is still there.
- [ ] Ask it to uninstall after a New from Folder that was stopped while deleting (section
      6, the optional step, answered Not Now): the agent sees `pendingDeletes` 1 in
      `Safe --check` and asks you to answer Safe's question first.
- [ ] Ask it to uninstall: `~/Applications/Safe.app` and
      `~/Library/Application Support/SafeDocker` are gone, and every `.crypt`,
      `.crypt.bak` and sparse bundle in `~/safetest-acceptance` is still there and
      opens with `openssl` or a double-click in the Finder.
- [ ] At no point did the agent ask for, type or see a password.

## 10. Help, tooltips and keyboard shortcuts

- [ ] Help > Safe Help (Shift-Command-/, shown as ⌘?) opens the help window. It is one
      window: choosing Safe Help again brings the same window to the front. The list on the
      left names eleven sections; clicking one shows it, and scrolling the text moves the
      selection in the list. The window can be resized, and the text reads well in light and
      dark mode (System Settings > Appearance).
- [ ] Type `sparse` in the help's search field: the first place is selected; Return finds the
      next, Shift-Return the one before. Command-F in the help window puts the cursor in the
      search field.
- [ ] Help > Keyboard Shortcuts opens the table of shortcuts. Each shortcut it lists does what
      it says, and the menus show the same keys.
- [ ] The "?" buttons: in the Volumes window (Volumes), at the bottom right of an editor
      (Opening and editing; while the text is locked, Locking), in the viewer's bar (Viewing
      and exporting), and in a password dialog (Passwords). With the password dialog still
      open, the help window can be scrolled; close the dialog with Cancel.
- [ ] Hover over each button, field and checkbox of the Volumes window, an editor (also its
      search field and the lock), the viewer and a password dialog: a short tooltip appears.
      Close and Remove from List say what may surprise; Open and Close end with their
      shortcuts.
- [ ] Volume menu: with the Volumes window in front, ⌘N, ⇧⌘N and ⇧⌘A start New Empty, New
      from Folder and Add Existing (Cancel each). Select a closed test volume: ⌘↩ opens it, ⌘E
      closes it. Return in the list opens the selected volume; Delete asks before removing it.
      With an editor in front, Open Volume and Close Volume are dimmed, and Command-Down Arrow
      and Command-Delete still work in the text.
- [ ] Viewer: in a PDF of several pages, ⌘+, ⌘=, ⌘-, ⌥⌘0 and ⌘9 zoom; ⌥⌘↓ and ⌥⌘↑ turn the
      pages. In a large picture the same zoom keys work, and Zoom to Fit fills the window. The
      View menu is dimmed while an editor or the Volumes window is in front.
- [ ] The menus still have no Spelling, Substitutions, Writing Tools, Services, Print or Share.
- [ ] Optional: give Encrypt with Safe a shortcut in System Settings > Keyboard > Keyboard
      Shortcuts... > Services > Files and Folders, as the help describes, and use it on a test
      file in the Finder. Remove the shortcut again if you do not want it.

## 11. Languages, Settings and the German keyboard (version 0.3.0)

- [ ] Safe > Settings... (⌘,) opens the Settings window, with Language: System, English,
      Deutsch. Hover over the popup, the text and the "?" button: each has a tooltip, and "?"
      opens the help at Settings and language.
- [ ] Open a test text in the editor, type something without saving, and open the Volumes
      and help windows. Choose Deutsch: at once the menu bar reads Safe, Ablage, Bearbeiten,
      Darstellung, Volume, Fenster, Hilfe; the Volumes window, the help and the Settings window
      are German. The editor stays open with its text and its unsaved change, in English, and
      its next opening is German. Choose English again: the same in reverse.
- [ ] With German chosen, look through the menus: the Edit menu reads Widerrufen,
      Wiederholen, Ausschneiden, Kopieren, Einsetzen, Löschen, Alles auswählen, Suchen, as in
      TextEdit; no Schreibtools, Diktat or Emoji item appears. Open a few dialogs (Encrypt
      File, New Empty, a wrong password, Quit with a busy volume): the German reads naturally,
      no button or label is cut off, Escape is Abbrechen and Return the default button.
- [ ] The restart offer: with nothing open in Safe (no text, viewer or volume), switch to the
      language macOS does not use for Safe. The Settings window says that the Open and Save
      dialogs and the About window change after a restart, and offers Safe neu starten /
      Restart Safe, which quits and starts Safe again in the new language. With a text open,
      it says so instead and offers no restart.
- [ ] System: with Deutsch above English in System Settings > General > Language & Region,
      System gives German; with English above Deutsch, English. Quit and start Safe: the
      choice is kept.
- [ ] German keyboard (add the German input source for this check only, if it is not there,
      and remove it afterwards): ⇧⌘ß opens Safe Help (the menu shows ⌘?); in a viewer,
      Command and the + key zooms in, ⇧⌘0 (=) zooms in too, Command and - zooms out, ⌥⌘0 is
      Actual Size; ⌘, opens Settings; ⌘Z undoes and ⇧⌘Z redoes in the editor (by character,
      not by the key's place). The help's table of shortcuts describes the same keys.
- [ ] German password: encrypt a test file with the password `Prüfung-ß` typed on the German
      keyboard, then open it again by typing the same password. It opens; in the Terminal,
      `openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt` with the
      same password typed there opens it too.
- [ ] German Finder services: with macOS itself in German (or a test account in German),
      right-click a test file: the service is called Mit Safe verschlüsseln, a `.crypt` file
      offers Mit Safe öffnen and Mit Safe exportieren, and Get Info calls the kind
      Verschlüsselte Datei. They follow macOS's language, not Safe's setting, which the help
      says too. (The Finder may need a log out and in, or `/System/Library/CoreServices/pbs
      -update` run by the owner, to show new service names.)

## 11a. The release: installer, Terminal and licence (version 0.3.2)

The automatic tests inspect the installer and run `install-safe.sh` into throwaway folders
only. On a Mac or a user account without Safe (a new test account is easiest):

- [ ] Download `Safe.pkg` from the release with a browser and open it: macOS refuses it the
      first time. On macOS 15 or later System Settings > Privacy & Security offers Open
      Anyway, on macOS 13 and 14 right-click > Open does. The installer says it installs for
      this user only, asks for no administrator's password, and puts Safe.app into
      `~/Applications`. Safe then opens without another question (or note the one it asks).
- [ ] After starting Safe once, Encrypt with Safe is in the Finder's right-click menu. [G2]
- [ ] In the Terminal of another test account,
      `curl -fsSL https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh | bash`
      installs and opens Safe without any question from macOS, and `... | bash -s -- --uninstall`
      removes the app and nothing else.
- [ ] Safe > About Safe shows "© 2026 Falk Herwig. GPL-3.0-or-later.", and the help has
      "Licence and source code" in "Old files and the long term", in both languages.

## 12. Clean up

- [ ] Close the test volumes, move `~/safetest-acceptance` to the Trash and empty it.
      The marker is left only inside encrypted files.

Result: accepted / not accepted, on ______ (date). Notes:
