# nightly-puffin systemd --user timer pivot (24/7 independence)

This replaces the session-tethered `CronCreate` registration (B2) with systemd `--user` timers that survive reboot, logout, and Claude session exit.

## Why

Anthropic's `CronCreate` silently ignored `durable: true` on CLI 2.1.114 — all 15 jobs landed as `[session-only]` and died with the session. That killed the "24/7" guarantee. See PUFFIN-B2a (#88).

systemd `--user` timers are the standard Linux answer: with `loginctl enable-linger $USER` (already on for `${USER}` on ${USER}-optiplex), the user's service manager runs even without a logged-in session. Shell scripts fire on cron. Scripts that need `claude -p` use the user's persisted auth token (from `~/.claude/.credentials.json`, `chmod 600`) — no interactive login required at fire time.

## Install

```bash
# One-time prerequisite (check state first):
loginctl show-user "$USER" | grep Linger=
# If Linger=no:
sudo loginctl enable-linger "$USER"

# Generate + install timers from config/nightly-schedule.yaml:
bash ~/.claude/scripts/install-systemd-timers.sh

# Verify:
systemctl --user list-timers 'nightly-puffin-*.timer'
```

Expected output: 26 timers listed, each with NEXT / LAST / ACTIVATES / PASSED columns populated.

## Deactivate the old session-only CronCreate jobs

Once systemd timers are proven, remove the session-only duplicates to avoid double-fires:

```bash
# In this Claude session:
CronList                     # confirm the 15 session-only IDs
CronDelete <id>              # repeat for each
```

Or just `CronDelete 3ebc2799` and any other `[session-only]` jobs that CronList surfaces — they'll re-expire after 7 days anyway if you forget.

## View logs

```bash
# Live tail a specific trigger:
journalctl --user -u nightly-puffin-nightly-selector.service -f

# Last fire of every trigger:
for u in ~/.config/systemd/user/nightly-puffin-*.service; do
  name=$(basename "$u" .service)
  echo "=== $name ==="
  journalctl --user -u "$name" -n 5 --no-pager
done
```

## Test-fire a single timer

```bash
systemctl --user start nightly-puffin-pool-worker-tick.service   # no wait, fires now
journalctl --user -u nightly-puffin-pool-worker-tick.service -n 20 --no-pager
```

## Uninstall

```bash
bash ~/.claude/scripts/install-systemd-timers.sh --uninstall
```

Removes all `nightly-puffin-*` service + timer unit files and reloads the daemon.

## Reconcile schedule changes

Any time `config/nightly-schedule.yaml` gains, drops, or renames a trigger, rerun the installer. It overwrites existing unit files in place and picks up any new triggers. Old units for deleted triggers are NOT auto-removed — use `--uninstall` then re-install if you need a clean slate.

## Trigger inventory (26 total)

| Group | Count | Purpose |
|-------|------:|---------|
| `nightly-*` | 9 | 23:30 → 07:00 overnight pipeline (selector → stages A / B1 / B2 / C1 / C2 / digest-prep / digest-out + issue-planner + plan-A) |
| `mini-dispatch-*` | 4 | Daytime sprint-blessed micro-dispatches (10:07, 13:17, 16:27, 19:37) |
| `product-discovery-*` | 10 | Weekday hourly (09–19) gap scans → `product-backlog` issues for PLAN-00 |
| `evening-sprint-collate` | 1 | 21:00 — collate day's product-backlog into sprint milestone |
| `sprint-refresh-midday` | 1 | 15:03 — mid-day sprint queue refresh |
| `pool-worker-tick` | 1 | */6 min — dispatch-queue drainer |

## Security

- Service units set `Environment=HOME=$HOME` and a minimal PATH. No secrets in unit files.
- stdout/stderr → journal (not persisted to disk beyond journal retention).
- `TimeoutStartSec=1800` caps a single fire at 30 min (long-running specialist dispatches).
- `Nice=10` deprioritizes vs interactive work on the same machine.
- No `ProtectHome` (we need `~/.claude/...` access); no `NoNewPrivileges` (scripts may need to fork git-side-channel helpers).

## Rollback

If timers misfire or cause load issues:
```bash
systemctl --user disable --now 'nightly-puffin-*.timer'     # stop all
# (investigation)
systemctl --user enable --now 'nightly-puffin-*.timer'      # re-arm all
```

Or full uninstall + re-register via `CronCreate` from the schedule playbook as a fallback.
