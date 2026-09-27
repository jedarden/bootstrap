#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the structural SOPS gate with disposable Git indexes. The fixture
# ciphertext is deliberately non-decryptable and contains no secret values;
# this test verifies the reviewable contract without requiring an age key.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-sops-contract.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sops-contract.XXXXXX")
trap 'find "$TMP" -depth -delete' EXIT

fail() {
    echo "SOPS contract test failed: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly passed: $*"
    fi
}

PRIMARY_RECIPIENT=age1$(printf 'a%.0s' {1..58})
RECOVERY_RECIPIENT=age1$(printf 'b%.0s' {1..58})
EXTRA_RECIPIENT=age1$(printf 'c%.0s' {1..58})
BOOTSTRAP_B2_FIELD='BOOTSTRAP_''B2_APPLICATION_KEY'
BOOTSTRAP_RESTIC_FIELD='BOOTSTRAP_''RESTIC_PASSWORD'

make_repo() {
    local name=$1
    local repo="$TMP/$name"
    mkdir -p "$repo/secrets/bootstrap"
    git init -q -b main "$repo"
    git -C "$repo" config user.name test
    git -C "$repo" config user.email test@example.invalid
    printf '%s\n' \
        'creation_rules:' \
        "  - path_regex: ^secrets/bootstrap/.*\\.sops\\.env$" \
        "    age: $PRIMARY_RECIPIENT, $RECOVERY_RECIPIENT" >"$repo/.sops.yaml"
    printf '%s=%s\n' "$BOOTSTRAP_B2_FIELD" 'ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]' \
        "$BOOTSTRAP_RESTIC_FIELD" 'ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]' \
        'sops_age__list_0__map_recipient' "$PRIMARY_RECIPIENT" \
        'sops_age__list_1__map_recipient' "$RECOVERY_RECIPIENT" \
        'sops_mac' 'ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]' \
        'sops_version' '3.13.3' >"$repo/secrets/bootstrap/ex44.sops.env"
    git -C "$repo" add .sops.yaml secrets/bootstrap/ex44.sops.env
    printf '%s\n' "$repo"
}

echo 'Checking the current tracked snapshot...'
"$CHECK" --root "$ROOT" >/dev/null

valid_repo=$(make_repo valid)
echo 'Checking a complete encrypted bootstrap file with both recipients...'
"$CHECK" --root "$valid_repo" >/dev/null

missing_recipient_repo=$(make_repo missing-recipient)
sed -i "/sops_age__list_1__map_recipient/d" "$missing_recipient_repo/secrets/bootstrap/ex44.sops.env"
git -C "$missing_recipient_repo" add secrets/bootstrap/ex44.sops.env
expect_failure "$CHECK" --root "$missing_recipient_repo"

partial_repo=$(make_repo partial-pair)
grep -v -F "$BOOTSTRAP_RESTIC_FIELD" "$partial_repo/secrets/bootstrap/ex44.sops.env" >"$partial_repo/partial"
mv "$partial_repo/partial" "$partial_repo/secrets/bootstrap/ex44.sops.env"
git -C "$partial_repo" add secrets/bootstrap/ex44.sops.env
expect_failure "$CHECK" --root "$partial_repo"

extra_field_repo=$(make_repo extra-field)
printf '%s=%s\n' 'UNEXPECTED_FIELD' 'ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]' \
    >>"$extra_field_repo/secrets/bootstrap/ex44.sops.env"
git -C "$extra_field_repo" add secrets/bootstrap/ex44.sops.env
expect_failure "$CHECK" --root "$extra_field_repo"

plaintext_repo=$(make_repo plaintext)
printf '%s=%s\n' "$BOOTSTRAP_B2_FIELD" 'runtime-only-fixture' >"$plaintext_repo/plain.env"
git -C "$plaintext_repo" add plain.env
expect_failure "$CHECK" --root "$plaintext_repo"

unencrypted_repo=$(make_repo unencrypted)
printf '%s=%s\n' "$BOOTSTRAP_B2_FIELD" 'plain-fixture' \
    "$BOOTSTRAP_RESTIC_FIELD" 'plain-fixture' >"$unencrypted_repo/secrets/bootstrap/ex44.sops.env"
git -C "$unencrypted_repo" add secrets/bootstrap/ex44.sops.env
expect_failure "$CHECK" --root "$unencrypted_repo"

ordinary_secret_repo=$(make_repo ordinary-secret)
printf '%s\n' 'disposable plaintext fixture' >"$ordinary_secret_repo/secrets/bootstrap/ex44.env"
git -C "$ordinary_secret_repo" add -f secrets/bootstrap/ex44.env
expect_failure "$CHECK" --root "$ordinary_secret_repo"

private_key_repo=$(make_repo private-key)
private_marker='AGE-SECRET-''KEY-'
printf '%s%s\n' "$private_marker" '1fixture-only' >"$private_key_repo/identity.txt"
git -C "$private_key_repo" add identity.txt
expect_failure "$CHECK" --root "$private_key_repo"

extra_recipient_repo=$(make_repo extra-recipient)
printf '%s=%s\n' 'sops_age__list_2__map_recipient' "$EXTRA_RECIPIENT" \
    >>"$extra_recipient_repo/secrets/bootstrap/ex44.sops.env"
git -C "$extra_recipient_repo" add secrets/bootstrap/ex44.sops.env
expect_failure "$CHECK" --root "$extra_recipient_repo"

echo 'SOPS contract validation tests passed.'
