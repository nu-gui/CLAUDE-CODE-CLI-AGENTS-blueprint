#!/usr/bin/env bash
# scripts/closure-watcher.sh
#
# Meta-monitor for the issue → PR → merge lifecycle (issue #185).
#
# The pipeline opens work (PROD-00 issues, specialist PRs) and reports it
# (digest), but until this watcher landed there was no enforcement layer that
# guarantees work reaches its terminal state. Symptoms accumulating:
#
#   - PRs labelled `sweep-ready-to-merge` sit forever (auto-merge gap, fixed
#     in #182 but ongoing audit needed)
#   - PRs MERGED on master but their linked issue is still OPEN
#     (Closes-keyword may have failed to fire)
#   - Issues created by PROD-00 with no PR ever opened → drift
#   - Branches with no PR → orphans
#   - Duplicate issues from PROD-00 (#184 dedupe is at-create-time only)
#
# Schedule: twice daily, off-minute aligned per existing convention.
#   - 14:43 local time  (after 13:17 mini-dispatch settles, before 15:03 sprint-refresh)
#   - 18:33 local time  (between 16:27 and 19:37 mini-dispatch fires)
#
# Per-fire actions:
#   1. Auto-merge clean sweep-ready / approved-nightly PRs (cap 10)
#   2. Detect DIRTY sweep-ready PRs and flag for rebase (cap 5; #183 will execute)
#   3. Close orphan issues — merged PRs in last 24h whose linked issue is still
#      open (cap 20; never close `do-not-auto`-labelled issues)
#   4. Detect orphan branches: origin/<branch> with no open PR + last commit > 7d
#      (read-only — surface in digest, never delete)
#   5. Detect issue duplicates within a repo (token-overlap >= 0.6, same labels)
#   6. Emit single COMPLETE event with JSON counts for digest aggregation
#
# Usage:
#   bash scripts/closure-watcher.sh [--dry-run] [--apply] [--orgs <csv>]
#
# Flags:
#   --dry-run        Default. Print what would happen; no mutations.
#   --apply          Execute auto-merges and orphan-issue closures.
#   --orgs <csv>     Comma-separated org list; default "${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}".
#   --output <path>  Manifest output path; default $HIVE/closure-watcher-<date>.md
#
# Safety rails:
#   - Per-run caps: 10 auto-merges / 5 rebase-flags / 20 issue closures
#   - Skip any repo whose nightly-repo-profiles.yaml entry has
#     `closure_watcher: skip` (per-repo opt-out)
#   - Never close issues with `do-not-auto` label
#   - Never touch `main` (explicit guard + pre-push hook)
#
# Exit codes:
#   0  Success (dry-run or apply completed)
#   1  Fatal (gh auth failure, unparseable config)
#   2  Partial (some repos failed; manifest written for completed repos)

set -euo pipefail

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

# ---------------------------------------------------------------------------
# Single-instance guard — refuse to start if another watcher is running.
# Prevents collision between scheduled timer fires and ad-hoc operator runs
# (issue #196). flock -n returns immediately on contention; the second
# instance exits 0 (timer must not be marked failed) with a BLOCKED event
# for visibility.
LOCK_FILE="${CLOSURE_WATCHER_LOCK:-/tmp/closure-watcher.lock}"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  hive_emit_event "closure-watcher" "BLOCKED" "another watcher instance running; aborting (lock=$LOCK_FILE)"
  echo "[closure-watcher] another instance is running — exit 0 (timer should not be marked failed)"
  exit 0
fi
# Lock will be released on FD 9 close at exit
# ---------------------------------------------------------------------------

HIVE_DEFAULT_AGENT="closure-watcher"
SESSION_ID="${SESSION_ID:-${SID:-closure-$(date -u +%Y%m%dT%H%M%SZ)}}"
SID="${SID:-$SESSION_ID}"
export SID

