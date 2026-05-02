#!/usr/bin/env bash
# doc-hygiene-scan.sh
#
# Daily doc-hygiene dispatcher. Buckets active ${GITHUB_ORG:-your-org} repos into 7 chunks by
# pushedAt recency; today's bucket gets swept by DOC-00 in hygiene mode.
#
# Bucket assignment (strict-chunk mode — matches "most recent first to least
# active last"):
#   sorted_repos[0:chunk_size]   → Monday (hottest)
#   sorted_repos[chunk_size:2*chunk_size] → Tuesday
#   ...
#   sorted_repos[6*chunk_size:]  → Sunday (coldest)
#
# Usage:
#   doc-hygiene-scan.sh                   # cron mode — today's bucket
#   doc-hygiene-scan.sh --repo=<name>     # ad-hoc single repo
#   doc-hygiene-scan.sh --all             # every active repo (catch-up run)
#   doc-hygiene-scan.sh --dry-run         # no issues/PRs; print findings only
#   doc-hygiene-scan.sh --day=<Mon|Tue|…> # simulate bucket for a different day

set -euo pipefail

# V6_EVENT_PATCHED — auto-inserted by example-repo-${USER}-local/scripts/wire-claude-cli-v6-events.sh
# Source the v6 event helper. Defines v6_emit_event,
# v6_pipeline_stage_started, v6_pipeline_stage_completed.
# Helper is no-op when V6_API_TOKEN env is unset (see helper for details).
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/v6-event.sh" ]]; then
  # shellcheck source=lib/v6-event.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/v6-event.sh"
  v6_pipeline_stage_started "stage=doc-hygiene-scan cron_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  trap 'v6_pipeline_stage_completed "stage=doc-hygiene-scan exit=$?"' EXIT
fi

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/doc-hygiene-profiles.yaml"
SESSIONS_DIR="$HIVE/sessions"
HANDBOOK="$CLAUDE_HOME/handbook"

TODAY="$(date +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOW_SHORT_DEFAULT="$(date +%a)"       # Mon, Tue, ...
OWNER="${NIGHTLY_OWNER:-${GITHUB_ORG:-your-org}}"

mkdir -p "$LOGS_DIR" "$ESC_DIR" "$SESSIONS_DIR"

# --- Args ---
REPO=""
DRY_RUN=0
ALL=0
DOW_OVERRIDE=""
for arg in "$@"; do
  case "$arg" in
    --repo=*)  REPO="${arg#--repo=}" ;;
    --dry-run) DRY_RUN=1 ;;
    --all)     ALL=1 ;;
    --day=*)   DOW_OVERRIDE="${arg#--day=}" ;;
    *)         echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

DOW_SHORT="${DOW_OVERRIDE:-$DOW_SHORT_DEFAULT}"

emit_event() { SID="$1" hive_emit_event "$2" "$3" "$4"; }

escalate() {
  local sid="$1" code="$2" msg="$3"
  local f="$ESC_DIR/${TODAY}-dochygiene-${sid}.md"
  {
    echo "# Doc hygiene escalation — $TODAY"
    echo "**SID:** $sid"
    echo "**Code:** $code"
    echo "**Message:** $msg"
    echo "**When:** $NOW_ISO"
  } > "$f"
  emit_event "$sid" "dispatch" "BLOCKED" "$code: $msg"
}

# Preflight
[[ -f "$PROFILES" ]] || { echo "profile missing: $PROFILES" >&2; exit 20; }
[[ -d "$HANDBOOK" ]] || { echo "handbook missing: $HANDBOOK" >&2; exit 20; }
command -v gh     >/dev/null || { echo "gh not in PATH" >&2; exit 10; }
command -v jq     >/dev/null || { echo "jq not in PATH" >&2; exit 10; }
command -v claude >/dev/null || { echo "claude not in PATH" >&2; exit 10; }
command -v python3 >/dev/null || { echo "python3 not in PATH" >&2; exit 10; }
gh auth status >/dev/null 2>&1 || { echo "gh auth failed" >&2; exit 11; }

