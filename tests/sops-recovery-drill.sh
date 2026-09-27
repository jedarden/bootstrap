#!/usr/bin/env bash
set -euo pipefail

# Verify the offline recovery path without printing identities, plaintext, or
# SOPS diagnostics. With no arguments this runs a disposable end-to-end drill;
# with two arguments it verifies the repository's bootstrap and Ansible files:
#
#   SOPS_RECOVERY_IDENTITY=/secure/offline/age-recovery.txt \
#     tests/sops-recovery-drill.sh \
#     secrets/bootstrap/ex44.sops.env secrets/ansible/ex44.sops.yml
#
# The recovery identity is supplied by path only. The script deliberately
# clears SOPS key variables, uses an isolated HOME, and sends decrypted output
# to /dev/null so a missing primary identity cannot cause a silent fallback or
# expose plaintext in the terminal.

SOPS_BIN=${SOPS_BIN:-sops}
AGE_KEYGEN_BIN=${AGE_KEYGEN_BIN:-age-keygen}

die() {
    echo "offline SOPS recovery drill failed: $*" >&2
    exit 1
}

resolve_tool() {
    local requested=$1
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "tool is not executable"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "required tool is unavailable"
    fi
}

usage() {
    cat >&2 <<'USAGE'
usage:
  tests/sops-recovery-drill.sh
  SOPS_RECOVERY_IDENTITY=/path/to/offline-age-identity \
    tests/sops-recovery-drill.sh bootstrap.sops.env ansible.sops.yml

With no arguments, run a disposable drill. With two arguments, verify the
bootstrap dotenv and Ansible YAML ciphertext using the recovery identity.
USAGE
    exit 2
}

