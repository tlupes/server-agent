#!/usr/bin/env bash

set -uo pipefail

if ! command -v smartctl >/dev/null 2>&1; then
    printf 'smartctl is not installed; install the smartmontools package.\n' >&2
    exit 1
fi

scan_output=$(smartctl --scan-open 2>&1) || {
    printf 'Unable to scan disks with smartctl:\n%s\n' "$scan_output" >&2
    exit 1
}

if [[ -z "$scan_output" ]]; then
    printf 'smartctl did not discover any disks.\n' >&2
    exit 1
fi

failures=()
checked=0
while IFS= read -r scan_line; do
    scan_line=${scan_line%%#*}
    [[ -n "${scan_line//[[:space:]]/}" ]] || continue
    read -ra device_args <<<"$scan_line"
    device=${device_args[0]}
    checked=$((checked + 1))

    if output=$(smartctl --health "${device_args[@]:1}" "$device" 2>&1); then
        printf '%s: SMART health passed.\n' "$device"
    else
        failures+=("$device: SMART health check failed.
$output")
    fi
done <<<"$scan_output"

if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}"
    exit 1
fi

printf 'SMART health passed for %d disk(s).\n' "$checked"
