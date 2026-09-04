#!/usr/bin/env bash

set -uo pipefail

readonly DUTY_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REBOOT_REQUIRED_FILE="${SERVER_AGENT_REBOOT_REQUIRED_FILE:-/var/run/reboot-required}"
readonly REBOOT_PACKAGES_FILE="${SERVER_AGENT_REBOOT_PACKAGES_FILE:-/var/run/reboot-required.pkgs}"
# shellcheck source=lib/ntfy.sh
source "$DUTY_DIR/lib/ntfy.sh"

for command in curl hostname systemctl; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required reboot command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
    printf 'Reboot preflight passed; reboots and notifications are skipped during trial updates.\n'
    exit 0
fi

if [[ ! -f "$REBOOT_REQUIRED_FILE" ]]; then
    printf 'No reboot is required.\n'
    exit 0
fi

packages="unspecified packages"
if [[ -s "$REBOOT_PACKAGES_FILE" ]]; then
    packages=$(paste -sd, "$REBOOT_PACKAGES_FILE")
    packages=${packages//,/, }
fi

message="$(hostname) is rebooting because installed updates require it.
Packages: $packages"
if ! duty_notify "Server rebooting" "$message" "high"; then
    printf 'Unable to send the reboot notification; reboot cancelled.\n' >&2
    exit 1
fi

printf 'Reboot notification delivered; requesting system reboot.\n'
systemctl reboot
