# SafeDocker

SafeDocker keeps a text file of passwords encrypted twice. The file, `safe.txt.crypt`, is encrypted with openssl and lives inside an encrypted macOS disk image. You read and edit it in a Docker container that has no network. When you leave, the plain text is gone, the container is removed and the disk image is unmounted.

## What you need

- macOS with Docker Desktop
- an encrypted disk image for the safe. To make one:

      hdiutil create -size 100m -fs APFS -encryption AES-256 -volname safe safe.dmg

## Install

    ./install.sh

asks where your disk image lives, and which app keeps its folder in sync, if any. It saves the answers in `safe.conf`, which git ignores, and builds the Docker image `fherwig/safe:22.0` if it is missing. `docker pull fherwig/safe:22.0` gets a ready-made image from Docker Hub instead, for Intel and Apple-silicon Macs.

## Use

    ./safe_load.sh

asks for the password of the disk image, mounts it at `/Volumes/safe` and opens a shell in the container, with the safe as the home folder. There, `bd` decrypts `safe.txt.crypt`, opens it in emacs, encrypts it again if you changed it, and removes the plain text. Leave the container with `exit`; `safe_load.sh` then removes the container and unmounts the safe.

The first time, write `safe.txt` in the container (`emacs safe.txt`) and encrypt it with `crypt.sh -e -r safe.txt`. [safe_tools/README.md](safe_tools/README.md) describes `bd` and `crypt.sh`.

Docker Desktop keeps the files of the safe cached in its Linux VM. To clear that cache, `safe_load.sh` runs a privileged container for a second, before and after the session. That container has no network and no access to the safe.
