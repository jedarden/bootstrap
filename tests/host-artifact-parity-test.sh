#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise worktree/staged parity views and the explicit host-directory split
# escape hatch in a disposable Git repository.

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

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44"
cp -p "$ROOT/scripts/check-host-parity.sh" "$FIXTURE/scripts/"
cp -p \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/ex44/"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name parity-test
git -C "$FIXTURE" config user.email parity-test@example.invalid
git -C "$FIXTURE" add scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m base

echo 'Checking the shared canonical layout...'
run_check --live
run_check --staged

echo 'Checking identical ex44/lab artifacts in the worktree and index...'
mkdir -p "$FIXTURE/hosts/lab"
cp -p \
    "$FIXTURE/hosts/ex44/bootstrap.sh" \
    "$FIXTURE/hosts/ex44/start.sh" \
    "$FIXTURE/hosts/ex44/start.sh.version" \
    "$FIXTURE/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/lab/"
cp -p "$FIXTURE"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/lab/"
git -C "$FIXTURE" add hosts/lab
run_check --live
run_check --staged

echo 'Checking that staged parity ignores an unstaged lab drift...'
printf '# unstaged drift\n' >> "$FIXTURE/hosts/lab/start.sh"
run_check --staged
expect_failure --live

echo 'Checking that staged parity catches staged lab drift...'
git -C "$FIXTURE" add hosts/lab/start.sh
expect_failure --staged

echo 'Checking the intentional split override...'
git -C "$FIXTURE" restore --staged hosts/lab/start.sh
cp -p "$FIXTURE/hosts/ex44/start.sh" "$FIXTURE/hosts/lab/start.sh"
printf '# intentional lab launcher change\n' >> "$FIXTURE/hosts/lab/start.sh"
(cd "$FIXTURE/hosts/lab" && ./sync-start-sh.sh)
cp -p "$FIXTURE/hosts/lab/bootstrap.sh" "$FIXTURE/hosts/lab/bootstrap-1.3.1.sh"
git -C "$FIXTURE" add hosts/lab
expect_failure --staged
run_check --staged --allow-split
run_check --live --allow-split

echo 'host artifact parity tests passed.'
