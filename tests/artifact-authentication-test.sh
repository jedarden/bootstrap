#!/usr/bin/env bash
set -Eeuo pipefail

# Verify the signed release metadata and exercise tamper/stale failures
# entirely offline. Runtime self-update behavior is covered separately by
# start-sh-self-update-test.sh.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HOST_DIR="$ROOT/hosts/ex44"
MANIFEST="$HOST_DIR/artifact-manifest.txt"
SIGNATURE="$HOST_DIR/artifact-manifest.sig"
PUBLIC_KEY="$HOST_DIR/keys/bootstrap-artifacts-signing.pub"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-artifact-authentication.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

manifest_hash() {
    local artifact=$1
    awk -v artifact="$artifact" '$1 == "artifact=" artifact { print $2 }' "$MANIFEST"
}

assert_artifact() {
    local artifact=$1 path=$2 expected actual
    expected=$(manifest_hash "$artifact")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || fail "manifest has no digest for $artifact"
    actual=$(sha256sum "$path" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || fail "digest mismatch for $artifact"
}

assert_manifest_coverage() {
    local expected actual
    expected="$TMP/expected-artifacts"
    actual="$TMP/manifest-artifacts"
    {
        printf '%s\n' \
            bootstrap.sh \
            start.sh \
            start.sh.version \
            keys/jedarden.pub \
            keys/jeda-mbp.pub \
            keys/bootstrap-artifacts-signing.pub
        find "$HOST_DIR" -maxdepth 1 -type f -name 'bootstrap-*.sh' -printf '%f\n'
    } | sort > "$expected"
    sed -n 's/^artifact=\([^ ]*\) [0-9a-f]\{64\}$/\1/p' "$MANIFEST" | sort > "$actual"
    cmp -s "$expected" "$actual" || fail 'manifest artifact coverage is incomplete or unexpected'
}

signature_bin="$TMP/manifest.sig.bin"
sed -n 's/^signature=//p' "$SIGNATURE" | base64 --decode > "$signature_bin" 2>/dev/null ||
    fail 'committed artifact signature encoding is invalid'
openssl dgst -sha256 -verify "$PUBLIC_KEY" \
    -signature "$signature_bin" \
    "$MANIFEST" >/dev/null 2>&1 || fail 'committed artifact manifest signature does not verify'

grep -Fxq 'format=bootstrap-artifact-manifest-v1' "$MANIFEST" ||
    fail 'artifact manifest format marker is missing'
grep -Fxq 'key_id=bootstrap-rsa-2026-09' "$MANIFEST" ||
    fail 'artifact manifest key ID is missing'
grep -Fxq 'version=1.3.1' "$MANIFEST" ||
    fail 'artifact manifest version is missing'

assert_manifest_coverage
while IFS= read -r line; do
    [[ "$line" =~ ^artifact=([^[:space:]]+)[[:space:]]([0-9a-f]{64})$ ]] ||
        fail 'manifest contains a malformed artifact digest entry'
    artifact=${BASH_REMATCH[1]}
    assert_artifact "$artifact" "$HOST_DIR/$artifact"
done < <(grep -E '^artifact=' "$MANIFEST")

cp "$MANIFEST" "$TMP/tampered-manifest"
sed -i 's/^version=1\.3\.1$/version=9.9.9/' "$TMP/tampered-manifest"
if openssl dgst -sha256 -verify "$PUBLIC_KEY" \
    -signature "$signature_bin" \
    "$TMP/tampered-manifest" >/dev/null 2>&1; then
    fail 'tampered manifest unexpectedly verified'
fi

cp "$HOST_DIR/bootstrap.sh" "$TMP/tampered-bootstrap.sh"
printf '%s\n' '# offline tamper fixture' >> "$TMP/tampered-bootstrap.sh"
if [[ "$(sha256sum "$TMP/tampered-bootstrap.sh" | awk '{print $1}')" == "$(manifest_hash bootstrap.sh)" ]]; then
    fail 'tampered bootstrap unexpectedly retained its signed digest'
fi

cp "$HOST_DIR/bootstrap-1.1.6.sh" "$TMP/stale-bootstrap.sh"
if [[ "$(sha256sum "$TMP/stale-bootstrap.sh" | awk '{print $1}')" == "$(manifest_hash bootstrap-1.3.1.sh)" ]]; then
    fail 'stale bootstrap unexpectedly matched the current archive digest'
fi

cp "$HOST_DIR/bootstrap-1.1.6.sh" "$TMP/stale-start.sh"
if [[ "$(sha256sum "$TMP/stale-start.sh" | awk '{print $1}')" == "$(manifest_hash start.sh)" ]]; then
    fail 'stale launcher payload unexpectedly matched the signed start digest'
fi

echo 'offline artifact authentication tests passed.'
