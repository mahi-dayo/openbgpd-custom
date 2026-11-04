#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    printf 'Usage: %s PATCHED_SOURCE_TREE [CONFIGURED_BUILD_TREE]\n' "$0"
    printf 'Linux/GNU make/CC: compile the actual rde_peer.c with a test limit of 100.\n'
    printf 'The source/build tree may be identical for an in-tree configure.\n'
    exit 0
fi
(( $# == 1 || $# == 2 )) || { printf 'Expected a source tree and optional configured build tree.\n' >&2; exit 2; }
[[ $(uname -s) == Linux ]] || { printf 'Run the production-C policy harness on Linux.\n' >&2; exit 1; }
SOURCE=$(cd -- "$1" && pwd)
BUILD=$(cd -- "${2:-$1}" && pwd)
[[ -f "$SOURCE/src/bgpd/rde_peer.c" && -f "$SOURCE/src/bgpd/rde.h" ]]
[[ -f "$BUILD/src/bgpd/Makefile" ]] || {
    printf 'Configure the supplied source/build tree before running this test.\n' >&2
    exit 1
}
TEST_TMP=$(mktemp -d /tmp/openbgpd-pending-policy.XXXXXX)
trap 'rm -rf -- "$TEST_TMP"' EXIT

# Reuse the configured production compiler, platform DEFS and include flags.
# No edited copy of the C algorithm or reduced replacement struct is used.
# Function/data sections permit unrelated production functions to be removed
# by GNU ld rather than supplying fake implementations for the whole daemon.
make -s --no-print-directory -C "$BUILD/src/bgpd" \
    --eval='.PHONY: __pending_policy_unit' \
    --eval='__pending_policy_unit: ; $(CC) $(DEFS) $(DEFAULT_INCLUDES) $(CPPFLAGS) $(AM_CPPFLAGS) $(AM_CFLAGS) $(CFLAGS) -O0 -g -ffunction-sections -fdata-sections -URDE_PENDING_LIMIT -DRDE_PENDING_LIMIT=100 -DRDE_PEER_SOURCE=\"$(POLICY_SOURCE)/src/bgpd/rde_peer.c\" -I"$(POLICY_SOURCE)/include" -I"$(POLICY_SOURCE)/src/bgpd" "$(POLICY_TEST)" -Wl,--gc-sections -o "$(POLICY_BIN)"' \
    POLICY_SOURCE="$SOURCE" POLICY_TEST="$TEST_DIR/production-policy.c" \
    POLICY_BIN="$TEST_TMP/production-policy" __pending_policy_unit
"$TEST_TMP/production-policy"
