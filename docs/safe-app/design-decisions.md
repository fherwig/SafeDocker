# Safe.app: design decisions

This file records why Safe.app is a native Mac app without Docker, which designs were
compared, what the reviewers found, which decisions the build took and what is left for
later. It summarises a design study of 2026-10-25: five independent designs for a Mac
app that needs no terminal, an adversarial review of each, and a judge who scored them
and wrote a recommendation. The study's working files are not in the repository.
`docs/requirements.md` holds the requirements, `building-plan.md` the plan that followed,
and `architecture.md` the system as built.

## 1. The question

Today's SafeDocker is a terminal tool. `safe_load.sh` attaches an encrypted disk image,
starts a Docker container without network, and `bd` decrypts `safe.txt.crypt`, opens it
in emacs and encrypts it again. The study asked how to replace this with an app that
needs no terminal (G1), that an AI agent can install for a user who is not technical
(G2), and that keeps today's file format (G3), and whether Docker should stay.

## 2. The five designs

All five kept both layers, the AES-256 disk image and `safe.txt.crypt` in the openssl
format, and the order in which `crypt.sh` saves (`.crypt_new`, check, `.bak`, rename).

| Design | The idea | Docker |
|---|---|---|
| Wrapper | An AppleScript applet that asks for the passwords in native dialogs and opens a Terminal window with `nano` in the existing container; plaintext in a tmpfs without swap inside the container, ciphertext streamed through `docker exec` | at run time |
| Native front end | A Swift editor; every decryption and encryption runs in a throwaway container over stdin and stdout, with no volume and no network | as crypto engine |
| Editor in the container | A Tk editor stays in the container; only its pixels reach a native window, through VNC over Docker's own stdio | at run time, holds the text |
| Native app without Docker | A sandboxed AppKit editor with its own implementation of the format over CommonCrypto, and an unsandboxed helper (XPC) for `hdiutil` | none |
| Security first | The same architecture as the native app, with the most complete hardening of the text view, a strict padding check and pinned signing identity | none |

## 3. Scores

The judge scored each design from 1 to 10 and weighted the criteria 3, 3, 3, 2, 2, 2.

| Design | No terminal | Format | Security | Robustness | Agent install | Effort | Weighted |
|---|---|---|---|---|---|---|---|
| Security first | 9 | 9 | 8 | 7 | 7 | 3 | **7.5** |
| Native app without Docker | 9 | 9 | 7 | 6 | 7 | 4 | **7.3** |
| Native front end | 8 | 10 | 6 | 5 | 4 | 3 | 6.4 |
| Wrapper | 4 | 10 | 6 | 5 | 5 | 6 | 6.1 |
| Editor in the container | 6 | 9 | 7 | 2 | 4 | 2 | 5.5 |

The two native designs share one architecture, so the judge merged them: the hardening
and the threat model of "security first", the build with the Command Line Tools and the
agent install of "native app without Docker".

The reviewers scored feasibility, security, convenience and the realism of the effort
estimate. Every designer had underestimated the effort, by a factor of two to three:

| Design | Feasibility | Security | Convenience | Effort realism | Designer's estimate | Reviewer's estimate |
|---|---|---|---|---|---|---|
| Security first | 7 | 7 | 7 | 4 | 13-20 days | 25-40 days |
| Native front end | 7 | 6 | 6 | 4 | 12-15 days | 25-40 days |
| Native app without Docker | 7 | 6 | 8 | 4 | 9-13 days | 25-40 days |
| Editor in the container | 5 | 7 | 4 | 3 | 18-24 days | 35-55 days |
| Wrapper | 7 | 6 | 5 | 4 | 8-10 days | 15-25 days |

The judge put the recommended plan at 30 to 45 working days.

## 4. Why a native app without Docker

The reviewers reached this independently of each other:

- **Docker no longer protects the text once a Mac window shows it.** An editor without a
  terminal has to show the text in a process on the Mac. From then on Docker isolates
  only the cryptography, not the plaintext. The one design that kept the text inside the
  container, the VNC editor, had its central mechanism refuted (section 5) and was the
  most expensive.
- **Docker Desktop is a heavy dependency for the users this is for.** It needs an
  administrator to install and to update, and its automatic update fails for a standard
  user; installed for one user, it allows only one account per Mac; larger organisations
  need a paid licence; its virtual machine takes 2 GB of memory or more and 10 to 60 s to
  start; and it shows windows of its own.
- **What Docker still gave was provenance:** the reference OpenSSL in every operation.
  The app replaces it with its own implementation of the format, checked against
  reference files made by the Docker image's OpenSSL 3 and by macOS's LibreSSL (G5). The
  Docker image stays in the repository for that, and as a way out.

