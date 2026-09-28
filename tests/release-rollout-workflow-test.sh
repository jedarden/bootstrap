#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the recurring multi-host release workflow in a disposable fixture:
# staged/live parity, signed version validation, Forgejo/GitHub/raw convergence,
# deployment/version checks for every lineage, and a forward-version rollback.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-rollout-workflow.XXXXXX")
FIXTURE="$TMP/repository"
FORGEJO_BARE="$TMP/forgejo.git"
GITHUB_BARE="$TMP/github.git"
GITHUB_RAW="$TMP/github-raw"
SIGNING_DIR="$TMP/signing"
DEPLOYED="$TMP/deployed"
RELEASE_VERSION=1.3.2
ROLLBACK_VERSION=1.3.3
PUBLIC_KEY="$SIGNING_DIR/public.pem"
PRIVATE_KEY="$SIGNING_DIR/private.pem"

cleanup() {
    local exit_code=$?
    rm -rf "$TMP"
    return "$exit_code"
}
trap cleanup EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_documented() {
    local doc="$ROOT/docs/release-rollout.md"
    [[ -f "$doc" ]] || fail 'release rollout runbook is missing'
    grep -Fq 'Forgejo origin/main = GitHub main = GitHub raw artifacts = deployed host versions' "$doc" ||
        fail 'runbook omits the distribution/deployment invariant'
    grep -Fq './scripts/check-host-parity.sh --live' "$doc" ||
        fail 'runbook omits live parity'
    grep -Fq './scripts/check-host-parity.sh --staged' "$doc" ||
        fail 'runbook omits staged parity'
    grep -Fq 'start-sh-release.sh --host "$host" publish' "$doc" ||
        fail 'runbook omits per-lineage publish'
    grep -Fq 'start-sh-release.sh --host "$host" distribution-check' "$doc" ||
        fail 'runbook omits raw distribution convergence'
    grep -Fq 'start.sh" --no-update --version' "$doc" ||
        fail 'runbook omits deployed version verification'
    grep -Fq 'start-sh-release.sh --host "$host" rollback' "$doc" ||
        fail 'runbook omits forward-version rollback'
    grep -Fq 'KNOWN_GOOD_COMMIT' "$doc" ||
        fail 'runbook omits the known-good rollback commit'
    grep -Fq 'tests/release-rollout-workflow-test.sh' "$doc" ||
        fail 'runbook omits its regression test'
    grep -Fq './docs/release-rollout.md' "$ROOT/README.md" ||
        fail 'README does not link the release rollout runbook'
}

prepare_lineage() {
    local host=$1 host_dir="$FIXTURE/hosts/$1"
    mkdir -p "$host_dir/keys"
    cp -p "$ROOT/hosts/ex44/start.sh" "$ROOT/hosts/ex44/bootstrap.sh" "$ROOT/hosts/ex44/start.sh.version" "$ROOT/hosts/ex44/sync-start-sh.sh" "$host_dir/"
    cp -p "$ROOT"/hosts/ex44/bootstrap-*.sh "$host_dir/"
    cp -p "$ROOT/hosts/ex44/keys/jedarden.pub" "$ROOT/hosts/ex44/keys/jeda-mbp.pub" "$host_dir/keys/"
    cp -p "$PUBLIC_KEY" "$host_dir/keys/bootstrap-artifacts-signing.pub"
    python3 - "$host_dir/start.sh" "$PUBLIC_KEY" "$host" <<'PY'
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
public_key = pathlib.Path(sys.argv[2]).read_text()
host = sys.argv[3]
text = path.read_text()
begin = "ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'\n"
end = "ARTIFACT_KEY\n)"
start = text.index(begin)
finish = text.index(end, start) + len(end)
text = text[:start] + begin + public_key + end + text[finish:]
text = text.replace(
    'REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44"',
    f'REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/{host}"',
)
path.write_text(text)
PY
    (cd "$host_dir" && ./sync-start-sh.sh >/dev/null)
    cp -p "$host_dir/bootstrap.sh" "$host_dir/bootstrap-1.3.1.sh"
}

