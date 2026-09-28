# Emergency artifact-signing-key compromise recovery

Use this procedure when the artifact-signing private key is lost, stolen,
exposed, or suspected of being used by somebody else. A lost key is still an
emergency: it cannot sign a recovery release, and a suspected compromise
means that every signature made with the key is no longer evidence of
operator approval.

This is deliberately different from [planned signing-key rotation](../../README.md#signing-key-rotation).
Planned rotation uses a reviewed overlap release, keeps the old key trusted
while hosts migrate, and waits for the supported-host inventory. Emergency
recovery revokes the old trust anchor immediately, has no overlap period, and
uses an out-of-band path for hosts that still carry the old launcher.

## 1. Halt the rollout and preserve evidence

Stop all release preparation, publishing, and host rollout immediately:

1. Do not sign, publish, or deploy any pending release with the old key.
2. Do not use the old key to make a transition release. Do not run the normal
   `rotation-check`; it intentionally requires the old key to remain the
   primary signer and trusted during overlap.
3. Record the compromised key ID, DER-SHA-256 fingerprint, the suspected
   compromise time, the last known-good Forgejo commit, pending release
   versions, and the deployed-host inventory. Preserve the relevant logs and
   copies of the old manifest/signature for incident review.
4. Quarantine the old private-key file and revoke its access in the operator
   key store. If it is lost, mark the key revoked in the key inventory. Do not
   delete historical repository artifacts as an attempted revocation; Git
   history and immutable archives are evidence.

Treat every artifact signed by the old key after the last known-good point as
untrusted until independently reviewed. A mathematically valid signature does
not prove that a signature made after compromise was approved.

## 2. Generate and approve a replacement key

Generate the replacement on the protected signing host, outside the checkout,
using the same path-only contract as normal releases:

```bash
key_id=bootstrap-rsa-2026-10-emergency
key_dir=/secure/bootstrap-signing/$key_id
private_key=$key_dir/private.pem
public_key=$key_dir/public.pem

install -d -m 0700 "$key_dir"
(
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$private_key"
)
chmod 0600 "$private_key"
openssl pkey -in "$private_key" -pubout -out "$public_key"
chmod 0644 "$public_key"

fingerprint=$(
  openssl pkey -pubin -in "$public_key" -outform DER |
    sha256sum | awk '{print $1}'
)
printf 'key_id=%s fingerprint=%s\n' "$key_id" "$fingerprint"
```

Verify the fingerprint through a separately trusted channel before putting the
public key in Git. The private key must stay outside the repository and must
never be placed in an environment value, command argument, release artifact,
or log. `ARTIFACT_SIGNING_KEY` receives only the private-key path.

## 3. Replace the pinned anchor with no overlap

Use a clean `main` checkout and review the last known-good release before
editing. Replace the public key at
`hosts/<host>/keys/bootstrap-artifacts-signing.pub`, and edit only the
canonical `hosts/<host>/start.sh` trust block so it contains exactly the new
pair:

```bash
ARTIFACT_TRUSTED_KEY_ID="$key_id"
ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'
<contents of the approved replacement public.pem>
ARTIFACT_KEY
)
ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")
ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")
```

Synchronize the generated bootstrap copy and check it before signing:

```bash
install -m 0644 "$public_key" \
  "hosts/$host/keys/bootstrap-artifacts-signing.pub"
(cd "hosts/$host" && ./sync-start-sh.sh)
(cd "hosts/$host" && ./sync-start-sh.sh --check)
```

Do not retain the old key in either trust array. Do not copy the old public
key back into the pinned-key file. The new manifest must be signed by the
replacement private key, and the release helper will reject a signing key
whose fingerprint does not match the newly pinned public key.

## 4. Prepare, publish, and roll out a forward release

The emergency release must have a version higher than every version that may
already be deployed, including a malicious or otherwise halted candidate.
Keep every existing `bootstrap-<version>.sh` archive. Prepare and validate the
new release with the replacement key:

```bash
next_version=1.3.3
ARTIFACT_SIGNING_KEY="$private_key" \
  ./scripts/start-sh-release.sh --host "$host" release "$next_version"
./scripts/start-sh-release.sh --host "$host" --check
./scripts/check-secret-leakage.sh --tracked --artifacts
tests/artifact-signing-compromise-recovery-test.sh
```

Review that the manifest `key_id`, detached signature, pinned public-key
fingerprint, standalone launcher, generated bootstrap, and new immutable
archive all use the replacement trust anchor. Stage only the release files,
commit on `main`, and publish through Forgejo:

```bash
git add "hosts/$host/start.sh" "hosts/$host/bootstrap.sh" \
  "hosts/$host/start.sh.version" "hosts/$host/artifact-manifest.txt" \
  "hosts/$host/artifact-manifest.sig" \
  "hosts/$host/bootstrap-$next_version.sh" \
  "hosts/$host/keys/bootstrap-artifacts-signing.pub"
git commit -m "security($host): recover artifact signing trust anchor"
./scripts/start-sh-release.sh --host "$host" publish
```

Do not roll out until the Forgejo/GitHub/raw distribution check succeeds.
Record the commit and the new key fingerprint in the incident record.

## 5. Recover already-deployed hosts

An old deployed launcher embeds the old trust anchor. It correctly rejects a
manifest signed by the replacement key, so publishing the new release alone
cannot migrate those hosts. Use an independently trusted administrative
channel for each host—console, rescue environment, or a separately verified
SSH session—to install the reviewed new-anchor launcher:

1. Verify the replacement launcher bytes and its new-key release manifest from
   the trusted operator workstation.
2. Install that launcher atomically at the deployed user's `start.sh` and
   verify its syntax, version, embedded key ID, and public-key fingerprint.
3. Run `start.sh --no-update --version`, then run the normal launcher once so
   it can self-update from the new signed release.
4. Repeat for every target in the reviewed rollout map and run
   `scripts/verify-deployed-launchers.sh`.

Do not use the old launcher as the recovery mechanism. If a host received a
release signed after the suspected compromise, isolate it first; do not run
that launcher to update itself. Reimage or re-bootstrap it from the newest
replacement-key archive after preserving the evidence required by the
incident review.

## 6. Handle older artifacts and finish the revocation

Older immutable archives remain in Git and in the current manifest so their
bytes can be audited. The new manifest may carry their SHA-256 entries, but
that does not make an old-key signature trustworthy again:

- An old-key manifest or old-key-only bootstrap is not an emergency recovery
  path after compromise, even if OpenSSL verifies its signature.
- Use an older payload only when its bytes are independently confirmed against
  a pre-compromise Forgejo commit or offline release record, and only as a
  controlled intermediate step to install the replacement-anchor launcher.
  Prefer the newest replacement-key archive.
- Never delete or rewrite a historical archive to hide the incident. Record
  which versions were deployed and which were withheld.
- After the out-of-band migration, the new-anchor verifier must accept the new
  manifest and reject the old manifest. A host that still accepts the old key
  has not completed recovery.

The incident is closed only after the old private key is revoked/quarantined,
the new release is distributed, every host is accounted for, compromised
hosts are rebuilt or cleared by incident response, old-key signatures fail on
the recovered launcher, and the new release's signed artifact and deployment
checks pass.
