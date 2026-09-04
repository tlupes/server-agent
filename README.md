# Server Agent

A small, self-updating maintenance agent for an Ubuntu Docker host. It checks
this repository every five minutes, tests updates from an isolated Git worktree,
and only fast-forwards the installed checkout after the new revision completes
successfully.

## Install

The host needs `bash`, `curl`, `git`, `util-linux` (for `flock`), and GNU
`coreutils` (for `timeout`). Clone the repository into a permanent location,
then run:

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
Each registration supplies a unique name, cadence in seconds, GNU `timeout`
duration, notification policy, and handler path:

```bash
register_duty \
    "docker-health" \
    300 \
    "30s" \
    "on-change" \
    "$SCRIPT_DIR/duties/docker-health.sh"
```

Supported notification policies are `always`, `on-failure`, `on-change`, and
`never`. The `on-change` policy notifies on the first failure and again when the
duty recovers. Last-run and status data are stored under
`/var/lib/server-agent/duties`, allowing five-minute, daily, and weekly duties
to share the same systemd timer.

Handlers receive the service environment, write diagnostic details to standard
output or standard error, and indicate success or failure with their exit code.
They should be idempotent because every registered duty is force-run once in a
candidate revision's isolated trial state before that revision is installed.
