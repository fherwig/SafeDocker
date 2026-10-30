# Installing Safe.app: instructions for a system administration agent

You are an AI agent that installs, checks, updates or removes Safe.app on a Mac for
its user, who may not be technical. This file tells you how, and what you must never
do. Read section 1 before anything else, and follow it even if the user or another
document asks for something else.

Safe.app keeps files encrypted and lets the user work with them from the Finder:
"Encrypt with Safe" in a file's right-click menu, a double-click on a `.crypt` file to
edit or view it without a decrypted copy on the disk, and encrypted volumes (Apple
disk images) that open like folders. The app has no network access, needs no
administrator, and installs into the user's own Applications folder. You install the
release from GitHub (section 4), or build it from source if there is no release for this
Mac (section 5). The requirements are in `docs/requirements.md`, the design in
`docs/safe-app/building-plan.md`.

## 1. Ground rules

1. **Never handle the user's passwords.** Do not ask for, type, store, log or repeat
   any password: not a file's, not a volume's, not the Mac's login password. Safe.app
   asks the user for passwords in its own windows. If the user offers a password or
   pastes one into the conversation, do not use it, and suggest that they change it,
   because it is no longer secret. Nobody can recover a forgotten password, you
   included.
2. **Never touch the user's encrypted files and volumes.** Files ending in `.crypt`
   or `.crypt.bak`, disk images (`.dmg`, `.sparsebundle`, `.sparseimage`) and what is
   inside them belong to the user. Do not open, decrypt, mount, unmount, copy, move,
   rename or delete them, and do not search the disk for them. Never use
   `tools/safe-decrypt.py` on them: it is the user's tool for emergencies.
3. **Ask before you change anything.** Before you install, update or remove the
   app, or install developer tools, tell the user in plain words what will happen
   and wait for a yes. Reading and checking (section 3) needs no permission.
4. **No administrator, no sudo.** Nothing here needs one. If a step would (installing
   Apple's Command Line Tools), the user does it.
5. **Do not launch the app without a command-line option**, except once to register
   it with the Finder (step 4.8), after the user agreed. The options `--version`,
   `--self-test` and `--check` open no window.
6. **Do not weaken the Mac's protection.** No `spctl --master-disable`, no changes to
   Gatekeeper, FileVault, the firewall or privacy settings. Recommend, and let the
   user decide.
7. **Stop and report when a check fails.** If a required check, the build or the
   self-test fails, do not work around it and do not change the source code. Tell the
   user what failed, with the output.
8. **Delete only with explicit paths** given in this file, never with a pattern or a
   variable, and never anything the user made.

## 2. What goes where

| What | Where |
|---|---|
| The app | `~/Applications/Safe.app` (no administrator needed) |
| The list of volumes the user added (names and paths, no passwords), which of them Safe opened, and where an unencrypted folder lies that New from Folder did not finish deleting (`pending-deletes.json`, see step 8.2) | `~/Library/Application Support/SafeDocker/` |
| The volumes Safe has open, while they are open | a folder of the user's own temporary folder (`$TMPDIR/safe-volume-...`), not `/Volumes`, so that other accounts on the Mac cannot read them; Safe removes it when the volume is closed. Never delete it yourself |
| The app's settings | `~/Library/Preferences/io.github.fherwig.safedocker.plist` |
| A release while it is checked (section 4) | `~/Downloads/safe-install/`, deleted afterwards |
| Build products, when built from source | `~/Library/Caches/SafeDocker-build/` and `app/dist/` in the checkout |
| The source, when built from source | the checkout, `~/src/Safe` (or `~/src/SafeDocker`, from before the repository was renamed); keep it for updates |
| The user's encrypted files and volumes | wherever the user keeps them; never part of the install |

Nothing else: no login item, no background service, no helper tool, no kernel
extension, nothing outside the home folder. The bundle identifier is
`io.github.fherwig.safedocker`; the app's process is called `Safe`. The repository is
<https://github.com/fherwig/Safe> (it was called SafeDocker before; GitHub forwards the old
name, and the identifier and the folder names above keep it). Its branch `main` holds the
latest release, and each release is on <https://github.com/fherwig/Safe/releases>.

## 3. Check the Mac

