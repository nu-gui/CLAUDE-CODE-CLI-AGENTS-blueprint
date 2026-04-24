#!/usr/bin/env bash
# hive-status.sh — one-command 24h pipeline activity summary (EXAMPLE-ID / #92)
# Usage:  hive-status.sh [--since <dur>] [--json] [--observe]
# Exit 0=healthy  1=blocked/degraded
# --observe: always exit 0 (for systemd/cron callers that only want a journal
#            snapshot — the DEGRADED/BLOCKED state is still printed and
#            parseable, but the non-zero exit is suppressed so the wrapping
#            unit is not marked failed). See #140.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
hive_cron_path

SINCE_ARG="24h"; JSON_MODE=false; OBSERVE_MODE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)    SINCE_ARG="${2:-24h}"; shift 2 ;;
    --since=*)  SINCE_ARG="${1#--since=}"; shift ;;
    --json)     JSON_MODE=true; shift ;;
    --observe)  OBSERVE_MODE=true; shift ;;
    -h|--help)  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# //'; exit 0 ;;
    *)          echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Parse --since (Nm / Nh / Nd) into an ISO8601 threshold via GNU date or python3 fallback
parse_since() {
  [[ "$1" =~ ^([0-9]+)(m|h|d)$ ]] || { echo "Invalid --since '$1'. Use e.g. 30m, 2h, 1d" >&2; exit 1; }
  local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
  local gnu_unit; case "$u" in m) gnu_unit="minutes";; h) gnu_unit="hours";; d) gnu_unit="days";; esac
  date -u -d "${n} ${gnu_unit} ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
    python3 -c "from datetime import datetime,timedelta as td; kw={'m':'minutes','h':'hours','d':'days'}; \
      print((datetime.utcnow()-td(**{kw['${u}']:${n}})).strftime('%Y-%m-%dT%H:%M:%SZ'))"
}

THRESHOLD="$(parse_since "$SINCE_ARG")"
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EVENTS_FILE="${EVENTS:-$HIVE/events.ndjson}"

# Filter events.ndjson to window; handle missing/empty file gracefully.
# Use `jq -R 'fromjson? | select(...)'` so malformed/legacy lines (e.g. older
# writers that emitted unquoted-key JS object literals) are silently skipped
# instead of halting the whole filter. EXAMPLE-ID discovered that jq's streaming
# mode aborts at the first parse error, previously hiding ALL recent events.
if [[ -s "$EVENTS_FILE" ]]; then
  FILTERED="$(jq -Rrc --arg t "$THRESHOLD" \
    'fromjson? | select(.ts? and (.ts >= $t)) | tojson' \
    "$EVENTS_FILE" 2>/dev/null || true)"
else
  FILTERED=""
fi
TOTAL=0; BLOCKED_COUNT=0
if [[ -n "$FILTERED" ]]; then
  TOTAL="$(echo "$FILTERED" | wc -l)"
  BLOCKED_COUNT="$(echo "$FILTERED" | jq -sc '[.[] | select(.event? and (.event | ascii_downcase | contains("block")))] | length' 2>/dev/null || echo 0)"
fi

# Systemd failed units
FAILED_UNITS_RAW="$(systemctl --user list-units --state=failed --type=service 'nightly-puffin-*' \
  --no-pager --no-legend 2>/dev/null | awk '{print $1}' | grep -v '^$' || true)"
FAILED_COUNT=0; [[ -n "$FAILED_UNITS_RAW" ]] && FAILED_COUNT="$(echo "$FAILED_UNITS_RAW" | wc -l)"

# Heartbeat stale-check (issue #96 / EXAMPLE-ID; #168 derives list from yaml)
# Any heartbeat key missing from heartbeats.log for >25 h is flagged STALE.
# Expected keys come from the `heartbeats:` lists in nightly-schedule.yaml so
# the two stay in lock-step (adding a new yaml trigger also registers its
# heartbeat, and removing one de-registers it). If the yaml is unreadable or
# the heartbeats file is absent we skip gracefully rather than erroring
# (first-run + degraded-config cases).
HEARTBEAT_LOG="${HIVE}/heartbeats.log"
STALE_TRIGGERS=()
STALE_CUTOFF="$(date -u -d '25 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || \
  python3 -c "from datetime import datetime,timedelta; print((datetime.utcnow()-timedelta(hours=25)).strftime('%Y-%m-%dT%H:%M:%SZ'))")"
EXPECTED_TRIGGERS=()
while IFS= read -r hb; do
  [[ -n "$hb" ]] && EXPECTED_TRIGGERS+=("$hb")
