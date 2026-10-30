#!/bin/bash
# Build Safe.app from the sources in app/: compile the program for Apple silicon
# and for Intel, join the two with lipo, assemble app/dist/Safe.app (with the
# reference files, the help in English and German, Resources/SafeHelp.md and
# SafeHelp.de.md, the texts of Resources/en.lproj and de.lproj, the icon
# Resources/Safe.icns and the LICENSE), sign it ad
# hoc with the hardened runtime, check the signature, run the app's self-test
# over its reference files (both halves, if Rosetta can run the Intel one), and
# zip it with a checksum. A build whose self-test fails is renamed to
# Safe-SELF-TEST-FAILED.app and loses its document type and services, so that
# it cannot be installed or used by mistake; one whose self-test could not run
# becomes Safe-NOT-SELF-TESTED.app in the same way. Runs from any directory, but
# not inside another sandbox (an agent's command sandbox, for example), where
# swift build and Safe itself cannot start.
#
#   build-app.sh                  debug build, quicker while developing
#   build-app.sh --release        optimised build, the one to install
#   build-app.sh --check-sandbox  only say whether this shell runs inside a
#                                 sandbox (exit 0 either way), and build nothing
#
# Build products go to ~/Library/Caches/SafeDocker-build, never into the
# repository, which may live in a synced folder. Set SAFE_SCRATCH_PATH to use
# another place. Only app/dist is written inside the repository; git ignores it.

set -euo pipefail

usage() { echo "Usage: build-app.sh [--release | --check-sandbox]"; }

# without HOME, as env -i and some sandboxes give: the user's home folder from the
# directory service, as agent-check.sh finds it (swift build itself needs none)
if [ -z "${HOME:-}" ]
then
    HOME=$(/usr/bin/dscl . -read "/Users/$(/usr/bin/id -un)" NFSHomeDirectory 2>/dev/null |
        /usr/bin/awk '{print $2}' || true)
    if [ -z "$HOME" ]
    then
        echo "HOME is not set, and the home folder could not be found. Run build-app.sh in a normal shell of the user." >&2
        exit 1
    fi
    export HOME
fi

# True if this shell runs inside another sandbox, such as an agent's command
# sandbox: then the no-network profile that Safe itself applies cannot be
# applied (sandbox-exec exits with 71, "sandbox_apply: Operation not permitted").
# Tested by the exit status, so that set -o pipefail cannot hide it.
in_another_sandbox() {
    [ -x /usr/bin/sandbox-exec ] && ! /usr/bin/sandbox-exec -n no-network /usr/bin/true 2>/dev/null
}

sandbox_note() {
    echo "Note: this shell runs inside a sandbox (sandbox_apply: Operation not permitted)." >&2
    echo "Building may fail with 'sandbox-exec: sandbox_apply: Operation not permitted', and the" >&2
    echo "self-test cannot run here. Run build-app.sh outside the sandbox: this is not a fault of Safe.app." >&2
}

config=debug
case $# in
    0) ;;
    1) case $1 in
           --release) config=release ;;
           --check-sandbox)
               if in_another_sandbox
               then
                   sandbox_note
                   echo "inside a sandbox"
               else
                   echo "not inside a sandbox"
               fi
               exit 0 ;;
           -h|--help) sed -n '2,21s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
           *) echo "Unknown option $1." >&2; usage >&2; exit 2 ;;
       esac ;;
    *) usage >&2; exit 2 ;;
esac

appdir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dist=$appdir/dist
app=$dist/Safe.app

# /usr/bin/swift and /usr/bin/lipo are stubs that open an install dialog when the
# developer tools are missing, so the real ones are looked for in the developer
# folder first, as agent-check.sh does, and nothing is run without them
devdir=$(xcode-select -p 2>/dev/null || true)
for tool in swift lipo
do
    if [ -z "$devdir" ] || { [ ! -x "$devdir/usr/bin/$tool" ] &&
        [ ! -x "$devdir/Toolchains/XcodeDefault.xctoolchain/usr/bin/$tool" ]; }
    then
        echo "$tool is missing. Install the Command Line Tools with: xcode-select --install" >&2
        echo "(it needs an administrator; app/scripts/agent-check.sh says what else is needed)." >&2
        exit 1
    fi
done
for tool in codesign ditto shasum plutil xattr
do
    if ! command -v "$tool" >/dev/null
    then
        echo "$tool is missing. It is part of macOS, so this Mac is unusual." >&2
        exit 1
    fi
