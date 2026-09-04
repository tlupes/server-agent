#!/usr/bin/env bash

set -uo pipefail

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
    printf 'Docker is available; no containers are defined.\n'
    exit 0
fi

issues=()
monitored_count=0
for container_id in "${container_ids[@]}"; do
    details=$(docker inspect --format \
        '{{.Name}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{index .Config.Labels "server-agent.healthcheck"}}' \
        "$container_id") || {
        issues+=("$container_id: inspection failed.")
        continue
    }

    IFS='|' read -r name status health monitoring <<<"$details"
    name=${name#/}
    [[ "$monitoring" == "ignore" ]] && continue
    monitored_count=$((monitored_count + 1))

    if [[ "$status" != "running" ]]; then
        issues+=("$name: state is $status.")
    elif [[ "$health" == "unhealthy" ]]; then
        issues+=("$name: Docker health check is unhealthy.")
    elif [[ "$health" != "none" && "$health" != "healthy" && "$health" != "starting" ]]; then
        issues+=("$name: unexpected health state '$health'.")
    fi

done

if ((${#issues[@]} > 0)); then
    printf '%s\n' "${issues[@]}"
    exit 1
fi

printf 'Docker and %d monitored container(s) are healthy.\n' "$monitored_count"
