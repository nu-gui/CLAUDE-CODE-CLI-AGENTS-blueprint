#!/usr/bin/env bash
# product-discovery.sh
#
# Thin dispatcher for PROD-00 (daytime product-discovery runs).
# Round-robins through ${GITHUB_ORG:-your-org} repos per ~/.claude/config/product-profiles.yaml,
# spawns `claude -p` with the PROD-00 agent, and logs results.
#
# Usage:
#   product-discovery.sh                       # cron mode: auto-pick from rotation
#   product-discovery.sh --repo=<name>         # ad-hoc single repo
#   product-discovery.sh --dry-run --repo=X    # preview without creating issues
#   product-discovery.sh --all                 # iterate every rotation candidate
#
# Cron entry should capture stderr so silent failures surface in logs:
#   product-discovery.sh >> $LOGS_DIR/product-discovery-cron.log 2>&1
# (per-repo agent output still lands in $LOGS_DIR/product-${HOUR}-${repo}.log)
#
# Event contract: see docs/event-contract.md (canonical source of truth for
# SPAWN/HANDOFF/SPECIALIST_COMPLETE/SPECIALIST_FAILED/BLOCKED/PROGRESS/COMPLETE
# semantics and invariants).

set -euo pipefail

# V6_EVENT_PATCHED — auto-inserted by example-repo-${USER}-local/scripts/wire-claude-cli-v6-events.sh
# Source the v6 event helper. Defines v6_emit_event,
# v6_pipeline_stage_started, v6_pipeline_stage_completed.
# Helper is no-op when V6_API_TOKEN env is unset (see helper for details).
if [[ -f "$(dirname "${BASH_SOURCE[0]}")/lib/v6-event.sh" ]]; then
  # shellcheck source=lib/v6-event.sh
  source "$(dirname "${BASH_SOURCE[0]}")/lib/v6-event.sh"
  v6_pipeline_stage_started "stage=product-discovery cron_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  trap 'v6_pipeline_stage_completed "stage=product-discovery exit=$?"' EXIT
fi

# Shared helpers (issue #35 / #47).
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

PROFILES="$CLAUDE_HOME/config/product-profiles.yaml"
SESSIONS_DIR="$HIVE/sessions"
HANDBOOK="$CLAUDE_HOME/handbook"

TODAY="$(date +%Y-%m-%d)"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
DOW_SHORT="$(date +%a)"     # Mon, Tue, ...
HOUR="$(date +%H)"           # 09, 13, 17

mkdir -p "$LOGS_DIR" "$ESC_DIR" "$SESSIONS_DIR"

# --- Args ---
REPO=""
DRY_RUN=0
ALL=0
for arg in "$@"; do
  case "$arg" in
    --repo=*)  REPO="${arg#--repo=}" ;;
    --dry-run) DRY_RUN=1 ;;
    --all)     ALL=1 ;;
    *)         echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# 4-arg per-call sid wrapper: override SID in the hive_emit_event call.
emit_event() { SID="$1" hive_emit_event "$2" "$3" "$4"; }

escalate() {
  local sid="$1" code="$2" msg="$3"
  local f="$ESC_DIR/${TODAY}-product-${sid}.md"
  {
    echo "# Product discovery escalation — $TODAY"
    echo "**SID:** $sid"
    echo "**Code:** $code"
    echo "**Message:** $msg"
    echo "**When:** $NOW_ISO"
  } > "$f"
  emit_event "$sid" "dispatch" "BLOCKED" "$code: $msg"
}

