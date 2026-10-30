#!/bin/bash
# Install, update or remove Safe.app, the Mac app of this repository, from the
# Terminal. Paste this line into the Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh | bash
#
# or, in a checkout: bash install-safe.sh. Options (with curl: ... | bash -s -- OPTION):
#
#   (none)          download the latest release, check its SHA-256 checksum and
#                   install Safe.app into ~/Applications, or update it there
#   --from-source   build Safe.app from the source on this Mac instead (needs
#                   Apple's Command Line Tools), then install it the same way
#   --uninstall     remove ~/Applications/Safe.app; your encrypted files and
#                   volumes stay where they are, and so does Safe's list of
#                   volumes, unless you add --remove-data
#   --help          this text
#
# Never asks for an administrator's password and never uses sudo. Never touches
# your encrypted files or volumes and never sees a password. If Safe is running,
# it asks you to quit Safe first; it never quits Safe for you, which could lose
# unsaved changes. INSTALL-AGENT.md has the same steps by hand, for an AI agent.
#
# For tests, without the network and without touching ~/Applications:
#   SAFE_RELEASE_DIR=DIR   take Safe.zip and SHA256SUMS from DIR, not GitHub
#   SAFE_APPS_DIR=DIR      install into DIR, not ~/Applications; then Safe is
#                          not opened, and only a Safe running from DIR counts
#   SAFE_SOURCE_DIR=DIR    the checkout for --from-source (default: this checkout,
#                          else ~/src/Safe, cloned if missing)

set -euo pipefail

# Everything is in functions, called on the last line, so that a download cut
# short by the network runs nothing.

repo_url=https://github.com/fherwig/Safe
release_url=$repo_url/releases/latest/download
bundle_id=io.github.fherwig.safedocker

say() { printf '%s\n' "$*"; }
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'END'
Install, update or remove Safe.app from the Terminal.

  curl -fsSL https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh | bash
  curl -fsSL https://raw.githubusercontent.com/fherwig/Safe/main/install-safe.sh | bash -s -- OPTION
  bash install-safe.sh [OPTION]          (in a checkout)

  (none)                     download the latest release, check its SHA-256 checksum,
                             and install Safe.app into ~/Applications, or update it
  --from-source              build Safe.app on this Mac instead (needs Apple's
                             Command Line Tools), then install it the same way
  --uninstall                remove ~/Applications/Safe.app; your encrypted files and
                             volumes, Safe's list of volumes and its settings stay
  --uninstall --remove-data  remove the list of volumes and the settings as well
  --help                     this text

No administrator password and no sudo. Your encrypted files and volumes are never
touched, and no password is ever asked for.
END
}

# version_at_least 15.4 13 -> true if the first is at least the second
version_at_least() {
    local IFS=.
    local a b i x y
    # shellcheck disable=SC2206
    a=($1)
    # shellcheck disable=SC2206
    b=($2)
    for i in 0 1 2
    do
        x=${a[i]:-0} y=${b[i]:-0}
        x=${x//[^0-9]/} y=${y//[^0-9]/}
        x=${x:-0} y=${y:-0}
        if [ "$x" -gt "$y" ]; then return 0; fi
        if [ "$x" -lt "$y" ]; then return 1; fi
    done
    return 0
}

# --- this Mac ---------------------------------------------------------------

check_mac() {
    local needed=$1 macos arch
    macos=$(sw_vers -productVersion 2>/dev/null || true)
    if [ -z "$macos" ] || ! version_at_least "$macos" "$needed"
    then
        fail "Safe needs macOS $needed or later; this Mac has ${macos:-an unknown version}. Update macOS in System Settings > General > Software Update first."
    fi
    arch=$(uname -m)
    case $arch in
        arm64|x86_64) ;;
        *) fail "Safe runs on Apple silicon (arm64) and Intel (x86_64) Macs, not on $arch." ;;
    esac
    local tool
    for tool in curl ditto shasum codesign plutil
    do
        command -v "$tool" >/dev/null || fail "$tool is missing. It is part of macOS, so this Mac is unusual."
    done
    say "This Mac: macOS $macos, $arch."
}

