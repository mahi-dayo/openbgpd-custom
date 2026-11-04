#!/usr/bin/env bash
set -Eeuo pipefail
TEST_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BUNDLE=$(cd -- "$TEST_DIR/.." && pwd)
TEST_TMP=$(mktemp -d /tmp/pending-fetch-test.XXXXXX)
TEST_TMP=$(cd -- "$TEST_TMP" && pwd -P)
trap 'rm -rf -- "$TEST_TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
mkdir -p "$TEST_TMP/bundle/scripts" "$TEST_TMP/bundle/upstream" "$TEST_TMP/archive/openbgpd-9.3"
cp "$BUNDLE/scripts/fetch-release.sh" "$TEST_TMP/bundle/scripts/"
cp "$BUNDLE/upstream/openbgpd.pub" "$TEST_TMP/bundle/upstream/"
FETCHER="$TEST_TMP/bundle/scripts/fetch-release.sh"
printf '9.3\n' > "$TEST_TMP/archive/openbgpd-9.3/VERSION"
tar -czf "$TEST_TMP/correct.tar.gz" -C "$TEST_TMP/archive" openbgpd-9.3
printf '9.4\n' > "$TEST_TMP/archive/openbgpd-9.3/VERSION"
tar -czf "$TEST_TMP/wrong-version.tar.gz" -C "$TEST_TMP/archive" openbgpd-9.3
printf 'outside\n' > "$TEST_TMP/archive/outside"
tar -czf "$TEST_TMP/wrong-path.tar.gz" -C "$TEST_TMP/archive" outside
printf 'fixture signature\n' > "$TEST_TMP/signature"
FETCH_ARCHIVE_FIXTURE="$TEST_TMP/correct.tar.gz"
FETCH_TEST_ROOT=$TEST_TMP
FETCH_TEST_SIGNATURE_FAIL=0
FETCH_TEST_CURL_FAIL=0
FETCH_TEST_LOG="$TEST_TMP/calls.log"
export FETCH_ARCHIVE_FIXTURE FETCH_TEST_ROOT FETCH_TEST_SIGNATURE_FAIL FETCH_TEST_CURL_FAIL FETCH_TEST_LOG
uname() { printf 'Linux\n'; }
curl()
{
    local target='' url=''
    printf 'curl\n' >> "$FETCH_TEST_LOG"
    (( FETCH_TEST_CURL_FAIL == 0 )) || return 28
    while (( $# )); do
        case "$1" in
            --output) target=$2; shift 2 ;;
            --retry|--connect-timeout|--max-time|--max-filesize|--proto|--proto-redir) shift 2 ;;
            -*) shift ;;
            *) url=$1; shift ;;
        esac
    done
    [[ "$target" == "$FETCH_TEST_ROOT/"* ]] || return 99
    case "$url" in
        https://cdn.openbsd.org/pub/OpenBSD/OpenBGPD/openbgpd-9.3.tar.gz) cp "$FETCH_ARCHIVE_FIXTURE" "$target" ;;
        https://cdn.openbsd.org/pub/OpenBSD/OpenBGPD/SHA256.sig) cp "$FETCH_TEST_ROOT/signature" "$target" ;;
        *) return 98 ;;
    esac
}
signify-openbsd()
{
    printf 'signify\n' >> "$FETCH_TEST_LOG"
    (( FETCH_TEST_SIGNATURE_FAIL == 0 )) || return 1
    [[ "$*" == '-C -p openbgpd.pub -x SHA256.sig openbgpd-9.3.tar.gz' ]] || return 97
    [[ -f openbgpd.pub && -f SHA256.sig && -f openbgpd-9.3.tar.gz ]] || return 96
    printf 'Fixture signature check accepted\n'
}
mv()
{
    # Test GNU no-clobber/no-nesting semantics on macOS without touching any
    # non-fixture path; production uses the real GNU mv on Ubuntu.
    [[ "$1" == -T && "$2" == -n && "$3" == -- ]] || return 95
    [[ "$4" == "$FETCH_TEST_ROOT/"* && "$5" == "$FETCH_TEST_ROOT/"* ]] || return 94
    [[ ! -e "$5" && ! -L "$5" ]] || return 0
    command mv "$4" "$5"
}
export -f uname curl signify-openbsd mv

