#!/bin/bash
set -euo pipefail

# Hetzner EX44 Bootstrap Script
# Hardens a fresh Debian/Ubuntu install and sets up isolated dev workspaces
#
# Version: 1.0.2
#
# Usage (download and run - interactive prompts require terminal):
#   curl -sLO https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh
#   chmod +x bootstrap.sh
#   ./bootstrap.sh

VERSION="1.0.2"

# Handle --version flag
if [[ "${1:-}" == "--version" ]] || [[ "${1:-}" == "-v" ]]; then
    echo "Hetzner EX44 Bootstrap v${VERSION}"
    exit 0
fi

# Handle both direct execution and sourcing
if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SCRIPT_DIR="$(pwd)"
fi
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44"

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
B2_APPLICATION_KEY=""
RESTIC_PASSWORD=""
REBOOT_AFTER_BOOTSTRAP=false
BACKUP_CONFIGURED=false
RESTORE_FROM_BACKUP=false
TAILSCALE_AUTHKEY=""

# Function to save configuration (non-sensitive values only)
save_config() {
    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << CONFIGEOF
# Bootstrap configuration - saved $(date)
# Non-sensitive values only. Secrets are prompted each run.
NEW_HOSTNAME="$NEW_HOSTNAME"
USERS="${USERS[*]}"
B2_BUCKET="$B2_BUCKET"
B2_PATH_PREFIX="$B2_PATH_PREFIX"
B2_ACCOUNT_ID="$B2_ACCOUNT_ID"
REBOOT_AFTER_BOOTSTRAP="$REBOOT_AFTER_BOOTSTRAP"
CONFIGEOF
    chmod 600 "$CONFIG_FILE"
}

