#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the documented clean-host recovery path as one disposable flow.
# The operator-side SOPS/age tools stay outside the container; the container
# receives only the two application secrets for the one bootstrap process.
# The restic fixture models the surviving B2 repository and its latest
# snapshot, while the bootstrap itself remains the production script.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
HOST_DIR="$ROOT/hosts/ex44"
IMAGE=${BOOTSTRAP_RECOVERY_TEST_IMAGE:-debian:12-slim}
SOPS_BIN=${SOPS_BIN:-sops}
AGE_KEYGEN_BIN=${AGE_KEYGEN_BIN:-age-keygen}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-disaster-recovery.XXXXXX")
CONTAINER="bootstrap-disaster-recovery-${PPID}-${RANDOM}"
DOWNLOAD="$TMP/download"
SEED="$TMP/restic-seed"
PRIMARY_IDENTITY="$TMP/primary-identity.txt"
RECOVERY_IDENTITY="$TMP/recovery-identity.txt"
RECOVERY_CIPHER="$TMP/bootstrap.sops.env"
RECOVERY_PLAIN="$TMP/bootstrap.env"
RECOVERY_RECIPIENT="$TMP/recovery-recipient.txt"
PRIMARY_RECIPIENT="$TMP/primary-recipient.txt"
RECOVERY_RECIPIENTS="$TMP/recipients.txt"
SERVER_OUTPUT="$TMP/bootstrap-output"
CONTAINER_STARTED=false

