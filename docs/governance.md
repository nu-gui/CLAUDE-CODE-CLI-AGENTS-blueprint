# Governance auto-approval (Tier-1 MVP)

Closes the gap where Claude Code agents could review PRs but couldn't
**approve** them — leaving system-authored CI/build/lint fixes stuck in a
`blocked-human` state forever, even when their content was provably safe.

## How it works

```
                        ┌─────────────────────────────────┐
                        │ scripts/governance-auto-approve  │  fires 15:30 + 19:00 local time (local time)
                        └────────────────┬────────────────┘
                                         │
            ┌────────────────────────────┴────────────────────────────┐
            │                                                          │
            ▼                                                          ▼
   gh search prs                                          scripts/lib/risk-classifier
   --label nightly-automation                             classify_pr_tier <repo> <pr>
   --state open                                                       │
            │                                                          │
            └─────────────────────► tier?  ◄───────────────────────────┘
                                     │
                       ┌─────────────┼─────────────┐
                       │             │             │
                     tier 0        tier 1     tier ≥ 2
                  (no-op,       SUP-00 review     skip
                  Dependabot)   verdict
                                     │
                              ┌──────┴──────┐
                            APPROVE      REJECT
                              │             │
                  gh pr review --approve   gh api labels
                  + sweep-ready-to-merge   + governance:rejected
                  + governance-revert      + verdict comment
                  + audit comment           + audit entry
                              │             │
                              └─────┬───────┘
                                    │
                              audit log:
                  context/hive/governance-decisions.ndjson
```

The actual merge happens via the existing closure-watcher (14:43 / 18:33
local time, local time) — it picks up `sweep-ready-to-merge` PRs, gates on
`mergeable=MERGEABLE && mergeStateStatus=CLEAN`, and merges. So branch
protection / required reviews / status checks are still respected.

## Tier model

| Tier | What | Approver | Status |
|------|------|----------|--------|
| 0 | Dependabot patch+minor, lockfile-only | sweeper auto-merge | live (existing) |
| 1 | System-authored CI/build/lint fixes ≤ 30 lines, allowed paths only | sup-00-qa-governance alone | **enabled** |
| 2 | Surgical fixes ≤ 100 lines | 1 domain agent + sup-00 | scaffolded, not enabled |
| 3 | Cross-module / schema / API contract | 2 domain agents + sup-00 (3-of-3) | scaffolded, not enabled |
| 4 | Always human (you, Team Lead) | n/a | mechanical bright line |

## Tier-1 acceptance gates (all must be true)

1. PR has label `nightly-automation` (proves system-authored)
2. Title matches `^(\[[A-Z][A-Z0-9-]*\] )?(chore|fix)\((ci|nightly-sweep|...)\)`
3. Diff ≤ 30 lines, ≤ 5 files
4. Every touched path is in `tier_1.match_all.paths_allowed`
5. No touched path is in `tier_1.match_all.paths_forbidden`
6. No touched path is in `always_human.paths` (hard refusal)
7. Required checks SUCCESS: Sourcery review, Security Scan
8. Mergeable state in `[MERGEABLE]` (not CONFLICTING)
9. SUP-00 verdict: `VERDICT: APPROVE` after diff inspection

If any gate fails, the PR is logged at tier 4 with the reason and the
auto-approver leaves it for you.

## Tier-4 always-human bright line

The `always_human.paths` list in `config/governance-policy.yaml` cannot
be overridden by any per-repo rule. It locks:

- Anything matching `*.env*`, `secrets/*`, `credentials*`, `auth/*`,
  `oauth/*`, `jwt/*`
- All SQL files, migrations (Alembic, Prisma, generic)
- Telecom signaling (Kamailio cfg, dispatcher.list, dialplan.xml)
- Branch protection / CODEOWNERS / `.github/workflows/release*`
- Production deploy targets (`docker-compose.prod*`, `k8s/prod/*`,
  `terraform/*/prod/*`, `infra/prod/*`)
- The governance policy file itself
- example-repo trading strategies (`strategies/*`)

Per-repo elevations (in `per_repo_overrides.<repo>.elevate_paths`) can
push additional paths up to tier 4 but cannot lower a tier-4 path down.

## Audit trail

Every decision (apply or dry-run) is appended to
`context/hive/governance-decisions.ndjson`:

```json
{"v":1,"ts":"...","sid":"governance-...","repo":"${GITHUB_ORG:-your-org}/example-repo","pr":329,"tier":1,"decision":"approved","reasoning":"tier-1-eligible","verdict":"VERDICT: APPROVE — diff matches title; no surprises","mode":"apply"}
```

The morning-digest shows a "Governance auto-approvals (last 24h)"
section with counts + per-PR list and a pointer to this file.

## Revert window

Every auto-approved PR gets the label `governance-revert-candidate` for
the first 24h after merge. Future work: a revert-on-comment loop
listening for `/revert` on these labelled PRs. Today the label exists
purely to flag merges as "auto-approved within last 24h" so they're
easy to spot via `gh search prs --label governance-revert-candidate`.

## Schedule

| Time (local time, local time) | Service | Why |
|---|---|---|
| 15:30 | governance-auto-approve-afternoon | Between 13:17 and 16:27 mini-dispatches; catches PRs the 13:17 specialists opened |
| 19:00 | governance-auto-approve-evening | Between 16:27 and 19:37 mini-dispatches |
| 14:43 | closure-watcher (existing) | Auto-merges anything with `sweep-ready-to-merge` from morning's governance work |
| 18:33 | closure-watcher (existing) | Auto-merges anything from afternoon's governance work |

## Per-run cap

`tier_1.per_run_cap` (default 5) caps how many tier-1 PRs the auto-approver
will review and act on per fire. Skipped tier-4 PRs do NOT count toward
this cap, so the search through 50+ open `nightly-automation` PRs always
reaches the eligible ones.

## Promoting a tier

To enable Tier 2 or 3, set `enabled: true` in the policy file. **The
policy file itself is in `always_human.paths`, so any PR enabling a tier
will mechanically be tier 4 — requiring you to merge it manually.** This
prevents the auto-approver from ever expanding its own jurisdiction.

## Operator commands

```bash
# Dry-run (no mutations) — shows what WOULD be approved
bash ~/.claude/scripts/governance-auto-approve.sh --dry-run

# Apply mode — what the cron does (15:30 + 19:00 local time, local time)
bash ~/.claude/scripts/governance-auto-approve.sh --apply

# Override the per-run cap for one run
bash ~/.claude/scripts/governance-auto-approve.sh --apply --max 10

# Classify a single PR ad-hoc
bash ~/.claude/scripts/lib/risk-classifier.sh ${GITHUB_ORG:-your-org}/example-repo 329

# Inspect the audit trail
tail -20 ~/.claude/context/hive/governance-decisions.ndjson | jq .
```

## Related files

- `config/governance-policy.yaml` — single source of truth (tier-4 locked)
- `scripts/governance-auto-approve.sh` — the auto-approver
- `scripts/lib/risk-classifier.sh` — sourceable classifier function
- `~/.config/systemd/user/nightly-puffin-governance-auto-approve-*.{timer,service}`
- `scripts/morning-digest.sh` — reads `governance-decisions.ndjson`,
  surfaces in "Governance auto-approvals (last 24h)" section
