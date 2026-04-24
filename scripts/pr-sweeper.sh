#!/usr/bin/env bash
# scripts/pr-sweeper.sh
#
# Org-wide PR sweeper — read-only inventory + label (PUFFIN-W18-ID15 / issue #113).
# Extended with --triage mode (PUFFIN-W19-ID10 / issue #131).
#
# Enumerates every open PR across ${GITHUB_ORG:-your-org} + ${GITHUB_ORG:-your-org}, applies the SWEEP_READY
# heuristic, and (in --apply mode) labels qualifying PRs and posts a one-time
# sweeper comment.
#
# In --triage mode, the NEEDS_ATTENTION bucket is re-classified into 5 actionable
# sub-buckets (each PR gets exactly one sweeper:* label):
#
#   sweeper:CLOSE_STALE      updatedAt >60d AND not MERGEABLE AND no 'active' label
#   sweeper:CLOSE_DRAFT      isDraft AND updatedAt >30d
#   sweeper:NEEDS_REBASE     CONFLICTING AND updatedAt ≤30d (flag for manual rebase)
#   sweeper:NEEDS_CI_FIX     MERGEABLE AND CI FAILURE AND updatedAt ≤30d
#   sweeper:NEEDS_REVIEW_FIX CHANGES_REQUESTED AND updatedAt ≤30d
#   sweeper:HOLD_HUMAN       has blocked-human / blocked-manual / do-not-merge label
#
# Usage:
#   bash scripts/pr-sweeper.sh [--dry-run] [--apply] [--orgs <csv>] [--output <path>]
#   bash scripts/pr-sweeper.sh --triage [--apply] [--orgs <csv>] [--output <path>]
#
# Flags:
#   --dry-run        Default. Print what would happen; no mutations.
#   --apply          Label PRs and post sweeper comments. Requires explicit opt-in.
#   --triage         Triage mode: re-classify NEEDS_ATTENTION into sub-buckets.
#                    Combine with --apply to mutate (label + close stale/draft).
#   --orgs <csv>     Comma-separated org list; default "${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}".
#   --output <path>  Inventory markdown path; default per-mode dated file in $HIVE.
#
# Heuristic for SWEEP_READY (ALL must be true):
#   1. mergeable == "MERGEABLE"
#   2. statusCheckRollup: all SUCCESS/NEUTRAL/SKIPPED; no FAILURE; no PENDING >24h
#   3. baseRefName in [master,main] AND equals repo defaultBranch
#   4. Labels NOT in: blocked-human, blocked-manual, needs-revision, draft, wip, do-not-merge
#   5. isDraft != true
#   6. Not authored by dependabot[bot] or renovate[bot]
#   7. Body or title matches linked-issue regex; if absent → NEEDS_ISSUE_LINK (still qualifies)
#
# Exit codes:
#   0  Success (dry-run or apply completed)
#   1  Fatal: gh auth failure or missing dependency
#   2  Partial: some repos failed; inventory written for completed repos

set -euo pipefail

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

HIVE_DEFAULT_AGENT="pr-sweeper"
SESSION_ID="${SESSION_ID:-${SID:-standalone-sweep}}"

emit() { hive_emit_event "pr-sweeper" "$1" "$2"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=1    # default: dry-run
APPLY=0
TRIAGE=0
# Org list honours $NIGHTLY_OWNER (CSV) — same convention as
# nightly-select-projects.sh, morning-digest.sh, actions-budget-monitor.sh.
# Override via --orgs flag below or the env var.
ORGS="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}}"
OUTPUT=""
REPORT_DATE="$(date +%F)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; APPLY=0; shift ;;
    --apply)    APPLY=1; DRY_RUN=0; shift ;;
    --triage)   TRIAGE=1; shift ;;
    --orgs)     ORGS="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    *)          echo "[pr-sweeper] Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  if [[ "$TRIAGE" -eq 1 ]]; then
    OUTPUT="${HIVE}/sweep-triage-${REPORT_DATE}.md"
  else
    OUTPUT="${HIVE}/sweep-report-${REPORT_DATE}.md"
  fi
fi

if [[ "$TRIAGE" -eq 1 ]]; then
  if [[ "$APPLY" -eq 1 ]]; then
    echo "[pr-sweeper] Mode: TRIAGE+APPLY (sub-classifying + mutating NEEDS_ATTENTION PRs)"
  else
    echo "[pr-sweeper] Mode: TRIAGE+DRY-RUN (sub-classifying; no mutations)"
  fi
elif [[ "$APPLY" -eq 1 ]]; then
  echo "[pr-sweeper] Mode: APPLY (labeling + commenting enabled)"
else
  echo "[pr-sweeper] Mode: DRY-RUN (no mutations)"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LABEL_SWEEP_READY="sweep-ready-to-merge"
LABEL_NEEDS_LINK="needs-issue-link"
BLOCKED_LABELS="blocked-human|blocked-manual|needs-revision|draft|wip|do-not-merge"
HARD_BLOCK_LABELS="blocked-human|blocked-manual|do-not-merge"
BOT_AUTHORS="dependabot\[bot\]|renovate\[bot\]"
LINKED_ISSUE_RE='(?i)(closes|fixes|resolves)\s+#[0-9]+'
SWEEPER_COMMENT_MARKER="sweeper: SWEEP_READY_TO_MERGE"
TRIAGE_COMMENT_MARKER="sweeper triage:"

# Triage label names
LABEL_TRIAGE_CLOSE_STALE="sweeper:CLOSE_STALE"
LABEL_TRIAGE_CLOSE_DRAFT="sweeper:CLOSE_DRAFT"
LABEL_TRIAGE_NEEDS_REBASE="sweeper:NEEDS_REBASE"
LABEL_TRIAGE_NEEDS_CI_FIX="sweeper:NEEDS_CI_FIX"
LABEL_TRIAGE_NEEDS_REVIEW_FIX="sweeper:NEEDS_REVIEW_FIX"
LABEL_TRIAGE_HOLD_HUMAN="sweeper:HOLD_HUMAN"

