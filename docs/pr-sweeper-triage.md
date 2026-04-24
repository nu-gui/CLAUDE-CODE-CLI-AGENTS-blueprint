# PR Sweeper Triage Mode

Added in EXAMPLE-ID (issue #131). Extends `scripts/pr-sweeper.sh` with a
`--triage` flag that sub-classifies the `NEEDS_ATTENTION` bucket into five
actionable sub-buckets, each carrying an executable auto-action.

---

## Usage

```bash
# Dry-run triage (reads all open PRs, classifies, prints actions — no mutations)
bash scripts/pr-sweeper.sh --triage

# Apply triage (labels PRs, posts comments, closes stale/draft PRs)
bash scripts/pr-sweeper.sh --triage --apply

# Scope to one org
bash scripts/pr-sweeper.sh --triage --apply --orgs ${GITHUB_ORG:-your-org}

# Custom output path
bash scripts/pr-sweeper.sh --triage --apply --output /tmp/my-triage.md
```

Manifest is written to `~/.claude/context/hive/sweep-triage-<YYYY-MM-DD>.md`
by default.

---

## Sub-Classification Table

Each `NEEDS_ATTENTION` PR receives exactly one `sweeper:*` label. Labels are
mutually exclusive. Classification is deterministic and applies in priority
order:

| Priority | Label | Criteria | Auto-action |
|----------|-------|----------|-------------|
| 1 | `sweeper:HOLD_HUMAN` | Has `blocked-human`, `blocked-manual`, or `do-not-merge` label | No action — human-gated. Highest priority: overrides all other rules. |
| 2 | `sweeper:CLOSE_STALE` | `updatedAt > 60 days` AND `mergeable != MERGEABLE` AND no `active` label | PR closed with stale comment. User can reopen. |
| 3 | `sweeper:CLOSE_DRAFT` | `isDraft == true` AND `updatedAt > 30 days` | PR closed with draft-stale comment. User can reopen. |
| 4 | `sweeper:NEEDS_REBASE` | `mergeable == CONFLICTING` AND `updatedAt ≤ 30 days` | Flagged for manual rebase. No automated mutation beyond label + comment. |
| 5 | `sweeper:NEEDS_CI_FIX` | `mergeable == MERGEABLE` AND CI has `FAILURE` AND `updatedAt ≤ 30 days` | Specialist dispatched to diagnose + fix failing checks. |
| 6 | `sweeper:NEEDS_REVIEW_FIX` | `reviewDecision == CHANGES_REQUESTED` AND `updatedAt ≤ 30 days` | Author notified via comment. No automated fix. |
| 7 (fallback) | `sweeper:HOLD_HUMAN` | Does not match any above | Requires human judgement. |

### Notes on thresholds

- **60-day stale threshold** for `CLOSE_STALE`: conservative — PRs less than
  60 days old may still have context in the author's head. Increase to 90d if
  too aggressive for your workflow.
- **30-day draft threshold** for `CLOSE_DRAFT`: draft PRs are explicitly
  work-in-progress; 30 days without a push suggests abandonment.
- **30-day recency window** for `NEEDS_REBASE`, `NEEDS_CI_FIX`,
  `NEEDS_REVIEW_FIX`: PRs updated within 30 days are considered active enough
  to invest automated effort in fixing.

---

## Action Flow

```
NEEDS_ATTENTION PR
        │
        ▼
┌───────────────────┐
│ blocked-* label?  │──YES──> sweeper:HOLD_HUMAN (no action)
└───────────────────┘
        │ NO
        ▼
┌──────────────────────────────┐
│ updatedAt >60d AND           │
│ not MERGEABLE AND no active? │──YES──> sweeper:CLOSE_STALE ──> gh pr close
└──────────────────────────────┘
        │ NO
        ▼
┌──────────────────────────┐
│ isDraft AND updatedAt    │
│ >30d?                    │──YES──> sweeper:CLOSE_DRAFT ──> gh pr close
└──────────────────────────┘
        │ NO
        ▼
┌──────────────────────────────┐
│ CONFLICTING AND             │
│ updatedAt ≤30d?             │──YES──> sweeper:NEEDS_REBASE (flag, no close)
└──────────────────────────────┘
        │ NO
        ▼
┌──────────────────────────────┐
│ MERGEABLE AND CI FAILURE AND │
│ updatedAt ≤30d?             │──YES──> sweeper:NEEDS_CI_FIX (dispatch specialist)
└──────────────────────────────┘
        │ NO
        ▼
┌──────────────────────────────┐
│ CHANGES_REQUESTED AND        │
│ updatedAt ≤30d?             │──YES──> sweeper:NEEDS_REVIEW_FIX (author action)
└──────────────────────────────┘
        │ NO (fallback)
        ▼
   sweeper:HOLD_HUMAN (human judgement)
```

---

## Mutations

The triage pass performs three categories of mutations (only with `--apply`):

1. **Label** — applies exactly one `sweeper:*` label to each PR via
   `gh pr edit --add-label`. Idempotent: repeated runs do not duplicate labels.

2. **Comment** — posts a `## sweeper triage: <LABEL>` comment with a 2-line
   rationale + "what happens next" explanation. Idempotent: checks for existing
   triage comment marker before posting.

3. **Close** (only for `CLOSE_STALE` and `CLOSE_DRAFT`) — posts a close-reason
   comment then calls `gh pr close`. Users can reopen any closed PR via GitHub
   UI or `gh pr reopen`.

---

## Labels Auto-Created

When `--apply` is passed, triage labels are created in each target repo if they
do not already exist. Colors and descriptions:

| Label | Hex Color | Description |
|-------|-----------|-------------|
| `sweeper:CLOSE_STALE` | `#b60205` (red) | 60+ days stale, not mergeable |
| `sweeper:CLOSE_DRAFT` | `#e4e669` (yellow) | Draft 30+ days stale |
| `sweeper:NEEDS_REBASE` | `#fbca04` (gold) | Merge conflicts — needs manual rebase |
| `sweeper:NEEDS_CI_FIX` | `#d93f0b` (orange-red) | CI failing — specialist dispatched |
| `sweeper:NEEDS_REVIEW_FIX` | `#f9d0c4` (pink) | Reviewer requested changes |
| `sweeper:HOLD_HUMAN` | `#0075ca` (blue) | Human-gated — no auto action |

---

## Output Manifest

The manifest is a Markdown file written to
`~/.claude/context/hive/sweep-triage-<YYYY-MM-DD>.md`. Structure:

```
# PR Sweeper Triage Manifest

**Generated:** <ISO8601>
**Scope:** ${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}
**Mode:** TRIAGE+APPLY

## Summary
| Metric | Count |

## Triage Sub-Classification Rules
| Label | Criteria | Auto-action |

## Per-Repo Detail

### org/repo-name
| # | Title | updatedAt | Verdict | Action |
```

---

## Safety Constraints

- `CLOSE_STALE` and `CLOSE_DRAFT` thresholds are intentionally conservative.
  60-day stale + not mergeable is a strong signal of abandonment.
- The `active` label exempts a PR from `CLOSE_STALE` regardless of age.
- Bot-authored PRs (Dependabot, Renovate) are always skipped.
- Existing `sweeper:*` labels are not removed or changed in subsequent runs
  (label idempotency — `gh pr edit --add-label` is additive).
- `HOLD_HUMAN` always wins when a hard-block label is present.
- This pass does NOT: reopen PRs, rebase branches, merge, retitle, or push
  any code. It only labels, comments, and closes.

---

## Relationship to Standard Sweep Mode

The standard `--apply` (SWEEP_READY) mode and `--triage` mode target different
PR populations and are designed to be run together:

```bash
# Step 1: Label merge-ready PRs (existing SWEEP_READY path)
bash scripts/pr-sweeper.sh --apply

# Step 2: Triage the NEEDS_ATTENTION remainder
bash scripts/pr-sweeper.sh --triage --apply
```

The nightly-puffin pipeline runs both steps on its maintenance cadence.