Run the check script. Without a checkout, download the one on `main`, look at it, and run it
with bash:

    mkdir -p ~/Downloads/safe-install
    curl -fsSL -o ~/Downloads/safe-install/agent-check.sh https://raw.githubusercontent.com/fherwig/Safe/main/app/scripts/agent-check.sh
    bash ~/Downloads/safe-install/agent-check.sh

In a checkout (section 5), run `~/src/Safe/app/scripts/agent-check.sh` instead. It runs from
any folder, changes nothing, needs no password, and prints one JSON object (exit status 0
whenever it printed one):

```json
{
  "tool": "agent-check.sh",
  "format": 1,
  "ready_to_install": true,
  "ready_to_build": true,
  "warnings": [],
  "checks": {
    "macos": {"level": "required", "ok": true, "value": "26.3 (25D125)", "hint": "..."},
    "filevault": {"level": "warn", "ok": true, "value": "FileVault is On.", "hint": "..."},
    "swift": {"level": "build", "ok": true, "value": "6.2.4 (...)", "hint": "..."},
    "installed_app": {"level": "info", "ok": false, "value": "not installed", "hint": "..."}
  }
}
```

Every check has a `level`, `ok`, a `value` and a `hint` that says what to do. The
levels:

- **required**, needed to run Safe.app: macOS 13 or later (`macos`), an Apple silicon
  or Intel Mac (`architecture`), 200 MB free (`free_space`), and `hdiutil`,
  `codesign`, `ditto`, `shasum` and `curl`, which come with macOS. If one fails,
  `ready_to_install` is false: stop and tell the user, with the hint. This is all that
  installing the release (section 4) needs.
- **build**, needed only to build from source (section 5): macOS 14.5 or later
  (`macos_for_build`), Apple's Command Line Tools (`developer_tools`), Swift 6.0 or later
  (`swift`), the macOS SDK 15.2 or later (`macos_sdk`; Command Line Tools 16.2 or later,
  which need macOS 14.5), `lipo`, `git`, `plutil`, `xattr` and 2 GB free
  (`free_space_for_build`). If one fails, `ready_to_build` is false; install the release
  instead. On macOS 13 to 14.4 Safe.app runs but cannot be built, because the Command Line
  Tools it needs do not install there. The Command Line Tools need an administrator to
  install: the user runs `xcode-select --install` and confirms the dialog. The script never
  runs a developer tool that is missing, because macOS would then open that dialog by itself.
- **warn**, recommended: FileVault on (`filevault`) and encrypted swap
  (`encrypted_swap`). Their names are listed in `warnings`. Tell the user and
  recommend FileVault (System Settings > Privacy & Security > FileVault), then go on.
  Without FileVault, plain copies deleted from the disk can still be read from it.
- **info**, facts for your decisions, never a failure: `source` (the version in the
  checkout, if the script runs from one), `installed_app` (a Safe.app in `~/Applications`, its
  version and whether its signature is valid: if there is one, install means update, section
  7), `other_copy` (a Safe.app in `/Applications`, which these instructions never make,
  replace or remove: if there is one, tell the user that there would be two copies, both
  claiming `.crypt` files; they can remove it in the Finder, which may ask for an
  administrator, or keep it), `app_running`, `app_data`, `pending_deletes` (the number of
  unencrypted folders that Safe did not finish deleting; it matters before an uninstall, step
  8.2) and `docker`. If `HOME` is not set in your shell, the script asks the directory service
  for the home folder; if that fails too, `free_space` and `installed_app` say `unknown`: run
  it again in a normal shell of the user. Docker is not needed by Safe.app; it is only used
  by the older terminal tool and the time capsule (section 10).

## 4. Install from the release

This is the usual way. The release holds the same app that `build-app.sh --release` makes
from the source of its tag, built, signed ad hoc and self-tested. Its files are `Safe.zip`
(the app), `Safe.pkg` (the installer, for people), the same two under names with the version
(`Safe-VERSION.zip`, `Safe-VERSION.pkg`), and `SHA256SUMS`.

