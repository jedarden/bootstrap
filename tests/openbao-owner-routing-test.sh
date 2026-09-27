#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the OpenBao owner-routing contract without contacting a live
# instance. Each fake instance records only the operation, path, and CAS
# version; the payload is supplied by file reference and is never printed or
# read back. A real writer must preserve these same boundaries.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-openbao-owner-routing.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

STATE="$TMP/state"
FAKE_BIN="$TMP/bin"
FAKE_BAO="$FAKE_BIN/bao"
FAKE_KUBECTL="$FAKE_BIN/kubectl"
LOG="$STATE/operations.log"
PAYLOAD="$TMP/payload.json"
mkdir -m 700 "$STATE" "$FAKE_BIN"
: >"$LOG"
printf '%s\n' '{"fixture":"owner-routing"}' >"$PAYLOAD"

fail() {
    echo "OpenBao owner-routing test failed: $*" >&2
    exit 1
}

path_key() {
    printf '%s' "$1" | tr '/:' '__'
}

version_file() {
    printf '%s/%s.version' "$STATE" "$(path_key "$1/$2")"
}

# The fake CLI deliberately has no read-data operation. Metadata is the only
# post-write OpenBao observation allowed by this contract.
cat >"$FAKE_BAO" <<'FAKE_BAO'
#!/usr/bin/env bash
set -Eeuo pipefail

state=$FAKE_OPENBAO_STATE
log=$FAKE_OPENBAO_LOG
instance=$1
shift

path_key() {
    printf '%s' "$1" | tr '/:' '__'
}

version_file() {
    printf '%s/%s.version' "$state" "$(path_key "$1/$2")"
}

read_version() {
    local file value
    file=$(version_file "$1" "$2")
    if [[ -f "$file" ]]; then
        value=$(<"$file")
        printf '%s\n' "$value"
    else
        printf '0\n'
    fi
}

