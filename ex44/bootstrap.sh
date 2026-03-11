#!/bin/bash
set -euo pipefail

# Hetzner EX44 Bootstrap Script
# Hardens a fresh Debian/Ubuntu install and sets up isolated dev workspaces
#
# Usage (from rescue or fresh install):
#   curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh | bash

echo "=== Hetzner EX44 Bootstrap ==="
echo "This script will:"
echo "  1. Update system packages"
echo "  2. Create isolated users (dev-coding, dev-trading)"
echo "  3. Harden SSH (key-only, no root, no password)"
echo "  4. Configure firewall (deny all except Tailscale)"
echo "  5. Install Tailscale"
echo "  6. Install Docker"
echo "  7. Install dev tools"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Run as root"
   exit 1
fi

# Prompt for required inputs
read -p "Enter your SSH public key: " SSH_PUBLIC_KEY
read -p "Enter your Tailscale auth key (tskey-auth-...): " TAILSCALE_AUTHKEY

if [[ -z "$SSH_PUBLIC_KEY" || -z "$TAILSCALE_AUTHKEY" ]]; then
    echo "ERROR: SSH key and Tailscale auth key are required"
    exit 1
fi

echo ""
echo "=== Step 1: System Update ==="
apt-get update
apt-get upgrade -y
apt-get install -y \
    curl \
    wget \
    git \
    tmux \
    neovim \
    htop \
    jq \
    unzip \
    fail2ban \
    ufw \
    unattended-upgrades

echo ""
echo "=== Step 2: Creating Users ==="
for user in dev-coding dev-trading; do
    echo "Creating user: $user"

    # Create user if doesn't exist
    id "$user" &>/dev/null || useradd -m -s /bin/bash "$user"

    # Set up SSH directory and key
    mkdir -p "/home/$user/.ssh"
    echo "$SSH_PUBLIC_KEY" > "/home/$user/.ssh/authorized_keys"
    chmod 700 "/home/$user/.ssh"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    chown -R "$user:$user" "/home/$user/.ssh"

    # Set up isolated TMPDIR
    mkdir -p "/home/$user/.tmp"
    chown "$user:$user" "/home/$user/.tmp"

    # Configure bashrc
    cat >> "/home/$user/.bashrc" << 'BASHRC'

# Isolated temp directory
export TMPDIR="$HOME/.tmp"

# Aliases
alias ll='ls -la'
alias gs='git status'
alias gd='git diff'

# Prompt with git branch
parse_git_branch() {
    git branch 2>/dev/null | sed -n 's/* \(.*\)/ (\1)/p'
}
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[33m\]$(parse_git_branch)\[\033[00m\]\$ '
BASHRC

    chown "$user:$user" "/home/$user/.bashrc"
done

echo ""
echo "=== Step 3: SSH Hardening ==="
cat > /etc/ssh/sshd_config.d/hardening.conf << 'SSHCONF'
# SSH Hardening Configuration
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
X11Forwarding no
AllowUsers dev-coding dev-trading
MaxAuthTries 3
LoginGraceTime 20
ClientAliveInterval 300
ClientAliveCountMax 2
SSHCONF

# Test SSH config before applying
sshd -t || {
    echo "ERROR: SSH config invalid"
    exit 1
}

echo ""
echo "=== Step 4: Firewall Configuration ==="
# Reset UFW to defaults
ufw --force reset

# Default policies
ufw default deny incoming
ufw default allow outgoing

# Allow Tailscale interface (will exist after Tailscale install)
ufw allow in on tailscale0

# Allow SSH from Hetzner rescue networks (emergency access)
ufw allow from 213.133.99.0/24 to any port 22 comment 'Hetzner rescue'
ufw allow from 213.133.100.0/24 to any port 22 comment 'Hetzner rescue'
ufw allow from 88.198.230.0/24 to any port 22 comment 'Hetzner rescue'

# Enable firewall
ufw --force enable
ufw status verbose

echo ""
echo "=== Step 5: Installing Tailscale ==="
curl -fsSL https://tailscale.com/install.sh | sh

# Start Tailscale with SSH enabled
tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh

echo "Tailscale status:"
tailscale status

echo ""
echo "=== Step 6: Installing Docker ==="
curl -fsSL https://get.docker.com | sh

# Add users to docker group
usermod -aG docker dev-coding
usermod -aG docker dev-trading

# Enable Docker service
systemctl enable docker
systemctl start docker

echo ""
echo "=== Step 7: Final Configuration ==="

# Enable fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# Enable automatic security updates
echo 'Unattended-Upgrade::Automatic-Reboot "false";' >> /etc/apt/apt.conf.d/50unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades

# Restart SSH with new config
systemctl restart sshd

echo ""
echo "=========================================="
echo "=== Bootstrap Complete ==="
echo "=========================================="
echo ""
echo "Server is now hardened and ready."
echo ""
echo "Access via Tailscale:"
echo "  ssh dev-coding@$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo "  ssh dev-trading@$(tailscale status --json | jq -r '.Self.DNSName' | sed 's/\.$//')"
echo ""
echo "Public IP SSH is blocked except from Hetzner rescue."
echo ""
echo "Next steps:"
echo "  1. Test Tailscale SSH access from another device"
echo "  2. Close this session once confirmed"
echo "  3. Install your dev tools per-user"
echo ""
echo "To verify firewall: ufw status"
echo "To verify Tailscale: tailscale status"
echo ""
