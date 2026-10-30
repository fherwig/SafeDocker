#!/bin/bash
# Make the installer app/dist/Safe-VERSION.pkg from app/dist/Safe.app, which
# build-app.sh --release made. The installer puts Safe.app into the Applications
# folder of the user's home folder (~/Applications), for that user only: it never
# asks for an administrator's password and never touches another account. It runs
# no scripts. It is not signed, because there is no Developer ID: macOS refuses it
# the first time it is opened, and the user allows it in System Settings > Privacy
# & Security > Open Anyway (README.md, "Install").
#
#   make-pkg.sh          make app/dist/Safe-VERSION.pkg
#   make-pkg.sh --help   this text
#
# The app inside keeps its own ad hoc signature. The package is made as Marina's
# is, with pkgbuild and productbuild, and app/Resources/distribution.xml; bundle
# relocation is turned off, so that the installer never goes looking for another
# copy of Safe.app (app/dist/Safe.app, say) and installs over that one instead.
# Only app/dist is written inside the repository; git ignores it. Nothing is
# installed on this Mac.

set -euo pipefail

case $# in
    0) ;;
    1) case $1 in
           -h|--help) sed -n '2,18s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
           *) echo "Unknown option $1." >&2; echo "Usage: make-pkg.sh [--help]" >&2; exit 2 ;;
       esac ;;
    *) echo "Usage: make-pkg.sh [--help]" >&2; exit 2 ;;
esac

appdir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dist=$appdir/dist
app=$dist/Safe.app
bundle_id=io.github.fherwig.safedocker
pkg_id=$bundle_id.pkg

for tool in pkgbuild productbuild pkgutil codesign ditto plutil
do
    if ! command -v "$tool" >/dev/null
    then
        echo "$tool is missing. It is part of macOS, so this Mac is unusual." >&2
        exit 1
    fi
done

version=$(tr -d '[:space:]' < "$appdir/VERSION")
if [ ! -d "$app" ]
then
    echo "There is no $app. Build it first with: app/scripts/build-app.sh --release" >&2
    exit 1
fi

# only the app that build-app.sh --release made and checked, of this version
id=$(plutil -extract CFBundleIdentifier raw "$app/Contents/Info.plist" 2>/dev/null || true)
app_version=$(plutil -extract CFBundleShortVersionString raw "$app/Contents/Info.plist" 2>/dev/null || true)
if [ "$id" != "$bundle_id" ]
then
    echo "$app is not Safe.app (its identifier is '${id:-none}')." >&2
    exit 1
fi
if [ "$app_version" != "$version" ]
then
    echo "$app is version '$app_version', but app/VERSION says $version. Build it again." >&2
    exit 1
fi
if ! codesign --verify --strict "$app" 2>/dev/null
then
    echo "The signature of $app is not valid. Build it again." >&2
    exit 1
fi
report=$("$app/Contents/MacOS/Safe" --self-test 2>/dev/null) || {
    echo "The self-test of $app failed; see: $app/Contents/MacOS/Safe --self-test" >&2
    exit 1
}
if ! printf '%s' "$report" | grep -Eq '"configuration" *: *"release"'
then
    echo "$app is a debug build. Build it with: app/scripts/build-app.sh --release" >&2
    exit 1
fi

pkg=Safe-$version.pkg
# a folder of its own for the parts, removed at the end
stage=$dist/pkg-parts
(cd "$dist" && /bin/rm -rf ./pkg-parts ./"$pkg")
trap '(cd "$dist" && /bin/rm -rf ./pkg-parts)' EXIT
mkdir -p "$stage/root"

# the payload: Safe.app alone, without extended attributes or resource forks
ditto --noextattr --norsrc "$app" "$stage/root/Safe.app"
codesign --verify --strict "$stage/root/Safe.app"

# Bundle relocation off: left on, the installer looks for any bundle with Safe's
# identifier on the Mac, decides that is where the app lives, and installs over
# it there. It did so to Marina's build folder once and left ~/Applications empty.
pkgbuild --analyze --root "$stage/root" "$stage/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$stage/component.plist"
pkgbuild --quiet --root "$stage/root" \
    --component-plist "$stage/component.plist" \
    --identifier "$pkg_id" \
    --version "$version" \
    --install-location /Applications \
    "$stage/component.pkg"
sed "s/__VERSION__/$version/" "$appdir/Resources/distribution.xml" > "$stage/distribution.xml"
productbuild --quiet --distribution "$stage/distribution.xml" \
    --package-path "$stage" \
    "$dist/$pkg"

# a look inside: the payload is Safe.app and the install goes to the home folder
if ! pkgutil --payload-files "$dist/$pkg" | grep -qx './Safe.app/Contents/MacOS/Safe'
then
    echo "$dist/$pkg does not hold Safe.app." >&2
    exit 1
fi

echo "Built $dist/$pkg"
echo "  version $version, installs Safe.app into ~/Applications, unsigned"
