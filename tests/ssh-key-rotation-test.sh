#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the host SSH-key rotation runbook in a disposable release and a
# real local sshd. The fixture changes one host-specific public-key input,
# runs the production release helper to regenerate and sign all artifacts,
# then proves that the unchanged fallback and replacement keys work while the
# retired key no longer authenticates.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-ssh-key-rotation.XXXXXX")
FIXTURE="$TMP/repository"
HOST_DIR="$FIXTURE/hosts/ex44"
SIGNING_DIR="$TMP/artifact-signing"
AUTHORIZED_KEYS="$TMP/authorized_keys"
SSHD_CONFIG="$TMP/sshd_config"
SSHD_LOG="$TMP/sshd.log"
SSHD_PID=""
trap 'if [[ -n "${SSHD_PID:-}" ]]; then kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; fi; rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_documented() {
    local doc="$ROOT/docs/security/ssh-key-rotation.md"
    [[ -f "$doc" ]] || fail 'SSH-key rotation runbook is missing'
    for required in \
        'hosts/<host>/keys/' \
        'ssh-keygen -q -t ed25519' \
        'ARTIFACT_SIGNING_KEY=' \
        'start-sh-release.sh release' \
        'authorized_keys' \
        'fresh connection' \
        'private key fails'; do
        grep -Fq "$required" "$doc" ||
            fail "SSH-key rotation runbook omits: $required"
    done
    grep -Fq 'docs/security/ssh-key-rotation.md' "$ROOT/README.md" ||
        fail 'README does not link the SSH-key rotation runbook'
    grep -Fq 'tests/ssh-key-rotation-test.sh' "$ROOT/README.md" ||
        fail 'README does not name the SSH-key rotation acceptance test'
}

make_ssh_key() {
    local private=$1 comment=$2
    ssh-keygen -q -t ed25519 -N '' -C "$comment" -f "$private" 2>/dev/null
}

make_signing_key() {
    mkdir -p "$SIGNING_DIR"
    chmod 700 "$SIGNING_DIR"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
        -out "$SIGNING_DIR/private.pem" 2>/dev/null
    chmod 600 "$SIGNING_DIR/private.pem"
    openssl pkey -in "$SIGNING_DIR/private.pem" -pubout \
        -out "$SIGNING_DIR/public.pem" 2>/dev/null
    chmod 644 "$SIGNING_DIR/public.pem"
}

replace_embedded_signing_key() {
    python3 - "$HOST_DIR/start.sh" "$SIGNING_DIR/public.pem" <<'PY'
import pathlib
import sys

start_path = pathlib.Path(sys.argv[1])
public_key = pathlib.Path(sys.argv[2]).read_text()
text = start_path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
start = text.index(begin)
finish = text.index(end, start) + len(end)
replacement = begin + public_key + end
start_path.write_text(text[:start] + replacement + text[finish:])
PY
    (cd "$HOST_DIR" && ./sync-start-sh.sh >/dev/null)
}

record_digest() {
    local relative=$1 destination="$TMP/before-${1//\//_}"
    if [[ -f "$FIXTURE/$relative" ]]; then
        sha256sum "$FIXTURE/$relative" | awk '{print $1}' > "$destination"
    else
        printf '%s\n' '<missing>' > "$destination"
    fi
}

assert_changed() {
    local relative=$1 before after
    before=$(<"$TMP/before-${relative//\//_}")
    if [[ "$before" == '<missing>' ]]; then
        [[ -f "$FIXTURE/$relative" ]] || fail "rotation did not create $relative"
        return 0
    fi
    after=$(sha256sum "$FIXTURE/$relative" | awk '{print $1}')
    [[ "$before" != "$after" ]] || fail "rotation did not regenerate $relative"
}

write_authorized_keys_from_host_inputs() {
    local temporary="$AUTHORIZED_KEYS.new"
    cat "$HOST_DIR/keys/jedarden.pub" "$HOST_DIR/keys/jeda-mbp.pub" > "$temporary"
    chmod 600 "$temporary"
    mv "$temporary" "$AUTHORIZED_KEYS"
}

run_ssh() {
    local private_key=$1
    ssh -q -p "$PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=2 \
        -o IdentitiesOnly=yes \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o GlobalKnownHostsFile=/dev/null \
        -i "$private_key" \
        "$LOGIN_USER@127.0.0.1" 'printf "%s\\n" ssh-key-rotation-ok'
}

