# Host SSH public-key rotation

This procedure rotates the keys that bootstrap installs in a host user's
`authorized_keys`. It is separate from artifact signing-key rotation: the
artifact signing key authenticates the release, while the files under
`hosts/<host>/keys/` are the host's access inputs.

## Inputs and safety invariant

For the EX44 lineage the declared inputs are:

| Input | Bootstrap behavior |
| --- | --- |
| `hosts/ex44/keys/jedarden.pub` | Required; a missing or invalid file stops bootstrap. |
| `hosts/ex44/keys/jeda-mbp.pub` | Optional at bootstrap time for compatibility, but present and signed in every current release. |

Bootstrap authenticates the manifest before fetching either key, verifies each
download against the signed digest, and then writes the verified key set to
each configured user's `.ssh/authorized_keys`. The release helper includes
both public-key files in the manifest. Never put a private SSH key in Git, in
an artifact, or in a command argument.

The rollout must always retain one independently approved access path. Keep an
existing SSH session open and leave an approved key in the other host-specific
input until a fresh connection using the new key has succeeded. If both input
files are already occupied and there is no approved fallback, stop and arrange
an out-of-band or console recovery path before changing either file.

## Prepare a rotation release

Generate the replacement key on the operator workstation or another approved
key-management host. Store the private key outside the repository with
restrictive permissions; only the public key is copied into the host inputs.

```bash
repo=/path/to/bootstrap
host=ex44
slot=jeda-mbp
key_dir=/secure/ssh/$host/$slot-2026-10
private_key=$key_dir/id_ed25519
public_key=$key_dir/id_ed25519.pub

install -d -m 0700 "$key_dir"
(
  umask 077
  ssh-keygen -q -t ed25519 -N '' -C "$host-$slot-2026-10" -f "$private_key"
)
chmod 600 "$private_key"
chmod 644 "$public_key"
ssh-keygen -lf "$public_key"

# Review the separately approved fingerprint before this installation step.
install -m 0644 "$public_key" "$repo/hosts/$host/keys/$slot.pub"
git -C "$repo" diff --check
git -C "$repo" diff -- "hosts/$host/keys/$slot.pub"
```

The example rotates `jeda-mbp.pub` while `jedarden.pub` remains the approved
fallback. To rotate `jedarden.pub`, first ensure that `jeda-mbp.pub` is an
approved fallback. When the only approved key is being rotated, use the
optional slot for a transition release first, verify the new connection, and
only then replace the old slot in a later release. The two declared slots are
the complete host input set; adding an unreferenced filename does not grant
access.

Regenerate and sign the complete release from the repository root. Do not
hand-edit `bootstrap.sh`, the versioned archive, the manifest, or its
signature:

```bash
next_version=1.3.2
ARTIFACT_SIGNING_KEY=/secure/path/bootstrap-artifacts-signing.pem \
  ./scripts/start-sh-release.sh release "$next_version"
./scripts/start-sh-release.sh --check
./scripts/check-host-parity.sh --live
tests/ssh-key-rotation-test.sh
```

`release` synchronizes the canonical launcher into `bootstrap.sh`, creates the
new immutable `bootstrap-<version>.sh`, and signs a manifest containing the
new SSH-key digest plus every other host artifact. Stage the complete host
release together after reviewing it. For example:

```bash
git add \
  "hosts/$host/keys/$slot.pub" \
  "hosts/$host/start.sh" \
  "hosts/$host/bootstrap.sh" \
  "hosts/$host/start.sh.version" \
  "hosts/$host/bootstrap-$next_version.sh" \
  "hosts/$host/artifact-manifest.txt" \
  "hosts/$host/artifact-manifest.sig"
git diff --cached --check
```

The signing key in `ARTIFACT_SIGNING_KEY` is an operator-held artifact
signing key, not the SSH key being rotated. Keep both private keys outside
the repository.

## Roll out without losing access

1. Confirm the release commit is on `main` and the distribution check has
   converged. Use the normal authenticated, immutable bootstrap rollout; do
   not execute an unverified `curl | bash` stream.
2. Keep an existing session authenticated by the unchanged approved fallback
   key. The bootstrap must finish its signed manifest and per-key digest checks
   before it writes `authorized_keys`.
3. From a second terminal, connect with the replacement private key and run a
   harmless identity check. Also reconnect with the unchanged fallback key.
   Do not close the original session until both checks succeed.
4. Confirm the deployed file contains the fallback and replacement public keys
   and does not contain the retired key. The expected permissions remain
   `0700` for `.ssh` and `0600` for `authorized_keys`.

When the replacement key is being staged in the spare slot, both the old and
new keys are authorized during this transition. After every supported host is
confirmed reachable with the replacement (or has an explicitly approved
out-of-band update), publish a retirement release that removes the old public
key from the host input set. Re-run the release checks and verify a fresh SSH
attempt with the old private key fails. Do not revoke the only fallback before
that verification.

If the new connection fails, keep the existing session open, stop the rollout,
and restore access through the unchanged fallback or the approved console
path. A correction is a new forward release; do not rewrite an immutable
archive or force-push history.

The offline acceptance test models this rollout with a disposable `sshd`: it
checks access with the old and fallback keys before replacement, regenerates
and signs a release after changing a host-specific public-key input, then
checks that the fallback and new key work while the old key is rejected.
