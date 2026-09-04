#!/usr/bin/env bash

# Register duties here. Cadences are seconds; timeout values use a GNU timeout
# suffix (s, m, h, or d). Notification policies are:
#   always     - notify after every run
#   on-failure - notify after every failed run
#   on-change  - notify on the first failure and subsequent recovery
#   never      - do not send duty notifications
#
# Example:
# register_duty \
#     "docker-health" \
#     300 \
#     "30s" \
#     "on-change" \
#     "$SCRIPT_DIR/duties/docker-health.sh"
