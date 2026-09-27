#!/usr/bin/env bash
set -euo pipefail

# Prepare a disposable Debian container for bootstrap integration tests. The
# bootstrap is intentionally run unchanged except for its /dev/tty input
# redirect (the test runner supplies stdin instead). Commands whose real
# implementations would mutate the container host kernel, require a systemd
# PID 1, or contact a real account are small deterministic doubles.

BOOTSTRAP_SOURCE=${1:?usage: host-fixture.sh /path/to/bootstrap.sh}
ROOT=/var/lib/bootstrap-test
KEYS="$ROOT/keys"
SHIM_DIR=/usr/local/lib/bootstrap-test

mkdir -p "$ROOT" "$KEYS" "$SHIM_DIR" /test /var/lib/tailscale
cp "$(dirname "$BOOTSTRAP_SOURCE")/keys/jedarden.pub" "$KEYS/jedarden.pub"
cp "$(dirname "$BOOTSTRAP_SOURCE")/keys/jeda-mbp.pub" "$KEYS/jeda-mbp.pub"

# The production script requires these system groups and directories before
# it reaches the package/service setup steps. The package manager is a no-op
# in this fixture because the test doubles below provide the package entry
# points that are observed by the bootstrap.
groupadd --system sudo 2>/dev/null || true
mkdir -p \
    /etc/apt/apt.conf.d \
    /etc/ssh/sshd_config.d \
    /etc/fail2ban \
    /etc/audit/rules.d \
    /etc/sysctl.d \
    /etc/ufw \
    /etc/modprobe.d \
    /etc/logrotate.d \
    /etc/cron.d \
    /etc/cron.daily \
    /etc/cron.hourly \
    /etc/cron.monthly \
    /etc/cron.weekly
touch /etc/ssh/sshd_config
# Docker manages /etc/hosts as a special mount that cannot be atomically
# replaced with sed -i. Preseed the exact documented hostname mapping so the
# production script exercises its already-configured branch.
grep -Fq '127.0.1.1	bootstrap-test' /etc/hosts ||
    printf '127.0.1.1\tbootstrap-test\n' >> /etc/hosts

cat > "$SHIM_DIR/command-shim" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail

name=$(basename "$0")
state=/var/lib/bootstrap-test
log="$state/commands.log"
mkdir -p "$state"
printf '%s %q\n' "$name" "$*" >> "$log"

case "$name" in
    apt-get)
        # Package presence is represented by the command doubles installed by
        # this fixture. Keeping apt a no-op makes the test quick and offline.
        exit 0
        ;;
    curl)
        url="${!#}"
        case "$url" in
            https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/keys/*)
                key_name=${url##*/}
                [[ -f "$state/keys/$key_name" ]] || exit 22
                cat "$state/keys/$key_name"
                ;;
            https://tailscale.com/install.sh)
                if [[ ${BOOTSTRAP_TEST_TAILSCALE_INSTALL_FAIL:-false} == true ]]; then
                    echo 'fixture: Tailscale installer unavailable' >&2
                    exit 1
                fi
                cat <<'TAILSCALE_INSTALL'
mkdir -p /usr/local/bin
cat > /usr/local/bin/tailscale <<'TAILSCALE'
#!/usr/bin/env bash
set -euo pipefail
state=/var/lib/bootstrap-test/tailscale-connected
case "${1:-}" in
    status)
        if [[ -f "$state" ]]; then
            if [[ "${2:-}" == "--json" ]]; then
                echo '{"Self":{"DNSName":"bootstrap-test.tailnet.ts.net."}}'
            else
                echo '100.64.0.10  bootstrap-test  linux   active; direct'
            fi
            exit 0
        fi
        echo 'Logged out.' >&2
        exit 1
        ;;
    down)
        rm -f "$state"
        exit 0
        ;;
    up)
        printf '%s\n' "$*" >> /var/lib/bootstrap-test/tailscale-up-args.log
        if [[ ${BOOTSTRAP_TEST_TAILSCALE_UP_FAIL:-false} == true ]]; then
            echo 'fixture: enrollment rejected' >&2
            exit 1
        fi
        touch "$state"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
