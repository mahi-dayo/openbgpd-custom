#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUNDLE=$(cd -- "$TEST_DIR/.." && pwd)
TEST_TMP=$(mktemp -d /tmp/pending-build-tools-test.XXXXXX)
trap 'rm -rf -- "$TEST_TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TEST_TMP/bundle/scripts" "$TEST_TMP/bundle/patches"
cp "$BUNDLE/scripts/apply-patch.sh" "$BUNDLE/scripts/patch-path.sh" "$TEST_TMP/bundle/scripts/"
cp "$BUNDLE/scripts/build.sh" "$TEST_TMP/bundle/scripts/"
APPLIER="$TEST_TMP/bundle/scripts/apply-patch.sh"
BUILDER="$TEST_TMP/bundle/scripts/build.sh"
PATCH="$TEST_TMP/bundle/patches/openbgpd-9.3-pending-backpressure.patch"
printf '%s\n' \
    '--- a/src/bgpd/rde.h' '+++ b/src/bgpd/rde.h' '@@ -1 +1 @@' '-original_header' '+patched_header' \
    '--- a/src/bgpd/rde_peer.c' '+++ b/src/bgpd/rde_peer.c' '@@ -1 +1 @@' '-original_peer' '+patched_peer' \
    '--- a/src/bgpd/rde.c' '+++ b/src/bgpd/rde.c' '@@ -1 +1 @@' '-original_rde' '+patched_rde' > "$PATCH"
fixture_source()
{
    mkdir -p "$1/src/bgpd"
    printf '9.3\n' > "$1/VERSION"
    printf 'original_header\n' > "$1/src/bgpd/rde.h"
    printf 'original_peer\n' > "$1/src/bgpd/rde_peer.c"
    printf 'original_rde\n' > "$1/src/bgpd/rde.c"
    printf '#!/bin/sh\nexit 99\n' > "$1/configure"
    chmod 755 "$1/configure"
}
digest()
{
    (cd "$1" && cksum VERSION src/bgpd/rde.h src/bgpd/rde_peer.c src/bgpd/rde.c)
}
fixture_source "$TEST_TMP/source"
before=$(digest "$TEST_TMP/source")
bash "$APPLIER" --check "$TEST_TMP/source" > "$TEST_TMP/check.log"
[[ $(digest "$TEST_TMP/source") == "$before" ]] || fail 'read-only check changed source'
grep -Fq CHECK_OK "$TEST_TMP/check.log" || fail 'successful check was not reported'
bash "$APPLIER" "$TEST_TMP/source" > "$TEST_TMP/apply.log"
grep -Fxq patched_header "$TEST_TMP/source/src/bgpd/rde.h" || fail 'patch not applied'
patched=$(digest "$TEST_TMP/source")
bash "$APPLIER" "$TEST_TMP/source" > "$TEST_TMP/again.log"
grep -Fq ALREADY_APPLIED "$TEST_TMP/again.log" || fail 'idempotent state not reported'
[[ $(digest "$TEST_TMP/source") == "$patched" ]] || fail 'reapply changed patched source'
printf 'PASS: read-only check, strict apply, and idempotent reapply\n'

fixture_source "$TEST_TMP/new-version"
printf '9.4\n' > "$TEST_TMP/new-version/VERSION"
if bash "$APPLIER" --check "$TEST_TMP/new-version" > "$TEST_TMP/new-version.log" 2>&1; then
    fail 'new version accepted without explicit review flag'
fi
grep -Fq -- --allow-new-version "$TEST_TMP/new-version.log" || fail 'new version explanation missing'
bash "$APPLIER" --check --allow-new-version "$TEST_TMP/new-version" > "$TEST_TMP/allow.log" 2>&1
grep -Fq CHECK_OK "$TEST_TMP/allow.log" || fail 'reviewed future-version context rejected'
printf 'PASS: future versions require explicit opt-in and context check\n'
mkdir "$TEST_TMP/bundle/patches/9.4"
sed 's/^+patched_/+updated_/' "$PATCH" > "$TEST_TMP/bundle/patches/9.4/pending-backpressure.patch"
bash "$APPLIER" --allow-new-version "$TEST_TMP/new-version" >/dev/null
grep -Fxq updated_header "$TEST_TMP/new-version/src/bgpd/rde.h" ||
    fail 'version-specific patch did not take precedence'