# Triage thresholds (in seconds)
STALE_THRESHOLD=$(( 60 * 86400 ))   # 60 days
DRAFT_STALE_THRESHOLD=$(( 30 * 86400 ))  # 30 days
RECENT_THRESHOLD=$(( 30 * 86400 ))  # 30 days — "active enough to fix"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL_REPOS=0
TOTAL_PRS=0
SWEEP_READY_COUNT=0
NEEDS_ATTENTION_COUNT=0
SKIP_COUNT=0
MISSING_LINK_COUNT=0
PARTIAL_FAIL=0

# Triage bucket counters
TRIAGE_CLOSE_STALE_COUNT=0
TRIAGE_CLOSE_DRAFT_COUNT=0
TRIAGE_NEEDS_REBASE_COUNT=0
TRIAGE_NEEDS_CI_FIX_COUNT=0
TRIAGE_NEEDS_REVIEW_FIX_COUNT=0
TRIAGE_HOLD_HUMAN_COUNT=0
TRIAGE_CLOSED_COUNT=0

# ---------------------------------------------------------------------------
# Inventory accumulation (written at end)
# ---------------------------------------------------------------------------
INVENTORY_TMP="$(mktemp /tmp/pr-sweeper-inv.XXXXXX)"
trap 'rm -f "$INVENTORY_TMP"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Ensure a label exists in the repo (idempotent). Only runs in --apply mode.
ensure_label() {
  local repo="$1" label="$2" color="$3" description="$4"
  [[ "$APPLY" -eq 0 ]] && return 0
  if ! gh_api_safe label list --repo "$repo" --json name \
       --jq '.[].name' 2>/dev/null | grep -qxF "$label"; then
    gh label create "$label" \
      --repo "$repo" \
      --color "$color" \
      --description "$description" \
      2>/dev/null || true
  fi
}

# Apply a label to a PR (idempotent — skips if already present).
apply_label() {
  local repo="$1" pr_number="$2" label="$3"
  [[ "$APPLY" -eq 0 ]] && { echo "[dry-run] would label $repo#$pr_number → $label"; return 0; }
  gh pr edit "$pr_number" --repo "$repo" --add-label "$label" 2>/dev/null || true
}

