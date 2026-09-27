#!/usr/bin/env bash
set -Eeuo pipefail

# Run the real EX44 bootstrap twice in one disposable Debian host. This is
# deliberately an installation/idempotence test, not a second implementation
# of bootstrap --verify; the latter is a read-only production check and is
# intentionally not invoked here.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
IMAGE=${BOOTSTRAP_TEST_IMAGE:-debian:12-slim}
KEEP_CONTAINER=false
CONTAINER="bootstrap-integration-${PPID}-${RANDOM}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-integration.XXXXXX")

cleanup() {
    local exit_code=$?
    if [[ "$KEEP_CONTAINER" == false ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    else
        echo "Keeping disposable host: $CONTAINER" >&2
    fi
    rm -rf "$TMP"
    return "$exit_code"
}
trap cleanup EXIT

usage() {
    cat <<'USAGE'
Usage: tests/integration/bootstrap-test.sh [--keep]

Environment:
  BOOTSTRAP_TEST_IMAGE  Debian image to use (default: debian:12-slim)
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP_CONTAINER=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

command -v docker >/dev/null || {
    echo 'bootstrap integration tests require Docker' >&2
    exit 2
}

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable test image $IMAGE..."
    docker pull "$IMAGE"
fi

echo "Starting disposable host $CONTAINER..."
docker run --detach \
    --name "$CONTAINER" \
    --privileged \
    --cap-add=ALL \
    --security-opt seccomp=unconfined \
    --volume "$ROOT:/src:ro" \
    "$IMAGE" sleep infinity >/dev/null

docker exec "$CONTAINER" bash /src/tests/integration/host-fixture.sh \
    /src/hosts/ex44/bootstrap.sh

first_input="$TMP/first-input"
cat > "$first_input" <<'INPUT'
bootstrap-test
coding

test-bucket
test-prefix
test-account

tskey-auth-integration

test-application-key
test-password
test-password
INPUT

second_input="$TMP/second-input"
cat > "$second_input" <<'INPUT'


test-application-key
test-password
test-password

INPUT

run_bootstrap() {
    local label=$1
    local input=$2
    local output="$TMP/$label-output"

    echo "Running bootstrap ($label)..."
    if ! docker exec -i "$CONTAINER" bash /test/bootstrap-under-test.sh \
        < "$input" > "$output" 2>&1; then
        echo "bootstrap failed during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    fi
    grep -Fq '=== Bootstrap Complete' "$output" || {
        echo "bootstrap did not report completion during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    }
}

assert_container() {
    local description=$1
    shift
    if ! docker exec "$CONTAINER" bash -ceu "$*"; then
        echo "ASSERTION FAILED: $description" >&2
        exit 1
    fi
}

assert_file_contains() {
    local description=$1
    local path=$2
    local text=$3
    assert_container "$description" "grep -Fq -- $(printf '%q' "$text") $(printf '%q' "$path")"
}

assert_mode() {
    local description=$1
    local path=$2
    local mode=$3
    assert_container "$description" "[[ \$(stat -c %a '$path') == '$mode' ]]"
}

assert_count() {
    local description=$1
    local expected=$2
    local pattern=$3
    local path=$4
    local quoted_pattern quoted_path
    printf -v quoted_pattern '%q' "$pattern"
    printf -v quoted_path '%q' "$path"
    assert_container "$description" "[[ \$(grep -Fc -- $quoted_pattern $quoted_path) -eq $expected ]]"
}

run_bootstrap first "$first_input"

echo 'Checking first-run host state...'
assert_file_contains 'SSH disables password authentication' \
    /etc/ssh/sshd_config.d/hardening.conf 'PasswordAuthentication no'
assert_file_contains 'SSH restricts root login' \
    /etc/ssh/sshd_config.d/hardening.conf 'PermitRootLogin prohibit-password'
assert_file_contains 'SSH allows the configured user' \
    /etc/ssh/sshd_config.d/hardening.conf 'AllowUsers root coding'
assert_file_contains 'sysctl enables reverse-path filtering' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.conf.all.rp_filter = 1'
assert_file_contains 'sysctl enables SYN cookies' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.tcp_syncookies = 1'
assert_file_contains 'sysctl enables ASLR' \
    /etc/sysctl.d/99-hardening.conf 'kernel.randomize_va_space = 2'
assert_file_contains 'fail2ban enables the SSH jail' \
    /etc/fail2ban/jail.local '[sshd]'
assert_file_contains 'auditd watches identity files' \
    /etc/audit/rules.d/hardening.rules '-w /etc/passwd -p wa -k identity'
assert_container 'fail2ban SSH jail is queryable' \
    "fail2ban-client status sshd | grep -Fq 'Status for the jail: sshd'"
assert_container 'auditd rules are queryable' \
    "auditctl -l | grep -Fq -- '-w /etc/passwd -p wa -k identity'"
assert_file_contains 'backup script is installed' \
    /usr/local/bin/backup-home 'restic backup'
assert_file_contains 'backup schedule is installed' \
    /etc/cron.d/restic-backup '0 3 * * * root /usr/local/bin/backup-home'

assert_container 'UFW is active with a deny-incoming policy and Tailscale rule' \
    "ufw status verbose | grep -Fq 'Status: active' && ufw status verbose | grep -Fq 'Default: deny incoming' && ufw status verbose | grep -Fq tailscale0"
assert_container 'Tailscale is connected' \
    'tailscale status | grep -Eq "^100\\.64\\."'
assert_container 'coding workspace has isolated directories' \
    '[[ -d /home/coding/.tmp && -d /home/coding/.cache && -d /home/coding/workspace ]]'
assert_mode 'coding home is private' /home/coding 700
assert_mode 'authorized keys are private' /home/coding/.ssh/authorized_keys 600
assert_mode 'restic credentials are private' /etc/restic/b2.env 600
assert_file_contains 'restic repository uses the configured prefix' \
    /etc/restic/b2.env 'RESTIC_REPOSITORY="b2:test-bucket:test-prefix/'
assert_container 'rootless Docker has a subuid range' \
    'grep -Eq "^coding:[0-9]+:[0-9]+$" /etc/subuid'
assert_container 'rootless Docker has a user service' \
    '[[ -f /home/coding/.config/systemd/user/docker.service ]]'
assert_container 'rootless runtime directory belongs to coding' \
    '[[ $(stat -c %U:%a /run/user/$(id -u coding)) == coding:700 ]]'
assert_file_contains 'rootless Docker environment is configured' \
    /home/coding/.bashrc '# === Rootless Docker ==='
assert_container 'launcher is exposed on PATH' \
    '[[ -L /home/coding/.local/bin/start && $(readlink /home/coding/.local/bin/start) == /home/coding/start.sh ]]'
assert_container 'rootless Docker helper is executable and user-owned' \
    '[[ -x /home/coding/bin/start-docker && $(stat -c %U /home/coding/bin/start-docker) == coding ]]'
assert_container 'rootless Docker helper reaches the daemon' \
    "su - coding -c /home/coding/bin/start-docker | grep -Fq 'Rootless Docker fixture'"
assert_container 'deployed launcher matches the canonical source' \
    'cmp -s /home/coding/start.sh /src/hosts/ex44/start.sh'
assert_container 'launcher reports its version without starting an agent' \
    "su - coding -c 'HOME=/home/coding /home/coding/.local/bin/start --version' | grep -Fq 'start v'"
assert_count 'workspace setup is not duplicated' 1 '# === Security: Isolated temp directory ===' /home/coding/.bashrc
assert_count 'rootless Docker setup is not duplicated' 1 '# === Rootless Docker ===' /home/coding/.bashrc

# Exercise the generated backup entry point too. The restic double records a
# local repository marker, so this validates the command path without using a
# real B2 account or leaking credentials.
assert_container 'backup-home completes' '/usr/local/bin/backup-home >/dev/null'
assert_container 'list-backups sees the repository' \
    "/usr/local/bin/list-backups | grep -Fq abcdef0123456789"

first_snapshot=$(docker exec "$CONTAINER" /usr/local/bin/bootstrap-test-snapshot)

run_bootstrap second "$second_input"

echo 'Checking second-run convergence...'
second_snapshot=$(docker exec "$CONTAINER" /usr/local/bin/bootstrap-test-snapshot)
if [[ "$first_snapshot" != "$second_snapshot" ]]; then
    echo 'ASSERTION FAILED: normalized host state changed on the second run' >&2
    diff -u <(printf '%s\n' "$first_snapshot") <(printf '%s\n' "$second_snapshot") >&2 || true
    exit 1
fi
assert_count 'second run does not duplicate workspace setup' 1 '# === Security: Isolated temp directory ===' /home/coding/.bashrc
assert_count 'second run does not duplicate rootless Docker setup' 1 '# === Rootless Docker ===' /home/coding/.bashrc
assert_container 'second run keeps one subuid range' \
    '[[ $(grep -Fc "coding:" /etc/subuid) -eq 1 ]]'
assert_container 'second run keeps one shared-memory fstab entry' \
    '[[ $(grep -Fc "tmpfs /run/shm" /etc/fstab) -eq 1 ]]'
assert_container 'second run keeps one temporary-filesystem note' \
    '[[ $(grep -Fc "noexec,nosuid,nodev to /tmp" /etc/fstab) -eq 1 ]]'

echo 'Bootstrap integration and idempotence tests passed.'
