#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
VERSION=9.3
LIMIT=20000000
PREFIX=''
ARCHIVE=''

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage()
{
    printf 'Usage: %s [--version VERSION] [--limit COUNT] [--prefix PATH] [--archive FILE]\n' "$0"
    printf 'Builds native OpenBGPD using a pinned profile and the Pending Prefix patch.\n'
    printf 'Default: version 9.3, limit 20000000, prefix ~/opt/openbgpd-native-VERSION-pending-cap-COUNT.\n'
    printf 'Optional --archive uses a local copy of the pinned upstream archive.\n'
}

while (( $# )); do
    case "$1" in
        --version|--limit|--prefix|--archive)
            (( $# >= 2 )) && [[ -n "$2" ]] || die "$1 needs a value"
            case "$1" in
                --version) VERSION=$2 ;;
                --limit) LIMIT=$2 ;;
                --prefix) PREFIX=$2 ;;
                --archive) ARCHIVE=$2 ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "unexpected argument: $1" ;;
    esac
done
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] || die 'invalid release version'
[[ "$LIMIT" =~ ^[0-9]{1,10}$ ]] || die 'limit must be an integer from 1 to 2147483647'
LIMIT=$(( 10#$LIMIT ))
(( LIMIT >= 1 && LIMIT <= 2147483647 )) || die 'limit must be an integer from 1 to 2147483647'

PROFILE_DIR="$SCRIPT_DIR/profiles/$VERSION"
[[ -f "$PROFILE_DIR/native.conf" ]] || die "no reviewed native profile for OpenBGPD $VERSION"
[[ "$(uname -s)" == OpenBSD ]] || die 'OpenBSD is required'
(( EUID != 0 )) || die 'build as an unprivileged user'
OS_VERSION=$(uname -r)
startup_patch=''
cppflags=("-DRDE_PENDING_LIMIT=${LIMIT}LL")
# Only trusted profiles shipped in this repository are loaded.
source "$PROFILE_DIR/native.conf"
native_platform "$OS_VERSION" || die "OpenBGPD $VERSION profile does not support OpenBSD $OS_VERSION"
[[ "$COMMIT" =~ ^[0-9a-f]{40}$ && "$ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || die 'invalid archive pin in native profile'
source "$SCRIPT_DIR/../scripts/patch-path.sh"
PENDING_PATCH=$(select_patch "$VERSION" pending-backpressure.patch openbgpd-9.3-pending-backpressure.patch) ||
    die "missing or unsafe Pending Prefix patch for $VERSION"

if [[ -z "$PREFIX" ]]; then
    PREFIX="$HOME/opt/openbgpd-native-$VERSION-pending-cap-$LIMIT"
fi
[[ "$PREFIX" =~ ^/[a-zA-Z0-9/._+-]+$ ]] || die 'prefix must be an absolute path with no spaces'
case "$PREFIX/" in */../*|*/./*|*//*) die 'invalid prefix path components' ;; esac
[[ "$PREFIX" == "$HOME/"* ]] || die 'prefix must be inside your home directory'
home_dir=$(cd -- "$HOME" && pwd -P)
prefix_parent=$(dirname -- "$PREFIX")
if [[ "$prefix_parent" == "$HOME/opt" && ! -e "$prefix_parent" && ! -L "$prefix_parent" ]]; then
    mkdir -p -- "$prefix_parent"
fi
prefix_parent=$(cd -- "$prefix_parent" && pwd -P) || die 'prefix parent directory must already exist'
[[ "$prefix_parent" == "$home_dir" || "$prefix_parent" == "$home_dir/"* ]] || die 'resolved prefix must be inside your home directory'
PREFIX="$prefix_parent/$(basename -- "$PREFIX")"
[[ ! -e "$PREFIX" && ! -L "$PREFIX" ]] || die "existing prefix preserved: $PREFIX"
id _bgpd >/dev/null || die 'native _bgpd privilege-separation user is missing'
for command in sha256 tar make cc git; do
    command -v "$command" >/dev/null || die "$command is missing"
done

work_dir=$(mktemp -d /tmp/openbgpd-native.XXXXXXXXXX)
prefix_created=0
cleanup()
{
    rm -rf -- "$work_dir"
    if (( prefix_created )); then
        rm -f -- "$PREFIX/sbin/bgpd" "$PREFIX/sbin/bgpctl" "$PREFIX/BUILD-METADATA.txt"
        rmdir -- "$PREFIX/sbin" "$PREFIX"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

archive_url="https://codeload.github.com/openbgpd-portable/openbgpd-openbsd/tar.gz/$COMMIT"
if [[ -n "$ARCHIVE" ]]; then
    [[ -f "$ARCHIVE" ]] || die "archive is not a file: $ARCHIVE"
    cp -- "$ARCHIVE" "$work_dir/native.tar.gz"
else
    ftp -o "$work_dir/native.tar.gz" "$archive_url"
fi
[[ "$(sha256 -q "$work_dir/native.tar.gz")" == "$ARCHIVE_SHA256" ]] || die 'pinned native archive checksum differs'
tar -xzf "$work_dir/native.tar.gz" -C "$work_dir"
source_root="$work_dir/openbgpd-openbsd-$COMMIT"

# Map the portable patch's paths onto the native source tree.
git -C "$source_root" apply --numstat -p3 --directory=src/usr.sbin/bgpd "$PENDING_PATCH" |
    awk '
        $3 ~ /^src\/usr[.]sbin\/bgpd\/(rde\.h|rde\.c|rde_peer\.c)$/ && !seen[$3]++ { count++; next }
        { exit 1 }
        END { if (count != 3) exit 1 }
    ' || die 'Pending Prefix patch must target exactly rde.h, rde_peer.c, and rde.c'
git -C "$source_root" apply --check --whitespace=error-all -p3 --directory=src/usr.sbin/bgpd "$PENDING_PATCH"
git -C "$source_root" apply --whitespace=error-all -p3 --directory=src/usr.sbin/bgpd "$PENDING_PATCH"
if [[ -n "$startup_patch" ]]; then
    git -C "$source_root" apply --check --whitespace=error-all -p0 "$PROFILE_DIR/$startup_patch"
    git -C "$source_root" apply --whitespace=error-all -p0 "$PROFILE_DIR/$startup_patch"
fi
imsg_metadata='system libutil'
if [[ -n "$IMSG_PATCH" ]]; then
    # Compile the upstream imsg implementation privately when the profile
    # needs a different ABI from the base system.
    git -C "$source_root" apply --check --whitespace=error-all -p0 "$PROFILE_DIR/$IMSG_PATCH"
    git -C "$source_root" apply --whitespace=error-all -p0 "$PROFILE_DIR/$IMSG_PATCH"
    cp "$PROFILE_DIR/$IMSG_MAKEFILE" "$source_root/src/usr.sbin/bgpd/lab-imsg.mk"
    cp "$PROFILE_DIR/$IMSG_MAKEFILE" "$source_root/src/usr.sbin/bgpctl/lab-imsg.mk"
    imsg_metadata="private upstream $VERSION imsg.c/imsg-buffer.c/imsg.h; system libutil unchanged"
fi

jobs=$(sysctl -n hw.ncpu)
(cd "$source_root/src/usr.sbin/bgpd"; make -j"$jobs" CPPFLAGS="${cppflags[*]}")
(cd "$source_root/src/usr.sbin/bgpctl"; make -j"$jobs")
for binary in bgpd bgpctl; do
    [[ "$("$source_root/src/usr.sbin/$binary/$binary" -V 2>&1)" == "OpenBGPD $VERSION" ]] ||
        die "built $binary version differs from OpenBGPD $VERSION"
done

mkdir -m 700 -- "$PREFIX" || die "could not reserve install prefix: $PREFIX"
prefix_created=1
mkdir "$PREFIX/sbin"
for binary in bgpd bgpctl; do
    install -m 755 "$source_root/src/usr.sbin/$binary/$binary" "$PREFIX/sbin/$binary"
done
{
    printf 'OpenBGPD_Version=%s\nNative_Commit=%s\nNative_Archive_SHA256=%s\n' "$VERSION" "$COMMIT" "$ARCHIVE_SHA256"
    printf 'Native_Archive_URL=%s\nOS=%s\nStartup_Compatibility=%s\n' "$archive_url" "$OS_VERSION" "$compat"
    printf 'IMSG=%s\nAllocator=OpenBSD libc\n' "$imsg_metadata"
    printf 'Pending_Prefix_Limit=%s\nPending_Patch_SHA256=%s\n' "$LIMIT" "$(sha256 -q "$PENDING_PATCH")"
    if [[ -n "$startup_patch" ]]; then
        printf 'Compatibility_Patch_SHA256=%s\n' "$(sha256 -q "$PROFILE_DIR/$startup_patch")"
    fi
    for binary in bgpd bgpctl; do
        printf '%s_SHA256=%s\n' "$binary" "$(sha256 -q "$PREFIX/sbin/$binary")"
    done
} > "$PREFIX/BUILD-METADATA.txt"
chmod 755 "$PREFIX"
prefix_created=0
printf 'Installed native OpenBGPD %s: %s\n' "$VERSION" "$PREFIX"