# --- a work folder, removed at the end ------------------------------------------

work=""
make_work() {
    work=$(mktemp -d "${TMPDIR:-/tmp}/safe-install.XXXXXX")
    trap remove_work EXIT
}
remove_work() {
    if [ -n "$work" ] && [ -d "$work" ]
    then
        local parent name
        parent=$(dirname "$work") name=$(basename "$work")
        case $name in
            safe-install.*) (cd "$parent" && /bin/rm -rf "./$name") ;;
        esac
    fi
}

# --- is Safe running? ---------------------------------------------------------

safe_running() {
    if [ -n "${SAFE_APPS_DIR:-}" ]
    then
        # a test: only a Safe started from that folder counts
        pgrep -f "$apps/Safe.app/Contents/MacOS/Safe" >/dev/null 2>&1
    else
        pgrep -x Safe >/dev/null 2>&1
    fi
}

# Asks the user to quit Safe and waits; never quits or kills it.
wait_until_safe_quit() {
    safe_running || return 0
    say ""
    say "Safe is running. Please save and close your files, close your volumes in Safe's"
    say "Volumes window, and quit Safe (Safe > Quit Safe)."
    if ! { : < /dev/tty; } 2>/dev/null
    then
        fail "Safe is running. Quit it, then run this again."
    fi
    while safe_running
    do
        printf 'Press Return when Safe has quit (or Control-C to stop here): '
        read -r _ < /dev/tty || fail "Safe is running. Quit it, then run this again."
    done
    say "Safe has quit."
}

# --- checks of an app bundle ------------------------------------------------------

# check_bundle PATH: Safe.app with a valid signature, or stop
check_bundle() {
    local app=$1 id
    [ -x "$app/Contents/MacOS/Safe" ] || fail "$app is not a complete Safe.app."
    id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)
    [ "$id" = "$bundle_id" ] || fail "$app is not Safe.app (its identifier is '${id:-none}')."
    codesign --verify --strict "$app" 2>/dev/null ||
        fail "The signature of $app is not valid, so it was not installed. Try again; if it happens again, report it."
}

# self_test PATH: Safe's self-test, which must pass, in a release build
self_test() {
    local app=$1 report
    if ! report=$("$app/Contents/MacOS/Safe" --self-test 2>&1)
    then
        case $report in
            *"cannot deny network access"*)
                fail "Safe could not switch off its network access, because this shell runs inside a sandbox. Run this in the Terminal app instead." ;;
        esac
        fail "The self-test of the new Safe failed, so it was not installed. Details: $app/Contents/MacOS/Safe --self-test"
    fi
    printf '%s' "$report" | grep -Eq '"configuration" *: *"release"' ||
        fail "$app is a debug build, not one to install."
}

# --- install a checked bundle ---------------------------------------------------

# install_app PATH: copies a checked Safe.app into $apps. An older Safe.app there
# is replaced only now, after the new one was unpacked and passed its self-test,
# and comes back if the copy fails.
install_app() {
    local new=$1 old_version=""
    mkdir -p "$apps"
    if [ -d "$apps/Safe.app" ]
    then
        old_version=$(plutil -extract CFBundleShortVersionString raw "$apps/Safe.app/Contents/Info.plist" 2>/dev/null || true)
        local old_id
        old_id=$(plutil -extract CFBundleIdentifier raw "$apps/Safe.app/Contents/Info.plist" 2>/dev/null || true)
        [ "$old_id" = "$bundle_id" ] ||
            fail "$apps/Safe.app is another app (identifier '${old_id:-none}'). Move it away first; it was left as it is."
    fi
    wait_until_safe_quit
    # ditto keeps the signature intact
    ditto "$new" "$work/Safe-installing.app"
    check_bundle "$work/Safe-installing.app"
    if [ -d "$apps/Safe.app" ]
    then
        mv "$apps/Safe.app" "$work/Safe-old.app"
    fi
    if ! ditto "$work/Safe-installing.app" "$apps/Safe.app"
    then
        (cd "$apps" && /bin/rm -rf ./Safe.app)
        if [ -d "$work/Safe-old.app" ]
        then
            mv "$work/Safe-old.app" "$apps/Safe.app"
            fail "Copying Safe.app into $apps failed; the old version $old_version is back in place."
        fi
        fail "Copying Safe.app into $apps failed."
    fi
    if [ -n "$old_version" ]
    then
        say "Replaced Safe $old_version in $apps."
    fi
}