# Parse the profile once at startup into a JSON blob we can cheaply query
# with jq (instead of re-invoking python3 per repo). Produces:
#   {"default_bg_window": 7200, "repos": {"repo-name": {"bg_window": 3600}, ...}}
PROFILE_CACHE="$(PROFILES="$PROFILES" python3 -c '
import os, yaml, json
p = yaml.safe_load(open(os.environ["PROFILES"]))
d = (p.get("defaults") or {})
out = {
  "default_bg_window": int(d.get("background_window_seconds", 7200)),
  "repos": {},
}
for name, cfg in (p.get("repos") or {}).items():
  entry = {}
  if "background_window_seconds" in (cfg or {}):
    entry["bg_window"] = int(cfg["background_window_seconds"])
  out["repos"][name] = entry
print(json.dumps(out))
')"

# --- Bucket logic: sort active repos by pushedAt desc, split into 7 chunks ---
# Returns space-separated repo names for today's bucket.
resolve_todays_bucket() {
  OWNER="$OWNER" DOW="$DOW_SHORT" python3 - <<'PY'
import os, subprocess, json, math
owner = os.environ["OWNER"]
dow = os.environ["DOW"]
dow_to_idx = {"Mon":0,"Tue":1,"Wed":2,"Thu":3,"Fri":4,"Sat":5,"Sun":6}
dow_idx = dow_to_idx.get(dow, 0)

raw = subprocess.check_output([
    "gh", "repo", "list", owner, "--limit", "200",
    "--json", "name,pushedAt,isArchived,isFork,updatedAt"
]).decode()
repos = json.loads(raw)
# Filter active: not archived, not a fork, pushed within 60 days
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=60)
active = []
for r in repos:
    if r.get("isArchived"):
        continue
    # NOTE: forks (e.g. example-repo forked from psurentax) are INCLUDED because
    # the user owns and maintains them in ${GITHUB_ORG:-your-org} as canonical. Archive-only is the
    # filter. To exclude a specific fork, add it to skip_paths handling or profile overrides.
    pushed = r.get("pushedAt")
    if not pushed:
        continue
    # Parse ISO-8601 ending in Z
    try:
        dt = datetime.datetime.fromisoformat(pushed.replace("Z","+00:00"))
    except Exception:
        continue
    if dt >= cutoff:
        active.append((dt, r["name"]))
active.sort(key=lambda x: x[0], reverse=True)
names = [n for _, n in active]
n = len(names)
if n == 0:
    print("")
    raise SystemExit
# Bucket assignment (strict-chunk, recency-ordered): Mon=0 (hottest) .. Sun=6.
# Off-by-one fix (2026-04-19): previous logic `chunk = ceil(n/7)` with n==36
# produced chunk=6 so Sun (dow_idx=6) got slice names[36:42] = empty because
# the math wraps past the array end when n is exactly 7k. New approach:
# distribute the remainder across the early buckets so every bucket holds
# either ceil(n/7) or floor(n/7) repos, and Sunday always gets a non-empty
# slice (unless n < 7).
base = n // 7
extra = n % 7   # first `extra` buckets get one additional repo
if dow_idx < extra:
    start = dow_idx * (base + 1)
    end   = start + (base + 1)
else:
    start = extra * (base + 1) + (dow_idx - extra) * base
    end   = start + base
bucket = names[start:end] if start < n else []
print(" ".join(bucket))
PY
}

# Is the repo path background-active (commits in last 2h)?
is_background_active() {
  local path="$1" window="$2"
  [[ -z "$path" || ! -d "$path/.git" ]] && { echo 0; return; }
  local cutoff
  cutoff="$(date -u -d "-${window} seconds" +%s 2>/dev/null || echo 0)"
  local count
  count="$(git -C "$path" log --since=@"$cutoff" --all --format=%H 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]] && echo 1 || echo 0
}

