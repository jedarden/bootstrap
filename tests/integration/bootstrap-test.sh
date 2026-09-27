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

assert_user_output() {
    local description=$1
    local user=$2
    local expected=$3
    local command=$4
    local quoted_user quoted_expected quoted_command
    printf -v quoted_user '%q' "$user"
    printf -v quoted_expected '%q' "$expected"
    printf -v quoted_command '%q' "$command"
    assert_container "$description" \
        "su -s /bin/bash $quoted_user -c $quoted_command | grep -Fq -- $quoted_expected"
}

run_bootstrap first "$first_input"

echo 'Checking first-run host state...'
assert_file_contains 'SSH disables password authentication' \
    /etc/ssh/sshd_config.d/hardening.conf 'PasswordAuthentication no'
assert_file_contains 'SSH restricts root login' \
    /etc/ssh/sshd_config.d/hardening.conf 'PermitRootLogin prohibit-password'
assert_file_contains 'SSH allows the configured user' \
    /etc/ssh/sshd_config.d/hardening.conf 'AllowUsers root coding'
assert_container 'effective SSH settings retain the documented key-only posture' \
    "sshd -T | grep -Fxq 'permitrootlogin prohibit-password' && \\
     sshd -T | grep -Fxq 'passwordauthentication no' && \\
     sshd -T | grep -Fxq 'pubkeyauthentication yes' && \\
     sshd -T | grep -Fxq 'authenticationmethods publickey' && \\
     sshd -T | grep -Fxq 'maxauthtries 3'"
assert_container 'effective SSH settings retain the documented forwarding boundaries' \
    "sshd -T | grep -Fxq 'allowusers root coding trading' && \\
     sshd -T | grep -Fxq 'x11forwarding no' && \\
     sshd -T | grep -Fxq 'allowtcpforwarding yes' && \\
     sshd -T | grep -Fxq 'allowagentforwarding no' && \\
     sshd -T | grep -Fxq 'permittunnel no' && \\
     sshd -T | grep -Fxq 'gatewayports no' && \\
     sshd -T | grep -Fxq 'permituserenvironment no'"
assert_file_contains 'sysctl enables reverse-path filtering' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.conf.all.rp_filter = 1'
assert_file_contains 'sysctl applies reverse-path filtering to new interfaces' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.conf.default.rp_filter = 1'
assert_file_contains 'sysctl enables SYN cookies' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.tcp_syncookies = 1'
assert_file_contains 'sysctl enables ASLR' \
    /etc/sysctl.d/99-hardening.conf 'kernel.randomize_va_space = 2'
assert_file_contains 'sysctl disables IPv4 source routing' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.conf.all.accept_source_route = 0'
assert_file_contains 'sysctl disables IPv6 source routing' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv6.conf.all.accept_source_route = 0'
assert_file_contains 'sysctl disables IPv4 redirects' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv4.conf.all.accept_redirects = 0'
assert_file_contains 'sysctl disables IPv6 redirects' \
    /etc/sysctl.d/99-hardening.conf 'net.ipv6.conf.all.accept_redirects = 0'
assert_container 'effective sysctl values are hardened' \
    "[[ \$(sysctl -n net.ipv4.conf.all.rp_filter) == 1 ]] && \\
     [[ \$(sysctl -n net.ipv4.tcp_syncookies) == 1 ]] && \\
     [[ \$(sysctl -n kernel.randomize_va_space) == 2 ]]"
assert_file_contains 'fail2ban enables the SSH jail' \
    /etc/fail2ban/jail.local '[sshd]'
assert_file_contains 'fail2ban uses the documented three-attempt limit' \
    /etc/fail2ban/jail.local 'maxretry = 3'
assert_file_contains 'fail2ban bans through UFW' \
    /etc/fail2ban/jail.local 'banaction = ufw'
assert_file_contains 'auditd watches identity files' \
    /etc/audit/rules.d/hardening.rules '-w /etc/passwd -p wa -k identity'
assert_file_contains 'auditd watches SSH configuration' \
    /etc/audit/rules.d/hardening.rules '-w /etc/ssh/sshd_config.d/ -p wa -k sshd'
assert_file_contains 'auditd watches scheduled jobs' \
    /etc/audit/rules.d/hardening.rules '-w /etc/cron.d/ -p wa -k cron'
assert_container 'fail2ban SSH jail is queryable' \
    "fail2ban-client status sshd | grep -Fq 'Status for the jail: sshd'"
assert_container 'auditd rules are queryable' \
    "auditctl -l | grep -Fq -- '-w /etc/passwd -p wa -k identity' && \\
     auditctl -l | grep -Fq -- '-w /etc/ssh/sshd_config.d/ -p wa -k sshd' && \\
     auditctl -l | grep -Fq -- '-w /etc/cron.d/ -p wa -k cron'"