# Post sweeper comment (idempotent — checks for existing marker comment first).
post_sweeper_comment() {
  local repo="$1" pr_number="$2" verdict="$3" base_branch="$4" linked_issue="$5"
  [[ "$APPLY" -eq 0 ]] && { echo "[dry-run] would comment on $repo#$pr_number (verdict=$verdict)"; return 0; }

  local existing
  existing="$(gh_api_safe pr view "$pr_number" --repo "$repo" \
    --json comments --jq '.comments[].body' 2>/dev/null \
    | grep -c "$SWEEPER_COMMENT_MARKER" || true)"
  if [[ "${existing:-0}" -gt 0 ]]; then
    echo "[pr-sweeper] $repo#$pr_number already has sweeper comment — skipping"
    return 0
  fi

  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local body
  body="## ${SWEEPER_COMMENT_MARKER}

Heuristic match (dated ${now_iso}):
- mergeable: MERGEABLE
- CI: all checks SUCCESS/NEUTRAL/SKIPPED
- base: ${base_branch} (default for repo)
- no blocked-* / revision labels
- linked issue: ${linked_issue}

No human action required. Next nightly-puffin sweep cycle will auto-merge unless the \`blocked-human\` label is added, or a reviewer posts \"HOLD\" in a comment."

  gh pr comment "$pr_number" --repo "$repo" --body "$body" 2>/dev/null || true
}

# Post triage comment (idempotent — checks for existing triage marker).
post_triage_comment() {
  local repo="$1" pr_number="$2" triage_label="$3" rationale="$4" next_action="$5"
  [[ "$APPLY" -eq 0 ]] && {
    echo "[dry-run] would post triage comment on $repo#$pr_number (label=$triage_label)"
    return 0
  }

  # Idempotent: skip if triage comment already present.
  local existing
  existing="$(gh_api_safe pr view "$pr_number" --repo "$repo" \
    --json comments --jq '.comments[].body' 2>/dev/null \
    | grep -c "$TRIAGE_COMMENT_MARKER" || true)"
  if [[ "${existing:-0}" -gt 0 ]]; then
    echo "[pr-sweeper] $repo#$pr_number already has triage comment — skipping"
    return 0
  fi

  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local body
  body="## ${TRIAGE_COMMENT_MARKER} \`${triage_label}\`

Classified by pr-sweeper triage pass (${now_iso}).

${rationale}

**What happens next:** ${next_action}"

  gh pr comment "$pr_number" --repo "$repo" --body "$body" 2>/dev/null || true
}

# Ensure all triage labels exist in the repo. Called once per repo in apply mode.
ensure_triage_labels() {
  local repo="$1"
  [[ "$APPLY" -eq 0 ]] && return 0
  ensure_label "$repo" "$LABEL_TRIAGE_CLOSE_STALE"      "b60205" \
    "60+ days stale, not mergeable — will be closed by sweeper"
  ensure_label "$repo" "$LABEL_TRIAGE_CLOSE_DRAFT"      "e4e669" \
    "Draft 30+ days stale — will be closed by sweeper"
  ensure_label "$repo" "$LABEL_TRIAGE_NEEDS_REBASE"     "fbca04" \
    "Merge conflicts — needs manual rebase before auto-merge"
  ensure_label "$repo" "$LABEL_TRIAGE_NEEDS_CI_FIX"     "d93f0b" \
    "CI failing and recently updated — specialist dispatched to fix"
  ensure_label "$repo" "$LABEL_TRIAGE_NEEDS_REVIEW_FIX" "f9d0c4" \
    "Reviewer requested changes — needs author action"
  ensure_label "$repo" "$LABEL_TRIAGE_HOLD_HUMAN"       "0075ca" \
    "Human-gated — blocked-human/blocked-manual/do-not-merge present"
}

# Check statusCheckRollup: returns verdict string.
# "clean"       → all SUCCESS/NEUTRAL/SKIPPED, no FAILURE, no PENDING >24h
# "failure"     → at least one FAILURE/ERROR/TIMED_OUT
# "pending_old" → PENDING older than 24h
# "pending_fresh" → PENDING but within 24h
check_ci_status() {
  local rollup_json="$1"
  local now_epoch
  now_epoch="$(date -u +%s)"
  local threshold=$(( now_epoch - 86400 ))  # 24h ago

  if [[ -z "$rollup_json" || "$rollup_json" == "null" || "$rollup_json" == "[]" ]]; then
    echo "clean"; return
  fi

  local has_failure
  has_failure="$(printf '%s' "$rollup_json" | \
    jq '[.[] | .conclusion // .status // ""] | any(. == "FAILURE" or . == "ERROR" or . == "TIMED_OUT" or . == "CANCELLED")' 2>/dev/null || echo "false")"
  [[ "$has_failure" == "true" ]] && { echo "failure"; return; }

  local pending_check
  pending_check="$(printf '%s' "$rollup_json" | jq --argjson threshold "$threshold" '
    [.[] | select(
      (.conclusion == null or .conclusion == "" or .conclusion == "IN_PROGRESS") and
      (.status == "QUEUED" or .status == "IN_PROGRESS" or .status == "PENDING" or
       .conclusion == null or .conclusion == "")
    ) |
    if (.startedAt // "" | . != "") then
      ((.startedAt | split(".")[0] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) < $threshold)
    else
      false
    end
  ] | any' 2>/dev/null || echo "false")"
  [[ "$pending_check" == "true" ]] && { echo "pending_old"; return; }

  local has_pending
  has_pending="$(printf '%s' "$rollup_json" | jq '[.[] |
    select(
      .conclusion == null or .conclusion == "" or
      .status == "QUEUED" or .status == "IN_PROGRESS" or .status == "PENDING"
    )
  ] | length > 0' 2>/dev/null || echo "false")"
  [[ "$has_pending" == "true" ]] && { echo "pending_fresh"; return; }

  echo "clean"
}

# ---------------------------------------------------------------------------
# Triage classifier: assigns ONE sweeper:* label per PR.
# Called for PRs that previously fell into NEEDS_ATTENTION.
# Returns the triage label string on stdout.
# ---------------------------------------------------------------------------
classify_triage() {
  local is_draft="$1"
  local mergeable="$2"
  local review_decision="$3"
  local ci_verdict="$4"
  local labels_json="$5"
  local updated_seconds_ago="$6"  # integer seconds since updatedAt

  # Rule 1: Hard-block labels → HOLD_HUMAN (always wins)
  if printf '%s' "$labels_json" | grep -qiE "$HARD_BLOCK_LABELS"; then
    echo "$LABEL_TRIAGE_HOLD_HUMAN"; return
  fi

  # Rule 2: Stale non-mergeable (not draft — drafts handled below)
  # Criteria: updatedAt >60d AND mergeable != MERGEABLE AND no 'active' label
  if [[ "$is_draft" != "true" && \
        "$mergeable" != "MERGEABLE" && \
        "$updated_seconds_ago" -gt "$STALE_THRESHOLD" ]] && \
     ! printf '%s' "$labels_json" | grep -qiE '\bactive\b'; then
    echo "$LABEL_TRIAGE_CLOSE_STALE"; return
  fi

  # Rule 3: Stale draft
  # Criteria: isDraft AND updatedAt >30d
  if [[ "$is_draft" == "true" && "$updated_seconds_ago" -gt "$DRAFT_STALE_THRESHOLD" ]]; then
    echo "$LABEL_TRIAGE_CLOSE_DRAFT"; return
  fi

  # Rule 4: Needs rebase — conflicting but recently updated
  # Criteria: CONFLICTING AND updatedAt ≤30d
  if [[ "$mergeable" == "CONFLICTING" && "$updated_seconds_ago" -le "$RECENT_THRESHOLD" ]]; then
    echo "$LABEL_TRIAGE_NEEDS_REBASE"; return
  fi

  # Rule 5: CI failing but mergeable and recent
  # Criteria: MERGEABLE AND CI has FAILURE AND updatedAt ≤30d
  if [[ "$mergeable" == "MERGEABLE" && \
        "$ci_verdict" == "failure" && \
        "$updated_seconds_ago" -le "$RECENT_THRESHOLD" ]]; then
    echo "$LABEL_TRIAGE_NEEDS_CI_FIX"; return
  fi

  # Rule 6: Review requested changes
  # Criteria: reviewDecision == CHANGES_REQUESTED AND updatedAt ≤30d
  if [[ "$review_decision" == "CHANGES_REQUESTED" && \
        "$updated_seconds_ago" -le "$RECENT_THRESHOLD" ]]; then
    echo "$LABEL_TRIAGE_NEEDS_REVIEW_FIX"; return
  fi

  # Fallback: anything else that didn't pass sweep but is also not clearly
  # stale — treat as HOLD_HUMAN (requires human judgement).
  echo "$LABEL_TRIAGE_HOLD_HUMAN"
}

# Rationale + next-action strings for triage comment body.
triage_comment_text() {
  local triage_label="$1" age_days="$2" mergeable="$3" ci_verdict="$4" review_decision="$5"
  local rationale next_action

  case "$triage_label" in
    "$LABEL_TRIAGE_CLOSE_STALE")
      rationale="This PR has not been updated in **${age_days} days** and is not mergeable (\`mergeable=${mergeable}\`). No \`active\` label was found. It appears abandoned."
      next_action="This PR will be **closed** automatically. If still relevant, reopen it, resolve the conflicts, and remove the \`sweeper:CLOSE_STALE\` label."
      ;;
    "$LABEL_TRIAGE_CLOSE_DRAFT")
      rationale="This PR has been a **draft for ${age_days} days** without progress. Draft PRs older than 30 days without updates are considered stale."
      next_action="This PR will be **closed** automatically. If still relevant, reopen it, mark as ready for review, and remove the \`sweeper:CLOSE_DRAFT\` label."
      ;;
    "$LABEL_TRIAGE_NEEDS_REBASE")
      rationale="This PR has **merge conflicts** (\`mergeable=CONFLICTING\`) but was updated within the last 30 days (${age_days} days ago), suggesting it is still active."
      next_action="A human or specialist must **rebase this branch** onto the target branch. No automated action taken. Remove this label once rebased."
      ;;
    "$LABEL_TRIAGE_NEEDS_CI_FIX")
      rationale="This PR is mergeable but **CI is failing** (\`ci=${ci_verdict}\`). It was updated ${age_days} days ago — recent enough to warrant fixing."
      next_action="A specialist will be **dispatched to diagnose and fix the failing test(s)**. Check CI logs for details."
      ;;
    "$LABEL_TRIAGE_NEEDS_REVIEW_FIX")
      rationale="A reviewer has **requested changes** (\`reviewDecision=${review_decision}\`). This PR was updated ${age_days} days ago and is still within the active window."
      next_action="The **author should address the review feedback**. Once changes are made and re-approved, the PR can proceed to merge."
      ;;
    "$LABEL_TRIAGE_HOLD_HUMAN")
      rationale="This PR has a **human-gating label** or does not match any auto-actionable triage bucket. Manual review required."
      next_action="**No automated action.** A human must decide whether to merge, close, or continue work."
      ;;
  esac

  printf '%s|||%s' "$rationale" "$next_action"
}

# Close a PR with a descriptive comment. Only called for CLOSE_STALE + CLOSE_DRAFT.
close_pr_with_comment() {
  local repo="$1" pr_number="$2" triage_label="$3"
  local close_reason
  case "$triage_label" in
    "$LABEL_TRIAGE_CLOSE_STALE")
      close_reason="Closed as stale — 60+ days without progress. Reopen if still relevant."
      ;;
    "$LABEL_TRIAGE_CLOSE_DRAFT")
      close_reason="Closed — draft 30+ days without progress. Reopen and mark ready-for-review if still relevant."
      ;;
    *)
      return 0
      ;;
  esac

  if [[ "$APPLY" -eq 0 ]]; then
    echo "[dry-run] would close $repo#$pr_number: \"$close_reason\""
    return 0
  fi

  # Post close-reason comment before closing so there is a paper trail.
  local now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  gh pr comment "$pr_number" --repo "$repo" \
    --body "**[sweeper auto-close ${now_iso}]** ${close_reason}" 2>/dev/null || true

  gh pr close "$pr_number" --repo "$repo" 2>/dev/null || true
  TRIAGE_CLOSED_COUNT=$(( TRIAGE_CLOSED_COUNT + 1 ))
  echo "[pr-sweeper] Closed $repo#$pr_number (${triage_label})"
}

# ---------------------------------------------------------------------------
# Per-repo PR scan (standard sweep mode)
# ---------------------------------------------------------------------------
scan_repo() {
  local org="$1" repo_name="$2" default_branch="$3"
  local repo="${org}/${repo_name}"
  local section_tmp
  section_tmp="$(mktemp /tmp/pr-sweeper-section.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$section_tmp'" RETURN

  printf '\n### %s\n\n' "$repo" >> "$section_tmp"
  printf '| # | Title | Linked Issue | CI | Mergeable | Age (days) | Verdict | Reason |\n' >> "$section_tmp"
  printf '|---|-------|-------------|-----|-----------|------------|---------|--------|\n' >> "$section_tmp"

  local prs_json
  prs_json="$(gh_api_safe pr list \
    --repo "$repo" \
    --state open \
    --json number,title,body,labels,mergeable,mergeStateStatus,statusCheckRollup,reviewDecision,baseRefName,headRefName,author,createdAt,updatedAt,isDraft \
    2>/dev/null)" || {
    echo "[pr-sweeper] WARN: failed to list PRs for $repo — skipping" >&2
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    printf '| — | *API error* | — | — | — | — | SKIP | api-failure |\n' >> "$section_tmp"
    cat "$section_tmp" >> "$INVENTORY_TMP"
    return
  }

  local pr_count
  pr_count="$(printf '%s' "$prs_json" | jq 'length')"
  if [[ "${pr_count:-0}" -eq 0 ]]; then
    printf '| — | *no open PRs* | — | — | — | — | — | — |\n' >> "$section_tmp"
    cat "$section_tmp" >> "$INVENTORY_TMP"
    return
  fi

  TOTAL_PRS=$(( TOTAL_PRS + pr_count ))

  local now_epoch
  now_epoch="$(date -u +%s)"

  while IFS= read -r pr_json; do
    local number title body base_branch is_draft mergeable author_login
    local created_at labels_json rollup_json
    number="$(printf '%s' "$pr_json" | jq -r '.number')"
    title="$(printf '%s' "$pr_json" | jq -r '.title')"
    body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
    base_branch="$(printf '%s' "$pr_json" | jq -r '.baseRefName')"
    is_draft="$(printf '%s' "$pr_json" | jq -r '.isDraft')"
    mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
    author_login="$(printf '%s' "$pr_json" | jq -r '.author.login // ""')"
    created_at="$(printf '%s' "$pr_json" | jq -r '.createdAt')"
    labels_json="$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")')"
    rollup_json="$(printf '%s' "$pr_json" | jq '.statusCheckRollup // []')"

    local created_epoch age_days
    created_epoch="$(date -u -d "$created_at" +%s 2>/dev/null || echo "$now_epoch")"
    age_days=$(( (now_epoch - created_epoch) / 86400 ))

    local title_short="${title:0:50}"
    [[ "${#title}" -gt 50 ]] && title_short="${title_short}…"

    # -- Check 1: Bot author --
    if printf '%s' "$author_login" | grep -qE "$BOT_AUTHORS"; then
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
      printf '| #%s | %s | — | — | — | %s | SKIP | bot-managed |\n' \
        "$number" "$title_short" "$age_days" >> "$section_tmp"
      continue
    fi

    # -- Check 2: Draft --
    if [[ "$is_draft" == "true" ]]; then
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
      printf '| #%s | %s | — | — | — | %s | SKIP | draft |\n' \
        "$number" "$title_short" "$age_days" >> "$section_tmp"
      continue
    fi

    # -- Check 3: Blocked labels --
    if printf '%s' "$labels_json" | grep -qiE "$BLOCKED_LABELS"; then
      local matched_label
      matched_label="$(printf '%s' "$labels_json" | grep -oiE "$BLOCKED_LABELS" | head -1)"
      NEEDS_ATTENTION_COUNT=$(( NEEDS_ATTENTION_COUNT + 1 ))
      printf '| #%s | %s | — | — | — | %s | NEEDS_ATTENTION | blocked-label: %s |\n' \
        "$number" "$title_short" "$age_days" "$matched_label" >> "$section_tmp"
      continue
    fi

    # -- Check 4: mergeable --
    if [[ "$mergeable" != "MERGEABLE" ]]; then
      NEEDS_ATTENTION_COUNT=$(( NEEDS_ATTENTION_COUNT + 1 ))
      printf '| #%s | %s | — | — | %s | %s | NEEDS_ATTENTION | not-mergeable |\n' \
        "$number" "$title_short" "$mergeable" "$age_days" >> "$section_tmp"
      continue
    fi

    # -- Check 5: base branch == default --
    local base_ok=0
    if [[ ("$base_branch" == "master" || "$base_branch" == "main") && "$base_branch" == "$default_branch" ]]; then
      base_ok=1
    fi
    if [[ "$base_ok" -eq 0 ]]; then
      NEEDS_ATTENTION_COUNT=$(( NEEDS_ATTENTION_COUNT + 1 ))
      printf '| #%s | %s | — | — | MERGEABLE | %s | NEEDS_ATTENTION | base=%s != default=%s |\n' \
        "$number" "$title_short" "$age_days" "$base_branch" "$default_branch" >> "$section_tmp"
      continue
    fi

    # -- Check 6: CI status --
    local ci_verdict
    ci_verdict="$(check_ci_status "$rollup_json")"
    if [[ "$ci_verdict" != "clean" ]]; then
      NEEDS_ATTENTION_COUNT=$(( NEEDS_ATTENTION_COUNT + 1 ))
      printf '| #%s | %s | — | %s | MERGEABLE | %s | NEEDS_ATTENTION | ci=%s |\n' \
        "$number" "$title_short" "$ci_verdict" "$age_days" "$ci_verdict" >> "$section_tmp"
      continue
    fi

    # -- Check 7: Linked issue (soft) --
    local linked_issue="missing" has_link=0
    local combined="${title} ${body}"
    local link_match
    link_match="$(printf '%s' "$combined" | grep -oiP '(closes|fixes|resolves)\s+#[0-9]+' | head -1 || true)"
    if [[ -n "$link_match" ]]; then
      has_link=1
      linked_issue="$(printf '%s' "$link_match" | grep -oP '#[0-9]+')"
    fi

    local verdict="SWEEP_READY" reason="all-checks-pass"
    if [[ "$has_link" -eq 0 ]]; then
      verdict="SWEEP_READY/NEEDS_ISSUE_LINK"
      reason="missing-linked-issue"
      MISSING_LINK_COUNT=$(( MISSING_LINK_COUNT + 1 ))
    fi
    SWEEP_READY_COUNT=$(( SWEEP_READY_COUNT + 1 ))

    printf '| #%s | %s | %s | %s | %s | %s | %s | %s |\n' \
      "$number" "$title_short" "$linked_issue" "$ci_verdict" "$mergeable" \
      "$age_days" "$verdict" "$reason" >> "$section_tmp"

    if [[ "$APPLY" -eq 1 ]]; then
      ensure_label "$repo" "$LABEL_SWEEP_READY" "0e8a16" "PR is ready for automated merge by nightly-puffin sweeper"
      apply_label "$repo" "$number" "$LABEL_SWEEP_READY"
      if [[ "$has_link" -eq 0 ]]; then
        ensure_label "$repo" "$LABEL_NEEDS_LINK" "e4e669" "PR body/title missing Closes/Fixes/Resolves #N link"
        apply_label "$repo" "$number" "$LABEL_NEEDS_LINK"
      fi
      post_sweeper_comment "$repo" "$number" "$verdict" "$base_branch" "$linked_issue"
    else
      echo "[dry-run] $repo#$number → $verdict (would apply: $LABEL_SWEEP_READY$([ "$has_link" -eq 0 ] && echo ", $LABEL_NEEDS_LINK" || echo ""))"
    fi

  done < <(printf '%s' "$prs_json" | jq -c '.[]')

  cat "$section_tmp" >> "$INVENTORY_TMP"
}

# ---------------------------------------------------------------------------
# Per-repo PR triage (--triage mode)
# ---------------------------------------------------------------------------
triage_repo() {
  local org="$1" repo_name="$2" default_branch="$3"
  local repo="${org}/${repo_name}"
  local section_tmp
  section_tmp="$(mktemp /tmp/pr-sweeper-triage-section.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$section_tmp'" RETURN

  printf '\n### %s\n\n' "$repo" >> "$section_tmp"
  printf '| # | Title | updatedAt | Verdict | Action |\n' >> "$section_tmp"
  printf '|---|-------|-----------|---------|--------|\n' >> "$section_tmp"

  local prs_json
  prs_json="$(gh_api_safe pr list \
    --repo "$repo" \
    --state open \
    --json number,title,body,labels,mergeable,mergeStateStatus,statusCheckRollup,reviewDecision,baseRefName,headRefName,author,createdAt,updatedAt,isDraft \
    2>/dev/null)" || {
    echo "[pr-sweeper] WARN: failed to list PRs for $repo — skipping" >&2
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    printf '| — | *API error* | — | — | — |\n' >> "$section_tmp"
    cat "$section_tmp" >> "$INVENTORY_TMP"
    return
  }

  local pr_count
  pr_count="$(printf '%s' "$prs_json" | jq 'length')"
  if [[ "${pr_count:-0}" -eq 0 ]]; then
    printf '| — | *no open PRs* | — | — | — |\n' >> "$section_tmp"
    cat "$section_tmp" >> "$INVENTORY_TMP"
    return
  fi

  TOTAL_PRS=$(( TOTAL_PRS + pr_count ))

  # Ensure all triage labels exist in this repo (single batched call in apply mode).
  ensure_triage_labels "$repo"

  local now_epoch
  now_epoch="$(date -u +%s)"

  while IFS= read -r pr_json; do
    local number title body is_draft mergeable author_login review_decision
    local updated_at labels_json rollup_json
    number="$(printf '%s' "$pr_json" | jq -r '.number')"
    title="$(printf '%s' "$pr_json" | jq -r '.title')"
    body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
    is_draft="$(printf '%s' "$pr_json" | jq -r '.isDraft')"
    mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
    author_login="$(printf '%s' "$pr_json" | jq -r '.author.login // ""')"
    review_decision="$(printf '%s' "$pr_json" | jq -r '.reviewDecision // ""')"
    updated_at="$(printf '%s' "$pr_json" | jq -r '.updatedAt')"
    labels_json="$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")')"
    rollup_json="$(printf '%s' "$pr_json" | jq '.statusCheckRollup // []')"

    # Skip bots entirely (they manage their own PRs).
    if printf '%s' "$author_login" | grep -qE "$BOT_AUTHORS"; then
      SKIP_COUNT=$(( SKIP_COUNT + 1 ))
      printf '| #%s | %s | — | SKIP | bot-managed |\n' \
        "$number" "${title:0:50}" >> "$section_tmp"
      continue
    fi

    # Already SWEEP_READY via the main path? — should not appear here in normal
    # usage but guard anyway: skip re-triaging.
    if printf '%s' "$labels_json" | grep -qxF "$LABEL_SWEEP_READY"; then
      printf '| #%s | %s | — | SWEEP_READY | already-labeled |\n' \
        "$number" "${title:0:50}" >> "$section_tmp"
      continue
    fi

    # Compute age from updatedAt (triage cares about recency of updates).
    local updated_epoch updated_seconds_ago age_days
    updated_epoch="$(date -u -d "$updated_at" +%s 2>/dev/null || echo "$now_epoch")"
    updated_seconds_ago=$(( now_epoch - updated_epoch ))
    age_days=$(( updated_seconds_ago / 86400 ))

    local ci_verdict
    ci_verdict="$(check_ci_status "$rollup_json")"

    local triage_label
    triage_label="$(classify_triage \
      "$is_draft" \
      "$mergeable" \
      "$review_decision" \
      "$ci_verdict" \
      "$labels_json" \
      "$updated_seconds_ago")"

    # Determine action string for manifest table.
    local action_str
    case "$triage_label" in
      "$LABEL_TRIAGE_CLOSE_STALE")
        action_str="close-stale"
        TRIAGE_CLOSE_STALE_COUNT=$(( TRIAGE_CLOSE_STALE_COUNT + 1 ))
        ;;
      "$LABEL_TRIAGE_CLOSE_DRAFT")
        action_str="close-draft"
        TRIAGE_CLOSE_DRAFT_COUNT=$(( TRIAGE_CLOSE_DRAFT_COUNT + 1 ))
        ;;
      "$LABEL_TRIAGE_NEEDS_REBASE")
        action_str="flag-for-rebase"
        TRIAGE_NEEDS_REBASE_COUNT=$(( TRIAGE_NEEDS_REBASE_COUNT + 1 ))
        ;;
      "$LABEL_TRIAGE_NEEDS_CI_FIX")
        action_str="dispatch-ci-fix"
        TRIAGE_NEEDS_CI_FIX_COUNT=$(( TRIAGE_NEEDS_CI_FIX_COUNT + 1 ))
        ;;
      "$LABEL_TRIAGE_NEEDS_REVIEW_FIX")
        action_str="needs-author-action"
        TRIAGE_NEEDS_REVIEW_FIX_COUNT=$(( TRIAGE_NEEDS_REVIEW_FIX_COUNT + 1 ))
        ;;
      "$LABEL_TRIAGE_HOLD_HUMAN")
        action_str="human-decision-required"
        TRIAGE_HOLD_HUMAN_COUNT=$(( TRIAGE_HOLD_HUMAN_COUNT + 1 ))
        ;;
    esac

    local updated_date
    updated_date="${updated_at:0:10}"  # YYYY-MM-DD

    printf '| #%s | %s | %s | %s | %s |\n' \
      "$number" "${title:0:50}" "$updated_date" "$triage_label" "$action_str" >> "$section_tmp"

    echo "[pr-sweeper] triage $repo#$number → $triage_label ($action_str)"

    # -- Mutations (apply mode only) --
    if [[ "$APPLY" -eq 1 ]]; then
      # Apply the sweeper triage label.
      apply_label "$repo" "$number" "$triage_label"

      # Post triage comment.
      local comment_parts
      comment_parts="$(triage_comment_text "$triage_label" "$age_days" "$mergeable" "$ci_verdict" "$review_decision")"
      local rationale next_action
      rationale="${comment_parts%%|||*}"
      next_action="${comment_parts##*|||}"
      post_triage_comment "$repo" "$number" "$triage_label" "$rationale" "$next_action"

      # Close PR for CLOSE_STALE and CLOSE_DRAFT.
      if [[ "$triage_label" == "$LABEL_TRIAGE_CLOSE_STALE" || \
            "$triage_label" == "$LABEL_TRIAGE_CLOSE_DRAFT" ]]; then
        close_pr_with_comment "$repo" "$number" "$triage_label"
      fi
    else
      # Dry-run output.
      echo "[dry-run] $repo#$number → would label: $triage_label | action: $action_str"
      if [[ "$triage_label" == "$LABEL_TRIAGE_CLOSE_STALE" || \
            "$triage_label" == "$LABEL_TRIAGE_CLOSE_DRAFT" ]]; then
        echo "[dry-run] $repo#$number → would close PR (${triage_label})"
      fi
    fi

  done < <(printf '%s' "$prs_json" | jq -c '.[]')

  cat "$section_tmp" >> "$INVENTORY_TMP"
}

# ---------------------------------------------------------------------------
# Main — enumerate orgs
# ---------------------------------------------------------------------------
emit "SPAWN" "mode=$([ "$TRIAGE" -eq 1 ] && echo triage || echo sweep)/$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) orgs=$ORGS"

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

IFS=',' read -ra ORG_LIST <<< "$ORGS"
for org in "${ORG_LIST[@]}"; do
  echo "[pr-sweeper] Scanning org: $org (mode=$([ "$TRIAGE" -eq 1 ] && echo triage || echo sweep))"
  local_org_tmp="$(mktemp /tmp/pr-sweeper-org.XXXXXX)"
  trap "rm -f '$local_org_tmp'" RETURN 2>/dev/null || true

  repos_json="$(gh_api_safe repo list "$org" \
    --limit 100 \
    --no-archived \
    --json name,defaultBranchRef,isArchived \
    --jq '[.[] | select(.isArchived == false)]' 2>/dev/null)" || {
    echo "[pr-sweeper] WARN: failed to list repos for $org" >&2
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    continue
  }

  repo_count="$(printf '%s' "$repos_json" | jq 'length')"
  echo "[pr-sweeper] $org: $repo_count repos found"
  TOTAL_REPOS=$(( TOTAL_REPOS + repo_count ))

  printf '\n## Org: %s\n' "$org" >> "$INVENTORY_TMP"

  while IFS=$'\t' read -r repo_name default_branch; do
    [[ -z "$repo_name" ]] && continue
    [[ -z "$default_branch" || "$default_branch" == "null" ]] && default_branch="master"
    echo "[pr-sweeper]   → $org/$repo_name (default: $default_branch)"
    if [[ "$TRIAGE" -eq 1 ]]; then
      triage_repo "$org" "$repo_name" "$default_branch"
    else
      scan_repo "$org" "$repo_name" "$default_branch"
    fi
  done < <(printf '%s' "$repos_json" | jq -r '.[] | [.name, (.defaultBranchRef.name // "master")] | @tsv')

done

# ---------------------------------------------------------------------------
# Write inventory / manifest file
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"

{
  if [[ "$TRIAGE" -eq 1 ]]; then
    printf '# PR Sweeper Triage Manifest\n\n'
    printf '**Generated:** %s  \n' "$START_TS"
    printf '**Scope:** %s  \n' "$ORGS"
    printf '**Mode:** %s  \n\n' "$([ "$APPLY" -eq 1 ] && echo "TRIAGE+APPLY" || echo "TRIAGE+DRY-RUN")"
    printf '## Summary\n\n'
    printf '| Metric | Count |\n'
    printf '|--------|-------|\n'
    printf '| Repos scanned | %s |\n' "$TOTAL_REPOS"
    printf '| Total PRs scanned | %s |\n' "$TOTAL_PRS"
    printf '| sweeper:CLOSE_STALE | %s |\n' "$TRIAGE_CLOSE_STALE_COUNT"
    printf '| sweeper:CLOSE_DRAFT | %s |\n' "$TRIAGE_CLOSE_DRAFT_COUNT"
    printf '| sweeper:NEEDS_REBASE | %s |\n' "$TRIAGE_NEEDS_REBASE_COUNT"
    printf '| sweeper:NEEDS_CI_FIX | %s |\n' "$TRIAGE_NEEDS_CI_FIX_COUNT"
    printf '| sweeper:NEEDS_REVIEW_FIX | %s |\n' "$TRIAGE_NEEDS_REVIEW_FIX_COUNT"
    printf '| sweeper:HOLD_HUMAN | %s |\n' "$TRIAGE_HOLD_HUMAN_COUNT"
    printf '| PRs actually closed | %s |\n' "$TRIAGE_CLOSED_COUNT"
    printf '| SKIP (bot/already-labeled) | %s |\n' "$SKIP_COUNT"
    [[ "$PARTIAL_FAIL" -gt 0 ]] && printf '| Repos with API errors | %s |\n' "$PARTIAL_FAIL"
    printf '\n## Triage Sub-Classification Rules\n\n'
    printf '%s\n' "| Label | Criteria | Auto-action |"
    printf '%s\n' "|-------|----------|-------------|"
    printf '%s\n' "| \`sweeper:CLOSE_STALE\` | updatedAt >60d AND not MERGEABLE AND no \`active\` label | PR closed with stale comment |"
    printf '%s\n' "| \`sweeper:CLOSE_DRAFT\` | isDraft AND updatedAt >30d | PR closed with draft comment |"
    printf '%s\n' "| \`sweeper:NEEDS_REBASE\` | CONFLICTING AND updatedAt ≤30d | Flagged — manual rebase needed |"
    printf '%s\n' "| \`sweeper:NEEDS_CI_FIX\` | MERGEABLE AND CI FAILURE AND updatedAt ≤30d | Specialist dispatched |"
    printf '%s\n' "| \`sweeper:NEEDS_REVIEW_FIX\` | CHANGES_REQUESTED AND updatedAt ≤30d | Author action required |"
    printf '%s\n' "| \`sweeper:HOLD_HUMAN\` | has blocked-human/blocked-manual/do-not-merge OR no other bucket matches | No action — human-gated |"
    printf '\n## Per-Repo Detail\n'
    printf '\n> Columns: PR # | Title | Last Updated | Triage Verdict | Action\n'
  else
    printf '# PR Sweeper Inventory\n\n'
    printf '**Generated:** %s  \n' "$START_TS"
    printf '**Scope:** %s  \n' "$ORGS"
    printf '**Mode:** %s  \n\n' "$([ "$APPLY" -eq 1 ] && echo "APPLY" || echo "DRY-RUN")"
    printf '## Summary\n\n'
    printf '| Metric | Count |\n'
    printf '|--------|-------|\n'
    printf '| Repos scanned | %s |\n' "$TOTAL_REPOS"
    printf '| Total PRs scanned | %s |\n' "$TOTAL_PRS"
    printf '| SWEEP_READY | %s |\n' "$SWEEP_READY_COUNT"
    printf '| NEEDS_ATTENTION | %s |\n' "$NEEDS_ATTENTION_COUNT"
    printf '| SKIP (bot/draft) | %s |\n' "$SKIP_COUNT"
    printf '| Missing issue link | %s |\n' "$MISSING_LINK_COUNT"
    [[ "$PARTIAL_FAIL" -gt 0 ]] && printf '| Repos with API errors | %s |\n' "$PARTIAL_FAIL"
    printf '\n## Heuristic Applied\n\n'
    printf '%s\n' "- mergeable == MERGEABLE"
    printf '%s\n' "- CI: all SUCCESS / NEUTRAL / SKIPPED; no FAILURE; no PENDING >24h"
    printf '%s\n' "- base branch in [master, main] AND equals repo default branch"
    printf '%s\n' "- Labels NOT in: $BLOCKED_LABELS"
    printf '%s\n' "- Not draft, not bot-authored"
    printf '%s\n' "- Linked-issue regex (Closes/Fixes/Resolves #N) — soft: missing => NEEDS_ISSUE_LINK label added"
    printf '\n## Per-Repo Detail\n'
  fi
  cat "$INVENTORY_TMP"
} > "$OUTPUT"

echo ""
echo "[pr-sweeper] Output written to: $OUTPUT"
echo "[pr-sweeper] Summary:"
echo "  Repos scanned    : $TOTAL_REPOS"
echo "  Total PRs        : $TOTAL_PRS"

if [[ "$TRIAGE" -eq 1 ]]; then
  echo "  CLOSE_STALE      : $TRIAGE_CLOSE_STALE_COUNT"
  echo "  CLOSE_DRAFT      : $TRIAGE_CLOSE_DRAFT_COUNT"
  echo "  NEEDS_REBASE     : $TRIAGE_NEEDS_REBASE_COUNT"
  echo "  NEEDS_CI_FIX     : $TRIAGE_NEEDS_CI_FIX_COUNT"
  echo "  NEEDS_REVIEW_FIX : $TRIAGE_NEEDS_REVIEW_FIX_COUNT"
  echo "  HOLD_HUMAN       : $TRIAGE_HOLD_HUMAN_COUNT"
  echo "  Actually closed  : $TRIAGE_CLOSED_COUNT"
  echo "  SKIP (bot/dup)   : $SKIP_COUNT"
else
  echo "  SWEEP_READY      : $SWEEP_READY_COUNT"
  echo "  NEEDS_ATTENTION  : $NEEDS_ATTENTION_COUNT"
  echo "  SKIP (bot/draft) : $SKIP_COUNT"
  echo "  Missing link     : $MISSING_LINK_COUNT"
fi
[[ "$PARTIAL_FAIL" -gt 0 ]] && echo "  API errors (repos): $PARTIAL_FAIL"

if [[ "$TRIAGE" -eq 1 ]]; then
  emit "COMPLETE" "mode=triage total_prs=$TOTAL_PRS close_stale=$TRIAGE_CLOSE_STALE_COUNT close_draft=$TRIAGE_CLOSE_DRAFT_COUNT needs_rebase=$TRIAGE_NEEDS_REBASE_COUNT needs_ci_fix=$TRIAGE_NEEDS_CI_FIX_COUNT needs_review_fix=$TRIAGE_NEEDS_REVIEW_FIX_COUNT hold_human=$TRIAGE_HOLD_HUMAN_COUNT closed=$TRIAGE_CLOSED_COUNT partial_fail=$PARTIAL_FAIL"
else
  emit "COMPLETE" "mode=sweep total_prs=$TOTAL_PRS sweep_ready=$SWEEP_READY_COUNT skip=$SKIP_COUNT partial_fail=$PARTIAL_FAIL"
fi

[[ "$PARTIAL_FAIL" -gt 0 ]] && exit 2 || exit 0
