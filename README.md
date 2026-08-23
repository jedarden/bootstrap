# Bootstrap Scripts

Infrastructure bootstrap scripts for various server configurations.

## Available Configurations

| Directory | Description |
|-----------|-------------|
| [hosts/ex44/](./hosts/ex44/) | Hetzner EX44 dedicated server setup — the fleet's canonical script; lab.ardenone.com runs it verbatim |

## Repo Layout

One directory per fleet host under `hosts/` (`hosts/ex44/`, and `hosts/lab/`
when lab ever needs host-specific content). The bootstrap and launcher
scripts are consumed as single self-contained files over raw HTTPS, so there
is no shared/overlay layer: while two hosts run identical content they share
one directory, and a host gets its own directory by copying the current
script the moment it needs to diverge (different keys, backup targets, or
hardening). Versioned script archives (`bootstrap-<version>.sh`) live
alongside the current script in the host directory that shipped them. See
`docs/plan/plan.md` ADR-5 for the full decision.

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
