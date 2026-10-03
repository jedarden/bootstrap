#!/bin/bash
set -euo pipefail

# Hetzner EX44 Bootstrap Script
# Hardens a fresh Debian/Ubuntu install and sets up isolated dev workspaces
#
# Version: 1.3.1
#
# Usage (download, authenticate per README.md, and run interactively):
#   curl -fsSLo bootstrap-1.3.1.sh https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap-1.3.1.sh
#   chmod +x bootstrap-1.3.1.sh
#   ./bootstrap-1.3.1.sh
#
# Usage (verify a host's hardened state, non-interactive):
#   sudo ./bootstrap-1.3.1.sh --verify

VERSION="1.3.1"

ARTIFACT_MANIFEST_FILE="artifact-manifest.txt"
ARTIFACT_SIGNATURE_FILE="artifact-manifest.sig"
ARTIFACT_TRUSTED_KEY_ID="bootstrap-rsa-2026-10"
ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEApNHGqYPfKvRpLulWXS8c
/VuKITatXEhDqrXY4/0ug9SqlZF8e/o3q6FVgbMqdRTniDOrhgx1mUcbzpFJ4Y6Z
ILcYmIEXne12A2BxHh2SF+9uXBAbwNdlEIXunybhGT4te32UKGGqRN7TdFpr6KsN
nSSNN2/WyvjL+ytqpa2KyguXkrGHSfwDdUDKDGYmL1eZHjhP2GrWxG6aI8EcMtfp
mAy/NUXxL2tOB8bGz+IPfTsycwcDqZ0mw59vQUy2+nUTnG/xQpWud6SXPMuSJoJ9
3tGGU24gz4vptPn7V/L3rGQp8Titgks0IxpwEXZV2T//wNEXBebGUGaoQfOrGSoC
AzELsxvleqZOKRJyP55Djqh5iELC9tF9yxmCmRLxYwUzYPz234Wf2E0Qi1Vo386e
VxyDwlCe9IIMEgejVkjseahaS5INmFjCoDjH7cZWY28MtTVy1u9/79n6wBkApJeQ
7AuWeqPskkNYJz18R2aRjER6/Ru+2gyXw5fnD3RbpLfzAgMBAAE=
-----END PUBLIC KEY-----
ARTIFACT_KEY
)
ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")
ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")

# External tool versions (pinned for reproducibility - update deliberately)
YQ_VERSION="v4.44.1"
KUBECTL_VERSION="v1.29.6"
CLOUDFLARED_VERSION="2024.8.1"

# Handle --version flag
if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
    echo "Hetzner EX44 Bootstrap v${VERSION}"
    exit 0
fi

# Handle --verify flag
if [[ "${1:-}" == "--verify" ]] || [[ "${1:-}" == "--check" ]]; then
    echo "=== Bootstrap Verification v${VERSION} ==="
    echo ""

    # cron and non-login shells run with a minimal PATH that omits /usr/sbin,
    # where ufw and sysctl live - normalize it so unattended runs don't
    # report spurious "command failed".
    export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"

    # Rootless Docker (per-user) resolves its socket via XDG_RUNTIME_DIR,
    # which cron and non-login shells don't set.
    if [[ -z "${XDG_RUNTIME_DIR:-}" && -d "/run/user/$EUID" ]]; then
        export XDG_RUNTIME_DIR="/run/user/$EUID"
    fi

    # Most checks (ufw, sshd -T, fail2ban, auditd) read state only root can
    # see. Continue anyway - the failures are accurate, just noisy - but say
    # why up front instead of making the operator discover it one FAIL at
    # a time.
    if [[ $EUID -ne 0 ]]; then
        echo "WARNING: not running as root - privileged checks (UFW, sshd -T,"
        echo "         fail2ban, auditd) will report FAIL. Re-run with sudo."
        echo ""
    fi

    TOTAL_CHECKS=0
    PASSED_CHECKS=0
    FAILED_CHECKS=0
    SKIPPED_CHECKS=0

    # Helper function for checks.
    #
    # Always returns 0 and records failures in FAILED_CHECKS instead: this
    # script runs under `set -euo pipefail`, so a non-zero return from a
    # top-level call would abort the run at the FIRST failure and skip both
    # the remaining checks and the summary - the one thing a verification
    # sweep must never do. The exit code after the summary carries the verdict.
    run_check() {
        local name="$1"
        local command="$2"
        local expected_pattern="${3:-.*}"
        local output detail

        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        printf "%-40s " "$name:"

        if ! output=$(eval "$command" 2>/dev/null); then
            echo "✗ FAIL (command failed)"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
            return 0
        fi

        if echo "$output" | grep -qE "$expected_pattern"; then
            echo "✓ PASS"
            PASSED_CHECKS=$((PASSED_CHECKS + 1))
        else
            # Show what was actually found so drift is visible in the output
            # (e.g. "got: passwordauthentication yes").
            detail=$(echo "$output" | head -1)
            echo "✗ FAIL (got: ${detail:-<no output>})"
            FAILED_CHECKS=$((FAILED_CHECKS + 1))
        fi
        return 0
    }

    echo "=== Firewall ==="
    run_check "UFW active" "ufw status" "^Status: active"
    run_check "UFW default incoming policy" "ufw status verbose | grep 'Default:'" "deny.*incoming"
    run_check "UFW default outgoing policy" "ufw status verbose | grep 'Default:'" "allow.*outgoing"
    run_check "UFW allows Tailscale" "ufw status verbose | grep 'tailscale0'" "ALLOW"
    for rescue_network in \
        213.133.99.0/24 \
        213.133.100.0/24 \
        88.198.230.0/24 \
        88.198.231.0/24; do
        run_check "UFW allows rescue ${rescue_network}" \
            "ufw status verbose | grep -F '${rescue_network}'" "ALLOW"
    done

    echo ""
    echo "=== Tailscale ==="
    # A connected node lists itself (and peers) with a Tailscale CGNAT
    # (100.64/10) or ULA (fd7a::/48) address; a logged-out or stopped node
    # prints "Logged out." / a daemon-connect error instead. 2>&1 so that
    # failure text becomes the check's "got:" detail.
    run_check "Tailscale connected" "tailscale status 2>&1" "^(100\.|fd7a:)"

    echo ""
    echo "=== SSH Hardening ==="
    run_check "PermitRootLogin is key-only" "sshd -T | grep permitrootlogin" "^permitrootlogin prohibit-password$"
    run_check "PasswordAuthentication disabled" "sshd -T | grep passwordauthentication" "^passwordauthentication no$"
    run_check "PubkeyAuthentication enabled" "sshd -T | grep pubkeyauthentication" "^pubkeyauthentication yes$"
    run_check "AuthenticationMethods requires public keys" "sshd -T | grep authenticationmethods" "^authenticationmethods publickey$"
    run_check "SSH user allowlist includes root" "sshd -T | grep allowusers" "^allowusers root( |$)"
    run_check "MaxAuthTries limited" "sshd -T | grep maxauthtries" "^maxauthtries 3$"
    run_check "X11 forwarding disabled" "sshd -T | grep x11forwarding" "^x11forwarding no$"
    run_check "TCP forwarding remains enabled" "sshd -T | grep allowtcpforwarding" "^allowtcpforwarding yes$"
    run_check "Agent forwarding disabled" "sshd -T | grep allowagentforwarding" "^allowagentforwarding no$"
    run_check "SSH tunnels disabled" "sshd -T | grep permittunnel" "^permittunnel no$"
    run_check "SSH gateway ports disabled" "sshd -T | grep gatewayports" "^gatewayports no$"
    run_check "SSH user environment disabled" "sshd -T | grep permituserenvironment" "^permituserenvironment no$"
    run_check "SSH protocol and cipher policy" \
        "sshd -T | grep -Fx 'protocol 2' && \
         sshd -T | grep -Fx 'ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com' && \
         sshd -T | grep -Fx 'macs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com' && \
         sshd -T | grep -Fx 'kexalgorithms curve25519-sha256,curve25519-sha256@libssh.org'" \
        "^kexalgorithms "

    echo ""
    echo "=== Docker ==="
    run_check "Docker installed" "command -v docker" "."
    run_check "Docker system daemon disabled" \
        "systemctl is-enabled docker.service 2>&1 || true" "disabled|masked"
    run_check "Docker system daemon inactive" \
        "systemctl is-active docker.service 2>&1 || true" "inactive|failed|unknown|not-found"

    # The bootstrap installs Docker's client and rootless daemon helper as
    # root, but all workloads must use a per-user daemon.  Verify that
    # contract by asking the first configured user to run the workload with
    # the runtime socket explicitly selected.  Calling `docker` directly as
    # root here would make this check accidentally pass against rootful
    # Docker's /run/docker.sock.
    verification_user=""
    verification_config_file=/etc/bootstrap/config
    if [[ -r "$verification_config_file" ]]; then
        configured_users=$(sed -n 's/^USERS="\([^"]*\)"$/\1/p' "$verification_config_file")
        verification_user="${configured_users%% *}"
    fi
    if [[ -n "$verification_user" ]]; then
        run_check "Docker workload runs through rootless socket" \
            "su -s /bin/bash '$verification_user' -c 'export XDG_RUNTIME_DIR=/run/user/\$(id -u); export DOCKER_HOST=unix://\$XDG_RUNTIME_DIR/docker.sock; docker run --rm hello-world' 2>&1 | head -5" \
            "Hello from Docker"
    else
        run_check "Rootless Docker user is configured" "false" "."
    fi

    echo ""
    echo "=== Security Services ==="
    run_check "fail2ban installed" "command -v fail2ban-client" "."
    run_check "fail2ban sshd jail active" "fail2ban-client status sshd" "Status for the jail: sshd"
    run_check "fail2ban enforces three-attempt UFW bans" \
        "grep -Fx 'maxretry = 3' /etc/fail2ban/jail.local && \
         grep -Fx 'banaction = ufw' /etc/fail2ban/jail.local && \
         grep -Fx 'enabled = true' /etc/fail2ban/jail.local && \
         grep -Fx 'port = ssh' /etc/fail2ban/jail.local" \
        "^port = ssh$"
    run_check "auditd installed" "command -v auditctl" "."
    run_check "auditd watches sudoers" \
        "auditctl -l | grep -Fx -- '-w /etc/sudoers -p wa -k sudoers' && \
         auditctl -l | grep -Fx -- '-w /etc/sudoers.d/ -p wa -k sudoers'" \
        "^-w /etc/sudoers.d/ -p wa -k sudoers$"
    run_check "auditd watches identity files" \
        "auditctl -l | grep -Fx -- '-w /etc/passwd -p wa -k identity' && \
         auditctl -l | grep -Fx -- '-w /etc/group -p wa -k identity' && \
         auditctl -l | grep -Fx -- '-w /etc/shadow -p wa -k identity'" \
        "^-w /etc/shadow -p wa -k identity$"
    run_check "auditd watches SSH configuration" \
        "auditctl -l | grep -Fx -- '-w /etc/ssh/sshd_config -p wa -k sshd' && \
         auditctl -l | grep -Fx -- '-w /etc/ssh/sshd_config.d/ -p wa -k sshd'" \
        "^-w /etc/ssh/sshd_config.d/ -p wa -k sshd$"
    run_check "auditd watches scheduled jobs" \
        "auditctl -l | grep -Fx -- '-w /etc/crontab -p wa -k cron' && \
         auditctl -l | grep -Fx -- '-w /etc/cron.d/ -p wa -k cron'" \
        "^-w /etc/cron.d/ -p wa -k cron$"
    run_check "auditd watches network configuration" \
        "auditctl -l | grep -Fx -- '-w /etc/hosts -p wa -k hosts' && \
         auditctl -l | grep -Fx -- '-w /etc/network/ -p wa -k network'" \
        "^-w /etc/network/ -p wa -k network$"

    echo ""
    echo "=== Kernel Hardening ==="
    run_check "IPv4 reverse-path filtering (all)" "sysctl -n net.ipv4.conf.all.rp_filter" "^1$"
    run_check "IPv4 reverse-path filtering (default)" "sysctl -n net.ipv4.conf.default.rp_filter" "^1$"
    run_check "ICMP broadcast requests ignored" "sysctl -n net.ipv4.icmp_echo_ignore_broadcasts" "^1$"
    run_check "IPv4 source routing (all) disabled" "sysctl -n net.ipv4.conf.all.accept_source_route" "^0$"
    run_check "IPv4 source routing (default) disabled" "sysctl -n net.ipv4.conf.default.accept_source_route" "^0$"
    run_check "IPv6 source routing (all) disabled" "sysctl -n net.ipv6.conf.all.accept_source_route" "^0$"
    run_check "IPv6 source routing (default) disabled" "sysctl -n net.ipv6.conf.default.accept_source_route" "^0$"
    run_check "IPv4 send redirects (all) disabled" "sysctl -n net.ipv4.conf.all.send_redirects" "^0$"
    run_check "IPv4 send redirects (default) disabled" "sysctl -n net.ipv4.conf.default.send_redirects" "^0$"
    run_check "TCP SYN cookies enabled" "sysctl -n net.ipv4.tcp_syncookies" "^1$"
    run_check "TCP SYN backlog hardened" "sysctl -n net.ipv4.tcp_max_syn_backlog" "^2048$"
    run_check "TCP SYN-ACK retries limited" "sysctl -n net.ipv4.tcp_synack_retries" "^2$"
    run_check "TCP SYN retries bounded" "sysctl -n net.ipv4.tcp_syn_retries" "^5$"
    run_check "Martian packets logged" "sysctl -n net.ipv4.conf.all.log_martians" "^1$"
    run_check "Bogus ICMP errors ignored" "sysctl -n net.ipv4.icmp_ignore_bogus_error_responses" "^1$"
    run_check "IPv4 redirects (all) disabled" "sysctl -n net.ipv4.conf.all.accept_redirects" "^0$"
    run_check "IPv4 redirects (default) disabled" "sysctl -n net.ipv4.conf.default.accept_redirects" "^0$"
    run_check "IPv6 redirects (all) disabled" "sysctl -n net.ipv6.conf.all.accept_redirects" "^0$"
    run_check "IPv6 redirects (default) disabled" "sysctl -n net.ipv6.conf.default.accept_redirects" "^0$"
    run_check "ASLR enabled" "sysctl -n kernel.randomize_va_space" "^2$"
    run_check "Kernel pointer exposure restricted" "sysctl -n kernel.kptr_restrict" "^2$"
    run_check "Kernel logs restricted" "sysctl -n kernel.dmesg_restrict" "^1$"
    run_check "Setuid core dumps disabled" "sysctl -n fs.suid_dumpable" "^0$"
    run_check "Hardlink protection enabled" "sysctl -n fs.protected_hardlinks" "^1$"
    run_check "Symlink protection enabled" "sysctl -n fs.protected_symlinks" "^1$"

    echo ""
    echo "=== Backup Configuration ==="
    if [[ -f /etc/restic/b2.env ]]; then
        run_check "Restic installed" "command -v restic" "."
        run_check "B2 credentials configured" "cat /etc/restic/b2.env | grep B2_ACCOUNT_ID" "B2_ACCOUNT_ID"
        run_check "Restic repository accessible" "source /etc/restic/b2.env && restic snapshots 2>&1 | head -1" "[a-f0-9]+"
    else
        TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
        SKIPPED_CHECKS=$((SKIPPED_CHECKS + 1))
        printf "%-40s " "Backup:"
        echo "- SKIPPED (not configured - /etc/restic/b2.env absent)"
    fi

    echo ""
    echo "=== Summary ==="
    echo "Total checks: $TOTAL_CHECKS"
    echo "Passed:       $PASSED_CHECKS"
    echo "Failed:       $FAILED_CHECKS"
    echo "Skipped:      $SKIPPED_CHECKS"

    if [[ $FAILED_CHECKS -eq 0 ]]; then
        echo ""
        echo "✓ All checks passed!"
        exit 0
    else
        echo ""
        echo "✗ Some checks failed. Review the output above."
        exit 1
    fi
