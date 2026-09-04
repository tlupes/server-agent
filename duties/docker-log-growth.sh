#!/usr/bin/env bash

set -uo pipefail

readonly WARNING_BYTES=$((500 * 1024 * 1024))
readonly CRITICAL_BYTES=$((1024 * 1024 * 1024))

if ! command -v docker >/dev/null 2>&1; then
    printf 'Docker CLI is not installed.\n' >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    printf 'Docker daemon is unavailable.\n' >&2
    exit 1
fi

mapfile -t container_ids < <(docker ps --all --quiet)
if ((${#container_ids[@]} == 0)); then
    printf 'Docker is available; no container logs exist.\n'
    exit 0
fi

issues=()
highest_threshold=0
checked=0
for container_id in "${container_ids[@]}"; do
    details=$(docker inspect --format \
        '{{.Name}}|{{.LogPath}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}' \
        "$container_id") || {
        issues+=("$container_id: unable to inspect its logging configuration.")
        highest_threshold=1
        continue
    }

    IFS='|' read -r name log_path log_driver max_size <<<"$details"
    name=${name#/}
    if [[ -z "$log_path" || "$log_path" == "<no value>" ]]; then
        continue
    fi
    if [[ ! -e "$log_path" ]]; then
        issues+=("$name: Docker reports a missing log path: $log_path")
        highest_threshold=1
        continue
    fi

    checked=$((checked + 1))
    log_directory=$(dirname -- "$log_path")
    log_filename=$(basename -- "$log_path")
    if ! log_bytes=$(find "$log_directory" -maxdepth 1 -type f \
        -name "$log_filename*" -printf '%s\n' 2>/dev/null |
        awk '{total += $1} END {printf "%.0f", total}'); then
        issues+=("$name: unable to measure logs under $log_directory.")
        highest_threshold=1
        continue
    fi
    [[ "$log_bytes" =~ ^[0-9]+$ ]] || log_bytes=0
    log_megabytes=$((log_bytes / 1024 / 1024))

    if ((log_bytes >= CRITICAL_BYTES)); then
        issues+=("$name: logs use ${log_megabytes} MB (critical threshold 1024 MB); driver=$log_driver, max-size=${max_size:-unset}.")
        highest_threshold=95
    elif ((log_bytes >= WARNING_BYTES)); then
        issues+=("$name: logs use ${log_megabytes} MB (warning threshold 500 MB); driver=$log_driver, max-size=${max_size:-unset}.")
        ((highest_threshold < 80)) && highest_threshold=80
    fi
done

if ((${#issues[@]} > 0)); then
    printf '%s\n' "${issues[@]}"
    exit "$highest_threshold"
fi

printf 'Checked log usage for %d container(s); all are below 500 MB.\n' "$checked"