bash "$FETCHER" --help >/dev/null
bash "$FETCHER" 9.3 "$TEST_TMP/success" > "$TEST_TMP/success.log"
for file in openbgpd-9.3.tar.gz SHA256.sig openbgpd.pub RELEASE-METADATA.txt openbgpd-9.3/VERSION; do
    [[ -f "$TEST_TMP/success/$file" ]] || fail "missing provenance/source file: $file"
done
grep -Fxq 9.3 "$TEST_TMP/success/openbgpd-9.3/VERSION" || fail 'correct source VERSION missing'
grep -Fq FETCH_OK "$TEST_TMP/success.log" || fail 'fetch success missing'
printf 'PASS: verified download flow preserves pristine source and provenance\n'

printf 'preserve\n' > "$TEST_TMP/success/marker"
before=$(wc -l < "$FETCH_TEST_LOG")
if bash "$FETCHER" 9.3 "$TEST_TMP/success" > "$TEST_TMP/existing.log" 2>&1; then fail 'existing destination accepted'; fi
[[ $(< "$TEST_TMP/success/marker") == preserve ]] || fail 'existing destination changed'
[[ $(wc -l < "$FETCH_TEST_LOG") == "$before" ]] || fail 'existing destination triggered network calls'
ln -s "$TEST_TMP/absent" "$TEST_TMP/link"
if bash "$FETCHER" 9.3 "$TEST_TMP/link" > "$TEST_TMP/link.log" 2>&1; then fail 'dangling symlink destination accepted'; fi
[[ -L "$TEST_TMP/link" && ! -e "$TEST_TMP/absent" ]] || fail 'destination symlink changed'
printf 'PASS: existing and symlink destinations are preserved\n'

FETCH_TEST_SIGNATURE_FAIL=1
if bash "$FETCHER" 9.3 "$TEST_TMP/bad-signature" > "$TEST_TMP/bad-signature.log" 2>&1; then fail 'signature failure ignored'; fi
[[ ! -e "$TEST_TMP/bad-signature" ]] || fail 'signature failure installed source'
grep -Fq 'no source was extracted' "$TEST_TMP/bad-signature.log" || fail 'signature failure explanation missing'
FETCH_TEST_SIGNATURE_FAIL=0
printf 'PASS: failed signature prevents extraction and installation\n'

FETCH_ARCHIVE_FIXTURE="$TEST_TMP/wrong-version.tar.gz"
if bash "$FETCHER" 9.3 "$TEST_TMP/bad-version" > "$TEST_TMP/bad-version.log" 2>&1; then fail 'source VERSION mismatch ignored'; fi
[[ ! -e "$TEST_TMP/bad-version" ]] || fail 'VERSION mismatch installed source'
FETCH_ARCHIVE_FIXTURE="$TEST_TMP/wrong-path.tar.gz"
if bash "$FETCHER" 9.3 "$TEST_TMP/bad-path" > "$TEST_TMP/bad-path.log" 2>&1; then fail 'unexpected archive root accepted'; fi
[[ ! -e "$TEST_TMP/bad-path" ]] || fail 'unexpected archive root installed source'
FETCH_ARCHIVE_FIXTURE="$TEST_TMP/correct.tar.gz"
printf 'PASS: requested VERSION and archive root must agree\n'

FETCH_TEST_CURL_FAIL=1
if bash "$FETCHER" 9.3 "$TEST_TMP/download-fail" > "$TEST_TMP/download-fail.log" 2>&1; then fail 'failed download accepted'; fi
[[ ! -e "$TEST_TMP/download-fail" ]] || fail 'failed download installed source'
FETCH_TEST_CURL_FAIL=0
if bash "$FETCHER" ../9.3 "$TEST_TMP/invalid-version" > "$TEST_TMP/invalid-version.log" 2>&1; then fail 'nonnumeric version accepted'; fi
printf 'PASS: download failure and invalid version leave no destination\n'

printf 'untrusted comment: fixture wrong key\nwrong-key\n' > "$TEST_TMP/bundle/upstream/openbgpd.pub"
before=$(wc -l < "$FETCH_TEST_LOG")
if bash "$FETCHER" 9.3 "$TEST_TMP/wrong-key" > "$TEST_TMP/wrong-key.log" 2>&1; then fail 'changed release key accepted'; fi
[[ $(wc -l < "$FETCH_TEST_LOG") == "$before" ]] || fail 'changed key triggered network calls'
if compgen -G "$TEST_TMP/.openbgpd-release-*" >/dev/null; then fail 'temporary extraction state left behind'; fi
printf 'PASS: bundled key is pinned; failed temporary work is cleaned up\n'