printf 'PASS: a reviewed version-specific patch overrides the common patch\n'

git init -q "$TEST_TMP/parent-repo"
fixture_source "$TEST_TMP/parent-repo/nested-source"
if bash "$APPLIER" --check "$TEST_TMP/parent-repo/nested-source" > "$TEST_TMP/nested.log" 2>&1; then
    fail 'nested source could silently skip patch hunks'
fi
grep -Fq 'outside an enclosing Git working tree' "$TEST_TMP/nested.log" ||
    fail 'nested source was not rejected explicitly'
printf 'PASS: source in an enclosing Git working tree is rejected\n'

fixture_source "$TEST_TMP/symlink"
printf 'external\n' > "$TEST_TMP/external"
rm "$TEST_TMP/symlink/src/bgpd/rde_peer.c"
ln -s "$TEST_TMP/external" "$TEST_TMP/symlink/src/bgpd/rde_peer.c"
if bash "$APPLIER" "$TEST_TMP/symlink" > "$TEST_TMP/symlink.log" 2>&1; then fail 'symlink accepted'; fi
[[ $(< "$TEST_TMP/external") == external ]] || fail 'external symlink target changed'
printf 'PASS: symlink targets are refused\n'

fixture_source "$TEST_TMP/mismatch"
printf 'unexpected_peer\n' > "$TEST_TMP/mismatch/src/bgpd/rde_peer.c"
before=$(digest "$TEST_TMP/mismatch")
if bash "$APPLIER" "$TEST_TMP/mismatch" > "$TEST_TMP/mismatch.log" 2>&1; then fail 'mismatching context accepted'; fi
[[ $(digest "$TEST_TMP/mismatch") == "$before" ]] || fail 'failed context check partially changed source'
printf 'PASS: a context mismatch leaves all source files unchanged\n'

fixture_source "$TEST_TMP/foreign"
printf 'original_extra\n' > "$TEST_TMP/foreign/extra"
printf '%s\n' '--- a/extra' '+++ b/extra' '@@ -1 +1 @@' '-original_extra' '+patched_extra' >> "$PATCH"
if bash "$APPLIER" "$TEST_TMP/foreign" > "$TEST_TMP/foreign.log" 2>&1; then fail 'unexpected target accepted'; fi
grep -Fxq original_extra "$TEST_TMP/foreign/extra" || fail 'foreign target changed'
printf 'PASS: patch file whitelist excludes unrelated targets\n'

bash "$APPLIER" --help >/dev/null
bash "$BUILDER" --help >/dev/null
# Override only OS discovery so validation paths are testable on macOS.
# Every accepted build must fail before configure/compilation in this suite.
uname() { printf 'Linux\n'; }
grep()
{
    if [[ "${@: -1}" == /etc/os-release ]]; then return 0; fi
    command grep "$@"
}
export -f uname grep
mkdir "$TEST_TMP/existing-prefix"
if bash "$BUILDER" --source "$TEST_TMP/source" --prefix "$TEST_TMP/existing-prefix" > "$TEST_TMP/prefix.log" 2>&1; then fail 'existing prefix accepted'; fi
command grep -Fq 'prefix already exists' "$TEST_TMP/prefix.log" || fail 'existing prefix guard did not execute'
if bash "$BUILDER" --source "$TEST_TMP/source" --prefix /usr/sbin > "$TEST_TMP/system.log" 2>&1; then fail 'system prefix accepted'; fi
command grep -Fq 'dedicated new prefix' "$TEST_TMP/system.log" || fail 'system prefix guard did not execute'
if bash "$BUILDER" --source "$TEST_TMP/source" --prefix "$TEST_TMP/not-created" --limit 0 > "$TEST_TMP/limit.log" 2>&1; then fail 'zero limit accepted'; fi
command grep -Fq 'limit must be between' "$TEST_TMP/limit.log" || fail 'limit guard did not execute'
[[ ! -e "$TEST_TMP/not-created" ]] || fail 'validation failure created a prefix'
printf 'PASS: build help, immutable prefix, system path, and limit guards\n'
if bash "$BUILDER" --source "$TEST_TMP/source" --prefix "$TEST_TMP/missing-policy-prefix" > "$TEST_TMP/missing-policy.log" 2>&1; then
    fail 'missing production policy harness accepted'