done < <(hive_expected_triggers || true)
if [[ -s "$HEARTBEAT_LOG" ]] && (( ${#EXPECTED_TRIGGERS[@]} > 0 )); then
  for trigger in "${EXPECTED_TRIGGERS[@]}"; do
    # Latest heartbeat timestamp for this trigger (field 1 = ts, field 2 = trigger)
    latest="$(awk -F'\t' -v t="$trigger" '$2 == t {last=$1} END {print last}' "$HEARTBEAT_LOG" 2>/dev/null || true)"
    if [[ -z "$latest" ]] || [[ "$latest" < "$STALE_CUTOFF" ]]; then
      STALE_TRIGGERS+=("$trigger")
    fi
  done
fi
STALE_COUNT="${#STALE_TRIGGERS[@]}"

# Active timers
TIMERS_RAW="$(systemctl --user list-timers 'nightly-puffin-*.timer' --no-pager --no-legend 2>/dev/null | head -5 || true)"
TIMER_COUNT=0; [[ -n "$TIMERS_RAW" ]] && TIMER_COUNT="$(echo "$TIMERS_RAW" | grep -c '.' || echo 0)"
NEXT_TIMER="$(echo "$TIMERS_RAW" | head -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /\.timer$/) {print $i; exit}}' || true)"

# Latest digest
LATEST_DIGEST="$(ls -t "${HIVE}/digests/"*.md 2>/dev/null | head -1 || true)"

# Overall status
STATUS="healthy"
[[ "$FAILED_COUNT" -gt 0 ]] && STATUS="degraded"
[[ "$STALE_COUNT" -gt 0 ]]  && STATUS="degraded"
[[ "$BLOCKED_COUNT" -gt 0 ]] && STATUS="blocked"
EXIT_CODE=0; [[ "$STATUS" != "healthy" ]] && EXIT_CODE=1
# --observe: degrade/block is still reported in the output and JSON payload,
# but the process exit stays 0 so systemd doesn't mark the calling service
# failed (issue #140).
[[ "$OBSERVE_MODE" == true ]] && EXIT_CODE=0

# JSON mode
if [[ "$JSON_MODE" == true ]]; then
  EVENTS_JSON="$(echo "$FILTERED" | jq -sc '.' 2>/dev/null || echo '[]')"
  [[ -z "$FILTERED" ]] && EVENTS_JSON="[]"
  FAILED_JSON="$(echo "$FAILED_UNITS_RAW" | jq -Rsc '[split("\n")[] | select(. != "")]' 2>/dev/null || echo '[]')"
  [[ -z "$FAILED_UNITS_RAW" ]] && FAILED_JSON="[]"
  jq -n \
    --arg generated_at "$NOW_ISO" --arg window "last ${SINCE_ARG}" \
    --argjson events "$EVENTS_JSON" --argjson failed_units "$FAILED_JSON" \
    --argjson active_timers_count "$TIMER_COUNT" \
    --arg latest_digest "${LATEST_DIGEST:-}" --arg status "$STATUS" \
    '{generated_at:$generated_at,window:$window,events:$events,
      failed_units:$failed_units,active_timers_count:$active_timers_count,
      latest_digest:$latest_digest,status:$status}'
  exit "$EXIT_CODE"
fi

# Pretty mode
echo "=== nightly-puffin status ==="
echo "Generated: ${NOW_ISO}"
echo "Window:    last ${SINCE_ARG}"
[[ -n "$NEXT_TIMER" ]] && echo "Active timers: ${TIMER_COUNT} (next: ${NEXT_TIMER})" \
                       || echo "Active timers: ${TIMER_COUNT}"
echo "Latest digest: ${LATEST_DIGEST:-(none)}"
echo "Failed units:  ${FAILED_COUNT}"
echo ""

if [[ -n "$FILTERED" ]]; then
  echo "Recent events (last ${SINCE_ARG}, ${TOTAL} total):"
  echo "$FILTERED" | tail -15 | tac 2>/dev/null | \
    jq -r '"  " + (.ts//"-")[11:19] + "Z  " +
      ((.agent//"?")  | .[0:14] | . + (" "*(14-length))) + "  " +
      ((.event//"?")  | .[0:20] | . + (" "*(20-length))) + "  " +
      (.detail//"" | if type=="string" then .[0:60] else (.|tostring)[0:60] end)' \
    2>/dev/null || true
else
  echo "Recent events (last ${SINCE_ARG}): no events in window"
fi

echo ""
echo "STATUS: $(echo "$STATUS" | tr '[:lower:]' '[:upper:]')"
exit "$EXIT_CODE"
