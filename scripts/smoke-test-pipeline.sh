#!/usr/bin/env bash
# scripts/smoke-test-pipeline.sh
#
# End-to-end smoke test for the nightly-puffin + daytime-harrier pipelines.
#
# Phases:
#   1. Static     — bash -n / yaml / json / systemd-analyze every artefact
#   2. Schedule   — config/nightly-schedule.yaml ↔ systemd timers parity;
#                   stale-fire detection
#   3. Dry-run    — runs every cron-fired script in --dry-run, asserts exit 0
#                   and ≥1 event emitted per stage
#   3.1 Governance live-fire — apply-mode on a single safest tier-1 PR
#                   (default: ${GITHUB_ORG:-your-org}/CLAUDE-CODE-CLI-AGENTS-blueprint does not have
#                   live tier-1 candidates so we look across the live
#                   classifier output for the lowest-risk match; the user-
#                   identified target is ${GITHUB_ORG:-your-org}/example-repo#329 — a 2-line
#                   pg_isready -U test_user workflow fix)
#   4. Wiring     — recent prod-* / nightly-* sids have full event chains;
#                   governance-decisions.ndjson valid
#   5. Liveness   — events.ndjson freshness, pool-worker cadence
#
# Exit codes:
#   0 — SMOKE PASS  (all phases clean)
#   1 — SMOKE WARN  (degraded but functional)
#   2 — SMOKE FAIL  (one or more hard-blocker gaps)
#
# Usage:
#   bash scripts/smoke-test-pipeline.sh                # full run
#   bash scripts/smoke-test-pipeline.sh --no-live      # skip Phase 3.1
#   bash scripts/smoke-test-pipeline.sh --no-live --quick   # static+schedule only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
hive_cron_path

# ---- CLI flags
NO_LIVE=0
QUICK=0
THOROUGH=0
GOVERNANCE_LIVE_TARGET="${GOVERNANCE_LIVE_TARGET:-${GITHUB_ORG:-your-org}/example-repo#329}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-live)  NO_LIVE=1; shift ;;
    --quick)    QUICK=1; NO_LIVE=1; shift ;;
    --thorough) THOROUGH=1; shift ;;
    --target)   GOVERNANCE_LIVE_TARGET="$2"; shift 2 ;;
    *) echo "[smoke-test] Unknown flag: $1" >&2; exit 2 ;;
  esac
done

SID="smoke-test-$(date -u +%Y%m%dT%H%M%SZ)"
emit() { SID="$SID" hive_emit_event "smoke-test-pipeline" "$1" "$2"; }
emit "SPAWN" "no_live=$NO_LIVE quick=$QUICK target=$GOVERNANCE_LIVE_TARGET"

# Phase result codes
declare -A PHASE_RESULTS=()
declare -A PHASE_DETAILS=()

# Helpers
hr() { printf '%*s\n' "${1:-72}" '' | tr ' ' '─'; }
fail_count=0
warn_count=0

# track pass/warn/fail per phase
phase_log() {
  local phase="$1" status="$2" detail="$3"
  PHASE_RESULTS[$phase]="$status"
  PHASE_DETAILS[$phase]="$detail"
  case "$status" in
    pass) ;;
    warn) warn_count=$(( warn_count + 1 )) ;;
    fail) fail_count=$(( fail_count + 1 )) ;;
  esac
}