write_manifest() {
    local host=$1 host_dir="$FIXTURE/hosts/$1" version
    version=$(tr -d '\r\n' < "$host_dir/start.sh.version")
    {
        printf '%s\n' 'format=bootstrap-artifact-manifest-v1'
        printf '%s\n' 'key_id=bootstrap-rsa-2026-09'
        printf 'version=%s\n' "$version"
        for path in bootstrap.sh start.sh start.sh.version keys/jedarden.pub keys/jeda-mbp.pub keys/bootstrap-artifacts-signing.pub; do
            printf 'artifact=%s %s\n' "$path" "$(sha256sum "$host_dir/$path" | awk '{print $1}')"
        done
        find "$host_dir" -maxdepth 1 -type f -name 'bootstrap-*.sh' -printf '%f\n' | sort |
            while IFS= read -r path; do
                printf 'artifact=%s %s\n' "$path" "$(sha256sum "$host_dir/$path" | awk '{print $1}')"
            done
    } > "$host_dir/artifact-manifest.txt"
    openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$TMP/$host-manifest.sig.bin" "$host_dir/artifact-manifest.txt" 2>/dev/null
    {
        printf '%s\n' 'key_id=bootstrap-rsa-2026-09'
        printf 'signature=%s\n' "$(base64 -w0 "$TMP/$host-manifest.sig.bin")"
    } > "$host_dir/artifact-manifest.sig"
}

install_fake_ssh() {
    mkdir -p "$TMP/bin" "$DEPLOYED/ex44" "$DEPLOYED/lab"
    cat > "$TMP/bin/ssh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
target=$1
shift
[[ $# -eq 1 ]] || { echo 'fake ssh expected one remote command' >&2; exit 2; }
case "$target" in
    ex44|lab) ;;
    *) echo "unknown fake SSH target: $target" >&2; exit 2 ;;
esac
export HOME="$DEPLOY_ROOT/$target"
mkdir -p "$HOME"
bash -c "$1"
SH
    chmod +x "$TMP/bin/ssh"
}

