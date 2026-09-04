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

grep -q 'register_duty "filesystem-capacity" 300 "20m"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the filesystem cleanup timeout is too short"
grep -q 'register_duty "docker-log-growth" 3600 "30s"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the Docker log-growth duty is not registered hourly"
grep -q 'register_duty "kernel-filesystem-errors" 300 "30s"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the kernel/filesystem error duty is not registered every five minutes"
grep -q 'register_duty "network-mounts" 300 "4m" "on-failure-recovery"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the network-mount duty does not retry every five minutes"
grep -q 'register_duty "reboot-required" "daily-at-02:00" "2m" "on-failure"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the reboot duty is not scheduled for 02:00"
grep -q 'register_duty "weekly-host-report" "weekly-sunday" "2m" "always"' \
    "$PROJECT_ROOT/duties/registry.sh" ||
    fail "the weekly host report is not scheduled for Sunday"

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
    printf 'efivarfs 0 0 0 - /sys/firmware/efi/efivars\n'
    if [[ "${*: -1}" != "/" ]]; then
        printf '/dev/media 1000 990 10 99%% /media/archive\n'
    fi
else
    printf 'Use%% Mounted on\n%s%% /\n' "${SPACE_PERCENT:-1}"
    if [[ "${*: -1}" != "/" ]]; then
        printf '99%% /media/archive\n'
    fi
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
grep -q "root filesystem is below 80%" "$OUTPUT_FILE" ||
    fail "the filesystem check was influenced by a separate /media mount"

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
        if [[ "$*" == *".LogPath"* ]]; then
            printf '%s\n' "${DOCKER_LOG_DETAILS:-/app|<no value>|json-file|<no value>}"
        else
            printf '%s\n' "${DOCKER_INSPECT:-/app|running|healthy|<no value>}"
        fi
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

docker_log="$TEST_ROOT/container-json.log"
truncate -s 400M "$docker_log"
DOCKER_LOG_DETAILS="/app|$docker_log|json-file|10m" expect_status 0 \
    bash "$PROJECT_ROOT/duties/docker-log-growth.sh"
truncate -s 600M "$docker_log"
DOCKER_LOG_DETAILS="/app|$docker_log|json-file|10m" expect_status 80 \
    bash "$PROJECT_ROOT/duties/docker-log-growth.sh"
grep -q "warning threshold 500 MB" "$OUTPUT_FILE" ||
    fail "Docker log growth did not report its warning threshold"
truncate -s 1100M "$docker_log"
DOCKER_LOG_DETAILS="/app|$docker_log|json-file|10m" expect_status 95 \
    bash "$PROJECT_ROOT/duties/docker-log-growth.sh"
grep -q "critical threshold 1024 MB" "$OUTPUT_FILE" ||
    fail "Docker log growth did not escalate at 1 GB"

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

cat >"$BIN_DIR/journalctl" <<'EOF'
#!/usr/bin/env bash
printf 'journalctl %s\n' "$*" >>"$COMMAND_LOG"
[[ -n "${KERNEL_JOURNAL:-}" ]] && printf '%s\n' "$KERNEL_JOURNAL"
[[ "${OMIT_JOURNAL_CURSOR:-0}" == "1" ]] ||
    printf '%s\n' '-- cursor: test-cursor'
EOF

kernel_state="$TEST_ROOT/kernel-state"
: >"$COMMAND_LOG"
OMIT_JOURNAL_CURSOR=1 KERNEL_JOURNAL='' \
SERVER_AGENT_STATE_DIR="$kernel_state" expect_status 0 \
    bash "$PROJECT_ROOT/duties/kernel-filesystem-errors.sh"
grep -q "no journal cursor was available yet" "$OUTPUT_FILE" ||
    fail "an empty first journal scan without a cursor was treated as a failure"

: >"$COMMAND_LOG"
KERNEL_JOURNAL='Sep 04 kernel: EXT4-fs error (device sda2): test failure' \
SERVER_AGENT_STATE_DIR="$kernel_state" expect_status 1 \
    bash "$PROJECT_ROOT/duties/kernel-filesystem-errors.sh"
grep -q "EXT4-fs error" "$OUTPUT_FILE" ||
    fail "the kernel duty did not report a filesystem error"

: >"$COMMAND_LOG"
KERNEL_JOURNAL='' SERVER_AGENT_STATE_DIR="$kernel_state" expect_status 0 \
    bash "$PROJECT_ROOT/duties/kernel-filesystem-errors.sh"
grep -q -- "--after-cursor test-cursor" "$COMMAND_LOG" ||
    fail "the kernel duty did not resume after its persisted journal cursor"
grep -q "No new kernel or filesystem errors" "$OUTPUT_FILE" ||
    fail "the kernel duty did not recover after processing the error"

cat >"$BIN_DIR/findmnt" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"--fstab"* ]]; then
    printf '/hillbox/media nfs defaults\n'
