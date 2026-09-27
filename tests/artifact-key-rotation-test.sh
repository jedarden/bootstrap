#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the launcher's embedded trust-anchor overlap policy with generated
# keys. The test deliberately uses the real verify_artifact_manifest function
# from both standalone and embedded launchers, but never changes repository
# artifacts or contacts the network.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-artifact-key-rotation.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

OLD_KEY_ID='bootstrap-rsa-old-test'
NEW_KEY_ID='bootstrap-rsa-new-test'
MISSING_KEY_ID='bootstrap-rsa-missing-test'
OLD_PRIVATE="$TMP/old-private.pem"
OLD_PUBLIC="$TMP/old-public.pem"
NEW_PRIVATE="$TMP/new-private.pem"
NEW_PUBLIC="$TMP/new-public.pem"
OLD_MANIFEST="$TMP/old-manifest.txt"
OLD_SIGNATURE="$TMP/old-manifest.sig"
NEW_MANIFEST="$TMP/new-manifest.txt"
NEW_SIGNATURE="$TMP/new-manifest.sig"
MISSING_MANIFEST="$TMP/missing-manifest.txt"
MISSING_SIGNATURE="$TMP/missing-manifest.sig"
UNSIGNED_SIGNATURE="$TMP/unsigned-manifest.sig"
STALE_PUBLIC="$TMP/stale-public.pem"
FAKE_BIN="$TMP/bin"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_key() {
    local private=$1 public=$2
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$private" 2>/dev/null
    openssl pkey -in "$private" -pubout -out "$public" 2>/dev/null
}

make_signed_manifest() {
    local key_id=$1 private=$2 manifest=$3 signature=$4 signature_bin="$TMP/signature.bin"
    {
        printf '%s\n' 'format=bootstrap-artifact-manifest-v1'
        printf 'key_id=%s\n' "$key_id"
        printf '%s\n' 'version=2.0.0'
        printf 'artifact=bootstrap-1.3.1.sh %s\n' "$(sha256sum "$OLD_ARCHIVE" | awk '{print $1}')"
        printf 'artifact=bootstrap-2.0.0.sh %s\n' "$(sha256sum "$NEW_ARCHIVE" | awk '{print $1}')"
    } > "$manifest"
    openssl dgst -sha256 -sign "$private" -out "$signature_bin" "$manifest" 2>/dev/null
    {
        printf 'key_id=%s\n' "$key_id"
        printf 'signature=%s\n' "$(base64 -w0 "$signature_bin")"
    } > "$signature"
}

make_missing_key_manifest() {
    local signature_bin="$TMP/missing-signature.bin"
    sed "s/^key_id=.*/key_id=$MISSING_KEY_ID/" "$OLD_MANIFEST" > "$MISSING_MANIFEST"
    openssl dgst -sha256 -sign "$OLD_PRIVATE" -out "$signature_bin" "$MISSING_MANIFEST" 2>/dev/null
    {
        printf 'key_id=%s\n' "$MISSING_KEY_ID"
        printf 'signature=%s\n' "$(base64 -w0 "$signature_bin")"
    } > "$MISSING_SIGNATURE"
}

make_harness() {
    local launcher=$1 mode=$2 harness
    harness="$TMP/harness-$mode.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        printf '%s\n' 'ARTIFACT_MANIFEST_FILE="artifact-manifest.txt"'
        printf '%s\n' 'ARTIFACT_SIGNATURE_FILE="artifact-manifest.sig"'
        printf '%s\n' 'ARTIFACT_TRUSTED_KEY_IDS=()' 'ARTIFACT_TRUSTED_PUBLIC_KEYS=()'
        case "$mode" in
            old-only)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$OLD_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$OLD_PUBLIC_FILE")")'
                ;;
            overlap)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$OLD_KEY_ID\" \"$NEW_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$OLD_PUBLIC_FILE")")'
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$NEW_PUBLIC_FILE")")'
                ;;
            new-only)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$NEW_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$NEW_PUBLIC_FILE")")'
                ;;
            stale-anchor)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$OLD_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$STALE_PUBLIC_FILE")")'
                ;;
            *)
                fail "unknown harness mode: $mode"
                ;;
        esac
        printf '%s\n' 'REPO_URL="https://fixture.invalid"'
        sed -n '/^verify_artifact_manifest() {/,/^}$/p' "$launcher"
        printf '%s\n' 'mkdir -p "$1"' 'if ! version=$(verify_artifact_manifest "$1"); then exit 1; fi' 'printf "%s\n" "$version"'
    } > "$harness"
    chmod +x "$harness"
    printf '%s\n' "$harness"
}

