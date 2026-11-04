#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
base_url=https://cdn.openbsd.org/pub/OpenBSD/OpenBGPD
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage()
{
    printf 'Usage: %s VERSION [--check | --lab] [--prefix DIR] [--no-pending-cap]\n' "$0"
    printf '       [--limit N] [--jobs N] [--archive FILE --signature FILE]\n'
}
case "${1:-}" in ''|-h|--help) usage; exit 0 ;; esac
version=$1
shift
[[ "$version" =~ ^[0-9]+([.][0-9]+)+(p[0-9]+)?$ ]] || die 'specify a portable release version, for example 9.3'
mode=build
prefix=''
limit=20000000
jobs=''
archive_input=''
signature=''
pending=1
while (( $# )); do
    case "$1" in
        --check|--lab)
            [[ "$mode" == build ]] || die 'choose only one of --check and --lab'
            mode=${1#--}
            shift ;;
        --no-pending-cap) pending=0; shift ;;
        --prefix|--limit|--jobs|--archive|--signature)
            (( $# >= 2 )) && [[ -n "$2" && "$2" != --* ]] || die "missing value for $1"
            case "$1" in
                --prefix) prefix=$2 ;;
                --limit) limit=$2 ;;
                --jobs) jobs=$2 ;;
                --archive) archive_input=$2 ;;
                --signature) signature=$2 ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done
[[ $(uname -s) == Linux ]] && grep -Eq '^ID=(ubuntu|"ubuntu")$' /etc/os-release ||
    die 'run this on Ubuntu'
