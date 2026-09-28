#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the documented workflow for creating a divergent host lineage.
# Private signing and SSH keys are generated outside the disposable repository.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-host-lineage-onboarding.XXXXXX")
FIXTURE="$TMP/repository"
SIGNING_DIR="$TMP/operator-signing"
SSH_DIR="$TMP/operator-ssh"
HOST=lab
VERSION=1.3.2
KEY_ID=bootstrap-rsa-lab-onboarding
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_documented() {
    local doc="$ROOT/docs/security/artifact-signing.md"
    [[ -f "$doc" ]] || fail 'host-lineage runbook is missing'
    grep -Fq '## New divergent host lineage' "$doc" ||
        fail 'runbook omits divergent-lineage workflow'
    grep -Fq 'cp -p "$source_dir"/bootstrap-*.sh' "$doc" ||
        fail 'runbook omits copying immutable archives'
    grep -Fq 'install -m 0644 /secure/ssh/$host/jedarden.pub' "$doc" ||
        fail 'runbook omits SSH public-key provisioning'
    grep -Fq 'rm "$repo/hosts/$host/artifact-manifest.txt"' "$doc" ||
        fail 'runbook omits replacing inherited signed metadata'
    grep -Fq './scripts/start-sh-release.sh --host "$host" release' "$doc" ||
        fail 'runbook omits host-selected first release'
    grep -Fq './scripts/check-host-parity.sh --live' "$doc" ||
        fail 'runbook omits live parity validation'
    grep -Fq './scripts/check-host-parity.sh --staged' "$doc" ||
        fail 'runbook omits staged parity validation'
    grep -Fq 'check-secret-leakage.sh --tracked --artifacts' "$doc" ||
        fail 'runbook omits private-key leakage validation'
}

replace_trust_anchor() {
    python3 - "$1" "$2" "$3" <<'PY'
import pathlib
import sys

start_path = pathlib.Path(sys.argv[1])
public_key_path = pathlib.Path(sys.argv[2])
key_id = sys.argv[3]
text = start_path.read_text()
public_key = public_key_path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
start = text.index(begin)
finish = text.index(end, start) + len(end)
replacement = begin + public_key + end
text = text[:start] + replacement + text[finish:]
text = text.replace(
    'ARTIFACT_TRUSTED_KEY_ID="bootstrap-rsa-2026-09"',
    f'ARTIFACT_TRUSTED_KEY_ID="{key_id}"',
)
start_path.write_text(text)
PY
}

assert_documented
mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44/keys" "$FIXTURE/hosts/$HOST/keys" "$SIGNING_DIR" "$SSH_DIR"

cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p "$ROOT/scripts/check-host-parity.sh" "$ROOT/scripts/check-secret-leakage.sh" "$ROOT/scripts/start-sh-release.sh" "$FIXTURE/scripts/"
cp -p "$ROOT/hosts/ex44/bootstrap.sh" "$ROOT/hosts/ex44/start.sh" "$ROOT/hosts/ex44/start.sh.version" "$ROOT/hosts/ex44/sync-start-sh.sh" "$ROOT/hosts/ex44/artifact-manifest.txt" "$ROOT/hosts/ex44/artifact-manifest.sig" "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/ex44/"

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out "$SIGNING_DIR/private.pem" 2>/dev/null
openssl pkey -in "$SIGNING_DIR/private.pem" -pubout -out "$SIGNING_DIR/public.pem" 2>/dev/null
chmod 600 "$SIGNING_DIR/private.pem"
chmod 644 "$SIGNING_DIR/public.pem"
ssh-keygen -q -t ed25519 -N '' -C "$HOST-jedarden-onboarding" -f "$SSH_DIR/jedarden" 2>/dev/null
ssh-keygen -q -t ed25519 -N '' -C "$HOST-jeda-mbp-onboarding" -f "$SSH_DIR/jeda-mbp" 2>/dev/null
chmod 600 "$SSH_DIR/jedarden" "$SSH_DIR/jeda-mbp"
chmod 644 "$SSH_DIR/jedarden.pub" "$SSH_DIR/jeda-mbp.pub"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name lineage-test
git -C "$FIXTURE" config user.email lineage-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m base

