#!/usr/bin/env bash
# nightly-select-projects.sh
#
# Dynamic project selector for the nightly-puffin pipeline.
# Queries gh CLI for repos/issues/PRs under the configured owner,
# applies the readiness scoring formula, emits the top-N queue.
#
# Output:
#   ~/.claude/context/hive/nightly-queue.json  (primary queue)
#   ~/.claude/context/hive/nightly-queue.cache.json  (fallback for later stages)
#
# Exit codes:
#   0   success (queue written; may be empty → "quiet night")
#   10  gh auth failure (escalation-worthy)
#   20  config missing
#   30  no repos matched filters (not an error; selector emits empty queue)

set -euo pipefail

# Shared helpers (issue #35 / #47): cron PATH + canonical hive_emit_event.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/nightly-repo-profiles.yaml"
QUEUE="$HIVE/nightly-queue.json"
CACHE="$HIVE/nightly-queue.cache.json"
HIVE_DEFAULT_AGENT="selector"

# W19-ID22: accept comma-separated owner list so ${GITHUB_ORG:-your-org} (and any future org)
# is in scope. Default keeps backward-compat for single-owner setups.
NIGHTLY_OWNER="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org},${GITHUB_ORG:-your-org}}"
IFS=',' read -r -a OWNERS <<< "$NIGHTLY_OWNER"
OWNER="${OWNERS[0]}"  # kept for any legacy scalar reference in this file
# W18-ID17: doubled MAX_REPOS/MAX_ISSUES defaults per user directive.
MAX_REPOS="${NIGHTLY_MAX_REPOS:-6}"
MAX_ISSUES="${NIGHTLY_MAX_ISSUES:-16}"
READINESS_THRESHOLD="${NIGHTLY_READINESS_THRESHOLD:-40}"
TODAY="$(date -u +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
SESSION_ID="nightly-${TODAY}-selector"

mkdir -p "$HIVE" "$ESC_DIR"

emit_event() { hive_emit_event "$HIVE_DEFAULT_AGENT" "$1" "$2"; }

escalate() {
  local code="$1" msg="$2"
  local f="$ESC_DIR/${TODAY}-selector.md"
  {
    echo "# Nightly selector escalation — $TODAY"
    echo ""
    echo "**Code:** $code"
    echo "**Message:** $msg"
    echo "**When:** $NOW_ISO"
  } > "$f"
  emit_event "BLOCKED" "selector:$code: $msg"
}

emit_event "SPAWN" "selector started; owner=$OWNER max_repos=$MAX_REPOS"
hive_heartbeat "nightly-select-projects"

# Preflight: config + gh auth
[[ -f "$PROFILES" ]] || { escalate "CONFIG_MISSING" "$PROFILES"; exit 20; }
gh auth status >/dev/null 2>&1 || { escalate "GH_AUTH_FAIL" "gh auth status failed"; exit 10; }

# Preflight: scheduler triggers present (#72 / PUFFIN-N3, extended by #84 / N3a).
# Refuse to run the selector if no nightly-puffin triggers are registered — otherwise
# we silently build a queue nothing will consume. Sources checked:
#   1. systemd --user timers (visible)
#   2. user crontab (visible)
#   3. Anthropic /schedule durable jobs persisted at ~/.claude/scheduled_tasks.json (N3a)
# The /schedule source is how Anthropic-managed recurring jobs (durable=true) register
# — invisible to systemd/cron but present in the JSON store.
# Skip the guard when NIGHTLY_SKIP_TRIGGER_CHECK=1 (for manual debug runs).
if [[ "${NIGHTLY_SKIP_TRIGGER_CHECK:-0}" != "1" ]]; then
  sd_count=$(systemctl --user list-timers --no-pager --all 2>/dev/null | grep -ciE 'nightly|puffin' || true)
  cr_count=$(crontab -l 2>/dev/null | grep -ciE 'nightly|puffin' || true)
  sch_count=$(jq '[.[] | select((.prompt // "") | test("nightly|puffin"; "i"))] | length' "$HOME/.claude/scheduled_tasks.json" 2>/dev/null || echo 0)
  if [[ "${sd_count:-0}" -eq 0 && "${cr_count:-0}" -eq 0 && "${sch_count:-0}" -eq 0 ]]; then
    mkdir -p "$HOME/.claude/logs"
    echo "$NOW_ISO [nightly-select-projects] BLOCKED: no scheduler triggers registered (systemd=$sd_count cron=$cr_count schedule=$sch_count). Run /schedule create for the nightly-schedule.yaml entries, or set NIGHTLY_SKIP_TRIGGER_CHECK=1 to bypass." >> "$HOME/.claude/logs/nightly-errors.log"
    escalate "NO_TRIGGERS" "No nightly-puffin triggers in systemd/cron/schedule sources. Selector refuses to run (exit 2). Register triggers via /schedule (durable=true) or set NIGHTLY_SKIP_TRIGGER_CHECK=1."
    exit 2
  fi
  emit_event "PROGRESS" "trigger-preflight-ok: systemd=$sd_count cron=$cr_count schedule=$sch_count"
