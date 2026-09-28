#!/usr/bin/env bash
set -Eeuo pipefail

# Run the real EX44 bootstrap in disposable Debian and Ubuntu hosts, cross a
# simulated reboot boundary, and rerun it. This is deliberately an
# installation, persistence, and idempotence test, not a second implementation
# of bootstrap --verify; the latter is a read-only production check and is
# invoked separately near the end of each distribution case.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

# Keep the full integration scenario in one place while exercising every
# supported base image. A child invocation owns one disposable container, so a
# failure leaves the --keep debugging behavior unchanged for that case.
if [[ ${BOOTSTRAP_TEST_MATRIX_CHILD:-false} != true ]]; then
    debian_image=${BOOTSTRAP_TEST_IMAGE:-${BOOTSTRAP_TEST_DEBIAN_IMAGE:-debian:12-slim}}
    ubuntu_image=${BOOTSTRAP_TEST_UBUNTU_IMAGE:-ubuntu:24.04}

    for distribution in debian ubuntu; do
        case "$distribution" in
            debian) image=$debian_image ;;
            ubuntu) image=$ubuntu_image ;;
        esac
        echo "=== Running bootstrap integration for $distribution ($image) ==="
        BOOTSTRAP_TEST_MATRIX_CHILD=true \
            BOOTSTRAP_TEST_DISTRIBUTION="$distribution" \
            BOOTSTRAP_TEST_IMAGE="$image" \
            "$0" "$@"
    done
    echo 'Bootstrap integration matrix passed for Debian 12 and Ubuntu 24.04.'
    exit 0
fi

DISTRIBUTION=${BOOTSTRAP_TEST_DISTRIBUTION:?BOOTSTRAP_TEST_DISTRIBUTION is required}
IMAGE=${BOOTSTRAP_TEST_IMAGE:-}
case "$DISTRIBUTION" in
    debian)
        IMAGE=${IMAGE:-debian:12-slim}
        ;;
    ubuntu)
        IMAGE=${IMAGE:-ubuntu:24.04}
        ;;
    *)
        echo "unsupported integration distribution: $DISTRIBUTION" >&2
        exit 2
        ;;
esac
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
  BOOTSTRAP_TEST_IMAGE          Override the Debian image (legacy alias)
  BOOTSTRAP_TEST_DEBIAN_IMAGE   Override the Debian image
  BOOTSTRAP_TEST_UBUNTU_IMAGE   Override the Ubuntu image
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --keep) KEEP_CONTAINER=true; shift ;;
        --help|-h) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

docker_is_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

