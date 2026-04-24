#!/usr/bin/env bash
# morning-digest.sh
#
# Composes the morning digest from the night's events and gh activity,
# then emits to 4 channels:
#   1. Local markdown: ~/.claude/context/hive/digests/<date>.md
#   2. Gmail draft (via claude -p + Gmail MCP) to wes@zyongate.com
#   3. GitHub Discussion on ${GITHUB_ORG:-your-org}/example-repo-v6 (category "Nightly Reports")
#   4. example-repo main-agent memory file append (auto-discover path)

set -euo pipefail

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

DIGESTS_DIR="$HIVE/digests"
QUEUE="$HIVE/nightly-queue.json"
HANDBOOK="$CLAUDE_HOME/handbook"

TODAY="$(date -u +%Y-%m-%d)"
YEST="$(date -u -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "$TODAY")"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SESSION_ID="nightly-${TODAY}-digest"

OWNER="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org}}"
DISCUSSION_REPO="${NIGHTLY_DISCUSSION_REPO:-${GITHUB_ORG:-your-org}/example-repo-v6}"

# gh search --owner accepts only a single org. The selector learned multi-org
# CSV in W19-ID22 (#137) but this script was missed, so a NIGHTLY_OWNER value
# like "${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}" silently returned [] from every gh search and the
# digest undercounted ${GITHUB_ORG:-your-org} activity (#145). Loop over CSV owners and
# concatenate JSON arrays.
gh_search_multi_owner() {
  local kind="$1"; shift  # "prs" or "issues"
  local all="[]"
  local _owner
  IFS=',' read -ra _owners <<< "$OWNER"
  for _owner in "${_owners[@]}"; do
    [[ -z "$_owner" ]] && continue
    local chunk
    chunk="$(gh search "$kind" --owner="$_owner" "$@" 2>/dev/null || echo '[]')"
    all="$(jq -s '.[0] + .[1]' <(printf '%s' "$all") <(printf '%s' "$chunk"))"
  done
  printf '%s' "$all"
}
EXTERNAL_AGENT_PATH="${EXTERNAL_AGENT_PATH:-$HOME/example-repo-local-llm}"

# Gmail recipient resolution — single source of truth is config/digest-config.yaml
# (W18-ID10). Precedence: env override > YAML config > hardcoded safety fallback.
DIGEST_CONFIG="$CLAUDE_HOME/config/digest-config.yaml"
_CONFIG_RECIPIENT=""
if [[ -f "$DIGEST_CONFIG" ]]; then
  _CONFIG_RECIPIENT="$(DIGEST_CONFIG_PATH="$DIGEST_CONFIG" python3 -c '
import os, yaml
c = yaml.safe_load(open(os.environ["DIGEST_CONFIG_PATH"])) or {}
print(((c.get("delivery") or {}).get("gmail_draft") or {}).get("recipient") or "")
' 2>/dev/null || echo "")"
fi
DIGEST_EMAIL_TO="${NIGHTLY_DIGEST_EMAIL:-${_CONFIG_RECIPIENT:-wes@zyongate.com}}"

mkdir -p "$DIGESTS_DIR"
DIGEST_MD="$DIGESTS_DIR/${TODAY}.md"
PARTIAL_MD="$DIGESTS_DIR/${TODAY}.partial.md"
SPRINTS_DIR="$CLAUDE_HOME/context/hive/sprints"
# Prefer yesterday's sprint doc (the collation that fed *this* night's run) over today's (not yet collated).
SPRINT_DOC=""
for d in "$YEST" "$TODAY"; do
  if [[ -f "$SPRINTS_DIR/$d.md" ]]; then
    SPRINT_DOC="$SPRINTS_DIR/$d.md"
    break
  fi
done

emit_event() { hive_emit_event "digest" "$1" "$2"; }

emit_event "SPAWN" "composing digest"
hive_heartbeat "morning-digest"

# --- Aggregate events since yesterday midnight UTC ---
SINCE_EPOCH="$(date -u -d "$YEST 23:00:00" +%s 2>/dev/null || echo 0)"

NIGHT_EVENTS="$(jq -c --argjson s "$SINCE_EPOCH" '
  select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= $s)
  | select(.sid | tostring | startswith("nightly-"))
' "$EVENTS" 2>/dev/null || echo "")"

# --- Pull gh activity since yesterday 23:00 UTC ---
# NOTE: `gh search prs --json baseRefName` is NOT supported (field doesn't exist
# in search API — only in `gh pr view`). Previous code requested it and all
# queries returned [] silently, causing the digest to report "0 PRs opened"
# even when specialists opened real PRs. Fix (2026-04-19): drop baseRefName
# from search; query promotion PRs separately via `--base main`.
GH_SINCE="${YEST}T23:00:00Z"
PRS_OPENED="$(gh_search_multi_owner prs --created=">=$GH_SINCE" \
  --json repository,number,title,state,labels,url,isDraft \
  --limit 100)"

