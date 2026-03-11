# EX44 Bootstrap

Bootstrap script for Hetzner EX44 dedicated server. Sets up a hardened, multi-user development environment with Tailscale access.

## What It Does

1. **System Update** - Updates packages
2. **Package Install** - Comprehensive dev and sysadmin tools
3. **User Creation** - Isolated users (`coding`, `trading`)
4. **SSH Hardening** - Key-only, no root, protocol hardening
5. **Kernel Hardening** - sysctl security settings
6. **Firewall** - UFW: deny all except Tailscale + Hetzner rescue
7. **Tailscale** - Secure mesh access with SSH
8. **Docker** - Hardened container runtime
9. **Security Services** - fail2ban, auditd, auto-updates

## Installed Utilities

| Category | Tools |
|----------|-------|
| **System** | htop, ncdu, duf, iotop, nload, vnstat, sysstat |
| **Search** | ripgrep (rg), fd, fzf, silversearcher (ag) |
| **Files** | bat, exa, tree |
| **Network** | httpie, mtr, tcpdump, netcat, dnsutils |
| **Dev** | git, tmux, neovim, python3, nodejs, build-essential |

## Prerequisites

Before running, have ready:
- A **Tailscale auth key** from [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)

SSH key is embedded in the repo (`keys/jedarden.pub`).

## Usage

### From Hetzner Rescue System

1. Boot into rescue mode via [Hetzner Robot](https://robot.hetzner.com)
2. SSH into rescue: `ssh root@<your-server-ip>`
3. Install the OS:
   ```bash
   installimage
   # Select: Debian 12 or Ubuntu 24.04
   # Reboot when prompted
   ```
4. SSH back in after reboot: `ssh root@<your-server-ip>`
5. Run bootstrap:
   ```bash
   curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh | bash
   ```
6. Enter your Tailscale auth key when prompted
7. Wait ~5-10 minutes for completion

### After Bootstrap

Connect via Tailscale (public IP is firewalled):
```bash
ssh coding@<hostname>.tailnet
ssh trading@<hostname>.tailnet
```

## Security Features

### Network
- UFW firewall: deny all incoming by default
- Only Tailscale interface allowed
- SSH from Hetzner rescue IPs only (emergency)

### SSH Hardening
- No root login
- No password authentication
- Key-only with modern ciphers
- Rate limiting (3 attempts, then ban)

### Kernel Hardening (sysctl)
- SYN flood protection
- IP spoofing protection
- ICMP redirect disabled
- Source routing disabled
- Memory protections (ASLR, etc.)

### Services
- **fail2ban** - Blocks brute force attempts
- **auditd** - Logs security-relevant events
- **unattended-upgrades** - Auto security patches
- **rkhunter/chkrootkit** - Rootkit detection (installed, run manually)

### Docker Hardening
- User namespace remapping
- No inter-container communication by default
- No new privileges flag
- Log rotation

## User Isolation

```
/home/coding/
├── .ssh/authorized_keys
├── .bashrc              # Isolated TMPDIR, aliases
├── .tmux.conf           # tmux config
├── .tmp/                # User-specific temp (TMPDIR)
├── .cache/              # User-specific cache
└── workspace/           # Work directory

/home/trading/
└── (same structure)
```

- Users cannot access each other's home directories
- Each has isolated `TMPDIR` and `XDG_CACHE_HOME`
- Docker group membership for both

## File Structure

```
ex44/
├── bootstrap.sh         # Main bootstrap script
├── keys/
│   └── jedarden.pub     # SSH public key
└── README.md            # This file
```

## Recovery

If you lose Tailscale access:
1. Go to [Hetzner Robot](https://robot.hetzner.com)
2. Activate rescue system
3. SSH in via public IP (allowed from Hetzner rescue)
4. Mount filesystem and fix, or re-run bootstrap

## Verification Commands

```bash
# Firewall
ufw status verbose

# Tailscale
tailscale status

# SSH hardening
sshd -T | grep -E 'permitrootlogin|passwordauthentication|allowusers'

# Docker
docker run hello-world

# fail2ban
fail2ban-client status sshd

# auditd
auditctl -l

# Kernel params
sysctl -a | grep -E 'rp_filter|syncookies'

# Disk usage
ncdu /

# System overview
htop
```

## Future Automation

- **Phase 2**: Ansible playbooks for drift management
- **Phase 3**: K8s-triggered provisioning via Hetzner Robot API