fi

# --- Fetch repos across ALL configured owners (W19-ID22) ---
# Each repo row is augmented with an `owner` field so downstream scoring +
# queue-emit stages can distinguish same-name repos across orgs.
#
# Union step uses temp files + slurpfile to avoid ARG_MAX on large payloads
# (same class as W19-ID21). Accumulate into a single tmpfile across iterations.
_union_dir="$(mktemp -d /tmp/nightly-select-union.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '$_union_dir' ${_scored_tmpdir:-}" EXIT
echo '[]' > "$_union_dir/repos.json"
for _own in "${OWNERS[@]}"; do
  _raw_file="$_union_dir/raw_${_own}.json"
  gh_api_safe repo list "$_own" --limit 200 \
    --json name,pushedAt,updatedAt,isArchived,isFork,defaultBranchRef,primaryLanguage,url \
    > "$_raw_file" || {
    escalate "GH_RATE_LIMIT" "gh repo list failed for owner=$_own — aborting selector"
    exit 10
  }
  _acc="$_union_dir/repos.json"
  _next="$_union_dir/repos.next.json"
  jq --slurpfile acc "$_acc" --slurpfile new "$_raw_file" --arg own "$_own" -n \
    '$acc[0] + ($new[0] | map(. + {owner:$own}))' > "$_next"
  mv "$_next" "$_acc"
done
REPOS_RAW="$(cat "$_union_dir/repos.json")"

# Filter: not archived, pushed within 30 days
REPOS_FILTERED="$(echo "$REPOS_RAW" | jq --arg now "$NOW_ISO" '
  map(select(
    .isArchived == false
    and (.pushedAt | sub("\\..*Z$"; "Z") | fromdateiso8601) >
        (($now | sub("\\..*Z$"; "Z") | fromdateiso8601) - 60*60*24*30)
  ))
')"

N_REPOS="$(echo "$REPOS_FILTERED" | jq 'length')"
emit_event "PROGRESS" "repos_active_30d=$N_REPOS"

if [[ "$N_REPOS" -eq 0 ]]; then
  echo '{"generated_at":"'"$NOW_ISO"'","repos":[],"reason":"no_active_repos","dependabot_prs":[]}' > "$QUEUE"
  cp "$QUEUE" "$CACHE"
  emit_event "COMPLETE" "empty queue (quiet night)"
  exit 0
fi

# --- Fetch open issues and PRs across ALL configured owners (W19-ID22) ---
# Union via temp files to avoid ARG_MAX (same class fix as REPOS_RAW above).
echo '[]' > "$_union_dir/issues.json"
echo '[]' > "$_union_dir/prs.json"
for _own in "${OWNERS[@]}"; do
  _ij_file="$_union_dir/issues_${_own}.json"
  gh_api_safe search issues --owner="$_own" --state=open \
    --json repository,number,title,updatedAt,labels,assignees --limit 200 \
    > "$_ij_file" || {
    escalate "GH_RATE_LIMIT" "gh search issues failed for owner=$_own — aborting selector"
    exit 10
  }
  _next="$_union_dir/issues.next.json"
  jq --slurpfile acc "$_union_dir/issues.json" --slurpfile new "$_ij_file" -n '$acc[0] + $new[0]' > "$_next"
  mv "$_next" "$_union_dir/issues.json"

  _pj_file="$_union_dir/prs_${_own}.json"
  gh_api_safe search prs --owner="$_own" --state=open \
    --json repository,number,title,updatedAt,isDraft,labels,author --limit 200 \
    > "$_pj_file" || {
    escalate "GH_RATE_LIMIT" "gh search prs failed for owner=$_own — aborting selector"
    exit 10
  }
  _next="$_union_dir/prs.next.json"
  jq --slurpfile acc "$_union_dir/prs.json" --slurpfile new "$_pj_file" -n '$acc[0] + $new[0]' > "$_next"
  mv "$_next" "$_union_dir/prs.json"