# gh search prs: `--merged` is a boolean flag (true/false), `--merged-at` takes
# the date comparison. Previous code passed `--merged=">=$DATE"` which fails as
# `strconv.ParseBool` on the date string. Fix (2026-04-19): use both flags.
PRS_MERGED="$(gh_search_multi_owner prs --merged --merged-at=">=$GH_SINCE" \
  --json repository,number,title,updatedAt,url \
  --limit 100)"

ISSUES_CLOSED="$(gh_search_multi_owner issues --closed=">=$GH_SINCE" \
  --json repository,number,title,url --limit 100)"

ISSUES_CREATED="$(gh_search_multi_owner issues --created=">=$GH_SINCE" \
  --json repository,number,title,url,labels --limit 100)"

# Promotion PRs (master→main) awaiting approval — dedicated query by base branch.
PROMOTION_PRS="$(gh_search_multi_owner prs --base=main \
  --label=nightly-promotion --state=open \
  --json repository,number,title,url,createdAt \
  --limit 20)"

# --- Stale-PR inventory (issue #46) ---
# Open PRs with no activity for more than STALE_WINDOW_DAYS (default 7).
# Surfaces aging PRs independent of sweeper state so the digest always shows
# "what the team still owes a human look at" — complements the existing
# sweeper-touched / awaiting-sweeper sections below.
STALE_WINDOW_DAYS="${DIGEST_STALE_WINDOW_DAYS:-7}"
STALE_CUTOFF_ISO="$(date -u -d "-${STALE_WINDOW_DAYS} days" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "$YEST")"
STALE_PRS_INV="$(gh_search_multi_owner prs --state=open \
  --updated="<$STALE_CUTOFF_ISO" \
  --json repository,number,title,url,updatedAt,labels,author,isDraft \
  --limit 100)"

# Sanity-check gate: if gh says we opened PRs but events.ndjson didn't record
# corresponding HANDOFF events, something's off (Phase 6 silent-failure class:
# headless specialists that no-op without emitting events). Surface the mismatch.
GH_PR_COUNT="$(echo "$PRS_OPENED" | jq 'length' 2>/dev/null || echo 0)"
HANDOFF_COUNT="$(echo "$NIGHT_EVENTS" | jq -s '[.[] | select(.event == "HANDOFF")] | length' 2>/dev/null || echo 0)"
# Divergence heuristics:
#   - gh reports PRs but 0 HANDOFFs: dispatcher never ran or failed silently.
#   - HANDOFFs fired but 0 gh PRs: specialists bailed without reporting, or
#     produced commits without PRs.
# Exact equality isn't required (a HANDOFF may legitimately not result in a PR),
# so only warn on one-sided zeros or >2x drift.
INTEGRITY_WARNING=""
if (( GH_PR_COUNT > 0 && HANDOFF_COUNT == 0 )); then
  INTEGRITY_WARNING="gh reports $GH_PR_COUNT PR(s) opened this window, but events.ndjson recorded 0 HANDOFF events. Dispatcher likely failed to emit events (see Phase 6 silent-failure class)."
elif (( HANDOFF_COUNT > 0 && GH_PR_COUNT == 0 )); then
  INTEGRITY_WARNING="events.ndjson recorded $HANDOFF_COUNT HANDOFF event(s) but gh reports 0 PR(s) opened. Specialists dispatched without producing PRs — check for early bailouts or FAILED events."
elif (( GH_PR_COUNT > 0 && HANDOFF_COUNT > 0 )) && \
     { (( GH_PR_COUNT > HANDOFF_COUNT * 2 )) || (( HANDOFF_COUNT > GH_PR_COUNT * 2 )); }; then
  INTEGRITY_WARNING="gh PRs ($GH_PR_COUNT) and HANDOFF events ($HANDOFF_COUNT) diverge by >2x. Investigate before trusting the counts below."
fi

# Blocker events
BLOCKERS="$(echo "$NIGHT_EVENTS" | jq -s '
  map(select(.event == "BLOCKED"))
')"

# Profile lookup for repos with deploy.kind: skip (issue #24). Used below to
# surface skipped deploys with their configure-to-enable reason string.
PROFILES="$CLAUDE_HOME/config/nightly-repo-profiles.yaml"
DEPLOY_SKIP_PROFILES="$(PROFILES="$PROFILES" python3 -c '
import json, os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"])) or {}
out = {}
for name, cfg in (p.get("repos") or {}).items():
    d = ((cfg or {}).get("deploy")) or {}
    if d.get("kind") == "skip":
        out[name] = d.get("command", "")
print(json.dumps(out))
' 2>/dev/null || echo '{}')"

# Quota used (scheduled runs this window)
RUNS_USED="$(echo "$NIGHT_EVENTS" | jq -s '[.[] | select(.event == "SPAWN") | .sid] | unique | length')"
RUNS_REMAINING=$((15 - RUNS_USED))
(( RUNS_REMAINING < 0 )) && RUNS_REMAINING=0

