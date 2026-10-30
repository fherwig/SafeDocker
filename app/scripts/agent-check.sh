#!/bin/bash
# Check whether this Mac can run Safe.app and build it from source, for the
# install agent (INSTALL-AGENT.md). Prints one JSON object on stdout:
#
#   ready_to_install  every "required" check is ok
#   ready_to_build    and every "build" check is ok too
#   warnings          the "warn" checks that are not ok
#   checks            per check: level, ok, value and a hint on what to do
#
# Levels: required (to run Safe.app at all), build (to build it from source),
# warn (recommended for the user's safety), info (facts, never a failure).
# Read only: it changes nothing (docker info may add to Docker Desktop's own
# log), needs no administrator and no password, and never runs a developer
# tool that is not installed, because macOS would then open a dialog offering
# to install the Command Line Tools. Exit status 0 whenever the report is
# printed.

set -u
export LC_ALL=C
# the system's tools even with a minimal PATH, as some agent tools and launchd
# jobs give (sysctl is in /usr/sbin); the caller's own folders still come first
export PATH="${PATH:+$PATH:}/usr/bin:/bin:/usr/sbin:/sbin"
# and without HOME, as env -i and some sandboxes give: the user's home folder from
# the directory service; if even that fails, the checks that need it say "unknown"
if [ -z "${HOME:-}" ]
then
    HOME=$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
    export HOME
fi

case ${1:-} in
    "") ;;
    -h|--help) sed -n '2,16s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "Usage: agent-check.sh [--help]" >&2; exit 2 ;;
esac

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
bundle_id=io.github.fherwig.safedocker

# --- JSON output ------------------------------------------------------------

json_string() {
    local s
    s=$(printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037')
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/}
    printf '"%s"' "$s"
}

checks=""
required_ok=true
build_ok=true
warnings=""

# check NAME LEVEL OK VALUE HINT
check() {
    local entry
    entry=$(printf '    %s: {"level": %s, "ok": %s, "value": %s, "hint": %s}' \
        "$(json_string "$1")" "$(json_string "$2")" "$3" "$(json_string "$4")" "$(json_string "$5")")
    checks=${checks:+$checks,$'\n'}$entry
    if [ "$3" != true ]
    then
        case $2 in
            required) required_ok=false; build_ok=false ;;
            build) build_ok=false ;;
            warn) warnings=${warnings:+$warnings, }$(json_string "$1") ;;
        esac
    fi
}

# version_at_least 15.4 15 -> true if the first is at least the second
version_at_least() {
    local IFS=.
    local -a a b
    a=($1) b=($2)
    local i x y
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

# runs a command, but gives up after some seconds: "docker info" can hang
with_timeout() {
    local tenths=$(($1 * 10))
    shift
    "$@" &
    local pid=$!
    while [ $tenths -gt 0 ] && kill -0 "$pid" 2>/dev/null
    do
        sleep 0.1
        tenths=$((tenths - 1))
    done
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
}

# --- the system -------------------------------------------------------------

macos=$(sw_vers -productVersion 2>/dev/null)
build=$(sw_vers -buildVersion 2>/dev/null)
if [ -n "$macos" ] && version_at_least "$macos" 13
then
    check macos required true "$macos ($build)" "macOS 13 or later is needed; this is fine."
else
    check macos required false "${macos:-unknown}" \
        "Safe.app needs macOS 13 (Ventura) or later. Suggest a macOS update to the user; do not start one yourself."
fi
# building needs the macOS 15.2 SDK, which comes with Command Line Tools 16.2 or
# later, and those install only on macOS 14.5 or later
if [ -n "$macos" ] && version_at_least "$macos" 14.5
then
    check macos_for_build build true "$macos" "Building from source needs macOS 14.5 or later; this is fine."
else
    check macos_for_build build false "${macos:-unknown}" \
        "This Mac cannot build Safe.app: building needs the macOS 15.2 SDK (Command Line Tools 16.2 or later), which needs macOS 14.5 or later. Install the release instead (INSTALL-AGENT.md section 4), which needs only macOS 13; or suggest a macOS update to the user (do not start one yourself)."
fi

arch=$(uname -m)
case $arch in
    arm64|x86_64) check architecture required true "$arch" "Apple silicon and Intel Macs are both supported." ;;
    *) check architecture required false "$arch" "Safe.app is built for arm64 and x86_64 only." ;;
esac

