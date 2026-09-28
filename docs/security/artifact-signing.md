# Initial artifact-signing trust-anchor provisioning

This is the one-time procedure for a new host lineage. It creates the
operator-held signing key, verifies the public-key fingerprint through a
separate trusted channel, pins only the public key in the repository, and
creates the first signed release. It is intentionally separate from key
rotation; after the first release, use the overlap procedure in the
[release documentation](../../README.md#signing-key-rotation).

The private key must remain outside the repository and outside release
artifacts. The release helper receives only a filesystem path through
`ARTIFACT_SIGNING_KEY`; it reads the key when OpenSSL signs the manifest. Do
not put the PEM value in an environment variable, a command argument, a log,
or a commit.

## New divergent host lineage

Use this procedure when a host needs its own keys, backup target, hardening, or
other release content. It starts from the current release but gives the new
directory its own repository URL, trust anchor, SSH inputs, signed manifest,
and immutable archive. Run it from a clean `main` checkout, and choose a
lowercase host directory name that does not already exist.

### 0. Copy the current release and link the host

The copy includes the current archive so the new lineage has a verified
rollback/bootstrap starting point. Do not copy a private signing or SSH key;
the source directory contains public inputs only.

```bash
repo=/path/to/bootstrap
source_host=ex44
host=lab
source_dir="$repo/hosts/$source_host"
host_dir="$repo/hosts/$host"
test ! -e "$host_dir"
current_version=$(tr -d '\r\n' < "$source_dir/start.sh.version")
mkdir -p "$host_dir/keys"
cp -p "$source_dir/bootstrap.sh" "$source_dir/start.sh" \
  "$source_dir/start.sh.version" "$source_dir/sync-start-sh.sh" "$host_dir/"
cp -p "$source_dir"/bootstrap-*.sh "$host_dir/"
cp -p "$source_dir/keys/jedarden.pub" "$source_dir/keys/jeda-mbp.pub" \
  "$host_dir/keys/"
```

Change the canonical launcher's raw-artifact URL to the new directory. Do not
hand-edit `bootstrap.sh`; the sync script propagates the canonical `REPO_URL`,
trust-anchor block, and embedded launcher together:

```bash
sed -i "s#/hosts/$source_host\"#/hosts/$host\"#" "$host_dir/start.sh"
(cd "$host_dir" && ./sync-start-sh.sh)
(cd "$host_dir" && ./sync-start-sh.sh --check)
```

Add a row for the new directory to the root `README.md` before running the
release helper. The parity gate requires every immediate `hosts/` directory
to have a real README link:

```markdown
| [hosts/lab/](./hosts/lab/) | Host-specific lab release lineage |
```

## 1. Generate and store the signing key

Perform this on the operator workstation or signing host. Use a dedicated
directory with an offline backup policy appropriate for the release key.

```bash
key_id=bootstrap-rsa-2026-09
key_dir=/secure/bootstrap-signing/$key_id
private_key=$key_dir/private.pem
public_key=$key_dir/public.pem

install -d -m 0700 "$key_dir"
(
  umask 077
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 \
    -out "$private_key"
)
chmod 600 "$private_key"
openssl pkey -in "$private_key" -pubout -out "$public_key"
chmod 644 "$public_key"
```

The commands above pass paths, never key contents. Do not run `cat` on the
private key or use a command such as `ARTIFACT_SIGNING_KEY="$(cat ... )"`.
Confirm that the private key is not below `$repo`, that its mode is `0600`,
and that `$key_dir` is mode `0700` before continuing.

## 2. Verify the public-key fingerprint

The fingerprint is the SHA-256 of the public key's DER encoding. Record it in
the release review and have it checked against the public key through a
separate trusted channel before installing the key. A downloaded public key
and its self-reported fingerprint are not independent evidence.

```bash
fingerprint=$(
  openssl pkey -pubin -in "$public_key" -outform DER |
    sha256sum | awk '{print $1}'
)
printf 'key_id=%s fingerprint=%s\n' "$key_id" "$fingerprint"

# Set this only from the separately approved fingerprint record.
expected_fingerprint='<approved-64-hex-fingerprint>'
test "$fingerprint" = "$expected_fingerprint"
```

If the comparison fails, stop. Do not install the key or sign a release.

## 3. Install and pin the public trust anchor

Install only the public key into the host lineage. The checked-in file is
reviewable and may be world-readable; the private key is never copied here.

```bash
install -m 0644 "$public_key" \
  "$repo/hosts/$host/keys/bootstrap-artifacts-signing.pub"
test "$(
  openssl pkey -pubin \
    -in "$repo/hosts/$host/keys/bootstrap-artifacts-signing.pub" \
    -outform DER | sha256sum | awk '{print $1}'
)" = "$fingerprint"
```

Edit only the canonical `hosts/$host/start.sh`. Set its
`ARTIFACT_TRUSTED_KEY_ID` to `$key_id`, replace the
`ARTIFACT_TRUSTED_PUBLIC_KEY` heredoc with the contents of `public.pem`, and
keep the initial trust arrays as one matching ID/public-key pair:

```bash
ARTIFACT_TRUSTED_KEY_ID="$key_id"
ARTIFACT_TRUSTED_PUBLIC_KEY=$(cat <<'ARTIFACT_KEY'
<contents of public.pem; public key only>
ARTIFACT_KEY
)
ARTIFACT_TRUSTED_KEY_IDS=("$ARTIFACT_TRUSTED_KEY_ID")
ARTIFACT_TRUSTED_PUBLIC_KEYS=("$ARTIFACT_TRUSTED_PUBLIC_KEY")
```

Do not hand-edit `bootstrap.sh`. Regenerate both its top-level verifier and
its embedded launcher from the canonical file:

```bash
(cd "$repo/hosts/$host" && ./sync-start-sh.sh)
(cd "$repo/hosts/$host" && ./sync-start-sh.sh --check)
```

The sync check is important: a host must receive the same initial trust anchor
when it runs `bootstrap.sh` and when its installed launcher self-updates.

Install the new host's SSH public inputs from the approved key-management
location. Keep the corresponding private keys outside the repository; the
two filenames are the complete input slots consumed by the bootstrap:

```bash
install -m 0644 /secure/ssh/$host/jedarden.pub \
  "$repo/hosts/$host/keys/jedarden.pub"
install -m 0644 /secure/ssh/$host/jeda-mbp.pub \
  "$repo/hosts/$host/keys/jeda-mbp.pub"
```

Before the first release, remove the copied manifest and signature. They were
signed by the source lineage's trust anchor and must not be reused after the
new anchor or SSH inputs change:

```bash
rm "$repo/hosts/$host/artifact-manifest.txt" \
  "$repo/hosts/$host/artifact-manifest.sig"
```

## 4. Create the first signed release

Choose a release version greater than the current version. The release helper
creates the manifest and detached signature; it never copies the private key
into the repository.

```bash
next_version=1.3.2
(
  cd "$repo"
  ARTIFACT_SIGNING_KEY="$private_key" \
    ./scripts/start-sh-release.sh --host "$host" release "$next_version"
  ./scripts/start-sh-release.sh --host "$host" --check
  ./scripts/check-secret-leakage.sh --tracked --artifacts
)
```

Review the generated bootstrap copy, immutable archive, manifest, signature,
and pinned public key. Verify the signature with the installed public key,
then run both parity views and stage only the release files plus the README
link and public inputs:

```bash
git -C "$repo" diff --check
(
  cd "$repo"
  ./scripts/check-host-parity.sh --live
)
git -C "$repo" add README.md \
  "hosts/$host/start.sh" \
  "hosts/$host/bootstrap.sh" \
  "hosts/$host/start.sh.version" \
  "hosts/$host/sync-start-sh.sh" \
  "hosts/$host/artifact-manifest.txt" \
  "hosts/$host/artifact-manifest.sig" \
  "hosts/$host/keys/jedarden.pub" \
  "hosts/$host/keys/jeda-mbp.pub" \
  "hosts/$host/keys/bootstrap-artifacts-signing.pub"
for archive in "$repo/hosts/$host"/bootstrap-*.sh; do
  git -C "$repo" add "$archive"
done
git -C "$repo" diff --cached --check
(
  cd "$repo"
  ./scripts/check-host-parity.sh --staged
)
"$repo/scripts/check-secret-leakage.sh" --tracked --artifacts
git -C "$repo" commit -m "release($host): establish artifact signing trust anchor"
```

The release helper's `ARTIFACT_SIGNING_KEY` input is a path only. The private
signing key and the SSH private keys must remain outside the checkout;
`check-secret-leakage.sh --tracked --artifacts` is the final gate proving that
no private-key material entered Git or a generated bootstrap/archive.

The private key should remain in the protected signing directory after the
first release, with an offline recovery copy if the operating policy calls
for one. Future releases use the same path-only `ARTIFACT_SIGNING_KEY`
contract. If the key is lost or suspected compromised, stop signing and use
the documented rotation or out-of-band recovery procedure; do not replace
the only trust anchor in a single release.
