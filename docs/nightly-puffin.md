# Nightly Puffin

The **nightly-puffin** pipeline is the overnight partner to [daytime-harrier](daytime-harrier.md). While harrier sweeps wide across business hours (discovery, triage, mini fixes), puffin dives deep during the quiet overnight window — running full specialist dispatch, tests, reviews, deploys, and the morning digest.

Named after the cold-water burrowing seabird: patient, deep-diving, fully committed once it goes under.

---

## Path convention (issue #152)

Repository clones are expected under `${HOME}/github/<owner>/<repo>/`. The
`config/nightly-repo-profiles.yaml` `github_root` key names the canonical root;
all readers use `hive_resolve_local_path` (in `scripts/lib/common.sh`) to
resolve each repo's clone path.

Resolution order:
1. Explicit `repos.<name>.local_path` override (supports `${HOME}` / `$HOME` expansion)
2. `${github_root}/${GITHUB_ORG:-your-org}/<repo>/` — primary org
3. `${github_root}/${GITHUB_ORG:-your-org}/<repo>/` — secondary org
4. `${HOME}/<repo>/` — legacy non-standard layouts (e.g. `example-repo-local-llm`, `example-repo-local-llm`)

When multiple candidates exist, the resolver picks the clone with the most
recent commit. This keeps the pipeline portable across hosts — any machine
where the repo layout follows the `${HOME}/github/<owner>/<repo>` convention
works without yaml edits.

---

## Cadence

All times local time (local time). Source of truth: `config/nightly-schedule.yaml`.

| Time (local time) | Cron | Stage | Script | Purpose |
|---|---|---|---|---|
| `23:30` | `30 23 * * *` | selector | `nightly-select-projects.sh` | Score repos, read queue hint from 21:00 collate, write `nightly-queue.json` |
| `00:00` | `0 0 * * *` | A | `nightly-dispatch.sh stage=A` | PLAN-00 gap-fills issues without `[AGENT-*]` prefix |
| `00:30` | `30 0 * * *` | planner | `issue-planner.sh all` | Per-issue parallel task planner; feeds Stage B1 |
| `01:00` | `0 1 * * *` | B1 | `nightly-dispatch.sh stage=B1` + `nightly-dependabot-merge.sh` | Specialist wave 1 + Dependabot PRs |
| `02:30` | `30 2 * * *` | B2 | `nightly-dispatch.sh stage=B2` | Specialist wave 2 (remaining nightly-candidate issues) |
| `04:00` | `0 4 * * *` | C1 | `nightly-dispatch.sh stage=C1` | TEST-00 suites + SUP-00 review + api-gov for security issues |
| `05:30` | `30 5 * * *` | C2 | `nightly-dispatch.sh stage=C2` + `nightly-deploy.sh` | DOC-00 doc updates + auto-merge + staging deploy |
| `06:30` | `30 6 * * *` | digest-prep | `nightly-dispatch.sh stage=digest-prep` | Aggregate `events.ndjson` since midnight |
| `06:45` | `45 6 * * *` | digest-out | `morning-digest.sh` | COM-00: markdown + Gmail draft + GitHub Discussion + example-repo memory |

---

## Agent Assignments

| Stage | Agent(s) | Notes |
|---|---|---|
| `selector` | `nightly-select-projects.sh` (script, no agent) | Sprint-blessed boost; reads queue hint |
| A | `plan-00-product-delivery` | Labels qualifying issues `nightly-candidate` |
| planner | `orc-00-orchestrator` (fan-out) | Per-issue plans consumed by B1 |
| B1 / B2 | Domain specialists per `[AGENT-*]` prefix | api-core, infra-core, data-core, etc. |
| C1 | `test-00-test-runner`, `sup-00-qa-governance`, `api-gov` | Parallel; api-gov only for `[SECURITY]`/`[P0-SEC]` |
| C2 | `doc-00-documentation`, `infra-core` | DOC-00 first; infra-core handles deploy after merge |
| digest-prep / digest-out | `com-00-inbox-gateway` | 4 channels: local MD, Gmail, GitHub Discussion, example-repo |

---

## Overnight Budget

| Limit | Value |
|---|---|
| Commits per repo | 10 |
| PRs per repo | 3 |
| Files per repo | 50 |
| Background-activity skip | 7200 s |
| Stale-PR window | 24 h (surfaced in digest) |

---

## Relationship to Daytime Harrier

| Dimension | Nightly Puffin | Daytime Harrier |
|---|---|---|
| Active window | 23:30 – 07:00 local time | 09:00 – 21:00 local time |
| Primary mode | Deep dives, heavy dispatch | Shallow sweeps, discovery |
| Dominant workload | Full specialist execution + deploy | Discovery + triage + mini fixes |
| Budget per repo | 10 commits / 3 PRs / 50 files | 3 commits / 1 PR / 15 files |
| Human overlap | Mostly unattended | Yes — bg-skip protects active repos |
| Input from the other | 21:00 queue hint → 23:30 selector | 06:45 digest seeds next-day context |

See [daytime-harrier.md](daytime-harrier.md) for the full daytime cadence and escalation paths.

---

## PROD-00 Conventions

- **Canonical ROADMAP filename**: `ROADMAP.md` (uppercase). Matches GitHub README convention and is the name PROD-00 scaffolds `ROADMAP-proposals.md` from when absent.
- **Case-conflict handling**: If a repo contains both `ROADMAP.md` and `roadmap.md`, the dispatcher picks whichever has the most recent `git log` entry and emits a `roadmap-case-conflict` PROGRESS event. The morning digest surfaces these under "Repos with ROADMAP case conflict". Resolution: remove or rename the lowercase variant.

---

## Observability

```bash
# Full overnight run summary
bash ~/.claude/scripts/hive-status.sh --since 8h

# Machine-readable
bash ~/.claude/scripts/hive-status.sh --since 8h --json

# Systemd unit logs
journalctl --user -u 'nightly-puffin-*' -S yesterday
```

| What to look at | Where |
|---|---|
| Per-stage events | `~/.claude/context/hive/events.ndjson` — filter by `"stage"` |
| Morning digest | `~/.claude/context/hive/digests/{date}.md` |
| Dispatch queue | `~/.claude/context/hive/nightly-queue.json` (written by 23:30 selector) |
| Channel config | `config/digest-config.yaml` |
