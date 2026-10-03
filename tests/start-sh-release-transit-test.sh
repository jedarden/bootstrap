#!/usr/bin/env bash
set -Eeuo pipefail

# Prove that the release helper can use a non-exportable OpenBao Transit RSA
# key without changing the detached-signature format consumed by launchers.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/start-sh-release-transit-test.XXXXXX")
FIXTURE="$TMP/repository"
KEY_DIR="$TMP/transit-key"
FAKE_BIN="$TMP/bin"
BAO_CALLS="$TMP/bao-calls"
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44/keys" "$KEY_DIR" "$FAKE_BIN"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$KEY_DIR/private.pem" 2>/dev/null
openssl pkey -in "$KEY_DIR/private.pem" -pubout \
    -out "$KEY_DIR/public.pem" 2>/dev/null

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
cp -p "$KEY_DIR/public.pem" \
    "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"

# The Transit test exercises a fixed 1.3.1 manifest followed by unsigned and
# signed 1.3.2 preparation. Normalize the disposable canonical files so the
# real checkout can advance without invalidating that scenario.
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

python3 - "$FIXTURE/hosts/ex44/start.sh" "$KEY_DIR/public.pem" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
public_key = pathlib.Path(sys.argv[2]).read_text()
text = path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
start = text.index(begin)
finish = text.index(end, start) + len(end)
path.write_text(text[:start] + begin + public_key + end + text[finish:])
PY

(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
cp -p "$FIXTURE/hosts/ex44/bootstrap.sh" \
    "$FIXTURE/hosts/ex44/bootstrap-1.3.1.sh"

cat > "$FAKE_BIN/bao" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >> "$FAKE_TRANSIT_CALLS"

case "${1:-}" in
    read)
        python3 - "$FAKE_TRANSIT_PUBLIC_KEY" <<'PY'
import json
import pathlib
import sys

print(json.dumps({
    "data": {
        "type": "rsa-3072",
        "keys": {"1": {"public_key": pathlib.Path(sys.argv[1]).read_text()}},
    }
}))
PY
        ;;
    write)
        encoded=$(cat)
        printf '%s' "$encoded" | base64 --decode > "$FAKE_TRANSIT_MESSAGE"
        openssl dgst -sha256 -sign "$FAKE_TRANSIT_PRIVATE_KEY" \
            -out "$FAKE_TRANSIT_SIGNATURE" "$FAKE_TRANSIT_MESSAGE" 2>/dev/null
        printf 'vault:v1:'
        base64 -w0 "$FAKE_TRANSIT_SIGNATURE"
        printf '\n'
        ;;
    *)
        exit 2
        ;;
esac
SH
chmod +x "$FAKE_BIN/bao"

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name transit-test
git -C "$FIXTURE" config user.email transit-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m base

export PATH="$FAKE_BIN:$PATH"
export FAKE_TRANSIT_PRIVATE_KEY="$KEY_DIR/private.pem"
export FAKE_TRANSIT_PUBLIC_KEY="$KEY_DIR/public.pem"
export FAKE_TRANSIT_MESSAGE="$TMP/transit-message"
export FAKE_TRANSIT_SIGNATURE="$TMP/transit-signature"
export FAKE_TRANSIT_CALLS="$BAO_CALLS"
export ARTIFACT_SIGNING_TRANSIT_KEY='bootstrap-signing/bootstrap-rsa-transit-test'
unset ARTIFACT_SIGNING_KEY

echo 'Checking OpenBao Transit manifest signing...'
(cd "$FIXTURE" && scripts/start-sh-release.sh manifest 1.3.1 >/dev/null)
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)
cmp -s "$FAKE_TRANSIT_MESSAGE" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'Transit did not receive the exact artifact manifest bytes'
grep -Fq 'bootstrap-signing/keys/bootstrap-rsa-transit-test' "$BAO_CALLS" ||
    fail 'release helper did not read the Transit public key'
grep -Fq 'bootstrap-signing/sign/bootstrap-rsa-transit-test' "$BAO_CALLS" ||
    fail 'release helper did not call the expected Transit signing path'
grep -Fq 'signature_algorithm=pkcs1v15' "$BAO_CALLS" ||
    fail 'release helper did not preserve the launcher-compatible RSA signature mode'
grep -Fq 'hash_algorithm=sha2-256' "$BAO_CALLS" ||
    fail 'release helper did not request SHA-256'

sed -n 's/^signature=//p' "$FIXTURE/hosts/ex44/artifact-manifest.sig" |
    base64 --decode > "$TMP/repository-signature"
openssl dgst -sha256 -verify "$KEY_DIR/public.pem" \
    -signature "$TMP/repository-signature" \
    "$FIXTURE/hosts/ex44/artifact-manifest.txt" >/dev/null 2>&1 ||
    fail 'the persisted Transit signature is not launcher-compatible'

echo 'Checking CI preparation removes stale signatures...'
(cd "$FIXTURE" && scripts/start-sh-release.sh prepare-unsigned 1.3.2 >/dev/null)
[[ -f "$FIXTURE/hosts/ex44/artifact-manifest.txt" ]] ||
    fail 'CI preparation did not create the artifact manifest'
[[ ! -e "$FIXTURE/hosts/ex44/artifact-manifest.sig" ]] ||
    fail 'CI preparation retained a stale detached signature'
grep -Fxq 'version=1.3.2' "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'CI preparation wrote the wrong manifest version'
(cd "$FIXTURE" && scripts/start-sh-release.sh manifest 1.3.2 >/dev/null)
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)

echo 'Checking ambiguous signing configuration fails closed...'
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.txt" "$TMP/manifest-before"
cp -p "$FIXTURE/hosts/ex44/artifact-manifest.sig" "$TMP/signature-before"
export ARTIFACT_SIGNING_KEY="$KEY_DIR/private.pem"
if (cd "$FIXTURE" && scripts/start-sh-release.sh manifest 1.3.1 >/dev/null 2>&1); then
    fail 'release helper accepted both file and Transit signing backends'
fi
cmp -s "$TMP/manifest-before" "$FIXTURE/hosts/ex44/artifact-manifest.txt" ||
    fail 'ambiguous backend selection changed the manifest'
cmp -s "$TMP/signature-before" "$FIXTURE/hosts/ex44/artifact-manifest.sig" ||
    fail 'ambiguous backend selection changed the signature'

echo 'OpenBao Transit release signing tests passed.'