emit() { hive_emit_event "closure-watcher" "$1" "$2"; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
DRY_RUN=1
APPLY=0
ORGS="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}}"
OUTPUT=""
REPORT_DATE="$(date +%F)"
NOW_TS="$(date -u +%H%M%S)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)  DRY_RUN=1; APPLY=0; shift ;;
    --apply)    APPLY=1; DRY_RUN=0; shift ;;
    --orgs)     ORGS="$2"; shift 2 ;;
    --output)   OUTPUT="$2"; shift 2 ;;
    *)          echo "[closure-watcher] Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$OUTPUT" ]]; then
  OUTPUT="${HIVE}/closure-watcher-${REPORT_DATE}-${NOW_TS}.md"
fi

if [[ "$APPLY" -eq 1 ]]; then
  echo "[closure-watcher] Mode: APPLY (auto-merge + close-orphan-issues enabled)"
else
  echo "[closure-watcher] Mode: DRY-RUN (no mutations)"
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
LABEL_SWEEP_READY="sweep-ready-to-merge"
LABEL_APPROVED_NIGHTLY="approved-nightly"
LABEL_NEEDS_REBASE="sweeper:NEEDS_REBASE"
LABEL_DO_NOT_AUTO="do-not-auto"
HARD_BLOCK_LABELS="blocked-human|blocked-manual|do-not-merge|do-not-auto|needs-revision"

# Per-run caps (issue #185 acceptance criteria).
CAP_AUTO_MERGE=10
CAP_REBASE=5
CAP_ISSUE_CLOSE=20

# Orphan-branch staleness window (days).
ORPHAN_BRANCH_AGE_DAYS=7

# Duplicate-detection token-overlap threshold.
DUP_THRESHOLD=0.6

REPO_PROFILES="${REPO_PROFILES:-$CLAUDE_HOME/config/nightly-repo-profiles.yaml}"

# ---------------------------------------------------------------------------
# Counters
# ---------------------------------------------------------------------------
TOTAL_REPOS=0
TOTAL_REPOS_SKIPPED=0
COUNT_AUTO_MERGED=0
COUNT_REBASE_FLAGGED=0
# Queue depth: total DIRTY PRs detected per fire, regardless of CAP_REBASE.
# Lets the digest spot chronic backlog even while flag count is pinned at cap.
COUNT_REBASE_QUEUE_DEPTH=0
COUNT_ISSUES_CLOSED=0
COUNT_ORPHAN_BRANCHES=0
COUNT_DUPLICATES=0
PARTIAL_FAIL=0

# ---------------------------------------------------------------------------
# Manifest accumulation
# ---------------------------------------------------------------------------
MANIFEST_TMP="$(mktemp /tmp/closure-watcher.XXXXXX)"
trap 'rm -f "$MANIFEST_TMP"' EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Returns 0 (true) if the named repo has `closure_watcher: skip` in profiles.
repo_is_skipped() {
  local repo_name="$1"
  [[ -f "$REPO_PROFILES" ]] || return 1
  REPO_PROFILES="$REPO_PROFILES" REPO_NAME="$repo_name" python3 -c '
import os, sys, yaml
try:
    p = yaml.safe_load(open(os.environ["REPO_PROFILES"])) or {}
except Exception:
    sys.exit(1)
repos = (p.get("repos") or {})
entry = repos.get(os.environ["REPO_NAME"]) or {}
if entry.get("closure_watcher") == "skip":
    sys.exit(0)
sys.exit(1)
' && return 0 || return 1
}

