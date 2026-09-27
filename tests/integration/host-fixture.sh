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
cp "$(dirname "$BOOTSTRAP_SOURCE")/artifact-manifest.txt" "$ROOT/artifact-manifest.txt"
cp "$(dirname "$BOOTSTRAP_SOURCE")/artifact-manifest.sig" "$ROOT/artifact-manifest.sig"
cp "$(dirname "$BOOTSTRAP_SOURCE")/keys/bootstrap-artifacts-signing.pub" \
    "$KEYS/bootstrap-artifacts-signing.pub"

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
        url=""
        for argument in "$@"; do
            if [[ "$argument" == http://* || "$argument" == https://* ]]; then
                url="$argument"
                break
            fi
        done
        url="${url:-${!#}}"
        case "$url" in
            https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/artifact-manifest.txt)
                cat "$state/artifact-manifest.txt"
                ;;
            https://raw.githubusercontent.com/jedarden/bootstrap/main/hosts/ex44/artifact-manifest.sig)
                cat "$state/artifact-manifest.sig"
                ;;
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
            https://traefik-rs-manager:8200/v1/secret/bootstrap/*/b2)
                method=""
                header_reference=""
                curl_arguments=("$@")
                for ((argument_index = 0; argument_index < ${#curl_arguments[@]}; argument_index++)); do
                    case "${curl_arguments[$argument_index]}" in
                        -X)
                            method="${curl_arguments[$((argument_index + 1))]:-}"
                            ;;
                        -H)
                            header_reference="${curl_arguments[$((argument_index + 1))]:-}"
                            ;;
                    esac
                done
                [[ "$method" == GET && "$header_reference" == @* ]] || exit 22
                header_path=${header_reference#@}
                [[ -f "$header_path" ]] || exit 22
                printf '%s\n' "$header_path" > "$state/openbao-last-header-path"
                [[ "$(cat "$header_path")" == "X-Vault-Token: ${BOOTSTRAP_TEST_OPENBAO_EXPECTED_TOKEN:-}" ]] || exit 22
                printf 'GET %s\n' "${url#https://traefik-rs-manager:8200}" >> "$state/openbao-requests.log"
                case "${BOOTSTRAP_TEST_OPENBAO_MODE:-unavailable}" in
                    complete)
                        printf '{"data":{"data":{"b2_application_key":"%s","restic_password":"%s"}}}\n' \
                            "${BOOTSTRAP_TEST_OPENBAO_B2_KEY:-}" \
                            "${BOOTSTRAP_TEST_OPENBAO_RESTIC_PASSWORD:-}"
                        touch "$state/openbao-api-contract-ok"
                        ;;
                    partial)
                        printf '{"data":{"data":{"b2_application_key":"%s"}}}\n' \
                            "${BOOTSTRAP_TEST_OPENBAO_B2_KEY:-}"
                        touch "$state/openbao-api-contract-ok"
                        ;;
                    malformed)
                        printf '%s\n' '{"data":{"data":'
                        ;;
                    *)
                        exit 7
                        ;;
                esac
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
                unit="${3:-${2:-}}"
                if [[ "$unit" == docker.service && -f "$state/system-docker-disabled" ]]; then
                    echo disabled
                    exit 0
                fi
                if [[ "$unit" == tailscaled ]]; then
                    if [[ -f "$state/tailscaled-enabled" ]]; then
                        [[ "${2:-}" == --quiet ]] || echo enabled
                        exit 0
                    fi
                    [[ "${2:-}" == --quiet ]] || echo disabled
                    exit 1
                fi
                if [[ -f "$state/$unit-enabled" ]]; then
                    [[ "${2:-}" == "--quiet" ]] || echo enabled
                    exit 0
                fi
                [[ "${2:-}" == "--quiet" ]] || echo disabled
                exit 1
                ;;
            is-active)
                unit="${3:-${2:-}}"
                if [[ "$unit" == docker.service && -f "$state/system-docker-disabled" ]]; then
                    echo inactive
                    exit 0
                fi
                if [[ -f "$state/$unit-active" ]]; then
                    [[ "${2:-}" == --quiet ]] || echo active
                    exit 0
                fi
                [[ "${2:-}" == --quiet ]] || echo inactive
                exit 3
                ;;
            enable)
                unit="${3:-${2:-}}"
                if [[ "$unit" == tailscaled ]]; then
                    if [[ ${BOOTSTRAP_TEST_TAILSCALE_SERVICE_FAIL:-false} == true ]]; then
                        echo 'fixture: tailscaled failed to start' >&2
                        exit 1
                    fi
                    touch "$state/tailscaled-enabled" "$state/tailscaled-active"
                elif [[ -n "$unit" && "$unit" != --* ]]; then
                    touch "$state/$unit-enabled"
                fi
                if [[ "${2:-}" == --now && -n "$unit" ]]; then
                    touch "$state/$unit-active"
                fi
                exit 0
                ;;
            stop)
                unit="${2:-}"
                rm -f "$state/$unit-active"
                exit 0
                ;;
            start)
                unit="${2:-}"
                touch "$state/$unit-active"
                exit 0
                ;;
            restart)
                unit="${2:-}"
                touch "$state/$unit-active"
                exit 0
                ;;
            --user)
                action="${2:-}"
                unit="${3:-}"
                if [[ "$action" == start && "$unit" == docker ]]; then
                    runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
                    mkdir -p "$runtime_dir"
                    touch "$runtime_dir/docker.sock"
                    chown "$(id -u):$(id -g)" "$runtime_dir/docker.sock"
                fi
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
                    rm -f "$state/ufw-active"
                elif [[ "${2:-}" == enable ]]; then
                    printf '%s\n' 'ENABLED=yes' > /etc/ufw/ufw.conf
                    touch "$state/ufw-enabled" "$state/ufw-active"
                fi
                ;;
            default)
                echo "Default: ${2:-} ${3:-}" >> "$rules"
                ;;
            allow)
                echo "ALLOW IN on ${3:-any} $*" >> "$rules"
                ;;
            status)
                if [[ -f "$state/ufw-active" ]]; then
                    echo 'Status: active'
                else
                    echo 'Status: inactive'
                fi
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
        json=$(cat)
        case "$*" in
            '-e .data.data')
                [[ "$json" == '{"data":{"data":'* ]] || exit 1
                [[ "$json" == *'}}}' ]] || exit 1
                ;;
            '-r .data.data.b2_application_key // empty')
                if [[ "$json" =~ \"b2_application_key\":\"([^\"]*)\" ]]; then
                    printf '%s\n' "${BASH_REMATCH[1]}"
                fi
                ;;
            '-r .data.data.restic_password // empty')
                if [[ "$json" =~ \"restic_password\":\"([^\"]*)\" ]]; then
                    printf '%s\n' "${BASH_REMATCH[1]}"
                fi
                ;;
            *)
                echo 'bootstrap-test.tailnet.ts.net'
                ;;
        esac
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
        docker_socket=${DOCKER_HOST#unix://}
        [[ -e "$docker_socket" ]] || {
            echo "rootless Docker fixture socket is unavailable: $docker_socket" >&2
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
        mkdir -p "${XDG_RUNTIME_DIR:?}"
        touch "$XDG_RUNTIME_DIR/docker.sock"
        chown "$(id -u):$(id -g)" "$XDG_RUNTIME_DIR/docker.sock"
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

cat > /usr/local/bin/bootstrap-test-reboot <<'REBOOT'
#!/usr/bin/env bash
set -Eeuo pipefail

# The disposable image has no systemd PID 1, so an actual container restart
# cannot exercise boot ordering. Model the important reboot boundary instead:
# persistent configuration and enablement markers remain on disk, while
# service/runtime state is discarded and reconstructed from those markers.
state=/var/lib/bootstrap-test
touch "$state/reboot-requested"
rm -f \
    "$state/sshd-active" \
    "$state/fail2ban-active" \
    "$state/auditd-active" \
    "$state/tailscaled-active" \
    "$state/ufw-active"
rm -rf /run/user/*

if [[ -f /etc/ufw/ufw.conf ]] && grep -Fxq 'ENABLED=yes' /etc/ufw/ufw.conf; then
    touch "$state/ufw-active"
fi

[[ -f /etc/ssh/sshd_config.d/hardening.conf ]] && touch "$state/sshd-active"
for unit in fail2ban auditd tailscaled; do
    [[ -f "$state/$unit-enabled" ]] && touch "$state/$unit-active"
done

for user in coding trading; do
    uid=$(id -u "$user")
    runtime_dir=/run/user/$uid
    if [[ -f /var/lib/systemd/linger/$user &&
          -L /home/$user/.config/systemd/user/default.target.wants/docker.service ]]; then
        mkdir -p "$runtime_dir"
        chown "$user:$user" "$runtime_dir"
        chmod 700 "$runtime_dir"
        touch "$runtime_dir/docker.sock"
        chown "$user:$user" "$runtime_dir/docker.sock"
    fi
done

printf '%s\n' 'reboot boundary completed' > "$state/reboot.log"
REBOOT
chmod +x /usr/local/bin/bootstrap-test-reboot

# The test copy is the production script without transformations: the
# integration runner allocates a pty so the signed bootstrap digest remains
# valid. Assert that the expected terminal line is present rather than
# silently testing a stale or different script.
cp "$BOOTSTRAP_SOURCE" /test/bootstrap-under-test.sh
grep -Fq 'exec 3</dev/tty' /test/bootstrap-under-test.sh
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
