#!/bin/bash
# integration-health.sh - Single-command health check for ~/.claude/ integration
# Usage: ~/.claude/scripts/integration-health.sh

PASS=0
WARN=0
FAIL=0

check_ok()   { echo "[OK]    $1"; PASS=$((PASS + 1)); }
check_warn() { echo "[WARN]  $1"; WARN=$((WARN + 1)); }
check_fail() { echo "[FAIL]  $1"; FAIL=$((FAIL + 1)); }

echo "=== Claude Code Integration Health Check ==="
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

# 1. Agent definitions exist
AGENT_COUNT=$(ls ~/.claude/agents/*.md 2>/dev/null | grep -v _HIVE_PREAMBLE | wc -l)
if [[ $AGENT_COUNT -eq 17 ]]; then
    check_ok "Agent definitions: $AGENT_COUNT/17 found"
else
    check_fail "Agent definitions: $AGENT_COUNT/17 found (expected 17)"
fi

# 2. Agent usage guide exists
if [[ -f ~/.claude/context/agents/ai_agents_org_suite.md ]]; then
    check_ok "Agent usage guide (ai_agents_org_suite.md) exists"
else
    check_fail "Agent usage guide missing"
fi

# 3. Preamble exists
if [[ -f ~/.claude/agents/_HIVE_PREAMBLE_v3.8.md ]]; then
    check_ok "Hive preamble v3.8 exists"
else
    check_fail "Hive preamble missing"
fi

# 4. CLAUDE.md bootstrap exists
if [[ -f ~/.claude/CLAUDE.md ]]; then
    check_ok "CLAUDE.md bootstrap exists"
else
    check_fail "CLAUDE.md bootstrap missing"
fi

# 5. Index freshness
if [[ -f ~/.claude/context/index.yaml ]]; then
    INDEX_DATE=$(grep "last_updated" ~/.claude/context/index.yaml | head -1 | grep -oP '\d{4}-\d{2}-\d{2}')
    DAYS_AGO=$(( ($(date +%s) - $(date -d "$INDEX_DATE" +%s 2>/dev/null || echo 0)) / 86400 ))
    if [[ $DAYS_AGO -le 7 ]]; then
        check_ok "index.yaml freshness: ${DAYS_AGO}d old"
    elif [[ $DAYS_AGO -le 30 ]]; then
        check_warn "index.yaml freshness: ${DAYS_AGO}d old (>7d)"
    else
        check_fail "index.yaml freshness: ${DAYS_AGO}d old (>30d)"
    fi
else
    check_fail "index.yaml missing"
fi

# 6. Landing.yaml freshness per project
for landing in ~/.claude/context/projects/*/landing.yaml; do
    PROJECT=$(basename "$(dirname "$landing")")
    LANDING_DATE=$(grep "last_updated" "$landing" 2>/dev/null | head -1 | grep -oP '\d{4}-\d{2}-\d{2}')
    if [[ -n "$LANDING_DATE" ]]; then
        DAYS_AGO=$(( ($(date +%s) - $(date -d "$LANDING_DATE" +%s 2>/dev/null || echo 0)) / 86400 ))
        if [[ $DAYS_AGO -le 14 ]]; then
            check_ok "landing.yaml ($PROJECT): ${DAYS_AGO}d old"
        else
            check_warn "landing.yaml ($PROJECT): ${DAYS_AGO}d old (>14d)"
        fi
    else
        check_warn "landing.yaml ($PROJECT): no last_updated field"
    fi
done

# 7. Stale active sessions
STALE_ACTIVE=$(find ~/.claude/context/hive/active/ -mindepth 1 -maxdepth 1 -type d -mtime +7 2>/dev/null | wc -l)
TOTAL_ACTIVE=$(find ~/.claude/context/hive/active/ -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
if [[ $STALE_ACTIVE -eq 0 ]]; then
    check_ok "Active sessions: $TOTAL_ACTIVE total, 0 stale (>7d)"
else
    check_warn "Active sessions: $STALE_ACTIVE/$TOTAL_ACTIVE stale (>7d)"
fi

# 8. Events.ndjson health
if [[ -f ~/.claude/context/hive/events.ndjson ]]; then
    EVENT_COUNT=$(wc -l < ~/.claude/context/hive/events.ndjson)
    SESSION_COUNT=$(ls -d ~/.claude/context/hive/sessions/*/ 2>/dev/null | wc -l)
    RATIO=$(echo "scale=1; $EVENT_COUNT / ($SESSION_COUNT + 1)" | bc 2>/dev/null || echo "?")
    if (( EVENT_COUNT > SESSION_COUNT )); then
        check_ok "Event emission: $EVENT_COUNT events for $SESSION_COUNT sessions (ratio: $RATIO)"
    else
        check_warn "Event emission low: $EVENT_COUNT events for $SESSION_COUNT sessions (ratio: $RATIO, expected >1.5)"
    fi
else
    check_fail "events.ndjson missing"
fi

# 9. Checkpoint coverage
SESSIONS_WITH_CHECKPOINTS=$(find ~/.claude/context/hive/sessions -name "checkpoints.ndjson" 2>/dev/null | sed 's|/agents/.*||' | sort -u | wc -l)
if [[ $SESSION_COUNT -gt 0 ]]; then
    PCT=$((SESSIONS_WITH_CHECKPOINTS * 100 / SESSION_COUNT))
    if [[ $PCT -ge 50 ]]; then
        check_ok "Checkpoint coverage: $PCT% ($SESSIONS_WITH_CHECKPOINTS/$SESSION_COUNT sessions)"
    else
        check_warn "Checkpoint coverage low: $PCT% ($SESSIONS_WITH_CHECKPOINTS/$SESSION_COUNT sessions)"
    fi
fi

# 10. Hooks
if [[ -f ~/.claude/hooks/dispatch-reminder.sh ]]; then
    check_ok "Dispatch reminder hook present"
else
    check_warn "Dispatch reminder hook missing"
fi

# 11. Protocols
PROTO_COUNT=$(ls ~/.claude/protocols/*.md 2>/dev/null | wc -l)
if [[ $PROTO_COUNT -ge 5 ]]; then
    check_ok "Protocols: $PROTO_COUNT files"
else
    check_warn "Protocols: only $PROTO_COUNT files"
fi

echo ""
echo "=== Summary ==="
TOTAL=$((PASS + WARN + FAIL))
echo "Passed: $PASS/$TOTAL | Warnings: $WARN | Failed: $FAIL"

if [[ $FAIL -eq 0 && $WARN -eq 0 ]]; then
    echo "Status: HEALTHY"
    exit 0
elif [[ $FAIL -eq 0 ]]; then
    echo "Status: DEGRADED ($WARN warnings)"
    exit 1
else
    echo "Status: UNHEALTHY ($FAIL failures, $WARN warnings)"
    exit 2
fi