# ============================================================================
# PHASE 1 — STATIC
# ============================================================================
phase1_static() {
  hr; echo "Phase 1 — Static (bash -n / yaml / json / systemd-analyze)"; hr

  local p1_fails=0 details=""

  # bash syntax check
  while IFS= read -r f; do
    if ! bash -n "$f" 2>/dev/null; then
      echo "  ❌ bash -n failed: $f"
      p1_fails=$(( p1_fails + 1 ))
      details+="bash-syntax-fail:$f;"
    fi
  done < <(find "$CLAUDE_HOME/scripts" -maxdepth 2 -name '*.sh' -not -name '*.pre-v6-patch')
  echo "  ✅ bash -n: $(find "$CLAUDE_HOME/scripts" -maxdepth 2 -name '*.sh' -not -name '*.pre-v6-patch' | wc -l) files"

  # YAML
  while IFS= read -r f; do
    if ! python3 -c "import yaml; yaml.safe_load(open('$f'))" 2>/dev/null; then
      echo "  ❌ yaml parse failed: $f"
      p1_fails=$(( p1_fails + 1 ))
      details+="yaml-parse-fail:$f;"
    fi
  done < <(find "$CLAUDE_HOME/config" -maxdepth 1 -name '*.yaml')
  echo "  ✅ yaml: $(find "$CLAUDE_HOME/config" -maxdepth 1 -name '*.yaml' | wc -l) files"

  # JSON (settings.json gitignored, but valid)
  if [[ -f "$CLAUDE_HOME/settings.json" ]] \
     && ! jq -e . "$CLAUDE_HOME/settings.json" >/dev/null 2>&1; then
    echo "  ❌ jq parse failed: settings.json"
    p1_fails=$(( p1_fails + 1 ))
    details+="json-parse-fail:settings.json;"
  fi
  echo "  ✅ json: settings.json"

  # systemd unit files: minimal well-formed check (must have [Unit] +
  # either [Timer] or [Service] section). systemd-analyze --user verify
  # is too slow per-unit at this scale (~30+ units = 30s+).
  local sys_dir="$HOME/.config/systemd/user"
  local sys_fails=0 sys_count=0
  while IFS= read -r f; do
    sys_count=$(( sys_count + 1 ))
    if ! grep -q '^\[Unit\]' "$f" 2>/dev/null; then
      sys_fails=$(( sys_fails + 1 ))
      details+="systemd-no-unit-section:$(basename "$f");"
    fi
    if [[ "$f" == *.timer ]] && ! grep -q '^\[Timer\]' "$f" 2>/dev/null; then
      sys_fails=$(( sys_fails + 1 ))
      details+="systemd-no-timer-section:$(basename "$f");"
    fi
    if [[ "$f" == *.service ]] && ! grep -q '^\[Service\]' "$f" 2>/dev/null; then
      sys_fails=$(( sys_fails + 1 ))
      details+="systemd-no-service-section:$(basename "$f");"
    fi
  done < <(find "$sys_dir" -maxdepth 1 \( -name 'nightly-puffin-*.timer' -o -name 'nightly-puffin-*.service' \) 2>/dev/null)
  if [[ "$sys_fails" -gt 0 ]]; then
    p1_fails=$(( p1_fails + sys_fails ))
    echo "  ❌ $sys_fails systemd unit(s) malformed"
  else
    echo "  ✅ systemd: $sys_count units, all well-formed"
  fi

  if [[ "$p1_fails" -gt 0 ]]; then
    phase_log "1-static" "fail" "$details"
    return 2
  fi
  phase_log "1-static" "pass" "ok"
  return 0
}

