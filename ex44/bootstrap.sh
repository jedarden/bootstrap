#!/bin/bash
set -euo pipefail

# Hetzner EX44 Bootstrap Script
# Hardens a fresh Debian/Ubuntu install and sets up isolated dev workspaces
#
# Usage (from rescue or fresh install):
#   curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh | bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44"

echo "=== Hetzner EX44 Bootstrap ==="
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Run as root"
   exit 1
fi

# Prompt for Tailscale auth key only (SSH key is in repo)
read -p "Enter your Tailscale auth key (tskey-auth-...): " TAILSCALE_AUTHKEY

if [[ -z "$TAILSCALE_AUTHKEY" ]]; then
    echo "ERROR: Tailscale auth key is required"
    exit 1
fi

# Fetch SSH key from repo
echo "Fetching SSH public key from repo..."
SSH_PUBLIC_KEY=$(curl -sL "$REPO_URL/keys/jedarden.pub")

if [[ -z "$SSH_PUBLIC_KEY" ]]; then
    echo "ERROR: Failed to fetch SSH key"
    exit 1
fi

echo ""
echo "=== Step 1: System Update ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo ""
echo "=== Step 2: Installing Packages ==="

# Core utilities
apt-get install -y \
    curl \
    wget \
    git \
    tmux \
    neovim \
    vim \
    htop \
    ncdu \
    jq \
    yq \
    unzip \
    zip \
    tree \
    file \
    less \
    man-db

# Modern CLI tools
apt-get install -y \
    ripgrep \
    fd-find \
    bat \
    fzf \
    exa \
    duf \
    httpie \
    silversearcher-ag

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
    needrestart \
    rkhunter \
    chkrootkit \
    auditd \
    libpam-tmpdir

# Development tools
apt-get install -y \
    build-essential \
    python3 \
    python3-pip \
    python3-venv \
    nodejs \
    npm

# GitHub CLI
echo "Installing GitHub CLI..."
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
apt-get install -y gh

# System tools
apt-get install -y \
    lsof \
    strace \
    sysstat \
    iotop \
    nload \
    vnstat

echo ""
echo "=== Step 3: Creating Users ==="
USERS=("coding" "trading")

for user in "${USERS[@]}"; do
    echo "Creating user: $user"

    # Create user if doesn't exist
    id "$user" &>/dev/null || useradd -m -s /bin/bash "$user"

    # Set up SSH directory and key
    mkdir -p "/home/$user/.ssh"
    echo "$SSH_PUBLIC_KEY" > "/home/$user/.ssh/authorized_keys"
    chmod 700 "/home/$user/.ssh"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    chown -R "$user:$user" "/home/$user/.ssh"

    # Set up isolated directories
    mkdir -p "/home/$user/.tmp"
    mkdir -p "/home/$user/.cache"
    mkdir -p "/home/$user/workspace"
    chown -R "$user:$user" "/home/$user"

    # Configure bashrc
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
set -g history-limit 50000

# Split panes with | and -
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Reload config
bind r source-file ~/.tmux.conf \; display "Reloaded!"
TMUXCONF
    chown "$user:$user" "/home/$user/.tmux.conf"
done

echo ""
echo "=== Step 4: SSH Hardening ==="
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSHCONF'
# === SSH Hardening Configuration ===

# Authentication
PermitRootLogin no
PasswordAuthentication no
PermitEmptyPasswords no
PubkeyAuthentication yes
AuthenticationMethods publickey
ChallengeResponseAuthentication no
UsePAM yes

# Allowed users
AllowUsers coding trading

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
echo "=== Step 5: Kernel Hardening (sysctl) ==="
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
echo "=== Step 6: Firewall Configuration ==="
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
echo "=== Step 7: Installing Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale with SSH enabled
tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh

echo "Tailscale status:"
tailscale status

echo ""
echo "=== Step 8: Installing Docker ==="
curl -fsSL https://get.docker.com | sh

# Add users to docker group
for user in "${USERS[@]}"; do
    usermod -aG docker "$user"
done

# Enable Docker service
systemctl enable docker
systemctl start docker

# Docker hardening
mkdir -p /etc/docker
cat > /etc/docker/daemon.json << 'DOCKERCONF'
{
    "icc": false,
    "userns-remap": "default",
    "no-new-privileges": true,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "10m",
        "max-file": "3"
    }
}
DOCKERCONF

systemctl restart docker

echo ""
echo "=== Step 9: Security Services ==="

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
echo "=== Step 10: Final Hardening ==="

# Secure shared memory
if ! grep -q "tmpfs /run/shm" /etc/fstab; then
    echo "tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0" >> /etc/fstab
fi

# Restrict cron
chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly
echo "root" > /etc/cron.allow
echo "root" > /etc/at.allow

# Secure tmp
if ! grep -q "/tmp" /etc/fstab | grep -q "nosuid"; then
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
chmod 750 /home/coding /home/trading

# Restart SSH with new config
systemctl restart sshd

echo ""
echo "=========================================="
echo "=== Bootstrap Complete ==="
echo "=========================================="
echo ""
echo "Server is hardened and ready."
echo ""
echo "Users created: coding, trading"
echo ""
TAILSCALE_HOSTNAME=$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')
echo "Access via Tailscale:"
echo "  ssh coding@$TAILSCALE_HOSTNAME"
echo "  ssh trading@$TAILSCALE_HOSTNAME"
echo ""
echo "Public IP SSH is blocked except from Hetzner rescue."
echo ""
echo "Installed utilities:"
echo "  System: htop, ncdu, duf, iotop, nload"
echo "  Search: ripgrep (rg), fd, fzf, ag"
echo "  Files:  bat, exa, tree"
echo "  Net:    httpie, mtr, tcpdump"
echo ""
echo "Security features enabled:"
echo "  - SSH hardened (key-only, no root)"
echo "  - UFW firewall (deny all except Tailscale)"
echo "  - fail2ban (SSH brute force protection)"
echo "  - auditd (system auditing)"
echo "  - Automatic security updates"
echo "  - Kernel hardening (sysctl)"
echo "  - Docker hardening"
echo ""
echo "Verify with:"
echo "  ufw status"
echo "  tailscale status"
echo "  fail2ban-client status"
echo "  auditctl -l"
echo ""
