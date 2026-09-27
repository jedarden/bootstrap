#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the repository's secret-file ignore rules in a disposable Git
# checkout. The force-add case models the final staged-path guard that keeps a
# plaintext secret from bypassing .gitignore.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-secrets-gitignore.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

REPOSITORY=$TMP/repository
git init -q -b main "$REPOSITORY"
cp "$ROOT/.gitignore" "$REPOSITORY/.gitignore"
git -C "$REPOSITORY" config user.name test
git -C "$REPOSITORY" config user.email test@example.invalid

mkdir -p "$REPOSITORY/secrets/bootstrap" "$REPOSITORY/secrets/ansible"
printf '%s\n' 'disposable plaintext fixture' >"$REPOSITORY/secrets/bootstrap/plain.env"
printf '%s\n' 'disposable encrypted fixture' >"$REPOSITORY/secrets/bootstrap/ex44.sops.env"
printf '%s\n' 'disposable encrypted fixture' >"$REPOSITORY/secrets/ansible/ex44.sops.yml"

# A normal add must leave the plaintext absent from both the index and status.
git -C "$REPOSITORY" add --all
staged=$(git -C "$REPOSITORY" diff --cached --name-only)
status=$(git -C "$REPOSITORY" status --porcelain --untracked-files=all)

grep -Fxq 'secrets/bootstrap/plain.env' <<<"$staged" &&
    fail 'git add staged the plaintext secret'
grep -Fq 'secrets/bootstrap/plain.env' <<<"$status" &&
    fail 'git status reported the ignored plaintext secret'
git -C "$REPOSITORY" check-ignore -q --no-index -- secrets/bootstrap/plain.env ||
    fail 'the plaintext secret is not ignored'

grep -Fxq 'secrets/bootstrap/ex44.sops.env' <<<"$staged" ||
    fail 'the bootstrap SOPS file is not trackable'
grep -Fxq 'secrets/ansible/ex44.sops.yml' <<<"$staged" ||
    fail 'the Ansible SOPS file is not trackable'

check_staged_secret_paths() {
    local path
    while IFS= read -r path; do
        case "$path" in
            secrets/*/*.sops.env|secrets/*/*.sops.yml|secrets/*/*.sops.yaml)
                ;;
            secrets/*/*)
                return 1
                ;;
        esac
    done < <(git -C "$REPOSITORY" diff --cached --name-only --diff-filter=ACM -- secrets/)
}

# .gitignore is not a protection against an explicit force-add. The staged
# path check must still reject the plaintext file after that bypass.
git -C "$REPOSITORY" add -f -- secrets/bootstrap/plain.env
if check_staged_secret_paths; then
    fail 'the staged-secret check accepted a force-added plaintext secret'
fi

echo 'Secret gitignore and force-add checks passed.'
