#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the guard in disposable Git checkouts so the definition-of-done
# test remains meaningful when it is itself run from a git archive.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
CHECK="$ROOT/scripts/check-hooks-path.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-hook-activation.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

run_rejected_check() {
    local expected=$1 description=$2 output
    if output=$("$CHECK" "$TMP/repository" 2>&1); then
        fail "$description was accepted"
    fi
    grep -Fq "$expected" <<<"$output" ||
        fail "$description did not explain the activation problem"
}

git init -q -b main "$TMP/repository"

echo 'Checking an unset core.hooksPath is rejected...'
run_rejected_check 'core.hooksPath is unset' 'unset core.hooksPath'

echo 'Checking a different core.hooksPath is rejected...'
git -C "$TMP/repository" config core.hooksPath other-hooks
run_rejected_check "core.hooksPath is 'other-hooks'" 'non-githooks core.hooksPath'

echo 'Checking githooks activation is accepted...'
git -C "$TMP/repository" config core.hooksPath githooks
"$CHECK" "$TMP/repository" >/dev/null

echo 'Hook activation checks passed.'
