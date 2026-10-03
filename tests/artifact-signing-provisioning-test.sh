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

assert_release_preflight_unchanged() {
    local description=$1
    cmp -s "$TMP/release-inputs.sha256" <(
        sha256sum \
            "$FIXTURE/hosts/ex44/start.sh" \
            "$FIXTURE/hosts/ex44/bootstrap.sh" \
            "$FIXTURE/hosts/ex44/start.sh.version"
    ) || fail "$description changed release inputs"
    [[ ! -e "$FIXTURE/hosts/ex44/bootstrap-$VERSION.sh" ]] ||
        fail "$description created the first-release archive"
    [[ ! -e "$FIXTURE/hosts/ex44/artifact-manifest.txt" ]] ||
        fail "$description created an unsigned manifest"
    [[ ! -e "$FIXTURE/hosts/ex44/artifact-manifest.sig" ]] ||
        fail "$description created a detached signature"
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
    grep -Fq 'tests/artifact-signing-key-recovery-drill.sh' "$doc" ||
        fail 'runbook omits offline signing-key recovery drill'
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
OTHER_FINGERPRINT=$(fingerprint "$OTHER_PUBLIC_KEY")
if [[ "$OTHER_FINGERPRINT" == "$EXPECTED_FINGERPRINT" ]]; then
    fail 'fingerprint approval accepted a mismatched public key'
fi

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
cp -p \
    "$ROOT/hosts/ex44/bootstrap-1.1.6.sh" \
    "$ROOT/hosts/ex44/bootstrap-1.3.1.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT"/hosts/ex44/keys/jedarden.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$ROOT"/hosts/ex44/keys/jeda-mbp.pub "$FIXTURE/hosts/ex44/keys/"

# Provisioning models a fixed unsigned 1.3.1 baseline followed by the first
# signed 1.3.2 release. Normalize the disposable canonical files so newer real
# releases do not collide with that scenario or copy future archives into it.
sed -i \
    's/^START_SH_VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/START_SH_VERSION="1.3.1"/' \
    "$FIXTURE/hosts/ex44/start.sh"
sed -i \
    -e 's/^# Version: [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/# Version: 1.3.1/' \
    -e 's/bootstrap-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.sh/bootstrap-1.3.1.sh/g' \
    -e 's/^VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/VERSION="1.3.1"/' \
    -e 's/^START_SH_VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/START_SH_VERSION="1.3.1"/' \
    "$FIXTURE/hosts/ex44/bootstrap.sh"
printf '%s\n' '1.3.1' > "$FIXTURE/hosts/ex44/start.sh.version"

echo 'Installing and checking the disposable pinned public key...'
install -m 0644 "$PUBLIC_KEY" "$PINNED_KEY"
assert_mode 644 "$PINNED_KEY"
cmp -s "$PUBLIC_KEY" "$PINNED_KEY" || fail 'pinned public key differs from generated key'
[[ "$(fingerprint "$PINNED_KEY")" == "$EXPECTED_FINGERPRINT" ]] ||
    fail 'pinned public key fingerprint does not match the approved fingerprint'

python3 - "$FIXTURE/hosts/ex44/start.sh" "$PUBLIC_KEY" "$KEY_ID" <<'PY'
import pathlib
import re
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
text, count = re.subn(
    r'^ARTIFACT_TRUSTED_KEY_ID="[A-Za-z0-9._-]+"$',
    f'ARTIFACT_TRUSTED_KEY_ID="{key_id}"',
    text,
    count=1,
    flags=re.MULTILINE,
)
if count != 1:
    raise SystemExit("could not replace the primary artifact key ID")
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
sha256sum \
    "$FIXTURE/hosts/ex44/start.sh" \
    "$FIXTURE/hosts/ex44/bootstrap.sh" \
    "$FIXTURE/hosts/ex44/start.sh.version" > "$TMP/release-inputs.sha256"

echo 'Rejecting a first release without a signing key...'
if (
    cd "$FIXTURE"
    env -u ARTIFACT_SIGNING_KEY \
        scripts/start-sh-release.sh release "$VERSION" >"$RELEASE_LOG" 2>&1
); then
    fail 'release without a signing key unexpectedly succeeded'
fi
assert_release_preflight_unchanged 'missing signing key rejection'

echo 'Rejecting a first release without the pinned trust anchor...'
mv "$PINNED_KEY" "$TMP/missing-pinned-key.pub"
if (
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" \
        scripts/start-sh-release.sh release "$VERSION" >"$RELEASE_LOG" 2>&1
); then
    fail 'release without a pinned trust anchor unexpectedly succeeded'
fi
assert_release_preflight_unchanged 'missing trust anchor rejection'
mv "$TMP/missing-pinned-key.pub" "$PINNED_KEY"

echo 'Rejecting a first release with a mismatched pinned fingerprint...'
install -m 0644 "$OTHER_PUBLIC_KEY" "$PINNED_KEY"
if (
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" \
        scripts/start-sh-release.sh release "$VERSION" >"$RELEASE_LOG" 2>&1
); then
    fail 'release with a mismatched pinned fingerprint unexpectedly succeeded'
fi
assert_release_preflight_unchanged 'fingerprint mismatch rejection'
install -m 0644 "$PUBLIC_KEY" "$PINNED_KEY"

echo 'Rejecting a first release with a private key inside the host repository...'
cp -p "$PRIVATE_KEY" "$FIXTURE/hosts/ex44/signing-private.pem"
if (
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" \
        scripts/start-sh-release.sh release "$VERSION" >"$RELEASE_LOG" 2>&1
); then
    fail 'release with a repository private key unexpectedly succeeded'
fi
assert_release_preflight_unchanged 'repository private-key rejection'
rm "$FIXTURE/hosts/ex44/signing-private.pem"

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
