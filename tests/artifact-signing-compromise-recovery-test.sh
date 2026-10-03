#!/usr/bin/env bash
set -Eeuo pipefail

# Acceptance-test the emergency signing-key compromise response in a disposable
# repository. The test deliberately distinguishes emergency replacement from
# planned overlap rotation: an old-key candidate is not published, the old
# anchor is removed without overlap, a new-key release is published, old
# deployed launchers reject it until an out-of-band replacement, and historical
# archives remain byte-preserved for audit.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-artifact-signing-emergency.XXXXXX")
FIXTURE="$TMP/repository"
FORGEJO_BARE="$TMP/forgejo.git"
GITHUB_BARE="$TMP/github.git"
GITHUB_RAW="$TMP/github-raw"
KEY_DIR="$TMP/signing"
OLD_PRIVATE="$KEY_DIR/old-private.pem"
OLD_PUBLIC="$KEY_DIR/old-public.pem"
NEW_PRIVATE="$KEY_DIR/new-private.pem"
NEW_PUBLIC="$KEY_DIR/new-public.pem"
OLD_KEY_ID='bootstrap-rsa-compromised-test'
NEW_KEY_ID='bootstrap-rsa-emergency-test'
OLD_MANIFEST="$TMP/pre-compromise-manifest.txt"
OLD_SIGNATURE="$TMP/pre-compromise-signature.sig"
COMPROMISED_MANIFEST="$TMP/compromised-manifest.txt"
COMPROMISED_SIGNATURE="$TMP/compromised-signature.sig"
FAKE_BIN="$TMP/bin"
RAW_BASE="file://$GITHUB_RAW"

trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_key() {
    local private=$1 public=$2
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$private" 2>/dev/null
    openssl pkey -in "$private" -pubout -out "$public" 2>/dev/null
}

replace_trust_anchor() {
    local path=$1 key_id=$2 public_key=$3
    python3 - "$path" "$key_id" "$public_key" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
key_id = sys.argv[2]
public_key = pathlib.Path(sys.argv[3]).read_text()
text = path.read_text()
pattern = re.compile(
    r'^ARTIFACT_TRUSTED_KEY_ID=.*?^ARTIFACT_TRUSTED_PUBLIC_KEYS=.*?\n',
    re.MULTILINE | re.DOTALL,
)
replacement = (
    f'ARTIFACT_TRUSTED_KEY_ID="{key_id}"\n'
    'ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<\'ARTIFACT_KEY\'\n'
    f'{public_key}'
    'ARTIFACT_KEY\n'
    ')\n'
    'ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")\n'
    'ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")\n'
)
updated, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit(f"could not replace trust anchor in {path}")
path.write_text(updated)
PY
}

make_harness() {
    local launcher=$1 mode=$2 harness
    harness="$TMP/harness-$(basename "$launcher")-$mode.sh"
    {
        printf '%s\n' '#!/usr/bin/env bash' 'set -Eeuo pipefail'
        printf '%s\n' 'ARTIFACT_MANIFEST_FILE="artifact-manifest.txt"'
        printf '%s\n' 'ARTIFACT_SIGNATURE_FILE="artifact-manifest.sig"'
        printf '%s\n' 'ARTIFACT_TRUSTED_KEY_IDS=()' 'ARTIFACT_TRUSTED_PUBLIC_KEYS=()'
        case "$mode" in
            old-only)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$OLD_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$OLD_PUBLIC_FILE")")'
                ;;
            new-only)
                printf '%s\n' "ARTIFACT_TRUSTED_KEY_IDS=(\"$NEW_KEY_ID\")"
                printf '%s\n' 'ARTIFACT_TRUSTED_PUBLIC_KEYS+=("$(<"$NEW_PUBLIC_FILE")")'
                ;;
            *)
                fail "unknown harness mode: $mode"
                ;;
        esac
        printf '%s\n' 'REPO_URL="https://fixture.invalid"'
        sed -n '/^verify_artifact_manifest() {/,/^}$/p' "$launcher"
        printf '%s\n' 'mkdir -p "$1"' 'verify_artifact_manifest "$1"'
    } > "$harness"
    chmod +x "$harness"
    printf '%s\n' "$harness"
}

run_verifier() {
    local harness=$1 manifest=$2 signature=$3
    rm -rf "$TMP/verifier-output"
    MANIFEST_FILE="$manifest" \
    SIGNATURE_FILE="$signature" \
    OLD_PUBLIC_FILE="$OLD_PUBLIC" \
    NEW_PUBLIC_FILE="$NEW_PUBLIC" \
    PATH="$FAKE_BIN:$(dirname "$(command -v bash)"):$(dirname "$(command -v openssl)"):/usr/bin:/bin" \
        "$harness" "$TMP/verifier-output"
}

expect_success() {
    local description=$1 harness=$2 manifest=$3 signature=$4
    if ! run_verifier "$harness" "$manifest" "$signature" >/dev/null 2>&1; then
        fail "$description"
    fi
}

