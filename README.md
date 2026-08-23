# Bootstrap Scripts

Infrastructure bootstrap scripts for various server configurations.

## Available Configurations

| Directory | Description |
|-----------|-------------|
| [ex44/](./ex44/) | Hetzner EX44 dedicated server setup |

## Philosophy

- **Manual first** - Scripts designed for manual execution initially
- **Idempotent** - Safe to re-run
- **Minimal dependencies** - curl + bash to start
- **Security-first** - Hardened by default

## Future Plans

- Ansible playbooks for drift management
- K8s-based automation via Hetzner Robot API
- SOPS-encrypted secrets

## Development

`bootstrap.sh` embeds a full copy of `start.sh` (the Step 13 heredoc). Never
edit the embedded copy directly — edit the standalone `start.sh` that sits
next to it, regenerate the embedded copy, and commit both together (see
`docs/plan/plan.md`, ADR-1 and ADR-4):

```bash
cd hosts/ex44            # the directory containing start.sh and bootstrap.sh
./sync-start-sh.sh       # regenerate the embedded copy (--check: verify only)
```

A pre-commit hook enforces this on every commit. Git does not version hooks,
so after a fresh clone activate it once:

```bash
git config core.hooksPath githooks
```