run_verifier() {
    local harness=$1 manifest=$2 signature=$3
    MANIFEST_FILE="$manifest" \
    SIGNATURE_FILE="$signature" \
    OLD_PUBLIC_FILE="$OLD_PUBLIC" \
    NEW_PUBLIC_FILE="$NEW_PUBLIC" \
    STALE_PUBLIC_FILE="$STALE_PUBLIC" \
    PATH="$FAKE_BIN:$(dirname "$(command -v bash)"):$(dirname "$(command -v openssl)"):/usr/bin:/bin" \
        "$harness" "$TMP/output" 2>&1
}

expect_success() {
    local description=$1 harness=$2 manifest=$3 signature=$4 output
    output=$(run_verifier "$harness" "$manifest" "$signature") ||
        fail "$description (verification failed: $output)"
    [[ "$output" == '2.0.0' ]] || fail "$description (wrong manifest version: $output)"
}

expect_failure() {
    local description=$1 harness=$2 manifest=$3 signature=$4
    if run_verifier "$harness" "$manifest" "$signature" >/dev/null; then
        fail "$description (verification unexpectedly succeeded)"
    fi
}

mkdir -p "$FAKE_BIN"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'url="${!#}"' \
    'case "$url" in' \
    '  */artifact-manifest.txt) cat "$MANIFEST_FILE" ;;' \
    '  */artifact-manifest.sig) cat "$SIGNATURE_FILE" ;;' \
    '  *) exit 22 ;;' \
    'esac' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

OLD_ARCHIVE="$TMP/bootstrap-1.3.1.sh"
NEW_ARCHIVE="$TMP/bootstrap-2.0.0.sh"
printf '%s\n' 'immutable historical bootstrap archive' > "$OLD_ARCHIVE"
printf '%s\n' 'new bootstrap archive' > "$NEW_ARCHIVE"
make_key "$OLD_PRIVATE" "$OLD_PUBLIC"
make_key "$NEW_PRIVATE" "$NEW_PUBLIC"
cp "$NEW_PUBLIC" "$STALE_PUBLIC"
make_signed_manifest "$OLD_KEY_ID" "$OLD_PRIVATE" "$OLD_MANIFEST" "$OLD_SIGNATURE"
make_signed_manifest "$NEW_KEY_ID" "$NEW_PRIVATE" "$NEW_MANIFEST" "$NEW_SIGNATURE"
make_missing_key_manifest
printf 'key_id=%s\n' "$OLD_KEY_ID" > "$UNSIGNED_SIGNATURE"

grep -Fxq "artifact=bootstrap-1.3.1.sh $(sha256sum "$OLD_ARCHIVE" | awk '{print $1}')" "$NEW_MANIFEST" ||
    fail 'new manifest dropped the immutable historical archive digest'

for launcher in "$ROOT/hosts/ex44/start.sh" "$ROOT/hosts/ex44/bootstrap.sh"; do
    launcher_name=$(basename "$launcher")
    old_only=$(make_harness "$launcher" old-only)
    overlap=$(make_harness "$launcher" overlap)
    new_only=$(make_harness "$launcher" new-only)
    stale_anchor=$(make_harness "$launcher" stale-anchor)

    echo "Checking $launcher_name old/new signature acceptance..."
    expect_success "$launcher_name rejected an old-key signature" "$old_only" "$OLD_MANIFEST" "$OLD_SIGNATURE"
    expect_success "$launcher_name overlap rejected an old-key signature" "$overlap" "$OLD_MANIFEST" "$OLD_SIGNATURE"
    expect_success "$launcher_name overlap rejected a new-key signature" "$overlap" "$NEW_MANIFEST" "$NEW_SIGNATURE"
    expect_success "$launcher_name final trust set rejected a new-key signature" "$new_only" "$NEW_MANIFEST" "$NEW_SIGNATURE"

    echo "Checking $launcher_name stale and missing trust anchors..."
    expect_failure "$launcher_name accepted a new signature with a stale old-only trust anchor" \
        "$old_only" "$NEW_MANIFEST" "$NEW_SIGNATURE"
    expect_failure "$launcher_name accepted an old signature after old-key retirement" \
        "$new_only" "$OLD_MANIFEST" "$OLD_SIGNATURE"
    expect_failure "$launcher_name accepted a signature with a stale public key under the old ID" \
        "$stale_anchor" "$OLD_MANIFEST" "$OLD_SIGNATURE"
    expect_failure "$launcher_name accepted a manifest signed by a missing key" \
        "$overlap" "$MISSING_MANIFEST" "$MISSING_SIGNATURE"
    expect_failure "$launcher_name accepted an unsigned manifest" \
        "$overlap" "$OLD_MANIFEST" "$UNSIGNED_SIGNATURE"
done

echo 'artifact signing-key rotation tests passed.'
