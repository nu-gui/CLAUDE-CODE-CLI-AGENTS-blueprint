# closure-watcher.sh

Meta-monitor that ensures the issue → PR → merge lifecycle reaches its
terminal state. Companion to `pr-sweeper.sh` — sweeper labels and merges
ready PRs; watcher audits closure across the full lifecycle and either
auto-fixes or surfaces what is stuck.

Background and motivation: issue [#185](https://github.com/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint/issues/185).

## Why it exists

The pipeline opens work (PROD-00 issues, specialist PRs) and reports it
(morning-digest), but until this watcher landed there was no enforcement
layer ensuring work reaches a terminal state. Symptoms accumulating:

- PRs labelled `sweep-ready-to-merge` sat forever (auto-merge gap; #182
  closed the immediate hole, but ongoing audit is needed because `state`
  drifts as new PRs are labelled).
- PRs MERGED on master but their linked issue still OPEN — the
  Closes-keyword may have failed to fire, or commits with `Closes #N`
  were squash-merged in a way GitHub did not recognise.
- Issues created by PROD-00 with no PR ever opened → drift.
- Branches with no PR → orphans.
- Duplicate issues from PROD-00 (#184 deduped at-create-time, but
  duplicates can still appear via different code paths).

Without continuous closure-loop enforcement, the backlog grows
monotonically. As of issue #185 filing, that was 164 open PRs + 324
open issues across both orgs.

## What it does

Per fire (twice daily — see [Schedule](#schedule)), the watcher executes
six sections in order:

1. **Auto-merge clean ready PRs** — PRs with `sweep-ready-to-merge` OR
   `approved-nightly` AND `mergeable=MERGEABLE` AND
   `mergeStateStatus=CLEAN` AND no failing CI checks AND no hard-block
   labels. Squash-merges with `--delete-branch --auto`. Cap **10** per
   run. Emits `PROGRESS auto-merged repo#N (squash)`.

2. **Detect DIRTY ready PRs** — PRs with `sweep-ready-to-merge` AND
   `mergeable=CONFLICTING`. Adds `sweeper:NEEDS_REBASE` label and emits
   `PROGRESS rebase-needed repo#N`. Cap **5** per run. Issue
   [#183](https://github.com/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint/issues/183)
   ships `hive_rebase_pr` which will execute the rebase; until then this
   section is detect-and-flag only. Two-stage counting (issue
   [#194](https://github.com/${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint/issues/194)):
   `rebase_queue_depth` records every eligible DIRTY PR observed in this
   fire, regardless of cap; `rebased` (a.k.a. flagged) only goes up to
   the per-fire cap. If `rebase_queue_depth > 3 × cap`, the run emits
   `BLOCKED rebase-queue-chronic-backlog` so the digest surfaces it.

3. **Close orphan issues** — for every PR merged in the last 24 h, parse
   `Closes/Fixes/Resolves #N` from PR title + body. If issue #N is still
   OPEN and not labelled `do-not-auto`, close it with a comment linking
   the merging PR. Cap **20** per run. Emits
   `PROGRESS orphan-issue-closed repo#N via PR #M`.

4. **Detect orphan branches** — branches on `origin` whose target commit
   is older than 7 days AND have no open PR (excluding `master`/`main`/
   `develop`). Read-only — emits `BLOCKED orphan-branch ...` events for
   digest visibility but never deletes the branch (humans decide).

5. **Detect issue duplicates** — within each repo's open issues,
   token-overlap pairwise comparison; if best score ≥ 0.6, count as a
   duplicate. Read-only — emits `PROGRESS duplicate-issues-detected`
   for digest visibility. Catches duplicates that bypassed the
   at-create-time `hive_issue_create_deduped` guardrail (#184).

6. **Emit summary** — single `COMPLETE` event with JSON detail
   `{auto_merged, rebased, rebase_queue_depth, issues_closed, orphans, dupes, repos, skipped}`
   so the morning-digest can aggregate over the day's two fires. The digest
   reports `rebase_queue_depth` as a peak (max across the window's fires)
   rather than a sum to avoid double-counting PRs that stay DIRTY across
   consecutive fires.

## Usage

```bash
# Dry-run (default — no mutations, prints intentions)
bash scripts/closure-watcher.sh

# Apply mode — auto-merge clean PRs + close orphan issues
bash scripts/closure-watcher.sh --apply

# Restrict to a single org
bash scripts/closure-watcher.sh --apply --orgs ${GITHUB_ORG:-your-org}

# Custom output path
bash scripts/closure-watcher.sh --output /tmp/cw-test.md
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | Yes | No mutations; print what would happen |
| `--apply` | No | Execute auto-merges, label rebase candidates, close orphan issues |
| `--orgs <csv>` | `${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}` | Comma-separated org list |
| `--output <path>` | `~/.claude/context/hive/closure-watcher-<date>-<HHMMSS>.md` | Manifest output |

## Schedule

Two cron entries in `config/nightly-schedule.yaml`, off-minute aligned
per existing convention:

| Time (local time) | Trigger | Rationale |
|-------------|---------|-----------|
| **14:43** | `closure-watcher-afternoon` | After 13:17 mini-dispatch settles, before 15:03 sprint-refresh |
| **18:33** | `closure-watcher-evening` | Between 16:27 and 19:37 mini-dispatch fires |

Both fire `bash ~/.claude/scripts/closure-watcher.sh --apply`. The
afternoon fire catches PRs that turned green during the morning's work;
the evening fire catches PRs from the afternoon mini-dispatch run.

## Safety rails

- **Per-run caps**: 10 auto-merges, 5 rebase-flags, 20 issue closures.
  Hitting any cap emits `BLOCKED <kind>-cap-reached` and defers the
  remainder to the next run.
- **Per-repo opt-out**: any repo with `closure_watcher: skip` in
  `config/nightly-repo-profiles.yaml` is skipped entirely.
- **Issue exclusion**: issues labelled `do-not-auto` are never closed.
- **PR base guard**: only merges PRs whose `baseRefName == master` —
  `main` is explicitly skipped (defence-in-depth on top of the global
  pre-push hook).
- **Hard-block labels**: `blocked-human`, `blocked-manual`,
  `do-not-merge`, `do-not-auto`, `needs-revision` — none of these PRs
  are touched.
- **Read-only sections**: orphan-branch detection (Section 4) and
  duplicate detection (Section 5) never mutate; they only emit events
  for the digest.

## Output

### Manifest file

Markdown manifest at
`~/.claude/context/hive/closure-watcher-<YYYY-MM-DD>-<HHMMSS>.md` with:

- Header (generated timestamp, scope, mode)
- Summary table (counts vs caps)
- Per-repo detail table (`Target | Item | Verdict | Note`)

### Hive events

| Event | Detail | When |
|-------|--------|------|
| `SPAWN` | `mode=apply\|dry-run orgs=...` | Run start |
| `PROGRESS auto-merged` | `repo#N (squash)` | Per merge |
| `PROGRESS rebase-needed` | `repo#N (CONFLICTING; ...)` | Per rebase candidate |
| `PROGRESS orphan-issue-closed` | `repo#N via PR #M` | Per orphan closure |
| `PROGRESS duplicate-issues-detected` | `repo=R count=N` | Per repo with duplicates |
| `BLOCKED orphan-branch` | `repo=R branch=B age=Nd` | Per orphan branch |
| `BLOCKED auto-merge-failed` | `repo#N` | Per merge failure |
| `BLOCKED <kind>-cap-reached` | `(N) — remaining ... deferred` | Per cap-hit |
| `BLOCKED rebase-queue-chronic-backlog` | `depth=D cap=C extra_fires=F` | When `depth > 3 × cap` (issue #194) |
| `COMPLETE` | `counts={auto_merged:N, rebased:M, rebase_queue_depth:Q, issues_closed:K, orphans:L, dupes:J, repos:P, skipped:S}` | End of run |

### Morning-digest section

`morning-digest.sh` aggregates `closure-watcher` events from the last
24 h and writes a "Closure-loop watcher (last 24h)" section with:

- Summed counts across both daily fires
- List of escalated BLOCKED events (excluding orphan-branch noise,
  which is collapsed to a single count)

## Per-repo opt-out

Add to a repo's entry in `config/nightly-repo-profiles.yaml`:

```yaml
repos:
  some-repo-name:
    closure_watcher: skip
```

The watcher will log `SKIP` in the manifest and the BLOCKED-orphan-issue
side-effects of merging activity in that repo will not be acted on.

## Testing

```bash
# Dry-run smoke test (always safe — no mutations)
bash scripts/closure-watcher.sh --dry-run --orgs ${GITHUB_ORG:-your-org}

# Inspect output
ls -ltr ~/.claude/context/hive/closure-watcher-*.md | tail -1
```

The `--dry-run` mode emits the same `SPAWN`/`COMPLETE` events as
`--apply`, so you can verify hive-event flow end-to-end without any
GitHub mutations.

## Sequencing with #182, #183, #184

- **#182** (closed) — tactical fix in `pr-sweeper.sh` that auto-merges
  clean `sweep-ready-to-merge` PRs in `--apply` mode. The watcher's
  Section 1 provides ongoing audit + applies the same rule to
  `approved-nightly` PRs.
- **#183** (open) — `hive_rebase_pr` helper. The watcher's Section 2
  flags candidates with `sweeper:NEEDS_REBASE` so #183's helper can
  later pick them up by label query.
- **#184** (closed) — `hive_issue_create_deduped` at-create-time
  dedupe. The watcher's Section 5 catches duplicates that bypassed
  that guardrail.

## Why it matters

Closure-loop completion is the difference between "pipeline that opens
work" (the previous state) and "pipeline that closes work" (the target
state). Without this layer, the backlog grows monotonically — every
fire of PROD-00 + every nightly specialist run pushes new items in,
but nothing pulls items out at terminal state.