done

version=$(tr -d '[:space:]' < "$appdir/VERSION")
if ! [[ $version =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]
then
    echo "$appdir/VERSION should hold a version such as 0.1.0, not '$version'." >&2
    exit 1
fi

# inside another sandbox, such as an agent's command sandbox, swift build cannot
# sandbox its manifests and Safe cannot deny itself the network; say so first
if in_another_sandbox
then
    sandbox_note
fi

# one scratch folder per checkout, so that two checkouts never share one
key=$(printf '%s' "$appdir" | shasum -a 256 | cut -c1-8)
scratch=${SAFE_SCRATCH_PATH:-$HOME/Library/Caches/SafeDocker-build/build-app-$key}
case $scratch in
    "$appdir"|"$appdir"/*) echo "SAFE_SCRATCH_PATH must be outside $appdir." >&2; exit 1 ;;
esac

# 1. compile for both architectures
bins=()
for arch in arm64 x86_64
do
    echo "Building Safe $version for $arch ($config) in $scratch ...."
    args=(--package-path "$appdir" --scratch-path "$scratch" -c "$config"
          --triple "$arch-apple-macosx13.0")
    swift build "${args[@]}" --product Safe
    bin=$(swift build "${args[@]}" --show-bin-path)/Safe
    if [ ! -f "$bin" ]
    then
        echo "The build did not produce $bin." >&2
        exit 1
    fi
    bins+=("$bin")
done

# 2. assemble the app bundle, after removing what an earlier run left
mkdir -p "$dist"
# (and the release files of make-release.sh, which would no longer match this app)
(cd "$dist" && /bin/rm -rf ./Safe.app ./Safe-SELF-TEST-FAILED.app ./Safe-NOT-SELF-TESTED.app ./Safe-*.zip ./SHA256SUMS \
    ./Safe.zip ./Safe-*.pkg ./Safe.pkg ./pkg-parts)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
lipo -create -output "$app/Contents/MacOS/Safe" "${bins[@]}"
lipo "$app/Contents/MacOS/Safe" -verify_arch arm64 x86_64
cp "$appdir/Resources/Info.plist" "$app/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$version" "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$app/Contents/PkgInfo"
if [ -d "$appdir/Fixtures" ]
then
    ditto "$appdir/Fixtures" "$app/Contents/Resources/Fixtures"
    find "$app/Contents/Resources/Fixtures" -name .DS_Store -type f -delete
else
    echo "Note: there is no $appdir/Fixtures yet, so the app carries no reference files."
fi
# the icon, drawn by scripts/gen-icon.swift (make-icon.sh); .crypt files get a
# document icon that macOS makes from it (CFBundleTypeIconSystemGenerated)
if [ -f "$appdir/Resources/Safe.icns" ]
then
    cp "$appdir/Resources/Safe.icns" "$app/Contents/Resources/Safe.icns"
else
    echo "Note: there is no $appdir/Resources/Safe.icns, so the app shows the generic icon."
fi
# the owner's manual in English and German, which Help > Safe Help shows; without
# it the help window shows a short note instead
for help in SafeHelp.md SafeHelp.de.md
do
    if [ -f "$appdir/Resources/$help" ]
    then
        cp "$appdir/Resources/$help" "$app/Contents/Resources/$help"
    else
        echo "Note: there is no $appdir/Resources/$help, so the app's help in that language shows only a short note."
    fi
done
# the licence, GPL-3.0-or-later, which goes with every copy of the app
if [ -f "$appdir/../LICENSE" ]
then
    cp "$appdir/../LICENSE" "$app/Contents/Resources/LICENSE"
else
    echo "Note: there is no LICENSE beside app/, so the app carries no copy of its licence."
fi
# the texts in English and German (Localizable.strings), and what the Finder shows
# in macOS's language (InfoPlist.strings, ServicesMenu.strings)
for lproj in en.lproj de.lproj
do
    if [ -d "$appdir/Resources/$lproj" ]
    then
        ditto "$appdir/Resources/$lproj" "$app/Contents/Resources/$lproj"
        find "$app/Contents/Resources/$lproj" -name .DS_Store -type f -delete
        for strings in "$app/Contents/Resources/$lproj"/*.strings
        do
            plutil -lint "$strings" >/dev/null || { echo "Error: $strings cannot be read." >&2; exit 1; }
        done
    else
        echo "Note: there is no $appdir/Resources/$lproj, so Safe shows English only."
    fi
done
# files from a synced folder may carry extended attributes, which codesign refuses
xattr -cr "$app"

# 3. sign ad hoc with the hardened runtime and check the signature
codesign --force --options runtime \
    --entitlements "$appdir/Resources/Safe.entitlements" --sign - "$app"
codesign --verify --strict --verbose=2 "$app"

# 4. the self-test of the app just built (requirement G5): the reference files
# must decrypt and the network must be blocked. A build that fails it, or whose
# self-test could not run, is not zipped
# disable_bundle NAME: renames the bundle and takes away its document type and
# services (then signs it again, so that it can still be run and inspected), so
# that nobody installs it and nothing registers it as the handler of .crypt files
disable_bundle() {
    (cd "$dist" && mv Safe.app "$1")
    local disabled=$dist/$1
    plutil -remove CFBundleDocumentTypes "$disabled/Contents/Info.plist" 2>/dev/null || true
    plutil -remove UTExportedTypeDeclarations "$disabled/Contents/Info.plist" 2>/dev/null || true
    plutil -remove NSServices "$disabled/Contents/Info.plist" 2>/dev/null || true
    codesign --force --options runtime \
        --entitlements "$appdir/Resources/Safe.entitlements" --sign - "$disabled" 2>/dev/null || true
}
failed_self_test() {
    disable_bundle Safe-SELF-TEST-FAILED.app
    failed=$dist/Safe-SELF-TEST-FAILED.app
    echo "The self-test of the new app failed ($1); see:" >&2
    echo "  $failed/Contents/MacOS/Safe --self-test" >&2
    echo "The app was renamed to Safe-SELF-TEST-FAILED.app; do not install it." >&2
    exit 1
}
# runs the self-test of one half; a self-test that could not start because this
# shell is inside another sandbox is no fault of the app, and is said so, but the
# app was not tested, so it is put out of use like a failed one (review round 4)
self_test() {
    local errors status=0
    errors=$("$@" --self-test 2>&1 >/dev/null) || status=$?
    if [ "$status" -ne 0 ] && printf '%s' "$errors" | grep -q 'cannot deny network access: Operation not permitted'
    then
        disable_bundle Safe-NOT-SELF-TESTED.app
        echo "The self-test could not run because this shell is inside another sandbox; run" >&2
        echo "build-app.sh outside it. This is not a fault of Safe.app. The app was not" >&2
        echo "self-tested, so it was renamed to $dist/Safe-NOT-SELF-TESTED.app: do not install it." >&2
        exit 3
    fi
    [ -n "$errors" ] && printf '%s\n' "$errors" >&2
    return "$status"
}
echo "Running the self-test of the new app ...."
if ! self_test "$app/Contents/MacOS/Safe"
then
    failed_self_test "$(uname -m)"
fi
# the other half too: on Apple silicon the Intel program runs under Rosetta
other=x86_64
[ "$(uname -m)" = x86_64 ] && other=arm64
if arch "-$other" /usr/bin/true 2>/dev/null
then
    if ! self_test arch "-$other" "$app/Contents/MacOS/Safe"
    then
        failed_self_test "$other"
    fi
elif [ "$other" = arm64 ]
then
    echo "Note: the arm64 half was not self-tested; an Intel Mac cannot run Apple silicon code."
else
    echo "Note: the x86_64 half was not self-tested; Rosetta is not installed on this Mac."
fi

# 5. zip and checksum, without extended attributes and AppleDouble (._) files,
# which unzip would add to the bundle and so break its signature. A debug build
# says so in the name of its zip
zip=Safe-$version.zip
[ "$config" = debug ] && zip=Safe-$version-debug.zip
(cd "$dist" && ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent Safe.app "$zip" &&
    shasum -a 256 "$zip" > SHA256SUMS)
if command -v unzip >/dev/null && unzip -Z1 "$dist/$zip" | grep -qE '(^|/)(\._|__MACOSX)'
then
    echo "$dist/$zip holds AppleDouble files; it would not unpack with a valid signature." >&2
    exit 1
fi

echo "Built $app"
echo "  version $version, $(lipo -archs "$app/Contents/MacOS/Safe"), $config"
echo "  $dist/$zip"
echo "  $(cat "$dist/SHA256SUMS")"
