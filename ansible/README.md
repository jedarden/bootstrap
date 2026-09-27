# Ansible drift management

This directory reconciles the stable, post-bootstrap state of the Debian or
Ubuntu EX44 host. It is deliberately separate from the one-time installer:
`hosts/ex44/bootstrap.sh` remains the recovery path for a fresh machine, while
Ansible is the repeatable path for correcting configuration drift on a host
that is already bootstrapped.

## Scope

The default role manages:

- the Debian package prerequisites used by the bootstrap;
- configured users, sudo membership, home/workspace permissions, shell settings,
  tmux configuration, and optional authorized-key files;
- SSH hardening, kernel sysctl settings, UFW defaults and the Tailscale/Hetzner
  rescue allow rules;
- fail2ban, auditd, unattended-upgrades, needrestart, cron permissions,
  `/run/shm`, and disabled kernel modules;
- optional rootless-Docker prerequisites and user-service setup; and
- optional restic credentials/configuration, helper scripts, schedule, and log
  rotation when `bootstrap_backup_enabled` is enabled.

The following remain intentionally outside the default role: Tailscale
enrollment, Cloudflared token enrollment, Claude/Codex installation, the
self-updating `start.sh` payload, DNS/timezone selection, backup repository
initialization, backup/restore execution, and any secret not supplied through
encrypted inventory variables. Those operations either require an interactive
or externally issued credential, or have data-plane side effects that are not
safe as routine drift reconciliation.

UFW rules are additive. The role does not reset or delete rules that an
operator manages separately. Authorized-key replacement is opt-in with
`bootstrap_manage_authorized_keys: true`; keep it false until every key is
present in the encrypted inventory.

For each `bootstrap_users` entry, the role converges `/home/<user>` and the
managed `.tmp/`, `.cache/`, and `workspace/` directories to that user's
ownership. The home and managed directories are mode `0700`, `.ssh/` is
`0700`, and an opted-in `authorized_keys` file is `0600`. This is the same
filesystem boundary used by the interactive bootstrap: an unprivileged user
can use its own workspace but cannot traverse another user's home. The role
does not install or rewrite `start.sh`; the signed per-user launcher remains
owned by the bootstrap/release workflow.

Rootless Docker is opt-in with `bootstrap_manage_rootless_docker: true`. It
installs the Docker client and rootless runtime prerequisites, allocates
non-overlapping subordinate UID/GID ranges, disables the system daemon,
enables lingering and the per-user `docker.service`, and exports each user's
`/run/user/<uid>/docker.sock` through the managed shell block. The rootful and
rootless Docker flags are mutually exclusive.

## First use

Install the pinned collection dependencies, copy the example inventory, and
edit the host and non-secret variables:

```bash
cd ansible
ansible-galaxy collection install -r collections/requirements.yml
cp inventory/hosts.yml.example inventory/hosts.yml
${EDITOR:-vi} inventory/hosts.yml
```

Put secret values such as `bootstrap_restic_env` in the repository's
SOPS-encrypted YAML workflow described in [`../docs/secrets/sops.md`](../docs/secrets/sops.md),
or another secret-management-backed variable source. Do not put credentials
in the repository, inventory example, command arguments, or logs. The
repository wrapper selects exactly one `secrets/ansible/*.sops.yml` file and
passes it to Ansible through a SOPS FIFO; do not place a plaintext file under
`group_vars/`.

When `bootstrap_backup_enabled` is true, the encrypted YAML must be a
top-level Ansible variable mapping containing non-empty values for all four
runtime fields below. Non-secret settings such as users and firewall rules
remain in inventory or another non-secret variable source:

```yaml
bootstrap_backup_enabled: true
bootstrap_restic_env:
  B2_ACCOUNT_ID: <b2-account-id>
  B2_ACCOUNT_KEY: <b2-account-key>
  RESTIC_REPOSITORY: <restic-repository>
  RESTIC_PASSWORD: <restic-password>
```

The role validates this contract before creating `/etc/restic/b2.env`; a
missing, empty, or malformed value fails the run without writing the runtime
secret file.

Preview and apply the complete reconciliation with an explicit limit:

```bash
./run-drift.sh check --limit ex44 --diff
./run-drift.sh apply --limit ex44 --diff
```

The `check-drift.yml` playbook always runs in check mode. It is safe to run
against a live host, but it cannot prove that a remote package manager or
service will accept a change; inspect its diff before applying.

## Idempotence validation

After an apply, run the check twice. The second run should report
`changed=0` for every host and no unexpected diff:

```bash
./run-drift.sh apply --limit ex44 --diff
./run-drift.sh check --limit ex44 --diff
./run-drift.sh check --limit ex44 --diff
```

The repository-only syntax gate is:

```bash
./validate.sh
```

It validates every playbook without contacting a host. A live idempotence
check needs a disposable or explicitly selected host; it is not run by the
repository gate because applying these tasks changes firewall, SSH, and
service state.

The acceptance test exercises both drift playbooks against a disposable
privileged Debian container. It covers initial convergence, idempotent
reapplication, representative file drift, check mode, and invalid backup or
Docker-policy variables without changing the controller or host:

```bash
../tests/ansible-drift-acceptance-test.sh
```

The test requires Docker and the `community.docker` Ansible collection. Set
`BOOTSTRAP_DRIFT_TEST_REQUIRE_DOCKER=true` when an unavailable Docker daemon
should fail rather than skip the test.