TAILSCALE
chmod +x /usr/local/bin/tailscale
TAILSCALE_INSTALL
                ;;
            https://claude.ai/install.sh)
                cat <<'CLAUDE_INSTALL'
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo 'claude 1.0.0'
CLAUDE
chmod +x "$HOME/.local/bin/claude"
CLAUDE_INSTALL
                ;;
            *)
                echo "unexpected curl URL in bootstrap fixture: $url" >&2
                exit 22
                ;;
        esac
        ;;
    timedatectl)
        case "${1:-}" in
            show)
                if [[ " $* " == *'--property=Timezone'* ]]; then
                    echo 'America/New_York'
                elif [[ " $* " == *'--property=NTP'* ]]; then
                    echo 'yes'
                fi
                ;;
            set-timezone|set-ntp)
                ;;
        esac
        ;;
    hostnamectl|reboot)
        exit 0
        ;;
    loginctl)
        if [[ "${1:-}" == enable-linger ]]; then
            user=${2:?missing linger user}
            mkdir -p /var/lib/systemd/linger
            touch "/var/lib/systemd/linger/$user"
        fi
        exit 0
        ;;
    systemctl)
        case "${1:-}" in
            disable)
                for unit in "${@:3}"; do
                    case "$unit" in
                        docker.service|docker.socket)
                            touch "$state/system-docker-disabled"
                            rm -f /run/docker.sock
                            ;;
                    esac
                done
                exit 0
                ;;
            is-enabled)
                unit="${2:-}"
                if [[ "$unit" == docker.service && -f "$state/system-docker-disabled" ]]; then
                    echo disabled
                    exit 0
                fi
                echo enabled
                exit 0
                ;;
            is-active)
                unit="${2:-}"
                if [[ "$unit" == docker.service && -f "$state/system-docker-disabled" ]]; then
                    echo inactive
                    exit 0
                fi
                echo active
                exit 0
                ;;
            enable)
                unit="${3:-${2:-}}"
                if [[ "$unit" == tailscaled ]]; then
                    if [[ ${BOOTSTRAP_TEST_TAILSCALE_SERVICE_FAIL:-false} == true ]]; then
                        echo 'fixture: tailscaled failed to start' >&2
                        exit 1
                    fi
                    touch "$state/tailscaled-enabled" "$state/tailscaled-active"
                fi
                exit 0
                ;;
            is-active)
                unit="${3:-${2:-}}"
                if [[ "$unit" == tailscaled && -f "$state/tailscaled-active" ]]; then
                    exit 0
                fi
                if [[ "$unit" == tailscale && -f "$state/tailscale-connected" ]]; then
                    exit 0
                fi
                exit 1
                ;;
            is-enabled)
                unit="${3:-${2:-}}"
                [[ "$unit" == tailscaled && -f "$state/tailscaled-enabled" ]]
                ;;
            stop)
                unit="${2:-}"
                [[ "$unit" != tailscaled ]] || rm -f "$state/tailscaled-active"
                exit 0
                ;;
            start)
                unit="${2:-}"
                [[ "$unit" != tailscaled ]] || touch "$state/tailscaled-active"
                exit 0
                ;;
            list-unit-files)
                # Make the optional systemd-resolved branch a no-op. DNS is
                # provided by the container runtime in this test.
                exit 1
                ;;
            *)
                exit 0
                ;;
        esac
        ;;
    resolvectl)
        echo 'DNS Servers: 1.1.1.1'
        ;;
    getent)
        if [[ "${1:-}" == hosts ]]; then
            echo "192.0.2.10 ${2:-bootstrap-test}"
            exit 0
        fi
        exec /usr/bin/getent "$@"
        ;;
    locale)
        echo 'C'
        echo 'en_US.utf8'
        ;;
    ping)
        exit 0
        ;;
    sysctl)
        case "${1:-}" in
            --system)
                echo '* Applying /etc/sysctl.d/99-hardening.conf'
                ;;
            -n)
                awk -v key="${2:-}" '$1 == key { print $3; found = 1 } END { exit !found }' \
                    /etc/sysctl.d/99-hardening.conf
                ;;
        esac
        ;;
    ufw)
        rules="$state/ufw.rules"
        mkdir -p "$state"
        case "${1:-}" in
            --force)
                if [[ "${2:-}" == reset ]]; then
                    : > "$rules"
                fi
                ;;
            default)
                echo "Default: ${2:-} ${3:-}" >> "$rules"
                ;;
            allow)
                echo "ALLOW IN on ${3:-any} $*" >> "$rules"
                ;;
            status)
                echo 'Status: active'
                cat "$rules"
                ;;
        esac
        ;;
    sshd)
        if [[ "${1:-}" == -t ]]; then
            exit 0
        fi
        if [[ "${1:-}" == -T ]]; then
            cat <<'SSHD'
