#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the documented OS matrix and host prerequisites in a disposable
# Debian container. The image supplies the required package tools; command
# shims model a reachable systemd manager, DNS, and HTTPS without depending on
# the test runner's network or PID 1.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${BOOTSTRAP_PLATFORM_TEST_IMAGE:-debian:12-slim}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-platform-acceptance.XXXXXX")

cleanup() {
    local exit_code=$?
    if [[ -d "$WORK" && "$WORK" == "${TMPDIR:-/tmp}/bootstrap-platform-acceptance."* ]]; then
        rm -rf "$WORK"
    fi
    return "$exit_code"
}
trap cleanup EXIT

die() {
    echo "Bootstrap platform acceptance test failed: $*" >&2
    exit 1
}

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    if [[ ${BOOTSTRAP_PLATFORM_TEST_REQUIRE_DOCKER:-false} == true ]]; then
        die 'a reachable Docker daemon is required'
    fi
    echo 'SKIP: bootstrap platform acceptance tests require a reachable Docker daemon' >&2
    exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "Pulling disposable test image $IMAGE..."
    docker pull "$IMAGE" >/dev/null
fi

run_case() {
    local label=$1 expected_status=$2 expected_text=$3
    local root_mode=$4 systemd_mode=$5 dns_mode=$6 https_mode=$7
    local terminal_mode=${TERMINAL_MODE:-tty}
    local os_release="$WORK/$label-os-release"
    local output="$WORK/$label-output"
    local bin_dir="$WORK/$label-bin"
    local state_dir="$WORK/$label-state"
    local container="bootstrap-platform-${PPID}-${RANDOM}"
    local missing_command=${MISSING_COMMAND:-}
    local architecture_mode=${ARCH_MODE:-pass}
    local os_release_mode=${OS_RELEASE_MODE:-present}
    local -a preflight_args=()
    shift 7
    if [[ "$os_release_mode" == present ]]; then
        printf '%s\n' "$@" >"$os_release"
    else
        preflight_args=(--os-release /preflight-state/missing-os-release)
    fi
    mkdir -p "$bin_dir"
    mkdir -p "$state_dir"
    chmod 0777 "$state_dir"

    # Keep the command path deliberately small. This makes a missing-command
    # case deterministic even if the base image gains another package later.
    ln -s /bin/bash "$bin_dir/bash"
    ln -s /usr/bin/sed "$bin_dir/sed"
    ln -s /usr/bin/head "$bin_dir/head"

    cat >"$bin_dir/apt-get" <<'APT_GET'
#!/bin/sh
printf 'MUTATION_ATTEMPT apt-get %s\n' "$*" >>/preflight-state/commands.log
exit 97
APT_GET

    cat >"$bin_dir/dpkg" <<'DPKG'
#!/bin/sh
printf 'READ dpkg %s\n' "$*" >>/preflight-state/commands.log
if [ "$1" != --print-architecture ]; then
    printf 'MUTATION_ATTEMPT dpkg %s\n' "$*" >>/preflight-state/commands.log
    exit 97
fi
if [ "${BOOTSTRAP_ARCHITECTURE_MODE:-pass}" = fail ]; then
    exit 1
fi
if [ "${BOOTSTRAP_ARCHITECTURE_MODE:-pass}" = i386 ]; then
    printf 'i386\n'
else
    printf 'amd64\n'
fi
DPKG

    cat >"$bin_dir/systemctl" <<'SYSTEMCTL'
#!/bin/sh
printf 'READ systemctl %s\n' "$*" >>/preflight-state/commands.log
if [ "$1" != show ] || [ "$2" != --property=Version ] || [ "$3" != --value ]; then
    printf 'MUTATION_ATTEMPT systemctl %s\n' "$*" >>/preflight-state/commands.log
    exit 97
fi
if [ "${BOOTSTRAP_SYSTEMD_MODE:-pass}" = fail ]; then
    exit 1
fi
if [ "${BOOTSTRAP_SYSTEMD_MODE:-pass}" = empty ]; then
    exit 0
fi
printf '260.2\n'
SYSTEMCTL

    cat >"$bin_dir/getent" <<'GETENT'
#!/bin/sh
printf 'READ getent %s\n' "$*" >>/preflight-state/commands.log
if [ "${BOOTSTRAP_DNS_MODE:-pass}" = fail ]; then
    exit 2
fi
printf '203.0.113.10 STREAM raw.githubusercontent.com\n'
GETENT

    cat >"$bin_dir/curl" <<'CURL'
#!/bin/sh
printf 'READ curl %s\n' "$*" >>/preflight-state/commands.log
if [ "${BOOTSTRAP_HTTPS_MODE:-pass}" = fail ]; then
    exit 56
fi
exit 0
CURL

    chmod 0755 "$bin_dir/apt-get" "$bin_dir/dpkg" "$bin_dir/systemctl" \
        "$bin_dir/getent" "$bin_dir/curl"
    if [[ -n "$missing_command" ]]; then
        rm "$bin_dir/$missing_command"
    fi

    local -a docker_args=(--name "$container")
    if [[ "$terminal_mode" == tty ]]; then
        docker_args+=(--tty)
    fi
    if [[ "$root_mode" == non-root ]]; then
        docker_args+=(--user 65534:65534)
    fi
    docker_args+=(
        --volume "$ROOT/scripts/bootstrap-preflight.sh:/preflight-script:ro"
        --volume "$bin_dir:/preflight-bin:ro"
        --volume "$state_dir:/preflight-state"
    )
    if [[ "$os_release_mode" == present ]]; then
        docker_args+=(--volume "$os_release:/etc/os-release:ro")
    fi
    docker_args+=(
        --env "BOOTSTRAP_ARCHITECTURE_MODE=$architecture_mode"
        --env "BOOTSTRAP_SYSTEMD_MODE=$systemd_mode"
        --env "BOOTSTRAP_DNS_MODE=$dns_mode"
        --env "BOOTSTRAP_HTTPS_MODE=$https_mode"
        "$IMAGE"
        /bin/bash
        -c
        'set -Eeuo pipefail
        set +e
        PATH=/preflight-bin "$1" "${@:2}"
        status=$?
        set -e
        exit "$status"'
        _
        /preflight-script
        "${preflight_args[@]}"
    )

    set +e
    docker create "${docker_args[@]}" >/dev/null
    docker start -a "$container" >"$output" 2>&1
    local status=$?
    local changes
    changes=$(docker diff "$container" | awk \
        '$2 != "/preflight-bin" && $2 !~ "^/preflight-bin/" && \
         $2 != "/preflight-state" && $2 !~ "^/preflight-state/" && \
         $2 != "/preflight-script" && $2 !~ "^/preflight-script/"')
    docker rm "$container" >/dev/null
    set -e

    [[ "$status" -eq "$expected_status" ]] || {
        echo "Unexpected status for $label: got $status, expected $expected_status" >&2
        cat "$output" >&2
        exit 1
    }
    grep -Fq "$expected_text" "$output" || {
        echo "Unexpected output for $label; missing: $expected_text" >&2
        cat "$output" >&2
        exit 1
    }
    [[ -z "$changes" ]] || {
        echo "ASSERTION FAILED: $label changed the disposable host:" >&2
        printf '%s\n' "$changes" >&2
        exit 1
    }
    if [[ -f "$state_dir/commands.log" ]] && grep -Fq 'MUTATION_ATTEMPT' "$state_dir/commands.log"; then
        echo "ASSERTION FAILED: $label attempted a package, service, or configuration mutation:" >&2
        cat "$state_dir/commands.log" >&2
        exit 1
    fi
    if [[ "$os_release_mode" != present && -e "$state_dir/missing-os-release" ]]; then
        echo "ASSERTION FAILED: $label created the missing os-release configuration file" >&2
        exit 1
    fi
    echo "PASS: $label (no filesystem, package, service, or configuration mutation)"
}

