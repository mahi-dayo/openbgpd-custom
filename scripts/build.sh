#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/patch-path.sh"
POLICY_RUNNER="$SCRIPT_DIR/../tests/run-policy.sh"
POLICY_TEST="$SCRIPT_DIR/../tests/production-policy.c"
SOURCE=''
PREFIX=''
LIMIT=20000000
JOBS=''
ALLOW_NEW_VERSION=0
REQUIRE_SIGNED_SOURCE=0
PENDING_CAP=1
ALLOCATOR=jemalloc

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage()
{
    printf 'Usage: %s --source SOURCE_DIR --prefix NEW_ABSOLUTE_PREFIX [--limit N] [--jobs N]\n' "$0"
    printf '       [--allocator jemalloc|system] [--no-pending-cap] [--allow-new-version] [--require-signed-source]\n'
    printf '\nUbuntu-only build; requires installed build dependencies and _openbgpd.\n'
    printf 'Default Pending Prefix soft-water limit: 20000000 entries.\n'
    printf 'The source is copied before patching; the supplied source stays unchanged.\n'
    printf 'The default allocator is jemalloc, linked into bgpd. No service or stock binary is changed.\n'
    printf 'An existing install prefix is always preserved.\n'
}
while (( $# )); do
    case "$1" in
        --source|--prefix|--limit|--jobs|--allocator)
            (( $# >= 2 )) || die "missing value: $1"
            case "$1" in
                --source) SOURCE=$2 ;;
                --prefix) PREFIX=$2 ;;
                --limit) LIMIT=$2 ;;
                --jobs) JOBS=$2 ;;
                --allocator) ALLOCATOR=$2 ;;
            esac
            shift 2 ;;
        --allow-new-version) ALLOW_NEW_VERSION=1; shift ;;
        --require-signed-source) REQUIRE_SIGNED_SOURCE=1; shift ;;
        --no-pending-cap) PENDING_CAP=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ -d "$SOURCE" && -n "$PREFIX" ]] || { usage >&2; exit 2; }
