# pr-sweeper.sh

Org-wide PR sweeper for the nightly-puffin pipeline. Enumerates open PRs across
`${GITHUB_ORG:-your-org}` and `${GITHUB_ORG:-your-org}`, applies the SWEEP_READY heuristic, and (in `--apply`
mode) labels qualifying PRs and posts a one-time idempotent comment.

## Usage

```bash
# Dry-run (default — read-only, prints intentions, no mutations)
bash scripts/pr-sweeper.sh

# Dry-run explicit + redirect output
bash scripts/pr-sweeper.sh --dry-run > /tmp/sweep-test.md

# Apply mode — label PRs and post sweeper comments
bash scripts/pr-sweeper.sh --apply

# Restrict to a single org
bash scripts/pr-sweeper.sh --apply --orgs ${GITHUB_ORG:-your-org}

# Custom output path
bash scripts/pr-sweeper.sh --output /tmp/my-sweep.md
```

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--dry-run` | Yes | No mutations; print what would happen |
| `--apply` | No | Label PRs and post idempotent sweeper comments |
| `--orgs <csv>` | `${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}` | Comma-separated org list |
| `--output <path>` | `~/.claude/context/hive/sweep-report-<date>.md` | Inventory output path |

## Heuristic

A PR is classified **SWEEP_READY** only when **all** conditions are true:

1. `mergeable == "MERGEABLE"` (GitHub computed merge status)
2. `statusCheckRollup`: every entry is SUCCESS, NEUTRAL, or SKIPPED; zero FAILURE/ERROR/TIMED_OUT; zero PENDING entries older than 24 hours
3. `baseRefName` is `master` or `main` AND equals the repo's `defaultBranch`
4. PR labels do NOT include: `blocked-human`, `blocked-manual`, `needs-revision`, `draft`, `wip`, `do-not-merge`
5. `isDraft != true`
6. Author is not `dependabot[bot]` or `renovate[bot]` (those have dedicated automation)
7. Body or title matches linked-issue pattern (`Closes #N`, `Fixes #N`, `Resolves #N`) — **soft check**: missing link qualifies the PR but also adds `needs-issue-link` label

## Labels Applied (--apply mode only)

| Label | Color | Condition |
|-------|-------|-----------|
| `sweep-ready-to-merge` | `#0e8a16` (green) | All hard checks pass |
| `needs-issue-link` | `#e4e669` (yellow) | Soft check: no linked-issue syntax |

Labels are created in the repo if they don't exist (idempotent).

## Sweeper Comment

A one-time comment is posted on each SWEEP_READY PR (idempotent — existing
sweeper comments prevent re-posting):

```
## sweeper: SWEEP_READY_TO_MERGE

Heuristic match (dated <iso8601>):
- mergeable: MERGEABLE
- CI: all checks SUCCESS/NEUTRAL/SKIPPED
- base: <branch> (default for repo)
- no blocked-* / revision labels
- linked issue: <#N> (or "missing — see needs-issue-link")

No human action required. Next nightly-puffin sweep cycle will auto-merge unless
the `blocked-human` label is added, or a reviewer posts "HOLD" in a comment.
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success — all repos scanned, inventory written |
| `1` | Fatal — gh auth failure or bad flag |
| `2` | Partial — one or more repos failed API calls; inventory written for completed repos |

## Actions-Budget-Blocked CI Failures

GitHub Actions has a monthly minutes quota. When that quota is exhausted,
workflow runs return `conclusion=FAILURE` with a single annotation:

> The job was not started because an Actions budget is preventing further use.

This is indistinguishable from a real test failure in the API rollup, so sweep
triage (`--triage`) will label affected PRs `sweeper:NEEDS_CI_FIX` and the W19+
follow-up rollup issues will queue them for a specialist. **No code fix is
possible** — the checks never executed.

Specialist handling for a rollup entry whose only failure is budget-related:

1. Confirm the failure annotation on the most recent bash-lint / CI run includes
   `"Actions budget is preventing further use"`.
2. Remove `sweeper:NEEDS_CI_FIX` (the code is fine) and add `blocked-human`
   (the gate is operational, not code).
3. Comment on the PR explaining the disposition and linking the rollup.
4. Tick the rollup checklist item and close the rollup issue.

Recovery happens when the billing period resets or the user tops up the
Actions quota. After that, a reviewer can remove `blocked-human` and
re-trigger CI with `gh pr comment <N> --body "/retest"` (if configured) or
by pushing an empty commit.

## Rollback: Removing a Mis-Tagged PR

If a PR was incorrectly labeled in `--apply` mode:

```bash
# Remove sweep-ready label from a specific PR
gh pr edit <PR_NUMBER> --repo <ORG>/<REPO> --remove-label "sweep-ready-to-merge"

# Also remove needs-issue-link if present
gh pr edit <PR_NUMBER> --repo <ORG>/<REPO> --remove-label "needs-issue-link"

# Add blocked-human to prevent future auto-merge
gh pr edit <PR_NUMBER> --repo <ORG>/<REPO> --add-label "blocked-human"
```

The sweeper comment cannot be deleted automatically; it is purely informational
and the `blocked-human` label is the authoritative "do not merge" signal.

## Integration with Nightly-Puffin

The sweeper is designed to run as an intermediate stage before the merge step:

1. Stage B1/B2: specialists implement and open PRs
2. **Sweeper**: label qualifying PRs (this script in `--apply` mode)
3. Stage C2 (nightly-deploy.sh): auto-merge PRs with `sweep-ready-to-merge`

Add `blocked-human` to any PR you want to exempt from the sweep cycle.

## Auto-Rebase Pre-Pass (issue #183)

Before the main scan/merge loop, `--apply` mode (sweep, not triage) runs a
pre-pass that finds every PR labeled `sweep-ready-to-merge` whose `mergeable`
state has decayed to `CONFLICTING` (master moved on after labelling) and
calls `hive_rebase_pr` on each via:

```
fetch origin → checkout origin/<head> → rebase origin/<base> → push --force-with-lease
```

- **Cap**: `SWEEP_REBASE_CAP=5` per run, lower than the merge cap (10) because
  each rebase re-fires CI. Backlog drains gradually, not all-at-once.
- **Conflict handling**: `git rebase --abort` and emit `BLOCKED:
  rebase-conflict <repo>#<n>` — manual intervention required.
- **Idempotent**: a second invocation with no upstream movement is a no-op
  (rebase reports "Current branch is up to date" and the SHA-equality
  short-circuit skips the push).
- **Fork PRs**: refused (no push permission to the fork's head ref) — emits
  BLOCKED with reason `fork-pr`.
- **Cron-only context**: the local clone at `~/github/<org>/<name>` is
  force-checked-out to the origin tip. Any uncommitted edits in that clone
  are wiped; do not invoke this against a clone where a human is iterating.

Counts surface in the summary line as `Auto-rebased: <N> (cap=<C>)` and in
the COMPLETE event payload as `sweep_rebased=<N>
sweep_rebase_failed=<N>`.

## Rate Limit Safety

Uses `gh_api_safe` from `scripts/lib/common.sh` for all GitHub API calls.
Repos are scanned sequentially to stay well within the hourly API cap (~41 repos
= ~41 PR-list calls + label/comment calls in apply mode).
