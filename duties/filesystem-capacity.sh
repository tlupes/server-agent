#!/usr/bin/env bash

set -uo pipefail

highest_threshold=0
issues=()
space_output=""
inode_output=""

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

if ! space_output=$(df --local --output=pcent,target \
    --exclude-type=tmpfs \
    --exclude-type=devtmpfs \
    --exclude-type=squashfs \
    --exclude-type=overlay 2>&1); then
    printf 'Unable to inspect filesystem capacity:\n%s\n' "$space_output" >&2
    exit 1
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
    exit 1
fi

while read -r filesystem inodes used available percent mountpoint; do
    [[ "$filesystem" == "Filesystem" ]] && continue
    record_usage "inode" "$percent" "$mountpoint"
done <<<"$inode_output"

if ((highest_threshold > 0)); then
    printf '%s\n' "${issues[@]}"
    exit "$highest_threshold"
fi

printf 'All local filesystems are below 80%% space and inode usage.\n'
