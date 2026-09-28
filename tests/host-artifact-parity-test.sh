#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise worktree/staged artifact views, independent host validation, and
# README host-link checks in a disposable Git repository.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/host-artifact-parity-test.XXXXXX")
FIXTURE="$TMP/repository"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_check() {
    (cd "$FIXTURE" && scripts/check-host-parity.sh "$@" >/dev/null)
}

expect_failure() {
    if run_check "$@"; then
        fail "parity check unexpectedly passed: $*"
    fi
}

expect_failure_all_views() {
    local mode
    for mode in --live --staged; do
        expect_failure "$mode"
        expect_failure "$mode" --allow-split
    done
}

write_lab_manifest() {
    local manifest="$FIXTURE/hosts/lab/artifact-manifest.txt"
    local signature="$FIXTURE/hosts/lab/artifact-manifest.sig"
    local signature_bin="$TMP/lab-signature.bin"
    local path
    {
        printf '%s\n' 'format=bootstrap-artifact-manifest-v1'
        printf '%s\n' 'key_id=bootstrap-rsa-2026-09'
        printf '%s\n' 'version=1.3.1'
        for path in bootstrap.sh start.sh start.sh.version; do
            printf 'artifact=%s %s\n' "$path" \
                "$(sha256sum "$FIXTURE/hosts/lab/$path" | awk '{print $1}')"
        done
        for path in keys/jedarden.pub keys/jeda-mbp.pub keys/bootstrap-artifacts-signing.pub; do
            printf 'artifact=%s %s\n' "$path" \
                "$(sha256sum "$FIXTURE/hosts/lab/$path" | awk '{print $1}')"
        done
        find "$FIXTURE/hosts/lab" -maxdepth 1 -type f -name 'bootstrap-*.sh' -printf '%f\n' |
            sort | while IFS= read -r path; do
                printf 'artifact=%s %s\n' "$path" \
                    "$(sha256sum "$FIXTURE/hosts/lab/$path" | awk '{print $1}')"
            done
    } > "$manifest"
    openssl dgst -sha256 -sign "$TMP/lab-signing-private.pem" \
        -out "$signature_bin" "$manifest" 2>/dev/null
    {
        printf '%s\n' 'key_id=bootstrap-rsa-2026-09'
        printf 'signature=%s\n' "$(base64 -w0 "$signature_bin")"
    } > "$signature"
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44/keys"
cp -p "$ROOT/scripts/check-host-parity.sh" "$FIXTURE/scripts/"
cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/artifact-manifest.txt" \
    "$ROOT/hosts/ex44/artifact-manifest.sig" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/ex44/"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
    -out "$TMP/lab-signing-private.pem" 2>/dev/null
openssl pkey -in "$TMP/lab-signing-private.pem" -pubout \
    -out "$TMP/lab-signing-public.pem" 2>/dev/null

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name parity-test
git -C "$FIXTURE" config user.email parity-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m base

echo 'Checking the shared canonical layout...'
run_check --live
run_check --staged

echo 'Checking an intentionally divergent lab host in the worktree and index...'
mkdir -p "$FIXTURE/hosts/lab"
cp -p \
    "$FIXTURE/hosts/ex44/bootstrap.sh" \
    "$FIXTURE/hosts/ex44/start.sh" \
    "$FIXTURE/hosts/ex44/start.sh.version" \
    "$FIXTURE/hosts/ex44/artifact-manifest.txt" \
    "$FIXTURE/hosts/ex44/artifact-manifest.sig" \
    "$FIXTURE/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/lab/"
mkdir -p "$FIXTURE/hosts/lab/keys"
cp -p "$FIXTURE/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/lab/keys/"
cp -p "$FIXTURE"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/lab/"
printf '%s\n' '| [hosts/lab/](./hosts/lab/) | Fixture-specific host split |' >> "$FIXTURE/README.md"
printf '# lab-specific divergence\n' >> "$FIXTURE/hosts/lab/start.sh"
(cd "$FIXTURE/hosts/lab" && ./sync-start-sh.sh >/dev/null)
cp -p "$FIXTURE/hosts/lab/bootstrap.sh" "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
cp -p "$TMP/lab-signing-public.pem" \
    "$FIXTURE/hosts/lab/keys/bootstrap-artifacts-signing.pub"
write_lab_manifest
cp -p "$FIXTURE/hosts/lab/start.sh" "$TMP/lab-start-good.sh"
git -C "$FIXTURE" add README.md hosts/lab
run_check --live
run_check --staged

echo 'Checking that staged validation ignores an unstaged lab drift...'
printf '# unstaged drift\n' >> "$FIXTURE/hosts/lab/start.sh"
run_check --staged
expect_failure --live
expect_failure --live --allow-split
cp -p "$TMP/lab-start-good.sh" "$FIXTURE/hosts/lab/start.sh"

echo 'Checking syntax validation with and without the backwards-compatible flag...'
printf 'if [\n' >> "$FIXTURE/hosts/lab/start.sh"
git -C "$FIXTURE" add hosts/lab/start.sh
expect_failure_all_views
cp -p "$TMP/lab-start-good.sh" "$FIXTURE/hosts/lab/start.sh"
git -C "$FIXTURE" add hosts/lab/start.sh

echo 'Checking version validation with and without the backwards-compatible flag...'
printf '%s\n' '9.9.9' > "$FIXTURE/hosts/lab/start.sh.version"
git -C "$FIXTURE" add hosts/lab/start.sh.version
expect_failure_all_views
printf '%s\n' '1.3.1' > "$FIXTURE/hosts/lab/start.sh.version"
git -C "$FIXTURE" add hosts/lab/start.sh.version

echo 'Checking required artifacts and archive validation with and without the backwards-compatible flag...'
mv "$FIXTURE/hosts/lab/start.sh.version" "$TMP/lab-start.sh.version"
git -C "$FIXTURE" add hosts/lab/start.sh.version
expect_failure_all_views
mv "$TMP/lab-start.sh.version" "$FIXTURE/hosts/lab/start.sh.version"
git -C "$FIXTURE" add hosts/lab/start.sh.version
cp -p "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh" "$TMP/lab-archive.sh"
sed -i '0,/^# Version: 1\.3\.1$/s//\# Version: 9.9.9/' \
    "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
git -C "$FIXTURE" add hosts/lab/bootstrap-1.3.1.sh
expect_failure_all_views
mv "$TMP/lab-archive.sh" "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
git -C "$FIXTURE" add hosts/lab/bootstrap-1.3.1.sh

echo 'Checking embedded-launcher validation with and without the backwards-compatible flag...'
cp -p "$FIXTURE/hosts/lab/bootstrap.sh" "$TMP/lab-bootstrap.sh"
sed -i '0,/^# start\.sh - Tmux + coding-agent launcher with self-update$/s//\# start.sh - Tmux + coding-agent launcher with embedded drift/' \
    "$FIXTURE/hosts/lab/bootstrap.sh"
git -C "$FIXTURE" add hosts/lab/bootstrap.sh
expect_failure_all_views
mv "$TMP/lab-bootstrap.sh" "$FIXTURE/hosts/lab/bootstrap.sh"
git -C "$FIXTURE" add hosts/lab/bootstrap.sh

echo 'Checking README-link validation with and without the backwards-compatible flag...'
cp -p "$FIXTURE/README.md" "$TMP/README.md"
sed -i '\|./hosts/lab/|d' "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
expect_failure_all_views
mv "$TMP/README.md" "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
cp -p "$FIXTURE/README.md" "$TMP/README.md"
sed -i 's|./hosts/lab/|./hosts/lab/missing/|' "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md
expect_failure_all_views
mv "$TMP/README.md" "$FIXTURE/README.md"
git -C "$FIXTURE" add README.md

echo 'Checking manifest coverage, digest, and signature failures...'
mv "$FIXTURE/hosts/lab/keys/jedarden.pub" "$TMP/lab-jedarden.pub"
expect_failure --live
mv "$TMP/lab-jedarden.pub" "$FIXTURE/hosts/lab/keys/jedarden.pub"

cp -p "$FIXTURE/hosts/lab/keys/jedarden.pub" "$TMP/lab-jedarden-good.pub"
printf '%s\n' '# tampered SSH public key' >> "$FIXTURE/hosts/lab/keys/jedarden.pub"
expect_failure --live
mv "$TMP/lab-jedarden-good.pub" "$FIXTURE/hosts/lab/keys/jedarden.pub"

cp -p "$FIXTURE/hosts/lab/artifact-manifest.txt" "$TMP/lab-manifest-good.txt"
sed -i 's/^version=1\.3\.1$/version=9.9.9/' \
    "$FIXTURE/hosts/lab/artifact-manifest.txt"
expect_failure --live
mv "$TMP/lab-manifest-good.txt" "$FIXTURE/hosts/lab/artifact-manifest.txt"

cp -p "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh" "$TMP/lab-current-archive-good.sh"
cp -p "$FIXTURE/hosts/lab/bootstrap-1.1.6.sh" \
    "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
expect_failure --live
mv "$TMP/lab-current-archive-good.sh" "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"

cp -p "$FIXTURE/hosts/lab/artifact-manifest.sig" "$TMP/lab-signature-good.sig"
printf 'key_id=bootstrap-rsa-2026-09\n' > "$FIXTURE/hosts/lab/artifact-manifest.sig"
expect_failure --live
mv "$TMP/lab-signature-good.sig" "$FIXTURE/hosts/lab/artifact-manifest.sig"

echo 'Checking the backwards-compatible split override...'
run_check --staged --allow-split
run_check --live --allow-split

echo 'host artifact completeness tests passed.'