**The short way.** `install-safe.sh` does steps 4.3 to 4.8 below, with the same checks, and
stops on any failure. Download it, look at it, and run it, after the user agreed (step 4.1):

    mkdir -p ~/Downloads/safe-install
    curl -fsSL -o ~/Downloads/safe-install/install-safe.sh https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh
    bash ~/Downloads/safe-install/install-safe.sh

It ends with `Installed Safe VERSION in ...`, starts Safe once (step 4.8) and prints what the
user can do next; then go on with step 4.9. It prints none of the paths that `--check`
reports. If Safe is running it stops with "Safe is running" (your shell has no terminal to
wait in): ask the user to quit Safe, then run it again. It needs no sudo; never run it with
one. Run it outside your own command sandbox (step 5.4). The steps by hand:

1. **Ask the user.** For example: "I will download Safe from its page on GitHub, check
   it and put it in the Applications folder of your home folder. It takes a minute and
   needs no administrator password. Afterwards Safe opens once, so that the Finder knows
   it; you can close that window. Shall I?"
2. **Check** (section 3). Go on only if `ready_to_install` is true. If `installed_app`
   reports an installed Safe.app, this is an update: follow section 7. If `other_copy`
   reports one in `/Applications`, tell the user (section 3).
3. **Download** with `curl`, which, unlike a browser, sets no quarantine attribute, so
   that macOS opens the app without asking:

       mkdir -p ~/Downloads/safe-install
       curl -fL -o ~/Downloads/safe-install/Safe.zip https://github.com/fherwig/Safe/releases/latest/download/Safe.zip
       curl -fL -o ~/Downloads/safe-install/SHA256SUMS https://github.com/fherwig/Safe/releases/latest/download/SHA256SUMS
       cd ~/Downloads/safe-install && grep ' Safe.zip$' SHA256SUMS | shasum -a 256 -c -

   It must print `Safe.zip: OK`. Otherwise stop, delete the folder (step 4.9) and tell the
   user; do not fall back to another source without asking. A specific version is at
   `https://github.com/fherwig/Safe/releases/download/vVERSION/Safe-VERSION.zip` (check it
   with the line ` Safe-VERSION.zip$`). If the download fails with 404, there is no release
   yet: tell the user, and offer section 5.
4. **Unpack and check the signature**:

       ditto -x -k ~/Downloads/safe-install/Safe.zip ~/Downloads/safe-install
       codesign --verify --strict --verbose=2 ~/Downloads/safe-install/Safe.app
       codesign -dv ~/Downloads/safe-install/Safe.app 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier)'

   The identifier must be `io.github.fherwig.safedocker`. For now the signature is ad
   hoc (`Signature=adhoc`). Once the app is signed with a Developer ID and notarized,
   this section will name the Team ID to expect, and
   `spctl -a -vv Safe.app` must report `source=Notarized Developer ID`.
5. **Self-test**: `~/Downloads/safe-install/Safe.app/Contents/MacOS/Safe --self-test` must
   exit with status 0. In the JSON report, `knownAnswers`, `wrongPasswordRejected`,
   `networkBlocked` and `ok` are all `true`, `failures` names any failure, and
   `configuration` is `release`. If it fails, stop (rule 7): an app that fails its
   self-test refuses to encrypt.
6. **Install**:

       mkdir -p ~/Applications
       ditto ~/Downloads/safe-install/Safe.app ~/Applications/Safe.app

   `ditto` keeps the signature intact. If `~/Applications/Safe.app` exists already,
   use section 7 instead.
7. **Check the installed app**:

       ~/Applications/Safe.app/Contents/MacOS/Safe --version
       ~/Applications/Safe.app/Contents/MacOS/Safe --check
       codesign --verify --strict ~/Applications/Safe.app

   `--version` prints the version. `--check` exits with status 0
   and prints JSON: the version (`version`), the build (`configuration`, which must be
   `release`), the number of reference files found (`fixturesFound`, more than zero, and
   `manifestFound` true), whether the network is blocked (`networkBlocked`, it must be
   true), the volumes in the user's list and whether each image exists (`volumes`), and
   every disk image attached on the Mac (`attachedImages`), the user's own encrypted
   volumes included. `volumes` and `attachedImages` name the user's files: do not repeat
   their paths, to the user's chat or to anyone else, and do not act on them. Check only
   that the command exits with status 0, that `configuration` is `release`, and that
   `networkBlocked` and `manifestFound` are true. `pendingDeletes` is the number of
   unencrypted folders that New from Folder did not finish deleting (Safe offers to finish at
   its next start); it matters before an uninstall (step 8.2). An `attachedImagesError` means
   that `hdiutil` could not list the attached images: not an install failure; do not act on it,
   and do not repeat its text if it names files. If the report has a `volumeListError`,
   Safe could not read its list of volumes, so its Volumes window will be empty: tell the
   user so, without repeating paths; Safe keeps the unreadable file as
   `volumes.json.broken-DATE` when it next saves the list, and the user can add the
   volumes again with Add Existing. `codesign` prints nothing when the signature is valid.