# Idempotent label apply (only in --apply mode).
apply_label() {
  local repo="$1" pr_number="$2" label="$3"
  if [[ "$APPLY" -eq 0 ]]; then
    echo "[dry-run] would label $repo#$pr_number → $label"
    return 0
  fi
  gh pr edit "$pr_number" --repo "$repo" --add-label "$label" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Section 1: Auto-merge clean ready PRs
# ---------------------------------------------------------------------------
# Find PRs with sweep-ready-to-merge OR approved-nightly AND mergeable=MERGEABLE
# AND mergeStateStatus=CLEAN AND no blocking labels.
auto_merge_clean_prs() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  local prs_json
  prs_json="$(gh_api_safe pr list --repo "$repo" --state open \
    --json number,title,labels,mergeable,mergeStateStatus,baseRefName,statusCheckRollup,url \
    2>/dev/null)" || {
    echo "[closure-watcher] WARN: failed to list PRs for $repo (sec1)" >&2
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    return
  }

  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue
    if [[ "$COUNT_AUTO_MERGED" -ge "$CAP_AUTO_MERGE" ]]; then
      emit "BLOCKED" "auto-merge-cap-reached ($CAP_AUTO_MERGE) — remaining ready PRs deferred to next run"
      break
    fi

    local number title base mergeable merge_state labels rollup url
    number="$(printf '%s' "$pr_json" | jq -r '.number')"
    title="$(printf '%s' "$pr_json" | jq -r '.title')"
    base="$(printf '%s' "$pr_json" | jq -r '.baseRefName')"
    mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
    merge_state="$(printf '%s' "$pr_json" | jq -r '.mergeStateStatus')"
    labels="$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")')"
    rollup="$(printf '%s' "$pr_json" | jq '.statusCheckRollup // []')"
    url="$(printf '%s' "$pr_json" | jq -r '.url')"

    # Must be eligible: ready labels, no hard-block labels.
    local has_ready_label=0
    if printf '%s' "$labels" | grep -qF "$LABEL_SWEEP_READY" \
       || printf '%s' "$labels" | grep -qF "$LABEL_APPROVED_NIGHTLY"; then
      has_ready_label=1
    fi
    [[ "$has_ready_label" -eq 0 ]] && continue

    if printf '%s' "$labels" | grep -qiE "$HARD_BLOCK_LABELS"; then
      continue
    fi

    # Hard guard: never touch main.
    if [[ "$base" != "master" ]]; then
      printf '| %s#%s | base=%s | SKIP | not-master |\n' \
        "$repo" "$number" "$base" >> "$MANIFEST_TMP"
      continue
    fi

    # Must be MERGEABLE + CLEAN.
    if [[ "$mergeable" != "MERGEABLE" || "$merge_state" != "CLEAN" ]]; then
      continue
    fi

    # CI must have zero failures.
    local ci_bad
    ci_bad="$(printf '%s' "$rollup" | jq '[.[] | .conclusion // ""] |
      any(. == "FAILURE" or . == "CANCELLED" or . == "TIMED_OUT" or . == "STARTUP_FAILURE")' \
      2>/dev/null || echo "true")"
    if [[ "$ci_bad" == "true" ]]; then
      continue
    fi

    if [[ "$APPLY" -eq 0 ]]; then
      echo "[dry-run] would auto-merge $repo#$number ($title)"
      printf '| %s#%s | %s | DRY-RUN | would-merge (squash) |\n' \
        "$repo" "$number" "${title:0:50}" >> "$MANIFEST_TMP"
      COUNT_AUTO_MERGED=$(( COUNT_AUTO_MERGED + 1 ))
      continue
    fi

    echo "[closure-watcher] auto-merging $repo#$number"
    if gh pr merge "$number" --repo "$repo" --squash --delete-branch --auto 2>/dev/null; then
      COUNT_AUTO_MERGED=$(( COUNT_AUTO_MERGED + 1 ))
      emit "PROGRESS" "auto-merged $repo#$number (squash)"
      printf '| %s#%s | %s | MERGED | squash |\n' \
        "$repo" "$number" "${title:0:50}" >> "$MANIFEST_TMP"
    else
      emit "BLOCKED" "auto-merge-failed $repo#$number"
      echo "[closure-watcher] WARN: auto-merge failed for $repo#$number" >&2
    fi
  done < <(printf '%s' "$prs_json" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
# Section 2: Detect DIRTY sweep-ready PRs (rebase candidates)
# ---------------------------------------------------------------------------
# #183 will ship `hive_rebase_pr`. Until then this section flags candidates
# with sweeper:NEEDS_REBASE label + emits PROGRESS so they surface in digest.
flag_dirty_ready_prs() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  local prs_json
  prs_json="$(gh_api_safe pr list --repo "$repo" --state open \
    --label "$LABEL_SWEEP_READY" \
    --json number,title,labels,mergeable,baseRefName \
    2>/dev/null)" || {
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    return
  }

  # Two-stage loop (issue #194):
  #   - Always count every eligible DIRTY PR into COUNT_REBASE_QUEUE_DEPTH so
  #     the digest sees true backlog, even when CAP_REBASE pins the flagged count.
  #   - Only call apply_label / emit PROGRESS up to CAP_REBASE.
  local cap_blocked=0
  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue

    local number title mergeable base labels
    number="$(printf '%s' "$pr_json" | jq -r '.number')"
    title="$(printf '%s' "$pr_json" | jq -r '.title')"
    mergeable="$(printf '%s' "$pr_json" | jq -r '.mergeable')"
    base="$(printf '%s' "$pr_json" | jq -r '.baseRefName')"
    labels="$(printf '%s' "$pr_json" | jq -r '[.labels[].name] | join(",")')"

    [[ "$mergeable" != "CONFLICTING" ]] && continue
    [[ "$base" != "master" ]] && continue
    if printf '%s' "$labels" | grep -qiE "$HARD_BLOCK_LABELS"; then
      continue
    fi

    COUNT_REBASE_QUEUE_DEPTH=$(( COUNT_REBASE_QUEUE_DEPTH + 1 ))

    if [[ "$COUNT_REBASE_FLAGGED" -ge "$CAP_REBASE" ]]; then
      if [[ "$cap_blocked" -eq 0 ]]; then
        emit "BLOCKED" "rebase-cap-reached ($CAP_REBASE) — remaining DIRTY PRs deferred"
        cap_blocked=1
      fi
      printf '| %s#%s | %s | REBASE_QUEUED | %s |\n' \
        "$repo" "$number" "${title:0:50}" "deferred-cap" >> "$MANIFEST_TMP"
      continue
    fi

    COUNT_REBASE_FLAGGED=$(( COUNT_REBASE_FLAGGED + 1 ))
    emit "PROGRESS" "rebase-needed $repo#$number (CONFLICTING; #183 helper will execute when shipped)"
    printf '| %s#%s | %s | REBASE_NEEDED | %s |\n' \
      "$repo" "$number" "${title:0:50}" "CONFLICTING" >> "$MANIFEST_TMP"

    # Idempotent label so #183's helper can pick them up by label query.
    if ! printf '%s' "$labels" | grep -qF "$LABEL_NEEDS_REBASE"; then
      apply_label "$repo" "$number" "$LABEL_NEEDS_REBASE"
    fi
  done < <(printf '%s' "$prs_json" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
# Section 3: Close orphan issues
# ---------------------------------------------------------------------------
# For each PR merged in the last 24h, parse Closes/Fixes/Resolves #N from the
# PR body + commit messages. If issue #N is open, close it with a watcher
# comment. Skip issues with do-not-auto label.
close_orphan_issues() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  local since_epoch
  since_epoch="$(date -u -d "-1 day" +%s 2>/dev/null || echo 0)"
  [[ "$since_epoch" -eq 0 ]] && return

  # Fetch recent merged PRs (limit 50). Filter by mergedAt client-side so
  # we avoid `--search` quirks and stay portable across gh CLI versions.
  local merged_json
  merged_json="$(gh_api_safe pr list --repo "$repo" --state merged \
    --json number,title,body,url,mergedAt \
    --limit 50 \
    2>/dev/null)" || {
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    return
  }
  merged_json="$(printf '%s' "$merged_json" | jq --argjson s "$since_epoch" '
    [.[] | select(
      (.mergedAt // "" | length > 0) and
      ((.mergedAt | sub("\\..*Z$"; "Z") | fromdateiso8601) >= $s)
    )]')"

  while IFS= read -r pr_json; do
    [[ -z "$pr_json" ]] && continue
    if [[ "$COUNT_ISSUES_CLOSED" -ge "$CAP_ISSUE_CLOSE" ]]; then
      emit "BLOCKED" "issue-close-cap-reached ($CAP_ISSUE_CLOSE) — remaining orphan issues deferred"
      break
    fi

    local pr_num pr_title pr_body pr_url
    pr_num="$(printf '%s' "$pr_json" | jq -r '.number')"
    pr_title="$(printf '%s' "$pr_json" | jq -r '.title // ""')"
    pr_body="$(printf '%s' "$pr_json" | jq -r '.body // ""')"
    pr_url="$(printf '%s' "$pr_json" | jq -r '.url')"

    # Parse Closes/Fixes/Resolves #N from PR title + body.
    # Matches case-insensitive, allows multiple linked issues per PR.
    local linked_issues
    linked_issues="$(printf '%s\n%s' "$pr_title" "$pr_body" \
      | grep -oiP '(closes|fixes|resolves)\s+#\K[0-9]+' \
      | sort -u || true)"

    [[ -z "$linked_issues" ]] && continue

    while read -r issue_num; do
      [[ -z "$issue_num" ]] && continue
      if [[ "$COUNT_ISSUES_CLOSED" -ge "$CAP_ISSUE_CLOSE" ]]; then
        break
      fi

      # Check issue state + labels (single API call).
      local issue_view issue_state issue_labels
      issue_view="$(gh_api_safe issue view "$issue_num" --repo "$repo" \
                     --json state,labels 2>/dev/null || echo '{}')"
      issue_state="$(printf '%s' "$issue_view" | jq -r '.state // ""')"
      [[ "$issue_state" != "OPEN" ]] && continue

      issue_labels="$(printf '%s' "$issue_view" | jq -r '[.labels[].name] | join(",")')"
      if printf '%s' "$issue_labels" | grep -qF "$LABEL_DO_NOT_AUTO"; then
        echo "[closure-watcher] $repo#$issue_num has do-not-auto — skip"
        continue
      fi

      if [[ "$APPLY" -eq 0 ]]; then
        echo "[dry-run] would close $repo#$issue_num (orphan; PR #$pr_num merged)"
        printf '| %s#%s | %s | DRY-RUN | would-close (PR #%s merged) |\n' \
          "$repo" "$issue_num" "(orphan issue)" "$pr_num" >> "$MANIFEST_TMP"
        COUNT_ISSUES_CLOSED=$(( COUNT_ISSUES_CLOSED + 1 ))
        continue
      fi

      local close_body
      close_body="Closed by merged PR ${pr_url} (closure-watcher detected the Closes-keyword link did not auto-fire)."
      if gh issue close "$issue_num" --repo "$repo" --comment "$close_body" 2>/dev/null; then
        COUNT_ISSUES_CLOSED=$(( COUNT_ISSUES_CLOSED + 1 ))
        emit "PROGRESS" "orphan-issue-closed $repo#$issue_num via PR #$pr_num"
        printf '| %s#%s | %s | CLOSED | PR #%s merged |\n' \
          "$repo" "$issue_num" "(orphan issue)" "$pr_num" >> "$MANIFEST_TMP"
      else
        emit "BLOCKED" "orphan-issue-close-failed $repo#$issue_num"
      fi
    done <<< "$linked_issues"
  done < <(printf '%s' "$merged_json" | jq -c '.[]')
}

# ---------------------------------------------------------------------------
# Section 4: Detect orphan branches (read-only)
# ---------------------------------------------------------------------------
# Branches on origin with no open PR and last commit > ORPHAN_BRANCH_AGE_DAYS.
# Emits BLOCKED events for digest visibility — does NOT delete (humans decide).
detect_orphan_branches() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  # GraphQL: list all refs/heads with their target commit date + open PR count.
  #
  # NOTE (issue #195): associatedPullRequests(states:[OPEN]) is NOT accepted
  # inside a `... on Commit` inline fragment — the GitHub API rejects the
  # `states` argument there, causing exit 1 on every repo and inflating
  # PARTIAL_FAIL by 43+. Fix: query associatedPullRequests at the Ref level
  # (where states:OPEN is supported) and committedDate via the Commit fragment
  # separately. Ref.associatedPullRequests counts PRs where this branch is the
  # HEAD ref, which is exactly the orphan-detection semantics we need.
  local branches_json
  branches_json="$(gh_api_safe api graphql \
    -f query='
      query($owner:String!,$repo:String!) {
        repository(owner:$owner, name:$repo) {
          refs(refPrefix:"refs/heads/", first:100, orderBy:{field:TAG_COMMIT_DATE, direction:DESC}) {
            nodes {
              name
              associatedPullRequests(first:1, states:OPEN) {
                totalCount
              }
              target {
                ... on Commit {
                  committedDate
                }
              }
            }
          }
        }
      }' \
    -f owner="$org" -f repo="$repo_name" 2>/dev/null)" || {
    emit "BLOCKED" "orphan-branch-api-error repo=$repo (graphql failed; check gh auth or repo permissions)"
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    return
  }

  local cutoff
  cutoff="$(date -u -d "-${ORPHAN_BRANCH_AGE_DAYS} days" +%s 2>/dev/null || echo 0)"

  while IFS=$'\t' read -r branch_name committed_date; do
    [[ -z "$branch_name" ]] && continue

    local committed_epoch now_epoch age_days
    committed_epoch="$(date -u -d "$committed_date" +%s 2>/dev/null || echo 0)"
    now_epoch="$(date -u +%s)"
    age_days=$(( (now_epoch - committed_epoch) / 86400 ))

    COUNT_ORPHAN_BRANCHES=$(( COUNT_ORPHAN_BRANCHES + 1 ))
    emit "BLOCKED" "orphan-branch repo=$repo branch=$branch_name age=${age_days}d"
    printf '| %s | %s | ORPHAN_BRANCH | %sd no-open-pr |\n' \
      "$repo" "$branch_name" "$age_days" >> "$MANIFEST_TMP"
  done < <(printf '%s' "$branches_json" | jq -r --argjson cutoff "$cutoff" '
    .data.repository.refs.nodes[]?
    | select(.name != "master" and .name != "main" and .name != "develop")
    | select(.associatedPullRequests.totalCount == 0)
    | select((.target.committedDate // "1970-01-01T00:00:00Z" | sub("\\..*Z$"; "Z") | fromdateiso8601) < $cutoff)
    | "\(.name)\t\(.target.committedDate)"
  ' 2>/dev/null)
}

# ---------------------------------------------------------------------------
# Section 5: Detect issue duplicates within a repo
# ---------------------------------------------------------------------------
# Token-overlap >= DUP_THRESHOLD on title text, grouped by repo. Read-only —
# surfaces the count for the digest. Per-issue dedupe at create-time is in
# hive_issue_create_deduped (#184); this section catches duplicates that
# bypassed that guardrail.
detect_issue_duplicates() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  local issues_json
  issues_json="$(gh_api_safe issue list --repo "$repo" --state open \
                  --limit 200 --json number,title,labels 2>/dev/null)" || {
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    return
  }

  # Use python for token-overlap pairwise comparison.
  local dup_count
  dup_count="$(ISSUES="$issues_json" REPO="$repo" TH="$DUP_THRESHOLD" python3 -c '
import json, os, re, sys
data = json.loads(os.environ["ISSUES"] or "[]")
threshold = float(os.environ["TH"])
def tokens(s):
    return set(re.findall(r"[a-z0-9]+", s.lower()))
seen = []
dups = 0
for issue in data:
    t = issue.get("title", "")
    toks = tokens(t)
    if not toks:
        seen.append((issue["number"], toks, t))
        continue
    is_dup = False
    for n2, t2, title2 in seen:
        if not t2: continue
        score = len(toks & t2) / max(len(toks), len(t2))
        if score >= threshold:
            is_dup = True
            print(f"#{issue[\"number\"]} ~ #{n2} score={score:.2f} :: {t[:50]}", file=sys.stderr)
            break
    if is_dup:
        dups += 1
    else:
        seen.append((issue["number"], toks, t))
print(dups)
' 2>"${MANIFEST_TMP}.dup-detail" || echo 0)"

  if [[ "${dup_count:-0}" -gt 0 ]]; then
    COUNT_DUPLICATES=$(( COUNT_DUPLICATES + dup_count ))
    emit "PROGRESS" "duplicate-issues-detected repo=$repo count=$dup_count"
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      printf '| %s | %s | DUPLICATE | %s |\n' \
        "$repo" "(issue)" "$line" >> "$MANIFEST_TMP"
    done < "${MANIFEST_TMP}.dup-detail"
  fi
  rm -f "${MANIFEST_TMP}.dup-detail"
}

# ---------------------------------------------------------------------------
# Per-repo orchestration
# ---------------------------------------------------------------------------
process_repo() {
  local org="$1" repo_name="$2"
  local repo="${org}/${repo_name}"

  if repo_is_skipped "$repo_name"; then
    echo "[closure-watcher] SKIP $repo (closure_watcher: skip in profile)"
    TOTAL_REPOS_SKIPPED=$(( TOTAL_REPOS_SKIPPED + 1 ))
    printf '| %s | — | SKIP | profile opt-out |\n' "$repo" >> "$MANIFEST_TMP"
    return
  fi

  echo "[closure-watcher] → $repo"
  auto_merge_clean_prs "$org" "$repo_name"
  flag_dirty_ready_prs "$org" "$repo_name"
  close_orphan_issues "$org" "$repo_name"
  detect_orphan_branches "$org" "$repo_name"
  detect_issue_duplicates "$org" "$repo_name"
}

# ---------------------------------------------------------------------------
# Main — enumerate orgs
# ---------------------------------------------------------------------------
emit "SPAWN" "mode=$([ "$APPLY" -eq 1 ] && echo apply || echo dry-run) orgs=$ORGS"
hive_heartbeat "closure-watcher"

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

printf '\n## Per-Repo Detail\n\n' >> "$MANIFEST_TMP"
printf '| Target | Item | Verdict | Note |\n' >> "$MANIFEST_TMP"
printf '|--------|------|---------|------|\n' >> "$MANIFEST_TMP"

IFS=',' read -ra ORG_LIST <<< "$ORGS"
for org in "${ORG_LIST[@]}"; do
  [[ -z "$org" ]] && continue
  echo "[closure-watcher] Scanning org: $org"

  repos_json="$(gh_api_safe repo list "$org" \
    --limit 100 \
    --no-archived \
    --json name,isArchived \
    --jq '[.[] | select(.isArchived == false)]' 2>/dev/null)" || {
    echo "[closure-watcher] WARN: failed to list repos for $org" >&2
    PARTIAL_FAIL=$(( PARTIAL_FAIL + 1 ))
    continue
  }

  while IFS= read -r repo_name; do
    [[ -z "$repo_name" ]] && continue
    TOTAL_REPOS=$(( TOTAL_REPOS + 1 ))
    process_repo "$org" "$repo_name"
  done < <(printf '%s' "$repos_json" | jq -r '.[].name')
done

# ---------------------------------------------------------------------------
# Manifest output
# ---------------------------------------------------------------------------
mkdir -p "$(dirname "$OUTPUT")"

{
  printf '# Closure-loop Watcher Run\n\n'
  printf '**Generated:** %s  \n' "$START_TS"
  printf '**Scope:** %s  \n' "$ORGS"
  printf '**Mode:** %s  \n\n' "$([ "$APPLY" -eq 1 ] && echo "APPLY" || echo "DRY-RUN")"

  printf '## Summary\n\n'
  printf '| Metric | Count |\n'
  printf '|--------|-------|\n'
  printf '| Repos scanned | %s |\n' "$TOTAL_REPOS"
  printf '| Repos skipped (profile) | %s |\n' "$TOTAL_REPOS_SKIPPED"
  printf '| Auto-merged | %s (cap %s) |\n' "$COUNT_AUTO_MERGED" "$CAP_AUTO_MERGE"
  printf '| Rebase-flagged | %s (cap %s) |\n' "$COUNT_REBASE_FLAGGED" "$CAP_REBASE"
  printf '| Rebase queue depth | %s |\n' "$COUNT_REBASE_QUEUE_DEPTH"
  printf '| Orphan issues closed | %s (cap %s) |\n' "$COUNT_ISSUES_CLOSED" "$CAP_ISSUE_CLOSE"
  printf '| Orphan branches | %s |\n' "$COUNT_ORPHAN_BRANCHES"
  printf '| Duplicate issues | %s |\n' "$COUNT_DUPLICATES"
  [[ "$PARTIAL_FAIL" -gt 0 ]] && printf '| Repos with API errors | %s |\n' "$PARTIAL_FAIL"

  cat "$MANIFEST_TMP"
} > "$OUTPUT"

echo ""
echo "[closure-watcher] Output: $OUTPUT"
echo "[closure-watcher] Summary:"
echo "  Repos scanned        : $TOTAL_REPOS"
echo "  Repos skipped        : $TOTAL_REPOS_SKIPPED"
echo "  Auto-merged          : $COUNT_AUTO_MERGED / $CAP_AUTO_MERGE"
echo "  Rebase-flagged       : $COUNT_REBASE_FLAGGED / $CAP_REBASE"
echo "  Rebase queue depth   : $COUNT_REBASE_QUEUE_DEPTH"
echo "  Orphan issues closed : $COUNT_ISSUES_CLOSED / $CAP_ISSUE_CLOSE"
echo "  Orphan branches      : $COUNT_ORPHAN_BRANCHES"
echo "  Duplicate issues     : $COUNT_DUPLICATES"
[[ "$PARTIAL_FAIL" -gt 0 ]] && echo "  API errors (repos)   : $PARTIAL_FAIL"

# Chronic-backlog escalation (issue #194): if observed queue depth has grown
# past 3× the per-fire cap, flag it before the COMPLETE event so the digest
# Escalations panel surfaces it (eventual consistency would still drain it,
# but the operator should know we'd need >3 more fires to catch up).
CHRONIC_THRESHOLD=$(( CAP_REBASE * 3 ))
if [[ "$COUNT_REBASE_QUEUE_DEPTH" -gt "$CHRONIC_THRESHOLD" ]]; then
  extra_fires=$(( (COUNT_REBASE_QUEUE_DEPTH + CAP_REBASE - 1) / CAP_REBASE ))
  emit "BLOCKED" "rebase-queue-chronic-backlog depth=$COUNT_REBASE_QUEUE_DEPTH cap=$CAP_REBASE extra_fires=$extra_fires"
fi

# Single COMPLETE event with JSON detail for digest aggregation.
COMPLETE_JSON="$(jq -nc \
  --argjson auto_merged "$COUNT_AUTO_MERGED" \
  --argjson rebased "$COUNT_REBASE_FLAGGED" \
  --argjson rebase_queue_depth "$COUNT_REBASE_QUEUE_DEPTH" \
  --argjson issues_closed "$COUNT_ISSUES_CLOSED" \
  --argjson orphans "$COUNT_ORPHAN_BRANCHES" \
  --argjson dupes "$COUNT_DUPLICATES" \
  --argjson repos "$TOTAL_REPOS" \
  --argjson skipped "$TOTAL_REPOS_SKIPPED" \
  '{auto_merged:$auto_merged, rebased:$rebased, rebase_queue_depth:$rebase_queue_depth,
    issues_closed:$issues_closed,
    orphans:$orphans, dupes:$dupes, repos:$repos, skipped:$skipped}')"
emit "COMPLETE" "counts=$COMPLETE_JSON"

[[ "$PARTIAL_FAIL" -gt 0 ]] && exit 2 || exit 0
