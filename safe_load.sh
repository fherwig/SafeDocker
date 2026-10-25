#!/bin/bash

# docker run -h safe --name safe -v /Volumes/safe:/home/user -t -i fherwig/safe:22.0 /bin/bash

# Realisations:
# * when we mount and unmount, even if we don't change anything, the disk image
#   will get a new time stamp. Therefore we can't know which safe has been last touched

# Strategy
# * the disk image lives in a synced folder, on every machine that uses the safe;
#   there it is part of each machine's Time Machine backup
#
# What this script does
# * read where the disk image lives from safe.conf, which install.sh writes
# * check if safe is already mounted > exit
# * if safe.conf names the app that syncs the folder, check that it is running,
#   ask for confirmation to continue if this is not the case
# * check if the disk image exists, if not exit
# * mount the disk image at /Volumes/safe
# * start docker container safe, without network, and mount /Volumes/safe to home
# * at that point the user runs `bd` (built into the image) to inspect and/or
#   change the safe.txt file
# * when user exits container this script
#   - stops and removes the Docker safe container
#   - makes Docker forget the files of the safe, and unmounts /Volumes/safe,
#     forcing the unmount if Docker still holds it
#   this also happens if the script is interrupted or the terminal is closed


# Where the disk image lives is a setting, not part of this script:
# install.sh asks for it and saves it in safe.conf, next to this script,
# which git ignores.
conf=$(dirname "$(readlink -f "$0")")/safe.conf
[ -f "$conf" ] && . "$conf"
if [ -z "$SAFE_DMG" ]
then
    echo "No safe set up yet. Run install.sh in $(dirname "$conf") first."
    exit 1
fi
dmg=$SAFE_DMG
volume=/Volumes/safe
container=safe
image=fherwig/safe:22.0

# check if the safe is already mounted, by this script or from the Finder
if [ -d $volume ] || hdiutil info | awk -F' : ' '/^image-path/ {print $2}' | grep -qxF "$dmg"
then
    echo "Safe is mounted. This means"
    echo "another safe process must be operating."
    echo "Find docker instance and close that instance,"
    echo "and make sure the safe is unmounted."
    echo "Then rerun."
    exit 1
fi

# check that the app which syncs the folder of the disk image is running
if [ -n "$SAFE_SYNC_APP" ] && ! pgrep -x "$SAFE_SYNC_APP" >/dev/null
then
    echo "$SAFE_SYNC_APP is not running. $dmg may not be the latest version."
    read -p "Continue anyways? [y/N] " input_continue
    if [ "$input_continue" != 'y' ] && [ "$input_continue" != 'Y' ]
    then
        echo "OK, exiting ...."
        exit
    fi
fi


if [ ! -f "$dmg" ]
then
    echo "Can't find $dmg"
    echo "Is the folder it lives in available? To set another location, run install.sh."
    echo "Exiting ...."
    exit 1
fi

# -mountpoint: mount the safe at /Volumes/safe, whatever its volume is called
if ! hdiutil attach -mountpoint $volume "$dmg" >/dev/null
then
    echo "Could not mount $dmg"
    echo "Exiting ...."
    exit 1
fi

# Docker Desktop's file sharing keeps the files of the safe cached in its
# Linux VM, and holds the volume for minutes after the container has stopped.
# If the volume goes away while the VM still caches its files, Docker cannot
# share the next safe that is mounted ("mkdir /host_mnt/Volumes/safe: file
# exists") until Docker Desktop restarts. Dropping the VM's file caches
# prevents this, and also repairs it. Writing to drop_caches takes a
# privileged container; this one sees neither the safe nor a network.
# Other containers only have to reread their files.
forget_cached_files() {
    docker run --rm --privileged --user root --network none --pull never \
        $image sh -c 'sync; echo 3 > /proc/sys/vm/drop_caches' >/dev/null 2>&1
}

# From here on, stop the container and unmount the safe however we exit,
# also when interrupted or when the terminal window is closed
cleanup() {
    if [ -n "$started" ]
    then
        echo "Stopping and removing Docker safe container"
        docker rm -f $container >/dev/null 2>&1
        forget_cached_files
    fi
    [ -d $volume ] || return
    echo "Unmounting $volume"
    # A normal unmount fails while Docker holds the volume. Once the container
    # is gone and the VM's caches are written back and dropped, forcing the
    # unmount loses nothing, so after a few tries we force it.
    tries=0
    until hdiutil detach -quiet $volume 2>/dev/null
    do
        [ -d $volume ] || break
        tries=$((tries+1))
        if [ $tries -gt 3 ]
        then
            echo "Docker still holds $volume, forcing the unmount"
            hdiutil detach -force -quiet $volume && break
            echo "Could not unmount $volume. Quit Docker Desktop, then run: hdiutil detach $volume"
            return
        fi
        sleep 1
    done
    echo "$volume unmounted."
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

tries=0
while [ ! -d $volume ] ; do
    tries=$((tries+1))
    if [ $tries -gt 30 ]
    then
        echo "$volume did not show up. Exiting ...."
        exit 1
    fi
    echo "Pausing until Tresor available."
    sleep 1
done

# repair what an earlier session may have left behind, see forget_cached_files
forget_cached_files

# --rm removes the container when you exit it. The container sees the
# secrets in plain text, so it gets no network and cannot gain privileges.
# --pull never: use the local image, never fetch one from Docker Hub.
# docker runs in the background (<&0 keeps the terminal) and we wait for it:
# docker does not exit when the terminal window is closed, and bash runs
# the cleanup only after a foreground command has finished.
started=1
docker run --rm -h safe --name $container --network none --cap-drop ALL \
    --security-opt no-new-privileges --pull never \
    -v $volume:/home/user -t -i $image /bin/bash <&0 &
wait $!
if [ $? == 125 ]
then
    echo "Docker could not start the container, see the message above."
    echo "If an old container safe was in the way, it is removed now."
    echo "If it says \"mkdir /host_mnt$volume: file exists\", restart Docker Desktop."
    echo "Then, try again ...."
fi