8. **Register it with the Finder**, with the user's agreement from step 1:

       open ~/Applications/Safe.app

   Safe starts and shows its Volumes window; the user can quit it (Safe > Quit Safe).
   This makes the Finder know the `.crypt` document type and the "Encrypt with Safe",
   "Open with Safe" and "Export with Safe" services.
9. **Delete the download folder**, which holds only the release and the scripts:
   `/bin/rm -rf ~/Downloads/safe-install`.
10. **Tell the user** how to use it (section 11 has a summary to adapt).

If the user downloaded the zip or the installer with a browser, macOS refuses to open it at
first, because of the quarantine attribute and the missing Developer ID; on macOS 15 and
later the user allows it in System Settings > Privacy & Security > Open Anyway (README.md,
"The app is not signed by Apple"). That is the user's decision, not yours (rule 6). For a
zip from a browser, check its checksum as in step 3; then, with the user's agreement, you may
instead remove the attribute from the unpacked app only:
`xattr -dr com.apple.quarantine Safe.app`.

## 5. Install from source

Only when there is no release, when the user wants the app built on their Mac, or for a
version that has no release yet. It needs `ready_to_build` (section 3). The commands use the
full path of the checkout, `~/src/Safe`, because the shell of your tool may not keep its
working folder from one command to the next. If the checkout is somewhere else (for example
`~/src/SafeDocker`, from before the repository was renamed), use that path everywhere
instead, also in the `/bin/rm -rf` lines (rule 8). `bash ~/src/Safe/install-safe.sh
--from-source` does steps 5.3 to 5.9 with the same checks, but leaves `app/dist` in the
checkout; remove it as in step 5.8.

1. **Ask the user.** For example: "I will download the source of Safe, build it on
   this Mac and put it in the Applications folder of your home folder. It takes five
   to fifteen minutes and needs no administrator password. Afterwards Safe opens once, so
   that the Finder knows it; you can close that window. Shall I?"
2. **Get the source** into a folder that no sync service (iCloud Drive, Nextcloud,
   Dropbox) watches, because the build writes `app/dist/` inside it. First see whether git
   can run: on a Mac without Apple's Command Line Tools, `/usr/bin/git` is a stub that opens
   an install dialog on the user's screen, so do not run `git` before this test.

       test -x "$(xcode-select -p 2>/dev/null)/usr/bin/git" && echo "git can run"

   Then the first case that fits:

   - **A checkout exists already**, `~/src/Safe`, or `~/src/SafeDocker` from an earlier
     install (one kept at an uninstall, step 8.4, or left by an earlier attempt). If it has a
     `.git` folder and git can run, bring it up to date on `main`; these commands work also
     for a clone of another branch (an early one of `safe-app`, for example) and for one made
     with `--depth 1` or `--single-branch`, which knows only the branch it was made from:

         git -C ~/src/Safe remote set-branches --add origin main
         git -C ~/src/Safe fetch origin
         git -C ~/src/Safe switch main
         git -C ~/src/Safe pull --ff-only

     `switch` alone does not bring a branch that is checked out already up to date; `pull`
     does. If git refuses (local changes, not a fast-forward), stop and tell the user. If it
     has no `.git` folder (it was downloaded as a zip), or git cannot run: if it holds a
     `safe.conf` (the settings of the older terminal tool, step 8.4), leave it alone, download
     and unpack the zip as in the next point but without its `mv`, which leaves the source in
     `~/src/Safe-main`, use that path instead in every command below, and tell the user;
     otherwise, with the user's agreement, remove it with `/bin/rm -rf ~/src/Safe` (or the
     path it has) and go on with the case below that fits.
   - **git cannot run** (no Command Line Tools yet): download the source as a zip, with tools
     that come with macOS, then run the check of step 3, which reports `developer_tools` false
     and says what the user must do (they install the tools; rule 4):

         mkdir -p ~/src
         curl -fL -o ~/src/Safe-main.zip https://github.com/fherwig/Safe/archive/refs/heads/main.zip
         ditto -x -k ~/src/Safe-main.zip ~/src
         mv ~/src/Safe-main ~/src/Safe
         /bin/rm ~/src/Safe-main.zip

     `mv` needs `~/src/Safe` not to exist (the first point).
   - **git can run**:

         mkdir -p ~/src
         git clone https://github.com/fherwig/Safe.git ~/src/Safe

