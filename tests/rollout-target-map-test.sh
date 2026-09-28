#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the reviewed rollout target map's format and ownership boundaries.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-rollout-target-map.XXXXXX")
FIXTURE="$TMP/repository"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect_failure() {
    local expected=$1
    shift
    local output
    if output=$("$@" 2>&1); then
        fail "expected failure containing '$expected'"
    fi
    grep -Fq "$expected" <<< "$output" ||
        fail "failure did not contain '$expected': $output"
}

mkdir -p "$FIXTURE/docs" "$FIXTURE/scripts" "$FIXTURE/hosts/ex44" "$FIXTURE/hosts/lab"
cp -p "$ROOT/scripts/check-rollout-targets.sh" "$FIXTURE/scripts/"
touch "$FIXTURE/hosts/ex44/artifact" "$FIXTURE/hosts/lab/artifact"

write_map() {
    printf '%s\n' \
        '# fixture map' \
        $'lineage\ttarget' \
        "$@" > "$FIXTURE/docs/release-rollout-targets.tsv"
}

write_map \
    $'ex44\tcoding@ex44.jedarden.com' \
    $'lab\tcoding@lab.ardenone.com'
(cd "$FIXTURE" && scripts/check-rollout-targets.sh --live >/dev/null)

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name rollout-target-test
git -C "$FIXTURE" config user.email rollout-target-test@example.invalid
git -C "$FIXTURE" add docs scripts hosts
(cd "$FIXTURE" && scripts/check-rollout-targets.sh --staged >/dev/null)

write_map $'ex44\tcoding@ex44.jedarden.com'
expect_failure 'missing rollout target for lineage: lab' \
    "$FIXTURE/scripts/check-rollout-targets.sh" --live

write_map \
    $'ex44\tcoding@ex44.jedarden.com' \
    $'lab\tcoding@ex44.jedarden.com'
expect_failure 'cross-lineage target host ex44.jedarden.com' \
    "$FIXTURE/scripts/check-rollout-targets.sh" --live

write_map \
    $'ex44\tcoding@ex44.jedarden.com' \
    $'lab\tcoding@lab.ardenone.com' \
    $'lab\tcoding@lab.ardenone.com'
expect_failure 'duplicates target host lab.ardenone.com' \
    "$FIXTURE/scripts/check-rollout-targets.sh" --live

write_map \
    $'ex44\tcoding@ex44.jedarden.com' \
    $'unknown\tcoding@unknown.ardenone.com'
expect_failure 'names unknown lineage: unknown' \
    "$FIXTURE/scripts/check-rollout-targets.sh" --live

write_map $'ex44\tcoding@not a host'
expect_failure 'unknown or invalid SSH target' \
    "$FIXTURE/scripts/check-rollout-targets.sh" --live

echo 'rollout target map tests passed.'
