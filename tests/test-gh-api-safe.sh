#!/usr/bin/env bash
# tests/test-gh-api-safe.sh
#
# Minimal self-test for gh_api_safe() from scripts/lib/common.sh.
#
# Strategy: override PATH with a temp dir containing a fake `gh` script that
# fails the first two invocations, then succeeds on the third.
# Asserts:
#   1. gh_api_safe returns exit 0 on eventual success
#   2. stdout matches expected output
#   3. the fake `gh` was called exactly 3 times
#   4. on permanent failure (all 5 attempts fail), exit code 2 is returned
#      and a BLOCKED event is written to $EVENTS
#
# Run:
#   bash tests/test-gh-api-safe.sh
#
# No dependencies beyond bash + standard coreutils.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMMON="$SCRIPT_DIR/../scripts/lib/common.sh"

PASS_COUNT=0
FAIL_COUNT=0
pass() { echo "PASS: $1"; PASS_COUNT=$((PASS_COUNT+1)); }
fail() { echo "FAIL: $1" >&2; FAIL_COUNT=$((FAIL_COUNT+1)); }

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# Fake bin dir: only gh and sleep are overridden. All other tools (date, jq,
# mktemp, cat, grep, etc.) resolve from the real system PATH.
FAKE_BIN="$WORKDIR/fakebin"
mkdir -p "$FAKE_BIN"

# Stub sleep so tests finish instantly.
cat > "$FAKE_BIN/sleep" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$FAKE_BIN/sleep"

# Real PATH with fake bin prepended (expanded NOW so the runner script carries it).
AUGMENTED_PATH="$FAKE_BIN:$PATH"

# ---------------------------------------------------------------------------
# TEST 1: fail twice, succeed on attempt 3 — assert 3 calls + correct stdout
# ---------------------------------------------------------------------------
COUNTER1="$WORKDIR/counter1.txt"
EVENTS1="$WORKDIR/events1.ndjson"
echo 0 > "$COUNTER1"

cat > "$FAKE_BIN/gh" <<GHEOF
#!/bin/bash
count=\$(cat "$COUNTER1" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$COUNTER1"
if [[ \$count -le 2 ]]; then
  echo "transient error" >&2
  exit 1
fi
echo 'gh_output_ok'
exit 0
GHEOF
chmod +x "$FAKE_BIN/gh"

set +e
T1_STDOUT="$(
  PATH="$AUGMENTED_PATH" \
  HIVE="$WORKDIR" \
  EVENTS="$EVENTS1" \
  SESSION_ID="selftest" \
  bash -c "source '$COMMON'; gh_api_safe search issues --limit 5" 2>/dev/null
)"
T1_EXIT=$?
set -e

[[ $T1_EXIT -eq 0 ]] && pass "TEST 1: exit 0 on eventual success" \
  || fail "TEST 1: expected exit 0, got $T1_EXIT"

[[ "$T1_STDOUT" == "gh_output_ok" ]] && pass "TEST 1: stdout passes through correctly" \
  || fail "TEST 1: unexpected stdout: '$T1_STDOUT'"

T1_COUNT="$(cat "$COUNTER1" 2>/dev/null || echo 0)"
[[ "$T1_COUNT" -eq 3 ]] && pass "TEST 1: exactly 3 gh invocations" \
  || fail "TEST 1: expected 3 invocations, got $T1_COUNT"

# ---------------------------------------------------------------------------
# TEST 2: all 5 attempts fail → exit 2, BLOCKED event with GH_RATE_LIMIT emitted
# ---------------------------------------------------------------------------
COUNTER2="$WORKDIR/counter2.txt"
EVENTS2="$WORKDIR/events2.ndjson"
echo 0 > "$COUNTER2"

cat > "$FAKE_BIN/gh" <<GHEOF
#!/bin/bash
count=\$(cat "$COUNTER2" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$COUNTER2"
echo "server error" >&2
exit 1
GHEOF
chmod +x "$FAKE_BIN/gh"

set +e
PATH="$AUGMENTED_PATH" \
HIVE="$WORKDIR" \
EVENTS="$EVENTS2" \
SESSION_ID="selftest" \
bash -c "source '$COMMON'; gh_api_safe repo list ${GITHUB_ORG:-your-org}" >/dev/null 2>/dev/null
T2_EXIT=$?
set -e

[[ $T2_EXIT -eq 2 ]] && pass "TEST 2: exit 2 when all attempts exhausted" \
  || fail "TEST 2: expected exit 2, got $T2_EXIT"

T2_COUNT="$(cat "$COUNTER2" 2>/dev/null || echo 0)"
[[ "$T2_COUNT" -eq 5 ]] && pass "TEST 2: exactly 5 attempts before giving up" \
  || fail "TEST 2: expected 5 attempts, got $T2_COUNT"

if [[ -f "$EVENTS2" ]] && grep -q "BLOCKED" "$EVENTS2"; then
  pass "TEST 2: BLOCKED event written to events.ndjson"
else
  fail "TEST 2: BLOCKED event not found in events.ndjson"
fi

if [[ -f "$EVENTS2" ]] && grep -q "GH_RATE_LIMIT" "$EVENTS2"; then
  pass "TEST 2: BLOCKED event detail contains GH_RATE_LIMIT code"
else
  fail "TEST 2: GH_RATE_LIMIT code not found in BLOCKED event"
fi

# ---------------------------------------------------------------------------
# TEST 3: "Bad credentials" in stderr → exit 1, fail-fast (1 attempt only)
# ---------------------------------------------------------------------------
COUNTER3="$WORKDIR/counter3.txt"
EVENTS3="$WORKDIR/events3.ndjson"
echo 0 > "$COUNTER3"

cat > "$FAKE_BIN/gh" <<GHEOF
#!/bin/bash
count=\$(cat "$COUNTER3" 2>/dev/null || echo 0)
count=\$((count + 1))
echo "\$count" > "$COUNTER3"
echo "Bad credentials" >&2
exit 1
GHEOF
chmod +x "$FAKE_BIN/gh"

set +e
PATH="$AUGMENTED_PATH" \
HIVE="$WORKDIR" \
EVENTS="$EVENTS3" \
SESSION_ID="selftest" \
bash -c "source '$COMMON'; gh_api_safe issue list --repo ${GITHUB_ORG:-your-org}/test" >/dev/null 2>/dev/null
T3_EXIT=$?
set -e

[[ $T3_EXIT -eq 1 ]] && pass "TEST 3: auth failure returns exit 1" \
  || fail "TEST 3: expected exit 1, got $T3_EXIT"

T3_COUNT="$(cat "$COUNTER3" 2>/dev/null || echo 0)"
[[ "$T3_COUNT" -eq 1 ]] && pass "TEST 3: auth failure triggers exactly 1 attempt (fail-fast)" \
  || fail "TEST 3: expected 1 attempt for auth failure, got $T3_COUNT"

# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed."
[[ $FAIL_COUNT -eq 0 ]]