fi
command grep -Fq 'production policy harness is missing' "$TEST_TMP/missing-policy.log" || fail 'missing harness guard did not execute'
[[ ! -e "$TEST_TMP/missing-policy-prefix" ]] || fail 'missing harness created an installation'
mkdir -p "$TEST_TMP/bundle/tests"
printf '#!/bin/sh\nexit 99\n' > "$TEST_TMP/bundle/tests/run-policy.sh"
chmod 755 "$TEST_TMP/bundle/tests/run-policy.sh"
if bash "$BUILDER" --source "$TEST_TMP/source" --prefix "$TEST_TMP/missing-policy-c-prefix" > "$TEST_TMP/missing-policy-c.log" 2>&1; then
    fail 'missing production policy C test accepted'
fi
command grep -Fq 'production policy test is missing' "$TEST_TMP/missing-policy-c.log" || fail 'missing C test guard did not execute'
[[ ! -e "$TEST_TMP/missing-policy-c-prefix" ]] || fail 'missing C test created an installation'
printf 'PASS: production policy harness is required before compilation or installation\n'

# Exercise the delivered patch itself when the separately acquired release is
# available. All mutation stays in the private fixture copy, not upstream/.
if [[ -f "$BUNDLE/patches/openbgpd-9.3-pending-backpressure.patch" &&
      -d "$BUNDLE/upstream/openbgpd-9.3" ]]; then
    original=$(digest "$BUNDLE/upstream/openbgpd-9.3")
    bash "$BUNDLE/scripts/apply-patch.sh" --check "$BUNDLE/upstream/openbgpd-9.3" >/dev/null
    mkdir "$TEST_TMP/actual-source"
    cp -a "$BUNDLE/upstream/openbgpd-9.3/." "$TEST_TMP/actual-source/"
    bash "$BUNDLE/scripts/apply-patch.sh" "$TEST_TMP/actual-source" >/dev/null
    actual_patched=$(digest "$TEST_TMP/actual-source")
    [[ "$actual_patched" != "$original" ]] || fail 'delivered patch did not change its fixture'
    bash "$BUNDLE/scripts/apply-patch.sh" "$TEST_TMP/actual-source" > "$TEST_TMP/actual-again.log"
    command grep -Fq ALREADY_APPLIED "$TEST_TMP/actual-again.log" || fail 'delivered patch idempotence'
    [[ $(digest "$TEST_TMP/actual-source") == "$actual_patched" ]] || fail 'delivered patch reapplied twice'
    git -C "$TEST_TMP/actual-source" apply --reverse --check "$BUNDLE/patches/openbgpd-9.3-pending-backpressure.patch"
    git -C "$TEST_TMP/actual-source" apply --reverse "$BUNDLE/patches/openbgpd-9.3-pending-backpressure.patch"
    [[ $(digest "$TEST_TMP/actual-source") == "$original" ]] || fail 'delivered patch reverse round-trip'
    [[ $(digest "$BUNDLE/upstream/openbgpd-9.3") == "$original" ]] || fail 'pristine upstream was modified'
    printf 'PASS: delivered 9.3 patch checks, applies once, and reverses without modifying pristine source\n'
fi