fi

# Ensure interactive reads work even when piped (curl | bash)
# Redirect all reads from /dev/tty
exec 3</dev/tty || { echo "ERROR: No terminal available for interactive input"; exit 1; }

# Handle both direct execution and sourcing
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44"

BOOTSTRAP_SOURCE_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    BOOTSTRAP_SOURCE_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
fi

verify_artifact_manifest() {
    local directory=$1 manifest="$1/$ARTIFACT_MANIFEST_FILE"
    local signature="$1/$ARTIFACT_SIGNATURE_FILE" public_key="$1/public-key.pem"
    local key_id signature_key_id signature_value trusted_public_key

    command -v openssl >/dev/null 2>&1 || return 1
    command -v base64 >/dev/null 2>&1 || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    curl -sfL "$REPO_URL/$ARTIFACT_MANIFEST_FILE" > "$manifest" 2>/dev/null || return 1
    curl -sfL "$REPO_URL/$ARTIFACT_SIGNATURE_FILE" > "$signature" 2>/dev/null || return 1
    mapfile -t key_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$manifest" || true)
    [[ ${#key_ids[@]} -eq 1 ]] || return 1
    key_id=${key_ids[0]#key_id=}
    trusted_public_key=""
    for key_index in "${!ARTIFACT_TRUSTED_KEY_IDS[@]}"; do
        if [[ "$key_id" == "${ARTIFACT_TRUSTED_KEY_IDS[$key_index]}" ]]; then
            trusted_public_key="${ARTIFACT_TRUSTED_PUBLIC_KEYS[$key_index]}"
            break
        fi
    done
    [[ -n "$trusted_public_key" ]] || return 1
    printf '%s\n' "$trusted_public_key" > "$public_key"
    mapfile -t signature_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$signature" || true)
    [[ ${#signature_ids[@]} -eq 1 && "${signature_ids[0]#key_id=}" == "$key_id" ]] || return 1
    mapfile -t signatures < <(grep -E '^signature=[A-Za-z0-9+/]+=*$' "$signature" || true)
    [[ ${#signatures[@]} -eq 1 ]] || return 1
    signature_value=${signatures[0]#signature=}
    printf '%s' "$signature_value" | base64 --decode > "$directory/signature.bin" 2>/dev/null || return 1
    openssl dgst -sha256 -verify "$public_key" -signature "$directory/signature.bin" "$manifest" >/dev/null 2>&1 || return 1
}

manifest_artifact_hash() {
    local manifest=$1 artifact=$2
    mapfile -t hashes < <(grep -E "^artifact=${artifact//./\.} [0-9a-f]{64}$" "$manifest" || true)
    [[ ${#hashes[@]} -eq 1 ]] || return 1
    printf '%s\n' "${hashes[0]##* }"
}

verify_artifact_file() {
    local manifest=$1 artifact=$2 path=$3 expected actual
    expected=$(manifest_artifact_hash "$manifest" "$artifact") || return 1
    actual=$(sha256sum "$path" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]]
}

echo "=== Hetzner EX44 Bootstrap v${VERSION} ==="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Run as root"
   exit 1
fi

# ===========================================
# Configuration storage
# ===========================================
CONFIG_DIR="/etc/bootstrap"
CONFIG_FILE="$CONFIG_DIR/config"
HARDWARE_UUID=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || echo "unknown")

# Initialize variables with defaults to avoid unbound variable errors
NEW_HOSTNAME=""
USERS=()
B2_BUCKET=""
B2_PATH_PREFIX=""
B2_ACCOUNT_ID=""
# SOPS passes these values through the environment for one bootstrap process.
# Keep the input names distinct from the runtime B2/restic variables so an
# accidentally inherited environment cannot be mistaken for SOPS input.
SOPS_B2_APPLICATION_KEY="${BOOTSTRAP_B2_APPLICATION_KEY:-}"
SOPS_RESTIC_PASSWORD="${BOOTSTRAP_RESTIC_PASSWORD:-}"
B2_ACCOUNT_KEY=""
RESTIC_PASSWORD=""
REBOOT_AFTER_BOOTSTRAP=false
BACKUP_CONFIGURED=false
RESTORE_FROM_BACKUP=false
TAILSCALE_AUTHKEY=""
TAILSCALE_AUTHKEY_FILE=""
CLOUDFLARED_TOKEN=""
ARTIFACT_MANIFEST_DIR=""

# Remove the temporary enrollment input even if an unexpected command failure
# exits the script between creating it and the normal cleanup below.
cleanup_tailscale_authkey_file() {
    if [[ -n "${TAILSCALE_AUTHKEY_FILE:-}" ]]; then
        rm -f -- "$TAILSCALE_AUTHKEY_FILE"
    fi
    if [[ -n "${ARTIFACT_MANIFEST_DIR:-}" ]]; then
        rm -rf -- "$ARTIFACT_MANIFEST_DIR"
    fi
}
trap cleanup_tailscale_authkey_file EXIT

# A SOPS environment file must contain both backup secrets. Do not silently
# combine one SOPS value with one OpenBao value or an interactive prompt.
SOPS_SECRETS_AVAILABLE=false
if [[ -n "$SOPS_B2_APPLICATION_KEY" || -n "$SOPS_RESTIC_PASSWORD" ]]; then
    if [[ -z "$SOPS_B2_APPLICATION_KEY" || -z "$SOPS_RESTIC_PASSWORD" ]]; then
        echo "ERROR: SOPS bootstrap input must provide both backup secrets" >&2
        echo "       (BOOTSTRAP_B2_APPLICATION_KEY and BOOTSTRAP_RESTIC_PASSWORD)." >&2
        exit 1
    fi
    B2_ACCOUNT_KEY="$SOPS_B2_APPLICATION_KEY"
    RESTIC_PASSWORD="$SOPS_RESTIC_PASSWORD"
    SOPS_SECRETS_AVAILABLE=true
fi
# Do not pass the SOPS-specific names to child processes after capturing them.
unset BOOTSTRAP_B2_APPLICATION_KEY BOOTSTRAP_RESTIC_PASSWORD
unset SOPS_B2_APPLICATION_KEY SOPS_RESTIC_PASSWORD

# Function to save configuration (non-sensitive values only)
save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONFIGEOF
# Bootstrap configuration - saved $(date)
# Non-sensitive values only. Secrets are prompted each run.
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
USERS="${USERS[*]:-}"
B2_BUCKET="${B2_BUCKET:-}"
B2_PATH_PREFIX="${B2_PATH_PREFIX:-}"
B2_ACCOUNT_ID="${B2_ACCOUNT_ID:-}"
REBOOT_AFTER_BOOTSTRAP="${REBOOT_AFTER_BOOTSTRAP:-false}"
CONFIGEOF
    chmod 600 "$CONFIG_FILE"
}

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        # Convert USERS string back to array (use default if empty)
        read -ra USERS <<< "${USERS:-}"
        # Strip any trailing UUID from B2_PATH_PREFIX (fix for corrupted configs)
        B2_PATH_PREFIX="${B2_PATH_PREFIX%/$HARDWARE_UUID}"
        return 0
    fi
    return 1
}

# ===========================================
# Collect all inputs upfront
# ===========================================
echo ""

USE_PREVIOUS_CONFIG=false

# Check for previous configuration
if load_config; then
    echo "Previous configuration found:"
    echo "  Hostname: $NEW_HOSTNAME"
    echo "  Users: ${USERS[*]}"
    echo "  B2 Bucket: ${B2_BUCKET:-<not configured>}"
    echo "  B2 Path Prefix: ${B2_PATH_PREFIX:-<not configured>}"
    echo "  B2 Account ID: ${B2_ACCOUNT_ID:-<not configured>}"
    echo "  Reboot after: $REBOOT_AFTER_BOOTSTRAP"
    echo ""
    read -p "Use previous configuration? [Y/n]: " USE_PREV <&3
    if [[ ! "$USE_PREV" =~ ^[Nn]$ ]]; then
        USE_PREVIOUS_CONFIG=true
        echo "Using previous configuration. Will prompt for secrets only."
    fi
fi

if ! $USE_PREVIOUS_CONFIG; then
    echo "Enter configuration values. Script will run unattended after this."
    echo ""

    # Hostname
    CURRENT_HOSTNAME=$(hostname)
    read -p "Hostname [$CURRENT_HOSTNAME]: " NEW_HOSTNAME <&3
    NEW_HOSTNAME="${NEW_HOSTNAME:-$CURRENT_HOSTNAME}"

    # Users to create
    echo ""
    echo "Users to create (enter each username, empty line to finish)"
    USERS=()
    while true; do
        if [[ ${#USERS[@]} -eq 0 ]]; then
            read -p "Username (or Enter for default 'coding'): " USERNAME <&3
            if [[ -z "$USERNAME" ]]; then
                USERS=("coding" "trading")
                echo "Using default users: coding, trading"
                break
            fi
        else
            read -p "Username (or Enter to finish): " USERNAME <&3
            if [[ -z "$USERNAME" ]]; then
                break
            fi
        fi
        # Validate username (lowercase, alphanumeric, underscore, hyphen)
        if [[ ! "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            echo "Invalid username. Use lowercase letters, numbers, underscore, hyphen."
            continue
        fi
        USERS+=("$USERNAME")
        echo "  Added: $USERNAME"
    done
    echo "Users to create: ${USERS[*]}"

    # B2 Backup configuration (non-sensitive parts)
    echo ""
    echo "Backblaze B2 Backup Configuration"
    echo "  Hardware UUID: $HARDWARE_UUID"
    echo "  (Leave Bucket name empty to skip backup setup)"
    echo ""
    read -p "B2 Bucket name: " B2_BUCKET <&3
    read -p "B2 Path prefix [hetzner-ex44]: " B2_PATH_PREFIX <&3
    B2_PATH_PREFIX="${B2_PATH_PREFIX:-hetzner-ex44}"
    read -p "B2 Account ID (or Key ID): " B2_ACCOUNT_ID <&3

    # Reboot after completion?
    echo ""
    read -p "Reboot automatically after bootstrap? [y/N]: " REBOOT_AFTER <&3
    REBOOT_AFTER_BOOTSTRAP=false
    [[ "$REBOOT_AFTER" =~ ^[Yy]$ ]] && REBOOT_AFTER_BOOTSTRAP=true
fi

# ===========================================
# Prompt for secrets (always required unless supplied by SOPS/OpenBao)
# ===========================================
echo ""
echo "--- Secrets (required each run) ---"

# Tailscale - check if already connected
if command -v tailscale &>/dev/null && tailscale status &>/dev/null 2>&1; then
    echo "Tailscale already connected, skipping auth key."
    TAILSCALE_AUTHKEY=""
else
    read -rsp "Tailscale auth key (input hidden; tskey-auth-...): " TAILSCALE_AUTHKEY <&3
    echo ""
    if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
        echo "ERROR: Tailscale auth key is required"
        exit 1
    fi
fi

# Cloudflared tunnel token (optional)
echo ""
read -p "Cloudflared tunnel token (leave empty to skip): " CLOUDFLARED_TOKEN <&3
if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
    echo "Cloudflared will be installed and configured."
else
    echo "Skipping cloudflared installation."
fi

# Function to fetch secrets from OpenBao (optional)
# Returns 0 if secrets were found and populated, 1 otherwise
#
# Expected OpenBao secret structure at secret/bootstrap/<hardware-uuid>/b2:
# {
#   "data": {
#     "data": {
#       "b2_application_key": "...",
#       "restic_password": "..."
#     }
#   }
# }
fetch_secrets_from_openbao() {
    local openbao_addr="https://traefik-rs-manager:8200"
    local secret_path="secret/bootstrap/${HARDWARE_UUID}/b2"

    # Only try if Tailscale is running (OpenBao is accessed over tailnet)
    if ! systemctl is-active --quiet tailscaled; then
        return 1
    fi

    echo "Checking OpenBao for pre-provisioned secrets at $openbao_addr..."

    if [[ -z "${OPENBAO_TOKEN:-}" ]]; then
        echo "No OpenBao token provided or OpenBao unreachable."
        return 1
    fi

    # Keep the token out of curl's argv and logs. curl accepts a header file;
    # the temporary file is private and removed before the response is parsed.
    local header_file secret_response
    header_file=$(mktemp)
    chmod 600 "$header_file"
    printf 'X-Vault-Token: %s\n' "$OPENBAO_TOKEN" > "$header_file"

    # Fetch and parse the secret response
    if ! secret_response=$(timeout 5 curl -fsk -X GET \
        "${openbao_addr}/v1/${secret_path}" \
        -H "@$header_file" 2>/dev/null); then
        rm -f -- "$header_file"
        echo "No OpenBao token provided or OpenBao unreachable."
        return 1
    fi
    rm -f -- "$header_file"

    # Check if the secret exists
    if ! echo "$secret_response" | jq -e '.data.data' &>/dev/null; then
        echo "No secrets found at OpenBao path: ${secret_path}"
        return 1
    fi

    # Extract values using jq
    local b2_key restic_pass
    b2_key=$(echo "$secret_response" | jq -r '.data.data.b2_application_key // empty')
    restic_pass=$(echo "$secret_response" | jq -r '.data.data.restic_password // empty')

    if [[ -z "$b2_key" || -z "$restic_pass" ]]; then
        echo "OpenBao secret exists but missing required fields (b2_application_key, restic_password)"
        return 1
    fi

    # Populate the variables
    B2_ACCOUNT_KEY="$b2_key"
    RESTIC_PASSWORD="$restic_pass"
    RESTIC_PASSWORD_CONFIRM="$restic_pass"

    echo "Secrets retrieved from OpenBao."
    return 0
}

# B2 secrets
BACKUP_CONFIGURED=false
RESTORE_FROM_BACKUP=false

if [[ -n "$B2_BUCKET" && -n "$B2_ACCOUNT_ID" ]]; then
    SECRETS_ALREADY_AVAILABLE="$SOPS_SECRETS_AVAILABLE"
    if $SOPS_SECRETS_AVAILABLE; then
        echo "Using backup secrets supplied by SOPS through the process environment."
    elif [[ -n "${OPENBAO_TOKEN:-}" ]] && command -v tailscale &>/dev/null && systemctl is-active --quiet tailscaled; then
        echo "Attempting to fetch B2 secrets from OpenBao..."
        if fetch_secrets_from_openbao; then
            SECRETS_ALREADY_AVAILABLE=true
        fi
    elif [[ -n "${OPENBAO_TOKEN:-}" ]]; then
        echo "Note: OPENBAO_TOKEN set, but Tailscale not running yet."
        echo "OpenBao fetch requires Tailscale connectivity. Falling back to interactive prompt."
        echo "On re-run with Tailscale active, secrets will be fetched automatically."
    fi

    # Fall back to interactive prompts if neither SOPS nor OpenBao worked.
    if ! $SECRETS_ALREADY_AVAILABLE; then
        echo ""
        read -p "B2 Application Key: " B2_ACCOUNT_KEY <&3
    fi

    if [[ -n "$B2_ACCOUNT_KEY" ]]; then
        if ! $SECRETS_ALREADY_AVAILABLE; then
            read -sp "Backup encryption password: " RESTIC_PASSWORD <&3
            echo ""
            read -sp "Confirm encryption password: " RESTIC_PASSWORD_CONFIRM <&3
            echo ""

            if [[ "$RESTIC_PASSWORD" != "$RESTIC_PASSWORD_CONFIRM" ]]; then
                echo "ERROR: Passwords do not match"
                exit 1
            fi
        fi

        # Show masked password for confirmation
        if [[ ${#RESTIC_PASSWORD} -ge 8 ]]; then
            MASK_LEN=$((${#RESTIC_PASSWORD} - 8))
            MASK=$(printf '%*s' "$MASK_LEN" | tr ' ' '*')
            echo "Password set: ${RESTIC_PASSWORD:0:4}${MASK}${RESTIC_PASSWORD: -4}"
        else
            echo "Password set: ****"
        fi

        BACKUP_CONFIGURED=true

        # Check if backup exists (test connection)
        echo ""
        echo "Checking for existing backup..."
        export B2_ACCOUNT_ID B2_ACCOUNT_KEY RESTIC_PASSWORD
        export RESTIC_REPOSITORY="b2:$B2_BUCKET:$B2_PATH_PREFIX/$HARDWARE_UUID"

        if restic snapshots &>/dev/null 2>&1; then
            echo "Found existing backup!"
            read -p "Restore from backup after setup? [y/N]: " RESTORE_CONFIRM <&3
            [[ "$RESTORE_CONFIRM" =~ ^[Yy]$ ]] && RESTORE_FROM_BACKUP=true
        else
            echo "No existing backup found. Will create initial backup."
        fi

        # Keep credentials in memory - they're needed for Step 15 backup config
        # Environment is cleared when script exits anyway
        unset RESTIC_REPOSITORY
    else
        echo "Skipping backup configuration (no application key provided)."
    fi
fi

# Save configuration for future runs
save_config

echo ""
echo "==========================================="
echo "Configuration complete. Starting bootstrap..."
echo "==========================================="
echo ""

echo ""
echo "=== Step 1: Configure Hostname ==="
CURRENT_SET_HOSTNAME=$(hostname)
if [[ "$CURRENT_SET_HOSTNAME" != "$NEW_HOSTNAME" ]]; then
    echo "Setting hostname to: $NEW_HOSTNAME"
    hostnamectl set-hostname "$NEW_HOSTNAME"
else
    echo "Hostname already set to: $NEW_HOSTNAME"
fi

# Update /etc/hosts (idempotent)
if ! grep -q "127.0.1.1.*$NEW_HOSTNAME" /etc/hosts; then
    # Remove any existing 127.0.1.1 line and add new one
    sed -i '/127.0.1.1/d' /etc/hosts
    echo "127.0.1.1	$NEW_HOSTNAME" >> /etc/hosts
    echo "Updated /etc/hosts"
else
    echo "/etc/hosts already configured"
fi

echo ""
echo "=== Step 2: Configure Timezone, Locale, NTP, and DNS ==="

# Set timezone to America/New_York (idempotent)
CURRENT_TZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "")
if [[ "$CURRENT_TZ" != "America/New_York" ]]; then
    echo "Setting timezone to America/New_York..."
    timedatectl set-timezone America/New_York
else
    echo "Timezone already set to America/New_York"
fi

# Configure locale (UTF-8) - idempotent
if ! locale -a 2>/dev/null | grep -q "en_US.utf8"; then
    echo "Configuring locale (en_US.UTF-8)..."
    apt-get install -y locales
    sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
    locale-gen en_US.UTF-8
    update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
else
    echo "Locale en_US.UTF-8 already configured"
fi

# Enable NTP (idempotent)
if [[ "$(timedatectl show --property=NTP --value 2>/dev/null)" != "yes" ]]; then
    echo "Enabling NTP time synchronization..."
    timedatectl set-ntp true
else
    echo "NTP already enabled"
fi

# Detect IPv6-only (test actual IPv4 connectivity, not just addresses)
IPV6_ONLY=false
echo "Testing network connectivity..."
if ! ping -4 -c 1 -W 3 1.1.1.1 &>/dev/null; then
    IPV6_ONLY=true
    echo "No IPv4 connectivity - will use Hetzner DNS64 for NAT64"
else
    echo "IPv4 connectivity confirmed"
fi

# Configure DNS based on network type
if $IPV6_ONLY; then
    echo "Configuring DNS (Hetzner DNS64 for NAT64)..."
    DNS_PRIMARY="2a01:4ff:ff00::add:1"
    DNS_SECONDARY="2a01:4ff:ff00::add:2"
    DNS_DISPLAY="Hetzner DNS64 (NAT64)"
else
    echo "Configuring DNS (Cloudflare)..."
    DNS_PRIMARY="1.1.1.1"
    DNS_SECONDARY="1.0.0.1"
    DNS_DISPLAY="Cloudflare (1.1.1.1)"
fi

# First, ensure we have working DNS by setting resolv.conf directly
# This is a fallback that works regardless of systemd-resolved state
if ! getent hosts debian.org &>/dev/null; then
    echo "DNS not working, setting direct nameserver..."
    rm -f /etc/resolv.conf
    echo -e "nameserver $DNS_PRIMARY\nnameserver $DNS_SECONDARY" > /etc/resolv.conf
fi

# Configure systemd-resolved if available
if command -v systemctl &>/dev/null && systemctl list-unit-files systemd-resolved.service &>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    if $IPV6_ONLY; then
        cat > /etc/systemd/resolved.conf.d/dns.conf << DNSCONF
[Resolve]
DNS=$DNS_PRIMARY $DNS_SECONDARY
# No fallback for IPv6-only - Hetzner DNS64 required for NAT64
DNSOverTLS=no
DNSCONF
    else
        cat > /etc/systemd/resolved.conf.d/dns.conf << 'DNSCONF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
DNSOverTLS=opportunistic
DNSCONF
    fi

    # Enable and start systemd-resolved
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl restart systemd-resolved 2>/dev/null || true

    # Only switch to stub-resolv if resolved is actually running
    if systemctl is-active --quiet systemd-resolved; then
        # Backup current resolv.conf if it's not already a symlink
        if [[ ! -L /etc/resolv.conf ]]; then
            cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true
        fi
        ln -sf ../run/systemd/resolve/stub-resolv.conf /etc/resolv.conf 2>/dev/null || true
    fi
fi

# Verify DNS is working
if ! getent hosts debian.org &>/dev/null; then
    echo "WARNING: DNS still not working, falling back to direct config..."
    rm -f /etc/resolv.conf
    echo -e "nameserver $DNS_PRIMARY\nnameserver $DNS_SECONDARY" > /etc/resolv.conf
fi

# Verify settings
echo "Timezone: $(timedatectl show --property=Timezone --value)"
echo "NTP: $(timedatectl show --property=NTP --value)"
echo "DNS: $(resolvectl status 2>/dev/null | grep "DNS Servers" | head -1 || echo "configured")"

echo ""
echo "=== Step 3: System Update ==="

# Suppress all interactive prompts for apt
export DEBIAN_FRONTEND=noninteractive

# Configure needrestart to auto-restart services without prompting
mkdir -p /etc/needrestart/conf.d
cat > /etc/needrestart/conf.d/no-prompt.conf << 'EOF'
# Restart services automatically without prompting
$nrconf{restart} = 'a';
EOF

apt-get update
apt-get upgrade -y

echo ""
echo "=== Step 4: Installing Packages ==="

# Helper function to install packages with fallback
install_packages() {
    local failed=()
    for pkg in "$@"; do
        if ! apt-get install -y "$pkg" 2>/dev/null; then
            echo "Warning: Package '$pkg' not available, skipping..."
            failed+=("$pkg")
        fi
    done
    if [[ ${#failed[@]} -gt 0 ]]; then
        echo "Skipped packages: ${failed[*]}"
    fi
}

# Core utilities (required - fail if missing)
apt-get install -y \
    curl \
    openssl \
    wget \
    git \
    tmux \
    vim \
    htop \
    jq \
    unzip \
    zip \
    tree \
    file \
    less \
    man-db

# Core utilities (optional - may not exist on all distros)
install_packages neovim ncdu

# Modern CLI tools (optional - names vary by distro)
install_packages \
    ripgrep \
    fd-find \
    bat \
    fzf \
    eza \
    exa \
    httpie \
    silversearcher-ag

# yq - not in standard repos, install via binary
if ! command -v yq &>/dev/null; then
    echo "Installing yq ${YQ_VERSION} from GitHub releases..."
    ARCH=$(dpkg --print-architecture)
    curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq || echo "Warning: Failed to install yq"
fi

# Network tools
apt-get install -y \
    dnsutils \
    net-tools \
    iptables \
    netcat-openbsd \
    tcpdump \
    mtr-tiny \
    whois

# Security tools
apt-get install -y \
    fail2ban \
    ufw \
    unattended-upgrades \
    apt-listchanges \
    auditd

# Security tools (optional)
install_packages needrestart rkhunter chkrootkit libpam-tmpdir

# Development tools
apt-get install -y \
    build-essential \
    python3 \
    python3-pip \
    python3-venv

# Node.js (may need nodesource for newer versions)
install_packages nodejs npm

# GitHub CLI (idempotent)
if ! command -v gh &>/dev/null; then
    echo "Installing GitHub CLI..."
    if curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /tmp/githubcli.gpg; then
        install -m 0644 /tmp/githubcli.gpg /usr/share/keyrings/githubcli-archive-keyring.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
        apt-get update
        apt-get install -y gh || echo "Warning: Failed to install GitHub CLI"
        rm -f /tmp/githubcli.gpg
    else
        echo "Warning: Failed to fetch GitHub CLI keyring"
    fi
else
    echo "GitHub CLI already installed"
fi

# System tools
apt-get install -y \
    lsof \
    strace \
    sysstat

# System tools (optional)
install_packages iotop nload vnstat duf

echo ""
echo "=== Authenticating Bootstrap Artifacts ==="
if [[ -z "$BOOTSTRAP_SOURCE_PATH" ]]; then
    echo "ERROR: bootstrap must be downloaded to a file and verified before execution" >&2
    echo "       Do not pipe an unverified raw HTTPS response directly to bash." >&2
    exit 1
fi

ARTIFACT_MANIFEST_DIR=$(mktemp -d /run/bootstrap-artifacts.XXXXXX)

if ! verify_artifact_manifest "$ARTIFACT_MANIFEST_DIR"; then
    echo "ERROR: signed artifact manifest verification failed" >&2
    echo "       Bootstrap stopped; no downloaded artifact is trusted." >&2
    exit 1
fi
if ! verify_artifact_file \
    "$ARTIFACT_MANIFEST_DIR/$ARTIFACT_MANIFEST_FILE" \
    "bootstrap-${VERSION}.sh" "$BOOTSTRAP_SOURCE_PATH"; then
    echo "ERROR: this bootstrap file is not the signed bootstrap-${VERSION}.sh artifact" >&2
    exit 1
fi
echo "Verified signed bootstrap-${VERSION}.sh artifact."

# Fetch SSH keys only after authenticating the manifest. The required key is
# verified against its signed digest before it is written to any account.
echo "Fetching and authenticating SSH public keys from repo..."
SSH_KEY_DIR="$ARTIFACT_MANIFEST_DIR/keys"
mkdir -p "$SSH_KEY_DIR"
if ! curl -sfL "$REPO_URL/keys/jedarden.pub" > "$SSH_KEY_DIR/jedarden.pub" 2>/dev/null ||
    ! verify_artifact_file "$ARTIFACT_MANIFEST_DIR/$ARTIFACT_MANIFEST_FILE" \
        "keys/jedarden.pub" "$SSH_KEY_DIR/jedarden.pub"; then
    echo "ERROR: signed SSH key verification failed (jedarden.pub)" >&2
    exit 1
fi
SSH_KEY_1=$(<"$SSH_KEY_DIR/jedarden.pub")

SSH_KEY_2=""
if curl -sfL "$REPO_URL/keys/jeda-mbp.pub" > "$SSH_KEY_DIR/jeda-mbp.pub" 2>/dev/null &&
    verify_artifact_file "$ARTIFACT_MANIFEST_DIR/$ARTIFACT_MANIFEST_FILE" \
        "keys/jeda-mbp.pub" "$SSH_KEY_DIR/jeda-mbp.pub"; then
    SSH_KEY_2=$(<"$SSH_KEY_DIR/jeda-mbp.pub")
else
    rm -f "$SSH_KEY_DIR/jeda-mbp.pub"
    echo "Warning: optional SSH key jeda-mbp.pub was unavailable or failed verification; continuing without it." >&2
fi

SSH_PUBLIC_KEYS="$SSH_KEY_1"
[[ -n "$SSH_KEY_2" ]] && SSH_PUBLIC_KEYS="$SSH_PUBLIC_KEYS
$SSH_KEY_2"

echo ""
echo "=== Step 5: Installing kubectl ==="

# Install kubectl if not present (idempotent)
if command -v kubectl &>/dev/null; then
    echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    ARCH=$(dpkg --print-architecture)
    echo "Installing kubectl ${KUBECTL_VERSION} for $ARCH..."

    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
    curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"

    # Verify checksum
    echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
    if [[ $? -ne 0 ]]; then
        echo "ERROR: kubectl checksum verification failed"
        exit 1
    fi

    chmod +x kubectl
    mv kubectl /usr/local/bin/kubectl
    rm kubectl.sha256

    echo "kubectl installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
fi

echo ""
echo "=== Step 6: Creating Users ==="
echo "Creating users: ${USERS[*]}"

for user in "${USERS[@]}"; do
    echo "Creating user: $user"

    # Create user if doesn't exist
    id "$user" &>/dev/null || useradd -m -s /bin/bash "$user"

    # Add to sudo group for admin access
    usermod -aG sudo "$user"

    # Set up SSH directory and keys
    mkdir -p "/home/$user/.ssh"
    echo "$SSH_PUBLIC_KEYS" > "/home/$user/.ssh/authorized_keys"
    chmod 700 "/home/$user/.ssh"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    chown -R "$user:$user" "/home/$user/.ssh"

    # Set up isolated directories
    mkdir -p "/home/$user/.tmp"
    mkdir -p "/home/$user/.cache"
    mkdir -p "/home/$user/workspace"
    chown -R "$user:$user" "/home/$user"

    # Configure bashrc (idempotent - check for marker)
    if ! grep -q "# === Security: Isolated temp directory ===" "/home/$user/.bashrc" 2>/dev/null; then
        cat >> "/home/$user/.bashrc" << 'BASHRC'

# === Security: Isolated temp directory ===
export TMPDIR="$HOME/.tmp"
export XDG_CACHE_HOME="$HOME/.cache"

# === Aliases ===
alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias gs='git status'
alias gd='git diff'
alias gp='git pull'
alias gc='git commit'
alias ga='git add'
alias ..='cd ..'
alias ...='cd ../..'

# Modern tool aliases (if available)
command -v batcat &>/dev/null && alias bat='batcat'
command -v fdfind &>/dev/null && alias fd='fdfind'
command -v exa &>/dev/null && alias ls='exa' && alias ll='exa -la' && alias tree='exa --tree'

# Safety aliases
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# === Prompt with git branch ===
parse_git_branch() {
    git branch 2>/dev/null | sed -n 's/* \(.*\)/ (\1)/p'
}
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '

# === History settings ===
HISTSIZE=10000
HISTFILESIZE=20000
HISTCONTROL=ignoreboth:erasedups
shopt -s histappend

# === FZF ===
[ -f /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
[ -f /usr/share/doc/fzf/examples/completion.bash ] && source /usr/share/doc/fzf/examples/completion.bash
BASHRC
    fi

    chown "$user:$user" "/home/$user/.bashrc"

    # tmux config
    cat > "/home/$user/.tmux.conf" << 'TMUXCONF'
# Remap prefix to Ctrl-a
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Enable mouse
set -g mouse on

# Start windows at 1
set -g base-index 1
setw -g pane-base-index 1

# Better colors
set -g default-terminal "screen-256color"

# Faster escape
set -sg escape-time 10

# History (kept modest deliberately - see the OOM-protection note below;
# large scrollback across many sessions was a contributing factor in the
# 2026-05-25 tmux-server OOM incident)
set -g history-limit 2000

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded!"
TMUXCONF
    chown "$user:$user" "/home/$user/.tmux.conf"
done

echo ""
echo "=== Step 7: SSH Hardening ==="

# Build AllowUsers list from configured users
ALLOW_USERS_LIST="${USERS[*]:-}"

cat > /etc/ssh/sshd_config.d/hardening.conf << SSHCONF
# === SSH Hardening Configuration ===

# Authentication
# PermitRootLogin set to prohibit-password (key-only) for Hetzner rescue network emergency access
# This enables root login via SSH keys from the Hetzner rescue network while blocking password auth
PermitRootLogin prohibit-password
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
ChallengeResponseAuthentication no
UsePAM yes

# Allowed users (dynamically configured)
# root included for Hetzner rescue network emergency access path (documented in Recovery section)
AllowUsers root $ALLOW_USERS_LIST

# Security limits
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused features
X11Forwarding no
# AllowTcpForwarding enabled for VS Code Remote SSH port forwarding support
AllowTcpForwarding yes
AllowAgentForwarding no
PermitTunnel no
GatewayPorts no
PermitUserEnvironment no

# Logging
LogLevel VERBOSE
SyslogFacility AUTH

# Protocol hardening
Protocol 2
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org
SSHCONF

# Keep the effective SSH policy immutable to unprivileged users even when the
# invoking environment has a permissive umask.
chmod 644 /etc/ssh/sshd_config.d/hardening.conf

# Test SSH config before applying
sshd -t || {
    echo "ERROR: SSH config invalid"
    exit 1
}

echo ""
echo "=== Step 8: Kernel Hardening (sysctl) ==="
cat > /etc/sysctl.d/99-hardening.conf << 'SYSCTL'
# === Kernel Hardening ===

# IP Spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP broadcast requests
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Disable source packet routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0

# Ignore send redirects
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Block SYN attacks
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Log Martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0

# Disable IPv6 if not needed (uncomment to disable)
# net.ipv6.conf.all.disable_ipv6 = 1
# net.ipv6.conf.default.disable_ipv6 = 1

# Memory protections
kernel.randomize_va_space = 2
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1

# Disable core dumps
fs.suid_dumpable = 0

# File system hardening
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
SYSCTL

sysctl --system

echo ""
echo "=== Step 9: Firewall Configuration ==="
# Reset UFW to defaults
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow Tailscale interface (will exist after Tailscale install)
ufw allow in on tailscale0

# Allow SSH from Hetzner rescue networks (emergency access)
ufw allow from 213.133.99.0/24 to any port 22 comment 'Hetzner rescue FSN'
ufw allow from 213.133.100.0/24 to any port 22 comment 'Hetzner rescue FSN'
ufw allow from 88.198.230.0/24 to any port 22 comment 'Hetzner rescue NBG'
ufw allow from 88.198.231.0/24 to any port 22 comment 'Hetzner rescue NBG'

# Enable firewall
ufw --force enable
ufw status verbose

echo ""
echo "=== Step 10: Installing Tailscale ==="

# Install Tailscale if not present (idempotent)
if ! command -v tailscale &>/dev/null; then
    echo "Installing Tailscale..."
    if ! curl -fsSL https://tailscale.com/install.sh | sh; then
        echo "ERROR: Tailscale installation failed"
        exit 1
    fi
else
    echo "Tailscale already installed"
fi

# Tailscale's package installs the tailscaled unit. Keep the daemon enabled
# across reboots and make service readiness an explicit prerequisite for both
# already-enrolled and first-time nodes.
if ! systemctl enable --now tailscaled >/dev/null 2>&1; then
    echo "ERROR: Could not enable or start the tailscaled service"
    echo "       Check: systemctl status tailscaled"
    exit 1
fi
if ! systemctl is-active --quiet tailscaled; then
    echo "ERROR: The tailscaled service is not active"
    echo "       Check: systemctl status tailscaled"
    exit 1
fi

# Start Tailscale with SSH enabled (idempotent). Auth keys are written to a
# private, short-lived file because putting the key in a command argument
# exposes it through process listings and audit tooling. Tailscale supports
# the file: form for --auth-key and reads the file only during enrollment.
if ! tailscale status &>/dev/null; then
    echo "Connecting to Tailscale..."
    TAILSCALE_AUTHKEY_FILE=$(mktemp /run/tailscale-bootstrap-authkey.XXXXXX)
    chmod 600 "$TAILSCALE_AUTHKEY_FILE"
    if ! printf '%s' "$TAILSCALE_AUTHKEY" > "$TAILSCALE_AUTHKEY_FILE"; then
        rm -f -- "$TAILSCALE_AUTHKEY_FILE"
        unset TAILSCALE_AUTHKEY
        echo "ERROR: Could not prepare the Tailscale authentication input"
        exit 1
    fi
    if ! tailscale up --auth-key="file:$TAILSCALE_AUTHKEY_FILE" --ssh >/dev/null 2>&1; then
        rm -f -- "$TAILSCALE_AUTHKEY_FILE"
        unset TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY_FILE
        echo "ERROR: Tailscale authentication failed"
        echo "       Verify the auth key is valid, pre-authorized, and not expired."
        exit 1
    fi
    rm -f -- "$TAILSCALE_AUTHKEY_FILE"
    unset TAILSCALE_AUTHKEY TAILSCALE_AUTHKEY_FILE
else
    echo "Tailscale already connected"
fi

TAILSCALE_STATUS=$(tailscale status 2>/dev/null) || {
    echo "ERROR: Tailscale is not reachable after enrollment"
    echo "       Check: systemctl status tailscaled"
    exit 1
}
if ! grep -Eq '(^|[[:space:]])(100\.|fd7a:)' <<< "$TAILSCALE_STATUS"; then
    echo "ERROR: Tailscale daemon is running but the node is not connected to the mesh"
    echo "       Check: tailscale status"
    exit 1
fi
echo "Tailscale status: connected"

echo ""
echo "=== Step 11: Installing Cloudflared ==="

if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
    # Install cloudflared if not present (idempotent)
    if ! command -v cloudflared &>/dev/null; then
        echo "Installing cloudflared ${CLOUDFLARED_VERSION}..."
        ARCH=$(dpkg --print-architecture)
        curl -fsSL "https://github.com/cloudflare/cloudflared/releases/download/${CLOUDFLARED_VERSION}/cloudflared-linux-${ARCH}.deb" -o /tmp/cloudflared.deb
        dpkg -i /tmp/cloudflared.deb
        rm -f /tmp/cloudflared.deb
    else
        echo "cloudflared already installed"
    fi

    # Install cloudflared as a service with the provided token (idempotent)
    if ! systemctl is-active --quiet cloudflared 2>/dev/null; then
        echo "Configuring cloudflared tunnel service..."
        cloudflared service install "$CLOUDFLARED_TOKEN"
    else
        echo "cloudflared service already running"
    fi

    echo "cloudflared status:"
    systemctl status cloudflared --no-pager || true
else
    echo "Skipping cloudflared (no token provided)."
fi

echo ""
echo "=== Step 12: Installing Claude Code ==="

# Helper to check if claude is installed for a user
claude_installed() {
    local home_dir="$1"
    [[ -x "$home_dir/.local/bin/claude" ]] || [[ -x "$home_dir/.claude/local/bin/claude" ]]
}

# Install Claude Code for root (idempotent - installer handles updates)
if ! claude_installed "/root"; then
    echo "Installing Claude Code for root..."
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "Warning: Claude Code installation for root failed, continuing..."
    fi
else
    echo "Claude Code already installed for root"
fi

# Add Claude Code to PATH for all users (idempotent) - check both possible locations
cat > /etc/profile.d/claude-code.sh << 'CLAUDEPATH'
# Claude Code PATH setup
[[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
[[ -d "$HOME/.claude/local/bin" ]] && export PATH="$HOME/.claude/local/bin:$PATH"
CLAUDEPATH
chmod 644 /etc/profile.d/claude-code.sh

# Install Claude Code for each user (idempotent)
for user in "${USERS[@]}"; do
    if ! claude_installed "/home/$user"; then
        echo "Installing Claude Code for user: $user"
        if ! su - "$user" -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
            echo "Warning: Claude Code installation for $user failed, continuing..."
        fi
    else
        echo "Claude Code already installed for $user"
    fi
done

echo ""
echo "=== Step 13: Setting Up start.sh for Users ==="
# Create start.sh for each user with tmux + Claude Code setup
for user in "${USERS[@]}"; do
    echo "Setting up start.sh for user: $user"
    cat > "/home/$user/start.sh" << 'STARTSH'
#!/usr/bin/env bash

# start.sh - Tmux + coding-agent launcher with self-update
#
# Run it as the `start` command: `start claude` or `start codex`. The deployed
# file stays ~/start.sh (the path self-update and the sync script key on);
# ~/.local/bin/start is a symlink to it, created by bootstrap.sh and, on hosts
# that predate it, by ensure_start_command below.
#
# Launches an interactive coding agent - claude or codex. On a bare shell it
# creates a phonetic-alphabet tmux session and starts the agent inside it.
# When something is already multiplexing - a herdr pane (HERDR_ENV, injected
# into every pane herdr spawns) or an existing tmux client ($TMUX) - it skips
# tmux entirely and execs the agent in the current pane instead of nesting.
#
# This file is the single canonical copy. bootstrap.sh embeds a byte-for-byte
# copy of it in a heredoc (Step 13) so freshly-bootstrapped hosts get it on
# first run; every host's copy self-updates from this file afterward (see
# check_for_self_update below). Never hand-edit a deployed ~/start.sh on a
# host and never edit only one of the two copies in this repo - run
# hosts/ex44/sync-start-sh.sh after any change here to regenerate
# bootstrap.sh's embedded copy, then commit both together. See
# docs/plan/plan.md ADR-1 for why (a hand-patched host copy and a corrupted
# embedded copy both went undetected in the wild before this rule existed).
START_SH_VERSION="1.3.1"
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44"
ARTIFACT_MANIFEST_FILE="artifact-manifest.txt"
ARTIFACT_SIGNATURE_FILE="artifact-manifest.sig"
ARTIFACT_TRUSTED_KEY_ID="bootstrap-rsa-2026-10"
ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'
-----BEGIN PUBLIC KEY-----
MIIBojANBgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEApNHGqYPfKvRpLulWXS8c
/VuKITatXEhDqrXY4/0ug9SqlZF8e/o3q6FVgbMqdRTniDOrhgx1mUcbzpFJ4Y6Z
ILcYmIEXne12A2BxHh2SF+9uXBAbwNdlEIXunybhGT4te32UKGGqRN7TdFpr6KsN
nSSNN2/WyvjL+ytqpa2KyguXkrGHSfwDdUDKDGYmL1eZHjhP2GrWxG6aI8EcMtfp
mAy/NUXxL2tOB8bGz+IPfTsycwcDqZ0mw59vQUy2+nUTnG/xQpWud6SXPMuSJoJ9
3tGGU24gz4vptPn7V/L3rGQp8Titgks0IxpwEXZV2T//wNEXBebGUGaoQfOrGSoC
AzELsxvleqZOKRJyP55Djqh5iELC9tF9yxmCmRLxYwUzYPz234Wf2E0Qi1Vo386e
VxyDwlCe9IIMEgejVkjseahaS5INmFjCoDjH7cZWY28MtTVy1u9/79n6wBkApJeQ
7AuWeqPskkNYJz18R2aRjER6/Ru+2gyXw5fnD3RbpLfzAgMBAAE=
-----END PUBLIC KEY-----
ARTIFACT_KEY
)
ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")
ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")

usage() {
    cat <<'USAGE'
Usage: start [claude|codex] [--agent claude|codex] [--resume <session>] [--no-update] [--version] [--help]

  claude | codex   Coding agent to launch, e.g. `start codex`. Equivalent to
                   --agent <name>; giving both with different values is an error.
  --agent <name>   Coding agent to launch: claude (default) or codex.
                   Also settable via the START_SH_AGENT environment variable.
                   If none of these is given and stdin is a TTY, start prompts;
                   with no TTY it defaults to claude so that scripted or
                   piped invocations never block on the prompt.
  --resume <id>    Resume the named session. Translates to `claude --resume
                   <id>` or `codex resume <id>` for the selected agent.
  --no-update      Skip the start self-update check.
  --version, -v    Print the start version and exit.
  --help, -h       Show this help and exit.
USAGE
}

# Captured before parsing so a self-update re-exec can replay the user's
# original flags (notably --agent) instead of dropping them.
ORIGINAL_ARGS=("$@")

SKIP_UPDATE=false
AGENT=""
POSITIONAL_AGENT=""
RESUME_SESSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version|-v)
            echo "start v${START_SH_VERSION}"
            exit 0
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --no-update)
            SKIP_UPDATE=true
            shift
            ;;
        --agent)
            if [[ -z "${2:-}" ]]; then
                echo "Error: --agent requires a value (claude or codex)" >&2
                exit 1
            fi
            AGENT="$2"
            shift 2
            ;;
        --agent=*)
            AGENT="${1#--agent=}"
            shift
            ;;
        --resume)
            if [[ -z "${2:-}" || "$2" == -* ]]; then
                echo "Error: --resume requires a session ID or name" >&2
                exit 1
            fi
            RESUME_SESSION="$2"
            shift 2
            ;;
        --resume=*)
            RESUME_SESSION="${1#--resume=}"
            if [[ -z "$RESUME_SESSION" ]]; then
                echo "Error: --resume requires a session ID or name" >&2
                exit 1
            fi
            shift
            ;;
        claude|codex)
            if [[ -n "$POSITIONAL_AGENT" ]]; then
                echo "Error: agent given twice: $POSITIONAL_AGENT and $1" >&2
                exit 1
            fi
            POSITIONAL_AGENT="$1"
            shift
            ;;
        -*)
            echo "Error: unknown option: $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            echo "Error: unknown agent '$1' (expected claude or codex)" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if [[ -n "$POSITIONAL_AGENT" ]]; then
    if [[ -n "$AGENT" && "$AGENT" != "$POSITIONAL_AGENT" ]]; then
        echo "Error: conflicting agents: '$POSITIONAL_AGENT' and --agent '$AGENT'" >&2
        exit 1
    fi
    AGENT="$POSITIONAL_AGENT"
fi

# Resolve symlinks so the script behaves identically whether it runs as
# ~/start.sh or through the `start` symlink on PATH (~/.local/bin/start).
# dirname of BASH_SOURCE[0] alone would name the symlink's directory, which
# would relocate the tmux config and point self-update at the wrong file.
SELF_PATH="$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)"
[[ -n "$SELF_PATH" ]] || SELF_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(dirname "$SELF_PATH")"
TMUX_DIR="$SCRIPT_DIR/.tmux"
TMUX_CONF="$TMUX_DIR/tmux.conf"
TPM_DIR="$TMUX_DIR/plugins/tpm"

# Verify a signed release manifest fetched from the raw distribution path.
# The public key is embedded in this launcher so a compromised or stale raw
# response cannot choose a new verification key. A future key rotation must
# ship a transition launcher that trusts both the old and new key while the
# manifest remains signed by the old key.
verify_artifact_manifest() {
    local directory=$1 manifest="$1/$ARTIFACT_MANIFEST_FILE"
    local signature="$1/$ARTIFACT_SIGNATURE_FILE" public_key="$1/public-key.pem"
    local key_id signature_key_id signature_value manifest_version trusted_public_key

    command -v openssl >/dev/null 2>&1 || return 1
    command -v base64 >/dev/null 2>&1 || return 1
    command -v sha256sum >/dev/null 2>&1 || return 1
    curl -sfL "$REPO_URL/$ARTIFACT_MANIFEST_FILE" > "$manifest" 2>/dev/null || return 1
    curl -sfL "$REPO_URL/$ARTIFACT_SIGNATURE_FILE" > "$signature" 2>/dev/null || return 1
    mapfile -t key_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$manifest" || true)
    [[ ${#key_ids[@]} -eq 1 ]] || return 1
    key_id=${key_ids[0]#key_id=}
    trusted_public_key=""
    for key_index in "${!ARTIFACT_TRUSTED_KEY_IDS[@]}"; do
        if [[ "$key_id" == "${ARTIFACT_TRUSTED_KEY_IDS[$key_index]}" ]]; then
            trusted_public_key="${ARTIFACT_TRUSTED_PUBLIC_KEYS[$key_index]}"
            break
        fi
    done
    [[ -n "$trusted_public_key" ]] || return 1
    printf '%s\n' "$trusted_public_key" > "$public_key"

    mapfile -t signature_ids < <(grep -E '^key_id=[A-Za-z0-9._-]+$' "$signature" || true)
    [[ ${#signature_ids[@]} -eq 1 ]] || return 1
    signature_key_id=${signature_ids[0]#key_id=}
    [[ "$signature_key_id" == "$key_id" ]] || return 1
    mapfile -t signatures < <(grep -E '^signature=[A-Za-z0-9+/]+=*$' "$signature" || true)
    [[ ${#signatures[@]} -eq 1 ]] || return 1
    signature_value=${signatures[0]#signature=}
    printf '%s' "$signature_value" | base64 --decode > "$directory/signature.bin" 2>/dev/null || return 1
    openssl dgst -sha256 -verify "$public_key" -signature "$directory/signature.bin" "$manifest" >/dev/null 2>&1 || return 1

    mapfile -t manifest_versions < <(grep -E '^version=[0-9]+\.[0-9]+\.[0-9]+$' "$manifest" || true)
    [[ ${#manifest_versions[@]} -eq 1 ]] || return 1
    manifest_version=${manifest_versions[0]#version=}
    printf '%s\n' "$manifest_version"
}

manifest_artifact_hash() {
    local manifest=$1 artifact=$2
    mapfile -t hashes < <(grep -E "^artifact=${artifact//./\.} [0-9a-f]{64}$" "$manifest" || true)
    [[ ${#hashes[@]} -eq 1 ]] || return 1
    printf '%s\n' "${hashes[0]##* }"
}

verify_artifact_file() {
    local manifest=$1 artifact=$2 path=$3 expected actual payload_version
    expected=$(manifest_artifact_hash "$manifest" "$artifact") || return 1
    actual=$(sha256sum "$path" | awk '{print $1}') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    if [[ "$artifact" == "start.sh" ]]; then
        mapfile -t payload_versions < <(grep -E '^START_SH_VERSION="[0-9]+\.[0-9]+\.[0-9]+"$' "$path" || true)
        [[ ${#payload_versions[@]} -eq 1 ]] || return 1
        payload_version=${payload_versions[0]#START_SH_VERSION=\"}
        payload_version=${payload_version%\"}
        [[ "$payload_version" == "$(grep -E '^version=' "$manifest" | cut -d= -f2)" ]] || return 1
    fi
}

# Self-update function
check_for_self_update() {
    if $SKIP_UPDATE; then
        return 0
    fi

    local manifest_dir remote_version new_script
    manifest_dir=$(mktemp -d "${SELF_PATH}.manifest.XXXXXX") || return 0
    if ! remote_version=$(verify_artifact_manifest "$manifest_dir"); then
        echo "Warning: release manifest verification failed; keeping current start.sh $START_SH_VERSION" >&2
        rm -rf "$manifest_dir"
        return 0
    fi

    # Compare versions
    if [[ "$START_SH_VERSION" != "$remote_version" ]]; then
        local lowest
        lowest=$(printf '%s\n%s' "$START_SH_VERSION" "$remote_version" | sort -V | head -n1)
        if [[ "$START_SH_VERSION" == "$lowest" && "$START_SH_VERSION" != "$remote_version" ]]; then
            echo "Updating start.sh: $START_SH_VERSION -> $remote_version"
            new_script=$(mktemp "${SELF_PATH}.tmp.XXXXXX") || {
                echo "Warning: could not create a temporary start.sh update, keeping current version $START_SH_VERSION" >&2
                rm -rf "$manifest_dir"
                return 0
            }

            # Fetch beside the deployed launcher so the final rename is an
            # atomic replacement on the same filesystem. Never stream a
            # remote response directly into the working launcher.
            if ! curl -sfL "$REPO_URL/start.sh" > "$new_script" 2>/dev/null; then
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 0
            fi

            # Require the signed manifest hash and the payload's own version
            # before the syntax gate. Never install a valid-but-stale script
            # or a payload from a different release.
            if ! verify_artifact_file "$manifest_dir/$ARTIFACT_MANIFEST_FILE" "start.sh" "$new_script" ||
                [[ ! -s "$new_script" ]] || ! bash -n "$new_script" 2>/dev/null; then
                echo "Warning: fetched start.sh failed authenticity, integrity, or syntax checks; keeping current version $START_SH_VERSION" >&2
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 0
            fi

            if ! chmod +x "$new_script" || ! mv -f "$new_script" "$SELF_PATH"; then
                echo "Warning: could not install fetched start.sh, keeping current version $START_SH_VERSION" >&2
                rm -f "$new_script"
                rm -rf "$manifest_dir"
                return 0
            fi

            rm -rf "$manifest_dir"
            echo "Updated! Restarting..."
            exec "$SELF_PATH" --no-update ${ORIGINAL_ARGS[@]+"${ORIGINAL_ARGS[@]}"}
        fi
    fi

    rm -rf "$manifest_dir"
}

check_for_self_update

# Expose the deployed copy as the `start` command. Hosts bootstrapped before
# this existed get the link here, on the first run after self-update lands it.
# Only ever from the deployed location: linking a repo checkout would make
# self-update write through the link into a tracked file. Never replaces an
# existing `start` that is not this script.
ensure_start_command() {
    local deployed link="$HOME/.local/bin/start"
    deployed="$(readlink -f "$HOME" 2>/dev/null)/start.sh"
    [[ "$SELF_PATH" == "$deployed" ]] || return 0

    if [[ -L "$link" && "$(readlink -f "$link" 2>/dev/null)" == "$SELF_PATH" ]]; then
        return 0
    fi
    if [[ -e "$link" || -L "$link" ]]; then
        echo "Note: $link already exists and is not this script - leaving it alone." >&2
        return 0
    fi
    if mkdir -p "$HOME/.local/bin" 2>/dev/null && ln -s "$SELF_PATH" "$link" 2>/dev/null; then
        echo "Installed the 'start' command: $link -> $SELF_PATH"
    fi
}

ensure_start_command

# Phonetic alphabet for tmux session naming
PHONETIC_ALPHABET=(
    "alpha" "bravo" "charlie" "delta" "echo" "foxtrot" "golf" "hotel"
    "india" "juliet" "kilo" "lima" "mike" "november" "oscar" "papa"
    "quebec" "romeo" "sierra" "tango" "uniform" "victor" "whiskey"
    "xray" "yankee" "zulu"
)

# Find the first available phonetic name for a tmux session
find_available_session_name() {
    for name in "${PHONETIC_ALPHABET[@]}"; do
        if ! tmux has-session -t "$name" 2>/dev/null; then
            echo "$name"
            return 0
        fi
    done
    return 1
}

# Install TPM (Tmux Plugin Manager) and plugins
install_tpm() {
    if [[ ! -d "$TPM_DIR" ]]; then
        echo "Installing Tmux Plugin Manager..."
        git clone https://github.com/tmux-plugins/tpm "$TPM_DIR"
    fi
}

# Install tmux plugins
install_plugins() {
    if [[ -x "$TPM_DIR/bin/install_plugins" ]]; then
        echo "Installing tmux plugins..."
        "$TPM_DIR/bin/install_plugins"
    fi
}

# Install or update Claude Code using native installer
install_claude_code() {
    echo "Installing/updating Claude Code via native installer..."
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "Warning: Claude Code installation failed"
        return 1
    fi
}

# Get installed Claude Code version (returns empty string if not installed)
get_installed_claude_version() {
    if command -v claude &>/dev/null; then
        claude --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# Get latest available Claude Code version
get_latest_claude_version() {
    local CLAUDE_RELEASES_URL="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases/latest"
    curl -fsSL "$CLAUDE_RELEASES_URL" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Compare semantic versions: returns 0 if v1 < v2, 1 otherwise
version_lt() {
    local v1="$1" v2="$2"
    [[ "$v1" == "$v2" ]] && return 1
    local lowest
    lowest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -n1)
    [[ "$v1" == "$lowest" ]]
}

# Check if Claude Code needs installation or update
check_and_update_claude() {
    local installed_version latest_version

    # Ensure PATH includes common install locations
    [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
    [[ -d "$HOME/.claude/local/bin" ]] && export PATH="$HOME/.claude/local/bin:$PATH"

    installed_version=$(get_installed_claude_version)
    latest_version=$(get_latest_claude_version)

    if [[ -z "$installed_version" ]]; then
        echo "Claude Code not found. Installing..."
        install_claude_code
        # Re-add paths after install
        [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
        [[ -d "$HOME/.claude/local/bin" ]] && export PATH="$HOME/.claude/local/bin:$PATH"
        if ! command -v claude &>/dev/null; then
            echo "Error: Claude Code installation failed."
            exit 1
        fi
        echo "Claude Code installed successfully: $(get_installed_claude_version)"
    elif [[ -z "$latest_version" ]]; then
        echo "Warning: Could not fetch latest Claude Code version. Skipping update check."
        echo "Current version: $installed_version"
    elif version_lt "$installed_version" "$latest_version"; then
        echo "Claude Code update available: $installed_version -> $latest_version"
        install_claude_code
        local new_version
        new_version=$(get_installed_claude_version)
        echo "Claude Code updated: $installed_version -> $new_version"
    else
        echo "Claude Code is up to date: $installed_version"
    fi
}

# Install or update the Codex CLI. Unlike Claude Code (native installer +
# a published "latest" endpoint) Codex ships as an npm global, so presence,
# version and update all go through npm.
install_codex() {
    if ! command -v npm &>/dev/null; then
        echo "Error: npm is required to install the Codex CLI." >&2
        echo "Install Node.js/npm first, or install Codex manually:" >&2
        echo "  npm install -g @openai/codex" >&2
        return 1
    fi
    echo "Installing/updating Codex CLI via npm..."
    if ! npm install -g @openai/codex@latest; then
        echo "Warning: Codex CLI installation failed"
        return 1
    fi
}

# Get installed Codex CLI version (returns empty string if not installed)
get_installed_codex_version() {
    if command -v codex &>/dev/null; then
        codex --version 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
    fi
}

# Get latest available Codex CLI version from the npm registry
get_latest_codex_version() {
    command -v npm &>/dev/null || return 0
    npm view @openai/codex version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Check if the Codex CLI needs installation or update
check_and_update_codex() {
    local installed_version latest_version

    [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"

    installed_version=$(get_installed_codex_version)
    latest_version=$(get_latest_codex_version)

    if [[ -z "$installed_version" ]]; then
        echo "Codex CLI not found. Installing..."
        install_codex
        [[ -d "$HOME/.local/bin" ]] && export PATH="$HOME/.local/bin:$PATH"
        if ! command -v codex &>/dev/null; then
            echo "Error: Codex CLI installation failed."
            exit 1
        fi
        echo "Codex CLI installed successfully: $(get_installed_codex_version)"
    elif [[ -z "$latest_version" ]]; then
        echo "Warning: Could not fetch latest Codex CLI version. Skipping update check."
        echo "Current version: $installed_version"
    elif version_lt "$installed_version" "$latest_version"; then
        echo "Codex CLI update available: $installed_version -> $latest_version"
        # A failed upgrade is not fatal when a working copy is already present.
        if install_codex; then
            echo "Codex CLI updated: $installed_version -> $(get_installed_codex_version)"
        else
            echo "Continuing with installed version $installed_version"
        fi
    else
        echo "Codex CLI is up to date: $installed_version"
    fi
}

# ---------------------------------------------------------------------------
# Agent selection
#
# Resolution order: --agent flag > $START_SH_AGENT > interactive prompt >
# claude. The prompt is only reached when stdin is a TTY, so a non-interactive
# invocation (`start.sh < /dev/null`, a scripted launch, a cron wrapper) takes
# the claude default silently rather than blocking forever inside `read`.
# ---------------------------------------------------------------------------

validate_agent() {
    case "$1" in
        claude|codex) return 0 ;;
        *) return 1 ;;
    esac
}

# Prompts on stderr, returns the chosen agent on stdout (so the caller can
# capture it with $(...) while the menu still reaches the user's terminal).
prompt_for_agent() {
    local choice
    while true; do
        printf 'Which agent?\n  1) claude  (default)\n  2) codex\n' >&2
        printf 'Choice [1]: ' >&2
        if ! read -r choice; then
            # EOF mid-prompt: take the default instead of spinning forever.
            printf '\n' >&2
            echo "claude"
            return 0
        fi
        case "$choice" in
            ""|1|claude) echo "claude"; return 0 ;;
            2|codex)     echo "codex";  return 0 ;;
            *) echo "Invalid choice: $choice" >&2 ;;
        esac
    done
}

resolve_agent() {
    if [[ -n "$AGENT" ]]; then
        if ! validate_agent "$AGENT"; then
            echo "Error: unsupported --agent '$AGENT' (expected claude or codex)" >&2
            exit 1
        fi
        return 0
    fi

    if [[ -n "${START_SH_AGENT:-}" ]]; then
        if ! validate_agent "$START_SH_AGENT"; then
            echo "Error: unsupported START_SH_AGENT '$START_SH_AGENT' (expected claude or codex)" >&2
            exit 1
        fi
        AGENT="$START_SH_AGENT"
        echo "Agent: $AGENT (from START_SH_AGENT)"
        return 0
    fi

    if [[ -t 0 ]]; then
        AGENT=$(prompt_for_agent)
    else
        AGENT="claude"
        echo "No TTY and no --agent/START_SH_AGENT given - defaulting to claude."
    fi
}

check_and_update_agent() {
    case "$AGENT" in
        claude) check_and_update_claude ;;
        codex)  check_and_update_codex ;;
    esac
}

# Launch argv for the selected agent. Both run with their approval prompts
# disabled, matching what this launcher has always done for Claude Code -
# these are dedicated single-tenant boxes reached only over Tailscale.
set_agent_argv() {
    case "$AGENT" in
        claude)
            AGENT_ARGV=(claude --dangerously-skip-permissions --model sonnet)
            if [[ -n "$RESUME_SESSION" ]]; then
                AGENT_ARGV+=(--resume "$RESUME_SESSION")
            fi
            ;;
        codex)
            if [[ -n "$RESUME_SESSION" ]]; then
                AGENT_ARGV=(codex resume --dangerously-bypass-approvals-and-sandbox "$RESUME_SESSION")
            else
                AGENT_ARGV=(codex --dangerously-bypass-approvals-and-sandbox)
            fi
            ;;
    esac
}

resolve_agent
check_and_update_agent
set_agent_argv

# Inside a herdr pane, herdr is already the multiplexer: creating a tmux
# session here would nest one inside the pane, consume a phonetic name, and
# confuse herdr's screen-manifest status detection. Exec the agent directly
# and let herdr own the pane. The ambient tmux server herdr rides on already
# carries its own OOM protection, so the choom step below is not needed here.
if [[ -n "${HERDR_ENV:-}" ]]; then
    echo "Detected herdr pane ${HERDR_PANE_ID:-unknown} - skipping nested tmux session."
    echo "Launching $AGENT in the current pane..."
    unset CLAUDECODE
    exec "${AGENT_ARGV[@]}"
fi

# Same reasoning one level down: tmux sets $TMUX in every process it spawns,
# so a non-empty value means we are already inside a tmux client. Creating a
# session here would nest a client inside a client, which tmux refuses to
# attach - the pre-v1.2.1 code created the session and launched the agent
# anyway, then failed at attach-session, leaving a detached session running an
# agent nobody was attached to (and consuming a phonetic name for it). Exec in
# the current pane instead. This is checked after the herdr branch above
# because herdr rides on the same ambient tmux server, so a herdr pane has
# both variables set and should report the more specific reason.
if [[ -n "${TMUX:-}" ]]; then
    CURRENT_SESSION=$(tmux display-message -p '#S' 2>/dev/null)
    echo "Already inside tmux (session: ${CURRENT_SESSION:-unknown}) - not nesting a new session."
    echo "Launching $AGENT in the current pane..."
    unset CLAUDECODE
    exec "${AGENT_ARGV[@]}"
fi

# Ensure tmux config directory exists
mkdir -p "$TMUX_DIR/plugins"
mkdir -p "$TMUX_DIR/resurrect"

# Create default tmux.conf if it doesn't exist
if [[ ! -f "$TMUX_CONF" ]]; then
    cat > "$TMUX_CONF" << 'TMUXCONF'
# Remap prefix to Ctrl-a
set -g prefix C-a
unbind C-b
bind C-a send-prefix

# Enable mouse
set -g mouse on

# Start windows at 1
set -g base-index 1
setw -g pane-base-index 1

# Better colors
set -g default-terminal "screen-256color"

# Faster escape
set -sg escape-time 10

# History (kept modest deliberately - see the OOM-protection note below;
# large scrollback across many sessions was a contributing factor in the
# 2026-05-25 tmux-server OOM incident)
set -g history-limit 2000

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded!"

# TPM plugins
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'

# Initialize TPM
run '~/.tmux/plugins/tpm/tpm'
TMUXCONF
fi

# Install TPM and plugins if needed
install_tpm
install_plugins

# Source updated config for any existing tmux server
if tmux list-sessions &>/dev/null; then
    echo "Updating tmux configuration..."
    tmux source-file "$TMUX_CONF" 2>/dev/null || true
fi

# Find an available session name
SESSION_NAME=$(find_available_session_name)

if [[ -z "$SESSION_NAME" ]]; then
    echo "Error: All phonetic alphabet session names are in use (alpha through zulu)."
    echo "Please close an existing tmux session and try again."
    exit 1
fi

# Create the tmux session with our config and start the selected agent
echo "Creating tmux session: $SESSION_NAME (agent: $AGENT)"
tmux -f "$TMUX_CONF" new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIR"

# Protect the tmux server from the OOM killer: on memory exhaustion the kernel
# should kill a claude worker pane, not the server (killing the server takes
# down every session at once). See the 2026-05-25 OOM incident. Needs
# passwordless sudo for choom.
SERVER_PID=$(tmux -f "$TMUX_CONF" display-message -t "$SESSION_NAME" -p '#{pid}' 2>/dev/null)
if [[ -n "$SERVER_PID" ]]; then
    if sudo -n choom -n -1000 -p "$SERVER_PID" >/dev/null 2>&1; then
        echo "Protected tmux server $SERVER_PID from OOM killer (oom_score_adj=-1000)"
    else
        echo "Warning: could not set OOM protection on tmux server $SERVER_PID (needs passwordless sudo + choom)"
    fi
fi

# tmux needs one shell command rather than an argv. Quote every element so a
# session name containing whitespace or shell metacharacters remains exactly
# one inert resume argument when the pane's shell evaluates the command.
printf -v AGENT_COMMAND '%q ' "${AGENT_ARGV[@]}"
AGENT_COMMAND=${AGENT_COMMAND% }
tmux send-keys -t "$SESSION_NAME" "unset CLAUDECODE && exec $AGENT_COMMAND" Enter

# Attach to the session
echo "Attaching to session: $SESSION_NAME"
tmux -f "$TMUX_CONF" attach-session -t "$SESSION_NAME"
STARTSH

    if ! verify_artifact_file \
        "$ARTIFACT_MANIFEST_DIR/$ARTIFACT_MANIFEST_FILE" \
        "start.sh" "/home/$user/start.sh"; then
        echo "ERROR: generated start.sh for $user failed signed artifact verification" >&2
        exit 1
    fi
    chmod +x "/home/$user/start.sh"
    chown "$user:$user" "/home/$user/start.sh"

    # Expose it as the `start` command (`start claude` / `start codex`). A
    # symlink, so the self-updating ~/start.sh stays the one deployed copy.
    # Run as the user so ~/.local is never root-owned; an existing `start`
    # (a re-run, or something unrelated) is left alone.
    su - "$user" -c 'mkdir -p "$HOME/.local/bin" && { [ -e "$HOME/.local/bin/start" ] || [ -L "$HOME/.local/bin/start" ] || ln -s "$HOME/start.sh" "$HOME/.local/bin/start"; }' \
        || echo "Warning: could not link ~/.local/bin/start for $user"
done

echo ""
echo "=== Step 14: Installing Rootless Docker ==="

# Install dependencies for rootless Docker (idempotent)
apt-get install -y \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
    rootlesskit \
    slirp4netns

# Install Docker if not present (idempotent)
if ! command -v docker &>/dev/null; then
    echo "Installing Docker..."
    if ! curl -fsSL https://get.docker.com | sh; then
        echo "ERROR: Docker installation failed"
        exit 1
    fi
else
    echo "Docker already installed"
fi

# Disable system Docker daemon - we'll use rootless per-user (idempotent)
systemctl disable --now docker.service docker.socket 2>/dev/null || true

# Rootless Docker needs one non-overlapping subordinate UID/GID range per
# configured user.  Reconcile the complete managed line on every run so a
# stale or duplicated entry cannot silently keep the old mapping.
ROOTLESS_DOCKER_SUBID_START=100000
ROOTLESS_DOCKER_SUBID_SIZE=65536
ensure_subordinate_id_range() {
    local path="$1"
    local user="$2"
    local start="$3"

    touch "$path"
    sed -i "/^${user}:/d" "$path"
    printf '%s:%s:%s\n' "$user" "$start" "$ROOTLESS_DOCKER_SUBID_SIZE" >> "$path"
    chown root:root "$path"
    chmod 0644 "$path"
}

# Debian's package keeps the setup helper under /usr/share, while Docker's
# upstream installer places it on PATH.  Support both layouts without ever
# running the helper as root.
ROOTLESS_SETUP_TOOL="$(command -v dockerd-rootless-setuptool.sh || true)"
if [[ -z "$ROOTLESS_SETUP_TOOL" && -x /usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh ]]; then
    ROOTLESS_SETUP_TOOL=/usr/share/docker.io/contrib/dockerd-rootless-setuptool.sh
fi
if [[ -z "$ROOTLESS_SETUP_TOOL" ]]; then
    echo "ERROR: dockerd-rootless-setuptool.sh is not installed" >&2
    exit 1
fi

# Configure rootless Docker for each user
for user_index in "${!USERS[@]}"; do
    user="${USERS[$user_index]}"
    echo "Setting up rootless Docker for user: $user"

    # Get user's UID
    USER_UID=$(id -u "$user")
    USER_SUBID_START=$((ROOTLESS_DOCKER_SUBID_START + user_index * ROOTLESS_DOCKER_SUBID_SIZE))

    # Enable lingering so user services start at boot
    loginctl enable-linger "$user"

    # Set up subuid/subgid ranges for user namespace mapping
    ensure_subordinate_id_range /etc/subuid "$user" "$USER_SUBID_START"
    ensure_subordinate_id_range /etc/subgid "$user" "$USER_SUBID_START"

    # Create XDG_RUNTIME_DIR if needed
    mkdir -p "/run/user/$USER_UID"
    chown "$user:$user" "/run/user/$USER_UID"
    chmod 700 "/run/user/$USER_UID"

    # Install rootless Docker as the user (idempotent - checks if already installed)
    if [[ ! -f "/home/$user/.config/systemd/user/docker.service" ]]; then
        su - "$user" -c "export XDG_RUNTIME_DIR=/run/user/\$(id -u); '$ROOTLESS_SETUP_TOOL' install" || {
            echo "ERROR: Rootless Docker setup failed for $user" >&2
            exit 1
        }
    else
        echo "Rootless Docker already configured for $user"
    fi

    # Enable the per-user service without requiring a live user D-Bus session
    # during bootstrap.  This is the same target symlink that
    # `systemctl --user enable docker` creates, and lingering starts the user
    # manager again after reboot.
    su - "$user" -c 'mkdir -p "$HOME/.config/systemd/user/default.target.wants" && ln -sfn ../docker.service "$HOME/.config/systemd/user/default.target.wants/docker.service"'

    # Add Docker environment to user's bashrc (idempotent)
    if ! grep -q "# === Rootless Docker ===" "/home/$user/.bashrc" 2>/dev/null; then
        cat >> "/home/$user/.bashrc" << 'DOCKERENV'

# === Rootless Docker ===
export PATH="$HOME/bin:$PATH"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
DOCKERENV
    fi

    # Create convenience script to start rootless Docker daemon
    mkdir -p "/home/$user/bin"
    cat > "/home/$user/bin/start-docker" << 'STARTDOCKER'
#!/bin/bash
set -euo pipefail
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DOCKER_HOST="${DOCKER_HOST:-unix://$XDG_RUNTIME_DIR/docker.sock}"
# Start rootless Docker daemon if not running
if ! docker info &>/dev/null; then
    echo "Starting rootless Docker daemon..."
    systemctl --user start docker
fi
docker info
STARTDOCKER
    chmod +x "/home/$user/bin/start-docker"
    chown -R "$user:$user" "/home/$user/bin"
done

echo "Rootless Docker installed. Each user has isolated Docker storage in ~/.local/share/docker/"

echo ""
echo "=== Step 15: Security Services ==="

# Configure fail2ban
cat > /etc/fail2ban/jail.local << 'FAIL2BAN'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 3
banaction = ufw

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 1h
FAIL2BAN

systemctl enable fail2ban
systemctl restart fail2ban

# Configure auditd
cat > /etc/audit/rules.d/hardening.rules << 'AUDITRULES'
# Delete all existing rules
-D

# Buffer size
-b 8192

# Failure mode
-f 1

# Monitor sudo usage
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor user/group changes
-w /etc/passwd -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/shadow -p wa -k identity

# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd

# Monitor cron
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron

# Monitor network config
-w /etc/hosts -p wa -k hosts
-w /etc/network/ -p wa -k network
AUDITRULES

systemctl enable auditd
systemctl restart auditd

# Automatic security updates
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'AUTOUPDATE'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}";
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
AUTOUPDATE

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE

echo ""
echo "=== Step 16: Backup Configuration (restic + B2) ==="

# Install restic
apt-get install -y restic

echo "Hardware UUID: $HARDWARE_UUID"

if $BACKUP_CONFIGURED; then
    # Create backup configuration directory
    mkdir -p /etc/restic
    chmod 700 /etc/restic

    # Store credentials securely
    cat > /etc/restic/b2.env << ENVFILE
export B2_ACCOUNT_ID="${B2_ACCOUNT_ID:-}"
export B2_ACCOUNT_KEY="${B2_ACCOUNT_KEY:-}"
export RESTIC_REPOSITORY="b2:${B2_BUCKET:-}:${B2_PATH_PREFIX:-}/$HARDWARE_UUID"
export RESTIC_PASSWORD="${RESTIC_PASSWORD:-}"
export RESTIC_CACHE_DIR="/var/cache/restic"
# Optimizations for B2 API call reduction
export RESTIC_PACK_SIZE="64"
ENVFILE
    chmod 600 /etc/restic/b2.env

    # Create cache directory
    mkdir -p /var/cache/restic
    chmod 700 /var/cache/restic

    # Source credentials
    source /etc/restic/b2.env

    if $RESTORE_FROM_BACKUP; then
        echo "Restoring from backup..."

        # Restore home directories
        restic restore latest --target / --include /home

        # Restore Tailscale state
        restic restore latest --target / --include /var/lib/tailscale

        # Fix ownership
        for user in "${USERS[@]}"; do
            if [[ -d "/home/$user" ]]; then
                chown -R "$user:$user" "/home/$user"
            fi
        done

        echo "Restore complete!"
    else
        # Check if repo exists, if not initialize and create first backup
        if ! restic snapshots &>/dev/null 2>&1; then
            echo "Initializing new backup repository..."
            restic init

            echo ""
            echo "Creating initial backup..."
            restic backup \
                --pack-size 64 \
                --one-file-system \
                --exclude='.cache' \
                --exclude='node_modules' \
                --exclude='.npm' \
                --exclude='__pycache__' \
                --exclude='.venv' \
                --exclude='venv' \
                --exclude='.local/share/docker/overlay2' \
                --exclude='.local/share/docker/buildkit' \
                --exclude='.local/share/docker/tmp' \
                --exclude='*.log' \
                --exclude='*.tmp' \
                /home \
                /var/lib/tailscale

            echo "Initial backup complete. Data is encrypted at rest in B2."
            echo "Encryption algorithm: AES-256 in CTR mode + Poly1305 MAC"
        else
            echo "Backup repository exists. Skipping initial backup."
        fi
    fi

    echo ""
    echo "=========================================="
    echo "IMPORTANT: Save your encryption password!"
    echo "=========================================="
    echo "Without this password, backups CANNOT be restored."
    echo "B2 stores only encrypted data - Backblaze cannot help recover it."
    echo ""
    echo "Bucket: $B2_BUCKET"
    echo "Path: $B2_PATH_PREFIX/$HARDWARE_UUID"
    echo "Hardware UUID: $HARDWARE_UUID"
    echo "=========================================="
else
    echo "Skipping B2 backup configuration (no credentials provided)."
fi

# Create optimized backup script
cat > /usr/local/bin/backup-home << 'BACKUPSCRIPT'
#!/bin/bash
set -euo pipefail

# Restic backup to B2 with optimizations for minimal API calls
# Usage: backup-home [--prune]

PRUNE=false
[[ "${1:-}" == "--prune" ]] && PRUNE=true

# Load B2 credentials
if [[ ! -f /etc/restic/b2.env ]]; then
    echo "ERROR: Backup not configured. Run bootstrap or create /etc/restic/b2.env"
    exit 1
fi
source /etc/restic/b2.env

echo "Starting backup to $RESTIC_REPOSITORY..."
echo "Timestamp: $(date)"

# Backup with optimizations:
# --pack-size 64: Larger packs = fewer B2 API calls
# --exclude: Skip caches and recreatable data
# --one-file-system: Don't cross filesystem boundaries
restic backup \
    --pack-size 64 \
    --one-file-system \
    --exclude='.cache' \
    --exclude='node_modules' \
    --exclude='.npm' \
    --exclude='__pycache__' \
    --exclude='.venv' \
    --exclude='venv' \
    --exclude='.local/share/docker/overlay2' \
    --exclude='.local/share/docker/buildkit' \
    --exclude='.local/share/docker/tmp' \
    --exclude='*.log' \
    --exclude='*.tmp' \
    /home \
    /var/lib/tailscale

echo "Backup complete."

# Prune old snapshots (API-intensive, do sparingly)
if $PRUNE; then
    echo "Pruning old snapshots..."
    restic forget \
        --keep-daily 7 \
        --keep-weekly 4 \
        --keep-monthly 6 \
        --prune
    echo "Prune complete."
fi

# Quick integrity check (5% of data, minimizes API calls)
echo "Running integrity check..."
restic check --read-data-subset=5%
echo "Check complete."
BACKUPSCRIPT

chmod +x /usr/local/bin/backup-home

# Create restore script
cat > /usr/local/bin/restore-home << 'RESTORESCRIPT'
#!/bin/bash
set -euo pipefail

# Restore from restic B2 backup
# Usage: restore-home [snapshot-id]
#        restore-home latest
#        restore-home          # interactive snapshot selection

# Load B2 credentials
if [[ ! -f /etc/restic/b2.env ]]; then
    echo "ERROR: Backup not configured. Create /etc/restic/b2.env"
    exit 1
fi
source /etc/restic/b2.env

SNAPSHOT="${1:-}"

if [[ -z "$SNAPSHOT" ]]; then
    echo "Available snapshots:"
    restic snapshots
    echo ""
    read -p "Enter snapshot ID to restore (or 'latest'): " SNAPSHOT
fi

if [[ -z "$SNAPSHOT" ]]; then
    echo "ERROR: No snapshot specified."
    exit 1
fi

echo "Restoring snapshot: $SNAPSHOT"
echo "This will overwrite existing files in /home and /var/lib/tailscale"
read -p "Continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Stop services that might interfere
systemctl stop tailscaled 2>/dev/null || true

# Restore
restic restore "$SNAPSHOT" --target /

# Fix ownership for users (detect from /home/*)
for user_home in /home/*; do
    if [[ -d "$user_home" ]]; then
        user=$(basename "$user_home")
        chown -R "$user:$user" "$user_home"
    fi
done

# Restart services
systemctl start tailscaled 2>/dev/null || true

echo "Restore complete from snapshot: $SNAPSHOT"
RESTORESCRIPT

chmod +x /usr/local/bin/restore-home

# Create list-backups script
cat > /usr/local/bin/list-backups << 'LISTSCRIPT'
#!/bin/bash
source /etc/restic/b2.env 2>/dev/null || { echo "Backup not configured"; exit 1; }
restic snapshots "$@"
LISTSCRIPT
chmod +x /usr/local/bin/list-backups

# Set up automated daily backup (with weekly prune)
cat > /etc/cron.d/restic-backup << 'CRONJOB'
# Daily backup at 3 AM
0 3 * * * root /usr/local/bin/backup-home >> /var/log/restic-backup.log 2>&1

# Weekly prune on Sunday at 4 AM (reduces B2 API calls by batching cleanup)
0 4 * * 0 root /usr/local/bin/backup-home --prune >> /var/log/restic-backup.log 2>&1
CRONJOB

# Create logrotate for backup logs
cat > /etc/logrotate.d/restic-backup << 'LOGROTATE'
/var/log/restic-backup.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
}
LOGROTATE

echo "Backup configuration complete."
echo "  - Daily backups at 3 AM"
echo "  - Weekly prune on Sundays at 4 AM"
echo "  - Commands: backup-home, restore-home, list-backups"

echo ""
echo "=== Step 17: Final Hardening ==="

# Secure shared memory
if ! grep -q "tmpfs /run/shm" /etc/fstab; then
    echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
fi

# Restrict cron
chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly
echo "root" > /etc/cron.allow
echo "root" > /etc/at.allow

# Secure tmp (idempotent - only add note if not present)
if ! grep -q "noexec,nosuid,nodev to /tmp" /etc/fstab; then
    echo "# Note: Consider adding noexec,nosuid,nodev to /tmp mount" >> /etc/fstab
fi

# Disable unused filesystems
cat > /etc/modprobe.d/disable-filesystems.conf << 'FSCONF'
install cramfs /bin/true
install freevxfs /bin/true
install jffs2 /bin/true
install hfs /bin/true
install hfsplus /bin/true
install squashfs /bin/true
install udf /bin/true
FSCONF

# Disable unused network protocols
cat > /etc/modprobe.d/disable-protocols.conf << 'PROTOCONF'
install dccp /bin/true
install sctp /bin/true
install rds /bin/true
install tipc /bin/true
PROTOCONF

# Set secure permissions on home directories (700 = owner only, no cross-user access)
for user in "${USERS[@]}"; do
    chmod 700 "/home/$user"
done

# Restart SSH with new config
systemctl restart sshd

echo ""
echo "=============================================="
echo "=== Bootstrap Complete (v${VERSION}) ==="
echo "=============================================="
echo ""
echo "INSTALLATION SUMMARY"
echo "=============================================="
echo ""
echo "Bootstrap:    v${VERSION}"
echo "Hostname:     $NEW_HOSTNAME"
echo "Timezone:     America/New_York"
echo "Locale:       en_US.UTF-8"
echo "DNS:          $DNS_DISPLAY"
echo "Hardware ID:  $HARDWARE_UUID"
echo ""
echo "Users created:"
for user in "${USERS[@]}"; do
    echo "  - $user"
done
echo ""
TAILSCALE_HOSTNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//' 2>/dev/null || echo "unknown")
echo "Access via Tailscale SSH:"
for user in "${USERS[@]}"; do
    echo "  ssh $user@$TAILSCALE_HOSTNAME"
done
echo ""
echo "Installed software:"
echo "  - Claude Code (native installer)"
echo "  - Rootless Docker (per-user isolation)"
echo "  - kubectl (Kubernetes CLI)"
if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
echo "  - cloudflared (Cloudflare Tunnel)"
fi
echo "  - tmux (with mouse support, 10k scrollback)"
echo "  - Modern CLI tools: ripgrep, fd, fzf, bat, exa, httpie"
echo ""
echo "Security features:"
echo "  - SSH hardened (key-only, no root, no password)"
echo "  - UFW firewall (deny all except Tailscale)"
echo "  - fail2ban (SSH brute force protection)"
echo "  - auditd (system auditing)"
echo "  - Automatic security updates (unattended-upgrades)"
echo "  - Kernel hardening (sysctl)"
echo "  - AppArmor enabled"
echo ""
if $BACKUP_CONFIGURED; then
echo "Backup configuration:"
echo "  - Repository: b2:$B2_BUCKET:$B2_PATH_PREFIX/$HARDWARE_UUID"
echo "  - Schedule: Daily at 3 AM, prune weekly"
echo "  - Commands: backup-home, restore-home, list-backups"
if $RESTORE_FROM_BACKUP; then
echo "  - Status: Restored from existing backup"
else
echo "  - Status: Initial backup created"
fi
else
echo "Backup: Not configured"
fi
echo ""
echo "Quick start:"
echo "  1. SSH to server: ssh ${USERS[0]}@$TAILSCALE_HOSTNAME"
echo "  2. Run 'start claude' or 'start codex' to launch a coding agent in tmux"
echo ""
echo "Verification commands:"
echo "  ufw status              # Firewall rules"
echo "  tailscale status        # Tailscale connection"
echo "  fail2ban-client status  # Brute force protection"
echo "  timedatectl             # Time/NTP status"
echo "  resolvectl status       # DNS configuration"
echo ""
echo "=============================================="
echo ""

# Reboot if requested at start
if $REBOOT_AFTER_BOOTSTRAP; then
    echo "Rebooting in 5 seconds to apply all changes..."
    sleep 5
    reboot
else
    echo "NOTE: A reboot is recommended to apply all kernel and sysctl changes."
    echo "Run 'reboot' when ready."
fi
