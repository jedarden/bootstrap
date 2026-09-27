#!/usr/bin/env bash
set -Eeuo pipefail

# Exercise the real drift playbooks against a disposable Debian container.
# The container is deliberately kept small and uses deterministic doubles for
# service-manager commands; Ansible still performs the real file, user, group,
# package, and mount reconciliation inside the isolated target.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${BOOTSTRAP_DRIFT_TEST_IMAGE:-debian:12-slim}
CONTAINER="bootstrap-drift-${PPID}-${RANDOM}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-drift-acceptance.XXXXXX")
CONTAINER_STARTED=false
KEEP_WORK=${BOOTSTRAP_DRIFT_TEST_KEEP_WORK:-false}

cleanup() {
    local exit_code=$?
    if [[ "$CONTAINER_STARTED" == true ]]; then
        if [[ "$KEEP_WORK" == true ]]; then
            echo "Keeping acceptance-test container: $CONTAINER" >&2
        else
            docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        fi
    fi
    if [[ "$KEEP_WORK" == true ]]; then
        echo "Keeping acceptance-test artifacts: $WORK" >&2
    elif [[ -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-drift-acceptance."* ]]; then
        rm -rf "$WORK"
    fi
    return "$exit_code"
}
trap cleanup EXIT

die() {
    echo "Ansible drift acceptance test failed: $*" >&2
    exit 1
}

docker_is_available() {
    command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

if ! docker_is_available; then
    if [[ ${BOOTSTRAP_DRIFT_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        die 'a reachable Docker daemon is required'
    fi
    echo 'SKIP: Ansible drift acceptance tests require a reachable Docker daemon' >&2
    exit 0
fi

python3 -c 'import ansible' >/dev/null 2>&1 ||
    die 'Ansible is required; install ansible-core before running this test'

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable test image $IMAGE..."
    docker pull "$IMAGE" >/dev/null
fi

echo "Starting disposable Ansible target $CONTAINER..."
docker run --detach \
    --name "$CONTAINER" \
    --privileged \
    --cap-add=ALL \
    --security-opt seccomp=unconfined \
    "$IMAGE" sleep infinity >/dev/null
CONTAINER_STARTED=true

# The role's service tasks are intentionally exercised, but a minimal image
# has no init system. These doubles retain enabled/running state so the service
# module has observable, idempotent behavior without touching the host.
docker exec -i "$CONTAINER" bash -s <<'FIXTURE'
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends python3 python3-apt sudo >/dev/null

mkdir -p /var/lib/bootstrap-drift-test/services /usr/local/sbin
mkdir -p \
    /etc/needrestart/conf.d \
    /etc/ssh/sshd_config.d \
    /etc/fail2ban \
    /etc/audit/rules.d \
    /etc/apt/apt.conf.d \
    /etc/sysctl.d \
    /etc/modprobe.d \
    /etc/logrotate.d \
    /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.monthly \
    /etc/cron.weekly \
    /run/shm
touch /etc/ssh/sshd_config
cat >/usr/local/sbin/service <<'SERVICE'
#!/bin/sh
set -eu
state=/var/lib/bootstrap-drift-test/services
mkdir -p "$state"
unit=${1:?missing service name}
action=${2:-status}
case "$action" in
    start|restart|reload)
        touch "$state/$unit.active"
        ;;
    stop)
        rm -f "$state/$unit.active"
        ;;
    status)
        test -e "$state/$unit.active"
        ;;
    *)
        ;;
esac
SERVICE
chmod 0755 /usr/local/sbin/service

cat >/usr/local/sbin/update-rc.d <<'UPDATE'
#!/bin/sh
set -eu
state=/var/lib/bootstrap-drift-test/services
unit=${1:?missing service name}
mkdir -p "$state"
touch "$state/$unit.enabled"
UPDATE
chmod 0755 /usr/local/sbin/update-rc.d

for unit in fail2ban auditd; do
    cat >"/etc/init.d/$unit" <<INIT
#!/bin/sh
### BEGIN INIT INFO
# Provides:          $unit
# Required-Start:    \$remote_fs
# Required-Stop:     \$remote_fs
# Default-Start:     2 3 4 5
# Default-Stop:      0 1 6
### END INIT INFO
exit 0
INIT
    chmod 0755 "/etc/init.d/$unit"
done

cat >/usr/local/sbin/sshd <<'SSHD'
#!/bin/sh
set -eu
test "${1:-}" = -t || exit 2
SSHD
chmod 0755 /usr/local/sbin/sshd

cat >/usr/local/sbin/sysctl <<'SYSCTL'
#!/bin/sh
set -eu
test "${1:-}" = --system || exit 2
SYSCTL
chmod 0755 /usr/local/sbin/sysctl

cat >/usr/local/sbin/augenrules <<'AUDIT'
#!/bin/sh
set -eu
test "${1:-}" = --load || exit 2
AUDIT
chmod 0755 /usr/local/sbin/augenrules

printf '%s\n' 'root ALL=(ALL) NOPASSWD:ALL' >/etc/sudoers.d/bootstrap-drift-test
chmod 0440 /etc/sudoers.d/bootstrap-drift-test
FIXTURE

cat >"$WORK/inventory.yml" <<EOF
all:
  children:
    ex44:
      hosts:
        fixture:
          ansible_connection: community.docker.docker
          ansible_host: $CONTAINER
          ansible_user: root
          ansible_python_interpreter: /usr/bin/python3
          ansible_docker_privileged: true
EOF

cat >"$WORK/vars.yml" <<'VARS'
bootstrap_users:
  - drift-user
bootstrap_user_shell: /bin/bash
bootstrap_user_groups:
  - drift-admin
bootstrap_user_directories:
  - .cache
  - workspace
bootstrap_manage_authorized_keys: false
bootstrap_manage_user_dotfiles: true
bootstrap_packages:
  - python3
  - sudo
bootstrap_optional_packages: []
bootstrap_package_state: present
bootstrap_apt_update_cache: false
bootstrap_manage_firewall: false
bootstrap_manage_system_docker: false
bootstrap_manage_rootless_docker: false
bootstrap_backup_enabled: false
VARS

cat >"$WORK/missing-backup-vars.yml" <<'VARS'
bootstrap_backup_enabled: true
VARS

cat >"$WORK/conflicting-docker-vars.yml" <<'VARS'
bootstrap_manage_system_docker: true
bootstrap_manage_rootless_docker: true
VARS

run_ansible() {
    local label=$1
    local playbook=$2
    local vars=$3
    shift 3
    local output="$WORK/$label.log"
    local status

    set +e
    (
        cd "$ROOT/ansible"
        ANSIBLE_CONFIG="$ROOT/ansible/ansible.cfg" \
            python3 -m ansible.cli.playbook \
            --inventory "$WORK/inventory.yml" \
            --extra-vars "@$WORK/vars.yml" \
            --extra-vars "@$vars" \
            --forks 1 \
            "$playbook" "$@"
    ) >"$output" 2>&1
    status=$?
    set -e
    if [[ $status != 0 ]]; then
        echo "--- $label output ---" >&2
        tail -n 80 "$output" >&2
    fi
    return "$status"
}

assert_changed() {
    local label=$1
    local output="$WORK/$label.log"
    grep -Eq 'fixture[[:space:]]*:.*changed=[1-9][0-9]*([[:space:]]|$)' "$output" ||
        die "$label did not report a change"
}

assert_clean() {
    local label=$1
    local output="$WORK/$label.log"
    grep -Eq 'fixture[[:space:]]*:.*changed=0([[:space:]]|$)' "$output" ||
        die "$label was not idempotent"
}

assert_target_file() {
    local path=$1
    docker exec "$CONTAINER" test -e "$path" || die "target file is missing: $path"
}

assert_target_contains() {
    local path=$1
    local text=$2
    docker exec "$CONTAINER" grep -Fq -- "$text" "$path" ||
        die "target file $path does not contain the expected managed content"
}

echo 'Converging the isolated target for the first time...'
run_ansible initial-convergence playbooks/drift.yml "$WORK/vars.yml"
assert_changed initial-convergence
assert_target_file /home/drift-user/.bashrc
assert_target_file /home/drift-user/.tmux.conf
assert_target_contains /etc/ssh/sshd_config.d/hardening.conf 'PasswordAuthentication no'
assert_target_contains /etc/sysctl.d/99-hardening.conf 'kernel.randomize_va_space = 2'

echo 'Reapplying the playbook to verify idempotence...'
run_ansible idempotent-reapply playbooks/drift.yml "$WORK/vars.yml"
assert_clean idempotent-reapply

echo 'Introducing representative file drift and previewing it in check mode...'
docker exec "$CONTAINER" sh -c \
    "printf '%s\\n' '# drift injected by acceptance test' > /etc/ssh/sshd_config.d/hardening.conf"
docker exec "$CONTAINER" rm -f /home/drift-user/.tmux.conf
run_ansible check-mode-drift playbooks/check-drift.yml "$WORK/vars.yml"
assert_changed check-mode-drift
assert_target_contains /etc/ssh/sshd_config.d/hardening.conf 'drift injected by acceptance test'
docker exec "$CONTAINER" test ! -e /home/drift-user/.tmux.conf ||
    die 'check mode changed the isolated target'

echo 'Applying the correction and checking the repaired target...'
run_ansible drift-correction playbooks/drift.yml "$WORK/vars.yml"
assert_changed drift-correction
assert_target_file /home/drift-user/.tmux.conf
assert_target_contains /etc/ssh/sshd_config.d/hardening.conf 'PasswordAuthentication no'

echo 'Verifying check mode is clean after convergence...'
run_ansible check-mode-clean playbooks/check-drift.yml "$WORK/vars.yml"
assert_clean check-mode-clean

echo 'Checking missing backup variables fail before a secret file is written...'
if run_ansible missing-backup-vars playbooks/drift.yml "$WORK/missing-backup-vars.yml" --tags backup; then
    die 'missing bootstrap_restic_env was accepted while backups were enabled'
fi
docker exec "$CONTAINER" test ! -e /etc/restic/b2.env ||
    die 'invalid backup variables created the restic environment file'

echo 'Checking conflicting Docker policy variables fail safely...'
if run_ansible conflicting-docker-vars playbooks/drift.yml "$WORK/conflicting-docker-vars.yml" --tags packages; then
    die 'conflicting Docker policy variables were accepted'
fi

echo 'Ansible drift acceptance test passed'
