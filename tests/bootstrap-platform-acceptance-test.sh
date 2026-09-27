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
    local os_release="$WORK/$label-os-release"
    local output="$WORK/$label-output"
    local bin_dir="$WORK/$label-bin"
    shift 7
    printf '%s\n' "$@" >"$os_release"
    mkdir -p "$bin_dir"

    if [[ "$systemd_mode" == pass ]]; then
        cat >"$bin_dir/systemctl" <<'SYSTEMCTL'
#!/bin/sh
if [ "$1" = show ]; then
    printf '260.2\n'
fi
SYSTEMCTL
    else
        cat >"$bin_dir/systemctl" <<'SYSTEMCTL'
#!/bin/sh
exit 1
SYSTEMCTL
    fi

    if [[ "$dns_mode" == pass ]]; then
        cat >"$bin_dir/getent" <<'GETENT'
#!/bin/sh
printf '203.0.113.10 STREAM raw.githubusercontent.com\n'
GETENT
    else
        cat >"$bin_dir/getent" <<'GETENT'
#!/bin/sh
exit 2
GETENT
    fi

    if [[ "$https_mode" == pass ]]; then
        cat >"$bin_dir/curl" <<'CURL'
#!/bin/sh
exit 0
CURL
    else
        cat >"$bin_dir/curl" <<'CURL'
#!/bin/sh
exit 56
CURL
    fi
    chmod 0755 "$bin_dir/systemctl" "$bin_dir/getent" "$bin_dir/curl"

    local -a docker_args=(--rm)
    if [[ "$root_mode" == non-root ]]; then
        docker_args+=(--user 65534:65534)
    fi
    docker_args+=(
        --volume "$ROOT/scripts/bootstrap-preflight.sh:/usr/local/sbin/bootstrap-preflight.sh:ro"
        --volume "$os_release:/etc/os-release:ro"
        --volume "$bin_dir:/preflight-bin:ro"
    )

    set +e
    docker run "${docker_args[@]}" \
        --env 'PATH=/preflight-bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
        "$IMAGE" /usr/local/sbin/bootstrap-preflight.sh >"$output" 2>&1
    local status=$?
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
    echo "PASS: $label"
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

run_case root-required 1 'run as root (use sudo)' non-root pass pass pass \
    'ID=debian' \
    'VERSION_ID="12"' \
    'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"'

run_case systemd-required 1 'systemd manager is unavailable' root fail pass pass \
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