filevault=$(fdesetup status 2>/dev/null | head -1)
case $filevault in
    "FileVault is On."*)
        check filevault warn true "$filevault" "The disk is encrypted, so deleted plain copies cannot be read from it." ;;
    *)
        check filevault warn false "${filevault:-unknown}" \
            "Recommend that the user turns on FileVault in System Settings > Privacy & Security > FileVault: without it, plain copies deleted from the disk (for example the folder a volume was made from) can still be read from it. Only the user turns it on; never do it for them." ;;
esac

swap=$(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null)
case $swap in
    *encrypted*) check encrypted_swap warn true "encrypted" "Memory written to swap is encrypted." ;;
    *) check encrypted_swap warn false "${swap:-unknown}" \
           "Swap is not reported as encrypted. With FileVault on, macOS encrypts swap; recommend FileVault to the user." ;;
esac

# free space on the volume of the home folder, in MB
free_mb=""
if [ -n "$HOME" ]
then
    free_mb=$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 {print int($4 / 1024)}')
fi
if [ -z "$free_mb" ]
then
    check free_space required false "unknown" \
        "The free space could not be read, because the home folder is unknown (HOME is not set and the directory service did not say). Run the script again in a normal shell of the user."
    check free_space_for_build build false "unknown" "The free space could not be read; see free_space."
else
    if [ "$free_mb" -ge 200 ]
    then
        check free_space required true "$free_mb MB free" "Safe.app itself needs about 20 MB."
    else
        check free_space required false "$free_mb MB free" \
            "Less than 200 MB is free on the disk of the home folder. Ask the user to free some space."
    fi
    if [ "$free_mb" -ge 2048 ]
    then
        check free_space_for_build build true "$free_mb MB free" \
            "Building from source needs about 1 GB in ~/Library/Caches/SafeDocker-build."
    else
        check free_space_for_build build false "$free_mb MB free" \
            "Building from source needs about 2 GB free (build products go to ~/Library/Caches/SafeDocker-build). Ask the user to free some space, or install the release instead (INSTALL-AGENT.md section 4)."
    fi
fi

# --- tools that come with macOS -----------------------------------------------

for tool in hdiutil codesign ditto shasum curl
do
    case $tool in
        hdiutil) why="Safe.app makes and opens its encrypted volumes with it." ;;
        codesign) why="Checks the signature of Safe.app." ;;
        ditto) why="Copies Safe.app and unpacks a release zip." ;;
        shasum) why="Checks the SHA-256 checksum of a release." ;;
        curl) why="Downloads a release; it sets no quarantine attribute." ;;
    esac
    if [ -x "/usr/bin/$tool" ]
    then
        check "$tool" required true "/usr/bin/$tool" "$why"
    else
        check "$tool" required false "missing" "$why It is part of macOS, so this Mac is unusual: report it to the user."
    fi
done

for tool in plutil xattr
do
    if [ -x "/usr/bin/$tool" ]
    then
        check "$tool" build true "/usr/bin/$tool" "build-app.sh uses it."
    else
        check "$tool" build false "missing" "build-app.sh needs it. It is part of macOS: report it to the user."
    fi
done

# --- developer tools, for building from source --------------------------------
# /usr/bin/swift, lipo and git are stubs that open an install dialog when the
# developer tools are missing, so only the real programs inside the developer
# folder are run.

devdir=$(xcode-select -p 2>/dev/null)
find_dev_tool() {
    local dir
    for dir in "$devdir/usr/bin" "$devdir/Toolchains/XcodeDefault.xctoolchain/usr/bin"
    do
        if [ -x "$dir/$1" ]
        then
            echo "$dir/$1"
            return 0
        fi
    done
    return 1
}

if [ -n "$devdir" ] && [ -d "$devdir" ] && find_dev_tool swift >/dev/null
then
    check developer_tools build true "$devdir" "The Command Line Tools (or Xcode) are installed."
    have_dev=true
else
    check developer_tools build false "${devdir:-not installed}" \
        "Building from source needs Apple's Command Line Tools. Installing them needs an administrator: ask the user, who runs xcode-select --install and confirms the dialog. Without them, install the release instead (INSTALL-AGENT.md section 4), which needs no developer tools."
    have_dev=false
fi