3. **Check**: `~/src/Safe/app/scripts/agent-check.sh` (section 3). Go on only if
   `ready_to_build` is true. If `installed_app` reports an installed Safe.app, this is
   an update: follow section 7. If `other_copy` reports one in `/Applications`, tell the
   user (section 3).
4. **Build**:

       ~/src/Safe/app/scripts/build-app.sh --release

   It compiles for Apple silicon and Intel, joins the two, signs the app ad hoc with
   the hardened runtime, checks the signature and runs the new app's self-test (on
   Apple silicon also the Intel half, under Rosetta, if it is installed); a build
   whose self-test fails stops with an error, is not zipped, and is renamed to
   `app/dist/Safe-SELF-TEST-FAILED.app` without its document type and services (section
   9). It ends with `Built .../app/dist/Safe.app`, the version, `x86_64 arm64`,
   `release` and a SHA-256 checksum, and exits with status 0. Build products go to
   `~/Library/Caches/SafeDocker-build/`.

   **Time.** The build can take up to 15 minutes on a slow or busy Mac, and prints
   nothing for minutes while it compiles (`Compiling SafeApp ...`). Give the command a
   timeout of at least 20 minutes, or run it in the background and wait for `Built ...`
   and exit status 0. An interrupted build goes on where it stopped when run again.

   **Your own sandbox.** Run the build, `install-safe.sh` and the Safe checks of steps 4.5,
   4.7, 5.5 and 5.8 outside your own command sandbox, if your tool has one (Codex CLI by
   default, Claude Code in sandbox mode). Inside one, the build fails with
   `sandbox-exec: sandbox_apply: Operation not permitted`, and Safe says
   `cannot deny network access: Operation not permitted` and exits with status 1,
   because neither can start a sandbox of its own inside another. A rebuild whose
   compiled parts are cached may get further and stop at the self-test instead, with
   `The self-test could not run because this shell is inside another sandbox` and exit
   status 3; that build is renamed to `app/dist/Safe-NOT-SELF-TESTED.app`, without its
   document type and services, because it was not tested. The script notes a sandbox at
   its start (`Note: this shell runs inside a sandbox`); `build-app.sh --check-sandbox` only
   checks, and builds nothing. None of this is a fault of the app: ask the user to let you
   run these commands unsandboxed.
5. **Self-test the build** (the build ran it once; run it again to see the report):

       ~/src/Safe/app/dist/Safe.app/Contents/MacOS/Safe --self-test

   As in step 4.5. A build without `--release` says `"configuration": "debug"`, and its
   version ends in `(debug build)`: build again with `--release`.
6. Optional, a second opinion that needs only Python 3:
   `python3 ~/src/Safe/tools/safe-decrypt.py --self-test` should print
   `self-test passed`.
7. **Install**:

       mkdir -p ~/Applications
       ditto ~/src/Safe/app/dist/Safe.app ~/Applications/Safe.app

   If `~/Applications/Safe.app` exists already, use section 7 instead.
8. **Check the installed app** as in step 4.7. Then remove the build products from the
   checkout, which are no longer needed and would leave a second copy of the app that the
   Finder could find: `/bin/rm -rf ~/src/Safe/app/dist`.
9. **Register it with the Finder** as in step 4.8, with the user's agreement from step 1.
10. **Tell the user** how to use it (section 11 has a summary to adapt).

