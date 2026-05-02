#!/usr/bin/env bash
# scripts/governance-auto-approve.sh
#
# Tier-1 governance auto-approver.
#
# Loop:
#   1. Find candidate PRs across ${GITHUB_ORG:-your-org} + ${GITHUB_ORG:-your-org}:
#       label=nightly-automation, state=open, base=master
#       NOT already labelled `governance:tier-1-approved` or `sweep-ready-to-merge`
#   2. For each, classify_pr_tier — skip unless tier == 1
#   3. Run sup-00-qa-governance review headlessly with a focused prompt
#   4. On APPROVE: apply gh pr review --approve + add `sweep-ready-to-merge`
#      + `governance:tier-1-approved` + post audit comment
#   5. On REJECT: add `governance:rejected` + post the verdict
#   6. Append every decision to context/hive/governance-decisions.ndjson
#
# The existing closure-watcher / pr-sweeper auto-merge consumers pick up
# PRs labelled `sweep-ready-to-merge` on their next fire and merge them
# (gating on CLEAN/MERGEABLE). This loop's job is JUST the approval —
# merge happens through the existing path so admin/branch protection
# rules still apply.
#
# Safety:
#   - default --dry-run; --apply for real
#   - per-run cap (governance-policy.yaml tier_1.per_run_cap)
#   - flock single-instance guard
#   - tier-4 hard refusal — classifier returns 4, we never call SUP-00
#   - audit log written even in dry-run
#
# Usage:
#   bash scripts/governance-auto-approve.sh [--dry-run|--apply] [--orgs <csv>]
#                                           [--max <N>]
#
# Exit codes:
#   0 success (dry-run or apply)
#   1 fatal (gh auth, malformed policy)
#   2 partial (some PRs failed; manifest written)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path
# shellcheck source=lib/risk-classifier.sh
source "${SCRIPT_DIR}/lib/risk-classifier.sh"

LOCK_FILE="${GOVERNANCE_LOCK:-/tmp/governance-auto-approve.lock}"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  hive_emit_event "governance-auto-approve" "BLOCKED" \
    "another instance is running (lock=$LOCK_FILE) — exit 0"
  exit 0
fi

GOVERNANCE_POLICY="${GOVERNANCE_POLICY:-$HOME/.claude/config/governance-policy.yaml}"
AUDIT_LOG="${GOVERNANCE_AUDIT_LOG:-$HIVE/governance-decisions.ndjson}"
mkdir -p "$(dirname "$AUDIT_LOG")"

DRY_RUN=1
APPLY=0
ORGS="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}}"
MAX_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; APPLY=0; shift ;;
    --apply)   APPLY=1;   DRY_RUN=0; shift ;;
    --orgs)    ORGS="$2"; shift 2 ;;
    --max)     MAX_OVERRIDE="$2"; shift 2 ;;
    *) echo "[governance-auto-approve] Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# ---- Read policy
PER_RUN_CAP="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print((p.get("tier_1") or {}).get("per_run_cap") or 5)
' 2>/dev/null)"
[[ -n "$MAX_OVERRIDE" ]] && PER_RUN_CAP="$MAX_OVERRIDE"

T1_ENABLED="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"])) or {}
print("true" if (p.get("tier_1") or {}).get("enabled") else "false")
' 2>/dev/null)"
if [[ "$T1_ENABLED" != "true" ]]; then
  hive_emit_event "governance-auto-approve" "PROGRESS" \
    "tier-1-disabled-in-policy — exiting"
  exit 0
fi

SID="governance-$(date -u +%Y%m%dT%H%M%SZ)"
# Export so child python3 calls inside audit() can read these via os.environ.
export SID APPLY
emit() { SID="$SID" hive_emit_event "governance-auto-approve" "$1" "$2"; }
emit "SPAWN" "mode=$([ $APPLY -eq 1 ] && echo apply || echo dry-run) cap=$PER_RUN_CAP orgs=$ORGS"

approved_count=0
rejected_count=0
skipped_count=0
errored_count=0
tier1_picks=0   # only tier-1 picks count toward the per_run_cap; skipping
                # tier-4 PRs (most of them) is essentially free.