assert_file_contains 'backup script is installed' \
    /usr/local/bin/backup-home 'restic backup'
assert_file_contains 'backup schedule is installed' \
    /etc/cron.d/restic-backup '0 3 * * * root /usr/local/bin/backup-home'

assert_container 'UFW is active with deny-incoming, allow-outgoing, and Tailscale rules' \
    "ufw status verbose | grep -Fq 'Status: active' && \\
     ufw status verbose | grep -Fq 'Default: deny incoming' && \\
     ufw status verbose | grep -Fq 'Default: allow outgoing' && \\
     ufw status verbose | grep -Fq 'tailscale0' && \\
     ufw status verbose | grep -Fq '213.133.99.0/24' && \\
     ufw status verbose | grep -Fq '88.198.231.0/24'"
assert_container 'Tailscale is connected' \
    'tailscale status | grep -Eq "^100\\.64\\."'
assert_container 'Tailscale identity is available through the JSON status endpoint' \
    "tailscale status --json | grep -Fq 'bootstrap-test.tailnet.ts.net.'"
assert_container 'coding workspace has isolated directories' \
    '[[ -d /home/coding/.tmp && -d /home/coding/.cache && -d /home/coding/workspace ]]'
assert_container 'both configured users have private, user-owned workspaces' \
    'for user in coding trading; do \
         [[ $(stat -c %U:%G:%a /home/$user) == $user:$user:700 ]] && \
         [[ $(stat -c %U:%G /home/$user/.tmp) == $user:$user ]] && \
         [[ $(stat -c %U:%G /home/$user/.cache) == $user:$user ]] && \
         [[ $(stat -c %U:%G /home/$user/workspace) == $user:$user ]] && \
         [[ $(stat -c %a /home/$user/.ssh/authorized_keys) == 600 ]]; \
     done'
assert_container 'workspace trees contain no root-owned files' \
    'for user in coding trading; do \
         ! find /home/$user -xdev ! -user $user -print -quit | grep -q .; \
     done'
assert_mode 'coding home is private' /home/coding 700
assert_mode 'trading home is private' /home/trading 700
assert_mode 'coding authorized keys are private' /home/coding/.ssh/authorized_keys 600
assert_mode 'trading authorized keys are private' /home/trading/.ssh/authorized_keys 600
assert_mode 'restic credentials are private' /etc/restic/b2.env 600
assert_file_contains 'restic repository uses the configured prefix' \
    /etc/restic/b2.env 'RESTIC_REPOSITORY="b2:test-bucket:test-prefix/'
assert_container 'rootless Docker has a subuid range' \
    'grep -Eq "^coding:[0-9]+:[0-9]+$" /etc/subuid && grep -Eq "^trading:[0-9]+:[0-9]+$" /etc/subuid'
assert_container 'rootless Docker has subordinate groups for both users' \
    'grep -Eq "^coding:[0-9]+:[0-9]+$" /etc/subgid && grep -Eq "^trading:[0-9]+:[0-9]+$" /etc/subgid'
assert_container 'rootless Docker has user-owned services and runtime directories' \
    'for user in coding trading; do \
         [[ -f /home/$user/.config/systemd/user/docker.service ]] && \
         [[ $(stat -c %U:%G /home/$user/.config/systemd/user/docker.service) == $user:$user ]] && \
         [[ $(stat -c %U:%a /run/user/$(id -u $user)) == $user:700 ]]; \
     done'
assert_file_contains 'rootless Docker environment is configured' \
    /home/coding/.bashrc '# === Rootless Docker ==='
assert_file_contains 'trading rootless Docker environment is configured' \
    /home/trading/.bashrc '# === Rootless Docker ==='
assert_container 'launcher is exposed on PATH' \
    'for user in coding trading; do \
         [[ -L /home/$user/.local/bin/start ]] && \
         [[ $(readlink /home/$user/.local/bin/start) == /home/$user/start.sh ]]; \
     done'
assert_container 'rootless Docker helpers are executable and user-owned' \
    'for user in coding trading; do \
         [[ -x /home/$user/bin/start-docker ]] && \
         [[ $(stat -c %U:%G /home/$user/bin/start-docker) == $user:$user ]]; \
     done'
for user in coding trading; do
    assert_user_output "$user rootless Docker helper runs unprivileged" \
        "$user" 'Rootless Docker fixture' \
        "/home/$user/bin/start-docker"
done
assert_container 'deployed launcher matches the canonical source' \
    'cmp -s /home/coding/start.sh /src/hosts/ex44/start.sh'
assert_container 'both deployed launchers match the canonical source' \
    'cmp -s /home/coding/start.sh /src/hosts/ex44/start.sh && cmp -s /home/trading/start.sh /src/hosts/ex44/start.sh'