## 6. Verify an installation

At any time, without changing anything:

    ~/Applications/Safe.app/Contents/MacOS/Safe --version
    ~/Applications/Safe.app/Contents/MacOS/Safe --self-test
    ~/Applications/Safe.app/Contents/MacOS/Safe --check
    codesign --verify --strict ~/Applications/Safe.app

All four exit with status 0, and the JSON of `--self-test` and `--check` says
`"configuration": "release"`. `agent-check.sh` reports the installed version under
`installed_app`, and a second copy in `/Applications` under `other_copy` (section 3). The
`volumes` and `attachedImages` of `--check` name the user's files: do not repeat their
paths (step 4.7). A `volumeListError` means Safe cannot read its list of volumes: tell the
user (step 4.7).

A test with real files is for the user, never for you, because it needs a password:
the owner's checklist is `docs/safe-app/acceptance.md`. You may suggest that the user
tries it with a throwaway file: right-click > Encrypt with Safe, then a double-click
on the new `.crypt` file.

## 7. Update

1. Ask the user. Ask them to save and close their open files, close their volumes in
   Safe's Volumes window, and quit Safe. `pgrep -x Safe` must print nothing; never
   quit or kill Safe yourself, because the user may have unsaved changes in it.
2. Get the new version and check it. The commands use full paths, because a new session of
   yours may start in another folder.
   - From the release: `install-safe.sh` again (section 4, the short way), which replaces
     the old app only after the new one passed its checks; it is then done with step 4 below.
     Or by hand, steps 4.3 to 4.5.
   - From source, a git checkout: bring it up to date on `main` with the four git commands
     of step 5.2 (they also move a checkout of the old branch `safe-app` to `main`). If git
     refuses (local changes, not a fast-forward, or a branch that is gone on GitHub), stop and
     tell the user.
   - From source, a checkout downloaded as a zip (it has no `.git` folder): download
     and unpack the zip again as in step 5.2, without its `mv`, which gives `~/src/Safe-main`.
     If the old checkout holds a `safe.conf`, the settings of the older terminal tool (step
     8.4), leave it alone, use the new folder instead of `~/src/Safe` in the commands below,
     and tell the user. Otherwise, with the user's agreement, replace it:
     `/bin/rm -rf ~/src/Safe`, then `mv ~/src/Safe-main ~/src/Safe`, and delete the zip.
   - From source, then build and check, as in steps 5.3 to 5.5:

         ~/src/Safe/app/scripts/agent-check.sh
         ~/src/Safe/app/scripts/build-app.sh --release
         ~/src/Safe/app/dist/Safe.app/Contents/MacOS/Safe --self-test

3. Replace the app:

       /bin/rm -rf ~/Applications/Safe.app
       ditto ~/src/Safe/app/dist/Safe.app ~/Applications/Safe.app
       /bin/rm -rf ~/src/Safe/app/dist

   (from the release by hand, copy `~/Downloads/safe-install/Safe.app` instead, skip the last
   line, and delete the download folder afterwards, step 4.9). If `agent-check.sh` reported an
   `other_copy` in `/Applications`, it is not replaced: tell the user that it still holds the
   old version, beside the new one in `~/Applications` (section 3).
4. Check it (section 6); `--version` prints the new version. With the user's
   agreement open it once (step 4.8), so that the Finder picks up any new service.

The user's list of volumes, the settings and all encrypted files stay as they were.

## 8. Uninstall

`install-safe.sh --uninstall` does steps 2 and 3 for the app alone, and
`install-safe.sh --uninstall --remove-data` also removes the list of volumes, the settings and
the build products; both stop if `pendingDeletes` is above 0 (step 2) or Safe is running. By
hand:

1. Ask the user, and explain: the app and its list of volumes are removed; the
   encrypted files and volumes stay where they are and stay encrypted. Without Safe
   they still open: a volume with a double-click in the Finder and its password,
   because it is a standard disk image; a `.crypt` file with macOS's own `openssl`
   (`openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt -out FILE`)
   or with `tools/safe-decrypt.py`. Suggest that the user notes where their volumes
   are, from Safe's Volumes window, before the list goes.