if [ "$have_dev" = true ]
then
    # a swift on the PATH that is not Apple's stub, for example from swift.org, comes first
    swift=$(command -v swift)
    if [ -z "$swift" ] || [ "$swift" = /usr/bin/swift ]
    then
        swift=$(find_dev_tool swift)
    fi
    swift_line=$("$swift" --version 2>/dev/null | grep -o 'Swift version [0-9][0-9.]*' | head -1)
    swift_version=${swift_line#Swift version }
    # build-app.sh runs swift through /usr/bin/swift, that is xcrun, which refuses
    # while the licence of an Xcode.app has not been accepted, a step that needs an
    # administrator; the swift found above runs anyway, so ask Xcode itself
    xcode_licence=ok
    case $devdir in
        *.app/Contents/Developer)
            if [ -x "$devdir/usr/bin/xcodebuild" ] &&
                ! with_timeout 20 "$devdir/usr/bin/xcodebuild" -license check >/dev/null 2>&1
            then
                xcode_licence=missing
            fi ;;
    esac
    if [ "$xcode_licence" != ok ]
    then
        check swift build false "${swift_version:-unknown} ($swift), Xcode licence not accepted" \
            "The Xcode that xcode-select points to ($devdir) needs its licence accepted before it builds anything, which needs an administrator: ask the user to run sudo xcodebuild -license, or to switch to the Command Line Tools with sudo xcode-select -s /Library/Developer/CommandLineTools if they are installed."
    elif [ -n "$swift_version" ] && version_at_least "$swift_version" 6.0
    then
        check swift build true "$swift_version ($swift)" "Swift 6.0 or later builds Safe.app; it was tested with Swift 6.2."
    else
        check swift build false "${swift_version:-unknown} ($swift)" \
            "Safe.app needs Swift 6.0 or later (Command Line Tools 16.2 or later). Ask the user to update the Command Line Tools in System Settings > General > Software Update."
    fi

    sdk_version=""
    for sdk in "$devdir/SDKs/MacOSX.sdk" "$devdir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
    do
        if [ -f "$sdk/SDKSettings.plist" ]
        then
            sdk_version=$(plutil -extract Version raw "$sdk/SDKSettings.plist" 2>/dev/null)
            break
        fi
    done
    if [ -n "$sdk_version" ] && version_at_least "$sdk_version" 15.2
    then
        check macos_sdk build true "$sdk_version" "The macOS SDK 15.2 or later is needed; tested with 26.2."
    else
        check macos_sdk build false "${sdk_version:-not found}" \
            "The editor switches off text features of macOS 14 and 15 (Writing Tools in menus came with 15.2), which needs the macOS 15.2 SDK or later to build (Command Line Tools 16.2 or later, which need macOS 14.5; see macos_for_build). On macOS 14.5 or later, ask the user to update the Command Line Tools in System Settings > General > Software Update; otherwise install the release instead (INSTALL-AGENT.md section 4)."
    fi

    for tool in lipo git
    do
        path=$(find_dev_tool "$tool")
        case $tool in
            lipo) why="build-app.sh joins the Apple silicon and Intel programs with it." ;;
            git) why="Gets and updates the source; downloading the repository as a zip with curl works too." ;;
        esac
        if [ -n "$path" ]
        then
            check "$tool" build true "$path" "$why"
        else
            check "$tool" build false "missing" "$why It comes with the Command Line Tools."
        fi
    done
else
    for tool in swift macos_sdk lipo git
    do
        check "$tool" build false "not checked" "Comes with the Command Line Tools, see developer_tools."
    done
fi

# --- facts for the agent --------------------------------------------------------

if [ -f "$repo/app/VERSION" ]
then
    check source info true "$(tr -d '[:space:]' < "$repo/app/VERSION") in $repo" \
        "The version in this checkout; build it with app/scripts/build-app.sh --release."
else
    check source info false "no app/VERSION in $repo" \
        "No checkout here: fine for an install from the release (INSTALL-AGENT.md section 4); a build from source needs a checkout (5.2)."
fi

# describe_app PATH: "PATH version X, signature valid", or nothing if it is not Safe.app
describe_app() {
    [ -d "$1" ] || return 0
    local id version signature
    id=$(plutil -extract CFBundleIdentifier raw "$1/Contents/Info.plist" 2>/dev/null)
    [ "$id" = "$bundle_id" ] || return 0
    version=$(plutil -extract CFBundleShortVersionString raw "$1/Contents/Info.plist" 2>/dev/null)
    if codesign --verify --strict "$1" 2>/dev/null
    then
        signature="signature valid"
    else
        signature="SIGNATURE INVALID"
    fi
    echo "$1 version ${version:-unknown}, $signature"
}