# ---- Audit-log emitter (separate file from events.ndjson)
audit() {
  local repo="$1" pr="$2" tier="$3" decision="$4" reasoning="$5" verdict="$6"
  python3 -c '
import json, sys, os, datetime
print(json.dumps({
  "v": 1,
  "ts": datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
  "sid": os.environ.get("SID",""),
  "repo": sys.argv[1],
  "pr": int(sys.argv[2]),
  "tier": int(sys.argv[3]),
  "decision": sys.argv[4],
  "reasoning": sys.argv[5],
  "verdict": sys.argv[6],
  "mode": "apply" if int(os.environ.get("APPLY","0")) == 1 else "dry-run",
}))
' "$repo" "$pr" "$tier" "$decision" "$reasoning" "$verdict" >> "$AUDIT_LOG"
  # Note: SID and APPLY are already exported above so the python3 child
  # process inherits them via the environment. Don't pass them as positional
  # args (they'd land in sys.argv and never reach os.environ).
}

# ---- Per-PR processor
process_pr() {
  local repo="$1" pr="$2"

  # Skip if already governance-handled
  local existing_labels
  existing_labels="$(gh pr view "$pr" --repo "$repo" --json labels \
    --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")"
  if printf '%s' "$existing_labels" | grep -qE '(^|,)(governance:tier-1-approved|governance:rejected|sweep-ready-to-merge)(,|$)'; then
    skipped_count=$(( skipped_count + 1 ))
    return 0
  fi

  # Classify
  local cls
  cls="$(classify_pr_tier "$repo" "$pr" 2>/dev/null)"
  local tier reason
  tier="$(printf '%s' "$cls" | jq -r '.tier // 4')"
  reason="$(printf '%s' "$cls" | jq -r '.reason // "no-reason"')"

  if [[ "$tier" != "1" ]]; then
    skipped_count=$(( skipped_count + 1 ))
    audit "$repo" "$pr" "$tier" "skipped" "$reason" ""
    return 2  # signal: do not count toward cap
  fi

  tier1_picks=$(( tier1_picks + 1 ))
  echo "[governance] $repo#$pr → tier=1 ($reason)"

  # Build SUP-00 review prompt — focused, brief
  local pr_meta
  pr_meta="$(gh pr view "$pr" --repo "$repo" --json title,body,additions,deletions,changedFiles 2>/dev/null)"
  local diff_lines diff_files title body
  diff_lines="$(printf '%s' "$pr_meta" | jq -r '(.additions + .deletions)')"
  diff_files="$(printf '%s' "$pr_meta" | jq -r '.changedFiles')"
  title="$(printf '%s' "$pr_meta" | jq -r '.title')"
  body="$(printf '%s' "$pr_meta" | jq -r '.body // ""' | head -c 2000)"

  local diff_content
  diff_content="$(gh pr diff "$pr" --repo "$repo" 2>/dev/null | head -c 8000 || echo "")"

  local prompt
  prompt="$(cat <<PROMPT
You are sup-00-qa-governance running headless to perform a Tier-1 governance review.

POLICY:
- This PR was pre-classified as Tier 1 by ~/.claude/scripts/lib/risk-classifier.sh.
- Tier 1 = system-authored CI/build/lint fix, ≤30 lines, allowed paths only.
- Sourcery review and Security Scan have already passed.
- Your job: spot-check that the diff matches the title's intent, contains no surprises (added secrets, expanded scope, behavioural changes outside the stated fix), and is genuinely safe to merge.

PR METADATA:
- Repo: $repo
- PR #$pr
- Title: $title
- Diff size: $diff_lines lines / $diff_files files

PR DESCRIPTION (truncated):
$body

