#!/usr/bin/env bash

set -uo pipefail

readonly MOUNT_ROOT="/hillbox"
readonly HEALTH_TIMEOUT="10s"
readonly MOUNT_TIMEOUT="30s"
readonly UNMOUNT_TIMEOUT="30s"

for command in findmnt mount stat timeout umount; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required network-mount command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
    printf 'Network-mount preflight passed; mount changes are skipped during trial updates.\n'
    exit 0
fi

if ! fstab_entries=$(findmnt --fstab --raw --noheadings \
    --output TARGET,FSTYPE,OPTIONS 2>&1); then
    printf 'Unable to read network mounts from /etc/fstab:\n%s\n' "$fstab_entries" >&2
    exit 1
fi

expected_mounts=()
expected_types=()
while read -r encoded_target filesystem_type mount_options; do
    [[ -n "$encoded_target" ]] || continue
    target=$(printf '%b' "$encoded_target")

    case "$target" in
        "$MOUNT_ROOT" | "$MOUNT_ROOT"/*) ;;
        *) continue ;;
    esac
    case "$filesystem_type" in
        nfs | nfs4 | cifs | smb3 | fuse.sshfs) ;;
        *)
            [[ ",$mount_options," == *,_netdev,* ]] || continue
            ;;
    esac
    if [[ ",$mount_options," == *,noauto,* ]]; then
        continue
    fi

    expected_mounts+=("$target")
    expected_types+=("$filesystem_type")
done <<<"$fstab_entries"

if ((${#expected_mounts[@]} == 0)); then
    printf 'No automatically managed network filesystems are defined under %s in /etc/fstab.\n' \
        "$MOUNT_ROOT" >&2
    exit 1
fi

failures=()
repaired=()
healthy=0
for index in "${!expected_mounts[@]}"; do
    target=${expected_mounts[$index]}
    expected_type=${expected_types[$index]}
    mounted=0

    if findmnt --mountpoint "$target" --noheadings >/dev/null 2>&1; then
        mounted=1
        actual_type=$(findmnt --mountpoint "$target" --noheadings --raw --output FSTYPE)
        if [[ "$actual_type" != "$expected_type" && "$actual_type" != "autofs" ]]; then
            failures+=("$target: mounted as $actual_type, expected $expected_type; left unchanged.")
            continue
        fi

        if timeout --signal=TERM --kill-after=5s "$HEALTH_TIMEOUT" \
            stat -- "$target" >/dev/null 2>&1; then
            healthy=$((healthy + 1))
            continue
        fi
    fi

    if ((mounted == 1)); then
        if ! output=$(timeout --signal=TERM --kill-after=5s "$UNMOUNT_TIMEOUT" \
            umount -- "$target" 2>&1); then
            failures+=("$target: mounted but unresponsive; normal unmount failed, so it was not forcefully detached.
${output:-The unmount timed out or returned no details.}")
            continue
        fi
    elif [[ ! -d "$target" ]]; then
        if ! mkdir -p -- "$target"; then
            failures+=("$target: mountpoint directory could not be created.")
            continue
        fi
    elif [[ -n "$(find "$target" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]]; then
        failures+=("$target: mountpoint contains local files; refusing to hide them with a network mount.")
        continue
    fi

    if ! output=$(timeout --signal=TERM --kill-after=5s "$MOUNT_TIMEOUT" \
        mount -- "$target" 2>&1); then
        failures+=("$target: not mounted and mount attempt failed.
${output:-The mount timed out or returned no details.}")
        continue
    fi

    if ! findmnt --mountpoint "$target" --noheadings >/dev/null 2>&1 ||
        ! timeout --signal=TERM --kill-after=5s "$HEALTH_TIMEOUT" \
            stat -- "$target" >/dev/null 2>&1; then
        failures+=("$target: mount command succeeded, but the mounted filesystem is not responsive.")
        continue
    fi

    repaired+=("$target")
    healthy=$((healthy + 1))
done

if ((${#failures[@]} > 0)); then
    printf '%s\n' "${failures[@]}"
    if ((${#repaired[@]} > 0)); then
        printf 'Successfully remounted during this run: %s\n' "${repaired[*]}"
    fi
    exit 1
fi

if ((${#repaired[@]} > 0)); then
    printf 'Successfully mounted network filesystems: %s\n' "${repaired[*]}"
else
    printf 'All %d network filesystem(s) under %s are mounted and responsive.\n' \
        "$healthy" "$MOUNT_ROOT"
fi
