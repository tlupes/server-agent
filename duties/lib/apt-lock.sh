#!/usr/bin/env bash

apt_locks_are_held() {
    local lock_path
    local lock_listing
    local -a lock_paths=(
        /var/lib/apt/lists/lock
        /var/cache/apt/archives/lock
        /var/lib/dpkg/lock
        /var/lib/dpkg/lock-frontend
    )

    command -v lslocks >/dev/null 2>&1 || return 1
    lock_listing=$(lslocks --noheadings --notruncate --output PATH 2>/dev/null) || return 1

    for lock_path in "${lock_paths[@]}"; do
        if grep -Fxq "$lock_path" <<<"$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<<"$lock_listing")"; then
            return 0
        fi
    done
    return 1
}

apt_run_with_lock_retry() {
    local wait_seconds=$1
    shift
    local deadline output_file exit_code
    local announced_wait=0

    deadline=$(($(date +%s) + wait_seconds))
    output_file=$(mktemp "${TMPDIR:-/tmp}/server-agent-apt.XXXXXX") || {
        printf 'Unable to create temporary APT output file.\n' >&2
        return 1
    }

    while true; do
        while apt_locks_are_held; do
            if (($(date +%s) >= deadline)); then
                printf 'Timed out after %s seconds waiting for another APT operation.\n' \
                    "$wait_seconds" >&2
                rm -f "$output_file"
                return 1
            fi
            if ((announced_wait == 0)); then
                printf 'Another APT operation is active; waiting up to %s seconds.\n' \
                    "$wait_seconds"
                announced_wait=1
            fi
            sleep 5
        done

        : >"$output_file"
        if "$@" >"$output_file" 2>&1; then
            cat "$output_file"
            rm -f "$output_file"
            return 0
        else
            exit_code=$?
        fi

        if grep -Eqi \
            'could not get lock|unable to acquire.*lock|is another process using it' \
            "$output_file" &&
            (($(date +%s) < deadline)); then
            if ((announced_wait == 0)); then
                printf 'Another APT operation acquired a lock; waiting up to %s seconds.\n' \
                    "$wait_seconds"
                announced_wait=1
            fi
            sleep 5
            continue
        fi

        cat "$output_file" >&2
        rm -f "$output_file"
        return "$exit_code"
    done
}
