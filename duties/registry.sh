#!/usr/bin/env bash

# Cadences may be seconds, "daily", or "weekly-<weekday>". Timeout values use a
# GNU timeout suffix (s, m, h, or d). Notification policies are:
#   always     - notify after every run
#   on-failure - notify after every failed run
#   on-change  - notify on the first failure and subsequent recovery
#   never      - do not send duty notifications
register_duty "filesystem-capacity" 300 "30s" "on-change" \
    "$SCRIPT_DIR/duties/filesystem-capacity.sh"
register_duty "docker-health" 300 "30s" "on-change" \
    "$SCRIPT_DIR/duties/docker-health.sh"
register_duty "host-health" 300 "30s" "on-change" \
    "$SCRIPT_DIR/duties/host-health.sh"
register_duty "disk-health" "daily" "5m" "on-change" \
    "$SCRIPT_DIR/duties/disk-health.sh"
register_duty "image-updates" "weekly-tuesday" "60m" "always" \
    "$SCRIPT_DIR/duties/image-updates.sh"
register_duty "security-updates" "daily" "30m" "always" \
    "$SCRIPT_DIR/duties/security-updates.sh"