echo 'Copying the current release into a divergent host directory...'
cp -p "$FIXTURE/hosts/ex44/bootstrap.sh" "$FIXTURE/hosts/ex44/start.sh" "$FIXTURE/hosts/ex44/start.sh.version" "$FIXTURE/hosts/ex44/sync-start-sh.sh" "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$FIXTURE/hosts/ex44/artifact-manifest.sig" "$FIXTURE/hosts/$HOST/"
cp -p "$FIXTURE/hosts/ex44/"bootstrap-*.sh "$FIXTURE/hosts/$HOST/"
cp -p "$FIXTURE/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/$HOST/keys/"
sed -i "s#/hosts/ex44\"#/hosts/$HOST\"#" "$FIXTURE/hosts/$HOST/start.sh"
cp -p "$SIGNING_DIR/public.pem" "$FIXTURE/hosts/$HOST/keys/bootstrap-artifacts-signing.pub"
cp -p "$SSH_DIR/jedarden.pub" "$FIXTURE/hosts/$HOST/keys/jedarden.pub"
cp -p "$SSH_DIR/jeda-mbp.pub" "$FIXTURE/hosts/$HOST/keys/jeda-mbp.pub"
replace_trust_anchor "$FIXTURE/hosts/$HOST/start.sh" "$SIGNING_DIR/public.pem" "$KEY_ID"

(cd "$FIXTURE/hosts/$HOST" && ./sync-start-sh.sh >/dev/null)
(cd "$FIXTURE/hosts/$HOST" && ./sync-start-sh.sh --check)
grep -Fq "/hosts/$HOST" "$FIXTURE/hosts/$HOST/bootstrap.sh" ||
    fail 'bootstrap top-level REPO_URL still points at the source lineage'
grep -Fq "$KEY_ID" "$FIXTURE/hosts/$HOST/bootstrap.sh" ||
    fail 'bootstrap did not receive the new trust anchor'
cmp -s "$FIXTURE/hosts/ex44/keys/jedarden.pub" "$FIXTURE/hosts/$HOST/keys/jedarden.pub" &&
    fail 'divergent lineage did not replace its required SSH input'

# The inherited metadata is invalid after changing the trust anchor and SSH
# inputs, so the first release must create a new manifest and signature.
rm -f "$FIXTURE/hosts/$HOST/artifact-manifest.txt" "$FIXTURE/hosts/$HOST/artifact-manifest.sig"
printf '%s\n' '| [hosts/lab/](./hosts/lab/) | Fixture-specific host split |' >> "$FIXTURE/README.md"
[[ ! -e "$FIXTURE/hosts/$HOST/artifact-manifest.txt" ]]
[[ ! -e "$FIXTURE/hosts/$HOST/artifact-manifest.sig" ]]

echo 'Generating and checking the first signed divergent release...'
(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$SIGNING_DIR/private.pem" scripts/start-sh-release.sh --host "$HOST" release "$VERSION" >/dev/null
    scripts/start-sh-release.sh --host "$HOST" --check >/dev/null
    scripts/check-host-parity.sh --live >/dev/null
)

echo 'Checking the staged parity view and secret boundary...'
git -C "$FIXTURE" add README.md hosts/lab
(cd "$FIXTURE" && scripts/check-host-parity.sh --staged >/dev/null)
git -C "$FIXTURE" diff --cached --check
(cd "$FIXTURE" && scripts/check-secret-leakage.sh --tracked --artifacts >/dev/null)

private_pattern='BEGIN .*PRIVATE KEY'
if git -C "$FIXTURE" grep -I -n -E "$private_pattern" -- .; then
    fail 'private-key material entered the Git index'
fi
if grep -R --binary-files=without-match -E "$private_pattern" "$FIXTURE/hosts/$HOST"; then
    fail 'private-key material entered a host artifact'
fi
[[ ! -e "$FIXTURE/hosts/$HOST/jedarden" ]] ||
    fail 'SSH private key was copied into the host directory'
[[ ! -e "$FIXTURE/hosts/$HOST/private.pem" ]] ||
    fail 'signing private key was copied into the host directory'
if git -C "$FIXTURE" ls-files | grep -Fq -- 'private.pem'; then
    fail 'private signing key is tracked'
fi
if git -C "$FIXTURE" ls-files | grep -Eq '(^|/)(jedarden|jeda-mbp)$'; then
    fail 'SSH private key filename is tracked'
fi

echo 'host-lineage onboarding tests passed.'