What the user gives up: the Linux virtual machine around the editor, the reference
openssl in the editing path, emacs (Cocoa's text view still knows the basic Ctrl keys),
and immunity to new macOS text and AI features. Each such feature must be switched off
by the app and checked again at every macOS release. This is the main new risk.

What the user gains: the plaintext no longer lands on the synced disk image, where today
`bd` writes it in every session (and a deleted file's text stays inside an APFS disk
image, as tested); no administrator at any point; none of Docker's file-sharing failures
and no privileged container.

## 5. What the reviewers refuted or corrected

- **VNC over pipes** (editor in the container): `Xvnc -inetd` cannot serve over
  `docker exec` pipes. TigerVNC wraps its standard input as a socket and calls
  `recv`/`send`, which fail on pipes. The claim that nothing listens anywhere was also
  false: the X server always listens on a unix socket inside the container.
- **A helper that keeps state** (native app without Docker): the design let the XPC
  helper hold the disk image's password between opening and saving, and finish a save if
  the editor died. Apple's documentation says launchd may kill an idle service at any
  time, and an embedded service ends with its client. A helper must be stateless.
- **Mutual exclusion with the terminal tool** (native app without Docker): both using
  `/Volumes/safe` does not exclude each other, because the app detaches the image while
  the user edits. The check of the file's hash before saving is the backstop.
- **Guaranteed clean-up** (security first): the helper's invalidation handler is not
  guaranteed to run when the app dies, so it cannot be relied on to detach the image.
- **Integrity from the disk image** (security first): the disk image is not
  authenticated either; it is AES-CBC on 512-byte blocks.
- **A pinned hash as a second source** (security first): a hash of the release zip
  written into the install instructions at the release tag cannot work, because a
  notarized zip is made after the tag, and both live in the same GitHub account.
- **"Strict checking rejected 300 of 300"** was misleading. A strict PKCS#7 check alone
  still lets about 1 in 256 wrong passwords through; the check of the content is the real
  gate. That CommonCrypto's `CCCrypt` with `kCCOptionPKCS7Padding` reports success for
  wrong keys was confirmed (2000 of 2000). The requirements review of the first build
  added that the gate must not shut out the right password: a file can be unusual (text
  in ISO Latin-1, a picture in an unknown format), so a content that does not fit only
  stops the file from opening without a question, and the user decides (plan 4.4). Review
  round 2 extended this to the older variants (G5: old files must open as well), and drew
  the line between the two kinds of unconfirmed result: text in another encoding is shown
  read only on request, while bytes that are not text in any encoding, nearly always a
  wrong password, are reported as one, with Export Anyway as the way out for the right
  password. Review round 3 did the same for types that always start with the same bytes
  (PDF, Office, archives), and closed two gaps where the right password was still
  refused: a file cut short at a block boundary, which fails the padding check, is
  reported as damaged when the start of what the key gives looks like a real file, with
  its readable part for export; and an old RC4 file that Safe cannot check can be exported
  after the same password was typed twice, never shown. Review round 4 carried this to
  files cut inside a block and to cut files whose start Safe cannot recognise (their
  readable part, unchecked), offered the other readings of a file from every question about
  an unconfirmed result, because an AES result that passed its padding check by chance hid
  the RC4 content, and tightened the rule for very short texts, which a wrong password
  matched too often.
- **Smaller claims**: the location of the Docker command-line tool, macOS 14 as the
  minimum because of Docker's support policy, and `.metadata_never_index` keeping
  Spotlight out (reported not to work on recent macOS).
- **Defects of the wrapper**: the pid file recorded the wrong process; Docker's default
  detach keys (Ctrl-P Ctrl-Q) collide with the editor's keys and detach the client while
  the container goes on; dialogs could appear behind Terminal; quitting could destroy an
  open edit; Terminal's state restoration is a way for the text to reach the disk.

Gaps the reviewers found in the native designs, which the build closes or lists:
dragging selected text out creates a plaintext `.textClipping` file; Look Up sends words
to Apple; the standard find bar writes search strings to the system-wide find
pasteboard; the clipboard marker that keeps text out of clipboard histories is not
documented by Apple (and macOS 26 brings a clipboard history of its own in Spotlight, before
whose first use Safe now asks); macOS will ask for permission to access files in Documents, Desktop
and cloud folders; macOS 27 deprecates `hdiutil` (reported by others, not confirmed from
Apple).

Findings about today's tool, checked during the study: Docker's `local` log driver,
the default on the Mac tested, records what a container started with `-t` shows, so
emacs's screen lands in Docker's virtual disk; a deleted file's text stays inside an
APFS disk image; macOS's LibreSSL and the Docker image's OpenSSL 3 read each other's
files.

## 6. Decisions taken in this build

The requirements were written after the study and go beyond its brief: besides the one
safe, any file can be encrypted from the Finder (R1), edited (R2) or viewed and
exported (R3), and the app manages several volumes, made empty or from a folder (R4).
So a volume opens in the Finder like a disk, and a single file is edited where it lies,
with its plaintext only in the app's memory.

- **Native AppKit app in Swift, no Docker at run time.** AppKit and not SwiftUI or
  `NSDocument`, so there is no autosave, no Versions, no Recent Items and no restored
  windows. Docker stays in the repository for the terminal tool and as the source of
  reference files.
- **The format implemented in the app** over CommonCrypto (G5): decryption without
  `kCCOptionPKCS7Padding` and a strict padding check of its own, then a check that the
  content is believable (UTF-8 for text, the first bytes of PDFs and images). The older
  variants are read, never written.
- **No App Sandbox, but no network either.** The App Sandbox lets an app write only the
  files the user picked, so it cannot write `NAME.crypt_new`, `NAME.crypt.bak` or
  `NAME.crypt` next to a file, nor delete the original after encrypting it (R1, R2).
  `hdiutil` also fails inside the App Sandbox, which would need a separate, stateless
  helper with its own signing. Instead the app denies itself the network when it starts,
  with `sandbox_init(kSBXProfileNoNetwork, SANDBOX_NAMED, &err)`. Tested on macOS 26.3:
  afterwards `connect()` fails with "Operation not permitted", while files and `hdiutil`
  in child processes still work. The call is deprecated but works; `--self-test` checks
  it on every Mac, and the app does not start if the call fails. The price: the network
  is closed, but the process can still read and write whatever the user can.
- **Hardened runtime and an ad hoc signature**, until there is a Developer ID.
- **Built with the Command Line Tools only.** The app must build on a Mac without Xcode,
  so SwiftPM builds it once for Apple silicon and once for Intel, `lipo` joins the two,
  and a script assembles and signs the bundle.
- **An own test runner.** XCTest and Swift Testing do not run without Xcode, so the
  tests are an executable, `SafeTests`, with a small assertion harness. The app's own
  logic is tested by the app itself (`Safe --app-tests`, debug builds only), because one
  executable cannot link another.
- **A self-test that can stop writing** (G5): reference files from several
  implementations are checked when the app is built and installed and each time it
  starts; if a check fails, the app refuses to encrypt or save.
- **Settled from the judge's open questions**, as written in the requirements and the
  plan: lock after 10 minutes without use and on sleep or screen lock; an editor without
  unsaved changes closes, one with unsaved changes is covered and needs the password
  again; the password stays in memory while its file is open, so saving needs no
  retyping; copied text goes to this Mac only, marked as concealed, and is cleared after
  60 s, on lock and on quit; one `.bak`, as `crypt.sh` keeps; macOS 13 or later; the
  name Safe and the bundle identifier `io.github.fherwig.safedocker`.
- **Install by an agent from source** (`INSTALL-AGENT.md`), until releases exist; the
  agent never sees, types or stores a password and never opens the user's files.
- **Not built:** a lock against the terminal tool running at the same time, since the
  app no longer has one fixed safe; the hash check before every save catches a file
  changed in between.

## 7. Left for later

- Developer ID signing and notarization, the Team ID pinned in `INSTALL-AGENT.md`,
  release builds on GitHub, and a way to learn about updates. Until then the app is
  signed ad hoc and installed from source.
- The App Sandbox for the editor, with a separate, stateless helper for disk images.
- The `diskutil image` commands, for when `hdiutil` is deprecated (macOS 27).
- Touch ID for passwords, an encrypted autosave (today unsaved edits are lost if the app
  crashes), a formatted Markdown view, several timestamped backups.
- Hardening the study proposed and this build leaves out: no core dumps (`RLIMIT_CORE`
  0), Secure Event Input for the whole editor, an option that hides the text from
  accessibility apps, a second try with the password in decomposed Unicode, and a limit
  on the length of new passwords.
- A check of every leak path after each macOS release, point releases included, with
  the marker search of `acceptance.md`.
- A test matrix: Intel and Apple silicon, standard and administrator accounts, the
  macOS versions from 13 on, sync folders in File Provider mode, and an agent installing
  on a fresh account.
- The proposed hardening of the terminal tool: `--log-driver none`, detach keys that
  emacs does not use, the plaintext in a tmpfs instead of on the disk image, attaching
  with `-nobrowse`, and a check of the decrypted content in `crypt.sh` and `bd`.
- Disk images used with the terminal tool may hold remnants of decrypted text from past
  sessions, and so may their synced and backed-up copies. Moving to a fresh image and
  changing the most sensitive passwords is the owner's decision.
- A licence for the repository.
