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
hardening). Every release creates a versioned bootstrap archive
(`bootstrap-<version>.sh`) alongside the current script in the host directory
that shipped it. The archive is an exact copy of that release's `bootstrap.sh`
and includes the same bootstrap and launcher version metadata. See
`docs/plan/plan.md` ADR-5 for the full layout decision. Archives are immutable:
the helper creates one for each new release and never rewrites older versions.

## Philosophy

- **Manual first** - Scripts designed for manual execution initially
- **Idempotent** - Safe to re-run
- **Minimal dependencies** - curl + bash to start
- **Security-first** - Hardened by default

## Future Plans

- [Ansible playbooks for drift management](./ansible/README.md)
- [Kubernetes-based Hetzner Robot provisioning](./automation/hetzner_robot/README.md)
- [SOPS-encrypted secrets](./docs/secrets/sops.md)

## Development

`bootstrap.sh` embeds a full copy of `start.sh` (the Step 13 heredoc). Never
edit the embedded copy directly. Edit the standalone `start.sh`, then use the
release helper to update the release metadata, regenerate the embedded copy,
create the versioned bootstrap archive, and sign the artifact manifest. Keep
the private signing key outside Git and provide it through
`ARTIFACT_SIGNING_KEY`:

```bash
ARTIFACT_SIGNING_KEY=/secure/path/bootstrap-artifacts-signing.pem \
  ./scripts/start-sh-release.sh release 1.3.2
./scripts/start-sh-release.sh --check
```

Each host directory publishes `artifact-manifest.txt` and its detached
`artifact-manifest.sig`. The manifest is signed with the pinned public key in
`hosts/ex44/keys/bootstrap-artifacts-signing.pub` and binds the launcher,
bootstrap archives, version marker, and SSH public keys to SHA-256 digests.
Release signing keys are operator-held; never add one to the repository.
For a new host lineage or the first signing release, follow the
[initial trust-anchor provisioning runbook](./docs/security/artifact-signing.md)
before publishing any artifact.

Before rollout, validate every host artifact set from the current working tree
and from the staged Git index:

```bash
./scripts/check-host-parity.sh --live
./scripts/check-host-parity.sh --staged
```

The check discovers every immediate directory under `hosts/` and independently
validates its `bootstrap.sh`, `start.sh`, `start.sh.version`, and every
`bootstrap-<version>.sh` archive. It checks syntax, embedded launcher
equality, version metadata, current-archive equality, and that each host is
linked from this README. Host directories are separate release lineages, so
intentional host-specific content does not need to be byte-identical. The
`--allow-split` option remains accepted for compatibility with older command
lines but is no longer required.

A release version is the same `MAJOR.MINOR.PATCH` in the standalone
`START_SH_VERSION=...` assignment, the generated embedded copy,
`hosts/ex44/start.sh.version`, the `bootstrap.sh` metadata, and
`hosts/ex44/bootstrap-<version>.sh`. The helper rejects non-forward versions
because deployed launchers only self-update to a higher version. Review the
diff, then commit the release files (`hosts/ex44/start.sh`, `bootstrap.sh`,
`start.sh.version`, the manifest/signature, and the new versioned archive) and
publish the commit with:

```bash
git add hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version \
  hosts/ex44/artifact-manifest.txt hosts/ex44/artifact-manifest.sig \
  hosts/ex44/bootstrap-1.3.2.sh
git commit -m "release(start.sh): v1.3.2"
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
tests/artifact-authentication-test.sh
```

## Artifact authentication

Do not execute an initial bootstrap directly from an unverified raw HTTPS
stream. Download the immutable versioned archive and its signed metadata, then
verify the public-key fingerprint and both the detached signature and archive
digest before running it:

```bash
version=1.3.1
base=https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44
curl -fsSLo "bootstrap-$version.sh" "$base/bootstrap-$version.sh"
curl -fsSLo artifact-manifest.txt "$base/artifact-manifest.txt"
curl -fsSLo artifact-manifest.sig "$base/artifact-manifest.sig"
curl -fsSLo bootstrap-artifacts-signing.pub "$base/keys/bootstrap-artifacts-signing.pub"
test "$(openssl pkey -pubin -in bootstrap-artifacts-signing.pub -outform DER 2>/dev/null | sha256sum | awk '{print $1}')" = \
  a6f26805c65bcd4de965b6d642c6dc5989de1cfa4c7e1b2e9bcb2b94ab28c589
sed -n 's/^signature=//p' artifact-manifest.sig | base64 --decode > artifact-manifest.sig.bin
openssl dgst -sha256 -verify bootstrap-artifacts-signing.pub \
  -signature artifact-manifest.sig.bin artifact-manifest.txt
awk -v file="bootstrap-$version.sh" '$1 == "artifact=" file {print $2 "  " file}' artifact-manifest.txt | sha256sum -c -
chmod +x "bootstrap-$version.sh"
sudo "./bootstrap-$version.sh"
```