# Resolve a local clone path for $name — thin wrapper over
# hive_resolve_local_path (scripts/lib/common.sh). Canonical resolver
# handles yaml override + ${HOME}/$HOME expansion + candidate fallback
# (issue #152).
resolve_local_path() {
  hive_resolve_local_path "$PROFILES" "$1"
}

# Dispatch DOC-00 in hygiene mode on one repo.
dispatch_one() {
  local repo="$1"
  local sid="dochygiene-${TODAY}-${repo}"
  local log="$LOGS_DIR/doc-hygiene-${repo}.log"
  local session_dir="$SESSIONS_DIR/$sid"
  mkdir -p "$session_dir/agents"
  printf "session_id: %s\nproject_key: %s\ncreated: %s\npurpose: doc-hygiene\n" \
    "$sid" "$repo" "$NOW_ISO" > "$session_dir/manifest.yaml"

  emit_event "$sid" "dispatch" "SPAWN" "repo=$repo dow=$DOW_SHORT dry_run=$DRY_RUN"

  # Refuse deprecated path defensively.
  if [[ "$repo" == "orchestrator" ]]; then
    escalate "$sid" "DEPRECATED_PATH" "refusing to run on /home/*/orchestrator"
    return 0
  fi

  local path
  path="$(resolve_local_path "$repo")"
  if [[ -z "$path" ]]; then
    escalate "$sid" "NO_LOCAL_CLONE" "$repo has no local clone; skipping"
    return 0
  fi

  # Background-activity gate (same 2h window as other phases)
  local bg_window
  bg_window="$(echo "$PROFILE_CACHE" | jq -r --arg r "$repo" '
    (.repos[$r].bg_window // .default_bg_window)
  ')"
  if [[ "$(is_background_active "$path" "$bg_window")" == "1" ]]; then
    emit_event "$sid" "dispatch" "BLOCKED" "$repo background-active (commits in last ${bg_window}s — skipping doc hygiene)"
    return 0
  fi

  # Prompt to DOC-00 in hygiene mode
  local prompt
  prompt="$(cat <<PROMPT
SESSION_ID: $sid
PROJECT_KEY: $repo
DEPTH: depth 0/0
MODE: hygiene
Local path: $path
Profile: $PROFILES (section: repos.$repo or defaults)
Dry run: $DRY_RUN
Handbook: $HANDBOOK

Hive protocol: checkpoints + events.ndjson emission per handbook/00-hive-protocol.md.
Tool/skill selection: consult handbook/07-decision-guide.md. Do not ask the user.

You are DOC-00 in Doc Hygiene Mode (see agent file
~/.claude/agents/doc-00-documentation.md → "Doc Hygiene Mode" section for full
protocol).

MISSION
- Scan all .md files in $path (excluding skip_paths from profile).
- Classify each as: purge-candidate (AI-pollution pattern OR small orphan),
  audit-candidate (stale / tech-drift / duplicate / rot-indicator), or leave.
- Protected basenames are NEVER purged even if they match a pattern.
- For purge-candidates: grep for valuable_content_markers; if found, extract
  the structured content to ~/.claude/context/shared/{lessons,decisions,patterns}/
  BEFORE including the file in the cleanup PR.
- Respect file-level background-active gate: skip any file with a git commit
  in the last file_level_background_window_seconds (default 7200s).

OUTPUT (respecting DRY_RUN=$DRY_RUN)
1. Create at most ONE cleanup PR per repo (branch chore/doc-hygiene-$TODAY)
   - Target: master
   - Label: doc-cleanup
   - Body: list each deletion + extraction with rationale
   - max_deletions_per_pr from profile
   - NEVER auto-merge
2. Create at most ONE audit issue per repo
   - Title: "[DOC] Doc hygiene audit — $TODAY"
   - Label: doc-hygiene
   - Body: Summary + sections for "Stale but possibly valuable", "Tech-drift",
     "Duplicates (ambiguous)", each with actionable proposals
   - max_audit_findings cap

3. Emit events:
   - PROGRESS "scanned=N purged=M audit=K extracted=L"
   - COMPLETE with the same aggregate

SAFETY
- Never commit directly to master; always via PR.
- Never force-push.
- Never touch files whose basename is in protected_basenames.
- Never delete files with a commit in the last 2h.
- If max_deletions_per_pr is 0 (e.g. example-repo), produce only the audit
  issue, no cleanup PR.
- If you find ROADMAP-proposals.md, LEAVE IT — that belongs to PROD-00.
- Prefix deletion commit message with "chore(doc-hygiene):" for attribution.
PROMPT
)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    {
      echo "---[DRY RUN doc-hygiene $repo dow=$DOW_SHORT]---"
      echo "$prompt" | head -30
      echo "---"
    } > "$log"
    emit_event "$sid" "dispatch" "PROGRESS" "$repo dry-run (see $log)"
    emit_event "$sid" "dispatch" "COMPLETE" "dry-run"
    return 0
  fi

  emit_event "$sid" "dispatch" "HANDOFF" "$repo → claude -p (DOC-00 hygiene)"
  local append_sys="You are doc-00-documentation in Doc Hygiene Mode running headless — execute the full hygiene protocol directly, including file deletions via PR branch, extraction to ~/.claude/context/shared/{lessons,decisions,patterns}/, and gh issue/PR creation. Read ~/.claude/agents/doc-00-documentation.md before acting. Read ~/.claude/handbook/00-hive-protocol.md and ~/.claude/handbook/07-decision-guide.md."

  # POOL_MODE=1: enqueue instead of direct claude -p (issue #49).
  if [[ "${POOL_MODE:-0}" == "1" ]]; then
    hive_pool_enqueue "doc-00" "$repo" "$sid" "$prompt" "$path" "$append_sys"
    emit_event "$sid" "dispatch" "PROGRESS" "$repo enqueued to pool (POOL_MODE=1)"
    return 0
  fi

  claude -p "$prompt" \
    --permission-mode acceptEdits \
    --add-dir "$path" \
    --add-dir "$HIVE" \
    --append-system-prompt "$append_sys" \
    > "$log" 2>&1 \
    && emit_event "$sid" "dispatch" "COMPLETE" "$repo done (see $log)" \
    || emit_event "$sid" "dispatch" "BLOCKED" "$repo claude -p exit $? (see $log)"
}

