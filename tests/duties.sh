#!/usr/bin/env bash

set -euo pipefail

readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
readonly TEST_ROOT="$(mktemp -d)"
readonly BIN_DIR="$TEST_ROOT/bin"
readonly OUTPUT_FILE="$TEST_ROOT/output"
readonly COMMAND_LOG="$TEST_ROOT/commands"

cleanup() {
    rm -rf -- "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_status() {
    local expected=$1
    shift
    local actual

    set +e
    "$@" >"$OUTPUT_FILE" 2>&1
    actual=$?
    set -e
    [[ "$actual" -eq "$expected" ]] ||
        fail "expected exit $expected, got $actual from: $*"
}

mkdir -p "$BIN_DIR" "$TEST_ROOT/project"
touch "$TEST_ROOT/project/compose.yml"
export PATH="$BIN_DIR:$PATH"
export COMMAND_LOG
export TEST_ROOT

cat >"$BIN_DIR/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${APT_LOCK_ONCE:-0}" == "1" && "$*" == *"update"* &&
    ! -f "$TEST_ROOT/apt-lock-retried" ]]; then
    touch "$TEST_ROOT/apt-lock-retried"
    printf 'Could not get lock /var/lib/apt/lists/lock. It is held by another process.\n' >&2
    exit 100
fi
EOF
cat >"$BIN_DIR/systemd-tmpfiles" <<'EOF'
#!/usr/bin/env bash
printf 'systemd-tmpfiles %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$BIN_DIR/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$COMMAND_LOG"
EOF
cat >"$BIN_DIR/lslocks" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN_DIR/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$BIN_DIR/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$COMMAND_LOG"
exit 0
EOF
cat >"$BIN_DIR/df" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--inodes"* ]]; then
    if [[ "$*" == *"--output"* ]]; then
        printf 'df: options -i and --output are mutually exclusive\n' >&2
        exit 1
    fi
    printf 'Filesystem Inodes IUsed IFree IUse%% Mounted on\n'
    printf '/dev/test 1000 %s 999 %s%% /\n' "${INODE_PERCENT:-1}" "${INODE_PERCENT:-1}"
else
    printf 'Use%% Mounted on\n%s%% /\n' "${SPACE_PERCENT:-1}"
fi
EOF

: >"$COMMAND_LOG"
SPACE_PERCENT=80 INODE_PERCENT=1 expect_status 80 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
grep -q "DPkg::Lock::Timeout=300 clean" "$COMMAND_LOG" ||
    fail "the 80% cleanup did not clear the APT cache"
grep -q "systemd-tmpfiles --clean" "$COMMAND_LOG" ||
    fail "the 80% cleanup did not invoke policy-managed temporary cleanup"
if grep -q "docker image prune" "$COMMAND_LOG"; then
    fail "the 80% cleanup pruned Docker images too early"
fi

: >"$COMMAND_LOG"
SPACE_PERCENT=90 INODE_PERCENT=1 expect_status 90 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
grep -q "docker image prune --force" "$COMMAND_LOG" ||
    fail "the 90% cleanup did not prune dangling Docker images"
grep -q "until=168h" "$COMMAND_LOG" ||
    fail "the 90% cleanup did not prune old Docker build cache"
grep -q "journalctl --vacuum-time=30d" "$COMMAND_LOG" ||
    fail "the 90% cleanup did not vacuum old journals"

: >"$COMMAND_LOG"
SPACE_PERCENT=95 INODE_PERCENT=1 expect_status 95 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
grep -q "until=24h" "$COMMAND_LOG" ||
    fail "the 95% cleanup did not prune unused build cache older than one day"
grep -q "journalctl --vacuum-time=7d --vacuum-size=500M" "$COMMAND_LOG" ||
    fail "the 95% cleanup did not enforce the emergency journal limits"

: >"$COMMAND_LOG"
SPACE_PERCENT=1 INODE_PERCENT=90 expect_status 90 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
SPACE_PERCENT=1 INODE_PERCENT=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"

