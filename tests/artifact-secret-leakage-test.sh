#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise both the tracked-file and generated-artifact secret audit without
# putting a real-looking secret in this repository. Secret-looking values are
# assembled at runtime inside a disposable directory.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-secret-leakage.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    if "$@" >/dev/null 2>&1; then
        fail "command unexpectedly passed: $*"
    fi
}

SCANNER="$ROOT/scripts/check-secret-leakage.sh"

echo 'Checking the committed repository and generated host artifacts...'
"$SCANNER" --tracked --artifacts >/dev/null

echo 'Checking sensitive field placeholders and variable references...'
SAFE="$TMP/safe.txt"
cat > "$SAFE" <<'SAFE'
BOOTSTRAP_RESTIC_PASSWORD="$BOOTSTRAP_RESTIC_PASSWORD"
B2_APPLICATION_KEY=<b2-application-key>
RESTIC_PASSWORD: <restic-password>
SAFE
"$SCANNER" --path "$SAFE" >/dev/null

echo 'Checking SOPS plaintext is rejected...'
SOPS_PLAINTEXT="$TMP/plain.env"
printf 'BOOTSTRAP_RESTIC_PASSWORD=%s\n' 'runtime-only-restic-password' > "$SOPS_PLAINTEXT"
expect_failure "$SCANNER" --path "$SOPS_PLAINTEXT"

echo 'Checking age private keys are rejected...'
AGE_PRIVATE="$TMP/age-key.txt"
printf '%s\n' 'AGE-SECRET-' 'KEY-1runtime-only-fixture' | tr -d '\n' > "$AGE_PRIVATE"
expect_failure "$SCANNER" --path "$AGE_PRIVATE"

echo 'Checking OpenBao tokens are rejected...'
OPENBAO_TOKEN="$TMP/openbao.txt"
printf 'token=hvs.%s\n' 'runtimeonlytokenvalue1234567890' > "$OPENBAO_TOKEN"
expect_failure "$SCANNER" --path "$OPENBAO_TOKEN"

echo 'Checking B2 keys are rejected...'
B2_KEY="$TMP/b2.env"
printf 'B2_APPLICATION_KEY=%s\n' 'runtimeonlyb2applicationkey1234567890' > "$B2_KEY"
expect_failure "$SCANNER" --path "$B2_KEY"

echo 'Checking restic passwords are rejected...'
RESTIC_PASSWORD="$TMP/restic.env"
printf 'RESTIC_PASSWORD=%s\n' 'runtime-only-restic-password' > "$RESTIC_PASSWORD"
expect_failure "$SCANNER" --path "$RESTIC_PASSWORD"

echo 'Checking unencrypted .sops files are rejected...'
SOPS_FILE="$TMP/example.sops.env"
printf 'ordinary: plaintext\n' > "$SOPS_FILE"
expect_failure "$SCANNER" --path "$SOPS_FILE"

echo 'Checking an encrypted SOPS-shaped file is accepted...'
SOPS_CIPHERTEXT="$TMP/example.sops.env"
printf 'password: ENC[AES256_GCM,data:fixture,iv:fixture,tag:fixture,type:str]\nsops:\n  version: 3.8.1\n' > "$SOPS_CIPHERTEXT"
"$SCANNER" --path "$SOPS_CIPHERTEXT" >/dev/null

echo 'Checking the tracked-file scope catches a staged secret...'
REPOSITORY="$TMP/repository"
mkdir -p "$REPOSITORY/scripts"
git init -q -b main "$REPOSITORY"
cp -p "$SCANNER" "$REPOSITORY/scripts/check-secret-leakage.sh"
printf 'RESTIC_PASSWORD=%s\n' 'runtime-only-restic-password' > "$REPOSITORY/leak.env"
git -C "$REPOSITORY" add scripts/check-secret-leakage.sh leak.env
expect_failure "$REPOSITORY/scripts/check-secret-leakage.sh" --tracked

echo 'Checking each generated artifact class is included...'
ARTIFACTS="$TMP/artifacts"
mkdir -p "$ARTIFACTS"
cp -p "$ROOT/hosts/ex44/start.sh" "$ARTIFACTS/start.sh"
cp -p "$ROOT/hosts/ex44/bootstrap.sh" "$ARTIFACTS/bootstrap.sh"
cp -p "$ROOT/hosts/ex44/start.sh.version" "$ARTIFACTS/start.sh.version"
cp -p "$ROOT/hosts/ex44/bootstrap-1.3.1.sh" "$ARTIFACTS/bootstrap-1.3.1.sh"
"$SCANNER" --path "$ARTIFACTS" >/dev/null
printf '\n%s=%s\n' RESTIC_PASSWORD 'runtime-only-restic-password' >> "$ARTIFACTS/bootstrap-1.3.1.sh"
expect_failure "$SCANNER" --path "$ARTIFACTS"

echo 'artifact secret leakage tests passed.'
