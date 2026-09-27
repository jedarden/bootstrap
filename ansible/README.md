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
in the repository, inventory example, command arguments, or logs. When using
SOPS, pass the decrypted YAML through `sops exec-file` and Ansible's `-e @{}`
FIFO form; do not place a plaintext file under `group_vars/`.

Preview and apply the complete reconciliation with an explicit limit:

```bash
ansible-playbook playbooks/check-drift.yml --limit ex44 --diff
ansible-playbook playbooks/drift.yml --limit ex44 --diff
```

The `check-drift.yml` playbook always runs in check mode. It is safe to run
against a live host, but it cannot prove that a remote package manager or
service will accept a change; inspect its diff before applying.

## Idempotence validation

After an apply, run the check twice. The second run should report
`changed=0` for every host and no unexpected diff:

```bash
ansible-playbook playbooks/drift.yml --limit ex44 --diff
ansible-playbook playbooks/drift.yml --limit ex44 --check --diff
ansible-playbook playbooks/drift.yml --limit ex44 --check --diff
```

The repository-only syntax gate is:

```bash
./validate.sh
```

It validates every playbook without contacting a host. A live idempotence
check needs a disposable or explicitly selected host; it is not run by the
repository gate because applying these tasks changes firewall, SSH, and
service state.