The running bootstrap repeats this verification for its own file, the SSH
keys, and every generated `start.sh`; a piped install is rejected. On an
offline, malformed, stale, unsigned, or digest-mismatched response, bootstrap
stops before trusting the artifact. `start.sh` keeps the existing launcher and
continues to the selected agent when its update check fails.

### Signing-key rotation

Rotation is a two-release migration. The primary
`ARTIFACT_TRUSTED_KEY_ID`/`ARTIFACT_TRUSTED_PUBLIC_KEY` pair is the signer for
the current manifest; `ARTIFACT_TRUSTED_KEY_IDS` and
`ARTIFACT_TRUSTED_PUBLIC_KEYS` are parallel arrays, with the primary pair
first. A manifest's `key_id` must select one of those embedded pairs, so a
stale raw response cannot replace the trust anchor.

1. Generate the new private key and public key outside Git. Record the new key
   ID and its DER-SHA-256 fingerprint in the release review; never put the
   private key in the repository or in a command argument.
2. Prepare the transition release by editing only `hosts/ex44/start.sh`:
   retain the old primary pair and append the new ID/public key to both trust
   arrays. Run `hosts/ex44/sync-start-sh.sh` so the bootstrap copy receives the
   same overlap set. Keep `keys/bootstrap-artifacts-signing.pub` as the old
   public key and sign this release with the old private key.
3. Before committing, run the structural rotation gate and the normal checks:

   ```bash
   ARTIFACT_SIGNING_KEY=/secure/path/old-signing-key.pem \
     ./scripts/start-sh-release.sh release 1.3.2
   ./scripts/start-sh-release.sh rotation-check \
     bootstrap-rsa-2026-09 bootstrap-rsa-2026-10
   ./scripts/start-sh-release.sh --check
   tests/artifact-key-rotation-test.sh
   ```

   `rotation-check` requires the manifest to remain signed by the old key and
   both launcher copies to embed the new key. It does not claim that hosts
   have migrated; record the deployed-host inventory separately.
4. Keep the overlap for at least 30 days and until every supported host has
   crossed the transition release (or has an explicitly approved out-of-band
   update). Retain the old private key until that migration check and the
   first new-key release have both been verified. During overlap, both old and
   new signatures are accepted; after retirement, old signatures must fail.
5. Publish the migration release by making the new pair primary, replacing
   the committed public key with the new public key, reducing both trust arrays
   to the new pair, and signing with the new private key. Do not remove an
   immutable `bootstrap-<version>.sh` archive. `manifest` generation retains
   every archive tracked in Git, and the release check fails if a historical
   archive is deleted.

Historical verification remains available from the immutable historical Git
commit using its manifest, signature, and then-current public key. The
current manifest also retains the SHA-256 entries for those archives, so a
new-key release can audit their bytes without changing them. A missing key,
stale trust anchor, key-ID mismatch, or unsigned manifest fails closed and
leaves an installed launcher in place. If the old key is compromised before
overlap completes, do not publish a one-step replacement: use an
out-of-band trusted host/bootstrap path to install a launcher carrying the
new anchor.

The check requires the release files, including the versioned archive and
signed manifest, to be committed, confirms local `HEAD`
matches Forgejo `origin/main`, confirms GitHub `main` has the same commit, and
byte-compares the raw `bootstrap.sh`, `start.sh`, `start.sh.version`, and
`bootstrap-<version>.sh` files with that commit. `publish` runs the same check
after pushing to Forgejo and waits for the mirror and raw files to converge.

### SSH public-key rotation

Host access keys are host-specific inputs under `hosts/<host>/keys/` and are
covered by the signed artifact manifest. Rotate one declared key at a time,
retain an independently approved fallback during rollout, regenerate and sign
the complete release with `scripts/start-sh-release.sh`, and verify a fresh
connection with the replacement before ending the existing session. After all
supported hosts have crossed the release, retire the old key in a later
forward release and verify that a connection using its private key fails. The
full runbook, including the safe single-key and spare-slot cases, is in the
[SSH public-key rotation procedure](./docs/security/ssh-key-rotation.md).

Run the offline acceptance test before committing a rotation:

```bash
tests/ssh-key-rotation-test.sh
```

To roll back a bad release, restore a known-good launcher from Git history
under a new, higher version, then review, commit, and publish it:

```bash
./scripts/start-sh-release.sh rollback GOOD_COMMIT 1.3.2
git diff -- hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version
git diff -- hosts/ex44/bootstrap-1.3.2.sh
git add hosts/ex44/start.sh hosts/ex44/bootstrap.sh hosts/ex44/start.sh.version hosts/ex44/bootstrap-1.3.2.sh
git commit -m "rollback(start.sh): restore GOOD_COMMIT"
./scripts/start-sh-release.sh publish
```

The pre-commit hook also enforces the generated-copy check on every commit.
Git does not version hooks, so after a fresh clone activate it once:

```bash
git config core.hooksPath githooks
```

The definition-of-done check verifies this clone-local setting and fails
loudly if it is missing or points somewhere else. Run it after activating the
hooks:

```bash
scripts/definition-of-done.sh --fast
```