elif [[ "$*" == *"--mountpoint"* ]]; then
    [[ -f "$TEST_ROOT/network-mounted" ]] || exit 1
    if [[ "$*" == *"FSTYPE"* ]]; then
        printf 'nfs\n'
    else
        printf '/hillbox/media\n'
    fi
fi
EOF
cat >"$BIN_DIR/mount" <<'EOF'
#!/usr/bin/env bash
printf 'mount %s\n' "$*" >>"$COMMAND_LOG"
if [[ "${NETWORK_MOUNT_FAIL:-0}" == "1" ]]; then
    printf 'Network server is unavailable.\n' >&2
    exit 32
fi
touch "$TEST_ROOT/network-mounted"
EOF
cat >"$BIN_DIR/umount" <<'EOF'
#!/usr/bin/env bash
rm -f "$TEST_ROOT/network-mounted"
EOF
cat >"$BIN_DIR/stat" <<'EOF'
#!/usr/bin/env bash
[[ -f "$TEST_ROOT/network-mounted" ]]
EOF
cat >"$BIN_DIR/mkdir" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"/hillbox"* ]]; then
    exit 0
fi
command -p mkdir "$@"
EOF

rm -f "$TEST_ROOT/network-mounted"
: >"$COMMAND_LOG"
NETWORK_MOUNT_FAIL=1 expect_status 1 \
    bash "$PROJECT_ROOT/duties/network-mounts.sh"
grep -q "not mounted and mount attempt failed" "$OUTPUT_FILE" ||
    fail "a failed network mount did not explain the failure"

NETWORK_MOUNT_FAIL=0 expect_status 0 \
    bash "$PROJECT_ROOT/duties/network-mounts.sh"
grep -q "Successfully mounted network filesystems" "$OUTPUT_FILE" ||
    fail "a recovered network mount did not report success"

NETWORK_MOUNT_FAIL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/network-mounts.sh"
grep -q "mounted and responsive" "$OUTPUT_FILE" ||
    fail "a healthy network mount was unnecessarily remounted"

rm -f "$TEST_ROOT/network-mounted"
: >"$COMMAND_LOG"
NETWORK_MOUNT_FAIL=1 SERVER_AGENT_TRIAL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/network-mounts.sh"
[[ ! -s "$COMMAND_LOG" ]] ||
    fail "a candidate trial attempted to change network mounts"

cat >"$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$COMMAND_LOG"
cat <&4 >>"$COMMAND_LOG"
printf '\n' >>"$COMMAND_LOG"
EOF
cat >"$BIN_DIR/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$COMMAND_LOG"
EOF

reboot_required="$TEST_ROOT/reboot-required"
reboot_packages="$TEST_ROOT/reboot-required.pkgs"
printf 'linux-image-test\nlibc-test\n' >"$reboot_packages"
touch "$reboot_required"

: >"$COMMAND_LOG"
NTFY_URL=https://ntfy.invalid/test \
SERVER_AGENT_REBOOT_REQUIRED_FILE="$reboot_required" \
SERVER_AGENT_REBOOT_PACKAGES_FILE="$reboot_packages" \
SERVER_AGENT_TRIAL=1 expect_status 0 \
    bash "$PROJECT_ROOT/duties/reboot-required.sh"
[[ ! -s "$COMMAND_LOG" ]] ||
    fail "a candidate trial sent a reboot notification or requested a reboot"

: >"$COMMAND_LOG"
NTFY_URL=https://ntfy.invalid/test \
SERVER_AGENT_REBOOT_REQUIRED_FILE="$reboot_required" \
SERVER_AGENT_REBOOT_PACKAGES_FILE="$reboot_packages" expect_status 0 \
    bash "$PROJECT_ROOT/duties/reboot-required.sh"
grep -q "Title: Server rebooting" "$COMMAND_LOG" ||
    fail "the reboot duty did not send its notification first"
grep -q "linux-image-test, libc-test" "$COMMAND_LOG" ||
    fail "the reboot notification did not list requiring packages"
grep -q "systemctl reboot" "$COMMAND_LOG" ||
    fail "the reboot duty did not request a systemd reboot"

report_state="$TEST_ROOT/report-state"
command -p mkdir -p "$report_state/duties"
printf 'failure:1\n' >"$report_state/duties/example-failure.status"
SERVER_AGENT_STATE_DIR="$report_state" expect_status 0 \
    bash "$PROJECT_ROOT/duties/weekly-host-report.sh"
for section in "Weekly host report" "Uptime:" "Root filesystem" \
    "Memory:" "Docker containers:" "Docker storage:" \
    "Failed duties: example-failure" "Reboot:"; do
    grep -q "$section" "$OUTPUT_FILE" ||
        fail "the weekly report omitted: $section"
done

printf 'Duty tests passed.\n'
