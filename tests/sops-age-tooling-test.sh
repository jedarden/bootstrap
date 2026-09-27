#!/usr/bin/env bash
set -euo pipefail

# This is an operator-tooling check, not a secret fixture. It creates all
# identities and plaintext in a private temporary directory and never prints
# them. Override the binary paths when testing freshly downloaded binaries:
#   SOPS_BIN=/path/to/sops AGE_BIN=/path/to/age \
#   AGE_KEYGEN_BIN=/path/to/age-keygen tests/sops-age-tooling-test.sh

EXPECTED_SOPS_VERSION='3.13.3'
EXPECTED_AGE_VERSION='1.3.2'

SOPS_BIN=${SOPS_BIN:-sops}
AGE_BIN=${AGE_BIN:-age}
AGE_KEYGEN_BIN=${AGE_KEYGEN_BIN:-age-keygen}

die() {
    echo "sops/age tooling validation failed: $*" >&2
    exit 1
}

resolve_tool() {
    local requested=$1
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "tool is not executable: $requested"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "tool is not on PATH: $requested"
    fi
}

SOPS_BIN=$(resolve_tool "$SOPS_BIN")
AGE_BIN=$(resolve_tool "$AGE_BIN")
AGE_KEYGEN_BIN=$(resolve_tool "$AGE_KEYGEN_BIN")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sops-age.XXXXXX")

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-sops-age."* ]]; then
        find "$WORK" -depth -delete
    fi
}
trap cleanup EXIT

mkdir -m 700 "$WORK/home" "$WORK/config"

sops_version=$(
    "$SOPS_BIN" --version 2>/dev/null \
        | sed -n 's/^sops \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        | head -n 1
)
[[ "$sops_version" == "$EXPECTED_SOPS_VERSION" ]] || \
    die "expected sops $EXPECTED_SOPS_VERSION"

age_version=$(
    "$AGE_BIN" --version 2>/dev/null \
        | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
        | head -n 1
)
[[ "$age_version" == "$EXPECTED_AGE_VERSION" ]] || \
    die "expected age $EXPECTED_AGE_VERSION"

primary_identity=$WORK/primary-identity.txt
recovery_identity=$WORK/recovery-identity.txt
unrelated_identity=$WORK/unrelated-identity.txt
primary_recipient=$WORK/primary-recipient.txt
recovery_recipient=$WORK/recovery-recipient.txt
recipients=$WORK/recipients.txt

for identity in "$primary_identity" "$recovery_identity" "$unrelated_identity"; do
    "$AGE_KEYGEN_BIN" -o "$identity" >"$WORK/keygen.out" 2>"$WORK/keygen.err" ||
        die "age-keygen could not create an ephemeral identity"
done
chmod 0600 "$primary_identity" "$recovery_identity" "$unrelated_identity"

"$AGE_KEYGEN_BIN" -y "$primary_identity" >"$primary_recipient" 2>"$WORK/recipient.err" ||
    die "could not derive the primary recipient"
"$AGE_KEYGEN_BIN" -y "$recovery_identity" >"$recovery_recipient" 2>>"$WORK/recipient.err" ||
    die "could not derive the recovery recipient"
cat "$primary_recipient" "$recovery_recipient" >"$recipients"

fixture=$WORK/fixture.env
printf 'CHECK_TOKEN=%s\n' "$(head -c 32 /dev/urandom | base64 | tr -d '\n')" >"$fixture"

age_ciphertext=$WORK/fixture.age
age_decrypted_primary=$WORK/age-primary.env
age_decrypted_recovery=$WORK/age-recovery.env
age_decrypted_wrong=$WORK/age-wrong.env

"$AGE_BIN" -R "$recipients" -o "$age_ciphertext" "$fixture" \
    >"$WORK/age-encrypt.out" 2>"$WORK/age-encrypt.err" ||
    die "age encryption failed"
"$AGE_BIN" -d -i "$primary_identity" "$age_ciphertext" >"$age_decrypted_primary" \
    2>"$WORK/age-primary.err" || die "primary age decryption failed"