expect_ssh_success() {
    local description=$1 private_key=$2 output
    output=$(run_ssh "$private_key") ||
        fail "$description (SSH authentication failed)"
    [[ "$output" == 'ssh-key-rotation-ok' ]] ||
        fail "$description (unexpected SSH output: $output)"
}

expect_ssh_failure() {
    local description=$1 private_key=$2
    if run_ssh "$private_key" >/dev/null 2>&1; then
        fail "$description (SSH authentication unexpectedly succeeded)"
    fi
}

start_sshd() {
    "$SSHD" -t -f "$SSHD_CONFIG" || {
        cat "$SSHD_CONFIG" >&2
        fail 'disposable sshd configuration is invalid'
    }
    "$SSHD" -D -e -f "$SSHD_CONFIG" >"$SSHD_LOG" 2>&1 &
    SSHD_PID=$!
    for _ in {1..40}; do
        if run_ssh "$STABLE_PRIVATE" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$SSHD_PID" 2>/dev/null; then
            cat "$SSHD_LOG" >&2
            fail 'disposable sshd exited before accepting connections'
        fi
        sleep 0.1
    done
    cat "$SSHD_LOG" >&2
    fail 'disposable sshd did not become ready'
}

assert_documented
command -v sshd >/dev/null 2>&1 || fail 'sshd is required for the SSH rotation acceptance test'
command -v ssh >/dev/null 2>&1 || fail 'ssh is required for the SSH rotation acceptance test'
command -v ssh-keygen >/dev/null 2>&1 || fail 'ssh-keygen is required for the SSH rotation acceptance test'

LOGIN_USER=$(id -un)
SSHD=$(command -v sshd)
PORT=$(python3 - <<'PY'
import socket

with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)

mkdir -p "$FIXTURE/scripts" "$HOST_DIR/keys"
make_ssh_key "$TMP/stable" 'bootstrap-rotation-stable'
make_ssh_key "$TMP/rotating-old" 'bootstrap-rotation-old'
make_ssh_key "$TMP/rotating-new" 'bootstrap-rotation-new'
STABLE_PRIVATE="$TMP/stable"
STABLE_PUBLIC="$TMP/stable.pub"
ROTATING_OLD_PRIVATE="$TMP/rotating-old"
ROTATING_OLD_PUBLIC="$TMP/rotating-old.pub"
ROTATING_NEW_PRIVATE="$TMP/rotating-new"
ROTATING_NEW_PUBLIC="$TMP/rotating-new.pub"
make_signing_key

cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p \
    "$ROOT/scripts/check-host-parity.sh" \
    "$ROOT/scripts/check-secret-leakage.sh" \
    "$ROOT/scripts/start-sh-release.sh" \
    "$FIXTURE/scripts/"
cp -p \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/start.sh.version" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$HOST_DIR/keys/"
cp -p "$STABLE_PUBLIC" "$HOST_DIR/keys/jedarden.pub"
cp -p "$ROTATING_OLD_PUBLIC" "$HOST_DIR/keys/jeda-mbp.pub"
cp -p "$SIGNING_DIR/public.pem" "$HOST_DIR/keys/bootstrap-artifacts-signing.pub"

# The disposable fixture gets its own artifact trust anchor. Synchronization
# must update both the top-level verifier and embedded launcher before either
# release is signed.
replace_embedded_signing_key
cp -p "$HOST_DIR/bootstrap.sh" "$HOST_DIR/bootstrap-1.3.1.sh"
rm -f "$HOST_DIR/artifact-manifest.txt" "$HOST_DIR/artifact-manifest.sig"

echo 'Creating a signed baseline with the old host key...'
(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$SIGNING_DIR/private.pem" \
        scripts/start-sh-release.sh manifest 1.3.1 >/dev/null
)

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name rotation-test
git -C "$FIXTURE" config user.email rotation-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44
git -C "$FIXTURE" commit -q --no-verify -m baseline

for relative in \
    hosts/ex44/keys/jedarden.pub \
    hosts/ex44/keys/jeda-mbp.pub \
    hosts/ex44/start.sh \
    hosts/ex44/bootstrap.sh \
    hosts/ex44/start.sh.version \
    hosts/ex44/bootstrap-1.3.2.sh \
    hosts/ex44/artifact-manifest.txt \
    hosts/ex44/artifact-manifest.sig; do
    record_digest "$relative"
done

