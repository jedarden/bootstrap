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
cp -p "$FIXTURE/hosts/lab/start.sh" "$TMP/lab-start-good.sh"
git -C "$FIXTURE" add README.md hosts/lab
run_check --live
run_check --staged

echo 'Checking that staged validation ignores an unstaged lab drift...'
printf '# unstaged drift\n' >> "$FIXTURE/hosts/lab/start.sh"
run_check --staged
expect_failure --live
cp -p "$TMP/lab-start-good.sh" "$FIXTURE/hosts/lab/start.sh"

echo 'Checking missing required artifacts and archive metadata...'
mv "$FIXTURE/hosts/lab/start.sh.version" "$TMP/lab-start.sh.version"
expect_failure --live
mv "$TMP/lab-start.sh.version" "$FIXTURE/hosts/lab/start.sh.version"
cp -p "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh" "$TMP/lab-archive.sh"
sed -i '0,/^# Version: 1\.3\.1$/s//\# Version: 9.9.9/' \
    "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
expect_failure --live
mv "$TMP/lab-archive.sh" "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"

echo 'Checking missing README host links...'
cp -p "$FIXTURE/README.md" "$TMP/README.md"
sed -i '\|./hosts/lab/|d' "$FIXTURE/README.md"
expect_failure --live
mv "$TMP/README.md" "$FIXTURE/README.md"
cp -p "$FIXTURE/README.md" "$TMP/README.md"
sed -i 's|./hosts/lab/|./hosts/lab/missing/|' "$FIXTURE/README.md"
expect_failure --live
mv "$TMP/README.md" "$FIXTURE/README.md"

echo 'Checking the backwards-compatible split override...'
run_check --staged --allow-split
run_check --live --allow-split

echo 'host artifact completeness tests passed.'