expect_failure() {
    local description=$1 harness=$2 manifest=$3 signature=$4
    if run_verifier "$harness" "$manifest" "$signature" >/dev/null 2>&1; then
        fail "$description"
    fi
}

assert_documented() {
    local doc="$ROOT/docs/security/artifact-signing-compromise-recovery.md"
    [[ -f "$doc" ]] || fail 'emergency recovery runbook is missing'
    grep -Fq 'Halt the rollout' "$doc" || fail 'runbook does not halt rollout'
    grep -Fq 'no overlap period' "$doc" || fail 'runbook does not distinguish emergency replacement from overlap rotation'
    grep -Fq 'out-of-band' "$doc" || fail 'runbook omits out-of-band recovery'
    grep -Fq 'already-deployed' "$doc" || fail 'runbook omits already-deployed host handling'
    grep -Fq 'Older immutable archives remain' "$doc" || fail 'runbook omits older artifact handling'
    grep -Fq 'ARTIFACT_SIGNING_KEY=' "$doc" || fail 'runbook omits path-only signing'
    grep -Fq 'publish' "$doc" || fail 'runbook omits publishing the replacement release'
}

assert_documented

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44/keys" "$KEY_DIR" "$FAKE_BIN" "$GITHUB_RAW"
make_key "$OLD_PRIVATE" "$OLD_PUBLIC"
make_key "$NEW_PRIVATE" "$NEW_PUBLIC"

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
    "$ROOT/hosts/ex44/artifact-manifest.txt" \
    "$ROOT/hosts/ex44/artifact-manifest.sig" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/ex44/keys/"

# This drill intentionally models a fixed 1.3.1 baseline, a halted 1.3.2
# candidate, and a 1.3.3 recovery release. Normalize the disposable copies so
# a newer real checkout does not silently change the scenario's starting
# version or make its baseline archive inconsistent.
sed -i \
    's/^START_SH_VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/START_SH_VERSION="1.3.1"/' \
    "$FIXTURE/hosts/ex44/start.sh"
sed -i \
    -e 's/^# Version: [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$/# Version: 1.3.1/' \
    -e 's/bootstrap-[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.sh/bootstrap-1.3.1.sh/g' \
    -e 's/^VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/VERSION="1.3.1"/' \
    -e 's/^START_SH_VERSION="[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*"$/START_SH_VERSION="1.3.1"/' \
    "$FIXTURE/hosts/ex44/bootstrap.sh"
printf '%s\n' '1.3.1' > "$FIXTURE/hosts/ex44/start.sh.version"

replace_trust_anchor "$FIXTURE/hosts/ex44/start.sh" "$OLD_KEY_ID" "$OLD_PUBLIC"
install -m 0644 "$OLD_PUBLIC" \
    "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"
(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
cp -p "$FIXTURE/hosts/ex44/bootstrap.sh" \
    "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh"

echo 'Creating the pre-compromise signed baseline...'
(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$OLD_PRIVATE" \
        scripts/start-sh-release.sh manifest 1.3.1 >/dev/null
)
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$OLD_MANIFEST"
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.sig" "$OLD_SIGNATURE"
OLD_ARCHIVE_DIGEST=$(sha256sum "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh" | awk '{print $1}')

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name emergency-test
git -C "$FIXTURE" config user.email emergency-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m baseline
BASELINE_COMMIT=$(git -C "$FIXTURE" rev-parse HEAD)
cp -p "$FIXTURE/hosts/ex44/start.sh" "$TMP/already-deployed-old-start.sh"

git init --bare -q "$FORGEJO_BARE"
git init --bare -q "$GITHUB_BARE"
git -C "$FIXTURE" remote add origin "$FORGEJO_BARE"
git --git-dir="$FORGEJO_BARE" config core.hooksPath "$FORGEJO_BARE/hooks"

# Model the configured Forgejo mirror and its raw artifact publication locally.
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    "FIXTURE=$(printf '%q' "$FIXTURE")" \
    "GITHUB_BARE=$(printf '%q' "$GITHUB_BARE")" \
    "GITHUB_RAW=$(printf '%q' "$GITHUB_RAW")" \
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
git -C "$FIXTURE" push -q origin main
[[ "$(git --git-dir="$FORGEJO_BARE" rev-parse refs/heads/main)" == "$BASELINE_COMMIT" ]] ||
    fail 'baseline was not published before the emergency candidate'

echo 'Preparing an old-key candidate, then proving rollout is halted...'
(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$OLD_PRIVATE" \
        scripts/start-sh-release.sh release 1.3.2 >/dev/null
)
grep -Fxq "key_id=$OLD_KEY_ID" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'the halted candidate was not signed by the compromised key'
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$COMPROMISED_MANIFEST"
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.sig" "$COMPROMISED_SIGNATURE"
[[ "$(git --git-dir="$FORGEJO_BARE" rev-parse refs/heads/main)" == "$BASELINE_COMMIT" ]] ||
    fail 'halted candidate was published before key replacement'

printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -Eeuo pipefail' \
    'url="${!#}"' \
    'case "$url" in' \
    '  */artifact-manifest.txt) cat "$MANIFEST_FILE" ;;' \
    '  */artifact-manifest.sig) cat "$SIGNATURE_FILE" ;;' \
    '  *) exit 22 ;;' \
    'esac' > "$FAKE_BIN/curl"
