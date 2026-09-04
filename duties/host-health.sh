#!/usr/bin/env bash

set -uo pipefail

issues=()
cpu_count=$(nproc)
read -r load_one _ </proc/loadavg
memory_total=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
memory_available=$(awk '
    /^MemAvailable:/ {available=$2}
    /^MemFree:/ {free=$2}
    /^Buffers:/ {buffers=$2}
    /^Cached:/ {cached=$2}
    END {
        if (available > 0) {
            print available
        } else {
            print free + buffers + cached
        }
    }
' /proc/meminfo)
swap_total=$(awk '/^SwapTotal:/ {print $2}' /proc/meminfo)
swap_free=$(awk '/^SwapFree:/ {print $2}' /proc/meminfo)

if awk -v load_value="$load_one" -v cpus="$cpu_count" \
    'BEGIN {exit !(load_value >= cpus * 2)}'; then
    issues+=("One-minute load is $load_one across $cpu_count CPUs (threshold $((cpu_count * 2))).")
fi

if [[ ! "$memory_total" =~ ^[1-9][0-9]*$ ||
    ! "$memory_available" =~ ^[0-9]+$ ]]; then
    printf 'Unable to read host memory information from /proc/meminfo.\n' >&2
    exit 1
fi

memory_available_percent=$(awk -v available="$memory_available" -v total="$memory_total" \
    'BEGIN {printf "%.0f", available * 100 / total}')
if ((memory_available_percent <= 10)); then
    issues+=("Available memory is $memory_available_percent% (threshold 10%).")
fi

swap_used_percent=0
if ((swap_total > 0)); then
    swap_used_percent=$(((swap_total - swap_free) * 100 / swap_total))
    if ((swap_used_percent >= 80)); then
        issues+=("Swap usage is $swap_used_percent% (threshold 80%).")
    fi
fi

for temperature_file in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$temperature_file" ]] || continue
    read -r temperature <"$temperature_file" || continue
    if [[ "$temperature" =~ ^[0-9]+$ ]] && ((temperature >= 85000)); then
        zone=${temperature_file%/temp}
        zone=${zone##*/}
        issues+=("$zone temperature is $((temperature / 1000))C (threshold 85C).")
    fi
done

if ((${#issues[@]} > 0)); then
    printf '%s\n' "${issues[@]}"
    exit 1
fi

printf 'Host is healthy: load %s/%s CPUs, %s%% memory available, %s%% swap used.\n' \
    "$load_one" "$cpu_count" "$memory_available_percent" "$swap_used_percent"