cleanup() {
    local exit_code=$?
    if [[ "$CONTAINER_STARTED" == true ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
    rm -rf "$TMP"
    return "$exit_code"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

docker_is_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

if ! docker_is_available; then
    if [[ ${BOOTSTRAP_RECOVERY_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        echo 'clean-host disaster-recovery tests require a reachable Docker daemon' >&2
        exit 2
    fi
    echo 'SKIP: clean-host disaster-recovery tests require a reachable Docker daemon' >&2
    exit 0
fi

for tool in "$SOPS_BIN" "$AGE_KEYGEN_BIN" openssl sha256sum; do
    command -v "$tool" >/dev/null 2>&1 || {
        if [[ ${BOOTSTRAP_RECOVERY_TEST_REQUIRE_TOOLS:-false} == true ]]; then
            fail "required recovery tool is unavailable: $tool"
        fi
        echo "SKIP: clean-host disaster-recovery tests require $tool" >&2
        exit 0
    }
done

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable recovery image $IMAGE..."
    docker pull "$IMAGE" >/dev/null
fi

mkdir -p "$DOWNLOAD" "$SEED/home/coding/workspace" "$SEED/tailscale"

version=$(tr -d '\r\n' < "$HOST_DIR/start.sh.version")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    fail 'could not determine the published bootstrap version'

# Copy the same published artifact set an operator downloads. The checks below
# are deliberately performed before the container is created: a bad release
# must never cross the clean-host bootstrap boundary.
for artifact in \
    bootstrap.sh \
    "bootstrap-$version.sh" \
    start.sh \
    start.sh.version \
    artifact-manifest.txt \
    artifact-manifest.sig \
    keys/bootstrap-artifacts-signing.pub \
    keys/jedarden.pub \
    keys/jeda-mbp.pub; do
    mkdir -p "$DOWNLOAD/$(dirname "$artifact")"
    cp -p "$HOST_DIR/$artifact" "$DOWNLOAD/$artifact"
done

manifest_hash() {
    local artifact=$1
    awk -v artifact="$artifact" '$1 == "artifact=" artifact { print $2 }' \
        "$DOWNLOAD/artifact-manifest.txt"
}

verify_artifact() {
    local artifact=$1 expected actual
    expected=$(manifest_hash "$artifact")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] ||
        fail "signed manifest has no digest for $artifact"
    actual=$(sha256sum "$DOWNLOAD/$artifact" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] ||
        fail "signed digest mismatch for $artifact"
}

fingerprint=$(openssl pkey -pubin \
    -in "$DOWNLOAD/keys/bootstrap-artifacts-signing.pub" \
    -outform DER | sha256sum | awk '{print $1}')
[[ "$fingerprint" == \
    a6f26805c65bcd4de965b6d642c6dc5989de1cfa4c7e1b2e9bcb2b94ab28c589 ]] ||
    fail 'published signing-key fingerprint changed unexpectedly'

signature_bin="$TMP/artifact-manifest.sig.bin"
sed -n 's/^signature=//p' "$DOWNLOAD/artifact-manifest.sig" |
    base64 --decode > "$signature_bin" 2>/dev/null ||
    fail 'published artifact signature is not valid base64'
openssl dgst -sha256 -verify "$DOWNLOAD/keys/bootstrap-artifacts-signing.pub" \
    -signature "$signature_bin" "$DOWNLOAD/artifact-manifest.txt" \
    >/dev/null 2>&1 || fail 'published artifact manifest signature failed'
grep -Fxq "version=$version" "$DOWNLOAD/artifact-manifest.txt" ||
    fail 'published artifact manifest version is unexpected'
verify_artifact bootstrap.sh
verify_artifact "bootstrap-$version.sh"
verify_artifact start.sh
verify_artifact start.sh.version
verify_artifact keys/jedarden.pub
verify_artifact keys/jeda-mbp.pub
verify_artifact keys/bootstrap-artifacts-signing.pub
cmp -s "$DOWNLOAD/bootstrap.sh" "$DOWNLOAD/bootstrap-$version.sh" ||
    fail 'current bootstrap.sh differs from the authenticated immutable archive'
bash -n "$DOWNLOAD/bootstrap-$version.sh" ||
    fail 'authenticated bootstrap archive has invalid Bash syntax'
chmod +x "$DOWNLOAD/bootstrap-$version.sh"
echo "Signed bootstrap artifact verified: v$version"

# The snapshot is the data that survives the host loss. It intentionally
# contains only representative user data and persisted Tailscale state; the
# fresh bootstrap recreates the system-owned files around it.
printf '%s\n' 'clean-host disaster-recovery marker' \
    > "$SEED/home/coding/workspace/recovered-marker.txt"
printf '%s\n' 'persisted tailscale state' > "$SEED/tailscale/recovery-state"

# Generate disposable operator-side SOPS material, then make the primary
# identity unavailable before the recovery bootstrap. No identity is copied
# into the container and no decrypted file is mounted there.
umask 077
"$AGE_KEYGEN_BIN" -o "$PRIMARY_IDENTITY" >/dev/null 2>"$TMP/primary-keygen.err"
"$AGE_KEYGEN_BIN" -o "$RECOVERY_IDENTITY" >/dev/null 2>"$TMP/recovery-keygen.err"
chmod 600 "$PRIMARY_IDENTITY" "$RECOVERY_IDENTITY"
"$AGE_KEYGEN_BIN" -y "$PRIMARY_IDENTITY" > "$PRIMARY_RECIPIENT" \
    2>"$TMP/primary-recipient.err"
"$AGE_KEYGEN_BIN" -y "$RECOVERY_IDENTITY" > "$RECOVERY_RECIPIENT" \
    2>"$TMP/recovery-recipient.err"
printf '%s,%s' "$(<"$PRIMARY_RECIPIENT")" "$(<"$RECOVERY_RECIPIENT")" \
    > "$RECOVERY_RECIPIENTS"

fixture_b2_value="recovery-b2-application-key"
fixture_restic_value="recovery-restic-password"
printf 'BOOTSTRAP_B2_APPLICATION_KEY=%s\nBOOTSTRAP_RESTIC_PASSWORD=%s\n' \
    "$fixture_b2_value" "$fixture_restic_value" > "$RECOVERY_PLAIN"
"$SOPS_BIN" encrypt --age "$(<"$RECOVERY_RECIPIENTS")" \
    --input-type dotenv --output-type dotenv "$RECOVERY_PLAIN" \
    > "$RECOVERY_CIPHER" 2>"$TMP/sops-encrypt.err" ||
    fail 'could not create the disposable encrypted recovery input'
rm -f "$RECOVERY_PLAIN" "$PRIMARY_IDENTITY"

docker run --detach \
    --name "$CONTAINER" \
    --privileged \
    --cap-add=ALL \
    --security-opt seccomp=unconfined \
    --volume "$ROOT:/src:ro" \
    --volume "$DOWNLOAD:/download:ro" \
    "$IMAGE" sleep infinity >/dev/null
CONTAINER_STARTED=true

docker exec "$CONTAINER" bash /src/tests/integration/host-fixture.sh \
    "/download/bootstrap-$version.sh" debian >/dev/null

# Seed the simulated remote B2/restic repository after the host fixture has
# initialized the clean machine. The repository marker makes the bootstrap
# choose its restore path instead of creating a new empty repository.
docker exec "$CONTAINER" mkdir -p \
    /var/lib/bootstrap-test/restic-snapshot/home \
    /var/lib/bootstrap-test/restic-snapshot/tailscale
docker cp "$SEED/home/." \
    "$CONTAINER:/var/lib/bootstrap-test/restic-snapshot/home/"
docker cp "$SEED/tailscale/." \
    "$CONTAINER:/var/lib/bootstrap-test/restic-snapshot/tailscale/"
docker exec "$CONTAINER" touch \
    /var/lib/bootstrap-test/restic-repository-created

run_recovery_bootstrap() {
    local input=$1 output=$2 command_string sops_command

    # docker exec -e NAME reads the value from the SOPS-created operator
    # environment. The env -u boundary prevents age/SOPS metadata from being
    # forwarded to the target container.
    printf -v command_string '%q ' \
        env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE -u SOPS_AGE_RECIPIENTS \
        docker exec -it \
        -e BOOTSTRAP_B2_APPLICATION_KEY \
        -e BOOTSTRAP_RESTIC_PASSWORD \
        "$CONTAINER" bash -c 'stty -echo; exec bash /test/bootstrap-under-test.sh'
    printf -v sops_command '%q ' \
        "$SOPS_BIN" exec-env "$RECOVERY_CIPHER" "$command_string"

    if ! SOPS_AGE_KEY_FILE="$RECOVERY_IDENTITY" \
        script -qefc "stty -echo; $sops_command" /dev/null \
        < "$input" > "$output" 2>&1; then
        echo 'recovery bootstrap failed; output follows:' >&2
        cat "$output" >&2
        exit 1
    fi
}

recovery_input="$TMP/recovery-input"
printf '%s\n' \
    bootstrap-test \
    '' \
    test-bucket \
    test-prefix \
    test-account \
    '' \
    tskey-auth-recovery \
    '' \
    y > "$recovery_input"

run_recovery_bootstrap "$recovery_input" "$SERVER_OUTPUT"
grep -Fq 'Using backup secrets supplied by SOPS through the process environment.' \
    "$SERVER_OUTPUT" || fail 'bootstrap did not consume the recovery SOPS input'
grep -Fq 'Restore complete!' "$SERVER_OUTPUT" ||
    fail 'bootstrap did not restore the surviving restic snapshot'
grep -Fq '=== Bootstrap Complete' "$SERVER_OUTPUT" ||
    fail 'clean-host bootstrap did not complete'

assert_container() {
    local description=$1
    shift
    docker exec "$CONTAINER" bash -ceu "$*" || fail "$description"
}

assert_container 'restored user data is readable by coding' \
    "su -s /bin/bash coding -c 'cat /home/coding/workspace/recovered-marker.txt' | grep -Fxq 'clean-host disaster-recovery marker'"
assert_container 'restored Tailscale state survived the rebuild' \
    "grep -Fxq 'persisted tailscale state' /var/lib/tailscale/recovery-state"
assert_container 'restored data has the configured user ownership' \
    "[[ \$(stat -c %U:%G /home/coding/workspace/recovered-marker.txt) == coding:coding ]]"
assert_container 'Tailscale access is available after recovery' \
    "systemctl is-enabled --quiet tailscaled && systemctl is-active --quiet tailscaled && tailscale status | grep -Eq '^100\\.'"
assert_container 'SSH access policy is active after recovery' \
    "sshd -t && sshd -T | grep -Fxq 'passwordauthentication no' && test -s /home/coding/.ssh/authorized_keys"
assert_container 'launcher operates for the recovered user' \
    "su -s /bin/bash coding -c 'HOME=/home/coding PATH=/home/coding/.local/bin:/usr/local/bin:/usr/bin:/bin HERDR_ENV=disaster-recovery /home/coding/start.sh --no-update --agent claude' | grep -Fxq 'claude 1.0.0'"
assert_container 'restic restore helper can list the surviving repository' \
    '/usr/local/bin/list-backups | grep -Fxq abcdef0123456789'
assert_container 'restic credentials are private and configured' \
    '[[ $(stat -c %a /etc/restic/b2.env) == 600 ]] && grep -Fq RESTIC_REPOSITORY /etc/restic/b2.env'
assert_container 'recovery did not install operator SOPS or age material' \
    'private_key_marker="AGE-SECRET-""KEY-"; \
     ! command -v sops && ! command -v age && ! command -v age-keygen && \
     ! find /etc /root /home /tmp /run -xdev -type f -print0 | \
       xargs -0 -r grep -Fq -- "$private_key_marker"'

if grep -Fq -- "$fixture_b2_value" "$SERVER_OUTPUT" ||
    grep -Fq -- "$fixture_restic_value" "$SERVER_OUTPUT"; then
    fail 'recovery SOPS values appeared in bootstrap output'
fi
printf '%s\0' "$fixture_b2_value" "$fixture_restic_value" |
    docker exec -i "$CONTAINER" /usr/local/bin/bootstrap-test-secret-audit ||
    fail 'recovery SOPS values leaked into runtime artifacts'

verify_output="$TMP/verify-output"
docker exec "$CONTAINER" bash /test/bootstrap-under-test.sh --verify \
    > "$verify_output" 2>&1 || {
    cat "$verify_output" >&2
    fail 'bootstrap verification failed immediately after recovery'
}
grep -Fq 'Failed:       0' "$verify_output" ||
    fail 'bootstrap verification reported recovery failures'

echo 'Simulating reboot and checking recovery persistence...'
docker exec "$CONTAINER" /usr/local/bin/bootstrap-test-reboot
assert_container 'restored user data survives reboot' \
    "grep -Fxq 'clean-host disaster-recovery marker' /home/coding/workspace/recovered-marker.txt"
assert_container 'Tailscale remains enabled and active after reboot' \
    'systemctl is-enabled --quiet tailscaled && systemctl is-active --quiet tailscaled && tailscale status | grep -Eq "^100\\."'
assert_container 'launcher remains usable after reboot' \
    "su -s /bin/bash coding -c 'HOME=/home/coding PATH=/home/coding/.local/bin:/usr/local/bin:/usr/bin:/bin HERDR_ENV=disaster-recovery /home/coding/start.sh --no-update --agent claude' | grep -Fxq 'claude 1.0.0'"
docker exec "$CONTAINER" bash /test/bootstrap-under-test.sh --verify \
    > "$TMP/post-reboot-verify-output" 2>&1 || {
    cat "$TMP/post-reboot-verify-output" >&2
    fail 'bootstrap verification failed after reboot'
}
grep -Fq 'Failed:       0' "$TMP/post-reboot-verify-output" ||
    fail 'post-reboot verification reported recovery failures'

echo 'clean-host disaster-recovery workflow passed (signed artifact, recovery SOPS, restic restore, access, launcher, reboot persistence)'
