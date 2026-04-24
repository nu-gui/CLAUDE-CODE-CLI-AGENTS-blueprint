# hive-status.sh

One-command summary of nightly-puffin pipeline activity. Designed to be polled by dashboards, monitoring scripts, or queried manually.

## Usage

```bash
# Default: last 24 hours, pretty output
bash ~/.claude/scripts/hive-status.sh

# Custom window
bash ~/.claude/scripts/hive-status.sh --since 2h
bash ~/.claude/scripts/hive-status.sh --since 30m
bash ~/.claude/scripts/hive-status.sh --since 1d

# Machine-readable JSON
bash ~/.claude/scripts/hive-status.sh --json
bash ~/.claude/scripts/hive-status.sh --since 6h --json
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0`  | HEALTHY — no blocked events, no failed systemd units |
| `1`  | DEGRADED or BLOCKED — one or more blocked events OR failed `nightly-puffin-*` units |

## Sample Pretty Output

```
=== nightly-puffin status ===
Generated: 2026-04-20T13:17:00Z
Window:    last 24h
Active timers: 26 (next: nightly-puffin-dispatch-b1.timer in 2h)
Latest digest: ${HOME}/.claude/context/hive/digests/2026-04-20.md
Failed units:  0

Recent events (last 24h, 142 total):
  13:01:14Z  dispatch        SPECIALIST_COMPLETE  example-repo stage=mini attempts=1
  12:07:45Z  pool-worker     SPAWN                pool tick (cap=9 window=3600s)
  11:58:02Z  nightly-select  PROGRESS             ranked 8 repos
  11:00:03Z  dispatch        SPAWN                stage=mini repos=3
  10:30:00Z  doc-hygiene     COMPLETE             3 files updated
  ...

STATUS: HEALTHY
```

## Sample JSON Output

```json
{
  "generated_at": "2026-04-20T13:17:00Z",
  "window": "last 24h",
  "events": [...],
  "failed_units": [],
  "active_timers_count": 26,
  "latest_digest": "${HOME}/.claude/context/hive/digests/2026-04-20.md",
  "status": "healthy"
}
```

JSON `status` values: `healthy` | `degraded` | `blocked`

## Integration Hints

### Cron health-check (alert on exit 1)

```bash
# In crontab: run every 30 minutes, mail on failure
*/30 * * * * bash ~/.claude/scripts/hive-status.sh --since 30m --json > /tmp/hive-status.json || mail -s "PUFFIN ALERT" your-email@example.com < /tmp/hive-status.json
```

### Dashboard polling (jq pipeline)

```bash
# Pull structured status for a dashboard widget
bash ~/.claude/scripts/hive-status.sh --json | jq '{status, active_timers_count, failed_units: (.failed_units | length), event_count: (.events | length)}'
```

### Combine with hive-verify.sh for full health picture

```bash
bash ~/.claude/scripts/hive-verify.sh && bash ~/.claude/scripts/hive-status.sh
```

## What it Checks

| Check | Source |
|-------|--------|
| Recent hive events | `~/.claude/context/hive/events.ndjson` filtered by `ts >= threshold` |
| Blocked events | Any event where `.event` contains `block` (case-insensitive) in window |
| Failed systemd units | `systemctl --user list-units --state=failed 'nightly-puffin-*'` |
| Active timers | `systemctl --user list-timers 'nightly-puffin-*.timer'` |
| Latest digest | Most recent `.md` in `~/.claude/context/hive/digests/` |

## Notes

- Read-only: never mutates `events.ndjson` or any hive state.
- Graceful on missing/empty events file — reports "no events in window" instead of erroring.
- `--since` accepts `Nm` (minutes), `Nh` (hours), `Nd` (days). Uses GNU `date -d` with Python3 fallback for portability.