case "${1:-}/${2:-}/${3:-}" in
    kv/metadata/get)
        path="${@: -1}"
        [[ "$path" == secret/* ]] || exit 2
        printf '%s metadata %s\n' "$instance" "$path" >>"$log"
        printf '{"data":{"current_version":%s}}\n' "$(read_version "$instance" "$path")"
        ;;
    kv/put*)
        cas=''
        path=''
        payload=''
        while (($# > 0)); do
            case "$1" in
                -cas=*) cas=${1#-cas=} ;;
                @*) payload=$1 ;;
                secret/*) path=$1 ;;
                *) ;;
            esac
            shift
        done
        [[ -n "$cas" && -n "$path" && "$payload" == @* ]] || exit 3
        [[ -f "${payload#@}" ]] || exit 4
        current=$(read_version "$instance" "$path")
        [[ "$cas" == "$current" ]] || exit 5
        next=$((current + 1))
        printf '%s put %s cas=%s\n' "$instance" "$path" "$cas" >>"$log"
        printf '%s\n' "$next" >"$(version_file "$instance" "$path")"
        printf '{"data":{"version":%s}}\n' "$next"
        ;;
    kv/get|kv/delete|kv/metadata/delete)
        printf '%s forbidden-read-or-delete %s\n' "$instance" "${4:-}" >>"$log"
        exit 90
        ;;
    *)
        exit 91
        ;;
esac
FAKE_BAO
chmod 0755 "$FAKE_BAO"

cat >"$FAKE_KUBECTL" <<'FAKE_KUBECTL'
#!/usr/bin/env bash
set -Eeuo pipefail

log=$FAKE_OPENBAO_LOG
if [[ "${1:-}" == get && "${2:-}" == externalsecret ]]; then
    printf 'externalsecret status\n' >>"$log"
    printf '%s\n' '{"status":{"conditions":[{"type":"Ready","status":"True","reason":"SecretSynced"}]}}'
    exit 0
fi

printf 'kubectl forbidden-or-unexpected %s\n' "${1:-}" >>"$log"
exit 92
FAKE_KUBECTL
chmod 0755 "$FAKE_KUBECTL"

export FAKE_OPENBAO_STATE=$STATE
export FAKE_OPENBAO_LOG=$LOG

owner_for_path() {
    case "$1" in
        secret/ardenone-cluster/*) printf '%s\n' 'openbao-v2' ;;
        secret/rs-manager/*) printf '%s\n' 'rs-manager' ;;
        secret/ardenone-manager/*) printf '%s\n' 'ardenone-manager' ;;
        *) return 1 ;;
    esac
}

metadata_version() {
    local instance=$1 path=$2
    "$FAKE_BAO" "$instance" kv metadata get -format=json "$path" |
        sed -n 's/.*"current_version":\([0-9][0-9]*\).*/\1/p'
}

# This is the boundary a provisioning writer must enforce before it calls
# bao. The explicit instance argument makes an accidental replica target
# observable and rejectable even if a replica endpoint would return HTTP 200.
write_owner_path() {
    local instance=$1 path=$2 payload=$3 expected current next
    expected=$(owner_for_path "$path") || {
        echo "unknown OpenBao owner for $path" >&2
        return 2
    }
    [[ "$instance" == "$expected" ]] || {
        echo "refusing non-owner OpenBao instance $instance for $path" >&2
        return 3
    }
    current=$(metadata_version "$instance" "$path")
    [[ -n "$current" ]] || return 4
    "$FAKE_BAO" "$instance" kv put "-cas=$current" "$path" "@$payload" >/dev/null
    next=$(metadata_version "$instance" "$path")
    [[ "$next" == "$((current + 1))" ]] || return 5
}

assert_replica_rejected() {
    local owner=$1 path=$2 replica before after
    for replica in openbao-v2 rs-manager ardenone-manager; do
        [[ "$replica" == "$owner" ]] && continue
        before=$(wc -l <"$LOG")
        if write_owner_path "$replica" "$path" "$PAYLOAD" 2>/dev/null; then
            fail "replica $replica accepted a write for $path"
        fi
        after=$(wc -l <"$LOG")
        [[ "$after" == "$before" ]] ||
            fail "replica rejection still contacted $replica for $path"
    done
}

declare -a cases=(
    'openbao-v2|secret/ardenone-cluster/bootstrap/owner-routing'
    'rs-manager|secret/rs-manager/bootstrap/owner-routing'
    'ardenone-manager|secret/ardenone-manager/bootstrap/owner-routing'
)

for case in "${cases[@]}"; do
    IFS='|' read -r owner path <<<"$case"
    [[ "$(owner_for_path "$path")" == "$owner" ]] ||
        fail "owner map disagrees for $path"
    write_owner_path "$owner" "$path" "$PAYLOAD" ||
        fail "owner write failed for $path"
    assert_replica_rejected "$owner" "$path"
done

if write_owner_path openbao-v2 secret/not-owned/by-any-instance "$PAYLOAD" 2>/dev/null; then
    fail 'unknown path prefix was accepted'
fi

# A downstream sync is proven from status only. There is intentionally no
# kubectl get secret invocation in this test.
"$FAKE_KUBECTL" get externalsecret owner-routing -o json |
    grep -Fq '"reason":"SecretSynced"' ||
    fail 'SecretSynced status was not observed'

if grep -Eq '(^| )(get|delete|metadata-delete) ' "$LOG"; then
    fail 'data read or delete operation was attempted'
fi
if grep -Fq 'fixture' "$LOG"; then
    fail 'secret payload appeared in the operation log'
fi
if grep -Fq 'forbidden-read-or-delete' "$LOG"; then
    fail 'forbidden data operation was attempted'
fi

for owner in openbao-v2 rs-manager ardenone-manager; do
    count=$(grep -c "^$owner put " "$LOG" || true)
    [[ "$count" == 1 ]] || fail "expected exactly one owner write for $owner, got $count"
done

echo 'OpenBao owner-routing tests passed.'
