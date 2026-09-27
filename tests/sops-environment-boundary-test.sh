#!/usr/bin/env bash
set -Eeuo pipefail

# Verify the operator-side SOPS command boundary without installing SOPS or
# age on a target host. This deliberately supplies an ephemeral age identity
# to sops, then proves the command that stands in for bootstrap receives only
# the decrypted application field after the documented env -u scrub.

SOPS_BIN=${SOPS_BIN:-sops}
AGE_KEYGEN_BIN=${AGE_KEYGEN_BIN:-age-keygen}

die() {
    echo "SOPS environment boundary test failed: $*" >&2
    exit 1
}

resolve_tool() {
    local requested=$1
    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "tool is not executable"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "required tool is unavailable"
    fi
}

SOPS_BIN=$(resolve_tool "$SOPS_BIN")
AGE_KEYGEN_BIN=$(resolve_tool "$AGE_KEYGEN_BIN")
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-sops-env-boundary.XXXXXX")

cleanup() {
    if [[ -n "${WORK:-}" && -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-sops-env-boundary."* ]]; then
        find "$WORK" -depth -delete
    fi
}
trap cleanup EXIT

mkdir -m 700 "$WORK/home" "$WORK/config"
identity="$WORK/identity.txt"
recipient="$WORK/recipient.txt"
plain="$WORK/plain.env"
ciphertext="$WORK/input.sops.env"
capture="$WORK/child-environment"

"$AGE_KEYGEN_BIN" -o "$identity" >"$WORK/keygen.out" 2>"$WORK/keygen.err" ||
    die "could not create the ephemeral identity"
chmod 0600 "$identity"
"$AGE_KEYGEN_BIN" -y "$identity" >"$recipient" 2>"$WORK/recipient.err" ||
    die "could not derive the recipient"
printf '%s\n' \
    'BOOTSTRAP_B2_APPLICATION_KEY=test-fixture' \
    'BOOTSTRAP_RESTIC_PASSWORD=test-fixture' >"$plain"

env -u SOPS_AGE_KEY -u SOPS_AGE_RECIPIENTS -u SOPS_CONFIG \
    SOPS_AGE_KEY_FILE="$identity" HOME="$WORK/home" \
    XDG_CONFIG_HOME="$WORK/config" "$SOPS_BIN" encrypt \
    --age "$(<"$recipient")" --input-type dotenv --output-type dotenv \
    "$plain" >"$ciphertext" 2>"$WORK/encrypt.err" ||
    die "could not create the encrypted fixture"

private_env_launcher="$WORK/private-env-launcher"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'export SOPS_AGE_KEY="$(<"$1")"' \
    'shift' \
    'exec "$@"' >"$private_env_launcher"
chmod 0755 "$private_env_launcher"

child="$WORK/capture-child"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -euo pipefail' \
    'env >"${SOPS_BOUNDARY_CAPTURE:?}"' >"$child"
chmod 0755 "$child"

SOPS_BOUNDARY_CAPTURE="$capture" \
    "$private_env_launcher" "$identity" \
    "$SOPS_BIN" exec-env "$ciphertext" \
    "exec env -u SOPS_AGE_KEY -u SOPS_AGE_KEY_FILE -u SOPS_AGE_RECIPIENTS $child" \
    >"$WORK/exec-env.out" 2>"$WORK/exec-env.err" ||
    die "the sanitized exec-env command failed"

grep -q '^BOOTSTRAP_B2_APPLICATION_KEY=test-fixture$' "$capture" ||
    die "the decrypted application field did not reach the child"
if grep -Eq '^SOPS_AGE_(KEY|KEY_FILE|RECIPIENTS)=' "$capture"; then
    die "an operator SOPS age variable reached the bootstrap child"
fi

private_key_marker='AGE-SECRET-''KEY-'
for artifact in "$ciphertext" "$capture" "$WORK"/*.out "$WORK"/*.err; do
    [[ -f "$artifact" ]] || continue
    ! grep -q "$private_key_marker" "$artifact" ||
        die "private age identity material appeared in an emitted artifact"
done

cleanup
[[ ! -e "$WORK" ]] || die "temporary SOPS boundary directory survived cleanup"
trap - EXIT
printf '%s\n' 'SOPS environment boundary test passed'
