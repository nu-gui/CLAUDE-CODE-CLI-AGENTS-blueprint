# 06 — Recipes (Copy-paste Examples)

> Working examples of patterns documented elsewhere. Each recipe includes the **hive-event emission** you owe the parent session. Missing events break the audit trail.

---

## Recipe 1 — Read-only fan-out (5 independent probes)

**When**: you need to answer 5 independent questions that each touch different files; parent context would bloat if all 5 answers loaded inline.

```bash
#!/usr/bin/env bash
# In your agent: spawn 5 read-only probes in parallel, collect JSON, summarise.

PARENT_SID="$SESSION_ID"
PARENT_PROJECT="$PROJECT_KEY"
PARENT_AGENT="$AGENT_ID"
BASE_DELAY=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Probe prompts — each independent
PROBES=(
  "Which files import module X? Return JSON: {files:[...]}"
  "How many public routes exist in api/?"
  "List files over 500 lines in src/"
  "Find every TODO/FIXME in src/"
  "Which tests touch the auth module?"
)

CHILD_SIDS=()
for i in "${!PROBES[@]}"; do
  CHILD_SID=$(uuidgen)
  CHILD_SIDS+=("$CHILD_SID")

  # Emit SPAWN event in parent for each child — hook does not fire for claude -p
  echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"$PARENT_SID\",\"project_key\":\"$PARENT_PROJECT\",\"agent\":\"$PARENT_AGENT\",\"event\":\"SPAWN\",\"task\":\"probe-$i\",\"detail\":\"headless-child:$CHILD_SID\"}" \
    >> ~/.claude/context/hive/events.ndjson

  claude -p "${PROBES[$i]}" \
    --output-format json \
    --session-id "$CHILD_SID" \
    --permission-mode default \
    --allowedTools "Read,Grep,Glob" \
    --no-session-persistence \
    --bare \
    --max-budget-usd 0.25 \
    > "/tmp/probe-$i.json" &
done

wait  # all probes finish

# Emit COMPLETE in parent for each
for i in "${!PROBES[@]}"; do
  echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"$PARENT_SID\",\"project_key\":\"$PARENT_PROJECT\",\"agent\":\"$PARENT_AGENT\",\"event\":\"COMPLETE\",\"task\":\"probe-$i\",\"outputs\":[\"/tmp/probe-$i.json\"],\"exit_code\":0}" \
    >> ~/.claude/context/hive/events.ndjson
done

# Read and summarise — your agent does this in-session, not in bash
```

