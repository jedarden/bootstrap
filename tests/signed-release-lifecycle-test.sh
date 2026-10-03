#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the documented signed-release lifecycle as one disposable flow:
# prepare and sign a release, fetch it over HTTPS, authenticate it before the
# clean-host boundary, bootstrap that downloaded archive, self-update the
# deployed launcher, and publish a higher-version rollback release.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${BOOTSTRAP_LIFECYCLE_TEST_IMAGE:-debian:12-slim}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-signed-lifecycle.XXXXXX")
FIXTURE="$TMP/repository"
RAW_ROOT="$TMP/raw"
TLS_DIR="$TMP/tls"
SIGNING_DIR="$TMP/signing"
VERIFIED_REPO="$FIXTURE/verified"
FORGEJO_BARE="$TMP/forgejo.git"
GITHUB_BARE="$TMP/github.git"
GOOD_START="$TMP/good-start.sh"
MUTATION_MARKER="$TMP/host-mutation.marker"
CONTAINER="bootstrap-signed-lifecycle-${PPID}-${RANDOM}"
SERVER_PID=
RELEASE_VERSION=1.3.2
ROLLBACK_VERSION=1.3.4

cleanup() {
    local exit_code=$?
    if [[ -n "${SERVER_PID:-}" ]]; then
        kill "$SERVER_PID" >/dev/null 2>&1 || true
        wait "$SERVER_PID" >/dev/null 2>&1 || true
    fi
    if [[ ${BOOTSTRAP_LIFECYCLE_TEST_KEEP:-false} == true ]]; then
        echo "Keeping lifecycle fixture at $TMP and container $CONTAINER" >&2
    else
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        rm -rf "$TMP"
    fi
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
    if [[ ${BOOTSTRAP_LIFECYCLE_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        echo 'signed release lifecycle tests require a reachable Docker daemon' >&2
        exit 2
    fi
    echo 'SKIP: signed release lifecycle tests require a reachable Docker daemon' >&2
    exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable test image $IMAGE..."
    docker pull "$IMAGE" >/dev/null
fi

mkdir -p \
    "$FIXTURE/scripts" \
    "$FIXTURE/hosts/ex44/keys" \
    "$FIXTURE/tests/integration" \
    "$RAW_ROOT" \
    "$TLS_DIR" \
    "$SIGNING_DIR"

# Reserve the HTTPS port before embedding the raw endpoint in the generated
# release. The short gap before the server starts is confined to loopback.
HTTPS_PORT=$(python3 - <<'PY'
import socket

with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
)
RAW_BASE="https://127.0.0.1:${HTTPS_PORT}"
RAW_RELEASE_BASE="$RAW_BASE/release/hosts/ex44"

openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj /CN=127.0.0.1 \
    -addext subjectAltName=IP:127.0.0.1 \
    -keyout "$TLS_DIR/server.key" \
    -out "$TLS_DIR/server.crt" >/dev/null 2>&1

openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$SIGNING_DIR/private.pem" 2>/dev/null
openssl pkey -in "$SIGNING_DIR/private.pem" -pubout \
    -out "$SIGNING_DIR/public.pem" 2>/dev/null
export ARTIFACT_SIGNING_KEY="$SIGNING_DIR/private.pem"

cp -p "$ROOT/README.md" "$FIXTURE/"
cp -p "$ROOT/scripts/"*.sh "$FIXTURE/scripts/"
cp -p \
    "$ROOT/hosts/ex44/bootstrap.sh" \
    "$ROOT/hosts/ex44/start.sh" \
    "$ROOT/hosts/ex44/sync-start-sh.sh" \
    "$ROOT"/hosts/ex44/bootstrap-1.0.*.sh \
    "$ROOT"/hosts/ex44/bootstrap-1.1.*.sh \
    "$ROOT/hosts/ex44/bootstrap-1.3.1.sh" \
    "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/start.sh.version" "$FIXTURE/hosts/ex44/"
cp -p "$ROOT/hosts/ex44/keys/"*.pub "$FIXTURE/hosts/ex44/keys/"
cp -p "$SIGNING_DIR/public.pem" \
    "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub"
cp -p "$ROOT/tests/integration/host-fixture.sh" \
    "$FIXTURE/tests/integration/"

# This end-to-end scenario deliberately starts at 1.3.1, publishes 1.3.2,
# injects a bad 1.3.3, and recovers forward to 1.3.4. Normalize only the
# disposable canonical files and omit future real archives so that sequence
# stays stable when the production release advances.
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

python3 - "$FIXTURE/hosts/ex44/start.sh" "$SIGNING_DIR/public.pem" \
    "$RAW_RELEASE_BASE" <<'PY'
import pathlib
import sys

start_path = pathlib.Path(sys.argv[1])
public_key = pathlib.Path(sys.argv[2]).read_text()
raw_base = sys.argv[3]
text = start_path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
replacement = begin + public_key + end
start = text.index(begin)
finish = text.index(end, start) + len(end)
text = text[:start] + replacement + text[finish:]
lines = text.splitlines(keepends=True)
for index, line in enumerate(lines):
    if line.startswith("REPO_URL="):
        lines[index] = f'REPO_URL="{raw_base}"\n'
        break
else:
    raise SystemExit("start.sh is missing REPO_URL")
start_path.write_text("".join(lines))
PY

(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)

# sync-start-sh.sh propagates the canonical launcher URL to bootstrap.sh's
# top-level verifier, so the initial bootstrap and installed launcher use the
# same HTTPS fixture.
python3 - "$FIXTURE/hosts/ex44/bootstrap.sh" "$RAW_RELEASE_BASE" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
raw_base = sys.argv[2]
text = path.read_text()
expected = f'REPO_URL="{raw_base}"'
prefix = text.split('    cat > "/home/$user/start.sh" << \'STARTSH\'\n', 1)[0]
if prefix.count(expected) != 1:
    raise SystemExit("bootstrap.sh has the wrong top-level REPO_URL")
PY

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name lifecycle-test
git -C "$FIXTURE" config user.email lifecycle-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts tests
git -C "$FIXTURE" commit -q --no-verify -m base

echo 'Preparing and signing the forward release...'
(cd "$FIXTURE" && scripts/start-sh-release.sh release "$RELEASE_VERSION" >/dev/null)
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)
(cd "$FIXTURE" && scripts/check-host-parity.sh --live >/dev/null)
cp -p "$FIXTURE/hosts/ex44/start.sh" "$GOOD_START"

git -C "$FIXTURE" add hosts/ex44
(cd "$FIXTURE" && scripts/check-host-parity.sh --staged >/dev/null)
git -C "$FIXTURE" commit -q --no-verify -m "release: forward lifecycle fixture"

serve_raw_artifacts() {
    local destination=$1
    rm -rf "$destination"
    mkdir -p "$destination"
    cp -a "$FIXTURE/hosts" "$destination/"
}

serve_raw_artifacts "$RAW_ROOT/release"

python3 - "$RAW_ROOT" "$HTTPS_PORT" "$TLS_DIR/server.crt" "$TLS_DIR/server.key" \
    >"$TMP/https-server.log" 2>&1 <<'PY' &
import http.server
import pathlib
import ssl
import sys
import urllib.parse

root = pathlib.Path(sys.argv[1]).resolve()
port = int(sys.argv[2])
certificate = sys.argv[3]
private_key = sys.argv[4]

class RawHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        relative = urllib.parse.unquote(urllib.parse.urlsplit(self.path).path).lstrip("/")
        path = (root / relative).resolve()
        if root not in path.parents or not path.is_file():
            self.send_error(404)
            return
        body = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", port), RawHandler)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(certificate, private_key)
server.socket = context.wrap_socket(server.socket, server_side=True)
print("ready", flush=True)
server.serve_forever()
PY
SERVER_PID=$!
for _ in {1..100}; do
    grep -Fxq ready "$TMP/https-server.log" && break
    kill -0 "$SERVER_PID" 2>/dev/null || {
        cat "$TMP/https-server.log" >&2
        fail 'raw HTTPS server exited before becoming ready'
    }
    sleep 0.05
done
grep -Fxq ready "$TMP/https-server.log" || fail 'raw HTTPS server did not become ready'
export CURL_CA_BUNDLE="$TLS_DIR/server.crt"

download_release() {
    local base=$1 version=$2 destination=$3 filename
    mkdir -p "$destination/keys"
    for filename in \
        bootstrap.sh \
        "bootstrap-$version.sh" \
        artifact-manifest.txt \
        artifact-manifest.sig \
        keys/bootstrap-artifacts-signing.pub \
        keys/jedarden.pub \
        keys/jeda-mbp.pub; do
        mkdir -p "$destination/$(dirname "$filename")"
        curl --fail --silent --show-error --location \
            "$base/$filename" > "$destination/$filename" || return 1
    done
}

verify_downloaded_release() {
    local base=$1 version=$2 destination=$3
    local signature_bin expected actual current_expected current_actual downloaded_fingerprint
    local manifest_key signature_key

    rm -rf "$destination"
    if ! download_release "$base" "$version" "$destination"; then
        return 1
    fi

    downloaded_fingerprint=$(openssl pkey -pubin \
        -in "$destination/keys/bootstrap-artifacts-signing.pub" \
        -outform DER | sha256sum | awk '{print $1}')
    [[ "$downloaded_fingerprint" == "$PINNED_FINGERPRINT" ]] || return 1
    grep -Fxq "format=bootstrap-artifact-manifest-v1" \
        "$destination/artifact-manifest.txt" || return 1
    grep -Fxq "version=$version" "$destination/artifact-manifest.txt" || return 1

    manifest_key=$(sed -n 's/^key_id=//p' "$destination/artifact-manifest.txt")
    signature_key=$(sed -n 's/^key_id=//p' "$destination/artifact-manifest.sig")
    [[ -n "$manifest_key" && "$manifest_key" == "$signature_key" ]] || return 1

    signature_bin="$destination/manifest.sig.bin"
    sed -n 's/^signature=//p' "$destination/artifact-manifest.sig" |
        base64 --decode > "$signature_bin" 2>/dev/null || return 1
    openssl dgst -sha256 \
        -verify "$destination/keys/bootstrap-artifacts-signing.pub" \
        -signature "$signature_bin" \
        "$destination/artifact-manifest.txt" >/dev/null 2>&1 || return 1

    expected=$(awk -v artifact="bootstrap-$version.sh" \
        '$1 == "artifact=" artifact {print $2}' \
        "$destination/artifact-manifest.txt")
    [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    actual=$(sha256sum "$destination/bootstrap-$version.sh" | awk '{print $1}')
    [[ "$actual" == "$expected" ]] || return 1
    bash -n "$destination/bootstrap-$version.sh"

    current_expected=$(awk '$1 == "artifact=bootstrap.sh" {print $2}' \
        "$destination/artifact-manifest.txt")
    [[ "$current_expected" =~ ^[0-9a-f]{64}$ ]] || return 1
    current_actual=$(sha256sum "$destination/bootstrap.sh" | awk '{print $1}')
    [[ "$current_actual" == "$current_expected" ]] || return 1
    cmp -s "$destination/bootstrap.sh" "$destination/bootstrap-$version.sh" || return 1
    bash -n "$destination/bootstrap.sh"
}

PINNED_FINGERPRINT=$(openssl pkey -pubin \
    -in "$FIXTURE/hosts/ex44/keys/bootstrap-artifacts-signing.pub" \
    -outform DER | sha256sum | awk '{print $1}')

echo 'Checking tampered and incomplete artifacts before host execution...'
cp -a "$RAW_ROOT/release" "$RAW_ROOT/tampered"
printf '# tampered release archive\n' >> \
    "$RAW_ROOT/tampered/hosts/ex44/bootstrap-$RELEASE_VERSION.sh"
if verify_downloaded_release "$RAW_BASE/tampered/hosts/ex44" "$RELEASE_VERSION" \
    "$TMP/tampered-download" >/dev/null 2>&1; then
    fail 'tampered archive passed raw-HTTPS verification'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'tampered artifact changed the host before verification failed'

cp -a "$RAW_ROOT/release" "$RAW_ROOT/current-tampered"
printf '# tampered current bootstrap\n' >> \
    "$RAW_ROOT/current-tampered/hosts/ex44/bootstrap.sh"
if verify_downloaded_release "$RAW_BASE/current-tampered/hosts/ex44" "$RELEASE_VERSION" \
    "$TMP/current-tampered-download" >/dev/null 2>&1; then
    fail 'tampered current bootstrap passed raw-HTTPS verification'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'tampered current bootstrap changed the host before verification failed'

cp -a "$RAW_ROOT/release" "$RAW_ROOT/manifest-tampered"
sed -i 's/^version=1\.3\.2$/version=9.9.9/' \
    "$RAW_ROOT/manifest-tampered/hosts/ex44/artifact-manifest.txt"
if verify_downloaded_release "$RAW_BASE/manifest-tampered/hosts/ex44" "$RELEASE_VERSION" \
    "$TMP/manifest-tampered-download" >/dev/null 2>&1; then
    fail 'tampered manifest passed raw-HTTPS verification'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'tampered manifest changed the host before verification failed'

cp -a "$RAW_ROOT/release" "$RAW_ROOT/incomplete"
rm "$RAW_ROOT/incomplete/hosts/ex44/artifact-manifest.sig"
if verify_downloaded_release "$RAW_BASE/incomplete/hosts/ex44" "$RELEASE_VERSION" \
    "$TMP/incomplete-download" >/dev/null 2>&1; then
    fail 'incomplete release passed raw-HTTPS verification'
fi
[[ ! -e "$MUTATION_MARKER" ]] || fail 'incomplete artifact changed the host before verification failed'

VALID_DOWNLOAD="$TMP/valid-download"
verify_downloaded_release "$RAW_RELEASE_BASE" "$RELEASE_VERSION" "$VALID_DOWNLOAD" ||
    fail 'generated release failed raw-HTTPS verification'
[[ ! -e "$MUTATION_MARKER" ]] || fail 'verification mutated the host before bootstrap execution'

sync_verified_source() {
    local download_dir=$1 version=$2
    rm -rf "$VERIFIED_REPO"
    mkdir -p "$VERIFIED_REPO"
    cp -a "$FIXTURE/hosts" "$VERIFIED_REPO/"
    cp -p "$download_dir/bootstrap.sh" \
        "$VERIFIED_REPO/hosts/ex44/"
    cp -p "$download_dir/bootstrap-$version.sh" \
        "$VERIFIED_REPO/hosts/ex44/"
    cp -p "$download_dir/artifact-manifest.txt" \
        "$VERIFIED_REPO/hosts/ex44/"
    cp -p "$download_dir/artifact-manifest.sig" \
        "$VERIFIED_REPO/hosts/ex44/"
    cp -p "$download_dir/keys/"*.pub "$VERIFIED_REPO/hosts/ex44/keys/"
}

sync_verified_source "$VALID_DOWNLOAD" "$RELEASE_VERSION"

echo 'Bootstrapping a clean disposable host from the verified archive...'
docker run --detach --name "$CONTAINER" \
    --network host \
    --privileged \
    --cap-add=ALL \
    --security-opt seccomp=unconfined \
    --volume "$FIXTURE:/src:ro" \
    --volume "$TLS_DIR:/cert:ro" \
    --env CURL_CA_BUNDLE=/cert/server.crt \
    "$IMAGE" sleep infinity >/dev/null

docker exec "$CONTAINER" bash -ceu \
    'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq; apt-get install -y -qq curl openssl ca-certificates >/dev/null'
docker exec "$CONTAINER" bash /src/tests/integration/host-fixture.sh \
    /src/verified/hosts/ex44/bootstrap-"$RELEASE_VERSION".sh
docker exec -i "$CONTAINER" bash -s <<'CONTAINER_SCRIPT'
set -Eeuo pipefail
rm -f /usr/local/bin/curl
cp -p /usr/local/lib/bootstrap-test/command-shim /tmp/curl
cat > /usr/local/bin/curl <<'CURL_WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
    case "$argument" in
        https://127.0.0.1:*)
            exec /usr/bin/curl "$@"
            ;;
    esac
done
exec /tmp/curl "$@"
CURL_WRAPPER
chmod +x /usr/local/bin/curl
CONTAINER_SCRIPT

bootstrap_input="$TMP/bootstrap-input"
printf '%s\n' \
    bootstrap-test \
    '' \
    '' \
    '' \
    '' \
    '' \
    lifecycle-auth \
    '' > "$bootstrap_input"
bootstrap_output="$TMP/bootstrap-output"
bootstrap_command=$(printf '%q ' \
    docker exec -it \
    -e CURL_CA_BUNDLE=/cert/server.crt \
    "$CONTAINER" bash -c 'stty -echo; exec bash /test/bootstrap-under-test.sh')
if ! script -qefc "stty -echo; $bootstrap_command" /dev/null \
    < "$bootstrap_input" > "$bootstrap_output" 2>&1; then
    cat "$bootstrap_output" >&2
    fail 'clean-host bootstrap failed'
fi
grep -Fq '=== Bootstrap Complete' "$bootstrap_output" || {
    cat "$bootstrap_output" >&2
    fail 'clean-host bootstrap did not report completion'
}
touch "$MUTATION_MARKER"

echo 'Checking launcher self-update from the clean host...'
docker exec "$CONTAINER" bash -ceu \
    'sed -i "s/^START_SH_VERSION=\"1\.3\.2\"$/START_SH_VERSION=\"1\.3\.1\"/" /home/coding/start.sh'
launcher_output="$TMP/launcher-output"
if ! docker exec -i -u coding \
    -e HOME=/home/coding \
    -e PATH=/home/coding/.local/bin:/usr/local/bin:/usr/bin:/bin \
    -e HERDR_ENV=signed-lifecycle \
    -e CURL_CA_BUNDLE=/cert/server.crt \
    "$CONTAINER" /home/coding/start.sh --agent claude >"$launcher_output" 2>&1; then
    cat "$launcher_output" >&2
    fail 'launcher self-update invocation failed'
fi
grep -Fq 'Updating start.sh: 1.3.1 -> 1.3.2' "$launcher_output" ||
    fail 'launcher did not authenticate and apply the forward self-update'
grep -Fq 'claude 1.0.0' "$launcher_output" ||
    fail 'launcher did not continue after self-update'
docker exec "$CONTAINER" grep -Fxq \
    'START_SH_VERSION="1.3.2"' /home/coding/start.sh ||
    fail 'launcher self-update did not install the signed forward release'
docker exec "$CONTAINER" cmp -s \
    /home/coding/start.sh /src/verified/hosts/ex44/start.sh ||
    fail 'clean-host launcher differs from the verified forward release'

echo 'Preparing a bad forward release and rolling it back at a higher version...'
printf '\n# lifecycle bad release fixture\n' >> "$FIXTURE/hosts/ex44/start.sh"
(cd "$FIXTURE/hosts/ex44" && ./sync-start-sh.sh >/dev/null)
(cd "$FIXTURE" && scripts/start-sh-release.sh release 1.3.3 >/dev/null)
git -C "$FIXTURE" add hosts/ex44
(cd "$FIXTURE" && scripts/check-host-parity.sh --staged >/dev/null)
git -C "$FIXTURE" commit -q --no-verify -m "release: bad lifecycle fixture"

(cd "$FIXTURE" && scripts/start-sh-release.sh rollback HEAD~1 "$ROLLBACK_VERSION" >/dev/null)
expected_rollback_start="$TMP/expected-rollback-start.sh"
sed -E 's/^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$/START_SH_VERSION="1.3.4"/' \
    "$GOOD_START" > "$expected_rollback_start"
cmp -s "$expected_rollback_start" "$FIXTURE/hosts/ex44/start.sh" ||
    fail 'rollback did not restore the known-good launcher payload'
! grep -Fq 'lifecycle bad release fixture' "$FIXTURE/hosts/ex44/start.sh" ||
    fail 'rollback retained the bad release payload'
(cd "$FIXTURE" && scripts/start-sh-release.sh --check >/dev/null)
(cd "$FIXTURE" && scripts/check-host-parity.sh --live >/dev/null)
git -C "$FIXTURE" add hosts/ex44
(cd "$FIXTURE" && scripts/check-host-parity.sh --staged >/dev/null)
git -C "$FIXTURE" commit -q --no-verify -m "rollback: restore lifecycle fixture"

serve_raw_artifacts "$RAW_ROOT/release"
FINAL_DOWNLOAD="$TMP/final-download"
verify_downloaded_release "$RAW_RELEASE_BASE" "$ROLLBACK_VERSION" "$FINAL_DOWNLOAD" ||
    fail 'generated rollback release failed raw-HTTPS verification'
sync_verified_source "$FINAL_DOWNLOAD" "$ROLLBACK_VERSION"

git init --bare -q "$FORGEJO_BARE"
git init --bare -q "$GITHUB_BARE"
git -C "$FIXTURE" remote add origin "$FORGEJO_BARE"
git --git-dir="$FORGEJO_BARE" config core.hooksPath "$FORGEJO_BARE/hooks"
cat > "$FORGEJO_BARE/hooks/post-receive" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE
while read -r oldrev newrev ref; do
    [[ "\$ref" == refs/heads/main ]] || continue
    git -C "$FIXTURE" push -q "$GITHUB_BARE" "\$newrev:refs/heads/main"
done
HOOK
chmod +x "$FORGEJO_BARE/hooks/post-receive"

echo 'Publishing and checking the rollback distribution path...'
(
    cd "$FIXTURE"
    FORGEJO_REMOTE=origin \
    GITHUB_REPO_URL="$GITHUB_BARE" \
    GITHUB_RAW_ROOT="$RAW_RELEASE_BASE" \
    DISTRIBUTION_TIMEOUT_SECONDS=5 \
    DISTRIBUTION_POLL_SECONDS=0 \
    scripts/start-sh-release.sh publish >/dev/null
)
(
    cd "$FIXTURE"
    FORGEJO_REMOTE=origin \
    GITHUB_REPO_URL="$GITHUB_BARE" \
    GITHUB_RAW_ROOT="$RAW_RELEASE_BASE" \
    DISTRIBUTION_TIMEOUT_SECONDS=5 \
    DISTRIBUTION_POLL_SECONDS=0 \
    scripts/start-sh-release.sh distribution-check >/dev/null
)
[[ -z "$(git -C "$FIXTURE" rev-list origin/main..HEAD)" ]] ||
    fail 'rollback publish left the Forgejo remote behind HEAD'
[[ "$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/main)" == \
    "$(git -C "$FIXTURE" rev-parse HEAD)" ]] ||
    fail 'rollback publish did not update the mirrored GitHub commit'

echo 'Checking launcher self-update to the signed rollback release...'
launcher_output="$TMP/rollback-launcher-output"
if ! docker exec -i -u coding \
    -e HOME=/home/coding \
    -e PATH=/home/coding/.local/bin:/usr/local/bin:/usr/bin:/bin \
    -e HERDR_ENV=signed-lifecycle \
    -e CURL_CA_BUNDLE=/cert/server.crt \
    "$CONTAINER" /home/coding/start.sh --agent claude >"$launcher_output" 2>&1; then
    cat "$launcher_output" >&2
    fail 'launcher rollback update invocation failed'
fi
grep -Fq 'Updating start.sh: 1.3.2 -> 1.3.4' "$launcher_output" ||
    fail 'launcher did not authenticate and apply the rollback self-update'
grep -Fq 'claude 1.0.0' "$launcher_output" ||
    fail 'launcher did not continue after rollback update'
docker exec "$CONTAINER" grep -Fxq \
    'START_SH_VERSION="1.3.4"' /home/coding/start.sh ||
    fail 'launcher did not install the signed rollback release'
docker exec "$CONTAINER" cmp -s \
    /home/coding/start.sh /src/verified/hosts/ex44/start.sh ||
    fail 'clean-host launcher differs from the verified rollback release'

echo 'signed release lifecycle tests passed.'
