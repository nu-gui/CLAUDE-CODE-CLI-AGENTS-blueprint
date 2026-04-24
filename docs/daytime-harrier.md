# Daytime Harrier

The **daytime-harrier** pipeline is the daylight partner to [nightly-puffin](nightly-puffin.md). Where puffin dives deep overnight (heavy dispatch, deploy, digest), harrier sweeps wide across business hours — discovering roadmap gaps, triaging new issues, refreshing the sprint queue, and warming worktrees so the evening collate has a full inbox ready for the overnight selector at 23:30.

Named after the long-range, low-altitude hunting raptor: systematic, broad-coverage passes across wide territory.

---

## Cadence

All times local time (UTC+2). Source of truth: `config/nightly-schedule.yaml`.

| Time (local time) | Cron | Stage | Script | Purpose |
|---|---|---|---|---|
| `09:13` | `13 9 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 rotation pick, scan for gaps, create product-backlog issues (cap 5) |
| `10:07` | `7 10 * * *` | mini | `nightly-dispatch.sh stage=mini` | Mini-dispatch: sprint-blessed issues, pared budget |
| `10:13` | `13 10 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `11:13` | `13 11 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `12:13` | `13 12 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `13:17` | `17 13 * * *` | mini | `nightly-dispatch.sh stage=mini` | Mini-dispatch |
| `14:13` | `13 14 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 (post-lunch restart) |
| `15:03` | `3 15 * * *` | sprint-refresh | `evening-sprint-collate.sh --mode=refresh` | Mid-day sprint refresh: up to 3 new issues → `daytime-candidate` |
| `15:13` | `13 15 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `16:13` | `13 16 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `16:27` | `27 16 * * *` | mini | `nightly-dispatch.sh stage=mini` | Mini-dispatch |
| `17:13` | `13 17 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `18:13` | `13 18 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 |
| `19:13` | `13 19 * * 1-5` | product-discovery | `product-discovery.sh` | PROD-00 (last slot before evening collate) |
| `19:37` | `37 19 * * *` | mini | `nightly-dispatch.sh stage=mini` | Mini-dispatch + worktree warm-up before 21:00 |
| `21:00` | `0 21 * * *` | sprint-collate | `evening-sprint-collate.sh` | PLAN-00 collates day's product-backlog → sprint milestone, writes queue hint |

> **Note**: 13:13 is intentionally skipped (lunch). Product-discovery fires on weekdays only (`1-5`); mini-dispatch and sprint stages fire every day.
>
> **Upcoming**: `actions-budget-monitor.sh` at `08:00` is already in `nightly-schedule.yaml`; a dedicated `pr-sweeper` at `08:00` is tracked as W18-ID15c follow-up.

---

## Agent Assignments

| Stage | Agent | Notes |
|---|---|---|
| `product-discovery` | `prod-00-product-discovery` | Rotation pick from `config/product-profiles.yaml`; 3h per-repo cooldown |
| `mini` | Varies by issue prefix | `[AGENT-*]` → mapped specialist; `[FEATURE]` → api-core or domain agent; ORC-00 fans out |
| `sprint-refresh` | `plan-00-product-delivery` | Labels qualifying issues `daytime-candidate`; attaches to current sprint milestone |
| `sprint-collate` | `plan-00-product-delivery` | Full collation; writes next-day queue hint read by 23:30 selector |

---

## Mini-Dispatch Budget

Each of the four mini fires uses a pared-down execution envelope to avoid starving interactive work:

| Limit | Value |
|---|---|
| Commits per repo | 3 |
| PRs per repo | 1 |
| Files per repo | 15 |
| Background-activity skip | 3600 s |
| Quiet-triage sweep | Disabled |

Contrast with overnight budget: 10 commits / 3 PRs / 50 files / 7200 s bg-skip.

---

## Escalation Paths

```
product-discovery (09:13 – 19:13)
    │  creates [FEATURE]/[AGENT-*] issues (label: product-backlog)
    ▼
sprint-refresh (15:03)
    │  picks up to 3 new issues → daytime-candidate label
    │  16:27 / 19:37 mini runs preferentially pick daytime-candidate issues
    ▼
evening-sprint-collate (21:00)
    │  full fold → sprint milestone
    │  writes next-day queue hint → ~/.claude/context/hive/nightly-queue-hint.json
    ▼
nightly-selector (23:30)                  ← handoff to nightly-puffin
    │  reads queue hint, scores repos, writes nightly-queue.json
    ▼
nightly-dispatch stages A → B1 → B2 → C1 → C2 (00:00 – 06:45)
```

If a mini-dispatch issues a `BLOCKED` event, the 21:00 collate still runs — blocked items surface in the morning digest's "Blocked" panel, not discarded.

---

## Relationship to Nightly-Puffin

| Dimension | Daytime Harrier | Nightly Puffin |
|---|---|---|
| Active window | 09:00 – 21:00 local time | 23:30 – 07:00 local time |
| Primary mode | Shallow sweeps, discovery | Deep dives, heavy dispatch |
| Dominant workload | Discovery + triage + mini fixes | Full specialist execution + deploy |
| Budget per repo | 3 commits / 1 PR / 15 files | 10 commits / 3 PRs / 50 files |
| Human overlap | Yes — bg-skip protects active repos | Mostly unattended |
| Output to the other | 21:00 collate → queue hint for 23:30 | 06:45 digest → next day's harrier context |
| Weekday gating | Product-discovery weekdays only | All stages run every day |

The two pipelines form a continuous 24-hour loop. Harrier feeds puffin; puffin's digest seeds the next harrier cycle.

---

## Observability

```bash
# Activity in the last 6 hours
bash ~/.claude/scripts/hive-status.sh --since 6h

# Just the daytime window since 09:00
bash ~/.claude/scripts/hive-status.sh --since 12h

# Machine-readable
bash ~/.claude/scripts/hive-status.sh --since 6h --json
```

| What to look at | Where |
|---|---|
| Per-stage events | `~/.claude/context/hive/events.ndjson` — filter `"stage":"mini"` or `"stage":"product-discovery"` |
| Journal trail | `journalctl --user -u 'nightly-puffin-*' -S today` |
| Morning digest sections | "Daytime Activity", "Blocked", "Stale PRs" panels in `~/.claude/context/hive/digests/{date}.md` |
| Sprint queue state | `~/.claude/context/hive/nightly-queue-hint.json` (written by 21:00 collate) |

`hive-status.sh` exit code `1` means DEGRADED — at least one blocked event or failed systemd unit in the query window. See `docs/hive-status.md` for full reference.
