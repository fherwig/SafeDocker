#!/bin/bash
# Set up the safe on this Mac: ask where the encrypted disk image lives and
# which app syncs its folder, save the answers in safe.conf (git ignores it),
# and build the Docker image if it is missing. Run it again to change the
# settings.

dir=$(dirname "$(readlink -f "$0")")
conf=$dir/safe.conf
image=$(sed -n 's/^image=//p' "$dir/safe_load.sh")

[ -f "$conf" ] && . "$conf"

# show a path under the home folder as ~/...
tilde() { case $1 in "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;; *) printf '%s' "$1" ;; esac; }

echo "Where does the encrypted disk image of your safe live?"
read -e -p "Path${SAFE_DMG:+ [$(tilde "$SAFE_DMG")]}: " answer
answer=${answer:-$SAFE_DMG}
if [ -z "$answer" ]
then
    echo "No path given. Nothing changed."
    exit 1
fi
dmg=${answer/#\~/$HOME}
case $dmg in /*) ;; *) dmg=$PWD/$dmg ;; esac
case $dmg in
    *[\"\$\`\\]*) echo "Please choose a path without \" \$ \` or \\ in it. Nothing changed."; exit 1 ;;
esac
if [ ! -f "$dmg" ]
then
    echo "There is no file $dmg yet. To make an encrypted disk image there:"
    echo "  hdiutil create -size 100m -fs APFS -encryption AES-256 -volname safe \"$dmg\""
    read -p "Use this location anyway? [y/N] " ok
    case $ok in
        y|Y|yes|Yes) ;;
        *) echo "Nothing changed."; exit 1 ;;
    esac
fi

echo "If an app keeps that folder in sync, safe_load.sh can check that it is running."
echo "The app's process name, as Activity Monitor shows it, or none:"
read -p "App${SAFE_SYNC_APP:+ [$SAFE_SYNC_APP]}: " app
app=${app:-$SAFE_SYNC_APP}
[ "$app" = none ] && app=
case $app in
    *[\"\$\`\\]*) echo "Please choose a name without \" \$ \` or \\ in it. Nothing changed."; exit 1 ;;
esac
if [ -n "$app" ] && ! pgrep -x "$app" >/dev/null
then
    echo "Note: no process called $app is running right now."
fi

# a path under the home folder is saved as $HOME/..., so that safe.conf
# also works on other Macs that sync this folder
case $dmg in
    "$HOME"/*) saved='$HOME'${dmg#"$HOME"} ;;
    *) saved=$dmg ;;
esac
{
    echo "# Written by install.sh: where your safe lives. Not part of git."
    printf 'SAFE_DMG="%s"\n' "$saved"
    printf 'SAFE_SYNC_APP="%s"\n' "$app"
} > "$conf"
echo "Saved in $conf"

if docker image inspect "$image" >/dev/null 2>&1
then
    echo "The Docker image $image is there."
else
    echo "Building the Docker image $image ...."
    docker build -t "$image" "$dir" || exit 1
fi

if ! command -v safe_load.sh >/dev/null
then
    echo "To start the safe from anywhere, link safe_load.sh into a folder on your PATH, for example:"
    echo "  ln -s \"$dir/safe_load.sh\" ~/bin/"
fi
echo "Done. Start the safe with safe_load.sh."