run_case debian-12 0 'Preflight passed: Debian 12 (bookworm)' root pass pass pass \
    'NAME="Debian GNU/Linux"' \
    'ID=debian' \
    'VERSION_ID="12"' \
    'VERSION_CODENAME=bookworm' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case ubuntu-24.04 0 'Preflight passed: Ubuntu 24.04 (noble)' root pass pass pass \
    'NAME="Ubuntu"' \
    'ID=ubuntu' \
    'VERSION_ID="24.04"' \
    'VERSION_CODENAME=noble' \
    'PRETTY_NAME="Ubuntu 24.04 LTS"'

run_case debian-13-unsupported 1 'unsupported release Debian GNU/Linux 13 (trixie)' root pass pass pass \
    'NAME="Debian GNU/Linux"' \
    'ID=debian' \
    'VERSION_ID="13"' \
    'VERSION_CODENAME=trixie' \
    'PRETTY_NAME="Debian GNU/Linux 13 (trixie)"'

run_case alpine-unsupported 1 'unsupported operating system Alpine Linux v3.20' root pass pass pass \
    'NAME="Alpine Linux"' \
    'ID=alpine' \
    'VERSION_ID="3.20"' \
    'PRETTY_NAME="Alpine Linux v3.20"'

run_case unknown-os 1 'could not identify the operating system' root pass pass pass \
    'NAME="Unknown"' \
    'PRETTY_NAME="Unknown Linux"'

OS_RELEASE_MODE=missing run_case missing-os-release 1 \
    'cannot read /preflight-state/missing-os-release' root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case root-required 1 'run as root (use sudo)' non-root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

MISSING_COMMAND=apt-get run_case missing-required-command 1 \
    "required command 'apt-get' is missing" root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

ARCH_MODE=fail run_case architecture-query-failed 1 \
    'could not determine the dpkg architecture' root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

ARCH_MODE=i386 run_case unsupported-architecture 1 \
    "unsupported architecture 'i386'" root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

TERMINAL_MODE=none run_case controlling-terminal-required 1 \
    'no controlling terminal available; run from an interactive terminal' \
    root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case systemd-required 1 'systemd manager is unavailable' root fail pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case systemd-version-missing 1 'systemd manager did not report a version' root empty pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case dns-required 1 'DNS lookup failed for raw.githubusercontent.com' root pass fail pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case https-required 1 'outbound HTTPS check failed for https://raw.githubusercontent.com/jedarden/bootstrap/main/README.md' root pass pass fail \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

echo 'Bootstrap platform acceptance tests passed.'