# Function to load configuration
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
        # Convert USERS string back to array (use default if empty)
        read -ra USERS <<< "${USERS:-}"
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
    read -p "Use previous configuration? [Y/n]: " USE_PREV
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
    read -p "Hostname [$CURRENT_HOSTNAME]: " NEW_HOSTNAME
    NEW_HOSTNAME="${NEW_HOSTNAME:-$CURRENT_HOSTNAME}"

    # Users to create
    echo ""
    echo "Users to create (enter each username, empty line to finish)"
    USERS=()
    while true; do
        if [[ ${#USERS[@]} -eq 0 ]]; then
            read -p "Username (or Enter for default 'coding'): " USERNAME
            if [[ -z "$USERNAME" ]]; then
                USERS=("coding" "trading")
                echo "Using default users: coding, trading"
                break
            fi
        else
            read -p "Username (or Enter to finish): " USERNAME
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
    read -p "B2 Bucket name: " B2_BUCKET
    read -p "B2 Path prefix [hetzner-ex44]: " B2_PATH_PREFIX
    B2_PATH_PREFIX="${B2_PATH_PREFIX:-hetzner-ex44}"
    read -p "B2 Account ID (or Key ID): " B2_ACCOUNT_ID

    # Reboot after completion?
    echo ""
    read -p "Reboot automatically after bootstrap? [y/N]: " REBOOT_AFTER
    REBOOT_AFTER_BOOTSTRAP=false
    [[ "$REBOOT_AFTER" =~ ^[Yy]$ ]] && REBOOT_AFTER_BOOTSTRAP=true
fi

# ===========================================
# Prompt for secrets (always required)
# ===========================================
echo ""
echo "--- Secrets (required each run) ---"

# Tailscale - check if already connected
if tailscale status &>/dev/null 2>&1; then
    echo "Tailscale already connected, skipping auth key."
    TAILSCALE_AUTHKEY=""
else
    read -p "Tailscale auth key (tskey-auth-...): " TAILSCALE_AUTHKEY
    if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
        echo "ERROR: Tailscale auth key is required"
        exit 1
    fi
fi

# B2 secrets
BACKUP_CONFIGURED=false
RESTORE_FROM_BACKUP=false

if [[ -n "$B2_BUCKET" && -n "$B2_ACCOUNT_ID" ]]; then
    read -p "B2 Application Key: " B2_APPLICATION_KEY

    if [[ -n "$B2_APPLICATION_KEY" ]]; then
        read -sp "Backup encryption password: " RESTIC_PASSWORD
        echo ""
        read -sp "Confirm encryption password: " RESTIC_PASSWORD_CONFIRM
        echo ""

        if [[ "$RESTIC_PASSWORD" != "$RESTIC_PASSWORD_CONFIRM" ]]; then
            echo "ERROR: Passwords do not match"
            exit 1
        fi

        BACKUP_CONFIGURED=true

        # Check if backup exists (test connection)
        echo ""
        echo "Checking for existing backup..."
        export B2_ACCOUNT_ID B2_APPLICATION_KEY RESTIC_PASSWORD
        export RESTIC_REPOSITORY="b2:$B2_BUCKET:$B2_PATH_PREFIX/$HARDWARE_UUID"

        if restic snapshots &>/dev/null 2>&1; then
            echo "Found existing backup!"
            read -p "Restore from backup after setup? [y/N]: " RESTORE_CONFIRM
            [[ "$RESTORE_CONFIRM" =~ ^[Yy]$ ]] && RESTORE_FROM_BACKUP=true
        else
            echo "No existing backup found. Will create initial backup."
        fi

        # Unset for now, will re-export when needed
        unset B2_ACCOUNT_ID B2_APPLICATION_KEY RESTIC_PASSWORD RESTIC_REPOSITORY
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

# Fetch SSH keys from repo
echo "Fetching SSH public keys from repo..."

# Verify network connectivity first
if ! getent hosts raw.githubusercontent.com &>/dev/null; then
    echo "ERROR: Cannot resolve raw.githubusercontent.com"
    echo "DNS may not be working. Try: echo 'nameserver 1.1.1.1' > /etc/resolv.conf"
    exit 1
fi

SSH_KEY_1=$(curl -sfL "$REPO_URL/keys/jedarden.pub") || {
    echo "ERROR: Failed to fetch SSH key (jedarden.pub)"
    echo "URL: $REPO_URL/keys/jedarden.pub"
    exit 1
}
SSH_KEY_2=$(curl -sfL "$REPO_URL/keys/jeda-mbp.pub") || SSH_KEY_2=""

if [[ -z "$SSH_KEY_1" ]]; then
    echo "ERROR: SSH key (jedarden.pub) is empty"
    exit 1
fi

# Combine all keys
SSH_PUBLIC_KEYS="$SSH_KEY_1"
[[ -n "$SSH_KEY_2" ]] && SSH_PUBLIC_KEYS="$SSH_PUBLIC_KEYS
$SSH_KEY_2"

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

# Configure DNS to use Cloudflare (1.1.1.1) - idempotent
echo "Configuring DNS (Cloudflare 1.1.1.1)..."

# First, ensure we have working DNS by setting resolv.conf directly
# This is a fallback that works regardless of systemd-resolved state
if ! getent hosts debian.org &>/dev/null; then
    echo "DNS not working, setting direct nameserver..."
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf
fi

# Configure systemd-resolved if available
if command -v systemctl &>/dev/null && systemctl list-unit-files systemd-resolved.service &>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/dns.conf << 'DNSCONF'
[Resolve]
DNS=1.1.1.1 1.0.0.1
FallbackDNS=8.8.8.8 8.8.4.4
DNSOverTLS=opportunistic
DNSCONF

    # Enable and start systemd-resolved
    systemctl enable systemd-resolved 2>/dev/null || true
    systemctl start systemd-resolved 2>/dev/null || true

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
    echo -e "nameserver 1.1.1.1\nnameserver 1.0.0.1" > /etc/resolv.conf
fi

# Verify settings
echo "Timezone: $(timedatectl show --property=Timezone --value)"
echo "NTP: $(timedatectl show --property=NTP --value)"
echo "DNS: $(resolvectl status 2>/dev/null | grep "DNS Servers" | head -1 || echo "configured")"

echo ""
echo "=== Step 3: System Update ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

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
    echo "Installing yq from GitHub releases..."
    YQ_VERSION=$(curl -sL "https://api.github.com/repos/mikefarah/yq/releases/latest" | jq -r '.tag_name') || YQ_VERSION="v4.40.5"
    curl -sL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_$(dpkg --print-architecture)" -o /usr/local/bin/yq && chmod +x /usr/local/bin/yq || echo "Warning: Failed to install yq"
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
echo "=== Step 5: Installing kubectl ==="

# Install kubectl if not present (idempotent)
if command -v kubectl &>/dev/null; then
    echo "kubectl already installed: $(kubectl version --client --short 2>/dev/null || kubectl version --client)"
else
    KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
    ARCH=$(dpkg --print-architecture)
    echo "Installing kubectl $KUBECTL_VERSION for $ARCH..."

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

# History
set -g history-limit 10000

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
ALLOW_USERS_LIST="${USERS[*]}"

cat > /etc/ssh/sshd_config.d/hardening.conf << SSHCONF
# === SSH Hardening Configuration ===

# Authentication
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
ChallengeResponseAuthentication no
UsePAM yes

# Allowed users (dynamically configured)
AllowUsers $ALLOW_USERS_LIST

# Security limits
MaxAuthTries 3
MaxSessions 10
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2

# Disable unused features
X11Forwarding no
AllowTcpForwarding no
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

# Start Tailscale with SSH enabled (idempotent)
if ! tailscale status &>/dev/null; then
    echo "Connecting to Tailscale..."
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh
else
    echo "Tailscale already connected"
fi

echo "Tailscale status:"
tailscale status

echo ""
echo "=== Step 11: Installing Claude Code ==="

# Install Claude Code for root (idempotent - installer handles updates)
if [[ ! -x "/root/.claude/local/bin/claude" ]]; then
    echo "Installing Claude Code for root..."
    if ! curl -fsSL https://claude.ai/install.sh | bash; then
        echo "Warning: Claude Code installation for root failed, continuing..."
    fi
else
    echo "Claude Code already installed for root"
fi

# Add Claude Code to PATH for all users (idempotent)
if [[ ! -f /etc/profile.d/claude-code.sh ]]; then
    echo "export PATH=\"\$HOME/.claude/local/bin:\$PATH\"" > /etc/profile.d/claude-code.sh
    chmod 644 /etc/profile.d/claude-code.sh
fi

# Install Claude Code for each user (idempotent)
for user in "${USERS[@]}"; do
    if [[ ! -x "/home/$user/.claude/local/bin/claude" ]]; then
        echo "Installing Claude Code for user: $user"
        if ! su - "$user" -c 'curl -fsSL https://claude.ai/install.sh | bash'; then
            echo "Warning: Claude Code installation for $user failed, continuing..."
        fi
    else
        echo "Claude Code already installed for $user"
    fi
done

echo ""
echo "=== Step 12: Setting Up start.sh for Users ==="
# Create start.sh for each user with tmux + Claude Code setup
for user in "${USERS[@]}"; do
    echo "Setting up start.sh for user: $user"
    cat > "/home/$user/start.sh" << 'STARTSH'
#!/bin/bash

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMUX_DIR="$SCRIPT_DIR/.tmux"
TMUX_CONF="$TMUX_DIR/tmux.conf"
TPM_DIR="$TMUX_DIR/plugins/tpm"

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

    # Ensure PATH includes common install location
    if [[ -x "$HOME/.claude/local/bin/claude" ]]; then
        export PATH="$HOME/.claude/local/bin:$PATH"
    fi

    installed_version=$(get_installed_claude_version)
    latest_version=$(get_latest_claude_version)

    if [[ -z "$installed_version" ]]; then
        echo "Claude Code not found. Installing..."
        install_claude_code
        if [[ -f "$HOME/.bashrc" ]]; then
            source "$HOME/.bashrc" 2>/dev/null || true
        fi
        if [[ -x "$HOME/.claude/local/bin/claude" ]]; then
            export PATH="$HOME/.claude/local/bin:$PATH"
        fi
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

check_and_update_claude

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

# History
set -g history-limit 10000

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

# Create the tmux session with our config and start claude code
echo "Creating tmux session: $SESSION_NAME"
tmux -f "$TMUX_CONF" new-session -d -s "$SESSION_NAME" -c "$SCRIPT_DIR"
tmux send-keys -t "$SESSION_NAME" "unset CLAUDECODE && exec claude --dangerously-skip-permissions" Enter

# Attach to the session
echo "Attaching to session: $SESSION_NAME"
tmux -f "$TMUX_CONF" attach-session -t "$SESSION_NAME"
STARTSH

    chmod +x "/home/$user/start.sh"
    chown "$user:$user" "/home/$user/start.sh"
done

echo ""
echo "=== Step 13: Installing Rootless Docker ==="

# Install dependencies for rootless Docker (idempotent)
apt-get install -y \
    uidmap \
    dbus-user-session \
    fuse-overlayfs \
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

# Configure rootless Docker for each user
for user in "${USERS[@]}"; do
    echo "Setting up rootless Docker for user: $user"

    # Get user's UID
    USER_UID=$(id -u "$user")

    # Enable lingering so user services start at boot
    loginctl enable-linger "$user"

    # Set up subuid/subgid ranges for user namespace mapping
    if ! grep -q "^$user:" /etc/subuid; then
        echo "$user:100000:65536" >> /etc/subuid
    fi
    if ! grep -q "^$user:" /etc/subgid; then
        echo "$user:100000:65536" >> /etc/subgid
    fi

    # Create XDG_RUNTIME_DIR if needed
    mkdir -p "/run/user/$USER_UID"
    chown "$user:$user" "/run/user/$USER_UID"
    chmod 700 "/run/user/$USER_UID"

    # Install rootless Docker as the user (idempotent - checks if already installed)
    if [[ ! -f "/home/$user/.config/systemd/user/docker.service" ]]; then
        su - "$user" -c 'dockerd-rootless-setuptool.sh install' || {
            echo "Warning: Rootless Docker setup for $user may need manual completion after first login"
        }
    else
        echo "Rootless Docker already configured for $user"
    fi

    # Add Docker environment to user's bashrc (idempotent)
    if ! grep -q "# === Rootless Docker ===" "/home/$user/.bashrc" 2>/dev/null; then
        cat >> "/home/$user/.bashrc" << 'DOCKERENV'

# === Rootless Docker ===
export PATH="$HOME/bin:$PATH"
export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
DOCKERENV
    fi

    # Create convenience script to start rootless Docker daemon
    mkdir -p "/home/$user/bin"
    cat > "/home/$user/bin/start-docker" << 'STARTDOCKER'
#!/bin/bash
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
echo "=== Step 14: Security Services ==="

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
echo "=== Step 15: Backup Configuration (restic + B2) ==="

# Install restic
apt-get install -y restic

echo "Hardware UUID: $HARDWARE_UUID"

if $BACKUP_CONFIGURED; then
    # Create backup configuration directory
    mkdir -p /etc/restic
    chmod 700 /etc/restic

    # Store credentials securely
    cat > /etc/restic/b2.env << ENVFILE
export B2_ACCOUNT_ID="$B2_ACCOUNT_ID"
export B2_APPLICATION_KEY="$B2_APPLICATION_KEY"
export RESTIC_REPOSITORY="b2:$B2_BUCKET:$B2_PATH_PREFIX/$HARDWARE_UUID"
export RESTIC_PASSWORD="$RESTIC_PASSWORD"
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
echo "=== Step 16: Final Hardening ==="

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

# Set secure permissions on home directories
for user in "${USERS[@]}"; do
    chmod 750 "/home/$user"
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
echo "DNS:          1.1.1.1 (Cloudflare)"
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
echo "  2. Run start.sh to launch Claude Code in tmux"
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