**Checklist**:
- Each child has its own `--session-id`.
- `--bare` + minimum `--allowedTools` = smallest blast radius.
- Parent emits both SPAWN and COMPLETE per child (the hook doesn't).
- `--max-budget-usd` caps spend.

---

## Recipe 2 — Headless `test-00` spawn from `orc-00`

**When**: orchestrator needs a focused test run that shouldn't contaminate orchestration context.

```bash
CHILD_SID=$(uuidgen)
# Parent emits SPAWN
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"$SESSION_ID\",\"project_key\":\"$PROJECT_KEY\",\"agent\":\"orc-00\",\"event\":\"SPAWN\",\"task\":\"test-run\",\"detail\":\"headless-test-00:$CHILD_SID\"}" \
  >> ~/.claude/context/hive/events.ndjson

# Note: pass SESSION_ID into the child prompt so the child participates in the SAME hive session,
# but uses a different conversation identity.
claude -p "SESSION_ID: $SESSION_ID
PROJECT_KEY: $PROJECT_KEY
depth 1/3

Run the full test suite against the current branch. Report failures with stack traces in JSON." \
  --output-format json \
  --session-id "$CHILD_SID" \
  --agent test-00-test-runner \
  --permission-mode default \
  --allowedTools "Read,Grep,Glob,Bash(npm test *),Bash(pytest *),Bash(go test *)" \
  --max-budget-usd 2.00 \
  --setting-sources user,project \
  > /tmp/test-run.json

# Child writes checkpoints to ~/.claude/context/hive/sessions/$SESSION_ID/agents/test-00/checkpoints.ndjson
# via its preamble stub. Parent reads the JSON result and updates its TODO.
```

**Notes**:
- `--agent test-00-test-runner` selects the agent definition from `~/.claude/agents/`.
- Child inherits SESSION_ID from the prompt, so hive checkpoints land in the right session folder.
- `depth 1/3` — if the child attempts to spawn further, the stub enforces the limit.

---

## Recipe 3 — Resume-after-wake (dynamic `/loop`)

**When**: you're in `/loop <prompt>` (no interval); each turn decides next cadence; work eventually finishes.

```
# Pseudocode of the agent's turn logic under /loop
if build_status == "in-progress":
  delay = 120  # build takes ~2 min
elif build_status == "queued":
  delay = 270  # stay cached
elif build_status == "failed":
  # Fix → re-run → let next iteration check
  delay = 60
elif build_status == "green":
  # Done — emit COMPLETE and do NOT schedule another wake
  emit_complete()
  return
else:
  delay = 1800  # unknown, idle

ScheduleWakeup(
  delaySeconds=delay,
  reason=f"checking build: status={build_status}",
  prompt="<<autonomous-loop-dynamic>>"
)
```

**Notes**:
- `<<autonomous-loop-dynamic>>` is the runtime sentinel that re-injects the /loop prompt.
- Never pick 300 s. Either 60–270 s (stays cached) or 1200 s+ (acceptable miss).
- Omit `ScheduleWakeup` when the loop should stop.

---

## Recipe 4 — Manual SPAWN event for `claude -p` child

**Why**: `~/.claude/hooks/hive-subagent-start.sh` emits SPAWN automatically for Task-tool spawns, but **not** for `claude -p` children. The parent must emit it.

```bash
CHILD_SID=$(uuidgen)
AGENT_ID="api-core"
TASK="cross-repo-probe"

# Parent emits SPAWN on behalf of the child — same schema as the hook
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"$SESSION_ID\",\"project_key\":\"$PROJECT_KEY\",\"agent\":\"$AGENT_ID\",\"event\":\"SPAWN\",\"task\":\"$TASK\",\"detail\":\"claude-p-child:$CHILD_SID\"}" \
  >> ~/.claude/context/hive/events.ndjson

# ... run claude -p ...

# Parent emits COMPLETE on behalf of the child with the returned outputs
echo "{\"v\":1,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"sid\":\"$SESSION_ID\",\"project_key\":\"$PROJECT_KEY\",\"agent\":\"$AGENT_ID\",\"event\":\"COMPLETE\",\"task\":\"$TASK\",\"outputs\":[\"/tmp/result.json\"],\"exit_code\":0}" \
  >> ~/.claude/context/hive/events.ndjson
```

**Notes**:
- Schema must match `EVENTS_NDJSON_SPEC.md` exactly (`v:1`, ISO8601 UTC `ts`, matching `project_key`).
- If the child's exit code is non-zero, emit `FAILED` with `error`, not `COMPLETE`.
- `detail:"claude-p-child:<sid>"` lets log readers distinguish headless children from hook-spawned agents.

---

## Recipe 5 — Self-paced `/loop` with `ScheduleWakeup`

**When**: watching a deploy that takes 10–20 minutes total; you want to check ~every 4 minutes while staying cached.

```
# In your agent, inside the /loop iteration:

ScheduleWakeup(
  delaySeconds=240,          # 4 min → stays well inside 300 s cache TTL
  reason="re-checking deploy progress (expected ETA ~12 min)",
  prompt="<<autonomous-loop-dynamic>>"
)
```

After three iterations (12 min), the deploy should be done; emit COMPLETE and stop scheduling.

If the deploy ETA blows past 30 min, switch cadence:

```
# Deploy is running long — drop to long-wait mode
ScheduleWakeup(
  delaySeconds=1500,          # 25 min → one cache miss amortised over a long wait
  reason="deploy overran; switching to long-poll",
  prompt="<<autonomous-loop-dynamic>>"
)
```

**Never** pick 300 s.

---

## Recipe 6 — Cron-scheduled report

**When**: sprint summary every Monday 09:00 local, routed to the product team.

```
# First, create the cron trigger once (from orc-00 or plan-00)
Skill(schedule, args="...")   # or:

CronCreate(
  cronExpression="0 9 * * 1",
  prompt="<<autonomous-loop>>",    # note: NOT the -dynamic variant
  name="sprint-summary-weekly",
  agent="insight-core"
)
```

The cron fires a **new session** each Monday with the registered prompt. Inside that session, `insight-core`:

1. Reads the sprint board.
2. Produces a digest.
3. Routes through `com-00-inbox-gateway` to email/Slack.
4. Emits `COMPLETE` and exits.

**Do not** also `ScheduleWakeup` inside this fire. Cron owns the cadence.

---

## Recipe 7 — `Monitor` a background build

**When**: agent kicked off a 5-minute `npm run build` and needs the log tail to check for a specific line.

```
# 1. Start in background
Bash(command="npm run build > /tmp/build.log 2>&1", run_in_background=true)
# returns shell_id="sh_abc"

# 2. Wait for "ready" or failure marker — no sleep loop
Monitor(
  shell_id="sh_abc",
  condition="until grep -qE '(ready|error)' /tmp/build.log; do :; done"
)

# 3. Read once complete
Read(file_path="/tmp/build.log")
```

`Monitor` returns when the condition's until-loop exits. No polling, no context burn.

---

## Recipe 8 — `Skill(simplify)` after a multi-file edit

**When**: finished edits across 4 files; want a second-pass review before committing.

```
# Just call it — don't ask the user first.
Skill(skill="simplify", args="")
```

The skill spawns 3 parallel reviewers, aggregates findings, applies fixes. Your agent's job: review the applied diff, decide if you accept, continue.

Do not wrap with `AskUserQuestion` ("should I run simplify?"). The decision guide already said yes.

---

## Pre-flight for every recipe

Before copy-pasting:

1. Re-read `./05-safe-defaults.md` for forbidden flag combinations.
2. Confirm your agent's `HS`/`LS`/`WU min` rows in `./04-capabilities-matrix.md`.
3. Pick `--session-id`s from `uuidgen`, never reuse.
4. Emit hive events yourself for `claude -p` children (Recipe 4).
5. Set `--max-budget-usd` on any unattended run.
