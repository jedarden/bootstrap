#!/usr/bin/env bash
set -euo pipefail

# Run one of the drift playbooks with a SOPS FIFO as Ansible's extra-vars
# source. The decrypted YAML must never become a regular file on the
# controller or a file on the managed host.

ANSIBLE_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$ANSIBLE_ROOT/.." && pwd)

die() {
    echo "Ansible SOPS workflow failed: $*" >&2
    exit 1
}

usage() {
    cat >&2 <<'USAGE'
usage:
  ansible/run-drift.sh check [ansible-playbook options...]
  ansible/run-drift.sh apply [ansible-playbook options...]

The workflow requires exactly one secrets/ansible/*.sops.yml file. Set
SOPS_ANSIBLE_VARS to an explicit encrypted YAML path when more than one host
file is present.
USAGE
    exit 2
}

resolve_executable() {
    local requested=$1

    if [[ "$requested" == */* ]]; then
        [[ -x "$requested" ]] || die "executable is not available: $requested"
        printf '%s\n' "$requested"
    else
        command -v "$requested" || die "executable is not on PATH: $requested"
    fi
}

[[ $# -gt 0 ]] || usage

case "$1" in
    check)
        playbook=playbooks/check-drift.yml
        ;;
    apply)
        playbook=playbooks/drift.yml
        ;;
    *)
        usage
        ;;
esac
shift
[[ ${1:-} == -- ]] && shift

SOPS_BIN=$(resolve_executable "${SOPS_BIN:-sops}")

if [[ -n "${SOPS_ANSIBLE_VARS:-}" ]]; then
    vars_file=$SOPS_ANSIBLE_VARS
    [[ "$vars_file" == /* ]] || vars_file="$PWD/$vars_file"
    [[ -f "$vars_file" ]] || die "SOPS_ANSIBLE_VARS does not name a file"
else
    shopt -s nullglob
    encrypted_files=("$REPO_ROOT"/secrets/ansible/*.sops.yml)
    shopt -u nullglob

    if [[ ${#encrypted_files[@]} -ne 1 ]]; then
        die "expected exactly one secrets/ansible/*.sops.yml file; set SOPS_ANSIBLE_VARS explicitly"
    fi
    vars_file=${encrypted_files[0]}
fi

[[ "$vars_file" == *.sops.yml ]] ||
    die "Ansible variables must use the .sops.yml suffix"

if [[ -n "${ANSIBLE_PLAYBOOK_BIN:-}" ]]; then
    ansible_playbook=("$(resolve_executable "$ANSIBLE_PLAYBOOK_BIN")")
elif command -v ansible-playbook >/dev/null 2>&1 &&
    ansible-playbook --version >/dev/null 2>&1; then
    ansible_playbook=("$(command -v ansible-playbook)")
elif command -v python3 >/dev/null 2>&1 &&
    python3 -c 'import ansible' >/dev/null 2>&1; then
    ansible_playbook=(python3 -m ansible.cli.playbook)
else
    die "Ansible is required; set ANSIBLE_PLAYBOOK_BIN or install ansible-playbook"
fi

export ANSIBLE_CONFIG=${ANSIBLE_CONFIG:-$ANSIBLE_ROOT/ansible.cfg}
cd "$ANSIBLE_ROOT"

# sops exec-file accepts one shell command. Quote every argument so an
# operator's normal --limit/--tags options cannot alter the command, while
# retaining the literal {} placeholder that sops replaces with its FIFO.
command=("${ansible_playbook[@]}" "$playbook" "$@" -e)
printf -v command_string '%q ' "${command[@]}"
command_string+='@{}'

# Do not use --no-fifo: sops owns the temporary FIFO lifecycle and removes it
# after Ansible exits, including when Ansible reports a failed play.
exec "$SOPS_BIN" exec-file "$vars_file" "$command_string"