permitrootlogin prohibit-password
passwordauthentication no
pubkeyauthentication yes
authenticationmethods publickey
maxauthtries 3
maxsessions 10
logingracetime 20
clientaliveinterval 300
clientalivecountmax 2
allowusers root coding trading
x11forwarding no
allowtcpforwarding yes
allowagentforwarding no
permittunnel no
gatewayports no
permituserenvironment no
protocol 2
ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
macs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
kexalgorithms curve25519-sha256,curve25519-sha256@libssh.org
SSHD
        fi
        ;;
    fail2ban-client)
        if [[ "${1:-}" == status ]]; then
            echo 'Status for the jail: sshd'
            echo '| Currently failed: 0'
        fi
        ;;
    auditctl)
        if [[ "${1:-}" == -l ]]; then
            grep -E '^-w |^-[Dbf]($| )' /etc/audit/rules.d/hardening.rules
        fi
        ;;
    jq)
        echo 'bootstrap-test.tailnet.ts.net'
        ;;
    docker)
        [[ $EUID -ne 0 ]] || {
            echo 'rootless Docker must not be queried as root' >&2
            exit 1
        }
        expected_docker_host="unix:///run/user/$(id -u)/docker.sock"
        [[ "${DOCKER_HOST:-}" == "$expected_docker_host" ]] || {
            echo "rootless Docker fixture requires DOCKER_HOST=$expected_docker_host" >&2
            exit 1
        }
        case "${1:-}" in
            info)
                echo 'Rootless Docker fixture'
                ;;
            run) echo 'Hello from Docker';;
        esac
        ;;
    dockerd-rootless-setuptool.sh)
        [[ $EUID -ne 0 ]] || {
            echo 'rootless Docker setup must not run as root' >&2
            exit 1
        }
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/docker.service" <<'DOCKER_SERVICE'
[Unit]
Description=Rootless Docker fixture

[Service]
ExecStart=/usr/bin/dockerd-rootless.sh

[Install]
WantedBy=default.target
DOCKER_SERVICE
        ;;
    restic)
        repository="$state/restic-repository-created"
        snapshot="$state/restic-snapshot"
        case "${1:-}" in
            snapshots)
                if [[ -f "$repository" ]]; then
                    echo 'abcdef0123456789'
                    exit 0
                fi
                exit 1
                ;;
            init)
                touch "$repository"
                ;;
            backup)
                # Keep a small local representation of the two production
                # backup roots. This is enough to exercise a real restore
                # round-trip without contacting B2 or exposing credentials.
                rm -rf "$snapshot"
                mkdir -p "$snapshot"
                cp -a /home "$snapshot/home"
                cp -a /var/lib/tailscale "$snapshot/tailscale"
                touch "$repository"
                echo 'backup complete'
                ;;
            check)
                ;;
            restore)
                target=/
                includes=()
                shift
                while [[ $# -gt 0 ]]; do
                    case "$1" in
                        --target)
                            target=$2
                            shift 2
                            ;;
                        --include)
                            includes+=("$2")
                            shift 2
                            ;;
                        *)
                            shift
                            ;;
                    esac
                done

                [[ -d "$snapshot/home" && -d "$snapshot/tailscale" ]] || {
                    echo 'restic fixture has no snapshot data' >&2
                    exit 1
                }

                restore_root() {
                    local source=$1 destination=$2
                    mkdir -p "$destination"
                    cp -a "$source/." "$destination/"
                }

                if [[ ${#includes[@]} -eq 0 ]]; then
                    restore_root "$snapshot/home" "$target/home"
                    restore_root "$snapshot/tailscale" "$target/var/lib/tailscale"
                else
                    for include in "${includes[@]}"; do
                        case "$include" in
                            /home) restore_root "$snapshot/home" "$target/home" ;;
                            /var/lib/tailscale)
                                restore_root "$snapshot/tailscale" "$target/var/lib/tailscale"
                                ;;
                            *)
                                echo "unexpected restic fixture include: $include" >&2
                                exit 1
                                ;;
                        esac
                    done
                fi
                ;;
            *)
                echo "unexpected restic operation in bootstrap fixture: ${1:-}" >&2
                exit 1
                ;;
        esac
        ;;
    yq|kubectl|gh)
        [[ "$name" != kubectl || "${1:-}" != version ]] || echo 'Client Version: v1.29.6'
        ;;
    *)
        echo "unexpected command shim invocation: $name" >&2
        exit 127
        ;;