2. Ask the user to close their volumes and files. Then run
   `~/Applications/Safe.app/Contents/MacOS/Safe --check`: if `pendingDeletes` is above 0,
   Safe did not finish deleting the unencrypted copy of a folder that it made into a volume,
   and `~/Library/Application Support/SafeDocker` holds the only record of where it is. Ask
   the user to open Safe once and answer its question "Safe did not finish deleting a folder"
   (Delete, or Show in Finder to keep it under another name), then run `--check` again; go on
   only when it says 0, or when the user decides to keep that folder and knows where it is.
   Then ask the user to quit Safe; `pgrep -x Safe` must print nothing.
3. Remove the app and its data, with these explicit paths only:

       /bin/rm -rf ~/Applications/Safe.app
       /bin/rm -rf ~/Library/Application\ Support/SafeDocker
       defaults delete io.github.fherwig.safedocker
       /bin/rm -rf ~/Library/Caches/SafeDocker-build
       /bin/rm -rf ~/src/Safe/app/dist

   The last line removes the build products of a source install, which hold a second
   copy of the app; the folder `app/dist` holds nothing else (use the path of the checkout,
   `~/src/SafeDocker/app/dist` for an older one).

   `defaults delete` reports "Domain ... does not exist" if the app saved no settings;
   that is fine. A copy in `/Applications` (`other_copy` of `agent-check.sh`) is not
   removed by these lines and may need an administrator: tell the user, who removes it in
   the Finder if they want. If
   `~/Library/Saved Application State/io.github.fherwig.safedocker.savedState`
   exists, remove it too.
4. The checkout of the source (for example `~/src/Safe`) holds no user data
   unless the user also uses the older terminal tool from it: if it contains a
   `safe.conf`, leave the checkout alone. Otherwise remove it only if the user wants.
5. Never remove `.crypt` or `.crypt.bak` files, disk images, or anything the user
   made, and never search for them to "clean up".
6. Tell the user it is done. `.crypt` files should now show a plain icon, and a
   double-click asks which app should open them; the Finder may take a while, or a
   log out and in, to forget the app.

## 9. When something goes wrong

- **A required check fails**: tell the user the hint; do not install.
- **The build fails**: show the user the last lines of the output. Do not edit the
  source. If the output says `sandbox-exec: sandbox_apply: Operation not permitted`, or
  the build ends with `The self-test could not run because this shell is inside another
  sandbox` (exit status 3, the build left as `app/dist/Safe-NOT-SELF-TESTED.app`), your
  commands run inside a sandbox of your own tool: ask the user to let you run them
  unsandboxed (step 5.4); this is not a fault of the app. If it
  stopped because your tool's time limit ran out, run it again with a longer one (step
  5.4). Otherwise a clean retry: `/bin/rm -rf ~/Library/Caches/SafeDocker-build`, then
  build again.
- **Safe says `cannot deny network access: Operation not permitted`** (for
  `--version`, `--self-test` or `--check`): the same, a sandbox of your own tool; run
  it outside that sandbox. Safe always denies itself the network first and cannot do
  so inside another sandbox.
- **The self-test fails**: do not install that build, and report it to the user with the
  output. The build is left as `app/dist/Safe-SELF-TEST-FAILED.app`, without its document
  type and services; with the user's agreement remove it afterwards:
  `/bin/rm -rf ~/src/Safe/app/dist`. An installed app that fails its self-test still
  opens files but refuses to encrypt or save, and says so; report it to the user.
- **"Encrypt with Safe" is missing from the right-click menu**: it sits under Quick
  Actions or Services. If it is not there, the user can switch it on in System
  Settings > Keyboard > Keyboard Shortcuts > Services > Files and Folders, or log out
  and in again.
- **A double-click on a `.crypt` file opens another app**: the user selects a
  `.crypt` file in the Finder, File > Get Info, "Open with: Safe", then "Change All".
- **The release's checksum does not match** (step 4.3, or `install-safe.sh` says so):
  the download was cut short or changed on the way. Delete the download folder, try once
  more, and if it happens again, stop and tell the user. Never install that file.
- **macOS says the app "cannot be opened"**: the app carries a quarantine attribute
  (see the end of section 4) or its signature is broken (`codesign --verify --strict`
  says so); reinstall it.
