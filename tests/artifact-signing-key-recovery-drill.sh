#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise recovery of an offline artifact-signing-key backup. With no
# ARTIFACT_SIGNING_BACKUP set, use a disposable key and repository fixture.
# To recover an operator backup, set all of:
#   ARTIFACT_SIGNING_BACKUP=/secure/offline/private.pem
#   ARTIFACT_SIGNING_APPROVED_FINGERPRINT=<separately approved SHA-256>
#   ARTIFACT_SIGNING_RECOVERY_DIR=/secure/bootstrap-signing/recovery
# Optional: ARTIFACT_SIGNING_HOST=ex44
#
# The key is handled by path only. The operator recovery copy is retained in
# the supplied mode-0700 directory; the disposable key and fixture are removed.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
HOST=${ARTIFACT_SIGNING_HOST:-ex44}
BACKUP=${ARTIFACT_SIGNING_BACKUP:-}
APPROVED_FINGERPRINT=${ARTIFACT_SIGNING_APPROVED_FINGERPRINT:-}
RECOVERY_DIR=${ARTIFACT_SIGNING_RECOVERY_DIR:-}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-artifact-key-recovery.XXXXXX")
FIXTURE="$TMP/repository"
DISPOSABLE=false
DISPOSABLE_PUBLIC_KEY="$TMP/offline-backup/public.pem"
trap 'rm -rf "$TMP"' EXIT

die() {
    echo "offline artifact-signing-key recovery drill failed: $*" >&2
    exit 1
}

fingerprint_private() {
    local key=$1 output
    output=$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}') || return 1
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$output"
}

