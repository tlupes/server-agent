#!/usr/bin/env bash

set -uo pipefail

readonly SCRIPT_NAME="server-agent"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="${SERVER_AGENT_REPO_ROOT:-$SCRIPT_DIR}"
readonly STATE_DIR="${SERVER_AGENT_STATE_DIR:-/var/lib/server-agent}"
readonly LOCK_FILE="${SERVER_AGENT_LOCK_FILE:-/run/lock/server-agent.lock}"
readonly REMOTE="${SERVER_AGENT_REMOTE:-origin}"
readonly TRIAL_TIMEOUT="${SERVER_AGENT_TRIAL_TIMEOUT:-240s}"
readonly NTFY_TIMEOUT="${SERVER_AGENT_NTFY_TIMEOUT:-15}"
readonly UPDATE_WORKTREE="$STATE_DIR/update-worktree"

log() {
    printf '%s [%s] %s\n' "$(date --iso-8601=seconds)" "$SCRIPT_NAME" "$*" >&2
}

notification_text() {
    local text=$1
    text=${text//$'\r'/}
    printf '%.3000s' "$text"
}

notify() {
    local title=$1
    local message=$2
    local priority=${3:-default}
    local sanitized_message
    local -a curl_args=(
        --silent
        --show-error
        --fail-with-body
        --max-time "$NTFY_TIMEOUT"
        --request POST
        --header "Title: $title"
        --header "Priority: $priority"
        --data-binary @/dev/fd/4
    )

    if [[ -z "${NTFY_URL:-}" ]]; then
        log "Notification not sent because NTFY_URL is not configured: $title"
        return 1
    fi

    sanitized_message=$(notification_text "$message")
    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        if ! curl "${curl_args[@]}" --header @/dev/fd/3 "$NTFY_URL" \
            3<<<"Authorization: Bearer $NTFY_TOKEN" \
            4<<<"$sanitized_message" >/dev/null; then
            log "Failed to send ntfy notification: $title"
            return 1
        fi
    elif ! curl "${curl_args[@]}" "$NTFY_URL" \
        4<<<"$sanitized_message" >/dev/null; then
        log "Failed to send ntfy notification: $title"
        return 1
    fi
}

notify_failure() {
    local summary=$1
    local details=$2
    notify "Server agent failed" "$summary

$(notification_text "$details")" "high" || true
}

run_duties() {
    # Add periodic host maintenance duties here. A trial update must complete all
    # duties successfully before the new revision is promoted.
    log "No periodic duties are configured yet."
}

repo_git() {
    git -c "safe.directory=$REPO_ROOT" -C "$REPO_ROOT" "$@"
}

remove_update_worktree() {
    if [[ -d "$UPDATE_WORKTREE" ]]; then
        repo_git worktree remove --force "$UPDATE_WORKTREE" >/dev/null 2>&1 || true
    fi
    repo_git worktree prune >/dev/null 2>&1 || true
}

run_trial_revision() {
    local output_file=$1

    if [[ ! -f "$UPDATE_WORKTREE/server-agent.sh" ]]; then
        printf 'The target revision does not contain server-agent.sh.\n' >"$output_file"
        return 1
    fi

    timeout --signal=TERM --kill-after=10s "$TRIAL_TIMEOUT" \
        env \
        SERVER_AGENT_TRIAL=1 \
        SERVER_AGENT_REPO_ROOT="$UPDATE_WORKTREE" \
        SERVER_AGENT_STATE_DIR="$STATE_DIR" \
        SERVER_AGENT_LOCK_FILE="$LOCK_FILE" \
        SERVER_AGENT_REMOTE="$REMOTE" \
        SERVER_AGENT_BRANCH="$BRANCH" \
        SERVER_AGENT_TRIAL_TIMEOUT="$TRIAL_TIMEOUT" \
        SERVER_AGENT_NTFY_TIMEOUT="$NTFY_TIMEOUT" \
        bash "$UPDATE_WORKTREE/server-agent.sh" >"$output_file" 2>&1
}

update_and_run() {
    local current_revision target_revision output_file failure_details

    mkdir -p "$STATE_DIR"
    output_file=$(mktemp "$STATE_DIR/git-output.XXXXXX") || {
        notify_failure "Unable to create a temporary output file." "$STATE_DIR"
        return 1
    }

    if ! repo_git fetch --quiet "$REMOTE" "$BRANCH" 2>"$output_file"; then
        failure_details=$(tail -c 3000 "$output_file")
        rm -f "$output_file"
        notify_failure "Unable to check for an update." \
            "${failure_details:-git fetch $REMOTE $BRANCH failed in $REPO_ROOT.}"
        return 1
    fi
    rm -f "$output_file"

    if ! current_revision=$(repo_git rev-parse HEAD 2>&1); then
        notify_failure "Unable to identify the installed revision." "$current_revision"
        return 1
    fi

    if ! target_revision=$(repo_git rev-parse FETCH_HEAD 2>&1); then
        notify_failure "Unable to identify the fetched revision." "$target_revision"
        return 1
    fi

    if [[ "$current_revision" == "$target_revision" ]]; then
        run_duties
        return
    fi

    if ! repo_git merge-base --is-ancestor "$current_revision" "$target_revision"; then
        notify_failure "The update was rejected because it is not fast-forward." \
            "Installed: $current_revision
Fetched:   $target_revision"
        return 1
    fi

    if [[ -n "$(repo_git status --porcelain)" ]]; then
        notify_failure "The update was rejected because the installed checkout has local changes." \
            "Commit or discard the changes in $REPO_ROOT."
        return 1
    fi

    notify "Server agent updating" \
        "Testing update ${current_revision:0:12} -> ${target_revision:0:12}." || true

    remove_update_worktree
    output_file=$(mktemp "$STATE_DIR/git-output.XXXXXX") || {
        notify_failure "Unable to create a temporary output file." "$STATE_DIR"
        return 1
    }
    if ! repo_git worktree add --quiet --detach \
        "$UPDATE_WORKTREE" "$target_revision" 2>"$output_file"; then
        failure_details=$(tail -c 3000 "$output_file")
        rm -f "$output_file"
        notify_failure "Unable to create the update worktree." \
            "${failure_details:-Target: $target_revision
Path: $UPDATE_WORKTREE}"
        return 1
    fi
    rm -f "$output_file"

    trap remove_update_worktree EXIT
    output_file=$(mktemp "$STATE_DIR/trial-output.XXXXXX") || {
        remove_update_worktree
        trap - EXIT
        notify_failure "Unable to create a temporary trial output file." "$STATE_DIR"
        return 1
    }

    if ! run_trial_revision "$output_file"; then
        failure_details=$(tail -c 3000 "$output_file")
        rm -f "$output_file"
        remove_update_worktree
        trap - EXIT
        notify_failure "Update ${target_revision:0:12} failed its trial run; the installed revision was kept." \
            "${failure_details:-The trial exited unsuccessfully without output.}"
        return 1
    fi

    rm -f "$output_file"
    remove_update_worktree
    trap - EXIT

    output_file=$(mktemp "$STATE_DIR/git-output.XXXXXX") || {
        notify_failure "Unable to create a temporary output file." "$STATE_DIR"
        return 1
    }
    if ! repo_git merge --quiet --ff-only \
        "$target_revision" 2>"$output_file"; then
        failure_details=$(tail -c 3000 "$output_file")
        rm -f "$output_file"
        notify_failure "The update passed its trial but could not be installed." \
            "${failure_details:-The installed checkout remains at ${current_revision:0:12}.}"
        return 1
    fi
    rm -f "$output_file"

    notify "Server agent updated" \
        "Successfully installed revision ${target_revision:0:12}." || true
}

main() {
    if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
        run_duties
        return
    fi

    for command in curl git timeout flock; do
        if ! command -v "$command" >/dev/null 2>&1; then
            log "Required command is missing: $command"
            return 1
        fi
    done

    mkdir -p "$STATE_DIR" "$(dirname -- "$LOCK_FILE")"
    exec 9>"$LOCK_FILE"
    if ! flock --nonblock 9; then
        log "Another invocation is still running; skipping this run."
        return
    fi

    if ! repo_git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        notify_failure "The configured repository is not a Git worktree." "$REPO_ROOT"
        return 1
    fi

    BRANCH="${SERVER_AGENT_BRANCH:-$(repo_git branch --show-current)}"
    if [[ -z "$BRANCH" ]]; then
        notify_failure "Unable to determine the update branch." \
            "Set SERVER_AGENT_BRANCH in the environment file."
        return 1
    fi
    readonly BRANCH

    update_and_run
}

main "$@"