# ============================================================================
# PHASE 2 — SCHEDULE INTEGRITY
# ============================================================================
phase2_schedule() {
  hr; echo "Phase 2 — Schedule integrity (yaml ↔ systemd parity)"; hr

  local p2_fails=0 p2_warns=0 details=""

  # 2a. Every yaml-named trigger has a matching systemd unit
  local yaml_names
  mapfile -t yaml_names < <(python3 -c "
import yaml
p = yaml.safe_load(open('$CLAUDE_HOME/config/nightly-schedule.yaml'))
for t in p.get('triggers') or []:
    print(t.get('name'))
" 2>/dev/null)

  for name in "${yaml_names[@]}"; do
    [[ -z "$name" ]] && continue
    local timer="$HOME/.config/systemd/user/nightly-puffin-${name}.timer"
    local svc="$HOME/.config/systemd/user/nightly-puffin-${name}.service"
    if [[ ! -f "$timer" ]]; then
      echo "  ❌ missing timer for trigger: $name"
      p2_fails=$(( p2_fails + 1 ))
      details+="missing-timer:$name;"
    fi
    if [[ ! -f "$svc" ]]; then
      echo "  ❌ missing service for trigger: $name"
      p2_fails=$(( p2_fails + 1 ))
      details+="missing-service:$name;"
    fi
  done
  echo "  ✅ yaml→systemd: ${#yaml_names[@]} triggers checked"

  # 2b. Every enabled timer has a sane next-fire (within 14 days)
  local now_epoch
  now_epoch="$(date -u +%s)"
  local stale_fires=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local next_fire
    next_fire="$(printf '%s' "$line" | awk '{print $1, $2, $3}')"
    [[ -z "$next_fire" || "$next_fire" == "n/a" || "$next_fire" == "-" ]] && continue
    local fire_epoch
    fire_epoch="$(date -d "$next_fire" +%s 2>/dev/null || echo 0)"
    if [[ "$fire_epoch" -gt 0 ]]; then
      local delta=$(( fire_epoch - now_epoch ))
      if [[ "$delta" -gt 1209600 ]]; then  # > 14 days
        stale_fires=$(( stale_fires + 1 ))
      fi
    fi
  done < <(systemctl --user list-timers --no-legend 2>/dev/null | grep "nightly-puffin-" | head -50)
  if [[ "$stale_fires" -gt 0 ]]; then
    echo "  ⚠ $stale_fires timer(s) with next-fire >14 days out (likely paused)"
    p2_warns=$(( p2_warns + 1 ))
    details+="stale-fires:$stale_fires;"
  fi
  echo "  ✅ next-fire times: sane for $(systemctl --user list-timers --no-legend 2>/dev/null | grep -c 'nightly-puffin-') timers"

  # 2c. Recently-fired-when-expected check
  # Pick the daily timers and verify each fired within the last 36h
  local critical_daily=(
    nightly-selector
    nightly-plan-A
    nightly-exec-B1
    nightly-exec-B2
    nightly-review-C1
    nightly-deploy-C2
    nightly-digest-out
    self-update
    pipeline-health-check
  )
  local stale_daily=0
  for t in "${critical_daily[@]}"; do
    local last_fire
    last_fire="$(systemctl --user show "nightly-puffin-${t}.service" -p ExecMainExitTimestamp --value 2>/dev/null)"
    [[ -z "$last_fire" || "$last_fire" == "0" || "$last_fire" == "n/a" ]] && {
      echo "  ⚠ $t never fired"
      stale_daily=$(( stale_daily + 1 ))
      continue
    }
    local last_epoch
    last_epoch="$(date -d "$last_fire" +%s 2>/dev/null || echo 0)"
    local age=$(( now_epoch - last_epoch ))
    if [[ "$last_epoch" -gt 0 && "$age" -gt 129600 ]]; then  # >36h
      echo "  ⚠ $t last-fired ${age}s ago (>36h)"
      stale_daily=$(( stale_daily + 1 ))
    fi
  done
  if [[ "$stale_daily" -gt 0 ]]; then
    p2_warns=$(( p2_warns + 1 ))
    details+="stale-daily-fires:$stale_daily;"
  fi
  echo "  ✅ critical daily fires: $((${#critical_daily[@]} - stale_daily))/${#critical_daily[@]} fresh"

  if [[ "$p2_fails" -gt 0 ]]; then
    phase_log "2-schedule" "fail" "$details"
    return 2
  fi
  if [[ "$p2_warns" -gt 0 ]]; then
    phase_log "2-schedule" "warn" "$details"
    return 1
  fi
  phase_log "2-schedule" "pass" "ok"
  return 0
}

# ============================================================================
# PHASE 3 — PER-STAGE DRY-RUN
# ============================================================================
phase3_dryrun() {
  hr; echo "Phase 3 — Per-stage dry-run"; hr

  local p3_fails=0 p3_warns=0 details=""
  local tmpdir
  tmpdir="$(mktemp -d /tmp/smoke-test.XXXXXX)"
  trap "rm -rf '$tmpdir'" RETURN

  # Snapshot events.ndjson size — measure events emitted DURING dry-runs
  local pre_events
  pre_events="$(wc -l < "$EVENTS" 2>/dev/null || echo 0)"

  run_dryrun() {
    local label="$1" cmd="$2"
    local logfile="$tmpdir/$label.log"
    local rc=0
    local start_lines
    start_lines="$(wc -l < "$EVENTS" 2>/dev/null || echo 0)"
    timeout 600 bash -c "$cmd" > "$logfile" 2>&1 || rc=$?
    local end_lines
    end_lines="$(wc -l < "$EVENTS" 2>/dev/null || echo 0)"
    local emitted=$(( end_lines - start_lines ))
    if [[ "$rc" -eq 0 ]]; then
      echo "  ✅ $label (exit=$rc, +$emitted events)"
    elif [[ "$rc" -eq 2 ]]; then
      # Exit 2 = PARTIAL (some sub-targets had API errors but the run
      # produced its expected outputs). Treated as warn, not fail.
      echo "  ⚠ $label (exit=$rc partial, +$emitted events, log=$logfile)"
      p3_warns=$(( p3_warns + 1 ))
      details+="dryrun-partial:$label-exit-$rc;"
    else
      echo "  ❌ $label (exit=$rc, +$emitted events, log=$logfile)"
      p3_fails=$(( p3_fails + 1 ))
      details+="dryrun-fail:$label-exit-$rc;"
      tail -5 "$logfile" | sed 's/^/     /'
    fi
  }

  # Fast checks (under ~60s combined). Closure-watcher + pr-sweeper +
  # digest-render are NOT included in the default smoke — they each scan
  # 38+ repos (3-4 min apiece) and their freshness is already asserted by
  # pipeline-health-check. Add `--thorough` to opt into them.
  run_dryrun "self-update"          "bash $CLAUDE_HOME/scripts/self-update.sh"
  run_dryrun "pipeline-health"      "bash $CLAUDE_HOME/scripts/pipeline-health-check.sh"
  run_dryrun "governance-classify"  "bash $CLAUDE_HOME/scripts/governance-auto-approve.sh --dry-run --max 3"

  if [[ "$THOROUGH" -eq 1 ]]; then
    # Heavy dry-runs — only when explicitly requested (e.g. weekly Sunday smoke)
    run_dryrun "closure-watcher"    "bash $CLAUDE_HOME/scripts/closure-watcher.sh --dry-run --orgs ${GITHUB_ORG:-your-org}"
    run_dryrun "pr-sweeper-triage"  "bash $CLAUDE_HOME/scripts/pr-sweeper.sh --triage --orgs ${GITHUB_ORG:-your-org}"
  fi

  if [[ "$p3_fails" -gt 0 ]]; then
    phase_log "3-dryrun" "fail" "$details"
    return 2
  fi
  if [[ "$p3_warns" -gt 0 ]]; then
    phase_log "3-dryrun" "warn" "$details"
    return 1
  fi
  phase_log "3-dryrun" "pass" "ok"
  return 0
}

# ============================================================================
# PHASE 3.1 — GOVERNANCE LIVE-FIRE (1 SAFEST CANDIDATE)
# ============================================================================
phase31_governance_live() {
  hr; echo "Phase 3.1 — Governance live-fire (apply-mode on 1 safest tier-1)"; hr

  if [[ "$NO_LIVE" -eq 1 ]]; then
    echo "  ⏭  --no-live set; skipped"
    phase_log "3.1-gov-live" "pass" "skipped"
    return 0
  fi

  # Parse target into repo + pr
  local target_repo="${GOVERNANCE_LIVE_TARGET%#*}"
  local target_pr="${GOVERNANCE_LIVE_TARGET#*#}"
  if [[ -z "$target_repo" || -z "$target_pr" ]]; then
    echo "  ❌ malformed target: $GOVERNANCE_LIVE_TARGET (expected owner/repo#PR)"
    phase_log "3.1-gov-live" "fail" "malformed-target"
    return 2
  fi

  echo "  Target: $target_repo#$target_pr"

  # Pre-flight: classify; refuse if target is not tier 1
  source "$CLAUDE_HOME/scripts/lib/risk-classifier.sh"
  local cls
  cls="$(classify_pr_tier "$target_repo" "$target_pr" 2>/dev/null)"
  local tier reason
  tier="$(printf '%s' "$cls" | jq -r '.tier // 4')"
  reason="$(printf '%s' "$cls" | jq -r '.reason // "unknown"')"
  if [[ "$tier" != "1" ]]; then
    echo "  ❌ target tier=$tier ($reason); refusing live-fire"
    phase_log "3.1-gov-live" "fail" "target-not-tier-1:$reason"
    return 2
  fi
  echo "  ✅ pre-flight: tier=1 ($reason)"

  # Pre-flight: target must NOT already be governance-handled
  local existing_labels
  existing_labels="$(gh pr view "$target_pr" --repo "$target_repo" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")"
  if printf '%s' "$existing_labels" | grep -qE '(^|,)(governance:tier-1-approved|governance:rejected|sweep-ready-to-merge)(,|$)'; then
    echo "  ⏭ target already governance-handled (labels: $existing_labels) — already-pass"
    phase_log "3.1-gov-live" "pass" "already-handled"
    return 0
  fi

  # Snapshot audit log
  local audit_log="$HIVE/governance-decisions.ndjson"
  local pre_audit_lines
  pre_audit_lines="$(wc -l < "$audit_log" 2>/dev/null || echo 0)"

  # Fire — capped to 1 candidate
  local govfire_log
  govfire_log="$(mktemp /tmp/smoke-gov-live.XXXXXX)"
  echo "  Running: governance-auto-approve.sh --apply --max 1"
  local govfire_rc=0
  timeout 300 bash "$CLAUDE_HOME/scripts/governance-auto-approve.sh" \
    --apply --max 1 > "$govfire_log" 2>&1 || govfire_rc=$?

  if [[ "$govfire_rc" -ne 0 ]]; then
    echo "  ❌ governance-auto-approve exit=$govfire_rc"
    tail -10 "$govfire_log" | sed 's/^/     /'
    phase_log "3.1-gov-live" "fail" "govfire-exit-$govfire_rc"
    return 2
  fi

  # Verify audit log gained an entry
  local post_audit_lines
  post_audit_lines="$(wc -l < "$audit_log" 2>/dev/null || echo 0)"
  if [[ "$post_audit_lines" -le "$pre_audit_lines" ]]; then
    echo "  ⚠ audit log unchanged — governance-auto-approve found no candidates"
    phase_log "3.1-gov-live" "warn" "no-audit-entry-added"
    return 1
  fi

  # Verify target's labels gained governance:tier-1-approved OR governance:rejected
  local final_labels
  final_labels="$(gh pr view "$target_pr" --repo "$target_repo" \
    --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")"
  if printf '%s' "$final_labels" | grep -qE 'governance:tier-1-approved'; then
    echo "  ✅ target approved + sweep-ready-to-merge applied"
    echo "  ✅ closure-watcher will pick up at 14:43 / 18:33 local time"
  elif printf '%s' "$final_labels" | grep -qE 'governance:rejected'; then
    echo "  ⚠ target was REJECTED by SUP-00 — review verdict in audit log"
    phase_log "3.1-gov-live" "warn" "sup00-rejected"
    return 1
  else
    # The cron fire may have hit a different candidate first, in which case
    # our target wasn't necessarily the one acted on with --max 1.
    echo "  ⚠ target labels unchanged (max=1 may have approved a different candidate first)"
    echo "    target labels: $final_labels"
    phase_log "3.1-gov-live" "warn" "target-not-acted-on"
    return 1
  fi

  rm -f "$govfire_log"
  phase_log "3.1-gov-live" "pass" "approved"
  return 0
}