# check_installed: --version, --self-test and --check of the installed app.
# --check names the user's volumes: its report goes to a file in the work folder,
# is read only for the fields below, and is never printed.
check_installed() {
    local app=$apps/Safe.app version report=$work/check.json
    check_bundle "$app"
    version=$("$app/Contents/MacOS/Safe" --version) || fail "Safe --version failed."
    self_test "$app"
    if ! (umask 077 && "$app/Contents/MacOS/Safe" --check > "$report" 2>/dev/null)
    then
        fail "Safe --check failed; see: $app/Contents/MacOS/Safe --check (it lists your volumes)."
    fi
    local field
    for field in '"configuration" *: *"release"' '"networkBlocked" *: *true' '"manifestFound" *: *true'
    do
        grep -Eq "$field" "$report" || fail "Safe --check did not report $(printf '%s' "$field" | sed 's/ \*: \*/ /; s/"//g')."
    done
    say "Installed Safe $version in $apps; its signature, self-test and checks are fine."
}

# open_once: start Safe once, so that the Finder learns its document type and
# its services (Encrypt, Open and Export with Safe)
open_once() {
    if [ -n "${SAFE_APPS_DIR:-}" ]
    then
        say "(A test install into $apps: Safe was not opened.)"
        return 0
    fi
    say "Starting Safe once, so that the Finder knows it. You can quit it again (Safe > Quit Safe)."
    open "$apps/Safe.app" || say "Could not start Safe. Open it once yourself from your Applications folder."
}

next_steps() {
    say ""
    say "Safe is installed in the Applications folder of your home folder."
    say "- To encrypt a file: right-click it in the Finder, Quick Actions (or Services) > Encrypt with Safe."
    say "- To read or change an encrypted file: double-click it and type its password."
    say "- To make and open encrypted volumes: open Safe from your Applications folder."
    say "- Help > Safe Help in the app explains the rest."
    say "If \"Encrypt with Safe\" is missing from the right-click menu, log out and in again."
    say "Nobody can recover a forgotten password, so keep yours safe."
}

# --- the three ways -------------------------------------------------------------

install_release() {
    check_mac 13.0
    make_work
    local from
    if [ -n "${SAFE_RELEASE_DIR:-}" ]
    then
        from=$SAFE_RELEASE_DIR
        say "Taking the release from $from (SAFE_RELEASE_DIR)."
        cp "$from/Safe.zip" "$from/SHA256SUMS" "$work/" || fail "$from does not hold Safe.zip and SHA256SUMS."
    else
        from=$release_url
        say "Downloading the latest release of Safe from $repo_url/releases ...."
        curl -fsSL --retry 2 -o "$work/Safe.zip" "$from/Safe.zip" ||
            fail "The download of $from/Safe.zip failed. Check the network and try again."
        curl -fsSL --retry 2 -o "$work/SHA256SUMS" "$from/SHA256SUMS" ||
            fail "The download of $from/SHA256SUMS failed. Check the network and try again."
    fi

    # The checksum must match the one published with the release. It catches a
    # download that was cut short or changed on the way; both files come from the
    # same release page.
    local expected actual
    expected=$(awk '$2 == "Safe.zip" || $2 == "*Safe.zip" {print $1}' "$work/SHA256SUMS" | head -1)
    [ -n "$expected" ] || fail "SHA256SUMS has no checksum for Safe.zip, so nothing was installed."
    actual=$(shasum -a 256 "$work/Safe.zip" | awk '{print $1}')
    if [ "$actual" != "$expected" ]
    then
        fail "The SHA-256 checksum of Safe.zip does not match SHA256SUMS ($actual instead of $expected). Nothing was installed. Try again later; if it happens again, report it."
    fi
    say "The SHA-256 checksum of Safe.zip is right."

    # curl sets no quarantine attribute, unlike a browser, so macOS opens the app
    # without asking; the checksum and the signature above take that place
    mkdir "$work/unpacked"
    ditto -x -k "$work/Safe.zip" "$work/unpacked" || fail "Safe.zip could not be unpacked."
    check_bundle "$work/unpacked/Safe.app"
    self_test "$work/unpacked/Safe.app"
    say "Safe $("$work/unpacked/Safe.app/Contents/MacOS/Safe" --version) passed its self-test."
    install_app "$work/unpacked/Safe.app"
    check_installed
    open_once
    next_steps
}

