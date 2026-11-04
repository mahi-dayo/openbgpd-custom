#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
KEY_FILE="$SCRIPT_DIR/../upstream/openbgpd.pub"
PINNED_KEY=RWTGJEPobKfXIP1+foh6O3ZGQIDIxwB0Hp4rH6fMYGdYPQMFH2IEqxcY
BASE_URL=https://cdn.openbsd.org/pub/OpenBSD/OpenBGPD

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage()
{
    printf 'Usage: %s VERSION NEW_DIRECTORY\n' "$0"
    printf '\nFetch an explicitly named portable release into a new Ubuntu work directory.\n'
    printf 'Verifies SHA256.sig with the bundled pinned release key before extraction.\n'
    printf 'Archives, signature, key, and release metadata remain beside the pristine source.\n'
    printf 'No existing directory is overwritten; no key, package, or service is changed.\n'
    printf 'Requires curl, tar, sha256sum, and signify-openbsd (or signify), installed separately.\n'
}
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then usage; exit 0; fi
(( $# == 2 )) || { usage >&2; exit 2; }
VERSION=$1
DESTINATION=$2
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] || die 'VERSION must be an explicit numeric release such as 9.3'
[[ $(uname -s) == Linux ]] || die 'fetch-release.sh requires Linux; run it on the Ubuntu build VM'
[[ -n "$DESTINATION" && ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || die 'destination exists or is invalid; it was preserved'
case "$(basename -- "$DESTINATION")" in ''|.|..) die 'choose a dedicated new directory' ;; esac
[[ -f "$KEY_FILE" && ! -L "$KEY_FILE" ]] || die 'bundled release key is missing or is a symlink'
KEY=$(awk 'NR == 2 { key=$0 } END { if (NR != 2) exit 1; print key }' "$KEY_FILE") || die 'bundled release key has an unexpected format'
[[ "$KEY" == "$PINNED_KEY" ]] || die 'bundled release key differs from the reviewed key; do not download a replacement key automatically'
for command in curl tar sha256sum awk tr cp mkdir mktemp mv; do
    command -v "$command" >/dev/null 2>&1 || die "missing dependency: $command"
done
if command -v signify-openbsd >/dev/null 2>&1; then
    SIGNIFY=signify-openbsd
elif command -v signify >/dev/null 2>&1; then
    SIGNIFY=signify
else
    die 'signify-openbsd or signify is required; install it separately before fetching'
fi

PARENT=$(dirname -- "$DESTINATION")
NAME=$(basename -- "$DESTINATION")
mkdir -p -- "$PARENT"
PARENT=$(cd -- "$PARENT" && pwd -P)
DESTINATION="$PARENT/$NAME"
[[ ! -e "$DESTINATION" && ! -L "$DESTINATION" ]] || die 'destination appeared before download; it was preserved'
STAGE=$(mktemp -d "$PARENT/.openbgpd-release-${VERSION}.XXXXXX")
cleanup() { if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
cp -p -- "$KEY_FILE" "$STAGE/openbgpd.pub"
ARCHIVE="openbgpd-${VERSION}.tar.gz"
curl -fsSL --retry 2 --connect-timeout 10 --max-time 180 --max-filesize 20971520 \
    --output "$STAGE/$ARCHIVE" "$BASE_URL/$ARCHIVE"
curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 --max-filesize 1048576 \
    --output "$STAGE/SHA256.sig" "$BASE_URL/SHA256.sig"
(cd -- "$STAGE" && "$SIGNIFY" -C -p openbgpd.pub -x SHA256.sig "$ARCHIVE") ||
    die 'release signature/checksum verification failed; no source was extracted or installed'

# The signature is authoritative; additionally refuse unexpected archive roots
# and traversal components before creating any source paths in the work area.
tar -tzf "$STAGE/$ARCHIVE" | awk -v root="openbgpd-$VERSION" '
    {
        count++
        if ($0 != root && index($0, root "/") != 1) bad=1
        n=split($0, component, "/")
        for (i=1; i<=n; i++) if (component[i] == "..") bad=1
    }
    END { exit (bad || count == 0) }
' || die 'archive paths do not match the requested release directory'
tar -xzf "$STAGE/$ARCHIVE" -C "$STAGE"
SOURCE="$STAGE/openbgpd-$VERSION"
[[ -d "$SOURCE" && ! -L "$SOURCE" && -f "$SOURCE/VERSION" && ! -L "$SOURCE/VERSION" ]] ||
    die 'archive does not contain a regular release VERSION file'
ACTUAL_VERSION=$(tr -d '\r' < "$SOURCE/VERSION")
[[ "$ACTUAL_VERSION" == "$VERSION" ]] || die "archive VERSION mismatch: expected $VERSION, got $ACTUAL_VERSION"
ARCHIVE_SHA=$(sha256sum "$STAGE/$ARCHIVE" | awk '{print $1}')
{
    printf 'OpenBGPD_Version=%s\nSource_URL=%s/%s\n' "$VERSION" "$BASE_URL" "$ARCHIVE"
    printf 'Source_Archive_SHA256=%s\nSource_Verification=signify_release_key_and_SHA256.sig\n' "$ARCHIVE_SHA"
    printf 'Release_Public_Key=%s\nDownloaded_UTC=%s\n' "$PINNED_KEY" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
} > "$STAGE/RELEASE-METADATA.txt"
chmod 755 "$STAGE"
# GNU mv -T -n refuses nesting/overwriting if another directory appears.
mv -T -n -- "$STAGE" "$DESTINATION"
[[ ! -d "$STAGE" ]] || die 'destination appeared during download; existing destination was preserved'
STAGE=''
printf 'FETCH_OK OpenBGPD=%s source=%s/openbgpd-%s\n' "$VERSION" "$DESTINATION" "$VERSION"
printf 'Archive, SHA256.sig, pinned key, and metadata preserved in %s\n' "$DESTINATION"
printf 'Next: apply-patch.sh --check --allow-new-version "%s/openbgpd-%s"\n' "$DESTINATION" "$VERSION"
printf 'A matching patch context is not a substitute for source review and regression/load tests.\n'