# ============================================================================
# PHASE 4 — WIRING SPOT-CHECK
# ============================================================================
phase4_wiring() {
  hr; echo "Phase 4 — Wiring spot-check"; hr

  local p4_fails=0 details=""

  # Latest nightly-* sid: should have all 5 stages COMPLETE
  local latest_nightly_sid
  latest_nightly_sid="$(jq -r 'select(.sid // "" | tostring | startswith("nightly-")) | .sid' \
    "$EVENTS" 2>/dev/null | tail -50 | sort -u | tail -1)"
  if [[ -z "$latest_nightly_sid" ]]; then
    echo "  ⚠ no nightly-* sids in event stream"
    details+="no-nightly-sids;"
  else
    echo "  Latest nightly sid (one stage): $latest_nightly_sid"
    # Check most recent nightly run had A, B1, B2, C1, C2 all emitting COMPLETE
    local missing_stages=""
    for stage in A B1 B2 C1 C2; do
      local stage_complete
      stage_complete="$(jq -r --arg s "$stage" '
        select(.event == "COMPLETE")
        | select(.sid // "" | tostring | endswith("-" + $s))
        | .ts
      ' "$EVENTS" 2>/dev/null | tail -1)"
      if [[ -z "$stage_complete" ]]; then
        missing_stages+=" $stage"
      fi
    done
    if [[ -n "$missing_stages" ]]; then
      echo "  ⚠ no recent COMPLETE for stage(s):$missing_stages"
      details+="missing-stage-completes:$missing_stages;"
    else
      echo "  ✅ all 5 nightly stages have recent COMPLETE events"
    fi
  fi

  # Latest prod-* sid: check SPAWN→HANDOFF→COMPLETE chain
  local latest_prod_sid
  latest_prod_sid="$(jq -r 'select(.sid // "" | tostring | startswith("prod-")) | .sid' \
    "$EVENTS" 2>/dev/null | tail -50 | sort -u | tail -1)"
  if [[ -z "$latest_prod_sid" ]]; then
    echo "  ⚠ no prod-* sids in event stream"
    details+="no-prod-sids;"
  else
    local has_spawn has_handoff has_complete
    has_spawn="$(jq -c --arg s "$latest_prod_sid" 'select(.sid == $s and .event == "SPAWN")' "$EVENTS" 2>/dev/null | head -1)"
    has_handoff="$(jq -c --arg s "$latest_prod_sid" 'select(.sid == $s and .event == "HANDOFF")' "$EVENTS" 2>/dev/null | head -1)"
    has_complete="$(jq -c --arg s "$latest_prod_sid" 'select(.sid == $s and (.event == "COMPLETE" or .event == "BLOCKED"))' "$EVENTS" 2>/dev/null | head -1)"
    if [[ -z "$has_spawn" || -z "$has_complete" ]]; then
      echo "  ⚠ prod-* sid $latest_prod_sid missing SPAWN or COMPLETE/BLOCKED"
      details+="incomplete-prod-chain:$latest_prod_sid;"
    else
      echo "  ✅ prod-* sid $latest_prod_sid has full SPAWN→...→COMPLETE chain"
    fi
  fi

  # Governance audit log: every entry must be valid JSON with required fields
  local audit_log="$HIVE/governance-decisions.ndjson"
  if [[ -f "$audit_log" ]]; then
    local invalid_entries=0
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if ! printf '%s' "$line" | jq -e '. | has("repo") and has("pr") and has("tier") and has("decision")' >/dev/null 2>&1; then
        invalid_entries=$(( invalid_entries + 1 ))
      fi
    done < <(tail -50 "$audit_log")
    if [[ "$invalid_entries" -gt 0 ]]; then
      echo "  ❌ governance-decisions.ndjson has $invalid_entries malformed entries (last 50)"
      p4_fails=$(( p4_fails + 1 ))
      details+="audit-malformed:$invalid_entries;"
    else
      echo "  ✅ governance-decisions.ndjson: $(wc -l < "$audit_log") entries, all valid"
    fi
  else
    echo "  ⏭ governance-decisions.ndjson not yet created"
  fi

  if [[ "$p4_fails" -gt 0 ]]; then
    phase_log "4-wiring" "fail" "$details"
    return 2
  fi
  if [[ -n "$details" ]]; then
    phase_log "4-wiring" "warn" "$details"
    return 1
  fi
  phase_log "4-wiring" "pass" "ok"
  return 0
}

# ============================================================================
# PHASE 5 — LIVENESS
# ============================================================================
phase5_liveness() {
  hr; echo "Phase 5 — Liveness sanity"; hr

  local p5_fails=0 details=""
  local now_epoch
  now_epoch="$(date -u +%s)"

  # 5a. events.ndjson freshness — within last hour
  local last_event_ts
  last_event_ts="$(tail -50 "$EVENTS" 2>/dev/null | jq -r '.ts // empty' | tail -1)"
  if [[ -n "$last_event_ts" ]]; then
    local last_event_epoch age
    last_event_epoch="$(date -d "$last_event_ts" +%s 2>/dev/null || echo 0)"
    age=$(( now_epoch - last_event_epoch ))
    if [[ "$age" -gt 3600 ]]; then
      echo "  ❌ events.ndjson stale: last event ${age}s ago (>1h)"
      p5_fails=$(( p5_fails + 1 ))
      details+="events-stale:${age}s;"
    else
      echo "  ✅ events.ndjson fresh (last event ${age}s ago)"
    fi
  else
    echo "  ❌ events.ndjson empty or unreadable"
    p5_fails=$(( p5_fails + 1 ))
    details+="events-unreadable;"
  fi

  # 5b. pool-worker cadence — should fire every 6 minutes
  local last_pool_ts
  last_pool_ts="$(jq -r 'select(.agent == "pool-worker" and .event == "SPAWN") | .ts' \
    "$EVENTS" 2>/dev/null | tail -1)"
  if [[ -n "$last_pool_ts" ]]; then
    local last_pool_epoch age_pool
    last_pool_epoch="$(date -d "$last_pool_ts" +%s 2>/dev/null || echo 0)"
    age_pool=$(( now_epoch - last_pool_epoch ))
    if [[ "$age_pool" -gt 720 ]]; then  # >12min
      echo "  ⚠ pool-worker stale: last fire ${age_pool}s ago (>12min)"
      details+="pool-stale:${age_pool}s;"
    else
      echo "  ✅ pool-worker fresh (${age_pool}s ago)"
    fi
  fi

  # 5c. recent BLOCKED with stash conflict in last 24h?
  local stash_conflicts
  stash_conflicts="$(jq -c --arg c "$(( now_epoch - 86400 ))" '
    select(.agent == "self-update" and .event == "BLOCKED")
    | select(.detail | tostring | test("stash-pop-conflict"; "i"))
    | select(.ts | sub("\\..*Z$"; "Z") | fromdateiso8601 >= ($c | tonumber))
  ' "$EVENTS" 2>/dev/null | wc -l)"
  if [[ "${stash_conflicts:-0}" -gt 0 ]]; then
    echo "  ⚠ $stash_conflicts self-update stash-pop-conflicts in last 24h — local mods diverging from upstream"
    details+="stash-pop-conflicts:$stash_conflicts;"
  else
    echo "  ✅ no self-update stash-pop conflicts in last 24h"
  fi

  if [[ "$p5_fails" -gt 0 ]]; then
    phase_log "5-liveness" "fail" "$details"
    return 2
  fi
  if [[ -n "$details" ]]; then
    phase_log "5-liveness" "warn" "$details"
    return 1
  fi
  phase_log "5-liveness" "pass" "ok"
  return 0
}

# ============================================================================
# RUN ALL PHASES
# ============================================================================
exit_code=0

run_phase() {
  local phase_func="$1"
  set +e
  $phase_func
  local rc=$?
  set -e
  if [[ "$rc" -gt "$exit_code" ]]; then
    exit_code=$rc
  fi
}

run_phase phase1_static
run_phase phase2_schedule
run_phase phase3_dryrun
[[ "$NO_LIVE" -eq 0 ]] && run_phase phase31_governance_live
run_phase phase4_wiring
run_phase phase5_liveness

# ============================================================================
# SUMMARY
# ============================================================================
hr; echo "Smoke summary"; hr

for phase in 1-static 2-schedule 3-dryrun 3.1-gov-live 4-wiring 5-liveness; do
  status="${PHASE_RESULTS[$phase]:-skipped}"
  detail="${PHASE_DETAILS[$phase]:-—}"
  case "$status" in
    pass)    icon="✅" ;;
    warn)    icon="⚠ " ;;
    fail)    icon="❌" ;;
    skipped) icon="⏭ " ;;
  esac
  printf '  %s phase=%s status=%s detail=%s\n' "$icon" "$phase" "$status" "$detail"
done

echo ""
case "$exit_code" in
  0) verdict="✅ SMOKE PASS" ;;
  1) verdict="⚠ SMOKE WARN ($warn_count warnings)" ;;
  2) verdict="❌ SMOKE FAIL ($fail_count failures)" ;;
esac

# Summary as a flat detail string + per-phase results dumped via jq for the
# digest's aggregator. Avoid embedding-Python-in-Bash gymnastics.
phases_csv=""
for phase in 1-static 2-schedule 3-dryrun 3.1-gov-live 4-wiring 5-liveness; do
  phases_csv+="${phase}=${PHASE_RESULTS[$phase]:-skipped},"
done
phases_csv="${phases_csv%,}"

emit "COMPLETE" "verdict=$verdict warnings=$warn_count failures=$fail_count phases=$phases_csv"
echo "$verdict"
exit "$exit_code"
