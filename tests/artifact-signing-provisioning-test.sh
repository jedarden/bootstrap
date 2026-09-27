#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise first-time trust-anchor provisioning in a disposable repository.
# The private key is generated outside the fixture, supplied only as a path,
# and must never appear in the pinned artifacts or release-helper output.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-artifact-signing-provisioning.XXXXXX")
FIXTURE="$TMP/repository"
KEY_DIR="$TMP/operator-signing"
PRIVATE_KEY="$KEY_DIR/private.pem"
PUBLIC_KEY="$KEY_DIR/public.pem"
PINNED_KEY="$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"
KEY_ID='bootstrap-rsa-provisioning-test'
VERSION='1.3.2'
RELEASE_LOG="$TMP/release.log"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

fingerprint() {
    local key=$1
    openssl pkey -pubin -in "$key" -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}'
}

assert_mode() {
    local expected=$1 path=$2 actual
    actual=$(stat -c '%a' "$path")
    [[ "$actual" == "$expected" ]] ||
        fail "$path has mode $actual, expected $expected"
}

assert_documented() {
    local doc="$ROOT/docs/security/artifact-signing.md"
    [[ -f "$doc" ]] || fail 'initial provisioning runbook is missing'
    grep -Fq 'openssl genpkey' "$doc" || fail 'runbook does not generate a key'
    grep -Fq 'chmod 600' "$doc" || fail 'runbook does not protect the private key'
    grep -Fq 'openssl pkey -pubin' "$doc" || fail 'runbook does not verify fingerprints'
    grep -Fq 'install -m 0644' "$doc" || fail 'runbook does not install the public key'
    grep -Fq 'ARTIFACT_SIGNING_KEY=' "$doc" || fail 'runbook omits path-only signing'
    grep -Fq 'sync-start-sh.sh --check' "$doc" || fail 'runbook omits trust-anchor sync'
}

assert_documented

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44/keys" "$KEY_DIR"
chmod 0700 "$KEY_DIR"
(
    umask 077
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
        -out "$PRIVATE_KEY" 2>/dev/null
)
chmod 0600 "$PRIVATE_KEY"
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" 2>/dev/null
chmod 0644 "$PUBLIC_KEY"
assert_mode 600 "$PRIVATE_KEY"
assert_mode 700 "$KEY_DIR"

EXPECTED_FINGERPRINT=$(fingerprint "$PUBLIC_KEY")
[[ "$EXPECTED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] ||
    fail 'generated public-key fingerprint is malformed'

# A fingerprint from a different public key must not pass the approval check.
OTHER_PUBLIC_KEY="$TMP/other-public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$TMP/other-private.pem" 2>/dev/null
openssl pkey -in "$TMP/other-private.pem" -pubout -out "$OTHER_PUBLIC_KEY" 2>/dev/null
[[ "$(fingerprint "$OTHER_PUBLIC_KEY")" != "$EXPECTED_FINGERPRINT" ]] ||
    fail 'different public key unexpectedly matched the approved fingerprint'

cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p \
    "$ROOT/scripts/check-host-parity.sh" \
    "$ROOT/scripts/check-secret-leakage.sh" \
    "$ROOT/scripts/start-sh-release.sh" \
    "$FIXTURE/scripts/"
cp -p \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$ROOT/hosts/ex44/artifact-manifest.txt" \
    "$ROOT/hosts/ex44/artifact-manifest.sig" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/ex44/"
cp -p "$ROOT"/hosts/ex44/keys/jedarden.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$ROOT"/hosts/ex44/keys/jeda-mbp.pub "$FIXTURE/hosts/ex44/keys/"

echo 'Installing and checking the disposable pinned public key...'
install -m 0644 "$PUBLIC_KEY" "$PINNED_KEY"
assert_mode 644 "$PINNED_KEY"
cmp -s "$PUBLIC_KEY" "$PINNED_KEY" || fail 'pinned public key differs from generated key'
[[ "$(fingerprint "$PINNED_KEY")" == "$EXPECTED_FINGERPRINT" ]] ||
    fail 'pinned public key fingerprint does not match the approved fingerprint'

python3 - "$FIXTURE/hosts/ex44/start.sh" "$PUBLIC_KEY" "$KEY_ID" <<'PY'
import pathlib
import sys

start_path = pathlib.Path(sys.argv[1])
public_key_path = pathlib.Path(sys.argv[2])
key_id = sys.argv[3]
text = start_path.read_text()
public_key = public_key_path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
start = text.index(begin)
finish = text.index(end, start) + len(end)
replacement = begin + public_key + end
text = text[:start] + replacement + text[finish:]
text = text.replace(
    'ARTIFACT_TRUSTED_KEY_ID="bootstrap-rsa-2026-09"',
    f'ARTIFACT_TRUSTED_KEY_ID="{key_id}"',
)
start_path.write_text(text)
PY

(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh --check)
grep -Fq "$KEY_ID" "$FIXTURE/hosts/ex44/bootstrap.sh" ||
    fail 'bootstrap.sh did not receive the initial key ID'
[[ "$(fingerprint "$PINNED_KEY")" == "$EXPECTED_FINGERPRINT" ]] ||
    fail 'trust-anchor installation changed during synchronization'

# Remove the historical signed metadata so the next release is the fixture's
# first signed release. The immutable 1.3.1 archive remains in the lineage.
rm "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$FIXTURE/hosts/ex44/artifact-manifest.sig"

echo 'Creating the first signed release with a path-only private-key input...'
if ! (
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" \
        scripts/start-sh-release.sh release "$VERSION" >"$RELEASE_LOG" 2>&1
); then
    cat "$RELEASE_LOG" >&2
    fail 'first signed release failed'
fi

(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)
grep -Fxq "key_id=$KEY_ID" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'first manifest has the wrong key ID'
grep -Fxq "version=$VERSION" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'first manifest has the wrong release version'

signature_bin="$TMP/manifest.sig.bin"
sed -n 's/^signature=//p' "$FIXTURE/hosts/ex44/artifact-manifest.sig" |
    base64 --decode > "$signature_bin" 2>/dev/null ||
    fail 'first manifest signature is not valid base64'
openssl dgst -sha256 -verify "$PINNED_KEY" \
    -signature "$signature_bin" \
    "$FIXTURE/hosts/ex44/artifact-manifest.txt" >/dev/null 2>&1 ||
    fail 'first manifest does not verify with the pinned public key'

private_marker='BEGIN PRIVATE KEY'
if grep -R --binary-files=without-match -Fq "$private_marker" "$FIXTURE"; then
    fail 'private-key material appeared in the repository fixture'
fi
if grep -Fq "$private_marker" "$RELEASE_LOG"; then
    fail 'private-key material appeared in release-helper output'
fi
[[ ! -e "$FIXTURE/private.pem" ]] || fail 'private key was copied into the repository'

echo 'artifact signing-key provisioning tests passed.'
