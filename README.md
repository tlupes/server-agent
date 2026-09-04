# Server Agent

A small, self-updating maintenance agent for an Ubuntu Docker host. It checks
this repository every five minutes, tests updates from an isolated Git worktree,
and only fast-forwards the installed checkout after the new revision completes
successfully.

## Install

The host needs `bash`, `curl`, `git`, Docker with the Compose plugin,
`smartmontools`, `unattended-upgrades`, `util-linux` (for `flock`), and GNU
`coreutils` (for `timeout`). On Ubuntu, install the host packages with:

```bash
sudo apt-get install smartmontools unattended-upgrades
```

Clone the repository into a permanent location, then run:

```bash
sudo ./install.sh
sudoedit /etc/server-agent/config.env
sudo systemctl start server-agent.service
```

Set `NTFY_URL` to the complete URL for the phone's ntfy topic. For a protected
topic, also set `NTFY_TOKEN`. The installer uses a systemd timer instead of cron
to avoid overlapping runs, retain logs, and resume automatically after reboot.

Inspect its status and logs with:

```bash
systemctl status server-agent.timer
journalctl -u server-agent.service
```

## Update behavior

On each run, `server-agent.sh` fetches the configured branch from `origin`.
When a newer fast-forward revision exists, it:

1. Sends an update-started notification.
2. Checks out the fetched revision into `/var/lib/server-agent/update-worktree`.
3. Invokes that revision in trial mode, with a four-minute timeout.
4. On failure, reports the captured error through ntfy and leaves the installed
   checkout unchanged. The next scheduled run tries the revision again.
5. On success, removes the worktree, fast-forwards the installed checkout, and
   sends a success notification.

Rewritten/non-fast-forward history and local checkout changes are rejected
rather than overwritten. A lock prevents concurrent timer or manual
invocations.

## Duties

`run_duties` dispatches standalone scripts declared in `duties/registry.sh`.
Each registration supplies a unique name, cadence, GNU `timeout` duration,
notification policy, and handler path. Cadences may be a number of seconds,
`daily`, `daily-at-HH:MM`, or `weekly-<weekday>`:

```bash
register_duty \
    "docker-health" \
    300 \
    "30s" \
    "on-change" \
    "$SCRIPT_DIR/duties/docker-health.sh"
```

Supported notification policies are `always`, `on-failure`, `on-change`,
`on-failure-recovery`, and `never`. The `on-change` policy notifies on the first
failure and again when the duty recovers. `on-failure-recovery` notifies after
every failed attempt and once after recovery. Last-run and status data are stored under
`/var/lib/server-agent/duties`, allowing five-minute, daily, and weekly duties
to share the same systemd timer.

Handlers receive the service environment, write diagnostic details to standard
output or standard error, and indicate success or failure with their exit code.
They should be idempotent because every registered duty is force-run once in a
candidate revision's isolated trial state before that revision is installed.

## Included duties

| Duty | Schedule | Behavior |
| --- | --- | --- |
| Filesystem capacity | Every 5 minutes, 20-minute timeout | Checks space and inodes only for the root filesystem `/`; separate mounts such as `/media` are excluded. At 80% it cleans policy-managed temporary files and APT caches; at 90% it also removes dangling Docker images, old build cache, and journals older than 30 days; at 95% it removes unused build cache older than one day and limits archived journals to seven days/500 MB. Alerts reflect the usage remaining after cleanup. The agent-wide lock prevents overlapping runs while cleanup is active. |
| Docker health | Every 5 minutes | Reports an unavailable daemon, stopped containers, and unhealthy health checks. Set the `server-agent.healthcheck=ignore` label to exclude an intentional stopped container. |
| Docker log growth | Hourly | Totals each container's active and rotated log files. Warns at 500 MB and escalates at 1 GB without deleting or truncating logs. |
| Host health | Every 5 minutes | Checks normalized load, available memory, swap usage, and Linux thermal zones. |
| Kernel/filesystem errors | Every 5 minutes | Uses a persistent journal cursor to detect each new kernel I/O, filesystem corruption/read-only remount, disk-controller, OOM, and kernel-fault event once. |
| Network mounts | Every 5 minutes | Checks responsive NFS, CIFS/SMB, and SSHFS entries from `/etc/fstab` mounted at `/hillbox` or below. Missing mounts are retried individually; stale mounts receive only a normal unmount/remount, never a forced or lazy detach. Every failed attempt and the eventual recovery are notified. |
| Disk health | Daily | Runs SMART health checks against disks discovered by `smartctl`. RAID monitoring is intentionally not included. |
| Image updates | Every Tuesday | Pulls images and recreates Docker Compose projects. It fails safely when unmanaged containers are present because they cannot be recreated reliably from image metadata alone. |
| Security updates | Daily | Waits up to ten minutes for APT list, archive, and dpkg locks, retries lock races, refreshes metadata with network retries, and applies updates permitted by the host's `unattended-upgrades` policy. Reports whether a reboot is required. |
| Reboot required | Daily during the 02:00 hour | If `/var/run/reboot-required` exists, sends a high-priority ntfy notification and then invokes `systemctl reboot`. A failed notification cancels the reboot. Missed 02:00-hour windows wait until the next day. |
| Weekly host report | Sundays | Reports uptime, load, root usage, memory, Docker container/storage summaries, failed duties, and reboot state through ntfy. |

Image and package duties perform dependency checks, but do not mutate the host
during candidate-revision trials. The systemd service allows up to two hours
for a run, while each duty retains its own shorter timeout.

Filesystem cleanup is intentionally conservative: it never removes Docker
volumes, stopped containers, images referenced by containers, arbitrary files
from temporary directories, or active journal files. Temporary-file removal is
delegated to the host's `systemd-tmpfiles` retention policies.