rollout_and_verify() {
    local version=$1 host_dir host output
    for host_dir in "$FIXTURE"/hosts/*; do
        host=$(basename "$host_dir")
        output=$(PATH="$TMP/bin:$PATH" DEPLOY_ROOT="$DEPLOYED" ssh "$host" 'set -eu
            tmp=$(mktemp "$HOME/start.sh.XXXXXX")
            cat > "$tmp"
            chmod 0755 "$tmp"
            bash -n "$tmp"
            mv -f "$tmp" "$HOME/start.sh"
            bash -n "$HOME/start.sh"
            "$HOME/start.sh" --no-update --version
        ' < "$host_dir/start.sh")
        [[ "$output" == "start v$version" ]] ||
            fail "$host deployed the wrong version: $output"
    done
    for host in ex44 lab; do
        output=$(HOME="$DEPLOYED/$host" "$DEPLOYED/$host/start.sh" --no-update --version)
        [[ "$output" == "start v$version" ]] ||
            fail "$host post-rollout version check failed: $output"
    done
}

run_parity_and_checks() {
    local version=$1
    (cd "$FIXTURE" && scripts/check-host-parity.sh --live >/dev/null)
    git -C "$FIXTURE" add "hosts/ex44/start.sh" "hosts/ex44/bootstrap.sh" "hosts/ex44/start.sh.version" "hosts/ex44/artifact-manifest.txt" "hosts/ex44/artifact-manifest.sig" "hosts/ex44/bootstrap-$version.sh" "hosts/lab/start.sh" "hosts/lab/bootstrap.sh" "hosts/lab/start.sh.version" "hosts/lab/artifact-manifest.txt" "hosts/lab/artifact-manifest.sig" "hosts/lab/bootstrap-$version.sh"
    (cd "$FIXTURE" && scripts/check-host-parity.sh --staged >/dev/null)
    for host in ex44 lab; do
        (cd "$FIXTURE" && scripts/start-sh-release.sh --host "$host" --check >/dev/null)
    done
    git -C "$FIXTURE" diff --cached --check
}

publish_and_verify_distribution() {
    local host
    for host in ex44 lab; do
        (
            cd "$FIXTURE"
            FORGEJO_REMOTE=origin GITHUB_REPO_URL="$GITHUB_BARE" GITHUB_RAW_ROOT="file://$GITHUB_RAW/$host" DISTRIBUTION_TIMEOUT_SECONDS=5 DISTRIBUTION_POLL_SECONDS=0 scripts/start-sh-release.sh --host "$host" publish >/dev/null
        )
    done
    for host in ex44 lab; do
        (
            cd "$FIXTURE"
            FORGEJO_REMOTE=origin GITHUB_REPO_URL="$GITHUB_BARE" GITHUB_RAW_ROOT="file://$GITHUB_RAW/$host" DISTRIBUTION_TIMEOUT_SECONDS=5 DISTRIBUTION_POLL_SECONDS=0 scripts/start-sh-release.sh --host "$host" distribution-check >/dev/null
        )
    done
    [[ -z "$(git -C "$FIXTURE" rev-list origin/main..HEAD)" ]] ||
        fail 'Forgejo origin is behind the committed release'
    [[ "$(git --git-dir="$GITHUB_BARE" rev-parse refs/heads/main)" == "$(git -C "$FIXTURE" rev-parse HEAD)" ]] ||
        fail 'GitHub mirror does not match Forgejo HEAD'
}

assert_documented
mkdir -p "$FIXTURE/scripts" "$FIXTURE/hosts/ex44" "$FIXTURE/hosts/lab" "$SIGNING_DIR"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" 2>/dev/null
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" 2>/dev/null

cp -p "$ROOT/README.md" "$FIXTURE/README.md"
cp -p "$ROOT/scripts/check-host-parity.sh" "$ROOT/scripts/check-secret-leakage.sh" "$ROOT/scripts/start-sh-release.sh" "$FIXTURE/scripts/"
prepare_lineage ex44
prepare_lineage lab
printf '%s\n' '| [hosts/lab/](./hosts/lab/) | Disposable second release lineage |' >> "$FIXTURE/README.md"
write_manifest ex44
write_manifest lab

git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.name rollout-test
git -C "$FIXTURE" config user.email rollout-test@example.invalid
git -C "$FIXTURE" add README.md scripts hosts/ex44 hosts/lab
git -C "$FIXTURE" commit -q --no-verify -m base
BASE_COMMIT=$(git -C "$FIXTURE" rev-parse HEAD)

git init --bare -q "$FORGEJO_BARE"
git init --bare -q "$GITHUB_BARE"
mkdir -p "$GITHUB_RAW"
git -C "$FIXTURE" remote add origin "$FORGEJO_BARE"
cat > "$FORGEJO_BARE/hooks/post-receive" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
FIXTURE=__FIXTURE__
GITHUB_BARE=__GITHUB_BARE__
GITHUB_RAW=__GITHUB_RAW__
unset GIT_DIR GIT_WORK_TREE
while read -r oldrev newrev ref; do
    [[ "$ref" == refs/heads/main ]] || continue
    git -C "$FIXTURE" push -q "$GITHUB_BARE" "$newrev:refs/heads/main" >/dev/null
    for host in ex44 lab; do
        version=$(git --git-dir="$GITHUB_BARE" show "$newrev:hosts/$host/start.sh.version")
        mkdir -p "$GITHUB_RAW/$host/keys"
        for filename in bootstrap.sh start.sh start.sh.version artifact-manifest.txt artifact-manifest.sig "bootstrap-$version.sh"; do
            git --git-dir="$GITHUB_BARE" show "$newrev:hosts/$host/$filename" > "$GITHUB_RAW/$host/$filename"
        done
        for filename in jedarden.pub jeda-mbp.pub bootstrap-artifacts-signing.pub; do
            git --git-dir="$GITHUB_BARE" show "$newrev:hosts/$host/keys/$filename" > "$GITHUB_RAW/$host/keys/$filename"
        done
    done
done
SH
sed -i "s|__FIXTURE__|$FIXTURE|; s|__GITHUB_BARE__|$GITHUB_BARE|; s|__GITHUB_RAW__|$GITHUB_RAW|" "$FORGEJO_BARE/hooks/post-receive"
chmod +x "$FORGEJO_BARE/hooks/post-receive"
git --git-dir="$FORGEJO_BARE" config core.hooksPath "$FORGEJO_BARE/hooks"
git -C "$FIXTURE" push -q origin HEAD:main

echo 'Preparing the forward release for both lineages...'
for host in ex44 lab; do
    (
        cd "$FIXTURE"
        ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" scripts/start-sh-release.sh --host "$host" release "$RELEASE_VERSION" >/dev/null
    )
done
run_parity_and_checks "$RELEASE_VERSION"
git -C "$FIXTURE" commit -q -m "release"
publish_and_verify_distribution
install_fake_ssh
rollout_and_verify "$RELEASE_VERSION"

echo 'Preparing the forward-version rollback for both lineages...'
for host in ex44 lab; do
    (
        cd "$FIXTURE"
        ARTIFACT_SIGNING_KEY="$PRIVATE_KEY" scripts/start-sh-release.sh --host "$host" rollback "$BASE_COMMIT" "$ROLLBACK_VERSION" >/dev/null
    )
done
run_parity_and_checks "$ROLLBACK_VERSION"
git -C "$FIXTURE" commit -q -m "rollback"
publish_and_verify_distribution
rollout_and_verify "$ROLLBACK_VERSION"

for host in ex44 lab; do
    [[ -f "$FIXTURE/hosts/$host/bootstrap-$RELEASE_VERSION.sh" ]] ||
        fail "$host lost the immutable failed-release archive"
    [[ -f "$FIXTURE/hosts/$host/bootstrap-$ROLLBACK_VERSION.sh" ]] ||
        fail "$host is missing the rollback archive"
done

echo 'multi-host release rollout workflow tests passed.'