: >"$COMMAND_LOG"
SPACE_PERCENT=95 INODE_PERCENT=1 SERVER_AGENT_TRIAL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
[[ ! -s "$COMMAND_LOG" ]] ||
    fail "the filesystem trial performed cleanup mutations"

cat >"$BIN_DIR/docker" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    info)
        exit 0
        ;;
    ps)
        printf 'container-id\n'
        ;;
    inspect)
        printf '%s\n' "${DOCKER_INSPECT:-/app|running|healthy|<no value>}"
        ;;
    compose)
        if [[ "${2:-}" == "version" ]]; then
            exit 0
        fi
        printf '%s\n' "$*" >>"$COMMAND_LOG"
        ;;
esac
EOF

DOCKER_INSPECT='/app|running|healthy|<no value>' expect_status 0 \
    bash "$PROJECT_ROOT/duties/docker-health.sh"
DOCKER_INSPECT='/app|running|unhealthy|<no value>' expect_status 1 \
    bash "$PROJECT_ROOT/duties/docker-health.sh"
grep -q "unhealthy" "$OUTPUT_FILE" ||
    fail "Docker health failure did not identify the unhealthy container"

cat >"$BIN_DIR/smartctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--scan-open" ]]; then
    printf '/dev/sda -d sat # test disk\n'
elif [[ "${SMART_FAIL:-0}" == "1" ]]; then
    printf 'SMART overall-health failed.\n' >&2
    exit 8
else
    printf 'SMART overall-health passed.\n'
fi
EOF

SMART_FAIL=0 expect_status 0 bash "$PROJECT_ROOT/duties/disk-health.sh"
SMART_FAIL=1 expect_status 1 bash "$PROJECT_ROOT/duties/disk-health.sh"

compose_details="/app|example|$TEST_ROOT/project|compose.yml"
: >"$COMMAND_LOG"
DOCKER_INSPECT="$compose_details" SERVER_AGENT_TRIAL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/image-updates.sh"
[[ ! -s "$COMMAND_LOG" ]] ||
    fail "the image update trial invoked Docker Compose mutations"

DOCKER_INSPECT="$compose_details" expect_status 0 \
    bash "$PROJECT_ROOT/duties/image-updates.sh"
grep -q "compose .* pull" "$COMMAND_LOG" ||
    fail "the image updater did not pull Compose images"
grep -q "compose .* up --detach" "$COMMAND_LOG" ||
    fail "the image updater did not recreate the Compose project"

DOCKER_INSPECT='/standalone|<no value>|<no value>|<no value>' expect_status 1 \
    bash "$PROJECT_ROOT/duties/image-updates.sh"
grep -q "not managed by Docker Compose" "$OUTPUT_FILE" ||
    fail "the image updater did not reject an unmanaged container"

cat >"$BIN_DIR/unattended-upgrade" <<'EOF'
#!/usr/bin/env bash
printf 'unattended-upgrade %s\n' "$*" >>"$COMMAND_LOG"
EOF

: >"$COMMAND_LOG"
SERVER_AGENT_TRIAL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/security-updates.sh"
if grep -q "apt-get update" "$COMMAND_LOG"; then
    fail "the security update trial refreshed or changed packages"
fi

: >"$COMMAND_LOG"
rm -f "$TEST_ROOT/apt-lock-retried"
APT_LOCK_ONCE=1 expect_status 0 bash "$PROJECT_ROOT/duties/security-updates.sh"
[[ "$(grep -c "Acquire::Retries=3 .*update" "$COMMAND_LOG")" == "2" ]] ||
    fail "the security updater did not retry an APT lists-lock race"
grep -q "DPkg::Lock::Timeout=600 .*Acquire::Retries=3 .*update" "$COMMAND_LOG" ||
    fail "the security updater did not refresh APT metadata"
grep -q "unattended-upgrade --verbose" "$COMMAND_LOG" ||
    fail "the security updater did not apply updates"

printf 'Duty tests passed.\n'