[[ $(uname -s) == Linux ]] || die 'build.sh requires Linux (Ubuntu lab settings)'
grep -Eq '^ID=(ubuntu|"ubuntu")$' /etc/os-release || die 'build.sh requires Ubuntu'
[[ "$PREFIX" == /* && "$PREFIX" != *[!a-zA-Z0-9_./+-]* ]] || die 'prefix must be a simple absolute path without whitespace or shell characters'
case "/${PREFIX#/}/" in
    */../*|*/./*) die 'prefix must not contain . or .. components' ;;
esac
PREFIX=${PREFIX%/}
case "$PREFIX" in
    ''|/|/usr|/usr/*|/bin|/sbin|/etc|/etc/*|/var|/var/*|/run|/run/*|/lib|/lib/*|/lib64|/lib64/*|/home|"$HOME")
        die 'choose a dedicated new prefix such as $HOME/opt/openbgpd-9.3-pending-cap-20m' ;;
esac
[[ ! -e "$PREFIX" && ! -L "$PREFIX" ]] || die "prefix already exists and was preserved: $PREFIX"
[[ "$LIMIT" =~ ^[0-9]{1,10}$ ]] || die 'limit must be a positive integer <= 2147483647'
LIMIT=$((10#$LIMIT))
(( LIMIT >= 1 && LIMIT <= 2147483647 )) || die 'limit must be between 1 and 2147483647'
case "$ALLOCATOR" in jemalloc|system) ;; *) die 'allocator must be jemalloc or system' ;; esac
if (( PENDING_CAP )); then
    [[ -f "$POLICY_RUNNER" && -x "$POLICY_RUNNER" && ! -L "$POLICY_RUNNER" ]] ||
        die 'production policy harness is missing, not executable, or a symlink: tests/run-policy.sh'
    [[ -f "$POLICY_TEST" && ! -L "$POLICY_TEST" ]] ||
        die 'production policy test is missing or a symlink: tests/production-policy.c'
fi
for command in cc make git pkg-config readelf awk sha256sum strings diff tar cp nproc timeout getent; do
    command -v "$command" >/dev/null 2>&1 || die "missing build dependency: $command (install dependencies separately)"
done
JOBS=${JOBS:-$(nproc)}
[[ "$JOBS" =~ ^[0-9]{1,3}$ ]] || die 'jobs must be an integer from 1 to 64'
JOBS=$((10#$JOBS))
(( JOBS >= 1 && JOBS <= 64 )) || die 'jobs must be an integer from 1 to 64'
getent passwd _openbgpd >/dev/null || die 'the existing Ubuntu _openbgpd account is required'
[[ -x "$SOURCE/configure" && -f "$SOURCE/VERSION" && ! -L "$SOURCE/VERSION" ]] || die 'source requires configure and a regular VERSION file'
[[ ! -e "$SOURCE/config.status" ]] || die 'supply a fresh unconfigured source tree, not an existing build tree'
SOURCE=$(cd -- "$SOURCE" && pwd -P)
VERSION=$(tr -d '\r\n' < "$SOURCE/VERSION")
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] || die 'unrecognized source VERSION'
[[ "$VERSION" == 9.3 || "$ALLOW_NEW_VERSION" == 1 ]] || die 'non-9.3 source requires explicit --allow-new-version after review'
case " ${CPPFLAGS:-} ${CFLAGS:-} " in
    *RDE_PENDING_LIMIT*) die 'pass the limit with --limit, not a conflicting compiler flag' ;;
esac

WORK=$(mktemp -d /tmp/openbgpd-pending-build.XXXXXX)
PREFIX_STAGE=''
cleanup()
{
    rm -rf -- "$WORK"
    if [[ -n "$PREFIX_STAGE" && -d "$PREFIX_STAGE" ]]; then rm -rf -- "$PREFIX_STAGE"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
mkdir -p "$WORK/src" "$WORK/build"
cp -a "$SOURCE/." "$WORK/src/"

ARCHIVE_SHA=''
ARCHIVE_CHECK=local_source_not_signature_verified
if (( REQUIRE_SIGNED_SOURCE )); then
    archive="openbgpd-$VERSION.tar.gz"
    directory=$(dirname -- "$SOURCE")
    signify=$(command -v signify-openbsd || command -v signify) || die 'signify is required'
    mkdir "$WORK/verified-archive"
    for file in "$archive" SHA256.sig; do
        [[ -f "$directory/$file" && ! -L "$directory/$file" ]] || die "missing signed release input: $file"
        cp -- "$directory/$file" "$WORK/verified-archive/"
    done
    (
        cd "$WORK/verified-archive" &&
        "$signify" -C -p "$SCRIPT_DIR/../upstream/openbgpd.pub" -x SHA256.sig "$archive" &&
        tar -xzf "$archive" &&
        diff -qr --no-dereference "$WORK/src" "openbgpd-$VERSION" >/dev/null
    ) || die 'source does not exactly match a signed release archive'
    ARCHIVE_SHA=$(sha256sum "$WORK/verified-archive/$archive" | awk '{print $1}')
    ARCHIVE_CHECK=signify_verified_archive_and_full_directory_match
fi

SOURCE_CORE=$(cd "$SOURCE" && sha256sum VERSION src/bgpd/rde.h src/bgpd/rde_peer.c src/bgpd/rde.c)
PATCH_SHA=''
PATCH_NAME=''
JEMALLOC_PATCH_SHA=''
JEMALLOC_PATCH_NAME=''
POLICY_CHECK=skipped_no_local_pending_patch
BUILD_CPPFLAGS=${CPPFLAGS:-}
if (( PENDING_CAP )); then
    PATCH_FILE=$(select_patch "$VERSION" pending-backpressure.patch openbgpd-9.3-pending-backpressure.patch) ||
        die "missing or unsafe Pending Prefix patch for $VERSION"
    apply_args=()
    (( ALLOW_NEW_VERSION == 0 )) || apply_args+=(--allow-new-version)
    "$SCRIPT_DIR/apply-patch.sh" "${apply_args[@]}" "$WORK/src"
    PATCH_SHA=$(sha256sum "$PATCH_FILE" | awk '{print $1}')
    PATCH_NAME=${PATCH_FILE#"$PATCH_ROOT/"}
    BUILD_CPPFLAGS="$BUILD_CPPFLAGS -DRDE_PENDING_LIMIT=${LIMIT}LL"
fi
if [[ "$ALLOCATOR" == jemalloc ]]; then
    JEMALLOC_PATCH=$(select_patch "$VERSION" ubuntu-jemalloc-link.patch ubuntu-jemalloc-link.patch) ||
        die "missing or unsafe jemalloc link patch for $VERSION"
    git -C "$WORK/src" apply --check --whitespace=error-all "$JEMALLOC_PATCH" ||
        die 'jemalloc build context changed; review and register a version-specific patch'
    git -C "$WORK/src" apply --whitespace=error-all "$JEMALLOC_PATCH"
    JEMALLOC_PATCH_SHA=$(sha256sum "$JEMALLOC_PATCH" | awk '{print $1}')
    JEMALLOC_PATCH_NAME=${JEMALLOC_PATCH#"$PATCH_ROOT/"}
fi
BUILD_CFLAGS=${CFLAGS:--O2 -g}
cd "$WORK/build"
env CFLAGS="$BUILD_CFLAGS" CPPFLAGS="$BUILD_CPPFLAGS" "$WORK/src/configure" \
    --prefix="$PREFIX" \
    --sysconfdir=/etc \
    --localstatedir=/var \
    --runstatedir=/run/openbgpd \
    --with-wwwrunstatedir=/run \
    --with-www-user=www-data \
    --with-privsep-user=_openbgpd
make -j"$JOBS"
make check
if (( PENDING_CAP )); then
    "$POLICY_RUNNER" "$WORK/src" "$WORK/build"
    POLICY_CHECK=passed
fi
make DESTDIR="$WORK/install" install
INSTALL_TREE="$WORK/install$PREFIX"
version_matches()
{
    timeout 10s env -u LD_PRELOAD -u LD_AUDIT "$1" -V 2>&1 | awk -v expected="$VERSION" '
        { for (i=1; i<NF; i++) if ($i=="OpenBGPD" && ("v" $(i+1))==("v" expected)) found=1 }
        END { exit !found }
    '
}
for binary in bgpd bgpctl; do
    [[ -f "$INSTALL_TREE/sbin/$binary" && -x "$INSTALL_TREE/sbin/$binary" ]] || die "built binary missing: $binary"
    version_matches "$INSTALL_TREE/sbin/$binary" || die "built version mismatch: $binary"
done
bgpd="$INSTALL_TREE/sbin/bgpd"
if [[ "$ALLOCATOR" == jemalloc ]]; then
    readelf -d "$bgpd" | awk '
        /NEEDED.*\[libjemalloc[.]so/ && !jemalloc { jemalloc=NR }
        /NEEDED.*\[libc[.]so/ && !libc { libc=NR }
        END { exit !(jemalloc && libc && jemalloc < libc) }
    ' || die 'bgpd must directly link jemalloc ahead of libc'
    timeout 10s env -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG_OUTPUT \
        LD_BIND_NOW=1 LD_DEBUG=bindings "$bgpd" -V > "$WORK/allocator-bindings.log" 2>&1 ||
        die 'bgpd did not start with linked jemalloc'
    awk -v binary="$bgpd" '
        $2=="binding" && $3=="file" && $4==binary && $7 ~ /\/libjemalloc[.]so([.]|$)/ {
            if ($0 ~ /symbol .malloc./) malloc=1
            if ($0 ~ /symbol .free./) free=1
        }
        END { exit !(malloc && free) }
    ' "$WORK/allocator-bindings.log" || die 'bgpd malloc/free did not both resolve to jemalloc without LD_PRELOAD'
fi
strings "$INSTALL_TREE/sbin/bgpd" | grep -Fx '_openbgpd' >/dev/null || die 'privilege separation user mismatch'
strings "$INSTALL_TREE/sbin/bgpd" | grep -Fx '/run/openbgpd/bgpd.sock' >/dev/null || die 'control socket directory mismatch'
mkdir -p -- "$(dirname -- "$PREFIX")"
PREFIX_STAGE=$(mktemp -d "$(dirname -- "$PREFIX")/.openbgpd-pending-cap.XXXXXX")
cp -a "$INSTALL_TREE/." "$PREFIX_STAGE/"
chmod 755 "$PREFIX_STAGE"
{
    printf 'OpenBGPD_Version=%s\n' "$VERSION"
    printf 'Source_Directory=%s\nSource_Archive_SHA256=%s\nSource_Verification=%s\n' "$SOURCE" "$ARCHIVE_SHA" "$ARCHIVE_CHECK"
    printf 'Pending_Patch=%s\nPatch_SHA256=%s\n' "$PATCH_NAME" "$PATCH_SHA"
    if (( PENDING_CAP )); then printf 'Pending_Prefix_Soft_Limit=%s\n' "$LIMIT"; fi
    printf 'CPPFLAGS=%s\nCFLAGS=%s\n' "$BUILD_CPPFLAGS" "$BUILD_CFLAGS"
    printf 'Allocator_Linkage=%s\nAllocator_Patch=%s\nAllocator_Patch_SHA256=%s\n' \
        "$ALLOCATOR" "$JEMALLOC_PATCH_NAME" "$JEMALLOC_PATCH_SHA"
    if [[ "$ALLOCATOR" == jemalloc ]]; then printf 'Allocator_Bindings=malloc_and_free_verified_without_preload\n'; fi
    printf 'Upstream_Make_Check=passed\nProduction_Policy_Check=%s\nBuild_UTC=%s\n' \
        "$POLICY_CHECK" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    printf 'Source_Core_SHA256_begin\n%s\nSource_Core_SHA256_end\n' "$SOURCE_CORE"
    for binary in bgpd bgpctl; do
        printf '%s_SHA256=%s\n' "$binary" "$(sha256sum "$PREFIX_STAGE/sbin/$binary" | awk '{print $1}')"
        printf '%s_Build_ID=%s\n' "$binary" "$(readelf -n "$PREFIX_STAGE/sbin/$binary" | awk '/Build ID:/ {print $3}')"
    done
} > "$PREFIX_STAGE/BUILD-METADATA.txt"
mv -T -n -- "$PREFIX_STAGE" "$PREFIX"
[[ ! -d "$PREFIX_STAGE" ]] || die "prefix appeared during build; existing destination preserved: $PREFIX"
PREFIX_STAGE=''
printf 'BUILD_OK OpenBGPD=%s allocator=%s local_pending_patch=%s prefix=%s\n' "$VERSION" "$ALLOCATOR" "$PENDING_CAP" "$PREFIX"