[[ "$limit" =~ ^[0-9]{1,10}$ ]] || die 'limit must be an integer from 1 to 2147483647'
limit=$((10#$limit))
(( limit >= 1 && limit <= 2147483647 )) || die 'limit must be an integer from 1 to 2147483647'
variant=stock
if (( pending )); then variant=pending; fi
prefix=${prefix:-"$HOME/opt/openbgpd-$version-$variant-jemalloc"}
[[ "$prefix" =~ ^/[a-zA-Z0-9_./+-]+$ ]] || die 'use a simple absolute prefix path'
prefix=$(realpath -m -- "$prefix")
case "$prefix" in
    /|/bin|/bin/*|/sbin|/sbin/*|/etc|/etc/*|/usr|/usr/*|/var|/var/*|/run|/run/*|/lib*|/home|"$HOME")
        die 'choose a dedicated prefix under $HOME/opt' ;;
esac
if [[ -n "$archive_input" || -n "$signature" ]]; then
    [[ -f "$archive_input" && -f "$signature" ]] || die 'provide both --archive FILE and --signature FILE'
fi
work=$(mktemp -d /tmp/openbgpd-build.XXXXXX)
stage=''
cleanup()
{
    rm -rf -- "$work"
    if [[ -n "$stage" ]]; then rm -rf -- "$stage"; fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

if [[ "$mode" == lab ]]; then
    launcher="$HOME/openbgpd-rs-lab/openbgpd-test.sh"
    base_config=${RS_TEST_CONFIG:-"$HOME/openbgpd-rs-lab/rs-test.env"}
    [[ -x "$launcher" && -x "$prefix/sbin/bgpd" && -x "$prefix/sbin/bgpctl" ]] ||
        die "existing lab launcher and built binaries are required: $prefix"
    grep -Fxq "OpenBGPD_Version=$version" "$prefix/BUILD-METADATA.txt" &&
        grep -Fxq 'Allocator_Linkage=jemalloc' "$prefix/BUILD-METADATA.txt" ||
        die 'build metadata does not match the requested version and allocator'
    {
        if [[ -r "$base_config" ]]; then printf 'source %q\n' "$base_config"; fi
        printf 'PORTABLE93_BGPD_BIN=%q\n' "$prefix/sbin/bgpd"
        printf 'PORTABLE93_BGPCTL_BIN=%q\n' "$prefix/sbin/bgpctl"
        printf 'PORTABLE93_OPENBGPD_VERSION=%q\nRS_ALLOCATOR=jemalloc\n' "$version"
    } > "$work/rs-test.env"
    RS_TEST_CONFIG="$work/rs-test.env" "$launcher"
    exit 0
fi

if [[ "$mode" == build ]]; then
    (( EUID != 0 )) || die 'build as an unprivileged user'
    [[ ! -e "$prefix" && ! -L "$prefix" ]] || die "existing prefix preserved: $prefix"
    for cmd in cc make pkg-config readelf timeout strings; do
        command -v "$cmd" >/dev/null || die "missing build dependency: $cmd"
    done
    getent passwd _openbgpd >/dev/null || die 'missing _openbgpd privilege-separation account'
    jobs=${jobs:-$(nproc)}
    [[ "$jobs" =~ ^[1-9][0-9]{0,2}$ ]] || die 'jobs must be a positive integer'
    case "${CPPFLAGS:-} ${CFLAGS:-}" in
        *RDE_PENDING_LIMIT*) die 'use --limit instead of defining RDE_PENDING_LIMIT in compiler flags' ;;
    esac
fi
signify=$(command -v signify-openbsd || command -v signify) || die 'install signify-openbsd'
archive="openbgpd-$version.tar.gz"
if [[ -n "$archive_input" ]]; then
    case "$(basename -- "$archive_input")" in
        "openbgpd-$version.tgz") archive="openbgpd-$version.tgz" ;;
    esac
    cp -- "$archive_input" "$work/$archive"
    cp -- "$signature" "$work/SHA256.sig"
else
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 120 \
        --output "$work/$archive" "$base_url/$archive"
    curl --fail --silent --show-error --location --retry 2 --connect-timeout 10 --max-time 60 \
        --output "$work/SHA256.sig" "$base_url/SHA256.sig"
fi
cd "$work"
printf '%s\n' 'untrusted comment: OpenBGPD release key' \
    'RWTGJEPobKfXIP1+foh6O3ZGQIDIxwB0Hp4rH6fMYGdYPQMFH2IEqxcY' > openbgpd.pub
"$signify" -C -p openbgpd.pub -x SHA256.sig "$archive" ||
    die "signature or checksum verification failed for $archive"
src="$work/openbgpd-$version"
tar -tzf "$archive" | awk -v root="openbgpd-$version" '
    $0 != root && index($0, root "/") != 1 { bad=1 }
    $0 ~ /(^|\/)[.][.]($|\/)/ { bad=1 }
    END { exit (bad || NR == 0) }
' || die 'unexpected archive paths'
tar -xzf "$archive"
[[ -f "$src/VERSION" && ! -L "$src/VERSION" && -x "$src/configure" ]] ||
    die 'release lacks a regular VERSION or configure'
[[ $(tr -d '\r\n' < "$src/VERSION") == "$version" ]] || die 'archive version differs from requested version'

patch=''
legacy_dump=0
if (( pending )); then
    patch="$repo/pending-backpressure-$version.patch"
    if [[ ! -e "$patch" && ! -L "$patch" ]]; then patch="$repo/pending-backpressure.patch"; fi
    [[ -f "$patch" && ! -L "$patch" ]] || die "missing or unsafe patch: $patch"
    git -C "$src" apply --numstat "$patch" | awk '
        $3 ~ /^src\/bgpd\/(rde[.]h|rde[.]c|rde_peer[.]c)$/ && !seen[$3]++ { count++; next }
        { bad=1 }
        END { exit (bad || count != 3) }
    ' || die 'Pending Prefix patch must target exactly the three RDE files'
    git -C "$src" apply --check --whitespace=error-all "$patch" ||
        die "OpenBGPD $version needs a reviewed pending-backpressure-$version.patch"
    # Older releases finish the two special exports through peer_blast_done.
    legacy_dump=$(awk '
        /^peer_dump\(struct rde_peer \*peer, uint8_t aid\)/ { dump=1 }
        dump && /^}/ { exit }
        dump && /^[[:space:]]*peer_blast\(peer, aid\);/ { count++ }
        END { if (!dump) exit 1; print count+0 }
    ' "$src/src/bgpd/rde_peer.c") || die "cannot identify peer_dump in OpenBGPD $version"
    [[ "$legacy_dump" == 0 || "$legacy_dump" == 2 ]] ||
        die "OpenBGPD $version uses an unrecognized peer_dump completion path"
    git -C "$src" apply --whitespace=error-all "$patch"
fi

# Keep the link change local to the daemon, and independent of the RDE diff.
makefile="$src/src/bgpd/Makefile.in"
ldadd_pattern='^bgpd_LDADD[[:blank:]]*=[[:blank:]]*'
[[ -f "$makefile" && $(grep -c "$ldadd_pattern" "$makefile") == 1 ]] ||
    die "OpenBGPD $version uses a different bgpd link rule"
sed -i "s/$ldadd_pattern/bgpd_LDADD = -ljemalloc /" "$makefile"
if [[ "$mode" == check ]]; then
    printf 'CHECK_OK OpenBGPD=%s patch=%s; build and runtime are separate checks.\n' "$version" "${patch##*/}"
    exit 0
fi

build_cppflags=${CPPFLAGS:-}
if (( pending )); then build_cppflags="$build_cppflags -DRDE_PENDING_LIMIT=${limit}LL"; fi
if (( legacy_dump )); then build_cppflags="$build_cppflags -DOPENBGPD_PENDING_LEGACY_DUMP"; fi
mkdir build
cd build
env CFLAGS="${CFLAGS:--O2 -g}" CPPFLAGS="$build_cppflags" "$src/configure" \
    --prefix="$prefix" --sysconfdir=/etc --localstatedir=/var \
    --runstatedir=/run/openbgpd --with-wwwrunstatedir=/run \
    --with-www-user=www-data --with-privsep-user=_openbgpd
make -j"$jobs"
make check
if (( pending )); then
    # Compile the patched production RDE file with the project's real flags.
    policy_defs=()
    if grep -Eq '^void[[:space:]]+up_generate_updates\(struct rde_peer \*, struct rib_entry \*\);' "$src/src/bgpd/rde.h"; then
        policy_defs+=(-DOPENBGPD_POLICY_LEGACY_UPDATES)
    fi
    if ! grep -q 'rde_rib_entry_count;' "$src/src/bgpd/bgpd.h"; then
        policy_defs+=(-DOPENBGPD_POLICY_NO_RIB_COUNTERS)
    fi
    make -s --no-print-directory -C src/bgpd \
        --eval='.PHONY: __pending_policy_unit' \
        --eval='__pending_policy_unit: ; $(CC) $(DEFS) $(DEFAULT_INCLUDES) $(CPPFLAGS) $(AM_CPPFLAGS) $(AM_CFLAGS) $(CFLAGS) $(POLICY_DEFS) -O0 -g -ffunction-sections -fdata-sections -URDE_PENDING_LIMIT -DRDE_PENDING_LIMIT=100 -DRDE_PEER_SOURCE=\"$(POLICY_SOURCE)/src/bgpd/rde_peer.c\" -I"$(POLICY_SOURCE)/include" -I"$(POLICY_SOURCE)/src/bgpd" "$(POLICY_TEST)" -Wl,--gc-sections -o "$(POLICY_BIN)"' \
        POLICY_SOURCE="$src" POLICY_TEST="$repo/policy-test.c" \
        POLICY_DEFS="${policy_defs[*]}" POLICY_BIN="$work/policy-test" __pending_policy_unit
    "$work/policy-test"
fi
make DESTDIR="$work/install" install
tree="$work/install$prefix"
for binary in bgpd bgpctl; do
    timeout 10s env -u LD_PRELOAD -u LD_AUDIT "$tree/sbin/$binary" -V 2>&1 |
        awk -v expected="$version" '
            { for (i=1; i<NF; i++) if ($i=="OpenBGPD" && ("v" $(i+1))==("v" expected)) found=1 }
            END { exit !found }
        ' || die "built version mismatch: $binary"
done
bgpd="$tree/sbin/bgpd"
strings "$bgpd" | grep -Fx '_openbgpd' >/dev/null || die 'privilege separation user mismatch'
strings "$bgpd" | grep -Fx '/run/openbgpd/bgpd.sock' >/dev/null || die 'control socket directory mismatch'
readelf -d "$bgpd" | awk '
    /NEEDED.*\[libjemalloc[.]so/ && !jemalloc { jemalloc=NR }
    /NEEDED.*\[libc[.]so/ && !libc { libc=NR }
    END { exit !(jemalloc && libc && jemalloc < libc) }
' || die 'bgpd must directly link jemalloc ahead of libc'
timeout 10s env -u LD_PRELOAD -u LD_AUDIT -u LD_DEBUG_OUTPUT \
    LD_BIND_NOW=1 LD_DEBUG=bindings "$bgpd" -V > "$work/bindings.log" 2>&1 ||
    die 'bgpd failed to start with linked jemalloc'
awk -v binary="$bgpd" '
    $2=="binding" && $3=="file" && $4==binary && $7 ~ /\/libjemalloc[.]so([.]|$)/ {
        if ($0 ~ /symbol .malloc./) malloc=1
        if ($0 ~ /symbol .free./) free=1
    }
    END { exit !(malloc && free) }
' "$work/bindings.log" || die 'bgpd malloc/free did not both resolve to jemalloc without LD_PRELOAD'

mkdir -p -- "$(dirname -- "$prefix")"
stage=$(mktemp -d "$(dirname -- "$prefix")/.openbgpd-install.XXXXXX")
cp -a "$tree/." "$stage/"
chmod 755 "$stage"
{
    printf 'OpenBGPD_Version=%s\n' "$version"
    printf 'Source_Archive_SHA256=%s\n' "$(sha256sum "$work/$archive" | awk '{print $1}')"
    printf 'Source_Verification=signify\nAllocator_Linkage=jemalloc\n'
    printf 'Allocator_Bindings=malloc_and_free_verified_without_preload\n'
    printf 'Pending_Patch=%s\n' "${patch##*/}"
    if (( pending )); then
        printf 'Patch_SHA256=%s\n' "$(sha256sum "$patch" | awk '{print $1}')"
        printf 'Pending_Prefix_Soft_Limit=%s\nProduction_Policy_Check=passed\n' "$limit"
    fi
    for binary in bgpd bgpctl; do
        printf '%s_SHA256=%s\n' "$binary" "$(sha256sum "$stage/sbin/$binary" | awk '{print $1}')"
        printf '%s_Build_ID=%s\n' "$binary" "$(readelf -n "$stage/sbin/$binary" | awk '/Build ID:/ {print $3}')"
    done
} > "$stage/BUILD-METADATA.txt"
mv -T -n -- "$stage" "$prefix"
[[ ! -d "$stage" ]] || die "existing prefix preserved: $prefix"
stage=''
printf 'BUILD_OK OpenBGPD=%s prefix=%s\n' "$version" "$prefix"
