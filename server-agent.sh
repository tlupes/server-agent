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
readonly DUTY_STATE_DIR="$STATE_DIR/duties"
readonly DUTY_REGISTRY="${SERVER_AGENT_DUTY_REGISTRY:-$SCRIPT_DIR/duties/registry.sh}"

declare -a DUTY_NAMES=()
declare -A DUTY_CADENCES=()
declare -A DUTY_TIMEOUTS=()
declare -A DUTY_POLICIES=()
declare -A DUTY_HANDLERS=()
DUTY_REGISTRY_ERRORS=0

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

register_duty() {
    local name=$1
    local cadence_seconds=$2
    local timeout_duration=$3
    local notification_policy=$4
    local handler=$5

    if [[ ! "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
        log "Invalid duty name '$name'; use lowercase letters, numbers, and hyphens."
        DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
        return 1
    fi
    if [[ -n "${DUTY_CADENCES[$name]+registered}" ]]; then
        log "Duty '$name' is registered more than once."
        DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
        return 1
    fi
    if [[ ! "$cadence_seconds" =~ ^[1-9][0-9]*$ &&
        "$cadence_seconds" != "daily" &&
        ! "$cadence_seconds" =~ ^weekly-(monday|tuesday|wednesday|thursday|friday|saturday|sunday)$ ]]; then
        log "Duty '$name' has an invalid cadence: $cadence_seconds"
        DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
        return 1
    fi
    if [[ ! "$timeout_duration" =~ ^[1-9][0-9]*(s|m|h|d)$ ]]; then
        log "Duty '$name' has an invalid timeout: $timeout_duration"
        DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
        return 1
    fi
    case "$notification_policy" in
        always | on-failure | on-change | on-failure-recovery | never) ;;
        *)
            log "Duty '$name' has an invalid notification policy: $notification_policy"
            DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
            return 1
            ;;
    esac
    if [[ ! -f "$handler" ]]; then
        log "Duty '$name' handler does not exist: $handler"
        DUTY_REGISTRY_ERRORS=$((DUTY_REGISTRY_ERRORS + 1))
        return 1
    fi

    DUTY_NAMES+=("$name")
    DUTY_CADENCES["$name"]=$cadence_seconds
    DUTY_TIMEOUTS["$name"]=$timeout_duration
    DUTY_POLICIES["$name"]=$notification_policy
    DUTY_HANDLERS["$name"]=$handler
}

load_duty_registry() {
    local source_result

    DUTY_NAMES=()
    DUTY_CADENCES=()
    DUTY_TIMEOUTS=()
    DUTY_POLICIES=()
    DUTY_HANDLERS=()
    DUTY_REGISTRY_ERRORS=0

    if [[ ! -f "$DUTY_REGISTRY" ]]; then
        log "Duty registry does not exist: $DUTY_REGISTRY"
        return 1
    fi

    # shellcheck source=/dev/null
    if source "$DUTY_REGISTRY"; then
        source_result=0
    else
        source_result=$?
    fi

    if ((source_result != 0 || DUTY_REGISTRY_ERRORS != 0)); then
        log "Duty registry validation failed with $DUTY_REGISTRY_ERRORS invalid declaration(s)."
        return 1
    fi
}

write_duty_state() {
    local destination=$1
    local value=$2
    local temporary

    temporary=$(mktemp "$destination.XXXXXX") || return 1
    if ! printf '%s\n' "$value" >"$temporary" || ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 1
    fi
}

weekday_number() {
    case "$1" in
        monday) printf '1\n' ;;
        tuesday) printf '2\n' ;;
        wednesday) printf '3\n' ;;
        thursday) printf '4\n' ;;
        friday) printf '5\n' ;;
        saturday) printf '6\n' ;;
        sunday) printf '7\n' ;;
    esac
}

duty_is_due() {
    local name=$1
    local last_run_file="$DUTY_STATE_DIR/$name.last-run"
    local cadence=${DUTY_CADENCES[$name]}
    local now last_run today last_run_day weekday scheduled_weekday

    if [[ "${SERVER_AGENT_FORCE_DUTIES:-0}" == "1" || ! -f "$last_run_file" ]]; then
        if [[ "$cadence" == weekly-* && "${SERVER_AGENT_FORCE_DUTIES:-0}" != "1" ]]; then
            scheduled_weekday=$(weekday_number "${cadence#weekly-}")
            weekday=$(date +%u)
            [[ "$weekday" == "$scheduled_weekday" ]]
            return
        fi
        return 0
    fi

    now=$(date +%s)
    read -r last_run <"$last_run_file" || return 0
    if [[ ! "$last_run" =~ ^[0-9]+$ || "$now" -lt "$last_run" ]]; then
        return 0
    fi

    case "$cadence" in
        daily)
            today=$(date +%F)
            last_run_day=$(date --date="@$last_run" +%F) || return 0
            [[ "$today" != "$last_run_day" ]]
            ;;
        weekly-*)
            scheduled_weekday=$(weekday_number "${cadence#weekly-}")
            weekday=$(date +%u)
            [[ "$weekday" == "$scheduled_weekday" ]] || return 1
            today=$(date +%F)
            last_run_day=$(date --date="@$last_run" +%F) || return 0
            [[ "$today" != "$last_run_day" ]]
            ;;
        *)
            ((now - last_run >= cadence))
            ;;
    esac
}

