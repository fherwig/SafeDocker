# Publishing a release

How a version of Safe.app goes public on <https://github.com/fherwig/Safe>. Like Marina, the
public repository serves releases: its `main` gets one commit per release, whose files are
exactly those of the local branch `safe-app` at that point, and a tag `vVERSION` with the
release's files on GitHub. The development history stays local, on `safe-app`. Never push
`safe-app`, `private-history` or any other branch, and never use `git push --all`,
`--mirror` or `--tags`: the commands below push `main` and one tag by name.

The steps for the first release, 0.3.2. For a later one, replace the version, and start from
the release commit before it instead of `4bc71c6` (step 2 shows it).

## 1. Before

On `safe-app`, everything committed, the checks of `building-plan.md` passed, and
`app/VERSION`, the release notes `docs/release-notes/VERSION.md` and this file agree on the
version. Then make the release files from that commit (some minutes):

    cd PATH-OF-THE-REPOSITORY
    git switch safe-app
    git status --short                        # prints nothing
    git config user.email                     # 10589734+fherwig@users.noreply.github.com
    app/scripts/make-release.sh
    (cd app/dist && shasum -a 256 -c SHA256SUMS)

The release commit and the tag carry the identity that `git config user.email` prints, and
both become public. This repository sets GitHub's private address in its own configuration;
in another clone git falls back to the global identity, which may be a university or other
private address. If the line above prints anything else, stop and set it first, with
`git config user.email 10589734+fherwig@users.noreply.github.com`.

`app/dist` then holds `Safe-0.3.2.zip`, `Safe-0.3.2.pkg`, `Safe.zip`, `Safe.pkg` and
`SHA256SUMS` (git ignores the folder). `make-release.sh` builds with `build-app.sh --release`,
which runs the self-test; `make-pkg.sh` makes the installer.

## 2. One commit on main, with the tree of safe-app

Start from GitHub's `main`, not from the local one (which held a checkpoint commit that was
never published):

    git fetch origin
    git log --oneline origin/main             # 4bc71c6 SafeDocker: a doubly encrypted ...

Make the release commit with `git commit-tree`. It takes the files of `safe-app` exactly as
they are (`safe-app^{tree}`) and makes a new commit whose only parent is `origin/main`. It
changes no branch, no file in the folder and nothing on GitHub; it only prints the new
commit's hash:

    release=$(git commit-tree 'safe-app^{tree}' -p origin/main \
        -m "Safe 0.3.2: the first release of Safe.app" \
        -m "Safe.app, a Mac app that keeps files encrypted, edits text and views PDFs and pictures from memory, and makes encrypted volumes, with no network access. The release notes are docs/release-notes/0.3.2.md. The terminal tool SafeDocker is still here, unchanged in use. Licence: GPL-3.0-or-later.")
    echo "$release"

Check it before anything else:

    git diff --stat "$release" safe-app       # prints nothing: the same files
    git log --oneline "$release"              # two commits: the release, then 4bc71c6
    git show --stat --format=fuller "$release" | head -20

The author and committer must be `Falk Herwig <10589734+fherwig@users.noreply.github.com>`
(step 1); check them in the `git show` output. `safe-app` must be the branch checked out
(step 1), because git does not move a branch that is checked out. Then let
the local `main` point at the release commit (its old checkpoint commit stays in the history
of `safe-app`, which grew from it):

    git branch -f main "$release"

## 3. Push main

    git push origin main

This is a fast-forward from `4bc71c6`. From now on `install-safe.sh` on GitHub is the new
one, but the release files are not there yet, so do steps 4 and 5 right away.

## 4. The tag

    git tag -a v0.3.2 -m "Safe 0.3.2" main
    git push origin v0.3.2

## 5. The release on GitHub

    gh release create v0.3.2 --repo fherwig/Safe --verify-tag \
        --title "Safe 0.3.2" \
        --notes-file docs/release-notes/0.3.2.md \
        app/dist/Safe-0.3.2.zip app/dist/Safe-0.3.2.pkg \
        app/dist/Safe.zip app/dist/Safe.pkg app/dist/SHA256SUMS
    gh release view v0.3.2 --repo fherwig/Safe

`Safe.zip`, `Safe.pkg` and `SHA256SUMS` are the names without a version that
`https://github.com/fherwig/Safe/releases/latest/download/...` serves for the newest release:
`install-safe.sh` and the links in `README.md` use them.

## 6. Description and topics

Proposed (the owner decides the words):

    gh repo edit fherwig/Safe \
        --description "Safe: a Mac app that keeps files encrypted, edits text and views PDFs from memory, and makes encrypted volumes, with no network access. Also SafeDocker, the older terminal tool." \
        --add-topic macos,encryption,openssl,aes-256,swift,appkit,privacy,disk-image

## 7. After

From any folder, without touching `~/Applications`, the published release installed into a
throwaway folder (it downloads from GitHub and checks the checksum):

    curl -fsSIL -o /dev/null -w '%{http_code}\n' https://github.com/fherwig/Safe/releases/latest/download/Safe.zip
    mkdir -p /tmp/safetest-apps
    curl -fsSL https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh |
        SAFE_APPS_DIR=/tmp/safetest-apps SAFE_VOLUME_LIST=/tmp/safetest-apps/volumes.json bash
    /bin/rm -rf /tmp/safetest-apps

The first prints `200`; the second ends with `Installed Safe 0.3.2 in /tmp/safetest-apps`
and does not open the app. Then go on working on `safe-app` as before; the next release
repeats steps 1 to 5 with `-p origin/main` again, which is then this release's commit.

## Tried in a throwaway clone

On 2026-10-29, steps 2 to 4 ran in a clone of the public repository under
`/tmp/safetest-publish-*`, with a bare copy of it as the remote and `safe-app` fetched from
the local repository: `git diff safe-app` was empty, `git log` showed the two commits
(the release and `4bc71c6`), `git push origin main` was a fast-forward (`4bc71c6..`), and
the tag `v0.3.2` arrived. Nothing was pushed to GitHub. The first try found the two points
written into steps 1 and 2: the fresh clone used the global identity (a private address)
until the repository's own was set, and `git branch -f main` refuses while `main` is
checked out.