if ! docker_is_available; then
    if [[ ${BOOTSTRAP_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        echo 'bootstrap integration tests require a reachable Docker daemon' >&2
        exit 2
    fi
    echo 'SKIP: bootstrap integration tests require a reachable Docker daemon' >&2
    exit 0
fi

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
    /src/hosts/ex44/bootstrap.sh "$DISTRIBUTION"

echo 'Checking non-interactive bootstrap safe-stop...'
noninteractive_output="$TMP/noninteractive-output"
set +e
docker exec "$CONTAINER" bash /test/bootstrap-under-test.sh >"$noninteractive_output" 2>&1
noninteractive_status=$?
set -e
if [[ "$noninteractive_status" -eq 0 ]]; then
    echo 'ASSERTION FAILED: non-interactive bootstrap unexpectedly continued' >&2
    cat "$noninteractive_output" >&2
    exit 1
fi
[[ "$noninteractive_status" -eq 1 ]] || {
    echo "ASSERTION FAILED: non-interactive bootstrap exited $noninteractive_status, expected 1" >&2
    cat "$noninteractive_output" >&2
    exit 1
}
grep -Fq 'ERROR: No terminal available for interactive input' "$noninteractive_output" || {
    echo 'ASSERTION FAILED: non-interactive bootstrap produced the wrong diagnostic' >&2
    cat "$noninteractive_output" >&2
    exit 1
}
if docker exec "$CONTAINER" test -e /etc/bootstrap/config; then
    echo 'ASSERTION FAILED: non-interactive bootstrap changed host configuration before stopping' >&2
    exit 1
fi
if docker exec "$CONTAINER" test -s /var/lib/bootstrap-test/commands.log; then
    echo 'ASSERTION FAILED: non-interactive bootstrap invoked a host-mutating command before stopping' >&2
    exit 1
fi
echo 'PASS: non-interactive bootstrap refuses before host changes'

first_input="$TMP/first-input"
tailscale_auth_key='tskey-auth-integration'
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

run_bootstrap() {
    local label=$1
    local input=$2
    local output="$TMP/$label-output"
    shift 2

    # Run through a disposable pty so the production bootstrap can open
    # /dev/tty without rewriting the signed fixture under test.
    local docker_args=(exec -it)
    local command_line
    if [[ $# -gt 0 ]]; then
        docker_args+=(--env-file "$1")
    fi
    docker_args+=("$CONTAINER" bash -c 'stty -echo; exec bash /test/bootstrap-under-test.sh')
    printf -v command_line '%q ' docker "${docker_args[@]}"

    echo "Running bootstrap ($label)..."
    if ! script -qefc "stty -echo; $command_line" /dev/null \
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

sops_b2_key='sops-application-key'
sops_restic_password='sops-password'
sops_input="$TMP/sops-input"
printf '\n\n\n' > "$sops_input"

write_private_env() {
    local path=$1
    shift
    (
        umask 077
        printf '%s\n' "$@" > "$path"
    )
}

sops_env="$TMP/sops.env"
write_private_env "$sops_env" \
    "BOOTSTRAP_B2_APPLICATION_KEY=$sops_b2_key" \
    "BOOTSTRAP_RESTIC_PASSWORD=$sops_restic_password"
[[ $(stat -c %a "$sops_env") == 600 ]] || {
    echo 'ASSERTION FAILED: SOPS environment input is not mode 0600' >&2
    exit 1
}

run_bootstrap_with_sops() {
    local label=$1
    local input=$2
    local env_file=${3:-$sops_env}
    local output="$TMP/$label-output"

    echo "Running bootstrap ($label) with SOPS environment input..."
    if ! run_bootstrap "$label" "$input" "$env_file"; then
        echo "bootstrap failed during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    fi
    grep -Fq 'Using backup secrets supplied by SOPS through the process environment.' "$output" || {
        echo "bootstrap did not use SOPS input during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fq '=== Bootstrap Complete' "$output" || {
        echo "bootstrap did not report completion during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    }
}

run_bootstrap_with_openbao() {
    local label=$1
    local input=$2
    local env_file=$3
    local output="$TMP/$label-output"

    echo "Running bootstrap ($label) with OpenBao input..."
    if ! run_bootstrap "$label" "$input" "$env_file"; then
        echo "bootstrap failed during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    fi
    grep -Fq 'Secrets retrieved from OpenBao.' "$output" || {
        echo "bootstrap did not use OpenBao input during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fq '=== Bootstrap Complete' "$output" || {
        echo "bootstrap did not report completion during $label; output follows:" >&2
        cat "$output" >&2
        exit 1
    }
}

run_bootstrap_expect_failure() {
    local label=$1
    local input=$2
    local environment=${3:-BOOTSTRAP_TEST_TAILSCALE_UP_FAIL=true}
    local output="$TMP/$label-output"

    echo "Running bootstrap ($label), expecting failure..."
    if script -qefc "stty -echo; $(printf '%q ' docker exec -it -e "$environment" \
        "$CONTAINER" bash -c 'stty -echo; exec bash /test/bootstrap-under-test.sh')" /dev/null \
        < "$input" > "$output" 2>&1; then
        echo "ASSERTION FAILED: bootstrap unexpectedly succeeded during $label" >&2
        cat "$output" >&2
        exit 1
    fi
    printf '%s\n' "$output"
}

partial_sops_output="$TMP/partial-sops-output"
partial_sops_env="$TMP/partial-sops.env"
write_private_env "$partial_sops_env" "BOOTSTRAP_B2_APPLICATION_KEY=$sops_b2_key"
if script -qefc "stty -echo; $(printf '%q ' docker exec -it --env-file "$partial_sops_env" \
    "$CONTAINER" bash -c 'stty -echo; exec bash /test/bootstrap-under-test.sh')" /dev/null \
    </dev/null > "$partial_sops_output" 2>&1; then
    echo 'ASSERTION FAILED: bootstrap accepted a partial SOPS secret pair' >&2
    exit 1
fi
grep -Fq 'SOPS bootstrap input must provide both backup secrets' "$partial_sops_output" || {
    echo 'ASSERTION FAILED: partial SOPS pair produced the wrong diagnostic' >&2
    cat "$partial_sops_output" >&2
    exit 1
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

assert_output_excludes() {
    local description=$1
    local output=$2
    local text=$3
    if grep -Fq -- "$text" "$output"; then
        echo "ASSERTION FAILED: $description" >&2
        exit 1
    fi
}

assert_runtime_secret_hygiene() {
    local description=$1
    shift
    if ! printf '%s\0' "$@" | docker exec -i "$CONTAINER" \
        /usr/local/bin/bootstrap-test-secret-audit; then
        echo "ASSERTION FAILED: $description" >&2
        exit 1
    fi
}

assert_no_age_identity_material() {
    local description=$1
    assert_container "$description" '
        private_key_marker="AGE-SECRET-""KEY-"
        while IFS= read -r -d "" path; do
            if grep -Fq -- "$private_key_marker" "$path"; then
                exit 1
            fi
        done < <(find /etc /root /home /tmp /run /var/lib/bootstrap-test \
            -xdev -type f -print0)
    '
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

assert_recovered_host() {
    local phase=$1

    assert_container "$phase: SSH remains usable" \
        'systemctl is-active --quiet sshd && sshd -t && sshd -T | grep -Fxq "passwordauthentication no"'
    assert_container "$phase: UFW remains active with the SSH recovery rules" \
        "ufw status verbose | grep -Fq 'Status: active' && \
         ufw status verbose | grep -Fq 'Default: deny incoming' && \
         ufw status verbose | grep -Fq 'tailscale0' && \
         ufw status verbose | grep -Fq '213.133.99.0/24'"
    assert_container "$phase: fail2ban remains enabled and queryable" \
        'systemctl is-enabled --quiet fail2ban && systemctl is-active --quiet fail2ban && \
         fail2ban-client status sshd | grep -Fq "Status for the jail: sshd"'
    assert_container "$phase: auditd remains enabled and queryable" \
        'systemctl is-enabled --quiet auditd && systemctl is-active --quiet auditd && \
         auditctl -l | grep -Fq -- "-w /etc/passwd -p wa -k identity"'
    assert_container "$phase: Tailscale reconnects with its persisted identity" \
        'systemctl is-enabled --quiet tailscaled && systemctl is-active --quiet tailscaled && \
         tailscale status | grep -Eq "^100\\.64\\." && \
         tailscale status --json | grep -Fq "bootstrap-test.tailnet.ts.net."'
    assert_container "$phase: backup scheduling remains executable" \
        'grep -Fq "0 3 * * * root /usr/local/bin/backup-home" /etc/cron.d/restic-backup && \
         grep -Fq "0 4 * * 0 root /usr/local/bin/backup-home --prune" /etc/cron.d/restic-backup && \
         test -x /usr/local/bin/backup-home && /usr/local/bin/backup-home >/dev/null'
    assert_container "$phase: user workspaces remain private and writable" \
        'for user in coding trading; do \
             [[ $(stat -c %U:%G:%a /home/$user) == $user:$user:700 ]] && \
             [[ $(stat -c %U:%G /home/$user/workspace/security-acceptance.txt) == $user:$user ]] && \
             su -s /bin/bash $user -c "printf %s $user >> /home/$user/workspace/security-acceptance.txt"; \
         done'
    for user in coding trading; do
        assert_user_output "$phase: $user rootless Docker starts after reboot" \
            "$user" 'Rootless Docker fixture' \
            "/home/$user/bin/start-docker"
        assert_user_output "$phase: $user workload uses its rootless Docker socket" \
            "$user" 'Hello from Docker' \
            'DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker run --rm hello-world'
        assert_user_output "$phase: $user launcher remains usable" \
            "$user" 'claude 1.0.0' \
            "HOME=/home/$user PATH=/home/$user/.local/bin:/usr/local/bin:/usr/bin:/bin HERDR_ENV=security-acceptance /home/$user/start.sh --no-update --agent claude"
    done
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
while IFS= read -r setting; do
    [[ -z "$setting" ]] || assert_file_contains "sysctl baseline includes $setting" \
        /etc/sysctl.d/99-hardening.conf "$setting"
done <<'SYSCTL_BASELINE'
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
fs.suid_dumpable = 0
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTL_BASELINE
while IFS= read -r setting; do
    [[ -z "$setting" ]] || assert_file_contains "SSH baseline includes $setting" \
        /etc/ssh/sshd_config.d/hardening.conf "$setting"
done <<'SSH_BASELINE'
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
ChallengeResponseAuthentication no
UsePAM yes
AllowUsers root coding trading
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowTcpForwarding yes
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no
Protocol 2
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
SSH_BASELINE
while IFS= read -r rule; do
    [[ -z "$rule" ]] || assert_file_contains "auditd baseline includes $rule" \
        /etc/audit/rules.d/hardening.rules "$rule"
done <<'AUDIT_BASELINE'
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /etc/hosts -p wa -k hosts
-w /etc/network/ -p wa -k network
AUDIT_BASELINE
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
assert_file_contains 'fail2ban records an enabled SSH jail' \
    /etc/fail2ban/jail.local 'enabled = true'
assert_file_contains 'fail2ban uses the SSH service port' \
    /etc/fail2ban/jail.local 'port = ssh'
assert_file_contains 'SSH keeps modern protocol settings' \
    /etc/ssh/sshd_config.d/hardening.conf 'KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org'
for rescue_network in \
    213.133.99.0/24 \
    213.133.100.0/24 \
    88.198.230.0/24 \
    88.198.231.0/24; do
    assert_container "UFW allows rescue network $rescue_network" \
        "ufw status verbose | grep -Fq '$rescue_network'"
done
assert_container 'UFW allows outbound traffic by default' \
    "ufw status verbose | grep -Fq 'Default: allow outgoing'"
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
assert_container 'tailscaled is enabled and active' \
    'systemctl is-enabled --quiet tailscaled && systemctl is-active --quiet tailscaled'
assert_container 'Tailscale enrollment uses a private file reference' \
    "grep -Fq -- '--auth-key=file:' /var/lib/bootstrap-test/tailscale-up-args.log && \\
     ! grep -Fq -- 'tskey-' /var/lib/bootstrap-test/tailscale-up-args.log"
# `script` records bytes echoed by the disposable PTY before the bootstrap
# prompt is active. Only inspect bootstrap output after its banner so that
# terminal input echo cannot be mistaken for a secret disclosure.
if sed -n '/=== Hetzner EX44 Bootstrap/,$p' "$TMP/first-output" | \
    grep -Fq -- "$tailscale_auth_key"; then
    echo 'ASSERTION FAILED: Tailscale auth key appeared in bootstrap output' >&2
    exit 1
fi
assert_container 'Tailscale auth input is not persisted in bootstrap state' \
    "! grep -R -Fq -- 'tskey-' /etc/bootstrap /var/lib/tailscale"
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
echo 'Checking the documented per-user workspace and launcher contract...'
assert_mode 'coding home is private' /home/coding 700
assert_mode 'trading home is private' /home/trading 700
assert_mode 'coding SSH directory is private' /home/coding/.ssh 700
assert_mode 'trading SSH directory is private' /home/trading/.ssh 700
assert_mode 'coding authorized keys are private' /home/coding/.ssh/authorized_keys 600
assert_mode 'trading authorized keys are private' /home/trading/.ssh/authorized_keys 600
assert_mode 'restic credentials are private' /etc/restic/b2.env 600
assert_file_contains 'interactive fallback supplies the B2 application key' \
    /etc/restic/b2.env 'test-application-key'
assert_file_contains 'interactive fallback supplies the restic password' \
    /etc/restic/b2.env 'test-password'
assert_file_contains 'restic repository uses the configured prefix' \
    /etc/restic/b2.env 'RESTIC_REPOSITORY="b2:test-bucket:test-prefix/'
assert_runtime_secret_hygiene 'interactive credentials stay out of argv, process listings, logs, and generated artifacts' \
    'test-application-key' 'test-password'
assert_container 'interactive bootstrap does not install SOPS or age runtime tools' \
    '! command -v sops && ! command -v age && ! command -v age-keygen && \
     ! grep -Eq "apt-get .* (sops|age|age-keygen)( |$)" /var/lib/bootstrap-test/commands.log'
assert_container 'interactive bootstrap does not copy SOPS or age input files' \
    '! find /etc /root /home /tmp /run /var/lib/bootstrap-test -xdev -type f \
         \( -name "*.sops.env" -o -name "*.sops.yml" -o -name "keys.txt" \) \
         -print -quit | grep -q .'
assert_no_age_identity_material \
    'interactive bootstrap does not copy arbitrary age private identities'
assert_container 'rootless Docker prerequisites are installed' \
    'grep -Eq "apt-get.*uidmap.*dbus-user-session.*fuse-overlayfs.*rootlesskit.*slirp4netns" /var/lib/bootstrap-test/commands.log'
assert_container 'rootless Docker has a subuid range' \
    'grep -Fxq "coding:100000:65536" /etc/subuid && grep -Fxq "trading:165536:65536" /etc/subuid && \
     [[ $(grep -Ec "^(coding|trading):" /etc/subuid) -eq 2 ]]'
assert_container 'rootless Docker has subordinate groups for both users' \
    'grep -Fxq "coding:100000:65536" /etc/subgid && grep -Fxq "trading:165536:65536" /etc/subgid && \
     [[ $(grep -Ec "^(coding|trading):" /etc/subgid) -eq 2 ]]'
assert_container 'rootful Docker daemon is disabled' \
    '[[ -f /var/lib/bootstrap-test/system-docker-disabled ]] && [[ ! -e /run/docker.sock ]]'
assert_container 'rootless Docker has user-owned services and runtime directories' \
    'for user in coding trading; do \
         [[ -f /home/$user/.config/systemd/user/docker.service ]] && \
         [[ $(stat -c %U:%G /home/$user/.config/systemd/user/docker.service) == $user:$user ]] && \
         [[ -L /home/$user/.config/systemd/user/default.target.wants/docker.service ]] && \
         [[ $(readlink /home/$user/.config/systemd/user/default.target.wants/docker.service) == ../docker.service ]] && \
         [[ -f /var/lib/systemd/linger/$user ]] && \
         [[ $(stat -c %U:%a /run/user/$(id -u $user)) == $user:700 ]]; \
     done'
assert_container 'rootless Docker service is not a root service' \
    '! grep -Eq "User=root|/etc/systemd/system/docker.service" /home/coding/.config/systemd/user/docker.service && \
     grep -Fq "dockerd-rootless.sh" /home/coding/.config/systemd/user/docker.service'
assert_file_contains 'rootless Docker environment is configured' \
    /home/coding/.bashrc 'export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"'
assert_file_contains 'trading rootless Docker environment is configured' \
    /home/trading/.bashrc 'export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"'
assert_container 'launcher is exposed on PATH' \
    'for user in coding trading; do \
         [[ -L /home/$user/.local/bin/start ]] && \
         [[ $(readlink /home/$user/.local/bin/start) == /home/$user/start.sh ]]; \
     done'
assert_container 'launchers are executable and user-owned' \
    'for user in coding trading; do \
         [[ -x /home/$user/start.sh ]] && \
         [[ $(stat -c %U:%G /home/$user/start.sh) == $user:$user ]] && \
         [[ $(stat -c %U:%G /home/$user/.local/bin/start) == $user:$user ]]; \
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
    assert_user_output "$user workload uses the per-user Docker socket" \
        "$user" 'Hello from Docker' \
        'DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock docker run --rm hello-world'
done
assert_container 'deployed launcher matches the canonical source' \
    'cmp -s /home/coding/start.sh /src/hosts/ex44/start.sh'
assert_container 'both deployed launchers match the canonical source' \
    'cmp -s /home/coding/start.sh /src/hosts/ex44/start.sh && cmp -s /home/trading/start.sh /src/hosts/ex44/start.sh'
for user in coding trading; do
    assert_user_output "$user can execute start.sh without root" \
        "$user" 'start v' \
        "HOME=/home/$user /home/$user/.local/bin/start --version"
    assert_user_output "$user can resolve start through its PATH" \
        "$user" 'start v' \
        "HOME=/home/$user PATH=/home/$user/.local/bin:/usr/local/bin:/usr/bin:/bin start --version"
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

run_bootstrap_with_sops sops "$sops_input"
assert_file_contains 'SOPS B2 key reaches the runtime restic environment' \
    /etc/restic/b2.env "$sops_b2_key"
assert_file_contains 'SOPS restic password reaches the runtime restic environment' \
    /etc/restic/b2.env "$sops_restic_password"
assert_output_excludes 'SOPS B2 key is not printed' \
    "$TMP/sops-output" "$sops_b2_key"
assert_output_excludes 'SOPS restic password is not printed' \
    "$TMP/sops-output" "$sops_restic_password"
assert_runtime_secret_hygiene 'SOPS credentials stay out of argv, process listings, logs, and generated artifacts' \
    "$sops_b2_key" "$sops_restic_password"
assert_container 'SOPS dotenv input is not copied to the provisioned host' \
    '! find /etc /root /home /tmp /run /var/lib/bootstrap-test -xdev -type f \
         -name "$(basename '"$sops_env"')" -print -quit | grep -q .'
assert_container 'SOPS ciphertext and age identity files are absent from the host' \
    '! find /etc /root /home /tmp /run /var/lib/bootstrap-test -xdev -type f \
         \( -name "*.sops.env" -o -name "*.sops.yml" -o -name "keys.txt" \) \
         -print -quit | grep -q .'
assert_no_age_identity_material \
    'SOPS bootstrap keeps the operator age private identity outside the host'

first_snapshot=$(docker exec "$CONTAINER" /usr/local/bin/bootstrap-test-snapshot)

run_bootstrap_with_sops second "$sops_input"

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

echo 'Simulating a reboot and checking persistent host services...'
assert_container 'reboot boundary reconstructs boot-time runtime state' \
    '/usr/local/bin/bootstrap-test-reboot && grep -Fxq "reboot boundary completed" /var/lib/bootstrap-test/reboot.log'
assert_recovered_host 'after reboot'

run_bootstrap_with_sops post-reboot-rerun "$sops_input"
assert_recovered_host 'after post-reboot bootstrap rerun'

openbao_token='fixture-openbao-token'
openbao_b2_key='openbao-application-key'
openbao_restic_password='openbao-password'
openbao_env="$TMP/openbao.env"
write_private_env "$openbao_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=complete' \
    "BOOTSTRAP_TEST_OPENBAO_B2_KEY=$openbao_b2_key" \
    "BOOTSTRAP_TEST_OPENBAO_RESTIC_PASSWORD=$openbao_restic_password"

run_bootstrap_with_openbao openbao "$sops_input" "$openbao_env"
assert_file_contains 'OpenBao supplies the B2 application key' \
    /etc/restic/b2.env "$openbao_b2_key"
assert_file_contains 'OpenBao supplies the restic password' \
    /etc/restic/b2.env "$openbao_restic_password"
assert_output_excludes 'OpenBao token is not printed' \
    "$TMP/openbao-output" "$openbao_token"
assert_output_excludes 'OpenBao B2 key is not printed' \
    "$TMP/openbao-output" "$openbao_b2_key"
assert_output_excludes 'OpenBao restic password is not printed' \
    "$TMP/openbao-output" "$openbao_restic_password"
assert_container 'OpenBao request uses the documented KV-v2 GET path' \
    "grep -Eq '^GET /v1/secret/bootstrap/[^/]+/b2$' /var/lib/bootstrap-test/openbao-requests.log"
assert_container 'bootstrap never writes an age identity to OpenBao' \
    '! grep -Eq "^(POST|PUT|PATCH|DELETE) " /var/lib/bootstrap-test/openbao-requests.log'
assert_container 'OpenBao requests contain no age private identity material' \
    'private_key_marker="AGE-SECRET-""KEY-"; \
     ! grep -Fq -- "$private_key_marker" /var/lib/bootstrap-test/openbao-requests.log'
assert_no_age_identity_material \
    'OpenBao bootstrap path keeps age private identities outside the host'
assert_container 'OpenBao request passed the private token header contract' \
    'test -f /var/lib/bootstrap-test/openbao-api-contract-ok'
assert_container 'OpenBao token header file is removed after the read' \
    '! test -e "$(cat /var/lib/bootstrap-test/openbao-last-header-path)"'
assert_container 'OpenBao token header file was mode 0600 while present' \
    '[[ $(cat /var/lib/bootstrap-test/openbao-header-mode) == 600 ]]'
assert_runtime_secret_hygiene 'OpenBao credentials stay out of argv, process listings, logs, and generated artifacts' \
    "$openbao_token" "$openbao_b2_key" "$openbao_restic_password"

partial_openbao_key='partial-openbao-application-key'
partial_openbao_env="$TMP/partial-openbao.env"
write_private_env "$partial_openbao_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=partial' \
    "BOOTSTRAP_TEST_OPENBAO_B2_KEY=$partial_openbao_key"
partial_openbao_input="$TMP/partial-openbao-input"
printf '\n\n%s\n%s\n%s\n\n' \
    'interactive-fallback-application-key' \
    'interactive-fallback-password' \
    'interactive-fallback-password' > "$partial_openbao_input"
run_bootstrap partial-openbao "$partial_openbao_input" "$partial_openbao_env"
partial_openbao_output="$TMP/partial-openbao-output"
grep -Fq 'OpenBao secret exists but missing required fields' "$partial_openbao_output" || {
    echo 'ASSERTION FAILED: partial OpenBao pair produced the wrong diagnostic' >&2
    cat "$partial_openbao_output" >&2
    exit 1
}
assert_file_contains 'partial OpenBao pair falls back to the interactive B2 key' \
    /etc/restic/b2.env 'interactive-fallback-application-key'
assert_file_contains 'partial OpenBao pair falls back to the interactive password' \
    /etc/restic/b2.env 'interactive-fallback-password'
if docker exec "$CONTAINER" grep -Fq -- "$partial_openbao_key" /etc/restic/b2.env; then
    echo 'ASSERTION FAILED: partial OpenBao pair was silently mixed with interactive input' >&2
    exit 1
fi
assert_output_excludes 'partial OpenBao token is not printed' \
    "$partial_openbao_output" "$openbao_token"
assert_output_excludes 'partial OpenBao key is not printed' \
    "$partial_openbao_output" "$partial_openbao_key"

malformed_openbao_env="$TMP/malformed-openbao.env"
write_private_env "$malformed_openbao_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=malformed'
malformed_openbao_input="$TMP/malformed-openbao-input"
printf '\n\n%s\n%s\n%s\n\n' \
    'malformed-fallback-application-key' \
    'malformed-fallback-password' \
    'malformed-fallback-password' > "$malformed_openbao_input"
run_bootstrap malformed-openbao "$malformed_openbao_input" "$malformed_openbao_env"
malformed_openbao_output="$TMP/malformed-openbao-output"
grep -Fq 'No secrets found at OpenBao path:' "$malformed_openbao_output" || {
    echo 'ASSERTION FAILED: malformed OpenBao response produced the wrong diagnostic' >&2
    cat "$malformed_openbao_output" >&2
    exit 1
}
assert_file_contains 'malformed OpenBao response falls back to the interactive B2 key' \
    /etc/restic/b2.env 'malformed-fallback-application-key'
assert_file_contains 'malformed OpenBao response falls back to the interactive password' \
    /etc/restic/b2.env 'malformed-fallback-password'
assert_output_excludes 'malformed OpenBao token is not printed' \
    "$malformed_openbao_output" "$openbao_token"

unavailable_openbao_env="$TMP/unavailable-openbao.env"
write_private_env "$unavailable_openbao_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=unavailable'
unavailable_openbao_input="$TMP/unavailable-openbao-input"
printf '\n\n%s\n%s\n%s\n\n' \
    'unavailable-fallback-application-key' \
    'unavailable-fallback-password' \
    'unavailable-fallback-password' > "$unavailable_openbao_input"
run_bootstrap unavailable-openbao "$unavailable_openbao_input" "$unavailable_openbao_env"
unavailable_openbao_output="$TMP/unavailable-openbao-output"
grep -Fq 'No OpenBao token provided or OpenBao unreachable.' "$unavailable_openbao_output" || {
    echo 'ASSERTION FAILED: unavailable OpenBao produced the wrong diagnostic' >&2
    cat "$unavailable_openbao_output" >&2
    exit 1
}
assert_file_contains 'unavailable OpenBao falls back to the interactive B2 key' \
    /etc/restic/b2.env 'unavailable-fallback-application-key'
assert_file_contains 'unavailable OpenBao falls back to the interactive password' \
    /etc/restic/b2.env 'unavailable-fallback-password'
assert_output_excludes 'unavailable OpenBao token is not printed' \
    "$unavailable_openbao_output" "$openbao_token"
assert_container 'unavailable OpenBao header file is removed after a failed read' \
    '! test -e "$(cat /var/lib/bootstrap-test/openbao-last-header-path)"'
assert_container 'unavailable OpenBao header file was mode 0600 while present' \
    '[[ $(cat /var/lib/bootstrap-test/openbao-header-mode) == 600 ]]'
assert_runtime_secret_hygiene 'interactive fallback after unavailable OpenBao stays free of credentials in runtime artifacts' \
    "$openbao_token" 'unavailable-fallback-application-key' 'unavailable-fallback-password'

openbao_request_count_before=$(docker exec "$CONTAINER" bash -ceu \
    "grep -c '^GET ' /var/lib/bootstrap-test/openbao-requests.log")
docker exec "$CONTAINER" systemctl stop tailscaled
tailscale_unavailable_env="$TMP/tailscale-unavailable.env"
write_private_env "$tailscale_unavailable_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=complete'
tailscale_unavailable_input="$TMP/tailscale-unavailable-input"
printf '\n\n%s\n%s\n%s\n\n' \
    'tailscale-unavailable-application-key' \
    'tailscale-unavailable-password' \
    'tailscale-unavailable-password' > "$tailscale_unavailable_input"
run_bootstrap tailscale-unavailable "$tailscale_unavailable_input" "$tailscale_unavailable_env"
tailscale_unavailable_output="$TMP/tailscale-unavailable-output"
grep -Fq 'OpenBao fetch requires Tailscale connectivity. Falling back to interactive prompt.' \
    "$tailscale_unavailable_output" || {
    echo 'ASSERTION FAILED: inactive Tailscale produced the wrong OpenBao fallback diagnostic' >&2
    cat "$tailscale_unavailable_output" >&2
    exit 1
}
assert_file_contains 'inactive Tailscale falls back to the interactive B2 key' \
    /etc/restic/b2.env 'tailscale-unavailable-application-key'
assert_file_contains 'inactive Tailscale falls back to the interactive password' \
    /etc/restic/b2.env 'tailscale-unavailable-password'
openbao_request_count_after=$(docker exec "$CONTAINER" bash -ceu \
    "grep -c '^GET ' /var/lib/bootstrap-test/openbao-requests.log")
if [[ "$openbao_request_count_after" != "$openbao_request_count_before" ]]; then
    echo 'ASSERTION FAILED: OpenBao was queried while Tailscale was unavailable' >&2
    exit 1
fi
assert_output_excludes 'inactive Tailscale token is not printed' \
    "$tailscale_unavailable_output" "$openbao_token"

rotation_sops_b2_key='rotated-sops-application-key'
rotation_sops_restic_password='rotated-sops-password'
rotation_sops_env="$TMP/rotation-sops.env"
write_private_env "$rotation_sops_env" \
    "BOOTSTRAP_B2_APPLICATION_KEY=$rotation_sops_b2_key" \
    "BOOTSTRAP_RESTIC_PASSWORD=$rotation_sops_restic_password" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=complete' \
    "BOOTSTRAP_TEST_OPENBAO_B2_KEY=$openbao_b2_key" \
    "BOOTSTRAP_TEST_OPENBAO_RESTIC_PASSWORD=$openbao_restic_password"
run_bootstrap_with_sops rotation-sops "$sops_input" "$rotation_sops_env"
rotation_sops_output="$TMP/rotation-sops-output"
if grep -Fq 'Secrets retrieved from OpenBao.' "$rotation_sops_output"; then
    echo 'ASSERTION FAILED: SOPS/OpenBao rotation silently selected OpenBao' >&2
    exit 1
fi
assert_file_contains 'SOPS wins during deliberate rotation' \
    /etc/restic/b2.env "$rotation_sops_b2_key"
assert_file_contains 'SOPS rotation updates the restic password' \
    /etc/restic/b2.env "$rotation_sops_restic_password"
if docker exec "$CONTAINER" grep -Fq -- "$openbao_b2_key" /etc/restic/b2.env; then
    echo 'ASSERTION FAILED: SOPS/OpenBao rotation silently mixed stale OpenBao credentials' >&2
    exit 1
fi
assert_runtime_secret_hygiene 'SOPS rotation keeps both source credentials out of runtime artifacts' \
    "$openbao_token" "$rotation_sops_b2_key" "$rotation_sops_restic_password"

rotated_openbao_env="$TMP/rotated-openbao.env"
write_private_env "$rotated_openbao_env" \
    "OPENBAO_TOKEN=$openbao_token" \
    "BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN=$openbao_token" \
    'BOOTSTRAP_TEST_OPENBAO_MODE=complete' \
    "BOOTSTRAP_TEST_OPENBAO_B2_KEY=$rotation_sops_b2_key" \
    "BOOTSTRAP_TEST_OPENBAO_RESTIC_PASSWORD=$rotation_sops_restic_password"
run_bootstrap_with_openbao openbao-after-rotation "$sops_input" "$rotated_openbao_env"
assert_file_contains 'deliberate OpenBao rotation publishes the new B2 key' \
    /etc/restic/b2.env "$rotation_sops_b2_key"
assert_file_contains 'deliberate OpenBao rotation publishes the new restic password' \
    /etc/restic/b2.env "$rotation_sops_restic_password"

verify_output="$TMP/verify-output"
if ! docker exec "$CONTAINER" bash /test/bootstrap-under-test.sh --verify > "$verify_output" 2>&1; then
    echo 'bootstrap --verify failed after the idempotence run; output follows:' >&2
    cat "$verify_output" >&2
    exit 1
fi
grep -Fq 'Failed:       0' "$verify_output" || {
    echo 'bootstrap --verify reported failed checks; output follows:' >&2
    cat "$verify_output" >&2
    exit 1
}
grep -Fq 'UFW allows rescue 213.133.99.0/24:' "$verify_output"
grep -Fq 'SSH protocol and cipher policy:' "$verify_output"
grep -Fq 'fail2ban enforces three-attempt UFW bans:' "$verify_output"
grep -Fq 'auditd watches network configuration:' "$verify_output"
grep -Fq 'Kernel pointer exposure restricted:' "$verify_output"

# A failed enrollment must stop the run with an actionable, non-secret
# diagnostic and remove the temporary auth-key file. This run deliberately
# starts from a logged-out client after the successful convergence checks.
docker exec "$CONTAINER" tailscale down
failure_input="$TMP/tailscale-failure-input"
cat > "$failure_input" <<'INPUT'

tskey-auth-failure

test-application-key
test-password
test-password

INPUT
failure_output=$(run_bootstrap_expect_failure tailscale-failure "$failure_input")
failure_log=${failure_output##*$'\n'}
grep -Fq 'ERROR: Tailscale authentication failed' "$failure_log" || {
    echo 'ASSERTION FAILED: failed Tailscale enrollment produced the wrong diagnostic' >&2
    cat "$failure_log" >&2
    exit 1
}
if sed -n '/=== Hetzner EX44 Bootstrap/,$p' "$failure_log" | grep -Fq -- 'tskey-auth-failure'; then
    echo 'ASSERTION FAILED: failed Tailscale enrollment exposed an auth key' >&2
    cat "$failure_log" >&2
    exit 1
fi
assert_container 'failed Tailscale enrollment removes the temporary auth-key file' \
    '! compgen -G "/run/tailscale-bootstrap-authkey.*" >/dev/null'

service_failure_output=$(run_bootstrap_expect_failure tailscale-service-failure \
    "$failure_input" BOOTSTRAP_TEST_TAILSCALE_SERVICE_FAIL=true)
service_failure_log=${service_failure_output##*$'\n'}
grep -Fq 'ERROR: Could not enable or start the tailscaled service' "$service_failure_log" || {
    echo 'ASSERTION FAILED: Tailscale service failure produced the wrong diagnostic' >&2
    cat "$service_failure_log" >&2
    exit 1
}
if sed -n '/=== Hetzner EX44 Bootstrap/,$p' "$service_failure_log" | grep -Fq -- 'tskey-auth-failure'; then
    echo 'ASSERTION FAILED: Tailscale service failure exposed an auth key' >&2
    cat "$service_failure_log" >&2
    exit 1
fi

docker exec "$CONTAINER" rm -f /usr/local/bin/tailscale
install_failure_output=$(run_bootstrap_expect_failure tailscale-install-failure \
    "$failure_input" BOOTSTRAP_TEST_TAILSCALE_INSTALL_FAIL=true)
install_failure_log=${install_failure_output##*$'\n'}
grep -Fq 'ERROR: Tailscale installation failed' "$install_failure_log" || {
    echo 'ASSERTION FAILED: Tailscale installation failure produced the wrong diagnostic' >&2
    cat "$install_failure_log" >&2
    exit 1
}
if sed -n '/=== Hetzner EX44 Bootstrap/,$p' "$install_failure_log" | grep -Fq -- 'tskey-auth-failure'; then
    echo 'ASSERTION FAILED: Tailscale installation failure exposed an auth key' >&2
    cat "$install_failure_log" >&2
    exit 1
fi

echo 'Bootstrap integration and idempotence tests passed.'
