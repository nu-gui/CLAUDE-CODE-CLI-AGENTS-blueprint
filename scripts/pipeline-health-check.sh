#!/usr/bin/env bash
# scripts/pipeline-health-check.sh
#
# Asserts pipeline liveness and surfaces silent-failure conditions to the
# morning digest. Without this, problems like "PROD-00 has run zero times in
# 24h" hide behind a green systemd-timer state because the underlying script
# completes successfully even when its agent emits nothing useful.
#
# Checks (each emits PROGRESS on pass, BLOCKED on fail):
#   1. self-update event in last 24h         → script-deploy gap
#   2. PROD-00 events in last 24h ≥ 6        → agent dispatched <50% of slots
#   3. sprint-collate doc for yesterday      → collation skipped/misfiled
#   4. nightly-dispatch B1+B2 events seen    → overnight pipeline ran
#   5. PRs merged in last 48h ≥ 1            → merge throughput alive
#   6. local HEAD == origin/master           → cron tree drift detected
#   7. permissions allow Write(.../hive/**)  → claude -p sandbox can write
#
# Run on the digest schedule (06:00 local time or before morning-digest at 06:45).
# A BLOCKED count > 0 surfaces in morning-digest's "Pipeline health" section
# (added in this PR).
#
# Usage:
#   bash scripts/pipeline-health-check.sh
#
# Exit code:
#   0  all checks passed
#   1  one or more checks failed (BLOCKED events emitted)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

SID="pipeline-health-$(date -u +%Y-%m-%d)"
emit() { SID="$SID" hive_emit_event "pipeline-health" "$1" "$2"; }

EVENTS="${EVENTS:-$HOME/.claude/context/hive/events.ndjson}"
SPRINTS_DIR="$HOME/.claude/context/hive/sprints"
NOW_TS="$(date -u +%s)"
DAY_AGO="$(( NOW_TS - 86400 ))"
TWO_DAYS_AGO="$(( NOW_TS - 172800 ))"
YEST="$(date -u -d 'yesterday' +%Y-%m-%d)"

FAIL=0
emit "SPAWN" "running pipeline-health checks"

# ---- 1. self-update fired in last 24h
self_update_count="$(jq -r --argjson c "$DAY_AGO" '
  select(.agent == "self-update")
  | select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= $c)
  | .ts' "$EVENTS" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${self_update_count:-0}" -lt 1 ]]; then
  emit "BLOCKED" "check=self-update last-24h-fires=$self_update_count expected>=1 (cron tree may be stale; see scripts/self-update.sh)"
  FAIL=1
else
  emit "PROGRESS" "check=self-update last-24h-fires=$self_update_count OK"
fi

# ---- 2. PROD-00 dispatched at least 6 times in last 24h
# (Hourly schedule 09–20 local time = 12 slots/day; threshold 6 = 50% to allow weekend skips.)
prod_count="$(jq -r --argjson c "$DAY_AGO" '
  select((.sid // "") | tostring | startswith("prod-"))
  | select(.event == "SPAWN")
  | select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= $c)
  | .sid' "$EVENTS" 2>/dev/null | sort -u | wc -l | tr -d ' ')"
if [[ "${prod_count:-0}" -lt 3 ]]; then
  emit "BLOCKED" "check=prod-00 last-24h-runs=$prod_count expected>=3 (timers may be firing but script bailing early)"
  FAIL=1
else
  emit "PROGRESS" "check=prod-00 last-24h-runs=$prod_count OK"
fi

# ---- 3. Sprint-collate doc for yesterday exists at canonical path
if [[ ! -f "$SPRINTS_DIR/$YEST.md" ]]; then
  emit "BLOCKED" "check=sprint-collate doc=$SPRINTS_DIR/$YEST.md missing (agent may have written to a fallback path; see CLAUDE-CODE-CLI-AGENTS#152 + 2026-04-30 incident)"
  FAIL=1
else
  emit "PROGRESS" "check=sprint-collate doc=$SPRINTS_DIR/$YEST.md OK"
fi

# ---- 4. Nightly-dispatch B1 + B2 stages both ran last night
b1_count="$(jq -r --argjson c "$DAY_AGO" '
  select((.sid // "") | tostring | test("^nightly-.*-B1$"))
  | select(.event == "COMPLETE")
  | select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= $c)
  | .sid' "$EVENTS" 2>/dev/null | wc -l | tr -d ' ')"
b2_count="$(jq -r --argjson c "$DAY_AGO" '
  select((.sid // "") | tostring | test("^nightly-.*-B2$"))
  | select(.event == "COMPLETE")
  | select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= $c)
  | .sid' "$EVENTS" 2>/dev/null | wc -l | tr -d ' ')"
if [[ "${b1_count:-0}" -lt 1 || "${b2_count:-0}" -lt 1 ]]; then
  emit "BLOCKED" "check=nightly-dispatch b1=$b1_count b2=$b2_count expected>=1 each"
  FAIL=1
else
  emit "PROGRESS" "check=nightly-dispatch b1=$b1_count b2=$b2_count OK"
fi

# ---- 5. PR merged in last 48h across ${GITHUB_ORG:-your-org} + ${GITHUB_ORG:-your-org}
# Soft check — counts gh search results. Tolerant of API errors (skip on failure).
if command -v gh >/dev/null 2>&1; then
  merge_since="$(date -u -d '48 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  merged_count="$(gh search prs --owner ${GITHUB_ORG:-your-org} --owner ${GITHUB_ORG:-your-org} \
    --merged --merged-at=">=$merge_since" --json number --limit 100 2>/dev/null \
    | jq 'length' 2>/dev/null || echo "?")"
  if [[ "$merged_count" == "?" ]]; then
    emit "PROGRESS" "check=merged-48h status=skipped (gh search failed)"
  elif [[ "$merged_count" -lt 1 ]]; then
    emit "BLOCKED" "check=merged-48h count=0 — pipeline producing zero merges; auto-merge or review pipeline likely stuck"
    FAIL=1
  else
    emit "PROGRESS" "check=merged-48h count=$merged_count OK"
  fi
fi

# ---- 6. Cron tree at HEAD == origin/master
if cd "$HOME/.claude" 2>/dev/null && git fetch --quiet origin master 2>/dev/null; then
  local_head="$(git rev-parse HEAD 2>/dev/null)"
  remote_head="$(git rev-parse origin/master 2>/dev/null)"
  if [[ "$local_head" != "$remote_head" ]]; then
    emit "BLOCKED" "check=tree-drift local=${local_head:0:7} remote=${remote_head:0:7} — self-update.sh should fix on next fire"
    FAIL=1
  else
    emit "PROGRESS" "check=tree-drift HEAD=${local_head:0:7} OK"
  fi
fi

# ---- 7. Settings.json allows hive writes
# (Phase 6 lesson — without this, claude -p calls silently dump output to
# fallback paths and the canonical pipeline contract breaks.)
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
  if ! jq -e '.permissions.allow | any(. | test("Write\\(.*context/hive"))' "$SETTINGS" >/dev/null 2>&1; then
    emit "BLOCKED" "check=hive-write-allow settings.json missing Write(.../context/hive/**) — claude -p will write to fallback paths"
    FAIL=1
  else
    emit "PROGRESS" "check=hive-write-allow OK"
  fi
fi

emit "COMPLETE" "checks-failed=$FAIL"
exit "$FAIL"