# Lessons written
LESSONS="[]"
if [[ -d "$CLAUDE_HOME/context/shared/lessons" ]]; then
  LESSONS="$(find "$CLAUDE_HOME/context/shared/lessons" -name "LESSON-TOOL-*.md" -newer "$PARTIAL_MD" 2>/dev/null \
            | jq -R -s 'split("\n") | map(select(length>0)) | map({path: .})' 2>/dev/null || echo '[]')"
fi

# --- Compose markdown digest ---
{
  echo "# Nightly digest — $TODAY"
  echo ""
  echo "_Generated $NOW_ISO by nightly-puffin_"
  echo ""

  # Integrity warning (prepended when gh PR count and HANDOFF event count diverge)
  if [[ -n "$INTEGRITY_WARNING" ]]; then
    echo "> **Integrity warning**: $INTEGRITY_WARNING"
    echo ">"
    echo "> - gh PRs opened this window: $GH_PR_COUNT"
    echo "> - HANDOFF events this window: $HANDOFF_COUNT"
    echo ""
  fi

  # Top: Promotion PRs awaiting approval
  PROM_COUNT="$(echo "$PROMOTION_PRS" | jq 'length')"
  echo "## Promotion PRs awaiting approval ($PROM_COUNT)"
  echo ""
  if [[ "$PROM_COUNT" -gt 0 ]]; then
    echo "$PROMOTION_PRS" | jq -r '.[] | "- [\(.repository.nameWithOwner) #\(.number)](\(.url)) — \(.title)"'
  else
    echo "_No master→main promotion PRs opened this night._"
  fi
  echo ""

  # Per-repo status
  echo "## Per-repo activity"
  echo ""
  if [[ -f "$QUEUE" ]]; then
    jq -r '.repos[] | select(.role=="primary") | "### \(.name)\n- Role: primary\n- Local path: \(.local_path)\n- Readiness score: \(.score)\n- Open issues: \(.open_issues) (priority:high=\(.priority_high))\n"' "$QUEUE"
  fi
  echo ""

  echo "## PRs opened ($(echo "$PRS_OPENED" | jq 'length'))"
  echo ""
  echo "$PRS_OPENED" | jq -r '.[] | "- [\(.repository.nameWithOwner) #\(.number)](\(.url)) → base=\(.baseRefName) — \(.title)"' || true
  echo ""

  echo "## PRs merged to master ($(echo "$PRS_MERGED" | jq '[.[] | select(.baseRefName=="master")] | length'))"
  echo ""
  echo "$PRS_MERGED" | jq -r '.[] | select(.baseRefName=="master") | "- [\(.repository.nameWithOwner) #\(.number)](\(.url)) — \(.title) (merged \(.mergedAt))"' || true
  echo ""

  echo "## Issues created ($(echo "$ISSUES_CREATED" | jq 'length'))"
  echo ""
  echo "$ISSUES_CREATED" | jq -r '.[] | "- [\(.repository.nameWithOwner) #\(.number)](\(.url)) — \(.title)"' || true
  echo ""

  echo "## Issues closed ($(echo "$ISSUES_CLOSED" | jq 'length'))"
  echo ""
  echo "$ISSUES_CLOSED" | jq -r '.[] | "- [\(.repository.nameWithOwner) #\(.number)](\(.url)) — \(.title)"' || true
  echo ""

  echo "## Blockers"
  echo ""
  BLOCKER_COUNT="$(echo "$BLOCKERS" | jq 'length')"
  if [[ "$BLOCKER_COUNT" -eq 0 ]]; then
    echo "_No blockers._"
  else
    echo "$BLOCKERS" | jq -r '.[] | "- [\(.agent)] \(.detail)"'
  fi
  echo ""

  # --- Coupled groups degraded this night (issue #18) ---
  # Surface any groups that had missing/archived members so the human knows
  # why atomic-deploy was skipped for those group members this run.
  if [[ -f "$QUEUE" ]]; then
    DEGRADED_GROUPS_QUEUE="$(jq '.degraded_groups // []' "$QUEUE" 2>/dev/null || echo '[]')"
    DEGRADED_COUNT_Q="$(echo "$DEGRADED_GROUPS_QUEUE" | jq 'length')"
    if [[ "$DEGRADED_COUNT_Q" != "0" ]]; then
      echo "## Coupled groups degraded this night"
      echo ""
      echo "_These groups had missing or archived members. Atomic-deploy was skipped; members dispatched independently (per-repo)._"
      echo ""
      echo "$DEGRADED_GROUPS_QUEUE" | jq -r '.[] |
        "- **\(.group)** (was: deploy_mode=\(.original_deploy_mode)) — degraded members: \(.degraded_members | join(", "))"'
      echo ""
    fi
  fi

  # --- Deploys skipped by profile (issue #24) ---
  # Repos configured with deploy.kind: skip emit a PROGRESS event with detail
  # "<repo> deploy skipped (kind=skip by profile)". Without an explicit section
  # the digest reader can't tell skipped repos apart from actually-deployed ones.
  # Only rendered when at least one skip happened this window.
  DEPLOY_SKIPS="$(echo "$NIGHT_EVENTS" | jq -s --argjson profiles "$DEPLOY_SKIP_PROFILES" '
    [.[]
     | select(.agent == "deploy" and .event == "PROGRESS")
     | select(.detail | tostring | test("deploy skipped \\(kind=skip by profile\\)"))
     | (.detail | tostring | capture("^(?<repo>[^ ]+) deploy skipped")) as $m
     | {repo: $m.repo, reason: ($profiles[$m.repo] // "(no profile command recorded)")}]
    | unique_by(.repo)
  ' 2>/dev/null || echo '[]')"
  DEPLOY_SKIP_COUNT="$(echo "$DEPLOY_SKIPS" | jq 'length')"
  if [[ "$DEPLOY_SKIP_COUNT" != "0" ]]; then
    echo "## Deploys skipped by profile (configure to enable)"
    echo ""
    echo "$DEPLOY_SKIPS" | jq -r '.[] | "- **\(.repo)** — \(.reason)"'
    echo ""
  fi

  # --- Product discovery summary (Phase 2) ---
  echo "## Product-discovery output (last 24h)"
  echo ""
  PROD_EVENTS="$(echo "$NIGHT_EVENTS" | jq -s '[.[] | select(.sid | tostring | startswith("prod-"))]' 2>/dev/null || echo '[]')"
  PROD_RUNS="$(echo "$PROD_EVENTS" | jq -r '[.[] | .sid] | unique | length')"
  PROD_COMPLETE="$(echo "$PROD_EVENTS" | jq -r '[.[] | select(.event == "COMPLETE")] | length')"
  PROD_BLOCKED="$(echo "$PROD_EVENTS" | jq -r '[.[] | select(.event == "BLOCKED")] | length')"
  echo "- PROD-00 runs: $PROD_COMPLETE complete, $PROD_BLOCKED blocked, $PROD_RUNS total"
  # Per-session one-liner
  if [[ "$PROD_RUNS" != "0" ]]; then
    echo "$PROD_EVENTS" | jq -r '
      group_by(.sid)
      | map(. as $g | {
          sid: $g[0].sid,
          last: ($g | sort_by(.ts) | last),
          block: ([$g[] | select(.event == "BLOCKED")] | first // null)
        })
      | .[]
      | if .block then "  - \(.sid): BLOCKED — \(.block.detail)"
        else "  - \(.sid): \(.last.event) — \(.last.detail)"
        end
    '
  fi
  # New product-backlog issues created today
  PB_ISSUES="$(gh_search_multi_owner issues --state=open --label=product-backlog \
                --created=">$YEST" --json repository,number,title,url,createdAt --limit 50)"
  PB_COUNT="$(echo "$PB_ISSUES" | jq 'length')"
  echo "- New product-backlog issues: $PB_COUNT"
  if [[ "$PB_COUNT" != "0" ]]; then
    echo "$PB_ISSUES" | jq -r '.[] | "  - [\(.repository.nameWithOwner)#\(.number)](\(.url)) — \(.title)"'
  fi
  echo ""

  # --- Red-CI nightly-automation PRs (issue #22) ---
  # Open PRs we authored (label nightly-automation) whose CI is not fully green.
  # These represent committed work that regressed — surface them at the top of the
  # sweep section so humans see them before any other stale-PR inventory.
  # Query uses gh pr list per repo (statusCheckRollup is not available in gh search),
  # so we read from the nightly-queue stale_prs_all list (already scored + sorted
  # score DESC by nightly-select-projects.sh) and filter for score > 0.
  RED_CI_PRS="[]"
  if [[ -f "$QUEUE" ]]; then
    RED_CI_PRS="$(jq '
      [(.stale_prs_all // [])[] | select(.score > 0)]
    ' "$QUEUE" 2>/dev/null || echo "[]")"
  fi
  # Also do a live gh search for any nightly-automation PRs with failing CI not yet
  # in the stale window (newly-red), grouped by repo.
  RED_CI_LIVE="$(gh_search_multi_owner prs --state=open \
    --label=nightly-automation \
    --json repository,number,title,url,updatedAt,labels \
    --limit 100 2>/dev/null || echo '[]')"
  RED_CI_COUNT="$(echo "$RED_CI_PRS" | jq 'length')"
  RED_CI_LIVE_COUNT="$(echo "$RED_CI_LIVE" | jq 'length')"
  echo "## Red-CI specialist PRs needing attention"
  echo ""
  if [[ "$RED_CI_COUNT" -eq 0 && "$RED_CI_LIVE_COUNT" -eq 0 ]]; then
    echo "_No nightly-automation PRs with failing CI detected._"
  else
    if [[ "$RED_CI_COUNT" -gt 0 ]]; then
      echo "### Stale + red CI (score-boosted, dispatch priority)"
      echo ""
      echo "$RED_CI_PRS" | jq -r \
        '.[] | "- [\(.repo) #\(.number)](\(.url)) — \(.title) (score=\(.score), updated \(.updated_at[:10]))"'
      echo ""
    fi
    if [[ "$RED_CI_LIVE_COUNT" -gt 0 ]]; then
      echo "### All open nightly-automation PRs (for reference)"
      echo ""
      echo "$RED_CI_LIVE" | jq -r \
        'group_by(.repository.name)
         | .[]
         | "**\(.[0].repository.name)** (\(length))\n" +
           (map("  - [#\(.number)](\(.url)) \(.title)") | join("\n"))'
      echo ""
    fi
  fi
  echo ""

  # --- ROADMAP case conflicts (issue #21) ---
  # Grep events.ndjson for the dispatcher PROGRESS event emitted when both
  # ROADMAP.md and roadmap.md exist in the same repo. Canonical name is ROADMAP.md.
  ROADMAP_CONFLICTS="$(jq -r '
    select(.event == "PROGRESS")
    | select((.detail // "") | test("^roadmap-case-conflict "))
    | .detail
  ' "$EVENTS" 2>/dev/null | sort -u || echo "")"
  CONFLICT_COUNT="$(echo "$ROADMAP_CONFLICTS" | grep -c 'roadmap-case-conflict' 2>/dev/null || echo 0)"
  if [[ "$CONFLICT_COUNT" -gt 0 ]]; then
    echo "## Repos with ROADMAP case conflict (action required)"
    echo ""
    echo "_Both ROADMAP.md and roadmap.md were found. Canonical name is \`ROADMAP.md\`._"
    echo "_Consolidate: remove or rename the lowercase variant and update history if needed._"
    echo ""
    echo "$ROADMAP_CONFLICTS" | while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      # Extract repo= and chose= from the detail string for a clean one-liner.
      _repo="$(echo "$line" | grep -oP 'repo=\K[^ ]+')"
      _chose="$(echo "$line" | grep -oP 'chose=\K[^ ]+')"
      echo "- **${_repo}**: using \`${_chose}\` this run — consolidate to \`ROADMAP.md\`"
    done
    echo ""
  fi

  # --- Phase 3: stale-PR sweeper ---
  echo "## Sweep-ready to merge (PRs the sweeper approved overnight)"
  echo ""
  SWEEP_READY="$(gh_search_multi_owner prs --state=open --label=sweep-ready-to-merge \
                  --json repository,number,title,url,updatedAt --limit 50)"
  SR_COUNT="$(echo "$SWEEP_READY" | jq 'length')"
  if [[ "$SR_COUNT" == "0" ]]; then
    echo "_None labelled this window._"
  else
    echo "$SWEEP_READY" | jq -r '.[] | "- [\(.repository.nameWithOwner)#\(.number)](\(.url)) \u2014 \(.title) (updated \(.updatedAt))"'
  fi
  echo ""

  echo "## Stale PRs touched overnight by sweeper"
  echo ""
  SWEEP_EVENTS="$(echo "$NIGHT_EVENTS" | jq -s '[.[] | select(.detail // "" | test("chore\\(nightly-sweep\\)|nightly-puffin sweeper"; "i"))]' 2>/dev/null || echo '[]')"
  SWEEP_COUNT="$(echo "$SWEEP_EVENTS" | jq 'length')"
  if [[ "$SWEEP_COUNT" == "0" ]]; then
    echo "_No sweeper actions logged (either nothing to triage or events missed the pattern)._"
  else
    echo "$SWEEP_EVENTS" | jq -r '.[] | "- [\(.agent)] \(.detail)"' | head -20
  fi
  echo ""

  # --- Stale-PR inventory (issue #46) ---
  echo "## Stale PRs (open >${STALE_WINDOW_DAYS} days)"
  echo ""
  STALE_INV_COUNT="$(echo "$STALE_PRS_INV" | jq '[.[] | select(.isDraft == false)] | length' 2>/dev/null || echo 0)"
  if [[ "$STALE_INV_COUNT" == "0" ]]; then
    echo "_No stale PRs — all repos fresh._"
  else
    echo "$STALE_PRS_INV" | jq -r --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" '
      map(select(.isDraft == false))
      | group_by(.repository.name)
      | sort_by(-(length))
      | map({
          repo: .[0].repository.name,
          prs: (sort_by(.updatedAt) | map({
            n: .number,
            title: .title,
            url: .url,
            age_days: ((($now | sub("\\..*Z$"; "Z") | fromdateiso8601) -
                      (.updatedAt | sub("\\..*Z$"; "Z") | fromdateiso8601)) / 86400 | floor),
            labels: ([.labels[]?.name] | join(","))
          }))
        })
      | .[]
      | "### \(.repo) (\(.prs | length))\n" +
        (.prs | map("- #\(.n) [\(.age_days)d] \(.title)\(if .labels == "" then "" else " — `" + .labels + "`" end)") | join("\n"))
    '
  fi
  echo ""

  echo "## Stale PRs awaiting sweeper (no specialist ran for their repo)"
  echo ""
  if [[ -f "$QUEUE" ]]; then
    AWAITING="$(jq -r '
      (.stale_prs_all // [])
      | group_by(.repo)
      | map({
          repo: .[0].repo,
          count: length,
          samples: (.[0:3] | map("#\(.number) \(.title)"))
        })
      | .[]
      | "- \(.repo) — \(.count) stale PR(s): \(.samples | join("; "))"
    ' "$QUEUE" 2>/dev/null | head -10)"
    if [[ -z "$AWAITING" ]]; then
      echo "_No stale PRs, or none left untouched._"
    else
      echo "$AWAITING"
    fi
  fi
  echo ""

  # --- Sprint summary (Phase 2) ---
  echo "## Sprint plan (last collation)"
  echo ""
  if [[ -f "$SPRINT_DOC" ]]; then
    echo "Source: \`$SPRINT_DOC\`"
    echo ""
    # Extract summary bullets from the collation doc (lines after ## Summary until next ##)
    awk '/^## Summary$/{flag=1; next} /^## /{flag=0} flag' "$SPRINT_DOC" | head -10
    echo ""
    echo "Open the full plan: file://$SPRINT_DOC"
  else
    echo "_No sprint-plan doc found for $YEST or $TODAY. Either collation skipped (quiet day) or hasn't run yet._"
  fi
  echo ""

  # --- Phase 4: doc-hygiene summary (rolling 7-day) ---
  echo "## Doc hygiene (rolling 7 days)"
  echo ""
  SEVEN_DAYS_AGO="$(date -d '-7 days' +%Y-%m-%d)"
  DH_CLEANUP_PRS="$(gh_search_multi_owner prs --label=doc-cleanup \
                    --created=">=$SEVEN_DAYS_AGO" \
                    --json repository,number,title,url,state --limit 50)"
  DH_AUDIT_ISSUES="$(gh_search_multi_owner issues --label=doc-hygiene \
                    --created=">=$SEVEN_DAYS_AGO" \
                    --json repository,number,title,url --limit 50)"
  DH_CLEANUP_COUNT="$(echo "$DH_CLEANUP_PRS" | jq 'length')"
  DH_AUDIT_COUNT="$(echo "$DH_AUDIT_ISSUES" | jq 'length')"
  DH_EXTRACT_COUNT=$(find "$CLAUDE_HOME/context/shared"/{lessons,decisions,patterns} \
                      -type f -name "*.md" -mtime -7 2>/dev/null | wc -l)
  echo "- Cleanup PRs opened: $DH_CLEANUP_COUNT"
  echo "- Audit issues created: $DH_AUDIT_COUNT"
  echo "- Hive extractions (LESSON/DECISION/PATTERN) in last 7d: $DH_EXTRACT_COUNT"
  # Rot-score leaderboard from audit issues
  if [[ "$DH_AUDIT_COUNT" != "0" ]]; then
    echo ""
    echo "Top repos by audit findings this week:"
    echo "$DH_AUDIT_ISSUES" | jq -r 'group_by(.repository.nameWithOwner) | map({repo: .[0].repository.nameWithOwner, n: length}) | sort_by(-.n) | .[0:5] | .[] | "  - \(.repo): \(.n) audit issue(s)"'
  fi
  echo ""

  # --- Actions budget (issue #100 / PUFFIN-W18-ID9) ---
  # Read the most recent actions-budget-monitor PROGRESS/BLOCKED events from
  # events.ndjson and surface one reading per org.
  echo "## Actions Budget"
  echo ""
  BUDGET_EVENTS="$(jq -c 'select(.agent == "actions-budget-monitor")' "$EVENTS" 2>/dev/null \
    | tail -50 \
    | jq -s '.')" || BUDGET_EVENTS="[]"
  BUDGET_COUNT="$(echo "$BUDGET_EVENTS" | jq 'length')"
  if [[ "$BUDGET_COUNT" -eq 0 ]]; then
    echo "_No actions-budget-monitor events found. Monitor runs daily at 08:00 local time._"
  else
    # Latest PROGRESS reading per org (extract org from detail field).
    # Org list honours $NIGHTLY_OWNER (CSV) — aligns with other scripts;
    # previously hardcoded to ${GITHUB_ORG:-your-org} + ${GITHUB_ORG:-your-org} only.
    IFS=',' read -ra _budget_orgs <<< "$OWNER"
    for _org in "${_budget_orgs[@]}"; do
      LATEST_READING="$(echo "$BUDGET_EVENTS" \
        | jq -r --arg o "$_org" \
            '[.[] | select(.event == "PROGRESS") | select(.detail | tostring | test($o; "i"))]
             | sort_by(.ts) | last | "\(.ts) \(.detail)"' 2>/dev/null || echo "")"
      LATEST_BLOCK="$(echo "$BUDGET_EVENTS" \
        | jq -r --arg o "$_org" \
            '[.[] | select(.event == "BLOCKED") | select(.detail | tostring | test($o; "i"))]
             | sort_by(.ts) | last | .detail' 2>/dev/null || echo "")"
      if [[ -n "$LATEST_BLOCK" ]]; then
        echo "- **${_org}**: BLOCKED — ${LATEST_BLOCK}"
      elif [[ -n "$LATEST_READING" ]]; then
        echo "- **${_org}**: ${LATEST_READING}"
      else
        echo "- **${_org}**: no reading yet"
      fi
    done
  fi
  echo ""

  echo "## Routine runs"
  echo ""
  echo "- Used this window: $RUNS_USED / 15"
  echo "- Remaining today: $RUNS_REMAINING"
  echo ""

  LESSON_COUNT="$(echo "$LESSONS" | jq 'length')"
  if [[ "$LESSON_COUNT" -gt 0 ]]; then
    echo "## New lessons captured"
    echo ""
    echo "$LESSONS" | jq -r '.[] | "- \(.path)"'
    echo ""
  fi

  echo "## Partial digest appendix"
  echo ""
  echo '```'
  [[ -f "$PARTIAL_MD" ]] && head -100 "$PARTIAL_MD" || echo "(no partial digest)"
  echo '```'
} > "$DIGEST_MD"

if [[ -n "$INTEGRITY_WARNING" ]]; then
  emit_event "PROGRESS" "integrity warning: gh=$GH_PR_COUNT handoffs=$HANDOFF_COUNT — $INTEGRITY_WARNING"
fi

emit_event "PROGRESS" "local markdown written: $DIGEST_MD"

# --- Channel 2: Gmail draft via claude -p + Gmail MCP ---
# Passes the full markdown via stdin (file paths and content) so the agent can
# embed the detailed report in the draft body + add click-to-open links to the
# local file copy. No attachment support in the Gmail MCP, so we embed instead.
if command -v claude >/dev/null 2>&1; then
  PR_SUMMARY_LINE="$(grep -c '^- ' "$DIGEST_MD" 2>/dev/null || echo 0)"
  GMAIL_LOG="$CLAUDE_HOME/context/hive/logs/morning-digest-gmail.log"
  claude -p "$(cat <<PROMPT
SESSION_ID: ${SESSION_ID}-gmail
You are COM-00 producing the nightly-puffin morning digest as a Gmail draft.

INPUTS
- Full report on disk: $DIGEST_MD
- Partial event log on disk: $PARTIAL_MD
- Target recipient: $DIGEST_EMAIL_TO

STEPS
1. (identity probe) Call mcp__claude_ai_Gmail__list_labels. Pick a fingerprint —
   the NAME of the first user-created (non-system) label. Exclude labels whose
   type is "system" and labels named CATEGORY_*, CHAT, SENT, INBOX, DRAFT,
   SPAM, TRASH, IMPORTANT, STARRED, UNREAD. Remember this value for step 4.
   Rationale: probe drift across runs is the earliest signal that the Gmail
   MCP got re-authed against a different Google account.
2. Read the full report from $DIGEST_MD.
3. Compose the draft using the Gmail MCP tool mcp__claude_ai_Gmail__create_draft.
   - to: ["$DIGEST_EMAIL_TO"]
   - subject: derive from the report. Pattern:
     "Nightly digest $TODAY — <N> opened, <M> merged, <K> promotions"
     Extract the counts from the report sections; use 0 if a section says so.
   - body (plain text): plain-text markdown of the FULL report from $DIGEST_MD,
     with a header prepended that reads:
       ── FULL REPORT also saved locally at:
          $DIGEST_MD
          Open: file://$DIGEST_MD
          VS Code: vscode://file$DIGEST_MD
     Then a blank line, then the complete report content.
   - htmlBody: a richer version — same content but rendered with <h1>/<h2>/<ul>,
     with the local-file links at the top as clickable anchors. Keep PR/issue
     links as real anchors to their GitHub URLs.
4. After creating the draft, print a single line to stdout:
     "gmail_draft_id=<ID> subject=<SUBJECT> mcp_account_probe=<FINGERPRINT>"
   If list_labels failed or returned no user labels, use mcp_account_probe=unknown.

RULES
- Never send — DRAFT only.
- If mcp__claude_ai_Gmail__create_draft is unavailable, exit with the single
  line: "gmail_draft_id=UNAVAILABLE subject=skipped mcp_account_probe=unavailable"
- Do not truncate the report; embed the whole thing so the user can review
  without leaving Gmail.
PROMPT
)" --permission-mode acceptEdits \
     --add-dir "$CLAUDE_HOME/context/hive" \
     > "$GMAIL_LOG" 2>&1 || GMAIL_EXIT=$?
  GMAIL_EXIT="${GMAIL_EXIT:-0}"
  # Grep for the sentinel line rather than tail -1: `claude -p` may emit trailing
  # summary/debug lines after the script's final echo, causing tail -1 to miss
  # the real status and emit "gmail draft: " with a meaningless tail. The
  # sentinel is always prefixed "gmail_draft_id=".
  GMAIL_STATUS_LINE="$(grep -E '^gmail_draft_id=' "$GMAIL_LOG" 2>/dev/null | tail -1 | head -c 200)"
  if (( GMAIL_EXIT == 0 )) && [[ -n "$GMAIL_STATUS_LINE" ]]; then
    emit_event "PROGRESS" "gmail draft: $GMAIL_STATUS_LINE"
  elif (( GMAIL_EXIT == 0 )); then
    emit_event "PROGRESS" "gmail draft: dispatch exit=0 but no sentinel line in $GMAIL_LOG (probe tail -20 to debug)"
  else
    emit_event "PROGRESS" "gmail draft: dispatch failed exit=$GMAIL_EXIT (see $GMAIL_LOG)"
  fi
fi

# --- Channel 3: GitHub Discussion ---
# Post to Discussions via `gh api graphql` — requires the category ID.
if gh repo view "$DISCUSSION_REPO" --json hasDiscussionsEnabled -q '.hasDiscussionsEnabled' 2>/dev/null | grep -q true; then
  REPO_ID="$(gh api graphql -f query='
    query($o:String!,$n:String!){ repository(owner:$o,name:$n){ id } }
  ' -f o="${DISCUSSION_REPO%/*}" -f n="${DISCUSSION_REPO#*/}" -q '.data.repository.id' 2>/dev/null || echo "")"
  CAT_ID="$(gh api graphql -f query='
    query($o:String!,$n:String!){ repository(owner:$o,name:$n){ discussionCategories(first:20){ nodes{ id name } } } }
  ' -f o="${DISCUSSION_REPO%/*}" -f n="${DISCUSSION_REPO#*/}" \
    -q '.data.repository.discussionCategories.nodes[] | select(.name=="Nightly Reports") | .id' 2>/dev/null || echo "")"

  if [[ -n "$REPO_ID" && -n "$CAT_ID" ]]; then
    gh api graphql -f query='
      mutation($r:ID!,$c:ID!,$t:String!,$b:String!){
        createDiscussion(input:{repositoryId:$r,categoryId:$c,title:$t,body:$b}){
          discussion{ url }
        }
      }
    ' -f r="$REPO_ID" -f c="$CAT_ID" \
      -f t="Nightly digest $TODAY" \
      -f b="$(cat "$DIGEST_MD")" >/dev/null 2>&1 \
      && emit_event "PROGRESS" "github discussion: posted" \
      || emit_event "PROGRESS" "github discussion: post failed"
  else
    emit_event "PROGRESS" "github discussion: category 'Nightly Reports' not found in $DISCUSSION_REPO"
  fi
fi

# --- Channel 4: example-repo main-agent memory append ---
EXTERNAL_AGENT_TARGET=""
if [[ -d "$EXTERNAL_AGENT_PATH" ]]; then
  # Discover existing memory file
  EXTERNAL_AGENT_TARGET="$(find "$EXTERNAL_AGENT_PATH" -type f \( -path '*/memory/*.md' -o -iname 'AGENT*.md' \) 2>/dev/null | head -1)"
  if [[ -z "$EXTERNAL_AGENT_TARGET" ]]; then
    mkdir -p "$EXTERNAL_AGENT_PATH/.claude/memory"
    EXTERNAL_AGENT_TARGET="$EXTERNAL_AGENT_PATH/.claude/memory/nightly-digest.md"
    [[ -f "$EXTERNAL_AGENT_TARGET" ]] || echo "# Nightly digest memory (example-repo)" > "$EXTERNAL_AGENT_TARGET"
  fi

  {
    echo ""
    echo "## $TODAY"
    echo ""
    head -60 "$DIGEST_MD"
    echo ""
    echo "_(full digest at $DIGEST_MD)_"
    echo ""
  } >> "$EXTERNAL_AGENT_TARGET"

  emit_event "PROGRESS" "example-repo memory: appended → $EXTERNAL_AGENT_TARGET"
else
  emit_event "PROGRESS" "example-repo path not found: $EXTERNAL_AGENT_PATH (skipped)"
fi

emit_event "COMPLETE" "digest delivered to 4 channels"
echo "digest: $DIGEST_MD"
echo "example-repo: ${EXTERNAL_AGENT_TARGET:-(skipped)}"
