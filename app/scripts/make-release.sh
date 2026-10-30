#!/bin/bash
# Make the files of a release of Safe.app in app/dist: build the app with
# build-app.sh --release (which runs its self-test), make the installer with
# make-pkg.sh, and write
#
#   Safe-VERSION.zip   the app, zipped
#   Safe-VERSION.pkg   the installer, which puts it into ~/Applications
#   Safe.zip           the same two files under names without the version, so
#   Safe.pkg           that .../releases/latest/download/Safe.zip always works
#                      (install-safe.sh and the links in README.md use them)
#   SHA256SUMS         the SHA-256 checksums of these four files
#
#   make-release.sh          make them
#   make-release.sh --help   this text
#
# Takes some minutes. Set SAFE_SCRATCH_PATH to build somewhere other than
# ~/Library/Caches/SafeDocker-build (build-app.sh). Nothing is uploaded and nothing
# is installed: publishing is docs/safe-app/publishing.md.

set -euo pipefail

case $# in
    0) ;;
    1) case $1 in
           -h|--help) sed -n '2,19s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
           *) echo "Unknown option $1." >&2; echo "Usage: make-release.sh [--help]" >&2; exit 2 ;;
       esac ;;
    *) echo "Usage: make-release.sh [--help]" >&2; exit 2 ;;
esac

appdir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
dist=$appdir/dist
version=$(tr -d '[:space:]' < "$appdir/VERSION")

"$appdir/scripts/build-app.sh" --release
"$appdir/scripts/make-pkg.sh"

cd "$dist"
for file in "Safe-$version.zip" "Safe-$version.pkg"
do
    if [ ! -f "$file" ]
    then
        echo "$dist/$file is missing." >&2
        exit 1
    fi
done
cp -p "Safe-$version.zip" Safe.zip
cp -p "Safe-$version.pkg" Safe.pkg
shasum -a 256 "Safe-$version.zip" "Safe-$version.pkg" Safe.zip Safe.pkg > SHA256SUMS
shasum -a 256 -c SHA256SUMS >/dev/null

# the zip as a user gets it: it unpacks to Safe.app with a valid signature and
# the version of this release
/bin/rm -rf ./release-check
trap '(cd "$dist" && /bin/rm -rf ./release-check)' EXIT
mkdir release-check
ditto -x -k Safe.zip release-check
codesign --verify --strict release-check/Safe.app
unpacked=$(release-check/Safe.app/Contents/MacOS/Safe --version)
if [ "$unpacked" != "$version" ]
then
    echo "Safe.zip holds version '$unpacked', not $version." >&2
    exit 1
fi

echo "Release files of Safe $version in $dist:"
ls -l "Safe-$version.zip" "Safe-$version.pkg" Safe.zip Safe.pkg SHA256SUMS | awk '{printf "  %-20s %10s bytes\n", $9, $5}'
echo "SHA256SUMS:"
sed 's/^/  /' SHA256SUMS
