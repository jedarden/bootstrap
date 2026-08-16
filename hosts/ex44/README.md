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
| **Dev** | git, gh (GitHub CLI), tmux, neovim, python3, nodejs, build-essential |

## Prerequisites

Before running, have ready:
- A **Tailscale auth key** from [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys)

SSH key is embedded in the repo (`keys/jedarden.pub`).

### Optional: OpenBao Secret Sourcing

Instead of entering secrets manually each bootstrap run, you can pre-provision them in OpenBao. If the `OPENBAO_TOKEN` environment variable is set and Tailscale is running, the script will attempt to fetch B2 credentials from OpenBao before falling back to interactive prompts.

**Expected OpenBao secret structure:**
```bash
# Path: secret/bootstrap/<hardware-uuid>/b2
{
  "data": {
    "data": {
      "b2_application_key": "your-b2-application-key",
      "restic_password": "your-restic-encryption-password"
    }
  }
}
```

**To use OpenBao sourcing:**
```bash
export OPENBAO_TOKEN="your-openbao-token"
curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/ex44/bootstrap.sh | bash
```

The script will:
1. Check if Tailscale is running (required for OpenBao access)
2. Attempt to fetch secrets from `https://traefik-rs-manager:8200/v1/secret/bootstrap/<hardware-uuid>/b2`
3. Fall back to manual prompts if OpenBao is unreachable or secrets don't exist

This is optional — the script works fine without OpenBao, just with manual secret entry each run.

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
   curl -sL https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap.sh | bash
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
- Key-based root login allowed (Hetzner rescue network emergency access)
- No password authentication (key-only for all users)
- Modern ciphers and protocol hardening
- TCP forwarding enabled (VS Code Remote SSH support)
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
├── bootstrap.sh         # Main bootstrap script (embeds start.sh, see below)
├── start.sh             # Canonical tmux + coding-agent launcher (self-updating)
├── start.sh.version     # Version string self-update compares against
├── sync-start-sh.sh     # Regenerates bootstrap.sh's embedded copy from start.sh
├── keys/
│   └── jedarden.pub     # SSH public key
└── README.md            # This file
```

**start.sh is single-sourced.** `bootstrap.sh` embeds a byte-for-byte copy of
`start.sh` in a heredoc to drop onto each new user's home directory; every
already-bootstrapped host's `start.sh` self-updates from the standalone
`start.sh` file afterward. After editing `start.sh`, run
`./sync-start-sh.sh` to regenerate the embedded copy and bump both
`START_SH_VERSION` (inside `start.sh`) and `start.sh.version` — never hand-edit
the embedded copy in `bootstrap.sh` directly, and never hand-patch a deployed
`~/start.sh` on a host (land the change here first). See
`../docs/plan/plan.md` ADR-1 for why this matters — both failure modes it
guards against already happened once.

**start.sh launches claude or codex.** Selection order is `--agent
claude|codex` > `$START_SH_AGENT` > interactive prompt > `claude`. The prompt
only appears when stdin is a TTY, so non-interactive invocations take the
`claude` default instead of blocking.

When start.sh detects that something is **already multiplexing** — a herdr
pane (`HERDR_ENV`) or an existing tmux client (`$TMUX`) — it skips tmux
entirely and execs the agent in the current pane rather than nesting. herdr is
checked first, since herdr rides on the same ambient tmux server and a herdr
pane has both variables set. On a bare shell the original behavior is
unchanged: a new phonetic-alphabet tmux session, then attach. See
`../docs/plan/plan.md` ADR-2 and ADR-3.

```bash
./start.sh                    # prompt (or claude if no TTY)
./start.sh --agent codex      # explicit
START_SH_AGENT=codex ./start.sh
```

## Recovery

If you lose Tailscale access:
1. Go to [Hetzner Robot](https://robot.hetzner.com)
2. Activate rescue system
3. SSH in via public IP (allowed from Hetzner rescue)
4. Mount filesystem and fix, or re-run bootstrap

## Automated Verification

Run `bootstrap.sh --verify` (or `--check`) to automatically verify the bootstrap completed successfully. This runs all the checks below and reports a PASS/FAIL summary:

```bash
./bootstrap.sh --verify
```

**Exit code:** 0 if all checks pass, 1 if any check fails

**Use cases:**
- Right after bootstrap to confirm success
- Periodically after `unattended-upgrades` runs (catches config drift)
- In CI/CD pipelines or monitoring scripts

**Example output:**
```
=== Bootstrap Verification v1.1.5 ===

=== Firewall ===
UFW active:                             ✓ PASS
UFW default incoming policy:            ✓ PASS
UFW allows Tailscale:                   ✓ PASS

=== Tailscale ===
Tailscale connected:                    ✓ PASS

=== SSH Hardening ===
PermitRootLogin prohibited:             ✓ PASS
PasswordAuthentication disabled:        ✓ PASS
PubkeyAuthentication enabled:           ✓ PASS
MaxAuthTries limited:                   ✓ PASS

=== Summary ===
Total checks: 16
Passed:       16
Failed:       0

✓ All checks passed!
```

## Manual Verification Commands

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
