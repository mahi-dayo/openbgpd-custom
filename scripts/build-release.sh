#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage()
{
    printf 'Usage: %s VERSION --prefix NEW_ABSOLUTE_PREFIX [build options]\n' "$0"
    printf 'Fetches a signed OpenBGPD portable release and builds it for Ubuntu.\n'
    "$SCRIPT_DIR/build.sh" --help
}
case "${1:-}" in ''|-h|--help) usage; exit 0 ;; esac
VERSION=$1
shift
[[ "$VERSION" =~ ^[0-9]+([.][0-9]+)+$ ]] || { printf 'ERROR: expected a numeric release version\n' >&2; exit 2; }
[[ $# -gt 0 ]] || { usage >&2; exit 2; }
WORK=$(mktemp -d /tmp/openbgpd-signed-release.XXXXXX)
trap 'rm -rf -- "$WORK"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
"$SCRIPT_DIR/fetch-release.sh" "$VERSION" "$WORK/release"
"$SCRIPT_DIR/build.sh" "$@" --source "$WORK/release/openbgpd-$VERSION" --require-signed-source