# --- Preflight ---
[[ -f "$PROFILES" ]] || { echo "profile missing: $PROFILES" >&2; exit 20; }
[[ -d "$HANDBOOK" ]] || { echo "handbook missing: $HANDBOOK" >&2; exit 20; }
command -v gh   >/dev/null || { echo "gh CLI not found in PATH" >&2; exit 10; }
command -v jq   >/dev/null || { echo "jq not found in PATH" >&2; exit 10; }
command -v claude >/dev/null || { echo "claude CLI not found in PATH" >&2; exit 10; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated" >&2; exit 11; }

# --- Select repo from rotation if not given ---
# Supports two modes from profiles.rotation.mode:
#   - "cycle"         → weighted list cycled by (dow_idx * slot_count + hour_idx)
#   - "static-weekly" → legacy explicit schedule map (DoW-HH → repo)
resolve_rotation_repo() {
  REPO_FROM_PROFILE="$(DOW="$DOW_SHORT" HOUR="$HOUR" PROFILES="$PROFILES" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"]))
rot = p.get("rotation") or {}
mode = rot.get("mode", "static-weekly")
dow = os.environ["DOW"]
hour = int(os.environ["HOUR"])

dow_to_idx = {"Mon":0, "Tue":1, "Wed":2, "Thu":3, "Fri":4, "Sat":5, "Sun":6}
dow_idx = dow_to_idx.get(dow, 0)

pick = ""
if mode == "cycle":
    cands = rot.get("candidates") or []
    weights = rot.get("weights") or {}
    slot_hours = rot.get("slot_hours") or [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20]
    # Build weighted list preserving candidates order so the cycle is deterministic.
    weighted = []
    for c in cands:
        w = int(weights.get(c, 1))
        weighted.extend([c] * max(1, w))
    if weighted and hour in slot_hours:
        hour_idx = slot_hours.index(hour)
        slot_index = dow_idx * len(slot_hours) + hour_idx
        pick = weighted[slot_index % len(weighted)]
elif mode == "static-weekly":
    sched = rot.get("schedule") or {}
    pick = sched.get(f"{dow}-{hour:02d}", "") or ""

if not pick:
    pick = rot.get("default_repo", "") or ""
print(pick)
')"
  echo "$REPO_FROM_PROFILE"
}

# Fetch per-repo config values
repo_cfg() {
  local repo="$1" key="$2"
  REPO="$repo" KEY="$key" PROFILES="$PROFILES" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"]))
repos = p.get("repos") or {}
defs  = p.get("defaults") or {}
r = repos.get(os.environ["REPO"]) or {}
key = os.environ["KEY"]
val = r.get(key, defs.get(key))
if isinstance(val, list):
    print(",".join(str(x) for x in val))
else:
    print("" if val is None else str(val))
'
}

# Path resolution — thin wrapper over hive_resolve_local_path
# (scripts/lib/common.sh). The canonical resolver reads yaml overrides,
# expands ${HOME}/$HOME, and picks the clone with most-recent commit
# when multiple candidates exist (issue #152).
resolve_local_path() {
  hive_resolve_local_path "$PROFILES" "$1"
}

# Background-activity detection (mirrors nightly selector).
is_background_active() {
  local path="$1" window="$2"
  [[ -z "$path" || ! -d "$path/.git" ]] && { echo 0; return; }
  local cutoff
  cutoff="$(date -u -d "-${window} seconds" +%s 2>/dev/null || echo 0)"
  local count
  count="$(git -C "$path" log --since=@"$cutoff" --all --format=%H 2>/dev/null | wc -l | tr -d ' ')"
  [[ "$count" -gt 0 ]] && echo 1 || echo 0
}