esac
SHIM
chmod +x "$SHIM_DIR/command-shim"

for command in apt-get curl timedatectl hostnamectl loginctl systemctl resolvectl \
    getent locale ping sysctl ufw sshd fail2ban-client auditctl jq docker \
    dockerd-rootless-setuptool.sh restic yq kubectl gh; do
    ln -sf "$SHIM_DIR/command-shim" "/usr/local/bin/$command"
done

# The test copy is the production script with only its terminal transport
# adapted for docker exec -i. Assert that the adapter found the expected line
# rather than silently testing a stale or different script.
sed 's#exec 3</dev/tty#exec 3<\&0#' "$BOOTSTRAP_SOURCE" > /test/bootstrap-under-test.sh
grep -Fq 'exec 3<&0' /test/bootstrap-under-test.sh
chmod +x /test/bootstrap-under-test.sh

cat > /usr/local/bin/bootstrap-test-snapshot <<'SNAPSHOT'
#!/usr/bin/env bash
set -euo pipefail

hash_file() {
    local path=$1
    if [[ "$path" == /etc/bootstrap/config ]]; then
        sed '/^# Bootstrap configuration - saved /d' "$path" | sha256sum | cut -d' ' -f1
    else
        sha256sum "$path" | cut -d' ' -f1
    fi
}

for path in \
    /etc/hosts \
    /etc/fstab \
    /etc/bootstrap/config \
    /etc/ssh/sshd_config.d/hardening.conf \
    /etc/sysctl.d/99-hardening.conf \
    /etc/ufw/ufw.conf \
    /etc/fail2ban/jail.local \
    /etc/audit/rules.d/hardening.rules \
    /etc/restic/b2.env \
    /etc/cron.d/restic-backup \
    /etc/logrotate.d/restic-backup \
    /etc/subuid \
    /etc/subgid \
    /home/coding/.bashrc \
    /home/coding/.tmux.conf \
    /home/coding/start.sh \
    /home/coding/.local/bin/start \
    /home/coding/bin/start-docker \
    /home/coding/.config/systemd/user/docker.service \
    /home/coding/.config/systemd/user/default.target.wants/docker.service \
    /home/trading/.bashrc \
    /home/trading/.tmux.conf \
    /home/trading/start.sh \
    /home/trading/.local/bin/start \
    /home/trading/bin/start-docker \
    /home/trading/.config/systemd/user/docker.service \
    /home/trading/.config/systemd/user/default.target.wants/docker.service \
    /var/lib/bootstrap-test/system-docker-disabled \
    /var/lib/systemd/linger/coding \
    /var/lib/systemd/linger/trading \
    /var/lib/bootstrap-test/ufw.rules $\
    /var/lib/bootstrap-test/restic-repository-created; do
    [[ -e "$path" || -L "$path" ]] || continue
    printf '%s %s\n' "$path" "$(hash_file "$path")"
done
SNAPSHOT
chmod +x /usr/local/bin/bootstrap-test-snapshot

echo 'bootstrap integration fixture ready'
