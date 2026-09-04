#!/usr/bin/env bash

set -uo pipefail

readonly JOURNAL_STATE_DIR="${SERVER_AGENT_STATE_DIR:-/var/lib/server-agent}/duties/kernel-filesystem-errors"
readonly CURSOR_FILE="$JOURNAL_STATE_DIR/journal.cursor"
readonly ERROR_PATTERN='I/O error|Buffer I/O error|blk_update_request|EXT[234]-fs (error|warning)|XFS.*(corruption|error)|BTRFS.*(corrupt|error)|ZFS.*(fault|error)|Remounting filesystem read-only|Read-only file system|nvme.*(error|timeout|reset|failed)|ata[0-9.]*.*(error|failed|reset)|Out of memory|Killed process [0-9]+|Kernel panic|BUG:|general protection fault'

if ! command -v journalctl >/dev/null 2>&1; then
    printf 'journalctl is not installed.\n' >&2
    exit 1
fi

mkdir -p "$JOURNAL_STATE_DIR"
journal_args=(--dmesg --no-pager --output=short-iso --show-cursor)
if [[ -s "$CURSOR_FILE" ]]; then
    read -r previous_cursor <"$CURSOR_FILE"
    journal_args+=(--after-cursor "$previous_cursor")
else
    journal_args+=(--since "10 minutes ago")
fi

if ! journal_output=$(journalctl "${journal_args[@]}" 2>&1); then
    if [[ -s "$CURSOR_FILE" ]]; then
        journal_output=$(journalctl --dmesg --no-pager --output=short-iso \
            --show-cursor --since "10 minutes ago" 2>&1) || {
            printf 'Unable to read the kernel journal:\n%s\n' "$journal_output" >&2
            exit 1
        }
    else
        printf 'Unable to read the kernel journal:\n%s\n' "$journal_output" >&2
        exit 1
    fi
fi

cursor=$(sed -n 's/^-- cursor: //p' <<<"$journal_output" | tail -n 1)
if [[ -z "$cursor" ]]; then
    printf 'journalctl did not return a cursor; kernel events cannot be checkpointed safely.\n' >&2
    exit 1
fi

temporary_cursor=$(mktemp "$JOURNAL_STATE_DIR/journal.cursor.XXXXXX") || {
    printf 'Unable to create a temporary kernel-journal cursor.\n' >&2
    exit 1
}
printf '%s\n' "$cursor" >"$temporary_cursor"
mv -f "$temporary_cursor" "$CURSOR_FILE"

journal_entries=$(sed '/^-- cursor: /d' <<<"$journal_output")
matches=$(grep -Ei "$ERROR_PATTERN" <<<"$journal_entries" || true)
if [[ -n "$matches" ]]; then
    printf 'New kernel or filesystem errors were detected:\n%s\n' "$matches"
    exit 1
fi

printf 'No new kernel or filesystem errors were detected.\n'