install_from_source() {
    check_mac 14.5
    make_work
    local src devdir here
    devdir=$(xcode-select -p 2>/dev/null || true)
    # /usr/bin/git and swift are stubs that open an install dialog when the tools
    # are missing: only the real ones in the developer folder are run
    # (in an Xcode.app, swift is in its toolchain)
    if [ -z "$devdir" ] || [ ! -x "$devdir/usr/bin/git" ] ||
        { [ ! -x "$devdir/usr/bin/swift" ] && [ ! -x "$devdir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift" ]; }
    then
        fail "Building Safe needs Apple's Command Line Tools. Install them with: xcode-select --install (it asks for an administrator), then run this again. Or install the release instead, without --from-source."
    fi
    here=""
    if [ -f "$script_dir/app/scripts/build-app.sh" ]
    then
        here=$script_dir
    fi
    src=${SAFE_SOURCE_DIR:-${here:-$HOME/src/Safe}}
    if [ -z "${SAFE_SOURCE_DIR:-}" ] && [ -z "$here" ] && [ ! -e "$src" ] && [ -d "$HOME/src/SafeDocker/.git" ]
    then
        src=$HOME/src/SafeDocker     # a checkout made before the repository was renamed
    fi
    if [ ! -e "$src" ]
    then
        say "Getting the source into $src ...."
        mkdir -p "$(dirname "$src")"
        "$devdir/usr/bin/git" clone --quiet "$repo_url.git" "$src" || fail "git clone of $repo_url failed."
    elif [ -z "$here" ] || [ -n "${SAFE_SOURCE_DIR:-}" ]
    then
        [ -f "$src/app/scripts/build-app.sh" ] || fail "$src exists but is not a checkout of Safe. Move it away, or set SAFE_SOURCE_DIR."
        if [ -d "$src/.git" ] && [ -z "$here" ]
        then
            say "Updating the source in $src ...."
            "$devdir/usr/bin/git" -C "$src" pull --ff-only --quiet ||
                fail "git could not update $src (local changes?). Nothing was installed."
        fi
    fi
    say "Using the source in $src."
    local readiness
    readiness=$(bash "$src/app/scripts/agent-check.sh") || fail "app/scripts/agent-check.sh failed."
    if ! printf '%s' "$readiness" | grep -q '"ready_to_build": true'
    then
        printf '%s\n' "$readiness" | grep -E '"level": "(required|build)", "ok": false' |
            sed 's/^ *"\([a-z_]*\)".*"hint": "\(.*\)"}.*$/- \1: \2/' >&2 || true
        fail "This Mac cannot build Safe yet; the lines above say what is missing. Or install the release instead, without --from-source."
    fi
    say "Building Safe; this takes five to fifteen minutes ...."
    bash "$src/app/scripts/build-app.sh" --release || fail "The build failed; see the lines above. Nothing was installed."
    check_bundle "$src/app/dist/Safe.app"
    self_test "$src/app/dist/Safe.app"
    install_app "$src/app/dist/Safe.app"
    check_installed
    if [ -z "$here" ] && [ -z "${SAFE_SOURCE_DIR:-}" ]
    then
        # the build products: a second copy of the app, which the Finder could find
        (cd "$src/app" && /bin/rm -rf ./dist)
    else
        say "The build is still in $src/app/dist; delete that folder if you do not need it."
    fi
    open_once
    next_steps
}