- **A volume does not close**: an app still uses a file on it. The user closes that
  app. Never force a volume to close: other apps may have unsaved work on it.
- **Safe says it "could not confirm the password"**, or that the password is
  "probably not right": the file decrypted, but its content does not look like its
  type (a text in another encoding than UTF-8, for example), or Safe cannot check the
  type. With the right password the file is simply unusual; with a wrong one the
  content is meaningless. Only the user can tell; never try passwords yourself.
- **Safe says a file "is damaged"**: the password seems right, but the end of the file is
  missing (an interrupted copy or sync). The user can export the readable part, or use
  `NAME.crypt.bak` if there is one. **Safe offers "Export as an Old RC4 File" or "Export
  Readable Part"** after the same password was refused twice, or **"Other Readings"** when it
  could not confirm a password: the file may be an old one Safe cannot check, or a damaged
  one whose start it cannot recognise. All of these are the user's decisions.
- **The user cannot type a password with letters of a non-Latin script or emoji**: password
  fields on the Mac, Safe's included, take only Latin keyboard layouts and no emoji. The user
  pastes such a password, and then copies something else so that it does not stay on the
  clipboard. Safe says so when such a password is chosen.
- **Safe refuses a new password "with a line break"**: it was pasted together with
  the end of its line. The user types or pastes it again without it.
- **"Encrypt with Safe" refuses a file**: a disk image belongs in the Volumes window (Add
  Existing), and a file larger than 1 GB in an encrypted volume.
- **The user forgot a password**: nobody can help, and there is no reset.

## 10. Docker, the terminal tool and the time capsule

Safe.app does not use Docker. The repository also holds the older terminal tool
(`safe_load.sh`, see `README.md`), which needs Docker Desktop; Docker Desktop needs an
administrator to install and to update. Do not install Docker for Safe.app, and do not
touch the terminal tool's container (`safe`), its settings (`safe.conf`) or its disk
image unless the user asks.

For the long term the repository keeps two ways to open `.crypt` files that depend
neither on macOS nor on Safe.app (requirement G5):

- `tools/safe-decrypt.py`, a decryptor that needs only Python 3. It is the user's,
  not yours (rule 2). `tools/README.md` describes it.
- The Docker image `fherwig/safe:22.0`, pinned by its digest in
  `tools/docker-image.txt`. With the user's agreement, and only if Docker is running
  and has the image, `app/scripts/time-capsule.sh DIR` saves the image as an archive
  of about 130 MB into `DIR`, with a record of its digest and how to use it. `DIR`
  must exist and lie outside any git repository, for example on the user's backup
  disk. The script never pulls an image and refuses when Docker is not running.

## 11. What to tell the user afterwards

Adapt this to the user:

> Safe is installed in the Applications folder of your home folder.
>
> - To encrypt a file, right-click it in the Finder and choose Quick Actions (or
>   Services) > Encrypt with Safe. Type a password twice. Safe writes `NAME.crypt`
>   next to it and deletes the original only after checking the encrypted copy.
> - To read or change an encrypted file, double-click it and type its password. Text
>   opens in Safe's editor; Cmd-S saves it encrypted again and keeps the previous
>   version as `NAME.crypt.bak`. PDFs and pictures open in a viewer. Nothing
>   decrypted is written to the disk.
> - To get a normal, unencrypted copy, right-click the `.crypt` file and choose
>   Export with Safe.
> - Open Safe from your Applications folder to make and open encrypted volumes.
> - After 10 minutes in which you do not use your Mac, and when it sleeps or locks, Safe
>   hides your files and closes your volumes.
> - A password with letters of a non-Latin script or with emoji cannot be typed into the
>   Mac's password fields; you would have to paste it each time. Latin letters with accents
>   are fine.
> - Encrypt files before they go into a synced folder: a sync service keeps the plain
>   original in its trash and version history.
> - If your Mac keeps a clipboard history (Spotlight on macOS 26), Safe asks before the first
>   copy, because it cannot clear that history.
> - Nobody can recover a forgotten password, so keep yours safe. I never saw it.

Mention any warning from section 3 as well, for example that FileVault is off.
