# Hive Integration Protocol v3.8.0 (MANDATORY)

This is the standard preamble to inject into all agent definition files.
Replace the existing "Live Hive Protocol" section with this content.

---

## Hive Integration Protocol v3.8 (MANDATORY)

You are operating within the AI Agent Organization's recoverable execution environment.
**Compliance is NON-NEGOTIABLE.**

> **Environment variables in the bash snippets below** (`SESSION_ID`, `PROJECT_KEY`, `AGENT_ID`, `TASK_SUMMARY`, `TASK`, `FILE_PATH`, `CHANGE_SUMMARY`, `PERCENT`, `MILESTONE`) are set by the orchestrator in each agent's spawn environment. Do not redefine them locally; do not copy these snippets verbatim into scripts that run outside a spawned-agent context — they will emit malformed JSON with empty fields and fail silently.

### Extract SESSION_ID (First Action)

Your prompt MUST contain `SESSION_ID: xxx`. Extract it immediately:
```
SESSION_ID: {extracted from prompt}
PROJECT_KEY: {extracted from prompt or infer from SESSION_ID prefix}
SESSION_DIR: ~/.claude/context/hive/sessions/${SESSION_ID}/
DEPTH: {extracted from "depth N/M" in prompt, default 0}
```

**If SESSION_ID is missing from your prompt → HALT and report error. Do not proceed.**

**If DEPTH exceeds limit → HALT and report recursion error.**

### On Spawn (Before Any Work)

1. **Emit EVENT_LOG_BRIDGE event**:
   ```bash
   # Log to local session and bridge to external listeners
   echo '{"v":1,"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","sid":"'${SESSION_ID}'","agent":"'${AGENT_ID}'","event":"BRIDGE_ACTIVE","detail":"event-logging-bridge-v1"}' >> ~/.claude/context/hive/events.ndjson
   ```

2. **Verify session folder exists**:
   ```bash
   ls ~/.claude/context/hive/sessions/${SESSION_ID}/manifest.yaml
   ```
   If missing → HALT. Session was not initialized properly.

2. **Emit SPAWN event**:
   ```bash
   echo '{"v":1,"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","sid":"'${SESSION_ID}'","project_key":"'${PROJECT_KEY}'","agent":"'${AGENT_ID}'","event":"SPAWN","task":"'${TASK_SUMMARY}'"}' >> ~/.claude/context/hive/events.ndjson
   ```

3. **Create agent status file**:
   ```bash
   echo "agent: ${AGENT_ID}
   status: active
   task: ${TASK_SUMMARY}
   started: $(date -u +%Y-%m-%dT%H:%M:%SZ)" > ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}.status
   ```

### During Execution (Checkpoints — MANDATORY)

**REQUIRED: After EVERY file modification**, append to your checkpoint file. Skipping checkpoints breaks crash recovery and audit trails:
```bash
mkdir -p ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}
echo '{"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","action":"FILE_MODIFY","path":"'${FILE_PATH}'","summary":"'${CHANGE_SUMMARY}'"}' >> ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}/checkpoints.ndjson
```

**At significant milestones**, emit PROGRESS event:
```bash
echo '{"v":1,"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","sid":"'${SESSION_ID}'","agent":"'${AGENT_ID}'","event":"PROGRESS","task":"'${TASK}'","progress":'${PERCENT}',"detail":"'${MILESTONE}'"}' >> ~/.claude/context/hive/events.ndjson
```

**Compliance note**: Current checkpoint coverage is 21% across sessions. This is unacceptable. Every agent MUST write checkpoints — no exceptions.

### Before Return (Always — MANDATORY)

**REQUIRED: You MUST emit events before returning.** Current event compliance is 38%. Every agent must emit SPAWN on start and COMPLETE on finish.

1. **Emit COMPLETE event**:
   ```bash
   echo '{"v":1,"ts":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","sid":"'${SESSION_ID}'","project_key":"'${PROJECT_KEY}'","agent":"'${AGENT_ID}'","event":"COMPLETE","task":"'${TASK}'","outputs":["file1","file2"]}' >> ~/.claude/context/hive/events.ndjson
   ```

2. **Update agent status**:
   ```bash
   echo "agent: ${AGENT_ID}
   status: complete
   task: ${TASK_SUMMARY}
   completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)
   outputs:
     - file1
     - file2" > ~/.claude/context/hive/sessions/${SESSION_ID}/agents/${AGENT_ID}.status
   ```

3. **Update RESUME_PACKET.md** with your contributions:
   - Add your outputs to the "Completed Work" section
   - Update progress percentage
   - Note any blockers or follow-up tasks

### Failure Mode

If you cannot complete your task:
1. Emit BLOCKED or ERROR event with reason
2. Update status file to `status: blocked` or `status: error`
3. Return with clear explanation of what went wrong

---
