#!/usr/bin/env bash
# Smoke test for EXAMPLE-STAGE preflight guard in scripts/nightly-select-projects.sh.
# Verifies both guard paths: (a) failure → exit 2 + log, (b) bypass via env var.
#
# Usage: bash tests/test-nightly-select-preflight.sh
# Exit: 0 on pass, 1 on any failure

set -u

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/nightly-select-projects.sh"
LOG="$HOME/.claude/logs/nightly-errors.log"
PASS=0; FAIL=0
check() { if [[ "$2" -eq "$3" ]]; then echo "PASS: $1"; PASS=$((PASS+1)); else echo "FAIL: $1 (expected $3, got $2)"; FAIL=$((FAIL+1)); fi; }

# Test 1: with no triggers registered on ${USER}-workstation, guard fires → exit 2.
# (This test assumes the test host has no nightly-puffin triggers. CI can skip
#  or run inside a systemd-free container to satisfy the precondition.)
# N3a: also check ~/.claude/scheduled_tasks.json as a third source.
systemd_has=$(systemctl --user list-timers --no-pager --all 2>/dev/null | grep -ciE 'nightly|puffin' || true)
cron_has=$(crontab -l 2>/dev/null | grep -ciE 'nightly|puffin' || true)
schedule_has=$(jq '[.[] | select((.prompt // "") | test("nightly|puffin"; "i"))] | length' "$HOME/.claude/scheduled_tasks.json" 2>/dev/null || echo 0)

if [[ "${systemd_has:-0}" -eq 0 && "${cron_has:-0}" -eq 0 && "${schedule_has:-0}" -eq 0 ]]; then
  bash "$SCRIPT" >/dev/null 2>&1
  check "guard fires with no triggers (exit 2)" $? 2
  # Log line appended with timestamp
  if tail -1 "$LOG" 2>/dev/null | grep -q "BLOCKED: no scheduler triggers registered"; then
    echo "PASS: error log contains BLOCKED entry"; PASS=$((PASS+1))
  else
    echo "FAIL: error log missing BLOCKED entry"; FAIL=$((FAIL+1))
  fi
else
  echo "SKIP: host has $systemd_has systemd + $cron_has cron + $schedule_has schedule trigger(s); can't test failure path"
fi

# Test 3 (N3a): /schedule source alone is enough to satisfy the guard.
# Shim scheduled_tasks.json into a temp HOME so we don't clobber the user's real file.
TMPHOME=$(mktemp -d)
mkdir -p "$TMPHOME/.claude"
echo '[{"id":"test1","prompt":"bash ~/.claude/scripts/nightly-select-projects.sh","cron":"30 23 * * *"}]' > "$TMPHOME/.claude/scheduled_tasks.json"
HOME="$TMPHOME" bash "$SCRIPT" >/dev/null 2>&1
rc=$?
if [[ "$rc" -ne 2 ]]; then
  echo "PASS: /schedule source satisfies guard (exit=$rc, not 2)"; PASS=$((PASS+1))
else
  echo "FAIL: /schedule source should satisfy guard but got exit 2"
  FAIL=$((FAIL+1))
fi
rm -rf "$TMPHOME"

# Test 2: bypass via env var lets guard pass (even with no triggers).
# The script may exit non-zero for *other* reasons (gh auth, config missing) —
# we only assert the guard itself didn't exit 2.
out=$(NIGHTLY_SKIP_TRIGGER_CHECK=1 bash "$SCRIPT" 2>&1)
rc=$?
if [[ "$rc" -ne 2 ]]; then
  echo "PASS: NIGHTLY_SKIP_TRIGGER_CHECK=1 bypasses guard (exit=$rc, not 2)"; PASS=$((PASS+1))
else
  echo "FAIL: NIGHTLY_SKIP_TRIGGER_CHECK=1 should bypass guard but got exit 2"
  echo "  output: $out" | head -5
  FAIL=$((FAIL+1))
fi

echo ""
echo "Summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
