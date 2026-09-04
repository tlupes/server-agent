#!/usr/bin/env bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly SERVICE_NAME="server-agent"
readonly ENV_DIR="/etc/server-agent"
readonly ENV_FILE="$ENV_DIR/config.env"
readonly SERVICE_FILE="/etc/systemd/system/$SERVICE_NAME.service"
readonly TIMER_FILE="/etc/systemd/system/$SERVICE_NAME.timer"

if [[ $EUID -ne 0 ]]; then
    printf 'Run this installer as root (for example: sudo ./install.sh).\n' >&2
    exit 1
fi

for command in curl git systemctl timeout flock; do
    if ! command -v "$command" >/dev/null 2>&1; then
        printf 'Required command is missing: %s\n' "$command" >&2
        exit 1
    fi
done

if ! git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'The installer must be run from a Git checkout.\n' >&2
    exit 1
fi

branch=$(git -C "$SCRIPT_DIR" branch --show-current)
if [[ -z "$branch" ]]; then
    printf 'The checkout must be on a branch before installation.\n' >&2
    exit 1
fi

install -d -m 0750 "$ENV_DIR"
if [[ ! -e "$ENV_FILE" ]]; then
    install -m 0640 "$SCRIPT_DIR/config.env.example" "$ENV_FILE"
fi

escaped_script_dir=${SCRIPT_DIR//%/%%}
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Periodic Docker host maintenance agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$ENV_FILE
Environment="SERVER_AGENT_REPO_ROOT=$escaped_script_dir"
Environment="SERVER_AGENT_BRANCH=$branch"
ExecStart="$escaped_script_dir/server-agent.sh"
TimeoutStartSec=4min30s

[Install]
WantedBy=multi-user.target
EOF

cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Run the server maintenance agent every five minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=15s
Unit=$SERVICE_NAME.service

[Install]
WantedBy=timers.target
EOF

chmod 0755 "$SCRIPT_DIR/server-agent.sh" "$SCRIPT_DIR/install.sh"
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME.timer"

printf 'Installed and started %s.timer.\n' "$SERVICE_NAME"
if grep -Eq '^NTFY_URL=$' "$ENV_FILE"; then
    printf 'Set NTFY_URL in %s, then run: systemctl start %s.service\n' \
        "$ENV_FILE" "$SERVICE_NAME"
fi