if [ -z "$HOME" ]
then
    check installed_app info false "unknown" "The home folder is unknown (HOME is not set), so ~/Applications could not be checked."
else
    installed=$(describe_app "$HOME/Applications/Safe.app")
    if [ -n "$installed" ]
    then
        check installed_app info true "$installed" \
            "Safe.app is installed in ~/Applications; an install from source or a release is then an update (INSTALL-AGENT.md section 7)."
    else
        check installed_app info false "not installed" "No Safe.app with the identifier $bundle_id in ~/Applications."
    fi
fi

# a copy in /Applications, which the steps of INSTALL-AGENT.md never make or replace
other=$(describe_app "/Applications/Safe.app")
if [ -n "$other" ]
then
    check other_copy info true "$other" \
        "Another Safe.app is in /Applications, beside the one in ~/Applications that these instructions install and update; both claim .crypt files. Tell the user: they can remove it in the Finder (it may ask for an administrator), or leave it, knowing that there are two copies. Never remove it yourself (rule 4)."
else
    check other_copy info false "none" "No Safe.app in /Applications."
fi

if pgrep -x Safe >/dev/null 2>&1
then
    check app_running info true "running" "Ask the user to close their files and volumes and quit Safe before an update or uninstall."
else
    check app_running info false "not running" "Safe is not running."
fi

if [ -n "$HOME" ] && [ -d "$HOME/Library/Application Support/SafeDocker" ]
then
    check app_data info true "~/Library/Application Support/SafeDocker" \
        "Holds the list of the user's volumes (not the volumes). Uninstalling removes it; the volumes stay where they are."
else
    check app_data info false "none" "Safe.app has not saved a list of volumes yet."
fi

# unencrypted rests of folders that New from Folder did not finish deleting: Safe
# offers to delete them at its next start, from pending-deletes.json; counted,
# never named, and the file must not be removed before the user dealt with them
pending_file="${HOME:-}/Library/Application Support/SafeDocker/pending-deletes.json"
if [ -n "${HOME:-}" ] && [ -f "$pending_file" ]
then
    pending=0
    entries=$(plutil -extract pending raw -o - "$pending_file" 2>/dev/null)
    case $entries in
        ''|*[!0-9]*) entries=0 ;;
    esac
    i=0
    while [ "$i" -lt "$entries" ]
    do
        folder=$(plutil -extract "pending.$i" raw -o - "$pending_file" 2>/dev/null)
        [ -n "$folder" ] && [ -d "$folder" ] && pending=$((pending + 1))
        i=$((i + 1))
    done
else
    pending=0
fi
if [ "$pending" -gt 0 ]
then
    check pending_deletes info true "$pending" \
        "Safe did not finish deleting the unencrypted copy of $pending folder(s) it made into volumes. Before an uninstall, ask the user to start Safe once and answer its question \"Safe did not finish deleting a folder\" (Delete, or Show in Finder); do not remove ~/Library/Application Support/SafeDocker before, which holds the only record of where they are."
else
    check pending_deletes info false "0" "No unencrypted rest of a folder made into a volume is waiting to be deleted."
fi

docker_path=$(command -v docker 2>/dev/null)
for path in /usr/local/bin/docker /Applications/Docker.app/Contents/Resources/bin/docker
do
    if [ -z "$docker_path" ] && [ -x "$path" ]
    then
        docker_path=$path
    fi
done
if [ -z "$docker_path" ]
then
    check docker info false "not installed" \
        "Not needed by Safe.app. Only the terminal tool (safe_load.sh) and app/scripts/time-capsule.sh use Docker."
elif with_timeout 10 "$docker_path" info >/dev/null 2>&1
then
    check docker info true "running ($docker_path)" \
        "Not needed by Safe.app. Only the terminal tool (safe_load.sh) and app/scripts/time-capsule.sh use Docker."
else
    check docker info false "installed, not running ($docker_path)" \
        "Not needed by Safe.app. Only the terminal tool (safe_load.sh) and app/scripts/time-capsule.sh use Docker."
fi

# --- the report -----------------------------------------------------------------

printf '{\n'
printf '  "tool": "agent-check.sh",\n'
printf '  "format": 1,\n'
printf '  "time": %s,\n' "$(json_string "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
printf '  "ready_to_install": %s,\n' "$required_ok"
printf '  "ready_to_build": %s,\n' "$build_ok"
printf '  "warnings": [%s],\n' "$warnings"
printf '  "checks": {\n%s\n  }\n' "$checks"
printf '}\n'
exit 0
