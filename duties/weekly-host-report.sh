#!/usr/bin/env bash

set -uo pipefail

readonly REPORT_STATE_DIR="${SERVER_AGENT_STATE_DIR:-/var/lib/server-agent}/duties"

uptime_text=$(uptime --pretty 2>/dev/null || printf 'unavailable')
load_text=$(awk '{print $1", "$2", "$3}' /proc/loadavg 2>/dev/null || printf 'unavailable')
root_usage=$(df --human-readable --output=size,used,avail,pcent / 2>/dev/null |
    tail -n 1 | xargs || printf 'unavailable')
memory_text=$(free --human 2>/dev/null |
    awk '/^Mem:/ {printf "%s used / %s total, %s available", $3, $2, $7}')
[[ -n "$memory_text" ]] || memory_text="unavailable"

docker_text="unavailable"
docker_storage="unavailable"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    total_containers=$(docker ps --all --quiet | wc -l | xargs)
    running_containers=$(docker ps --quiet | wc -l | xargs)
    unhealthy_containers=$(docker ps --filter health=unhealthy --quiet | wc -l | xargs)
    docker_text="$running_containers running / $total_containers total, $unhealthy_containers unhealthy"
    docker_storage=$(docker system df \
        --format '{{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null |
        awk 'BEGIN {separator=""} {printf "%s%s", separator, $0; separator="; "}')
    [[ -n "$docker_storage" ]] || docker_storage="no Docker storage data"
fi

failed_duties=()
for status_file in "$REPORT_STATE_DIR"/*.status; do
    [[ -f "$status_file" ]] || continue
    read -r status <"$status_file" || continue
    if [[ "$status" == failure:* ]]; then
        duty_name=${status_file##*/}
        failed_duties+=("${duty_name%.status}")
    fi
done
if ((${#failed_duties[@]} == 0)); then
    duty_health="none"
else
    duty_health="${failed_duties[*]}"
fi

if [[ -f /var/run/reboot-required ]]; then
    reboot_text="required"
else
    reboot_text="not required"
fi

cat <<EOF
Weekly host report for $(hostname)
Uptime: $uptime_text
Load (1/5/15m): $load_text
Root filesystem (size/used/available/use): $root_usage
Memory: $memory_text
Docker containers: $docker_text
Docker storage: $docker_storage
Failed duties: $duty_health
Reboot: $reboot_text
EOF
