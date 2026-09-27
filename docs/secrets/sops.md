# SOPS secret management

This repository uses SOPS with age for operator-managed secret material. The
encrypted file is the reviewable source of record; the age private keys and
all plaintext values stay outside Git. SOPS is an operator-side tool. It is
not installed by `hosts/ex44/bootstrap.sh`, and an age private key is never
copied to a provisioned host.

The design has two deliberately separate paths:

| Source | Owner | Use |
| --- | --- | --- |
| SOPS-encrypted files | Operator/Git | Reproducible bootstrap inputs and Ansible variables |
| OpenBao KV-v2 | Host/recovery operator | Optional per-host fallback when Tailscale is available |
| Interactive prompt | Person at the console | Last-resort bootstrap and recovery path |

SOPS and OpenBao are not automatically synchronized. SOPS remains the
operator-managed source of record; OpenBao is a host-local recovery/cache
source. A deliberate credential rotation updates both when both paths are
enabled.

## File layout and plaintext rules

Use explicit `.sops` filenames for encrypted material:

```text
secrets/bootstrap/ex44.sops.env
secrets/ansible/ex44.sops.yml
```

The repository ignores ordinary files under `secrets/*/` so a temporary
plaintext file cannot be committed accidentally. The negated `.sops.env`,
`.sops.yml`, and `.sops.yaml` patterns are the only files in that tree that
may be tracked. Do not add a decrypted copy, age identity, OpenBao token, B2
key, or restic password to Git.

The bootstrap SOPS dotenv file has exactly these two application-facing
variables (the values below are placeholders and must never be entered into a
shell command line):

```dotenv
BOOTSTRAP_B2_APPLICATION_KEY=<b2-application-key>
BOOTSTRAP_RESTIC_PASSWORD=<restic-encryption-password>
```

Both variables are required together. The bootstrap script rejects a partial
pair instead of combining one SOPS value with OpenBao or an interactive
prompt.

## Age key handling

Provision two independent age recipients before creating the first encrypted
file:

1. a primary operator recipient, whose private identity is kept on the
   operator workstation or hardware-backed secret store; and
2. an offline recovery recipient, whose private identity is kept separately
   from the primary identity and from the B2/restic data it unlocks.

Only the public recipients belong in the repository's `.sops.yaml` creation
rules or in SOPS file metadata. Do not invent a recipient or commit a private
identity to make a local example work. Once the real recipients are
provisioned, commit the public `.sops.yaml` rules with the encrypted files.

On Linux, keep the private identity file at the SOPS default
`$HOME/.config/sops/age/keys.txt`, or point `SOPS_AGE_KEY_FILE` at a mode-0600
file. Prefer the file variable over `SOPS_AGE_KEY` so the private key is not
copied through shell command strings. A recovery copy must be tested before
the primary key is retired.

Do not store the age private key in OpenBao as part of the normal bootstrap
flow. That would make the host need OpenBao to decrypt the SOPS input and
would turn the two recovery paths into one circular dependency. If local
policy requires an escrow copy, store it as a separately controlled,
access-audited recovery item and never make bootstrap fetch it automatically.

## Creating and editing encrypted files

Install pinned, reviewed versions of `sops` and `age` on the operator
workstation. [`sops.yaml.example`](sops.yaml.example) shows the repository
rules; copy it to a root `.sops.yaml`, replace both public-recipient
placeholders, and commit that public configuration with the encrypted files.
Creation rules are evaluated in order; keep the specific bootstrap and
Ansible rules before any fallback rule.

Create or edit the encrypted dotenv file directly. `sops edit` opens a
temporary plaintext editor buffer and writes ciphertext back to the target:

```bash
install -d -m 700 secrets/bootstrap
sops edit secrets/bootstrap/ex44.sops.env
```

Enter only `BOOTSTRAP_B2_APPLICATION_KEY` and
`BOOTSTRAP_RESTIC_PASSWORD`. Do not use `printf`, a here-document, or a
command-line flag containing either value. Confirm the result is encrypted
before staging it:

```bash
sops filestatus secrets/bootstrap/ex44.sops.env
git diff --check
```

For Ansible, store the variables required by `bootstrap_restic_env` in an
encrypted YAML file outside `ansible/group_vars/` and pass it through a SOPS
FIFO. The FIFO avoids leaving decrypted YAML on disk:

```bash
sops exec-file secrets/ansible/ex44.sops.yml \
  'ansible-playbook ansible/playbooks/check-drift.yml --limit ex44 --diff -e @{}'
```

Use the same form for `playbooks/drift.yml` after reviewing check mode. Do
not use `--no-fifo` unless the consumer genuinely needs a seekable file; if
it is required, ensure the temporary file is mode 0600 and is destroyed
immediately after the command exits.

## Bootstrap consumption

SOPS decrypts only on the operator workstation and passes the two dotenv
variables to the one bootstrap process. For a checked-out repository:

```bash
sops exec-env secrets/bootstrap/ex44.sops.env \
  'exec bash hosts/ex44/bootstrap.sh'
```