[[ $# == 0 || $# == 2 ]] || usage

SOPS_BIN=$(resolve_tool "$SOPS_BIN")
AGE_KEYGEN_BIN=$(resolve_tool "$AGE_KEYGEN_BIN")

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sops-recovery.XXXXXX")

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-sops-recovery."* ]]; then
        find "$WORK" -depth -delete
    fi
}
trap cleanup EXIT

mkdir -m 700 "$WORK/home" "$WORK/config"

check_identity_file() {
    local identity=$1
    [[ -f "$identity" && -r "$identity" && -s "$identity" ]] ||
        die "offline recovery identity is unavailable"

    local mode
    mode=$(stat -c '%a' -- "$identity" 2>/dev/null) ||
        die "could not inspect offline recovery identity"
    [[ "$mode" == 600 ]] || die "offline recovery identity must be mode 0600"

    # Derive only the public recipient. The output is redirected so neither
    # the identity nor recipient enters this drill's terminal output.
    "$AGE_KEYGEN_BIN" -y "$identity" >"$WORK/recovery-recipient" \
        2>"$WORK/identity.err" || die "offline recovery identity is invalid"
}

sops_with_identity() {
    local identity=$1
    shift

    # SOPS_AGE_KEY is intentionally unset: the private key must come from the
    # checked mode-0600 file, never from a shell value or command argument.
    env -u SOPS_AGE_KEY -u SOPS_AGE_RECIPIENTS -u SOPS_AGE_KEY_FILE \
        -u SOPS_CONFIG HOME="$WORK/home" XDG_CONFIG_HOME="$WORK/config" \
        SOPS_AGE_KEY_FILE="$identity" "$SOPS_BIN" "$@"
}

assert_encrypted() {
    local file=$1
    local label=$2
    local status="$WORK/$label-status.json"

    [[ -f "$file" ]] || die "$label ciphertext is unavailable"
    sops_with_identity "$RECOVERY_IDENTITY" filestatus "$file" \
        >"$status" 2>"$WORK/$label-status.err" ||
        die "$label ciphertext status check failed"
    grep -Eq '"encrypted"[[:space:]]*:[[:space:]]*true' "$status" ||
        die "$label input is not encrypted SOPS data"
}

decrypt_without_output() {
    local identity=$1
    local file=$2
    local label=$3

    # Do not capture decrypted output in a file. A successful exit status is
    # the only evidence needed for this drill.
    sops_with_identity "$identity" decrypt "$file" >/dev/null \
        2>"$WORK/$label-decrypt.err" || die "$label recovery decryption failed"
}

assert_no_private_key_material() {
    local artifact
    for artifact in "$WORK"/*.err "$WORK"/*status.json; do
        [[ -f "$artifact" ]] || continue
        ! grep -q 'AGE-SECRET-KEY-' "$artifact" ||
            die "private identity material appeared in diagnostics"
    done
}

run_disposable_drill() {
    local primary="$WORK/primary-identity.txt"
    local recovery="$WORK/recovery-identity.txt"
    local primary_recipient="$WORK/primary-recipient.txt"
    local recovery_recipient="$WORK/recovery-recipient.txt"
    local recipients="$WORK/recipients.txt"
    local bootstrap_plain="$WORK/bootstrap.env"
    local ansible_plain="$WORK/ansible.yml"
    local bootstrap_cipher="$WORK/bootstrap.sops.env"
    local ansible_cipher="$WORK/ansible.sops.yml"

    "$AGE_KEYGEN_BIN" -o "$primary" >"$WORK/keygen.out" 2>"$WORK/keygen.err" ||
        die "could not create disposable primary identity"
    "$AGE_KEYGEN_BIN" -o "$recovery" >>"$WORK/keygen.out" 2>>"$WORK/keygen.err" ||
        die "could not create disposable recovery identity"
    chmod 0600 "$primary" "$recovery"

    "$AGE_KEYGEN_BIN" -y "$primary" >"$primary_recipient" \
        2>"$WORK/recipient.err" || die "could not derive disposable primary recipient"
    "$AGE_KEYGEN_BIN" -y "$recovery" >"$recovery_recipient" \
        2>>"$WORK/recipient.err" || die "could not derive disposable recovery recipient"
    printf '%s,%s' "$(<"$primary_recipient")" "$(<"$recovery_recipient")" >"$recipients"

    # These random values are disposable fixture data. They are never printed
    # and are removed with the mode-0700 work directory on every exit path.
    bootstrap_value=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    restic_value=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    ansible_value=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    ansible_password=$(head -c 32 /dev/urandom | base64 | tr -d '\n')
    printf 'BOOTSTRAP_B2_APPLICATION_KEY=%s\nBOOTSTRAP_RESTIC_PASSWORD=%s\n' \
        "$bootstrap_value" "$restic_value" >"$bootstrap_plain"
    printf 'bootstrap_restic_env:\n  B2_APPLICATION_KEY: %s\n  RESTIC_PASSWORD: %s\n' \
        "$ansible_value" "$ansible_password" >"$ansible_plain"
    unset bootstrap_value restic_value ansible_value ansible_password

    "$SOPS_BIN" encrypt --age "$(<"$recipients")" \
        --input-type dotenv --output-type dotenv "$bootstrap_plain" \
        >"$bootstrap_cipher" 2>"$WORK/bootstrap-encrypt.err" ||
        die "could not encrypt disposable bootstrap fixture"
    "$SOPS_BIN" encrypt --age "$(<"$recipients")" \
        --input-type yaml --output-type yaml "$ansible_plain" \
        >"$ansible_cipher" 2>"$WORK/ansible-encrypt.err" ||
        die "could not encrypt disposable Ansible fixture"

    RECOVERY_IDENTITY="$recovery"
    check_identity_file "$RECOVERY_IDENTITY"
    assert_encrypted "$bootstrap_cipher" bootstrap
    assert_encrypted "$ansible_cipher" ansible

    # Establish the normal path first, then make the primary unavailable
    # without touching any operator-managed identity.
    decrypt_without_output "$primary" "$bootstrap_cipher" primary-bootstrap
    decrypt_without_output "$primary" "$ansible_cipher" primary-ansible
    mv "$primary" "$WORK/primary-identity.unavailable"

    check_identity_file "$RECOVERY_IDENTITY"
    decrypt_without_output "$RECOVERY_IDENTITY" "$bootstrap_cipher" recovery-bootstrap
    decrypt_without_output "$RECOVERY_IDENTITY" "$ansible_cipher" recovery-ansible
    assert_no_private_key_material

    echo "offline SOPS recovery drill passed (disposable bootstrap and Ansible ciphertext)"
}

run_repository_drill() {
    [[ -n "${SOPS_RECOVERY_IDENTITY:-}" ]] ||
        die "SOPS_RECOVERY_IDENTITY must name the offline identity file"
    RECOVERY_IDENTITY=$SOPS_RECOVERY_IDENTITY
    check_identity_file "$RECOVERY_IDENTITY"

    assert_encrypted "$1" bootstrap
    assert_encrypted "$2" ansible
    decrypt_without_output "$RECOVERY_IDENTITY" "$1" recovery-bootstrap
    decrypt_without_output "$RECOVERY_IDENTITY" "$2" recovery-ansible
    assert_no_private_key_material

    echo "offline SOPS recovery drill passed (repository bootstrap and Ansible ciphertext)"
}

if [[ $# == 0 ]]; then
    run_disposable_drill
else
    run_repository_drill "$1" "$2"
fi
