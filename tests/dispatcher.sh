#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_ROOT="$(mktemp -d)"
readonly NOTIFICATION_FILE="$TEST_ROOT/notifications"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

export SERVER_AGENT_STATE_DIR="$TEST_ROOT/state"
export SERVER_AGENT_DUTY_REGISTRY="$TEST_ROOT/registry.sh"
export DUTY_TEST_COUNT="$TEST_ROOT/count"
source "$PROJECT_ROOT/server-agent.sh"

notify() {
    printf '%s|%s|%s\n' "$1" "$2" "${3:-default}" >>"$NOTIFICATION_FILE"
}

cat >"$TEST_ROOT/success.sh" <<'EOF'
#!/usr/bin/env bash
count=0
[[ -f "$DUTY_TEST_COUNT" ]] && read -r count <"$DUTY_TEST_COUNT"
printf '%s\n' "$((count + 1))" >"$DUTY_TEST_COUNT"
printf 'Duty output.\n'
EOF

cat >"$TEST_ROOT/failure.sh" <<'EOF'
#!/usr/bin/env bash
printf 'Expected failure.\n' >&2
exit 42
EOF

cat >"$TEST_ROOT/slow.sh" <<'EOF'
#!/usr/bin/env bash
sleep 5
EOF

cat >"$SERVER_AGENT_DUTY_REGISTRY" <<EOF
register_duty "cadence-check" 3600 "5s" "never" "$TEST_ROOT/success.sh"
EOF

run_duties
run_duties
[[ "$(cat "$DUTY_TEST_COUNT")" == "1" ]] ||
    fail "a duty ran again before its cadence elapsed"

SERVER_AGENT_FORCE_DUTIES=1 run_duties
[[ "$(cat "$DUTY_TEST_COUNT")" == "2" ]] ||
    fail "a forced duty run was skipped"

cat >"$SERVER_AGENT_DUTY_REGISTRY" <<EOF
register_duty "change-check" 3600 "5s" "on-change" "$TEST_ROOT/failure.sh"
EOF

if SERVER_AGENT_FORCE_DUTIES=1 run_duties; then
    fail "a failed duty returned success"
fi
[[ "$(grep -c "Duty failed: change-check" "$NOTIFICATION_FILE")" == "1" ]] ||
    fail "the first failure did not send one notification"

if SERVER_AGENT_FORCE_DUTIES=1 run_duties; then
    fail "a repeatedly failed duty returned success"
fi
[[ "$(grep -c "Duty failed: change-check" "$NOTIFICATION_FILE")" == "1" ]] ||
    fail "an unchanged failure sent another on-change notification"

cat >"$SERVER_AGENT_DUTY_REGISTRY" <<EOF
register_duty "change-check" 3600 "5s" "on-change" "$TEST_ROOT/success.sh"
EOF
SERVER_AGENT_FORCE_DUTIES=1 run_duties
[[ "$(grep -c "Duty healthy: change-check" "$NOTIFICATION_FILE")" == "1" ]] ||
    fail "recovery did not send a notification"

cat >"$SERVER_AGENT_DUTY_REGISTRY" <<EOF
register_duty "timeout-check" 3600 "1s" "on-failure" "$TEST_ROOT/slow.sh"
EOF
if SERVER_AGENT_FORCE_DUTIES=1 run_duties; then
    fail "a timed-out duty returned success"
fi
grep -q "Timed out after 1s" "$NOTIFICATION_FILE" ||
    fail "the timeout notification did not explain the failure"

cat >"$SERVER_AGENT_DUTY_REGISTRY" <<EOF
register_duty "invalid-check" 0 "5s" "never" "$TEST_ROOT/success.sh"
register_duty "valid-check" 3600 "5s" "never" "$TEST_ROOT/success.sh"
EOF
if run_duties; then
    fail "an invalid registry returned success"
fi

printf 'Dispatcher test passed.\n'