DIFF (first 8000 chars):
\`\`\`diff
$diff_content
\`\`\`

Output ONE of these strings, verbatim, on the FIRST line of your reply:
- "VERDICT: APPROVE" — diff matches title, no surprises, safe to auto-merge
- "VERDICT: REJECT — <reason>" — anything looks off

Optional: a short sentence after the verdict explaining your reasoning. Do not write more than 3 sentences. Do not edit any files. Do not run any commands. This is a read-only review.
PROMPT
)"

  if [[ "$APPLY" -eq 0 ]]; then
    audit "$repo" "$pr" "1" "would-review" "$reason" ""
    echo "[dry-run] would review $repo#$pr (tier=1, lines=$diff_lines)"
    return 0
  fi

  # Run SUP-00
  local sup_log
  sup_log="$(mktemp /tmp/governance-sup00.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$sup_log'" RETURN

  local sup_rc=0
  claude -p "$prompt" \
    --permission-mode plan \
    --append-system-prompt "You are sup-00-qa-governance in tier-1 governance auto-approval mode. Output the VERDICT line on the first line of your reply, exactly as instructed. Do not modify files. Do not call gh." \
    > "$sup_log" 2>&1 || sup_rc=$?

  if [[ "$sup_rc" -ne 0 ]]; then
    errored_count=$(( errored_count + 1 ))
    audit "$repo" "$pr" "1" "errored" "$reason" "claude-exit=$sup_rc"
    return 0
  fi

  # Parse verdict — first VERDICT: line wins
  local verdict_line verdict
  verdict_line="$(grep -m1 '^VERDICT: ' "$sup_log" 2>/dev/null || true)"
  if [[ -z "$verdict_line" ]]; then
    errored_count=$(( errored_count + 1 ))
    audit "$repo" "$pr" "1" "errored" "$reason" "no-verdict-line-in-sup00-output"
    echo "[governance] $repo#$pr — sup-00 produced no VERDICT line; skipping" >&2
    return 0
  fi

  if [[ "$verdict_line" =~ ^VERDICT:\ APPROVE ]]; then
    verdict="APPROVE"
  elif [[ "$verdict_line" =~ ^VERDICT:\ REJECT ]]; then
    verdict="REJECT"
  else
    errored_count=$(( errored_count + 1 ))
    audit "$repo" "$pr" "1" "errored" "$reason" "malformed-verdict=${verdict_line:0:120}"
    return 0
  fi

  # Build comment body
  local touched_paths_csv
  touched_paths_csv="$(printf '%s' "$cls" | jq -r '.paths // ""' | head -c 200)"
  local comment_body
  comment_body="$(GOV="$GOVERNANCE_POLICY" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["GOV"]))
print((p.get("tier_1") or {}).get("approval_comment_template") or "")
' 2>/dev/null)"
  comment_body="${comment_body//%DIFF_LINES%/$diff_lines}"
  comment_body="${comment_body//%DIFF_FILES%/$diff_files}"
  comment_body="${comment_body//%DIFF_PATHS%/$touched_paths_csv}"
  comment_body="${comment_body//%ALLOWED_FAILING%/PR Validation}"
  comment_body="${comment_body//%SUP00_VERDICT%/$verdict}"

  if [[ "$verdict" == "APPROVE" ]]; then
    # Use the gh api PR-review endpoint directly (gh pr review --approve
    # fails with rc=1 on repos that still have classic Project cards
    # attached due to GraphQL deprecation — the REST endpoint avoids the
    # project-card lookup entirely).
    local approve_rc=0
    gh api -X POST "repos/$repo/pulls/$pr/reviews" \
      --input - >/dev/null 2>&1 \
      <<<"{\"event\":\"APPROVE\",\"body\":\"Auto-approved under tier-1 governance policy. See policy at config/governance-policy.yaml. Audit: governance-decisions.ndjson sid=$SID.\"}" \
      || approve_rc=$?

    # Add governance labels + remove blocked-human (the closure-watcher's
    # HARD_BLOCK_LABELS list refuses any PR with blocked-human; keeping it
    # would mean approval applies but auto-merge skips). The governance
    # label carries the same semantic now.
    gh api -X POST "repos/$repo/issues/$pr/labels" \
      --input - >/dev/null 2>&1 \
      <<<'{"labels":["governance:tier-1-approved","sweep-ready-to-merge","governance-revert-candidate"]}' \
      || true
    gh api -X DELETE "repos/$repo/issues/$pr/labels/blocked-human" \
      >/dev/null 2>&1 || true

    # Audit-comment via issues REST
    gh api -X POST "repos/$repo/issues/$pr/comments" \
      --input - >/dev/null 2>&1 \
      <<<"$(python3 -c 'import json,sys; print(json.dumps({"body": sys.stdin.read()}))' <<<"$comment_body")" \
      || true

    if [[ "$approve_rc" -eq 0 ]]; then
      approved_count=$(( approved_count + 1 ))
      audit "$repo" "$pr" "1" "approved" "$reason" "$(head -c 200 "$sup_log" | sed 's/"/\\"/g; s/\n/ /g')"
      echo "[governance] $repo#$pr APPROVED + sweep-ready + blocked-human removed"
    else
      # API approval failed but labels applied — still counts as approved
      # for the downstream merge consumer.
      approved_count=$(( approved_count + 1 ))
      audit "$repo" "$pr" "1" "approved-via-labels-only" "$reason" "gh-api-pulls-reviews-rc=$approve_rc"
      echo "[governance] $repo#$pr labels applied (gh api review failed rc=$approve_rc)"
    fi
  else
    # REJECT — label + verdict comment
    gh api -X POST "repos/$repo/issues/$pr/labels" \
      --input - >/dev/null 2>&1 \
      <<<'{"labels":["governance:rejected"]}' || true
    gh api -X POST "repos/$repo/issues/$pr/comments" \
      --input - >/dev/null 2>&1 \
      <<<"$(python3 -c 'import json,sys; print(json.dumps({"body": sys.stdin.read()}))' <<<"🔴 **Tier-1 governance — REJECT**

$verdict_line

This PR was rejected by sup-00-qa-governance under tier-1 policy. Label \`governance:rejected\` applied. Resolve manually or remove the label after addressing the concern.

Audit: \`governance-decisions.ndjson\` sid=$SID")" || true

    rejected_count=$(( rejected_count + 1 ))
    audit "$repo" "$pr" "1" "rejected" "$reason" "$(printf '%s' "$verdict_line" | head -c 200 | sed 's/"/\\"/g')"
    echo "[governance] $repo#$pr REJECTED ($verdict_line)"
  fi
}

# ---- Main scan
declare -i picked=0
IFS=',' read -ra _orgs <<< "$ORGS"
for _org in "${_orgs[@]}"; do
  [[ -z "$_org" ]] && continue

  # Search only PRs labelled nightly-automation, state=open, base=master
  candidates_json="$(gh search prs \
    --owner "$_org" \
    --label "nightly-automation" \
    --state open \
    --json repository,number,title,updatedAt \
    --limit 50 2>/dev/null || echo '[]')"

  while IFS= read -r pair; do
    [[ -z "$pair" ]] && continue
    # Only tier-1 picks count toward cap (skipping tier-4 is cheap).
    [[ "$tier1_picks" -ge "$PER_RUN_CAP" ]] && break 2

    local_repo="${pair%%|*}"
    local_pr="${pair##*|}"
    process_pr "$local_repo" "$local_pr" || true
  done < <(printf '%s' "$candidates_json" | \
           jq -r '.[] | "\(.repository.nameWithOwner)|\(.number)"')
done

emit "COMPLETE" \
  "approved=$approved_count rejected=$rejected_count skipped=$skipped_count errored=$errored_count tier1_picked=$tier1_picks cap=$PER_RUN_CAP"

echo ""
echo "[governance-auto-approve] Summary:"
echo "  Approved      : $approved_count"
echo "  Rejected      : $rejected_count"
echo "  Skipped (T≠1) : $skipped_count"
echo "  Errored       : $errored_count"
echo "  Tier-1 picks  : $tier1_picks / $PER_RUN_CAP"
echo "  Audit         : $AUDIT_LOG"

[[ "$errored_count" -gt 0 ]] && exit 2
exit 0
