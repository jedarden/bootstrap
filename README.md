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
edit the embedded copy directly. Edit the standalone `start.sh`, then use the
release helper to update its version, regenerate the embedded copy, and run
the syntax/version checks:

```bash
./scripts/start-sh-release.sh release 1.3.1
./scripts/start-sh-release.sh --check
```

A release version is the same `MAJOR.MINOR.PATCH` in the standalone
`START_SH_VERSION=...` assignment, the generated embedded copy, and
`hosts/ex44/start.sh.version`. The helper rejects non-forward versions because
deployed launchers only self-update to a higher version. Review the diff, then
commit the release files (`hosts/ex44/start.sh`, `bootstrap.sh`, and
`start.sh.version`) and publish the commit with:

```bash
git add hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version
git commit -m "release(start.sh): v1.3.1"
./scripts/start-sh-release.sh publish
```

Forgejo remains the write-side source of truth. `publish` pushes only
`origin/main`; the configured Forgejo mirror then publishes the same commit
through GitHub, which is the URL used by bootstrap and self-update.

Before deploying a release, verify the distribution path from the committed
Forgejo state through GitHub and its raw artifacts:

```bash
./scripts/start-sh-release.sh distribution-check
```

Run the local self-update regression suite without contacting the network:

```bash
tests/start-sh-self-update-test.sh
```

The check requires the release files to be committed, confirms local `HEAD`
matches Forgejo `origin/main`, confirms GitHub `main` has the same commit, and
byte-compares the raw `bootstrap.sh`, `start.sh`, and `start.sh.version` files
with that commit. `publish` runs the same check after pushing to Forgejo and
waits for the mirror and raw files to converge.

To roll back a bad release, restore a known-good launcher from Git history
under a new, higher version, then review, commit, and publish it:

```bash
./scripts/start-sh-release.sh rollback GOOD_COMMIT 1.3.2
git diff -- hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version
git add hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version
git commit -m "rollback(start.sh): restore GOOD_COMMIT"
./scripts/start-sh-release.sh publish
```

The pre-commit hook also enforces the generated-copy check on every commit.
Git does not version hooks, so after a fresh clone activate it once:

```bash
git config core.hooksPath githooks
```