"$AGE_BIN" -d -i "$recovery_identity" "$age_ciphertext" >"$age_decrypted_recovery" \
    2>"$WORK/age-recovery.err" || die "recovery age decryption failed"
cmp -s "$fixture" "$age_decrypted_primary" || die "primary age plaintext mismatch"
cmp -s "$fixture" "$age_decrypted_recovery" || die "recovery age plaintext mismatch"

if "$AGE_BIN" -d -i "$unrelated_identity" "$age_ciphertext" >"$age_decrypted_wrong" \
    2>"$WORK/age-wrong.err"; then
    die "unrelated age identity decrypted the ciphertext"
fi
[[ ! -s "$age_decrypted_wrong" ]] || die "failed age decryption emitted plaintext"

primary_recipient_value=$(<"$primary_recipient")
recovery_recipient_value=$(<"$recovery_recipient")
sops_recipients="$primary_recipient_value,$recovery_recipient_value"
sops_ciphertext=$WORK/fixture.sops.env
sops_decrypted_primary=$WORK/sops-primary.env
sops_decrypted_recovery=$WORK/sops-recovery.env
sops_decrypted_wrong=$WORK/sops-wrong.env

run_sops() {
    local identity=$1
    shift
    env -u SOPS_AGE_KEY -u SOPS_AGE_RECIPIENTS \
        SOPS_CONFIG="$WORK/sops.yaml" \
        SOPS_AGE_KEY_FILE="$identity" \
        HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" \
        "$SOPS_BIN" "$@"
}

: >"$WORK/sops.yaml"
run_sops "$primary_identity" encrypt --age "$sops_recipients" \
    --input-type dotenv --output-type dotenv "$fixture" >"$sops_ciphertext" \
    2>"$WORK/sops-encrypt.err" || die "SOPS encryption failed"
run_sops "$primary_identity" filestatus --input-type dotenv "$sops_ciphertext" \
    >"$WORK/sops-status.json" 2>"$WORK/sops-status.err" || die "SOPS filestatus failed"
grep -q '"encrypted":true' "$WORK/sops-status.json" || die "SOPS did not report encrypted"

run_sops "$primary_identity" decrypt --input-type dotenv --output-type dotenv \
    "$sops_ciphertext" >"$sops_decrypted_primary" 2>"$WORK/sops-primary.err" ||
    die "primary SOPS decryption failed"
run_sops "$recovery_identity" decrypt --input-type dotenv --output-type dotenv \
    "$sops_ciphertext" >"$sops_decrypted_recovery" 2>"$WORK/sops-recovery.err" ||
    die "recovery SOPS decryption failed"
cmp -s "$fixture" "$sops_decrypted_primary" || die "primary SOPS plaintext mismatch"
cmp -s "$fixture" "$sops_decrypted_recovery" || die "recovery SOPS plaintext mismatch"

if run_sops "$unrelated_identity" decrypt --input-type dotenv --output-type dotenv \
    "$sops_ciphertext" >"$sops_decrypted_wrong" 2>"$WORK/sops-wrong.err"; then
    die "unrelated SOPS identity decrypted the ciphertext"
fi
[[ ! -s "$sops_decrypted_wrong" ]] || die "failed SOPS decryption emitted plaintext"

if cmp -s "$fixture" "$sops_ciphertext"; then
    die "SOPS output was not encrypted"
fi

# Diagnostics and ciphertext may contain public metadata, but never a private
# identity marker. Keep this assertion over every emitted artifact, excluding
# the deliberately private identity files and decrypted fixture copies.
private_key_marker='AGE-SECRET-''KEY-'
for artifact in "$age_ciphertext" "$sops_ciphertext" "$WORK"/*.err "$WORK/sops-status.json"; do
    if grep -q "$private_key_marker" "$artifact"; then
        die "private identity material appeared in emitted artifacts"
    fi
done

printf '%s\n' "SOPS $EXPECTED_SOPS_VERSION and age $EXPECTED_AGE_VERSION validation passed"
