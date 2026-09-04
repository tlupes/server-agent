#!/usr/bin/env bash

set -uo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    printf 'apt-get is not installed.\n' >&2
    exit 1
fi
if ! command -v unattended-upgrade >/dev/null 2>&1; then
    printf 'unattended-upgrade is not installed; install the unattended-upgrades package.\n' >&2
    exit 1
fi

if [[ "${SERVER_AGENT_TRIAL:-0}" == "1" ]]; then
    unattended-upgrade --help >/dev/null
    printf 'Security update preflight passed; package changes are skipped during trial updates.\n'
    exit 0
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
unattended-upgrade --verbose

if [[ -f /var/run/reboot-required ]]; then
    printf 'Security updates completed; the host requires a reboot.\n'
else
    printf 'Security updates completed; no reboot is currently required.\n'
fi
