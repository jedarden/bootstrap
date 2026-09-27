#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise release preparation in a disposable repository. This covers the
# generated archive as well as the current bootstrap/start/version agreement
# that the release helper enforces.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-release-test.XXXXXX")
FIXTURE="$TMP/repository"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_version_metadata() {
    local path=$1 version=$2
    grep -Fxq "# Version: $version" "$path" || fail "$path has the wrong Version comment"
    grep -Fxq "VERSION=\"$version\"" "$path" || fail "$path has the wrong VERSION assignment"
}

assert_release() {
    local version=$1 archive
    archive="$FIXTURE/hosts/ex44/bootstrap-$version.sh"
    [[ -f "$archive" ]] || fail "release archive was not created: $archive"
    [[ -x "$archive" ]] || fail "release archive is not executable: $archive"
    cmp -s "$FIXTURE/hosts/ex44/bootstrap.sh" "$archive" ||
        fail "release archive is not an exact bootstrap.sh copy"
    assert_version_metadata "$FIXTURE/hosts/ex44/bootstrap.sh" "$version"
    assert_version_metadata "$archive" "$version"
    grep -Fxq "START_SH_VERSION=\"$version\"" "$FIXTURE/hosts/ex44/start.sh" ||
        fail 'standalone launcher has the wrong version'
    grep -Fxq "START_SH_VERSION=\"$version\"" "$FIXTURE/hosts/ex44/bootstrap.sh" ||
        fail 'embedded launcher has the wrong version'
    [[ "$(<"$FIXTURE/hosts/ex44/start.sh.version")" == "$version" ]] ||
        fail 'advertised launcher version is wrong'
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44"
cp -p "$ROOT/scripts/start-sh-release.sh" "$FIXTURE/scripts/start-sh-release.sh"
cp -p \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/bootstrap-1.3.1.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/ex44/"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name release-test
git -C "$FIXTURE" config user.email release-test@example.invalid
git -C "$FIXTURE" add scripts/start-sh-release.sh hosts/ex44
git -C "$FIXTURE" commit -q -m base

echo 'Checking release archive generation and metadata...'
(cd "$FIXTURE" && scripts/start-sh-release.sh release 1.3.2 >/dev/null)
assert_release 1.3.2
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)

echo 'Checking archive content drift is rejected...'
cp -p "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh" "$TMP/archive-good.sh"
printf '# archive drift\n' >> "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh"
if (cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null 2>&1); then
    fail 'archive content drift unexpectedly passed --check'
fi
mv "$TMP/archive-good.sh" "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh"

echo 'Checking archive metadata drift is rejected...'
cp -p "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh" "$TMP/archive-good.sh"
sed -i '0,/^# Version: 1\.3\.2$/s//\# Version: 9.9.9/' \
    "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh"
if (cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null 2>&1); then
    fail 'archive metadata drift unexpectedly passed --check'
fi
mv "$TMP/archive-good.sh" "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh"

git -C "$FIXTURE" add hosts/ex44
git -C "$FIXTURE" commit -q -m release

echo 'Checking rollback archive generation...'
(cd "$FIXTURE" && scripts/start-sh-release.sh rollback HEAD~1 1.3.3 >/dev/null)
assert_release 1.3.3
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)

echo 'start.sh release archive tests passed.'