for user in coding trading; do
    assert_user_output "$user can execute start.sh without root" \
        "$user" 'start v' \
        "HOME=/home/$user /home/$user/.local/bin/start --version"
done
for user in coding trading; do
    assert_user_output "$user can execute the launcher through its agent path" \
        "$user" 'claude 1.0.0' \
        "HOME=/home/$user PATH=/home/$user/.local/bin:/usr/local/bin:/usr/bin:/bin HERDR_ENV=security-acceptance /home/$user/start.sh --no-update --agent claude"
done
assert_container 'ownership boundary fixtures are owned by their respective users' \
    'for user in coding trading; do \
         printf %s "$user secret" > /home/$user/workspace/security-acceptance.txt; \
         chown $user:$user /home/$user/workspace/security-acceptance.txt; \
     done'
assert_container 'unprivileged users cannot read each other homes' \
    'for user in coding trading; do \
         other=coding; [[ $user == coding ]] && other=trading; \
         ! su -s /bin/bash $user -c "cat /home/$other/workspace/security-acceptance.txt" 2>/dev/null; \
     done'
assert_container 'unprivileged users can write only their own workspace' \
    'for user in coding trading; do \
         su -s /bin/bash $user -c "printf %s $user >> /home/$user/workspace/security-acceptance.txt"; \
         other=coding; [[ $user == coding ]] && other=trading; \
         ! su -s /bin/bash $user -c "printf x >> /home/$other/workspace/security-acceptance.txt" 2>/dev/null; \
     done'
assert_container 'unprivileged users cannot modify system security state' \
    '! su -s /bin/bash coding -c "printf x >> /etc/ssh/sshd_config.d/hardening.conf" 2>/dev/null && \
     ! su -s /bin/bash trading -c "printf x >> /etc/restic/b2.env" 2>/dev/null'
assert_count 'workspace setup is not duplicated' 1 '# === Security: Isolated temp directory ===' /home/coding/.bashrc
assert_count 'rootless Docker setup is not duplicated' 1 '# === Rootless Docker ===' /home/coding/.bashrc

# Exercise the generated backup and restore entry points too. The restic
# double persists representative /home and Tailscale data locally, so this
# validates a usable round-trip without using a real B2 account or leaking
# credentials.
assert_container 'restore drill fixture is owned by coding' \
    'mkdir -p /home/coding/workspace/restore-drill && printf "restic restore drill\n" > /home/coding/workspace/restore-drill/marker.txt && chown -R coding:coding /home/coding/workspace/restore-drill'
assert_container 'backup-home completes' '/usr/local/bin/backup-home >/dev/null'
assert_container 'list-backups sees the repository' \
    "/usr/local/bin/list-backups | grep -Fq abcdef0123456789"
assert_container 'restore drill source is usable before restore' \
    "su -s /bin/bash coding -c 'cat /home/coding/workspace/restore-drill/marker.txt' | grep -Fxq 'restic restore drill'"
assert_container 'restore drill source is changed before restore' \
    "printf 'tampered data\\n' > /home/coding/workspace/restore-drill/marker.txt"

restore_input="$TMP/restore-input"
printf 'y\n' > "$restore_input"
restore_output="$TMP/restore-output"
if ! docker exec -i "$CONTAINER" /usr/local/bin/restore-home latest \
    < "$restore_input" > "$restore_output" 2>&1; then
    echo 'restore-home failed during the restore drill; output follows:' >&2
    cat "$restore_output" >&2
    exit 1
fi
grep -Fq 'Restore complete from snapshot: latest' "$restore_output" || {
    echo 'restore-home did not report completion; output follows:' >&2
    cat "$restore_output" >&2
    exit 1
}
assert_container 'restore drill recovers the original file' \
    "grep -Fxq 'restic restore drill' /home/coding/workspace/restore-drill/marker.txt"
assert_container 'restored data is usable by the configured user' \
    "su -s /bin/bash coding -c 'cat /home/coding/workspace/restore-drill/marker.txt' | grep -Fxq 'restic restore drill'"
assert_container 'restore drill preserves user ownership' \
    '[[ $(stat -c %U:%G /home/coding/workspace/restore-drill/marker.txt) == coding:coding ]]'

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
assert_container 'second run preserves both users ownership boundaries' \
    '[[ $(stat -c %U:%G:%a /home/coding) == coding:coding:700 ]] && \
     [[ $(stat -c %U:%G:%a /home/trading) == trading:trading:700 ]] && \
     [[ $(grep -Fc "coding:" /etc/subuid) -eq 1 ]] && \
     [[ $(grep -Fc "trading:" /etc/subuid) -eq 1 ]]'

echo 'Bootstrap integration and idempotence tests passed.'
