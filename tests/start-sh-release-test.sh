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
TEST_SIGNING_DIR="$TMP/signing"
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
    (cd "$FIXTURE" && hosts/ex44/sync-start-sh.sh --check >/dev/null) ||
        fail 'embedded launcher copy is not synchronized with start.sh'
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44"
mkdir -p "$FIXTURE/hosts/ex44/keys" "$TEST_SIGNING_DIR"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$TEST_SIGNING_DIR/private.pem" 2>/dev/null
openssl pkey -in "$TEST_SIGNING_DIR/private.pem" -pubout \
    -out "$TEST_SIGNING_DIR/public.pem" 2>/dev/null
export ARTIFACT_SIGNING_KEY="$TEST_SIGNING_DIR/private.pem"
cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p \
    "$ROOT/scripts/check-host-parity.sh" \
    "$ROOT/scripts/check-secret-leakage.sh" \
    "$ROOT/scripts/start-sh-release.sh" \
    "$FIXTURE/scripts/"
cp -p \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/bootstrap-1.3.1.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$TEST_SIGNING_DIR/public.pem" \
    "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"

python3 - "$FIXTURE/hosts/ex44/start.sh" \
    "$FIXTURE/hosts/ex44/bootstrap.sh" "$TEST_SIGNING_DIR/public.pem" <<'PY'
import pathlib
import sys

public_key = pathlib.Path(sys.argv[3]).read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
replacement = begin + public_key + end
for filename in sys.argv[1:3]:
    path = pathlib.Path(filename)
    text = path.read_text()
    start = text.index(begin)
    finish = text.index(end, start) + len(end)
    path.write_text(text[:start] + replacement + text[finish:])

# Start with a realistic overlap set. Only the canonical launcher is edited;
# sync-start-sh.sh must propagate it to bootstrap.sh's top-level verifier and
# embedded launcher.
path = pathlib.Path(sys.argv[1])
text = path.read_text()
text = text.replace(
    'ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")',
    'ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID" "bootstrap-rsa-rotation-test")',
)
text = text.replace(
    'ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")',
    'ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY" "$ARTIFACT_TRUSTED_PUBLIC_KEY")',
)
path.write_text(text)
PY

(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
grep -Fq 'bootstrap-rsa-rotation-test' "$FIXTURE/hosts/ex44/bootstrap.sh" ||
    fail 'sync did not propagate the overlap key to bootstrap.sh'
cp -p "$FIXTURE/hosts/ex44/bootstrap.sh" "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh"
(cd "$FIXTURE" && scripts/start-sh-release.sh manifest 1.3.1 >/dev/null)
(cd "$FIXTURE" && scripts/start-sh-release.sh rotation-check \
    bootstrap-rsa-2026-09 bootstrap-rsa-rotation-test >/dev/null) ||
    fail 'rotation-check rejected the prepared overlap release'

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name release-test
git -C "$FIXTURE" config user.email release-test@example.invalid
git -C "$FIXTURE" add README.md scripts/check-host-parity.sh scripts/start-sh-release.sh hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m base
git -C "$FIXTURE" show HEAD:hosts/ex44/start.sh > "$KNOWN_GOOD_START"

echo 'Checking historical archive deletion is rejected...'
cp -p "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh" "$TMP/archive-retention-backup.sh"
rm "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh"
if (cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null 2>&1); then
    fail 'release check accepted deletion of an immutable historical archive'
fi
mv "$TMP/archive-retention-backup.sh" "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh"

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
    '    for filename in bootstrap.sh start.sh start.sh.version artifact-manifest.txt artifact-manifest.sig "bootstrap-$version.sh"; do' \
    '        git --git-dir="$GITHUB_BARE" show "$newrev:hosts/ex44/$filename" > "$GITHUB_RAW/$filename"' \
    '    done' \
    '    mkdir -p "$GITHUB_RAW/keys"' \
    '    for filename in jedarden.pub jeda-mbp.pub bootstrap-artifacts-signing.pub; do' \
    '        git --git-dir="$GITHUB_BARE" show "$newrev:hosts/ex44/keys/$filename" > "$GITHUB_RAW/keys/$filename"' \
    '    done' \
    'done' > "$FORGEJO_BARE/hooks/post-receive"
chmod +x "$FORGEJO_BARE/hooks/post-receive"
git -C "$FIXTURE" push -q origin HEAD:main

echo 'Checking --check rejects an embedded launcher copy drift...'
cp -p "$FIXTURE/hosts/ex44/bootstrap.sh" "$TMP/bootstrap-good.sh"
printf '# embedded copy drift\n' >> "$FIXTURE/hosts/ex44/bootstrap.sh"
if (cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null 2>&1); then
    fail '--check unexpectedly accepted an embedded launcher copy drift'
fi
mv "$TMP/bootstrap-good.sh" "$FIXTURE/hosts/ex44/bootstrap.sh"
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null) ||
    fail '--check did not recover after restoring the embedded launcher copy'

echo 'Checking non-forward releases are rejected without changing release files...'
for version in 1.3.1 1.3.0; do
    if (cd "$FIXTURE" && scripts/start-sh-release.sh release "$version" >/dev/null 2>&1); then
        fail "non-forward release $version was unexpectedly accepted"
    fi
done
git -C "$FIXTURE" diff --quiet -- hosts/ex44 ||
    fail 'a rejected non-forward release changed the release files'

echo 'Checking release archive generation and metadata...'
(cd "$FIXTURE" && scripts/start-sh-release.sh release 1.3.2 >/dev/null)
assert_release 1.3.2
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)

echo 'Checking secret material fails closed before release generation...'
cp -p "$FIXTURE/hosts/ex44/start.sh" "$TMP/start-good.sh"
private_key_prefix='AGE-SECRET-'
printf '\n# poisoned fixture: %sKEY-1fixtureonly\n' "$private_key_prefix" >> "$FIXTURE/hosts/ex44/start.sh"
cp -p "$FIXTURE/hosts/ex44/start.sh" "$TMP/start-poisoned.sh"
if (cd "$FIXTURE" && scripts/start-sh-release.sh release 1.3.4 >/dev/null 2>&1); then
    fail 'release generation accepted secret material in start.sh'
fi
cmp -s "$TMP/start-poisoned.sh" "$FIXTURE/hosts/ex44/start.sh" ||
    fail 'failed release generation changed poisoned start.sh'
mv "$TMP/start-good.sh" "$FIXTURE/hosts/ex44/start.sh"

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
git -C "$FIXTURE" commit -q --no-verify -m release

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
git -C "$FIXTURE" commit -q --no-verify -m rollback

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
