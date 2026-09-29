#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the documentation checker against disposable repository copies.
# The source checkout is never modified, which also makes this test safe in
# the shared worker checkout.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-documentation-reference.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

fail() {
    echo "Documentation reference test failed: $*" >&2
    exit 1
}

expect_failure() {
    local description=$1
    shift
    if "$@" >"$WORK/stdout" 2>"$WORK/stderr"; then
        fail "$description unexpectedly passed"
    fi
}

make_fixture() {
    local destination=$1
    mkdir -p "$destination"
    cp -p "$ROOT/scripts/check-documentation.sh" "$destination/scripts-check.sh"
    cp -p "$ROOT/README.md" "$destination/"
    cp -a "$ROOT/docs" "$destination/"
    cp -a "$ROOT/scripts" "$destination/"
    cp -a "$ROOT/tests" "$destination/"
    cp -a "$ROOT/ansible" "$destination/"
    cp -a "$ROOT/hosts" "$destination/"
    cp -a "$ROOT/.gitignore" "$destination/"
    chmod 0755 "$destination/scripts-check.sh"
}

"$ROOT/scripts/check-documentation.sh" >"$WORK/baseline.out"
grep -Fq 'Documentation reference validation passed' "$WORK/baseline.out" ||
    fail 'baseline check did not report success'

make_fixture "$WORK/path-fixture"
sed -i '0,/scripts\/check-rollout-targets\.sh/s//scripts\/removed-rollout-check.sh/' \
    "$WORK/path-fixture/docs/release-rollout.md"
expect_failure 'removed script reference' \
    "$WORK/path-fixture/scripts-check.sh" --root "$WORK/path-fixture"
grep -Fq 'removed-rollout-check.sh' "$WORK/stderr" ||
    fail 'removed script failure did not identify the stale path'

make_fixture "$WORK/option-fixture"
sed -i '0,/check-host-parity\.sh --live/s//check-host-parity.sh --removed-option/' \
    "$WORK/option-fixture/docs/release-rollout.md"
expect_failure 'removed option reference' \
    "$WORK/option-fixture/scripts-check.sh" --root "$WORK/option-fixture"
grep -Fq -- '--removed-option' "$WORK/stderr" ||
    fail 'removed option failure did not identify the stale option'

make_fixture "$WORK/link-fixture"
sed -i '0,/release-rollout-targets\.tsv/s//removed-rollout-targets.tsv/' \
    "$WORK/link-fixture/docs/release-rollout.md"
expect_failure 'removed linked file' \
    "$WORK/link-fixture/scripts-check.sh" --root "$WORK/link-fixture"
grep -Fq 'removed-rollout-targets.tsv' "$WORK/stderr" ||
    fail 'removed link failure did not identify the stale target'

echo 'Documentation reference checks passed'