cat > "$AUTHORIZED_KEYS" <<EOF
$(<"$STABLE_PUBLIC")
$(<"$ROTATING_OLD_PUBLIC")
EOF
chmod 600 "$AUTHORIZED_KEYS"
chmod 600 "$TMP/stable" "$TMP/rotating-old" "$TMP/rotating-new"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/host-key" 2>/dev/null
cat > "$SSHD_CONFIG" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $TMP/host-key
PidFile $TMP/sshd.pid
AuthorizedKeysFile $AUTHORIZED_KEYS
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
UsePAM no
PermitRootLogin no
AllowUsers $LOGIN_USER
# The authorized_keys fixture is outside the login user's home below /tmp;
# production uses the normal StrictModes-safe ~/.ssh/authorized_keys path.
StrictModes no
X11Forwarding no
PrintMotd no
UseDNS no
LogLevel ERROR
EOF

start_sshd
echo 'Checking approved access before the rotation...'
expect_ssh_success 'unchanged fallback key was not authorized before rotation' "$STABLE_PRIVATE"
expect_ssh_success 'old rotating key was not authorized before rotation' "$ROTATING_OLD_PRIVATE"

echo 'Replacing the host-specific key input and regenerating the signed release...'
cp -p "$ROTATING_NEW_PUBLIC" "$HOST_DIR/keys/jeda-mbp.pub"
(
    cd "$FIXTURE"
    ARTIFACT_SIGNING_KEY="$SIGNING_DIR/private.pem" \
        scripts/start-sh-release.sh release 1.3.2 >/dev/null
    scripts/start-sh-release.sh --check >/dev/null
)

for relative in \
    hosts/ex44/keys/jeda-mbp.pub \
    hosts/ex44/start.sh \
    hosts/ex44/bootstrap.sh \
    hosts/ex44/start.sh.version \
    hosts/ex44/bootstrap-1.3.2.sh \
    hosts/ex44/artifact-manifest.txt \
    hosts/ex44/artifact-manifest.sig; do
    assert_changed "$relative"
done

new_key_digest=$(sha256sum "$HOST_DIR/keys/jeda-mbp.pub" | awk '{print $1}')
grep -Fxq "artifact=keys/jeda-mbp.pub $new_key_digest" \
    "$HOST_DIR/artifact-manifest.txt" ||
    fail 'signed manifest does not contain the rotated SSH-key digest'
grep -Fq "$(<"$ROTATING_OLD_PUBLIC")" "$HOST_DIR/keys/jeda-mbp.pub" &&
    fail 'rotated host input still contains the old public key'

signature_bin="$TMP/manifest.sig.bin"
sed -n 's/^signature=//p' "$HOST_DIR/artifact-manifest.sig" |
    base64 --decode > "$signature_bin" 2>/dev/null ||
    fail 'rotated manifest signature is not valid base64'
openssl dgst -sha256 -verify "$HOST_DIR/keys/bootstrap-artifacts-signing.pub" \
    -signature "$signature_bin" "$HOST_DIR/artifact-manifest.txt" >/dev/null 2>&1 ||
    fail 'rotated manifest signature does not verify'

if grep -R --binary-files=without-match -Fq 'BEGIN OPENSSH PRIVATE KEY' "$FIXTURE"; then
    fail 'private SSH key material appeared in the release fixture'
fi

# Model the authenticated bootstrap write from the new signed host inputs.
# Keep the server and the already-approved session alive while this happens.
write_authorized_keys_from_host_inputs
echo 'Checking access after the rotation...'
expect_ssh_success 'unchanged fallback access was lost during rotation' "$STABLE_PRIVATE"
expect_ssh_success 'replacement SSH key was not authorized after rotation' "$ROTATING_NEW_PRIVATE"
expect_ssh_failure 'retired SSH key remains authorized after rotation' "$ROTATING_OLD_PRIVATE"
grep -Fq "$(<"$STABLE_PUBLIC")" "$AUTHORIZED_KEYS" ||
    fail 'authorized_keys lost the unchanged fallback key'
grep -Fq "$(<"$ROTATING_NEW_PUBLIC")" "$AUTHORIZED_KEYS" ||
    fail 'authorized_keys is missing the replacement key'
if grep -Fq "$(<"$ROTATING_OLD_PUBLIC")" "$AUTHORIZED_KEYS"; then
    fail 'authorized_keys still contains the retired key'
fi
[[ "$(stat -c '%a' "$AUTHORIZED_KEYS")" == 600 ]] ||
    fail 'authorized_keys permissions changed during rotation'

echo 'SSH public-key rotation acceptance tests passed.'
