#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_ROOT="$(mktemp -d)"
readonly REMOTE="$TEST_ROOT/remote.git"
readonly SOURCE="$TEST_ROOT/source"
readonly INSTALLED="$TEST_ROOT/installed"
readonly STATE="$TEST_ROOT/state"
readonly NOTIFICATION_FILE="$TEST_ROOT/notifications"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

git init --quiet --bare "$REMOTE"
git init --quiet --initial-branch=main "$SOURCE"
git -C "$SOURCE" config user.name "Server Agent Test"
git -C "$SOURCE" config user.email "server-agent-test@example.invalid"
cp "$PROJECT_ROOT/server-agent.sh" "$SOURCE/server-agent.sh"
mkdir -p "$SOURCE/duties"
printf '#!/usr/bin/env bash\n' >"$SOURCE/duties/registry.sh"
chmod 0755 "$SOURCE/server-agent.sh"
git -C "$SOURCE" add server-agent.sh duties/registry.sh
git -C "$SOURCE" commit --quiet -m "Initial revision"
git -C "$SOURCE" remote add origin "$REMOTE"
git -C "$SOURCE" push --quiet --set-upstream origin main

git clone --quiet "$REMOTE" "$INSTALLED"
initial_revision=$(git -C "$INSTALLED" rev-parse HEAD)

mkdir -p "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$NOTIFICATION_LOG"
cat <&4 >>"$NOTIFICATION_LOG"
printf '\n' >>"$NOTIFICATION_LOG"
EOF
cat >"$TEST_ROOT/bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod 0755 "$TEST_ROOT/bin/curl" "$TEST_ROOT/bin/flock"

sed -i 's/No duties are registered/Successful trial/' \
    "$SOURCE/server-agent.sh"
git -C "$SOURCE" add server-agent.sh
git -C "$SOURCE" commit --quiet -m "Working update"
git -C "$SOURCE" push --quiet
working_revision=$(git -C "$SOURCE" rev-parse HEAD)

PATH="$TEST_ROOT/bin:$PATH" \
NOTIFICATION_LOG="$NOTIFICATION_FILE" \
NTFY_URL="https://ntfy.invalid/test" \
SERVER_AGENT_STATE_DIR="$STATE" \
SERVER_AGENT_LOCK_FILE="$TEST_ROOT/server-agent.lock" \
bash "$INSTALLED/server-agent.sh"

[[ "$(git -C "$INSTALLED" rev-parse HEAD)" == "$working_revision" ]] ||
    fail "the successful revision was not promoted"
grep -q "Server agent updating" "$NOTIFICATION_FILE" ||
    fail "the update-started notification was not sent"
grep -q "Server agent updated" "$NOTIFICATION_FILE" ||
    fail "the update-success notification was not sent"
[[ ! -d "$STATE/update-worktree" ]] ||
    fail "the successful update worktree was not removed"

cat >"$SOURCE/duties/healthy.sh" <<'EOF'
#!/usr/bin/env bash
printf 'Healthy duty output that must not appear in the failure notification.\n'
EOF
cat >"$SOURCE/duties/broken.sh" <<'EOF'
#!/usr/bin/env bash
printf 'Intentional trial failure.\n' >&2
exit 42
EOF
cat >"$SOURCE/duties/registry.sh" <<'EOF'
register_duty "healthy-check" 300 "5s" "never" "$SCRIPT_DIR/duties/healthy.sh"
register_duty "broken-check" 300 "5s" "never" "$SCRIPT_DIR/duties/broken.sh"
EOF
git -C "$SOURCE" add duties
git -C "$SOURCE" commit --quiet -m "Broken update"
git -C "$SOURCE" push --quiet

run_broken_update() {
    PATH="$TEST_ROOT/bin:$PATH" \
    NOTIFICATION_LOG="$NOTIFICATION_FILE" \
    NTFY_URL="https://ntfy.invalid/test" \
    SERVER_AGENT_STATE_DIR="$STATE" \
    SERVER_AGENT_LOCK_FILE="$TEST_ROOT/server-agent.lock" \
    bash "$INSTALLED/server-agent.sh"
}

if run_broken_update; then
    fail "the broken revision unexpectedly succeeded"
fi
[[ "$(git -C "$INSTALLED" rev-parse HEAD)" == "$working_revision" ]] ||
    fail "the broken revision replaced the working revision"
[[ "$(git -C "$INSTALLED" rev-parse HEAD)" != "$initial_revision" ]] ||
    fail "the prior successful update was unexpectedly rolled back"
grep -q "failed its trial run" "$NOTIFICATION_FILE" ||
    fail "the failed-update notification was not sent"
grep -q "Failed duties:" "$NOTIFICATION_FILE" ||
    fail "the failed-update notification did not identify its duty list"
grep -q -- "- broken-check" "$NOTIFICATION_FILE" ||
    fail "the failed-update notification did not list the failed duty"
if grep -q "healthy-check" "$NOTIFICATION_FILE"; then
    fail "the failed-update notification included a successful duty"
fi
[[ ! -d "$STATE/update-worktree" ]] ||
    fail "the failed update worktree was not removed"

failure_count=$(grep -c "failed its trial run" "$NOTIFICATION_FILE")
if run_broken_update; then
    fail "the broken revision unexpectedly succeeded on retry"
fi
[[ "$(grep -c "failed its trial run" "$NOTIFICATION_FILE")" -eq $((failure_count + 1)) ]] ||
    fail "the failed revision was not retried"

printf 'Integration test passed.\n'