dispatch_one() {
  local repo="$1"
  local sid="prod-${TODAY}-${HOUR}-${repo}"
  local log="$LOGS_DIR/product-${HOUR}-${repo}.log"
  local session_dir="$SESSIONS_DIR/$sid"
  mkdir -p "$session_dir/agents"
  # Minimal session manifest so the agent's HALT check passes.
  printf "session_id: %s\nproject_key: %s\ncreated: %s\npurpose: product-discovery\n" \
    "$sid" "$repo" "$NOW_ISO" > "$session_dir/manifest.yaml"

  emit_event "$sid" "dispatch" "SPAWN" "repo=$repo slot=${DOW_SHORT}-${HOUR} dry_run=$DRY_RUN"
  hive_heartbeat "product-discovery"

  # Refuse deprecated path defensively (wrappers elsewhere already block it).
  if [[ "$repo" == "orchestrator" ]] || [[ "$repo" == *"/orchestrator" ]]; then
    escalate "$sid" "DEPRECATED_PATH" "refusing to run on /home/*/orchestrator (use example-repo)"
    return 0
  fi

  local path
  path="$(resolve_local_path "$repo")"
  if [[ -z "$path" ]]; then
    escalate "$sid" "NO_LOCAL_CLONE" "$repo has no local clone; skipping"
    return 0
  fi

  local window
  window="$(repo_cfg "$repo" background_window_seconds)"
  [[ -z "$window" ]] && window=7200
  if [[ "$(is_background_active "$path" "$window")" == "1" ]]; then
    emit_event "$sid" "dispatch" "BLOCKED" "$repo background-active (commits in last ${window}s; another session is working it)"
    return 0
  fi

  # Cool-down: skip if PROD-00 successfully created >=1 issue on this repo
  # within the last cool_down_seconds. Only applies to *successful* past runs —
  # a COMPLETE with "created=0" still permits a retry.
  local cooldown last_ts last_epoch now_epoch delta
  cooldown="$(repo_cfg "$repo" cool_down_seconds)"
  [[ -z "$cooldown" ]] && cooldown=10800
  if [[ "$cooldown" -gt 0 ]] && [[ -f "$EVENTS" ]]; then
    last_ts="$(jq -r --arg r "$repo" '
      select(.agent == "prod-00")
      | select(.event == "COMPLETE")
      | select((.sid // "") | test("^prod-.*-" + $r + "$"))
      | select((.detail // "") | test("created=[1-9]"))
      | .ts
    ' "$EVENTS" 2>/dev/null | tail -1 || echo "")"
    if [[ -n "$last_ts" ]]; then
      now_epoch="$(date -u +%s)"
      last_epoch="$(date -u -d "$last_ts" +%s 2>/dev/null || echo 0)"
      delta=$(( now_epoch - last_epoch ))
      if (( delta < cooldown )); then
        emit_event "$sid" "dispatch" "PROGRESS" "$repo cool-down active (last success ${delta}s ago, cool_down=${cooldown}s) — skipping"
        return 0
      fi
    fi
  fi

  # --- ROADMAP case-conflict resolver (issue #21) ---
  # ext4 is case-sensitive. A repo may legitimately have both ROADMAP.md and
  # roadmap.md; PROD-00 must pick exactly one as the authoritative file.
  # Canonical name is ROADMAP.md (uppercase, matches GitHub README convention).
  local roadmap_file=""
  local has_upper=0 has_lower=0
  [[ -f "$path/ROADMAP.md" ]] && has_upper=1
  [[ -f "$path/roadmap.md" ]] && has_lower=1

  if [[ "$has_upper" -eq 1 && "$has_lower" -eq 1 ]]; then
    # Both exist: pick whichever has the most recent git log entry.
    local ts_upper ts_lower
    ts_upper="$(git -C "$path" log -1 --format=%ct -- ROADMAP.md 2>/dev/null || echo 0)"
    ts_lower="$(git -C "$path" log -1 --format=%ct -- roadmap.md 2>/dev/null || echo 0)"
    [[ -z "$ts_upper" ]] && ts_upper=0
    [[ -z "$ts_lower" ]] && ts_lower=0
    if (( ts_lower > ts_upper )); then
      roadmap_file="roadmap.md"
    else
      roadmap_file="ROADMAP.md"
    fi
    emit_event "$sid" "dispatch" "PROGRESS" \
      "roadmap-case-conflict repo=$repo chose=$roadmap_file (ROADMAP.md ts=$ts_upper roadmap.md ts=$ts_lower) — consolidate to ROADMAP.md"
  elif [[ "$has_upper" -eq 1 ]]; then
    roadmap_file="ROADMAP.md"
  elif [[ "$has_lower" -eq 1 ]]; then
    roadmap_file="roadmap.md"
  fi
  # roadmap_file is empty when neither variant exists — agent will scaffold proposals.

  local max_issues signals boosts
  max_issues="$(repo_cfg "$repo" max_issues_per_run)"
  signals="$(repo_cfg "$repo" gap_signals)"
  boosts="$(repo_cfg "$repo" priority_boost_labels)"

  # Resolve current sprint milestone for milestone auto-attachment (issue #94).
  # We pass the full OWNER/REPO so hive_current_sprint_milestone hits the right
  # milestones endpoint. Defaults to CLAUDE-CODE-CLI-AGENTS repo when $repo is
  # a bare repo name (no slash); product-discovery repos are usually ${GITHUB_ORG:-your-org}/*.
  local _ms_repo="$repo"
  [[ "$_ms_repo" != */* ]] && _ms_repo="${GITHUB_ORG:-your-org}/$repo"
  local sprint_milestone=""
  sprint_milestone="$(hive_current_sprint_milestone "$_ms_repo" 2>/dev/null || true)"

  local prompt
  prompt="$(cat <<PROMPT
SESSION_ID: $sid
PROJECT_KEY: $repo
DEPTH: depth 0/0
Local path: $path
Profile: $PROFILES
Max issues this run: ${max_issues:-5}
Gap signals enabled: ${signals:-roadmap_not_yet_built}
Priority-boost labels: ${boosts:-}
Sprint milestone: ${sprint_milestone:-}
Dry run: $DRY_RUN
Handbook: $HANDBOOK

Hive protocol: checkpoints + events.ndjson emission per handbook/00-hive-protocol.md.
Tool/skill selection: consult handbook/07-decision-guide.md before acting. Do not ask
the user which tool to use.

You are PROD-00 (product discovery). Read ~/.claude/agents/prod-00-product-discovery.md
for your full operating contract.

Key constraints:
  - Read code/docs, create GitHub issues only. No commits, no PRs, no code edits.
  - Use the issue-quality contract (title + 3-section body + dedup check).
  - Respect max_issues_per_run.
  - Canonical ROADMAP filename is ROADMAP.md (uppercase). The dispatcher has already
    resolved any case conflict and passes the chosen filename below.
  - Chosen ROADMAP file: ${roadmap_file:-<none>}
  - If chosen ROADMAP file is empty (neither ROADMAP.md nor roadmap.md exists in $path),
    scaffold ROADMAP-proposals.md and exit.
  - Do not treat the unchosen lowercase variant as authoritative even if it exists.
  - Emit PROGRESS per issue created; COMPLETE at end with created=N skipped=M proposals=K.
  - If background activity detected on this repo despite the wrapper's check (race),
    emit BLOCKED: background-active and exit.
  - Issue dedup (Layer-1 guardrail, issue #184): NEVER call \`gh issue create\` directly.
    Instead use the shared wrapper for every issue you would create:
      bash ~/.claude/scripts/hive-issue-create.sh <repo> "<title>" "<body>" "<labels>"
    The wrapper fuzzy-matches the title against open issues with the same labels.
    If stdout starts with "DUPLICATE_OF=#N", skip — emit PROGRESS "dedup-skipped: ..."
    and count it in the final skipped=M total. If stdout is a URL, the issue was
    created normally — proceed as below.
  - Milestone: if "Sprint milestone" above is non-empty, pass --milestone "<value>"
    to every gh issue create call. If the milestone flag fails (repo has no such
    milestone), retry the create without the flag rather than dropping the issue.
    Note: hive-issue-create.sh does not accept a milestone flag — pass it via a
    follow-up \`gh issue edit <url> --milestone "<value>"\` if needed.
  - Projects v2: after each successful issue creation (URL returned by the wrapper),
    source scripts/lib/common.sh and call hive_add_to_project "<issue-url>".
    The helper is idempotent and gracefully skips if the token lacks "project" scope
    — do not treat that as failure.
PROMPT
)"

  if [[ "$DRY_RUN" -eq 1 ]]; then
    {
      echo "---[DRY RUN $repo slot=${DOW_SHORT}-${HOUR}]---"
      echo "$prompt" | head -30
      echo "---"
    } > "$log"
    emit_event "$sid" "dispatch" "PROGRESS" "$repo dry-run"
    emit_event "$sid" "dispatch" "COMPLETE" "dry-run"
    return 0
  fi

  emit_event "$sid" "dispatch" "HANDOFF" "$repo → claude -p (PROD-00)"
  local append_sys="You are prod-00-product-discovery running in a headless dispatch (not interactive plan mode). Execute the full protocol directly — scan, create issues, scaffold ROADMAP-proposals.md as specified. Read ~/.claude/agents/prod-00-product-discovery.md, ~/.claude/handbook/00-hive-protocol.md, and ~/.claude/handbook/07-decision-guide.md before acting. Do not write intermediate plan files — act."

  # POOL_MODE=1: enqueue instead of direct claude -p (issue #49).
  if [[ "${POOL_MODE:-0}" == "1" ]]; then
    hive_pool_enqueue "prod-00" "$repo" "$sid" "$prompt" "$path" "$append_sys"
    emit_event "$sid" "dispatch" "PROGRESS" "$repo enqueued to pool (POOL_MODE=1)"
    return 0
  fi

  local claude_rc=0
  claude -p "$prompt" \
    --permission-mode acceptEdits \
    --add-dir "$path" \
    --add-dir "$HIVE" \
    --append-system-prompt "$append_sys" \
    > "$log" 2>&1 || claude_rc=$?

  # Post-run agent-outcome inspection:
  # The dispatcher COMPLETE only means `claude -p` exited cleanly — it does NOT
  # mean PROD-00 finished its protocol. Grep the agent log for the agent's own
  # terminal events so the hive stream distinguishes dispatcher vs agent outcome.
  local agent_blocked_reason=""
  if [[ -f "$log" ]]; then
    agent_blocked_reason="$(grep -oE 'BLOCKED[: ]+no-roadmap[^"]*' "$log" 2>/dev/null | head -1 || true)"
  fi
  if [[ -n "$agent_blocked_reason" ]]; then
    emit_event "$sid" "dispatch" "PROGRESS" "$repo agent-blocked-no-roadmap (see $log)"
  fi

  if [[ "$claude_rc" -eq 0 ]]; then
    emit_event "$sid" "dispatch" "SPECIALIST_COMPLETE" "$repo slot=${DOW_SHORT}-${HOUR} attempts=1"
    emit_event "$sid" "dispatch" "COMPLETE" "$repo dispatch-complete (agent output in $log)"
  else
    emit_event "$sid" "dispatch" "SPECIALIST_FAILED" "$repo slot=${DOW_SHORT}-${HOUR} exit=$claude_rc attempts=1"
    emit_event "$sid" "dispatch" "BLOCKED" "$repo claude -p exit $claude_rc (see $log)"
  fi
}

# --- Main ---
if [[ "$ALL" -eq 1 ]]; then
  CANDIDATES="$(PROFILES="$PROFILES" python3 -c '
import os, yaml
p = yaml.safe_load(open(os.environ["PROFILES"]))
repos = list((p.get("repos") or {}).keys())
print("\n".join(repos))
')"
  while IFS= read -r r; do
    [[ -n "$r" ]] && dispatch_one "$r"
  done <<< "$CANDIDATES"
  exit 0
fi

if [[ -z "$REPO" ]]; then
  REPO="$(resolve_rotation_repo)"
  if [[ -z "$REPO" ]]; then
    echo "no repo resolved from rotation for slot ${DOW_SHORT}-${HOUR}" >&2
    emit_event "product-$TODAY-$HOUR-none" "dispatch" "BLOCKED" "no rotation slot for ${DOW_SHORT}-${HOUR}"
    exit 0
  fi
fi

dispatch_one "$REPO"
echo "product-discovery: $REPO done"