uninstall() {
    local remove_data=$1
    local app=$apps/Safe.app
    make_work
    if [ -d "$app" ]
    then
        local id
        id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)
        [ "$id" = "$bundle_id" ] || fail "$app is another app (identifier '${id:-none}'); it was left as it is."
        # unencrypted rests of folders that New from Folder did not finish deleting;
        # Safe's own data holds the only record of where they are
        local pending="" report=$work/check.json
        if (umask 077 && "$app/Contents/MacOS/Safe" --check > "$report" 2>/dev/null)
        then
            pending=$(sed -n 's/.*"pendingDeletes" *: *\([0-9][0-9]*\).*/\1/p' "$report" | head -1)
        fi
        if [ -n "$pending" ] && [ "$pending" -gt 0 ]
        then
            say "Safe did not finish deleting the unencrypted copy of $pending folder(s) that it made into volumes."
            say "Open Safe once and answer its question \"Safe did not finish deleting a folder\" (Delete, or"
            say "Show in Finder to keep it), quit Safe, and run this again."
            fail "Nothing was removed."
        fi
        wait_until_safe_quit
        (cd "$apps" && /bin/rm -rf ./Safe.app)
        say "Removed $app."
    else
        say "There is no Safe.app in $apps."
    fi
    if [ "$remove_data" = yes ]
    then
        (cd "$HOME/Library/Application Support" 2>/dev/null && /bin/rm -rf ./SafeDocker) || true
        (cd "$HOME/Library/Saved Application State" 2>/dev/null && /bin/rm -rf ./io.github.fherwig.safedocker.savedState) || true
        (cd "$HOME/Library/Caches" 2>/dev/null && /bin/rm -rf ./SafeDocker-build) || true
        defaults delete "$bundle_id" >/dev/null 2>&1 || true
        say "Removed Safe's list of volumes, its settings and its build products."
    else
        say "Safe's list of volumes (~/Library/Application Support/SafeDocker) and its settings were kept;"
        say "add --remove-data to remove them as well."
    fi
    say ""
    say "Your encrypted files and volumes were not touched. Without Safe they still open: a volume"
    say "with a double-click in the Finder, a .crypt file in the Terminal with"
    say "  openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt -out FILE"
    if [ -d /Applications/Safe.app ] && [ -z "${SAFE_APPS_DIR:-}" ]
    then
        say "Another Safe.app is in /Applications; remove it in the Finder if you want (it may ask for an administrator)."
    fi
}

main() {
    if [ "$(id -u)" = 0 ]
    then
        fail "Do not run this with sudo or as root: Safe installs into your own home folder."
    fi
    [ -n "${HOME:-}" ] || fail "HOME is not set. Run this in the Terminal app."
    apps=${SAFE_APPS_DIR:-$HOME/Applications}
    case $# in
        0) install_release ;;
        1) case $1 in
               --from-source) install_from_source ;;
               --uninstall) uninstall no ;;
               -h|--help) usage ;;
               *) say "Unknown option $1." >&2; usage >&2; exit 2 ;;
           esac ;;
        2) case "$1 $2" in
               "--uninstall --remove-data"|"--remove-data --uninstall") uninstall yes ;;
               *) usage >&2; exit 2 ;;
           esac ;;
        *) usage >&2; exit 2 ;;
    esac
}

# the file this runs from, if any (with curl ... | bash there is none)
script_file=${BASH_SOURCE[0]:-}
script_dir=""
if [ -n "$script_file" ] && [ -f "$script_file" ]
then
    script_dir=$(cd "$(dirname "$script_file")" && pwd -P)
fi
apps=""

main "$@"
