#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise release preparation in a disposable repository. This covers the
# generated archive as well as the current bootstrap/start/version agreement
# that the release helper enforces.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-release-test.XXXXXX")
FIXTURE="$TMP/repository"
FORGEJO_BARE="$TMP/forgejo.git"
GITHUB_BARE="$TMP/github.git"
GITHUB_RAW="$TMP/github-raw"
KNOWN_GOOD_START="$TMP/known-good-start.sh"
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
git -C "$FIXTURE" show HEAD:hosts/ex44/start.sh > "$KNOWN_GOOD_START"

git init --bare -q "$FORGEJO_BARE"
git init --bare -q "$GITHUB_BARE"
mkdir -p "$GITHUB_RAW"
git -C "$FIXTURE" remote add origin "$FORGEJO_BARE"
git --git-dir="$FORGEJO_BARE" config core.hooksPath "$FORGEJO_BARE/hooks"

# Model the server-side mirror and its raw artifact tree locally. The release
# helper still uses its real git push and distribution checks; this hook only
# keeps the test self-contained and non-destructive.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "GITHUB_BARE=$(printf '%q' "$GITHUB_BARE")" \
    "GITHUB_RAW=$(printf '%q' "$GITHUB_RAW")" \
    "FIXTURE=$(printf '%q' "$FIXTURE")" \
    'unset GIT_DIR GIT_WORK_TREE' \
    'while read -r oldrev newrev ref; do' \
    '    [[ "$ref" == refs/heads/main ]] || continue' \
    '    git -C "$FIXTURE" push -q "$GITHUB_BARE" "$newrev:refs/heads/main"' \
    '    version=$(git --git-dir="$GITHUB_BARE" show "$newrev:hosts/ex44/start.sh.version")' \
    '    for filename in bootstrap.sh start.sh start.sh.version "bootstrap-$version.sh"; do' \
    '        git --git-dir="$GITHUB_BARE" show "$newrev:hosts/ex44/$filename" > "$GITHUB_RAW/$filename"' \
    '    done' \
    'done' > "$FORGEJO_BARE/hooks/post-receive"
chmod +x "$FORGEJO_BARE/hooks/post-receive"
git -C "$FIXTURE" push -q origin HEAD:main

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

expected_rollback_start="$TMP/expected-rollback-start.sh"
sed -E 's/^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/START_SH_VERSION="1.3.3"/' \
    "$KNOWN_GOOD_START" > "$expected_rollback_start"
cmp -s "$expected_rollback_start" "$FIXTURE/hosts/ex44/start.sh" ||
    fail 'rollback did not restore the known-good launcher payload from Git history'

git -C "$FIXTURE" add hosts/ex44
git -C "$FIXTURE" commit -q -m rollback

echo 'Checking rollback through the publish and distribution gates...'
(
    cd "$FIXTURE"
    FORGEJO_REMOTE=origin \
    GITHUB_REPO_URL="$GITHUB_BARE" \
    GITHUB_RAW_ROOT="file://$GITHUB_RAW" \
    DISTRIBUTION_TIMEOUT_SECONDS=5 \
    DISTRIBUTION_POLL_SECONDS=0 \
    scripts/start-sh-release.sh publish >/dev/null
)
(
    cd "$FIXTURE"
    FORGEJO_REMOTE=origin \
    GITHUB_REPO_URL="$GITHUB_BARE" \
    GITHUB_RAW_ROOT="file://$GITHUB_RAW" \
    DISTRIBUTION_TIMEOUT_SECONDS=5 \
    DISTRIBUTION_POLL_SECONDS=0 \
    scripts/start-sh-release.sh distribution-check >/dev/null
)
[[ -z "$(git -C "$FIXTURE" rev-list origin/main..HEAD)" ]] ||
    fail 'publish gate left the fixture origin behind HEAD'
[[ "$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/main)" == "$(git -C "$FIXTURE" rev-parse HEAD)" ]] ||
    fail 'distribution gate did not mirror the rollback commit'
for filename in bootstrap.sh start.sh start.sh.version bootstrap-1.3.3.sh; do
    cmp -s "$FIXTURE/hosts/ex44/$filename" "$GITHUB_RAW/$filename" ||
        fail "distributed $filename does not match the committed rollback release"
done

echo 'start.sh release and rollback tests passed.'