notify_for_duty_result() {
    local name=$1
    local result=$2
    local previous_result=$3
    local details=$4
    local policy=${DUTY_POLICIES[$name]}
    local should_notify=0
    local result_kind=${result%%:*}

    if [[ "${SERVER_AGENT_SUPPRESS_DUTY_NOTIFICATIONS:-0}" == "1" ]]; then
        return
    fi

    case "$policy" in
        always)
            should_notify=1
            ;;
        on-failure)
            [[ "$result_kind" == "failure" ]] && should_notify=1
            ;;
        on-change)
            if [[ "$result" != "$previous_result" &&
                ("$result_kind" == "failure" || "$previous_result" == failure:*) ]]; then
                should_notify=1
            fi
            ;;
        on-failure-recovery)
            if [[ "$result_kind" == "failure" ||
                ("$result" == "success" && "$previous_result" == failure:*) ]]; then
                should_notify=1
            fi
            ;;
        never)
            return
            ;;
    esac

    if ((should_notify == 0)); then
        return
    fi

    if [[ "$result_kind" == "failure" ]]; then
        notify "Duty failed: $name" "${details:-The duty exited unsuccessfully without output.}" "high" || true
    else
        notify "Duty healthy: $name" "${details:-The duty completed successfully.}" || true
    fi
}

run_duty() {
    local name=$1
    local output_file previous_result="" result exit_code details now
    local last_run_file="$DUTY_STATE_DIR/$name.last-run"
    local status_file="$DUTY_STATE_DIR/$name.status"

    if ! duty_is_due "$name"; then
        return
    fi

    output_file=$(mktemp "$DUTY_STATE_DIR/$name.output.XXXXXX") || {
        log "Unable to create an output file for duty '$name'."
        return 1
    }

    log "Running duty '$name' (timeout ${DUTY_TIMEOUTS[$name]})."
    if timeout --signal=TERM --kill-after=5s "${DUTY_TIMEOUTS[$name]}" \
        bash "${DUTY_HANDLERS[$name]}" >"$output_file" 2>&1; then
        exit_code=0
        result="success"
    else
        exit_code=$?
        result="failure:$exit_code"
    fi

    details=$(tail -c 3000 "$output_file")
    rm -f "$output_file"
    if ((exit_code == 124)); then
        details="Timed out after ${DUTY_TIMEOUTS[$name]}.
${details}"
    fi
    [[ -f "$status_file" ]] && read -r previous_result <"$status_file"

    now=$(date +%s)
    if ! write_duty_state "$last_run_file" "$now" ||
        ! write_duty_state "$status_file" "$result"; then
        log "Unable to persist state for duty '$name'."
        return 1
    fi

    notify_for_duty_result "$name" "$result" "$previous_result" "$details"
    if [[ "$result" == failure:* ]]; then
        if ((exit_code == 124)); then
            log "Duty '$name' timed out after ${DUTY_TIMEOUTS[$name]}."
        else
            log "Duty '$name' failed with exit code $exit_code: ${details:-no output}"
        fi
        return 1
    fi

    log "Duty '$name' completed successfully."
}

run_duties() {
    local name
    local failures=0

    if ! load_duty_registry; then
        return 1
    fi
    if ((${#DUTY_NAMES[@]} == 0)); then
        log "No duties are registered."
        return
    fi

    mkdir -p "$DUTY_STATE_DIR"
    for name in "${DUTY_NAMES[@]}"; do
        if ! run_duty "$name"; then
            failures=$((failures + 1))
        fi
    done

    ((failures == 0))
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
        SERVER_AGENT_STATE_DIR="$UPDATE_WORKTREE/.server-agent-state" \
        SERVER_AGENT_LOCK_FILE="$LOCK_FILE" \
        SERVER_AGENT_REMOTE="$REMOTE" \
        SERVER_AGENT_BRANCH="$BRANCH" \
        SERVER_AGENT_TRIAL_TIMEOUT="$TRIAL_TIMEOUT" \
        SERVER_AGENT_NTFY_TIMEOUT="$NTFY_TIMEOUT" \
        SERVER_AGENT_FORCE_DUTIES=1 \
        SERVER_AGENT_SUPPRESS_DUTY_NOTIFICATIONS=1 \
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