done
ISSUES_JSON="$(cat "$_union_dir/issues.json")"
PRS_JSON="$(cat "$_union_dir/prs.json")"

# Stale-PR sweep: open PRs whose last activity is older than STALE_WINDOW_SEC
# (default 24h). Excludes draft PRs, dependabot-authored, and dependabot-labeled
# (those are handled by the nightly-dependabot-merge.sh side-track). Grouped by
# (repo, specialist) using the [AGENT-*] title prefix so dispatch can hand them
# to the right specialist. If no specialist dispatches tonight for a given
# domain, the digest still surfaces the PR under "Stale PRs awaiting sweeper."
STALE_WINDOW_SEC="${NIGHTLY_STALE_PR_WINDOW_SEC:-86400}"
STALE_CUTOFF_EPOCH="$(date -u -d "-${STALE_WINDOW_SEC} seconds" +%s 2>/dev/null || echo 0)"

# Archived repos reject all writes (merges, comments, label edits). Sweeper
# attempts on open PRs from archived repos would produce benign but noisy
# failures — exclude them up front.
ARCHIVED_REPOS="$(echo "$REPOS_RAW" | jq '
  [ .[] | select(.isArchived == true) | .name ]
')"

# --- Red-CI boost: fetch statusCheckRollup for nightly-automation PRs (issue #22) ---
# gh search prs does not expose statusCheckRollup. We do a targeted per-org
# `gh pr list --label nightly-automation` (which supports --json statusCheckRollup)
# and build a lookup map keyed by "nameWithOwner#number" → has_red_ci (boolean).
# Missing label or fetch failure → graceful empty map (no boost, no error).
# Reuses REPOS_RAW (already fetched) to enumerate repos — no extra API calls.
_red_ci_map="{}"
for _own in "${OWNERS[@]}"; do
  # Repos for this owner already fetched into REPOS_RAW (with .owner field)
  while IFS= read -r _repo_name; do
    [[ -z "$_repo_name" ]] && continue
    _na_prs="$(gh pr list \
      --repo "${_own}/${_repo_name}" \
      --state open \
      --label nightly-automation \
      --json number,statusCheckRollup \
      --limit 100 2>/dev/null || echo '[]')"
    if [[ -z "$_na_prs" || "$_na_prs" == "null" || "$_na_prs" == "[]" ]]; then
      continue
    fi
    # Build map entries: key = "nameWithOwner#number", value = has_red_ci
    _new_entries="$(printf '%s' "$_na_prs" | jq \
      --arg own "$_own" --arg repo "$_repo_name" '
      [ .[] | {
          key: ("\($own)/\($repo)#\(.number)"),
          value: ((.statusCheckRollup // []) | any(
            .conclusion == "FAILURE" or
            .conclusion == "CANCELLED" or
            .conclusion == "TIMED_OUT" or
            .conclusion == "STARTUP_FAILURE"
          ))
        }
      ] | from_entries
    ' 2>/dev/null || echo '{}')"
    _red_ci_map="$(jq -s '.[0] * .[1]' \
      <(printf '%s' "$_red_ci_map") \
      <(printf '%s' "$_new_entries") 2>/dev/null || echo "$_red_ci_map")"
  done < <(echo "$REPOS_RAW" | jq -r \
    --arg own "$_own" '.[] | select(.owner == $own) | .name' 2>/dev/null || true)
done

printf '%s' "$_red_ci_map" > "$_union_dir/red_ci_map.json"

