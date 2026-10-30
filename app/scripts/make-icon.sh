#!/bin/bash
# Regenerate Safe's icon: gen-icon.swift draws the 1024 x 1024 master, sips
# scales it to the sizes macOS wants, and iconutil packs them into
# Resources/Safe.icns, which build-app.sh puts into the app. It also writes
# docs/images/safe-icon.png (256 x 256) for the README.
#
#   make-icon.sh
#
# Needs swift, sips and iconutil, which come with the Command Line Tools and
# macOS. Work files go to a fresh folder under /tmp, removed at the end.

set -euo pipefail

appdir=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d /tmp/safetest-icon.XXXXXX)
trap '/bin/rm -rf "${work:?}"' EXIT

swift "$appdir/scripts/gen-icon.swift" "$work/master.png" >/dev/null
mkdir "$work/Safe.iconset"
for s in 16 32 128 256 512
do
    sips -z $s $s "$work/master.png" --out "$work/Safe.iconset/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$work/master.png" --out "$work/Safe.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$work/Safe.iconset" -o "$appdir/Resources/Safe.icns"
mkdir -p "$appdir/../docs/images"
sips -z 256 256 "$work/master.png" --out "$appdir/../docs/images/safe-icon.png" >/dev/null
echo "wrote $appdir/Resources/Safe.icns and docs/images/safe-icon.png"
