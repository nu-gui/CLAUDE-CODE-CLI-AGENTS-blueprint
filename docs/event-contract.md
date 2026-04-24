# Event Contract — dispatcher lifecycle events

Canonical definitions for events emitted to `~/.claude/context/hive/events.ndjson` by any script that spawns `claude -p` subprocesses. This is the single source of truth — `scripts/nightly-dispatch.sh` and `scripts/product-discovery.sh` reference this file rather than inlining their own docstring.

## Events

| Event | Scope | Fires when | Notes |
|---|---|---|---|
| `SPAWN` | per-SID | Dispatcher starts | Exactly once per SID at the top of the run. Follow-up events share the same SID. |
| `PROGRESS` | per-SID | Informational waypoint | Free-form. Used for ssh-preflight, background-active guards, rate-limit retries, etc. |
| `HANDOFF` | per-subprocess | `claude -p` is about to be invoked | One per repo (or per PROD-00 target). Detail: `<repo> → claude -p (<stage>)`. |
| `SPECIALIST_COMPLETE` | per-subprocess | `claude -p` exited 0 | One per successful handoff. Detail should include repo + stage + attempts. |
| `SPECIALIST_FAILED` | per-subprocess | `claude -p` exited non-zero | One per failed handoff. Detail must include repo + stage + exit + attempts. |
| `BLOCKED` | per-SID or per-subprocess | Dispatch skipped, pre-flight failed, specialist unrecoverable | Always followed by a `COMPLETE` at the stage level so downstream consumers can tell the SID finished. |
| `COMPLETE` | per-SID | Stage wrapper exits cleanly | At most once per SID. Fires regardless of specialist success/failure within the stage. |

## Invariants

1. **Every SID that emits `SPAWN` must also emit exactly one `COMPLETE`** (even if the body blocked, failed, or produced zero handoffs).
2. **Every `HANDOFF` must be followed by either `SPECIALIST_COMPLETE` or `SPECIALIST_FAILED`** for the same SID before the stage's `COMPLETE` fires.
3. **`SPECIALIST_COMPLETE` count ≤ `HANDOFF` count** for any SID (a subprocess may fail, but cannot complete without first handing off).

## Health-monitoring jq queries

### Specialists that silently stalled (no terminal event for a HANDOFF)

```bash
jq -cR 'fromjson? | select(.agent == "dispatch")' ~/.claude/context/hive/events.ndjson | \
jq -s '
  group_by(.sid)
  | map({
      sid: .[0].sid,
      handoff: ([.[] | select(.event == "HANDOFF")] | length),
      terminal: ([.[] | select(.event | IN("SPECIALIST_COMPLETE","SPECIALIST_FAILED"))] | length)
    })
  | map(select(.handoff > 0 and .handoff != .terminal))
'
```
Expect `[]`. Any entry is a stalled subprocess.

### Stages that started but never closed (no `COMPLETE`)

```bash
jq -cR 'fromjson? | select(.agent == "dispatch")' ~/.claude/context/hive/events.ndjson | \
jq -s '
  group_by(.sid)
  | map({
      sid: .[0].sid,
      spawn: ([.[] | select(.event == "SPAWN")] | length),
      complete: ([.[] | select(.event == "COMPLETE")] | length)
    })
  | map(select(.spawn > 0 and .complete == 0))
'
```
Expect `[]`. Any entry is a stage that started but didn't finish — often a crash before the final `emit_event`.

### Hidden trailing-rc events (PROGRESS events emitted by the #155 guard)

```bash
jq -cR 'fromjson? | select(.agent == "dispatch" and (.detail | contains("trailing-rc")))' \
  ~/.claude/context/hive/events.ndjson
```
Should be rare. A flood here means `ci_retrigger_after_merge`, `emit_event`, or another trailing call in the dispatch function is frequently returning non-zero — investigate before it becomes a silent correctness issue.

## Emitting events

Both dispatchers use a wrapper around `hive_emit_event` from `scripts/lib/common.sh`:

- `scripts/nightly-dispatch.sh` defines `emit_event <agent> <event> <detail>` (3 args; derives SID from the current stage run).
- `scripts/product-discovery.sh` calls `emit_event <sid> <agent> <event> <detail>` (4 args; SID passed explicitly because one run can dispatch to multiple repo slots).

The SID is what ties events together. Keep it stable for the lifetime of a single dispatcher run and prefixed so grepping the stream is easy (`nightly-YYYY-MM-DD-<stage>`, `prod-YYYY-MM-DD-<hour>-<repo>`, etc.).

## When to update this doc

- **New event type**: add a row to the table, add a matching jq monitoring query if it's a failure signal, update the relevant invariant.
- **New dispatcher script**: reference this file in its header docstring (one-liner: `# Event contract: see docs/event-contract.md`). Use the same 3-arg or 4-arg emit_event shape as the closest existing dispatcher.
- **Changing invariant behaviour** (e.g. making `COMPLETE` conditional on something): update the invariants section AND the morning-digest.sh integrity-warning logic, since it checks these counts.

## History

| Date | Change | Issue |
|---|---|---|
| 2026-04-23 | Contract formalised after false-alarm stall report in daytime audit | #154 |
| 2026-04-23 | `return 0` guard added to nightly-dispatch.sh ensures `COMPLETE` fires after specialist success under `set -euo pipefail` | #155 |