For a fresh host, the same process-environment contract works with the raw
bootstrap stream:

```bash
sops exec-env secrets/bootstrap/ex44.sops.env \
  'exec bash -s' < <(curl -fsSL \
    https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/bootstrap.sh)
```

The operator's age private key and the SOPS ciphertext stay on the operator
side. The target host receives only the normal interactive bootstrap input
and, for the lifetime of that process, the two environment variables. The
script does not save those SOPS-specific variables in `/etc/bootstrap/config`.
It writes the resulting runtime B2/restic environment to
`/etc/restic/b2.env` with mode `0600`, which is required by the existing backup
jobs.

When backup is configured, the source precedence is:

1. both SOPS environment variables;
2. both OpenBao KV-v2 fields; or
3. interactive prompts.

The SOPS path wins even when `OPENBAO_TOKEN` is also present. This makes an
explicit operator run deterministic and prevents a stale OpenBao value from
silently overriding a reviewed encrypted change.

SOPS does not supply the Tailscale auth key or Cloudflared token. Those remain
interactive inputs. OpenBao also does not supply them.

## OpenBao reconciliation

The existing OpenBao contract remains:

```text
https://traefik-rs-manager:8200/v1/secret/bootstrap/<hardware-uuid>/b2
```

The KV-v2 data fields are `b2_application_key` and `restic_password`. The
bootstrap lookup is attempted only after Tailscale is active and only when a
complete SOPS pair was not supplied. If OpenBao is unreachable or the fields
are incomplete, the script falls back to interactive prompts.

Do not make the bootstrap script download a SOPS file and do not put an age
private key on the host. For a host-side re-bootstrap, choose one of these
explicit paths:

- run `sops exec-env` from the operator workstation; or
- use `OPENBAO_TOKEN` and the per-host KV-v2 record over the Tailscale path.

If both records are enabled, update SOPS first, validate a bootstrap or
Ansible run, then update the corresponding OpenBao record through the approved
OpenBao workflow. Never echo either record or token while doing so.

## Rotation

There are two kinds of rotation and they must not be conflated.

### SOPS recipients and data keys

When adding a new operator or replacing a recipient, first update the public
recipient rules, then update the encrypted files. Use `updatekeys` when only
the recipient set changes, and `rotate` when the SOPS data-encryption key
should also be renewed:

```bash
sops updatekeys --yes secrets/bootstrap/ex44.sops.env
sops updatekeys --yes secrets/ansible/ex44.sops.yml
sops rotate --in-place secrets/bootstrap/ex44.sops.env
sops rotate --in-place secrets/ansible/ex44.sops.yml
```

Review the encrypted diff and test decryption with both the primary and
recovery identity before pushing. After a private identity is suspected
compromised, add the replacement recipient, re-encrypt, verify recovery, and
remove the compromised recipient. Rotating recipients cannot erase ciphertext
copies that were already downloaded, so rotate the underlying B2/restic
credentials as well.

### B2 and restic credentials

For a B2 application-key rotation, create the replacement key, edit the SOPS
dotenv file, update OpenBao if it is enabled, run the bootstrap or Ansible
reconciliation, and perform a backup/restore drill. Revoke the old B2 key only
after the new credentials have successfully written and read a snapshot.

Restic repository encryption is different: replacing
`BOOTSTRAP_RESTIC_PASSWORD` alone can make existing snapshots unreadable. Add
the new restic key to the repository, verify that it can list and restore a
snapshot, then update SOPS and OpenBao, and remove the old restic key only
after the recovery drill succeeds. Keep the old key available until that
validation is complete.

## Recovery

1. **Operator key unavailable:** set `SOPS_AGE_KEY_FILE` to the offline
   recovery identity and use the normal `sops exec-env` command. Do not print
   the identity or decrypted file.
2. **Host lost, OpenBao available:** provision the replacement host, bring up
   Tailscale, and use the documented `OPENBAO_TOKEN` fallback. The host's
   hardware UUID is part of the path, so a replacement host needs an
   intentionally provisioned record rather than guessing another host's path.
3. **Host lost, OpenBao unavailable:** use the recovery age identity from the
   operator side. This is the preferred path because the age key never had to
   exist on the failed host.
4. **Both age identities lost:** the encrypted files are intentionally
   unrecoverable. Restore the recovery identity from the separately protected
   offline backup before attempting bootstrap. Do not create a new identity
   and overwrite the old recipient metadata.

After any suspected credential disclosure, revoke or rotate the affected B2
key, restic key, OpenBao token, and age recipient as applicable. Treat old
SOPS ciphertext as compromised if an age private key was exposed.

## Verification checklist

Before committing or applying a change:

```bash
sops filestatus secrets/bootstrap/ex44.sops.env
git diff --check
bash -n hosts/ex44/bootstrap.sh
scripts/definition-of-done.sh --fast
```

Also decrypt with the primary identity and, during a planned recovery drill,
with the offline identity. The clean-extraction definition-of-done check must
pass before a change is pushed. A successful `sops filestatus` proves the file
has SOPS metadata; it does not prove that every intended recipient can still
decrypt it.