chmod +x "$FAKE_BIN/curl"

echo 'Checking both verifier copies before revocation...'
for launcher in "$FIXTURE/hosts/ex44/start.sh" "$FIXTURE/hosts/ex44/bootstrap.sh"; do
    old_harness=$(make_harness "$launcher" old-only)
    new_harness=$(make_harness "$launcher" new-only)
    expect_success "$(basename "$launcher") did not verify the old-key candidate before revocation" \
        "$old_harness" "$COMPROMISED_MANIFEST" "$COMPROMISED_SIGNATURE"
    expect_failure "$(basename "$launcher") accepted the old-key candidate under the replacement anchor" \
        "$new_harness" "$COMPROMISED_MANIFEST" "$COMPROMISED_SIGNATURE"
done

echo 'Replacing the pinned anchor with no overlap and creating the recovery release...'
replace_trust_anchor "$FIXTURE/hosts/ex44/start.sh" "$NEW_KEY_ID" "$NEW_PUBLIC"
install -m 0644 "$NEW_PUBLIC" \
    "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"
(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
grep -Fxq "ARTIFACT_TRUSTED_KEY_ID=\"$NEW_KEY_ID\"" \
    "$FIXTURE/hosts/ex44/start.sh" || fail 'canonical launcher kept the old key ID'
grep -Fxq 'ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")' \
    "$FIXTURE/hosts/ex44/start.sh" || fail 'canonical launcher retained a trust overlap'
if grep -Fq "$OLD_KEY_ID" "$FIXTURE/hosts/ex44/start.sh"; then
    fail 'canonical launcher still embeds the compromised key ID'
fi

(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$NEW_PRIVATE" \
        scripts/start-sh-release.sh release 1.3.3 >/dev/null
    scripts/start-sh-release.sh --check >/dev/null
)
grep -Fxq "key_id=$NEW_KEY_ID" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'recovery manifest was not signed by the replacement key'
grep -Fxq "artifact=bootstrap-1.3.1.sh $OLD_ARCHIVE_DIGEST" \
    "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'recovery manifest dropped the historical archive digest'
[[ "$(sha256sum "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh" | awk '{print $1}')" == "$OLD_ARCHIVE_DIGEST" ]] ||
    fail 'historical archive bytes changed during recovery'
[[ -f "$FIXTURE/hosts/ex44/bootstrap-1.3.2.sh" ]] ||
    fail 'halted candidate archive was deleted instead of retained for audit'

NEW_MANIFEST="$FIXTURE/hosts/ex44/artifact-manifest.txt"
NEW_SIGNATURE="$FIXTURE/hosts/ex44/artifact-manifest.sig"
OLD_DEPLOYED="$TMP/already-deployed-old-start.sh"
old_deployed_harness=$(make_harness "$OLD_DEPLOYED" old-only)
recovered_harness=$(make_harness "$FIXTURE/hosts/ex44/start.sh" new-only)
expect_success 'old deployed launcher could not verify its pre-compromise release' \
    "$old_deployed_harness" "$OLD_MANIFEST" "$OLD_SIGNATURE"
expect_failure 'old deployed launcher accepted the replacement-key recovery release without out-of-band update' \
    "$old_deployed_harness" "$NEW_MANIFEST" "$NEW_SIGNATURE"
expect_failure 'recovered launcher accepted the revoked old-key manifest' \
    "$recovered_harness" "$OLD_MANIFEST" "$OLD_SIGNATURE"
expect_failure 'recovered launcher accepted the halted compromised candidate' \
    "$recovered_harness" "$COMPROMISED_MANIFEST" "$COMPROMISED_SIGNATURE"
expect_success 'recovered launcher rejected the replacement-key recovery release' \
    "$recovered_harness" "$NEW_MANIFEST" "$NEW_SIGNATURE"

git -C "$FIXTURE" add hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m emergency-recovery
(
    cd "$FIXTURE"
    FORGEJO_REMOTE=origin \
    GITHUB_REPO_URL="$GITHUB_BARE" \
    GITHUB_RAW_ROOT="$RAW_BASE" \
    DISTRIBUTION_TIMEOUT_SECONDS=5 \
    DISTRIBUTION_POLL_SECONDS=0 \
    scripts/start-sh-release.sh publish >/dev/null
)
[[ "$(git --git-dir="$FORGEJO_BARE" rev-parse refs/heads/main)" == "$(git -C "$FIXTURE" rev-parse HEAD)" ]] ||
    fail 'replacement release was not published to Forgejo'
[[ "$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/main)" == "$(git -C "$FIXTURE" rev-parse HEAD)" ]] ||
    fail 'replacement release was not mirrored to GitHub'
cmp -s "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$GITHUB_RAW/artifact-manifest.txt" ||
    fail 'published raw manifest differs from the committed recovery release'

echo 'artifact signing-key compromise recovery tests passed.'
