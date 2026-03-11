# EX44 Bootstrap

Bootstrap script for Hetzner EX44 dedicated server. Sets up a hardened, multi-user development environment with Tailscale access.

## What It Does

1. **System Update** - Updates packages, installs base tools
2. **User Creation** - Creates isolated users (`dev-coding`, `dev-trading`)
3. **SSH Hardening** - Key-only auth, no root login, no passwords
4. **Firewall** - Blocks all incoming except Tailscale + Hetzner rescue
5. **Tailscale** - Secure mesh access with SSH
6. **Docker** - Container runtime for both users
7. **Security** - fail2ban, automatic security updates

## Prerequisites

Before running, have ready:
- Your **SSH public key** (e.g., `ssh-ed25519 AAAA...`)
- A **Tailscale auth key** from [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)
  - Create a reusable key or one-time key
  - Enable "Pre-approved" if you want auto-approval

## Usage

### From Hetzner Rescue System

1. Boot into rescue mode via [Hetzner Robot](https://robot.hetzner.com)
2. SSH into rescue: `ssh root@<your-server-ip>`
3. Install the OS:
   ```bash
   installimage
   # Select: Debian 12 or Ubuntu 24.04
   # Configure partitioning as needed
   # Reboot when prompted
   ```
4. SSH back in after reboot: `ssh root@<your-server-ip>`
5. Run bootstrap:
   ```bash
   curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh | bash
   ```
6. Enter your SSH public key when prompted
7. Enter your Tailscale auth key when prompted
8. Wait ~5 minutes for completion

### After Bootstrap

Connect via Tailscale (public IP is firewalled):
```bash
ssh dev-coding@<hostname>.tailnet
ssh dev-trading@<hostname>.tailnet
```

## Security Model

```
Internet
    │
    ├── Public IP (Hetzner)
    │   └── Firewall: DENY ALL
    │       └── Exception: Hetzner rescue IPs → port 22
    │
    └── Tailscale Mesh (encrypted)
        └── tailscale0 interface
            └── Firewall: ALLOW ALL
                └── SSH to dev-coding / dev-trading
```

- **No public SSH** - Only accessible via Tailscale
- **No root login** - Only dev-coding and dev-trading users
- **No passwords** - SSH key authentication only
- **Isolated users** - Each has separate home, TMPDIR, and permissions
- **Auto-updates** - Security patches applied automatically

## User Isolation

Each user has:
- Separate home directory (`/home/dev-coding`, `/home/dev-trading`)
- Isolated temp directory (`$HOME/.tmp` via `TMPDIR`)
- Docker access (both in `docker` group)
- Cannot access each other's files (standard Unix permissions)

## File Structure

```
/home/dev-coding/
├── .ssh/authorized_keys    # Your SSH key
├── .bashrc                 # Shell config with isolated TMPDIR
├── .tmp/                   # User-specific temp directory
└── (your workspaces)

/home/dev-trading/
├── .ssh/authorized_keys
├── .bashrc
├── .tmp/
└── (your workspaces)
```

## Recovery

If you lose Tailscale access:
1. Go to [Hetzner Robot](https://robot.hetzner.com)
2. Activate rescue system
3. SSH in via public IP (allowed from Hetzner rescue)
4. Mount filesystem and fix, or re-run bootstrap

## Future Automation

This manual bootstrap is Phase 1. Future phases:
- **Phase 2**: Ansible playbooks for configuration management
- **Phase 3**: K8s-triggered provisioning via Hetzner Robot API

The bootstrap script is designed to be idempotent - safe to re-run.

## Customization

Edit the script to:
- Add more users
- Change installed packages
- Modify firewall rules
- Add dotfiles

## Verification Commands

```bash
# Check firewall
ufw status verbose

# Check Tailscale
tailscale status

# Check SSH config
sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers'

# Check Docker
docker run hello-world

# Check fail2ban
fail2ban-client status
```