fingerprint_public() {
    local key=$1 output
    output=$(openssl pkey -pubin -in "$key" -outform DER 2>/dev/null |
        sha256sum | awk '{print $1}') || return 1
    [[ "$output" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$output"
}

path_is_inside() {
    local path=$1 root=$2
    [[ "$path" == "$root" || "$path" == "$root/"* ]]
}

copy_release_fixture() {
    [[ -d "$ROOT/hosts/$HOST" ]] || die "host release is unavailable"
    mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts"
    cp "$ROOT/README.md" "$FIXTURE/README.md"
    cp "$ROOT/scripts/check-host-parity.sh" \
        "$ROOT/scripts/check-secret-leakage.sh" \
        "$ROOT/scripts/start-sh-release.sh" "$FIXTURE/scripts/"
    cp -a "$ROOT/hosts/$HOST" "$FIXTURE/hosts/$HOST"
}

restore_disposable_backup() {
    local backup_dir="$TMP/offline-backup" recovery_dir="$TMP/recovered"
    mkdir -m 700 "$backup_dir" "$recovery_dir"
    (
        umask 077
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
            -out "$backup_dir/private.pem" 2>/dev/null
    ) || die "could not create disposable signing key"
    chmod 600 "$backup_dir/private.pem"
    openssl pkey -in "$backup_dir/private.pem" -pubout \
        -out "$DISPOSABLE_PUBLIC_KEY" 2>/dev/null ||
        die "could not create disposable public key"
    install -m 600 "$backup_dir/private.pem" "$TMP/offline-copy.pem" ||
        die "could not create disposable offline backup"
    rm -f "$backup_dir/private.pem"
    BACKUP="$TMP/offline-copy.pem"
    RECOVERY_DIR="$recovery_dir"
    APPROVED_FINGERPRINT=$(fingerprint_public "$DISPOSABLE_PUBLIC_KEY") ||
        die "could not prepare disposable approval fingerprint"
    DISPOSABLE=true
}

restore_backup() {
    local source destination source_dir recovery_path actual_fingerprint pinned_fingerprint
    [[ -n "$BACKUP" && -n "$APPROVED_FINGERPRINT" && -n "$RECOVERY_DIR" ]] ||
        die "backup, approved fingerprint, and recovery directory are all required"
    [[ "$APPROVED_FINGERPRINT" =~ ^[0-9a-f]{64}$ ]] ||
        die "approved fingerprint must be 64 lowercase hexadecimal characters"
    [[ -f "$BACKUP" && ! -L "$BACKUP" && -r "$BACKUP" ]] ||
        die "offline signing-key backup is unavailable"
    source=$(realpath -e -- "$BACKUP") || die "offline signing-key backup is unavailable"
    source_dir=$(realpath -e -- "$(dirname "$source")") ||
        die "offline signing-key backup location is unavailable"
    ! path_is_inside "$source" "$ROOT" && ! path_is_inside "$source_dir" "$ROOT" ||
        die "offline signing-key backup must be outside the repository"
    local backup_mode
    backup_mode=$(stat -c '%a' -- "$source" 2>/dev/null) ||
        die "could not inspect offline backup permissions"
    (( (8#$backup_mode & 077) == 0 )) ||
        die "offline signing-key backup must not be accessible by group or other"

    if [[ -e "$RECOVERY_DIR" ]]; then
        [[ -d "$RECOVERY_DIR" && ! -L "$RECOVERY_DIR" ]] ||
            die "recovery location must be a real directory"
    else
        install -d -m 700 -- "$RECOVERY_DIR" ||
            die "could not create the recovery directory"
    fi
    recovery_path=$(realpath -e -- "$RECOVERY_DIR") ||
        die "recovery directory is unavailable"
    ! path_is_inside "$recovery_path" "$ROOT" ||
        die "recovery directory must be outside the repository"
    [[ "$(stat -c '%a' -- "$recovery_path")" == 700 ]] ||
        die "recovery directory must have mode 0700"
    destination="$recovery_path/recovered-artifact-signing-key.pem"
    [[ ! -e "$destination" ]] ||
        die "recovery destination already exists; choose a fresh recovery directory"
    install -m 600 -- "$source" "$destination" 2>/dev/null ||
        die "could not restore the offline signing-key backup"
    [[ "$(stat -c '%a' -- "$destination")" == 600 ]] ||
        die "restored signing key must have mode 0600"

    actual_fingerprint=$(fingerprint_private "$destination") ||
        die "restored signing-key backup is invalid"
    [[ "$actual_fingerprint" == "$APPROVED_FINGERPRINT" ]] ||
        die "restored key does not match the separately approved fingerprint"
    pinned_fingerprint=$(fingerprint_public \
        "$FIXTURE/hosts/$HOST/keys/bootstrap-artifacts-signing.pub") ||
        die "pinned public trust anchor is unavailable"
    [[ "$actual_fingerprint" == "$pinned_fingerprint" ]] ||
        die "restored key does not match the repository trust anchor"

    RESTORED_KEY=$destination
}

configure_disposable_trust_anchor() {
    local start="$FIXTURE/hosts/$HOST/start.sh"
    install -m 0644 "$DISPOSABLE_PUBLIC_KEY" \
        "$FIXTURE/hosts/$HOST/keys/bootstrap-artifacts-signing.pub" ||
        die "could not install disposable public trust anchor"
    python3 - "$start" "$DISPOSABLE_PUBLIC_KEY" <<'PY'
import pathlib
import sys

start_path = pathlib.Path(sys.argv[1])
public_key = pathlib.Path(sys.argv[2]).read_text()
text = start_path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
first = text.find(begin)
last = text.find(end, first)
if first < 0 or last < 0:
    raise SystemExit("could not locate the disposable trust-anchor block")
last += len(end)
text = text[:first] + begin + public_key + end + text[last:]
start_path.write_text(text)
PY
    (
        cd "$FIXTURE/hosts/$HOST"
        ./sync-start-sh.sh >/dev/null
        ./sync-start-sh.sh --check >/dev/null
        cp -p bootstrap.sh "bootstrap-$(<start.sh.version).sh"
    ) || die "could not synchronize disposable trust anchor"
}

exercise_release_signature() {
    local version signature_bin key_marker='BEGIN ''PRIVATE KEY'
    version=$(tr -d '\r\n' < "$FIXTURE/hosts/$HOST/start.sh.version")
    (
        cd "$FIXTURE"
        ARTIFACT_SIGNING_KEY="$RESTORED_KEY" \
            ./scripts/start-sh-release.sh --host "$HOST" manifest "$version"
    ) >"$TMP/release.log" 2>&1 || die "temporary release signing failed"

    signature_bin="$TMP/release-signature.bin"
    sed -n 's/^signature=//p' "$FIXTURE/hosts/$HOST/artifact-manifest.sig" |
        base64 --decode >"$signature_bin" 2>/dev/null ||
        die "temporary release signature is malformed"
    openssl dgst -sha256 \
        -verify "$FIXTURE/hosts/$HOST/keys/bootstrap-artifacts-signing.pub" \
        -signature "$signature_bin" \
        "$FIXTURE/hosts/$HOST/artifact-manifest.txt" >/dev/null 2>&1 ||
        die "temporary release signature did not verify"
    "$FIXTURE/scripts/check-secret-leakage.sh" --tracked --artifacts \
        >"$TMP/leak-check.log" 2>&1 || die "temporary release leakage check failed"
    if grep -R --binary-files=without-match -Fq "$key_marker" "$FIXTURE" "$TMP/release.log"; then
        die "private-key material appeared in the repository fixture or release log"
    fi
    [[ ! -e "$FIXTURE/recovered-artifact-signing-key.pem" ]] ||
        die "restored signing key appeared in the repository fixture"
}

[[ "$HOST" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid host name"
if [[ -z "$BACKUP" && -z "$APPROVED_FINGERPRINT" && -z "$RECOVERY_DIR" ]]; then
    restore_disposable_backup
elif [[ -z "$BACKUP" || -z "$APPROVED_FINGERPRINT" || -z "$RECOVERY_DIR" ]]; then
    die "set all three recovery inputs for an operator backup"
fi

copy_release_fixture
if [[ "$DISPOSABLE" == true ]]; then
    configure_disposable_trust_anchor
fi
restore_backup
exercise_release_signature

if [[ "$DISPOSABLE" == true ]]; then
    echo "offline artifact-signing-key recovery drill passed (disposable backup and signed release)"
else
    echo "offline artifact-signing-key recovery drill passed; restored key retained in the secure recovery directory"
fi
