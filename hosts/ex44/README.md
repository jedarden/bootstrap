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

## Prerequisites and configuration contract

Run the script on a freshly installed **Debian 12 or Ubuntu 24.04** EX44,
from an interactive root shell. The host needs working DNS and outbound
HTTPS access so the script can install packages and fetch the repository keys.
The install path uses Bash-specific syntax and reads prompts from `/dev/tty`,
so it requires `bash`, `curl`, and a terminal (a pseudo-TTY when running over
SSH). It does not support a completely non-interactive install.

Have these inputs ready before starting:

- A **Tailscale auth key** from the [Tailscale Admin Console](https://login.tailscale.com/admin/settings/keys).
  It is required unless Tailscale is already connected on the host.
- Optional Backblaze B2 details: bucket name, path prefix, account/key ID,
  application key, and a restic encryption password. Leave the bucket name
  empty to skip backup configuration.
- Optional Cloudflare Tunnel token. Leave it empty to skip cloudflared.

There is no SSH-key prompt. The script fetches `keys/jedarden.pub` (required)
and `keys/jeda-mbp.pub` (best effort) from the repository’s raw GitHub URL and
writes those keys to `~/.ssh/authorized_keys` for every configured user. The
matching private keys must therefore be available to whoever will connect;
the same repository-managed keys are installed for all selected users.

Install mode has no flags for supplying these values. Its supported flags are
only `--version`/`-v` and `--verify`/`--check`; all installation choices are
collected by prompts.

### Optional: OpenBao secret sourcing

Instead of typing the B2 application key and restic password on every run,
set `OPENBAO_TOKEN` in the environment before starting. OpenBao lookup is
attempted only when Tailscale is active; otherwise the script falls back to
the prompts. The expected KV-v2 data is:

```json
{
  "data": {
    "data": {
      "b2_application_key": "<b2-application-key>",
      "restic_password": "<restic-encryption-password>"
    }
  }
}
```

The lookup path is
`secret/bootstrap/<hardware-uuid>/b2`, through
`https://traefik-rs-manager:8200/v1/secret/bootstrap/<hardware-uuid>/b2`.
OpenBao is optional; it does not supply the Tailscale or cloudflared token.
If invoking the script through `sudo` from a non-root shell, preserve the
variable (`sudo --preserve-env=OPENBAO_TOKEN bash`) or export it after opening
a root shell.

## Usage

### From Hetzner Rescue System

1. Boot into rescue mode via [Hetzner Robot](https://robot.hetzner.com).
2. SSH into rescue: `ssh root@<your-server-ip>`.
3. Install the OS:
   ```bash
   installimage
   # Select: Debian 12 or Ubuntu 24.04
   # Reboot when prompted
   ```
4. SSH back in after reboot and keep an interactive terminal:
   `ssh root@<your-server-ip>`.
5. Run the current bootstrap script as root:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap.sh | bash
   ```
   From a non-root account, use the equivalent:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap.sh | sudo bash
   ```
6. Answer the prompts described below. The bootstrap normally takes several
   minutes and prints a summary when complete.

### Prompts and saved configuration

On the first run the script asks for the following, in order:

| Prompt | Contract |
| --- | --- |
| Hostname | Defaults to the current hostname when left empty. |
| Users | Press Enter at the first username prompt to create the defaults `coding` and `trading`. Otherwise enter one or more lowercase usernames matching `[a-z_][a-z0-9_-]*`, then press Enter on an empty prompt to finish. |
| B2 bucket, path prefix, account/key ID | The path prefix defaults to `hetzner-ex44`; the script appends the machine’s hardware UUID to form the restic repository path. Backup is enabled only when both the bucket and account/key ID are non-empty; leave them empty to skip it. |
| Reboot after bootstrap | `y` enables an automatic reboot after a five-second delay; the default is `N`. |
| Tailscale auth key | Required unless `tailscale status` already succeeds. |
| Cloudflared token | Optional; an empty response skips cloudflared. |
| B2 application key and encryption password | Asked only when both a bucket and account/key ID were supplied, unless valid OpenBao data supplies both secrets. The password is confirmed interactively. |
| Restore from backup | Asked only when the configured restic repository already has snapshots. `y` restores `/home` and `/var/lib/tailscale` after setup; this overwrites those paths. |

The script saves non-secret choices in `/etc/bootstrap/config` with mode
`0600`: hostname, users, B2 bucket/path/account ID, and the reboot choice. On
a later run it displays that configuration and asks `Use previous
configuration? [Y/n]`; the default is yes, in which case only secrets are
requested again. Answer `n` to re-enter the non-secret choices. Tailscale,
cloudflared, and B2 secrets are not reused from `/etc/bootstrap/config`. When
backup is configured, credentials are written to `/etc/restic/b2.env` with
mode `0600` for restic and the scheduled backup jobs.

The bootstrap is designed to be rerunnable, but a rerun still reapplies
system state: it rewrites the SSH hardening configuration, resets and
re-enables UFW rules, refreshes user `authorized_keys`, and reinstalls or
updates missing software. Review the restore prompt carefully before
accepting it.

### After Bootstrap

Unless automatic reboot was selected, reboot when convenient so all kernel
and sysctl changes take effect. The public IP is firewalled except for
Hetzner rescue access; connect through Tailscale instead:

```bash
ssh coding@<hostname>.tailnet
ssh trading@<hostname>.tailnet
```

The configured users are in the `sudo` group and can launch the coding-agent
launcher with `start claude` or `start codex`.

### Post-bootstrap verification

Run the read-only verification mode as root. It checks UFW, Tailscale,
SSH hardening, Docker, fail2ban, auditd, kernel settings, and (when
configured) the restic/B2 repository:

```bash
curl -fsSL https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap.sh | sudo bash -s -- --verify
```

`--check` is an alias for `--verify`. Exit status `0` means every applicable
check passed; exit status `1` means one or more checks failed. All checks and
the summary still run after an individual failure. If B2 was skipped, the
backup section is reported as `SKIPPED` rather than failed. Run as root with
`sudo`; an unprivileged verification prints warnings and privileged checks
will fail.

### Backup and restore drill

Run this after bootstrap and periodically after changing the B2 or restic
configuration. It verifies that the credentials can reach the configured
repository, a new snapshot is written, and a representative file can be
restored and read. The commands below use a temporary restore target, so they
do not overwrite the live `/home` tree:

```bash
# Use the configured backup entry point and confirm that a snapshot exists.
sudo /usr/local/bin/backup-home
sudo /usr/local/bin/list-backups

# Create a marker in a backed-up path, then write it to B2.
sudo install -d -o coding -g coding /home/coding/workspace/restic-restore-drill
printf 'restic restore drill %s\n' "$(date -u +%FT%TZ)" |
  sudo tee /home/coding/workspace/restic-restore-drill/marker.txt >/dev/null
sudo chown coding:coding /home/coding/workspace/restic-restore-drill/marker.txt
sudo /usr/local/bin/backup-home

# Restore the latest snapshot into a disposable directory and verify the marker.
DRILL_DIR=$(mktemp -d /var/tmp/restic-restore-drill.XXXXXX)
sudo bash -c 'set -euo pipefail; source /etc/restic/b2.env; restic restore latest --target "$1" --include /home/coding/workspace/restic-restore-drill' _ "$DRILL_DIR"
sudo grep -Fq 'restic restore drill ' \
  "$DRILL_DIR/home/coding/workspace/restic-restore-drill/marker.txt"
sudo rm -rf "$DRILL_DIR"
```

The automated integration test performs the same round trip through
`restore-home latest`, changes the marker before restoring, and checks that
the restored file is readable by `coding`. A live `restore-home` invocation
restores into `/` and overwrites `/home` and `/var/lib/tailscale`; use it only
for an intentional recovery or maintenance window:

```bash
sudo /usr/local/bin/restore-home latest
```

Confirm the prompt only after checking the selected snapshot and ensuring the
host is ready for those paths to be replaced. The restic encryption password
and B2 application key remain in `/etc/restic/b2.env`; never put either value
in shell history, logs, or this procedure.

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
hosts/ex44/
├── bootstrap.sh         # Main bootstrap script (embeds start.sh, see below)
├── start.sh             # Canonical tmux + coding-agent launcher (self-updating)
├── start.sh.version     # Version string self-update compares against
├── sync-start-sh.sh     # Regenerates bootstrap.sh's embedded copy from start.sh
├── keys/
│   ├── jedarden.pub     # SSH public keys fetched at bootstrap time
│   └── jeda-mbp.pub     # (both are installed; jeda-mbp is optional)
└── README.md            # This file
```

**start.sh is single-sourced.** `bootstrap.sh` embeds a byte-for-byte copy of
`start.sh` in a heredoc to drop onto each new user's home directory; every
already-bootstrapped host's `start.sh` self-updates from the standalone
`start.sh` file afterward. Never hand-edit the embedded copy in
`bootstrap.sh` or hand-patch a deployed `~/start.sh`. From the repository root,
edit `hosts/ex44/start.sh`, then run:

```bash
./scripts/start-sh-release.sh release 1.3.1
./scripts/start-sh-release.sh --check
```

The helper updates `START_SH_VERSION`, writes the matching
`start.sh.version`, regenerates the embedded copy, and runs `bash -n` on both
scripts. The check rejects any disagreement among the standalone,
embedded, and advertised versions. Review and commit those three release
files, then run `./scripts/start-sh-release.sh publish`; pushing `origin/main`
updates Forgejo, whose server-side mirror publishes the GitHub raw URL used by
hosts. See `../../docs/plan/plan.md` ADR-1 and ADR-8 for the source-of-truth
and release decisions.

For rollback, restore a known-good Git revision under a new higher version so
the self-update comparison accepts it:

```bash
./scripts/start-sh-release.sh rollback GOOD_COMMIT 1.3.2
./scripts/start-sh-release.sh publish
```

**start.sh launches claude or codex, as the `start` command.** Selection order
is the positional agent (`start codex`) or `--agent claude|codex` >
`$START_SH_AGENT` > interactive prompt > `claude`. The prompt only appears when
stdin is a TTY, so non-interactive invocations take the `claude` default
instead of blocking. Giving a positional agent and a different `--agent` is an
error.

`~/.local/bin/start` is a **symlink** to `~/start.sh`, not a second copy:
`bootstrap.sh` creates it, and hosts bootstrapped earlier get it on the first
run after self-update lands v1.3.0. `~/start.sh` stays the deployed file so
self-update, the sync script and already-deployed hosts are unaffected; the
script resolves its real path (`readlink -f`) so it behaves the same through
the link. It only auto-links from `~/start.sh` itself and never replaces an
existing `start`. See `../../docs/plan/plan.md` ADR-7.

When start.sh detects that something is **already multiplexing** — a herdr
pane (`HERDR_ENV`) or an existing tmux client (`$TMUX`) — it skips tmux
entirely and execs the agent in the current pane rather than nesting. herdr is
checked first, since herdr rides on the same ambient tmux server and a herdr
pane has both variables set. On a bare shell the original behavior is
unchanged: a new phonetic-alphabet tmux session, then attach. See
`../../docs/plan/plan.md` ADR-2 and ADR-3.

```bash
start                         # prompt (or claude if no TTY)
start claude                  # explicit
start codex
start --agent codex           # same as `start codex`
START_SH_AGENT=codex start
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
sudo ./bootstrap.sh --verify
```

Run it as root (or with `sudo`): the UFW, `sshd -T`, fail2ban and auditd checks read state only root can see — an unprivileged run prints a warning up front and those checks report FAIL. The mode is safe to run unattended: it normalizes `PATH` (ufw and sysctl live in `/usr/sbin`, which cron omits) and `XDG_RUNTIME_DIR` (rootless Docker's socket), and every check is read-only.

**Exit code:** 0 if all checks pass, 1 if any check fails. All checks always run and the summary always prints — one failure never hides the rest.

**Use cases:**
- Right after bootstrap to confirm success
- Periodically after `unattended-upgrades` runs (catches config drift)
- From cron or a NEEDLE worker, alerting on the exit code

**Example output:**
```
=== Bootstrap Verification v1.1.6 ===

=== Firewall ===
UFW active:                              ✓ PASS
UFW default incoming policy:             ✓ PASS
UFW allows Tailscale:                    ✓ PASS

=== Tailscale ===
Tailscale connected:                     ✓ PASS

=== SSH Hardening ===
PermitRootLogin prohibited:              ✓ PASS
PasswordAuthentication disabled:         ✗ FAIL (got: passwordauthentication yes)
PubkeyAuthentication enabled:            ✓ PASS
MaxAuthTries limited:                    ✓ PASS

=== Summary ===
Total checks: 20
Passed:       19
Failed:       1
Skipped:      0

✗ Some checks failed. Review the output above.
```

A failed check prints the actual value it found (`got: ...`) so drift is visible directly in the output. On a host without backup configured, the Backup section reports `SKIPPED` (counted in the summary) instead of failing.

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
