#!/usr/bin/env bash

duty_notify() {
    local title=$1
    local message=$2
    local priority=${3:-default}
    local sanitized_message=${message//$'\r'/}
    local -a curl_args=(
        --silent
        --show-error
        --fail-with-body
        --max-time "${SERVER_AGENT_NTFY_TIMEOUT:-15}"
        --request POST
        --header "Title: $title"
        --header "Priority: $priority"
        --data-binary @/dev/fd/4
    )

    if [[ -z "${NTFY_URL:-}" ]]; then
        printf 'NTFY_URL is not configured; refusing an unannounced reboot.\n' >&2
        return 1
    fi

    if [[ -n "${NTFY_TOKEN:-}" ]]; then
        curl "${curl_args[@]}" --header @/dev/fd/3 "$NTFY_URL" \
            3<<<"Authorization: Bearer $NTFY_TOKEN" \
            4<<<"${sanitized_message:0:3000}" >/dev/null
    else
        curl "${curl_args[@]}" "$NTFY_URL" \
            4<<<"${sanitized_message:0:3000}" >/dev/null
    fi
}
