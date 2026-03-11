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
