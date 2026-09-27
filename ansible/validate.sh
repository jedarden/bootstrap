#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "$ROOT"

# Some development images provide Ansible through a Python environment whose
# console-script shebang points at a path not present in the image. Prefer the
# normal command, then use the Python module entry point as a portable fallback.
if command -v ansible-playbook >/dev/null 2>&1 && ansible-playbook --version >/dev/null 2>&1; then
    ANSIBLE_PLAYBOOK=(ansible-playbook)
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import ansible' >/dev/null 2>&1; then
    ANSIBLE_PLAYBOOK=(python3 -m ansible.cli.playbook)
else
    echo "Ansible is required for playbook validation." >&2
    exit 1
fi

# The example intentionally ends in `.yml.example` so it cannot be mistaken
# for a real inventory. Give the YAML inventory plugin a `.yml` path while
# validating, otherwise Ansible 2.20 may try the INI plugin first.
inventory=$(mktemp --suffix=.yml)
trap 'rm -f "$inventory"' EXIT
cp inventory/hosts.yml.example "$inventory"

for playbook in playbooks/*.yml; do
    "${ANSIBLE_PLAYBOOK[@]}" \
        --syntax-check \
        --inventory "$inventory" \
        "$playbook"
done