# --- Main ---
if [[ "$ALL" -eq 1 ]]; then
  CANDIDATES="$(OWNER="$OWNER" python3 - <<'PY'
import os, subprocess, json
raw = subprocess.check_output([
    "gh","repo","list", os.environ["OWNER"], "--limit","200",
    "--json","name,isArchived"
]).decode()
for r in json.loads(raw):
    if not r.get("isArchived"):
        print(r["name"])
PY
)"
  while IFS= read -r r; do [[ -n "$r" ]] && dispatch_one "$r"; done <<< "$CANDIDATES"
  exit 0
fi

if [[ -n "$REPO" ]]; then
  dispatch_one "$REPO"
  echo "doc-hygiene: $REPO done"
  exit 0
fi

# Cron mode: today's bucket
BUCKET="$(resolve_todays_bucket)"
if [[ -z "$BUCKET" ]]; then
  emit_event "dochygiene-$TODAY" "dispatch" "COMPLETE" "empty bucket for $DOW_SHORT"
  echo "doc-hygiene: empty bucket for $DOW_SHORT"
  exit 0
fi

echo "doc-hygiene: bucket($DOW_SHORT) = $BUCKET"
emit_event "dochygiene-$TODAY" "dispatch" "SPAWN" "bucket=$DOW_SHORT repos='$BUCKET'"
for r in $BUCKET; do
  dispatch_one "$r"
done
emit_event "dochygiene-$TODAY" "dispatch" "COMPLETE" "bucket $DOW_SHORT finished"
echo "doc-hygiene: bucket $DOW_SHORT complete"
