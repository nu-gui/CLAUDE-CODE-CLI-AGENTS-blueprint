#!/usr/bin/env bash
# scripts/actions-budget-monitor.sh
#
# Daily GitHub Actions billing watch.
# Queries both orgs, emits PROGRESS with usage %, BLOCKED at >80% warn,
# BLOCKED + label at >=100% exhausted.
#
# Auth note: the billing endpoint requires `admin:org` scope on the PAT
# (or org billing-read API access, which is not publicly available).
# On a 403, the monitor gracefully skips with a PROGRESS event and does NOT
# block the pipeline. Callers that need hard enforcement should check for a
# BLOCKED event with code ACTIONS_BUDGET_WARN or ACTIONS_BUDGET_EXHAUSTED.
#
# Issue #100 (EXAMPLE-ID)
# Usage: bash scripts/actions-budget-monitor.sh [--dry-run]

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

HIVE_DEFAULT_AGENT="actions-budget-monitor"
export HIVE_DEFAULT_AGENT

: "${SID:=${SESSION_ID:-${HIVE_DEFAULT_AGENT}-$(date -u +%Y-%m-%d)}}"
export SID

DRY_RUN=0
for arg in "$@"; do
  [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

# Org list honours $NIGHTLY_OWNER (CSV) — same convention as
# nightly-select-projects.sh, morning-digest.sh, pr-sweeper.sh. Previously
# hardcoded here; centralised so membership changes only touch the env
# default (or the selector's top-of-file default).
IFS=',' read -ra ORGS <<< "${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}}"

# Sprint milestone label to attach on exhaustion
SPRINT_MILESTONE_LABEL="sprint-milestone"
EXHAUSTED_LABEL="actions-budget-exhausted"

hive_heartbeat "actions-budget-monitor"
hive_emit_event "PROGRESS" "actions-budget-monitor: starting (dry_run=$DRY_RUN)"

# ---------------------------------------------------------------------------
# check_org_budget <org>
# Queries billing API, computes usage %, emits events.
# Returns 0 on success, 1 on skippable auth/403 error.
# ---------------------------------------------------------------------------
check_org_budget() {
  local org="$1"
  local endpoint="/orgs/${org}/settings/billing/actions"

  # Fetch billing data.
  local billing_json
  local gh_stderr
  gh_stderr="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$gh_stderr'" RETURN

  billing_json="$(gh api "$endpoint" 2>"$gh_stderr")" || {
    local exit_code=$?
    local stderr_content
    stderr_content="$(cat "$gh_stderr")"

    # 403 / 404 / 410 / missing scope — graceful skip, do not BLOCK pipeline.
    # 410 = GitHub has moved the billing endpoint (see gh.io/billing-api-updates-org).
    # admin:org = PAT lacks the required scope.
    if echo "$stderr_content" | grep -qiE "403|404|410|Not Found|Must have admin rights|Resource not accessible|admin:org|This endpoint has been moved"; then
      hive_emit_event "PROGRESS" \
        "actions-budget-monitor: ${org} billing endpoint returned auth/scope/moved error (need admin:org scope or updated endpoint) — skipped"
      return 0
    fi

    # Other failure — emit BLOCKED via gh_api_safe retry path next time;
    # for now just surface the raw error.
    hive_emit_event "BLOCKED" \
      "actions-budget-monitor: ${org} billing fetch failed (exit=${exit_code}): $(head -c 200 "$gh_stderr")"
    return 1
  }

  # Parse fields.
  local total_used included paid_used spending_limit
  total_used="$(echo "$billing_json" | jq -r '.total_minutes_used // 0')"
  included="$(echo "$billing_json" | jq -r '.included_minutes // 0')"
  paid_used="$(echo "$billing_json" | jq -r '.total_paid_minutes_used // 0')"
  spending_limit="$(echo "$billing_json" | jq -r '.minutes_used_breakdown // null | if . then "paid" else "none" end')"

  # Effective budget = included_minutes (free tier cap).
  # If included_minutes == 0 (unlimited plan) emit info and skip threshold logic.
  if [[ "$included" -eq 0 ]]; then
    hive_emit_event "PROGRESS" \
      "actions-budget-monitor: ${org} included_minutes=0 (likely unlimited plan) — used=${total_used} min, paid=${paid_used} min"
    echo "[actions-budget-monitor] ${org}: unlimited plan — used=${total_used} min, paid=${paid_used} min"
    return 0
  fi

  # Compute usage percentage via shell arithmetic — no `bc` dependency,
  # no silent-0 on missing-tool (previously: `| bc 2>/dev/null || echo 0`
  # quietly reported 0% usage on any host without bc, masking billing
  # exhaustion). Guarded by the `included` non-zero check above.
  local pct=$(( total_used * 100 / included ))

  echo "[actions-budget-monitor] ${org}: ${total_used}/${included} min used (${pct}%)"

  # Always emit a PROGRESS with the reading.
  hive_emit_event "PROGRESS" \
    "actions-budget-monitor: ${org} ${pct}% used (${total_used}/${included} free-tier min, paid=${paid_used})"

  # >= 100%: EXHAUSTED — emit BLOCKED + label open sprint-milestone issues.
  if [[ "$pct" -ge 100 ]]; then
    hive_emit_event "BLOCKED" \
      "ACTIONS_BUDGET_EXHAUSTED: ${org} ${pct}% used — pipeline CI will fail; immediate action required"
    echo "[actions-budget-monitor] EXHAUSTED: ${org} at ${pct}%"

    if [[ "$DRY_RUN" -eq 0 ]]; then
      attach_exhausted_label "$org"
    else
      echo "[actions-budget-monitor] DRY_RUN: would attach label '${EXHAUSTED_LABEL}' to open sprint issues in ${org}"
    fi
    return 0
  fi

  # > 80%: WARN.
  if [[ "$pct" -gt 80 ]]; then
    hive_emit_event "BLOCKED" \
      "ACTIONS_BUDGET_WARN: ${org} ${pct}% used — approaching free-tier limit"
    echo "[actions-budget-monitor] WARN: ${org} at ${pct}%"
    return 0
  fi

  return 0
}

# ---------------------------------------------------------------------------
# attach_exhausted_label <org>
# Labels all open issues that are attached to the current sprint milestone
# with the actions-budget-exhausted label.
# ---------------------------------------------------------------------------
attach_exhausted_label() {
  local org="$1"

  # Enumerate repos in the org.
  local repos_json
  repos_json="$(gh_api_safe repo list "$org" --json name --limit 100 2>/dev/null)" || {
    hive_emit_event "PROGRESS" \
      "actions-budget-monitor: ${org} repo list failed, skipping label attachment"
    return 0
  }

  echo "$repos_json" | jq -r '.[].name' | while read -r repo_name; do
    local full_repo="${org}/${repo_name}"

    # Find the current sprint milestone.
    local milestone
    milestone="$(hive_current_sprint_milestone "$full_repo")" || continue
    [[ -z "$milestone" ]] && continue

    # Fetch open issues in this milestone.
    local issues_json
    issues_json="$(gh_api_safe issue list --repo "$full_repo" \
      --milestone "$milestone" --state open \
      --json number --limit 200 2>/dev/null)" || continue

    echo "$issues_json" | jq -r '.[].number' | while read -r issue_num; do
      gh issue edit "$issue_num" --repo "$full_repo" \
        --add-label "$EXHAUSTED_LABEL" 2>/dev/null \
        && hive_emit_event "PROGRESS" \
             "actions-budget-monitor: labelled ${full_repo}#${issue_num} with ${EXHAUSTED_LABEL}" \
        || true
    done
  done
}

# ---------------------------------------------------------------------------
# Main: iterate over orgs
# ---------------------------------------------------------------------------
any_error=0
for org in "${ORGS[@]}"; do
  check_org_budget "$org" || any_error=1
done

hive_emit_event "PROGRESS" "actions-budget-monitor: complete (any_error=${any_error})"
exit "$any_error"
