#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/patch-path.sh"
SOURCE=''
CHECK_ONLY=0
ALLOW_NEW_VERSION=0

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage()
{
    printf 'Usage: %s [--check] [--allow-new-version] SOURCE_DIR\n' "$0"
    printf '\nApplies only the three-file Pending Prefix backpressure patch.\n'
    printf '  --check              validate context without changing source\n'
    printf '  --allow-new-version  explicitly permit a version other than 9.3\n'
    printf '\nNo fuzzy/forced application, installation, or service operation is used.\n'
    printf 'A successful context check does not prove compatibility with a new release.\n'
}
while (( $# )); do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        --allow-new-version) ALLOW_NEW_VERSION=1; shift ;;
        -h|--help) usage; exit 0 ;;
        -*) die "unknown option: $1" ;;
        *) [[ -z "$SOURCE" ]] || die 'exactly one source directory is required'; SOURCE=$1; shift ;;
    esac
done
[[ -n "$SOURCE" && -d "$SOURCE" ]] || { usage >&2; exit 2; }
SOURCE=$(cd -- "$SOURCE" && pwd -P)
[[ "$SOURCE" != / ]] || die 'source directory cannot be /'
command -v git >/dev/null 2>&1 || die 'git is required for strict patch checking'
[[ -z "$(git -C "$SOURCE" rev-parse --show-prefix 2>/dev/null || true)" ]] ||
    die 'place the source outside an enclosing Git working tree, or use its own repository root'
for path in VERSION src src/bgpd src/bgpd/rde.h src/bgpd/rde_peer.c src/bgpd/rde.c; do
    [[ ! -L "$SOURCE/$path" ]] || die "source path must not be a symlink: $path"
done
for path in VERSION src/bgpd/rde.h src/bgpd/rde_peer.c src/bgpd/rde.c; do
    [[ -f "$SOURCE/$path" ]] || die "required regular source file is missing: $path"
done
VERSION=$(tr -d '\r\n' < "$SOURCE/VERSION")
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] || die 'unrecognized source VERSION'
if [[ "$VERSION" != 9.3 && "$ALLOW_NEW_VERSION" != 1 ]]; then
    die "this patch was reviewed against 9.3, not $VERSION; inspect the source changes and use --allow-new-version only after review"
fi
PATCH_FILE=$(select_patch "$VERSION" pending-backpressure.patch openbgpd-9.3-pending-backpressure.patch) ||
    die "missing or unsafe Pending Prefix patch for $VERSION"

# Reject a changed bundle that unexpectedly targets other files. This is not
# a substitute for authenticating the upstream source archive separately.
git -C "$SOURCE" apply --numstat "$PATCH_FILE" |
    awk '
        $3 == "src/bgpd/rde.h" || $3 == "src/bgpd/rde_peer.c" || $3 == "src/bgpd/rde.c" {
            if (seen[$3]++) exit 1
            count++; next
        }
        { exit 1 }
        END { if (count != 3) exit 1 }
    ' || die 'patch must target exactly rde.h, rde_peer.c, and rde.c'

if git -C "$SOURCE" apply --reverse --check --whitespace=error-all "$PATCH_FILE" >/dev/null 2>&1; then
    printf 'ALREADY_APPLIED OpenBGPD=%s source=%s\n' "$VERSION" "$SOURCE"
    exit 0
fi
git -C "$SOURCE" apply --check --whitespace=error-all "$PATCH_FILE" ||
    die 'patch context does not match; source was not changed; do not use --reject, --3way, or fuzzy/forced application'
if (( CHECK_ONLY == 1 )); then
    printf 'CHECK_OK OpenBGPD=%s source=%s (no files changed)\n' "$VERSION" "$SOURCE"
else
    git -C "$SOURCE" apply --whitespace=error-all "$PATCH_FILE"
    printf 'APPLIED OpenBGPD=%s source=%s\n' "$VERSION" "$SOURCE"
fi
if [[ "$VERSION" != 9.3 ]]; then
    printf 'NOTICE: this version is not validated; rebuild and rerun correctness and load checks before use.\n' >&2
fi
