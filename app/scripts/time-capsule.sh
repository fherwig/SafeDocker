#!/bin/bash
# Save the Docker image fherwig/safe:22.0 as an archive file: a way to open
# the encrypted files that depends neither on macOS, nor on Safe.app, nor on
# Docker Hub (requirement G5). Records the image's digest and writes two
# files into DIR:
#
#   fherwig-safe-22.0-DATE.tar.gz   the image, from docker save
#   fherwig-safe-22.0-DATE.txt      digest, image ID, platform, OpenSSL version,
#                                   the archive's SHA-256, and how to use it
#
#   time-capsule.sh DIR
#
# DIR must exist and must not lie inside the repository or any other git
# repository: the archive is large and does not belong in git. The digest is
# compared with the one pinned in tools/docker-image.txt. Needs Docker
# running and the image on this Mac; it never pulls, builds or removes an
# image, and touches no container but a throwaway one of its own.

set -euo pipefail

image=fherwig/safe:22.0
base=fherwig-safe-22.0

usage() { echo "Usage: time-capsule.sh DIR"; }

case $# in
    1) case $1 in
           -h|--help) sed -n '2,18s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
           -*) echo "Unknown option $1." >&2; usage >&2; exit 2 ;;
       esac ;;
    *) usage >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
if [ ! -d "$1" ]
then
    echo "$1 is not a folder. Make it first, outside the repository, for example: mkdir -p ~/SafeDocker-time-capsule" >&2
    exit 1
fi
dir=$(cd "$1" && pwd -P)

# never inside the repository, nor inside any other git repository
case $dir/ in
    "$repo"/*)
        echo "$dir is inside the repository $repo. Choose a folder outside it." >&2
        exit 1 ;;
esac
d=$dir
while [ -n "$d" ] && [ "$d" != / ]
do
    if [ -e "$d/.git" ]
    then
        echo "$dir is inside the git repository $d. Choose a folder outside any repository." >&2
        exit 1
    fi
    d=$(dirname "$d")
done

# Docker running, and the image here
docker=$(command -v docker || true)
for path in /usr/local/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker
do
    if [ -z "$docker" ] && [ -x "$path" ]
    then
        docker=$path
    fi
done
if [ -z "$docker" ]
then
    echo "Docker is not installed. The time capsule needs Docker Desktop with the image $image." >&2
    exit 1
fi
if ! "$docker" info >/dev/null 2>&1
then
    echo "Docker is not running. Start Docker Desktop and run this again." >&2
    exit 1
fi
pinned=$(grep -v '^#' "$repo/tools/docker-image.txt" 2>/dev/null | grep -m1 . || true)
if ! "$docker" image inspect "$image" >/dev/null 2>&1
then
    echo "The image $image is not on this Mac, and this script never pulls one." >&2
    if [ -n "$pinned" ]
    then
        echo "Get the pinned image with: docker pull $pinned && docker tag $pinned $image" >&2
    fi
    exit 1
fi

inspect() { "$docker" image inspect --format "$1" "$image"; }
id=$(inspect '{{.Id}}')
digests=$(inspect '{{range .RepoDigests}}{{println .}}{{end}}' | grep . || true)
platform=$(inspect '{{.Os}}/{{.Architecture}}')
created=$(inspect '{{.Created}}')
size=$(inspect '{{.Size}}')
if [ -z "$digests" ]
then
    digest_note="none: this image was built on this Mac and never pushed, so it has no registry digest"
elif [ -n "$pinned" ] && printf '%s\n' "$digests" | grep -xF "$pinned" >/dev/null
then
    digest_note="matches tools/docker-image.txt"
else
    digest_note="DIFFERS from tools/docker-image.txt ($pinned)"
fi

stamp=$(date +%Y%m%d)
archive=$base-$stamp.tar.gz
record=$base-$stamp.txt
for f in "$archive" "$record"
do
    if [ -e "$dir/$f" ]
    then
        echo "$dir/$f exists already. Not overwriting it." >&2
        exit 1
    fi
done
free_kb=$(df -k "$dir" | awk 'NR == 2 {print $4}')
if [ "$((free_kb * 1024))" -lt "$size" ]
then
    echo "Not enough space in $dir: the image has $((size / 1048576)) MB, $((free_kb / 1024)) MB are free." >&2
    exit 1
fi

# versions inside the image, from a throwaway container (never the safe's own
# container, which is called safe) without network
versions=$("$docker" run --rm --network none --pull never --name "safetest-capsule-$$" "$image" \
    sh -c 'openssl version; cat /etc/debian_version')
openssl_version=$(printf '%s\n' "$versions" | sed -n 1p)
debian_version=$(printf '%s\n' "$versions" | sed -n 2p)

# save to a hidden partial file and rename it at the end, so that an
# interrupted run never leaves a file that looks complete
partial=$dir/.$archive.partial
trap '/bin/rm -f "$partial"' EXIT
trap 'exit 1' INT TERM HUP
echo "Saving $image ($((size / 1048576)) MB) into $dir/$archive ...." >&2
"$docker" save "$image" | gzip -n > "$partial"
gzip -t "$partial"
if ! tar -tzf "$partial" | grep -x 'manifest.json' >/dev/null
then
    echo "The saved archive holds no manifest.json, so it is not a Docker image archive." >&2
    exit 1
fi
sha=$(shasum -a 256 "$partial" | awk '{print $1}')
bytes=$(wc -c < "$partial" | tr -d ' ')
mv "$partial" "$dir/$archive"
trap - EXIT

version=$(tr -d '[:space:]' < "$repo/app/VERSION" 2>/dev/null || echo unknown)
{
    echo "Time capsule of the Docker image $image"
    echo "saved $(date -u +%Y-%m-%dT%H:%M:%SZ) by app/scripts/time-capsule.sh (SafeDocker $version)"
    echo
    echo "image:            $image"
    echo "registry digest:  ${digests:-none}" | sed '2,$s/^/                  /'
    echo "pinned digest:    $digest_note"
    echo "image ID:         $id"
    echo "platform:         $platform"
    echo "created:          $created"
    echo "OpenSSL:          $openssl_version"
    echo "Debian:           $debian_version"
    echo "archive:          $archive"
    echo "archive SHA-256:  $sha"
    echo "archive size:     $bytes bytes"
    echo
    echo "To open an encrypted file with it, on any computer with Docker, without the internet:"
    echo
    echo "  shasum -a 256 $archive    (compare with the SHA-256 above)"
    echo "  docker load -i $archive"
    echo "  cd FOLDER-WITH-THE-FILE"
    echo "  docker run --rm -it --network none -v \"\$PWD\":/home/user $image bash"
    echo
    echo "and in the container, which asks for the password:"
    echo
    echo "  openssl enc -d -aes-256-cbc -md sha512 -pbkdf2 -iter 100000 -in FILE.crypt -out FILE"
    echo
    echo "FILE is not encrypted: delete it when done. The archive holds the image for"
    echo "$platform; Docker Desktop runs it on other processors through emulation."
} > "$dir/$record"

cat "$dir/$record"
echo
echo "Wrote $dir/$archive"
echo "  and $dir/$record"
