#!/usr/bin/env bash

set -uo pipefail

readonly DUTY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/apt-lock.sh
source "$DUTY_DIR/lib/apt-lock.sh"

highest_threshold=0
issues=()
cleanup_log=()
space_output=""
inode_output=""

reset_capacity_result() {
    highest_threshold=0
    issues=()
}

record_usage() {
    local kind=$1
    local percent=$2
    local mountpoint=$3
    local threshold=0

    percent=${percent%%%}
    [[ "$percent" =~ ^[0-9]+$ ]] || return

    if ((percent >= 95)); then
        threshold=95
    elif ((percent >= 90)); then
        threshold=90
    elif ((percent >= 80)); then
        threshold=80
    fi

    if ((threshold > 0)); then
        issues+=("$mountpoint: $kind usage is $percent% (threshold $threshold%).")
        ((threshold > highest_threshold)) && highest_threshold=$threshold
    fi
}

inspect_capacity() {
    local filesystem inodes used available percent mountpoint

    reset_capacity_result

    if ! space_output=$(df --local --output=pcent,target \
        --exclude-type=tmpfs \
        --exclude-type=devtmpfs \
        --exclude-type=squashfs \
        --exclude-type=overlay 2>&1); then
        printf 'Unable to inspect filesystem capacity:\n%s\n' "$space_output" >&2
        return 1
    fi

    while read -r percent mountpoint; do
        [[ "$percent" == "Use%" ]] && continue
        record_usage "space" "$percent" "$mountpoint"
    done <<<"$space_output"

    if ! inode_output=$(df --local --inodes --portability \
        --exclude-type=tmpfs \
        --exclude-type=devtmpfs \
        --exclude-type=squashfs \
        --exclude-type=overlay 2>&1); then
        printf 'Unable to inspect filesystem inode capacity:\n%s\n' "$inode_output" >&2
        return 1
    fi

    while read -r filesystem inodes used available percent mountpoint; do
        [[ "$filesystem" == "Filesystem" ]] && continue
        record_usage "inode" "$percent" "$mountpoint"
    done <<<"$inode_output"
}

run_cleanup() {
    local description=$1
    shift
    local output

    if output=$("$@" 2>&1); then
        cleanup_log+=("$description: completed.")
        [[ -n "$output" ]] && cleanup_log+=("$output")
    else
        cleanup_log+=("$description: failed; continuing.
$output")
    fi
}

clean_safe_files() {
    local threshold=$1

    cleanup_log+=("Filesystem usage reached the $threshold% tier; running safe cleanup.")

    if command -v systemd-tmpfiles >/dev/null 2>&1; then
        run_cleanup "Policy-managed temporary-file cleanup" systemd-tmpfiles --clean
    else
        cleanup_log+=("Policy-managed temporary-file cleanup: skipped; systemd-tmpfiles is unavailable.")
    fi

    if command -v apt-get >/dev/null 2>&1; then
        run_cleanup "APT package-cache cleanup" \
            apt_run_with_lock_retry 300 \
            apt-get -o DPkg::Lock::Timeout=300 clean
    else
        cleanup_log+=("APT package-cache cleanup: skipped; apt-get is unavailable.")
    fi

    if ((threshold >= 90)); then
        if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
            run_cleanup "Dangling Docker-image cleanup" docker image prune --force
            if ((threshold >= 95)); then
                run_cleanup "Unused Docker build-cache cleanup (older than one day)" \
                    docker builder prune --all --force --filter "until=24h"
            else
                run_cleanup "Unused Docker build-cache cleanup (older than seven days)" \
                    docker builder prune --force --filter "until=168h"
            fi
        else
            cleanup_log+=("Docker cache cleanup: skipped; the Docker daemon is unavailable.")
        fi

        if command -v journalctl >/dev/null 2>&1; then
            if ((threshold >= 95)); then
                run_cleanup "Archived journal cleanup (seven days, 500 MB maximum)" \
                    journalctl --vacuum-time=7d --vacuum-size=500M
            else
                run_cleanup "Archived journal cleanup (older than 30 days)" \
                    journalctl --vacuum-time=30d
            fi
        else
            cleanup_log+=("Archived journal cleanup: skipped; journalctl is unavailable.")
        fi
    fi
}

inspect_capacity || exit 1
initial_threshold=$highest_threshold
initial_issues=("${issues[@]}")

if ((initial_threshold > 0)); then
    if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
        printf '%s\n' "${initial_issues[@]}"
        printf 'Cleanup is intentionally skipped during candidate-revision trials.\n'
        exit 0
    fi

    clean_safe_files "$initial_threshold"
    inspect_capacity || exit 1

    printf 'Before cleanup:\n%s\n\nCleanup actions:\n%s\n' \
        "$(printf '%s\n' "${initial_issues[@]}")" \
        "$(printf '%s\n' "${cleanup_log[@]}")"

    if ((highest_threshold > 0)); then
        printf '\nAfter cleanup:\n%s\n' "$(printf '%s\n' "${issues[@]}")"
        exit "$highest_threshold"
    fi

    printf '\nAfter cleanup: all local filesystems are below 80%% space and inode usage.\n'
    exit 0
fi

printf 'All local filesystems are below 80%% space and inode usage.\n'
