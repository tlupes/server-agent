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

cat >"$BIN_DIR/df" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--inodes"* ]]; then
    printf 'IUse%% Mounted on\n%s%% /\n' "${INODE_PERCENT:-1}"
else
    printf 'Use%% Mounted on\n%s%% /\n' "${SPACE_PERCENT:-1}"
fi
EOF

SPACE_PERCENT=80 INODE_PERCENT=1 expect_status 80 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
SPACE_PERCENT=90 INODE_PERCENT=1 expect_status 90 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
SPACE_PERCENT=95 INODE_PERCENT=1 expect_status 95 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"
SPACE_PERCENT=1 INODE_PERCENT=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/filesystem-capacity.sh"

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

cat >"$BIN_DIR/apt-get" <<'EOF'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >>"$COMMAND_LOG"
EOF
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
expect_status 0 bash "$PROJECT_ROOT/duties/security-updates.sh"
grep -q "apt-get update" "$COMMAND_LOG" ||
    fail "the security updater did not refresh APT metadata"
grep -q "unattended-upgrade --verbose" "$COMMAND_LOG" ||
    fail "the security updater did not apply updates"

printf 'Duty tests passed.\n'