STALE_PRS_BY_SPEC="$(echo "$PRS_JSON" | jq \
  --argjson cutoff "$STALE_CUTOFF_EPOCH" \
  --argjson archived "$ARCHIVED_REPOS" \
  --slurpfile red_ci_arr "$_union_dir/red_ci_map.json" '
  ($red_ci_arr[0]) as $red_ci |
  def spec_of($title):
    (($title | capture("^\\[(?<p>[A-Za-z0-9-]+)\\]") | .p) // "") | ascii_downcase
    | if . == ""         then "any"
      elif . == "p0-sec"   then "api-gov"
      elif . == "security" then "api-gov"
      elif . == "feature"  then "any"      # plan-00 would only route; any specialist can triage
      elif . == "tech-debt" then "any"
      else .
      end;
  def red_ci_boost($pr):
    # +30 when PR has label nightly-automation AND has a non-SUCCESS CI conclusion.
    # The red_ci lookup map is keyed "nameWithOwner#number".
    ( ($pr.labels // []) | any(.name == "nightly-automation") ) as $has_na_label |
    ( $red_ci["\($pr.repository.nameWithOwner)#\($pr.number)"] // false ) as $has_red_ci |
    if ($has_na_label and $has_red_ci) then 30 else 0 end;
  [ .[]
    | select(.isDraft == false)
    | select((.author.login // "") != "dependabot[bot]")
    | select((.labels // []) | any(.name == "dependencies") | not)
    | select((.updatedAt | sub("\\..*Z$"; "Z") | fromdateiso8601) < $cutoff)
    | select(.repository.name as $n | ($archived | index($n)) | not)  # skip archived repos
    | . as $pr
    | {
        repo: .repository.name,
        number,
        title,
        url: ("https://github.com/\(.repository.nameWithOwner)/pull/\(.number)"),
        updated_at: .updatedAt,
        specialist: spec_of(.title),
        labels: [.labels[].name // empty],
        score: red_ci_boost($pr)
      }
  ]
  | sort_by([-.score, .updated_at])
  | group_by(.repo)
  | map({
      key: .[0].repo,
      value: (group_by(.specialist) | map({key: .[0].specialist, value: .}) | from_entries)
    })
  | from_entries
')"

# Extract the set of issue numbers referenced by any open PR (#N in title).
# Used to avoid re-dispatching issues that already have work in flight.
PR_IN_FLIGHT_REFS="$(echo "$PRS_JSON" | jq '
  map({
    repo: .repository.name,
    refs: [.title | scan("#([0-9]+)") | .[0] | tonumber]
  })
  | group_by(.repo)
  | map({key: .[0].repo, value: (map(.refs) | add | unique)})
  | from_entries
')"

# Agent prefix regex for routing readiness signal
AGENT_PREFIX_RE='^\[(API-CORE|DATA-CORE|UI-BUILD|INFRA-CORE|FEATURE|SECURITY|P0-SEC|DEPLOY|tech-debt)\]'

# --- Score each repo ---
# W19-ID21: passing $ISSUES_JSON + $PRS_JSON via --argjson breaks at ARG_MAX
# (~2MB) once the org has ~200+ issues/PRs with boosted label blobs. Switch to
# --slurpfile with a temp-file fan-out so jq reads each payload from the
# filesystem instead of argv. Files are auto-cleaned via trap on script exit.
_scored_tmpdir="$(mktemp -d /tmp/nightly-select-scored.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -rf '$_scored_tmpdir'" EXIT
printf '%s' "$REPOS_FILTERED"    > "$_scored_tmpdir/repos.json"
printf '%s' "$ISSUES_JSON"       > "$_scored_tmpdir/issues.json"
printf '%s' "$PRS_JSON"          > "$_scored_tmpdir/prs.json"
printf '%s' "$PR_IN_FLIGHT_REFS" > "$_scored_tmpdir/pr_refs.json"
SCORED="$(jq -n \
  --slurpfile repos_arr   "$_scored_tmpdir/repos.json" \
  --slurpfile issues_arr  "$_scored_tmpdir/issues.json" \
  --slurpfile prs_arr     "$_scored_tmpdir/prs.json" \
  --slurpfile pr_refs_arr "$_scored_tmpdir/pr_refs.json" \
  --arg now "$NOW_ISO" \
  --arg agent_re "$AGENT_PREFIX_RE" '
  # slurpfile wraps the top-level value in an array; unwrap for single-doc JSON.
  ($repos_arr[0])   as $repos   |
  ($issues_arr[0])  as $issues  |
  ($prs_arr[0])     as $prs     |
  ($pr_refs_arr[0]) as $pr_refs |
  def count_label($lbls; $name):
    [$lbls[]? | select(.name == $name)] | length;
  def days_since($ts):
    (($now | sub("\\..*Z$"; "Z") | fromdateiso8601) -
     ($ts  | sub("\\..*Z$"; "Z") | fromdateiso8601)) / 86400 | floor;

  $repos | map(
    . as $r
    | ($issues | map(select(.repository.name == $r.name))) as $r_issues
    | ($prs    | map(select(.repository.name == $r.name))) as $r_prs
    | (($pr_refs[$r.name] // []) ) as $in_flight
    # Prefixed issues NOT already in flight (no open PR mentioning #N in title):
    | ($r_issues
       | map(select(.title | test($agent_re)))
       | map(select(.number as $n | ($in_flight | index($n)) | not))
      ) as $prefixed_available
    | ($prefixed_available | length) as $prefixed
    # Already-in-flight prefixed work (counted separately for digest visibility):
    | ($r_issues
       | map(select(.title | test($agent_re)))
       | map(select(.number as $n | ($in_flight | index($n))))
       | length
      ) as $prefixed_in_flight
    | ($r_issues | map(select([.labels[]? | select(.name == "priority:high")] | length > 0)) | length) as $hi
    | ($r_issues | map(select([.labels[]? | select(.name == "nightly-candidate")] | length > 0)) | length) as $carryover
    | ($r_issues | map(select([.labels[]? | select(.name == "technical-debt" or .name == "tech-debt")] | length > 0)) | length) as $tech_debt
    # Sprint-blessed: issues with BOTH product-backlog AND nightly-candidate labels
    # (put there by evening-sprint-collate.sh). These are the sprint picks from
    # PLAN-00 and should dominate scoring when present.
    | ($r_issues | map(select(
        ([.labels[]? | select(.name == "product-backlog")] | length > 0) and
        ([.labels[]? | select(.name == "nightly-candidate")] | length > 0)
      )) | length) as $sprint_blessed
    | ($r_issues | length) as $total_issues
    | ($r_prs | length)    as $total_prs
    | ($r_prs | map(select(.isDraft == false and ((.labels // []) | any(.name == "dependencies") | not))) | length) as $ready_prs
    | ($r_prs | map(select((.labels // []) | any(.name == "dependencies"))) | length) as $dep_prs
    | days_since($r.pushedAt) as $dsc
    | ($total_prs > 5) as $pr_pileup
    | ( (if $dsc <= 7 then 20 else 0 end)
      + ($hi * 10)
      + ($prefixed * 5)                   # only not-in-flight prefixed work
      + ($carryover * 8)                  # boost: resume left-over nightly-candidate work
      + ($tech_debt * 2)                  # boost: tech-debt grind
      + ($sprint_blessed * 50)            # hard signal: PLAN-00 chose this for the sprint
      + ($ready_prs * 15)
      + (if $dsc <= 30 then 10 else 0 end)
      - ([$total_issues, 30] | min) * 0.5
      - (if $pr_pileup then 15 else 0 end)
      ) as $score
    | {
        name: $r.name,
        score: ($score * 10 | floor / 10),
        language: ($r.primaryLanguage.name // "unknown"),
        default_branch: ($r.defaultBranchRef.name // "master"),
        pushed_at: $r.pushedAt,
        days_since_commit: $dsc,
        open_issues: $total_issues,
        priority_high: $hi,
        prefixed_issues: $prefixed,
        open_prs: $total_prs,
        ready_prs: $ready_prs,
        dependabot_prs: $dep_prs,
        carryover_nightly_candidate: $carryover,
        tech_debt_issues: $tech_debt,
        sprint_blessed_issues: $sprint_blessed,
        prefixed_in_flight: $prefixed_in_flight,
        url: $r.url,
        prefixed_issue_refs: ($prefixed_available | map({number, title, labels: [.labels[].name // empty]}))
      }
  )
  | sort_by(-.score)
')"

emit_event "PROGRESS" "scoring complete; candidates=$(echo "$SCORED" | jq 'length')"

# --- Gather repo names currently queued (top N above threshold) ---
TOP_NAMES="$(echo "$SCORED" | jq -r --arg th "$READINESS_THRESHOLD" --argjson n "$MAX_REPOS" '
  [.[] | select(.score >= ($th | tonumber))] | .[:$n] | map(.name) | .[]
')"

if [[ -z "$TOP_NAMES" ]]; then
  echo '{"generated_at":"'"$NOW_ISO"'","repos":[],"reason":"no_repo_above_threshold","dependabot_prs":[]}' > "$QUEUE"
  cp "$QUEUE" "$CACHE"
  emit_event "COMPLETE" "no repos above readiness threshold ($READINESS_THRESHOLD)"
  exit 0
fi

# --- Expand coupled groups: if any group member is queued, bring in siblings ---
export TOP_NAMES PROFILES
EXPANDED="$(python3 - <<'PY'
import os, yaml, json
profiles = yaml.safe_load(open(os.environ["PROFILES"]))
top = [l for l in os.environ.get("TOP_NAMES","").strip().splitlines() if l]
active = list(top)
for _, g in (profiles.get("groups") or {}).items():
    members = g.get("members", [])
    if any(m in top for m in members):
        for m in members:
            if m not in active:
                active.append(m)
print(json.dumps({"active": active, "primary": top}))
PY
)"

PRIMARY_NAMES="$(echo "$EXPANDED" | jq -r '.primary[]')"
ACTIVE_NAMES="$(echo "$EXPANDED" | jq -r '.active[]')"

# --- Liveness check for coupled groups (issue #18) ---
# For any group with `liveness_check: true`, query `gh repo view` for each
# member. If any member is missing (gh returns non-zero) or archived
# (isArchived == true), mark the group "degraded" and emit a WARNING so
# dispatch can downgrade atomic → per-repo for this run.
DEGRADED_GROUPS="[]"
LIVENESS_CHECK_GROUPS="$(PROFILES="$PROFILES" python3 -c '
import json, os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"])) or {}
owner = (p.get("owner") or "${GITHUB_ORG:-your-org}")
out = []
for name, g in (p.get("groups") or {}).items():
    if g.get("liveness_check"):
        out.append({"group": name, "members": g.get("members", []), "deploy_mode": g.get("deploy_mode", "per-repo")})
print(json.dumps(out))
')"

while IFS= read -r grp_json; do
  [[ -z "$grp_json" || "$grp_json" == "null" ]] && continue
  grp_name="$(echo "$grp_json" | jq -r '.group')"
  grp_deploy_mode="$(echo "$grp_json" | jq -r '.deploy_mode')"
  degraded=0
  degraded_members=()
  while IFS= read -r member; do
    [[ -z "$member" ]] && continue
    # Try to resolve owner: check yaml repos section for a local_path hint,
    # then fall back to the configured default owner. Use plain gh repo view
    # (not gh_api_safe) so we get a simple 0/non-zero exit code.
    member_owner="$(PROFILES="$PROFILES" MEMBER="$member" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"])) or {}
# local_path hint gives us the org directory (${GITHUB_ORG:-your-org} or ${GITHUB_ORG:-your-org})
lp = ((p.get("repos") or {}).get(os.environ["MEMBER"]) or {}).get("local_path","")
import re
m = re.search(r"/github/([^/]+)/", lp)
if m:
    print(m.group(1))
else:
    print(p.get("owner","${GITHUB_ORG:-your-org}"))
' 2>/dev/null || echo "${NIGHTLY_OWNER%%,*}")"
    repo_info=""
    if repo_info="$(gh repo view "${member_owner}/${member}" \
        --json isArchived,name 2>/dev/null)"; then
      is_archived="$(echo "$repo_info" | jq -r '.isArchived')"
      if [[ "$is_archived" == "true" ]]; then
        degraded=1
        degraded_members+=("${member}(archived)")
        emit_event "WARNING" "liveness_check: ${grp_name} member ${member_owner}/${member} is archived — group degraded"
      fi
    else
      degraded=1
      degraded_members+=("${member}(missing)")
      emit_event "WARNING" "liveness_check: ${grp_name} member ${member_owner}/${member} not found — group degraded"
    fi
  done < <(echo "$grp_json" | jq -r '.members[]')

  if [[ "$degraded" -eq 1 ]]; then
    degraded_info="$(jq -n \
      --arg g "$grp_name" \
      --arg orig_deploy "$grp_deploy_mode" \
      --argjson members "$(printf '%s\n' "${degraded_members[@]}" | jq -R . | jq -s .)" \
      '{group: $g, original_deploy_mode: $orig_deploy, degraded_members: $members}')"
    DEGRADED_GROUPS="$(echo "$DEGRADED_GROUPS" | jq --argjson d "$degraded_info" '. + [$d]')"
    emit_event "PROGRESS" "liveness_check: group ${grp_name} degraded (deploy_mode downgraded atomic→per-repo if applicable)"
  fi
done < <(echo "$LIVENESS_CHECK_GROUPS" | jq -c '.[]')

# --- Resolve local path for each active repo ---
# Thin wrapper over hive_resolve_local_path (scripts/lib/common.sh) so
# existing callers stay unchanged. The canonical resolver handles
# ${HOME}/$HOME expansion, yaml github_root lookup, candidate fallback,
# and most-recent-commit tie-break (issue #152).
resolve_local_path() {
  hive_resolve_local_path "$PROFILES" "$1"
}

# Window (seconds) in which a recent commit means "background work in progress
# — don't dispatch, another session is already on it." 2h is long enough to
# catch a /loop pacing at ~15-30min cadence, short enough that stale inactivity
# lets nightly-puffin take over.
BACKGROUND_WINDOW_SEC="${NIGHTLY_BACKGROUND_WINDOW_SEC:-7200}"

# Return "true" if the repo at $1 has any commits in the last BACKGROUND_WINDOW_SEC.
# Checks all branches — a background session may be on a feature branch not yet
# merged. Also reports the authors so the digest can show who was active.
detect_background_activity() {
  local path="$1"
  [[ -z "$path" || ! -d "$path/.git" ]] && { printf '{"active":false}'; return; }
  local cutoff
  cutoff="$(date -u -d "-${BACKGROUND_WINDOW_SEC} seconds" +%s 2>/dev/null || echo 0)"
  local count authors last_ts
  count="$(git -C "$path" log --since=@"$cutoff" --all --format=%H 2>/dev/null | wc -l | tr -d ' ')"
  if [[ "$count" -eq 0 ]]; then
    printf '{"active":false,"recent_commits":0}'
    return
  fi
  authors="$(git -C "$path" log --since=@"$cutoff" --all --format=%an 2>/dev/null \
    | sort -u | jq -R . | jq -s .)"
  last_ts="$(git -C "$path" log --since=@"$cutoff" --all -1 --format=%cI 2>/dev/null || echo '')"
  jq -n --argjson n "$count" --argjson a "$authors" --arg ts "$last_ts" \
    '{active: true, recent_commits: $n, authors: $a, last_commit: $ts}'
}

# Build final queue entries for primary repos (with issue lists) and context-only siblings
build_queue_entry() {
  local name="$1" role="$2"
  local meta path
  meta="$(echo "$SCORED" | jq --arg n "$name" '.[] | select(.name==$n)')"
  if [[ -z "$meta" || "$meta" == "null" ]]; then
    meta="$(jq -n --arg n "$name" '{name: $n, score: null, prefixed_issues: null}')"
  fi
  path="$(resolve_local_path "$name")"
  # Detect multi-tree collisions
  local collisions=()
  for c in "$HOME/github/${GITHUB_ORG:-your-org}/$name" "$HOME/github/${GITHUB_ORG:-your-org}/$name" "$HOME/$name"; do
    [[ -d "$c/.git" ]] && collisions+=("$c")
  done
  local collisions_json="[]"
  if [[ "${#collisions[@]}" -gt 1 ]]; then
    collisions_json="$(printf '%s\n' "${collisions[@]}" | jq -R . | jq -s .)"
  fi
  # Detect background work (git commits in last BACKGROUND_WINDOW_SEC)
  local bg_json
  bg_json="$(detect_background_activity "$path")"
  local bg_active
  bg_active="$(echo "$bg_json" | jq -r '.active')"
  # If a primary repo has background activity, demote it to context-only so
  # nightly-puffin doesn't fight another session for the same issues.
  local effective_role="$role"
  if [[ "$role" == "primary" && "$bg_active" == "true" ]]; then
    effective_role="background-active"
    emit_event "PROGRESS" "$name demoted primary→background-active (recent commits detected)"
  fi
  echo "$meta" | jq \
    --arg path "$path" \
    --arg role "$effective_role" \
    --argjson col "$collisions_json" \
    --argjson bg "$bg_json" '
    . + {local_path: $path, role: $role, collisions: $col, background: $bg}
  '
}

QUEUE_REPOS="[]"
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  role="primary"
  entry="$(build_queue_entry "$name" "$role")"
  QUEUE_REPOS="$(echo "$QUEUE_REPOS" | jq --argjson e "$entry" '. + [$e]')"
done <<< "$PRIMARY_NAMES"

# Append context-only siblings (in active but not primary)
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
  if ! grep -qxF "$name" <<< "$PRIMARY_NAMES"; then
    entry="$(build_queue_entry "$name" "context-only")"
    QUEUE_REPOS="$(echo "$QUEUE_REPOS" | jq --argjson e "$entry" '. + [$e]')"
  fi
done <<< "$ACTIVE_NAMES"

# Cap total issues across primary repos at MAX_ISSUES
TOTAL_ISSUES="$(echo "$QUEUE_REPOS" | jq '[.[] | select(.role=="primary") | .prefixed_issues // 0] | add // 0')"

# --- Dependabot sub-queue ---
DEPENDABOT="$(echo "$PRS_JSON" | jq '[.[] | select(
  (.labels // []) | any(.name == "dependencies")
)] | map({repo: .repository.name, number, title, updatedAt})')"

# --- Optional CEO Dashboard filter (intersect only) ---
DASHBOARD_URL="${NIGHTLY_CEO_DASHBOARD_URL:-}"
if [[ -n "$DASHBOARD_URL" ]]; then
  if DASHBOARD_RESP="$(curl -sfL --max-time 10 "$DASHBOARD_URL/api/nightly-queue" 2>/dev/null)"; then
    DASH_REPOS="$(echo "$DASHBOARD_RESP" | jq -r '.repos[]?.name // empty' 2>/dev/null || true)"
    if [[ -n "$DASH_REPOS" ]]; then
      FILTERED="[]"
      while IFS= read -r dname; do
        FILTERED="$(echo "$QUEUE_REPOS" | jq --arg n "$dname" --argjson f "$FILTERED" '
          ($f + [.[] | select(.name==$n)]) | unique_by(.name)
        ')"
      done <<< "$DASH_REPOS"
      QUEUE_REPOS="$FILTERED"
      emit_event "PROGRESS" "ceo_dashboard_filter_applied; repos_after=$(echo "$QUEUE_REPOS" | jq 'length')"
    fi
  else
    emit_event "PROGRESS" "ceo_dashboard_unreachable; proceeding with gh-derived queue"
  fi
fi

# --- Write final queue ---
# Latest sprint-plan doc from evening-sprint-collate.sh (strict date-named files only,
# never random notes/findings files that may live in sprints/). Accept today or
# yesterday because selector runs at 23:30 local and a 21:00 collation that's
# slow may have landed yesterday in UTC terms.
SPRINT_DOC=""
if [[ -d "$HIVE/sprints" ]]; then
  _today_local="$(date +%Y-%m-%d)"
  _yest_local="$(date -d 'yesterday' +%Y-%m-%d 2>/dev/null || echo "")"
  for d in "$_today_local" "$_yest_local"; do
    [[ -z "$d" ]] && continue
    if [[ -f "$HIVE/sprints/$d.md" ]]; then
      SPRINT_DOC="$HIVE/sprints/$d.md"
      break
    fi
  done
fi

# Flat list of all stale PRs across the org (for digest "awaiting sweeper" when
# the owning specialist doesn't run tonight). Sorted score DESC so dispatch
# prompt and digest surface boosted (red-CI nightly-automation) PRs first.
STALE_PRS_ALL="$(echo "$STALE_PRS_BY_SPEC" | jq '
  [ to_entries[] | .key as $repo
    | .value | to_entries[] | .key as $spec
    | .value[] | . + {repo: $repo, specialist: $spec}
  ]
  | sort_by([-.score, .updated_at])
')"

QUEUE_JSON="$(jq -n \
  --arg ts "$NOW_ISO" \
  --arg owner "$OWNER" \
  --argjson repos "$QUEUE_REPOS" \
  --argjson deps "$DEPENDABOT" \
  --argjson threshold "$READINESS_THRESHOLD" \
  --argjson max_issues "$MAX_ISSUES" \
  --arg sprint_doc "$SPRINT_DOC" \
  --argjson stale_by_spec "$STALE_PRS_BY_SPEC" \
  --argjson stale_all "$STALE_PRS_ALL" \
  --argjson stale_window_sec "${STALE_WINDOW_SEC:-86400}" \
  --argjson degraded_groups "$DEGRADED_GROUPS" \
  '{
    schema: "nightly-queue.v1",
    generated_at: $ts,
    owner: $owner,
    readiness_threshold: $threshold,
    max_issues_per_night: $max_issues,
    sprint_plan_doc: $sprint_doc,
    stale_pr_window_sec: $stale_window_sec,
    stale_prs_by_specialist: $stale_by_spec,
    stale_prs_all: $stale_all,
    degraded_groups: $degraded_groups,
    repos: $repos,
    dependabot_prs: $deps
  }'
)"

echo "$QUEUE_JSON" > "$QUEUE"
cp "$QUEUE" "$CACHE"

PRIMARY_COUNT="$(echo "$QUEUE_JSON" | jq '[.repos[] | select(.role=="primary")] | length')"
SIBLING_COUNT="$(echo "$QUEUE_JSON" | jq '[.repos[] | select(.role=="context-only")] | length')"
DEP_COUNT="$(echo "$QUEUE_JSON" | jq '.dependabot_prs | length')"
STALE_COUNT="$(echo "$QUEUE_JSON" | jq '.stale_prs_all | length')"
DEGRADED_COUNT="$(echo "$QUEUE_JSON" | jq '.degraded_groups | length')"

emit_event "COMPLETE" "queue written: primary=$PRIMARY_COUNT siblings=$SIBLING_COUNT dependabot=$DEP_COUNT stale_prs=$STALE_COUNT degraded_groups=$DEGRADED_COUNT"

echo "selector: primary=$PRIMARY_COUNT siblings=$SIBLING_COUNT dependabot=$DEP_COUNT stale_prs=$STALE_COUNT degraded_groups=$DEGRADED_COUNT → $QUEUE"
